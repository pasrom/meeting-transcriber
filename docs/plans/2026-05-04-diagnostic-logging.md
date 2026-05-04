# Diagnostic Logging Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build an end-to-end "users attach a log file to GitHub issues" workflow — toggle in Settings turns on verbose diagnostics across all pipelines (audio, transcription, diarization, protocol), an "Export Diagnostics" button writes a redacted, pseudonymized log file the user can attach, and an issue template guides users to that file.

**Architecture:** The existing `audioDebugLogging` flag is generalized to `verboseDiagnostics` and gates new logs across *all* pipelines, not just audiotap. PII (speaker names, transcripts) never appears in clear text — names are SHA-256-pseudonymized via a new `LogRedaction.swift` helper, and `os_log` `%{private}@` formatting is used as defense-in-depth. The export reads `OSLogStore.local()` for the last 30 min and writes to a tempfile, then reveals it in Finder.

**Tech Stack:** Swift 6, `os.Logger` / `OSLogStore` (Apple-native unified logging), `CryptoKit.SHA256` (Apple-native, no external dep), SwiftUI for the export button, GitHub Issue Forms YAML for the template.

---

## Conventions for this plan

- **One task = one atomic commit.** Each task ends with a `git commit` step.
- **TDD where the unit can be tested in isolation** (redaction helpers, RMS calculations, status-code translation). Pure Swift logic gets a failing test first.
- **Manual verification where it cannot** (UI buttons, OSLogStore reads, log-emission side effects). Each such task notes how to verify by hand.
- **All commits use Conventional Commits** (`feat`, `fix`, `chore`, `test`, etc.) with scope `app`, `audiotap`, `ci`, or `docs`.
- **Branch:** `feat/diagnostic-logging` from `origin/main`.
- **PR strategy:** all phases in **one PR** at the end (per user request); commits stay atomic so the reviewer can read them top-to-bottom.

Run before starting:

```bash
git fetch origin
git checkout -b feat/diagnostic-logging origin/main
```

---

## Phase 1: Infrastructure

Foundation pieces every later phase depends on: redaction helpers, settings rename + migration, job-ID correlation.

### Task 1.1: Add `LogRedaction.swift` with `pseudonymized` + `redactedName`

**Files:**
- Create: `app/MeetingTranscriber/Sources/LogRedaction.swift`
- Test: `app/MeetingTranscriber/Tests/LogRedactionTests.swift`

**Step 1: Write the failing test**

Create `app/MeetingTranscriber/Tests/LogRedactionTests.swift`:

```swift
import XCTest
@testable import MeetingTranscriber

final class LogRedactionTests: XCTestCase {
    // pseudonymized — stable, hex, 4 chars
    func test_pseudonymized_isStable() {
        XCTAssertEqual("Roman".pseudonymized, "Roman".pseudonymized)
    }

    func test_pseudonymized_differsAcrossNames() {
        XCTAssertNotEqual("Roman".pseudonymized, "Anna".pseudonymized)
    }

    func test_pseudonymized_format() {
        let p = "Roman".pseudonymized
        XCTAssertTrue(p.hasPrefix("speaker_"))
        XCTAssertEqual(p.count, "speaker_".count + 4)  // 4 hex chars
        XCTAssertTrue(p.dropFirst("speaker_".count).allSatisfy { "0123456789abcdef".contains($0) })
    }

    func test_pseudonymized_emptyString_returnsAnonymous() {
        XCTAssertEqual("".pseudonymized, "speaker_anon")
    }

    // redactedName — keeps first + last (when long enough)
    func test_redactedName_long() {
        XCTAssertEqual("Roman".redactedName, "R***n")
    }

    func test_redactedName_short3() {
        // 3 chars: keep first only, mask rest
        XCTAssertEqual("Tom".redactedName, "T**")
    }

    func test_redactedName_two() {
        XCTAssertEqual("Li".redactedName, "L*")
    }

    func test_redactedName_one() {
        XCTAssertEqual("X".redactedName, "*")
    }

    func test_redactedName_empty() {
        XCTAssertEqual("".redactedName, "")
    }

    func test_redactedName_unicode() {
        // Use Character count, not byte count
        XCTAssertEqual("Ümlaut".redactedName, "Ü****t")
    }
}
```

**Step 2: Run test to verify it fails**

```bash
cd app/MeetingTranscriber && swift test --filter LogRedactionTests
```

Expected: compile error "no member 'pseudonymized'" / "no member 'redactedName'".

**Step 3: Create the implementation**

Create `app/MeetingTranscriber/Sources/LogRedaction.swift`:

```swift
import CryptoKit
import Foundation

extension String {
    /// Deterministic 4-hex-char pseudonym derived from SHA-256.
    /// Stable across runs (same input → same output) so logs can be correlated
    /// without exposing the clear name. Used for speaker IDs in diagnostic logs.
    var pseudonymized: String {
        guard !isEmpty else { return "speaker_anon" }
        let hash = SHA256.hash(data: Data(utf8))
        let prefix = hash.prefix(2).map { String(format: "%02x", $0) }.joined()
        return "speaker_\(prefix)"
    }

    /// First-and-last-char redaction: "Roman" → "R***n", "Tom" → "T**", "Li" → "L*".
    /// Less privacy-preserving than `pseudonymized` (length leaks); use for UI-adjacent
    /// logs where the user actively benefits from recognising "their" name. For
    /// machine-readable forensic logs, prefer `pseudonymized`.
    var redactedName: String {
        let chars = Array(self)
        switch chars.count {
        case 0: return ""
        case 1: return "*"
        case 2: return "\(chars[0])*"
        case 3: return "\(chars[0])**"
        default:
            let middle = String(repeating: "*", count: chars.count - 2)
            return "\(chars[0])\(middle)\(chars.last!)"
        }
    }
}
```

