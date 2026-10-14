#!/usr/bin/env bash
# github-to-gitlab-sync: mirror the current git checkout to a GitLab repository.
#
# Configuration comes from environment variables (set by action.yml):
#   INPUT_GITLAB_TOKEN, INPUT_GITLAB_REPO, INPUT_GITLAB_URL, INPUT_GITLAB_USERNAME,
#   INPUT_BRANCHES, INPUT_SYNC_TAGS, INPUT_FORCE, INPUT_PRUNE, INPUT_DRY_RUN, INPUT_LFS
#
# Testing hooks (not part of the public interface):
#   G2G_REMOTE_URL          full remote URL, replaces <gitlab-url>/<gitlab-repo>.git
#   G2G_SOURCE_REMOTE       remote that holds the GitHub refs (default: origin)
#   G2G_FORCE_AUTH_HEADER   set to 1 to build the auth header even for non http URLs
#
# Exit codes: 0 success or no changes, 1 failure (including invalid input).

set -euo pipefail

STATUS="failed"
PUSHED_REFS=""
PRUNED_REFS=""
TMP_DIR=""
TOKEN=""
AUTH_B64=""

# ---------------------------------------------------------------- logging ---

in_actions() { [[ ${GITHUB_ACTIONS:-} == "true" ]]; }

log() { printf '%s\n' "$*"; }

warn() {
  if in_actions; then printf '::warning::%s\n' "$*"; else printf 'WARNING: %s\n' "$*" >&2; fi
}

err() {
  if in_actions; then printf '::error::%s\n' "$*"; else printf 'ERROR: %s\n' "$*" >&2; fi
}

die() {
  err "$*"
  exit 1
}

group() { if in_actions; then printf '::group::%s\n' "$*"; else printf '\n== %s ==\n' "$*"; fi; }
endgroup() { if in_actions; then printf '::endgroup::\n'; fi; }

# Print stdin with the token and the encoded auth header replaced by ***.
redact() {
  local line
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ -n $TOKEN ]]; then line=${line//"$TOKEN"/***}; fi
    if [[ -n $AUTH_B64 ]]; then line=${line//"$AUTH_B64"/***}; fi
    printf '%s\n' "$line"
  done
}

# ---------------------------------------------------------------- outputs ---

write_outputs() {
  [[ -n ${GITHUB_OUTPUT:-} ]] || return 0
  local delim="G2G_EOF_$$_${RANDOM}"
  {
    printf 'status=%s\n' "$STATUS"
    if [[ -n $PUSHED_REFS ]]; then
      printf 'pushed-refs<<%s\n%s\n%s\n' "$delim" "$PUSHED_REFS" "$delim"
    else
      printf 'pushed-refs=\n'
    fi
    if [[ -n $PRUNED_REFS ]]; then
      printf 'pruned-refs<<%s\n%s\n%s\n' "$delim" "$PRUNED_REFS" "$delim"
    else
      printf 'pruned-refs=\n'
    fi
  } >> "$GITHUB_OUTPUT"
}

on_exit() {
  write_outputs || true
  if [[ -n $TMP_DIR && -d $TMP_DIR ]]; then rm -rf "$TMP_DIR"; fi
}
trap on_exit EXIT

step_summary() {
  [[ -n ${GITHUB_STEP_SUMMARY:-} ]] || return 0
  printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"
}

# ------------------------------------------------------------- validation ---

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

parse_bool() {
  local name=$1 value
  value=$(lower "${2:-}")
  case $value in
    true) printf 'true' ;;
    false) printf 'false' ;;
    *) die "Input '$name' must be 'true' or 'false', got '${2:-}'." ;;
  esac
}

trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

PATTERNS=()
BRANCH_ALL="false"

