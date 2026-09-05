# Local Automation API

A versioned, localhost-only HTTP API for driving the transcription pipeline
headlessly: feed an audio file in, get a diarized transcript (and optionally an
LLM protocol) back, all without touching the menu-bar UI. It is intended for
fleet / agent-orchestration use cases (a Mac mini that records and a separate
machine that drives processing over the loopback interface, or an AI agent that
submits files and reads results).

The API is served by the embedded `DebugRPCServer` and lives under the `/v1`
prefix. The `/v1` surface carries a stability contract; the unversioned debug
endpoints (`/state`, `/metrics`, `/screenshot`, `/action/*`) are inspection-only
and may change without notice.

## Availability

- **Homebrew / direct build only.** The whole server is compiled out of the App
  Store variant (`#if !APPSTORE`), because the sandbox forbids the
  `network.server` entitlement the listener needs.
- **Off by default.** Enable it one of two ways:
  - **Settings → Advanced → "Local Automation API"** (persistent toggle, backed
    by the `debugRPCEnabled` user default).
  - **`MEETINGTRANSCRIBER_DEBUG_RPC=1`** environment variable, which force-starts
    the server at launch (used by `./scripts/run_app.sh` and the E2E drivers).
- **Bind address:** `127.0.0.1:9876`. The listener is pinned to the IPv4
  loopback and accepts local connections only; it is never reachable off the
  machine.

## Authentication

Two layers of defense, both enforced on every request:

1. **Bearer token.** Send `Authorization: Bearer <token>`. The token is a
   64-character hex string (32 bytes of entropy) stored at
   `~/Library/Application Support/MeetingTranscriber/.rpc-token` (mode `0600`).
   It is generated on first launch and reused across launches. Toggling the
   server off then on rotates the token (invalidating any previously leaked
   value). A missing or wrong token returns `401`. Comparison is constant-time.
2. **Origin / Host guard.** Any request carrying a non-empty browser `Origin`
   header (other than the literal `null`) is rejected with `403`, which blocks
   CSRF and DNS-rebinding from a page running locally. The `Host` header, when
   present, must be `127.0.0.1` or `localhost` (with or without the port), else
   `403`. `curl` and native CLIs send neither header, so they pass; browsers do,
   so they are kept out.

Read the token into a shell variable for the examples below:

```bash
TOKEN=$(cat ~/Library/Application\ Support/MeetingTranscriber/.rpc-token)
BASE=http://127.0.0.1:9876
```

The whole request (request line, headers, and body together) is capped at 64 KiB
per connection; exceeding it closes the connection without sending a response.

## Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/v1/transcribe` | Enqueue one file and block until it finishes (or the wait elapses). |
| `POST` | `/v1/jobs` | Enqueue one or more files, return immediately with the created job IDs. |
| `GET`  | `/v1/jobs/<id>` | Read a job's status and result paths (live or finished). |
| `GET`  | `/v1/jobs/<id>/naming` | Read the pending speaker-naming choice for a job. |
| `POST` | `/v1/jobs/<id>/naming` | Confirm speaker names for a job. |
| `POST` | `/v1/jobs/<id>/naming/skip` | Skip naming for a job (accept auto-assigned names). |
| `GET`  | `/v1/watch` | Read whether the app is watching for meetings. |
| `POST` | `/v1/watch` | Start, stop or toggle meeting watching. |
| `GET`  | `/v1/record` | Read whether a microphone-only recording is running. |
| `POST` | `/v1/record` | Start, stop or toggle a microphone-only recording. |

