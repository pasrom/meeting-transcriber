---
name: e2e-architecture
description: Reference for the E2E approaches (fixture-based xctest e2e.yml, live-recording e2e-app.yml/e2e-app.sh, browser-meeting e2e-browser.yml incl. the Jitsi variant), the CI trigger labels (run-e2e/run-quality), which to pick, why the live-recording variant exists, and the one-time self-hosted Mac mini runner setup. Read before changing e2e.yml, e2e-app.yml, e2e-browser.yml, scripts/e2e-app.sh, scripts/e2e-browser.sh, the naming-confirm lane, or the runner configuration.
---

# E2E Architecture

Two complementary E2E approaches, run by different workflows. Pick by what
you're validating:

**CI trigger labels:** the heavy self-hosted lanes stay off ordinary PRs (only
`ci.yml` runs there) and otherwise fire post-merge or nightly. Two opt-in PR
labels start them pre-merge, on same-repo branches only (fork PRs never run on
the Mac mini): `run-e2e` gates `e2e.yml`, `e2e-app.yml`, and
`e2e-crash-recovery.yml`; `run-quality` gates `quality-and-safety.yml` (TSan/ASan
plus WER/DER). Apply with `gh pr edit <n> --add-label run-e2e`. Each lane's
job-level `if:` guard checks `head.repo.full_name == github.repository`, so fork
PRs are excluded from the self-hosted runner.

**Fixture-based xctest E2E (`e2e.yml`)**
- Engine + pipeline tests in `app/MeetingTranscriber/Tests/*E2ETests.swift`
  (Parakeet, WhisperKit, WatchLoop) feed pre-recorded `two_speakers_de.wav`
  into the components and assert on transcripts.
- Triggered on `workflow_dispatch`, every push to `main`, and label-gated
  PR runs (apply the `run-e2e` label to a same-repo PR; fork PRs are
  excluded from the self-hosted lanes).
- No live recording — `DualSourceRecorder` is bypassed; tests substitute
  fixture WAVs at the same point the recorder would emit them.
- Strengths: fast, deterministic, isolates engine logic; runs in xctest's
  sandboxed harness without TCC concerns.
- Limitations: can't catch regressions in the recording stack, the audio
  routing path, TCC interactions, or detector → recorder handoff.

**Live-recording E2E (`e2e-app.yml`, `scripts/e2e-app.sh`)**
- Builds the dev `.app`, deploys to `~/Applications/MeetingTranscriber-Dev.app`
  (stable path → TCC permissions persist), launches it, triggers a meeting
  via `meeting-simulator`, polls `DebugRPCServer`'s `/state` for
  `lastJob.state == .done`, asserts on the resulting transcript file.
- Triggered on `workflow_dispatch`, every `push` to main (no paths-filter
  — so the stable-tag ruleset always has a push-event check-run on the
  SHA), a nightly cron at 04:30 UTC, and label-gated PR runs (apply the
  `run-e2e` label; same-repo branches only — fork PRs never execute on
  the self-hosted Mac mini, and a fork run would fail anyway because fork
  runs get no signing secrets and thus no TCC mic grant; to E2E a fork
  contribution, push it to a same-repo branch and label that PR).
- Exercises the production code path end-to-end including TCC, audio
  routing, CATapDescription tap, and the dual-track recorder/diarizer
  handoff.
- The `--naming-escape` lane is the only automated cover for "the user pressed
  Escape on the naming dialog" (issue #577, where Escape used to commit the
  auto-matched names). It parks a job at naming, fronts the app, posts a real
  Escape via System Events, then asserts *both* halves of the fix: the window is
  gone from `/state.windows`, and the job is still `speakerNamingPending` — a
  dismiss, not a Skip. It deliberately does not click into a name field first,
  because the unfocused path is the one the fix nearly shipped broken (the
  dialog binds dismiss twice: `onExitCommand` for the focused case, a
  `.cancelAction` carrier for the rest). Needs the two grants in step 6 below.
- The `--naming-confirm` lane additionally drives the speaker-naming CONFIRM
  path end-to-end (enqueue a 2-speaker fixture, park at naming instead of
  auto-skipping, `POST /v1/jobs/<id>/naming` an anonymous mapping, then assert
  the confirmed names replace the raw diarization labels in the transcript and
  the speaker DB learns the voices); it snapshots + restores the runner's real
  `speakers.json`/`recognition_log.jsonl` (`$GITHUB_ACTIONS`-gated) so the
  confirm never pollutes the persistent speaker DB.
