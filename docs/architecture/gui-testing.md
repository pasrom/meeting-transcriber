# UI and GUI testing

View architecture, UI notes and how to test GUI behaviour at each layer.

**View architecture:**
- `SettingsView` receives its dependencies as stored properties (not `@State`): the engine instances, `updateChecker`, `recognitionStatsLog`, an `enrollmentDiarizerFactory`, the `namingDialogActive`/`pipelineBusy` state flags, and an `onSpeakerMutate` callback.

**UI:**
- `MenuBarIcon` renders animated waveform reflecting pipeline state (idle, recording, transcribing, diarizing, protocol).
- `AppPickerView` enables manual recording of any app via app picker.
- `UpdateChecker` checks GitHub releases for newer versions, shows badge on menu bar icon.
- **`SpeakerNamingView` keys the name fields and the expanded known-names rows by speaker label, never by row position (issue #700).** The name field is a plain SwiftUI `TextField`, which takes a fresh binding on every update. A binding captured by position goes stale when a surviving label moves to another sorted position: it writes the user's typing into another row and traps once `names` has fewer entries than that index (issue #702). **Which switch reproduces it was measured, and only one does:** switching between two still-pending jobs with the segmented picker keeps the fields, while *completing* the first job does not, because `speakerNamingPicker` is gated on `pendingSpeakerNamingJobs.count > 1` and dropping it changes the enclosing `VStack`'s structure, so SwiftUI rebuilds the form with fresh fields. A Re-run keeps the slot too. `SpeakerNamingFieldIdentityTests` hosts the view in a real `NSWindow` (ViewInspector cannot instantiate a reused field), locates each row by the seed value it shows, and proves the typed name reaches that row's binding by committing the edit (resigning first responder re-reads each field from its binding). `scripts/e2e-app.sh --naming-switch` drives the same switch in the shipped app. Both row-keyed values live in `SpeakerNamingRowState`, one `@Observable` object rather than two `@State` values, which is what lets `SpeakerNamingRowWritesTests` assert *which* row a chip tap or a "More…" press wrote to instead of only that the action ran.

## GUI Testing

Rule: test each behavior at the cheapest layer that can falsify it.

1. **Pure logic first.** Extract decision logic into a value type
   (`BadgeKind.compute`, `LiveCaptionsGate`, `WatchLoopEndPolicy` pattern) and put
   the bulk of assertions there.
2. **ViewInspector** (`swift test`, every PR): exactly one wiring test per control —
   find by its `A11yID` constant (see Identifiers), drive
   (`.tap()`/`.select()`/`.increment()`),
   assert the `AppSettings` write-back. Don't enumerate logic states through the view;
   that's layer 1's job. (ViewInspector is reflection over undocumented SwiftUI
   internals — keep to the boring primitives; breakage is loud since it runs on
   every PR.)
   **A tap that writes state the view keeps is assertable only when that state
   is a reference type** (a tap that calls a callback is assertable either way,
   and most are). The tap runs the action regardless, but a `@State` mutation
   lands in the copy SwiftUI made for that body evaluation, so the next
   `inspect()` still reads the old value. Hosting does not change that: measured with
   `ViewHosting.host` and with a real `NSHostingView` in a real window, both of
   which host a copy, and ViewInspector's own way around it wants an `Inspection`
   hook inside the view's body, which is a test-only affordance in shipping code.
   Where a form's mutable state is worth asserting, hold it in one `@Observable`
   object (`SpeakerNamingRowState` is the worked example) and the object the test
   holds is the object the action writes to. Without that, a chip or toggle test
   can only say the action ran, never where the write landed.
3. **`/state` (live RPC):** first choice for live assertions, including window/scene
   behavior via `/state.windows` (`isVisible` after deactivate, `floating`,
   `canJoinAllSpaces` — how #509/#511 guard the naming-window pin).
4. **`/ui/tree` + `/ui/press` + `/ui/type`** (live, Settings window only): only for behavior that
   exists solely in the real AppKit/AX layer. A live test earns its keep only when
   ViewInspector cannot instantiate the failing layer (real NSWindow/NSPanel,
   focus/activation, scene routing, the NSHostingView boundary, actual AX exposure).
5. **Snapshots** (dev-only, `XCTSkipIf(isCI)`): pixel truth; never CI-gated.

**Identifiers:** add `.accessibilityIdentifier` on demand via the shared `A11yID`
namespace (`Sources/A11yID.swift`) — the view modifier, the ViewInspector `find`, and
the `/ui/press` allowlist all reference the constant so the compiler catches drift.
Interaction tests locate by the `A11yID` constant, `Picker` and `Stepper`
included. Both are findable by an identifier attached to the control itself, in
two steps, because the lookup returns the modified view rather than the typed
control and the second `find` is what makes `select`/`increment` reachable:

```swift
let picker = try view.inspect()
    .find(viewWithAccessibilityIdentifier: A11yID.liveCaptionsSizePicker)
    .find(ViewType.Picker.self)
try picker.select(value: LiveCaptionsSize.small)
```

Measured under the pinned ViewInspector 0.10.3, and pinned by
`ViewInspectorIdentifierTests`: a `Picker` and a `Stepper` each carrying an
identifier are found and driven, and an unknown identifier throws, so the lookup
is not matching whatever it is handed. The label and document-order locators still in `SettingsInteractionTests` work, and they are not the shape to copy. `find(text:)` for a bare
label only when the label itself is the behavior under test. An identifier makes a control
tree-visible;
press-drivable *additionally* requires a `/ui/press` allowlist entry — never allowlist
a control whose action opens a menu/popover/sheet/panel (a nested runloop wedges the
app, see `DebugRPCServer+UIPress.swift`). Never widen the window allowlist to PII
windows or expose control values (`DebugRPCServer+UITree.swift`).

**Live assertions:** assert the `/state` effect, never the returned `pressed` flag or
tree structure (depth/frames/child counts). Assert the env-stable, load-bearing pin
subset (`isVisible`, `floating`, `canJoinAllSpaces`) — `fullScreenAuxiliary` proved
env-unstable on the CI mini (#511). `e2e-ui-smoke` is a harness-liveness canary only —
feature-level live assertions go in `test_rpc.sh` or the `e2e-app` lanes.

**GUI bug found:** failing test first, at the lowest layer that reproduces it. If only
the live scene reproduces, drive the real scene window (a minimal probe window does not
reproduce — #504). Acceptance: revert the fix, test goes red.

**Don't:** chase snapshot coverage; use `/ui/press` to arrange state (it's for testing
the pressed control); test SwiftUI framework behavior (e.g. that `.keyboardShortcut`
fires). **Manual-QA-only, accepted:** menu-bar dropdown interaction, modal panels
(NSOpenPanel/NSAlert), TCC prompts, drag/focus order, visual appearance beyond dev-only
snapshots.

**A self-pid accessibility tree is not a unit-test locator: it is empty behind
the lock screen.** Measured on macOS 26: with the screen locked, HIServices
answers every window query on the app's own `AXUIElement` with the application
element itself and serves no SwiftUI element, so a SwiftUI
`.accessibilityIdentifier` is unreachable there even though it is present when
unlocked; `NSApplication.finishLaunching()` does not change this, and neither the
backing `NSTextField` nor its cell ever carries the identifier. A unit test that
finds controls through the AX tree is green at an unlocked desk and red on an
unattended or locked runner. Locate hosted controls by their `NSView` state
instead (`SpeakerNamingFieldIdentityTests` finds a name field by the seed value
it shows). The AX identifier stays the contract for the out-of-process drivers
(`/ui/*`, `scripts/drive-naming-field.swift`), which run against a live, unlocked
app rather than xctest.

**Escape resists injection, and the reason shapes how Escape must be bound.** A
hand-built `NSEvent` with keycode 53 does not reach SwiftUI's `onExitCommand`:
tried via `NSWindow.sendEvent` in xctest, and in the live app via both
`NSWindow.sendEvent` and `NSApplication.sendEvent` with the window made key and
the app activated — all report a clean dispatch and change nothing. The
mechanism: keycode 53 becomes `cancelOperation:` only inside
`interpretKeyEvents:`, which only text-input responders call, so with no field
focused AppKit's fallback emits `cancel:` instead, which `onExitCommand` ignores.
Text injection works precisely because insertion *is* interpreted down there.
Consequence for product code, not just tests: `onExitCommand` alone gives you a
focus-dependent Escape, so a dialog that must always dismiss on Escape also needs
a `.keyboardShortcut(.cancelAction)` carrier, which rides the focus-independent
key-equivalent pass (`SpeakerNamingView.escapeDismissShortcut`). A physical Escape is
drivable only from outside the process, via a WindowServer keystroke: that is what
`scripts/e2e-app.sh --naming-escape` does, and it is why that lane (alone) needs an
Accessibility grant on the runner ("Device Control and Data Access" on macOS 27;
see the e2e-architecture skill, runner setup step 6). Below that layer, ViewInspector pins the handler
wiring and `/state` pins the resulting window/job state.

**Typing** is automatable via `POST /ui/type` (allowlisted plain text fields only —
never a `SecureField`). It posts real key events, because an AX set-value does *not*
fire the SwiftUI binding; that asymmetry is why there is no `/ui/setValue`. Pass
`clear: true` to replace rather than append, or the assertion depends on the field's
prior contents. Reaching a control outside the General tab needs a tab switch first,
and only `POST /ui/press` with `"via": "click"` performs one — the AX press reports
success on a sidebar row without selecting it.
