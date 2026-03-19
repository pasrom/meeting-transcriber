# Roadmap

## High Priority

### Push-to-talk dictation

**Status:** Not started
**Priority:** High
**Inspiration:** [Handy](https://github.com/cjpais/Handy) — local push-to-talk dictation app (Rust/Tauri)

Add Handy-style dictation to the menu bar app: hold a configurable hotkey → speak → release → transcribed text is pasted into the focused app. Leverages existing mic recording and Parakeet transcription infrastructure.

#### Core dictation flow

**Hold hotkey → record mic → release → transcribe → (optional) post-process → paste into focused app**

1. **Global hotkey manager** (~200-300 lines, new `HotkeyManager.swift`)
   - `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` for modifier keys, or `CGEventTap` for arbitrary keys
   - Accessibility permission already granted — prerequisite satisfied
   - Key-down → start recording, key-up → stop + transcribe
   - Debounce rapid key repeats (~30ms threshold, same as Handy)
   - Hotkey picker UI in Settings (custom key recorder view)

2. **Dictation controller** (~150-200 lines, new `DictationController.swift`)
   - Thin wrapper around existing `MicRecorder` / `AVAudioEngine` — no dual-source, no mixing
   - Single-mic capture to temp WAV, reuse existing mic device selection from `AppSettings.micDeviceUID`
   - On release: feed WAV to `FluidTranscriptionEngine.transcribe()` → extract plain text
   - No diarization, no protocol generation, no VAD — direct path only
   - Model already loaded if app is running (shared `FluidTranscriptionEngine` instance) — near-zero cold start

3. **Text insertion** (~50-80 lines, part of `DictationController`)
   - Save current clipboard contents (`NSPasteboard.general`)
   - Copy transcribed text to clipboard
   - Synthesize Cmd+V via `CGEvent` to paste into focused app
   - Restore original clipboard contents after paste
   - App Store variant: verify `CGEvent` keyboard synthesis works within sandbox, may need alternative approach

4. **Settings UI** (~100-150 lines, edit `SettingsView.swift` + `AppSettings.swift`)
   - Enable/disable dictation toggle
   - Hotkey picker (record a key combination)
   - Post-processing toggle + prompt selection (see below)
   - Custom words list (see below)

5. **Menu bar integration** (~30-50 lines, edit `MenuBarView.swift`)
   - Visual indicator when dictation is active (recording state)
   - Toggle dictation on/off from menu

#### Post-processing via LLM

Optional LLM cleanup of the raw transcript before pasting, matching Handy's approach.

**How Handy does it:** Sends the raw transcript to a configurable OpenAI-compatible API endpoint with a user-selected prompt. Supports structured JSON output. Two separate hotkeys: one for raw transcription, one for transcribe-then-post-process.

**Implementation approach:**
- Reuse existing `OpenAIProtocolGenerator` HTTP client infrastructure (already supports any OpenAI-compatible API)
- Add `DictationPostProcessor` that sends transcript + system prompt to the configured LLM endpoint
- Multiple named prompts (like Handy's `post_process_prompts: Vec<LLMPrompt>`) — user can create/select prompts for different use cases (e.g., "clean up filler words", "format as bullet points", "translate to English")
- Settings: enable/disable, select prompt, configure provider (reuse existing OpenAI-compatible provider settings or add dictation-specific ones)
- Strip filler words list: configurable `custom_filler_words` that are removed before/after LLM processing
- Consider two hotkey bindings: one for raw dictation, one for dictation + post-processing (Handy's `--toggle-transcription` vs `--toggle-post-process` pattern)

#### Custom words / vocabulary guidance

Guide transcription toward domain-specific terminology (project names, technical terms, proper nouns).

**How Handy does it:** Stores `custom_words: Vec<String>` in settings. These are passed to the Whisper model's `initial_prompt` parameter, which biases the decoder toward recognizing those words without constraining it.

**Implementation for meeting-transcriber:**
- Parakeet (FluidAudio) does not support Whisper-style `initial_prompt` biasing — it's a CTC/TDT model, not an autoregressive decoder
- Two viable approaches:
  1. **Post-processing correction:** Pass custom words list to the LLM post-processor with instructions like "correct any misrecognized words from this list: [words]". Low effort, works with any model. Handy's filler word removal already demonstrates this pattern.
  2. **Whisper model option:** Add a Whisper model variant (via FluidAudio or WhisperKit) alongside Parakeet specifically for use cases where vocabulary guidance matters. Higher effort but gives native decoder biasing.
- **Recommendation:** Start with approach 1 (LLM post-processing correction). Add Whisper option later if needed.
- Same custom words list should also be usable by meeting transcription pipeline (pass to protocol generation prompt)
- Settings: text field or list editor for custom words, shared between dictation and meeting transcription

#### Effort estimate

| Component | Lines | Files |
|---|---|---|
| Global hotkey manager | ~200-300 | 1 new (`HotkeyManager.swift`) |
| Dictation controller + text insertion | ~200-280 | 1 new (`DictationController.swift`) |
| Post-processing | ~150-200 | 1 new (`DictationPostProcessor.swift`) |
| Settings UI + model | ~150-200 | Edit `SettingsView.swift` + `AppSettings.swift` |
| Menu bar integration | ~30-50 | Edit `MenuBarView.swift` |
| Tests | ~200-300 | 1-2 new test files |
| **Total** | **~900-1300** | **3-4 new + edits to 4-5 existing** |

## Low Priority

### Replace Screen Recording with Accessibility API for meeting detection

**Status:** Not started
**Priority:** Low

Currently `MeetingDetector` uses `CGWindowListCopyWindowInfo` (requires Screen Recording permission) to enumerate all windows. Since we only need to detect MS Teams meetings, we could use Accessibility APIs instead (`AXUIElementCreateApplication` + `kAXTitleAttribute`), which the app already has permission for.

**Motivation:** Reduce actual data access scope — current code polls all app windows, targeted AX approach would only touch Teams.

**Note:** This is _not_ a strict security improvement. Accessibility permission is equally (or more) powerful than Screen Recording. The benefit is narrower code-level scope, not a reduced permission ceiling.

**Implementation approach:**
- Use `NSRunningApplication.runningApplications(withBundleIdentifier:)` to find Teams PID
- Read window titles via `AXUIElementCreateApplication(pid)` + `kAXWindowRole` + `kAXTitleAttribute`
- Match against existing patterns in `MeetingPatterns.swift`
- `ParticipantReader.swift` already demonstrates this exact pattern
- Would allow removing Screen Recording permission requirement

## Medium Priority

### Surface silent pipeline failures to the user

**Status:** Not started
**Priority:** Medium

Several pipeline failures are logged but not surfaced to the user:
- **Diarization failure** (`PipelineQueue.swift:483-486`): falls back to undiarized transcript silently. User gets result without speaker labels but no explanation.
- **Speaker naming timeout** (`PipelineQueue.swift:397-399`): auto-skips after 120s with no notification. Easy to miss during back-to-back meetings.
- **Empty audio capture**: only detected after transcription produces empty text.

**Implementation approach:**
- Send macOS notifications on diarization fallback and speaker naming timeout
- Show a warning badge on completed jobs that had degraded results
- Add a "warnings" field to `PipelineJob` to track what was skipped/degraded

### Protocol generation fallback

**Status:** Not started
**Priority:** Medium

If the configured protocol provider (Claude CLI or OpenAI API) fails, the entire job fails with no recovery. Both providers implement the same `ProtocolGenerating` protocol.

**Implementation approach:**
- Allow configuring a secondary/fallback provider in Settings
- Wrap `protocolGeneratorFactory()` call in `PipelineQueue.processNext()` with a try/catch that attempts the fallback provider
- Log which provider succeeded so the user knows

### Pipeline progress for long meetings

**Status:** Not started
**Priority:** Medium

Long meetings can take minutes to process with no segment-level feedback. `activeJobElapsed` tracks wall time but not completion percentage.

**Implementation approach:**
- Transcription: add a progress callback to `FluidTranscriptionEngine` reporting segment N of M
- Diarization: estimate progress based on audio duration vs elapsed time
- Protocol generation: stream partial output to show the protocol being written
- Surface progress in `MenuBarView` and job detail UI

### Detect back-to-back meeting transitions

**Status:** Not started
**Priority:** Medium

`waitForMeetingEnd` only checks whether *any* Teams meeting window exists, not whether the *same* meeting is still active. When one meeting ends and another starts immediately, the window title changes but the detector treats it as one continuous session — recording everything under the first meeting's name.

**Impact:** Back-to-back meetings are merged into a single recording and transcript with the wrong title.

**Implementation approach:**
- In `waitForMeetingEnd`, compare current window title against the original `meeting.windowTitle`
- If the title changes to a different meeting (not an idle pattern), treat it as: meeting A ended, meeting B started
- Stop recording for meeting A, enqueue it, then start a new recording for meeting B
- Need to handle brief title flickers (e.g., Teams UI transitions) — possibly require consecutive title-change detections before splitting
