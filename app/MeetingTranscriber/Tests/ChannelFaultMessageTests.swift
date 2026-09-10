import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// What each channel fault tells the user to go and do.
///
/// Split out of `ChannelFaultIntegrationTests`, which covers when a fault is
/// reported at all. These pin the wording, and they are worth pinning because
/// every one of them stands for a claim that was made once, was wrong, and cost
/// somebody a search in the wrong place: a permission pane with nothing wrong in
/// it, a meeting app declared dead while it was still playing the call, a lever
/// named without an address.
@MainActor
final class ChannelFaultMessageTests: XCTestCase {
    func testTheFaultMessageDistinguishesTheChannel() {
        let appMessage = ChannelHealthController.faultMessage(
            channel: .app, fault: .noBuffers, everCarriedSignal: true,
        )
        let micMessage = ChannelHealthController.faultMessage(channel: .mic, fault: .noBuffers, everCarriedSignal: true)
        XCTAssertNotEqual(appMessage, micMessage)
        XCTAssertTrue(appMessage.lowercased().contains("app-audio"))
        XCTAssertTrue(micMessage.lowercased().contains("microphone"))
    }

    func testAnAppChannelSilentSinceTheStartStillPointsAtPermissionAndAudioTools() {
        // A tap that never carried a single non-zero sample is the signature of
        // a missing Screen & System Audio Recording grant (issue #524) or of a
        // third-party audio utility intercepting the meeting app's output. Both
        // stay named, because for this case they are the answer.
        let message = ChannelHealthController.faultMessage(
            channel: .app, fault: .digitalSilence, everCarriedSignal: false,
        )
        XCTAssertTrue(message.contains(SystemSettingsPaths.screenRecording))
        XCTAssertTrue(message.contains("SoundSource"))
    }

    func testAnAppTapThatCarriedAudioIsNotSentToThePermissionPane() {
        // The discriminator, and the whole point of the flag: a tap that is not
        // allowed to hear the app delivers zeroes from its first buffer and
        // never anything else. So a channel that carried audio and then went to
        // zeroes cannot be a permission problem, and sending the user to that
        // pane costs them the time it takes to find nothing wrong there.
        let message = ChannelHealthController.faultMessage(
            channel: .app, fault: .digitalSilence, everCarriedSignal: true,
        )
        XCTAssertFalse(
            message.contains(SystemSettingsPaths.screenRecording),
            "a tap that already worked is not missing a grant",
        )
        XCTAssertFalse(message.contains("SoundSource"))
        XCTAssertTrue(
            message.lowercased().contains("not a permission problem"),
            "and it says so, because the pane is where the user would look first",
        )
    }

    func testAStoppedAppTapIsNotBlamedOnAPermission() {
        // Buffers stopping entirely is a dead tap, not a denied one: a denied
        // tap still delivers, it delivers zeroes.
        let message = ChannelHealthController.faultMessage(
            channel: .app, fault: .noBuffers, everCarriedSignal: true,
        )
        XCTAssertFalse(message.contains(SystemSettingsPaths.screenRecording))
    }

    func testTheRecoverableAppFaultsNameTheOutputDeviceLever() {
        // A default-output device change is the only thing that rebuilds the
        // tap today, and it is the only remedy a user can apply mid-meeting
        // without splitting the recording in two.
        for carried in [true, false] {
            let stopped = ChannelHealthController.faultMessage(
                channel: .app, fault: .noBuffers, everCarriedSignal: carried,
            )
            XCTAssertTrue(stopped.lowercased().contains("output device"), "noBuffers/\(carried)")
        }
        let wentSilent = ChannelHealthController.faultMessage(
            channel: .app, fault: .digitalSilence, everCarriedSignal: true,
        )
        XCTAssertTrue(wentSilent.lowercased().contains("output device"))
    }

    func testTheStoppedTapMessageClaimsNothingAboutPermissionsOrTheMicrophone() {
        // Two claims this message must not make, both of which it made once and
        // both of which were lost again without a single test going red.
        //
        // It must not say a permission cannot cause a stopped IOProc. What
        // issue #524 measured is a tap denied from the start, which delivers
        // zeroes rather than nothing, and ChannelFault.noBuffers still lists a
        // mid-recording revocation as a possible cause.
        //
        // And it must not mention the microphone. Unlike digitalSilence, this
        // fault is reported without corroboration from the other channel, and
        // an app-only recording has no microphone at all.
        for carried in [true, false] {
            let message = ChannelHealthController.faultMessage(
                channel: .app, fault: .noBuffers, everCarriedSignal: carried,
            ).lowercased()
            XCTAssertFalse(message.contains("permission"), "noBuffers/\(carried)")
            XCTAssertFalse(message.contains("microphone"), "noBuffers/\(carried)")
        }
    }

    func testTheActionableAppMessagesLeadWithWhatToDo() {
        // A notification banner shows a line or two and truncates the rest, so a
        // remedy at the end of a long diagnosis is a remedy nobody reads. The
        // longest of these ran to 522 characters with the lever in the last
        // sentence. The bound is deliberately loose: it pins the ordering, not
        // the wording.
        let actionable: [(ChannelFault, Bool)] = [
            (.noBuffers, true), (.noBuffers, false), (.digitalSilence, true),
        ]
        for (fault, carried) in actionable {
            let message = ChannelHealthController.faultMessage(
                channel: .app, fault: fault, everCarriedSignal: carried,
            )
            let lever = try? XCTUnwrap(message.range(of: "output device"), "\(fault)/\(carried)")
            guard let lever else { continue }
            let offset = message.distance(from: message.startIndex, to: lever.lowerBound)
            XCTAssertLessThan(offset, 150, "the remedy must survive truncation: \(fault)/\(carried)")
        }
    }

    func testTheMicMessagesDoNotDependOnWhetherTheChannelCarriedAudio() {
        // The flag answers an app-tap question. The microphone's two faults
        // already send the user to the right place and must not start varying.
        for fault in [ChannelFault.noBuffers, .digitalSilence] {
            XCTAssertEqual(
                ChannelHealthController.faultMessage(channel: .mic, fault: fault, everCarriedSignal: true),
                ChannelHealthController.faultMessage(channel: .mic, fault: fault, everCarriedSignal: false),
                "\(fault)",
            )
        }
    }

    func testTheTwoMicFaultsSendTheUserToDifferentPlaces() {
        // A device that stopped answering and a device that is muted are
        // different things to go and fix.
        let stopped = ChannelHealthController.faultMessage(channel: .mic, fault: .noBuffers, everCarriedSignal: true)
        let muted = ChannelHealthController.faultMessage(channel: .mic, fault: .digitalSilence, everCarriedSignal: true)
        XCTAssertNotEqual(stopped, muted)
        XCTAssertTrue(muted.lowercased().contains("mute"))
        XCTAssertTrue(stopped.lowercased().contains("connected"))
    }
}
