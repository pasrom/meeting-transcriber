# Stream Deck, hotkeys and other buttons

Meeting Transcriber watches for meetings on its own, but sometimes you want a
physical control: a Stream Deck key to arm it before a call, a hotkey to stop it
when you switch to something private, a menu bar of your own.

This guide wires that up. Everything here goes through `/v1/watch` in the
[local automation API](automation-api.md) — one endpoint that reports whether the
watch loop is running and turns it on or off.

> **Homebrew build only.** The automation API is compiled out of the App Store
> build, which is sandboxed and cannot host a local server.

## Before you start

Turn the API on: **Settings → Advanced → Local Automation API**. It is off by
default and binds to `127.0.0.1` only.

Enabling it writes a bearer token to
`~/Library/Application Support/MeetingTranscriber/.rpc-token` (mode `0600`).
Everything below reads that file at run time rather than copying the value, so
nothing breaks when the token rotates — which it does every time you switch the
toggle off and back on.

## A Stream Deck plugin, if you want live state

[**Meeting Transcriber for Stream Deck**](https://github.com/alexpfau/meeting-transcriber-streamdeck)
is a plugin that polls `/v1/watch` and repaints the key, so it shows whether
watching is on even when it was turned on from the app. Three actions — toggle,
start, stop.

[Download the latest `.streamDeckPlugin`](https://github.com/alexpfau/meeting-transcriber-streamdeck/releases/latest)
and double-click it. The actions then appear under **Meeting Transcriber** in
the Stream Deck app. It reads the token file itself, so there is no pairing
step and nothing to configure.

Worth knowing before you do: that token is not scoped to watching. It is the
single bearer token for the whole automation server — all of `/v1`, the
`/action/*` UI-driving surface and `/screenshot`, which can capture the app's
windows. Anything that can read the file can do all of it. The plugin helping
itself to the token is the reason it needs no setup, and it is also the thing to
weigh before installing.

It is a separate project rather than part of this repo: it ships on Elgato's
release cadence, not this app's, and nobody without a Stream Deck should have to
download it.

If you would rather not install a plugin, the rest of this guide does the same
job with a Shortcut — minus the live state.

## The simplest thing that works

A Stream Deck key that runs a Shortcut. No plugin, no extra software.

**1. Build the Shortcut.**

In Shortcuts.app, create a new Shortcut named **Start Meeting Watching**
containing a single **Run Shell Script** action (shell `/bin/zsh`) with:

```bash
TOKEN_FILE="$HOME/Library/Application Support/MeetingTranscriber/.rpc-token"
if [ ! -r "$TOKEN_FILE" ]; then
  echo "Meeting Transcriber automation API is off. Enable it in Settings > Advanced." >&2
  exit 1
fi
TOKEN=$(cat "$TOKEN_FILE")
curl -sS --fail-with-body -X POST http://127.0.0.1:9876/v1/watch \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"action":"start"}'
```

The token is read at run time rather than baked in, so the Shortcut keeps
working when the token rotates — which happens every time the API toggle is
switched off and back on.

Then duplicate it as **Stop Meeting Watching** with `"action":"stop"`. Two keys
rather than one is the recommendation of this guide, not an accident — see
[Start and stop beat toggle](#start-and-stop-beat-toggle). If you only have one
key to spare, swap the verb for `toggle` and accept the caveat described there.
Dropping `-X POST` and the `-d` line turns the same call into a status read.

**2. Point a Stream Deck key at it.**

Drag a **System → Website** action onto a key and set:

| Field | Value |
| --- | --- |
| URL | `shortcuts://run-shortcut?name=Start%20Meeting%20Watching` |
| Access in background | ticked |

Repeat for a second key pointing at `Stop%20Meeting%20Watching`.

Leaving "Access in background" unticked opens your browser on every press.
If you renamed the Shortcut, URL-encode the new name (spaces become `%20`).

**3. Press it.**

The first press asks macOS for permission to run the Shortcut; allow it. After
that the key is silent and takes about a second.

## Any other launcher

The Shortcut is only a wrapper. Raycast, Alfred, BetterTouchTool, Keyboard
Maestro, Hammerspoon, a `.zshrc` alias — anything that can run a command can do
this directly:

```bash
TOKEN=$(cat "$HOME/Library/Application Support/MeetingTranscriber/.rpc-token")
curl -sS -X POST http://127.0.0.1:9876/v1/watch \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"action":"toggle"}'
```

If you have the repo checked out, [`mt-cli`](../tools/mt-cli/) is shorter and
finds the token itself:

```bash
mt-cli watch toggle
mt-cli watch status
```

## Start and stop beat toggle

`toggle` is the obvious binding and the worst one, because a button press is a
*wish*, not a delta. Bind a key to `toggle` and its meaning depends on state you
cannot see: if watching stopped on its own — an error, a restart, a meeting that
ended — your "start" press stops nothing and you sit through the next call
unrecorded.

`start` and `stop` say what you want and are idempotent. Pressing `start` twice
is not an error; the second press returns the same 200 with `watching: true`.
Two keys, or one key per Stream Deck profile, will misfire less than one clever
one. Use `toggle` when you genuinely have only one key to spare.

## Reading state back

Every call — `GET` and `POST` alike — returns the state *after* it, so a button
never has to guess or re-fetch:

```json
{ "watching": true, "state": "watching", "badge": "inactive",
  "manualRecording": false, "permissionsHealthy": true }
```

`watching` is the on/off answer. `badge` is what the menu bar icon is showing
(`inactive`, `recording`, `transcribing`, `diarizing`, `processing`,
`userAction`, `done`, `error`, `updateAvailable`) — the field to render if you
want more than a binary light. `permissionsHealthy` is worth surfacing
somewhere: watching can be *on* while a missing permission means nothing is
actually being captured.

Full field reference: [`docs/automation-api.md`](automation-api.md#watchstatusdto).

## What a Shortcut cannot do

**The key cannot show you the current state.** A Shortcut fires and forgets;
nothing polls, so the key's image never changes when the app's state does. The
`Multi Action Switch` action looks like a fix and is a trap — it alternates two
static images by counting presses, so it desynchronises the first time watching
starts or stops without you pressing anything, and then lies.

That is the whole reason the plugin above exists. If you only ever start
watching by pressing the key, a Shortcut is fine. If the app also starts and
stops on its own — which is the point of a watch loop — you want the key to be
told.

## When it does not work

| Symptom | Cause |
| --- | --- |
| `401` | Token rotated, or the API was toggled off and on. Re-read the file — do not cache it. |
| Connection refused | App not running, or **Settings → Advanced → Local Automation API** is off. |
| Token file missing | Same — the file is written when the API starts. |
| `409` | A manual recording from the app picker owns the loop. Stop it in the menu bar first. |
| Browser opens on every press | "Access in background" is unticked on the Website action. |
| Nothing happens, no error | The Shortcut name in the URL does not match, or is not URL-encoded. |

Watching turns on but nothing records? That is a permissions problem rather than
an API one — `permissionsHealthy: false` in the response, and the menu bar icon
carries a red badge. See the README's permissions section.
