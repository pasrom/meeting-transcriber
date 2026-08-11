# Generic Browser Meeting Detection: Process-Open Matching with Per-App Remembered Decisions

Status: proposed (design + implementation plan, nothing implemented)
Date: 2026-08-11
Related: issue #503 (browser meetings), issue #543 (consent parking), PR #601 (Aside, superseded by this plan)

## Problem

Browser meeting detection matches the Chromium content layer's power assertion
(`NoIdleSleepAssertion` named "WebRTC has active PeerConnections") but only for
a hard-coded list of process names: Google Chrome, Brave Browser, Microsoft
Edge, Chromium (`PowerAssertionDetector.defaultPatterns`, the browser entry).
Every new Chromium fork needs a source edit plus a release; PR #601 is adding a
fifth fork ("Aside") one string at a time. A wrong or missing string fails
completely silently: the "watched app did not match" diagnostic
(`unmatchedWatchedAssertionKeys`) is gated on the very same process allowlist
(`watched.contains(processName)`), so an unlisted browser produces no log line
at all. The next fork is discoverable only by guessing.

The allowlist also created a shared identity. All four browsers are aliased
into one `AppMeetingPattern.chromeBrowser` whose `appName` is "Google Chrome",
and that alias leaks into every downstream consumer:

1. A consent decline for a meeting detected in one fork is recorded against
   the shared "Google Chrome" cooldown key (`WatchLoop+Consent.swift` passes
   `meeting.pattern.appName` to `consentPolicy.recordDecline`), silently
   suppressing prompts for meetings in every other fork for ten minutes.
2. `isMeetingActive` filters patterns by
   `pattern.appName == meeting.pattern.appName` and then accepts a match from
   any process in the family list, so a second, unrelated browser holding a
   WebRTC assertion keeps a finished meeting's recording alive until the four
   hour `maxDuration` cap.
3. The once-per-poll guard in `checkOnce` (`hitsThisRound`, keyed by
   `pattern.appName`) keeps only one family member per poll, chosen by
   unordered dictionary iteration, so `firstMatch` and with it `windowPID`
   (the audio tap target) can belong to the wrong browser.
4. `chromeBrowser` has empty `meetingPatterns`/`idlePatterns` and lists all
   four forks as `ownerNames`, so `MeetingTitleMatcher.selectWindowTitle`
   returns the first non-empty window title owned by ANY family browser: an
   unrelated browser's tab title can become the meeting title, the protocol
   filename, and part of the LLM prompt.
5. `WatchLoop.handleMeeting` forwards `meeting.pattern.appName` to
   `enqueueRecording`, so a record-only sidecar says `appName: "Google
   Chrome"` for a recording made in Brave, Edge, or any other fork.

All five are consequences of one decision: the process list doubles as the
identity. This plan removes both.

## Design

### 1. The browser pattern becomes process-open

The browser `AssertionPattern` drops its `processNames` and matches on its
keywords alone (`webrtc`, `peerconnection`). The keyword is the
meeting-specific signal (the assertion name is emitted by Chromium's content
layer during any WebRTC call and by nothing else we know of); the process list
was only ever an identity plus an incidental filter. All other patterns
(Teams, Zoom, Webex, meeting-simulator) stay process-bound: there the process
name IS the distinguishing signal, because their assertion names or types are
generic.

A pattern carries two INDEPENDENT properties, and keeping them independent is
what makes the staging below work:

- `processNames`: what the pattern accepts. Non-empty means allowlist-bound;
  empty means process-open. The browser pattern empties it in PR 3.
- `identity`: how a hit is identified downstream, `.shared` (the pattern's
  own `appName`, today's behaviour for every pattern) or `.perProcess` (the
  concrete process name). The browser pattern switches to `.perProcess` in
  PR 1.

Deriving identity from `processNames.isEmpty` would collapse the two, and PR 1
would then be a no-op: it keeps the allowlist by design, so the browser
pattern would stay `.shared` and findings 1 to 5 would survive the PR that is
supposed to fix them. The two properties are also conceptually distinct (what
do I accept, versus what do I call it), so an explicit field is the better
design independently of the staging.

