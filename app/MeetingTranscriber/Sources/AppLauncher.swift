// Process entry point. SwiftUI's App.main() is a protocol requirement, so a
// conforming type cannot intercept its own launch without recursing into
// itself; this separate @main enum makes the one pre-launch decision — divert
// into the LocalVQE selftest probe (scripts/localvqe-bundle-check.sh) or
// start the GUI — before any app state is constructed.
import SwiftUI

@main
enum AppLauncher {
    /// What the previous run left behind, read by `main()` as it takes the
    /// marker over and reported by `MeetingTranscriberApp.init` once the
    /// notification centre is set up (issue #703). `.clean` until `main()`
    /// has run, which is also what a unit test sees: xctest never enters it.
    @MainActor private(set) static var previousExit: PreviousExit = .clean

    // Invoked by the @main synthesis, which the analyzer cannot see, so the
    // analyzer needs the disable. It rides the declaration's own line: as a
    // `disable:next` above the `@MainActor` attribute it would protect the
    // attribute instead, leaving `main()` unguarded and the command itself
    // superfluous, which `swiftlint analyze` reports as two violations.
    @MainActor
    static func main() { // swiftlint:disable:this unused_declaration
        // The selftest exists for the Homebrew build's bundle check and is
        // compiled out of the App Store variant entirely, like the debug RPC
        // server. Where present it is reachable only via this explicit argv
        // flag; it constructs no app state and exits before the GUI starts.
        #if !APPSTORE
            if let mode = LocalVQESelftest.parse(
                arguments: CommandLine.arguments, bundledModel: LocalVQEModel.resolve().path,
            ) {
                exit(LocalVQESelftest.run(mode))
            }
        #endif
        // Before anything else is constructed. `MeetingTranscriberApp.main()`
        // builds `AppState` as a stored-property initialiser, and that is the
        // heavy part of launch (engines, the pipeline queue with its crash
        // recovery, model warm-up): a crash in there is the crashiest way to
        // stay down, and it has to leave a marker like any other. xctest
        // never enters this function, so no test process writes a marker the
        // next real launch would read as a crash.
        previousExit = LivenessMarker.arm()
        MeetingTranscriberApp.main()
    }
}
