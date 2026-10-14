# Security Policy

## Supported versions

Security fixes are released for the latest `v1.x` version. Use the floating `v1` tag to receive them automatically.

## Reporting a vulnerability

Please do not open a public issue for a security problem.

Use one of these private channels:

1. GitHub private vulnerability reporting: open the **Security** tab of this repository and choose **Report a vulnerability**.
2. Email **fahimbinamin@gmail.com** with the subject `github-to-gitlab-sync security`.

Please include:

- What the problem is and how to reproduce it
- The version or commit you tested
- Any suggested fix

You can expect an acknowledgement within 5 days. We will keep you updated, agree on a disclosure date, and credit you in the release notes if you wish.

## What counts

Examples of in-scope problems: the token appearing in logs, errors, outputs, or on disk; command or argument injection through an input; sending credentials to a host other than the configured GitLab URL.

## If a token may have leaked

Revoke it in GitLab right away (**Access tokens**, then **Revoke**), create a new one, and update the GitHub secret. Then review the project's activity for unexpected pushes.
