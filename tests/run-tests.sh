#!/usr/bin/env bash
# Test suite for scripts/sync.sh. Needs only bash and git.
#
# Every test builds throwaway local repos: a bare repo plays "GitHub", a clone of
# it plays the Actions checkout, and another bare repo plays "GitLab".
#
# Usage: tests/run-tests.sh [name-filter]

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SYNC="$ROOT/scripts/sync.sh"
FILTER=${1:-}

# Keep the host git configuration out of the tests.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@example.invalid"
export GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@example.invalid"
unset GITHUB_ACTIONS GITHUB_OUTPUT GITHUB_STEP_SUMMARY GIT_CONFIG_COUNT

TOKEN="glpat-SuperSecretTokenValue-0123456789"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
CURRENT=""

# ---------------------------------------------------------------- helpers ---

native_path() {
  if (cd "$1" && pwd -W > /dev/null 2>&1); then (cd "$1" && pwd -W); else (cd "$1" && pwd); fi
}

ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }

bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL %s (in %s)\n' "$1" "$CURRENT"
  if [[ -n ${2:-} ]]; then printf '%s\n' "$2" | sed 's/^/       /'; fi
}

assert_eq() { # expected actual message
  if [[ $1 == "$2" ]]; then ok "$3"; else bad "$3" "expected: $1"$'\n'"actual:   $2"; fi
}

assert_contains() { # haystack needle message
  if [[ $1 == *"$2"* ]]; then ok "$3"; else bad "$3" "missing: $2"$'\n'"in output:"$'\n'"$1"; fi
}

assert_not_contains() { # haystack needle message
  if [[ $1 != *"$2"* ]]; then ok "$3"; else bad "$3" "unexpected: $2"; fi
}

# Build the source repos. Sets GH (bare "GitHub"), SRC (the checkout).
new_source() {
  local dir=$1
  GH="$dir/github.git"
  SRC="$dir/src"
  git init -q --bare -b main "$GH"
  git clone -q "$GH" "$SRC" 2> /dev/null
  (
    cd "$SRC"
    git checkout -q -b main
    echo one > file.txt && git add . && git commit -q -m "one"
    git tag v1
    echo two >> file.txt && git commit -q -am "two"
    git tag -a v2 -m "release two"
    git checkout -q -b feature/a && echo a > a.txt && git add . && git commit -q -m "a"
    git checkout -q main && git checkout -q -b feature/b && echo b > b.txt && git add . && git commit -q -m "b"
    git checkout -q main && git checkout -q -b hotfix && echo h > h.txt && git add . && git commit -q -m "hotfix"
    git checkout -q main
    git push -q origin --all 2> /dev/null
    git push -q origin --tags 2> /dev/null
    git fetch -q origin
  )
}

new_dest() { git init -q --bare -b main "$1/gitlab.git"; DEST="$1/gitlab.git"; }

# Run the sync script from SRC. Extra VAR=value arguments override the defaults.
# Sets OUT (combined output), RC, OUTFILE (the GITHUB_OUTPUT file).
run_sync() {
  OUTFILE="$WORK/github-output-$RANDOM"
  : > "$OUTFILE"
  RC=0
  OUT=$(cd "$SRC" && env \
    INPUT_GITLAB_TOKEN="$TOKEN" \
    INPUT_GITLAB_REPO="group/project" \
    G2G_REMOTE_URL="$DEST" \
    GITHUB_OUTPUT="$OUTFILE" \
    "$@" \
    bash "$SYNC" 2>&1) || RC=$?
}

get_output() { # name
  awk -v key="$1" '
    index($0, key "=") == 1 { print substr($0, length(key) + 2); next }
    index($0, key "<<") == 1 { delim = substr($0, length(key) + 3); inblock = 1; next }
    inblock && $0 == delim { inblock = 0; next }
    inblock { print }' "$OUTFILE"
}

dest_refs() { git -C "$DEST" for-each-ref --format='%(refname)' | sort | tr '\n' ' '; }
dest_sha() { git -C "$DEST" rev-parse --verify -q "$1" 2> /dev/null || echo "missing"; }
src_sha() { git -C "$SRC" rev-parse "$1"; }

# Remove a branch on "GitHub" and refresh the checkout, like a fresh clone would see.
delete_source_branch() {
  git -C "$GH" branch -q -D "$1"
  git -C "$SRC" fetch -q --prune origin
}

# Put an extra commit on a GitLab branch so history diverges.
diverge_dest() { # branch
  local clone="$WORK/diverge-$RANDOM"
  git clone -q "$DEST" "$clone" 2> /dev/null
  (cd "$clone" && git checkout -q "$1" && echo extra > extra.txt && git add . && git commit -q -m "gitlab only" && git push -q origin "$1" 2> /dev/null)
}

