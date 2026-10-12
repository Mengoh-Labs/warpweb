# Security policy

## Report privately

Use [GitHub private vulnerability reporting](https://github.com/mmingo-director-of-ai/warpweb/security/advisories/new). Include the affected commit, prerequisites, impact and a minimal reproduction using synthetic data. Do not post credentials, personal files, transcripts or exploitable details in public issues.

The maintained branch is `main`. There are no supported historical release lines or response-time guarantees yet. This experimental software has not received an independent security audit.

## Contribution and automation boundaries

Public read access does not grant repository write access. External changes arrive through forks and pull requests. Main-branch protection, CODEOWNERS and required checks are configured on GitHub; those settings are separate from files in this repository. Fork workflows require maintainer approval. Workflows use read-only tokens, pinned actions and GitHub-hosted runners. No automatic merge or deployment is configured.

Review dependency updates and GitHub workflow changes as code. Never add repository secrets to workflows that execute untrusted pull-request code. Signing credentials and local app data must stay outside this repository.

## Application boundaries

Web content and trusted chrome use separate WebKit views. Page context events run in an isolated content world and require a recent native right-click on the active tab. The optional HTTP viewer is loopback-only, with exact Host/Origin checks and a random session path. Keep the URL private: possession controls the session. There is no supported public network deployment.

Diagnostics are opt-in and retain full URLs and titles. Session/diagnostic files are written atomically with mode 0600 before publication. Files and directories you intentionally share can still reveal their contents. Capture uses an owned window, never a desktop display filter. A local program running as your user is outside this protection boundary. Keep macOS and WebKit updated.

Administrators can bypass the review requirement only when merging a pull request, so a sole maintainer can submit their own fixes. Required CI checks and the main-branch force-push/deletion protections have no bypass actors. Administrators retain the ability to change repository settings.
