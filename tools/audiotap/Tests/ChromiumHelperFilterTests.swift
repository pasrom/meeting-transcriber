@testable import AudioTapLib
import XCTest

/// Pins the helper selection of issue #791; the measurement behind it is on
/// `ChromiumHelperFilter`.
final class ChromiumHelperFilterTests: XCTestCase {
    /// Comet during a call: root 100, audio service 200, video-capture
    /// service 300, a renderer 400 and the GPU process 500.
    private let comet: [pid_t: [String]] = [
        100: ["/Applications/Comet.app/Contents/MacOS/Comet"],
        200: [
            "/Applications/Comet.app/Contents/Frameworks/Comet Framework.framework/Helpers/Comet Helper.app/Contents/MacOS/Comet Helper",
            "--type=utility", "--utility-sub-type=audio.mojom.AudioService", "--lang=en-US",
        ],
        300: [
            "/Applications/Comet.app/Contents/Frameworks/Comet Framework.framework/Helpers/Comet Helper.app/Contents/MacOS/Comet Helper",
            "--type=utility", "--utility-sub-type=video_capture.mojom.VideoCaptureService",
        ],
        400: ["Comet Helper (Renderer)", "--type=renderer", "--lang=en-US"],
        500: ["Comet Helper (GPU)", "--type=gpu-process"],
    ]

    /// Empty for a PID outside the tree, which is what the live reader
    /// returns for a process the kernel will not describe.
    private func cometArguments(_ pid: pid_t) -> [String] {
        comet[pid] ?? []
    }

    // MARK: - role

    func testRootWithoutTypeFlagIsNotAChild() {
        XCTAssertEqual(ChromiumHelperFilter.role(of: cometArguments(100)), .notAChild)
        XCTAssertEqual(ChromiumHelperFilter.role(of: []), .notAChild, "an unreadable argv carries no --type= either")
    }

    func testAudioServiceRoleNeedsBothFlags() {
        XCTAssertEqual(ChromiumHelperFilter.role(of: cometArguments(200)), .audioService)
        XCTAssertEqual(ChromiumHelperFilter.role(of: cometArguments(300)), .otherChild)
        XCTAssertEqual(ChromiumHelperFilter.role(of: cometArguments(400)), .otherChild)
        XCTAssertEqual(ChromiumHelperFilter.role(of: cometArguments(500)), .otherChild)
        XCTAssertEqual(
            ChromiumHelperFilter.role(of: ["Helper", "--utility-sub-type=audio.mojom.AudioService"]),
            .notAChild,
            "the sub-type alone is not a Chromium child; only --type= marks one",
        )
        XCTAssertEqual(
            ChromiumHelperFilter.role(of: ["Helper", "--type=renderer", "--utility-sub-type=audio.mojom.AudioService"]),
            .otherChild,
        )
    }

    // MARK: - selection

    func testDropsTheVideoCaptureServiceNextToTheAudioService() {
        // The measured failing set of #791: root + audio + video capture.
        let selection = ChromiumHelperFilter.select([100, 200, 300], arguments: cometArguments)
        XCTAssertEqual(selection.kept, [100, 200], "the video-capture service must not be in the tap")
        XCTAssertEqual(selection.dropped, [300])
    }

    func testKeepsOnlyRootAndAudioServiceFromTheWholeHelperTree() {
        let selection = ChromiumHelperFilter.select([100, 400, 300, 200, 500], arguments: cometArguments)
        XCTAssertEqual(selection.kept, [100, 200], "order is the caller's: the root stays first for the aggregate name tag")
        XCTAssertEqual(selection.dropped, [400, 300, 500])
    }

    func testLeavesTheSetAloneWithoutAnAudioService() {
        // A Chromium that has not spawned its audio service yet, or runs audio
        // in-process: no helper is known to be the renderer, so none is dropped.
        let selection = ChromiumHelperFilter.select([100, 300, 400], arguments: cometArguments)
        XCTAssertEqual(selection.kept, [100, 300, 400])
        XCTAssertTrue(selection.dropped.isEmpty)
    }

