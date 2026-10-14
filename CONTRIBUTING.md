# Contributing

Thanks for helping. This is a small project, so the process is light.

## Ground rules

- Be kind. See the [Code of Conduct](CODE_OF_CONDUCT.md).
- Open an issue before a large change, so we can agree on the approach.
- Keep the action a composite action written in bash. If you think Docker or Node is needed, explain why in an issue first.
- Do not add files to `.github/workflows/` in this repository. GitHub Marketplace action repositories should contain only the action's metadata, code, and necessary files. Sample workflows live in `examples/`.

## Setup

You need bash, git 2.31 or newer, and [shellcheck](https://www.shellcheck.net/).

```bash
git clone https://github.com/FahimFBA/github-to-gitlab-sync.git
cd github-to-gitlab-sync
bash tests/run-tests.sh
shellcheck scripts/sync.sh tests/run-tests.sh
```

On Windows use Git Bash. The repository uses LF line endings (see `.gitattributes`).

## How the tests work

`tests/run-tests.sh` creates temporary local repositories: a bare repo as "GitHub", a clone of it as the Actions checkout, and a bare repo as "GitLab". It runs `scripts/sync.sh` against them and checks the refs on the fake GitLab side. No network or token is needed.

Plain bash was chosen over bats because it has no dependency, runs unchanged in Git Bash on Windows, and keeps the barrier to contributing low.

Run a subset with a name filter:

```bash
bash tests/run-tests.sh prune
```

`scripts/sync.sh` has three testing hooks, all optional environment variables: `G2G_REMOTE_URL` (use a local path instead of the GitLab URL), `G2G_SOURCE_REMOTE`, and `G2G_FORCE_AUTH_HEADER`. They are not part of the public interface and may change.

## Making a change

1. Fork the repository and create a branch.
2. Add or update a test in `tests/run-tests.sh`. A bug fix needs a test that fails before the fix.
3. Run the tests and shellcheck. Both must pass.
4. Update `README.md`, the `action.yml` descriptions, and `CHANGELOG.md` when behavior or inputs change.
5. Open a pull request and describe what changed and why.

## Code style

- Use `set -euo pipefail`, quote every variable, and keep shellcheck clean (use a `# shellcheck disable=` comment with a reason when truly needed).
- Never print or log the token. Anything that may contain it goes through `redact`.
- Pass inputs to the script as environment variables. Never expand `${{ }}` inside a `run:` script body.
- Write plain, friendly text. Avoid long dashes (em and en dashes) in code comments and docs. Use commas, periods, colons, or parentheses.

## Releases

Maintainers tag releases as `vX.Y.Z` and move the floating `v1` tag to the newest `v1.x.y`.