Matching gains one guard, the **native-claim exclusion**: a process that belongs to any
process-bound pattern in `PowerAssertionDetector.defaultPatterns` (for
example `MSTeams`, `zoom.us`) can never match a process-open pattern. This is
not hypothetical hygiene: Microsoft Teams is Electron-based and shares
Chromium's content layer, so it plausibly emits the identical WebRTC assertion
during a call. Without the exclusion, a native Teams call could trigger a
browser consent prompt alongside its own auto-start, and turning the Teams
toggle off would resurrect Teams recording through the browser path against
the user's explicit opt-out. The exclusion set is computed from
`defaultPatterns` (all known native patterns), NOT from the watched subset,
precisely so that an unwatched native app stays excluded.

Honest accounting: today `matchAssertion` checks `processNames` first, so the
allowlist DOES currently participate in matching. It is what keeps Firefox
(which has its own power management) and Electron apps out. Opening the
pattern deliberately trades that incidental filter for the remembered per-app
decision described below. The existing test
`testNonChromeWebRTCAssertionIsNotDetected` pins the old behaviour (a
`firefox` process holding the WebRTC-named assertion must not fire) and is
intentionally inverted by this design: any process holding that assertion is
now a candidate, and the consent prompt plus the Never action are the filter.

### 2. Per-process identity throughout

The concrete process name becomes the meeting identity for process-open hits.
`AppMeetingPattern.chromeBrowser` stops being an identity and becomes a
category: renamed to `AppMeetingPattern.browserMeetings` with
`appName: "Browser Meetings"` (a token that can never collide with a real
process name), `ownerNames: []`, `meetingPatterns: []`, and
`requiresRecordingConsent: true`. It exists so that:

- `AppSettings.watchApps` has a token to append when `watchBrowserMeetings`
  is on (the master toggle stays one switch, off by default), and
  `PowerAssertionDetector.patterns(watching:)` has a name to filter on;
- the category-level `requiresRecordingConsent` policy has one home.

The rename is load-bearing, not cosmetic: if the category kept the appName
"Google Chrome", then a meeting detected in actual Chrome would resolve
`AppMeetingPattern.forAppName("Google Chrome")` to the category with all four
`ownerNames`, resurrecting the cross-browser title leak (finding 4) for Chrome
specifically. `watchApps` is computed, never persisted, so the token rename
needs no migration.

For a process-open hit, `checkOnce` synthesizes a per-process
`AppMeetingPattern`:

```swift
AppMeetingPattern(
    appName: processName,           // e.g. "Aside"
    ownerNames: [processName],
    meetingPatterns: [],
    requiresRecordingConsent: true, // MUST be explicit, see below
)
```

`checkOnce` already synthesizes exactly this shape when `forAppName` misses
(existing code), with one critical difference: the existing fallback leaves
`requiresRecordingConsent` at its default `false`. Reusing it unchanged would
make every unknown fork AUTO-RECORD with no prompt, the exact inverse of the
safety story. The synthesis for open-pattern hits must set the flag from the
matched pattern's category. This is the single most dangerous line in the
change and gets a dedicated test.

That synthesized pattern is then the identity everywhere downstream, with no
further plumbing changes needed in `WatchLoop`, because everything already
keys on `meeting.pattern.appName`:

- consent cooldown key (`BrowserConsentPolicy` is already per-key; the key
  simply becomes per-process), resolving finding 1;
- `RecordingSidecar.appName` and `PipelineJob.appName`, resolving finding 5;
- `detector.reset(appName:)` after a meeting or a decline;
- the consent prompt body (today's `meeting.ownerName` naming stays correct:
  for a per-process identity, `appName == ownerName`).

Two places need real changes:

- **Liveness.** `isMeetingActive` filters `pattern.appName ==
  meeting.pattern.appName`; the open pattern's `appName` is the category
  token while the meeting's is the process name, so without a change the
  filter matches nothing, `isMeetingActive` returns false, and every browser
  recording would end at the grace period (about 15 s). The generalized rule:
  an assertion keeps `meeting` alive iff its identity key (below) equals
  `meeting.pattern.appName` and the assertion matches the pattern. For bound
  patterns the identity key is `pattern.appName`, which reduces to today's
  behaviour; for open patterns it is the process name, which resolves
  finding 2 and is also what makes the feature work at all.
