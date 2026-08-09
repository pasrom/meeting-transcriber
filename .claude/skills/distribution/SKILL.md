---
name: distribution
description: How the app ships — self-contained .app via Homebrew Cask (stable vs @beta), the v* tag release workflow (release.yml), and the stable-tag ruleset gate. Read before cutting a release, pushing a v* tag, editing Casks/*.rb or release.yml, or configuring the tag ruleset.
---

# Distribution

The app can be distributed as a self-contained `.app` via Homebrew Cask:

```bash
# Build DMG locally
./scripts/build_release.sh

# Install stable via Homebrew
brew tap pasrom/meeting-transcriber
brew install --cask meeting-transcriber

# Install pre-release (RC) via Homebrew
brew install --cask meeting-transcriber@beta
```

> Note: The stable and beta casks conflict — uninstall one before installing the other.

**Release workflow:** Push a `v*` tag to trigger `.github/workflows/release.yml` which
builds the DMG on a macOS runner and creates a GitHub Release. Pre-release tags
(containing `-`) update `meeting-transcriber@beta`. Stable tags update
`meeting-transcriber` and *also* carry `@beta` forward when the stable version is newer
than what that cask holds.

That second half exists because the beta channel would otherwise freeze at the last RC:
a cycle that ships without one leaves beta users on older software than stable users,
with `brew upgrade` reporting them up to date and the beta cask's `conflicts_with`
standing in the way of the obvious escape. The guard is a SemVer comparison, not `sort -V` — mid-cycle the beta channel
legitimately runs ahead (0.8.0-rc1 must survive a 0.7.1 hotfix), and `sort -V` alone
orders `0.8.0-rc1` *after* `0.8.0`, which would strand users at exactly the RC-to-stable
step the rule is for.

**Stable tag gate:** A GitHub Tag Ruleset (`Stable tag protection`) rejects any
`git push` of a tag matching `v*` *without* a `-` suffix unless the tagged SHA
has green status checks for every context listed in
`.github/tag-ruleset.json` (`required_status_checks`). Apply or update the
ruleset via `./scripts/configure-tag-ruleset.sh` (idempotent, needs repo-admin
`gh` auth). RC tags (`v*-rc*`) stay unrestricted. `e2e.yml` and `e2e-app.yml`
both fire on every main push (no paths-filter) so every SHA a stable tag might
point at already has the required check-runs — no manual `gh workflow run`
ceremony before tagging.