**Step 4: Run test to verify it passes**

```bash
cd app/MeetingTranscriber && swift test --filter LogRedactionTests
```

Expected: 8 tests pass.

**Step 5: Commit**

```bash
git add app/MeetingTranscriber/Sources/LogRedaction.swift app/MeetingTranscriber/Tests/LogRedactionTests.swift
git commit -m "feat(app): add LogRedaction with pseudonymized + redactedName helpers"
```

---

### Task 1.2: Rename `audioDebugLogging` → `verboseDiagnostics` with UserDefaults migration

Generalises the existing flag — same UserDefaults key reused so users keep their setting; new name reflects new scope.

**Files:**
- Modify: `app/MeetingTranscriber/Sources/AppSettings.swift:288-290, 363`
- Modify: `app/MeetingTranscriber/Sources/AppState.swift:250, 308`
- Modify: `app/MeetingTranscriber/Sources/WatchLoop.swift:54, 81, 94, 157, 265`
- Modify: `app/MeetingTranscriber/Sources/Settings/AdvancedSettingsView.swift:59-65`
- Modify: `app/MeetingTranscriber/Tests/AppSettingsTests.swift` (any tests touching `audioDebugLogging`)

**Step 1: Update test for new name + migration**

In `app/MeetingTranscriber/Tests/AppSettingsTests.swift`, find any test using `audioDebugLogging` and rename. Add a new test for migration:

```swift
func test_verboseDiagnostics_migratesFromAudioDebugLoggingKey() {
    let suite = "AppSettingsTests-migration-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    // Simulate old install with the legacy key set
    defaults.set(true, forKey: "audioDebugLogging")

    let settings = AppSettings(defaults: defaults)

    XCTAssertTrue(settings.verboseDiagnostics, "Should read the legacy key on first launch")

    // Cleanup
    UserDefaults().removePersistentDomain(forName: suite)
}

func test_verboseDiagnostics_persistsUnderNewKey() {
    let suite = "AppSettingsTests-persist-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!

    let settings = AppSettings(defaults: defaults)
    settings.verboseDiagnostics = true

    XCTAssertEqual(defaults.bool(forKey: "verboseDiagnostics"), true)

    UserDefaults().removePersistentDomain(forName: suite)
}
```

**Step 2: Run tests to verify they fail**

```bash
cd app/MeetingTranscriber && swift test --filter AppSettingsTests
```

Expected: failures on `verboseDiagnostics` (member not found) and migration test.

**Step 3: Rename + add migration in `AppSettings.swift`**

Replace lines 281-290:

```swift
    // MARK: - Diagnostics

    /// Enables verbose diagnostic logging across **all** pipelines: audio
    /// capture (process/device identity, periodic RMS), transcription
    /// (segment counts, input RMS, sample-rate validation), VAD
    /// (segment boundaries, round-trip checks), diarization, speaker
    /// matching (top-2 candidates + margins), and protocol generation.
    /// Off by default. Logs go to `com.meetingtranscriber` and
    /// `com.meetingtranscriber.audiotap`. Use the "Export Diagnostics"
    /// button in Settings → Advanced to attach a log to a bug report.
    var verboseDiagnostics: Bool {
        didSet { defaults.set(verboseDiagnostics, forKey: "verboseDiagnostics") }
    }
```

Replace line 363 with:

```swift
        // Migrate legacy "audioDebugLogging" key (renamed to "verboseDiagnostics" 2026-05-04).
        // Read either key; new key takes precedence if both are set.
        if let new = defaults.object(forKey: "verboseDiagnostics") as? Bool {
            verboseDiagnostics = new
        } else if let legacy = defaults.object(forKey: "audioDebugLogging") as? Bool {
            verboseDiagnostics = legacy
            defaults.set(legacy, forKey: "verboseDiagnostics")
        } else {
            verboseDiagnostics = false
        }
```

**Step 4: Update all call sites**

Replace `audioDebugLogging` → `verboseDiagnostics` everywhere it occurs:

```bash
# Verify the changes
grep -rn "audioDebugLogging" app/MeetingTranscriber/Sources/ tools/audiotap/Sources/
```

Expected after edit: no matches in `Sources/` (legacy key only appears in the migration block in `AppSettings.swift`).

Files to edit (use `Edit` tool, one occurrence at a time):
- `app/MeetingTranscriber/Sources/AppState.swift:250` — `audioDebugLogging:` parameter label and value
- `app/MeetingTranscriber/Sources/AppState.swift:308` — same
- `app/MeetingTranscriber/Sources/WatchLoop.swift:54` — property
- `app/MeetingTranscriber/Sources/WatchLoop.swift:81, 94` — init param + assignment
- `app/MeetingTranscriber/Sources/WatchLoop.swift:157, 265` — call sites still pass `debugLogging:` to AudioCaptureSession (unchanged param name there) — *only rename the source, not the audiotap-side parameter*

In `app/MeetingTranscriber/Sources/Settings/AdvancedSettingsView.swift:59-65`:

```swift
                Toggle("Verbose Diagnostic Logging", isOn: $settings.verboseDiagnostics)
                Text(
                    "Logs detailed diagnostics across recording, transcription,"
                        + " diarization, and protocol generation. Used to debug"
                        + " issues. Off by default — toggle on, reproduce the"
                        + " problem, then click \"Export Diagnostics\" below to"
                        + " attach a redacted log file to a bug report.",
                )
                .font(.caption)
                .foregroundStyle(.secondary)
```

