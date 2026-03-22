# Plan: Live-Transcription + Meeting-Chat

## Ziel
Während eines Meetings wird fortlaufend transkribiert. Das Live-Transkript + eine rollierende Zusammenfassung werden als IPC-Dateien geschrieben, sodass Claude Code (oder andere Tools) den Meeting-Kontext lesen und darauf reagieren können — z.B. automatisch Jira-Tickets erstellen, wenn jemand "Claude, erstelle ein Ticket für X" sagt.

## Architektur

```
Aufnahme läuft (DualSourceRecorder)
    │
    ├── App-Audio: raw Float32 @ 48kHz stereo → wachsende Temp-Datei
    │   (POSIX write, kein Locking → concurrent read möglich)
    │
    └── Mic-Audio: 16kHz mono 16-bit PCM WAV → wachsende WAV-Datei
        (AVAudioFile schreibt Buffers, concurrent read möglich)
    │
    ▼  alle ~15s
LiveTranscriptionSession
    │
    ├── Liest inkrementell neue Bytes aus beiden Dateien
    ├── Konvertiert: raw PCM → mono → resample 16kHz → temp WAV
    ├── Transkribiert Chunk via aktive Engine (Parakeet bevorzugt: 10× schneller)
    ├── Akkumuliert Transkript
    │
    ├── → live_transcript.txt (IPC, jedes Chunk-Update)
    ├── → live_summary.md    (IPC, alle ~60s via Claude CLI / OpenAI API)
    └── → live_commands.jsonl (IPC, erkannte Trigger-Phrasen)
```

## Neue Dateien

### 1. `LiveTranscriptionSession.swift`
Hauptklasse, `@MainActor @Observable`.

**Verantwortlichkeiten:**
- Timer-basierte Schleife (alle ~15s)
- Inkrementelles Lesen der wachsenden Audio-Dateien:
  - App-Audio: `FileHandle` seek + read, raw Float32 → stereo-to-mono → resample 16kHz
  - Mic-Audio: `FileHandle` seek + read, Int16 PCM → Float32 (bereits 16kHz)
- Chunk als temp WAV speichern → `engine.transcribeSegments()` aufrufen
- Dual-Source: beide Tracks separat transkribieren, mergen (wie PipelineQueue)
- Akkumuliertes Transkript verwalten
- IPC-Dateien schreiben (`AppPaths.ipcDir/live_transcript.txt` etc.)
- Trigger-Erkennung: Lines mit "Claude," scannen → `live_commands.jsonl`
- Rollierende Zusammenfassung: alle ~4 Chunks via ProtocolGenerator

**Config struct:**
- `chunkIntervalSeconds: TimeInterval = 15`
- `summaryIntervalChunks: Int = 4` (= alle ~60s)
- `triggerPhrases: [String] = ["claude,", "claude "]`

**API:**
- `start(appTempURL:micURL:appSampleRate:)` — startet die Chunk-Schleife
- `stop()` — stoppt, verarbeitet letzten Rest-Chunk
- `cleanup()` — entfernt temp + IPC-Dateien

## Änderungen an bestehenden Dateien

### 2. `AppPaths.swift`
Neue statische Properties:
```swift
static let liveTranscriptFile = ipcDir.appendingPathComponent("live_transcript.txt")
static let liveSummaryFile = ipcDir.appendingPathComponent("live_summary.md")
static let liveCommandsFile = ipcDir.appendingPathComponent("live_commands.jsonl")
```

### 3. `AppSettings.swift`
Neue Settings:
```swift
var liveTranscriptionEnabled: Bool  // default: false
var liveChunkInterval: Double       // default: 15.0 (Sekunden)
var liveSummaryEnabled: Bool        // default: true
var liveTriggerDetection: Bool      // default: true
```

### 4. `AppState.swift`
- Neue Property: `var liveSession: LiveTranscriptionSession?`
- `LiveTranscriptionSession` erzeugen + starten wenn Recording beginnt (in `toggleWatching()` und `startManualRecording()`)
- Session stoppen wenn Recording endet

