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
- You're debugging a UI bug and would otherwise have to ask the user to describe state
- You're verifying a fix end-to-end after editing code

Don't use it for production debugging — RPC is `#if !APPSTORE` only and gated
by the `MEETINGTRANSCRIBER_DEBUG_RPC=1` env var.

## How to enable

The user must launch the dev app with the env flag set:

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

## Build mt-cli

From the repo root:

```bash
cd tools/mt-cli && swift build
.build/debug/mt-cli state | jq .
```

## Failure modes

- **"app is not running on http://127.0.0.1:9876"** → user hasn't launched
  the dev app, or didn't set the env flag. Ask them to run
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