run_test() {
  local name=$1
  if [[ -n $FILTER && $name != *"$FILTER"* ]]; then return 0; fi
  CURRENT=$name
  printf '%s\n' "$name"
  local dir="$WORK/$name"
  mkdir -p "$dir"
  new_source "$dir"
  new_dest "$dir"
  "test_$name"
}

# ------------------------------------------------------------------ tests ---

test_normal_push() {
  run_sync
  assert_eq 0 "$RC" "exits 0"
  assert_eq "success" "$(get_output status)" "status is success"
  assert_eq "$(src_sha main)" "$(dest_sha main)" "main matches"
  assert_eq "$(src_sha feature/a)" "$(dest_sha feature/a)" "feature/a matches"
  assert_eq "$(src_sha feature/b)" "$(dest_sha feature/b)" "feature/b matches"
  assert_eq "$(src_sha hotfix)" "$(dest_sha hotfix)" "hotfix matches"
  assert_contains "$(get_output pushed-refs)" "refs/heads/main" "pushed-refs lists main"
  run_sync
  assert_eq 0 "$RC" "second run exits 0"
  assert_eq "no-changes" "$(get_output status)" "second run reports no-changes"
  assert_eq "" "$(get_output pushed-refs)" "second run pushes nothing"
}

test_tags() {
  run_sync
  assert_eq "$(src_sha refs/tags/v1)" "$(dest_sha refs/tags/v1)" "lightweight tag pushed"
  assert_eq "$(src_sha refs/tags/v2)" "$(dest_sha refs/tags/v2)" "annotated tag object pushed"
  assert_eq "tag" "$(git -C "$DEST" cat-file -t refs/tags/v2)" "annotated tag stays annotated"
  assert_contains "$(get_output pushed-refs)" "refs/tags/v1" "pushed-refs lists tags"

  new_dest "$WORK/$CURRENT/second"
  run_sync INPUT_SYNC_TAGS=false G2G_REMOTE_URL="$DEST"
  assert_eq "success" "$(get_output status)" "sync-tags=false still succeeds"
  assert_not_contains "$(dest_refs)" "refs/tags/" "sync-tags=false pushes no tags"
}

test_branch_filter() {
  run_sync INPUT_BRANCHES="main"
  assert_eq "refs/heads/main refs/tags/v1 refs/tags/v2 " "$(dest_refs)" "exact name pushes only main (plus tags)"

  new_dest "$WORK/$CURRENT/glob"
  run_sync INPUT_BRANCHES="main, feature/*" INPUT_SYNC_TAGS=false G2G_REMOTE_URL="$DEST"
  assert_eq "refs/heads/feature/a refs/heads/feature/b refs/heads/main " "$(dest_refs)" "list with glob and spaces"

  new_dest "$WORK/$CURRENT/none"
  run_sync INPUT_BRANCHES="does-not-exist" INPUT_SYNC_TAGS=false G2G_REMOTE_URL="$DEST"
  assert_contains "$OUT" "No source branches or tags matched" "warns when nothing matches"
}

test_prune_off() {
  run_sync
  delete_source_branch hotfix
  run_sync
  assert_eq 0 "$RC" "exits 0"
  assert_contains "$(dest_refs)" "refs/heads/hotfix" "deleted branch stays on GitLab when prune is off"
}

test_prune_on() {
  run_sync
  delete_source_branch hotfix
  git -C "$GH" tag -d v1 > /dev/null
  git -C "$SRC" tag -d v1 > /dev/null
  run_sync INPUT_PRUNE=true
  assert_eq 0 "$RC" "exits 0"
  assert_eq "success" "$(get_output status)" "status is success"
  assert_not_contains "$(dest_refs)" "refs/heads/hotfix" "deleted branch is pruned"
  assert_not_contains "$(dest_refs)" "refs/tags/v1" "deleted tag is pruned"
  assert_contains "$(dest_refs)" "refs/heads/main" "other branches survive"
  assert_contains "$(get_output pruned-refs)" "refs/heads/hotfix" "pruned-refs lists the branch"
}

test_prune_respects_filter() {
  run_sync
  delete_source_branch hotfix
  run_sync INPUT_PRUNE=true INPUT_BRANCHES="main"
  assert_contains "$(dest_refs)" "refs/heads/hotfix" "branch outside the filter is not pruned"
  assert_contains "$(dest_refs)" "refs/heads/feature/a" "unfiltered branches are not pruned"
  run_sync INPUT_PRUNE=true INPUT_BRANCHES="hotfix"
  assert_not_contains "$(dest_refs)" "refs/heads/hotfix" "branch inside the filter is pruned"
}

