# DMG Distribution Plan

## Goal

Distribute MeetingTranscriber as a notarized DMG with embedded Python — no Homebrew/venv required for end users.

## Architecture

```
MeetingTranscriber.app/
  Contents/
    MacOS/MeetingTranscriber          ← Swift menu bar app
    Resources/
      python-env/                     ← Embedded Python + site-packages
        bin/python3
        lib/python3.14/site-packages/
          meeting_transcriber/        ← Our package
          pywhispercpp/
          pyannote/
          torch/
          ...
      scripts/
        transcribe                    ← Entry point (shebang → embedded python)
```

## Steps

### 1. Embedded Python via py2app

- Use `py2app` or `python-build-standalone` to create a relocatable Python
- Bundle into `.app/Contents/Resources/python-env/`
- Includes: meeting_transcriber, pywhispercpp, pyannote-audio, torch, numpy, scipy, rich
- Estimated size: ~500MB (PyTorch dominates)

### 2. Whisper Models: On-Demand Download

- Don't bundle models (large-v3-turbo alone is ~1.5GB)
- On first use: download to `~/Library/Application Support/MeetingTranscriber/models/`
- Show progress in menu bar UI
- Ship with `base` model for fast first experience (~150MB)

### 3. PythonProcess.swift: Path Change

```swift
// Current:
let venvBin = (projectRoot as NSString).appendingPathComponent(".venv/bin")

// New:
let resourcePath = Bundle.main.resourcePath!
let pythonEnv = (resourcePath as NSString).appendingPathComponent("python-env/bin")
```

### 4. DMG Packaging

- Use `create-dmg` or `hdiutil` to build DMG
- Drag-to-Applications layout (app icon + Applications symlink)
- Background image with install instructions

### 5. Code Signing & Notarization

```bash
# Sign
codesign --deep --force --verify --verbose \
  --sign "Developer ID Application: ..." \
  MeetingTranscriber.app

# Notarize
xcrun notarytool submit MeetingTranscriber.dmg \
  --apple-id "..." --team-id "..." --password "..."

# Staple
xcrun stapler staple MeetingTranscriber.dmg
```

Requires Apple Developer Program membership ($99/year).

### 6. HuggingFace Token Handling

- pyannote models require HF token + license acceptance
- Options:
  a) First-launch setup wizard in Swift UI (user enters token)
  b) Store in macOS Keychain
  c) Ship pre-converted CoreML models (eliminates HF dependency, but significant work)

### 7. Claude CLI Dependency

- Currently shells out to `claude` CLI
- For DMG distribution: either bundle Claude CLI or switch to Claude API (HTTP)
- API approach is cleaner: `import anthropic` → direct API call
- Requires user to provide API key (settings UI)

## Size Optimization

| Component | Size | Optimization |
|-----------|------|-------------|
| PyTorch | ~200MB | Use torch CPU-only (no CUDA) |
| pyannote | ~50MB | As-is |
| pywhispercpp | ~10MB | As-is (whisper.cpp compiled) |
| Whisper models | 0 (on-demand) | Downloaded to Application Support |
| Python stdlib | ~50MB | Strip unused modules |
| numpy/scipy | ~60MB | As-is |
| **Total** | **~370MB** | |

## Prerequisites

- Apple Developer Program membership
- Stable, tested pipeline (current priority)
- Decision on Claude CLI vs API

## Open Questions

- Minimum macOS version? (ScreenCaptureKit requires 13.0+)
- Auto-update mechanism? (Sparkle framework?)
- Licensing model? (free / one-time / subscription)