**Step 5: Build + run tests**

```bash
cd app/MeetingTranscriber && swift build && swift test --filter AppSettingsTests
```

Expected: build succeeds, AppSettingsTests pass (including the two new migration tests).

**Step 6: Commit**

```bash
git add app/MeetingTranscriber/Sources/ app/MeetingTranscriber/Tests/AppSettingsTests.swift
git commit -m "refactor(app): rename audioDebugLogging → verboseDiagnostics with UserDefaults migration"
```

---

### Task 1.3: Add `PipelineJob.id` for cross-stage log correlation

The pipeline runs transcription → diarization → protocol generation per job. Today the logs in each stage have no shared identifier. Add a UUID per job, log it at every stage entry/exit.

**Files:**
- Modify: `app/MeetingTranscriber/Sources/PipelineJob.swift`
- Modify: `app/MeetingTranscriber/Sources/PipelineQueue.swift` (add `[\(job.shortID)]` prefix to existing log lines at stage boundaries — narrowed to ~5 spots, see Step 3)
- Test: `app/MeetingTranscriber/Tests/PipelineJobTests.swift` (create if absent)

**Step 1: Write the failing test**

Create `app/MeetingTranscriber/Tests/PipelineJobTests.swift` if not present, otherwise extend it:

```swift
import XCTest
@testable import MeetingTranscriber

final class PipelineJobTests: XCTestCase {
    func test_jobHasUniqueID() {
        let a = PipelineJob.makeTestStub()
        let b = PipelineJob.makeTestStub()
        XCTAssertNotEqual(a.id, b.id)
    }

    func test_shortIDIsEightHexChars() {
        let job = PipelineJob.makeTestStub()
        XCTAssertEqual(job.shortID.count, 8)
        XCTAssertTrue(job.shortID.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func test_shortIDIsStableForSameJob() {
        let job = PipelineJob.makeTestStub()
        XCTAssertEqual(job.shortID, job.shortID)
    }
}
```

`PipelineJob.makeTestStub()` is a test-only factory — see implementation note in Step 3 (use a `#if DEBUG` extension or read existing test helpers in the file).

**Step 2: Run test to verify it fails**

```bash
cd app/MeetingTranscriber && swift test --filter PipelineJobTests
```

Expected: missing-member error on `id` and `shortID`.

**Step 3: Implement**

In `app/MeetingTranscriber/Sources/PipelineJob.swift`, add:

```swift
struct PipelineJob: ... {  // existing properties unchanged
    let id: UUID = UUID()  // unique per job, used for log correlation

    /// Short 8-hex-char form of `id` for log prefixes — `[a3f29b71]`.
    var shortID: String {
        String(id.uuidString.prefix(8).lowercased())
    }

    // ... existing rest of struct
}

#if DEBUG
extension PipelineJob {
    static func makeTestStub() -> PipelineJob {
        // Construct minimal valid PipelineJob with placeholder values
        // (adapt based on the actual struct's required fields)
        ...
    }
}
#endif
```

If `PipelineJob` is decoded from disk (queue persistence), make `id` decodable but with a default-on-decode-failure (`UUID()`) so old persisted queues still load:

```swift
init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    // ... rest of decode
}
```

**Step 4: Run tests + build**

```bash
cd app/MeetingTranscriber && swift build && swift test --filter PipelineJobTests
```

Expected: tests pass, build clean.

**Step 5: Add `[shortID]` prefix to stage-boundary logs in `PipelineQueue.swift`**

Identify the ~5 stage entry/exit log statements (transcription start, transcription done, diarization start, diarization done, protocol generation start). Prepend `[\(job.shortID)] ` to each. Example:

```swift
logger.info("[\(job.shortID, privacy: .public)] Transcription start")
```