- The `--mic-only` lane (issue #633) records the microphone with no app audio,
  driving `POST /v1/record` instead of a detected meeting, and asserts the
  record-only sidecar carries a mic track, `trigger` is `manual`, and there is
  **no** app track. That last one is the point: nothing else in the suite would
  notice a microphone-only recording quietly opening a process tap. It is the
  only lane that mutates a machine-global setting, pointing the default audio
  output at the loopback for its own duration (see setup step 1 for why), so it
  is also the only one whose teardown can leave the host in a worse state than
  it found it. It restores the device only after re-reading it, keeps its marker
  when a restore fails, and every `e2e-app.sh` invocation heals a dead run's
  marker before any lane can record. A machine left on the loopback would record
  a mic track that is a bit-perfect copy of the app track on every later
  dual-source lane, which no lane asserts against.
- The `--echo-bleed` lane (issue #581) is the odd one out: it records nothing.
  A recording made on loudspeakers carries the remote voices on the microphone
  track too, so the same speech is transcribed twice; the pipeline measures that
  before transcription and reports the verdict on `GET /v1/jobs/<id>`. The Mini
  has no microphone, only a virtual input device, so there is no acoustic path
  to bleed through and the condition cannot be produced live. The driver
  synthesises the audio instead (`scripts/fixtures/make-echo-pair.py`, stdlib
  Python), enqueues each `_app`/`_mic` pair through `POST /v1/jobs` — where
  `PairedRecordingResolver` turns it into one real dual-source job, which the
  lane asserts by requiring exactly one job id back — and reads the verdict off
  the job. **Two pairs, differing by exactly one term:** without the clean
  control the lane would stay green against a detector that answers yes to
  everything, and a false positive here tells a user their recording is broken
  when it is not. The control additionally asserts `windowsScored`, because a
  verdict computed over too few windows says "not affected" for want of
  evidence rather than for want of bleed. Both fixture properties that are not
  obvious — the local side has to be gated into short bursts, and that gate's
  period has to stay under one analysis window — are measured, and the reasoning
  is in the generator's docstring. Touches no settings and needs no grants, but
  it is **not** residue-free: it resolves both jobs with
  `POST /v1/jobs/<id>/naming/skip` so nothing is left parked in the persisted
  job store, and that appends a row to the runner's real
  `recognition_log.jsonl` and leaves two terminal-job records. It does not
  enroll voices — skipping never writes an embedding — so unlike
  `--naming-confirm` there is nothing to snapshot around `speakers.json`.
- The `--echo-cancel` lane is that lane's other half, and the two cannot share a
  run: one needs echo cancellation off to measure the transcript dedup, the
  other needs it on, and under cancellation the dedup stands down by design. So
  the driver rejects the combination rather than resolving it by dispatch order,
  which would run one lane under the other's settings and still report a pass.
  It writes `echoCancellationEnabled` on **every** invocation, not just its own:
  left `true` by an earlier run it would take precedence over the dedup, and the
  `--echo-bleed` lane would fail with the dedup standing down correctly.
  Its pairs carry one term the other lane's do not — a far end that pauses
  (`--app-burst` / `--app-gap`). That is not cosmetic. The canceller's
  self-check is a *difference* between the windows where the far end was playing
  and the windows where it was not, so a fixture whose far end never stops
  offers no control group; the other lane's pair splits its windows 42 to 8
  against a floor of ten on each side, and the run comes back unjudgeable however
  well it went. Gated 2.5 s on / 2.5 s off the same sources split 25 to 25. The
  other lane's pair is left byte-identical, so its calibrated numbers still hold.
  What it asserts: the far end was removed from the microphone audio
  (`echo.removed == true`, read off the FINISHED job so a build that loses the
  flag on the way to the terminal store fails), nothing was *also* stripped from
  the transcript with both switches on, the clean control was never even
  attempted (`removed` absent, which is not `false`), and the local speaker
  survived — measured against the control's own transcript, because a canceller
  that emptied the microphone track passes every other assertion. It also
  asserts the bundled model is in the deployed bundle up front: without it the
  stage correctly reports a missing model and leaves the track as recorded,
  which would read as a broken canceller.
- Limitations: needs one-time runner setup (see below); can't run on
  GitHub-hosted runners — only on a self-hosted Mac with an interactive
  GUI session and a stable code-signing identity.

**Browser-meeting E2E (`e2e-browser.yml`, `scripts/e2e-browser.sh`)**
- Proves the issue #503 chain end-to-end without a real meeting service:
  deploys the dev `.app` (`watchBrowserMeetings` + `recordOnly` + `noMic` +
  RPC, reusing `e2e-app.sh --redeploy-only` for build/sign), opens Chrome with
  the self-contained `scripts/fixtures/webrtc-tone.html` (an in-page pc1↔pc2
  WebRTC loopback carrying a 440 Hz WebAudio tone), then answers the parked
  consent prompt over RPC (`mt-cli confirm-browser-consent`) instead of a
  click, records ~15 s, quits Chrome to end the meeting, and asserts the
  record-only `_app.wav` is non-silent (`mt-cli wav-verdict`).
- The consent prompt normally requires a click; the debug-RPC
  `POST /action/confirmBrowserConsent` resolves the parked
  `ConsentPromptCoordinator` continuation so the whole flow runs headless.
  `askToRecord` parks and blocks the watch loop regardless of notification
  permission, so the RPC resolve works even when notifications are denied.
- Detection uses the sandbox-safe power-assertion path (no Screen Recording),
  so it needs no extra TCC beyond e2e-app's; the only new runner prerequisite
  is Google Chrome installed. No mic (`noMic`).
- The signal the driver polls is `confirm-browser-consent` returning
  `{"resolved":true}` (a prompt has parked) — detection alone can't be read
  from `watchState` (it stays `"watching"` both before detection and while
  deferring for consent). After granting, it polls `watchState == "recording"`.
- NON-GATING canary: reports red but is not a required check and not in
  `tag-ruleset.json`. The assertion-hold (does a loopback PeerConnection hold
  "WebRTC has active PeerConnections") and tap-capture (does the CATap record
  Chrome's shared-audio-service output) are verified live on the mini when the
  lane is first brought up.
- Limitation: like `e2e-app`, self-hosted mini only; the fixture's Chrome
  assertion wording is Chrome-version-dependent (the likeliest flake vector).
- **Real-meeting variant (`--jitsi`, `scripts/fixtures/jitsi-keeper.mjs`):** the
  synthetic fixture is an in-page `pc1↔pc2` loopback, not a real remote meeting.
  `e2e-browser.sh --jitsi` instead drives Chrome via CDP (puppeteer-core) so two
  tabs join a REAL public Jitsi room (`meet.ffmuc.net`, no login — `meet.jit.si`
  requires a moderator login since 2023) — a genuine 2-participant WebRTC SFU
  meeting; each tab's `getUserMedia` is overridden to a 440 Hz WebAudio tone, so
  no real mic is touched (the macOS Chrome **mic-TCC** gate otherwise *hangs*
  `getUserMedia` on a headless runner, and `--use-file-for-fake-audio-capture`
  is buggy on macOS). Verified live on the mini: Chrome holds the assertion
  (detection fires) and the tone flows tab-A → real server → tab-B (`recvPeak`
  ≈ the tone), so the CATap captures real server-transported meeting audio.
  Runs **nightly/dispatch only, never on labeled PRs**, and `continue-on-error`
  (best-effort, depends on a third-party public instance being up — an outage is
  not our regression). Chrome must be installed; `~/Applications` works for a
  runner user without `/Applications` write access, and `node`/`npm` are needed
  (puppeteer-core is `npm i`-installed on demand into `scripts/fixtures`).

**Why the live-recording variant exists** (history that's easy to lose):
- An earlier attempt at xctest-framed live recording (PR #100,
  `E2EFullPipelineTests`) crashed reproducibly with
  `freed pointer was not the last allocation` on the self-hosted Mac mini.
  Root cause: ad-hoc-signed xctest binaries get a fresh cdhash on every
  build, never inherit stable TCC permissions, and AVAudioEngine on a
  no-input host hits a libmalloc abort.
- The production `.app` doesn't have any of those problems because it has
  a stable bundle ID + (with `setup-self-hosted-runner.sh`) a stable
  signing identity whose cert leaf SHA-1 TCC keys its permission grants on,
  so the grants survive rebuilds.

**One-time self-hosted runner setup**:
1. `brew install blackhole-2ch switchaudio-osx` then reboot (or
   `sudo killall coreaudiod`), set BlackHole 2ch as the default Input in
   System Settings → Sound. Mac mini hosts have no built-in mic; without a
   virtual input device the dual-source recorder hits the libmalloc abort path.

   **BlackHole as the input carries no signal on its own**, and that is worth
   knowing before reading a silent mic track as a bug. It is a loopback: its
   input carries exactly what something plays into its *output*, and the default
   output is the speakers, which nothing routes back. Measured 2026-08-18: four
   mic tracks sampled from earlier runs each read -120 dBFS, while the analyzer
   reports -22 dBFS for the shipped fixture. Every lane except `--mic-only` is
   unaffected, because the app track comes from the CATap, which reads process
   output and touches no device at all.

   `switchaudio-osx` is what `--mic-only` uses to point the default output at
   the loopback for its own duration (and to put it back). Only that lane needs
   it, and it preflights for it with this hint, so a runner without it fails
   loudly rather than recording silence.
2. Configure auto-login for the runner user so loginwindow brings up an
   Aqua session at boot. CATapDescription captures silence in non-GUI
   contexts even when API calls return `noErr`.
3. Run `scripts/setup-self-hosted-runner.sh` once. It creates a self-signed
   code-signing cert in a dedicated dev keychain, builds the dev `.app`, signs
   it with that cert, and deploys to `~/Applications/`. It does NOT install a
   configuration profile: macOS ignores a non-MDM-delivered PPPC payload, and
   the MDM/`add-trusted-cert -d` path needs an actual MDM server (unavailable
   here). TCC permissions are instead granted manually, once, and macOS keys
   the grant on the cert leaf SHA-1.
4. In the GUI session, launch the deployed `.app`
   (`open ~/Applications/MeetingTranscriber-Dev.app`). Click "Allow" on the
   Microphone prompt, and toggle the dev `.app` on under System Settings →
   Privacy & Security → Screen & System Audio Recording (used for window-title
   meeting detection — the e2e also has a sandbox-safe power-assertion detector,
   so this one is belt-and-suspenders).
5. Verify Microphone + Screen & System Audio Recording show the dev `.app`
   with the toggle on.
6. Grant **Accessibility** and **Automation** for the `--naming-escape` lane.
   Nothing else needs them, and they are of a different shape than the grants
   above: they key on a *binary path* and a *user account*, not on the app's
   signing cert, so they survive app rebuilds but not a reinstall that moves the
   binary.

   The lane needs them because posting a real key event through the WindowServer
   is the only way to reach SwiftUI's exit command — a synthetic `NSEvent` with
   keycode 53 never gets there, since the translation to `cancelOperation:`
   happens inside `interpretKeyEvents:`, which no responder in that window calls
   unless a name field holds focus.

   **Grant as the runner's own account.** The agent runs as its own user
   (`runner`, `~/runners/<runner-name>/`), which on this host is also the console
   user, and TCC is per-user: granting from the account a person normally uses
   leaves the runner's database untouched, so a hand-run passes while CI keeps
   skipping.

   **The two do not attribute the same way** — the detail that cost the most
   time here. Measured on the mini:

   - **Automation** carried over from a hand-run to CI on its own.
   - **Accessibility** did not. Granting Terminal did not help, nor did granting
     `/usr/bin/osascript`. TCC attributes it to the *responsible* process, which
     for a CI job is the service's top-level binary, so the entry that works is
     the agent's own Node: `~/runners/<runner-name>/externals/node20/bin/node`.
     The listener binary itself cannot be picked — the Accessibility chooser
     greys out bare executables — and launchd starts `runsvc.sh` → node → the
     listener anyway, so node is both the selectable and the correct answer.

   Only the runner carrying the `audio` label serves this workflow, so only that
   one needs the grant. A second runner given that label would need its own node
   binary added, since the grant is per path.

   To raise the prompts by hand, run the lane once in the runner's GUI session:
   `E2E_TCC_PROMPT_TIMEOUT=300 bash scripts/e2e-app.sh --no-build --naming-escape`.
   The env var widens the preflight's probe window from its 10 s CI default so
   the prompt stays up long enough to answer; without it the probe gives up
   first and the prompt goes with it. `tccutil` can only reset, and the MDM/PPPC
   route is unavailable here (see step 3), so a click is unavoidable.

   Until both are in place the lane **skips loudly and passes**, writing cause
   and fix to the step summary. Deliberate: an ungranted host would otherwise
   turn every PR red for a prerequisite unrelated to the change under test, and
   a silent skip would be worse still, since it would read as coverage. The
   tolerance is narrow — only the preflight's two missing-grant arms return
   early; anything failing after them still fails the lane.

After setup, every CI run rebuilds + re-signs the `.app`; the cdhash differs
per build but the cert leaf SHA-1 doesn't, so TCC keeps the manual grant across
rebuilds. The grant keys on the cert of whatever bundle you Allowed — CI
re-signs with the Developer ID cert each run, so make the grant against a
Developer-ID-signed bundle (the state CI leaves at `~/Applications/`).

NOTE: the dev `.app` is **unnotarized** Developer ID (`spctl` reports
"rejected"), and macOS occasionally revokes TCC grants for such apps — observed
2026-06-05: e2e-app went green→red overnight with no reboot, no OS/XProtect
update, and no rebuild, because the Microphone grant was silently dropped and
the headless run then blocked on the consent prompt (first lane fails with
`no new pipeline job within 240s, active=0`). Remedy: re-click "Allow" in the
GUI session. Notarizing the dev build or a real MDM-delivered PPPC profile
would make the grant fully durable; neither is set up.