validate_inputs() {
  TOKEN=${INPUT_GITLAB_TOKEN:-}
  if in_actions && [[ -n $TOKEN ]]; then printf '::add-mask::%s\n' "$TOKEN"; fi
  [[ -n $TOKEN ]] || die "Input 'gitlab-token' is required. Store the token as a GitHub secret and pass it as: gitlab-token: \${{ secrets.GITLAB_TOKEN }}"
  [[ $TOKEN != *[[:space:]]* ]] || die "Input 'gitlab-token' contains whitespace or a newline. Re-create the secret and paste the token without extra characters."

  GITLAB_REPO=${INPUT_GITLAB_REPO:-}
  [[ -n $GITLAB_REPO ]] || die "Input 'gitlab-repo' is required, for example: group/project"
  GITLAB_REPO=${GITLAB_REPO#/}
  GITLAB_REPO=${GITLAB_REPO%/}
  GITLAB_REPO=${GITLAB_REPO%.git}
  [[ $GITLAB_REPO != *://* ]] || die "Input 'gitlab-repo' must be a path like group/project, not a URL. Put the host in 'gitlab-url'."
  [[ $GITLAB_REPO =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$ ]] \
    || die "Input 'gitlab-repo' must look like group/project or group/subgroup/project, got '$GITLAB_REPO'."

  GITLAB_URL=${INPUT_GITLAB_URL:-https://gitlab.com}
  while [[ $GITLAB_URL == */ ]]; do GITLAB_URL=${GITLAB_URL%/}; done
  [[ $GITLAB_URL =~ ^https?://[^/@[:space:]?#]+(/[^@[:space:]?#]*)?$ ]] \
    || die "Input 'gitlab-url' must be an http(s) URL without credentials, like https://gitlab.com, got '$GITLAB_URL'."
  if [[ $GITLAB_URL == http://* ]]; then
    warn "gitlab-url uses plain http. The token will be sent unencrypted. Use https if you can."
  fi

  GITLAB_USERNAME=${INPUT_GITLAB_USERNAME:-oauth2}
  [[ $GITLAB_USERNAME =~ ^[^:[:space:]]+$ ]] || die "Input 'gitlab-username' must not be empty or contain ':' or whitespace."

  local branches
  branches=$(trim "${INPUT_BRANCHES:-all}")
  [[ -n $branches ]] || die "Input 'branches' must be 'all' or a comma separated list of names or glob patterns."
  if [[ $(lower "$branches") == "all" ]]; then
    BRANCH_ALL="true"
  else
    local raw item
    IFS=',' read -r -a raw <<< "$branches"
    for item in "${raw[@]}"; do
      item=$(trim "$item")
      [[ -n $item ]] || die "Input 'branches' has an empty entry: '$branches'."
      PATTERNS+=("$item")
    done
  fi

  SYNC_TAGS=$(parse_bool sync-tags "${INPUT_SYNC_TAGS:-true}")
  FORCE=$(parse_bool force "${INPUT_FORCE:-false}")
  PRUNE=$(parse_bool prune "${INPUT_PRUNE:-false}")
  DRY_RUN=$(parse_bool dry-run "${INPUT_DRY_RUN:-false}")
  LFS=$(parse_bool lfs "${INPUT_LFS:-false}")

  SOURCE_REMOTE=${G2G_SOURCE_REMOTE:-origin}
  REMOTE_URL=${G2G_REMOTE_URL:-${GITLAB_URL}/${GITLAB_REPO}.git}
}

check_environment() {
  command -v git > /dev/null 2>&1 || die "git is not installed on this runner."

  local version major minor
  version=$(git --version | sed -n 's/^git version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
  major=${version%%.*}
  minor=${version#*.}
  if [[ -z $version ]] || (( major < 2 || (major == 2 && minor < 31) )); then
    die "git 2.31 or newer is required (found '$(git --version)')."
  fi

  git rev-parse --is-inside-work-tree > /dev/null 2>&1 \
    || die "Not inside a git repository. Run actions/checkout with 'fetch-depth: 0' before this action."

  if [[ $LFS == "true" ]]; then
    git lfs version > /dev/null 2>&1 || die "Input 'lfs' is true but git-lfs is not installed on this runner."
  fi
}

ensure_full_history() {
  if [[ $(git rev-parse --is-shallow-repository) != "true" ]]; then return 0; fi

  warn "This is a shallow clone. Add 'fetch-depth: 0' to actions/checkout. Trying to fetch the full history now."
  git remote get-url "$SOURCE_REMOTE" > /dev/null 2>&1 \
    || die "Shallow clone and no '$SOURCE_REMOTE' remote to fetch from. Use actions/checkout with 'fetch-depth: 0'."
  if ! git fetch --quiet --unshallow --tags "$SOURCE_REMOTE" "+refs/heads/*:refs/remotes/${SOURCE_REMOTE}/*" 2>&1 | redact; then
    die "Could not unshallow the repository. Use actions/checkout with 'fetch-depth: 0'."
  fi
  [[ $(git rev-parse --is-shallow-repository) != "true" ]] || die "Repository is still shallow. Use actions/checkout with 'fetch-depth: 0'."
}

# ------------------------------------------------------------------- auth ---

GIT_CONFIG_N=0

add_git_config() {
  GIT_CONFIG_N=${GIT_CONFIG_COUNT:-0}
  export "GIT_CONFIG_KEY_${GIT_CONFIG_N}=$1"
  export "GIT_CONFIG_VALUE_${GIT_CONFIG_N}=$2"
  export GIT_CONFIG_COUNT=$((GIT_CONFIG_N + 1))
}

setup_auth() {
  AUTH_B64=$(printf '%s:%s' "$GITLAB_USERNAME" "$TOKEN" | base64 | tr -d '\n')
  if in_actions; then printf '::add-mask::%s\n' "$AUTH_B64"; fi

  # The header is scoped to the GitLab URL, so it is never sent to GitHub, and
  # lives only in this process environment. Nothing is written to .git/config.
  if [[ $REMOTE_URL == http* || ${G2G_FORCE_AUTH_HEADER:-} == "1" ]]; then
    add_git_config "http.${GITLAB_URL}/.extraheader" "Authorization: Basic ${AUTH_B64}"
  fi
  add_git_config "credential.${GITLAB_URL}.helper" ""

  export GIT_TERMINAL_PROMPT=0
  export GCM_INTERACTIVE=never
  unset GIT_TRACE GIT_TRACE_CURL GIT_CURL_VERBOSE GIT_TRACE_PACKET GIT_TRACE_SETUP || true
}

# Explain a failed git command from its (already redacted) stderr file.
explain_remote_error() {
  local file=$1
  if grep -qiE 'authentication failed|could not read (username|password)|invalid (username|credentials)|HTTP (401|403)|returned error: (401|403)' "$file"; then
    err "GitLab rejected the credentials."
    log "  Check that the token is valid, not expired, and has the write_repository scope."
    log "  For project and group tokens the role must be Developer or higher (Maintainer if the branch is protected)."
    log "  GitLab also answers 'authentication failed' when the project path is wrong or the token cannot see it."
  elif grep -qiE 'not found|does not appear to be a git repository|HTTP 404|returned error: 404' "$file"; then
    err "GitLab repository not found at ${GITLAB_URL}/${GITLAB_REPO}.git"
    log "  Check 'gitlab-repo' and 'gitlab-url'. The project must already exist on GitLab, this action does not create it."
  elif grep -qiE 'could not resolve host|failed to connect|connection (refused|timed out)|timed out|network is unreachable' "$file"; then
    err "Could not reach ${GITLAB_URL}."
    log "  Check 'gitlab-url' and that the runner can reach your GitLab server (self-hosted GitLab may need a self-hosted runner or a firewall rule)."
  elif grep -qiE 'ssl|certificate' "$file"; then
    err "TLS problem while talking to ${GITLAB_URL}."
    log "  A self-signed or private CA certificate is not trusted by this runner. Install the CA on the runner or use a certificate from a public CA."
  else
    err "git failed. See the output above."
  fi
}

# ----------------------------------------------------------- ref handling ---

matches_filter() {
  local name=$1 pattern
  if [[ $BRANCH_ALL == "true" ]]; then return 0; fi
  for pattern in "${PATTERNS[@]}"; do
    # shellcheck disable=SC2053 # glob matching on the pattern is intended
    if [[ $name == $pattern ]]; then return 0; fi
  done
  return 1
}

# Writes "<sha><TAB><destref><TAB><localref>" lines for every source branch and tag.
collect_source_refs() {
  local prefix="refs/remotes/${SOURCE_REMOTE}/"
  if [[ -z $(git for-each-ref --count=1 "$prefix") ]]; then
    warn "No remote-tracking refs under '${prefix}'. Falling back to local branches. Use actions/checkout with 'fetch-depth: 0' to sync every branch."
    prefix="refs/heads/"
  fi

  git for-each-ref --format='%(objectname) %(refname)' "$prefix" \
    | awk -v p="$prefix" '
        { ref = $2; if (index(ref, p) != 1) next
          name = substr(ref, length(p) + 1)
          if (name == "HEAD") next
          printf "%s\trefs/heads/%s\t%s\n", $1, name, ref }' > "$SRC_BRANCHES_ALL"

  : > "$SRC_TAGS"
  if [[ $SYNC_TAGS == "true" ]]; then
    git for-each-ref --format='%(objectname) %(refname)' refs/tags \
      | awk '{ printf "%s\t%s\t%s\n", $1, $2, $2 }' > "$SRC_TAGS"
  fi

  : > "$SRC_SELECTED"
  local sha destref localref
  while IFS=$'\t' read -r sha destref localref; do
    if matches_filter "${destref#refs/heads/}"; then
      printf '%s\t%s\t%s\n' "$sha" "$destref" "$localref" >> "$SRC_SELECTED"
    fi
  done < "$SRC_BRANCHES_ALL"
  cat "$SRC_TAGS" >> "$SRC_SELECTED"
}

DEST_DEFAULT_BRANCH=""

fetch_dest_refs() {
  local out="$TMP_DIR/ls-remote.out" errf="$TMP_DIR/ls-remote.err"
  if ! git ls-remote --symref "$REMOTE_URL" HEAD 'refs/heads/*' 'refs/tags/*' > "$out" 2> "$errf"; then
    redact < "$errf" >&2
    explain_remote_error "$errf"
    exit 1
  fi
  awk -F'\t' '$2 ~ /^refs\/(heads|tags)\// && $2 !~ /\^\{\}$/ { print $1 "\t" $2 }' "$out" > "$DEST_REFS"
  DEST_DEFAULT_BRANCH=$(awk -F'\t' '$2 == "HEAD" && $1 ~ /^ref: / { sub(/^ref: /, "", $1); print $1; exit }' "$out")
}

# plan file columns: action, sha, destref, destsha, localref
build_plan() {
  awk -F'\t' '
    FILENAME == ARGV[1] { dest[$2] = $1; next }
    {
      if (!($2 in dest))        printf "new\t%s\t%s\t-\t%s\n", $1, $2, $3
      else if (dest[$2] != $1)  printf "update\t%s\t%s\t%s\t%s\n", $1, $2, dest[$2], $3
      else                      printf "same\t%s\t%s\t%s\t%s\n", $1, $2, dest[$2], $3
    }' "$DEST_REFS" "$SRC_SELECTED" > "$PLAN"

  : > "$PRUNE_PLAN"
  if [[ $PRUNE != "true" ]]; then return 0; fi

  if [[ ! -s $SRC_BRANCHES_ALL ]]; then
    warn "Prune is on but no source branches were found. Skipping prune so nothing is deleted by mistake."
    return 0
  fi

  # Dest refs that no longer exist at the source. Branches must also match the
  # branch filter, so a filtered mirror never deletes branches it does not manage.
  local sha ref name
  awk -F'\t' '
    FILENAME == ARGV[1] { src[$2] = 1; next }
    FILENAME == ARGV[2] { src[$2] = 1; next }
    !($2 in src) { print $1 "\t" $2 }' "$SRC_BRANCHES_ALL" "$SRC_TAGS" "$DEST_REFS" > "$TMP_DIR/prune-candidates"
  while IFS=$'\t' read -r sha ref; do
    case $ref in
      refs/heads/*)
        name=${ref#refs/heads/}
        if ! matches_filter "$name"; then continue; fi
        if [[ $ref == "$DEST_DEFAULT_BRANCH" ]]; then
          warn "Not deleting '$name' on GitLab because it is the default branch there. Change the GitLab default branch first if you want it removed."
          continue
        fi
        ;;
      refs/tags/*)
        if [[ $SYNC_TAGS != "true" ]]; then continue; fi
        ;;
    esac
    printf '%s\t%s\n' "$sha" "$ref" >> "$PRUNE_PLAN"
  done < "$TMP_DIR/prune-candidates"
}

count_lines() { awk 'END { print NR }' "$1"; }

print_plan() {
  local action sha destref destsha localref
  while IFS=$'\t' read -r action sha destref destsha localref; do
    case $action in
      new) log "  new     $destref (${sha:0:7})" ;;
      update) log "  update  $destref (${destsha:0:7} -> ${sha:0:7})" ;;
    esac
  done < "$PLAN"
  while IFS=$'\t' read -r sha destref; do
    log "  delete  $destref (${sha:0:7})"
  done < "$PRUNE_PLAN"
  log "  unchanged: $(awk -F'\t' '$1 == "same"' "$PLAN" | awk 'END { print NR }') ref(s)"
}

# ------------------------------------------------------------------ push ----

REJECTED_COUNT=0
HINT_PROTECTED="false"
HINT_DIVERGED="false"
HINT_TAG_EXISTS="false"
HINT_OTHER="false"

BATCH_SPECS=()
BATCH_FLAGS=()

# Parse `git push --porcelain` output and update the result lists.
parse_push_output() {
  local file=$1 line flag rest refpair summary to
  while IFS= read -r line || [[ -n $line ]]; do
    flag=${line:0:1}
    case $flag in
      ' ' | '+' | '*' | '-' | '=' | '!') ;;
      *) continue ;;
    esac
    [[ $line == *$'\t'* ]] || continue
    rest=${line:1}
    rest=${rest#$'\t'}
    refpair=${rest%%$'\t'*}
    summary=${rest#*$'\t'}
    to=${refpair#*:}
    case $flag in
      ' ' | '+' | '*')
        PUSHED_REFS=${PUSHED_REFS:+$PUSHED_REFS$'\n'}$to
        ;;
      '-')
        PRUNED_REFS=${PRUNED_REFS:+$PRUNED_REFS$'\n'}$to
        ;;
      '!')
        REJECTED_COUNT=$((REJECTED_COUNT + 1))
        err "Rejected: $to $summary"
        case $summary in
          *"pre-receive hook declined"* | *"protected branch"* | *"hook declined"*) HINT_PROTECTED="true" ;;
          *"non-fast-forward"* | *"fetch first"* | *"stale info"*) HINT_DIVERGED="true" ;;
          *"already exists"*) HINT_TAG_EXISTS="true" ;;
          *) HINT_OTHER="true" ;;
        esac
        ;;
    esac
  done < "$file"
}

CUR_SPECS=()
CUR_FLAGS=()

# Push CUR_SPECS with CUR_FLAGS. Returns 1 without printing anything when GitLab
# declined a multi-ref push through a hook and the caller may retry ref by ref.
run_push() {
  local allow_fallback=$1
  local out="$TMP_DIR/push.out" errf="$TMP_DIR/push.err" rc=0 before=$REJECTED_COUNT
  local args=(push --porcelain --no-verify)
  if [[ $DRY_RUN == "true" ]]; then args+=(--dry-run); fi
  if [[ ${#CUR_FLAGS[@]} -gt 0 ]]; then args+=("${CUR_FLAGS[@]}"); fi
  args+=("$REMOTE_URL" "${CUR_SPECS[@]}")

  git "${args[@]}" > "$out" 2> "$errf" || rc=$?

  if (( rc != 0 )) && [[ $allow_fallback == "yes" && ${#CUR_SPECS[@]} -gt 1 ]]     && grep -qiE 'hook declined|protected branch' "$out" "$errf"; then
    return 1
  fi

  redact < "$errf" >&2
  parse_push_output "$out"

  if (( rc != 0 && REJECTED_COUNT == before )); then
    # Failed without a per-ref rejection: auth, network, or server error.
    explain_remote_error "$errf"
    exit 1
  fi
  return 0
}

flush_batch() {
  [[ ${#BATCH_SPECS[@]} -gt 0 ]] || return 0

  CUR_SPECS=("${BATCH_SPECS[@]}")
  CUR_FLAGS=()
  if [[ ${#BATCH_FLAGS[@]} -gt 0 ]]; then CUR_FLAGS=("${BATCH_FLAGS[@]}"); fi
  BATCH_SPECS=()
  BATCH_FLAGS=()

  if run_push yes; then return 0; fi

  # A rejected ref makes a hook refuse the whole push. Retry one ref at a time so
  # a single protected branch does not block every other ref.
  log "GitLab declined the combined push. Retrying ref by ref to find which refs are blocked."
  local specs=("${CUR_SPECS[@]}") flags=() spec flag target
  if [[ ${#CUR_FLAGS[@]} -gt 0 ]]; then flags=("${CUR_FLAGS[@]}"); fi
  for spec in "${specs[@]}"; do
    target=${spec#*:}
    CUR_SPECS=("$spec")
    CUR_FLAGS=()
    if [[ ${#flags[@]} -gt 0 ]]; then
      for flag in "${flags[@]}"; do
        if [[ $flag == *"=${target}:"* ]]; then CUR_FLAGS+=("$flag"); fi
      done
    fi
    run_push no
  done
}

add_to_batch() {
  BATCH_SPECS+=("$1")
  if [[ $# -gt 1 ]]; then BATCH_FLAGS+=("$2"); fi
  if [[ ${#BATCH_SPECS[@]} -ge 100 ]]; then flush_batch; fi
}

lfs_transfer() {
  local refs=() action sha destref destsha localref
  while IFS=$'\t' read -r action sha destref destsha localref; do
    if [[ $action == "new" || $action == "update" ]]; then refs+=("$localref"); fi
  done < "$PLAN"
  [[ ${#refs[@]} -gt 0 ]] || return 0

  group "Git LFS"
  if git remote get-url "$SOURCE_REMOTE" > /dev/null 2>&1; then
    log "Fetching all LFS objects from '$SOURCE_REMOTE'"
    git lfs fetch --all "$SOURCE_REMOTE" 2>&1 | redact || die "git lfs fetch failed."
  fi
  local lfs_args=(lfs push --all)
  if [[ $DRY_RUN == "true" ]]; then lfs_args+=(--dry-run); fi
  local i=0 chunk=50
  while (( i < ${#refs[@]} )); do
    local errf="$TMP_DIR/lfs.err" rc=0
    git "${lfs_args[@]}" "$REMOTE_URL" "${refs[@]:i:chunk}" > "$TMP_DIR/lfs.out" 2> "$errf" || rc=$?
    redact < "$TMP_DIR/lfs.out"
    redact < "$errf" >&2
    if (( rc != 0 )); then
      explain_remote_error "$errf"
      die "git lfs push failed. Nothing was pushed to GitLab."
    fi
    i=$((i + chunk))
  done
  endgroup
}

execute_plan() {
  local action sha destref destsha localref
  while IFS=$'\t' read -r action sha destref destsha localref; do
    case $action in
      new)
        add_to_batch "${sha}:${destref}"
        ;;
      update)
        if [[ $destref == refs/tags/* ]]; then
          if [[ $FORCE == "true" ]]; then
            add_to_batch "+${destref}:${destref}"
          else
            add_to_batch "${destref}:${destref}"
          fi
        else
          if [[ $FORCE == "true" ]]; then
            add_to_batch "${sha}:${destref}" "--force-with-lease=${destref}:${destsha}"
          else
            add_to_batch "${sha}:${destref}"
          fi
        fi
        ;;
    esac
  done < "$PLAN"

  while IFS=$'\t' read -r sha destref; do
    add_to_batch ":${destref}"
  done < "$PRUNE_PLAN"

  flush_batch
}

print_hints() {
  if [[ $HINT_PROTECTED == "true" ]]; then
    log ""
    log "Some pushes were refused by GitLab, most likely because of a protected branch or tag."
    log "  Fix: in GitLab open Settings > Repository > Protected branches (or Protected tags) and either allow the token's role"
    log "  to push (and to force push, if you use 'force: true'), or unprotect the branch."
    log "  The default branch is protected by default, and only Maintainers can push to it."
  fi
  if [[ $HINT_DIVERGED == "true" ]]; then
    log ""
    log "Some branches on GitLab have commits that GitHub does not have (diverged history)."
    log "  Fix: set 'force: true' to overwrite GitLab with GitHub (this discards the extra GitLab commits),"
    log "  or stop pushing to the mirror from anywhere else."
  fi
  if [[ $HINT_TAG_EXISTS == "true" ]]; then
    log ""
    log "Some tags already exist on GitLab and point to a different commit."
    log "  Fix: set 'force: true' to move them, or delete the tags on GitLab."
  fi
  if [[ $HINT_OTHER == "true" ]]; then
    log ""
    log "Some refs were rejected for another reason. See the git output above."
  fi
}

# ------------------------------------------------------------------- main ---

main() {
  validate_inputs
  check_environment
  setup_auth
  ensure_full_history

  TMP_DIR=$(mktemp -d)
  SRC_BRANCHES_ALL="$TMP_DIR/src-branches-all"
  SRC_TAGS="$TMP_DIR/src-tags"
  SRC_SELECTED="$TMP_DIR/src-selected"
  DEST_REFS="$TMP_DIR/dest-refs"
  PLAN="$TMP_DIR/plan"
  PRUNE_PLAN="$TMP_DIR/prune-plan"

  log "Source:      $(git remote get-url "$SOURCE_REMOTE" 2> /dev/null | sed -E 's#(https?://)[^/@]*@#\1#' || true)"
  log "Destination: ${GITLAB_URL}/${GITLAB_REPO}.git"
  if [[ $DRY_RUN == "true" ]]; then log "DRY RUN: nothing will be pushed."; fi

  if [[ $LFS == "false" ]] && git grep -q -e 'filter=lfs' HEAD -- '*.gitattributes' 2> /dev/null; then
    warn "This repository uses Git LFS but 'lfs' is false. GitLab will receive LFS pointer files without the real content. Set 'lfs: true' to copy LFS objects."
  fi

  collect_source_refs
  if [[ ! -s $SRC_SELECTED ]]; then
    warn "No source branches or tags matched. Check the 'branches' input and that actions/checkout used 'fetch-depth: 0'."
  fi

  fetch_dest_refs
  build_plan

  local changes pruned
  changes=$(awk -F'\t' '$1 == "new" || $1 == "update"' "$PLAN" | awk 'END { print NR }')
  pruned=$(count_lines "$PRUNE_PLAN")

  group "Plan"
  print_plan
  endgroup

  if (( changes == 0 && pruned == 0 )); then
    log "GitLab is already up to date. Nothing to push."
    STATUS="no-changes"
    step_summary "### github-to-gitlab-sync" "" "GitLab is already up to date."
    return 0
  fi

  if [[ $LFS == "true" ]]; then lfs_transfer; fi

  group "Push"
  execute_plan
  endgroup

  print_hints
  if (( REJECTED_COUNT > 0 )); then
    STATUS="failed"
    err "$REJECTED_COUNT ref(s) were rejected. Pushed: $(printf '%s' "$PUSHED_REFS" | awk 'END { print NR }') ref(s)."
    exit 1
  fi

  if [[ $DRY_RUN == "true" ]]; then
    log "Dry run complete. Would push $changes ref(s) and delete $pruned ref(s)."
    # Nothing was pushed, so the output lists stay empty.
    PUSHED_REFS=""
    PRUNED_REFS=""
    STATUS="success"
    return 0
  fi

  STATUS="success"
  log "Done. Pushed $(printf '%s' "$PUSHED_REFS" | awk 'END { print NR }') ref(s), deleted $(printf '%s' "$PRUNED_REFS" | awk 'END { print NR }')."
  step_summary "### github-to-gitlab-sync" "" "Pushed ${changes} ref(s) to \`${GITLAB_URL}/${GITLAB_REPO}\`."
}

main "$@"
