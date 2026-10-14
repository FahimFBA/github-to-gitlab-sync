# GitHub to GitLab Sync

Mirror a GitHub repository to GitLab with a few lines of workflow YAML. Works with gitlab.com and self-hosted GitLab.

- Pushes branches and tags from GitHub to a GitLab project
- Branch filters with names and glob patterns
- Optional prune (opt-in) and dry run
- Force push with a safer `--force-with-lease` for branches
- Token handling that keeps the secret out of logs, remote URLs, and `.git/config`
- Composite action written in plain bash, no Docker image to pull and no Node runtime

Version 1 syncs in one direction only: **GitHub to GitLab**. GitLab to GitHub is on the [roadmap](#roadmap).

Documentation site: https://FahimFBA.github.io/github-to-gitlab-sync-site/

## Quick start

1. Create an empty project on GitLab (this action does not create it).
2. [Create a GitLab access token](#create-the-gitlab-token) with the `write_repository` scope.
3. [Add the token as a GitHub secret](#add-the-github-secret) named `GITLAB_TOKEN`.
4. Add this workflow at `.github/workflows/mirror.yml`:

```yaml
name: Mirror to GitLab

on:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  mirror:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - uses: FahimFBA/github-to-gitlab-sync@v1
        with:
          gitlab-token: ${{ secrets.GITLAB_TOKEN }}
          gitlab-repo: my-group/my-project
```

`fetch-depth: 0` matters. Without it the checkout is shallow and has only one branch. The action will try to fetch the missing history and warn you, but it is faster and more reliable to check out everything up front.

More ready-to-copy workflows are in [`examples/`](examples/):

| File | What it shows |
| --- | --- |
| [`basic.yml`](examples/basic.yml) | Mirror `main` on every push |
| [`all-branches-and-tags.yml`](examples/all-branches-and-tags.yml) | Mirror every branch and tag, with prune |
| [`scheduled-mirror.yml`](examples/scheduled-mirror.yml) | Nightly mirror plus a manual run with dry run |
| [`self-hosted-gitlab.yml`](examples/self-hosted-gitlab.yml) | Self-hosted GitLab and a branch filter |
| [`ci-for-this-action.yml`](examples/ci-for-this-action.yml) | CI for contributors (copy into your fork) |

## Create the GitLab token

You need a token that can push to the target project. Pick one kind:

**Project access token (recommended).** Limited to one project.

1. Open the GitLab project, then **Settings > Access tokens**.
2. Name it (for example `github-mirror`), pick an expiry date, and choose the role **Maintainer** (see the note on protected branches below).
3. Tick the scope **write_repository**.
4. Click **Create project access token** and copy the value. GitLab shows it only once.

**Personal access token.** Acts as you, across all your projects.

1. Open **User settings > Access tokens** (your avatar menu, then **Edit profile**, then **Access tokens**).
2. Tick the scope **write_repository** and create the token.

**Group access token.** Works for every project in a group. Create it under the group's **Settings > Access tokens**.

Notes:

- Only `write_repository` is needed. Do not grant `api` unless you have another reason.
- GitLab requires tokens to expire. Put the expiry date in your calendar, because the mirror stops working on that day.
- By default the default branch on GitLab is protected and only Maintainers may push to it. If your token has the Developer role the push to `main` will be refused. Either use the Maintainer role or change the rules under **Settings > Repository > Protected branches**.
- `force: true` needs "Allowed to force push" enabled on protected branches.

## Add the GitHub secret

1. Open your GitHub repository, then **Settings > Secrets and variables > Actions**.
2. Click **New repository secret**.
3. Name: `GITLAB_TOKEN`. Value: the token from GitLab. Save.

Reference it in the workflow as `${{ secrets.GITLAB_TOKEN }}`. Never paste the token into the YAML file.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `gitlab-token` | yes | | GitLab personal, project, or group access token with `write_repository`. |
| `gitlab-repo` | yes | | Project path such as `group/project` or `group/subgroup/project`. A trailing `.git` is accepted. |
| `gitlab-url` | no | `https://gitlab.com` | Base URL of the GitLab server. Use your own URL for self-hosted GitLab. |
| `gitlab-username` | no | `oauth2` | Username sent with the token. `oauth2` works for personal, project, and group tokens. |
| `branches` | no | `all` | `all`, or a comma separated list of names or glob patterns, such as `main,release/*`. |
| `sync-tags` | no | `true` | Push tags. |
| `force` | no | `false` | Overwrite refs on GitLab that diverged from GitHub. See [force](#force-and-force-with-lease). |
| `prune` | no | `false` | **Destructive.** Delete branches and tags on GitLab that no longer exist on GitHub. See [prune](#prune). |
| `dry-run` | no | `false` | Print what would change and push nothing. |
| `lfs` | no | `false` | Copy Git LFS objects too. See [LFS](#git-lfs). |

Boolean inputs accept `true` or `false`.

## Outputs

| Output | Description |
| --- | --- |
| `status` | `success` (something was pushed or deleted, or a dry run found changes), `no-changes`, or `failed`. |
| `pushed-refs` | Refs pushed to GitLab, one per line, such as `refs/heads/main`. Empty on a dry run. |
| `pruned-refs` | Refs deleted from GitLab by prune, one per line. Empty on a dry run. |

Use them in later steps:

```yaml
- id: mirror
  uses: FahimFBA/github-to-gitlab-sync@v1
  with:
    gitlab-token: ${{ secrets.GITLAB_TOKEN }}
    gitlab-repo: my-group/my-project

- run: echo "Mirror finished with status ${{ steps.mirror.outputs.status }}"
```

## How it works

1. Validates the inputs and refuses to continue on a mistake (clear messages).
2. Makes sure the checkout has full history (unshallows if it can).
3. Reads the branches and tags from the checkout and the current refs on GitLab.
4. Builds a plan: new refs, updated refs, refs to delete, refs already in sync.
5. Pushes only what changed, in batches. Refs already in sync are skipped, so a run with no changes makes no push.

If GitLab refuses a batch through a hook (the usual sign of a protected branch), the action retries one ref at a time, so one blocked branch does not stop the others.

### Branch filter

`branches` takes `all` or a comma separated list. Each entry is a branch name or a glob:

- `main` matches exactly `main`
- `release/*` matches `release/1.0` and also `release/1.0/hotfix` (`*` matches `/` too)
- `main, dev` spaces around entries are ignored

Tags are controlled only by `sync-tags`, not by the branch filter.

### Force and force-with-lease

By default a diverged branch (GitLab has commits GitHub does not) is **rejected** and the job fails with an explanation. That protects work done on GitLab.

With `force: true` the action overwrites GitLab:

- **Branches** use `--force-with-lease`. The action reads the branch tip on GitLab, then pushes with the condition "only overwrite if the tip is still what I saw". If someone pushes to GitLab in between, the push is refused instead of silently erasing their commit.
- **Tags** use `--force`. A tag that points at a different commit on GitLab is moved to match GitHub.

`--force` overwrites without any check. `--force-with-lease` is the same overwrite with a safety condition. Both discard the extra GitLab commits, so use `force: true` only for a pure mirror that nobody else pushes to.

### Prune

`prune: true` deletes refs on GitLab that no longer exist on GitHub. **It cannot be undone** (apart from GitLab's own reflog or backups). Rules:

- Branches are deleted only if they also match the `branches` filter. With `branches: main` and `prune: true`, other GitLab branches are left alone.
- Tags are deleted only when `sync-tags` is `true`.
- The default branch on GitLab is never deleted.
- If no source branches are found at all, prune is skipped, so a broken checkout cannot wipe the mirror.

Run once with `dry-run: true` before you turn prune on.

### Dry run

`dry-run: true` talks to GitLab (it needs to read the current refs and ask GitLab to check the push) but changes nothing. The log shows the plan, for example:

```
  new     refs/heads/feature/login (3fa91c2)
  update  refs/heads/main (a1b2c3d -> 9e8f7a6)
  delete  refs/heads/old-experiment (55aa11b)
  unchanged: 12 ref(s)
```

`status` is `success` when changes exist and `no-changes` when GitLab is up to date. The `pushed-refs` and `pruned-refs` outputs stay empty.

### Git LFS

| `lfs` | Behavior |
| --- | --- |
| `false` (default) | Plain `git push`. LFS pointer files are pushed but the large files are not, so they are broken on GitLab. The action prints a warning if it sees LFS attributes in the repo. |
| `true` | Runs `git lfs fetch --all` from GitHub, then `git lfs push --all` to GitLab before the normal push. Needs `git-lfs` on the runner (it is preinstalled on GitHub-hosted runners). |

For `lfs: true`, keep `actions/checkout` at its default `persist-credentials: true`, so the runner can fetch LFS objects from GitHub. The repo must have LFS enabled on the GitLab project (it is on by default).

## Security notes

- **The token is masked.** The action calls `::add-mask::` for the token and for the encoded auth header, and also filters git output through a redaction step.
- **No token in the remote URL.** The push goes to a plain `https://host/group/project.git` URL. Credentials travel in an `http.extraheader` supplied through `GIT_CONFIG_*` environment variables, scoped to your GitLab URL only. It is never sent to GitHub.
- **Nothing is written to disk.** The credential is not stored in `.git/config`, the credential helper is disabled for GitLab, and the tests check that the token appears nowhere in the checkout. Environment variables are used rather than command line arguments, because arguments are visible in process lists.
- **Use least privilege.** A project access token with `write_repository` and an expiry date limits the damage if it leaks.
- **Set `permissions: contents: read`** in the workflow. The action does not need to write to GitHub.
- **Pin the version.** `@v1` follows compatible updates. For stricter supply chain control pin a full commit SHA.
- **Trust your `gitlab-url`.** The token is sent to whatever URL you configure. Do not build that URL from untrusted input.
- **Fork pull requests do not get secrets.** Run the mirror on `push`, `schedule`, or `workflow_dispatch`, not on `pull_request` from forks.
- **Do not enable debug tracing** (`GIT_TRACE`, `GIT_CURL_VERBOSE`) in your workflow. The action unsets them for its own git commands, but `ACTIONS_STEP_DEBUG` output is outside its control.

To report a vulnerability see [SECURITY.md](SECURITY.md).

## Loop safety

Version 1 pushes in one direction, so there is no loop. If you later add a reverse sync (GitLab to GitHub), or if you let people push to both sides, watch for these:

- **Ping-pong.** A push to GitHub triggers a push to GitLab, which triggers a push back to GitHub, and so on. Break it by skipping runs caused by the sync itself: check the actor, use a marker in the commit message, or filter by a dedicated bot account.
- **Divergence.** Two writers produce two histories. Pick one side as the source of truth, and avoid `force: true` on the side that people push to.
- **Concurrency.** Use a `concurrency` group so two mirror runs never overlap. The examples do this.
- **Branch protection.** Protect the mirror target (GitLab) against human pushes if it is meant to be read-only.

## Troubleshooting

| Symptom | Likely cause and fix |
| --- | --- |
| `GitLab rejected the credentials` | Token expired, revoked, or missing `write_repository`. Create a new one and update the secret. GitLab also reports this when the project path is wrong or the token cannot see the project. |
| `GitLab repository not found` | Wrong `gitlab-repo` or `gitlab-url`, or the project does not exist yet. Create the empty project first. |
| `Rejected: refs/heads/main ... pre-receive hook declined` | Protected branch. Use the Maintainer role for the token, or allow your role to push in **Settings > Repository > Protected branches**. |
| `Rejected: ... non-fast-forward` or `fetch first` | GitLab has commits that GitHub does not. Set `force: true` or stop pushing to GitLab directly. |
| `Rejected: ... already exists` (tags) | A tag on GitLab points elsewhere. Set `force: true` or delete the tag on GitLab. |
| `This is a shallow clone` | Add `fetch-depth: 0` to `actions/checkout`. |
| `Could not reach https://...` | URL typo, a firewall, or GitLab not reachable from GitHub-hosted runners. Use a self-hosted runner inside your network. |
| TLS or certificate error | Self-signed or private CA certificate on GitLab. Install the CA on the runner. |
| Large files are broken on GitLab | Repo uses Git LFS. Set `lfs: true`. |
| Push is slow or times out on a huge first sync | Push once from your own machine, or use `branches` to start with a subset, then let the action keep it in sync. |
| `No source branches or tags matched` | Check the `branches` filter spelling and that checkout used `fetch-depth: 0`. |

If a push is refused by a GitLab push rule (for example commit author email checks), loosen the rule on the mirror project, because the action cannot rewrite history.

## Limitations

- One direction only: GitHub to GitLab.
- The GitLab project must already exist. The action does not create it.
- Syncs Git data (branches, tags, commits). It does not copy issues, pull requests, wikis, releases, or settings.
- Pull request refs (`refs/pull/*`) are not mirrored.
- Submodules are not followed. Each submodule repo needs its own mirror.
- Authentication is by HTTPS token only. SSH keys are not supported yet.
- Runs on Linux, macOS, and Windows runners that provide bash and git 2.31 or newer.

## Roadmap

- GitLab to GitHub (the reverse direction), with loop protection
- SSH deploy key authentication
- Optionally create the GitLab project if it is missing
- Ref renaming and mapping rules

Ideas and pull requests are welcome, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Development

```bash
bash tests/run-tests.sh        # needs bash and git only
shellcheck scripts/sync.sh tests/run-tests.sh
```

The tests build local bare repositories that stand in for GitHub and GitLab, so they need no network and no token.

## License

[MIT](LICENSE)