### 5. `WatchLoop.swift`
- Neue optionale Property: `var liveTranscriptionSession: LiveTranscriptionSession?`
- In `handleMeeting()`: nach `recorder.start()` → `liveSession.start(appTempURL, micURL)` aufrufen
- Vor `recorder.stop()`: `liveSession.stop()` aufrufen
- Analog für `startManualRecording()` / `stopManualRecording()`

### 6. `DualSourceRecorder.swift`
- Neue read-only Properties exponieren (damit WatchLoop die URLs kennt):
  ```swift
  var currentAppTempURL: URL? { ... }
  var currentMicURL: URL? { ... }
  ```

### 7. `SettingsView.swift`
- Neuer Abschnitt "Live Transcription" in den Settings:
  - Toggle: Live-Transkription aktivieren
  - Slider: Chunk-Intervall (10-30s)
  - Toggle: Automatische Zusammenfassung
  - Toggle: Trigger-Erkennung

## IPC-Dateien (für Claude Code)

| Datei | Format | Update-Frequenz | Inhalt |
|-------|--------|-----------------|--------|
| `live_transcript.txt` | Plain text | Alle ~15s | Vollständiges akkumuliertes Transkript |
| `live_summary.md` | Markdown | Alle ~60s | Rollierende Meeting-Zusammenfassung |
| `live_commands.jsonl` | JSON Lines | Bei Erkennung | `{timestamp, trigger, command, context}` |

**Pfad:** `~/Library/Application Support/MeetingTranscriber/ipc/`

## Nutzung von Claude Code

Nach Aktivierung kann der User in Claude Code z.B.:
```
# Transkript lesen
cat ~/Library/Application\ Support/MeetingTranscriber/ipc/live_transcript.txt

# Zusammenfassung lesen
cat ~/Library/Application\ Support/MeetingTranscriber/ipc/live_summary.md

# Auf Voice Commands reagieren
tail -f ~/Library/Application\ Support/MeetingTranscriber/ipc/live_commands.jsonl
```

Oder Claude Code direkt bitten: "Lies das Live-Transkript und erstelle ein Jira-Ticket für den besprochenen Login-Bug."

## Tests

Neue Testdatei `LiveTranscriptionSessionTests.swift`:
- Test: Inkrementelles Lesen von wachsender raw Float32 Datei
- Test: Inkrementelles Lesen von wachsender WAV Datei
- Test: Trigger-Erkennung ("Claude, erstelle ein Ticket")
- Test: IPC-Dateien werden korrekt geschrieben
- Test: Start/Stop Lifecycle
- Test: Leere Audio-Chunks werden übersprungen

Mock-Engine die sofort einen fixen Text zurückgibt (existiert vermutlich schon in Tests).

## Einschränkungen / Bekannte Limitierungen

1. **Latenz ~15-20s** — 15s Chunk-Sammlung + ~2-5s Transkription
2. **Chunk-Grenzen** — Wörter können an Chunk-Grenzen abgeschnitten werden (akzeptabel für MVP)
3. **Keine Diarization** — Live-Chunks werden ohne Diarization transkribiert (zu langsam für live)
4. **Summary-Qualität** — Rollierende Zusammenfassung basiert auf Roh-Transkript ohne Diarization
5. **App-Audio Latenz** — Kernel-Buffer-Delay bis Daten auf Disk sind (~10-100ms, vernachlässigbar)

## Implementierungs-Reihenfolge

1. `LiveTranscriptionSession.swift` — Kernlogik (Chunking, inkrementelles Lesen, IPC)
2. `AppPaths.swift` — IPC-Pfade hinzufügen
3. `AppSettings.swift` — Settings hinzufügen
4. `DualSourceRecorder.swift` — URLs exponieren
5. `WatchLoop.swift` — LiveSession starten/stoppen
6. `AppState.swift` — LiveSession verwalten
7. `SettingsView.swift` — UI für Settings
8. Tests schreiben
9. Lint + Test + Commit + Push