    func testLeavesNativeAndWebKitProcessesAlone() {
        // Safari and its WebKit XPC helper carry no --type= flag.
        let safari: [pid_t: [String]] = [
            707: ["/Applications/Safari.app/Contents/MacOS/Safari"],
            2032: ["/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"],
        ]
        let selection = ChromiumHelperFilter.select([707, 2032]) { safari[$0] ?? [] }
        XCTAssertEqual(selection.kept, [707, 2032])
        XCTAssertTrue(selection.dropped.isEmpty)
    }

    func testKeepsAProcessWhoseArgumentsCannotBeRead() {
        // 999 is a process the kernel will not describe: no opinion, so it
        // stays, even though an audio service was found.
        let selection = ChromiumHelperFilter.select([100, 200, 300, 999], arguments: cometArguments)
        XCTAssertEqual(selection.kept, [100, 200, 999])
        XCTAssertEqual(selection.dropped, [300])
    }

    func testKeepsANativeModuleHostNextToTheAudioService() {
        // New Teams: a WebView2 audio service for the shell, while the call
        // media engine runs in a native helper with its own --process_type=
        // flag, not Chromium's --type=. The helper must stay in the tap.
        var tree = comet
        tree[600] = ["Microsoft Teams ModuleHost", "--process_type=native_module", "--module_name=SlimCore"]
        let selection = ChromiumHelperFilter.select([100, 200, 300, 600]) { tree[$0] ?? [] }
        XCTAssertEqual(selection.kept, [100, 200, 600])
        XCTAssertEqual(selection.dropped, [300])
    }

    func testKeepsEveryAudioServiceWhenThereAreSeveral() {
        // Two Chromium apps grouped under one root is not a real layout, but
        // two audio services must both stay rather than the first winning.
        var tree = comet
        tree[600] = ["Helper", "--type=utility", "--utility-sub-type=audio.mojom.AudioService"]
        let selection = ChromiumHelperFilter.select([100, 200, 300, 600]) { tree[$0] ?? [] }
        XCTAssertEqual(selection.kept, [100, 200, 600])
    }

    // MARK: - KERN_PROCARGS2 layout

    private func procargs2(argc: Int32, executable: String, arguments: [String], environment: [String]) -> [UInt8] {
        var bytes = withUnsafeBytes(of: argc) { Array($0) }
        bytes += Array(executable.utf8) + [0, 0, 0]
        for argument in arguments {
            bytes += Array(argument.utf8) + [0]
        }
        for entry in environment {
            bytes += Array(entry.utf8) + [0]
        }
        return bytes
    }

    func testParsesArgumentsAfterTheExecutablePathAndPadding() {
        let bytes = procargs2(
            argc: 3,
            executable: "/Applications/Comet.app/Contents/MacOS/Comet Helper",
            arguments: ["Comet Helper", "--type=utility", "--utility-sub-type=audio.mojom.AudioService"],
            environment: ["HOME=/Users/x", "--type=renderer"],
        )
        XCTAssertEqual(
            ProcessArguments.parse(procargs2: bytes),
            ["Comet Helper", "--type=utility", "--utility-sub-type=audio.mojom.AudioService"],
            "the environment after argv must not be read as arguments",
        )
    }

    func testRejectsABufferShortOfItsArgumentCount() {
        let bytes = procargs2(argc: 3, executable: "/bin/x", arguments: ["x", "--type=utility"], environment: [])
        XCTAssertTrue(ProcessArguments.parse(procargs2: bytes).isEmpty, "a truncated read must not pass as complete")
        XCTAssertTrue(ProcessArguments.parse(procargs2: []).isEmpty)
    }

    func testReadsTheOwnProcessArguments() {
        // The one live read a unit test can make: xctest's own argv, which
        // starts with its executable.
        XCTAssertEqual(ProcessArguments.live(getpid()).first, CommandLine.arguments.first)
    }

    func testAProcessTheKernelWillNotDescribeReadsAsNoOpinion() throws {
        // launchd belongs to root; KERN_PROCARGS2 refuses another user's
        // process with EINVAL. Root would be allowed to read it.
        try XCTSkipIf(geteuid() == 0, "running as root, every process is readable")
        XCTAssertTrue(ProcessArguments.live(1).isEmpty)
    }
}
