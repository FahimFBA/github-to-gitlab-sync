# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-10-14

First release.

### Added

- Mirror a GitHub repository to GitLab (gitlab.com or self-hosted), one direction: GitHub to GitLab.
- Inputs: `gitlab-token`, `gitlab-repo`, `gitlab-url`, `gitlab-username`, `branches`, `sync-tags`, `force`, `prune`, `dry-run`, `lfs`.
- Outputs: `status` (`success`, `no-changes`, `failed`), `pushed-refs`, `pruned-refs`.
- Branch filter with names and glob patterns.
- Tag sync, including annotated tags.
- Opt-in prune of branches and tags that no longer exist on GitHub. It respects the branch filter and never deletes the GitLab default branch.
- Dry run that prints the plan and pushes nothing.
- `force` mode using `--force-with-lease` for branches and `--force` for tags.
- Optional Git LFS object transfer.
- Token handling: masked in logs, sent through a scoped `http.extraheader` in environment variables, never written to `.git/config` or the remote URL.
- Early input validation with clear messages.
- Shallow clone detection with automatic unshallow.
- Clear explanations for protected branches, diverged history, existing tags, authentication, and network errors. One protected branch does not block the other refs.
- Test suite using local bare repositories, and shellcheck-clean scripts.