A query string is stripped before routing, so `/v1/jobs/<id>?foo=bar` still
resolves the id. The one query parameter with meaning is `include=transcript`
on `POST /v1/transcribe` and `GET /v1/jobs/<id>` (see [Inline transcript](#inline-transcript)).

### POST /v1/transcribe

The one-call path: enqueue a single file and wait for a terminal result. The job
runs with headless auto-skip, so a multi-speaker recording completes on its own
(accepting the auto-assigned speaker names) instead of parking on the
interactive naming dialog.

Request body:

```json
{ "path": "/absolute/path/to/audio.wav", "maxWaitSeconds": 600 }
```

- `path` (required): absolute path to an audio/video file readable by the app.
- `maxWaitSeconds` (optional): how long to block. Default `600`, clamped to
  `[0, 1800]`. Use `0` to enqueue and return the current status without waiting.

Responses:

- `200 OK` with a [JobStatusDTO](#jobstatusdto) once the job reaches a terminal
  state (`done` or `error`).
- `202 Accepted` with a JobStatusDTO if the wait elapsed while the job was still
  running. The job keeps running; poll `GET /v1/jobs/<id>` until it is terminal.
- `400 Bad Request` if `path` is missing/empty, the body is undecodable, or the
  file does not exist on disk.

```bash
curl -sS -X POST "$BASE/v1/transcribe" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"path":"/Users/me/Recordings/standup.wav","maxWaitSeconds":900}'
```

#### Inline transcript

By default the response carries only metadata and a `transcriptPath` — fine when
the client shares a filesystem with the app, useless for a remote agent that
cannot read that path. Add `?include=transcript` to fold the transcript text into
the response as a `transcript` field:

```bash
curl -sS -X POST "$BASE/v1/transcribe?include=transcript" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"path":"/Users/me/Recordings/standup.wav"}'
```

- Opt-in only. Without the parameter the wire shape is unchanged (no `transcript`
  key), so existing clients are unaffected.
- Populated on the terminal `200` response (and on `GET /v1/jobs/<id>?include=transcript`).
  A `202` (still running) has no transcript yet, so the field is absent.
- Best-effort: if the transcript file is missing or unreadable the field is
  omitted and `transcriptPath` is still returned — opting in never turns a
  finished job into an error.

### POST /v1/jobs

Enqueue one or more files without blocking. Returns the created job IDs so a
client can poll each one.

Request body:

```json
{ "paths": ["/abs/one.wav", "/abs/two.wav"] }
```

Responses:

- `200 OK` with `{ "jobIDs": ["<uuid>", ...] }`.
- `400 Bad Request` if `paths` is missing/empty or the body is undecodable.

```bash
curl -sS -X POST "$BASE/v1/jobs" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"paths":["/Users/me/Recordings/standup.wav"]}'
```

### GET /v1/jobs/&lt;id&gt;

Read a job's current status. Answers for both live (in-flight) jobs and finished
jobs that have already been reaped from the in-memory queue: terminal records
are persisted to a small file-backed store (cap 200, owner-only) that survives
both the queue's 60-second cleanup of finished jobs and an app restart. A slow
poller therefore never loses the transcript/protocol paths.

Responses:

- `200 OK` with a [JobStatusDTO](#jobstatusdto).
- `404 Not Found` if the id is unknown (never enqueued, or aged out of the
  terminal store).

```bash
curl -sS "$BASE/v1/jobs/<id>" -H "Authorization: Bearer $TOKEN"
```

### GET /v1/jobs/&lt;id&gt;/naming

Read the speaker-naming choice awaiting resolution for a job. Only meaningful
when the job is in the `speakerNamingPending` state (which the headless
`/v1/transcribe` path skips; this is for interactive automation that wants to
assign names itself).

Responses:

- `200 OK` with a [NamingStatusDTO](#namingstatusdto).
- `404 Not Found` if the id is unknown or the job is not awaiting naming.

### POST /v1/jobs/&lt;id&gt;/naming

Confirm speaker names for a job that is awaiting naming.

Request body:

```json
{ "mapping": { "Speaker 1": "Alice", "Speaker 2": "Bob" } }
```

Responses:

- `200 OK` on success.
- `409 Conflict` if the job exists but is not awaiting naming (wrong state).
- `404 Not Found` if the id is unknown.
- `400 Bad Request` if the body is undecodable.

### POST /v1/jobs/&lt;id&gt;/naming/skip

Skip naming for a job (accept the auto-assigned names and let it finish).

Responses:

- `200 OK` on success.
- `409 Conflict` if the job exists but is not awaiting naming.
- `404 Not Found` if the id is unknown.

### GET /v1/watch

Read whether the app is currently watching for meetings. Returns a
[`WatchStatusDTO`](#watchstatusdto).

```bash
curl -sS "$BASE/v1/watch" -H "Authorization: Bearer $TOKEN"
```

Always `200 OK`. Before the app has finished starting up it reports a steady
"not watching, nothing wrong" state rather than failing, so a client polling on
an interval never has to special-case launch.

### POST /v1/watch

Start, stop or toggle meeting watching — the same thing the menu bar's *Start
Watching* item does.

```bash
curl -sS -X POST "$BASE/v1/watch" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"action":"toggle"}'
```

`action` is `start`, `stop`, or `toggle`.

Prefer `start`/`stop` over `toggle` for anything that fires from a button, key
or schedule. A toggle applies a *delta* to a state the caller cannot see
reliably: if a meeting ended (or you started watching from the menu bar) since
the caller last looked, a blind toggle does the opposite of what was intended
and stays inverted until someone notices. `start` and `stop` express the desired
end state and converge no matter what happened in between.

The response body is a [`WatchStatusDTO`](#watchstatusdto) describing the state
**after** the action, so a controller can redraw from the response instead of
racing a follow-up `GET`.

Responses:

- `200 OK` — the request was satisfied. This covers *both* "the state changed"
  and "it was already like that": asking an already-watching app to `start` is a
  satisfied request, not an error. A `stop` while a manual recording owns the
  loop is also `200`: the app is not watching, which is what was asked for.
  Read `manualRecording` in the body if you need to distinguish that case.
- `409 Conflict` — refused because a manual (app-picker) recording owns the
  watch loop, and starting would clobber it. Stop that recording first. The body
  is still a `WatchStatusDTO`, with `manualRecording: true`, so a client can
  explain the refusal. Only `start` and a `toggle` that resolves to a start can
  return this.
- `503 Service Unavailable` — the action was attempted but the state did not
  settle within 20 seconds. In practice this means an unanswered microphone
  permission dialog: the first watch start on a fresh install blocks on it, and
  on a menu-bar-only app that dialog can sit unnoticed behind other windows.
  Answer it and retry. Note that a *denied* microphone does not produce a `503`
  — watching starts regardless, because app audio records without it, so you get
  `200` with `watching: true`. Check the badge or `permissionsHealthy` for that.
- `400 Bad Request` — the body is not JSON, or `action` is not one of the three
  verbs.

### GET /v1/record

Read whether a microphone-only recording is running. Returns a
[`RecordStatusDTO`](#recordstatusdto).

```bash
curl -sS "$BASE/v1/record" -H "Authorization: Bearer $TOKEN"
```

Always `200 OK`, on the same terms as `GET /v1/watch`: before the app has
finished starting up it reports a steady "not recording, nothing in the way"
state rather than failing.

### POST /v1/record

Record the system microphone with no app audio, for a meeting happening in the
room rather than in an app. The same thing the menu bar's *Record Microphone*
item does.

```bash
curl -sS -X POST "$BASE/v1/record" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"action":"start"}'
```

`action` is `start`, `stop`, or `toggle`. Prefer `start`/`stop` for anything
that fires from a button, key or schedule, for the reason spelled out under
`POST /v1/watch`.

The response body is a [`RecordStatusDTO`](#recordstatusdto) describing the state
**after** the action.

Responses:

- `200 OK` — the request was satisfied, covering both "the state changed" and
  "it was already like that". A `stop` while something *else* is being recorded
  is also `200`: no microphone recording is running, which is what was asked
  for, and that other recording is deliberately left alone. This endpoint only
  ever stops the recording it could have started.
- `409 Conflict` — refused because another recording owns the watch loop: an
  auto-detected meeting, or an app-picker recording. Starting would clobber it.
  Stop that recording first, or use `POST /v1/watch` if it is a detected
  meeting. `otherRecordingActive` is normally `true` in the body; it can read
  `false` when the conflict is a start that registered moments earlier and has
  not reached `recording` yet, in which case `startPending` is the one that is
  set. Only `start` and a `toggle` that resolves to a start can return this.
- `412 Precondition Failed` — refused because nothing would be captured. Either
  "No Microphone (app audio only)" is set in Settings, or the microphone
  permission is denied or broken. Read `noMic` and `microphoneHealthy` in the
  body to tell the two apart. **Retrying does not help**: unlike `503` this
  answer is stable until someone changes a setting, so a retry loop should stop
  on it.
- `400 Bad Request` — the body is undecodable or `action` is not one of the
  three verbs. Unlike the codes above this one carries an **empty** body, not a
  `RecordStatusDTO`, because nothing was applied and there is no resulting state
  to report.
- `503 Service Unavailable` — the start was attempted and did not produce a
  recording. Two causes: it did not settle within 20 seconds (in practice an
  unanswered microphone permission dialog), or the recorder itself refused to
  start, which a device that is absent or held by another process looks like. A
  `stop` answers `503` when the recording could not be handed to the pipeline,
  i.e. the audio is gone; the job you would poll for does not exist.

Retrying is right for `503` and pointless for `412`. That is the whole reason
they are separate codes.

**Why a denied microphone is `412` here and `200` on `/v1/watch`.** Watching
starts fine without the microphone, because app audio still records, so a `200`
with `watching: true` is the truth there. A microphone-only recording has no
second channel to fall back on, so the same machine state means nothing at all
would be captured, and reporting success would be a lie a client could not
detect until it went looking for the file.

## Idempotency

`POST /v1/jobs` and `POST /v1/transcribe` honour an `Idempotency-Key` request
header. A repeat request carrying a key already seen returns the original job(s)
instead of enqueuing duplicates: `/v1/jobs` returns the original `jobIDs`, and
`/v1/transcribe` returns the existing job's current status.

```bash
curl -sS -X POST "$BASE/v1/transcribe" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Idempotency-Key: standup-2026-06-18" \
  -H "Content-Type: application/json" \
  -d '{"path":"/Users/me/Recordings/standup.wav"}'
```

Scope and limits:

- The key map is in-memory per server instance (a bounded FIFO, cap 1024).
  Toggling the server off then on clears it; the dedup window is one session,
  which is all retry-dedup needs.
- The key is recorded after the job is created, so this dedupes **sequential**
  retries (a client re-sending after a response or a timeout, the common case).
  Two same-key requests racing in-flight can both enqueue. Reserve-before-work
  hardening is a planned follow-up.

## Data shapes

### JobStatusDTO

```json
{
  "jobID": "1B4E28BA-2FA1-11D2-883F-0016D3CCA427",
  "state": "done",
  "meetingTitle": "Daily Standup",
  "transcriptPath": "/Users/me/.../standup.md",
  "protocolPath": "/Users/me/.../standup-protocol.md",
  "error": null,
  "warnings": [],
  "echo": {
    "detected": true,
    "affectedWindowShare": 0.62,
    "windowsScored": 34,
    "windowsAffected": 21,
    "suppressedSegments": 12,
    "removed": false
  }
}
```

- `state`: one of `waiting`, `transcribing`, `diarizing`, `generatingProtocol`,
  `speakerNamingPending`, `done`, `error`. The terminal states are `done` and
  `error`.
- `transcriptPath` / `protocolPath`: absolute paths, present once produced
  (`protocolPath` stays `null` when protocol generation is disabled or skipped).
- `error`: a message string when `state == "error"`, else `null`.
- `warnings`: zero or more non-fatal warning strings (for example a partial
  diarization failure on one track).
- `echo`: the echo-bleed verdict, see below. Absent for a single-source job and
  for a dual-source job no verdict could be reached on.
- `transcript`: the transcript text, present **only** when the request opted in
  via `?include=transcript` (see [Inline transcript](#inline-transcript)). Absent
  otherwise, so the default shape is unchanged.

#### Echo verdict

A dual-source recording made on loudspeakers carries the remote voices on the
microphone track as well, so the same speech is transcribed twice and appears
twice in the transcript. The pipeline measures this before transcription and
reports it here.

- `detected`: whether the recording is judged affected. This is the same verdict
  that produces the human-readable entry in `warnings`; assert on this field and
  not on the sentence, which is free to be reworded.
- `affectedWindowShare`: `0…1`, the share of analysed windows whose two tracks
  carry the same audio.
- `windowsScored` / `windowsAffected`: the counts the share is computed from. A
  verdict needs a minimum of both before it claims anything, so a share alone is
  not the whole decision.
- `suppressedSegments`: how many microphone segments were left out of the written
  transcript because the app track already carries them. `0` when nothing was
  removed, which includes every recording that was never analysed.
- `removed`: whether the far end was taken out of the microphone **audio** before
  transcription. Three states, and the absent one carries weight: absent means the
  cancellation stage was never reached (the feature is off, or the recording was
  not judged affected), `false` means it was reached and the far end is still in
  the microphone track, `true` means the track was rewritten without it. Nothing
  else in this shape distinguishes the three — a cancelled recording and one that
  never had an echo both end up with the far end written once, and
  `suppressedSegments` reads `0` for a run that cancelled, a run with the
  transcript dedup switched off, and a run that did nothing at all.

  `false` does not say why, and there are four whys: no model could be resolved,
  the run failed, its self-check would not confirm it, or the confirmed output
  could not be put in place. The job's `warnings` carry which one in prose. A
  caller counting how often the feature fails to deliver wants the field; a
  caller diagnosing one recording wants the warning.

**The two remedies do not compose, and cancellation wins.** Cancellation removes
the far end from the microphone audio; the dedup drops microphone transcript
lines that duplicate it. Run together, the dedup would be judging audio the far
end has already been taken out of, where its own measure no longer means what it
was calibrated to mean. So `"removed": true` implies `"suppressedSegments": 0`
even with both switches on, and that zero is the dedup standing down rather than
an absence of duplicates. When cancellation is not confirmed the microphone track
is exactly as recorded and the dedup applies again, so `"removed": false` can be
accompanied by a non-zero count.

**Deduplication only runs on a recording reported as affected**, and it removes
lines rather than audio: the segments stay in the job's stored data, so the words
remain recoverable, and only the rendered transcript leaves them out. A caller
that counts lines and expects the far end twice will now see it once, and
`suppressedSegments` is how that difference is announced. A recording too short
for a verdict keeps its duplicates and reports `0`. A suppressed line is not
guaranteed to be remote speech: a quiet local remark made while the far end was
talking can be classified as echo and left out of the rendered transcript. The
words stay in the job's stored data either way, which is what makes that
recoverable.

**An absent `echo` is not a clean verdict.** It means no measurement was made:
the job was single-source, one track was silent, or the tracks overlapped for
less than one analysis window. A driver that treats missing as clean will report
a recording as unaffected that was never looked at. Only `"detected": false`
means analysed and clean.

The analysis covers the opening minutes of a recording rather than all of it, so
`windowsScored` is the honest denominator: for a long meeting it describes a
prefix, and bleed that starts later is not seen.

### NamingStatusDTO

```json
{
  "jobID": "1B4E28BA-2FA1-11D2-883F-0016D3CCA427",
  "meetingTitle": "Daily Standup",
  "speakers": [
    { "label": "Speaker 1", "suggested": "Alice", "speakingSeconds": 412.5 },
    { "label": "Speaker 2", "suggested": "Speaker 2", "speakingSeconds": 88.0 }
  ],
  "participants": ["Alice", "Bob"]
}
```

`suggested` is the auto-name match (falling back to the label itself when no
known voice matched). `participants` are the meeting attendees read via
accessibility, when available. Embeddings and audio are deliberately excluded
(they are large and carry PII).

### WatchStatusDTO

```json
{
  "watching": true,
  "state": "recording",
  "badge": "recording",
  "manualRecording": false,
  "pendingConsentApp": "Google Chrome",
  "permissionsHealthy": true
}
```

`watching`, `badge`, `manualRecording` and `permissionsHealthy` are always
present — everything a controller needs to render a button is guaranteed to be
in every response. `state` and `pendingConsentApp` are nullable and, following
the same convention as the job DTOs, their keys are **omitted** rather than sent
as `null` when they have no value. Read them as "absent means none".

- `watching`: whether the watch loop is running and not owned by a manual
  recording. This is an explicit field rather than something you infer from
  `state`, so the meaning cannot drift.
- `state`: `idle`, `watching`, `recording`, or `error`. Absent when no watch loop
  exists at all (the app is not watching).
- `badge`: what the menu bar icon is showing: `inactive`, `recording`,
  `transcribing`, `diarizing`, `processing`, `userAction`, `done`, `error`, or
  `updateAvailable`. This is the single richest field for a physical button or
  status display, since it folds the whole pipeline into one glanceable value.
- `manualRecording`: an app-picker recording owns the loop. Watch control is
  refused (`409`) while this is true.
- `pendingConsentApp`: the app name awaiting a browser-meeting consent answer.
  Absent when no prompt is parked. Resolve it with
  `POST /action/confirmBrowserConsent`.
- `permissionsHealthy`: false only when a permission probe has actually failed.
  A check that has not run yet reports `true`.

### RecordStatusDTO

```json
{
  "recording": true,
  "startPending": false,
  "state": "recording",
  "badge": "recording",
  "otherRecordingActive": false,
  "noMic": false,
  "microphoneHealthy": true
}
```

`recording`, `startPending`, `badge`, `otherRecordingActive`, `noMic` and
`microphoneHealthy` are always present. `state` is nullable and its key is **omitted** rather than sent
as `null`, following the same convention as the other DTOs.

- `recording`: whether a **microphone-only** recording is in progress.
  Deliberately narrower than "something is recording": an app-picker recording
  and an auto-detected meeting are reported by `otherRecordingActive` instead,
  so a client is never invited to `stop` a recording it did not start.
- `startPending`: a start has been accepted but is not recording yet. It waits
  on the microphone permission gate, which on a first run means an OS dialog
  somebody has to answer, so this window is not always short. Without this field
  a poller would read it as plain idle and press again.
- `state`: `idle`, `watching`, `recording`, or `error`. Absent when no watch loop
  exists at all.
- `badge`: what the menu bar icon is showing. Same values as in
  [`WatchStatusDTO`](#watchstatusdto).
- `otherRecordingActive`: some other capture owns the watch loop. A `start` is
  refused with `409` while this is true.
- `noMic`: the "No Microphone (app audio only)" setting is on. A `start` is
  refused with `412` while this is true.
- `microphoneHealthy`: false only when a microphone probe has actually failed
  (denied, or allowed but not working). A check that has not run yet reports
  `true`. Scoped to the one permission this endpoint needs: a denied Screen
  Recording grant does not appear here, because a microphone recording opens no
  process tap for it to gate.

## Status codes

| Code | Meaning |
|------|---------|
| `200` | Success. Body is the relevant DTO (or `{"jobIDs":[...]}` for `POST /v1/jobs`). |
| `202` | `POST /v1/transcribe` only: job still running after the wait. Poll `GET /v1/jobs/<id>`. |
| `400` | Missing/empty required field, undecodable JSON body, or a `path` that does not exist. |
| `401` | Missing or wrong bearer token. |
| `403` | Rejected by the Origin or Host guard. |
| `404` | Unknown job id. Also `GET /v1/jobs/<id>/naming` when the job is not awaiting naming (the GET folds wrong-state into `404`; the POST naming routes use `409` instead). |
| `409` | Confirm/skip naming on a job that exists but is not awaiting naming. Also `POST /v1/watch` while a manual recording owns the watch loop, and `POST /v1/record` while any other recording owns it. |
| `412` | `POST /v1/record` only: nothing would be captured ("No Microphone" is set, or the mic permission is denied/broken). Stable until a setting changes, so do not retry. |
| `503` | `POST /v1/watch` and `POST /v1/record`: the action was attempted and did not take. On `/v1/watch` that means the state did not settle within 20 seconds; on `/v1/record` also a recorder that would not start, or a stop whose audio could not be handed to the pipeline. Retryable, unlike `412`. On `/v1/watch` a *denied* microphone gives `200`, not this; on `/v1/record` it gives `412`. |

## Typical flows

**Blocking, one call (simplest):**

```bash
curl -sS -X POST "$BASE/v1/transcribe" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"path":"/abs/audio.wav"}'
# 200 with the finished JobStatusDTO, or 202 if it ran past maxWaitSeconds.
```

**Non-blocking, then poll:**

```bash
ID=$(curl -sS -X POST "$BASE/v1/jobs" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"paths":["/abs/audio.wav"]}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["jobIDs"][0])')

while :; do
  STATE=$(curl -sS "$BASE/v1/jobs/$ID" -H "Authorization: Bearer $TOKEN" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["state"])')
  case "$STATE" in done|error) break;; esac
  sleep 2
done
```

**Control watching from a script, hotkey or button:**

```bash
# Read it (safe to poll on an interval — the payload is small and stable).
curl -sS "$BASE/v1/watch" -H "Authorization: ******"

# Ask for a state, don't flip one. See POST /v1/watch for why.
curl -sS -X POST "$BASE/v1/watch" \
  -H "Authorization: ******" -H "Content-Type: application/json" \
  -d '{"action":"start"}'
```

Or via the bundled CLI, which handles the token and base URL for you:

```bash
mt-cli watch          # status
mt-cli watch start
mt-cli watch stop
mt-cli watch toggle
```

**Record an in-person meeting:**

```bash
mt-cli record start
# ... the meeting happens in the room ...
mt-cli record stop
```

The recording then goes through the normal pipeline and shows up as a job, so
`GET /v1/jobs/<id>` and the naming endpoints apply to it exactly as they do to
an imported file. Stop on a `412`: it means nothing is being captured, and the
answer will not change on a retry.

For wiring this to a physical button — a Stream Deck key, a Shortcut, a global
hotkey — see [`docs/stream-deck.md`](stream-deck.md), which covers the launcher
side.

## Notes and limitations

- **Starting watching can trigger a system permission prompt.** The first
  `POST /v1/watch` with `start` on a fresh install asks for microphone (and
  possibly Screen Recording) access, which surfaces as a macOS dialog. Triggered
  from a button press or a schedule that dialog arrives unannounced, so grant
  the permissions once interactively before relying on remote control. Check
  `permissionsHealthy` in the response to detect the state where the app cannot
  actually record.
- **Speaker DB is read-only on the headless path.** The blocking
  `POST /v1/transcribe` path recognizes already-enrolled voices but does not
  enroll new speakers or write recognition stats. (The interactive
  `POST /v1/jobs/<id>/naming` and `.../naming/skip` endpoints do log recognition
  stats, but no endpoint here enrolls new voices.) A long-running fleet does not
  improve its own speaker DB through this API. An opt-in auto-enroll mode is a
  possible follow-up.
- **Polling only.** There is no push/webhook/SSE callback in v1; clients poll
  `GET /v1/jobs/<id>`, or `GET /v1/watch` for the watching state. Push delivery
  is a known deferred item. On loopback a 3–5 s poll costs effectively nothing.
- **No file upload.** The `path` must already be readable on the host running the
  app. Cross-host submission (multipart upload, no shared filesystem) is not part
  of v1.
- **A microphone recording has no end signal of its own.** An app recording ends
  when the app quits and a detected meeting ends when the meeting does, but a
  room has no process to watch, so `POST /v1/record` with `stop` is the only way
  it ends short of the duration cap. A caller that starts one owns stopping it.
- **A refused start puts watching back, a successful one does not.** Taking the
  loop for a recording stops meeting detection; when the start is then refused
  (`412`) or fails (`503`), detection is restored, so a refusal really does
  leave the machine as it found it. A start that succeeds does not, which is the
  next bullet.
- **Recording the microphone turns meeting watching off, and stopping does not
  turn it back on.** A recording takes over the watch loop, so after a
  `start`/`stop` pair the app is idle even on a machine set to watch
  automatically. Same for the app-picker recording in the menu bar; it is just
  easier to miss over the API, where nobody is looking at the menu bar icon.
  Follow a `stop` with `POST /v1/watch {"action":"start"}` if the app should keep
  watching.
- **A crash during a microphone recording loses the track.** Recovery on the
  next launch keys on artefacts an app-audio tap leaves behind, and a
  microphone-only recording leaves none. Known limitation, not a regression.
- **`mt-cli` covers inspection plus watch and record control.** The bundled
  `tools/mt-cli` client wraps the debug endpoints (`state`, `healthz`,
  `screenshot`, `open-settings`, `close-settings`) plus `mt-cli watch` and
  `mt-cli record`; an `mt-cli transcribe` front for the job endpoints is a
  planned follow-up. For now drive the rest of `/v1` with `curl` or any HTTP
  client.

## See also

- `app/MeetingTranscriber/Sources/DebugRPCServer.swift` for the server, auth, and
  threat model, and `DebugRPCServer+V1.swift` for the `/v1` routing.
- `tools/mt-cli/skill.md` for the inspection CLI.
- `scripts/test_rpc.sh` for a live end-to-end smoketest.