test_prune_keeps_tags_when_not_syncing_tags() {
  run_sync
  git -C "$SRC" tag -d v1 > /dev/null
  run_sync INPUT_PRUNE=true INPUT_SYNC_TAGS=false
  assert_contains "$(dest_refs)" "refs/tags/v1" "tags are untouched when sync-tags is false"
}

test_dry_run() {
  run_sync INPUT_DRY_RUN=true
  assert_eq 0 "$RC" "exits 0"
  assert_eq "" "$(dest_refs)" "nothing was pushed"
  assert_contains "$OUT" "DRY RUN" "says it is a dry run"
  assert_contains "$OUT" "new     refs/heads/main" "prints the plan"
  assert_eq "success" "$(get_output status)" "status is success"
  assert_eq "" "$(get_output pushed-refs)" "pushed-refs is empty"

  run_sync
  delete_source_branch hotfix
  run_sync INPUT_DRY_RUN=true INPUT_PRUNE=true
  assert_contains "$(dest_refs)" "refs/heads/hotfix" "dry run does not prune"
  assert_contains "$OUT" "delete  refs/heads/hotfix" "dry run lists the pending delete"
}

test_diverged_without_force() {
  run_sync
  diverge_dest main
  echo three >> "$SRC/file.txt"
  git -C "$SRC" commit -q -am "three"
  git -C "$SRC" push -q origin main 2> /dev/null
  git -C "$SRC" fetch -q origin
  local before
  before=$(dest_sha main)
  run_sync
  assert_eq 1 "$RC" "exits 1"
  assert_eq "failed" "$(get_output status)" "status is failed"
  assert_eq "$before" "$(dest_sha main)" "GitLab main is untouched"
  assert_contains "$OUT" "force: true" "explains how to fix it"
}

test_diverged_with_force() {
  run_sync
  diverge_dest main
  echo three >> "$SRC/file.txt"
  git -C "$SRC" commit -q -am "three"
  git -C "$SRC" push -q origin main 2> /dev/null
  git -C "$SRC" fetch -q origin
  run_sync INPUT_FORCE=true
  assert_eq 0 "$RC" "exits 0"
  assert_eq "success" "$(get_output status)" "status is success"
  assert_eq "$(src_sha origin/main)" "$(dest_sha main)" "GitLab main now equals GitHub main"
}

test_moved_tag_force() {
  run_sync
  git -C "$GH" tag -f v1 "$(src_sha feature/a)" > /dev/null
  git -C "$SRC" fetch -q --tags --force origin
  local before
  before=$(dest_sha refs/tags/v1)
  run_sync
  assert_eq 1 "$RC" "moved tag fails without force"
  assert_eq "$before" "$(dest_sha refs/tags/v1)" "tag on GitLab is untouched"
  assert_contains "$OUT" "already exists" "mentions the existing tag"
  run_sync INPUT_FORCE=true
  assert_eq 0 "$RC" "moved tag succeeds with force"
  assert_eq "$(src_sha refs/tags/v1)" "$(dest_sha refs/tags/v1)" "tag moved on GitLab"
}

test_protected_branch() {
  cat > "$DEST/hooks/pre-receive" << 'HOOK'
#!/bin/sh
while read old new ref; do
  if [ "$ref" = "refs/heads/main" ]; then
    echo "GitLab: You are not allowed to push code to protected branches on this project." >&2
    exit 1
  fi
done
exit 0
HOOK
  chmod +x "$DEST/hooks/pre-receive"
  run_sync
  assert_eq 1 "$RC" "exits 1"
  assert_eq "failed" "$(get_output status)" "status is failed"
  assert_contains "$OUT" "protected branch" "explains protected branches"
  assert_contains "$(dest_refs)" "refs/heads/hotfix" "other refs are still pushed"
  assert_contains "$(get_output pushed-refs)" "refs/heads/hotfix" "pushed-refs lists what did go through"
}

test_token_never_printed() {
  local cfg_before
  cfg_before=$(cat "$SRC/.git/config")

  run_sync G2G_FORCE_AUTH_HEADER=1
  assert_eq 0 "$RC" "sync with auth header exits 0"
  assert_not_contains "$OUT" "$TOKEN" "token absent from output"
  local b64
  b64=$(printf '%s:%s' "oauth2" "$TOKEN" | base64 | tr -d '\n')
  assert_not_contains "$OUT" "$b64" "encoded header absent from output"
  assert_eq "$cfg_before" "$(cat "$SRC/.git/config")" ".git/config is unchanged"
  if grep -rqF -e "$TOKEN" -e "$b64" "$SRC/.git" "$DEST" 2> /dev/null; then
    bad "token or header found inside a .git directory"
  else
    ok "token not stored in any .git directory"
  fi

  # Failure path: unreachable host. The error text must not leak the token either.
  run_sync G2G_REMOTE_URL="" INPUT_GITLAB_URL="http://127.0.0.1:9"
  assert_eq 1 "$RC" "unreachable host exits 1"
  assert_not_contains "$OUT" "$TOKEN" "token absent from failure output"
  assert_not_contains "$OUT" "$b64" "encoded header absent from failure output"
  assert_contains "$OUT" "Could not reach" "explains the connection problem"
  assert_eq "failed" "$(get_output status)" "status is failed"

  # Inside Actions the script masks the token. Only the mask command may contain it.
  run_sync GITHUB_ACTIONS=true
  assert_contains "$OUT" "::add-mask::" "emits add-mask inside Actions"
  assert_not_contains "$(printf '%s\n' "$OUT" | grep -v '^::add-mask::')" "$TOKEN" "token only appears in add-mask lines"
}

