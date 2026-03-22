# Plan: Live-Transcription + CC-Agent Meeting-Chat

## Ziel

Während eines Meetings wird fortlaufend transkribiert. Bei Meeting-Start spawnt die App
eine Claude Code Agent-Session, die das wachsende Transkript überwacht und autonom handelt:
Zusammenfassungen schreiben, Jira-Tickets erstellen, Notizen machen — alles was CC mit
seinen eingebauten Tools (Bash, Read, Write, etc.) kann.

## Architektur

```
Meeting startet (DualSourceRecorder)
    │
    ├── App-Audio: raw Float32 @ 48kHz stereo → wachsende Temp-Datei
    └── Mic-Audio: 16kHz mono 16-bit PCM WAV → wachsende WAV-Datei
    │
    ▼  alle ~15s
LiveTranscriptionSession
    │
    ├── Liest inkrementell neue Bytes aus beiden Dateien
    ├── Konvertiert: raw PCM → mono → resample 16kHz → temp WAV
    ├── Transkribiert Chunk via aktive Engine (Parakeet bevorzugt)
    ├── Akkumuliert Transkript
    └── → live_transcript.txt (IPC, jedes Chunk-Update)
    │
    ▼  bei Meeting-Start
MeetingAgentSession (spawnt CC-Prozess)
    │
    ├── claude -p --resume <session> --allowedTools ...
    │   "Du bist ein Meeting-Assistent. Überwache live_transcript.txt.
    │    Reagiere auf Anweisungen. Fasse zusammen. Erstelle Tickets."
    │
    ├── CC hat alle Tools: Bash, Read, Write, gh, jira CLI, ...
    ├── CC liest live_transcript.txt selbst (via Read/Bash)
    ├── CC erkennt Commands ("Claude, erstelle Ticket...")
    ├── CC schreibt live_summary.md
    └── CC erstellt Tickets, Notizen, etc. autonom
    │
    ▼  Meeting endet
    App stoppt Live-Transkription + sendet finalen Chunk an CC
    CC erstellt finales Meeting-Protokoll
```

## Neue Dateien

### 1. `LiveTranscriptionSession.swift`

`@MainActor @Observable` — reine Audio-Chunking + Transkription.

**Verantwortlichkeiten:**
- Timer-basierte Schleife (alle ~15s)
- Inkrementelles Lesen der wachsenden Audio-Dateien:
  - App-Audio: `FileHandle` seek + read, raw Float32 → stereo-to-mono → resample 16kHz
  - Mic-Audio: `FileHandle` seek + read, Int16 PCM → Float32 (bereits 16kHz)
- Chunk als temp WAV speichern → `engine.transcribeSegments()` aufrufen
- Dual-Source: beide Tracks separat transkribieren, mergen
- Akkumuliertes Transkript in `live_transcript.txt` schreiben

**Nicht mehr zuständig für** (macht CC-Agent):
- ~~Trigger-Erkennung~~
- ~~Zusammenfassung~~
- ~~Command-Ausführung~~

**API:**
- `start(appTempURL:micURL:appSampleRate:)` — startet die Chunk-Schleife
- `stop()` — stoppt, verarbeitet letzten Rest-Chunk
- `cleanup()` — entfernt temp + IPC-Dateien

### 2. `MeetingAgentSession.swift`

Verwaltet den Claude Code Subprocess der während des Meetings läuft.

**Verantwortlichkeiten:**
- CC-Prozess spawnen bei Meeting-Start mit System-Prompt
- CC-Prozess stoppen bei Meeting-Ende
- Session-ID verwalten (für `--resume`)

**System-Prompt (eingebettet):**
```
Du bist ein autonomer Meeting-Assistent. Während des Meetings wird fortlaufend
transkribiert nach: {live_transcript_path}

Deine Aufgaben:
1. Lies das Transkript regelmäßig (alle 30s) via Read tool
2. Wenn jemand "Claude, ..." sagt, führe die Anweisung aus
3. Halte eine laufende Zusammenfassung in: {live_summary_path}
4. Du hast Zugriff auf alle Tools: Bash, Read, Write, gh, jira, etc.
5. Sei proaktiv: erkenne Action Items und schlage vor

Beispiel-Trigger im Transkript:
- "Claude, erstelle ein Jira-Ticket für den Login-Bug"
- "Claude, notiere: Deadline ist nächster Freitag"
- "Claude, fasse die letzten 5 Minuten zusammen"
```

