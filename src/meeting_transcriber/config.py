"""Shared configuration constants."""

from pathlib import Path

DEFAULT_WHISPER_MODEL_MAC = "large-v3-turbo-q5_0"
DEFAULT_WHISPER_MODEL_WIN = "large"
DEFAULT_OUTPUT_DIR = Path("./protocols")
TARGET_RATE = 16000

# Status file for menu bar app communication
STATUS_DIR = Path.home() / ".meeting-transcriber"
STATUS_FILE = STATUS_DIR / "status.json"

# Speaker naming IPC (Python ↔ Swift menu bar app)
SPEAKER_REQUEST_FILE = STATUS_DIR / "speaker_request.json"
SPEAKER_RESPONSE_FILE = STATUS_DIR / "speaker_response.json"
SPEAKER_SAMPLES_DIR = STATUS_DIR / "speaker_samples"
SPEAKER_NAMING_TIMEOUT = 300  # 5 minutes

# Speaker count IPC (ask user before diarization)
SPEAKER_COUNT_REQUEST_FILE = STATUS_DIR / "speaker_count_request.json"
SPEAKER_COUNT_RESPONSE_FILE = STATUS_DIR / "speaker_count_response.json"
SPEAKER_COUNT_TIMEOUT = 120  # 2 minutes

# Watch mode defaults
DEFAULT_POLL_INTERVAL = 3.0
DEFAULT_END_GRACE_PERIOD = 15.0
DEFAULT_CONFIRMATION_COUNT = 2
MAX_RECORDING_SECONDS = 14400  # 4 hours

PROTOCOL_PROMPT = """You are a professional meeting minute taker.
Create a structured meeting protocol in German from the following transcript.

Return ONLY the finished Markdown document - no explanations, no introduction,
no comments before or after.

Use exactly this structure:

# Meeting Protocol - [Meeting Title]
**Date:** [Date from context or today]

---

## Summary
[3-5 sentence summary of the meeting]

## Participants
- [Name 1]
- [Name 2]

## Topics Discussed

### [Topic 1]
[What was discussed]

### [Topic 2]
[What was discussed]

## Decisions
- [Decision 1]
- [Decision 2]

## Tasks
| Task | Responsible | Deadline | Priority |
|------|-------------|----------|----------|
| [Description] | [Name] | [Date or open] | 🔴 high / 🟡 medium / 🟢 low |

## Open Questions
- [Question 1]
- [Question 2]

Do NOT include the full transcript in the output – it will be appended automatically.

---
Transcript:
"""