(Use `Logger`'s string-interpolation `privacy:` modifier — Apple-native, makes the ID public so it shows in Console/exports.)

**Step 6: Commit**

```bash
git add app/MeetingTranscriber/Sources/PipelineJob.swift \
        app/MeetingTranscriber/Sources/PipelineQueue.swift \
        app/MeetingTranscriber/Tests/PipelineJobTests.swift
git commit -m "feat(app): add per-PipelineJob UUID + shortID for log correlation"
```

---

## Phase 2: New Diagnostic Logs (HIGH-priority items)

Each task adds one specific diagnostic that closed a known visibility gap. All gated by `verboseDiagnostics` unless the gap exists at *every* run (e.g., catch-block error logs are always on).

### Task 2.1: Translate `AudioHardwareCreateProcessTap` OSStatus to human-readable

**Files:**
- Modify: `tools/audiotap/Sources/AppAudioCapture.swift:241-246`
- Test: `tools/audiotap/Tests/AppAudioCaptureStatusTests.swift` (new)

**Step 1: Write a failing test for the pure status-translation function**

Create `tools/audiotap/Tests/AppAudioCaptureStatusTests.swift`:

```swift
import XCTest
@testable import AudioTapLib

final class AppAudioCaptureStatusTests: XCTestCase {
    func test_describeTapError_knownStatus_returnsHumanHint() {
        // -12988 is the historical "permission denied" / not-permitted code
        let msg = AppAudioCapture.describeTapError(-12988)
        XCTAssertTrue(msg.contains("permission") || msg.contains("Privacy"))
    }

    func test_describeTapError_unknown_includesCode() {
        let msg = AppAudioCapture.describeTapError(-99999)
        XCTAssertTrue(msg.contains("-99999"))
    }
}
```

**Step 2: Run test → fail**

```bash
cd tools/audiotap && swift test --filter AppAudioCaptureStatusTests
```

Expected: `describeTapError` not found.

**Step 3: Add the translator**

In `AppAudioCapture.swift`, add as a static helper:

```swift
/// Maps `AudioHardwareCreateProcessTap` OSStatus codes to a human hint.
/// Exposed `static internal` for unit testing the translation table.
static func describeTapError(_ status: OSStatus) -> String {
    switch status {
    case -12988:
        return "OSStatus -12988: likely missing permission. " +
               "Check System Settings → Privacy & Security → Screen Recording " +
               "and enable Meeting Transcriber."
    case -10851:
        return "OSStatus -10851 (kAudioUnitErr_InvalidProperty): tap target may have exited."
    case -50:
        return "OSStatus -50 (paramErr): invalid CATapDescription parameters."
    default:
        return "OSStatus \(status): unrecognised — see CoreAudio headers."
    }
}
```

In the existing tap-creation error path (around line 245), replace the generic `"Failed to create process tap"` log with:

```swift
logger.error("Failed to create process tap (pid=\(pid, privacy: .public), bundle=\(bundleID ?? "?", privacy: .public)): \(Self.describeTapError(status), privacy: .public)")
```

**Step 4: Run tests → pass**

```bash
cd tools/audiotap && swift test --filter AppAudioCaptureStatusTests
```

**Step 5: Commit**

```bash
git add tools/audiotap/Sources/AppAudioCapture.swift tools/audiotap/Tests/AppAudioCaptureStatusTests.swift
git commit -m "feat(audiotap): translate tap-creation OSStatus to human-readable hint"
```

---

### Task 2.2: Empty-transcription detection + input-RMS log in `PipelineQueue`

When transcription returns 0 segments, today the pipeline silently produces an empty protocol. Log a warning with input audio RMS so the cause is identifiable (silent input vs. ASR misconfiguration).

**Files:**
- Modify: `app/MeetingTranscriber/Sources/PipelineQueue.swift` (after the call site that runs transcription — find the line that calls `engine.transcribeSegments` or equivalent)
- Reuse existing RMS computation from `tools/audiotap/Sources/DebugRMSReporter.swift` if exposed; otherwise use a small inline helper.

**Step 1: Add a public test helper for RMS-from-PCM-buffer**

Skip a separate test for this task — it's an additive log statement integrated into existing flow. Manual verification only.

**Step 2: Add the diagnostic log**

After the transcription call (in `PipelineQueue.swift`, around the spot where `segments` is bound from the engine result), add:

```swift
let totalWords = segments.reduce(0) { $0 + $1.text.split(separator: " ").count }
let totalSecs = segments.last?.endTime ?? 0
let inputRMSdBFS = AudioMixer.rmsDecibels(forFileAt: jobMixURL) ?? Float.nan
logger.info("[\(job.shortID, privacy: .public)] transcription_complete segments=\(segments.count, privacy: .public) words=\(totalWords, privacy: .public) duration=\(totalSecs, privacy: .public)s inputRMSdBFS=\(inputRMSdBFS, privacy: .public)")
if segments.isEmpty {
    logger.warning("[\(job.shortID, privacy: .public)] transcription_empty engine=\(engineName, privacy: .public) inputRMSdBFS=\(inputRMSdBFS, privacy: .public). Consider checking audio quality or VAD threshold.")
}
```

If `AudioMixer.rmsDecibels(forFileAt:)` does not yet exist, add it to `AudioMixer.swift`:

```swift
/// RMS in dBFS for a Float32 PCM file. Returns `nil` if the file cannot be read.
static func rmsDecibels(forFileAt url: URL) -> Float? {
    guard let samples = try? loadAudioAsFloat32(url: url) else { return nil }
    guard !samples.isEmpty else { return -.infinity }
    let sumSq = samples.reduce(Float(0)) { $0 + $1 * $1 }
    let rms = (sumSq / Float(samples.count)).squareRoot()
    return 20 * log10(max(rms, 1e-10))
}
```

…and a test:

```swift
// In AudioMixerTests.swift
func test_rmsDecibels_silentBuffer_returnsLow() {
    // Generate a silent WAV via existing test helpers, assert rms < -90 dBFS
    ...
}
```

**Step 3: Run tests + manual verification**

```bash
cd app/MeetingTranscriber && swift test --filter AudioMixerTests
```

Manual: launch the app with a known-silent WAV, verify the warning fires:

```bash
log stream --predicate 'subsystem == "com.meetingtranscriber" && category == "PipelineQueue"' --style compact
```

**Step 4: Commit**

```bash
git add app/MeetingTranscriber/Sources/PipelineQueue.swift app/MeetingTranscriber/Sources/AudioMixer.swift app/MeetingTranscriber/Tests/AudioMixerTests.swift
git commit -m "feat(app): log transcription summary + warn on empty result with input RMS"
```

---

### Task 2.3: VAD round-trip validation log in `FluidVAD`

**Files:**
- Modify: `app/MeetingTranscriber/Sources/FluidVAD.swift:114-152` (around `extractSpeechSamples`)

**Step 1: Manual verification only — no unit test**

VAD logs are observational; behavior is unchanged. No new test required.

**Step 2: Add diagnostic log**

After speech-region extraction completes, add:

```swift
let originalSecs = Float(originalSampleCount) / Float(sampleRate)
let trimmedSecs = Float(extractedSampleCount) / Float(sampleRate)
let trimRatio = originalSecs > 0 ? (1 - trimmedSecs / originalSecs) : 0
logger.info("vad_extract regions=\(regions.count, privacy: .public) original=\(originalSecs, privacy: .public)s trimmed=\(trimmedSecs, privacy: .public)s trimRatio=\(trimRatio, privacy: .public)")

// Round-trip sanity: pick a midpoint in the trimmed timeline, map back, verify it's
// inside one of the original regions.
if !regions.isEmpty, let map = vadMap {
    let probe: Float = trimmedSecs / 2
    let mapped = map.toOriginalTime(probe)
    let inSomeRegion = regions.contains { mapped >= $0.startSec && mapped <= $0.endSec }
    if !inSomeRegion {
        logger.warning("vad_roundtrip_drift probe=\(probe)s mapped=\(mapped)s — VadSegmentMap may be inconsistent")
    }
}
```

(Adjust types to match existing `VadSegmentMap` API — read the file first.)

**Step 3: Build + run app, verify log appears**

```bash
cd app/MeetingTranscriber && swift build
./scripts/run_app.sh
# Trigger a recording with VAD enabled, check Console.app for vad_extract lines
```

**Step 4: Commit**

```bash
git add app/MeetingTranscriber/Sources/FluidVAD.swift
git commit -m "feat(app): log VAD trim summary + round-trip drift detection"
```

---

### Task 2.4: Mic-delay clamp logging in `AudioMixer`

**Files:**
- Modify: `app/MeetingTranscriber/Sources/AudioMixer.swift` (around `maxMicDelay` clamp, line ~29)

**Step 1: Write a failing test**

In `AudioMixerDelayTests.swift`, add:

```swift
func test_clampMicDelay_withinBound_unchanged() {
    XCTAssertEqual(AudioMixer.clampMicDelay(5.0), 5.0)
}

func test_clampMicDelay_excessivePositive_clampsToMax() {
    XCTAssertEqual(AudioMixer.clampMicDelay(45.0), AudioMixer.maxMicDelay)
}

func test_clampMicDelay_excessiveNegative_clampsToNegMax() {
    XCTAssertEqual(AudioMixer.clampMicDelay(-45.0), -AudioMixer.maxMicDelay)
}
```

**Step 2: Run → fail**

Expected: `clampMicDelay` not exposed (likely currently inline).

**Step 3: Extract + log**

In `AudioMixer.swift`:

```swift
static let maxMicDelay: TimeInterval = 30.0  // existing

/// Clamps `delay` to ±`maxMicDelay`. Logs a warning if clamping occurred —
/// excessive deltas usually mean the output device was switched mid-recording.
static func clampMicDelay(_ delay: TimeInterval) -> TimeInterval {
    let clamped = min(max(delay, -maxMicDelay), maxMicDelay)
    if clamped != delay {
        logger.warning("mic_delay_clamped original=\(delay)s clamped=\(clamped)s — possible output-device switch during recording")
    }
    return clamped
}
```

Replace the existing inline clamp with `let micDelay = clampMicDelay(rawDelay)`.

**Step 4: Run tests**

```bash
cd app/MeetingTranscriber && swift test --filter AudioMixerDelayTests
```

**Step 5: Commit**

```bash
git add app/MeetingTranscriber/Sources/AudioMixer.swift app/MeetingTranscriber/Tests/AudioMixerDelayTests.swift
git commit -m "feat(app): warn when mic delay is clamped (likely device-switch artefact)"
```

---

### Task 2.5: Log LLM errors in OpenAI + Claude CLI generators

**Files:**
- Modify: `app/MeetingTranscriber/Sources/OpenAIProtocolGenerator.swift:154`
- Modify: `app/MeetingTranscriber/Sources/ClaudeCLIProtocolGenerator.swift:71` (and the silent declared-but-unused logger)

**Step 1: Manual verification only**

These are catch blocks already in place. Test would require mocking the LLM endpoint — skip for now.

**Step 2: Edit `OpenAIProtocolGenerator.swift:154` (and surrounding catch)**

Find the catch block at line 154. Add:

```swift
} catch {
    logger.error("openai_generation_failed error=\(error.localizedDescription, privacy: .public) endpoint=\(endpoint, privacy: .public) model=\(model, privacy: .public)")
    throw error
}
```

**Step 3: Edit `ClaudeCLIProtocolGenerator.swift:71`**

Replace the silent catch with:

```swift
} catch {
    logger.error("claude_cli_generation_failed error=\(error.localizedDescription, privacy: .public)")
    throw error
}
```

Also instrument the subprocess flow at lines 107-111 (write stdin, read stdout). Add:

```swift
logger.info("claude_cli_subprocess_start prompt_bytes=\(promptData.count)")
// ... existing code ...
// in readStreamJSON loop:
logger.debug("claude_cli_progress parts=\(parts.count) lines=\(linesSeen)")  // gated by verboseDiagnostics
// on timeout:
logger.warning("claude_cli_timeout elapsed=\(elapsed)s parts_received=\(parts.count)")
```

**Step 4: Build + smoke**

```bash
cd app/MeetingTranscriber && swift build
```

**Step 5: Commit**

```bash
git add app/MeetingTranscriber/Sources/OpenAIProtocolGenerator.swift app/MeetingTranscriber/Sources/ClaudeCLIProtocolGenerator.swift
git commit -m "feat(app): log LLM generation errors and Claude CLI subprocess progress"
```

---

### Task 2.6: Permission-denial logging in `Permissions` + `AXHelper`

**Files:**
- Modify: `app/MeetingTranscriber/Sources/Permissions.swift`
- Modify: `app/MeetingTranscriber/Sources/AXHelper.swift`

**Step 1: Read both files first**

```bash
cat app/MeetingTranscriber/Sources/Permissions.swift
cat app/MeetingTranscriber/Sources/AXHelper.swift
```

(Adapt the snippets below to the actual function signatures.)

**Step 2: Add a logger declaration to each file (if missing) + log denials**

```swift
// At top of each file:
import os.log
private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "Permissions")  // or "AXHelper"

// In the check function, log when denied/restricted/notDetermined:
case .denied, .restricted:
    logger.warning("permission_denied resource=microphone status=\(status.rawValue, privacy: .public)")
    return false
```

For `AXHelper`: most calls return `nil` on failure. Add `logger.warning("ax_call_failed function=\(#function, privacy: .public)")` at each silent failure point.

**Step 3: Build + manual smoke**

```bash
cd app/MeetingTranscriber && swift build
./scripts/run_app.sh
# Verify that a fresh install with mic permission denied logs to Console.app
```

**Step 4: Commit**

```bash
git add app/MeetingTranscriber/Sources/Permissions.swift app/MeetingTranscriber/Sources/AXHelper.swift
git commit -m "feat(app): log permission and accessibility-API denials"
```

---

### Task 2.7: Speaker-matcher forensic logging with pseudonymization

The Big One — logs top-2 candidates and which threshold check failed when a speaker is rejected. Uses `pseudonymized` from Task 1.1.

**Files:**
- Modify: `app/MeetingTranscriber/Sources/SpeakerMatcher.swift:176-182`

**Step 1: Read SpeakerMatcher first to understand the current matching code**

```bash
sed -n '160,210p' app/MeetingTranscriber/Sources/SpeakerMatcher.swift
```

**Step 2: Add forensic logs at the decision point**

In the match function:

```swift
let bestPseudo = best.name.pseudonymized
let secondPseudo = second?.name.pseudonymized ?? "none"
let margin = (second.map { best.distance - $0.distance }) ?? .infinity

logger.info("speaker_match label=\(label, privacy: .public) best=\(bestPseudo, privacy: .public) bestDist=\(best.distance, privacy: .public) second=\(secondPseudo, privacy: .public) secondDist=\(second?.distance ?? -1, privacy: .public) margin=\(margin, privacy: .public)")

if best.distance >= threshold {
    logger.info("speaker_match_rejected label=\(label, privacy: .public) reason=above_threshold dist=\(best.distance) threshold=\(threshold)")
    return nil
}
if margin < confidenceMargin {
    logger.info("speaker_match_rejected label=\(label, privacy: .public) reason=below_margin margin=\(margin) min=\(confidenceMargin)")
    return nil
}
logger.info("speaker_match_assigned label=\(label, privacy: .public) speaker=\(bestPseudo, privacy: .public)")
```

(Adapt to the actual variable names — `best`, `second`, `threshold`, `confidenceMargin` may differ.)

**Step 3: Build + smoke**

```bash
cd app/MeetingTranscriber && swift build && swift test --filter SpeakerMatcher
```

**Step 4: Commit**

```bash
git add app/MeetingTranscriber/Sources/SpeakerMatcher.swift
git commit -m "feat(app): log speaker-match decisions with pseudonymized names + reject reason"
```

---

## Phase 3: Export UI

### Task 3.1: `DiagnosticExporter.swift` reads `OSLogStore` and writes a redacted file

**Files:**
- Create: `app/MeetingTranscriber/Sources/DiagnosticExporter.swift`
- Test: `app/MeetingTranscriber/Tests/DiagnosticExporterTests.swift`

**Step 1: Write a failing test for the header generator (pure function)**

```swift
import XCTest
@testable import MeetingTranscriber

final class DiagnosticExporterTests: XCTestCase {
    func test_header_includesRequiredFields() {
        let header = DiagnosticExporter.makeHeader(
            appVersion: "1.2.3",
            commit: "abcdef",
            macOSVersion: "14.5",
            settings: ["verboseDiagnostics": "true", "diarize": "true"]
        )
        XCTAssertTrue(header.contains("MeetingTranscriber 1.2.3"))
        XCTAssertTrue(header.contains("abcdef"))
        XCTAssertTrue(header.contains("macOS 14.5"))
        XCTAssertTrue(header.contains("verboseDiagnostics=true"))
    }
}
```

**Step 2: Run → fail**

```bash
cd app/MeetingTranscriber && swift test --filter DiagnosticExporterTests
```

**Step 3: Implement**

Create `app/MeetingTranscriber/Sources/DiagnosticExporter.swift`:

```swift
import Foundation
import OSLog

enum DiagnosticExporter {
    static func makeHeader(
        appVersion: String,
        commit: String,
        macOSVersion: String,
        settings: [String: String]
    ) -> String {
        let pairs = settings.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return """
        # MeetingTranscriber \(appVersion) (\(commit))
        # macOS \(macOSVersion)
        # exported_at=\(ISO8601DateFormatter().string(from: Date()))
        # settings: \(pairs)
        # ---
        """
    }

    /// Reads the last `windowSeconds` seconds of unified-log entries for our subsystems
    /// and writes them to `outputURL`. Returns the number of lines written.
    @available(macOS 12, *)
    static func export(
        to outputURL: URL,
        windowSeconds: TimeInterval = 1800,  // last 30 min
        appVersion: String,
        commit: String,
        macOSVersion: String,
        settings: [String: String]
    ) throws -> Int {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: Date().addingTimeInterval(-windowSeconds))
        let predicate = NSPredicate(
            format: "subsystem CONTAINS 'com.meetingtranscriber'"
        )
        let entries = try store.getEntries(at: position, matching: predicate)

        var lines = [makeHeader(
            appVersion: appVersion, commit: commit,
            macOSVersion: macOSVersion, settings: settings
        )]

        for entry in entries {
            guard let log = entry as? OSLogEntryLog else { continue }
            let ts = ISO8601DateFormatter().string(from: log.date)
            lines.append("\(ts) [\(log.level.rawValue)] \(log.subsystem)/\(log.category): \(log.composedMessage)")
        }

        try lines.joined(separator: "\n").write(to: outputURL, atomically: true, encoding: .utf8)
        return lines.count - 1
    }
}
```

**Step 4: Run tests**

```bash
cd app/MeetingTranscriber && swift test --filter DiagnosticExporterTests
```

Note: integration test of `export(to:)` can't be reliably written in unit tests — it depends on live OSLogStore. Cover only `makeHeader` with unit tests; verify `export` manually in Task 3.2.

**Step 5: Commit**

```bash
git add app/MeetingTranscriber/Sources/DiagnosticExporter.swift app/MeetingTranscriber/Tests/DiagnosticExporterTests.swift
git commit -m "feat(app): add DiagnosticExporter to write last-30-min OSLogStore entries"
```

---

### Task 3.2: "Export Diagnostics" button in `AdvancedSettingsView`

**Files:**
- Modify: `app/MeetingTranscriber/Sources/Settings/AdvancedSettingsView.swift` (Diagnostics section)

**Step 1: Add the button + state**

After the verbose-diagnostics Toggle section, add:

```swift
@State private var lastExportPath: URL?
@State private var exportError: String?

// inside Section("Diagnostics") {
Button("Export Diagnostics…") {
    exportDiagnostics()
}
if let path = lastExportPath {
    Text("Exported to: \(path.lastPathComponent)")
        .font(.caption)
        .foregroundStyle(.secondary)
}
if let err = exportError {
    Text("Export failed: \(err)").font(.caption).foregroundStyle(.red)
}
// }

private func exportDiagnostics() {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("MeetingTranscriber-diagnostics-\(Int(Date().timeIntervalSince1970)).log")
    do {
        let count = try DiagnosticExporter.export(
            to: tmp,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            commit: Bundle.main.infoDictionary?["GitCommitHash"] as? String ?? "dev",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            settings: [
                "verboseDiagnostics": "\(settings.verboseDiagnostics)",
                "diarize": "\(settings.diarize)",
                "vadEnabled": "\(settings.vadEnabled)",
                "transcriptionEngine": settings.transcriptionEngine.rawValue,
                "protocolProvider": settings.protocolProvider.rawValue,
                "recordOnly": "\(settings.recordOnly)",
            ]
        )
        lastExportPath = tmp
        exportError = nil
        NSWorkspace.shared.activateFileViewerSelecting([tmp])
        logger.info("diagnostics_exported lines=\(count) path=\(tmp.lastPathComponent, privacy: .public)")
    } catch {
        exportError = error.localizedDescription
        lastExportPath = nil
    }
}
```

(Add `private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "AdvancedSettingsView")` at top of file.)

**Step 2: Build + manual verification**

```bash
./scripts/run_app.sh
# In the app: Settings → Advanced → Diagnostics → "Export Diagnostics…"
# Finder should open with the .log file selected. Open it and verify:
# 1. Header with version, commit, macOS, settings
# 2. Log lines from com.meetingtranscriber subsystems
# 3. No clear-text speaker names — only "speaker_xxxx" pseudonyms
```

**Step 3: Commit**

```bash
git add app/MeetingTranscriber/Sources/Settings/AdvancedSettingsView.swift
git commit -m "feat(app): add Export Diagnostics button revealing log file in Finder"
```

---

## Phase 4: NSLog → Logger conversions

### Task 4.1: WhisperKitEngine NSLog → Logger

**Files:**
- Modify: `app/MeetingTranscriber/Sources/WhisperKitEngine.swift`

**Step 1: Find call sites**

```bash
grep -n "NSLog" app/MeetingTranscriber/Sources/WhisperKitEngine.swift
```

**Step 2: Add logger + replace each NSLog**

Add at top of file (if not present):

```swift
private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "WhisperKitEngine")
```

Replace each `NSLog("[WhisperKit] ...", arg)` with:

```swift
logger.info("...")  // for status messages
logger.error("...")  // for failures
```

**Step 3: Build + commit**

```bash
cd app/MeetingTranscriber && swift build
git add app/MeetingTranscriber/Sources/WhisperKitEngine.swift
git commit -m "chore(app): switch WhisperKitEngine from NSLog to os.Logger"
```

---

### Task 4.2: Qwen3AsrEngine NSLog → Logger

Same approach as Task 4.1, applied to `app/MeetingTranscriber/Sources/Qwen3AsrEngine.swift`.

```bash
grep -n "NSLog" app/MeetingTranscriber/Sources/Qwen3AsrEngine.swift
```

Replace, build, commit:

```bash
git add app/MeetingTranscriber/Sources/Qwen3AsrEngine.swift
git commit -m "chore(app): switch Qwen3AsrEngine from NSLog to os.Logger"
```

---

### Task 4.3: NotificationManager print → Logger

**Files:**
- Modify: `app/MeetingTranscriber/Sources/NotificationManager.swift`

```bash
grep -n "print(" app/MeetingTranscriber/Sources/NotificationManager.swift
```

Replace `print("...")` with `logger.warning("...")` or `logger.error("...")` based on context.

```bash
git add app/MeetingTranscriber/Sources/NotificationManager.swift
git commit -m "chore(app): switch NotificationManager from print to os.Logger"
```

---

## Phase 5: Issue template

### Task 5.1: Add `bug-report.yml` issue template referencing diagnostic export

**Files:**
- Create: `.github/ISSUE_TEMPLATE/bug-report.yml`
- Create: `.github/ISSUE_TEMPLATE/config.yml` (if it doesn't already exist — pinning the form-only choice)

**Step 1: Check existing templates**

```bash
ls -la .github/ISSUE_TEMPLATE/ 2>/dev/null
```

**Step 2: Create `bug-report.yml`**

```yaml
name: Bug Report
description: Report a bug with Meeting Transcriber
title: "[Bug] "
labels: ["bug"]
body:
  - type: markdown
    attributes:
      value: |
        Thanks for the report! To help us debug, please attach a diagnostic log:

        1. Open Meeting Transcriber → Settings → Advanced → Diagnostics
        2. Toggle **Verbose Diagnostic Logging** ON
        3. Reproduce the problem
        4. Click **Export Diagnostics…** — Finder will reveal a `.log` file
        5. Drag the `.log` file into the "Diagnostic log" field below

        Speaker names are pseudonymised (`speaker_a3f2`); transcript content is **not** included.

  - type: input
    id: app-version
    attributes:
      label: App version
      description: Settings → Advanced → About
      placeholder: "1.2.3 (abcdef) · Homebrew"
    validations:
      required: true

  - type: dropdown
    id: variant
    attributes:
      label: Build variant
      options:
        - Homebrew (stable)
        - Homebrew (beta / RC)
        - App Store
        - Built from source
    validations:
      required: true

  - type: textarea
    id: what-happened
    attributes:
      label: What happened?
      description: Describe the bug. What did you expect, what did you see instead?
    validations:
      required: true

  - type: textarea
    id: repro
    attributes:
      label: Steps to reproduce
      placeholder: |
        1. Start a Zoom meeting
        2. ...
    validations:
      required: true

  - type: textarea
    id: log
    attributes:
      label: Diagnostic log
      description: Drag the exported .log file here. (GitHub will upload it automatically.)
    validations:
      required: false
```

**Step 3: Commit**

```bash
mkdir -p .github/ISSUE_TEMPLATE
git add .github/ISSUE_TEMPLATE/bug-report.yml
git commit -m "docs(ci): add bug-report issue template requesting diagnostic log"
```

---

## Phase 6: Open the PR

After all tasks complete:

```bash
git push -u origin feat/diagnostic-logging
gh pr create --title "feat: diagnostic logging end-to-end (toggle + export + redaction)" --body "$(cat <<'EOF'
## Summary

End-to-end "users attach a log file to GitHub issues" workflow.

- **Phase 1:** infrastructure — `LogRedaction.swift` (pseudonymized + redactedName), renamed `audioDebugLogging` → `verboseDiagnostics` (with UserDefaults migration, no setting loss), per-PipelineJob UUID for cross-stage log correlation
- **Phase 2:** new diagnostic logs — tap-status translation, empty-transcription detection with input RMS, VAD round-trip drift detection, mic-delay clamp warning, LLM error logging, permission denial logging, speaker-match forensics with pseudonymization
- **Phase 3:** export UI — `DiagnosticExporter` reads `OSLogStore` (last 30 min), Settings → Advanced → "Export Diagnostics…" button writes a redacted file and reveals it in Finder
- **Phase 4:** NSLog → os.Logger across WhisperKit, Qwen3, NotificationManager
- **Phase 5:** `.github/ISSUE_TEMPLATE/bug-report.yml` guides users to attach the export

## Test plan

- [ ] All Swift tests pass: `cd app/MeetingTranscriber && swift test --parallel`
- [ ] Lint clean: `./scripts/lint.sh`
- [ ] Manually toggle Verbose Diagnostic Logging, run a recording, click Export Diagnostics, verify Finder opens to the .log file
- [ ] Verify the .log file contains pseudonymised speaker names (no clear text)
- [ ] Verify the legacy `audioDebugLogging=true` UserDefaults entry migrates to `verboseDiagnostics=true` on first launch
- [ ] Verify pipeline job IDs appear in `[xxxxxxxx]` form across transcription/diarization/protocol logs

EOF
)"
```

---

## Open questions to resolve during execution

If any of these surface mid-implementation, pause and ask:

1. **`PipelineJob` codable migration:** if existing persisted queues lack `id`, the decode-default makes them work. But test-stub creation requires checking the actual struct definition — if test stubs already exist (`PipelineJob.empty` or similar), reuse them; otherwise add `makeTestStub()`.
2. **`OSLogStore.local()` vs `.currentProcessIdentifier`:** `.local()` requires the entitlement `com.apple.developer.os-logging.read` (granted by default to user-launched apps). If the App Store sandbox build can't read other processes' logs, fall back to `.currentProcessIdentifier` (covers our app only — sufficient for diagnostics).
3. **`%{public}@` vs `%{private}@`:** any **clear name, transcript text, or path under `~/`** must use `%{private}@` (Logger string-interpolation `privacy: .private`). Pseudonyms, IDs, durations, counts, OSStatus codes are `.public`.
4. **Dual-build (`#if APPSTORE`):** the Claude CLI logs in Task 2.5 are inside `#if !APPSTORE` — keep them there. The export button works in both variants.

---

## Skill references

- @superpowers:test-driven-development — every task with a pure-function unit follows the red→green→refactor cadence above.
- @superpowers:requesting-code-review — when each phase finishes, the implementer subagent runs spec + quality reviews via the subagent-driven-development workflow.
- @superpowers:finishing-a-development-branch — used after Phase 6 to push, open the PR, and respond to review feedback.
