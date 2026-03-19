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

Guide transcription toward domain-specific terminology (project names, technical terms, proper nouns). Shared between dictation and meeting transcription.

**How Handy does it:** Dual strategy depending on the transcription engine:
1. **Whisper models:** Passes `custom_words` as the `initial_prompt` parameter, which biases the autoregressive decoder toward those words.
2. **Parakeet (non-Whisper):** Applies fuzzy post-correction via `apply_custom_words()` — a text-level correction pass after transcription using Levenshtein distance + Soundex phonetic matching. A configurable `word_correction_threshold` (0.0–1.0) controls match strictness. N-gram matching (3→2→1 words) handles multi-word terms. Case and punctuation are preserved in replacements.
3. **Filler word removal:** Separate `custom_filler_words` list + built-in language-specific filler words, stripped from output via `filter_transcription_output()`.

**Implementation for meeting-transcriber:**
- Since we use Parakeet (CTC/TDT model), follow Handy's approach 2: fuzzy post-correction after transcription
- Implement `applyCustomWords()` with Levenshtein + phonetic matching (Swift has no built-in Soundex but it's ~30 lines)
- N-gram matching (up to 3-grams) to handle multi-word terms like "Meeting Transcriber" or "FluidAudio"
- Configurable threshold in settings (default ~0.3, same as Handy)
- Filler word removal: configurable list + built-in defaults (um, uh, like, you know, etc.)
- Same custom words list feeds into meeting transcription pipeline (pass to protocol generation prompt for additional context)
- Settings: list editor for custom words + filler words, shared between dictation and meeting transcription
- **Effort:** ~150-200 lines for the text correction logic, ~50-80 lines for settings UI

#### Effort estimate

| Component | Lines | Files |
|---|---|---|
| Global hotkey manager | ~200-300 | 1 new (`HotkeyManager.swift`) |
| Dictation controller + text insertion | ~200-280 | 1 new (`DictationController.swift`) |
| Post-processing via LLM | ~150-200 | 1 new (`DictationPostProcessor.swift`) |
| Custom words (fuzzy correction + filler removal) | ~200-280 | 1 new (`TextCorrector.swift`) |
| Settings UI + model | ~200-250 | Edit `SettingsView.swift` + `AppSettings.swift` |
| Menu bar integration | ~30-50 | Edit `MenuBarView.swift` |
| Tests | ~300-400 | 2-3 new test files |
| **Total** | **~1300-1800** | **4-5 new + edits to 4-5 existing** |

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
