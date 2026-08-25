// Process entry point. SwiftUI's App.main() is a protocol requirement, so a
// conforming type cannot intercept its own launch without recursing into
// itself; this separate @main enum makes the one pre-launch decision — divert
// into the LocalVQE selftest probe (scripts/localvqe-bundle-check.sh) or
// start the GUI — before any app state is constructed.
import SwiftUI

@main
enum AppLauncher {
    // Invoked by the @main synthesis, which the analyzer cannot see.
    // swiftlint:disable:next unused_declaration
    static func main() {
        // The selftest exists for the Homebrew build's bundle check and is
        // compiled out of the App Store variant entirely, like the debug RPC
        // server. Where present it is reachable only via this explicit argv
        // flag; it constructs no app state and exits before the GUI starts.
        #if !APPSTORE
            if let mode = LocalVQESelftest.parse(arguments: CommandLine.arguments) {
                exit(LocalVQESelftest.run(mode))
            }
        #endif
        MeetingTranscriberApp.main()
    }
}
