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
builds the DMG on a macOS runner and creates a GitHub Release. Stable tags update the
`meeting-transcriber` cask, pre-release tags (containing `-`) update `meeting-transcriber@beta`.

**Stable tag gate:** A GitHub Tag Ruleset (`Stable tag protection`) rejects any
`git push` of a tag matching `v*` *without* a `-` suffix unless the tagged SHA
has green status checks for every context listed in
`.github/tag-ruleset.json` (`required_status_checks`). Apply or update the
ruleset via `./scripts/configure-tag-ruleset.sh` (idempotent, needs repo-admin
`gh` auth). RC tags (`v*-rc*`) stay unrestricted. `e2e.yml` and `e2e-app.yml`
both fire on every main push (no paths-filter) so every SHA a stable tag might
point at already has the required check-runs — no manual `gh workflow run`
ceremony before tagging.