**Implementierung:**
```swift
#if !APPSTORE
struct MeetingAgentSession {
    let claudeBin: String
    private var process: Process?
    private var sessionID: String?

    mutating func start(transcriptPath: URL, summaryPath: URL) throws
    mutating func stop()
    var isRunning: Bool
}
#endif
```

- Nutzt `Process()` wie `ClaudeCLIProtocolGenerator`
- `#if !APPSTORE` (Sandbox verbietet Process)
- Startet CC im Hintergrund, liest stdout für Status-Updates

## Änderungen an bestehenden Dateien

### 3. `AppPaths.swift`
```swift
static let liveTranscriptFile = ipcDir.appendingPathComponent("live_transcript.txt")
static let liveSummaryFile = ipcDir.appendingPathComponent("live_summary.md")
```

### 4. `AppSettings.swift`
```swift
var liveTranscriptionEnabled: Bool  // default: false
var liveChunkInterval: Double       // default: 15.0
var meetingAgentEnabled: Bool       // default: false (opt-in)
```

### 5. `DualSourceRecorder.swift`
Neue read-only Properties:
```swift
var currentAppTempURL: URL?
var currentMicURL: URL?
```

### 6. `WatchLoop.swift`
- Nach `recorder.start()` → `liveSession.start()` + `agentSession.start()`
- Vor `recorder.stop()` → `liveSession.stop()` + `agentSession.stop()`
- Analog für manuelle Aufnahmen

### 7. `AppState.swift`
- `var liveSession: LiveTranscriptionSession?`
- `var agentSession: MeetingAgentSession?`
- Lifecycle-Management

### 8. `SettingsView.swift`
Neuer Abschnitt "Live Transcription":
- Toggle: Live-Transkription aktivieren
- Slider: Chunk-Intervall (10-30s)
- Toggle: Meeting-Agent aktivieren (startet CC-Session)

## IPC-Dateien

| Datei | Geschrieben von | Inhalt |
|-------|----------------|--------|
| `live_transcript.txt` | App (LiveTranscriptionSession) | Akkumuliertes Transkript, alle ~15s |
| `live_summary.md` | CC-Agent (MeetingAgentSession) | Rollierende Zusammenfassung |

**Pfad:** `~/Library/Application Support/MeetingTranscriber/ipc/`

## Tests

### `LiveTranscriptionSessionTests.swift`
- Inkrementelles Lesen wachsender raw Float32 Datei
- Inkrementelles Lesen wachsender WAV Datei
- IPC-Datei wird korrekt geschrieben
- Start/Stop Lifecycle
- Leere Audio-Chunks werden übersprungen

### `MeetingAgentSessionTests.swift`
- CC-Prozess wird gestartet mit korrektem Prompt
- CC-Prozess wird bei Stop beendet
- Session-ID wird korrekt verwaltet
- `#if !APPSTORE` Kompilierungstest

## Einschränkungen

1. **Latenz ~15-20s** — 15s Chunk-Sammlung + ~2-5s Transkription
2. **Chunk-Grenzen** — Wörter können an Chunk-Grenzen abgeschnitten werden
3. **Keine Live-Diarization** — zu langsam; Diarization nur im finalen Protokoll
4. **CC-Agent nur Homebrew** — `#if !APPSTORE` (Sandbox verbietet Process)
5. **CC muss installiert sein** — `claude` CLI muss im PATH sein
6. **CC-Agent-Kosten** — Agent läuft kontinuierlich, verbraucht API-Tokens

## Implementierungs-Reihenfolge

1. `LiveTranscriptionSession.swift` — Audio-Chunking + Transkription + IPC
2. `MeetingAgentSession.swift` — CC-Prozess Lifecycle
3. `AppPaths.swift` — IPC-Pfade
4. `AppSettings.swift` — Settings
5. `DualSourceRecorder.swift` — URLs exponieren
6. `WatchLoop.swift` — Sessions starten/stoppen
7. `AppState.swift` — Lifecycle-Management
8. `SettingsView.swift` — UI
9. Tests
10. Lint + Test + Commit + Push
