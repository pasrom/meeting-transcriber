---
name: meeting-transcriber
description: Use when working on the Meeting Transcriber repo and you need to inspect or drive the running dev app from the shell instead of asking the user for screenshots.
---

# Meeting Transcriber — shell-driven inspection

The dev build of Meeting Transcriber can run an embedded debug RPC server.
When it's running, prefer `mt-cli` over asking the user "kannst du screenshot
machen" / "ist das im Menü sichtbar".

## When to use

- You want to know what's in the speaker DB right now → `mt-cli state`
- You want to verify the app is alive after a code change → `mt-cli healthz`
- You want to see what the user sees → `mt-cli screenshot /tmp/x.png`, then Read it
- You want to assert on UI structure (a Settings section exists, a control is enabled) without eyeballing a screenshot → `mt-cli ui-tree --window settings`
- You want to drive a control (press a toggle/button) and check the effect → `mt-cli ui-press <identifier> --window settings`, then `mt-cli state`. A Settings sidebar tab row (e.g. `settings-tab-about`) needs `--via click` — a plain press reports success without actually selecting the row
- You want to start or stop meeting watching without touching the menu bar → `mt-cli watch start` / `mt-cli watch stop` (prefer these over `toggle`, which flips blind)
- You want to record the microphone for an in-person meeting → `mt-cli record start` / `mt-cli record stop`. A `412` means nothing would be recorded ("No Microphone" is set, or the mic permission is denied), and it will not clear by retrying; a `409` means something else is being recorded and the request refused rather than clobber it
- You're debugging a UI bug and would otherwise have to ask the user to describe state
- You're verifying a fix end-to-end after editing code

Don't use it for production debugging — RPC is `#if !APPSTORE` only.

## How to enable

Either persistent (preferred for repeated dev sessions):

- Settings → Advanced → toggle **Local Automation API** on. The server starts
  immediately and survives app relaunches.

Or per-session (one-shot, e.g. for `scripts/test_rpc.sh`):

```bash
MEETINGTRANSCRIBER_DEBUG_RPC=1 ./scripts/run_app.sh
```

The app writes a 64-hex bearer token to
`~/Library/Application Support/MeetingTranscriber/.rpc-token` (chmod 0600).
`mt-cli` reads it automatically — no config needed on your side.

## Endpoints

| HTTP                | mt-cli              | Returns                            |
| ------------------- | ------------------- | ---------------------------------- |
| `GET /healthz`      | `mt-cli healthz`    | "ok"                               |
| `GET /state`        | `mt-cli state`      | Pipeline + speaker DB JSON         |
| `GET /screenshot`   | `mt-cli screenshot` | PNG of frontmost window            |
| `GET /ui/tree`      | `mt-cli ui-tree`    | Accessibility tree JSON (allowlisted windows) |
| `POST /ui/press`    | `mt-cli ui-press`   | Press a control by identifier (allowlisted windows); assert via `state` |
| `GET /v1/watch`     | `mt-cli watch`      | Whether the app is watching for meetings (`WatchStatusDTO`) |
| `POST /v1/watch`    | `mt-cli watch start\|stop\|toggle` | Control watching; returns the resulting `WatchStatusDTO` |
| `GET /v1/record`    | `mt-cli record`     | Whether a microphone-only recording is running (`RecordStatusDTO`) |
| `POST /v1/record`   | `mt-cli record start\|stop\|toggle` | Control microphone recording; returns the resulting `RecordStatusDTO` |

## Build mt-cli

From the repo root:

```bash
cd tools/mt-cli && swift build
.build/debug/mt-cli state | jq .
```

## Failure modes

- **"app is not running on http://127.0.0.1:9876"** → either the dev app
  isn't running, or the toggle / env flag was off when it launched. Ask the
  user to enable Settings → Advanced → Local Automation API, or relaunch with
  `MEETINGTRANSCRIBER_DEBUG_RPC=1 ./scripts/run_app.sh`.
- **"RPC token not found"** → same as above; the token is created on first
  successful start.
- **HTTP 401** → token rotated. Restart the app or delete the token file.
- **HTTP 403 with Origin header** → You're hitting it from a browser. Use curl
  or `mt-cli` instead.

## Security model

Loopback bind (`127.0.0.1` only) + Origin reject + bearer token. Two-layer
defense against browser CSRF and cross-user access on shared Macs. See
`app/MeetingTranscriber/Sources/DebugRPCServer.swift` for the threat model.