- **Title lookup.** For open-pattern hits, build a `MeetingTitleMatcher` from
  the synthesized per-process pattern at hit time (ownerNames is exactly the
  one process; no regexes to compile, so this is cheap) instead of the
  precompiled `matchers[appName]` dictionary, which stays for bound patterns.
  This resolves finding 4: only the detected browser's own windows can
  contribute a title. The init-time drift guard ("no AppMeetingPattern for
  watched app") skips process-open patterns.

### 3. Detector keying: identity key instead of appName

`hitsThisRound`, `consecutiveHits`, `cooldownUntil`, and `firstMatch` are all
keyed today on `pattern.appName`. They move to an identity key:

```swift
extension PowerAssertionDetector.AssertionPattern {
    enum Identity { case shared, perProcess }

    /// `.shared`: the appName (unchanged, every pattern today). `.perProcess`:
    /// the concrete process name, so each browser counts its own confirmation
    /// polls and holds its own cooldown. Deliberately NOT derived from
    /// `processNames.isEmpty`: identity switches in PR 1 while the allowlist
    /// is still in place, and the allowlist is only emptied in PR 3.
    func identityKey(processName: String) -> String {
        switch identity {
        case .shared: appName
        case .perProcess: processName
        }
    }
}
```

Consequences: each browser accumulates its own `confirmationCount` polls; the
once-per-poll guard no longer makes two forks race for one slot (finding 3);
`firstMatch` and therefore the tap target `windowPID` always belong to the
browser that confirmed; `reset(appName:)`/cooldowns are per browser.
`firstMatch` additionally records the source `AssertionPattern` so the
confirmation loop knows whether to synthesize a per-process identity (open
pattern) or use the existing `forAppName` path (bound pattern).

### 4. Per-app remembered decisions: a deny list

Decision (the user's explicit call, not an assumption): recording consent
stays per meeting for every browser, known or unknown. A detected browser
meeting always prompts, for two reasons:

- existing installations must see no behaviour change: today every Chrome
  call prompts, and nothing in this plan may turn per-call prompting into
  auto-recording;
- the documented false positive must never record silently: Google Meet
  holds the same WebRTC assertion on an open page you cannot even join, so
  any app-level "record without asking" state would record non-meetings.

That decision collapses the remembered state to two values. The original
direction called for a three-state store (confirmed / denied / undecided,
with Record promoting an app to confirmed and the four known browsers
pre-seeded as confirmed). With per-meeting consent fixed, a confirmed app
and an undecided app prompt identically, Record's promotion changes no
future behaviour, and the pre-seed is a no-op; the confirmed state carried
bookkeeping and nothing else. It is dropped. If a per-app auto-record
setting is ever wanted, a positive state returns then, with actual
behaviour attached. What remains:

- **denied**: never prompt for this app again, never record it, until the
  user reverts the decision in Settings. This is the only remembered state
  and the intended answer to the Electron risk (section 6).
- **everything else**: prompts per meeting, exactly like Chrome today.

The consent prompt gains a third action:

- Record: record now. It remembers nothing: approval is per meeting.
- Ignore: this time only; the existing ten minute decline cooldown, unchanged.
- Never for this app: add the app to the deny list; also start the decline
  cooldown so the current call is quiet immediately.

`ConsentAnswer` gains a `.never` case (`isGranted` stays `== .granted`).
`NotificationManager` maps a third action identifier to it; the debug RPC
`confirmBrowserConsent` keeps its Bool body (granted maps to `.granted`,
not-granted to `.declined`), so `mt-cli` and the e2e lane are unaffected.

The store is a small value type plus a defaults-backed adapter:

```swift
/// Pure core: one name list in, membership and transitions out.
struct ConsentDenyList: Equatable {
    var denied: [String]
    func isDenied(_ app: String) -> Bool
    func denying(_ app: String) -> ConsentDenyList    // idempotent
    func reverting(_ app: String) -> ConsentDenyList  // Settings "Remove"
}
```

`WatchLoop` receives the store through a narrow injected protocol (pattern:
`notifier`, `nowProvider`), defaulting to an in-memory instance so existing
tests are untouched; `WatchingController` wires the `AppSettings`-backed
adapter. The consent gate consults it before prompting: a denied app is
skipped with a `detector.reset` (same shape as the existing suppressed-decline
branch), and a `.never` answer is recorded in `finishConsent`.

### 5. Persistence and migration

One new UserDefaults key on `AppSettings`:

- `consentDeniedApps: [String]`, read as `stringArray(forKey:) ?? []`

No seeding and no migration: the deny list starts empty, and the four
previously hard-coded browser names disappear from the source entirely (the
detection allowlist is deleted by process-open matching, and the dropped
confirmed list needed no seed). An upgraded install behaves identically
until the user's first Never.

Back-compat inventory:

- `watchBrowserMeetings` toggle: unchanged key, unchanged default (off).
- `watchApps` token rename ("Google Chrome" to "Browser Meetings"): computed
  value, never persisted, no migration.
- `RecordingSidecar.appName`: existing free-string field; the VALUE changes
  from "Google Chrome" to the concrete process name. No schema/version bump.
  A fleet consumer that string-matched "Google Chrome" will see per-browser
  names after the update; called out in the release notes.
- `/state.pendingConsentApp`: stays a string; the value becomes the concrete
  process name. The debug surface carries no stability contract, but
  `scripts/e2e-browser.sh` pins the old value and must change in the same PR
  (section on staging).
- Downgrade: an older build ignores the new key and falls back to its
  hard-coded list. Nothing breaks.

### 6. The Electron risk, stated plainly

Electron apps embed Chromium's content layer. A Slack huddle, a Discord call,
or any other Electron app doing WebRTC plausibly holds the identical "WebRTC
has active PeerConnections" assertion. Today the process allowlist excludes
them incidentally; that exclusion was never documented as intent, and this
design removes it knowingly.

What changes for such a user, concretely: with browser watching ON (it is off
by default), the first Slack huddle after the update produces one notification:
"Record browser meeting? A meeting is active in Slack." with Record / Ignore /
Never for this app. Choosing Never silences Slack permanently (reviewable and
revertible in Settings). Choosing Ignore gives ten minutes of quiet. Nothing
is ever recorded without a Record answer, because process-open hits always
carry `requiresRecordingConsent`. Known native meeting apps (Teams and
friends) never reach this prompt thanks to the native-claim exclusion, even
when their toggle is off.

This is a real, intended trade: one extra prompt per Electron app the user
actually calls with, in exchange for every Chromium fork working without a
release. It is tested at the pure layer (an Electron-shaped process name that
appears nowhere in Sources must route to the prompt with per-process identity;
`MSTeams` holding the same assertion must not), and the first-time UX is
exactly the existing consent prompt, so no new UI surface is involved.

Whether any given fork or Electron app actually emits the assertion remains
empirically open (a controlled loopback RTCPeerConnection page made Chrome
raise it within seconds, while the same page in Aside never reached the
connected state, so Aside in a real call is unverified). The design does not
depend on any particular app emitting it: an app that never emits it is simply
never detected, same as today.

### 7. Diagnostic widening

`unmatchedWatchedAssertionKeys` currently reports only assertions from
processes on the allowlist, which is why a wrong string was invisible. It is
widened with a second clause: an assertion whose NAME matches a process-open
pattern's keywords, from ANY process, that nevertheless produced no hit this
round (native-claim exclusion, cooldown) is reported once per session in the
same `process|name|type` key format. After this change, "a Chromium-ish
process held a WebRTC assertion and we did not act on it" is always visible in
the log, which is the signal that makes the next detection gap diagnosable
from a user's diagnostic export instead of by guessing.

Limitation, stated openly: when `watchBrowserMeetings` is off, the open
pattern is filtered out of the detector entirely and no diagnostic fires. That
matches the precedent set by `MicInputDetector` (it only enumerates and logs
when its toggle is on) and avoids logging WebRTC activity for users who opted
out of the feature.

## Review findings: resolved or not

| Finding | Status after this plan |
|---|---|
| 1. Decline recorded against shared key suppresses other browsers | Resolved: cooldown key is the per-process identity (verified: the key is `meeting.pattern.appName` end to end, so the identity change alone fixes it) |
| 2. `isMeetingActive` keeps a recording alive on any family browser | Resolved, and required: without the identity-key liveness rule the feature breaks outright (grace-period stop), not just cross-talks |
| 3. Once-per-poll guard picks an arbitrary family member; wrong tap target | Resolved: per-identity-key keying; `firstMatch` carries the confirming process's pid |
| 4. Title lookup leaks any family browser's tab title | Resolved: per-process `MeetingTitleMatcher` with single-element `ownerNames`; the category's `ownerNames` shrink to `[]` |
| 5. Sidecar/job `appName` says "Google Chrome" for other forks | Resolved: identity flows into `enqueueRecording` unchanged (verified plumbing) |
| 6. Silent failure for unlisted forks (diagnostic gated on allowlist) | Mostly resolved: with the toggle on, an unlisted fork now either detects or logs; with the toggle off there is still no signal (documented limitation) |

## Code changes per file, in dependency order

Verified line references are against branch `work` at the time of writing.

1. `app/MeetingTranscriber/Sources/ConsentAnswer.swift`
   Add `.never`. `isGranted` unchanged.

2. `app/MeetingTranscriber/Sources/ConsentDenyList.swift` (new)
   `ConsentDenyList` (pure), the `ConsentDenyListStoring` protocol
   (`isDenied(_:)`, `deny(_:)`, `revert(_:)`), and an in-memory default.

3. `app/MeetingTranscriber/Sources/AppSettings.swift` (+ a defaults-backed
   `ConsentDenyListStoring` adapter, either here or in the new file)
   `consentDeniedApps` with the empty-default read described above.

4. `app/MeetingTranscriber/Sources/MeetingPatterns.swift`
   Rename `chromeBrowser` to `browserMeetings`; `appName: "Browser Meetings"`,
   `ownerNames: []`. Keep it in `all` (harmless in `byName`; `forAppName`
   can only be asked for it by the category token, which no process carries).

5. `app/MeetingTranscriber/Sources/AppSettings+Computed.swift`
   `watchApps` appends `AppMeetingPattern.browserMeetings.appName`.

6. `app/MeetingTranscriber/Sources/PowerAssertionDetector.swift`
   The core change:
   - browser `AssertionPattern` takes the category appName and
     `identity: .perProcess` (PR 1); it loses `processNames` (empty = open)
     only in PR 3;
   - `matchAssertion` becomes a pure static
     `matches(pattern:processName:assertName:assertType:claimed:)` with the
     open-pattern branch and the native-claim exclusion;
   - `claimedProcesses(in:)` pure static, computed once from
     `defaultPatterns` at init;
   - `identityKey(processName:)` on `AssertionPattern`; `hitsThisRound`,
     `consecutiveHits`, `cooldownUntil`, `firstMatch` re-keyed on it, and
     `firstMatch` extended to carry the source pattern;
   - `meetingIdentity(...)` pure static: bound pattern hit resolves via
     `forAppName` with the existing fallback; open pattern hit synthesizes
     the per-process pattern with `requiresRecordingConsent: true`;
   - `isMeetingActive` uses the identity-key rule;
   - per-process title matcher for open hits; drift guard skips open
     patterns;
   - `unmatchedWatchedAssertionKeys` gains the keyword clause.

7. `app/MeetingTranscriber/Sources/NotificationManager.swift`
   Third action ("Never for this app", id `BROWSER_MEETING_NEVER`) in
   `makeConsentCategory`; replace `consentGranted(for:)` with
   `consentAnswer(for:) -> ConsentAnswer`; `resolveConsent` routes through
   `ConsentPromptCoordinator.resolve(id:answer:)` (the answer overload already
   exists). `resolvePending(granted:)` (the RPC path) unchanged.

8. `app/MeetingTranscriber/Sources/WatchLoop.swift` and
   `WatchLoop+Consent.swift`
   Inject the deny-list store (default in-memory). `requestConsentIfNeeded`
   adds the denied guard before the cooldown check; `finishConsent` records
   `.never` as denied plus the decline cooldown.

9. `app/MeetingTranscriber/Sources/WatchingController.swift`
   Wire the settings-backed store into both `WatchLoop` construction sites.

10. `app/MeetingTranscriber/Sources/A11yID.swift` and
    `app/MeetingTranscriber/Sources/Settings/GeneralSettingsView.swift`
    Toggle label/caption stop naming specific forks ("Browser Web Meetings
    (Chromium-based)"). New sub-section, visible when the toggle is on and
    the deny list is non-empty: the never-record apps as rows with a Remove
    button each (`A11yID.browserAppRemove(name)`), writing back through the
    store.

11. `scripts/e2e-browser.sh`
    `_consent_parked` asserts `pendingConsentApp == "$BROWSER_LABEL"` (the
    concrete browser) instead of the literal "Google Chrome"; update the
    comment block that documents the shared identity. Read the
    `e2e-architecture` skill before touching this file (repo rule).

12. `README.md`, `CLAUDE.md` (Detection section), `docs/automation-api.md` if
    it mentions the consent identity
    Rewrite the browser-meeting paragraphs: keyword-only matching, per-process
    identity, remembered decisions, the Electron trade-off.

## Test strategy

Repo rule: assert each behaviour at the cheapest layer that can falsify it.
The bulk of coverage goes to the pure functions this plan extracts:

- `PowerAssertionDetector.matches(...)` (open matching + native-claim
  exclusion),
- `AssertionPattern.identityKey(processName:)`,
- `PowerAssertionDetector.meetingIdentity(...)` (synthesis incl. the consent
  flag),
- `PowerAssertionDetector.unmatchedWatchedAssertionKeys` (widened),
- `ConsentDenyList` (membership + transitions),
- `NotificationManager.consentAnswer(for:)` and `makeConsentCategory()`.

A known trap in exactly this area: a test that feeds back the literal it
asserts. The family tests added around PR #601 iterate over the same four
names the source hard-codes, so they cannot fail for a wrong process name.
Every test below names what makes it able to fail.

### Layer 1: pure logic (XCTest on value types)

1. **Open matching fires for a name that appears nowhere in Sources.**
   Process "Fjordfox" + assert name "WebRTC has active PeerConnections"
   matches the open pattern. Falsifiable because no allowlist implementation
   can pass it; the literal exists only in the test.
2. **Open matching still requires the keyword.** "Fjordfox" + "Playing audio"
   does not match. Falsifiable against an implementation that made the open
   pattern match every assertion from every process.
3. **Native-claim exclusion.** "MSTeams" + the WebRTC assert name does not
   match the open pattern (and this must hold with a `patterns` list from
   which the Teams pattern was filtered out, pinning that the claimed set
   comes from `defaultPatterns`). Falsifiable: a naive keyword-only match
   passes the assertion through.
4. **Identity key.** Bound pattern returns `appName` for any process; open
   pattern returns the process name. Trivial but load-bearing for every
   keying consumer.
5. **Synthesis carries the consent flag.** `meetingIdentity` for an
   open-pattern hit on "Fjordfox" returns a pattern with
   `requiresRecordingConsent == true` and `ownerNames == ["Fjordfox"]`.
   Falsifiable against reusing the existing `forAppName` fallback verbatim,
   whose default is `false`; this is the auto-record-without-prompt trap.
6. **Deny list.** `isDenied` membership; `denying` is idempotent (no
   duplicate entries after two Nevers); `reverting` removes exactly the one
   app and is a no-op for an absent one. Edge cases per the repo's
   heuristics rule: empty list, one entry, many entries.
7. **Widened diagnostic.** A "Fjordfox" WebRTC-named assertion with no hit is
   reported; the same assertion present in `hits` under key "Fjordfox" is
   not; a claimed process ("MSTeams") with the WebRTC name is reported (that
   is the excluded-but-interesting case). Falsifiable against the current
   allowlist-gated implementation by construction.
8. **Consent answer mapping.** Record/Never/Ignore/dismiss identifiers map to
   `.granted`/`.never`/`.declined`/`.declined`; the category exposes exactly
   three actions.

### Layer 1b: detector-level (injected `assertionProvider`, still `swift test`)

9. **Per-process confirmation counting.** `confirmationCount: 2`; poll 1:
   only "Fjordfox" asserts; poll 2: "Fjordfox" and "Brave Browser" assert.
   Result confirms "Fjordfox" (its second poll), not Brave (its first), and
   the returned `windowPID` is Fjordfox's pid. Falsifiable against shared
   keying, under which poll 2 would be the shared key's second hit with an
   arbitrary `firstMatch`.
10. **Per-process liveness, both directions.** A meeting identified as
    "Fjordfox": assertions containing only Brave's WebRTC assertion give
    `isMeetingActive == false` (fails against today's family-wide match);
    assertions containing Fjordfox's give `true` (fails against a botched
    rewrite in which open-pattern meetings match nothing and recordings stop
    at the grace period).
11. **Per-process title.** Window list with a Brave-owned title and a
    Fjordfox-owned title; the detected Fjordfox meeting's title is the
    Fjordfox one and never the Brave one. Falsifiable against the shared
    `ownerNames` matcher.
12. **Repurposed Firefox test.** The existing
    `testNonChromeWebRTCAssertionIsNotDetected` inverts: "firefox" + WebRTC name
    now detects, with identity "firefox" and the consent flag. Kept, renamed,
    with a comment stating the deliberate flip.
13. **Store persistence.** The `AppSettings`-backed adapter round-trips:
    deny writes the array, revert removes the entry, a fresh defaults suite
    reads an empty list. Falsifiable against a store that forgets to persist
    (in-memory only), which every WatchLoop-level test would miss because
    those inject the in-memory instance.

### Layer 1c: WatchLoop consent gate (existing `WatchLoopBrowserConsentTests` harness)

14. **Denied means silence, past every cooldown.** Store with "Fjordfox"
    denied; the consent spy is never called, even after `nowProvider` jumps
    beyond `declineCooldown`. Falsifiable against implementing Never as a
    mere decline (which re-prompts after ten minutes); the time jump is what
    makes this test distinguish the two.
15. **Never records the denial.** Spy answers `.never`: no recording starts,
    the store records denied, and a subsequent detection of the same app does
    not prompt. A control detection of a different app still prompts (guards
    against a global, rather than per-app, denial).
16. **Record remembers nothing.** Spy answers `.granted` for "Fjordfox":
    recording starts and the deny list stays untouched. Falsifiable against
    an implementation whose answer switch misroutes `.granted` into the
    deny transition, which would silence an app the user just approved.
17. **Cross-browser cooldown independence.** Decline a "Fjordfox" prompt,
    then a "Google Chrome" meeting appears: Chrome prompts immediately.
    Falsifiable against the shared-identity cooldown (finding 1); with
    today's code both meetings carry the same `appName` so the second prompt
    is suppressed.

### Layer 2: ViewInspector (one wiring test per new control)

18. The Remove button on a deny-list row calls the store (assert the
    settings array write-back), located by its `A11yID` constant. One test
    per control kind, not per state; list-content logic (which rows appear)
    is layer 1 via `ConsentDenyList`.
19. The existing browser-toggle wiring test stays as is.

### Layer 3: `/state` live (e2e-browser lane)

20. `scripts/e2e-browser.sh` asserts `pendingConsentApp` equals the concrete
    `$BROWSER_LABEL` for whichever fork the lane drives. This is the live
    proof of per-process identity end to end and it fails against the shared
    identity by construction (the current script asserts the literal "Google
    Chrome" for every fork). The lane's existing notification and
    time-sensitive assertions are untouched. No new lane for a fifth fork in
    this plan (open item).

### Layer 4/5

No new `/ui/press` allowlist entries (the Remove buttons need no live
driving; their behaviour is fully falsifiable at layers 1 and 2). No
snapshots.

### TDD ordering

Per the repo rule, each behavioural commit starts with its failing test:
within each PR below, the listed tests land first (red against the current
code for exactly the reason named in each item), then the implementation
turns them green. Acceptance check per test: revert the implementation hunk,
the test goes red again. The two tests that pin traps rather than features
(5: consent flag on synthesis; 14: denial outlives the cooldown) must be
written before their implementation with particular care, since both traps
produce silently wrong behaviour rather than failures.

## Staging

Three PRs, in this order, each independently green and shippable:

1. **Per-process identity within the existing allowlist.** The `Identity`
   property with the browser pattern set to `.perProcess` (the allowlist
   stays populated), detector keying on the identity key, synthesis with the
   consent flag, liveness rule, per-process title matcher, the
   `browserMeetings` category rename, and the
   `e2e-browser.sh` assertion update. Tests 4, 5, 9 to 11, 17. This fixes review findings 1 to 5 while
   detection behaviour stays allowlist-bound, so the blast radius is the
   five known bugs, not the matching semantics.
2. **The deny list.** `ConsentAnswer.never`, the third notification action,
   the deny list + AppSettings persistence, the WatchLoop gate, the
   Settings review UI. Tests 6, 8, 13 to 16. Still allowlist-bound:
   Never is already useful for the four known browsers, and the machinery
   exists before anything unknown can prompt.
3. **Process-open matching.** Empty the browser pattern's `processNames`
   (identity is already `.perProcess` from PR 1), native-claim exclusion,
   diagnostic widening, docs/copy (README, CLAUDE.md, toggle caption).
   Tests 1 to 3, 7, 12 (the repurposed Firefox test). The smallest diff with the
   largest behavioural change, deliberately last: an Electron user who gets
   their first surprise prompt already has the Never button.

Rationale for a sequence over one PR: the ordering argument is safety-bearing
(process-open before Never would ship surprise prompts with no way to silence
them permanently), each PR maps to one reviewable concern, and the repo's
atomic-commit rule scales to PR scope here. Each PR is internally a series of
test-then-implementation commits per the TDD ordering.

PR #601 relationship: PR 3 makes fork-name additions permanently unnecessary,
and PR 1 removes the shared-identity bugs that #601 would otherwise inherit
for a fifth name. Whether to merge #601's one-string addition in the interim
is a maintainer call this plan does not make.

## What this does NOT do, and what stays open

- **No detection for browsers that do not emit the assertion.** A fork that
  never emits it is undetectable by this mechanism, and no log can show what
  IOKit never reports. Aside specifically is now verified: a field
  measurement during a real Google Meet call reported
  `pid 729(Aside): NoIdleSleepAssertion named: "WebRTC has active PeerConnections"`,
  so its assertion process name is exactly `Aside`. That says nothing about
  the next fork, which is the point of process-open matching.
- **No Firefox or Safari meeting detection.** Both are outside the Chromium
  content layer; Safari call audio capture is a separate, already-shipped
  concern.
- **No per-app auto-record.** Every non-denied app prompts per meeting, by
  design (the WebRTC signal is not meeting-exclusive). An explicit per-app
  "record without asking" setting would be a new feature with its own
  consent story, and it is where a positive per-app state (the dropped
  confirmed list) would return.
- **No diagnostic when the master toggle is off** (documented limitation,
  matches the MicInputDetector precedent).
- **No per-tab capture** (pre-existing known follow-up: recording captures
  all of the browser's audio).
- **No fifth-fork e2e lane.** Adding `--browser aside` to `e2e-browser.sh`
  requires the cask on the runner and an answer to the assertion-emission
  question first.
- **The stale-tab false positive stays.** Google Meet's un-joinable page
  still parks a prompt about no meeting at all; the cost remains one prompt,
  as documented for issue #503.
