# Plan: Live-Transcription

## Ziel

Während eines Meetings wird fortlaufend transkribiert. Das Live-Transkript wird als
IPC-Datei geschrieben, sodass der User in seiner eigenen Claude Code Session (oder
anderem Tool) das Transkript lesen und damit arbeiten kann.

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
```

Der User öffnet seine eigene CC-Session und arbeitet mit dem Transkript:
```bash
# Transkript lesen
cat ~/Library/Application\ Support/MeetingTranscriber/ipc/live_transcript.txt

# Oder in CC: "Lies das Live-Transkript und fasse zusammen"
# Oder: "Erstelle ein Jira-Ticket für den besprochenen Bug"
```

## Neue Dateien

### 1. `LiveTranscriptionSession.swift`

`@MainActor @Observable` — Audio-Chunking + Transkription + IPC.

**Verantwortlichkeiten:**
- Timer-basierte Schleife (alle ~15s)
- Inkrementelles Lesen der wachsenden Audio-Dateien:
  - App-Audio: `FileHandle` seek + read, raw Float32 → stereo-to-mono → resample 16kHz
  - Mic-Audio: `FileHandle` seek + read, Int16 PCM → Float32 (bereits 16kHz)
- Chunk als temp WAV speichern → `engine.transcribeSegments()` aufrufen
- Dual-Source: beide Tracks separat transkribieren, mergen
- Akkumuliertes Transkript in `live_transcript.txt` schreiben

**API:**
- `start(appTempURL:micURL:appSampleRate:)` — startet die Chunk-Schleife
- `stop()` — stoppt, verarbeitet letzten Rest-Chunk
- `cleanup()` — entfernt temp + IPC-Dateien

## Änderungen an bestehenden Dateien

### 2. `AppPaths.swift`
```swift
static let liveTranscriptFile = ipcDir.appendingPathComponent("live_transcript.txt")
```

### 3. `AppSettings.swift`
```swift
var liveTranscriptionEnabled: Bool  // default: false
var liveChunkInterval: Double       // default: 15.0
```

### 4. `DualSourceRecorder.swift`
Neue read-only Properties:
```swift
var currentAppTempURL: URL?
var currentMicURL: URL?
```

### 5. `WatchLoop.swift`
- Nach `recorder.start()` → `liveSession.start()`
- Vor `recorder.stop()` → `liveSession.stop()`
- Analog für manuelle Aufnahmen

### 6. `AppState.swift`
- `var liveSession: LiveTranscriptionSession?`
- Lifecycle-Management

### 7. `SettingsView.swift`
Neuer Abschnitt "Live Transcription":
- Toggle: Live-Transkription aktivieren
- Slider: Chunk-Intervall (10-30s)

## IPC-Datei

| Datei | Format | Update-Frequenz | Inhalt |
|-------|--------|-----------------|--------|
| `live_transcript.txt` | Plain text | Alle ~15s | Vollständiges akkumuliertes Transkript |

**Pfad:** `~/Library/Application Support/MeetingTranscriber/ipc/`

## Tests

### `LiveTranscriptionSessionTests.swift`
- Inkrementelles Lesen wachsender raw Float32 Datei
- Inkrementelles Lesen wachsender WAV Datei
- IPC-Datei wird korrekt geschrieben
- Start/Stop Lifecycle
- Leere Audio-Chunks werden übersprungen

## Einschränkungen

1. **Latenz ~15-20s** — 15s Chunk-Sammlung + ~2-5s Transkription
2. **Chunk-Grenzen** — Wörter können an Chunk-Grenzen abgeschnitten werden
3. **Keine Live-Diarization** — zu langsam; Diarization nur im finalen Protokoll

## Implementierungs-Reihenfolge

1. `LiveTranscriptionSession.swift` — Audio-Chunking + Transkription + IPC
2. `AppPaths.swift` — IPC-Pfad
3. `AppSettings.swift` — Settings
4. `DualSourceRecorder.swift` — URLs exponieren
5. `WatchLoop.swift` — LiveSession starten/stoppen
6. `AppState.swift` — Lifecycle-Management
7. `SettingsView.swift` — UI
8. Tests
9. Lint + Test + Commit + Push
