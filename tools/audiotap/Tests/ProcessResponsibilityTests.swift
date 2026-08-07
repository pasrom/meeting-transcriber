@testable import AudioTapLib
import XCTest

/// Covers the responsible-app grouping that lets an app-audio tap reach a
/// browser's out-of-bundle helpers.
///
/// The bug these guard: `pidsRooted(in: Safari.app)` returns Safari's main
/// process alone, because WebKit's GPU and WebContent services live under
/// `/System/Library/Frameworks`. Tapping that set records silence — the audio
/// is produced by the helper, not by Safari itself.
final class ProcessResponsibilityTests: XCTestCase {
    /// Safari (707) with two WebKit helpers, plus an unrelated app and its own
    /// helper. Only processes CoreAudio knows about are candidates.
    private let responsible: [pid_t: pid_t] = [
        707: 707, 2032: 707, 2273: 707,
        999: 999, 4081: 999,
    ]

    private func lookup(_ pid: pid_t) -> pid_t {
        responsible[pid] ?? 0
    }

    // MARK: - grouping

    func testGroupsEveryAudioCapableHelperUnderItsResponsibleApp() {
        let pids = ProcessResponsibility.audioPIDsResponsible(
            to: 707,
            audioCapable: { [707, 2032, 2273, 999, 4081] },
            responsibleFor: lookup,
        )
        XCTAssertEqual(pids, [707, 2032, 2273])
    }

    func testExcludesAnotherAppsHelperSharingTheSameBundlePath() {
        // The precise failure of bundle-path enumeration: every app's WebKit
        // helpers share a prefix under /System/Library/Frameworks.
        let pids = ProcessResponsibility.audioPIDsResponsible(
            to: 707,
            audioCapable: { [707, 2032, 4081, 999] },
            responsibleFor: lookup,
        )
        XCTAssertFalse(pids.contains(4081), "another app's helper must not be tapped")
        XCTAssertFalse(pids.contains(999))
    }

    func testIgnoresProcessesCoreAudioDoesNotKnowAbout() {
        // A Metal shader compiler or speech-synthesis service can share the
        // responsible app without ever being tappable.
        let pids = ProcessResponsibility.audioPIDsResponsible(
            to: 707,
            audioCapable: { [707] },
            responsibleFor: lookup,
        )
        XCTAssertEqual(pids, [707])
    }

    func testOwnerZeroYieldsNothingRatherThanEverything() {
        let pids = ProcessResponsibility.audioPIDsResponsible(
            to: 0,
            audioCapable: { [1, 2, 3] },
            responsibleFor: { _ in 0 },
        )
        XCTAssertTrue(pids.isEmpty)
    }

    // MARK: - tapPIDs composition

    func testWidensTheBundleSetWithTheAppsAudioHelpers() {
        let pids = ProcessResponsibility.tapPIDs(
            rootPID: 707,
            bundleDerived: [707],
            responsibleFor: lookup,
        ) { [707, 2032, 2273] }
        XCTAssertEqual(pids, [707, 2032, 2273], "the helper producing audio must be tapped")
    }

    func testDoesNotWidenForAProcessAttributedToItsLauncher() {
        // A shell- or script-launched process is attributed to the LAUNCHER.
        // Widening there would tap whatever audio-capable processes happen to
        // share that launcher — a terminal that played a sound, a media tool
        // from the same shell — instead of the target app.
        let launcher: pid_t = 500
        let attributedToLauncher: (pid_t) -> pid_t = { _ in launcher }
        let pids = ProcessResponsibility.tapPIDs(
            rootPID: 4242,
            bundleDerived: [4242],
            responsibleFor: attributedToLauncher,
        ) { [4242, 6001, 6002] }
        XCTAssertEqual(pids, [4242], "must not widen to the launcher's other audio processes")
    }

    func testFallsBackToTheBundleSetWhenResponsibilityIsUnavailable() {
        let noOpinion: (pid_t) -> pid_t = { _ in 0 }
        let pids = ProcessResponsibility.tapPIDs(
            rootPID: 707,
            bundleDerived: [707, 708],
            responsibleFor: noOpinion,
        ) { [707, 2032] }
        XCTAssertEqual(pids, [707, 708], "no opinion must leave today's behaviour untouched")
    }

    func testDoesNotDuplicatePIDsPresentInBothSets() {
        let pids = ProcessResponsibility.tapPIDs(
            rootPID: 707,
            bundleDerived: [707, 2032],
            responsibleFor: lookup,
        ) { [707, 2032, 2273] }
        XCTAssertEqual(pids, [707, 2032, 2273])
        XCTAssertEqual(Set(pids).count, pids.count)
    }

    func testPreservesBundleOrderingSoTheAggregateNameTagIsStable() {
        // resolveTapPIDs documents root-first ordering as load-bearing for the
        // aggregate device's name tag (#84); widening must append, not reorder.
        let pids = ProcessResponsibility.tapPIDs(
            rootPID: 707,
            bundleDerived: [707, 2273],
            responsibleFor: lookup,
        ) { [707, 2032, 2273] }
        XCTAssertEqual(pids.first, 707)
    }
}
