#!/usr/bin/env bash
# Live-recording E2E driver for the Meeting Transcriber dev app.
#
# Builds the dev .app, deploys it to a stable path so its TCC permissions
# persist across runs, launches it, triggers a synthetic meeting via the
# meeting-simulator tool, polls the DebugRPCServer for the resulting
# pipeline job, and asserts on the transcript output.
#
# This is the production-app E2E path, intentionally separate from the
# fixture-based component E2E tests in `app/MeetingTranscriber/Tests/*E2E*.swift`
# (which run on PR-CI). Rationale and history: see the e2e-architecture skill.
#
# Prerequisites on the runner host (one-time setup):
#   - Xcode at /Applications/Xcode.app (xcode-select pointed there)
#   - GUI session for the runner user (CATapDescription needs a logged-in
#     loginwindow context — service-mode runners get silent audio capture)
#   - A virtual input device (BlackHole 2ch) so AVAudioEngine has something
#     to bind to on Mac mini hosts without a built-in mic
#   - System Settings → Privacy: Microphone + Screen & System Audio Recording
#     granted to ~/Applications/MeetingTranscriber-Dev.app
#   See scripts/setup-self-hosted-runner.sh for the bootstrap flow.

set -euo pipefail

# --- args -----------------------------------------------------------------

APP_AFTER=quit           # quit | leave
SIMULATOR_FIXTURE=""     # custom audio fixture for the simulator
NO_BUILD=false           # skip build/deploy/re-sign — use whatever's at ~/Applications already
TWO_MEETINGS=false       # trigger two back-to-back meetings to validate cooldown + state reset
MIC_ONLY=false           # drive a microphone-only recording over /v1/record and assert its sidecar
RECORD_ONLY=false        # validate record-only mode (sidecar+WAV instead of transcript)
REIMPORT_RECORDED=false  # chain a record-only meeting with re-import via POST /action/enqueueFile
REIMPORT_LATEST=false    # skip live-record phase, re-import the freshest *_mix.wav already on disk
KEEP_RECORDINGS=false    # leave record-only output on disk for a follow-up --reimport-latest run
MIC_DEVICE_CHANGE=false  # build the issue #379 fault-injection seam + assert the app survives it
CRASH_RECOVERY=false     # kill mid-recording + assert the orphan is recovered into the pipeline on relaunch (issue #379 part 3)
REDEPLOY_ONLY=false      # rebuild + redeploy the canonical (non-fault) bundle and exit — restores a clean bundle after --mic-device-change
NAMING_CONFIRM=false     # drive the speaker-naming CONFIRM path end-to-end via POST /v1/jobs/<id>/naming (see run_naming_confirm)
NAMING_ESCAPE=false      # press a real Escape on the naming dialog + assert it dismisses without resolving (issue #577)
NAMING_SWITCH=false      # type into the naming dialog after it moves on to a same-title job with fewer speakers (issue #700, see run_naming_switch)
TITLE_SOURCE=false      # drive the window-title lookup with a no-usable-title case + assert the clean placeholder (issue #501 title source)
ECHO_BLEED=false         # feed a synthesised affected + clean pair through /v1/jobs and assert the echo verdict (see run_echo_bleed)
QUIT_FOREIGN_APP=false   # hand-runs: quit a dev app this driver did not start instead of refusing (see the app-provenance guard)
ECHO_CANCEL=false        # same two pairs with the canceller ON: assert the far end is taken out of the mic audio (see run_echo_cancel)
QUIT_FLUSH=false         # quit with a manual recording running + assert the recording survives as a job (issue #745, see run_quit_flush)
MIC_STALL=""             # stall | stall-after-delivery: withhold the mic's buffers and assert the progress watchdog (see run_mic_stall)
UPGRADE=false            # start the build on the data v0.8.1 leaves behind, in an isolated home (see run_upgrade)
PROTOCOL_LANE=false      # generate the protocol through a local OpenAI-compatible stub and assert request + file (see run_protocol_lane)
PROTOCOL_REPAIR=false    # only finish what a killed --protocol run left on the host, then exit (see _pp_repair)

while [ $# -gt 0 ]; do
    case "$1" in
        --quit-app)         APP_AFTER=quit ;;     # explicit alias for the default
        --keep-app)         APP_AFTER=leave ;;
        --no-build)         NO_BUILD=true ;;
        --fixture)          shift; SIMULATOR_FIXTURE="$1" ;;
        --two-meetings)     TWO_MEETINGS=true ;;
        --mic-only)         MIC_ONLY=true ;;
        --record-only)      RECORD_ONLY=true ;;
        --reimport-recorded) REIMPORT_RECORDED=true ;;
        --reimport-latest)  REIMPORT_LATEST=true ;;
        --keep-recordings)  KEEP_RECORDINGS=true ;;
        --mic-device-change) MIC_DEVICE_CHANGE=true ;;
        --crash-recovery)   CRASH_RECOVERY=true ;;
        --redeploy-only)    REDEPLOY_ONLY=true ;;
        --naming-confirm)   NAMING_CONFIRM=true ;;
        --naming-escape)    NAMING_ESCAPE=true ;;
        --naming-switch)    NAMING_SWITCH=true ;;
        --title-source)     TITLE_SOURCE=true ;;
        --echo-bleed)       ECHO_BLEED=true ;;
        --echo-cancel)      ECHO_CANCEL=true ;;
        --quit-foreign-app) QUIT_FOREIGN_APP=true ;;
        --quit-flush)       QUIT_FLUSH=true ;;
        --mic-stall)        MIC_STALL=stall ;;
        --mic-stall-late)   MIC_STALL=stall-after-delivery ;;
        --upgrade)          UPGRADE=true ;;
        --protocol)         PROTOCOL_LANE=true ;;
        --protocol-repair)  PROTOCOL_REPAIR=true ;;
        -h|--help)
            cat <<'HELP'
Usage: e2e-app.sh [--no-build] [--keep-app] [--two-meetings] [--record-only]
                  [--reimport-recorded | --reimport-latest] [--keep-recordings]
                  [--naming-escape] [--naming-switch] [--echo-bleed] [--echo-cancel]
                  [--naming-confirm] [--quit-flush] [--upgrade] [--protocol]
                  [--fixture path/to.wav]

  --no-build           Skip build/deploy/re-sign; use ~/Applications/MeetingTranscriber-Dev.app as-is.
  --keep-app           Leave the dev app running on exit. Default: quit it.
  --two-meetings       Run two meetings back-to-back (cooldown + state-reset coverage).
  --mic-only           Record the microphone with no app audio (issue #633) via
                       POST /v1/record, and assert the sidecar carries a mic track
                       and NO app track. Reroutes the default OUTPUT to BlackHole
                       2ch for the lane's duration so the loopback input has
                       something to hear, and restores it on any exit. Also
                       the live check of POST /v1/watch's refusal: a start
                       during the manual recording must answer 409 and
                       change nothing.
  --record-only        Enable record-only mode: assert on sidecar JSON + mix WAV instead
                       of transcript/protocol. Exercises the WatchLoop branch that
                       skips VAD/transcription/diarization/protocol generation.
  --reimport-recorded  Chain a record-only meeting with a re-import via the
                       POST /action/enqueueFile RPC: capture audio live, write
                       a WAV, then feed that WAV back in through the "Open from
                       Recording" pipeline and assert the transcript. Covers
                       both the recorder's WAV-encoding correctness and the
                       AudioMixer 3-tier file-load fallback in one pass.
                       Self-contained — no prior run required.
  --reimport-latest    Skip the live-record phase and re-import the freshest
                       *_mix.wav already in ~/Downloads/MeetingTranscriber/recordings/.
                       Pair with a previous `--record-only --keep-recordings`
                       run (CI uses this to chain steps without re-recording;
                       locally also useful for silent fast iteration on the
                       import pipeline).
  --keep-recordings    Suppress the on-exit cleanup of record-only output, so
                       a follow-up --reimport-latest can pick the WAV up.
                       Meaningful with --record-only, and with --quit-flush,
                       where it leaves the jobs' transcripts and audio in place
                       and lists them instead.
  --mic-device-change  Build with the issue #379 fault-injection seam
                       (-DE2E_FAULT_INJECTION) and run one meeting. The app
                       self-triggers a mic device-change restart mid-recording
                       that installs the tap with an invalid format — the
                       condition that raises an uncatchable NSException from
                       installTapOnBus. Asserts the app SURVIVES (no SIGABRT)
                       and the recording still completes. Pre-fix this crashes;
                       the fix must catch + recover. Requires a build (incompatible
                       with --no-build).
  --crash-recovery     Issue #379 part 3: start a meeting, wait until the
                       recorder is writing its raw app temp, then SIGKILL the
                       app mid-recording (no stop() -> the raw _app16k_raw.tmp +
                       unfinalized _mic.wav survive, no _mix.wav). Relaunch and
                       assert the recovered recording enters the pipeline and a
                       job reaches done (the re-mixed _mix.wav is transient — the
                       pipeline consumes it into its workdir within seconds).
                       Pre-fix the launch cleanup deletes the temp -> no
                       recovery (RED); the fix re-mixes + enqueues it (GREEN).
  --redeploy-only      Rebuild + redeploy the canonical (non-fault-injection)
                       bundle to ~/Applications/MeetingTranscriber-Dev.app and
                       exit without launching or running a meeting. Used as an
                       always() cleanup after --mic-device-change to restore a
                       clean bundle (that run leaves a deliberately-crashing
                       fault-injection build deployed). Requires a build
                       (incompatible with --no-build and --mic-device-change).
  --naming-confirm     Drive the speaker-naming CONFIRM path end-to-end. Enqueues
                       the 2-speaker fixture with diarization on and expected
                       speakers = 2 via POST /v1/jobs, waits for the job to park
                       at speaker-naming (does NOT auto-skip like the other
                       lanes), reads GET /v1/jobs/<id>/naming, POSTs an anonymous
                       Speaker A / Speaker B mapping, then asserts the confirmed
                       names land as transcript speaker labels, the raw
                       diarization labels are gone, and the speaker DB learned the
                       voices. Standalone lane (incompatible with the other lane
                       flags). Under CI it snapshots + restores the runner's real
                       speakers.json / recognition_log.jsonl so confirming never
                       pollutes the persistent speaker DB; that snapshot/restore
                       is $GITHUB_ACTIONS-gated, so a LOCAL run enrolls voices
                       into your real speaker DB (a warning is printed).
  --naming-switch      Issue #700: type into the naming dialog after it switches
                       to the next pending job of the same meeting title. Two
                       dual-source pairs are imported with one stem (so both jobs
                       are dual-source and share a title); expected speakers is
                       pinned to 1 so the app track yields exactly one remote (R_)
                       cluster, while the mic tracks cluster into several speakers
                       on the first job and one on the second, which moves the
                       surviving R_ label to a lower row. The lane asserts that
                       geometry, then (with BOTH jobs still pending) switches the
                       dialog's segmented job picker to the second job so the same
                       view is reused, posts real keystrokes into the surviving R_
                       field from outside the process, and asserts the app is
                       still alive, the text landed in that row and nowhere else,
                       and a Confirm enrolls that name into the speaker DB (read
                       over RPC). Pre-fix the first keystroke trapped
                       Array._checkSubscript_mutating and killed the app. Needs
                       the Accessibility grant (see the e2e-architecture skill);
                       without it the lane skips loudly and passes. Standalone
                       lane; ignores --fixture (rejected). Needs python3 + swiftc.
  --title-source       Issue #501: run meeting-simulator with a window title equal
                       to the app name (no usable meeting-window title), then assert
                       the detected meeting title is the clean "MeetingSimulator Call"
                       placeholder — not the raw IOKit assertion name. Fails against
                       the pre-fix detector, so it proves the deployed
                       detection → title-selection chain end-to-end.
  --echo-bleed         Assert the echo-bleed verdict end to end. Synthesises two
                       dual-source pairs from the shipped fixtures — one whose
                       microphone track carries the app track back from the
                       loudspeaker, one clean control differing by exactly that
                       term — enqueues each via POST /v1/jobs, and asserts the
                       verdict on GET /v1/jobs/<id>: detected on the affected
                       pair, present-and-false on the control. The control is
                       what keeps the lane from passing on a detector that says
                       yes to everything. Standalone lane. Needs python3.
                       Leaves two finished jobs and a recognition-log row behind
                       (it skips their naming so nothing stays parked); it never
                       enrolls a voice, so speakers.json is untouched.
  --echo-cancel        The other half of --echo-bleed: run the same two pairs with
                       echo cancellation ON and assert the far end is taken out of
                       the microphone AUDIO rather than out of the transcript after
                       the fact. Asserts removed=true on the affected pair, absent
                       on the control (nobody tried, which is not the same as
                       tried and failed), and zero suppressed segments on the
                       affected pair with the dedup still switched on — that last
                       one is the precedence, not a coincidence. Its pairs carry a
                       far end that pauses, because the canceller's self-check is a
                       difference between the windows where the far end played and
                       the windows where it did not. Standalone lane. Needs python3
                       and the bundled model.
  --quit-flush         Issue #745: quit the app with an AppleScript quit while a
                       manual recording (POST /v1/record) is running, and assert
                       that the recording survives as a job. Read from the
                       pipeline snapshot on disk after the process is gone and
                       before anything relaunches, then from GET /v1/jobs/<id>
                       after a relaunch. Two cycles: one quit, then a second quit
                       sent while the first is held. AppKit either cancels
                       it (-128) or asks the delegate again after the first
                       reply; which one is logged from AppKit's own log, and
                       either way the held quit must end the app exactly once,
                       leave no app or 'log stream' process, and keep the
                       recording. Hand-run only; see the lane header.
                       Does NOT prove that the snapshot flush is what saved the
                       job (a no-op flush stays green) or anything about a
                       logout. Each launch must have exactly one
                       persistent-log `log stream` child, and none may outlive
                       the app. Plays the fixture (afplay) so the microphone
                       hears speech and the jobs finish as done; the lane then
                       skips their naming and removes their transcripts and
                       audio. The dev and the installed build share one data
                       directory, so the lane aborts before changing anything
                       when the live lock ($MT_LIVE_LOCK, default
                       /tmp/mt-live-lock) is held, the installed app is
                       running, or the pipeline queue is not empty; it backs the
                       shared pipeline state up (E2E_QUIT_FLUSH_BACKUP_DIR,
                       default under ~/Library/Caches/MeetingTranscriber-e2e)
                       and restores it on exit: a file that existed is put
                       back byte for byte and one that did not is removed,
                       each only when what changed is this run's records;
                       anything else fails the run. A checksum compare is
                       printed; the backup is removed on a match and kept,
                       with its path, otherwise. The queue check and the
                       backup follow the quit of a running dev app.
                       Standalone lane; incompatible with --keep-app.
  --mic-stall          Issues #724/#706: build with the fault-injection seam, run
                       one ~110 s meeting whose microphone engine starts and runs
                       but whose every buffer is withheld from the handler, and
                       assert the progress watchdog end to end: rebuilds after 3,
                       6, 12 and 24 s without a buffer, the microphone released
                       at 60 s while the app track keeps recording, /state
                       reporting micFault=stalled with micStallCount=1, one
                       "Capture Channel Lost" notification with the stall
                       wording, and the job still finishing with a German
                       transcript from the app track. Runs the app with an
                       isolated home (CFFIXED_USER_HOME, a temp dir removed on
                       exit), so it never reads or writes the host's real
                       MeetingTranscriber data or output folder, and with
                       protocol generation off. Standalone lane.
  --mic-stall-late     Same, but the microphone delivers for its first 10 s and
                       then stops with no configuration change: the shape a
                       one-shot first-buffer check never sees.
  --upgrade            Start this build on what v0.8.1 leaves on disk (a model in
                       Documents/huggingface, an unreadable speakers.json, an
                       interrupted queued job, a finished-job record), in an
                       isolated home removed on exit and with the network closed
                       but for localhost; what it asserts is listed at
                       run_upgrade. Clones the model from E2E_UPGRADE_MODEL_SOURCE
                       (a `huggingface` folder with openai_whisper-small and its
                       tokenizer), by default the account's app model folder,
                       which it only reads. Records nothing, so needs no TCC
                       grant and no audio device. Standalone lane.
  --protocol           Run the protocol stage against a local OpenAI-compatible
                       stub (scripts/fixtures/openai-chat-stub.py on a free
                       127.0.0.1 port) instead of a real model. Imports a short
                       fixture twice via POST /v1/jobs. First with the stub
                       answering: asserts the one chat-completions request it got
                       (model, stream, max_tokens, temperature set and top_p
                       absent, the protocol language in the system prompt, the
                       transcript file as the user message), then the job done with
                       no protocol warning and protocolPath naming a file in the
                       output folder that is the stub's reply plus the
                       transcript. Then with the stub answering HTTP 500:
                       asserts the job done with the "transcript saved" warning,
                       no protocolPath and no protocol file. Changes the host's
                       protocol, OpenAI and diarize/output settings and restores
                       them on exit, or on the next run of this script (or
                       --protocol-repair) when one was killed. Leaves the API
                       key alone: the request carries whatever key the host has,
                       and the stub never logs it. Quits the app on every exit,
                       since it holds those settings in memory, and removes the
                       jobs' transcripts, protocols and sidecars.
                       Outside CI it refuses, changing nothing, while the
                       pipeline queue or the staging folder holds work the
                       launch would send to the stub. Needs python3. Standalone
                       lane; incompatible with --keep-app.
  --protocol-repair    Finish what a killed --protocol run left: quit a running
                       dev app (it may hold the lane's settings), stop a leftover
                       stub, restore the recorded settings, drop the lane's
                       unfinished jobs from the queue snapshot and remove its
                       output files. Exits non-zero when a setting did not come
                       back. A no-op when nothing is left. CI runs it as an
                       always() step after the lane. Outside CI a running dev
                       app is quit only with --quit-foreign-app. Runs nothing
                       else; incompatible with the lane flags.
  --fixture            Audio fixture for meeting-simulator. Default: two_speakers_de.wav.
  --quit-foreign-app   Outside CI the driver refuses to start while a dev app it did
                       not launch is running (someone may be using it). Pass this
                       to quit and relaunch it instead, when you know it is yours.
HELP
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

# --reimport-recorded and --reimport-latest are advertised as alternatives
# in the help text — enforce that here so a typo can't silently fall
# through to whichever branch the dispatch chain checks first.
if [ "$REIMPORT_RECORDED" = true ] && [ "$REIMPORT_LATEST" = true ]; then
    echo "Error: --reimport-recorded and --reimport-latest are mutually exclusive" >&2
    exit 2
fi
# --protocol points the host's protocol provider at a stub for the whole run, so
# any other lane in the same run would send its transcript there, and its own
# settings (diarize off among them) would change what that lane asserts.
if [ "$PROTOCOL_LANE" = true ] && { [ "$NAMING_CONFIRM" = true ] || [ "$NAMING_ESCAPE" = true ] \
    || [ "$NAMING_SWITCH" = true ] || [ "$RECORD_ONLY" = true ] || [ "$REIMPORT_RECORDED" = true ] \
    || [ "$REIMPORT_LATEST" = true ] || [ "$MIC_DEVICE_CHANGE" = true ] || [ "$CRASH_RECOVERY" = true ] \
    || [ "$REDEPLOY_ONLY" = true ] || [ "$TWO_MEETINGS" = true ] || [ "$MIC_ONLY" = true ] \
    || [ "$TITLE_SOURCE" = true ] || [ "$ECHO_BLEED" = true ] || [ "$ECHO_CANCEL" = true ] \
    || [ "$QUIT_FLUSH" = true ] || [ -n "$MIC_STALL" ] || [ "$UPGRADE" = true ] \
    || [ -n "$SIMULATOR_FIXTURE" ]; }; then
    echo "Error: --protocol is a standalone lane; incompatible with the other lane flags and --fixture" >&2
    exit 2
fi
if [ "$PROTOCOL_REPAIR" = true ] && { [ "$PROTOCOL_LANE" = true ] || [ "$NAMING_CONFIRM" = true ] \
    || [ "$NAMING_ESCAPE" = true ] || [ "$NAMING_SWITCH" = true ] || [ "$RECORD_ONLY" = true ] \
    || [ "$REIMPORT_RECORDED" = true ] || [ "$REIMPORT_LATEST" = true ] || [ "$MIC_DEVICE_CHANGE" = true ] \
    || [ "$CRASH_RECOVERY" = true ] || [ "$REDEPLOY_ONLY" = true ] || [ "$TWO_MEETINGS" = true ] \
    || [ "$MIC_ONLY" = true ] || [ "$TITLE_SOURCE" = true ] || [ "$ECHO_BLEED" = true ] \
    || [ "$ECHO_CANCEL" = true ] || [ "$QUIT_FLUSH" = true ] || [ -n "$MIC_STALL" ] \
    || [ "$UPGRADE" = true ] || [ -n "$SIMULATOR_FIXTURE" ]; }; then
    echo "Error: --protocol-repair runs nothing but the repair; incompatible with the lane flags and --fixture" >&2
    exit 2
fi
if [ "$PROTOCOL_LANE" = true ] && [ "$APP_AFTER" = leave ]; then
    echo "Error: --protocol quits the app on exit, which holds the lane's settings in memory; incompatible with --keep-app" >&2
    exit 2
fi

# --naming-confirm is a standalone lane (its own enqueue + poll + confirm flow).
# Reject combinations up-front so a typo can't silently fall through to another
# lane's branch in the dispatch chain below.
if [ "$NAMING_ESCAPE" = true ] && { [ "$NAMING_CONFIRM" = true ] || [ "$RECORD_ONLY" = true ] \
    || [ "$REIMPORT_RECORDED" = true ] || [ "$REIMPORT_LATEST" = true ] || [ "$MIC_DEVICE_CHANGE" = true ] \
    || [ "$CRASH_RECOVERY" = true ] || [ "$REDEPLOY_ONLY" = true ] || [ "$TWO_MEETINGS" = true ]; }; then
    echo "Error: --naming-escape is a standalone lane; incompatible with the other lane flags" >&2
    exit 2
fi
if [ "$NAMING_CONFIRM" = true ] && { [ "$RECORD_ONLY" = true ] || [ "$REIMPORT_RECORDED" = true ] \
    || [ "$REIMPORT_LATEST" = true ] || [ "$MIC_DEVICE_CHANGE" = true ] || [ "$CRASH_RECOVERY" = true ] \
    || [ "$REDEPLOY_ONLY" = true ] || [ "$TWO_MEETINGS" = true ]; }; then
    echo "Error: --naming-confirm is a standalone lane; incompatible with the other lane flags" >&2
    exit 2
fi
# --naming-switch imports its own pairs and drives the dialog from outside the
# process; nothing it does can share a run with a meeting lane, and the pinned
# expected-speakers setting it needs would silently change what the other
# naming lanes measure.
if [ "$NAMING_SWITCH" = true ] && { [ "$NAMING_CONFIRM" = true ] || [ "$NAMING_ESCAPE" = true ] \
    || [ "$RECORD_ONLY" = true ] || [ "$REIMPORT_RECORDED" = true ] || [ "$REIMPORT_LATEST" = true ] \
    || [ "$MIC_DEVICE_CHANGE" = true ] || [ "$CRASH_RECOVERY" = true ] || [ "$REDEPLOY_ONLY" = true ] \
    || [ "$TWO_MEETINGS" = true ] || [ "$MIC_ONLY" = true ] || [ "$TITLE_SOURCE" = true ] \
    || [ "$ECHO_BLEED" = true ] || [ "$ECHO_CANCEL" = true ] || [ -n "$SIMULATOR_FIXTURE" ]; }; then
    echo "Error: --naming-switch is a standalone lane; incompatible with the other lane flags and --fixture" >&2
    exit 2
fi
# --naming-confirm always enqueues the known 2-speaker fixture, so a custom
# --fixture would be silently ignored. Reject the combination rather than
# mislead. (SIMULATOR_FIXTURE is only non-empty here when --fixture was passed;
# it defaults to the 2-speaker fixture further below.)
if [ "$NAMING_CONFIRM" = true ] && [ -n "$SIMULATOR_FIXTURE" ]; then
    echo "Error: --naming-confirm ignores --fixture (it always uses the 2-speaker fixture)" >&2
    exit 2
fi
# --quit-flush quits and relaunches the app itself, twice; any other lane in the
# same run would have its app quit under it.
if [ "$QUIT_FLUSH" = true ] && { [ "$RECORD_ONLY" = true ] || [ "$NAMING_CONFIRM" = true ] \
    || [ "$NAMING_ESCAPE" = true ] || [ "$NAMING_SWITCH" = true ] || [ "$REIMPORT_RECORDED" = true ] \
    || [ "$REIMPORT_LATEST" = true ] || [ "$MIC_DEVICE_CHANGE" = true ] || [ "$CRASH_RECOVERY" = true ] \
    || [ "$REDEPLOY_ONLY" = true ] || [ "$TWO_MEETINGS" = true ] || [ "$MIC_ONLY" = true ] \
    || [ "$TITLE_SOURCE" = true ] || [ "$ECHO_BLEED" = true ] || [ "$ECHO_CANCEL" = true ]; }; then
    echo "Error: --quit-flush is a standalone lane; incompatible with the other lane flags" >&2
    exit 2
fi
# It restores the shared pipeline state on exit, which needs the app stopped.
if [ "$QUIT_FLUSH" = true ] && [ "$APP_AFTER" = leave ]; then
    echo "Error: --quit-flush restores the shared pipeline state on exit and quits the app for it; incompatible with --keep-app" >&2
    exit 2
fi
# --mic-only drives its own recording over /v1/record and reroutes the machine's
# audio output; sharing a run with a meeting lane would have the detector start a
# second recording next to it.
if [ "$MIC_ONLY" = true ] && { [ "$RECORD_ONLY" = true ] || [ "$NAMING_CONFIRM" = true ] \
    || [ "$NAMING_ESCAPE" = true ] || [ "$REIMPORT_RECORDED" = true ] || [ "$REIMPORT_LATEST" = true ] \
    || [ "$MIC_DEVICE_CHANGE" = true ] || [ "$CRASH_RECOVERY" = true ] || [ "$REDEPLOY_ONLY" = true ] \
    || [ "$TWO_MEETINGS" = true ] || [ "$ECHO_BLEED" = true ] || [ "$ECHO_CANCEL" = true ] \
    || [ "$TITLE_SOURCE" = true ]; }; then
    echo "Error: --mic-only is a standalone lane; incompatible with the other lane flags" >&2
    exit 2
fi
# --echo-bleed builds its own audio from the shipped fixtures and never records,
# so it shares nothing with the meeting lanes and would only mask a typo. The
# --echo-cancel term below is where the two echo lanes are kept apart: they are
# the same audio under opposite settings, one needing cancellation off to
# measure the dedup and the other needing it on, so a shared run could only
# measure one of them and would still report a pass.
if [ "$ECHO_BLEED" = true ] && { [ "$NAMING_CONFIRM" = true ] || [ "$NAMING_ESCAPE" = true ] \
    || [ "$RECORD_ONLY" = true ] || [ "$REIMPORT_RECORDED" = true ] || [ "$REIMPORT_LATEST" = true ] \
    || [ "$MIC_DEVICE_CHANGE" = true ] || [ "$CRASH_RECOVERY" = true ] || [ "$REDEPLOY_ONLY" = true ] \
    || [ "$TWO_MEETINGS" = true ] || [ "$TITLE_SOURCE" = true ] || [ "$ECHO_CANCEL" = true ] \
    || [ -n "$SIMULATOR_FIXTURE" ]; }; then
    echo "Error: --echo-bleed is a standalone lane; incompatible with the other lane flags and --fixture" >&2
    exit 2
fi
# Same reasoning as --echo-bleed above, which is also where their mutual
# exclusion is enforced.
if [ "$ECHO_CANCEL" = true ] && { [ "$NAMING_CONFIRM" = true ] || [ "$NAMING_ESCAPE" = true ] \
    || [ "$RECORD_ONLY" = true ] || [ "$REIMPORT_RECORDED" = true ] || [ "$REIMPORT_LATEST" = true ] \
    || [ "$MIC_DEVICE_CHANGE" = true ] || [ "$CRASH_RECOVERY" = true ] || [ "$REDEPLOY_ONLY" = true ] \
    || [ "$TWO_MEETINGS" = true ] || [ "$TITLE_SOURCE" = true ] \
    || [ -n "$SIMULATOR_FIXTURE" ]; }; then
    echo "Error: --echo-cancel is a standalone lane; incompatible with the other lane flags and --fixture" >&2
    exit 2
fi

# --mic-stall records its own long meeting with its own fault, home and
# settings; sharing a run with another lane would put that lane's recording
# under a withheld microphone or run this one against the host's real data.
# This is also where it is kept apart from --quit-flush, whose own check does
# not name it: that lane backs up, asserts on and restores the host's real
# pipeline state, which an app running in this lane's temp home never writes.
if [ -n "$MIC_STALL" ] && { [ "$NAMING_CONFIRM" = true ] || [ "$NAMING_ESCAPE" = true ] \
    || [ "$NAMING_SWITCH" = true ] || [ "$RECORD_ONLY" = true ] || [ "$REIMPORT_RECORDED" = true ] \
    || [ "$REIMPORT_LATEST" = true ] || [ "$MIC_DEVICE_CHANGE" = true ] || [ "$CRASH_RECOVERY" = true ] \
    || [ "$REDEPLOY_ONLY" = true ] || [ "$TWO_MEETINGS" = true ] || [ "$MIC_ONLY" = true ] \
    || [ "$TITLE_SOURCE" = true ] || [ "$ECHO_BLEED" = true ] || [ "$ECHO_CANCEL" = true ] \
    || [ "$QUIT_FLUSH" = true ] || [ -n "$SIMULATOR_FIXTURE" ]; }; then
    echo "Error: --mic-stall/--mic-stall-late is a standalone lane; incompatible with the other lane flags and --fixture" >&2
    exit 2
fi
# --upgrade launches its own app in its own home, with its own settings and the
# network closed; any other lane in the same run would run against that home or
# without network, and --keep-app would leave an app writing into a home the
# lane removes.
if [ "$UPGRADE" = true ] && { [ "$NAMING_CONFIRM" = true ] || [ "$NAMING_ESCAPE" = true ] \
    || [ "$NAMING_SWITCH" = true ] || [ "$RECORD_ONLY" = true ] || [ "$REIMPORT_RECORDED" = true ] \
    || [ "$REIMPORT_LATEST" = true ] || [ "$MIC_DEVICE_CHANGE" = true ] || [ "$CRASH_RECOVERY" = true ] \
    || [ "$REDEPLOY_ONLY" = true ] || [ "$TWO_MEETINGS" = true ] || [ "$MIC_ONLY" = true ] \
    || [ "$TITLE_SOURCE" = true ] || [ "$ECHO_BLEED" = true ] || [ "$ECHO_CANCEL" = true ] \
    || [ "$QUIT_FLUSH" = true ] || [ -n "$MIC_STALL" ] || [ -n "$SIMULATOR_FIXTURE" ] \
    || [ "$APP_AFTER" = leave ]; }; then
    echo "Error: --upgrade is a standalone lane; incompatible with the other lane flags, --fixture and --keep-app" >&2
    exit 2
fi

# --mic-device-change needs the fault-injection seam compiled in, so it must
# build — `defaults`/runtime flags can't add the -DE2E_FAULT_INJECTION code.
if [ "$MIC_DEVICE_CHANGE" = true ] && [ "$NO_BUILD" = true ]; then
    echo "Error: --mic-device-change requires a build; incompatible with --no-build" >&2
    exit 2
fi
# --redeploy-only rebuilds the canonical bundle, so it must build (not --no-build)
# and must NOT carry the fault-injection seam it exists to clean up.
if [ "$REDEPLOY_ONLY" = true ] && [ "$NO_BUILD" = true ]; then
    echo "Error: --redeploy-only rebuilds the bundle; incompatible with --no-build" >&2
    exit 2
fi
if [ "$REDEPLOY_ONLY" = true ] && [ "$MIC_DEVICE_CHANGE" = true ]; then
    echo "Error: --redeploy-only restores the canonical bundle; incompatible with --mic-device-change" >&2
    exit 2
fi
# Export before the build step below so run_app.sh adds -DE2E_FAULT_INJECTION.
# --mic-stall may run --no-build against a fault build already deployed; the
# preflight checks that the deployed bundle really is one.
if [ "$MIC_DEVICE_CHANGE" = true ] || [ -n "$MIC_STALL" ]; then
    export MTT_FAULT_INJECTION=1
fi

# --reimport-recorded chains a record-only meeting with a follow-up
# enqueueFile RPC. Phase 1 needs the recordOnly toggle on so WatchLoop
# writes a WAV instead of running the pipeline — flip it on implicitly
# rather than requiring callers to pass both flags.
if [ "$REIMPORT_RECORDED" = true ]; then
    RECORD_ONLY=true
fi

# --- paths ----------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEV_BUNDLE_BUILD="$ROOT/app/MeetingTranscriber/.build/MeetingTranscriber-Dev.app"
DEV_BUNDLE_DEPLOY="$HOME/Applications/MeetingTranscriber-Dev.app"
SIMULATOR_PKG="$ROOT/tools/meeting-simulator"
SIMULATOR_BIN="$SIMULATOR_PKG/.build/release/meeting-simulator"
MTCLI_PKG="$ROOT/tools/mt-cli"
MTCLI="$MTCLI_PKG/.build/release/mt-cli"
DEFAULT_FIXTURE="$ROOT/app/MeetingTranscriber/Tests/Fixtures/two_speakers_de.wav"

# The home the APP sees. The host's own for every lane but --mic-stall, which
# launches the app with CFFIXED_USER_HOME pointing at a temp dir of its own:
# Foundation resolves Application Support and Downloads from it, so the app's
# data dir (token, queue snapshot, speaker DB, staging recordings) and its
# default output folder all land in that dir, and the host's real ones are
# neither read (no orphan recovery of real recordings, no matching against a
# real speaker DB) nor written. UserDefaults are NOT redirected by it (cfprefsd
# ignores the variable), which is why the dev bundle's own domain still carries
# the lane's settings. Every path below that the app owns derives from this.
APP_HOME="$HOME"
# Where the mic-stall lane keeps what must outlive one run: the host's protocol
# provider as it was before the lane switched it off, the homes a failed run
# had to leave behind, and the provenance marker of the app it launched. Not
# the throwaway home, which the next run never sees, and not $TMPDIR, which a
# reboot clears.
_MS_STATE_DIR="$HOME/Library/Caches/MeetingTranscriber-e2e"
_MS_PROTOCOL_RECORD="$_MS_STATE_DIR/mic-stall-protocolProvider"
_MS_KEPT_HOMES="$_MS_STATE_DIR/mic-stall-kept-homes"
# The mic-stall lane's cleanup, armed as soon as the lane has made anything of
# its own and run again by on_exit; every step is idempotent (the helpers are in
# lib/e2e-helpers.sh, tested by scripts/tests/test_mic_stall_lane_helpers.sh):
#   - protocolProvider back from the record written right before the lane's
#     write, only while it still reads `none`, verified, the record kept if
#     the restore did not land. A run killed before it got here leaves the
#     record, and the next run of any lane of this script repairs it (below,
#     at its start).
#   - its own home, unless the app it launched still runs: a failed run leaves
#     it up and writing there. Then the home is listed for a later run to
#     remove once that app is gone.
_ms_cleanup() {
    declare -F mic_stall_restore_protocol >/dev/null || return 0
    mic_stall_restore_protocol "$DEV_BUNDLE_ID" "$(dev_container_plist)" "$_MS_PROTOCOL_RECORD" none || true
    local pid="${_launched_app:-}"
    [ -n "$pid" ] || pid="$( { pgrep -f "MeetingTranscriber-Dev.app/Contents/MacOS/MeetingTranscriber" || true; } | head -1)"
    mic_stall_release_home "$APP_HOME" "$pid" "$_MS_KEPT_HOMES"
}
if [ -n "$MIC_STALL" ]; then
    # No trailing slash on the parent: the app reports its paths normalised, and
    # the output-folder check below compares strings.
    _app_home_parent="${TMPDIR:-/tmp}"
    APP_HOME="$(mktemp -d "${_app_home_parent%/}/e2e-mic-stall-home.XXXXXX")"
    trap '_ms_cleanup' EXIT
    mkdir -p "$APP_HOME/Library/Application Support" "$APP_HOME/Downloads"
    # The ASR and diarizer models are a multi-gigabyte cache, not user data;
    # link the host's copy rather than download it into a throwaway home.
    # rm -rf on APP_HOME removes the link, never what it points at.
    [ -d "$HOME/Library/Application Support/FluidAudio" ] \
        && ln -s "$HOME/Library/Application Support/FluidAudio" "$APP_HOME/Library/Application Support/FluidAudio"
fi
# The upgrade lane's home: a temp dir of its own like the mic-stall lane's, but
# seeded with what v0.8.1 leaves behind rather than empty, and with no link to
# the host's model caches, because the WhisperKit model is the thing under test
# and the lane switches diarization and VAD off so no other model is needed.
# `_ug_cleanup` (armed here, run again by on_exit) quits the app this lane
# launched, since nothing else of value runs in that home, and then removes the
# home, unless the app could not be stopped. Keyed on the pid `_ug_launch`
# records at once, not on the readiness poll's record, so a launch whose RPC
# never came up is stopped too; a run that never launched leaves any running
# dev app alone, since that one is not writing into this home.
_UG_HOME_STEM=e2e-upgrade-home
_ug_cleanup() {
    [ -n "${_UG_HOME_PARENT:-}" ] && declare -F e2e_is_lane_home >/dev/null || return 0
    e2e_is_lane_home "$APP_HOME" "$_UG_HOME_STEM" "$_UG_HOME_PARENT" || return 0
    # Status 2 is "gone, ended by signal" (see quit_running_app): the home can
    # go then, nothing writes there any more.
    local quit_status=0
    if [ -n "${_UG_APP_PID:-}" ] && kill -0 "$_UG_APP_PID" 2>/dev/null; then
        quit_running_app || quit_status=$?
    fi
    if [ "$quit_status" -eq 1 ]; then
        printf '[e2e-app] [upgrade] the app could not be stopped; leaving its home %s\n' "$APP_HOME" >&2
        return 0
    fi
    rm -rf "${APP_HOME:?}"
}
if [ "$UPGRADE" = true ]; then
    _UG_HOME_PARENT="${TMPDIR:-/tmp}"
    _UG_HOME_PARENT="${_UG_HOME_PARENT%/}"   # the app reports its paths without it
    APP_HOME="$(mktemp -d "$_UG_HOME_PARENT/$_UG_HOME_STEM.XXXXXX")"
    trap '_ug_cleanup' EXIT
    mkdir -p "$APP_HOME/Library/Application Support" "$APP_HOME/Documents" "$APP_HOME/Downloads"
fi
# The protocol lane's state. What has to outlive a killed run sits in the same
# directory as the mic-stall lane's records, so the repair at the start of every
# later run (and the workflow's always-run step, --protocol-repair) can finish
# what a killed run left: the settings it overrides as they were before, the ids
# of the jobs it enqueued, and the files those jobs wrote into the host's output
# folder.
#
# The lane does not touch the API key. The app reads it from the Keychain, and
# a lane-owned item would mean editing the user keychain search list, which is
# shared with the second runner and with an installed app on the same host. So
# the request carries whatever key the host has configured, the stub never logs
# it, and where the key goes is covered by OpenAIProtocolGeneratorTests.
# The deployed dev app's process, for every pgrep in this script (here because
# the protocol helpers below need it before the preflight runs).
_DEV_APP_PATTERN="MeetingTranscriber-Dev.app/Contents/MacOS/MeetingTranscriber"
_PP_RECORD="$_MS_STATE_DIR/protocol-lane-defaults"
_PP_JOBS_RECORD="$_MS_STATE_DIR/protocol-lane-jobs"
_PP_OUTPUTS_RECORD="$_MS_STATE_DIR/protocol-lane-outputs"
# The host's own data and output folders, not $APP_HOME's: the lane never runs
# in an isolated home, and the repair runs from every lane, --mic-stall and
# --upgrade (whose $APP_HOME is a temp dir) included.
_PP_HOST_SNAPSHOT="$HOME/Library/Application Support/MeetingTranscriber/ipc/pipeline_queue.json"
_PP_HOST_OUTPUT_DIR="$HOME/Downloads/MeetingTranscriber"
_PP_KEYS=(protocolProvider protocolLanguage openAIEndpoint openAIModel openAITemperature openAITopP
    diarize saveRawTranscriptSeparately includeFullTranscriptInProtocol useAITitleForFilenames)
_PP_MODEL="e2e-stub-model"
_PP_LANGUAGE="French"
_PP_TEMPERATURE=0.5   # exactly representable, so the JSON number compares exactly
_PP_REPLY=$'# Meeting Protocol - E2E Stub Reply\n\n## Summary\nCanned protocol from the e2e chat-completions stub.'
_PP_DIR=""
_PP_STUB_PID=""

# Finish what the lane left on the host: its settings, its unfinished jobs in
# the queue snapshot, its output files. Idempotent, and every step keeps its own
# record until it is done, so a later run retries only what is left. Returns 1
# when a setting did not come back.
#
# The jobs are dropped by id, and only while no MeetingTranscriber runs at all
# (the installed app shares the snapshot and could save it between the read and
# the rename): a quit saves a job still in flight into the snapshot, and the
# host's next launch would resume it under the host's own settings from a
# fixture copy that no longer exists. Finished ones are left; the app discards
# them at load. While any MeetingTranscriber runs they cannot be dropped, and
# the next dev launch would resume them, so that is a failure too. The output
# files are removed only inside the output folder. A killed run's stub is
# matched by the lane's own temp-dir argument, which no other stub (the helper
# test's, for one) carries.
_pp_repair() {
    local status=0 snapshot="$_PP_HOST_SNAPSHOT" ids f
    pkill -f "openai-chat-stub.py --port-file /tmp/e2e-protocol\." 2>/dev/null || true
    if [ -f "$_PP_RECORD" ]; then
        if defaults_restore_record "$_PP_RECORD"; then
            printf '[e2e-app] [protocol] protocol settings restored to the values before the lane\n'
        else
            printf '[e2e-app] WARNING: [protocol] some protocol settings were not restored; %s keeps them for the next run\n' "$_PP_RECORD" >&2
            status=1
        fi
    fi
    if [ -f "$_PP_JOBS_RECORD" ] && { pgrep -f "$_DEV_APP_PATTERN" >/dev/null 2>&1 || [ -n "$(non_dev_meetingtranscriber_pids)" ]; }; then
        printf '[e2e-app] WARNING: [protocol] a MeetingTranscriber is running, so the lane jobs a killed run left (%s) cannot be dropped from the queue snapshot; quit it and rerun\n' "$_PP_JOBS_RECORD" >&2
        status=1
    elif [ -f "$_PP_JOBS_RECORD" ]; then
        ids="$(jq -R 'ascii_downcase' "$_PP_JOBS_RECORD" | jq -s -c .)"
        if [ ! -f "$snapshot" ]; then
            rm -f "$_PP_JOBS_RECORD"
        elif jq --argjson ids "$ids" \
            'if type == "array" then map(select(((.id // "") | ascii_downcase) as $id
                | ($ids | index($id)) == null or .state == "done" or .state == "error")) else . end' \
            "$snapshot" >"$snapshot.e2e-tmp" 2>/dev/null && mv "$snapshot.e2e-tmp" "$snapshot"; then
            rm -f "$_PP_JOBS_RECORD"
        else
            rm -f "$snapshot.e2e-tmp"
            printf '[e2e-app] WARNING: [protocol] could not drop the lane jobs from %s; kept %s\n' "$snapshot" "$_PP_JOBS_RECORD" >&2
        fi
    fi
    if [ -f "$_PP_OUTPUTS_RECORD" ]; then
        while IFS= read -r f; do
            case "$f" in
                "$_PP_HOST_OUTPUT_DIR"/*) [ -f "$f" ] && rm -f "$f" && printf '[e2e-app] [protocol] removed %s\n' "$f" ;;
            esac
        done <"$_PP_OUTPUTS_RECORD"
        rm -f "$_PP_OUTPUTS_RECORD"
    fi
    return "$status"
}

# Undo everything the protocol lane changed; idempotent, so the early trap and
# on_exit can both run it. Returns 1 when the host's settings could not be put
# back, which on_exit turns into a red run.
#
# The fast steps first and with INT/TERM ignored: a second signal during the
# slow quit would otherwise end on_exit early (it runs once) with nothing
# restored. Then any dev app that is still running: every other one was quit
# before this lane launched, and it holds the lane's settings in memory (a stub
# endpoint, diarize off), so left running after a failure it would process the
# host's next meeting with them, after the restore on disk had already read back
# clean. Stopping it also means no lane job can write a file after the removal.
_pp_cleanup() {
    local status=0
    trap '' INT TERM
    if [ -n "$_PP_STUB_PID" ]; then
        kill "$_PP_STUB_PID" 2>/dev/null || true
        wait "$_PP_STUB_PID" 2>/dev/null || true
        _PP_STUB_PID=""
    fi
    rm -f "$_PP_RECORD.tmp"
    if [ -f "$_PP_RECORD" ]; then
        defaults_restore_record "$_PP_RECORD" || status=1
    fi
    if pgrep -f "$_DEV_APP_PATTERN" >/dev/null 2>&1; then
        quit_running_app \
            || printf '[e2e-app] WARNING: [protocol] the dev app could not be stopped; it still holds the lane settings in memory\n' >&2
    fi
    _pp_repair || status=1
    if [ -n "$_PP_DIR" ] && [ -d "$_PP_DIR" ]; then
        rm -rf "$_PP_DIR"
        _PP_DIR=""
    fi
    return "$status"
}

RPC_TOKEN_FILE="$APP_HOME/Library/Application Support/MeetingTranscriber/.rpc-token"
RPC_BASE="http://127.0.0.1:9876"

# The app's output folder — `AppPaths.downloadsProtocolsDir`. Unsandboxed
# (Homebrew variant) so this is a real path, not a container-mapped one.
# Recordings and protocols are SIBLINGS under it: audio and its sidecar go to
# `recordings/`, transcripts and protocols to `protocols/`. Derive both from
# one root so an assertion cannot end up pointed at the wrong sibling.
OUTPUT_DIR="$APP_HOME/Downloads/MeetingTranscriber"
RECORDINGS_DIR="$OUTPUT_DIR/recordings"
# `find -newer` marker so cleanup only touches THIS run's files — never
# pre-existing user data.
RECORD_ONLY_MARKER="/tmp/e2e-app-record-only-marker.$$"

[ -n "$SIMULATOR_FIXTURE" ] || SIMULATOR_FIXTURE="$DEFAULT_FIXTURE"

# Content-assertion keywords for the default two_speakers_de fixture. The
# `run_one_meeting` transcript check greps for these German content words so a
# live-recorded run can't go green on a >100-byte GARBAGE transcript: an empty
# file, a wrong-language hallucination, or silent-capture noise all clear the
# size check but hit zero of these. This list is identical to the xctest E2E's
# `expectedKeywords` (ParakeetE2ETests.swift / WhisperKitE2ETests.swift) and
# must stay in sync with them if the fixture is regenerated. The fixture also
# speaks "Meeting", but neither this list nor the xctest set includes it: it is
# the one English word, so requiring only German words proves the German
# fixture actually transcribed rather than an English hallucination.
# The check itself lives in lib/e2e-helpers.sh as `transcript_is_german` and
# keys on common German words, NOT on the fixture's script. Recording starts
# only once the app has DETECTED the meeting, so the opening seconds are never
# captured and which sentences land shifts run to run; a script-derived list
# therefore measured recording-start timing, not transcription quality.
# Applied only when the simulator plays the known fixture (and not the
# mic-device-change survival lane); a custom --fixture keeps only the
# >100-byte size check.
IS_DEFAULT_FIXTURE=false
[ "$SIMULATOR_FIXTURE" = "$DEFAULT_FIXTURE" ] && IS_DEFAULT_FIXTURE=true

# --- timing budgets -------------------------------------------------------

# Cold first run downloads ~50 MB Parakeet model — give it room. Hot run
# under 10 s easily.
RPC_READY_TIMEOUT_S=30
PIPELINE_TIMEOUT_S=240

# Record-only skips the whole pipeline, so the budget is just: detector
# notices the simulator stopped (~1 s poll) + endGrace (≥1 s) + recorder
# finalize (~3 s) + sidecar write (instant). 60 s gives ample buffer.
RECORD_ONLY_DEADLINE_S=60

# wav-verdict calibration, shared by every lane that asserts a track carries
# signal. The threshold is the analyzer's own silence floor; the active-seconds
# floor is what separates a real capture from a "one second then silence"
# wedge, so it is set against the fixture's measured content (two_speakers_de.wav
# is 49.8 s long and carries 37.5 s above the threshold) rather than at a token
# value that any partial capture would clear.
WAV_VERDICT_THRESHOLD_DBFS=-50
WAV_VERDICT_MIN_ACTIVE_S=3
WAV_VERDICT_FIXTURE_MIN_ACTIVE_S=25

# Sidecar write completes before the recorder's async tail bytes do — give
# the WAV's AVAudioFile close a moment before re-feeding it to the engine.
# Observed worst case on Mini is ~1 s; 2 s is honest margin.
RECORDER_FINALIZE_WAIT_S=2

# WatchLoop's per-app cooldown (`MeetingDetector.swift` cooldownDuration
# = 5 s) plus a 3 s buffer so the second meeting isn't suppressed as a
# re-detection. Bump if MeetingDetector.cooldownDuration grows.
INTER_MEETING_COOLDOWN_S=8

# --- helpers --------------------------------------------------------------

log()  { printf '[e2e-app] %s\n' "$*"; }
fail() { printf '[e2e-app] FAIL: %s\n' "$*" >&2; exit 1; }

# shellcheck source=lib/e2e-helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/e2e-helpers.sh"
# Ends what a timed-out earlier step left running, then records this
# driver for the next (see e2e_register_driver).
e2e_register_driver
# For LOCALVQE_RESOURCE_GLOB, so the echo-cancellation lane's bundle check and
# the install it checks for agree on what a model file looks like.
# shellcheck source=lib/localvqe-resources.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/localvqe-resources.sh"
# The v0.8.1 on-disk shapes and folder fingerprints the upgrade lane seeds and
# compares with.
# shellcheck source=lib/upgrade-seed.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/upgrade-seed.sh"

# --protocol-repair: nothing else of this script runs. The dev app goes first,
# since a running one holds the lane's settings and is what would keep a job in
# flight; any dev app here is a leftover (CI runs this right after the lane).
if [ "$PROTOCOL_REPAIR" = true ]; then
    if pgrep -f "$_DEV_APP_PATTERN" >/dev/null 2>&1; then
        # In CI it is the lane's own leftover; anywhere else it may be someone's
        # session, so the same rule as the start-up guard: only when told.
        [ "${GITHUB_ACTIONS:-}" = "true" ] || [ "$QUIT_FOREIGN_APP" = true ] \
            || fail "[protocol-repair] the dev app is running and may be in use. Quit it yourself, or pass --quit-foreign-app if it is the lane's leftover."
        log "[protocol-repair] quitting the running dev app"
        quit_running_app || fail "[protocol-repair] the dev app could not be stopped"
    fi
    _pp_repair || fail "[protocol-repair] not everything could be undone (see the warning above; records in $_MS_STATE_DIR)"
    log "[protocol-repair] nothing of a --protocol run is left"
    exit 0
fi

require_command() {
    command -v "$1" >/dev/null || fail "missing command: $1"
}

RPC_TOKEN=""  # populated once when the token file appears

# Returns empty string + exit 0 on transient curl failure so callers in
# `set -e` poll loops keep going. 15 s timeout covers brief main-thread
# blocks during model load + audio teardown.
rpc() {
    local path="$1"
    curl --silent --show-error --max-time 15 \
        --header "Authorization: Bearer $RPC_TOKEN" \
        "$RPC_BASE$path" 2>/dev/null || true
}


# --- Mic-only lane: audio routing ------------------------------------------
#
# The lane needs one invariant that no default configuration guarantees: the
# default INPUT must be a loopback of the default OUTPUT, so that playing a
# fixture is the same as speaking into the microphone. It arranges the second
# half itself, pointing the default output at the loopback device for its own
# duration, and asserts the first half in its preflight rather than assuming it.
#
# Why it is needed at all, measured 2026-08-18: with the output on the speakers,
# four mic tracks sampled from earlier runs on this host each read -120 dBFS
# (a sample, not a census), while the analyzer reports -22 dBFS for the shipped
# fixture. With the output routed into the loopback this lane records -22 dBFS.
# The app track is unaffected either way because it comes from the CATap, which
# reads process output and touches no device at all.
#
# Restoring the routing matters more than setting it. A machine left on the
# loopback goes silent AND records, on every later dual-source lane, a mic track
# that is a bit-perfect copy of the app track. That is textbook echo bleed: it
# would skew the echo detector on runs that have nothing to do with this lane,
# and no lane asserts against it, so CI would stay green while the meaning of
# every recording quietly changed. Hence:
#
#   - the marker is written BEFORE the switch, so a kill can never strand the
#     machine with no record of where to go back to;
#   - it is deleted only AFTER the restore has been verified by re-reading the
#     device, so a restore that fails keeps its own repair instructions;
#   - it carries the owning PID, so a concurrent run heals a dead run's marker
#     and never steals a live one;
#   - the self-heal runs before every early exit, not just before the lane.
_MIC_ONLY_DEVICE="BlackHole 2ch"
_MIC_ONLY_OUTPUT_MARKER="$HOME/Library/Application Support/MeetingTranscriber/.e2e-mic-only-previous-output"

# Read the current default output, or empty on failure.
_mic_only_current_output() {
    SwitchAudioSource -c -t output 2>/dev/null || true
}

_mic_only_switch_output() {
    local previous
    previous="$(_mic_only_current_output)"
    [ -n "$previous" ] || fail "[mic-only] could not read the current default output device"
    # No benign "already on the loopback" path: on this host that is never a
    # resting state, it is the signature of a previous run that failed to
    # restore, and skipping would hide exactly the damage this file guards.
    [ "$previous" != "$_MIC_ONLY_DEVICE" ] \
        || fail "[mic-only] default output is already $_MIC_ONLY_DEVICE, which means an earlier run never restored it; fix the machine's audio output before re-running"
    mkdir -p "$(dirname "$_MIC_ONLY_OUTPUT_MARKER")"
    # PID first so a reader can tell a live owner from a dead one; the device
    # name may contain spaces, so it takes the whole rest of the line.
    printf '%s %s' "$$" "$previous" >"$_MIC_ONLY_OUTPUT_MARKER"
    SwitchAudioSource -t output -s "$_MIC_ONLY_DEVICE" >/dev/null \
        || fail "[mic-only] could not set default output to $_MIC_ONLY_DEVICE"
    local now
    now="$(_mic_only_current_output)"
    [ "$now" = "$_MIC_ONLY_DEVICE" ] \
        || fail "[mic-only] default output is '$now' after switching; expected $_MIC_ONLY_DEVICE"
    log "[mic-only] default output $previous -> $_MIC_ONLY_DEVICE (restores on exit)"
}

# Restore and only then forget. $1 = "trap" when called from the exit trap,
# where a failure must warn rather than mask the run's real status; any other
# caller gets a hard failure, because a self-heal that cannot repair the machine
# must stop the run rather than hand the next lane a poisoned device.
_mic_only_restore_output() {
    local mode="${1:-trap}"
    [ -f "$_MIC_ONLY_OUTPUT_MARKER" ] || return 0
    local raw owner previous now
    raw="$(cat "$_MIC_ONLY_OUTPUT_MARKER" 2>/dev/null || true)"
    owner="${raw%% *}"
    previous="${raw#* }"
    if [ -z "$raw" ] || [ -z "$previous" ] || [ "$owner" = "$raw" ]; then
        _mic_only_report "$mode" "[mic-only] output marker is unreadable ('$raw'); set the default output by hand"
        return 0
    fi
    if ! SwitchAudioSource -t output -s "$previous" >/dev/null 2>&1; then
        _mic_only_report "$mode" "[mic-only] could not restore default output to '$previous' (device gone?); marker kept at $_MIC_ONLY_OUTPUT_MARKER"
        return 0
    fi
    now="$(_mic_only_current_output)"
    if [ "$now" != "$previous" ]; then
        _mic_only_report "$mode" "[mic-only] default output is '$now' after restoring; expected '$previous'; marker kept"
        return 0
    fi
    # Verified: only now is the marker safe to drop.
    rm -f "$_MIC_ONLY_OUTPUT_MARKER"
    log "[mic-only] default output restored to $previous"
}

_mic_only_report() {
    local mode="$1" message="$2"
    if [ "$mode" = "trap" ]; then
        log "WARNING: $message"
    else
        fail "$message"
    fi
}

# Startup self-heal, run by every invocation of this script before any lane can
# record. Only acts on a marker whose owner is gone: a live owner means another
# run holds the routing, and restoring it under that run would both break it and
# strand the machine once it switches again.
_mic_only_self_heal_output() {
    [ -f "$_MIC_ONLY_OUTPUT_MARKER" ] || return 0
    local owner
    owner="$(cut -d' ' -f1 <"$_MIC_ONLY_OUTPUT_MARKER" 2>/dev/null || true)"
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
        fail "[mic-only] another run (pid $owner) currently holds the audio routing; wait for it to finish"
    fi
    log "[mic-only] leftover output-routing marker from a dead run detected; self-healing"
    _mic_only_restore_output heal
}

# Heal a dead run's routing before anything else happens on this machine.
# Deliberately here and not after the traps: `--redeploy-only` and every
# preflight `fail` exit long before those, and the marker they would leave
# unhealed poisons the mic track of every later lane on this host.
_mic_only_self_heal_output

# --- Upgrade lane: seed and launch ------------------------------------------
#
# What v0.8.1 leaves on disk, laid out in the lane's own home (APP_HOME, a
# mktemp dir; see `_ug_cleanup`), and the launch that starts the new build on
# it. The on-disk shapes come from scripts/lib/upgrade-seed.sh, which says what
# each one is derived from. The assertions are at `run_upgrade`.

# The variant the lane loads, one it seeds incomplete next to it, and the
# tokenizer the loaded one needs. Small, because the lane needs a real model
# that loads, not a large one.
_UG_VARIANT=openai_whisper-small
_UG_INCOMPLETE_VARIANT=openai_whisper-base
_UG_TOKENIZER=whisper-small
# The account's real model folders, old and new location. What the lane's app
# would touch there if the isolated home did not hold (this variant, its
# download metadata and its tokenizer) is fingerprinted before and after; not
# the whole folders, which other jobs on the same account change meanwhile.
_UG_REAL_DOCS_HF="$HOME/Documents/huggingface"
_UG_REAL_APP_HF="$HOME/Library/Application Support/MeetingTranscriber/huggingface"
_ug_real_fingerprint() {
    local base
    for base in "$_UG_REAL_DOCS_HF" "$_UG_REAL_APP_HF"; do
        echo "== $base"
        upgrade_tree_fingerprint "$base/$UPGRADE_WHISPERKIT_REPO/$_UG_VARIANT"
        upgrade_tree_fingerprint "$base/$UPGRADE_WHISPERKIT_REPO/.cache/huggingface/download/$_UG_VARIANT"
        upgrade_tree_fingerprint "$base/$UPGRADE_TOKENIZER_ORG/$_UG_TOKENIZER"
    done
}
# Where the model is cloned from: a `huggingface` folder in the current layout.
# CI points it at the runner's pre-warmed test home; by default it is the
# account's own app model folder. Only ever read.
_UG_MODEL_SOURCE="${E2E_UPGRADE_MODEL_SOURCE:-$_UG_REAL_APP_HF}"
# What the lane imports to have the queue built (see run_upgrade): short, since
# only the restored job's transcript is read.
_UG_TRIGGER_FIXTURE="$ROOT/app/MeetingTranscriber/Tests/Fixtures/two_speakers_en.wav"
# The lane's own files (seed copies, fingerprints, the app's output) sit in the
# home but outside every folder the app owns.
_UG_LANE_DIR="$APP_HOME/.e2e-upgrade"
_UG_DATA_DIR="$APP_HOME/Library/Application Support/MeetingTranscriber"
_UG_DOCS_HF="$APP_HOME/Documents/huggingface"
_UG_APP_HF="$_UG_DATA_DIR/huggingface"
_UG_STAGING_DIR="$_UG_DATA_DIR/recordings"
_UG_IPC_DIR="$_UG_DATA_DIR/ipc"
_UG_PENDING_TITLE="Upgrade Seed Interrupted"
_UG_FINISHED_TITLE="Upgrade Seed Finished"
# A v0.8.1 speaker entry cut off mid-embedding: valid JSON up to that point,
# so it reads as a damaged file and not as an empty one.
_UG_SPEAKERS_SEED='[{"name":"Seed Voice","embeddings":[[0.125,-0.5,0.25'
# Closes the network to everything but localhost, where the RPC server answers.
# Not to measure that the app avoids the network but to make a download fail
# loudly: WhisperKit's downloader contacts the Hub before it looks at any local
# file (see WhisperKitLocalSnapshot), so with this profile a model that was not
# found locally ends in a failed load instead of a quiet re-download.
_UG_SANDBOX_PROFILE='(version 1)(allow default)(deny network-outbound (remote ip "*:*"))(allow network-outbound (remote ip "localhost:*"))'
# The lane's settings, passed as launch arguments: they land in the argument
# domain, which overrides the dev bundle's stored preferences for this process
# and is never written back. Diarization and VAD are off so no FluidAudio model
# is needed behind the closed network, protocol generation is off so no
# transcript leaves the machine, and auto-watch is off so nothing asks for the
# microphone: a binary started directly, as here, is not the bundle the
# runner's grants were made for.
_UG_APP_ARGS=(
    -transcriptionEngine whisperKit -whisperKitModel "$_UG_VARIANT"
    -whisperKitCustomModelEnabled NO -whisperLanguage de
    -diarize NO -vadEnabled NO -protocolProvider none -autoWatch NO
    -recordOnly NO -liveTranscriptionEnabled NO -echoCancellationEnabled NO
)

_ug_preflight() {
    require_command sandbox-exec
    require_command shasum
    upgrade_variant_complete "$_UG_MODEL_SOURCE/$UPGRADE_WHISPERKIT_REPO/$_UG_VARIANT" \
        && [ -f "$_UG_MODEL_SOURCE/$UPGRADE_TOKENIZER_ORG/$_UG_TOKENIZER/tokenizer.json" ] \
        || fail "--upgrade needs a complete $_UG_VARIANT and its $_UG_TOKENIZER tokenizer under '$_UG_MODEL_SOURCE' (set E2E_UPGRADE_MODEL_SOURCE to a huggingface folder that has them; in CI that is the runner home the runner-home action pre-warms)"
    # The profile has to close the Hub to this host's processes, or "loaded
    # without a download" proves nothing. Checked with curl under the same
    # profile the app gets.
    if sandbox-exec -p "$_UG_SANDBOX_PROFILE" curl --silent --max-time 10 -o /dev/null https://huggingface.co/ 2>/dev/null; then
        fail "--upgrade: the sandbox profile did not stop a connection to huggingface.co, so the lane could not tell a local load from a download"
    fi
}

# Lay out the v0.8.1 data. Refuses any target outside the lane's own home.
_ug_seed() {
    local label="[upgrade]" d now stem
    [ "$APP_HOME" != "$HOME" ] && e2e_is_lane_home "$APP_HOME" "$_UG_HOME_STEM" "$_UG_HOME_PARENT" \
        || fail "$label: refusing to seed '$APP_HOME', which is not this lane's temp home"
    for d in "$_UG_LANE_DIR" "$_UG_DOCS_HF" "$_UG_DATA_DIR" "$OUTPUT_DIR"; do
        upgrade_path_inside "$d" "$APP_HOME" || fail "$label: refusing to seed '$d', outside the lane's home $APP_HOME"
    done
    mkdir -p "$_UG_LANE_DIR" "$_UG_STAGING_DIR" "$_UG_IPC_DIR" "$OUTPUT_DIR/protocols" "$RECORDINGS_DIR"
    _ug_real_fingerprint >"$_UG_LANE_DIR/real-models.before"

    # 1. The model, where v0.8.1 downloaded it. Next to it an incomplete
    # variant (one weight file missing) and something another tool keeps in
    # the shared folder: neither is the app's to move.
    upgrade_seed_whisperkit "$_UG_MODEL_SOURCE" "$_UG_DOCS_HF" "$_UG_VARIANT" "$_UG_TOKENIZER" \
        || fail "$label: could not seed the model from '$_UG_MODEL_SOURCE'"
    local repo="$_UG_DOCS_HF/$UPGRADE_WHISPERKIT_REPO"
    # Stand-in files: the migration judges a variant by which files exist.
    local bundle file
    for bundle in "${UPGRADE_REQUIRED_BUNDLES[@]}"; do
        for file in "${UPGRADE_REQUIRED_FILES[@]}"; do
            [ "$bundle/$file" = TextDecoder/weights/weight.bin ] && continue
            mkdir -p "$(dirname "$repo/$_UG_INCOMPLETE_VARIANT/$bundle.mlmodelc/$file")"
            printf 'stand-in' >"$repo/$_UG_INCOMPLETE_VARIANT/$bundle.mlmodelc/$file"
        done
    done
    mkdir -p "$_UG_DOCS_HF/models/example-org/other-model"
    printf '{"model_type":"other"}\n' >"$_UG_DOCS_HF/models/example-org/other-model/config.json"
    upgrade_tree_fingerprint "$repo/$_UG_VARIANT" >"$_UG_LANE_DIR/variant.seeded"
    upgrade_tree_fingerprint "$repo/.cache/huggingface/download/$_UG_VARIANT" >"$_UG_LANE_DIR/metadata.seeded"
    upgrade_tree_fingerprint "$repo/$_UG_INCOMPLETE_VARIANT" >"$_UG_LANE_DIR/incomplete.seeded"
    upgrade_tree_fingerprint "$_UG_DOCS_HF/models/example-org" >"$_UG_LANE_DIR/other.seeded"
    upgrade_tree_fingerprint "$_UG_DOCS_HF/$UPGRADE_TOKENIZER_ORG" >"$_UG_LANE_DIR/tokenizer.seeded"
    upgrade_tree_digest "$_UG_DOCS_HF/$UPGRADE_TOKENIZER_ORG/$_UG_TOKENIZER" >"$_UG_LANE_DIR/tokenizer.digest"

    # 2. A speaker DB that does not decode.
    printf '%s' "$_UG_SPEAKERS_SEED" >"$_UG_DATA_DIR/speakers.json"
    printf '%s' "$_UG_SPEAKERS_SEED" >"$_UG_LANE_DIR/speakers.seed"

    # 3. An interrupted job in the queue snapshot, its recording still in
    # staging, plus a finished job's record and the processed-recordings
    # ledger every v0.8.1 install has. The ledger names an older recording, as
    # it would, so the app does not seed it afresh from the staging folder.
    now="$(date +%s)"
    stem="$(date -r $(( now - 600 )) +%Y%m%d_%H%M%S)_upgrade-seed"
    _UG_SEEDED_MIX="$_UG_STAGING_DIR/${stem}_mix.wav"
    cp "$DEFAULT_FIXTURE" "$_UG_SEEDED_MIX"
    _UG_PENDING_ID="$(uuidgen)"
    _UG_FINISHED_ID="$(uuidgen)"
    _UG_FINISHED_TRANSCRIPT="$OUTPUT_DIR/protocols/$(date -r $(( now - 86400 )) +%Y%m%d_%H%M)_upgrade-seed-finished.md"
    printf '# Transcript\n\nSeed.\n' >"$_UG_FINISHED_TRANSCRIPT"
    jq -n --argjson job "$(upgrade_v081_pipeline_job "$_UG_PENDING_ID" "$_UG_PENDING_TITLE" transcribing "$_UG_SEEDED_MIX" $(( now - 600 )))" \
        '[$job]' >"$_UG_IPC_DIR/pipeline_queue.json"
    jq -n --argjson rec "$(upgrade_v081_terminal_record "$_UG_FINISHED_ID" "$_UG_FINISHED_TITLE" "$_UG_FINISHED_TRANSCRIPT")" \
        '[$rec]' >"$_UG_IPC_DIR/terminal_jobs.json"
    jq -n --arg p "$RECORDINGS_DIR/$(date -r $(( now - 86400 )) +%Y%m%d_%H%M%S)_older_mix.wav" \
        '[$p]' >"$_UG_IPC_DIR/processed_recordings.json"
    log "$label: seeded v0.8.1 data in $APP_HOME (model $_UG_VARIANT in Documents, unreadable speakers.json, job $_UG_PENDING_ID interrupted while transcribing, finished record $_UG_FINISHED_ID)"
}

# Start the deployed binary directly, inside the sandbox profile, with the
# lane's home and settings. Directly and not with `open`, because only a
# process this script starts can be put in the profile; that is also why the
# lane never touches anything a TCC grant guards. Appends to the lane's log.
_ug_launch() {
    # The installed app serves the same port when its automation API is on.
    # The readiness check would then time out on a token mismatch and blame
    # this app; say what is actually in the way instead.
    local holder
    holder="$(lsof -nP -iTCP:9876 -sTCP:LISTEN -t 2>/dev/null | head -1 || true)"
    [ -z "$holder" ] \
        || fail "[upgrade]: 127.0.0.1:9876 is already served by pid $holder ($(ps -o command= -p "$holder" 2>/dev/null | cut -c1-100)); this lane's app could not answer there"
    CFFIXED_USER_HOME="$APP_HOME" MEETINGTRANSCRIBER_DEBUG_RPC=1 MEETINGTRANSCRIBER_DEBUG_SUPPRESS_AUTOWATCH=1 \
        nohup sandbox-exec -p "$_UG_SANDBOX_PROFILE" "$DEV_BUNDLE_DEPLOY/Contents/MacOS/MeetingTranscriber" \
        "${_UG_APP_ARGS[@]}" >>"$_UG_LANE_DIR/app.log" 2>&1 &
    # sandbox-exec execs the app, so this is the app's pid.
    _UG_APP_PID=$!
}

# --- preflight ------------------------------------------------------------

require_command curl
require_command jq
require_command swift
require_command codesign

[ -f "$SIMULATOR_FIXTURE" ] || fail "simulator fixture not found: $SIMULATOR_FIXTURE"
[ "$UPGRADE" = true ] && _ug_preflight

# Sanity check: a virtual input device is set as default. If the runner
# host has no built-in mic and no BlackHole/Loopback, AVAudioEngine binds
# to a no-input device and the dual-source recorder hits a libmalloc abort
# (observed on Mac mini hosts). Surface the misconfiguration up-front.
if [ "$UPGRADE" != true ] && ! system_profiler SPAudioDataType 2>/dev/null | grep -A4 "Default Input" | grep -q "Input Channels"; then
    fail "no default audio input device — install BlackHole 2ch (brew install blackhole-2ch + reboot/coreaudiod restart) and set it as the default Input in System Settings → Sound"
fi

# Refuse to run alongside another driver. Two e2e-app.sh runs on one host share
# the deployed bundle, the RPC port and the audio device, and each one quits the
# other's app at launch (the line below), so BOTH results are meaningless and the
# host can be left with a bundle, settings or a speaker DB that neither run
# expects. Observed 2026-09-09: a hand-started `--two-meetings` run overlapped a
# second driver started over SSH, and the CI-worker check the SSH side relied on
# cannot see a hand-started lane. Matched on the script name, excluding this
# process and its ancestors (the shell that invoked it carries the same words on
# its command line). Other e2e-*.sh drivers are not matched: they never run
# concurrently with this one in the workflow.
_e2e_other_drivers() {
    local ancestors p
    ancestors="$(_ancestor_pids)"
    # The name must stand as a path component or a word (`bash scripts/e2e-app.sh`,
    # `./scripts/e2e-app.sh`): a quoted mention inside some other command line,
    # such as a monitoring `pgrep -f "e2e-app.sh"`, is not a driver and must not
    # block one. `|| true`: pgrep exits 1 when nothing matches, and under
    # pipefail that would abort the script instead of reporting "no other driver".
    { pgrep -f '(^|[ /])e2e-app\.sh( |$)' 2>/dev/null || true; } | while read -r p; do
        case "$ancestors" in *" $p "*) continue ;; esac
        # A driver runs under bash (its shebang), so a process whose executable
        # is not a shell only mentions the script: `scp scripts/e2e-app.sh ...`,
        # an editor holding it open, a `zsh -c` wrapper around a copy. Measured:
        # such an scp blocked a run on another machine for the copy's duration.
        case "$(basename "$(ps -o comm= -p "$p" 2>/dev/null)")" in bash|sh) ;; *) continue ;; esac
        # Descendants of this script carry its command line too: the subshell
        # running this very check is one (measured: it reported itself as a
        # second driver). Walk up from the candidate and skip it if the chain
        # reaches this process.
        case "$(_ancestor_pids "$p")" in *" $$ "*) continue ;; esac
        printf '%s ' "$p"
    done
}
_other_drivers="$(_e2e_other_drivers)"
[ -z "$_other_drivers" ] \
    || fail "another e2e-app.sh is already running on this host (pid(s): ${_other_drivers}). Two drivers would share the deployed bundle, the RPC port and the audio device and quit each other's app, so neither result could be trusted. Wait for it to finish (ps -p ${_other_drivers% } -o pid,command)."

# --quit-flush writes jobs into the pipeline state the dev and the installed
# build SHARE (one data directory, only the preferences are per bundle id), so
# it guards that state before it changes anything, and aborts rather than
# continues on any of:
#   - another live user of this host holds the lock directory ($MT_LIVE_LOCK,
#     a bare `mkdir` lock any driver or agent session can share);
#   - the installed app is running: it reads and writes the same snapshot file
#     this lane reads its verdict from, and would adopt the lane's jobs;
#   - the pipeline queue is not empty: the lane restores it on exit, and
#     restoring over someone's queued work would lose it. Checked, and the
#     backup taken, only after the dev app below has quit, since a dev app
#     that was recording writes that recording on its quit.
# Then it backs the shared state up, and `on_exit` restores it. Only this run's
# records may have changed in the meantime: each of the four ipc files that
# existed before is put back byte for byte when everything added to it since
# the backup is one of this run's jobs (job ids, or for the processed-recordings
# ledger the jobs' file paths), and each that did not exist before is removed
# when everything in it is. A file with anyone else's record, or one that does
# not parse, is left as it is and fails the run. A SHA-256 compare is printed
# either way; speakers.json is compared, never written. The backup (it holds a
# copy of speakers.json) is removed when the compare matches, and kept, with
# its path printed, when it does not.
_QF_DATA_DIR="$HOME/Library/Application Support/MeetingTranscriber"
_QF_IPC_DIR="$_QF_DATA_DIR/ipc"
_QF_IPC_FILES=(pipeline_queue.json terminal_jobs.json pipeline_log.jsonl processed_recordings.json)
_QF_LOCK_HELD=""
_QF_BACKUP_DIR=""
# Quit-flush cleanup: stop the app, remove what this run's unreleased jobs
# wrote, put the shared pipeline state back and remove the backup when it
# matches. Defined before the backup is taken and called from the early EXIT
# trap as well as from `on_exit`, so a failure before `on_exit` exists (a
# launch or readiness failure) restores too. Runs once.
_QF_RESTORED=""
_qf_restore_shared_state() {
    [ "$QUIT_FLUSH" = true ] && [ -n "$_QF_BACKUP_DIR" ] && [ -z "${_QF_RESTORED:-}" ] || return 0
    _QF_RESTORED=1
    [ -n "${_QF_AFPLAY_PID:-}" ] && kill "$_QF_AFPLAY_PID" 2>/dev/null || true
    local quit_status=0
    quit_running_app || quit_status=$?
    case "$quit_status" in
        1) log "[quit-flush] WARNING: the dev app did not stop; restoring anyway" ;;
        2) log "[quit-flush] WARNING: the dev app was ended by signal, without its quit hold (see the Automation error above); restoring anyway" ;;
    esac
    # A cycle that failed after its recording started may have a job in the
    # shared state that nothing registered yet; the quit above may have just
    # written it. Defined with the lane further down.
    if declare -F _qf_register_cycle_jobs >/dev/null; then _qf_register_cycle_jobs; fi
    # Defined with the lane further down; an abort before that point has
    # no lane jobs to clean up.
    # This run's records, for the shared files that did not exist before
    # the lane: the restore removes such a file only when it holds nothing
    # else. Collected before the unreleased files go, while the snapshot
    # still names them.
    local _qf_ids="$_QF_BACKUP_DIR/run-job-ids" _qf_paths="$_QF_BACKUP_DIR/run-paths" _qf_job
    : >"$_qf_ids"
    : >"$_qf_paths"
    for _qf_job in ${_QF_JOBS[@]+"${_QF_JOBS[@]}"}; do
        printf '%s\n' "$_qf_job" >>"$_qf_ids"
        if declare -F _qf_job_file_paths >/dev/null; then _qf_job_file_paths "$_qf_job" >>"$_qf_paths"; fi
    done
    if [ -n "${_QF_OWNED_PATHS[*]+set}" ]; then printf '%s\n' "${_QF_OWNED_PATHS[@]}" >>"$_qf_paths"; fi
    if declare -F _qf_remove_unreleased_files >/dev/null; then _qf_remove_unreleased_files; fi
    # The double-quit cycle's osascript reply file, left when a failure
    # came before that cycle removed it. Exact path, this run's pid.
    rm -f "/tmp/e2e-quit-flush-q1.$$"
    log "[quit-flush] restoring the shared pipeline state from $_QF_BACKUP_DIR"
    local _qf_cmp _qf_cmp_status=0
    _qf_cmp="$(restore_state_files "$_QF_BACKUP_DIR/ipc" "$_QF_IPC_DIR" "$_qf_ids" "$_qf_paths" "${_QF_IPC_FILES[@]}")" || _qf_cmp_status=$?
    _qf_cmp="$_qf_cmp
$(compare_state_files "$_QF_BACKUP_DIR" "$_QF_DATA_DIR" speakers.json)" || _qf_cmp_status=1
    while IFS= read -r _qf_line; do log "[quit-flush]   $_qf_line"; done <<<"$_qf_cmp"
    if [ "$_qf_cmp_status" -ne 0 ]; then
        log "[quit-flush] FAIL: the shared pipeline state does not match its backup (see the lines above); the backup is kept at $_QF_BACKUP_DIR"
        _QF_RESTORE_FAILED=1
    else
        # It holds a copy of speakers.json (voice embeddings and names) and
        # of the queue: gone once the state is back, file by file.
        rm -f "$_qf_ids" "$_qf_paths"
        if remove_state_backup "$_QF_BACKUP_DIR/ipc" "${_QF_IPC_FILES[@]}" >/dev/null \
            && remove_state_backup "$_QF_BACKUP_DIR" speakers.json >/dev/null; then
            log "[quit-flush] state matches its backup; backup removed"
        else
            log "[quit-flush] state matches its backup, but $_QF_BACKUP_DIR holds files the lane did not write; left in place"
        fi
    fi
}

_qf_release_lock() {
    if [ -n "${_QF_LOCK_HELD:-}" ]; then
        rmdir "$MT_LIVE_LOCK" 2>/dev/null || true
        _QF_LOCK_HELD=""
    fi
}

if [ "$QUIT_FLUSH" = true ]; then
    # First, before any build, quit, backup or settings change: the unified-log
    # precondition (see the lane header). Both modes are checked so both
    # reasons come out at once.
    _qf_refused="" _qf_failed=""
    for _qf_mode in stream show; do
        _qf_status=0
        _qf_reason="$(unified_log_unusable "$_qf_mode")" || _qf_status=$?
        case "$_qf_status" in
            1) ;;
            0) _qf_refused="$_qf_refused 'log $_qf_mode': $_qf_reason;" ;;
            *) _qf_failed="$_qf_failed 'log $_qf_mode': $_qf_reason;" ;;
        esac
    done
    [ -z "$_qf_refused" ] \
        || fail "--quit-flush: this user ($(id -un)) may not read the unified log:$_qf_refused$_qf_failed it needs an admin user on macOS 26 (see the lane header)."
    [ -z "$_qf_failed" ] \
        || fail "--quit-flush: the unified log probe failed:$_qf_failed the lane needs the log (see the lane header); retry, or check logd."
    MT_LIVE_LOCK="${MT_LIVE_LOCK:-/tmp/mt-live-lock}"
    mkdir "$MT_LIVE_LOCK" 2>/dev/null \
        || fail "--quit-flush: the live lock $MT_LIVE_LOCK is held (since $(stat -f '%Sm' "$MT_LIVE_LOCK" 2>/dev/null)). Someone else is using the live app on this host; aborting without touching anything."
    _QF_LOCK_HELD=yes
    # Until `on_exit` is armed after the launch, an abort runs it if the script
    # got far enough to define it, and otherwise does the quit-flush part of it
    # itself: once the backup exists, the lane has started to change shared
    # state (the app launch writes it), so a failure here restores too.
    trap 'if declare -F on_exit >/dev/null; then on_exit; else _qf_restore_shared_state; _qf_release_lock; [ -z "${_QF_RESTORE_FAILED:-}" ] || exit 1; fi' EXIT
    _qf_installed="$( { pgrep -x MeetingTranscriber || true; } | while read -r p; do
        ps -o command= -p "$p" 2>/dev/null | grep -q "MeetingTranscriber-Dev.app/" || printf '%s ' "$p"; done)"
    [ -z "$_qf_installed" ] \
        || fail "--quit-flush: a MeetingTranscriber that is not the dev app is running (pid(s): ${_qf_installed% }). It shares the pipeline state this lane writes and restores. Quit it first."
    log "[quit-flush] lock $MT_LIVE_LOCK held, installed app not running; the queue check and the backup follow the dev app's quit"
fi

# Second half of the guard: a dev app that is running when this driver starts.
# The line below quits it, as this driver always has, so the question is whose
# it is. A launch marker this driver owns answers it for apps a driver started:
# it is written once the app it opened is up (`<pid> launched`), rewritten at
# exit as `kept` (--keep-app) or `abandoned` (an exit that never reached the
# quit, i.e. a failed lane), and removed when the driver quit the app itself.
#
#   marker matches, kept       a developer left it on purpose: say so, quit it
#   marker matches, abandoned  a previous run failed and left it: warn, quit it
#   no match                   not started by any e2e-app.sh run. Outside CI
#                              that may be someone's session (run_app.sh, a hand
#                              launch): REFUSE unless --quit-foreign-app. In CI
#                              warn and quit it: the sibling e2e-*.sh drivers in
#                              the workflow open the same app without writing
#                              the marker, one of them is continue-on-error, and
#                              a refusal here would cascade its leftover into
#                              every later e2e-app.sh step going red.
#
# What this cannot tell apart: a foreign app from a sibling driver's leftover
# on a hand-run host, and a stale marker pid reused by an unrelated process
# (both rare, both reported with the pid and command so a person can decide).
# The mic-stall lane plays a synthetic meeting for over a minute. Its own app
# runs in a throwaway home, but a MeetingTranscriber that is not the dev app
# (the installed one) runs in the host's: with auto-watch on it would detect
# that meeting and record it into the real staging folder and Downloads. Its
# output-folder check below cannot catch that, because it reads `/state` from
# whichever app answers the RPC port, and an installed app with the automation
# API off does not. So the lane refuses, and never quits it.
if [ -n "$MIC_STALL" ]; then
    _installed="$(non_dev_meetingtranscriber_pids)"
    [ -z "$_installed" ] \
        || fail "--mic-stall: a MeetingTranscriber that is not the dev app is running (pid(s): ${_installed% }). It would record the lane's synthetic meeting into the host's real folders. Quit it first; this lane does not quit it for you."
fi

# The marker a driver running the app in the host's own home leaves.
_E2E_HOST_MARKER="$HOME/Library/Application Support/MeetingTranscriber/.e2e-app-launched"
# The one a lane with an isolated home (--mic-stall, --upgrade) leaves. Outside that home,
# which the next run never sees: kept there, an app a failed run left behind
# read as foreign to every later run.
_E2E_ISOLATED_MARKER="$_MS_STATE_DIR/isolated-home-app-launched"
_E2E_APP_MARKER="$_E2E_HOST_MARKER"
[ "$APP_HOME" != "$HOME" ] && _E2E_APP_MARKER="$_E2E_ISOLATED_MARKER"
_running_app="$( { pgrep -f "$_DEV_APP_PATTERN" || true; } | head -1)"
if [ -n "$_running_app" ]; then
    # Whichever marker names the running app, whichever lane left it.
    _marker=""
    for _m in "$_E2E_HOST_MARKER" "$_E2E_ISOLATED_MARKER"; do
        _c="$(cat "$_m" 2>/dev/null || true)"
        if [ -n "$_c" ] && [ "${_c%% *}" = "$_running_app" ]; then
            _marker="$_c"
            break
        fi
    done
    _marker_pid="${_marker%% *}"
    _marker_state="${_marker#* }"
    _running_cmd="$(ps -o command= -p "$_running_app" 2>/dev/null | cut -c1-120)"
    if [ -n "$_marker_pid" ] && [ "$_marker_pid" = "$_running_app" ]; then
        case "$_marker_state" in
            kept) log "the dev app (pid $_running_app) was left running on purpose by a previous e2e-app.sh run (--keep-app); quitting it to relaunch with this lane's settings" ;;
            *)    log "WARNING: the dev app (pid $_running_app) is left over from a previous e2e-app.sh run that exited without quitting it; quitting it" ;;
        esac
    elif [ "$QUIT_FOREIGN_APP" = true ] || [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        log "WARNING: the dev app (pid $_running_app) is running and was not started by an e2e-app.sh run; quitting it$( [ "$QUIT_FOREIGN_APP" = true ] && echo " (--quit-foreign-app)" || echo " (CI: a sibling e2e-*.sh driver may have left it)"). Command: $_running_cmd"
    else
        fail "the dev app is running (pid $_running_app) and was not started by an e2e-app.sh run, so it may be in use (a run_app.sh session, a hand launch, another driver between its phases). Refusing rather than quitting someone's session. Quit it yourself, or pass --quit-foreign-app if you know it is yours. Command: $_running_cmd"
    fi
fi

# Always — even with --no-build, since UserDefaults below take effect
# only on launch and the running RPC server would shadow the new one.
quit_running_app

# Whatever lane this is: finish what a killed --protocol run left, its
# settings, its jobs and its files. Now, with the dev app stopped, and before
# --quit-flush checks and backs up the shared queue, which would otherwise
# count a lane job the repair is about to drop, or restore it at exit. Hard
# failure when a setting does not come back: the lane that runs next would
# launch with the stub endpoint and diarize off and report verdicts about a
# configuration nobody chose.
_pp_repair \
    || fail "a killed --protocol run left something this run could not undo (see the warning above; records in $_MS_STATE_DIR). Fix what it names, then rerun."

# --quit-flush: the dev app just quit may have been recording, and its quit
# writes that recording into the shared state. So the queue check and the
# backup come only now, with no app of ours or anyone's left to write, or the
# restore at exit would put the state back over that recording.
if [ "$QUIT_FLUSH" = true ]; then
    ! pgrep -f "$_DEV_APP_PATTERN" >/dev/null \
        || fail "--quit-flush: the dev app is still running after the quit; refusing to back up state it may still write"
    _qf_q_status=0
    queue_snapshot_is_empty "$_QF_IPC_DIR/pipeline_queue.json" || _qf_q_status=$?
    case "$_qf_q_status" in
        0) ;;
        1) fail "--quit-flush: the shared pipeline queue is not empty ($(jq -c '[.[] | {meetingTitle, state}]' "$_QF_IPC_DIR/pipeline_queue.json")). The lane restores it on exit and would lose that work. Let those jobs finish or dismiss them, then rerun." ;;
        *) fail "--quit-flush: $_QF_IPC_DIR/pipeline_queue.json does not parse; refusing to run over it." ;;
    esac
    _QF_BACKUP_DIR="${E2E_QUIT_FLUSH_BACKUP_DIR:-$HOME/Library/Caches/MeetingTranscriber-e2e/quit-flush-$(date +%Y%m%d-%H%M%S)}"
    if ! backup_state_files "$_QF_IPC_DIR" "$_QF_BACKUP_DIR/ipc" "${_QF_IPC_FILES[@]}" \
        || ! backup_state_files "$_QF_DATA_DIR" "$_QF_BACKUP_DIR" speakers.json; then
        # Nothing has been changed yet, so there is nothing to restore, and a
        # copy that may be partial must not be restored over the real files.
        # It may hold a copy of speakers.json, so its path is said.
        _qf_incomplete="$_QF_BACKUP_DIR"
        _QF_BACKUP_DIR=""
        fail "--quit-flush: could not back up the shared pipeline state; nothing was changed. The incomplete backup (it may hold a copy of speakers.json) is at $_qf_incomplete: delete it by hand"
    fi
    log "[quit-flush] dev app stopped, queue empty; shared state backed up to $_QF_BACKUP_DIR"
fi

# Whatever lane of this script this is: finish what an earlier mic-stall run
# could not. A killed one leaves protocolProvider at `none` and its record
# behind, and this lane would otherwise launch the app with it; a failed one
# leaves its home behind while its app was up, and that app is gone now. Only
# this script does this: e2e-browser.sh, e2e-channel-fault.sh and a hand
# launch of the dev bundle run with whatever is left until it next runs.
mic_stall_restore_protocol "$DEV_BUNDLE_ID" "$(dev_container_plist)" "$_MS_PROTOCOL_RECORD" none || true
mic_stall_sweep_kept_homes "$_MS_KEPT_HOMES"

if [ "$NO_BUILD" = true ]; then
    [ -d "$DEV_BUNDLE_DEPLOY" ] || fail "--no-build given but $DEV_BUNDLE_DEPLOY doesn't exist — deploy a signed bundle there first"
    log "Skipping build/deploy/re-sign — using existing $DEV_BUNDLE_DEPLOY"
else
    # Establish the signing identity before the build. The deploy below replaces
    # the shared bundle whose TCC grants are keyed on the certificate, and every
    # `--no-build` sibling lane reuses it, so a lane that only discovers it
    # cannot sign afterwards has already stranded an unsigned one there.
    #
    #
    # No exemption for `--redeploy-only`, deliberately. It is the build path of
    # the browser, channel-fault and soak drivers as well as the cleanup step
    # that restores the canonical bundle, and on main all four refused here. A
    # blanket exemption would downgrade three whole lanes to a warning, and the
    # channel-fault lane asserts channel silence, which a denied capture also
    # produces. The cleanup's own concern (refusing leaves a fault-injection
    # bundle deployed) is real but narrower, and needs a flag of its own rather
    # than this door.
    require_signing_identity || exit 1

    log "Building dev .app bundle"
    "$SCRIPT_DIR/run_app.sh" --build-only

    log "Deploying to $DEV_BUNDLE_DEPLOY"
    mkdir -p "$(dirname "$DEV_BUNDLE_DEPLOY")"
    # rsync into the existing bundle dir — TCC keys off the bundle path,
    # so a delete+copy would invalidate granted permissions.
    if [ -d "$DEV_BUNDLE_DEPLOY" ]; then
        rsync -a --delete "$DEV_BUNDLE_BUILD/" "$DEV_BUNDLE_DEPLOY/"
    else
        cp -R "$DEV_BUNDLE_BUILD" "$DEV_BUNDLE_DEPLOY"
    fi

    # Re-sign with our stable identity. run_app.sh signs with what
    # choose_signing_identity picks from the build host's keychain: the
    # certificate the bundle already carried, else a Developer ID, else the
    # first identity listed, and nothing at all on an empty keychain. That
    # choice follows the host's keychain while this lane's grants follow one
    # certificate, so the deployed copy is put on that certificate here
    # whatever the build chose. CI path uses the imported Developer ID;
    # local-dev path falls back to the self-signed cert from
    # setup-self-hosted-runner.sh. resign_deployed_bundle carries the dev
    # entitlements through that re-sign, and skips it entirely when the build
    # already used this certificate — a bare codesign would silently strip both
    # the microphone and the time-sensitive entitlement (issue #609).
    log "Re-signing $DEV_BUNDLE_DEPLOY with $SIGN_IDENTITY"
    # Re-assert the signing keychain right before codesign — a parallel job
    # on the Mini's other runner (shared OS user) may have mutated the user
    # search list during our 60-90 s build. codesign honours `--keychain`
    # for the signing identity but still consults the search list for
    # trust-chain resolution.
    [ -z "$SIGN_KEYCHAIN" ] || "$SCRIPT_DIR/keychain-prepend.sh" "$SIGN_KEYCHAIN" || true
    resign_deployed_bundle "$DEV_BUNDLE_DEPLOY" "$SIGN_IDENTITY" "$SIGN_KEYCHAIN" \
        || fail "re-sign of the deployed bundle failed — see the message above"
fi

# --redeploy-only stops here: the canonical bundle is rebuilt + deployed +
# signed above, which is the whole job. Don't launch, don't run a meeting.
# This is the always() cleanup the --mic-device-change workflow runs to leave
# a clean (non-fault-injection) bundle at the shared deploy path.
if [ "$REDEPLOY_ONLY" = true ]; then
    log "Redeployed the canonical (non-fault-injection) bundle to $DEV_BUNDLE_DEPLOY; exiting (--redeploy-only)"
    exit 0
fi

# The mic-stall lane's whole premise is a bundle that withholds the
# microphone's buffers on request. Checked on the deployed binary, not on the
# build flag, so a --no-build run against a canonical bundle fails here rather
# than recording a healthy microphone and failing a minute later with "never
# stalled". The variable name exists only in a -DE2E_FAULT_INJECTION build
# (see E2EMicFault), which is also how a release build is shown not to carry it.
if [ -n "$MIC_STALL" ]; then
    grep -q -a "MEETINGTRANSCRIBER_E2E_MIC_FAULT" "$DEV_BUNDLE_DEPLOY/Contents/MacOS/MeetingTranscriber" \
        || fail "--mic-stall needs a fault-injection build at $DEV_BUNDLE_DEPLOY (its binary does not carry MEETINGTRANSCRIBER_E2E_MIC_FAULT); run without --no-build"
    log "[mic-stall] deployed bundle is a fault-injection build"
fi

if [ "$UPGRADE" != true ] && [ ! -x "$SIMULATOR_BIN" ]; then
    log "Building meeting-simulator"
    (cd "$SIMULATOR_PKG" && swift build -c release)
fi

# Record-only lanes assert the captured app track is non-silent via
# `mt-cli wav-verdict` (the same analyzer the browser lane uses). Only that
# mode needs it, so build lazily to keep the processing lane unchanged.
# Rebuilt when any of its sources is newer than the binary, not only when it is
# missing: a hand-run host keeps .build across checkouts, and an mt-cli older
# than the lane could lack a subcommand or flag it calls and fail with an
# error that blames the app.
_mtcli_stale() {
    [ ! -x "$MTCLI" ] \
        || [ -n "$(find "$MTCLI_PKG/Sources" "$MTCLI_PKG/Package.swift" "$MTCLI_PKG/Package.resolved" -newer "$MTCLI" -print -quit 2>/dev/null)" ]
}
if { [ "$RECORD_ONLY" = true ] || [ "$MIC_ONLY" = true ] || [ "$QUIT_FLUSH" = true ] || [ -n "$MIC_STALL" ]; } && _mtcli_stale; then
    # record-only asserts the app track carries signal; mic-only needs the same
    # analyzer for its mic track AND drives `record start/stop` through it.
    log "Building mt-cli (track silence guard + record control)"
    (cd "$MTCLI_PKG" && swift build -c release) || fail "mt-cli build failed"
fi

if [ "$MIC_ONLY" = true ]; then
    command -v SwitchAudioSource >/dev/null 2>&1 \
        || fail "--mic-only needs SwitchAudioSource to route the default output into the loopback input: brew install switchaudio-osx"
    SwitchAudioSource -a -t output 2>/dev/null | grep -qx "$_MIC_ONLY_DEVICE" \
        || fail "--mic-only needs $_MIC_ONLY_DEVICE as an output device: brew install blackhole-2ch (then reboot or restart coreaudiod)"
    # The lane's actual premise, asserted rather than assumed: it feeds the
    # default OUTPUT, and only a default input that loops that back turns the
    # fixture into captured microphone audio. Without this check a host with a
    # real default microphone silences its speakers, records the room, and
    # fails 60 s later with a message blaming microphone capture.
    _MIC_ONLY_INPUT="$(SwitchAudioSource -c -t input 2>/dev/null || true)"
    [ "$_MIC_ONLY_INPUT" = "$_MIC_ONLY_DEVICE" ] \
        || fail "--mic-only needs the default INPUT to be $_MIC_ONLY_DEVICE (the loopback it routes the output into), but it is '$_MIC_ONLY_INPUT'. Set it in System Settings > Sound, or unplug the device that took over."
fi

# `autoWatch` triggers the same `.autoWatchStart` notification an
# explicit "Start Watching" menu click would — necessary because that
# menu isn't reachable over SSH. `debugRPCEnabled` brings the RPC up at
# launch instead of after a Settings toggle.
write_dev_default "$DEV_BUNDLE_ID" debugRPCEnabled true bool
write_dev_default "$DEV_BUNDLE_ID" autoWatch true bool
# The echo dedup ships off, so the lane has to ask for it. Set unconditionally
# rather than only for --echo-bleed: a stale toggle from an earlier run on the
# same host would otherwise decide it, and the lane that asserts nothing is
# removed on a clean pair needs the feature ON to mean anything.
write_dev_default "$DEV_BUNDLE_ID" echoDedupEnabled true bool
# Cancellation ships off and only one lane wants it. Written on every run, not
# just that one: left over from an earlier --echo-cancel run on the same host it
# would take precedence over the dedup, and the lane that asserts segments were
# removed would fail with the dedup standing down correctly.
#
# It has to be here, before the launch further down, which is also what bounds
# the restore in `on_exit`: the EXIT trap is installed after that launch, so a
# failure between this line and the trap leaves the key set. Tried moving the
# write below the trap to close that, and it moves the bug rather than fixing
# it — the app is already running by then and would never see the setting.
# Accepted, with the blast radius written down: the next invocation of this
# script writes the key again for whichever lane it is, so a runner self-heals,
# and what is exposed is a developer host keeping a default-off feature on until
# then.
write_dev_default "$DEV_BUNDLE_ID" echoCancellationEnabled "$ECHO_CANCEL" bool

if [ "$MIC_ONLY" = true ]; then
    # Record-only so the lane needs no ASR models, and auto-watch OFF so nothing
    # detects a meeting and starts a second recording next to the manual one.
    log "Enabling record-only mode and disabling auto-watch for the mic-only lane"
    write_dev_default "$DEV_BUNDLE_ID" recordOnly true bool
    write_dev_default "$DEV_BUNDLE_ID" autoWatch false bool
    mkdir -p "$RECORDINGS_DIR"
    touch "$RECORD_ONLY_MARKER"
    RECORD_ONLY=true   # reuse the record-only cleanup + marker-bounded sweep
elif [ "$RECORD_ONLY" = true ]; then
    log "Enabling record-only mode (no transcript/protocol generation)"
    write_dev_default "$DEV_BUNDLE_ID" recordOnly true bool
    mkdir -p "$RECORDINGS_DIR"
    touch "$RECORD_ONLY_MARKER"
else
    # Reset stale toggle from a previous --record-only run on the same host
    # so a plain `--two-meetings` invocation isn't silently still in record-only.
    delete_dev_default "$DEV_BUNDLE_ID" recordOnly
fi

# Optional diarizer-mode override. `MTT_DIARIZER_MODE=sortformer` flips the
# dev .app into Sortformer mode for this run — used by the Sortformer-naming
# lane to assert that Phase 1 of issue #165 (post-hoc WeSpeaker embeddings)
# actually lights up the naming dialog in production-chain. Always cleared
# on exit so subsequent runs return to the default `.offline` mode.
#
# Domain handling lives in `write_dev_default` / `delete_dev_default` (see
# scripts/lib/e2e-helpers.sh for why a bare `defaults write <bundle-id>` reaches
# a domain the app does not read). These two wrappers only bind the bundle id
# and keep the call sites below short.
_CONTAINER_PLIST="$(dev_container_plist)"
_STANDARD_PLIST="$(dev_standard_plist)"
_set_dev_default() {
    local key="$1" value="$2" type="${3:-string}"
    # `numSpeakers` is read as `defaults.object(forKey:) as? Int`, so it must be
    # written with `-int`; a string-typed write would fail the `as? Int` cast
    # and silently fall back to the auto-detect sentinel (0).
    write_dev_default "$DEV_BUNDLE_ID" "$key" "$value" "$type"
}
_delete_dev_default() {
    local key="$1"
    delete_dev_default "$DEV_BUNDLE_ID" "$key"
}

if [ "$QUIT_FLUSH" = true ]; then
    # No protocol provider, so a restored job finishes without calling out to
    # an LLM; restored on exit. Auto-watch stays ON, as every lane leaves it,
    # and here it is load-bearing: the app builds its pipeline queue, and with
    # it restores the snapshot, only when watching or a recording starts or a
    # file is imported. With auto-watch off a relaunch restores nothing until
    # the user does one of those, so the post-relaunch read would fail on a
    # property that is not the quit's. The manual start stops the watch loop,
    # so no detected meeting records next to the lane's recording.
    log "Disabling protocol generation for the quit-flush lane"
    _QF_PRE_PROVIDER="$(read_dev_default_effective "$DEV_BUNDLE_ID" "$_CONTAINER_PLIST" protocolProvider)"
    log "[quit-flush] protocolProvider before the lane: '${_QF_PRE_PROVIDER:-<unset>}' (restored on exit)"
    _set_dev_default protocolProvider none
fi

# The mic-stall lane runs no protocol generation: it asserts the recording and
# the transcript, and a configured Claude CLI or HTTP endpoint would otherwise be
# sent the fixture's transcript on every run. Restored to the host's own value
# in on_exit, since unlike the lane toggles above this one is a user's choice.
if [ -n "$MIC_STALL" ]; then
    # The record first, then the write, so no exit lands between a write and
    # the means to undo it. A record still here is one the repair at this
    # run's start could not restore (it said why): it still holds the host's
    # value, and what is set now is an earlier run's `none`.
    mkdir -p "$_MS_STATE_DIR"
    if [ -f "$_MS_PROTOCOL_RECORD" ]; then
        log "[mic-stall] an earlier run's protocolProvider record could not be restored yet; trying again with '$(cat "$_MS_PROTOCOL_RECORD")' at exit"
    else
        read_dev_default_effective "$DEV_BUNDLE_ID" "$_CONTAINER_PLIST" protocolProvider >"$_MS_PROTOCOL_RECORD"
    fi
    log "[mic-stall] protocol generation off for this run (was '$(cat "$_MS_PROTOCOL_RECORD")')"
    _set_dev_default protocolProvider none
fi

# The protocol lane: record the host's values, start the stub, then write, and
# the app reads all of it at launch. The cleanup is armed before the record, as
# the mic-stall lane does, because on_exit is installed only after the launch;
# on_exit runs it again.
if [ "$PROTOCOL_LANE" = true ]; then
    require_command python3
    # Any job the app resumes or recovers at launch would be sent to the stub
    # and saved with its canned reply as that meeting's protocol. In CI the
    # queue snapshot is reset before the launch (below) and the lane requires
    # an idle app before its first job; on any other host, refuse before the
    # lane changes any protocol setting while the queue holds an unfinished job
    # or the staging folder holds a recording a launch could recover. Finished
    # jobs do not count: the app drops them when it loads the snapshot.
    if [ "${GITHUB_ACTIONS:-}" != "true" ]; then
        _pp_data="$APP_HOME/Library/Application Support/MeetingTranscriber"
        _pp_snapshot="$_pp_data/ipc/pipeline_queue.json"
        if [ -f "$_pp_snapshot" ] && ! jq -e 'type == "array" and all(.[]; .state == "done" or .state == "error")' "$_pp_snapshot" >/dev/null 2>&1; then
            fail "[protocol] the pipeline queue snapshot holds unfinished jobs (or does not parse); the app would resume them against the stub. Let them finish first. No protocol setting was changed."
        fi
        _pp_staged="$(find "$_pp_data/recordings" -maxdepth 1 -type f \( -name '*.wav' -o -name '*.tmp' \) 2>/dev/null | head -3)"
        [ -z "$_pp_staged" ] \
            || fail "[protocol] the staging folder holds recordings a launch could recover and send to the stub: $_pp_staged. Process or move them first. No protocol setting was changed."
    fi
    trap '_pp_cleanup' EXIT
    mkdir -p "$_MS_STATE_DIR"
    rm -f "$_PP_RECORD.tmp"
    # Both domains write_dev_default writes; the container only if it exists.
    for _pp_plist in "$_STANDARD_PLIST" "$_CONTAINER_PLIST"; do
        [ "$_pp_plist" = "$_STANDARD_PLIST" ] || [ -f "$_pp_plist" ] || continue
        defaults_record_keys "$_PP_RECORD.tmp" "$_pp_plist" "${_PP_KEYS[@]}" \
            || fail "[protocol] could not record the host's protocol settings; no protocol setting was changed"
    done
    mv "$_PP_RECORD.tmp" "$_PP_RECORD"
    # The count, not the values: an endpoint can name a host, and this log is
    # public on CI.
    log "[protocol] recorded $(grep -c . "$_PP_RECORD") host setting(s) in $_PP_RECORD (restored on exit)"

    _PP_DIR="$(mktemp -d /tmp/e2e-protocol.XXXXXX)"
    python3 "$ROOT/scripts/fixtures/openai-chat-stub.py" \
        --port-file "$_PP_DIR/port" --log "$_PP_DIR/requests.jsonl" --mode-file "$_PP_DIR/mode" \
        --reply "$_PP_REPLY" >"$_PP_DIR/stub.log" 2>&1 &
    _PP_STUB_PID=$!
    _pp_stub_listening() { [ -s "$_PP_DIR/port" ]; }
    poll_until 10 0.2 _pp_stub_listening \
        || fail "[protocol] the stub did not start listening within 10s: $(cat "$_PP_DIR/stub.log")"
    _PP_PORT="$(cat "$_PP_DIR/port")"
    _PP_ENDPOINT="http://127.0.0.1:$_PP_PORT/v1"
    log "[protocol] stub (pid $_PP_STUB_PID) listening on $_PP_ENDPOINT"

    _set_dev_default protocolProvider openAICompatible
    _set_dev_default protocolLanguage "$_PP_LANGUAGE"
    _set_dev_default openAIEndpoint "$_PP_ENDPOINT"
    _set_dev_default openAIModel "$_PP_MODEL"
    _set_dev_default openAITemperature "$_PP_TEMPERATURE" float
    _delete_dev_default openAITopP
    # Diarize off, so the job never parks at speaker naming and the protocol is
    # generated in the pipeline's own stage rather than on a naming skip. The
    # output options pin the protocol file's exact contents and name, and keep
    # the transcript file the user message is compared with: an AI-title rename
    # would move every artifact to a stem taken from the stub's heading.
    _set_dev_default diarize false bool
    _set_dev_default saveRawTranscriptSeparately true bool
    _set_dev_default includeFullTranscriptInProtocol true bool
    _set_dev_default useAITitleForFilenames false bool
    defaults_mark_lane_values "$_PP_RECORD" \
        || fail "[protocol] could not read back the lane's own settings to mark them; restoring"
fi

if [ -n "${MTT_DIARIZER_MODE:-}" ]; then
    log "Overriding diarizerMode=$MTT_DIARIZER_MODE for this run"
    _set_dev_default diarizerMode "$MTT_DIARIZER_MODE"
else
    _delete_dev_default diarizerMode
fi

# --- speaker-DB snapshot/restore (naming-confirm lane, CI ONLY) -----------
#
# Confirming speaker names enrolls the voices into the real
# `speakers.json` and appends a row to `recognition_log.jsonl` (both under
# Application Support, via AppPaths). Left unmanaged that would permanently
# pollute the Mac mini runner's persistent speaker DB, which the
# Sortformer-naming lane's recognition expectations depend on. Snapshot both
# files before the lane and restore them from the exit trap (success AND
# failure). The snapshot also resets speakers.json to empty so the fixture's
# voices are guaranteed UNMATCHED, the clean precondition the transcript
# relabel assertion relies on (auto-name == raw SPEAKER_n label).
#
# GUARDED to CI via `$GITHUB_ACTIONS` (never set in a developer's shell), like
# the pipeline-queue reset above: the destructive reset/restore machinery must
# never touch a developer's real speaker DB. A LOCAL run therefore does NOT
# snapshot, so the confirm will enroll into your real DB (warned below).
_APP_SUPPORT_DIR="$APP_HOME/Library/Application Support/MeetingTranscriber"
# Durable, DETERMINISTIC backup siblings (not a random /tmp dir): a hard kill
# between the reset and the trap-restore would strand a random mktemp backup
# nothing ever finds again, losing the runner's real DB. Deterministic sibling
# paths let _naming_confirm_self_heal_db (run at every CI lane's startup) detect
# and restore a dead run's DB.
_NC_DB_FILES=(speakers.json recognition_log.jsonl)
_NC_DB_BACKUP_SUFFIX=".e2e-nc-backup"
_NC_DB_ABSENT_SUFFIX=".e2e-nc-absent"
# Per-domain (standard + container) pre-lane values of the settings this lane
# overrides, so cleanup restores EACH domain to exactly its own snapshot. A
# container-first read paired with a both-domain delete would wipe a
# standard-domain value that was never snapshotted. Initialised empty so the
# exit trap is `set -u`-safe even if it fires before the snapshot ran.
_NC_PRE_DIARIZE_STD=""
_NC_PRE_DIARIZE_CTR=""
_NC_PRE_NUMSPK_STD=""
_NC_PRE_NUMSPK_CTR=""
# Temp dir holding this lane's private COPY of the fixture (see run_naming_confirm
# for why a copy is mandatory). Cleaned up by _naming_confirm_cleanup on any exit.
_NC_FIXTURE_DIR=""

# Temp dir holding the echo lane's synthesised dual-source pairs. Its own mktemp
# dir, removed by on_exit; the shipped fixtures it is built from are read-only.
_ECHO_FIXTURE_DIR=""

# True when any durable backup / absent marker exists on disk.
_naming_confirm_backup_present() {
    local f
    for f in "${_NC_DB_FILES[@]}"; do
        [ -f "$_APP_SUPPORT_DIR/$f$_NC_DB_BACKUP_SUFFIX" ] && return 0
        [ -f "$_APP_SUPPORT_DIR/$f$_NC_DB_ABSENT_SUFFIX" ] && return 0
    done
    return 1
}

_naming_confirm_snapshot_db() {
    [ "${GITHUB_ACTIONS:-}" = "true" ] || return 0
    local f
    for f in "${_NC_DB_FILES[@]}"; do
        rm -f "$_APP_SUPPORT_DIR/$f$_NC_DB_BACKUP_SUFFIX" "$_APP_SUPPORT_DIR/$f$_NC_DB_ABSENT_SUFFIX"
        if [ -f "$_APP_SUPPORT_DIR/$f" ]; then
            # `|| true` so a copy failure falls through to the verify below (which
            # fails with a clear message) instead of a raw abort mid-loop.
            cp -p "$_APP_SUPPORT_DIR/$f" "$_APP_SUPPORT_DIR/$f$_NC_DB_BACKUP_SUFFIX" || true
        else
            : >"$_APP_SUPPORT_DIR/$f$_NC_DB_ABSENT_SUFFIX"
        fi
    done
    # NEVER destroy the live DB until its durable backup verifiably exists.
    if [ -f "$_APP_SUPPORT_DIR/speakers.json" ] \
        && [ ! -f "$_APP_SUPPORT_DIR/speakers.json$_NC_DB_BACKUP_SUFFIX" ]; then
        fail "[naming-confirm] durable speaker-DB backup failed; refusing to reset the live speakers.json"
    fi
    rm -f "$_APP_SUPPORT_DIR/speakers.json"
    log "[naming-confirm] CI: durable speaker-DB backup written; reset speakers.json to empty"
}

# Restore from the durable backup + clear the markers, verifying byte-identity.
# Shared by the exit-trap cleanup AND the startup self-heal, so a run that died
# mid-lane is recovered on the next lane's startup. Idempotent: no markers = no-op.
_naming_confirm_restore_db() {
    [ "${GITHUB_ACTIONS:-}" = "true" ] || return 0
    _naming_confirm_backup_present || return 0
    local f mismatch=""
    for f in "${_NC_DB_FILES[@]}"; do
        # cp guarded (this runs from a trap; a failed cp must log, not abort the
        # rest of cleanup). cmp confirms the restore is byte-identical.
        if [ -f "$_APP_SUPPORT_DIR/$f$_NC_DB_BACKUP_SUFFIX" ]; then
            if cp -p "$_APP_SUPPORT_DIR/$f$_NC_DB_BACKUP_SUFFIX" "$_APP_SUPPORT_DIR/$f"; then
                cmp -s "$_APP_SUPPORT_DIR/$f" "$_APP_SUPPORT_DIR/$f$_NC_DB_BACKUP_SUFFIX" || mismatch="$mismatch $f"
            else
                mismatch="$mismatch $f(copy-failed)"
            fi
        elif [ -f "$_APP_SUPPORT_DIR/$f$_NC_DB_ABSENT_SUFFIX" ]; then
            rm -f "$_APP_SUPPORT_DIR/$f"
        fi
        rm -f "$_APP_SUPPORT_DIR/$f$_NC_DB_BACKUP_SUFFIX" "$_APP_SUPPORT_DIR/$f$_NC_DB_ABSENT_SUFFIX"
    done
    # Log a diff rather than fail: this runs from a trap, and a restore warning
    # must not mask the run's real exit status.
    if [ -n "$mismatch" ]; then
        log "[naming-confirm] WARNING: speaker-DB restore diff:$mismatch"
    else
        log "[naming-confirm] CI: speaker DB restored from durable backup (verified)"
    fi
}

# Startup self-heal: if a prior naming-confirm run died between the reset and its
# restore, its durable backup is still on disk. Restore it before anything else
# touches the DB. Runs for EVERY lane (CI-gated) so a different lane following a
# dead naming-confirm run still recovers the real DB. Logs even when clean, so
# its execution is visible in the run log.
_naming_confirm_self_heal_db() {
    [ "${GITHUB_ACTIONS:-}" = "true" ] || return 0
    if _naming_confirm_backup_present; then
        log "[naming-confirm] CI: leftover durable speaker-DB backup from a prior run detected; self-healing"
        _naming_confirm_restore_db
    else
        log "[naming-confirm] CI: no leftover speaker-DB backup to self-heal"
    fi
}

# Full naming-confirm teardown: restore the DB + the lane's diarize/numSpeakers
# overrides (per domain, to their exact pre-lane values), then log the restored
# effective values. Registered as the naming-confirm hook of the single on_exit
# trap (no second trap arming); idempotent (DB restore no-ops once markers clear,
# a re-restore of an already-restored default is a harmless re-write/delete).
_naming_confirm_cleanup() {
    # Remove the lane's private fixture copy (our own mktemp dir; not CI-gated).
    if [ -n "${_NC_FIXTURE_DIR:-}" ] && [ -d "$_NC_FIXTURE_DIR" ]; then
        rm -rf "$_NC_FIXTURE_DIR"
        _NC_FIXTURE_DIR=""
    fi
    _naming_confirm_restore_db
    # Restore each domain to exactly its own snapshot. The shared restore_*_default
    # helpers translate `defaults read`'s 1/0 into the -bool true/false tokens and
    # write -int for numSpeakers (a raw 1/0 into `-bool` errors; see the helpers).
    restore_bool_default "$_STANDARD_PLIST" diarize "$_NC_PRE_DIARIZE_STD"
    restore_int_default "$_STANDARD_PLIST" numSpeakers "$_NC_PRE_NUMSPK_STD"
    if [ -f "$_CONTAINER_PLIST" ]; then
        restore_bool_default "$_CONTAINER_PLIST" diarize "$_NC_PRE_DIARIZE_CTR"
        restore_int_default "$_CONTAINER_PLIST" numSpeakers "$_NC_PRE_NUMSPK_CTR"
    fi
    local now_diarize now_num
    now_diarize="$(read_dev_default_effective "$DEV_BUNDLE_ID" "$_CONTAINER_PLIST" diarize)"
    now_num="$(read_dev_default_effective "$DEV_BUNDLE_ID" "$_CONTAINER_PLIST" numSpeakers)"
    log "[naming-confirm] settings restored (effective diarize='$now_diarize' numSpeakers='$now_num')"
}

# Self-heal a dead prior run's DB before anything touches it (CI-gated, all lanes).
_naming_confirm_self_heal_db
if [ "$NAMING_CONFIRM" = true ] || [ "$NAMING_ESCAPE" = true ] || [ "$NAMING_SWITCH" = true ]; then
    # The switch lane pins the app track to ONE remote cluster: the setting
    # applies to the app track only (the mic track always auto-detects), and
    # with a single remote speaker the mic clusters alone decide where
    # R_SPEAKER_00 sits, which is the position the lane needs to move.
    _NAMING_NUM_SPEAKERS=2
    [ "$NAMING_SWITCH" = true ] && _NAMING_NUM_SPEAKERS=1
    log "Enabling naming lane (diarize on, expected speakers = $_NAMING_NUM_SPEAKERS)"
    # Snapshot BOTH domains (standard + container) BEFORE overriding so cleanup
    # restores each domain to exactly its own pre-lane state.
    _NC_PRE_DIARIZE_STD="$(snapshot_default "$_STANDARD_PLIST" diarize)"
    _NC_PRE_NUMSPK_STD="$(snapshot_default "$_STANDARD_PLIST" numSpeakers)"
    if [ -f "$_CONTAINER_PLIST" ]; then
        _NC_PRE_DIARIZE_CTR="$(snapshot_default "$_CONTAINER_PLIST" diarize)"
        _NC_PRE_NUMSPK_CTR="$(snapshot_default "$_CONTAINER_PLIST" numSpeakers)"
    fi
    log "[naming-confirm] pre-lane diarize(std='$_NC_PRE_DIARIZE_STD' ctr='$_NC_PRE_DIARIZE_CTR') numSpeakers(std='$_NC_PRE_NUMSPK_STD' ctr='$_NC_PRE_NUMSPK_CTR')"
    _set_dev_default diarize true bool
    _set_dev_default numSpeakers "$_NAMING_NUM_SPEAKERS" int
    if [ "${GITHUB_ACTIONS:-}" != "true" ] && [ "$NAMING_ESCAPE" != true ]; then
        # Escape-lane runs never confirm — they dismiss — so nothing reaches
        # updateSpeakerDB and the warning would be a false alarm on the one run
        # people are told to perform by hand (the TCC setup run).
        log "[naming-confirm] WARNING: not running under CI. The speaker-DB"
        log "[naming-confirm] snapshot/restore is \$GITHUB_ACTIONS-gated, so this run"
        log "[naming-confirm] WILL enroll the fixture voices into your real"
        log "[naming-confirm] $_APP_SUPPORT_DIR/speakers.json (+ recognition_log.jsonl)."
    fi
    # Durably back up + reset the DB. No interim trap here (one-trap design): the
    # window before on_exit is armed is covered by _naming_confirm_self_heal_db
    # (called above), which restores a dead run's durable backup at the next
    # lane's startup, and the snapshot verifies the backup exists before the reset.
    _naming_confirm_snapshot_db
fi

# LaunchServices' `open` routes to the WindowServer of the *foreground* Aqua
# session, not just any session with our UID loaded. If a second user is
# signed in via Fast User Switching and currently has the foreground, our
# LaunchAgent's `open` lands in an inactive session and LaunchServices
# returns the misleading `procNotFound (-600)`. Catch this before the call
# so the failure is actionable instead of cryptic.
fg_user=$(stat -f "%Su" /dev/console)
my_user=$(id -un)
if [ "$fg_user" != "$my_user" ]; then
    fail "Aqua foreground user is '$fg_user', not '$my_user' — Fast User Switching is active. On the Mac mini, log '$fg_user' out completely (Apple menu → Log Out '$fg_user'…), then re-trigger this workflow."
fi

# Stale pipeline-queue reset (CI ONLY). A persisted errored job in
# `ipc/pipeline_queue.json` is recovered on every launch and surfaces as
# `lastJob`, so a single genuine silent-capture flake turns into a permanent
# red across all later runs — the same job UUID + frozen `enqueuedAt` reappear
# run-to-run (observed 2026-06-03: 7ABA2BA8… with a monotonically growing
# durationSec). The app was already stopped above (`quit_running_app`), so the
# snapshot is static here.
#
# GUARDED to CI via `$GITHUB_ACTIONS` — that variable is set only inside a
# GitHub Actions runner, NEVER in a developer's shell, so this branch can
# never execute on a local / production machine. It also removes ONLY the
# regenerable queue snapshot — never recordings, speakers.json, protocols, or
# any other user content.
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    _ipc_dir="$HOME/Library/Application Support/MeetingTranscriber/ipc"
    rm -f "$_ipc_dir/pipeline_queue.json" "$_ipc_dir/pipeline_queue.tmp"
    log "CI: reset stale pipeline-queue snapshot ($_ipc_dir/pipeline_queue.json)"
fi

[ "$UPGRADE" = true ] && _ug_seed

log "Launching $DEV_BUNDLE_DEPLOY"
if [ -n "$MIC_STALL" ]; then
    # `open --env`, not a leading `env`: only the former reaches a process
    # LaunchServices starts (see the e2e-architecture skill).
    log "[mic-stall] app home $APP_HOME, microphone fault '$MIC_STALL'"
    open --env CFFIXED_USER_HOME="$APP_HOME" --env MEETINGTRANSCRIBER_E2E_MIC_FAULT="$MIC_STALL" "$DEV_BUNDLE_DEPLOY"
elif [ "$UPGRADE" = true ]; then
    log "[upgrade] app home $APP_HOME, network closed but for localhost"
    _ug_launch
elif [ "$MIC_DEVICE_CHANGE" = true ]; then
    # The fault build injects nothing unless asked, so a leftover fault bundle
    # cannot inject into a later, unrelated launch.
    open --env MEETINGTRANSCRIBER_E2E_MIC_FAULT=device-change "$DEV_BUNDLE_DEPLOY"
else
    open "$DEV_BUNDLE_DEPLOY"
fi

log "Waiting up to ${RPC_READY_TIMEOUT_S}s for RPC /healthz"
# Assigns RPC_TOKEN in caller scope on success so subsequent `rpc` calls
# carry the bearer token.
# `rpc` ends in `|| true` so its callers can read a body without tripping
# `set -e`, which also means it reports success for a refused connection. That
# made this check "the token file exists", and the token file survives every
# previous run on the host, so "RPC up" could be logged 70 ms after launch with
# nothing listening yet. Ask curl directly and let its exit status decide.
_rpc_ready() {
    [ -f "$RPC_TOKEN_FILE" ] || return 1
    RPC_TOKEN="$(cat "$RPC_TOKEN_FILE")"
    curl --silent --fail --max-time 5 \
        --header "Authorization: Bearer $RPC_TOKEN" \
        "$RPC_BASE/healthz" >/dev/null 2>&1
}
poll_until "$RPC_READY_TIMEOUT_S" 1 _rpc_ready \
    || fail "RPC /healthz did not respond within ${RPC_READY_TIMEOUT_S}s"
log "RPC up"
# Record which app this driver started, for the provenance guard above.
_record_launched_app() {
    _launched_app="$( { pgrep -f "$_DEV_APP_PATTERN" || true; } | head -1)"
    if [ -n "$_launched_app" ]; then
        mkdir -p "$(dirname "$_E2E_APP_MARKER")"
        printf '%s launched' "$_launched_app" >"$_E2E_APP_MARKER"
    fi
}
_record_launched_app


# Single trap covers the simulator process + record-only side-effects for
# any exit path (success, fail, signal). Set before the first `&` line so
# a kill between fork and the trap line doesn't orphan the subprocess.
SIM_PID=""
_ON_EXIT_RAN=""
on_exit() {
    # Run exactly once. The INT/TERM traps below run on_exit then `exit`, and
    # that exit re-fires the EXIT trap, and without this guard on_exit would run
    # twice on a signal (harmless because every step is idempotent, but noisy).
    [ -n "$_ON_EXIT_RAN" ] && return 0
    _ON_EXIT_RAN=1
    # Quit-flush: stop the app, remove what this run's unreleased jobs wrote,
    # and put the shared pipeline state back. First, because the restore needs
    # the app stopped, and the provenance marker below then sees it gone.
    if [ "$QUIT_FLUSH" = true ] && [ -n "$_QF_BACKUP_DIR" ]; then
        _qf_restore_shared_state
    fi
    # Upgrade: stop the app this lane started and remove its home, before the
    # provenance below, which then finds the app gone. A no-op for other lanes.
    _ug_cleanup
    # Protocol lane: stop the stub, put the host's settings back, stop the app,
    # drop the lane's unfinished jobs and its outputs (see `_pp_cleanup`).
    # Before the provenance below, which then finds the app gone.
    if [ "$PROTOCOL_LANE" = true ]; then
        _pp_cleanup || _PP_RESTORE_FAILED=1
    fi
    # Leave the app's provenance for the next driver: still running means this
    # run kept it (--keep-app) or failed before the quit; gone means we quit it.
    if [ -n "${_launched_app:-}" ]; then
        if pgrep -f "$_DEV_APP_PATTERN" >/dev/null 2>&1; then
            if [ "$APP_AFTER" = leave ]; then
                printf '%s kept' "$_launched_app" >"$_E2E_APP_MARKER"
            else
                printf '%s abandoned' "$_launched_app" >"$_E2E_APP_MARKER"
            fi
        else
            rm -f "$_E2E_APP_MARKER"
        fi
    fi
    [ -n "${SIM_PID:-}" ] && kill "$SIM_PID" 2>/dev/null || true
    if [ "$MIC_ONLY" = true ]; then
        # The lane turns auto-watch off; nothing else here would turn it back
        # on, and a human using the dev app on this host would find detection
        # silently disabled.
        write_dev_default "$DEV_BUNDLE_ID" autoWatch true bool
    fi
    if [ "$QUIT_FLUSH" = true ]; then
        [ -n "${_QF_AFPLAY_PID:-}" ] && kill "$_QF_AFPLAY_PID" 2>/dev/null || true
        if [ -n "${_QF_PRE_PROVIDER:-}" ]; then
            _set_dev_default protocolProvider "$_QF_PRE_PROVIDER"
        else
            _delete_dev_default protocolProvider
        fi
    fi
    if [ "$ECHO_CANCEL" = true ]; then
        # Back to the shipped default rather than to whatever was there before:
        # the write at launch already clobbered the old value on every run, so
        # there is nothing to restore, and false is what a user of this bundle
        # should find. Without this the lane leaves echo cancellation ON for
        # every later run_app.sh session and every e2e-browser.sh run, neither
        # of which writes the key.
        write_dev_default "$DEV_BUNDLE_ID" echoCancellationEnabled false bool
    fi
    if [ "$RECORD_ONLY" = true ]; then
        delete_dev_default "$DEV_BUNDLE_ID" recordOnly
        # Marker-bounded cleanup: only files created since `touch $MARKER`
        # at launch — never touches pre-existing user data. See feedback
        # memory `no_destructive_fs_on_real_dirs`. Skipped under
        # --keep-recordings so a follow-up --reimport-latest run can pick
        # the WAV up.
        if [ "$KEEP_RECORDINGS" = false ] && [ -f "$RECORD_ONLY_MARKER" ]; then
            find "$RECORDINGS_DIR" -type f -newer "$RECORD_ONLY_MARKER" -delete 2>/dev/null || true
            rm -f "$RECORD_ONLY_MARKER"
        fi
    fi
    # Always clear the diarizerMode override so the next run on this host
    # starts from the AppSettings default (.offline) regardless of which
    # lane left it set. Clears both standard and container plists for the
    # same reason `_set_dev_default` writes to both.
    if [ -n "${MTT_DIARIZER_MODE:-}" ]; then
        _delete_dev_default diarizerMode
    fi
    # Crash-recovery: remove only THIS run's recording artifacts (the exact
    # stem we created). Stem-targeted, so it never touches pre-existing user
    # recordings. See feedback memory `no_destructive_fs_on_real_dirs`.
    if [ "$CRASH_RECOVERY" = true ] && [ -n "${CRASH_STEM:-}" ]; then
        rm -f "$CRASH_RECORDINGS/${CRASH_STEM}"* 2>/dev/null || true
        [ -n "${CRASH_MARKER:-}" ] && rm -f "$CRASH_MARKER"
    fi
    # Naming-confirm: restore the runner's real speaker DB (CI-gated, no-op
    # locally) and the lane's diarize/numSpeakers overrides so a later run on
    # this host starts from the AppSettings defaults.
    if [ "$NAMING_CONFIRM" = true ] || [ "$NAMING_ESCAPE" = true ] || [ "$NAMING_SWITCH" = true ]; then
        _naming_confirm_cleanup
    fi
    # Naming-switch: drop its compiled driver and synthesised pairs (our own
    # mktemp dir, never a real recordings directory).
    if [ -n "${_NS_DIR:-}" ] && [ -d "$_NS_DIR" ]; then
        rm -rf "$_NS_DIR"
        _NS_DIR=""
    fi
    # Mic-only: hand the machine's audio output back before anything else runs
    # on this host. Unconditional, not gated on $MIC_ONLY, so a marker left by a
    # previous run is cleared even when this run never touched the routing.
    _mic_only_restore_output
    # Mic-stall: the host's protocol provider back, then the lane's own home
    # (see `_ms_cleanup`). Our own mktemp dir: the model link inside it is
    # removed as a link.
    [ -n "$MIC_STALL" ] && _ms_cleanup
    # Echo lane: drop the synthesised pairs (our own mktemp dir, never a real
    # recordings directory).
    if [ -n "${_ECHO_FIXTURE_DIR:-}" ] && [ -d "$_ECHO_FIXTURE_DIR" ]; then
        rm -rf "$_ECHO_FIXTURE_DIR"
        _ECHO_FIXTURE_DIR=""
    fi
    _qf_release_lock
    # A restore that did not match turns any run red, a passing one included.
    [ -z "${_QF_RESTORE_FAILED:-}" ] || exit 1
    [ -z "${_PP_RESTORE_FAILED:-}" ] || exit 1
}
# Single cleanup hook, but the signal paths must EXIT after cleaning up: a
# trapped INT/TERM otherwise returns into the interrupted command and execution
# continues (e.g. the confirm would re-pollute a just-restored DB). Only the
# EXIT trap runs cleanup-without-exit (the shell is already leaving). 130 = 128+SIGINT,
# 143 = 128+SIGTERM, the conventional shell exit codes for those signals.
trap on_exit EXIT

trap 'on_exit; exit 130' INT
trap 'on_exit; exit 143' TERM

# The lane configures the app by writing preferences from the shell, and a write
# that misses the domain the app resolves is completely silent: the app runs on
# its own defaults, and the lane fails minutes later with a missing artifact
# that says nothing about why. `/state.settings` is the running process's own
# resolved view, so assert it here, where the answer is still cheap and points
# at the cause. recordOnly is the setting under test because it decides which
# pipeline runs at all.
#
# Placed AFTER the exit trap is armed, not next to the readiness poll where it
# logically belongs: this assertion can fail, and failing ahead of the trap
# would leave the app running with this lane's recordOnly and autoWatch
# unrestored.
if [ "$RECORD_ONLY" = true ]; then _EXPECTED_RECORD_ONLY=true; else _EXPECTED_RECORD_ONLY=false; fi
# A 200 from /healthz is not proof the app under test is the one answering, and
# neither is an answer from /state: one without the field would read as a null
# setting, which would get reported as the wrong preference domain. Require the
# field itself to be present before believing anything about its value.
poll_state 20 1 state_is '.settings.recording | has("recordOnly")' \
    || fail "$(state_why $? "/healthz answered but no /state carrying settings.recording.recordOnly arrived within 20s. Either the app came up without serving a state snapshot, or something other than the dev app is holding 127.0.0.1:9876.")"
_SNAP="$STATE_BODY"
_RESOLVED_RECORD_ONLY="$(jq -r '.settings.recording.recordOnly' <<<"$_SNAP")"
[ "$_RESOLVED_RECORD_ONLY" = "$_EXPECTED_RECORD_ONLY" ] \
    || fail "the app resolved settings.recording.recordOnly=$_RESOLVED_RECORD_ONLY but this lane needs $_EXPECTED_RECORD_ONLY. Most likely the preference write did not reach the domain the app reads (see write_dev_default in scripts/lib/e2e-helpers.sh); the other possibility is that a different MeetingTranscriber instance is answering on 127.0.0.1:9876."
log "app resolved recordOnly=$_RESOLVED_RECORD_ONLY (as configured)"

# Same reasoning one field over: every artifact assertion in this lane is built
# on `$OUTPUT_DIR`, a literal restatement of a path the app owns and the user
# can repoint (Settings, a security-scoped bookmark). Restating an app-owned
# path is what made the record-only assertion vacuous in the first place, so
# assert the agreement here instead of searching a tree the app never writes to
# and reporting the emptiness as a pass.
#
# `null` means a custom bookmark is set and did not resolve just now, which is a
# real app state but not one this lane can assert against, so it fails too.
_RESOLVED_OUTPUT_DIR="$(jq -r '.settings.output.directory // "null"' <<<"$_SNAP")"
[ "${_RESOLVED_OUTPUT_DIR%/}" = "${OUTPUT_DIR%/}" ] \
    || fail "the app writes to '$_RESOLVED_OUTPUT_DIR' but this lane asserts against '$OUTPUT_DIR'. Every artifact check here would search a tree the app never touches and report the emptiness as a pass. Clear the custom Output Folder on this host, or point the lane at the app's directory."
log "app resolved output directory=$_RESOLVED_OUTPUT_DIR (as assumed)"



# Trigger one meeting, poll until a new pipeline job reaches a terminal
# state, assert it landed in `done` with a non-trivial transcript. Reads
# `$1` as a human label for log lines ("meeting 1 of 2", etc.). Mutates
# `PRE_LAST_JOB_ID` so the next call recognises the next job as new.
PRE_LAST_JOB_ID=""
# Capture the pre-trigger baseline only AFTER the app's async
# `recoverOrphanedRecordings()` / `loadSnapshot()` has settled. Those run off
# the main actor a beat after launch, so a job they recover isn't yet visible
# the instant RPC comes up. If we baseline too early, a recovered job appears
# *after* the baseline and the poll loop's `id != PRE_LAST_JOB_ID` test
# mistakes it for the job THIS trigger produced — and a recovered *errored*
# job (see the CI reset above) fails the run before the fresh recording even
# finishes. Poll until `lastJob.jobID` is stable across two reads (bounded
# ~15 s), then baseline. Read-only — touches no files, safe on any machine.
# An unanswered read is no reading at all: it used to come out as an empty id,
# two of which looked stable and baselined "no job".
_pre_prev="" _pre_stable=0
for _ in $(seq 1 15); do
    if ! _pre_cur="$(state_query '.lastJob.jobID // ""' 2>/dev/null)"; then
        _pre_stable=0 _pre_prev="(no answer)"
        sleep 1
        continue
    fi
    if [ "$_pre_cur" = "$_pre_prev" ]; then
        _pre_stable=$(( _pre_stable + 1 ))
        [ "$_pre_stable" -ge 2 ] && break
    else
        _pre_stable=0
    fi
    _pre_prev="$_pre_cur"
    sleep 1
done
# The value found stable is the baseline; only a loop that ran out without
# settling needs another read.
if [ "$_pre_stable" -ge 2 ]; then
    PRE_LAST_JOB_ID="$_pre_cur"
else
    PRE_LAST_JOB_ID="$(state_query '.lastJob.jobID // empty')" \
        || fail "$(state_why $? "the pre-trigger lastJob baseline")"
fi
log "Pre-trigger lastJob.jobID: ${PRE_LAST_JOB_ID:-<none>}"

# Shared poll loop used by every flow that triggers a pipeline job
# (`run_one_meeting`, `run_one_reimport`). Polls /state every 5 s, drains
# speaker-naming dialogs along the way, breaks when a NEW lastJob (id
# different from $PRE_LAST_JOB_ID) reaches `.done` or `.error`.
#
# On success: sets globals POLL_LJ_ID, POLL_LJ_STATE for the caller's
# post-poll assertions. On PIPELINE_TIMEOUT_S elapsed: calls `fail()`.
#
# One jq invocation, four fields out via `|`-joined output saves 3 forks
# per poll. `|` (not `@tsv`) keeps consecutive empty fields as boundaries
# — bash `IFS=$'\t' read` collapses them and misparses a fully-null
# lastJob.
#
# The loop is poll_state's: a tick the app does not answer (e.g. a timeout
# during model load) is skipped and logged rather than read as empty fields,
# and a deadline reached while it is not answering says so instead of
# blaming the pipeline. assert_app_alive runs on every tick through --each,
# answered or not, so a dead app fails at once instead of after the full
# ${PIPELINE_TIMEOUT_S}s of unanswered reads. --judge-deadline-read: the
# verdict is in the snapshot itself (a job that is new and terminal), so the
# read that follows a gap at the deadline counts like any answered tick. That
# lets a job finishing up to about two read bounds (2 x STATE_READ_BOUND_S)
# past ${PIPELINE_TIMEOUT_S}s pass, which is accepted: the timeout is a hang
# guard, not a latency budget, and an answered last tick already overruns it
# by up to one bound.
#
# The poll's last read is the terminal snapshot, left in STATE_BODY, so the
# callers' post-poll assertions read the same snapshot the verdict came from.
# Nothing may call state_read (or state_query, poll_state, watch_state)
# between this function's return and those reads: it would replace
# STATE_BODY with a later snapshot.
POLL_LJ_ID=""
POLL_LJ_STATE=""
_poll_for_new_lastjob_terminal() {
    local label="$1"
    # When $2 is non-empty, launch-recovery jobs ("Recovered Recording (...)")
    # never satisfy the wait: a stale orphan from a previous run is recovered
    # at app launch and races the simulator-triggered job — three CI reds in
    # one day came from lanes mistaking that recovery job for their own. The
    # crash-recovery lane omits the flag; its expected job IS the recovered one.
    local ignore_recovered="${2:-}"
    log "$label: polling /state every 5s for new lastJob (timeout ${PIPELINE_TIMEOUT_S}s)"
    local last_state="" last_id="" noted_recovered="" status=0
    local lj_id="" lj_state="" lj_recovered="" pipe_active="" pipe_processing="" pending_naming=""

    poll_state --each assert_app_alive --judge-deadline-read "$PIPELINE_TIMEOUT_S" 5 _lastjob_tick || status=$?
    case "$status" in
        0) ;;
        1) fail "$label: no new pipeline job reached terminal state within ${PIPELINE_TIMEOUT_S}s (active=$pipe_active processing=$pipe_processing)" ;;
        *) fail "$(state_why "$status" "$label: whether a new pipeline job reached a terminal state within ${PIPELINE_TIMEOUT_S}s (last answered: active=$pipe_active processing=$pipe_processing)")" ;;
    esac

    POLL_LJ_ID="$lj_id"
    POLL_LJ_STATE="$lj_state"
}

# One tick of _poll_for_new_lastjob_terminal, on an answered STATE_BODY. Reads
# and writes that function's locals (bash dynamic scoping).
_lastjob_tick() {
    lj_id=""; lj_state=""; lj_recovered=""; pipe_active=""; pipe_processing=""; pending_naming=""
    IFS='|' read -r lj_id lj_state lj_recovered pipe_active pipe_processing pending_naming < <(
        jq -r '[.lastJob.jobID // "", .lastJob.state // "", ((.lastJob.meetingTitle // "") | startswith("Recovered Recording")), .pipeline.activeJobCount, .pipeline.isProcessing, .pipeline.pendingNamingJobCount] | join("|")' <<<"$STATE_BODY"
    ) || true

    # Drain speaker-naming dialogs so headless runs don't deadlock on a
    # UI click. Fire-and-forget; the endpoint is a no-op when nothing
    # is pending and the next tick picks up the state change.
    if [ "${pending_naming:-0}" != "0" ] && [ -n "$pending_naming" ]; then
        # Capture pendingNamingJobs[0].speakerCount the FIRST time we
        # observe a pending naming job — before /action/skipNaming
        # clears the queue. Surfaces the speaker-count Phase 1 of
        # issue #165 promises: Sortformer mode must populate
        # `result.embeddings` so the naming dialog sees N>0 speakers.
        # Without this capture there's no production-chain signal that
        # the embedding-extraction wiring is actually producing output.
        if [ -z "${OBSERVED_NAMING_SPEAKERS:-}" ]; then
            OBSERVED_NAMING_SPEAKERS="$(jq -r '.pendingNamingJobs[0].speakerCount // 0' <<<"$STATE_BODY")" || OBSERVED_NAMING_SPEAKERS=0
            log "$label:   First observed pendingNamingJobs[0].speakerCount=$OBSERVED_NAMING_SPEAKERS"
        fi
        log "$label:   Auto-skipping ${pending_naming} pending naming job(s) via /action/skipNaming"
        curl --silent --show-error --max-time 5 -X POST \
            --header "Authorization: Bearer $RPC_TOKEN" \
            "$RPC_BASE/action/skipNaming" >/dev/null 2>&1 || true
    fi

    if [ "$lj_state" != "$last_state" ] || [ "$lj_id" != "$last_id" ]; then
        log "$label:   pipeline.active=$pipe_active processing=$pipe_processing lastJob=$lj_id state=$lj_state pending_naming=$pending_naming"
        last_state="$lj_state"
        last_id="$lj_id"
    fi

    if [ -n "$ignore_recovered" ] && [ "$lj_recovered" = "true" ] \
        && [ "$lj_id" != "$PRE_LAST_JOB_ID" ] && [ "$lj_id" != "${noted_recovered:-}" ]; then
        log "$label:   ignoring launch-recovery job $lj_id (state=$lj_state) — waiting for the simulator-triggered job"
        noted_recovered="$lj_id"
    fi
    [ -n "$lj_id" ] && [ "$lj_id" != "$PRE_LAST_JOB_ID" ] \
        && { [ -z "$ignore_recovered" ] || [ "$lj_recovered" != "true" ]; } \
        && { [ "$lj_state" = "done" ] || [ "$lj_state" = "error" ]; }
}

# jq filter: whether the speaker-naming window is on screen (the naming lanes).
_NAMING_WINDOW_VISIBLE='[.windows[] | select(.id == "speaker-naming") | .isVisible] | first // false'

# _read_transcript_size <label> <path> — the transcript's size into
# TRANSCRIPT_SIZE, read under a bound, failing the lane below 101 bytes. The job's preflight step catches a
# missing Downloads grant up front; this is the backstop for a lane run by
# hand or a grant lost mid-job, where a bare `wc -c` once blocked behind a
# consent prompt until the step timeout and outlived it. Called before the
# first read of the transcript's contents in the transcript, re-import and
# naming-confirm lanes; other reads of the output folder stay unbounded and
# rely on the preflight.
_read_transcript_size() {
    local label="$1" path="$2" bound="${E2E_READ_BOUND_S:-30}" out status=0
    out="$(run_bounded "$bound" wc -c "$path" 2>&1)" || status=$?
    local verdict
    verdict="$(tcc_probe_verdict "$status" "$out")"
    # Only the real ~/Downloads is TCC-guarded; the isolated-home lanes keep
    # their output under $TMPDIR, where a hang has some other cause.
    case "$path" in "$HOME/Downloads/"*) ;; *) [ "$verdict" = granted ] || verdict=error ;; esac
    case "$verdict" in
        granted) TRANSCRIPT_SIZE="$(awk '{ print $1; exit }' <<<"$out")" ;;
        blocked) fail "$label: reading the transcript $path did not return within ${bound}s: blocked, most likely behind a TCC consent prompt. Fix: $(tcc_fix_hint 'Files & Folders → Downloads')" ;;
        denied) fail "$label: reading the transcript $path was refused ($out). Fix: $(tcc_fix_hint 'Files & Folders → Downloads')" ;;
        *) fail "$label: could not read the transcript $path (exit $status, 124 = no answer within ${bound}s): $out" ;;
    esac
    [ "$TRANSCRIPT_SIZE" -gt 100 ] || fail "$label: transcript suspiciously short: $TRANSCRIPT_SIZE bytes (expected > 100)"
}

# Fail the lane unless the transcript reads as German. Guards the
# live-recording lanes against a transcript that clears the >100-byte size
# check but is actually garbage — wrong-language hallucination, silent-capture
# noise, or an empty-ish file. Logs which words matched so a near-miss is
# diagnosable straight from the CI log.
assert_transcript_is_german() {
    local label="$1" transcript_path="$2"
    if ! transcript_is_german "$transcript_path"; then
        fail "$label: transcript does not read as German — matched only $GERMAN_MARKER_MATCHED/${#GERMAN_MARKER_WORDS[@]} common German words (need >= $GERMAN_MARKER_WORDS_MIN), so it is likely an English hallucination or garbage despite passing the >100-byte size check. matched=[$GERMAN_MARKER_HITS]. Preview:"$'\n'"$(head -c 500 "$transcript_path")"
    fi
    log "$label: transcript content OK — matched $GERMAN_MARKER_MATCHED/${#GERMAN_MARKER_WORDS[@]} German words [$GERMAN_MARKER_HITS]"
}

run_one_meeting() {
    local label="$1"
    # Reset between meetings so --two-meetings captures each run's first
    # observed naming-dialog speaker count, not just meeting 1's stale value.
    OBSERVED_NAMING_SPEAKERS=""
    log "$label: starting meeting-simulator → $SIMULATOR_FIXTURE"
    "$SIMULATOR_BIN" "$SIMULATOR_FIXTURE" >/tmp/e2e-app-sim.log 2>&1 &
    SIM_PID=$!

    _poll_for_new_lastjob_terminal "$label" ignore-recovered
    local lj_id="$POLL_LJ_ID" lj_state="$POLL_LJ_STATE"

    log "$label: final state: $lj_state"
    local final_snapshot
    final_snapshot="$STATE_BODY"
    echo "$final_snapshot" | jq '.lastJob'

    [ "$lj_state" = "done" ] || fail "$label: lastJob.state == \"$lj_state\", expected \"done\". Error: $(jq -r '.lastJob.error // "<none>"' <<<"$final_snapshot")"

    local transcript_path
    transcript_path="$(jq -r '.lastJob.transcriptPath // empty' <<<"$final_snapshot")"
    [ -n "$transcript_path" ] || fail "$label: lastJob.transcriptPath is empty"
    [ -f "$transcript_path" ] || fail "$label: transcript file does not exist: $transcript_path"

    _read_transcript_size "$label" "$transcript_path"

    log "$label: transcript $transcript_path ($TRANSCRIPT_SIZE bytes)"
    log "$label: preview:"
    head -c 500 "$transcript_path" | sed 's/^/    /'

    # Content assertion: a >100-byte transcript can still be garbage (an
    # empty-ish file, a wrong-language hallucination, or silent-capture noise
    # all clear the size gate). For the known fixture, require its German
    # content words actually appear so this lane can't go green on a broken
    # audio-path or wrong-language regression.
    if [ "$MIC_DEVICE_CHANGE" = true ]; then
        # Survival lane (issue #379): the injected mid-recording tap fault can
        # degrade capture, and its PASS criterion is "app survived + recording
        # completed", not ASR content quality. A content gate here would risk a
        # false regression that masks the real survival signal, so skip it.
        log "$label: mic-device-change survival lane — skipping content keyword assertion"
    elif [ "$IS_DEFAULT_FIXTURE" = true ]; then
        assert_transcript_is_german "$label" "$transcript_path"
    else
        # Custom --fixture: unknown spoken content, so keep only the size check.
        log "$label: custom fixture — skipping content keyword assertion (size check only)"
    fi

    # Phase 1 of #165 production-chain assertion: when caller sets
    # MTT_EXPECT_NAMING_SPEAKERS_MIN, require that the pending naming
    # dialog observed during this run carried at least N speakers.
    # `OBSERVED_NAMING_SPEAKERS` is populated inside the poll loop when
    # the first `pendingNamingJobs[0]` appears (before /action/skipNaming
    # drains it). Default lane (offline) doesn't set the gate; the
    # Sortformer-mode lane wires it via `MTT_EXPECT_NAMING_SPEAKERS_MIN=1`
    # so a regression that returns `embeddings: nil` would surface as
    # "speakerCount=0, naming dialog never opened".
    if [ -n "${MTT_EXPECT_NAMING_SPEAKERS_MIN:-}" ]; then
        observed="${OBSERVED_NAMING_SPEAKERS:-0}"
        if [ "$observed" -lt "$MTT_EXPECT_NAMING_SPEAKERS_MIN" ]; then
            fail "$label: pendingNamingJobs[0].speakerCount=$observed < MTT_EXPECT_NAMING_SPEAKERS_MIN=$MTT_EXPECT_NAMING_SPEAKERS_MIN — naming dialog did not fire with the expected speaker count (Phase 1 #165 production-chain regression?)"
        fi
        log "$label: naming-dialog speaker count assertion passed (observed=$observed >= min=$MTT_EXPECT_NAMING_SPEAKERS_MIN)"
    fi
    echo

    PRE_LAST_JOB_ID="$lj_id"
    SIM_PID=""
}

# --- Shared sidecar assertions ---------------------------------------------
#
# Extracted so the record-only and mic-only lanes cannot drift on the parts that
# are properties of a *sidecar* rather than of a lane. Each lane keeps its own
# jq for what makes it that lane (trigger, which track must be present).

# Wait for a `*_meta.json` newer than $2 to appear, then dump it.
# Sets $SIDECAR_PATH; an out-variable rather than stdout because `log` writes
# there and command substitution would swallow the run log into the value.
await_new_sidecar() {
    local label="$1" marker="$2"
    log "$label: polling $RECORDINGS_DIR for sidecar (timeout ${RECORD_ONLY_DEADLINE_S}s)"
    local deadline=$(( $(date +%s) + RECORD_ONLY_DEADLINE_S ))
    SIDECAR_PATH=""
    while true; do
        SIDECAR_PATH="$(find "$RECORDINGS_DIR" -type f -name '*_meta.json' -newer "$marker" -print 2>/dev/null | head -1)"
        [ -n "$SIDECAR_PATH" ] && break
        [ "$(date +%s)" -lt "$deadline" ] || fail "$label: no *_meta.json appeared in $RECORDINGS_DIR within ${RECORD_ONLY_DEADLINE_S}s"
        sleep 2
    done
    log "$label: found sidecar $SIDECAR_PATH"
    jq -C . "$SIDECAR_PATH" | sed 's/^/    /'
}

# The lane-independent half of the schema: shape and timestamps.
assert_sidecar_common() {
    local label="$1" sidecar="$2" check
    check="$(jq -r '
        if .version != 2 then "version != 2 (got: \(.version))"
        elif (.startedAt | type) != "string" then "startedAt not string"
        elif (.stoppedAt | type) != "string" then "stoppedAt not string"
        elif (.startedAt | fromdateiso8601? // -1) < 0 then "startedAt not ISO8601"
        elif (.stoppedAt | fromdateiso8601? // -1) < 0 then "stoppedAt not ISO8601"
        elif (.stoppedAt | fromdateiso8601) <= (.startedAt | fromdateiso8601) then "stoppedAt <= startedAt"
        else "ok"
        end
    ' "$sidecar")"
    [ "$check" = "ok" ] || fail "$label: sidecar schema invalid: $check"
}

# Assert one track named in the sidecar exists and carries audio.
# $4 is the active-seconds floor: pass the fixture-calibrated one where the
# lane controls what is played, so a capture that dies partway is caught.
assert_sidecar_track_has_signal() {
    local label="$1" sidecar="$2" key="$3" min_active="$4" hint="$5"
    local name path verdict
    name="$(jq -r ".files.$key // empty" "$sidecar")"
    [ -n "$name" ] || fail "$label: sidecar has no $key track (.files.$key is null). $hint"
    path="$(dirname "$sidecar")/$name"
    [ -f "$path" ] || fail "$label: $key track WAV not found: $path"
    # `=` form for the negative threshold: ArgumentParser reads a bare `-50` as
    # another flag and errors out.
    if verdict="$("$MTCLI" wav-verdict "$path" --threshold-dbfs=$WAV_VERDICT_THRESHOLD_DBFS --min-active-seconds="$min_active")"; then
        log "$label: $key track $name capture OK: $verdict"
    else
        fail "$label: $key track $name is silent/too quiet (reason above). $hint"
    fi
}

# Record-only short-circuits before the pipeline, so `lastJob` must not move.
# Record-only means the pipeline never ran. Two observations are needed for
# that, and the second is the one that was missing.
#
# `lastJob` is `lastFinishedJobSnapshot()`, which only ever reports a job in
# `.done` or `.error`: a job that is still waiting or transcribing is invisible
# to it. The artifact check beside this one is blind to the same job for its own
# reason, since the transcript is written near the END of the pipeline, after
# transcription and diarization. Both checks run a few seconds after the sidecar
# appears, so a regression that hands the queue a usable recording would still
# be transcribing at that moment, and the lane would pass while the very thing
# it forbids was underway. Neither lane runs a second meeting in CI, so nothing
# catches it on a later iteration either.
#
# The queue counters see exactly the states `lastJob` hides. Asserting them
# turns "no finished job and no finished artifact" into "no job at all", which
# is what record-only actually promises.
assert_pipeline_did_not_run() {
    local label="$1" violation snap
    # An unanswered read used to reach record_only_violation as an empty
    # snapshot, which with no baseline job reads as "nothing ran".
    snap="$(state_query .)" || fail "$(state_why $? "$label: whether record-only left the pipeline idle")"
    violation="$(record_only_violation "$snap" "$PRE_LAST_JOB_ID")"
    [ -z "$violation" ] \
        || fail "$label: $violation. Record-only must not enqueue at all, and a job still in flight is invisible to both lastJob and the transcript check, so without this the lane would report success while the pipeline was doing what it must not do."
}

# Mic-only lane (issue #633): no meeting, no detector, no app audio. Starts the
# recording over POST /v1/record, plays the fixture into the loopback input so
# the microphone has something to capture, stops over the same route, and asserts
# the sidecar describes a single-track recording.
#
# `afplay` rather than the meeting-simulator, and auto-watch off: this lane wants
# sound, not a detectable meeting. The simulator holds a power assertion, and the
# watch loop would start an auto recording alongside the manual one.
#
# The lane also carries the only live check of POST /v1/watch's refusal, which
# is otherwise tested against fakes: it holds a manual recording, and while one
# owns the loop a watch start must be refused with 409 and leave everything as
# it was. The check asserts the effect, the watch state unchanged and the
# recording still running, not just the code. It never starts watching: a
# start rebuilds the pipeline, including staged-recording recovery against the
# host's real staging folder, which a test must not set off. The status is
# read with rpc_post_status because the code is the contract, and mt-cli folds
# every refusal into one non-zero exit.
_mic_only_assert_watch_refused() {
    local label="$1" code state status
    # 30 s: the endpoint may take its 20 s settle before answering. The caller
    # has just confirmed the recording, so the state before is 'recording'.
    code="$(rpc_post_status /v1/watch '{"action":"start"}' 30)"
    [ "$code" = 409 ] \
        || fail "$label: POST /v1/watch start during a manual recording answered $code, expected 409"
    state="$(watch_state)"
    [ "$state" = recording ] \
        || fail "$label: after the refused watch start, /state.watchState is '$state', expected the manual recording's 'recording'"
    status="$("$MTCLI" record)" || fail "$label: mt-cli record status failed after the refused watch start"
    jq -e '.recording == true' >/dev/null <<<"$status" \
        || fail "$label: the refused watch start ended the manual recording: $status"
    log "$label: watch start refused with 409; watch state still 'recording', recording still running"
}

run_mic_only() {
    local label="[mic-only]"

    _mic_only_switch_output

    log "$label: starting microphone recording over POST /v1/record"
    "$MTCLI" record start >/dev/null || fail "$label: mt-cli record start failed"

    # Assert the app agrees it is recording before feeding it audio: a start that
    # answered 200 while nothing runs would otherwise surface later as a
    # confusing "no sidecar appeared".
    local status
    status="$("$MTCLI" record)" || fail "$label: mt-cli record status failed"
    echo "$status" | jq -e '.recording == true' >/dev/null \
        || fail "$label: /v1/record reports recording=false right after a 200 start: $status"
    log "$label: recording confirmed: $status"

    _mic_only_assert_watch_refused "$label"

    log "$label: playing $SIMULATOR_FIXTURE into the loopback input"
    afplay "$SIMULATOR_FIXTURE" || fail "$label: afplay failed; the microphone had nothing to capture"

    log "$label: stopping recording"
    "$MTCLI" record stop >/dev/null || fail "$label: mt-cli record stop failed"

    # `record stop` is synchronous through mix + sidecar write, so this resolves
    # on the first iteration or never; the deadline only bounds a regression.
    local sidecar
    await_new_sidecar "$label" "$RECORD_ONLY_MARKER"
    sidecar="$SIDECAR_PATH"

    # `trigger` is what tells a fleet consumer a short recording was deliberate
    # rather than a false detection, and this lane is its only live producer.
    # The identity fields are asserted for the same reason: nothing else records
    # under them, so a drift would ship unnoticed.
    local schema_check
    schema_check="$(jq -r '
        if .trigger != "manual" then "trigger != manual (got: \(.trigger // "absent"))"
        elif .appName != "Microphone" then "appName != Microphone (got: \(.appName // "absent"))"
        elif .title != "Microphone Recording" then "title != Microphone Recording (got: \(.title // "absent"))"
        elif (.micDelaySeconds // 0) != 0 then "micDelaySeconds != 0 (got: \(.micDelaySeconds)) — there is no app track to align against"
        elif (.files.mic // "") == "" then "files.mic missing"
        elif (.files.mic | endswith("_mic.wav") | not) then "files.mic doesn'"'"'t end with _mic.wav (got: \(.files.mic))"
        else "ok"
        end
    ' "$sidecar")"
    [ "$schema_check" = "ok" ] || fail "$label: sidecar schema invalid: $schema_check"
    assert_sidecar_common "$label" "$sidecar"

    # THE assertion this lane exists for. Everything else here would also hold
    # for an ordinary dual-source recording.
    #
    # Known limit, worth stating rather than implying: `.files.app` is written
    # only when the tap delivered bytes, so this catches a tap that opens AND
    # captures, not one that opens and yields nothing. Distinguishing those needs
    # the recording source on `/state`, which it does not expose today.
    local app_filename
    app_filename="$(jq -r '.files.app // empty' "$sidecar")"
    [ -z "$app_filename" ] || fail "$label: sidecar carries an app track ($app_filename); a microphone-only recording must open no process tap"
    log "$label: no app track in the sidecar, as required"

    assert_sidecar_track_has_signal "$label" "$sidecar" mic "$WAV_VERDICT_FIXTURE_MIN_ACTIVE_S" \
        "Either the default output is no longer routed into the loopback input, or microphone capture regressed."

    # Negative: record-only short-circuits before VAD/transcription/protocol, and
    # a manual trigger must not be the exception that slips past it.
    local unexpected
    unexpected="$(pipeline_output_artifacts "$OUTPUT_DIR" "$RECORD_ONLY_MARKER")" \
        || fail "$label: could not determine whether the pipeline wrote anything under $OUTPUT_DIR (see the message above). Treating that as a clean run is the failure this assertion exists to prevent."
    [ -z "$unexpected" ] || fail "$label: a microphone recording must not produce transcript/protocol; found: $unexpected"
    assert_pipeline_did_not_run "$label"
    assert_app_alive

    log "$label: PASS"
}

# Record-only counterpart: trigger one meeting, wait for sidecar+WAV to
# land in `recordings/`, assert schema/files, negative-assert that no
# transcript/protocol got written and `lastJob` didn't advance.
run_one_record_only_meeting() {
    local label="$1"

    # Per-meeting marker so iteration 2 of --two-meetings doesn't see the
    # iteration-1 sidecar as "new". Outer $RECORD_ONLY_MARKER still bounds
    # the cleanup sweep on exit.
    local meeting_marker="/tmp/e2e-app-record-only-meeting-marker.$$"
    rm -f "$meeting_marker"
    touch "$meeting_marker"

    log "$label: starting meeting-simulator (record-only) → $SIMULATOR_FIXTURE"
    "$SIMULATOR_BIN" "$SIMULATOR_FIXTURE" >/tmp/e2e-app-sim.log 2>&1 &
    SIM_PID=$!

    # Block until the simulator finishes playing the fixture. Exit code is
    # irrelevant; we assert on filesystem state below.
    wait "$SIM_PID" || true
    SIM_PID=""

    log "$label: simulator done; polling $RECORDINGS_DIR for sidecar (timeout ${RECORD_ONLY_DEADLINE_S}s)"
    local deadline=$(( $(date +%s) + RECORD_ONLY_DEADLINE_S ))
    local sidecar=""
    while true; do
        sidecar="$(find "$RECORDINGS_DIR" -type f -name '*_meta.json' -newer "$meeting_marker" -print 2>/dev/null | head -1)"
        [ -n "$sidecar" ] && break
        [ "$(date +%s)" -lt "$deadline" ] || fail "$label: no *_meta.json appeared in $RECORDINGS_DIR within ${RECORD_ONLY_DEADLINE_S}s"
        sleep 2
    done

    log "$label: found sidecar $sidecar"
    jq -C . "$sidecar" | sed 's/^/    /'

    # Schema check in one jq invocation — emits "ok" or a human-readable reason.
    local schema_check
    schema_check="$(jq -r '
        if .trigger != "auto" then "trigger != auto (got: \(.trigger // "absent"))"
        elif (.files.mix // "") == "" then "files.mix missing"
        elif (.files.mix | endswith("_mix.wav") | not) then "files.mix doesn'\''t end with _mix.wav (got: \(.files.mix))"
        else "ok"
        end
    ' "$sidecar")"
    [ "$schema_check" = "ok" ] || fail "$label: sidecar schema invalid: $schema_check"
    assert_sidecar_common "$label" "$sidecar"

    # Mix WAV must live next to the sidecar and be non-trivial.
    local sidecar_dir mix_filename mix_path mix_size
    sidecar_dir="$(dirname "$sidecar")"
    mix_filename="$(jq -r '.files.mix' "$sidecar")"
    mix_path="$sidecar_dir/$mix_filename"
    [ -f "$mix_path" ] || fail "$label: mix WAV not found: $mix_path"
    mix_size="$(wc -c <"$mix_path" | tr -d ' ')"
    # 16 kHz mono 16-bit PCM = 32 KB/sec. Fixture two_speakers_de.wav is 49.8 s,
    # so expect > 64 KB even after heavy truncation.
    [ "$mix_size" -gt 65536 ] || fail "$label: mix WAV suspiciously small: $mix_size bytes (expected > 64 KB)"
    log "$label: mix WAV $mix_path ($mix_size bytes)"

    # The mix-size check above only proves bytes were written. Two capture
    # failures slip past it: (a) an all-zeros app track is byte-for-byte the
    # same size as a good one, and the mic masks it in the mix via speaker
    # bleed; (b) a tap that never attaches leaves no app track at all, and the
    # mix falls back to mic-only at full size. This meeting is always
    # dual-source (the simulator plays the fixture the whole time), so assert
    # the app track both exists AND carries energy, via the same mt-cli
    # wav-verdict analyzer the browser lane uses (windowed peak RMS, robust to
    # the trailing grace-period silence). A missing or silent app track means
    # system-audio capture produced no signal (a wrong tap PID set, a missing
    # TCC audio-capture grant, or a regressed capture path).
    # `=` form for the negative threshold: ArgumentParser reads a bare `-50` as
    # another flag and errors out.
    assert_sidecar_track_has_signal "$label" "$sidecar" app "$WAV_VERDICT_FIXTURE_MIN_ACTIVE_S" \
        "System-audio capture produced no usable signal: likely a wrong tap PID set, a missing TCC audio-capture grant, or a regressed capture path."

    # Negative: record-only short-circuits before VAD/transcription/protocol.
    local unexpected
    unexpected="$(pipeline_output_artifacts "$OUTPUT_DIR" "$meeting_marker")" \
        || fail "$label: could not determine whether the pipeline wrote anything under $OUTPUT_DIR (see the message above). Treating that as a clean run is the failure this assertion exists to prevent."
    [ -z "$unexpected" ] || fail "$label: record-only should not produce transcript/protocol; found: $unexpected"

    # Negative: PipelineQueue.enqueue() was skipped entirely — no finished job,
    # and nothing waiting or running either. Shared with the mic-only lane so
    # the two cannot drift apart.
    assert_pipeline_did_not_run "$label"

    # Surface the produced mix path so the optional reimport chain picks
    # it up without re-globbing. Reset by each caller's `local` line.
    LAST_RECORDED_MIX_PATH="$mix_path"

    rm -f "$meeting_marker"
}

# Re-import a previously-recorded WAV via POST /action/enqueueFile — same
# code path the menu's "Open from Recording" entry takes. Polls /state for
# a new lastJob in `done`, asserts transcript exists, is non-trivial, and
# contains the expected fixture keyword. Confirms the round-trip:
# recorder-produced WAV is loadable + transcribable.
run_one_reimport() {
    local label="$1"
    local audio_path="$2"
    local expected_phrase="${3:-meeting}"  # case-insensitive substring

    [ -f "$audio_path" ] || fail "$label: re-import source not found: $audio_path"

    log "$label: POST /action/enqueueFile path=$audio_path"
    local enq_status
    enq_status="$(rpc_post_status /action/enqueueFile "$(jq -nc --arg p "$audio_path" '{path: $p}')" 10)"
    [ "$enq_status" = "200" ] || fail "$label: enqueueFile returned HTTP $enq_status (expected 200)"

    _poll_for_new_lastjob_terminal "$label"
    local lj_id="$POLL_LJ_ID" lj_state="$POLL_LJ_STATE"

    log "$label: final state: $lj_state"
    local final_snapshot
    final_snapshot="$STATE_BODY"
    echo "$final_snapshot" | jq '.lastJob'

    [ "$lj_state" = "done" ] || fail "$label: lastJob.state == \"$lj_state\", expected \"done\". Error: $(jq -r '.lastJob.error // "<none>"' <<<"$final_snapshot")"

    local transcript_path
    transcript_path="$(jq -r '.lastJob.transcriptPath // empty' <<<"$final_snapshot")"
    [ -n "$transcript_path" ] || fail "$label: lastJob.transcriptPath is empty"
    [ -f "$transcript_path" ] || fail "$label: transcript file does not exist: $transcript_path"

    _read_transcript_size "$label" "$transcript_path"

    # Content assertion: re-imported WAV came from the live recording stack,
    # so a successful round-trip means the engine actually recognised the
    # fixture's spoken content — not just emitted any non-empty file.
    # `meeting` is case-insensitive-robust (Parakeet may capitalise/translate;
    # WhisperKit may emit "Meeting" or "meeting" depending on punctuation).
    grep -qi "$expected_phrase" "$transcript_path" \
        || fail "$label: transcript does not contain '$expected_phrase' (case-insensitive). Preview:$(printf '\n')$(head -c 500 "$transcript_path")"

    log "$label: transcript $transcript_path ($TRANSCRIPT_SIZE bytes, contains '$expected_phrase')"
    log "$label: preview:"
    head -c 500 "$transcript_path" | sed 's/^/    /'
    echo

    PRE_LAST_JOB_ID="$lj_id"
}

LAST_RECORDED_MIX_PATH=""

# Issue #379 part 3 — crash recovery. Record via the live stack, SIGKILL the
# app mid-recording so `stop()` never runs (the raw `_app16k_raw.tmp` + unfinalized
# `_mic.wav` survive, no `_mix.wav`), then relaunch and assert the recovered
# recording enters the pipeline and a job reaches done. The re-mixed `_mix.wav`
# is transient (recoverOrphanedRecordings enqueues it + the pipeline consumes it
# into its workdir within seconds), so the assertion is on the pipeline job, not
# the file. Pre-fix the launch cleanup deletes the temp first → no recovery
# (RED); the fix re-mixes + enqueues it (GREEN).
#
# Live temps go to AppPaths.recordingsDir (Application Support), NOT the
# record-only Downloads dir — recovery scans the same path.
CRASH_RECORDINGS="$HOME/Library/Application Support/MeetingTranscriber/recordings"
CRASH_MARKER=""
CRASH_STEM=""
run_crash_recovery() {
    local label="[crash-recovery]"
    mkdir -p "$CRASH_RECORDINGS"
    CRASH_MARKER="/tmp/e2e-crash-recovery-marker.$$"
    rm -f "$CRASH_MARKER"; touch "$CRASH_MARKER"

    # Baseline the pre-crash lastJob now (RPC is already up from launch). The
    # recovered recording gets a fresh job id after relaunch, so this stable
    # baseline can never equal the recovered job — avoids a race where recovery
    # enqueues before we could sample a post-relaunch baseline.
    PRE_LAST_JOB_ID="$(state_query '.lastJob.jobID // empty')" \
        || fail "$(state_why $? "$label: the pre-crash lastJob baseline")"
    log "$label: pre-crash baseline lastJob.jobID=${PRE_LAST_JOB_ID:-<none>}"

    # 1. Start a meeting so the app begins recording.
    log "$label: starting meeting-simulator -> $SIMULATOR_FIXTURE"
    "$SIMULATOR_BIN" "$SIMULATOR_FIXTURE" >/tmp/e2e-app-sim.log 2>&1 &
    SIM_PID=$!

    # 2. Wait until the recorder is writing the raw app temp (recording active).
    local orphan_tmp=""
    _crash_tmp_appeared() {
        orphan_tmp="$(find "$CRASH_RECORDINGS" -maxdepth 1 -name '*_app16k_raw.tmp' -newer "$CRASH_MARKER" -print 2>/dev/null | head -1)"
        [ -n "$orphan_tmp" ]
    }
    log "$label: waiting for an active recording (*_app16k_raw.tmp)"
    poll_until 40 1 _crash_tmp_appeared || fail "$label: no *_app16k_raw.tmp appeared — recording never started"
    sleep 3   # let a little audio accumulate before the kill

    CRASH_STEM="$(basename "$orphan_tmp")"; CRASH_STEM="${CRASH_STEM%_app16k_raw.tmp}"
    local stem="$CRASH_STEM"
    log "$label: recording active, orphan stem=$stem"

    # 3. Simulate a crash: SIGKILL the app (no stop() → temp survives, no mix).
    #    Kill the simulator too so the relaunch sees no active meeting — the
    #    only recording that can surface post-relaunch is the recovered one.
    log "$label: SIGKILL the app mid-recording (simulating a crash)"
    # Everything below this line is equally true of an app that is still
    # running, so the kill needs a verdict of its own. The helper owns the whole
    # sequence — capture the victims, refuse if there are none, kill, prove
    # those process ids are gone — because a caller that kills first and asks
    # afterwards cannot tell a successful kill from a pattern that matched
    # nothing, and the second is the likelier failure here.
    kill_and_verify_gone "$_DEV_APP_PATTERN" 10 \
        || fail "$label: the kill did not demonstrably remove the app. Nothing below this point would exercise crash recovery: a live recorder keeps the raw temp present and the mix absent, so every later assertion passes against an ordinary recording. See the message above for which of the two happened; a pattern that matched nothing means the bundle or executable was renamed."
    [ -n "${SIM_PID:-}" ] && kill "$SIM_PID" 2>/dev/null || true
    SIM_PID=""
    sleep 2

    # 4. Verify the crashed-orphan state on disk.
    [ -f "$CRASH_RECORDINGS/${stem}_app16k_raw.tmp" ] || fail "$label: orphan ${stem}_app16k_raw.tmp did not survive the crash"
    [ ! -f "$CRASH_RECORDINGS/${stem}_mix.wav" ] || fail "$label: a _mix.wav exists — stop() ran, this wasn't a crash"
    log "$label: confirmed crashed state (raw temp present, no mix)"

    # 5. Backdate the orphan past recovery's in-progress guard (a real
    #    crash→relaunch gap is minutes; keeps the e2e fast + deterministic).
    local old; old="$(date -v-5M +%Y%m%d%H%M.%S)"
    touch -t "$old" "$CRASH_RECORDINGS/${stem}_app16k_raw.tmp"
    [ -f "$CRASH_RECORDINGS/${stem}_mic.wav" ] && touch -t "$old" "$CRASH_RECORDINGS/${stem}_mic.wav" || true

    # 6. Relaunch — recovery runs at the launch queue-build.
    log "$label: relaunching $DEV_BUNDLE_DEPLOY"
    open "$DEV_BUNDLE_DEPLOY"
    poll_until "$RPC_READY_TIMEOUT_S" 1 _rpc_ready || fail "$label: RPC did not come back after relaunch"
    log "$label: RPC back up after relaunch"

    # 7. Assert recovery: the recovered recording enters the pipeline. The
    #    re-mixed `_mix.wav` is TRANSIENT — `recoverOrphanedRecordings` enqueues
    #    it and the pipeline moves it into its workdir within a few seconds — so
    #    asserting the file persists is wrong (it races the pipeline). Assert on
    #    a NEW pipeline job instead: any active / pending-naming / waiting job.
    #    The CI snapshot reset (above, $GITHUB_ACTIONS-gated) zeroes the queue
    #    first, so a non-zero count here is the recovered recording. Pre-fix the
    #    orphan is deleted with no recovery → the queue stays empty (RED).
    log "$label: waiting for the recovered recording to enter the pipeline (timeout 120s)"
    poll_state 120 3 state_is '((.pipeline.activeJobCount // 0) + (.pipeline.pendingNamingJobCount // 0) + (.pipeline.waitingJobCount // 0)) > 0' \
        || fail "$(state_why $? "$label: orphan NOT recovered — no recovered recording entered the pipeline within 120s (recovery missing, or the orphan was deleted by launch cleanup)")"
    log "$label: recovered recording entered the pipeline ✅"

    # 8. Full chain: drive the recovered job to a terminal state (the poll loop
    #    auto-skips the speaker-naming dialog) and assert it reached done — the
    #    crashed recording was re-mixed AND transcribed end-to-end.
    _poll_for_new_lastjob_terminal "$label"
    [ "$POLL_LJ_STATE" = "done" ] || fail "$label: recovered job state=$POLL_LJ_STATE, expected done"


    # 9. Tie that job to THIS run's recording. Steps 7 and 8 accept any job, and
    #    "any job" is reachable without this lane having recovered anything: an
    #    orphan left behind by an interrupted earlier run is recovered at the
    #    same launch, satisfies the queue count at once, and satisfies the
    #    terminal check when it finishes. The lane would then report success on
    #    a recording it never crashed. Recovery titles the job after the stem it
    #    rebuilt, which is the only thing in the snapshot that names ours.
    local want_title="Recovered Recording (${stem})" got_title
    got_title="$(jq -r '.lastJob.meetingTitle // ""' <<<"$STATE_BODY")"
    [ "$got_title" = "$want_title" ] \
        || fail "$label: the job that finished is titled '$got_title', not '$want_title'. Something reached a terminal state, but not the recording this lane crashed — most likely an orphan left by an earlier interrupted run, recovered at the same launch."
    log "$label: recovered recording transcribed and it is ours (lastJob done) ✅"
}

# Speaker-naming CONFIRM lane. Every other lane's shared poll loop auto-skips
# each naming dialog (POST /action/skipNaming), so the confirm path (assign
# names → the names land as transcript speaker labels → the speaker DB learns
# the voices) has ZERO live coverage. That path is exactly the bug family the
# late-rerun transcript-rebuild fix addressed (a confirm that renamed labels but
# never re-segmented the persisted .txt), so it needs a standing regression net.
#
# Suppression of the auto-skip is scoped to this lane BY CONSTRUCTION: it drives
# the whole flow itself (enqueue → poll pendingNamingJobs → GET/POST
# /v1/jobs/<id>/naming → poll the job to done) and never calls
# `_poll_for_new_lastjob_terminal`, so the global auto-skip other lanes rely on
# is untouched.
# --- Escape-dismisses-naming lane (issue #577) ----------------------------
# Presses a REAL Escape on the open speaker-naming dialog and asserts the one
# thing the fix is about: the window goes away and the job does NOT resolve.
#
# Why a WindowServer keystroke and not an RPC endpoint. A synthetic NSEvent
# cannot do this: keycode 53 only becomes `cancelOperation:` inside
# `interpretKeyEvents:`, which only text-input responders call, so with no name
# field focused SwiftUI's exit command never sees it. Measured three ways (both
# NSWindow.sendEvent and NSApplication.sendEvent in the live app, plus xctest)
# — every one reports a clean dispatch and changes nothing, which is why an
# in-process endpoint for this was built, found inert, and reverted.
#
# Deliberately does NOT click into a name field first. The dialog binds dismiss
# twice — `onExitCommand` for the focused case and a `.cancelAction` carrier for
# the rest — and it is the unfocused path that the fix nearly shipped broken,
# so that is the one worth a lane.
#
# RUNNER PREREQUISITE: the shell running this needs an Accessibility grant
# (System Settings → Privacy & Security → Accessibility), same one-time,
# cert-independent shape as the existing mic / screen-recording grants. Checked
# up front so a missing grant is reported as a skip with its own message
# (host_skip) instead of looking like a broken dismiss.
run_naming_escape() {
    local label="[naming-escape]"
    [ -f "$DEFAULT_FIXTURE" ] || fail "$label: 2-speaker fixture not found: $DEFAULT_FIXTURE"

    # Preflight both grants this lane needs, because they fail in different ways
    # and only one of them fails loudly.
    #
    # Accessibility (posting keystrokes) refuses with a clear error. Automation
    # (driving another process through System Events) does not: without it the
    # AppleEvent simply never gets an answer and osascript sits there for its
    # default 120 s timeout, which reads as a hung lane rather than a missing
    # permission. So the probe wraps the *same* operation the lane performs in a
    # short explicit timeout and treats the timeout as the diagnosis.
    local probe tcc_timeout
    tcc_timeout="$(e2e_tcc_prompt_timeout)" || fail "$label: see the line above"
    # The first Apple Event to System Events, so the one that raises the
    # prompt: it honours the same setup knob as the probe below.
    # Under a hard bound as well: a pending prompt can hold osascript before
    # its Apple Event is sent, where `with timeout` never fires. A cut-off
    # probe reads as the timeout it stands for.
    probe="$(run_bounded $((tcc_timeout + 5)) osascript -e "with timeout of ${tcc_timeout} seconds" \
        -e 'tell application "System Events" to key code 53' \
        -e 'end timeout' 2>&1)" || { [ $? -ne 124 ] || probe="timed out (no answer within $((tcc_timeout + 5))s)"; }
    case "$probe" in
        *"not allowed"*|*"assistive"*|*"1002"*)
            # SKIP for the same reason the Automation arm skips: this is a host
            # prerequisite that only a human at the GUI can satisfy, so failing
            # on it would redden every PR for something unrelated to the change.
            # The two grants are separate and can be half-configured — Automation
            # granted, Accessibility not — so both arms need the same treatment
            # or the lane just moves its red one step later.
            log "$label: cause: $probe"
            host_skip naming-escape "This host may drive System Events but is missing the Accessibility grant, so the real-Escape assertion did not run. Fix: System Settings → Privacy & Security → Accessibility, enable the entry for the process that runs this lane (for this run: $(tcc_grantee); see the e2e-architecture skill, runner setup step 6)."
            return 0 ;;
    esac
    # The probe's window is short by default so a missing grant is reported in
    # seconds rather than waited out. For the one-time setup run it has to be
    # long enough for a human to answer the prompt it raises, hence the knob:
    # E2E_TCC_PROMPT_TIMEOUT=300 bash scripts/e2e-app.sh --naming-escape
    local probe_status attempt
    # A timeout is what a missing Automation grant looks like, but a busy
    # System Events looks the same, so a timeout is retried once with three
    # times the window before it is taken as the grant. A connection that
    # dropped (-609) or a System Events not running yet (-600) is transient
    # and retried once too, then fails. A definite refusal (-1743) needs no
    # retry, and any other error fails the lane.
    local timeout_retried="" transient_retried=""
    for attempt in 1 2 3; do
        probe_status=0
        probe="$(run_bounded $((tcc_timeout + 5)) osascript -e "with timeout of ${tcc_timeout} seconds" \
            -e 'tell application "System Events" to get name of first process whose frontmost is true' \
            -e 'end timeout' 2>&1)" || probe_status=$?
        [ "$probe_status" -ne 124 ] || probe="timed out (no answer within $((tcc_timeout + 5))s)"
        case "$probe" in
            *"timed out"*|*"-1712"*)
                [ -z "$timeout_retried" ] || break
                timeout_retried=1
                # Three times the window, capped at 60 s (the setup knob may
                # already be minutes long), but never shorter than the first.
                local longer=$((tcc_timeout * 3 > 60 ? 60 : tcc_timeout * 3))
                tcc_timeout=$((longer > tcc_timeout ? longer : tcc_timeout))
                log "$label: System Events did not answer; retrying once with ${tcc_timeout}s" ;;
            *"-609"*|*"-600"*)
                [ -z "$transient_retried" ] || break
                transient_retried=1
                log "$label: System Events was not reachable ($probe); retrying once"
                sleep 2 ;;
            *) break ;;
        esac
    done
    case "$probe" in
        *"timed out"*|*"-1712"*|*"not authori"*|*"-1743"*)
            # SKIP, not FAIL. The grant can only be given by clicking Allow in
            # the host's GUI session — no MDM profile here, and tccutil can only
            # reset — so on an ungranted host this would turn every PR red for a
            # reason unrelated to the change under test. Failing after this point
            # still fails: only the missing prerequisite is tolerated, and it is
            # reported loudly enough that nobody mistakes it for coverage.
            log "$label: cause: $probe"
            host_skip naming-escape "This host cannot drive System Events within ${tcc_timeout}s: the Automation grant is missing, so the real-Escape assertion did not run. Fix: System Settings → Privacy & Security → Automation, allow the process that runs this lane to control System Events, and grant it Accessibility for keystrokes (for this run: $(tcc_grantee); see the e2e-architecture skill, runner setup step 6). Both prompt on first use, so run this lane once by hand in the GUI session and click Allow."
            return 0 ;;
    esac
    [ "$probe_status" -eq 0 ] \
        || fail "$label: the System Events preflight failed for a reason that is not a missing grant (exit $probe_status): $probe"
    log "$label: frontmost process is '$probe'"

    local fixture_dir fixture_copy
    fixture_dir="$(mktemp -d /tmp/e2e-naming-escape-fixture.XXXXXX)"
    fixture_copy="$fixture_dir/two_speakers_de.wav"
    cp "$DEFAULT_FIXTURE" "$fixture_copy" || fail "$label: could not copy fixture to $fixture_copy"

    local enq job_id
    enq="$(curl --silent --show-error --max-time 10 -X POST \
        --header "Authorization: Bearer $RPC_TOKEN" \
        --header "Content-Type: application/json" \
        --data "$(jq -nc --arg p "$fixture_copy" '{paths: [$p]}')" \
        "$RPC_BASE/v1/jobs" 2>/dev/null || echo '{}')"
    job_id="$(jq -r '.jobIDs[0] // empty' <<<"$enq")"
    [ -n "$job_id" ] || fail "$label: POST /v1/jobs did not return a job id (response: $enq)"
    log "$label: enqueued job $job_id"

    _naming_escape_parked() {
        [ "$(rpc "/v1/jobs/$job_id" | jq -r '.state // empty')" = "speakerNamingPending" ]
    }
    poll_until "$PIPELINE_TIMEOUT_S" 5 _naming_escape_parked \
        || fail "$label: job $job_id never parked at speaker-naming within ${PIPELINE_TIMEOUT_S}s"

    poll_state 30 2 state_is "$_NAMING_WINDOW_VISIBLE" \
        || fail "$(state_why $? "$label: naming window never became visible")"
    log "$label: naming window open, job parked"

    # Front the app so the keystroke lands on it, then Escape. No click into the
    # dialog: the point is that dismiss works without a focused field.
    local front_err
    # Both bounded like the probes above: the grants were just proved, but one
    # lost mid-lane would otherwise hold osascript behind a prompt.
    local front_s=$(( tcc_timeout > 15 ? tcc_timeout : 15 ))
    front_err="$(run_bounded $((front_s + 5)) osascript -e "with timeout of ${front_s} seconds" \
        -e 'tell application "System Events" to tell process "MeetingTranscriber" to set frontmost to true' \
        -e 'end timeout' 2>&1)" \
        || fail "$label: could not front the app (124 = no answer within $((front_s + 5)) s): ${front_err:-<no output>}. If it was refused or timed out: $(tcc_fix_hint 'Automation → System Events')"
    sleep 1
    local key_err
    key_err="$(run_bounded $((tcc_timeout + 5)) osascript -e "with timeout of ${tcc_timeout} seconds" \
        -e 'tell application "System Events" to key code 53' \
        -e 'end timeout' 2>&1)" \
        || fail "$label: could not post Escape (124 = no answer within $((tcc_timeout + 5)) s): ${key_err:-<no output>}. If it was refused or timed out: $(tcc_fix_hint 'Device Control and Data Access, and Automation → System Events')"

    # The negative check is where an unanswered read did the most harm: it read
    # as "not visible", so a wedged app passed as a dismissed window.
    poll_state 15 1 state_is "($_NAMING_WINDOW_VISIBLE) | not" \
        || fail "$(state_why $? "$label: Escape did not dismiss the naming window (windows=$(jq -c '[.windows[]|{id,isVisible}]' <<<"$STATE_BODY"))")"
    log "$label: window dismissed"

    # The half that separates a dismiss from a Skip: the job must be untouched
    # and still resolvable. A Skip here would have committed the auto-names and
    # deleted the naming data.
    local state
    state="$(rpc "/v1/jobs/$job_id" | jq -r '.state // empty')"
    [ "$state" = "speakerNamingPending" ] \
        || fail "$label: Escape resolved the job (state=$state, expected speakerNamingPending)"
    log "$label: job still parked — dismiss did not resolve it"

    # Leave nothing pending behind; the dialog would reopen on the next launch.
    curl --silent --show-error --max-time 10 -X POST \
        --header "Authorization: Bearer $RPC_TOKEN" --header "Content-Length: 0" \
        "$RPC_BASE/v1/jobs/$job_id/naming/skip" >/dev/null 2>&1 || true
    rm -rf "$fixture_dir"
    log "$label: PASS"
}

run_naming_confirm() {
    local label="[naming-confirm]"
    [ -f "$DEFAULT_FIXTURE" ] || fail "$label: 2-speaker fixture not found: $DEFAULT_FIXTURE"

    # Confirm the app actually resolved the diarization settings the lane
    # configured via `defaults write`; /state.settings is the running
    # process's effective view (a blind `defaults read` is unreliable for the
    # dev bundle's container-plist redirect). Read the DB baseline from the
    # same snapshot.
    local snap diarize num_speakers record_only pre_db_count
    snap="$(state_query .)" || fail "$(state_why $? "$label: the resolved diarization settings")"
    diarize="$(jq -r '.settings.diarization.diarize' <<<"$snap")"
    num_speakers="$(jq -r '.settings.diarization.numSpeakers' <<<"$snap")"
    record_only="$(jq -r '.settings.recording.recordOnly' <<<"$snap")"
    pre_db_count="$(jq -r '.speakerDB.count // 0' <<<"$snap")"
    log "$label: resolved settings diarize=$diarize numSpeakers=$num_speakers recordOnly=$record_only; speakerDB.count=$pre_db_count"
    [ "$diarize" = "true" ] || fail "$label: settings.diarization.diarize is '$diarize', expected true"
    [ "$num_speakers" = "2" ] || fail "$label: settings.diarization.numSpeakers is '$num_speakers', expected 2"
    [ "$record_only" = "false" ] || fail "$label: settings.recording.recordOnly is '$record_only', expected false"

    # Enqueue a PRIVATE COPY of the fixture, never the shared Tests/Fixtures
    # path. The pipeline leaves a user-picked import where it is nowadays, so
    # this is a safety margin rather than load-bearing: it also keeps the lane
    # from leaving its own artifacts next to the shared fixture, and it survives
    # a future change to what counts as relocatable audio. Copy into a temp dir
    # cleaned up on exit by _naming_confirm_cleanup.
    _NC_FIXTURE_DIR="$(mktemp -d /tmp/e2e-naming-confirm-fixture.XXXXXX)"
    local fixture_copy="$_NC_FIXTURE_DIR/two_speakers_de.wav"
    cp "$DEFAULT_FIXTURE" "$fixture_copy" || fail "$label: could not copy fixture to $fixture_copy"

    # Enqueue on the /v1 automation surface (returns the job id). autoSkipNaming
    # is false on this path, so the job parks at speaker-naming.
    log "$label: POST /v1/jobs paths=[$fixture_copy]"
    local enq job_id
    enq="$(curl --silent --show-error --max-time 10 -X POST \
        --header "Authorization: Bearer $RPC_TOKEN" \
        --header "Content-Type: application/json" \
        --data "$(jq -nc --arg p "$fixture_copy" '{paths: [$p]}')" \
        "$RPC_BASE/v1/jobs" 2>/dev/null || echo '{}')"
    job_id="$(jq -r '.jobIDs[0] // empty' <<<"$enq")"
    [ -n "$job_id" ] || fail "$label: POST /v1/jobs did not return a job id (response: $enq)"
    log "$label: enqueued job $job_id"

    # Poll /state.pendingNamingJobs until OUR job parks at speaker-naming. No
    # /action/skipNaming here; driving the confirm is the whole point.
    local pending_count=""
    _naming_pending() {
        pending_count="$(jq -r --arg id "$job_id" \
            '[.pendingNamingJobs[] | select(.jobID == $id)] | .[0].speakerCount // empty' <<<"$STATE_BODY")"
        [ -n "$pending_count" ]
    }
    log "$label: waiting for job $job_id to reach speaker-naming (timeout ${PIPELINE_TIMEOUT_S}s)"
    poll_state --each assert_app_alive "$PIPELINE_TIMEOUT_S" 5 _naming_pending \
        || fail "$(state_why $? "$label: job $job_id never reached speaker-naming within ${PIPELINE_TIMEOUT_S}s (diarization produced no naming dialog?)")"
    log "$label: job parked at naming with speakerCount=$pending_count"
    [ "${pending_count:-0}" -ge 2 ] 2>/dev/null \
        || fail "$label: naming dialog speakerCount=$pending_count, expected >= 2 (numSpeakers=2 on a 2-speaker fixture)"

    # --- #504 regression net: the speaker-naming window must be PINNED --------
    # It floats + joins all Spaces + shows over full-screen apps so it stays
    # reachable when the user switches apps, instead of being swept away by
    # Stage Manager or a full-screen Space. Assert on the window PROPERTIES, not
    # mere visibility: an un-pinned NSWindow also stays visible on deactivation,
    # so a visibility-only check would stay green even with the fix reverted
    # (vacuous). Reverting NamingWindowPolicy flips floating -> false here, which
    # is what turns this lane red.
    local naming_win=""
    # Capture the speaker-naming window's projection from the poll's /state
    # answer into $naming_win; non-zero if the window is not present.
    _naming_window() {
        naming_win="$(jq -c '[.windows[] | select(.id == "speaker-naming")] | .[0] // empty' <<<"$STATE_BODY")"
        [ -n "$naming_win" ]
    }
    # Assert only the environment-STABLE pin properties. `.fullScreenAuxiliary`
    # is deliberately NOT asserted: apply() sets it and it holds on a normal
    # desktop, but on the headless/virtual-display CI mini AppKit normalises it
    # off (observed false there, true on a real display), so asserting it flakes.
    # `.canJoinAllSpaces` already covers cross-Space reachability, and `floating`
    # is the load-bearing stays-on-top property; reverting NamingWindowPolicy
    # flips floating -> false, which still turns this lane red.
    _naming_window_pinned() {
        _naming_window || return 1
        jq -e '.floating and .canJoinAllSpaces' <<<"$naming_win" >/dev/null
    }
    # Phase-2 predicate (used after deactivation): present AND on-screen AND
    # floating. isVisible is the load-bearing new signal a hidesOnDeactivate
    # regression would flip.
    _naming_window_visible_pinned() {
        _naming_window || return 1
        jq -e '.isVisible and .floating' <<<"$naming_win" >/dev/null
    }
    # The window opens asynchronously (.showSpeakerNaming -> bringWindowToFront
    # on the next runloop), so poll rather than assert once.
    log "$label: asserting speaker-naming window is pinned (floating + all-Spaces)"
    poll_state --each assert_app_alive 30 2 _naming_window_pinned \
        || fail "$(state_why $? "$label: speaker-naming window not pinned (#504 regression): $(jq -c '[.windows[] | select(.id=="speaker-naming")]' <<<"$STATE_BODY")")"
    log "$label: naming window pinned OK: $naming_win"

    # And it must SURVIVE the app losing focus: bring another app to the front,
    # then re-assert. The pin flags are focus-invariant, so the load-bearing new
    # signal here is isVisible: a "window hides when the app loses focus"
    # regression (e.g. hidesOnDeactivate flipped back on) flips isVisible to
    # false only AFTER deactivation, which phase 1 (app still active) cannot see.
    # RPC + the naming confirm are localhost HTTP, so leaving our menu-bar app
    # in the background does not block the rest of the lane.
    run_bounded 5 osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1 || true
    sleep 2
    # Poll rather than single-shot: a transient localhost RPC hiccup at this one
    # instant would otherwise fail the lane with a misleading "regression"
    # message. A genuine hide-on-deactivate regression stays red the whole window.
    poll_state --each assert_app_alive 20 2 _naming_window_visible_pinned \
        || fail "$(state_why $? "$label: speaker-naming window not visible + pinned after the app was deactivated (#504 regression): $(jq -c '.windows' <<<"$STATE_BODY")")"
    log "$label: naming window still visible + pinned after deactivating the app"
    # -------------------------------------------------------------------------

    # Read the naming choice: raw labels + auto-name suggestions + speaking time.
    local naming speaker_count
    naming="$(curl --silent --show-error --max-time 10 \
        --header "Authorization: Bearer $RPC_TOKEN" \
        "$RPC_BASE/v1/jobs/$job_id/naming" 2>/dev/null || echo '{}')"
    echo "$naming" | jq '.' | sed 's/^/    /'
    speaker_count="$(jq -r '.speakers | length' <<<"$naming")"
    [ "${speaker_count:-0}" -ge 2 ] 2>/dev/null \
        || fail "$label: GET naming returned $speaker_count speakers, expected >= 2"

    # Build a mapping assigning ANONYMOUS names (Speaker A, Speaker B, …).
    # Repo rule: never real first names. Keys MUST be the DTO's raw labels so
    # the confirm relabel anchors on the right transcript slots. The parallel
    # arrays (labels, in-transcript suggestions, assigned names) feed the
    # post-confirm assertions.
    local mapping labels_json suggested_json names_json
    mapping="$(jq -c '[.speakers[].label]
        | to_entries
        | map({key: .value, value: ("Speaker " + ([65 + .key] | implode))})
        | from_entries' <<<"$naming")"
    labels_json="$(jq -c '[.speakers[].label]' <<<"$naming")"
    suggested_json="$(jq -c '[.speakers[].suggested]' <<<"$naming")"
    names_json="$(jq -c '[.speakers[].label] | to_entries | map("Speaker " + ([65 + .key] | implode))' <<<"$naming")"
    log "$label: confirming mapping: $mapping"

    local confirm_status
    confirm_status="$(rpc_post_status "/v1/jobs/$job_id/naming" "$(jq -nc --argjson m "$mapping" '{mapping: $m}')" 10)"
    [ "$confirm_status" = "200" ] || fail "$label: POST naming returned HTTP $confirm_status (expected 200)"
    log "$label: naming confirmed; polling job to a terminal state"

    # Poll GET /v1/jobs/<id> (never /state → no auto-skip) until terminal.
    local state=""
    _job_terminal() {
        assert_app_alive
        state="$(curl --silent --show-error --max-time 10 \
            --header "Authorization: Bearer $RPC_TOKEN" \
            "$RPC_BASE/v1/jobs/$job_id" 2>/dev/null | jq -r '.state // empty')"
        [ "$state" = "done" ] || [ "$state" = "error" ]
    }
    poll_until "$PIPELINE_TIMEOUT_S" 5 _job_terminal \
        || fail "$label: job $job_id did not reach a terminal state within ${PIPELINE_TIMEOUT_S}s"

    local final transcript_path
    final="$(curl --silent --show-error --max-time 10 \
        --header "Authorization: Bearer $RPC_TOKEN" \
        "$RPC_BASE/v1/jobs/$job_id" 2>/dev/null || echo '{}')"
    echo "$final" | jq '.' | sed 's/^/    /'
    [ "$state" = "done" ] || fail "$label: job state=$state, expected done. Error: $(jq -r '.error // "<none>"' <<<"$final")"
    transcript_path="$(jq -r '.transcriptPath // empty' <<<"$final")"
    [ -n "$transcript_path" ] || fail "$label: job has no transcriptPath"
    [ -f "$transcript_path" ] || fail "$label: transcript file missing: $transcript_path"
    _read_transcript_size "$label" "$transcript_path"
    log "$label: transcript $transcript_path"
    head -c 600 "$transcript_path" | sed 's/^/    /'
    echo

    # --- Assertion 1: the confirmed names landed as speaker labels ---
    # A transcript line is "[MM:SS] Speaker: text"; the confirm relabel anchors
    # on "] <label>:", so assert on that exact slot form (fixed-string grep).
    local names_present=0 name
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        if grep -Fq "] $name:" "$transcript_path"; then
            names_present=$((names_present + 1))
        fi
    done < <(jq -r '.[]' <<<"$names_json")
    [ "$names_present" -ge 2 ] \
        || fail "$label: only $names_present assigned name(s) present as speaker labels; expected >= 2 (confirm did not relabel the transcript, the late-rerun rebuild regression)"
    log "$label: $names_present confirmed speaker names present in transcript ✅"

    # --- Assertion 2: raw diarization labels no longer appear ---
    # Both the DTO raw label (SPEAKER_n / R_/M_-prefixed) and its pre-confirm
    # in-transcript suggestion must be gone from every speaker slot.
    local leaked="" raw
    while IFS= read -r raw; do
        [ -n "$raw" ] || continue
        if grep -Fq "] $raw:" "$transcript_path"; then
            leaked="$leaked $raw"
        fi
    done < <(jq -r '.[]' <<<"$labels_json"; jq -r '.[]' <<<"$suggested_json")
    [ -z "$leaked" ] \
        || fail "$label: raw diarization label(s) still present as speaker slots after confirm:$leaked"
    log "$label: no raw diarization labels remain in transcript ✅"

    # --- Assertion 3 (CI only): the speaker DB learned the confirmed voices ---
    # Reliable only against the empty baseline the CI snapshot reset guarantees;
    # a local run starts from the dev's real DB (voices may already match, so a
    # confirm updates in place with no count change). Locally, just log.
    # Retry the readback: a single transient RPC hiccup would leave post_db_count
    # empty and turn the integer comparison into a misleading red. An app that
    # does not answer at all fails as such.
    local post_db_count="" db_rc=0
    poll_state 5 1 state_is '.speakerDB.count != null' || db_rc=$?
    [ "$db_rc" -ne 2 ] || fail "$(state_why 2 "$label: speakerDB.count after confirm")"
    post_db_count="$(jq -r '.speakerDB.count // 0' <<<"$STATE_BODY")"
    log "$label: speakerDB.count after confirm: $post_db_count (was $pre_db_count)"
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        [ "$post_db_count" -gt "$pre_db_count" ] 2>/dev/null \
            || fail "$label: speakerDB.count did not grow ($pre_db_count → $post_db_count); confirm did not enroll the named voices"
        log "$label: speaker DB learned the confirmed voices ✅"
    fi

    # --- Runtime settings readback ---
    # Re-read /state.settings and confirm the lane didn't drift the app's
    # effective settings mid-run vs the lane-start values. The app instance is
    # stable, so these must match; a diff would mean the pipeline mutated
    # settings unexpectedly. Log-only (a standing lane must not go red on a
    # diagnostic); the exit-trap cleanup separately verifies the persisted
    # UserDefaults + speakers.json are restored to their pre-lane state.
    local end_snap
    if end_snap="$(state_query . 2>/dev/null)"; then
        local end_diarize end_num end_record
        end_diarize="$(jq -r '.settings.diarization.diarize' <<<"$end_snap")"
        end_num="$(jq -r '.settings.diarization.numSpeakers' <<<"$end_snap")"
        end_record="$(jq -r '.settings.recording.recordOnly' <<<"$end_snap")"
        if [ "$end_diarize" = "$diarize" ] && [ "$end_num" = "$num_speakers" ] && [ "$end_record" = "$record_only" ]; then
            log "$label: /state.settings unchanged across the lane (diarize=$end_diarize numSpeakers=$end_num recordOnly=$end_record) ✅"
        else
            log "$label: WARNING: /state.settings drifted during the lane: diarize $diarize->$end_diarize, numSpeakers $num_speakers->$end_num, recordOnly $record_only->$end_record"
        fi
    else
        log "$label: (could not re-read /state.settings for the runtime readback)"
    fi

    # Guard against a future regression that enqueues the shared fixture path
    # directly: the pipeline would MOVE it out of Tests/Fixtures and poison
    # every later lane in this checkout. Assert it still exists here so such a
    # bug fails loudly in THIS lane instead of surfacing as a cryptic
    # "fixture not found" in a downstream lane.
    [ -f "$DEFAULT_FIXTURE" ] \
        || fail "$label: shared fixture $DEFAULT_FIXTURE no longer exists after this lane; a consumer moved it. Enqueue a COPY, never the shared Tests/Fixtures path."
    log "$label: shared fixture intact after the lane ✅"
}

# --- Speaker-naming switch lane (issue #700) -------------------------------
#
# Types into the naming dialog AFTER it has switched to the next pending job of
# the same meeting title. The window keeps one view for both jobs because its
# identity is the title, and the mic track's cluster count differs between the
# jobs, so a remote label that survives the switch sits at a lower row than
# before. That is the geometry that reproduced the issue #700 crash: the field
# a surviving label keeps must carry the user's typing to that label and no
# other. See issue #700 for the defect this guards against.
#
# The switch is done via the dialog's segmented job picker while BOTH jobs are
# still pending ("while the second dialog is showing", in the reporter's words),
# NOT by resolving the first job. This matters and was measured: resolving the
# first drops the picker (count 2 -> 1), which shifts the SpeakerNamingView's
# structural slot in its VStack and makes SwiftUI rebuild it with FRESH fields,
# so the reused view under test is never exercised. Keeping both jobs pending
# keeps the picker present and the view reused, which is what the lane needs.
#
# Two dual-source pairs are enqueued through the same paired import a fleet
# consumer uses, so both jobs are genuinely dual-source (`M_`/`R_` labels) and
# both carry the stem as their title. The app side is pinned to exactly one
# remote cluster through the "expected speakers" setting (it applies to the app
# track only; the mic track always auto-detects), and the mic tracks are chosen
# so the first job clusters into several `M_` speakers and the second into one.
# The resulting positions are ASSERTED before anything is typed: the lane fails
# as "geometry not staged" rather than passing vacuously if the diarizer ever
# hears the fixtures differently.
#
# Why a paired import and not two live recordings. The defect lives in the
# dialog, not in the recorder, and every other lane here covers the recorder. A
# live recording starts only once the meeting is detected, so the mic fixture's
# opening seconds are lost, and how much is lost varies run to run; that is
# exactly the part that decides how many clusters the diarizer hears. The import
# feeds the diarizer the same samples every time.
#
# The keystroke is a real WindowServer key event from outside the process,
# because the naming window is off the in-process /ui/type allowlist (PII). It
# goes through scripts/drive-naming-field.swift, which needs only the
# Accessibility grant the --naming-escape lane already requires; that file says
# why System Events (which would also need Automation) is not used.
# RUNNER PREREQUISITE: the Accessibility grant from the e2e-architecture skill's
# runner setup. Missing, the lane skips loudly and passes, like --naming-escape.
_NS_DIR=""
run_naming_switch() {
    local label="[naming-switch]"
    require_command python3
    require_command swiftc
    [ -f "$DEFAULT_FIXTURE" ] || fail "$label: 2-speaker fixture not found: $DEFAULT_FIXTURE"

    _NS_DIR="$(mktemp -d /tmp/e2e-naming-switch.XXXXXX)"
    local driver="$_NS_DIR/drive-naming-field"
    log "$label: compiling the dialog driver"
    swiftc -O -o "$driver" "$ROOT/scripts/drive-naming-field.swift" 2>&1 | sed 's/^/    /' \
        || fail "$label: could not compile scripts/drive-naming-field.swift"

    # Preflight the one grant this lane needs. SKIP rather than FAIL, for the
    # reason the Escape lane gives: only a person at the GUI can grant it, so a
    # red here would blame every PR for a host prerequisite. Only the driver's
    # explicit answer (exit 3, trusted=false) is the missing grant; a crash or
    # any other output fails the lane, as does anything after this arm.
    local trust trust_status=0
    trust="$("$driver" trusted 2>&1)" || trust_status=$?
    case "$trust_status:$trust" in
        0:*"trusted=true"*) ;;
        3:*"trusted=false"*) ;;
        *) fail "$label: the Accessibility preflight did not answer (exit $trust_status): $trust" ;;
    esac
    if [ "$trust_status" -eq 3 ]; then
        host_skip naming-switch "This process may not use Accessibility, so no keystroke can reach the dialog and the typing-after-switch assertion did not run. Fix: System Settings → Privacy & Security → Accessibility; it is the same grant the --naming-escape lane needs, for this run to $(tcc_grantee) (see the e2e-architecture skill, runner setup step 6)."
        return 0
    fi

    # The settings the lane depends on, read back from the running process (a
    # blind `defaults read` is unreliable for the dev bundle's container redirect).
    local snap diarize num_speakers record_only
    snap="$(state_query .)" || fail "$(state_why $? "$label: the resolved diarization settings")"
    diarize="$(jq -r '.settings.diarization.diarize' <<<"$snap")"
    num_speakers="$(jq -r '.settings.diarization.numSpeakers' <<<"$snap")"
    record_only="$(jq -r '.settings.recording.recordOnly' <<<"$snap")"
    log "$label: resolved settings diarize=$diarize numSpeakers=$num_speakers recordOnly=$record_only"
    [ "$diarize" = "true" ] || fail "$label: settings.diarization.diarize is '$diarize', expected true"
    [ "$num_speakers" = "1" ] || fail "$label: settings.diarization.numSpeakers is '$num_speakers', expected 1 (the app track must yield exactly one remote cluster)"
    [ "$record_only" = "false" ] || fail "$label: settings.recording.recordOnly is '$record_only', expected false"

    # Both pairs carry this stem, and the stem is the meeting title of a paired
    # import with no sidecar; the shared title is what keeps one view alive
    # across the job switch.
    local stem="naming-switch"
    log "$label: building the two pairs under $_NS_DIR/pairs"
    python3 "$ROOT/scripts/fixtures/make-naming-switch-pairs.py" \
        --app "$DEFAULT_FIXTURE" \
        --mic-first "$ROOT/app/MeetingTranscriber/Tests/Fixtures/three_speakers_de.wav" \
        --voice-source "$ROOT/app/MeetingTranscriber/Tests/Fixtures/quality/two_speakers_de.wav" \
        --voice-truth "$ROOT/app/MeetingTranscriber/Tests/Fixtures/quality/two_speakers_de_truth.json" \
        --voice-speaker B --out "$_NS_DIR/pairs" --stem "$stem" 2>&1 | sed 's/^/    /' \
        || fail "$label: could not build the pairs"

    # Wait for a job to park at speaker naming and stash its naming DTO in the
    # caller's `_NS_NAMING` (bash dynamic scoping, as the echo lanes do). An
    # errored job is reported as such instead of being waited out.
    _ns_parked() {
        assert_app_alive
        local state
        state="$(rpc "/v1/jobs/$1" | jq -r '.state // empty')"
        case "$state" in
            error) fail "$label: job $1 errored before reaching speaker naming: $(rpc "/v1/jobs/$1" | jq -r '.error // "<none>"')" ;;
            done) fail "$label: job $1 finished without parking at speaker naming (diarization produced no dialog?)" ;;
        esac
        _NS_NAMING="$(rpc "/v1/jobs/$1/naming")"
        jq -e '(.speakers | length) > 0' <<<"$_NS_NAMING" >/dev/null 2>&1
    }
    local _NS_NAMING=""

    # First job: several mic speakers. Enqueued alone and parked before the
    # second is enqueued, so the window opens on this one.
    local first second first_naming second_naming
    first="$(_echo_enqueue "$label" "$_NS_DIR/pairs/first" "$stem")"
    log "$label: first pair enqueued as $first; waiting for it to park at naming (timeout ${PIPELINE_TIMEOUT_S}s)"
    poll_until "$PIPELINE_TIMEOUT_S" 5 _ns_parked "$first" \
        || fail "$label: first job $first never parked at speaker naming within ${PIPELINE_TIMEOUT_S}s"
    first_naming="$_NS_NAMING"

    second="$(_echo_enqueue "$label" "$_NS_DIR/pairs/second" "$stem")"
    log "$label: second pair enqueued as $second; waiting for it to park at naming"
    poll_until "$PIPELINE_TIMEOUT_S" 5 _ns_parked "$second" \
        || fail "$label: second job $second never parked at speaker naming within ${PIPELINE_TIMEOUT_S}s"
    second_naming="$_NS_NAMING"

    # --- the geometry, asserted rather than assumed ------------------------
    # Sorted labels are the dialog's row order (the view sorts `data.mapping`'s
    # keys). Dual-track prefixes the app/remote track `R_` and the mic/local
    # track `M_`, so with the app track pinned to one remote cluster the SURVIVOR
    # is the single `R_` label, and the trap needs its row in the first job to
    # lie at or past the second job's row count.
    local first_labels second_labels first_count second_count first_index survivor other_label
    first_labels="$(jq -c '[.speakers[].label] | sort' <<<"$first_naming")"
    second_labels="$(jq -c '[.speakers[].label] | sort' <<<"$second_naming")"
    first_count="$(jq -r 'length' <<<"$first_labels")"
    second_count="$(jq -r 'length' <<<"$second_labels")"
    # The remote label of the second job: derived, because the diarizer's id
    # scheme (R_S1, R_SPEAKER_00, ...) is not something the lane should hardcode.
    # Exactly one, since the app track is pinned to one cluster on both jobs.
    local second_remote_count
    second_remote_count="$(jq -r '[.[] | select(startswith("R_"))] | length' <<<"$second_labels")"
    [ "$second_remote_count" = "1" ] \
        || fail "$label: the second job has $second_remote_count remote (R_) speaker(s), expected exactly 1 ($second_labels). Both tracks must diarize for the R_/M_ prefixes to appear; a single-track fallback drops them and there is no survivor to move."
    survivor="$(jq -r 'map(select(startswith("R_"))) | .[0]' <<<"$second_labels")"
    # A non-survivor label present in the second job, for the misroute check.
    other_label="$(jq -r --arg s "$survivor" 'map(select(. != $s)) | .[0] // ""' <<<"$second_labels")"
    first_index="$(jq -r --arg s "$survivor" 'index($s) // -1' <<<"$first_labels")"
    log "$label: first job rows  $first_labels ($survivor at row $first_index)"
    log "$label: second job rows $second_labels ($second_count rows, survivor $survivor, other $other_label)"
    [ "$(jq -r '.meetingTitle' <<<"$first_naming")" = "$(jq -r '.meetingTitle' <<<"$second_naming")" ] \
        || fail "$label: the two jobs do not share a meeting title ($(jq -r '.meetingTitle' <<<"$first_naming") vs $(jq -r '.meetingTitle' <<<"$second_naming")); the window would give the second job fresh fields and no reused field would be exercised"
    [ -n "$other_label" ] \
        || fail "$label: the second job has only the survivor row ($second_labels); the misroute check needs another row to prove the write did not land there"
    [ "$first_index" -ge 0 ] \
        || fail "$label: geometry not staged: $survivor is absent from the first job ($first_labels)"
    [ "$first_index" -ge "$second_count" ] \
        || fail "$label: geometry not staged: $survivor sits at row $first_index of the first job but the second job has $second_count rows, so the stale binding would stay in bounds and the defect could only misroute, not trap. The mic track of the first pair must cluster into more speakers than the whole second job has; the diarizer heard first=$first_labels second=$second_labels."
    log "$label: geometry staged: row $first_index >= $second_count rows, so a stale binding trips the bounds check ✅"

    # The window must be showing the FIRST job, or the switch below is no
    # switch. Its fields are enumerated from outside through AX.
    poll_state 30 2 state_is "$_NAMING_WINDOW_VISIBLE" \
        || fail "$(state_why $? "$label: naming window never became visible")"
    # Labels whose name field is currently in the window, sorted, as a JSON array.
    _ns_shown_labels() {
        "$driver" windows 2>/dev/null \
            | sed -n 's/^identifier=speaker-name-\(.*\) role=.*/\1/p' \
            | jq -R . | jq -sc 'sort'
    }
    local shown=""
    _ns_shows() { shown="$(_ns_shown_labels)"; [ "$shown" = "$1" ]; }

    # The picker is driven BY IDENTITY, never by a fixed ordinal. This lane does
    # not own the queue: the app recovers orphaned recordings a beat after
    # launch, and with nothing here auto-skipping naming such a job parks and
    # takes a picker segment of its own. In its first CI run one did exactly
    # that and landed BETWEEN this lane's two jobs (under the pinned expected
    # speaker count a single-source recording diarizes to a lone "S1"), so a
    # hard-coded "segment 1" selected a foreign job. A job's segment is its
    # position in /state.pendingNamingJobs: that array is built from the very
    # `pendingSpeakerNamingJobs` the picker's ForEach iterates, so the two
    # orders agree by construction. The order is re-read right before every
    # press, the picker's segment count is required to equal the pending count
    # read, and the press is verified by the labels that appear; a bounded
    # retry absorbs a job parking between the read and the press. Foreign jobs
    # are left alone, they belong to whichever lane produced them.
    local _ns_order=""
    _ns_select_job() {
        local job="$1" labels="$2" which="$3" attempt idx count segments out
        for attempt in 1 2 3; do
            _ns_order="$(state_query '[.pendingNamingJobs[].jobID]' -c)" \
                || fail "$(state_why $? "$label: the pending naming order")"
            idx="$(jq -r --arg id "$job" 'index($id) // -1' <<<"$_ns_order")"
            count="$(jq -r 'length' <<<"$_ns_order")"
            [ "$idx" -ge 0 ] \
                || fail "$label: the $which job $job is no longer pending (pending order: $_ns_order)"
            [ "$count" -ge 2 ] \
                || fail "$label: only $count pending naming job(s), so the dialog shows no job picker; both of this lane's jobs must be pending (pending order: $_ns_order)"
            out="$("$driver" select-segment --index "$idx" 2>&1)" \
                || fail "$label: could not select picker segment $idx for the $which job: $out"
            segments="$(sed -n 's/^selected-segment=[0-9]* of=\([0-9]*\)$/\1/p' <<<"$out")"
            if [ "$segments" = "$count" ] && poll_until 10 1 _ns_shows "$labels"; then
                log "$label: $which job selected at picker segment $idx of $count (pending order: $_ns_order)"
                return 0
            fi
            log "$label: attempt $attempt: picker has ${segments:-?} segment(s) vs $count pending job(s), window shows $shown; a job may have parked meanwhile, re-reading the order"
            sleep 2
        done
        fail "$label: could not bring the $which job ($job) into the window: the picker has ${segments:-?} segment(s) but /state lists $count pending naming job(s), and the window shows $shown where $labels was expected (pending order: $_ns_order)"
    }

    local pending_now pending_count
    pending_now="$(state_query '[.pendingNamingJobs[] | {jobID, meetingTitle}]' -c)" \
        || fail "$(state_why $? "$label: the pending naming jobs")"
    pending_count="$(jq -r 'length' <<<"$pending_now")"
    log "$label: pending naming jobs now: $pending_now"
    [ "$pending_count" -eq 2 ] \
        || log "$label: note: $((pending_count - 2)) pending job(s) are not this lane's (a launch-recovered recording, or one another lane left parked); selecting by identity"

    # Show the first job explicitly rather than trusting what opened: the window
    # opens on the first PENDING job, which may be a foreign one. The survivor's
    # field is created here, at its higher row.
    _ns_select_job "$first" "$first_labels" first
    log "$label: window shows the first job ($first_count fields)"

    # Switch to the second job the way the reporter did: with BOTH jobs still
    # pending, pick the other one in the dialog's segmented job picker ("while
    # the second dialog is showing"). This is what keeps one view alive across
    # the switch and so keeps its reused fields in play. Resolving the
    # first job instead would drop the picker (count 2 -> 1), which shifts the
    # SpeakerNamingView's structural slot and makes SwiftUI rebuild it with
    # FRESH fields, and the defect then cannot show. Measured on the
    # unfixed build: the resolve-first path did not crash; the picker-switch
    # path does.
    _ns_select_job "$second" "$second_labels" second
    log "$label: picker switched to the second job ($second_count fields) in the same view; first job still pending"

    # --- type into the survivor -----------------------------------------------
    local field="speaker-name-$survivor" other_field="speaker-name-$other_label" typed="Speaker Z"
    local other_before other_after
    other_before="$("$driver" read --identifier "$other_field" 2>/dev/null | sed -n 's/^value=//p')"
    "$driver" focus --identifier "$field" 2>&1 | sed 's/^/    /' \
        || fail "$label: could not focus $field (see driver output above)"

    local out rc=0
    set +e
    out="$("$driver" type --identifier "$field" --text "$typed" 2>&1)"
    rc=$?
    set -e
    printf '%s\n' "$out" | sed 's/^/    /'
    # The regression itself: pre-fix, the first keystroke wrote names[$first_index]
    # into a $second_count-element array and the app died. Check the process
    # directly so the report names the defect rather than a generic dead app.
    if ! pgrep -f "MeetingTranscriber-Dev.app/Contents/MacOS/MeetingTranscriber" >/dev/null 2>&1; then
        fail "$label: the app DIED on the first keystrokes into $survivor after the dialog switched from a $first_count-speaker job to a $second_count-speaker job with the same title (issue #700: the field kept a binding to row $first_index, past the new job's $second_count rows). Driver output: $out"
    fi
    assert_app_alive
    [ "$rc" -eq 0 ] || fail "$label: the dialog driver failed (exit $rc); see its output above"

    local value
    value="$(sed -n 's/^value=//p' <<<"$out" | tail -1)"
    [ "$value" = "$typed" ] \
        || fail "$label: typed '$typed' into $survivor but that field reads '$value' (the keystrokes went elsewhere)"
    other_after="$("$driver" read --identifier "$other_field" 2>/dev/null | sed -n 's/^value=//p')"
    [ "$other_after" = "$other_before" ] \
        || fail "$label: typing into $survivor changed M_SPEAKER_00 from '$other_before' to '$other_after' (misrouted write)"
    log "$label: '$typed' landed in $survivor and nowhere else ✅"

    # --- the confirmed name has to reach persistent state ----------------------
    # Confirm from the dialog (AXPress on its button), not over RPC: an RPC
    # confirm carries its own mapping and would say nothing about what the
    # dialog holds. `confirm-button` is A11yID.confirmButton.
    "$driver" press --identifier "confirm-button" 2>&1 | sed 's/^/    /' \
        || fail "$label: could not press the Confirm button"
    local state=""
    _ns_terminal() {
        assert_app_alive
        state="$(rpc "/v1/jobs/$1" | jq -r '.state // empty')"
        [ "$state" = "done" ] || [ "$state" = "error" ]
    }
    poll_until "$PIPELINE_TIMEOUT_S" 5 _ns_terminal "$second" \
        || fail "$label: second job $second did not reach a terminal state within ${PIPELINE_TIMEOUT_S}s after Confirm (state=$state)"
    local final
    final="$(rpc "/v1/jobs/$second")"
    [ "$state" = "done" ] || fail "$label: second job state=$state after Confirm, expected done. Error: $(jq -r '.error // "<none>"' <<<"$final")"

    # Assert the confirmed name reached the speaker DB, read over RPC
    # (`/state.speakerDB`). This is the confirm going through end to end: the
    # dialog held '$typed' in $survivor (verified above), and confirming
    # enrolled that voice under that name. Deliberately NOT the transcript file:
    # that lives under ~/Downloads, which is TCC-protected, so reading it needs
    # the fragile per-runner Downloads grant that the naming-confirm lane already
    # depends on; `/state.speakerDB` is served by the app itself and needs no
    # such grant, which is also what lets this lane be hand-run over SSH. The
    # transcript relabel is already covered end to end by the naming-confirm lane.
    _ns_db_has_typed() {
        state_is '((.speakerDB.recentNames // []) + (.speakerDB.knownSpeakerNames // [])) | index($n) != null' --arg n "$typed"
    }
    poll_state --each assert_app_alive 30 2 _ns_db_has_typed \
        || fail "$(state_why $? "$label: '$typed' never appeared in /state.speakerDB after Confirm (recent=$(jq -c '.speakerDB.recentNames' <<<"$STATE_BODY") known=$(jq -c '.speakerDB.knownSpeakerNames' <<<"$STATE_BODY")). The confirmed dialog contents did not enroll the voice.")"
    log "$label: '$typed' enrolled into the speaker DB after Confirm ✅"

    # Leave nothing parked: the first job was never resolved (the lane switched
    # away from it via the picker rather than resolving it). Skip it over RPC so
    # the dialog does not reopen on the next launch, then let it settle.
    curl --silent --show-error --max-time 10 -X POST \
        --header "Authorization: Bearer $RPC_TOKEN" --header "Content-Length: 0" \
        "$RPC_BASE/v1/jobs/$first/naming/skip" >/dev/null 2>&1 || true
    poll_until "$PIPELINE_TIMEOUT_S" 5 _ns_terminal "$first" || true
    log "$label: PASS"
}

# Title-source lane (issue #501): drive the app's window-title lookup with a
# title that is NOT usable — the window title equals the app name, which the
# lookup skips — so PowerAssertionDetector finds no meeting-window title and
# must fall back to the clean "<app> Call" placeholder. Pre-fix the detector
# leaked the raw IOKit assertion name ("Simulator Meeting Call in progress")
# instead, so this assertion fails against the old code (non-vacuous). Proves
# the real deployed detection → title-selection → job-title chain, which the
# unit tests can only exercise through injected seams.
run_title_source() {
    local label="[title-source]"
    log "$label: starting meeting-simulator --title MeetingSimulator (no usable window title) → $SIMULATOR_FIXTURE"
    "$SIMULATOR_BIN" "$SIMULATOR_FIXTURE" --title "MeetingSimulator" >/tmp/e2e-app-sim.log 2>&1 &
    SIM_PID=$!

    _poll_for_new_lastjob_terminal "$label" ignore-recovered
    [ "$POLL_LJ_STATE" = "done" ] || fail "$label: lastJob.state == \"$POLL_LJ_STATE\", expected \"done\""

    local meeting_title
    meeting_title="$(jq -r '.lastJob.meetingTitle // empty' <<<"$STATE_BODY")"
    log "$label: lastJob.meetingTitle = \"$meeting_title\""
    [ "$meeting_title" = "MeetingSimulator Call" ] \
        || fail "$label: meetingTitle == \"$meeting_title\", expected \"MeetingSimulator Call\". The window title equalled the app name, so the title lookup should return nil and the detector substitute the placeholder; a leaked assertion name or window title means the title-source fix regressed."
    log "$label: PASS — no usable window title fell back to the clean placeholder ✅"
}

# --- mic-stall lane (issues #724, #706) ------------------------------------
#
# The field fault: a microphone engine that logged "Mic recording started" and
# then delivered nothing, for 48 minutes in one report, while the app track
# recorded on. The capture layer's progress watchdog rebuilds such an engine
# with growing deadlines and releases it once a minute has passed without a
# buffer, and the app tells the user. Nothing on a runner produces the fault
# (the loopback input always delivers, the field cases need a Bluetooth
# headset), so the fault-injection build withholds every buffer in the handler
# on request: the real engine starts and runs, and the handler sees nothing.
#
# What is asserted, each from the layer that owns it:
#   - the capture log: the fault was active, the engine was rebuilt after 3, 6,
#     12 and 24 s without a buffer (rebuilds 1 to 4, in that order) and the
#     microphone released after at least the 60 s budget;
#   - /state during the recording: micFault becomes "stalled" with
#     micStallCount 1, not before the budget could have run out; the
#     microphone never delivered (or, late variant, did deliver before it
#     stopped); and seconds after the release the recording is still running
#     with the app channel delivering and no app fault;
#   - /state.notifications: exactly one "Capture Channel Lost" with the stall
#     wording, which is the notification fault path, not just the flag;
#   - the job: it finishes done with no error and a German transcript, which
#     can only come from the app track, and the files on disk agree (the app
#     track carries the fixture, the mic track holds only digital silence,
#     or only its first seconds in the late variant).
#
# The app runs with an isolated home (see APP_HOME), so everything it writes
# lands in a temp dir this lane removes, and with protocol generation off.
MIC_STALL_MEETING_S=110
# The rebuild deadlines `MicCaptureProgressPolicy` must produce, in order.
MIC_STALL_EXPECTED_REBUILDS="3:1 6:2 12:3 24:4"
MIC_STALL_BUDGET_S=60
# How long into the recording the stall may land on /state: the budget, plus
# the late variant's delivery and its last healthy check, plus the 1 s tick
# and the poll. Earlier than the budget means something other than the
# watchdog released the microphone.
MIC_STALL_EARLIEST_S=$((MIC_STALL_BUDGET_S - 3))
MIC_STALL_LATEST_S=$((MIC_STALL_BUDGET_S + 25))

_ms_float_lt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'; }

# The capture layer's own account since $1, for this run's app only.
_ms_capture_log() {
    /usr/bin/log show --style compact --info --start "$1" \
        --predicate "processID == ${_launched_app:-0} AND subsystem == \"com.meetingtranscriber.audiotap\" AND category == \"MicCapture\"" 2>/dev/null || true
}

run_mic_stall() {
    local label="[mic-stall:$MIC_STALL]"
    local log_start
    log_start="$(date '+%Y-%m-%d %H:%M:%S')"
    log "$label: starting meeting-simulator (looping $SIMULATOR_FIXTURE for ${MIC_STALL_MEETING_S}s)"
    "$SIMULATOR_BIN" "$SIMULATOR_FIXTURE" --loop --duration "$MIC_STALL_MEETING_S" >/tmp/e2e-app-sim.log 2>&1 &
    SIM_PID=$!

    poll_state 60 1 state_is '.watchState == "recording"' \
        || fail "$(state_why $? "$label: no recording started within 60s of the meeting")"
    local rec_at
    rec_at="$(date +%s)"
    log "$label: recording; watching /state for the microphone stall"

    # Until the stall, keep what the microphone did: whether /state ever saw it
    # deliver a buffer. One jq per tick, `|`-joined for the reason given at
    # _poll_for_new_lastjob_terminal. The loop is poll_state's, as there: an
    # unanswered tick is skipped, not read as empty fields (which used to say
    # "the recording ended"), and assert_app_alive runs on every tick. The
    # window ends where the old loop's did, at the first tick more than
    # MIC_STALL_LATEST_S into the recording. Unlike the lastJob poll, the
    # deadline read is not judged: MIC_STALL_LATEST_S bounds when the stall
    # may land, the snapshot does not say when it landed, and that read can
    # return up to STATE_READ_BOUND_S after the window.
    local fault="" count="" mic_age="" app_age="" watch="" elapsed=0 saw_mic_buffer=false status=0
    _ms_stalled() {
        fault=""; count=""; mic_age=""; app_age=""; watch=""
        IFS='|' read -r fault count mic_age app_age watch < <(
            jq -r '[.channelHealth.micFault // "", (.channelHealth.micStallCount // "" | tostring), (.channelHealth.micSecondsSinceLastBuffer // "" | tostring), (.channelHealth.appSecondsSinceLastBuffer // "" | tostring), .watchState // ""] | join("|")' <<<"$STATE_BODY"
        ) || true
        elapsed=$(( $(date +%s) - rec_at ))
        if [ -n "$mic_age" ] && _ms_float_lt "$mic_age" 2; then saw_mic_buffer=true; fi
        [ "$fault" = stalled ] && return 0
        [ "$watch" = recording ] || fail "$label: the recording ended after ${elapsed}s without the microphone ever being reported stalled (micFault='$fault')"
        return 1
    }
    poll_state --each assert_app_alive \
        $(( rec_at + MIC_STALL_LATEST_S + 1 - $(date +%s) )) 1 _ms_stalled || status=$?
    # On a pass, elapsed is the stalled read's; on a failure, the time now.
    [ "$status" -eq 0 ] || elapsed=$(( $(date +%s) - rec_at ))
    case "$status" in
        0) ;;
        1)
            # Which half broke: the capture layer releasing the microphone, or
            # the release reaching /state.
            if _ms_capture_log "$log_start" | grep -q "releasing the microphone"; then
                fail "$label: the capture log shows the microphone released, but /state still reads micFault='$fault' ${elapsed}s into the recording: the stall never reached the app"
            fi
            fail "$label: no stall on /state ${elapsed}s into the recording (micFault='$fault' micSecondsSinceLastBuffer='$mic_age'), and no release in the capture log. The watchdog must release a microphone that went ${MIC_STALL_BUDGET_S}s without a buffer."
            ;;
        *) fail "$(state_why "$status" "$label: whether the microphone was reported stalled within ${elapsed}s of the recording (last answered micFault='$fault' micSecondsSinceLastBuffer='$mic_age')")" ;;
    esac
    log "$label: /state micFault=stalled micStallCount=$count after ${elapsed}s (micSecondsSinceLastBuffer='$mic_age')"
    [ "$elapsed" -ge "$MIC_STALL_EARLIEST_S" ] \
        || fail "$label: stalled after ${elapsed}s, before the ${MIC_STALL_BUDGET_S}s budget could have run out"
    [ "$count" = 1 ] || fail "$label: micStallCount=$count at the first stall, expected 1"
    if [ "$MIC_STALL" = stall ]; then
        [ "$saw_mic_buffer" = false ] \
            || fail "$label: /state saw the microphone deliver a buffer although every one was to be withheld; the fault did not hold"
    else
        [ "$saw_mic_buffer" = true ] \
            || fail "$label: /state never saw the microphone deliver, so this run measured a microphone that never started, not one that stopped"
    fi

    # Released, not just flagged: seconds later the recording goes on, the app
    # channel still delivers, and nothing is reported against it.
    sleep 6
    local snap app_fault
    snap="$(state_query .)" || fail "$(state_why $? "$label: the channel health 6s after the stall")"
    IFS='|' read -r fault count mic_age app_age watch app_fault < <(
        jq -r '[.channelHealth.micFault // "", (.channelHealth.micStallCount // "" | tostring), (.channelHealth.micSecondsSinceLastBuffer // "" | tostring), (.channelHealth.appSecondsSinceLastBuffer // "" | tostring), .watchState // "", .channelHealth.appFault // ""] | join("|")' <<<"$snap"
    ) || true
    log "$label: 6s after the stall: watchState=$watch micFault=$fault micStallCount=$count appSecondsSinceLastBuffer=$app_age appFault='${app_fault}'"
    [ "$watch" = recording ] || fail "$label: the recording stopped with the microphone (watchState=$watch); only the microphone may be released"
    [ "$fault" = stalled ] && [ "$count" = 1 ] || fail "$label: after the stall /state reads micFault='$fault' micStallCount='$count', expected stalled/1"
    [ -n "$app_age" ] && _ms_float_lt "$app_age" 2 \
        || fail "$label: the app channel is not delivering after the microphone was released (appSecondsSinceLastBuffer='$app_age')"
    [ -z "$app_fault" ] || fail "$label: the app channel reports '$app_fault'; the stall must not touch it"

    local lost lost_body lost_posted
    lost="$(jq -c '[.notifications[]? | select(.title == "Capture Channel Lost")]' <<<"$snap")"
    [ "$(jq 'length' <<<"$lost")" = 1 ] \
        || fail "$label: expected exactly one \"Capture Channel Lost\" notification, got: $lost"
    lost_body="$(jq -r '.[0].body' <<<"$lost")"
    lost_posted="$(jq -r '.[0].posted' <<<"$lost")"
    # Worded from the stall: a microphone withheld from the start never
    # delivered, so it must not be told it "stopped"; the late variant did.
    local expected_opening="The microphone stopped delivering audio and restarting it did not help"
    [ "$MIC_STALL" = stall ] \
        && expected_opening="The microphone has not delivered any audio in this recording and restarting it did not help"
    case "$lost_body" in
        "$expected_opening"*) ;;
        *) fail "$label: the \"Capture Channel Lost\" notification does not carry the stall wording for '$MIC_STALL' (expected it to open with '$expected_opening'): $lost_body" ;;
    esac
    # `posted` is whether the notification centre was there to take it, a
    # property of the host's notification settings rather than of the fault
    # path, so it is reported and not asserted.
    log "$label: notification \"Capture Channel Lost\" with the stall wording (posted=$lost_posted)"
    log "$label: other notifications: $(jq -c '[.notifications[]? | select(.title != "Capture Channel Lost") | .title]' <<<"$snap")"

    # The capture layer's own account, read for this app's pid only.
    local caplog rebuilds stall_line stall_s
    caplog="$(_ms_capture_log "$log_start")"
    grep -q "\[debug-fault\] withholding every mic buffer" <<<"$caplog" \
        || fail "$label: the capture log has no [debug-fault] line, so this run cannot show the fault was the one injected. Log:"$'\n'"$caplog"
    log "$label: 'Mic recording started' lines in the capture log: $(grep -c 'Mic recording started' <<<"$caplog" || true)"
    rebuilds="$(grep -oE 'no buffer for [0-9]+s, rebuilding the engine \(rebuild [0-9]+ without audio\)' <<<"$caplog" \
        | sed -E 's/no buffer for ([0-9]+)s.*\(rebuild ([0-9]+) .*/\1:\2/' | tr '\n' ' ' | sed 's/ $//')"
    log "$label: rebuilds (deadline:rebuild) from the capture log: '$rebuilds'"
    [ "$rebuilds" = "$MIC_STALL_EXPECTED_REBUILDS" ] \
        || fail "$label: the watchdog's rebuilds were '$rebuilds', expected '$MIC_STALL_EXPECTED_REBUILDS'"
    stall_line="$(grep -oE 'no audio for [0-9]+s across [0-9]+ rebuilds, releasing the microphone' <<<"$caplog" || true)"
    [ "$(grep -c . <<<"$stall_line")" = 1 ] && [ -n "$stall_line" ] \
        || fail "$label: expected one release line in the capture log, got: '$stall_line'"
    stall_s="$(sed -E 's/no audio for ([0-9]+)s.*/\1/' <<<"$stall_line")"
    [ "$stall_s" -ge "$MIC_STALL_BUDGET_S" ] && grep -q "across 4 rebuilds" <<<"$stall_line" \
        || fail "$label: released with '$stall_line', expected at least ${MIC_STALL_BUDGET_S}s across 4 rebuilds"
    log "$label: capture log: '$stall_line'"

    # The recording still goes through the pipeline: done, no error, and a
    # German transcript, which with the microphone withheld can only come from
    # the app track.
    _poll_for_new_lastjob_terminal "$label" ignore-recovered
    local final
    final="$STATE_BODY"
    jq '.lastJob' <<<"$final"
    [ "$POLL_LJ_STATE" = "done" ] \
        || fail "$label: lastJob.state == \"$POLL_LJ_STATE\", expected \"done\". Error: $(jq -r '.lastJob.error // "<none>"' <<<"$final")"
    [ "$(jq -r '.lastJob.error // ""' <<<"$final")" = "" ] || fail "$label: the job finished with an error"
    local transcript_path
    transcript_path="$(jq -r '.lastJob.transcriptPath // empty' <<<"$final")"
    [ -n "$transcript_path" ] && [ -f "$transcript_path" ] || fail "$label: no transcript file ('$transcript_path')"
    case "$transcript_path" in
        "$APP_HOME"/*) ;;
        *) fail "$label: the transcript was written outside the lane's isolated home: $transcript_path" ;;
    esac
    assert_transcript_is_german "$label" "$transcript_path"

    # The files: the app track carries the fixture, the microphone track holds
    # no audio (or only its first seconds in the late variant). In the
    # isolated home the only recording is this one.
    local app_wav mic_wav mic_s verdict
    app_wav="$(find "$RECORDINGS_DIR" -name "*_app.wav" -type f 2>/dev/null | head -1)"
    mic_wav="$(find "$RECORDINGS_DIR" -name "*_mic.wav" -type f 2>/dev/null | head -1)"
    [ -n "$app_wav" ] || fail "$label: no app track under $RECORDINGS_DIR"
    if verdict="$("$MTCLI" wav-verdict "$app_wav" --threshold-dbfs=$WAV_VERDICT_THRESHOLD_DBFS --min-active-seconds="$WAV_VERDICT_FIXTURE_MIN_ACTIVE_S")"; then
        log "$label: app track $(basename "$app_wav"): $verdict"
    else
        fail "$label: the app track is silent or short; the stall must not cost the app channel"
    fi
    if [ -n "$mic_wav" ]; then
        mic_s="$(afinfo "$mic_wav" 2>/dev/null | sed -nE 's/^estimated duration: ([0-9.]+) sec.*/\1/p')"
        log "$label: mic track $(basename "$mic_wav"): ${mic_s:-?}s"
        if [ "$MIC_STALL" = stall ]; then
            # Not empty, by design: a capture restarted before it ever
            # delivered is anchored at its start and each rebuild writes the
            # wait as silence, so the track runs to the last rebuild (about
            # 3+6+12+24 s). What must hold is that none of it is audio: exact
            # zeros, which a microphone in a room never produces.
            verdict="$("$MTCLI" wav-verdict "$mic_wav" --threshold-dbfs=-100 --min-active-seconds=0.01 || true)"
            log "$label: mic track content: $verdict"
            grep -q '"overallRMSdBFS":-120' <<<"$verdict" \
                || fail "$label: the mic track carries audio although no buffer reached the handler: $verdict"
        else
            [ -n "$mic_s" ] && _ms_float_lt 5 "$mic_s" && _ms_float_lt "$mic_s" 20 \
                || fail "$label: the mic track holds ${mic_s:-?}s; expected roughly the 10s delivered before the fault"
        fi
    else
        fail "$label: no mic track under $RECORDINGS_DIR; a stalled microphone keeps its file"
    fi
    log "$label: warnings on the job: $(jq -c '.lastJob.warnings' <<<"$final")"
    echo
    PRE_LAST_JOB_ID="$POLL_LJ_ID"
    SIM_PID=""
}

# --- upgrade lane -------------------------------------------------------------
#
# Every other lane starts the app on a clean or an isolated empty home, so
# nothing exercises the new build on the data an older release left behind,
# and three of this release's changes act only on such data. Seeded before
# launch by `_ug_seed` (above, with what each seed is derived from); asserted
# here, each change from the layer that shows it:
#   1. WhisperKit models move once from Documents/huggingface to the app's own
#      folder (WhisperKitModelMigration): the variant being loaded moves whole,
#      inode for inode, with its download metadata; its tokenizer is copied;
#      it loads with the network closed, so not through a download; nothing
#      else in the shared folder is touched, an incomplete variant included;
#      the new folder is excluded from backup; a relaunch moves nothing.
#   2. An undecodable speakers.json is quarantined on the first write instead
#      of being overwritten (SpeakerMatcher.mutateDB): launch leaves it byte
#      for byte, the first write moves it to speakers.json.corrupt-<stamp>
#      unchanged, the DB starts empty, the user is told, the app keeps running.
#   3. Queue snapshot and finished-job records written by v0.8.1 are read by
#      the new folder logic (PipelineQueue.loadSnapshot, TerminalJobStore):
#      the old record is still served; the interrupted job is restored, runs
#      to done, its recording moves from staging to <output>/recordings and
#      into the ledger, and neither this launch nor the next makes a second
#      job of it.
# Then the account's real model folders are compared with their state before
# the seed, which is what shows the isolated home held.
#
# The queue is built, and the snapshot read, on the first watch start or import
# (`PipelineController.rebuild`). The lane cannot watch (see _UG_APP_ARGS), so
# it imports a fixture, which runs the same rebuild; that job is the "trigger"
# below and is counted like any other.

_UG_MODEL_TIMEOUT_S=300

# Fail with the tail of the app's own output, which a home removed at exit
# would otherwise take with it.
_ug_fail() {
    log "[upgrade] last lines of the app's output:"
    tail -n 40 "$_UG_LANE_DIR/app.log" 2>/dev/null | sed 's/^/    /' || true
    fail "$@"
}

# Polls until the WhisperKit engine reports the lane's variant loaded. Any
# `downloading` seen on the way fails at once: with the network closed a
# download cannot succeed, and its being tried at all means the local copy was
# not found where the migration should have put it. A `loading` followed by
# `unloaded` is a failed load, and fails at once too.
_UG_MODEL_STATE=""
_UG_MODEL_SEEN=""
_ug_model_settled() {
    local state variant
    read -r state variant < <(jq -r '.engines.whisperKit | "\(.modelState // "") \(.modelVariant // "")"' <<<"$STATE_BODY" 2>/dev/null || true) || true
    [ -n "$state" ] || return 1
    [ "$state" = "$_UG_MODEL_STATE" ] || _UG_MODEL_SEEN="$_UG_MODEL_SEEN $state"
    _UG_MODEL_STATE="$state"
    case "$state" in
        downloading) return 0 ;;
        loaded) [ "$variant" = "$_UG_VARIANT" ] ;;
        unloaded) case "$_UG_MODEL_SEEN" in *loading*) return 0 ;; esac; return 1 ;;
        *) return 1 ;;
    esac
}
_ug_await_model() {
    local label="$1"
    _UG_MODEL_STATE="" _UG_MODEL_SEEN=""
    poll_state --each assert_app_alive "$_UG_MODEL_TIMEOUT_S" 1 _ug_model_settled \
        || _ug_fail "$(state_why $? "$label: WhisperKit did not load $_UG_VARIANT within ${_UG_MODEL_TIMEOUT_S}s (states seen:${_UG_MODEL_SEEN:- none}). Only 'unloaded' seen usually means a load that failed between two polls: with the network closed, a download attempt fails within milliseconds")"
    [ "$_UG_MODEL_STATE" = loaded ] \
        || _ug_fail "$label: WhisperKit went '$_UG_MODEL_STATE' (states seen:$_UG_MODEL_SEEN). With the network closed that means it did not find $_UG_VARIANT in its own folder and tried the Hub"
    log "$label: $_UG_VARIANT loaded with the network closed (states seen:$_UG_MODEL_SEEN)"
}

# Fails unless `dir` now fingerprints as recorded in `file`; with a fifth
# argument, by that function instead (upgrade_tree_digest for a copy).
_ug_expect_fingerprint() {
    local label="$1" what="$2" dir="$3" file="$4" measure="${5:-upgrade_tree_fingerprint}"
    "$measure" "$dir" >"$file.now"
    cmp -s "$file" "$file.now" \
        || _ug_fail "$label: $what differs ($dir): $(diff "$file" "$file.now" | head -5 | tr '\n' ' ')"
}

# The one entry in `dir` matching `pattern`, left in _UG_FOUND; fails on none
# or several. A global rather than printed, because `_ug_fail` inside a command
# substitution would exit only the subshell and lose the app's output tail.
_UG_FOUND=""
_ug_single() {
    local label="$1" dir="$2" pattern="$3"
    _UG_FOUND="$(find "$dir" -maxdepth 1 -name "$pattern" -print)"
    [ -n "$_UG_FOUND" ] && [ "$(printf '%s\n' "$_UG_FOUND" | wc -l | tr -d ' ')" = 1 ] \
        || _ug_fail "$label: expected exactly one $pattern in $dir, found: ${_UG_FOUND:-none}"
}

_ug_assert_settings() {
    local label="[upgrade:settings]" snap
    snap="$(state_query .)" || _ug_fail "$(state_why $? "$label: whether the app took the lane's launch arguments")"
    jq -e --arg v "$_UG_VARIANT" '.settings.transcription.engine == "whisperKit"
        and .settings.transcription.whisperKitModel == $v
        and .settings.diarization.diarize == false and .settings.diarization.vadEnabled == false
        and .settings.protocolGeneration.provider == "none" and .settings.detection.autoWatch == false
        and .watchState == null' <<<"$snap" >/dev/null \
        || _ug_fail "$label: the app did not take the lane's launch arguments: $(jq -c '{t: .settings.transcription, d: .settings.diarization.diarize, v: .settings.diarization.vadEnabled, p: .settings.protocolGeneration.provider, w: .settings.detection.autoWatch, watchState}' <<<"$snap")"
    log "$label: launch arguments in effect (WhisperKit $_UG_VARIANT, no diarization, no VAD, no protocol, not watching)"
}

_ug_assert_model() {
    local label="[upgrade:model]"
    local old_repo="$_UG_DOCS_HF/$UPGRADE_WHISPERKIT_REPO" new_repo="$_UG_APP_HF/$UPGRADE_WHISPERKIT_REPO"
    _ug_await_model "$label"
    [ ! -e "$old_repo/$_UG_VARIANT" ] \
        || _ug_fail "$label: $_UG_VARIANT is still in Documents/huggingface after a load from the app's folder"
    _ug_expect_fingerprint "$label" "the moved $_UG_VARIANT (inode, size or time of a file)" \
        "$new_repo/$_UG_VARIANT" "$_UG_LANE_DIR/variant.seeded"
    [ ! -e "$old_repo/.cache/huggingface/download/$_UG_VARIANT" ] \
        || _ug_fail "$label: the download metadata of $_UG_VARIANT was left in Documents/huggingface"
    _ug_expect_fingerprint "$label" "the moved download metadata" \
        "$new_repo/.cache/huggingface/download/$_UG_VARIANT" "$_UG_LANE_DIR/metadata.seeded"
    _ug_expect_fingerprint "$label" "the $_UG_TOKENIZER tokenizer copied to the app's folder (contents)" \
        "$_UG_APP_HF/$UPGRADE_TOKENIZER_ORG/$_UG_TOKENIZER" "$_UG_LANE_DIR/tokenizer.digest" upgrade_tree_digest
    _ug_expect_fingerprint "$label" "the tokenizer in Documents (it is copied, never moved)" \
        "$_UG_DOCS_HF/$UPGRADE_TOKENIZER_ORG" "$_UG_LANE_DIR/tokenizer.seeded"
    _ug_expect_fingerprint "$label" "the incomplete $_UG_INCOMPLETE_VARIANT" \
        "$old_repo/$_UG_INCOMPLETE_VARIANT" "$_UG_LANE_DIR/incomplete.seeded"
    [ ! -e "$new_repo/$_UG_INCOMPLETE_VARIANT" ] \
        || _ug_fail "$label: the incomplete $_UG_INCOMPLETE_VARIANT appeared in the app's folder"
    _ug_expect_fingerprint "$label" "another tool's model in the shared folder" \
        "$_UG_DOCS_HF/models/example-org" "$_UG_LANE_DIR/other.seeded"
    [ -z "$(find "$_UG_APP_HF" \( -name '*.incomplete' -o -name '.whisper-*.partial-*' \) -print -quit)" ] \
        || _ug_fail "$label: partial downloads or copies were left in the app's folder"
    # Checked on the attribute, not with `tmutil isexcluded`: that reports the
    # whole temp dir this home lives in as excluded, so it would pass anyway.
    xattr -p com.apple.metadata:com_apple_backup_excludeItem "$_UG_APP_HF" >/dev/null 2>&1 \
        || _ug_fail "$label: the app's model folder is not excluded from backup"
    log "$label: moved whole with its metadata, tokenizer copied, incomplete variant and shared content untouched, folder excluded from backup"
}

_ug_assert_speakers() {
    local label="[upgrade:speakers]" status corrupt
    cmp -s "$_UG_LANE_DIR/speakers.seed" "$_UG_DATA_DIR/speakers.json" \
        || _ug_fail "$label: launching changed the unreadable speakers.json; it must stay as it is until something writes"
    local snap
    snap="$(state_query .)" || _ug_fail "$(state_why $? "$label: how /state reads the unreadable DB")"
    jq -e '.speakerDB.count == 0' <<<"$snap" >/dev/null \
        || _ug_fail "$label: /state does not read the unreadable DB as empty"
    # Any write runs the read-modify-write that quarantines; deleting a name
    # nobody has is the one that changes nothing else.
    status="$(rpc_post_status /action/deleteSpeaker '{"name":"Nobody Enrolled"}')"
    [ "$status" = 409 ] \
        || _ug_fail "$label: a write to the unreadable DB answered $status, expected 409 (set aside and replaced)"
    _ug_single "$label" "$_UG_DATA_DIR" 'speakers.json.corrupt-*'
    corrupt="$_UG_FOUND"
    cmp -s "$_UG_LANE_DIR/speakers.seed" "$corrupt" \
        || _ug_fail "$label: the quarantined file is not the original bytes"
    [ "$(stat -f '%Lp' "$corrupt")" = 600 ] \
        || _ug_fail "$label: the quarantined file is not owner-only ($(stat -f '%Lp' "$corrupt"))"
    jq -e '. == []' "$_UG_DATA_DIR/speakers.json" >/dev/null 2>&1 \
        || _ug_fail "$label: the replacement speakers.json is not an empty DB"
    snap="$(state_query .)" || _ug_fail "$(state_why $? "$label: whether the user was told the profiles were set aside")"
    jq -e --arg f "$(basename "$corrupt")" '.speakerDB.count == 0
        and any(.notifications[]; .title == "Voice profiles could not be read" and (.body | contains($f)))' \
        <<<"$snap" >/dev/null \
        || _ug_fail "$label: the user was not told the profiles were set aside as $(basename "$corrupt")"
    assert_app_alive
    log "$label: quarantined unchanged as $(basename "$corrupt"), DB empty, user notified"
}

_ug_assert_finished_record() {
    local label="[upgrade:finished-record]" body
    body="$(rpc "/v1/jobs/$_UG_FINISHED_ID")"
    jq -e --arg t "$_UG_FINISHED_TITLE" --arg p "$_UG_FINISHED_TRANSCRIPT" \
        '.state == "done" and .meetingTitle == $t and .transcriptPath == $p
         and .echo.windowsScored == 12 and .echo.cancellationSeconds == null' <<<"$body" >/dev/null 2>&1 \
        || _ug_fail "$label: GET /v1/jobs/$_UG_FINISHED_ID does not serve the v0.8.1 record: ${body:-<no answer>}"
    log "$label: v0.8.1 record still served"
}

# POST /v1/jobs for one file; the one job id it created is left in _UG_JOB_ID
# (a global for the reason given at `_ug_single`).
_UG_JOB_ID=""
_ug_enqueue() {
    local enq
    enq="$(rpc_post /v1/jobs "$(jq -nc --arg p "$1" '{paths: [$p]}')")"
    _UG_JOB_ID="$(jq -er 'select(.jobIDs | length == 1) | .jobIDs[0]' <<<"$enq" 2>/dev/null || true)"
    [ -n "$_UG_JOB_ID" ] || _ug_fail "[upgrade]: POST /v1/jobs did not create exactly one job: $enq"
}

_UG_STATUS=""
_ug_job_terminal() {
    assert_app_alive
    _UG_STATUS="$(rpc "/v1/jobs/$1")"
    jq -e '.state == "done" or .state == "error"' <<<"$_UG_STATUS" >/dev/null 2>&1
}
# Waits for a job to finish and requires done; leaves its status in _UG_STATUS.
_ug_await_done() {
    local label="$1" what="$2" id="$3"
    poll_until "$PIPELINE_TIMEOUT_S" 2 _ug_job_terminal "$id" \
        || _ug_fail "$label: $what ($id) did not finish within ${PIPELINE_TIMEOUT_S}s (last: ${_UG_STATUS:-<no answer>})"
    jq -e '.state == "done"' <<<"$_UG_STATUS" >/dev/null \
        || _ug_fail "$label: $what ($id) ended in error: $(jq -r '.error // "?"' <<<"$_UG_STATUS")"
}

# The finished-job records, which every job that reaches a terminal state adds
# to: a recovered duplicate of the restored recording would show up here.
_ug_assert_records() {
    local label="$1" expected="$2"
    local records="$_UG_IPC_DIR/terminal_jobs.json"
    jq -e --argjson n "$expected" 'length == $n' "$records" >/dev/null 2>&1 \
        || _ug_fail "$label: expected $expected finished-job records, found: $(jq -c '[.[] | {jobID, meetingTitle, state}]' "$records" 2>/dev/null)"
    jq -e 'all(.[]; .meetingTitle | startswith("Recovered Recording") | not)' "$records" >/dev/null \
        || _ug_fail "$label: the seeded recording was picked up a second time as an orphan: $(jq -c '[.[] | .meetingTitle]' "$records")"
}

_ug_assert_restored_job() {
    local label="[upgrade:restored-job]" trigger transcript relocated base
    _ug_enqueue "$_UG_TRIGGER_FIXTURE"
    trigger="$_UG_JOB_ID"
    log "$label: imported the fixture as job $trigger, which builds the queue and reads the snapshot"
    _ug_await_done "$label" "the interrupted v0.8.1 job" "$_UG_PENDING_ID"
    transcript="$(jq -r '.transcriptPath // empty' <<<"$_UG_STATUS")"
    upgrade_path_inside "$transcript" "$OUTPUT_DIR" && [ -s "$transcript" ] \
        || _ug_fail "$label: the restored job's transcript '$transcript' is not a file under $OUTPUT_DIR"
    transcript_is_german "$transcript" \
        || _ug_fail "$label: the restored job's transcript is not German (matched: ${GERMAN_MARKER_HITS:-none})"
    [ ! -e "$_UG_SEEDED_MIX" ] \
        || _ug_fail "$label: the recording is still in staging after its job finished"
    _ug_single "$label" "$RECORDINGS_DIR" '*_mix.wav'
    relocated="$_UG_FOUND"
    base="$(basename "$relocated")"
    jq -e --arg b "/MeetingTranscriber/recordings/$base" 'any(.[]; endswith($b))' \
        "$_UG_IPC_DIR/processed_recordings.json" >/dev/null \
        || _ug_fail "$label: the processed-recordings ledger does not name the moved recording $base: $(cat "$_UG_IPC_DIR/processed_recordings.json")"
    _ug_await_done "$label" "the import" "$trigger"
    _ug_assert_records "$label" 3
    _UG_RELOCATED_MIX="$relocated"
    log "$label: restored, done, transcript in the output folder, recording moved to $RECORDINGS_DIR and into the ledger, no duplicate"
}

# Quit, start again on the same home, and require that nothing is migrated or
# run a second time.
_ug_relaunch_and_assert() {
    local label="[upgrade:relaunch]" new_repo="$_UG_APP_HF/$UPGRADE_WHISPERKIT_REPO" trigger
    upgrade_tree_fingerprint "$new_repo/$_UG_VARIANT" >"$_UG_LANE_DIR/variant.before-relaunch"
    local quit_status=0
    quit_running_app || quit_status=$?
    case "$quit_status" in
        1) _ug_fail "$label: could not quit the app" ;;
        2) _ug_fail "$label: the app had to be ended by signal, without its own quit (see the Automation error above), so the relaunch would not test what a quit leaves" ;;
    esac
    _ug_launch
    poll_until "$RPC_READY_TIMEOUT_S" 1 _rpc_ready || _ug_fail "$label: RPC did not come back after the relaunch"
    _record_launched_app
    _ug_await_model "$label"
    _ug_expect_fingerprint "$label" "$_UG_VARIANT in the app's folder (the second launch must not move or rewrite it)" \
        "$new_repo/$_UG_VARIANT" "$_UG_LANE_DIR/variant.before-relaunch"
    [ ! -e "$_UG_DOCS_HF/$UPGRADE_WHISPERKIT_REPO/$_UG_VARIANT" ] \
        || _ug_fail "$label: $_UG_VARIANT reappeared in Documents/huggingface"
    _ug_enqueue "$_UG_TRIGGER_FIXTURE"
    trigger="$_UG_JOB_ID"
    _ug_await_done "$label" "the second import" "$trigger"
    _ug_assert_records "$label" 4
    jq -e '.state == "done"' <<<"$(rpc "/v1/jobs/$_UG_PENDING_ID")" >/dev/null \
        || _ug_fail "$label: the restored job no longer reads as done"
    [ -f "$_UG_RELOCATED_MIX" ] \
        || _ug_fail "$label: the moved recording $_UG_RELOCATED_MIX is gone"
    log "$label: no second migration, no second run of the restored job"
}

_ug_assert_isolation() {
    local label="[upgrade:isolation]"
    _ug_expect_fingerprint "$label" "$_UG_VARIANT and its tokenizer in the account's real model folders" \
        "" "$_UG_LANE_DIR/real-models.before" _ug_real_fingerprint
    log "$label: $_UG_VARIANT and its tokenizer in the account's real model folders are as they were"
}

run_upgrade() {
    _ug_assert_settings
    _ug_assert_model
    _ug_assert_speakers
    _ug_assert_finished_record
    _ug_assert_restored_job
    _ug_relaunch_and_assert
    _ug_assert_isolation
}

# --- echo-bleed lane ------------------------------------------------------
#
# A dual-source recording made on loudspeakers carries the remote voices on the
# microphone track too, so the same speech is transcribed twice and lands in the
# transcript twice. The pipeline measures that before transcription and reports
# the verdict on GET /v1/jobs/<id>. This lane drives that chain in the deployed
# app: synthesise a pair, enqueue it, read the verdict back.
#
# It cannot record the condition live. The runner is a Mac mini with no
# microphone, only a virtual input device, so there is no acoustic path for a
# loudspeaker to bleed through. The synthesised pair is the better instrument
# anyway: it makes the expected verdict exact instead of a property of the room.
#
# TWO pairs are enqueued, differing by exactly one term. Without the clean
# control the lane would stay green against a detector that answers yes to
# everything, which is the failure mode that actually matters here — a false
# positive tells the user their recording is broken when it is not.
#
# No settings are touched. The verdict does not depend on any of them, so a lane
# that mutates the runner's defaults would add a restore path and a way to leave
# the host dirty for nothing.
# The parts of the two echo lanes' fixture setup that are the same lane to lane:
# where the generator and its two source recordings live, and a fresh directory
# to put the output in. What the generator is ASKED for stays at each lane's own
# call site, because that is the one thing they differ in and hiding it behind a
# passthrough would cost more than the two lines it saves.
#
# Shared rather than copied for a reason this change learned the hard way: the
# two functions held these lines verbatim, and an edit anchored on text that
# appears in both landed in the wrong one and broke a lane that had been green
# for weeks.
# Separate directories per pair. The resolver groups on directory AND stem, so
# this keeps the two pairs apart no matter what stem names are chosen.
_echo_fixture_setup() {
    local label="$1"
    _ECHO_GENERATOR="$ROOT/scripts/fixtures/make-echo-pair.py"
    _ECHO_APP_SOURCE="$ROOT/app/MeetingTranscriber/Tests/Fixtures/two_speakers_de.wav"
    _ECHO_LOCAL_SOURCE="$ROOT/app/MeetingTranscriber/Tests/Fixtures/three_speakers_de.wav"
    [ -f "$_ECHO_GENERATOR" ]    || fail "$label: fixture generator missing: $_ECHO_GENERATOR"
    [ -f "$_ECHO_APP_SOURCE" ]   || fail "$label: fixture missing: $_ECHO_APP_SOURCE"
    [ -f "$_ECHO_LOCAL_SOURCE" ] || fail "$label: fixture missing: $_ECHO_LOCAL_SOURCE"

    _ECHO_FIXTURE_DIR="$(mktemp -d /tmp/e2e-echo.XXXXXX)"
    _ECHO_AFFECTED_DIR="$_ECHO_FIXTURE_DIR/affected"
    _ECHO_CLEAN_DIR="$_ECHO_FIXTURE_DIR/clean"
    log "$label: synthesising pairs under $_ECHO_FIXTURE_DIR"
}

# Enqueue one synthesised pair; echoes its job id. Asserts the two files came
# back as ONE job: PairedRecordingResolver has to recognise the _app/_mic stem
# pair, and if it does not the pipeline silently runs two single-source jobs
# that can never be compared against each other, so nothing is ever measured.
_echo_enqueue() {
    local label="$1" dir="$2" stem="$3"
    local enq ids
    enq="$(rpc_post /v1/jobs "$(jq -nc --arg a "$dir/${stem}_app.wav" --arg m "$dir/${stem}_mic.wav" '{paths: [$a, $m]}')")"
    ids="$(jq -r '.jobIDs | length' <<<"$enq" 2>/dev/null || echo 0)"
    [ "$ids" = "1" ] \
        || fail "$label: POST /v1/jobs returned $ids job(s) for one _app/_mic pair, expected 1 (response: $enq)"
    jq -r '.jobIDs[0]' <<<"$enq"
}

# True once the job carries a verdict, or has settled without one. Settling
# without one is a failure, but it has to be READ as one: polling only for the
# verdict would turn a job that errored in its first second into a timeout, and
# report a two-minute wait instead of the error that caused it.
_echo_settled() {
    assert_app_alive
    # Writes the caller's `_ECHO_STATUS`: bash locals are dynamically scoped, so
    # the lane declares it and this stashes the last response for the
    # post-loop assertions. Same shape the naming lanes use.
    _ECHO_STATUS="$(rpc "/v1/jobs/$1")"
    jq -e '.echo != null or .state == "done" or .state == "error"' <<<"$_ECHO_STATUS" >/dev/null 2>&1
}

# Waits for the verdict on $1 and leaves it in $_ECHO_STATUS.
_echo_await_verdict() {
    local label="$1" job="$2"
    _ECHO_STATUS=""
    poll_until "$PIPELINE_TIMEOUT_S" 3 _echo_settled "$job" \
        || fail "$label: job $job produced neither an echo verdict nor a terminal state within ${PIPELINE_TIMEOUT_S}s (last: $_ECHO_STATUS)"
    jq -e '.echo != null' <<<"$_ECHO_STATUS" >/dev/null \
        || fail "$label: job $job reached state=$(jq -r '.state // "?"' <<<"$_ECHO_STATUS") with NO echo verdict. Every dual-source job is measured, so a missing verdict means the tracks never reached the detector. error=$(jq -r '.error // "<none>"' <<<"$_ECHO_STATUS")"
    log "$label: verdict $(jq -c '.echo' <<<"$_ECHO_STATUS")"
}

# Let a job finish rather than leaving it parked at speaker naming. Diarization
# is on by default, so an enqueued job parks there and would otherwise outlive
# the lane in the persisted job store, where a later run reads it as its own.
# Best effort: this is teardown, and a job that will not settle is not this
# lane's failure to report.
_echo_settled_or_skipped() {
    local state
    state="$(rpc "/v1/jobs/$1" | jq -r '.state // empty')"
    case "$state" in
        done|error) return 0 ;;
        speakerNamingPending)
            # Same call the naming-escape lane makes; the explicit zero
            # Content-Length matters for a POST with no body.
            curl --silent --show-error --max-time 10 -X POST \
                --header "Authorization: Bearer $RPC_TOKEN" \
                --header "Content-Length: 0" \
                "$RPC_BASE/v1/jobs/$1/naming/skip" >/dev/null 2>&1 || true
            ;;
    esac
    return 1
}
_echo_release() {
    poll_until "$PIPELINE_TIMEOUT_S" 2 _echo_settled_or_skipped "$1" || true
}

# Fetches a finished job and requires it to have settled as done. Both echo
# lanes read two jobs back after releasing them, and all four reads want the
# same sentence when a job errored instead. Leaves the response in
# `_ECHO_STATUS`, the same dynamic-scoping idiom the polling helpers use,
# because `fail` is an `exit` and an exit inside a command substitution leaves
# only the subshell.
_echo_read_done() {
    local label="$1" which="$2" job="$3" state
    _ECHO_STATUS="$(rpc "/v1/jobs/$job")"
    state="$(jq -r '.state // empty' <<<"$_ECHO_STATUS")"
    [ "$state" = "done" ] \
        || fail "$label: $which settled as '$state', expected done. error=$(jq -r '.error // "<none>"' <<<"$_ECHO_STATUS")"
}

# Asserts a verdict was computed over enough windows to mean anything. Shared
# by both pairs: on the affected one it guards against a verdict resting on a
# single lucky window, and on the control it is what stops "not affected" from
# meaning "not enough evidence to say".
_echo_assert_scored() {
    local label="$1" which="$2" status="$3"
    jq -e '.echo.windowsScored >= 3' <<<"$status" >/dev/null \
        || fail "$label: $which scored only $(jq -r '.echo.windowsScored' <<<"$status") window(s); a verdict needs at least 3"
}

run_echo_bleed() {
    local label="[echo-bleed]"
    # Stashed by _echo_settled through bash's dynamic scoping (see there).
    local _ECHO_STATUS=""
    require_command python3


    _echo_fixture_setup "$label"
    local affected_dir="$_ECHO_AFFECTED_DIR" clean_dir="$_ECHO_CLEAN_DIR"
    python3 "$_ECHO_GENERATOR" --app "$_ECHO_APP_SOURCE" --local "$_ECHO_LOCAL_SOURCE" --out "$affected_dir" --stem meeting --bleed 1.0 \
        | sed 's/^/    /' || fail "$label: could not synthesise the affected pair"
    python3 "$_ECHO_GENERATOR" --app "$_ECHO_APP_SOURCE" --local "$_ECHO_LOCAL_SOURCE" --out "$clean_dir" --stem meeting --bleed 0 \
        | sed 's/^/    /' || fail "$label: could not synthesise the clean control"

    # --- affected pair ----------------------------------------------------
    local affected_job
    affected_job="$(_echo_enqueue "$label" "$affected_dir" meeting)"
    log "$label: affected pair enqueued as $affected_job"
    _echo_await_verdict "$label" "$affected_job"
    local affected_status="$_ECHO_STATUS"

    jq -e '.echo.detected == true' <<<"$affected_status" >/dev/null \
        || fail "$label: affected pair NOT detected. The microphone track is the app track delayed 15 ms at unit gain, which is the condition itself: $(jq -c '.echo' <<<"$affected_status")"
    # Measured 4 of 4 windows on this fixture. Asserting a floor well under that
    # keeps the lane from re-litigating the threshold, while still failing if the
    # verdict decays to a single lucky window.
    _echo_assert_scored "$label" "affected pair" "$affected_status"
    jq -e '.echo.affectedWindowShare >= 0.5' <<<"$affected_status" >/dev/null \
        || fail "$label: affected share $(jq -r '.echo.affectedWindowShare' <<<"$affected_status") below 0.5 (measured 1.0 on this fixture)"
    # The structured verdict and the sentence the user actually sees are separate
    # channels, and only one of them is in front of the person with the problem.
    jq -e '(.warnings | length) >= 1' <<<"$affected_status" >/dev/null \
        || fail "$label: affected job carries the verdict but no warning — the menu-bar channel is silent on a recording the API calls affected"
    log "$label: affected pair detected, share $(jq -r '.echo.affectedWindowShare' <<<"$affected_status") over $(jq -r '.echo.windowsScored' <<<"$affected_status") windows ✅"

    # --- clean control ----------------------------------------------------
    local clean_job
    clean_job="$(_echo_enqueue "$label" "$clean_dir" meeting)"
    log "$label: clean control enqueued as $clean_job"
    _echo_await_verdict "$label" "$clean_job"
    local clean_status="$_ECHO_STATUS"

    jq -e '.echo.detected == false' <<<"$clean_status" >/dev/null \
        || fail "$label: clean control reported as affected. Its microphone track is the same gated local speech as the affected pair with the bleed term removed, so this is a false positive: $(jq -c '.echo' <<<"$clean_status")"
    _echo_assert_scored "$label" "clean control" "$clean_status"
    jq -e '.echo.windowsAffected == 0' <<<"$clean_status" >/dev/null \
        || fail "$label: clean control has $(jq -r '.echo.windowsAffected' <<<"$clean_status") affected window(s); measured 0, with its hottest window at 0.35 against a 0.7 threshold"
    log "$label: clean control measured over $(jq -r '.echo.windowsScored' <<<"$clean_status") windows and found nothing ✅"

    # --- the verdict has to survive the job finishing ---------------------
    # Finished jobs are reaped from the queue and read back out of the terminal
    # store. A verdict that only exists on the live job is invisible to exactly
    # the caller most likely to look: one polling after the fact.
    _echo_release "$affected_job"
    _echo_release "$clean_job"
    _echo_read_done "$label" "affected job" "$affected_job"
    local final="$_ECHO_STATUS"
    jq -e '.echo.detected == true' <<<"$final" >/dev/null \
        || fail "$label: the verdict did not survive the job finishing: $(jq -c '.echo' <<<"$final")"
    log "$label: verdict intact on the finished job ✅"

    # The dedup half, asserted here and not next to the verdict above: the
    # verdict is recorded BEFORE transcription, so at the moment it appears the
    # merge that suppresses anything has not run yet and the count is still 0.
    # Reading it there passed against a working build and would have passed
    # against a broken one too.
    #
    # On the count rather than on transcript text: what the engine makes of a
    # bleed copy is not stable enough to grep for, while "how many microphone
    # segments were left out" is exactly the effect, and it is the number a fleet
    # caller reads.
    jq -e '.echo.suppressedSegments >= 1' <<<"$final" >/dev/null \
        || fail "$label: affected pair had nothing suppressed. Its microphone track IS the app track, so every microphone segment is a duplicate: $(jq -c '.echo' <<<"$final")"
    log "$label: $(jq -r '.echo.suppressedSegments' <<<"$final") microphone segment(s) left out of the transcript ✅"

    # The control that stops this from being "drop the microphone track". Without
    # it the lane passes against a build that removes the user's own words from
    # every recording and still leaves a plausible transcript behind.
    # Read with the same required state as the affected job. Left as a bare
    # fetch this passed for a control that had errored: the assertion below
    # tolerates a missing count, so the check that stops the lane from being
    # "drop the microphone track" evaporated exactly when the control failed.
    _echo_read_done "$label" "clean control" "$clean_job"
    local clean_final="$_ECHO_STATUS"
    jq -e '(.echo.suppressedSegments // 0) == 0' <<<"$clean_final" >/dev/null \
        || fail "$label: clean control had $(jq -r '.echo.suppressedSegments' <<<"$clean_final") segment(s) removed. Nothing may be dropped from a recording without bleed: $(jq -c '.echo' <<<"$clean_final")"
    log "$label: clean control kept every microphone segment ✅"

    # The acceptance criterion, stated as plainly as a driver can state it: the
    # transcript still has to say something. Removing duplicates and removing the
    # meeting look identical in every count asserted above, and this pair carries
    # a local speaker the far end never played.
    local transcript
    transcript="$(jq -r '.transcriptPath // empty' <<<"$final")"
    [ -n "$transcript" ] && [ -f "$transcript" ] \
        || fail "$label: finished job has no transcript on disk (transcriptPath=$transcript)"
    local lines
    # awk rather than `wc -l`: saveTranscript writes no trailing newline, so wc
    # misses the final line and this floor would silently demand three.
    lines="$(awk 'END { print NR }' "$transcript")"
    [ "${lines:-0}" -ge 2 ] \
        || fail "$label: transcript is down to $lines line(s) after dedup — the local speaker has to survive the far end, not be removed with it"
    log "$label: transcript still carries $lines lines after dedup ✅"
    log "$label: PASS"
}

# --- echo-cancellation lane -------------------------------------------------
#
# The other half of --echo-bleed. That lane proves the far end is left out of
# the TRANSCRIPT after the fact; this one proves it is taken out of the
# microphone AUDIO before anything reads it, which is what also keeps it out of
# the mic track's diarization and out of the speaker embeddings taken from it.
#
# Its pairs differ from that lane's in one term: the far end pauses. That is not
# a convenience. The canceller's self-check is a DIFFERENCE between the windows
# where the far end was playing and the windows where it was not, so a fixture
# whose far end never stops offers no control group and the shipped check
# refuses to confirm the run — measured on the other lane's pair, which splits
# 42 windows to 8 against a floor of 10 on each side and comes back unjudgeable
# however well the run went. Gated 2.5 s on / 2.5 s off it splits 25 to 25.
#
# The dedup stays ON for this lane, deliberately. Both remedies asked for at
# once is the configuration where precedence is a decision rather than a
# formality, and zero suppressed segments on a pair the other lane strips four
# from is what proves cancellation took it.

# Asserts the deployed bundle carries the model before anything is enqueued.
# Without it the stage reports "the model is missing" and leaves the track as
# recorded, which is correct behaviour and a failure of this lane, but one that
# reads as a broken canceller unless it is named here.
#
# The pattern comes from the library that installs it, so the convention has one
# owner; the concrete filename is nobody's business here, which is what keeps a
# model bump to a single edit.
#
# NOT the app's own `--localvqe-selftest`, which would be the deeper check: it
# goes through the production resolver and would also catch a model that is
# present and does not load. Tried, and it hangs in exactly the situation this
# precondition exists for. A bundle old enough to lack the model is usually old
# enough to lack the flag, and an unrecognised argument does not fail, it starts
# the menu-bar app, which never exits. Measured against a deployed bundle from a
# fortnight earlier: no output, no exit, killed after two minutes. A precondition
# that can hold the runner for a whole step budget is worse than one that
# under-checks, and the case it would add is caught by the lane's own assertion,
# where the job's warnings name it.
_echo_require_model() {
    local label="$1" resources="$DEV_BUNDLE_DEPLOY/Contents/Resources" found
    # The override wins outright in LocalVQEModel.resolve and does NOT fall back
    # to the bundle, so one naming a file that is gone yields no canceller at
    # all. That is the state a measurement session leaves behind, and the bundle
    # below would still look fine.
    local override="${MEETINGTRANSCRIBER_LOCALVQE_MODEL:-}"
    if [ -n "$override" ]; then
        [ -f "$override" ] \
            || fail "$label: MEETINGTRANSCRIBER_LOCALVQE_MODEL points at $override, which does not exist. The override takes precedence over the bundled model and does not fall back to it, so cancellation could only decline. Unset it or point it at a model."
        log "$label: using the model override at $override"
        return 0
    fi
    # `-print -quit` rather than piping into `grep -q`: grep closing the pipe on
    # its first match sends find a SIGPIPE, and under `set -o pipefail` that
    # makes the whole pipeline fail on exactly the runs where the model IS
    # there. The check would have reported every bundle as missing it.
    found="$(find "$resources" -maxdepth 1 -name "$LOCALVQE_RESOURCE_GLOB" -type f -print -quit 2>/dev/null)"
    [ -n "$found" ] \
        || fail "$label: no $LOCALVQE_RESOURCE_GLOB in $resources. The build installs it (scripts/lib/localvqe-resources.sh); a --no-build run against an older bundle will not have it, and the lane would fail as a canceller that removed nothing."
}

# Counts transcript lines spoken into the microphone.
#
# awk rather than `wc -l` for the same reason the whole-file count used it:
# saveTranscript writes no trailing newline, so wc misses the final line.
_echo_mic_lines() {
    awk '/^\[[0-9:]+\] (M_|Me:)/ { n++ } END { print n + 0 }' "$1"
}

# Prints "true", "false", "absent" or "no-verdict" for a job's cancellation
# outcome. The last one is its own answer: a record that lost its whole echo
# object is a persistence problem, and reporting it as "absent" would send the
# reader to the cancellation stage instead.
#
# A helper rather than `.echo.removed // "absent"`, which is how this was first
# written and is wrong in the one case the message exists to explain: jq's `//`
# takes the alternative for false as well as for null, so a run that was
# attempted and declined printed as one that was never attempted — inverting the
# distinction in the sentence drawing it.
_echo_removed_state() {
    jq -r 'if .echo == null then "no-verdict"
           elif .echo | has("removed") then (.echo.removed | tostring)
           else "absent" end' <<<"$1"
}

run_echo_cancel() {
    local label="[echo-cancel]"
    # Stashed by _echo_settled through bash's dynamic scoping (see there).
    local _ECHO_STATUS=""
    require_command python3
    _echo_require_model "$label"


    _echo_fixture_setup "$label"
    local affected_dir="$_ECHO_AFFECTED_DIR" clean_dir="$_ECHO_CLEAN_DIR"
    python3 "$_ECHO_GENERATOR" --app "$_ECHO_APP_SOURCE" --local "$_ECHO_LOCAL_SOURCE" --out "$affected_dir" --stem meeting \
        --bleed 1.0 --app-burst 2.5 --app-gap 2.5 \
        | sed 's/^/    /' || fail "$label: could not synthesise the affected pair"
    python3 "$_ECHO_GENERATOR" --app "$_ECHO_APP_SOURCE" --local "$_ECHO_LOCAL_SOURCE" --out "$clean_dir" --stem meeting \
        --bleed 0 --app-burst 2.5 --app-gap 2.5 \
        | sed 's/^/    /' || fail "$label: could not synthesise the clean control"

    # --- affected pair ----------------------------------------------------
    local affected_job
    affected_job="$(_echo_enqueue "$label" "$affected_dir" meeting)"
    log "$label: affected pair enqueued as $affected_job"
    _echo_await_verdict "$label" "$affected_job"
    local affected_status="$_ECHO_STATUS"

    # Cancellation only runs on a recording the detector called affected, so a
    # missed detection would make every assertion below vacuously unreachable
    # rather than false.
    jq -e '.echo.detected == true' <<<"$affected_status" >/dev/null \
        || fail "$label: affected pair NOT detected, so cancellation was never reached: $(jq -c '.echo' <<<"$affected_status")"
    _echo_assert_scored "$label" "affected pair" "$affected_status"
    # Logged and floored rather than left to `detected`, so the margin is
    # visible before it becomes a failure: the gated pair's per-window
    # correlations sit at 0.72 to 0.83 against a 0.7 bar, and the verdict needs
    # only two affected windows, so erosion would show up here as a falling
    # share long before the lane went red with "NOT detected".
    jq -e '.echo.affectedWindowShare >= 0.5' <<<"$affected_status" >/dev/null \
        || fail "$label: affected share $(jq -r '.echo.affectedWindowShare' <<<"$affected_status") below 0.5 (measured 1.0 on this fixture)"
    log "$label: detected over $(jq -r '.echo.windowsScored' <<<"$affected_status") windows, share $(jq -r '.echo.affectedWindowShare' <<<"$affected_status")"

    # --- clean control ----------------------------------------------------
    local clean_job
    clean_job="$(_echo_enqueue "$label" "$clean_dir" meeting)"
    log "$label: clean control enqueued as $clean_job"
    _echo_await_verdict "$label" "$clean_job"
    local clean_status="$_ECHO_STATUS"

    jq -e '.echo.detected == false' <<<"$clean_status" >/dev/null \
        || fail "$label: clean control reported as affected; its microphone track is the same local speech with the bleed term removed: $(jq -c '.echo' <<<"$clean_status")"
    _echo_assert_scored "$label" "clean control" "$clean_status"

    _echo_release "$affected_job"
    _echo_release "$clean_job"

    _echo_read_done "$label" "affected job" "$affected_job"
    local final="$_ECHO_STATUS"
    # The control is required to have finished too, and not just because it is a
    # job: every assertion below reads it as the measure the affected pair is
    # compared against, so a control that errored would be diagnosed as a
    # transcript missing from disk rather than as the run that failed.
    _echo_read_done "$label" "clean control" "$clean_job"
    local clean_final="$_ECHO_STATUS"

    # --- the assertion the lane exists for --------------------------------
    # Read off the FINISHED job rather than the live one: the flag is written
    # two stages before the job settles, and a driver polling after the fact
    # reads it out of the terminal store. Asserting it only where it is first
    # written would pass against a build that loses it on the way there.
    jq -e '.echo.removed == true' <<<"$final" >/dev/null \
        || fail "$label: the far end was NOT taken out of the microphone track (removed=$(_echo_removed_state "$final")). Absent means the stage never ran; false means it ran and its self-check would not confirm it — the warnings say which: $(jq -c '.warnings' <<<"$final")"
    log "$label: the far end was removed from the microphone audio ✅"

    # Precedence, with both switches on. The other lane strips four segments off
    # this same source audio, so zero here is the dedup standing down under
    # cancellation and not an absence of duplicates to find.
    jq -e '.echo.suppressedSegments == 0' <<<"$final" >/dev/null \
        || fail "$label: $(jq -r '.echo.suppressedSegments' <<<"$final") segment(s) were also dropped from the transcript. Under cancellation the dedup has to stand down: it judges how closely a microphone segment tracks the app track, which no longer means what it was calibrated to mean once the far end has been taken out of that microphone track."
    log "$label: the transcript dedup stood down ✅"

    # Nothing may be attempted on a recording with no echo. Absent, not false:
    # false would say the canceller ran here and could not be confirmed, which
    # is the population a field soak counts.
    # `has`, not `== null`: jq reads a field off a null as null, so asking
    # `.echo.removed == null` on a record that lost its whole echo object
    # answers yes. That is the one way this assertion could pass while the
    # thing it checks is gone.
    jq -e '.echo != null and (.echo | has("removed") | not)' <<<"$clean_final" >/dev/null \
        || fail "$label: the clean control carries removed=$(_echo_removed_state "$clean_final") (echo object: $(jq -c '.echo' <<<"$clean_final")); cancellation must not be attempted on a recording the detector called clean, and the verdict has to survive the job finishing"
    jq -e '(.echo.suppressedSegments // 0) == 0' <<<"$clean_final" >/dev/null \
        || fail "$label: clean control had $(jq -r '.echo.suppressedSegments' <<<"$clean_final") segment(s) removed. Nothing may be dropped from a recording without bleed."
    log "$label: the clean control was left alone ✅"

    # The acceptance criterion. Every assertion above is equally satisfied by a
    # canceller that emptied the microphone track: the far end would be gone,
    # nothing would be suppressed, and the transcript would still carry the app
    # track. What that would cost is the local speaker.
    #
    # MICROPHONE lines only, not the whole transcript, which is what this first
    # counted and why it could not fail. Most of the transcript comes from the
    # app track, which cancellation never touches: on this fixture the far end
    # speaks about 25 s and the local side about 8 s, so a run that wrote pure
    # silence to the microphone track still returns roughly three quarters of
    # the control's lines and sails past any halving floor.
    #
    # Matched by speaker prefix: dual-track diarization labels mic speakers
    # `M_<id>`, and a job whose mic diarization failed keeps the raw `Me`
    # instead. Both are accepted, because either is a microphone line and the
    # lane is not here to pin which of the two the run took.
    #
    # Known limit, and the reason the control's count is asserted separately
    # below: a speaker the stored database RECOGNISES is renamed to that entry
    # before the transcript is rendered, prefix and all, so a host whose
    # speakers.json has learned these fixture voices makes both counts zero. CI
    # restores that database around the lane that enrols from these fixtures, so
    # it does not arise there; a local run after enrolling can. It fails loudly
    # rather than quietly, and the message prints the speaker labels it did see.
    local transcript clean_transcript lines clean_lines
    transcript="$(jq -r '.transcriptPath // empty' <<<"$final")"
    clean_transcript="$(jq -r '.transcriptPath // empty' <<<"$clean_final")"
    # Checked here and not inside a helper: `fail` is an `exit`, and an exit
    # inside a command substitution leaves the subshell, not the script, so the
    # run would carry on with an empty count and report the wrong thing.
    [ -n "$transcript" ] && [ -f "$transcript" ] \
        || fail "$label: the finished affected job has no transcript on disk (transcriptPath=$transcript)"
    [ -n "$clean_transcript" ] && [ -f "$clean_transcript" ] \
        || fail "$label: the finished clean control has no transcript on disk (transcriptPath=$clean_transcript)"
    lines="$(_echo_mic_lines "$transcript")"
    clean_lines="$(_echo_mic_lines "$clean_transcript")"
    # The control has to carry the local speaker for this to mean anything. It
    # also fails loudly if the label convention above ever stops matching, which
    # is the one way this assertion could go quietly vacuous.
    [ "${clean_lines:-0}" -ge 2 ] \
        || fail "$label: the clean control transcript has only $clean_lines microphone line(s), so it cannot serve as the measure for the affected one. If the speakers below carry real names rather than an M_ prefix, this host's speaker database recognised the fixture voice and renamed it, which is a stale database and not a broken canceller. Speakers seen: $(sed -n 's/^\[[0-9:]*\] \([^:]*\):.*/\1/p' "$clean_transcript" | sort -u | tr '\n' ' ')"
    # Half, not parity: the two transcripts come from separate ASR passes over
    # audio that differs, and the yield moves. Half still fails the case this
    # guards, where the local speaker is removed along with the echo.
    [ "$((lines * 2))" -ge "$clean_lines" ] \
        || fail "$label: the affected transcript is down to $lines microphone lines against the control's $clean_lines. Cancellation took the local speaker with the far end."
    log "$label: $lines microphone lines against the control's $clean_lines ✅"
    log "$label: PASS"
}

# --- protocol lane ------------------------------------------------------------
#
# No other lane asserts that the protocol stage produces a protocol. The runner
# leaves the provider at its default, the Claude CLI, which is installed there
# but not logged in for the runner account, so every live lane logs "Protocol
# generation failed — transcript saved" and passes on the transcript alone. This
# lane points the OpenAI-compatible provider at a local stub (set up before the
# launch, see the PROTOCOL_LANE block there) and asserts both outcomes of the
# stage. It imports through POST /v1/jobs rather than recording: an import runs
# the same PipelineQueue stages, protocol generation included, and needs no
# audio device, so the lane takes seconds.
#
# Two jobs, the stub's answer switched between them through its mode file:
#   1. it answers: the one request it got is the expected one, the job is done
#      with no protocol warning, and protocolPath names a file in the output
#      folder holding exactly the reply followed by the transcript;
#   2. it answers HTTP 500: the job is still done, with the "transcript saved"
#      warning, no protocolPath and no protocol file beside the transcript.
# The second is what shows the first phase's checks tell the two outcomes apart.

_PP_STATUS=""
_PP_NEW_REQUESTS=""
_PP_TRANSCRIPT=""
_PP_PROTOCOL=""

_pp_request_count() {
    if [ -f "$_PP_DIR/requests.jsonl" ]; then wc -l <"$_PP_DIR/requests.jsonl" | tr -d ' '; else echo 0; fi
}

# Register a job's outputs for removal, in the on-disk record `_pp_repair`
# reads, so a killed run's files go too: its transcript and protocol and the
# per-stem sidecars SpeakerNamingStore keeps in recordings/ (its
# sidecarSuffixes and namingJSONSuffix, restated here by value). Only when the
# paths changed since the last tick; a duplicate is harmless.
_PP_REGISTERED=""
_pp_register_outputs() {
    local f stem suffix paths
    paths="$(jq -r '.transcriptPath, .protocolPath | select(. != null)' <<<"$_PP_STATUS" 2>/dev/null)"
    [ -n "$paths" ] && [ "$paths" != "$_PP_REGISTERED" ] || return 0
    _PP_REGISTERED="$paths"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        printf '%s\n' "$f" >>"$_PP_OUTPUTS_RECORD"
        if [ "${f%.txt}" != "$f" ]; then
            stem="$(basename "${f%.txt}")"
            for suffix in _16k.wav _app_16k.wav _mic_16k.wav _segments.json _naming.json; do
                printf '%s\n' "$RECORDINGS_DIR/$stem$suffix" >>"$_PP_OUTPUTS_RECORD"
            done
        fi
    done <<<"$paths"
}

# Writes `_PP_STATUS` (dynamic scoping, as the echo lanes' poll does), and
# registers the outputs on every tick, so a job that times out after saving its
# transcript still has it removed.
_pp_terminal() {
    assert_app_alive
    _PP_STATUS="$(rpc "/v1/jobs/$1")"
    _pp_register_outputs
    jq -e '.state == "done" or .state == "error"' <<<"$_PP_STATUS" >/dev/null 2>&1
}

# Import one fixture copy and wait for the job to settle. Leaves the final
# GET /v1/jobs/<id> body in `_PP_STATUS` and the stub's log lines for this job
# in `_PP_NEW_REQUESTS` (its outputs are registered for removal while it is
# polled). Also leaves the job's two paths in `_PP_TRANSCRIPT` and
# `_PP_PROTOCOL` (empty when null).
_pp_run_job() {
    local label="$1" fixture="$2" before enq job
    before="$(_pp_request_count)"
    enq="$(rpc_post /v1/jobs "$(jq -nc --arg p "$fixture" '{paths: [$p]}')")"
    job="$(jq -er 'select(.jobIDs | length == 1) | .jobIDs[0]' <<<"$enq" 2>/dev/null || true)"
    [ -n "$job" ] || fail "$label: POST /v1/jobs did not create exactly one job (response: $enq)"
    log "$label: enqueued job $job"
    printf '%s\n' "$job" >>"$_PP_JOBS_RECORD"
    _PP_STATUS=""
    poll_until "$PIPELINE_TIMEOUT_S" 2 _pp_terminal "$job" \
        || fail "$label: job $job did not settle within ${PIPELINE_TIMEOUT_S}s (last: $_PP_STATUS)"
    _PP_NEW_REQUESTS="$(tail -n +"$(( before + 1 ))" "$_PP_DIR/requests.jsonl" 2>/dev/null || true)"
    _PP_TRANSCRIPT="$(jq -r '.transcriptPath // empty' <<<"$_PP_STATUS")"
    _PP_PROTOCOL="$(jq -r '.protocolPath // empty' <<<"$_PP_STATUS")"
    log "$label: job settled: $(jq -c '{state, warnings, transcriptPath, protocolPath, error}' <<<"$_PP_STATUS")"
    [ "$(jq -r '.state' <<<"$_PP_STATUS")" = "done" ] \
        || fail "$label: job $job settled as '$(jq -r '.state' <<<"$_PP_STATUS")', expected done. error=$(jq -r '.error // "<none>"' <<<"$_PP_STATUS")"
}

# Exactly one request per job: the generator retries only on a 400 that names
# max_completion_tokens, so a second request would mean something else asked.
_pp_assert_one_request() {
    local label="$1" n
    n="$(grep -c . <<<"$_PP_NEW_REQUESTS" || true)"
    [ "$n" = 1 ] || fail "$label: the stub got $n request(s) for this job, expected exactly 1: $(jq -c 'del(.body)' <<<"$_PP_NEW_REQUESTS" 2>/dev/null)"
}

run_protocol_lane() {
    local label="[protocol]"
    local fixture="$ROOT/app/MeetingTranscriber/Tests/Fixtures/two_speakers_en.wav"
    [ -f "$fixture" ] || fail "$label: fixture missing: $fixture"

    # The running app's own resolved view: a write that missed its domain would
    # otherwise send the lane's jobs to the host's real provider.
    local snap
    snap="$(state_query .)" || fail "$(state_why $? "$label: whether the app resolved the lane's settings")"
    jq -e --arg ep "$_PP_ENDPOINT" --arg model "$_PP_MODEL" --arg lang "$_PP_LANGUAGE" \
        --argjson temp "$_PP_TEMPERATURE" '
        .settings.protocolGeneration as $p | .settings.output as $o
        | $p.provider == "openAICompatible" and $p.openAIEndpoint == $ep and $p.openAIModel == $model
          and $p.language == $lang and $p.openAITemperature == $temp and $p.openAITopP == null
          and .settings.diarization.diarize == false
          and $o.saveRawTranscriptSeparately == true and $o.includeFullTranscriptInProtocol == true
          and $o.useAITitleForFilenames == false' \
        <<<"$snap" >/dev/null \
        || fail "$label: the app did not resolve the lane's settings: $(jq -c '{protocol: .settings.protocolGeneration, diarize: .settings.diarization.diarize, output: (.settings.output | {saveRawTranscriptSeparately, includeFullTranscriptInProtocol, useAITitleForFilenames})}' <<<"$snap")"
    # A custom prompt need not mention the language, so only the built-in one
    # is held to naming it; the placeholder check applies either way.
    local language_in_prompt=true
    if [ "$(jq -r '.settings.output.hasCustomPrompt' <<<"$snap")" = "true" ]; then
        language_in_prompt=false
        log "$label: a custom protocol prompt is installed; not requiring it to name the language"
    fi
    log "$label: app resolved provider=openAICompatible endpoint=$_PP_ENDPOINT model=$_PP_MODEL language=$_PP_LANGUAGE"

    # Copies, one per job, so neither job shares a path with the other or with
    # the shared fixture (same reasoning as the naming-confirm lane).
    cp "$fixture" "$_PP_DIR/protocol-ok.wav"
    cp "$fixture" "$_PP_DIR/protocol-500.wav"

    # Nothing but this lane's jobs may reach the stub: a job the launch resumed
    # or recovered has either already called it or is about to.
    # Read fresh and twice in a row, since recovery enqueues off the main actor
    # a beat after launch.
    # "In a row" must not span a stretch the app did not answer: a job could be
    # enqueued and finish inside it. The predicate runs only on answered ticks,
    # so the gap is seen from the --each hook, which runs before every read: a
    # previous tick that never reached the predicate resets the count. The
    # verdict, including the deadline retry, is poll_state's.
    local busy="" idle_reads=0 prev_answered=1 idle_rc=0
    _pp_gap_resets_idle() {
        assert_app_alive
        [ "$prev_answered" -eq 1 ] || idle_reads=0
        prev_answered=0
    }
    _pp_idle_twice() {
        prev_answered=1
        busy="$(jq -r '(.pipeline.activeJobCount // 0) + (.pipeline.pendingNamingJobCount // 0) + (.pipeline.waitingJobCount // 0)' <<<"$STATE_BODY" 2>/dev/null)"
        if [ "$busy" = 0 ] && [ "$(_pp_request_count)" = 0 ]; then idle_reads=$(( idle_reads + 1 )); else idle_reads=0; fi
        [ "$idle_reads" -ge 2 ]
    }
    poll_state --each _pp_gap_resets_idle 20 1 _pp_idle_twice || idle_rc=$?
    [ "$idle_rc" -eq 0 ] \
        || fail "$(state_why "$idle_rc" "$label: the app is not idle before the lane's first job (pipeline jobs: ${busy:-?}, stub requests so far: $(_pp_request_count)); a job the launch resumed or recovered would be sent to the stub")"

    # --- 1. the stub answers --------------------------------------------------
    printf 'ok' >"$_PP_DIR/mode"
    _pp_run_job "$label [ok]" "$_PP_DIR/protocol-ok.wav"
    local transcript="$_PP_TRANSCRIPT" protocol="$_PP_PROTOCOL" warned problems
    warned="$(jq -r '.warnings[]? | select(test("protocol"; "i"))' <<<"$_PP_STATUS")"
    [ -z "$warned" ] || fail "$label [ok]: the job carries a protocol warning: $warned"
    [ -n "$transcript" ] && [ -f "$transcript" ] \
        || fail "$label [ok]: no transcript file (transcriptPath='$transcript'), so the user message cannot be checked"
    _pp_assert_one_request "$label [ok]"
    problems="$(openai_stub_request_violations "$_PP_NEW_REQUESTS" "$(jq -nc --rawfile t "$transcript" \
        --arg model "$_PP_MODEL" --arg lang "$_PP_LANGUAGE" --argjson temp "$_PP_TEMPERATURE" \
        --argjson lip "$language_in_prompt" \
        '{path: "/v1/chat/completions", model: $model, language: $lang, transcript: $t,
          temperature: $temp, topP: null, languageInPrompt: $lip}')")" \
        || fail "$label [ok]: could not check the stub's request: $(jq -c 'del(.body)' <<<"$_PP_NEW_REQUESTS" 2>/dev/null)"
    [ -z "$problems" ] || fail "$label [ok]: the chat-completions request is not the expected one:"$'\n'"$problems"
    log "$label [ok]: the request carried the model, the sampling override, the language and the transcript ✅"
    [ -n "$protocol" ] || fail "$label [ok]: protocolPath is null although the stub answered"
    [ "$(dirname "$protocol")" = "$OUTPUT_DIR/protocols" ] && [ "${protocol%.md}" != "$protocol" ] \
        || fail "$label [ok]: protocolPath '$protocol' is not a .md file in $OUTPUT_DIR/protocols"
    [ -f "$protocol" ] || fail "$label [ok]: protocolPath names a file that does not exist: $protocol"
    # What generateProtocol saves with includeFullTranscriptInProtocol on: the
    # reply, a rule, and the transcript the request carried.
    { printf '%s' "$_PP_REPLY"; printf '\n\n---\n\n## Full Transcript\n\n'; cat "$transcript"; } >"$_PP_DIR/expected.md"
    cmp -s "$_PP_DIR/expected.md" "$protocol" \
        || fail "$label [ok]: the protocol file is not the stub's reply followed by the transcript. diff:"$'\n'"$(diff "$_PP_DIR/expected.md" "$protocol" | head -20)"
    log "$label [ok]: $protocol holds the stub's reply and the transcript ✅"

    # --- 2. the stub fails ----------------------------------------------------
    printf 'http500' >"$_PP_DIR/mode"
    _pp_run_job "$label [500]" "$_PP_DIR/protocol-500.wav"
    transcript="$_PP_TRANSCRIPT" protocol="$_PP_PROTOCOL"
    _pp_assert_one_request "$label [500]"
    # That the stub really served this job a 500, so the warning below is the
    # app's answer to a failed call and not to something else going wrong.
    [ "$(jq -r '"\(.mode)/\(.status)"' <<<"$_PP_NEW_REQUESTS")" = "http500/500" ] \
        || fail "$label [500]: the stub did not answer this job's request with a 500: $(jq -c 'del(.body)' <<<"$_PP_NEW_REQUESTS")"
    jq -e 'any(.warnings[]?; . == "Protocol generation failed — transcript saved")' <<<"$_PP_STATUS" >/dev/null \
        || fail "$label [500]: the job lacks the 'Protocol generation failed — transcript saved' warning: $(jq -c '.warnings' <<<"$_PP_STATUS")"
    [ -z "$protocol" ] || fail "$label [500]: protocolPath is '$protocol' although the stub answered 500"
    [ -n "$transcript" ] && [ -f "$transcript" ] \
        || fail "$label [500]: the transcript was not kept (transcriptPath='$transcript')"
    [ ! -e "${transcript%.txt}.md" ] || fail "$label [500]: a protocol file exists beside the transcript: ${transcript%.txt}.md"
    log "$label [500]: done with the 'transcript saved' warning, transcript kept, no protocol file ✅"
    log "$label: PASS"
}

# --- quit-flush lane (issue #745) -------------------------------------------
#
# NOT wired into CI; run by hand. On macOS 26 the non-admin runner user can
# neither `log stream` ("Must be admin to run 'stream' command") nor `log show`
# ("Could not open local log store: Operation not permitted"), and two of the
# checks below read the unified log: the persistent-log streamer counts and the
# AppKit trace of the double quit. Wiring it needs an admin runner or
# assertions that do not read the log. The lane checks that precondition before
# it changes anything, and stops with that message rather than failing later
# as an app regression.
#
# A quit has to finish the recording in progress, hand it to the pipeline and
# wait for the snapshot write that hand-over produces before the process exits.
# Unit tests pin each step against fakes; only a real quit through AppKit shows
# that the delegate is installed, that an AppleScript quit reaches it at all
# (it never went through the menu), and that `terminate` waits for it.
#
# The verdict is read from the snapshot FILE after the process is gone and
# before anything relaunches. That is the only point where it says what the
# quit wrote: once the app is back, the restore and the resumed pipeline write
# the file again, and the crash recovery at launch rebuilds a lost recording
# from its tracks under a different title, which an assertion made after the
# relaunch alone could mistake for a flushed one.
#
# Three more things only a live quit shows, from the PR's manual checks:
#   - a second quit sent while the first is held. Two answers were measured
#     and the race between them is AppKit's: it cancels the second request
#     itself (osascript gets -128, the app logs "Failed responder chain
#     validation for terminate: action. Canceling termination."), or it queues
#     it and asks the delegate again only after the held quit's reply. The
#     lane logs which one happened and fails on a trace that is neither, and
#     asserts what the user depends on either way: the held quit still
#     completes, the app ends exactly once, nothing relaunches it, nothing is
#     left running, and the recording is on disk and restored;
#   - each launch starts exactly one persistent-log streamer (`AppState` is
#     built in `App.init`, so a second `init` would start a second one);
#   - no streamer outlives the app. Checked before the relaunch, because the
#     launch reaps orphaned streamers and would hide one.
#
# What this lane does NOT prove:
#   - that the snapshot FLUSH is what put the job on disk. Measured: with the
#     flush made a no-op the lane stays green, because the background write
#     lands in the few tens of milliseconds between the reply and the exit. It
#     proves the recording survives a quit, not which step saved it; the unit
#     tests pin the flush.
#   - anything about a logout or shutdown. Those send their own quit request,
#     which the lane does not produce; whether one arriving during a held quit
#     is cancelled the same way is not measured here.
#   - the menu's Quit and Cmd-Q, which need a UI driver; the lane quits through
#     AppleScript, the path that never went through the menu.
#
# Audio: a manual recording is microphone only, and an empty transcript ends a
# job in `error`, which the queue keeps until a person dismisses it. So the
# fixture plays while recording, the jobs finish as `done`, and the lane skips
# their naming and removes their transcripts and audio on the way out.

_QF_TITLE="Microphone Recording"   # ManualRecordingInfo.microphoneTitle
_QF_SNAPSHOT="$HOME/Library/Application Support/MeetingTranscriber/ipc/pipeline_queue.json"
# TerminationFlush: 5 s recording budget, 2 s flush, a second 2 s flush, plus
# AppKit and teardown. Past this the quit is not being held, it is stuck.
_QF_EXIT_DEADLINE_S=20
_QF_RECORD_S=8
_QF_AFPLAY_PID=""
_QF_STREAMER_PID=""
_QF_JOB_ID=""
_QF_JOBS=()
# Every file path this run's jobs were seen to name, collected before the
# release removes them, so the restore can tell this run's records from
# anyone else's in a shared state file that did not exist before the lane.
_QF_OWNED_PATHS=()

# The cycle under way, from the moment its recording starts: the ids of the
# lane-titled jobs already in the snapshot then, so any job with that title
# that appears later is this cycle's. Registered as the run's (`_QF_JOBS`)
# right after the exit, before any assertion, and again by the restore, so
# cleanup and restore cover a failure at any point after the recording began,
# including one before the exit.
_QF_CYCLE_ACTIVE=""
_QF_CYCLE_KNOWN=""
_qf_cycle_started() {
    _QF_CYCLE_KNOWN="$(jq -r '.[].id' "$_QF_SNAPSHOT" 2>/dev/null | tr '\n' ' ' || true)"
    _QF_CYCLE_ACTIVE=yes
}
_qf_register_cycle_jobs() {
    local new id j seen
    [ -n "${_QF_CYCLE_ACTIVE:-}" ] || return 0
    # shellcheck disable=SC2086 # one id per word, the known list is uuids
    new="$(snapshot_new_job_ids "$_QF_SNAPSHOT" "$_QF_TITLE" $_QF_CYCLE_KNOWN)" || return 0
    for id in $new; do
        seen=""
        for j in ${_QF_JOBS[@]+"${_QF_JOBS[@]}"}; do [ "$j" = "$id" ] && seen=yes; done
        [ -n "$seen" ] || _QF_JOBS+=("$id")
    done
    return 0
}

# The app process itself, not anything whose command line mentions its path:
# `pgrep -f` alone once returned a short-lived process naming the bundle, whose
# pid was lower than the app's, and the lane looked for streamers under it.
_qf_app_pid() {
    local p
    for p in $(pgrep -x MeetingTranscriber 2>/dev/null || true); do
        case "$(ps -o command= -p "$p" 2>/dev/null)" in
            *"$_DEV_APP_PATTERN"*) echo "$p"; return 0 ;;
        esac
    done
}
_qf_app_gone() { [ -z "$(_qf_app_pid)" ]; }
_qf_streamers_of() { ps -axo pid=,ppid=,command= | streamer_pids "$1"; }
_qf_has_streamer() { [ -n "$(_qf_streamers_of "$1")" ]; }
# The quits below are timed by the lane (see the double-quit cycle), so they
# keep their shape and only get a generous cap: a pending Automation prompt
# would otherwise hold osascript, and the step, open. A capped one reports 124.
_QF_OSA_BOUND_S=60
_qf_quit() { run_bounded "$_QF_OSA_BOUND_S" osascript -e "tell application id \"$DEV_BUNDLE_ID\" to quit"; }

# Exactly one persistent-log streamer under the running app; leaves its pid in
# _QF_STREAMER_PID. Waits for the first, then looks again a moment later: a
# second AppState would start its streamer a beat after the first.
_qf_assert_one_streamer() {
    local label="$1" app_pid pids n
    app_pid="$(_qf_app_pid)"
    [ -n "$app_pid" ] || fail "$label: the dev app is not running"
    poll_until 15 1 _qf_has_streamer "$app_pid" \
        || fail "$label: the app (pid $app_pid) started no persistent-log 'log stream' child within 15s. If the app's stream predicate changed, MT_LOG_STREAM_PREDICATE in scripts/lib/e2e-helpers.sh has to follow it. Children: $(pgrep -lP "$app_pid" | tr '\n' ' ')"
    sleep 3
    pids="$(_qf_streamers_of "$app_pid")"
    n="$(grep -c . <<<"$pids" || true)"
    [ "$n" -eq 1 ] \
        || fail "$label: the app (pid $app_pid) has $n persistent-log 'log stream' children, expected exactly 1: $(tr '\n' ' ' <<<"$pids"). More than one means more than one AppState was built."
    _QF_STREAMER_PID="$pids"
    log "$label: exactly one 'log stream' child (pid $_QF_STREAMER_PID) under the app (pid $app_pid)"
}

_qf_relaunch() {
    local label="$1" i
    # Right after an exit LaunchServices can still hold the old instance and
    # answer `open` with procNotFound (-600); measured on the second cycle of
    # this lane. Retry, then force a new instance: the old one is already
    # proven gone above, so -n cannot start a second copy.
    local opened=""
    for i in 1 2 3; do
        if open "$DEV_BUNDLE_DEPLOY"; then opened=yes; break; fi
        log "$label: open failed (attempt $i), retrying"
        sleep 1
    done
    if [ -z "$opened" ]; then
        open -n "$DEV_BUNDLE_DEPLOY" || fail "$label: could not relaunch $DEV_BUNDLE_DEPLOY"
    fi
    poll_until "$RPC_READY_TIMEOUT_S" 1 _rpc_ready || fail "$label: RPC did not come back after the relaunch"
    _launched_app="$(_qf_app_pid)"
    printf '%s launched' "$_launched_app" >"$_E2E_APP_MARKER"
    log "$label: relaunched (pid $_launched_app)"
}

# One cycle: record, quit with one or two AppleScript quits, read the snapshot
# the exit left, relaunch, read the restored job. Leaves its id in _QF_JOB_ID.
_qf_cycle() {
    local label="$1" mode="$2"
    local app_pid status new n t0 t_exit q1 s1=0
    local out1="/tmp/e2e-quit-flush-q1.$$"

    _qf_assert_one_streamer "$label"
    app_pid="$(_qf_app_pid)"

    log "$label: starting a manual recording over POST /v1/record"
    # From here on any new job with the lane's title is this cycle's.
    _qf_cycle_started
    "$MTCLI" record start >/dev/null || fail "$label: mt-cli record start failed (is the Microphone grant in place for $DEV_BUNDLE_DEPLOY?)"
    "$MTCLI" record | jq -e '.recording == true' >/dev/null \
        || fail "$label: /v1/record reports recording=false right after a successful start"
    afplay "$SIMULATOR_FIXTURE" &
    _QF_AFPLAY_PID=$!
    log "$label: recording, fixture playing; quitting in ${_QF_RECORD_S}s"
    sleep "$_QF_RECORD_S"
    "$MTCLI" record | jq -e '.recording == true' >/dev/null \
        || fail "$label: the recording ended before the quit; nothing below would exercise the quit path"

    t0="$(date +%s)"
    local log_start
    log_start="$(date '+%Y-%m-%d %H:%M:%S')"
    if [ "$mode" = double ]; then
        # Both quits from one script: the first without waiting for its reply,
        # the second right behind it, waiting for its own. The whole hold takes
        # well under a second here (measured: two separate osascript calls
        # 0.3 s apart found the app already gone), so only back-to-back events
        # reach it while it is held. The second reply is the answer AppKit gave
        # that request.
        run_bounded "$_QF_OSA_BOUND_S" osascript -e 'ignoring application responses' \
            -e "tell application id \"$DEV_BUNDLE_ID\" to quit" \
            -e 'end ignoring' \
            -e "tell application id \"$DEV_BUNDLE_ID\" to quit" >"$out1" 2>&1 &
        q1=$!
        log "$label: sent two quits back to back"
    else
        _qf_quit >"$out1" 2>&1 &
        q1=$!
        log "$label: sent one quit"
    fi

    _qf_exited() { ! _pid_is_alive "$app_pid"; }
    poll_until "$_QF_EXIT_DEADLINE_S" 0.2 _qf_exited \
        || fail "$label: the app (pid $app_pid) did not exit within ${_QF_EXIT_DEADLINE_S}s of the quit. The quit is being held open past every budget, a second quit cancelled it, or the quit never arrived. osascript output so far: '$(tr '\n' ' ' <"$out1")' (empty while it is still waiting: the bound holds the output until it returns). Only -1743 there, or a quit that never shows in the app's log, points at the Automation grant: $(tcc_fix_hint 'Automation → MeetingTranscriber-Dev')"
    t_exit="$(date +%s)"
    log "$label: app exited about $(( t_exit - t0 ))s after the quit"
    # Before any assertion: a failure below must still clean up and restore
    # the job this quit wrote.
    _qf_register_cycle_jobs
    kill "$_QF_AFPLAY_PID" 2>/dev/null || true
    _QF_AFPLAY_PID=""

    wait "$q1" || s1=$?
    log "$label: first osascript exited $s1: $(tr '\n' ' ' <"$out1")"
    if [ "$mode" = double ]; then
        # Staged or not is read from AppKit's own log of this process: the
        # second quit event has to arrive before the held quit's reply, or the
        # cycle proves nothing about a second quit (one that arrives after the
        # exit ends the same way). The system log, not the app's: the measured
        # answer to the second event comes from AppKit before the delegate is
        # asked anything.
        local trace received
        trace="$(/usr/bin/log show --start "$log_start" --info --debug --style compact \
            --predicate "processID == $app_pid AND (subsystem == \"com.apple.AppKit\" OR subsystem == \"com.apple.appleevents\")" 2>/dev/null \
            | grep -E 'RECEIVED:\(aevt,quit\)|replyToApplicationShouldTerminate|Canceling termination|applicationShouldTerminate:' || true)"
        log "$label: AppKit trace of the quit:"
        while IFS= read -r line; do [ -n "$line" ] && log "    ${line:11:190}"; done <<<"$trace"
        received="$(awk '/replyToApplicationShouldTerminate/ { exit } /RECEIVED:\(aevt,quit\)/ { n++ } END { print n + 0 }' <<<"$trace")"
        [ "$received" -ge 2 ] \
            || fail "$label: not staged: the app received $received quit event(s) before replying to the held quit, so the second quit did not arrive while the first was held"
        log "$label: staged: both quit events reached the app while the first quit was held"
        # Which way AppKit answered the second request is logged, not
        # asserted: two outcomes were measured and both end in one exit.
        # AppKit cancels it itself (the script gets -128, and AppKit logs
        # "Canceling termination"), or it queues it and asks the delegate
        # again after the held quit's reply. A trace that is neither fails:
        # it is not a run this lane can explain.
        local outcome
        outcome="$(second_quit_outcome "$trace" "$(cat "$out1")")" \
            || fail "$label: the second quit request was answered neither of the two measured ways (cancelled with -128, or asked again after the first reply); osascript said: $(tr '\n' ' ' <"$out1"). See the AppKit trace above."
        case "$outcome" in
            cancelled) log "$label: the second quit request was cancelled by AppKit (-128)" ;;
            *) log "$label: the second quit request was asked again after the first reply; the delegate answered ${outcome#asked-after-reply }" ;;
        esac
        # Ended once: nothing brought the app back. An AppleScript quit sent to
        # an app that has gone must not launch it again.
        sleep 3
        _qf_app_gone || fail "$label: a dev app is running again ($(_qf_app_pid)) after the double quit; the app did not end exactly once"
        # No MeetingTranscriber at all: the preflight refused to start next to
        # the installed app, so any instance now was started by this quit.
        local left
        left="$( { pgrep -x MeetingTranscriber || true; } | tr '\n' ' ')"
        [ -z "$left" ] || fail "$label: a MeetingTranscriber process is running after the double quit (pid(s): $left)"
        log "$label: the app ended once, nothing relaunched it, no MeetingTranscriber process left"
    fi
    rm -f "$out1"

    # THE assertion: the snapshot the exit left holds the recording as a job.
    status=0
    # shellcheck disable=SC2086 # one id per word, the known list is uuids
    new="$(snapshot_new_job_ids "$_QF_SNAPSHOT" "$_QF_TITLE" $_QF_CYCLE_KNOWN)" || status=$?
    [ "$status" -eq 0 ] || fail "$label: the snapshot the quit left could not be read (see above)"
    n="$(grep -c . <<<"$new" || true)"
    [ "$n" -ge 1 ] \
        || fail "$label: the snapshot on disk holds no new '$_QF_TITLE' job after the quit. The recording was not handed to the pipeline, or its snapshot write did not land before the exit. Jobs on disk: $(jq -c '[.[] | {meetingTitle, state}]' "$_QF_SNAPSHOT" 2>/dev/null)"
    [ "$n" -eq 1 ] || fail "$label: the snapshot holds $n new '$_QF_TITLE' jobs after one quit, expected 1: $(tr '\n' ' ' <<<"$new")"
    _QF_JOB_ID="$new"
    _qf_register_cycle_jobs
    log "$label: the snapshot on disk holds the recording as job $_QF_JOB_ID (state $(jq -r --arg id "$_QF_JOB_ID" '.[] | select(.id == $id) | .state' "$_QF_SNAPSHOT"))"

    # The streamer this launch started must not outlive the app. Checked now,
    # because the next launch reaps orphaned streamers.
    _qf_streamer_gone() { _no_pid_alive "$_QF_STREAMER_PID"; }
    poll_until 5 0.5 _qf_streamer_gone \
        || fail "$label: the app's 'log stream' (pid $_QF_STREAMER_PID) is still running after the app exited: $(ps -o pid=,ppid=,command= -p "$_QF_STREAMER_PID")"
    new="$(ps -axo pid=,ppid=,command= | streamer_pids 1 | grep -vxF -f <(printf '%s\n' "${_QF_PRE_ORPHANS:-}") || true)"
    [ -z "$new" ] || fail "$label: orphaned persistent-log streamer(s) appeared: $(tr '\n' ' ' <<<"$new")"
    log "$label: no 'log stream' left behind"

    # And the next launch restores it under its title.
    _qf_relaunch "$label"
    # Polled: the restore runs when auto-watch starts, a beat after RPC is up.
    local dto=""
    _qf_restored() {
        dto="$(rpc "/v1/jobs/$_QF_JOB_ID")"
        [ "$(jq -r '.meetingTitle // empty' <<<"$dto" 2>/dev/null || true)" = "$_QF_TITLE" ]
    }
    poll_until 30 1 _qf_restored \
        || fail "$label: after the relaunch GET /v1/jobs/$_QF_JOB_ID does not return the job with its title within 30s (last: ${dto:-<no response>})"
    log "$label: restored after relaunch: $(jq -c '{jobID, state, meetingTitle}' <<<"$dto")"
    _QF_CYCLE_ACTIVE=""
}

# The files a job in the snapshot names (its audio, transcript and protocol),
# as filesystem paths. JSONEncoder writes a URL as its absolute string,
# percent-encoded.
_qf_job_file_paths() {
    jq -r --arg id "$1" '.[] | select(.id == $id)
        | (.mixPath, .appPath, .micPath, .transcriptPath, .protocolPath) | select(. != null)
        | if type == "object" then .relative else . end' "$_QF_SNAPSHOT" 2>/dev/null \
        | python3 -I -c 'import sys, urllib.parse
for line in sys.stdin:
    u = urllib.parse.urlparse(line.strip())
    if u.scheme == "file": print(urllib.parse.unquote(u.path))'
}

# On exit, for jobs the release never reached (a failure before it): remove
# the files the snapshot names for them, by exact path, before the restore
# drops the jobs from the queue and nothing names those files any more.
_qf_remove_unreleased_files() {
    local job f
    [ "$KEEP_RECORDINGS" = true ] && return 0
    # `${a[@]+...}`: bash 3.2 under `set -u` calls an empty array unbound,
    # and a run that fails before its first job gets here with none.
    for job in ${_QF_JOBS[@]+"${_QF_JOBS[@]}"}; do
        while IFS= read -r f; do
            [ -n "$f" ] && [ -f "$f" ] && rm -f "$f" && log "[quit-flush] removed $f"
        done < <(_qf_job_file_paths "$job")
    done
    return 0
}

# Let the lane's jobs finish and remove what they wrote. Best effort, like the
# echo lanes' release: this is teardown, and its own failure is reported, not
# turned into the lane's verdict.
_qf_release_jobs() {
    local job dto state f
    # `${a[@]+...}`: bash 3.2 under `set -u` calls an empty array unbound,
    # and a run that fails before its first job gets here with none.
    for job in ${_QF_JOBS[@]+"${_QF_JOBS[@]}"}; do
        while IFS= read -r f; do
            [ -n "$f" ] && _QF_OWNED_PATHS+=("$f")
        done < <(_qf_job_file_paths "$job")
        _echo_release "$job"
        dto="$(rpc "/v1/jobs/$job")"
        state="$(jq -r '.state // empty' <<<"$dto")"
        if [ "$state" != "done" ]; then
            log "[quit-flush] NOTE: job $job settled as '${state:-unknown}', not done; it stays in the queue until dismissed in the app. error=$(jq -r '.error // "<none>"' <<<"$dto")"
            continue
        fi
        if [ "$KEEP_RECORDINGS" = true ]; then
            log "[quit-flush] --keep-recordings: leaving job $job's files: $(jq -r '.transcriptPath // empty' <<<"$dto") $(_qf_job_file_paths "$job" | tr '\n' ' ')"
            continue
        fi
        # Exact paths only, never a sweep: the output folder is the user's.
        for f in "$(jq -r '.transcriptPath // empty' <<<"$dto")" "$(jq -r '.protocolPath // empty' <<<"$dto")"; do
            [ -n "$f" ] && [ -f "$f" ] && rm -f "$f" && log "[quit-flush] removed $f"
        done
        while IFS= read -r f; do
            [ -n "$f" ] && [ -f "$f" ] && rm -f "$f" && log "[quit-flush] removed $f"
        done < <(_qf_job_file_paths "$job")
    done
    # The loops above end on a false test whenever a file is already gone (the
    # transcript is named twice), and under `set -e` that status would end the
    # script here, before the lane's verdict is printed.
    return 0
}

run_quit_flush() {
    # Orphans that predate the lane are not its doing (another build that
    # crashed); only new ones are.
    _QF_PRE_ORPHANS="$(ps -axo pid=,ppid=,command= | streamer_pids 1)"
    [ -z "$_QF_PRE_ORPHANS" ] || log "[quit-flush] note: orphaned streamer(s) predate the lane: $(tr '\n' ' ' <<<"$_QF_PRE_ORPHANS")"

    _qf_cycle "[quit-flush 1/2 one quit]" single
    _qf_cycle "[quit-flush 2/2 two quits]" double
    _qf_assert_one_streamer "[quit-flush after relaunch]"

    _qf_release_jobs
    log "[quit-flush] PASS"
}

if [ "$REIMPORT_LATEST" = true ]; then
    # Skip the live-record phase and reuse a WAV produced by an earlier
    # `--record-only --keep-recordings` run on this host. Picks the
    # freshest `*_mix.wav` in $RECORDINGS_DIR — eliminates the audible
    # ~30 s playback + capture round and the meeting-detector cooldown
    # that --reimport-recorded incurs.
    # Pick the freshest *_mix.wav by mtime. A single awk max-pass replaces
    # `sort -rn | head -1`: under `set -o pipefail`, `head` closing the pipe
    # after one line left `sort` writing into a closed pipe → SIGPIPE (exit
    # 141) → `set -e` aborted with "sort: Broken pipe" once two or more
    # recordings had accumulated. awk reads the whole stream, so the upstream
    # find/stat finish cleanly. (`$1` = mtime, `$0` = "mtime path"; cut keeps
    # the path, tolerating spaces.)
    latest_mix="$(find "$RECORDINGS_DIR" -maxdepth 1 -name '*_mix.wav' -type f \
        -exec stat -f '%m %N' {} + 2>/dev/null \
        | awk 'NR == 1 || $1 > newest { newest = $1; line = $0 } END { if (NR) print line }' \
        | cut -d' ' -f2-)"
    [ -n "$latest_mix" ] && [ -f "$latest_mix" ] \
        || fail "--reimport-latest: no *_mix.wav found in $RECORDINGS_DIR — run \`e2e-app.sh --record-only --keep-recordings\` first to produce one"
    log "Reusing latest record-only WAV: $latest_mix"
    # No `sleep $RECORDER_FINALIZE_WAIT_S` here, unlike --reimport-recorded:
    # the WAV was produced by a prior script invocation that already exited,
    # so its AVAudioFile close + tail-byte flush happened on process exit
    # — nothing left to wait for.
    run_one_reimport "[reimport-latest]" "$latest_mix"
elif [ "$REIMPORT_RECORDED" = true ]; then
    # Phase 1: record-only meeting → produces a WAV via the live capture stack.
    run_one_record_only_meeting "[record]"
    [ -n "$LAST_RECORDED_MIX_PATH" ] || fail "record-phase did not surface a mix path; cannot continue"

    # Phase 2: re-import that WAV through the menu's "Open from Recording"
    # entry — same code path NSOpenPanel uses, exposed via RPC. recordOnly
    # is still toggled on but only affects WatchLoop.enqueueRecording, not
    # AppState.enqueueFiles, so the pipeline runs end-to-end.
    log "Sleeping ${RECORDER_FINALIZE_WAIT_S}s before re-import to let recorder finalize tail bytes"
    sleep "$RECORDER_FINALIZE_WAIT_S"
    run_one_reimport "[reimport]" "$LAST_RECORDED_MIX_PATH"
elif [ "$MIC_ONLY" = true ]; then
    # Before the record-only arm: the mic-only lane turns RECORD_ONLY on to
    # reuse its cleanup, so testing RECORD_ONLY first would run the wrong lane.
    run_mic_only
elif [ "$RECORD_ONLY" = true ]; then
    if [ "$TWO_MEETINGS" = true ]; then
        run_one_record_only_meeting "[1/2]"
        log "Sleeping ${INTER_MEETING_COOLDOWN_S}s for WatchLoop cooldown before meeting 2"
        sleep "$INTER_MEETING_COOLDOWN_S"
        run_one_record_only_meeting "[2/2]"
    else
        run_one_record_only_meeting "meeting"
    fi
elif [ "$MIC_DEVICE_CHANGE" = true ]; then
    # Issue #379: the fault-injection build self-triggers a mic device-change
    # restart ~2 s into recording whose tap install uses an invalid format,
    # raising an NSException from installTapOnBus. Pre-fix the app aborts mid
    # recording → the poll loop's assert_app_alive fails before any job lands
    # (RED). Post-fix the app catches + recovers → recording completes → the
    # existing run_one_meeting .done/transcript assertions pass (GREEN).
    log "[mic-device-change] fault-injection build active; app will self-trigger a"
    log "[mic-device-change] mic device-change restart with an invalid tap format mid-recording."
    log "[mic-device-change] PASS = app survives (no SIGABRT) AND recording completes."
    run_one_meeting "[mic-device-change]"
    assert_app_alive
    log "[mic-device-change] app survived the injected device-change restart ✅"
elif [ "$CRASH_RECOVERY" = true ]; then
    run_crash_recovery
elif [ "$NAMING_ESCAPE" = true ]; then
    run_naming_escape
elif [ "$NAMING_CONFIRM" = true ]; then
    run_naming_confirm
elif [ "$NAMING_SWITCH" = true ]; then
    run_naming_switch
elif [ "$TITLE_SOURCE" = true ]; then
    run_title_source
elif [ "$ECHO_BLEED" = true ]; then
    run_echo_bleed
elif [ "$ECHO_CANCEL" = true ]; then
    run_echo_cancel
elif [ "$QUIT_FLUSH" = true ]; then
    run_quit_flush
elif [ -n "$MIC_STALL" ]; then
    run_mic_stall
elif [ "$UPGRADE" = true ]; then
    run_upgrade
elif [ "$PROTOCOL_LANE" = true ]; then
    run_protocol_lane
elif [ "$TWO_MEETINGS" = true ]; then
    run_one_meeting "[1/2]"
    log "Sleeping ${INTER_MEETING_COOLDOWN_S}s for WatchLoop cooldown before meeting 2"
    sleep "$INTER_MEETING_COOLDOWN_S"
    run_one_meeting "[2/2]"
else
    run_one_meeting "meeting"
fi

if [ "$APP_AFTER" = quit ]; then
    quit_running_app
fi

log "PASS"