test_input_validation() {
  run_sync INPUT_GITLAB_TOKEN=""
  assert_eq 1 "$RC" "missing token fails"
  assert_contains "$OUT" "'gitlab-token' is required" "missing token message"
  assert_eq "failed" "$(get_output status)" "missing token sets status failed"

  run_sync INPUT_GITLAB_REPO="justone"
  assert_eq 1 "$RC" "single segment repo fails"
  assert_contains "$OUT" "group/project" "repo message shows the expected shape"

  run_sync INPUT_GITLAB_REPO="https://gitlab.com/group/project"
  assert_eq 1 "$RC" "repo given as URL fails"
  assert_contains "$OUT" "not a URL" "repo URL message"

  run_sync INPUT_GITLAB_URL="gitlab.com"
  assert_eq 1 "$RC" "url without scheme fails"
  run_sync INPUT_GITLAB_URL="https://user:pw@gitlab.com"
  assert_eq 1 "$RC" "url with credentials fails"

  run_sync INPUT_FORCE="maybe"
  assert_eq 1 "$RC" "bad boolean fails"
  assert_contains "$OUT" "'force' must be 'true' or 'false'" "boolean message"

  run_sync INPUT_BRANCHES="main,,dev"
  assert_eq 1 "$RC" "empty branch entry fails"

  run_sync INPUT_GITLAB_TOKEN=$'abc\ndef'
  assert_eq 1 "$RC" "token with newline fails"
  assert_not_contains "$OUT" "abc" "bad token is not echoed"

  run_sync INPUT_GITLAB_REPO="group/project.git" INPUT_GITLAB_URL="https://gitlab.example.com/"
  assert_eq 0 "$RC" "trailing .git and trailing slash are accepted"
}

test_not_a_repo() {
  local empty="$WORK/not-a-repo"
  mkdir -p "$empty"
  local saved=$SRC
  SRC=$empty
  run_sync
  SRC=$saved
  assert_eq 1 "$RC" "exits 1 outside a repository"
  assert_contains "$OUT" "fetch-depth: 0" "tells the user about checkout"
}

test_shallow_clone() {
  local shallow="$WORK/$CURRENT/shallow"
  git clone -q --depth 1 "file://$(native_path "$GH")" "$shallow" 2> /dev/null
  local saved=$SRC
  SRC=$shallow
  run_sync
  SRC=$saved
  assert_eq 0 "$RC" "exits 0"
  assert_contains "$OUT" "shallow clone" "warns about the shallow clone"
  assert_eq "$(src_sha main)" "$(dest_sha main)" "main pushed after unshallow"
  assert_eq "$(src_sha feature/a)" "$(dest_sha feature/a)" "other branches fetched and pushed"
  assert_eq "false" "$(git -C "$shallow" rev-parse --is-shallow-repository)" "checkout is no longer shallow"
}

test_lfs_warning_and_input() {
  (
    cd "$SRC"
    echo '*.bin filter=lfs diff=lfs merge=lfs -text' > .gitattributes
    git add . && git commit -q -m "lfs attributes"
  )
  run_sync
  assert_contains "$OUT" "uses Git LFS" "warns when LFS is used but lfs is false"
  run_sync INPUT_LFS=sometimes
  assert_eq 1 "$RC" "invalid lfs value fails"
}

test_local_branches_fallback() {
  local solo="$WORK/$CURRENT/solo"
  git init -q -b main "$solo"
  (cd "$solo" && echo x > x && git add . && git commit -q -m x && git tag t1)
  local saved=$SRC
  SRC=$solo
  run_sync
  SRC=$saved
  assert_eq 0 "$RC" "exits 0 without an origin remote"
  assert_contains "$(dest_refs)" "refs/heads/main" "local branch pushed"
  assert_contains "$(dest_refs)" "refs/tags/t1" "local tag pushed"
}

# ------------------------------------------------------------------- main ---

for t in $(declare -F | awk '$3 ~ /^test_/ { sub(/^test_/, "", $3); print $3 }'); do
  run_test "$t"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
