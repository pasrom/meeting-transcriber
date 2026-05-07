# Security Policy

## Supported Versions

Only the latest stable release on the `main` branch receives security patches. Pre-release builds from the `meeting-transcriber@beta` cask are best-effort.

| Channel | Branch | Cask | Security fixes |
|---------|--------|------|----------------|
| Stable  | `main`, latest tag | `pasrom/meeting-transcriber/meeting-transcriber` | Yes |
| Beta (RC) | `main`, RC tags | `pasrom/meeting-transcriber/meeting-transcriber@beta` | Best-effort |
| App Store | TBD | TBD | Yes (when published) |

## Reporting a Vulnerability

**Please do not file public issues for security problems.** Use one of the private channels below:

- **Preferred:** GitHub's private vulnerability reporting — open a draft advisory at <https://github.com/pasrom/meeting-transcriber/security/advisories/new>. This is encrypted, only visible to maintainers, and lets us coordinate a fix and release before disclosure.
- **Email:** if GitHub is not available to you, contact the maintainer directly via the email associated with the GitHub account.

When reporting, please include:

1. The affected version (`Settings → Advanced → About` shows version + commit hash).
2. A minimal reproduction or proof-of-concept.
3. The impact you observed and any mitigating factors.

## Disclosure Timeline

- **Within 5 business days**: acknowledgement and triage.
- **Within 30 days**: a fix or a clear timeline for one, depending on severity.
- **At release**: credit in the release notes (you can opt out).

## Scope

- The macOS menu-bar app and its bundled libraries (AudioTapLib, mt-cli, whisperkit-cli) are in scope.
- The Debug RPC server (`#if !APPSTORE`, off by default) is in scope when enabled.
- Vulnerabilities in upstream dependencies (WhisperKit, FluidAudio, swift-snapshot-testing, ViewInspector) should be reported to those projects directly; we will track and bump as fixes land.

## Out of Scope

- Issues that require the attacker to already have full filesystem access on the same Mac (the app is designed for personal use, not multi-tenant).
- Theoretical issues without a working reproduction.
