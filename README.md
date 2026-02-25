# 🎙 Meeting Transcriber

Automatische Aufnahme, Transkription und Protokollgenerierung von Meetings – lokal auf Windows, ohne Cloud-Kosten.

```
Mikrofon + Systemton → faster-whisper → Claude CLI → Markdown-Protokoll
```

---

## Features

- **Dual-Audio-Aufnahme** – Mikrofon und Systemton (Teams, Zoom, etc.) gleichzeitig via WASAPI Loopback, kein virtuelles Kabel nötig
- **Lokale Transkription** – [faster-whisper](https://github.com/SYSTRAN/faster-whisper) (Whisper large), automatische GPU-Erkennung (CUDA) oder CPU-Fallback
- **KI-Protokoll** – strukturiertes Markdown via [Claude Code CLI](https://claude.ai/code), kein separater API-Key nötig
- **Flexibler Input** – Audiodatei (wav, mp3, m4a, ...) oder fertiges `.txt`-Transkript

---

## Ausgabe

Alle Dateien landen im Ordner `./protokolle/`:

| Datei | Inhalt |
|-------|--------|
| `20260225_1400_meeting.txt` | Rohes Transkript |
| `20260225_1400_meeting.md` | Strukturiertes Protokoll |

**Protokoll-Struktur:**
- Zusammenfassung
- Teilnehmer
- Besprochene Themen
- Entscheidungen
- Tasks (Tabelle mit Verantwortlichem, Deadline, Priorität)
- Offene Fragen
- Vollständiges Transkript

---

## Voraussetzungen

### Software
- Python 3.10+
- [Claude Code CLI](https://claude.ai/code) – installiert und eingeloggt (`claude --version`)
- Node.js 20+ (für Claude Code)

### Python-Pakete

```bash
pip install faster-whisper pyaudiowpatch numpy rich
```

Für GPU-Beschleunigung (optional, empfohlen):
```bash
pip install torch --index-url https://download.pytorch.org/whl/cu121
```

---

## Installation

```bash
git clone https://github.com/meanstone/Meeting_transcriber
cd Meeting_transcriber
pip install faster-whisper pyaudiowpatch numpy rich
```

---

## Verwendung

### Live-Aufnahme (Mikrofon + Systemton)
```bash
python Meeting_transcriber.py --title "Projektmeeting"
```
→ Drücke **Enter** zum Stoppen der Aufnahme.

### Audiodatei transkribieren
```bash
python Meeting_transcriber.py --file aufnahme.mp3 --title "Sprint Review"
```

### Nur Protokoll aus bestehendem Transkript
```bash
python Meeting_transcriber.py --file protokolle/transkript.txt --title "Teammeeting"
```
Whisper wird übersprungen, Claude erstellt direkt das Protokoll.

---

## Konfiguration

Am Anfang der Datei `Meeting_transcriber.py`:

```python
WHISPER_MODEL = "large"   # tiny | base | small | medium | large
WHISPER_LANG  = None      # None = automatisch, "de" = Deutsch erzwingen
OUTPUT_DIR    = Path("./protokolle")
```

| Modell | Qualität | GPU-VRAM | Geschwindigkeit |
|--------|----------|----------|-----------------|
| `tiny` | niedrig | ~1 GB | sehr schnell |
| `base` | gut | ~1 GB | schnell |
| `small` | sehr gut | ~2 GB | mittel |
| `medium` | exzellent | ~5 GB | langsam |
| `large` | beste | ~10 GB | sehr langsam |

---

## Teams / Zoom Audio aufnehmen

Das Skript nutzt **WASAPI Loopback** – damit wird der Systemton direkt vom Windows-Audiomixer abgegriffen:

1. Teams/Zoom-Call starten
2. Skript starten (`python Meeting_transcriber.py`)
3. Aufnahme läuft automatisch mit Mikrofon + Gesprächspartner
4. Enter drücken zum Stoppen

> **Hinweis:** Jabra und einige USB-Headsets setzen den Standard-Lautsprecher um – in Windows-Einstellungen → Sound → Ausgabe prüfen, welches Gerät aktiv ist.

---

## Troubleshooting

| Problem | Lösung |
|---------|--------|
| `claude nicht gefunden` | `claude --version` im Terminal testen, ggf. neu installieren |
| Kein Systemton aufgenommen | Standard-Ausgabegerät in Windows-Soundeinstellungen prüfen |
| GPU wird nicht erkannt | `pip install torch` mit CUDA-Version, `nvidia-smi` prüfen |
| Transkript auf Englisch | `WHISPER_LANG = "de"` setzen |
| Protokoll leer | `echo Hallo | claude --print` im Terminal testen |
