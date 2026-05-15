# Security Policy

zwgsl is a compiler and tooling project. Security-relevant reports can include
compiler crashes on untrusted shader input, memory safety issues in the native
library or C API, malformed LSP message handling, and playground behavior that
could expose users to unsafe content.

## Supported Versions

There are no tagged releases yet. Until the first release is cut, security fixes
target the `main` branch.

## Reporting A Vulnerability

Please do not open a public issue with exploit details.

Use GitHub's private vulnerability reporting for this repository if it is
available. If private reporting is not available, open a public issue that asks
for a security contact without including sensitive details, reproduction steps,
or proof-of-concept input.

Include these details in the private report when possible:

- affected component: compiler, CLI, LSP, C API, playground, or VS Code extension
- version, commit, or branch tested
- platform and tool versions
- minimal input or message sequence needed to reproduce the issue
- expected impact and whether the issue is already public

## Handling

Maintainers should acknowledge private reports when they can, reproduce the
issue, prepare a focused fix, and coordinate disclosure timing with the reporter.
When a fix is user-visible, add an entry to `CHANGELOG.md`.
