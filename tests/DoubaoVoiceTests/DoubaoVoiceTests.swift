import AVFoundation
import XCTest
@testable import Doubao_Voice

final class DoubaoVoiceTests: XCTestCase {
    func testMicrophoneButtonRequestsOnceThenOpensSystemSettings() {
        XCTAssertEqual(
            PermissionCenter.microphoneRequestAction(for: .notDetermined),
            .requestAccess
        )
        XCTAssertEqual(
            PermissionCenter.microphoneRequestAction(for: .denied),
            .openSettings
        )
        XCTAssertEqual(
            PermissionCenter.microphoneRequestAction(for: .restricted),
            .openSettings
        )
        XCTAssertEqual(
            PermissionCenter.microphoneRequestAction(for: .authorized),
            .none
        )
    }

    func testLocalDistributionAlwaysHasAccess() {
        XCTAssertTrue(RecordingPolicy.hasAccess(localDistribution: true, isSubscribed: false))
        XCTAssertFalse(RecordingPolicy.hasAccess(localDistribution: false, isSubscribed: false))
        XCTAssertTrue(RecordingPolicy.hasAccess(localDistribution: false, isSubscribed: true))
    }

    func testRecordingDurationIsCappedAndNeverNegative() {
        XCTAssertEqual(RecordingPolicy.availableSeconds(localDistribution: true, subscriptionRemaining: 0), 120)
        XCTAssertEqual(RecordingPolicy.availableSeconds(localDistribution: false, subscriptionRemaining: 42), 42)
        XCTAssertEqual(RecordingPolicy.availableSeconds(localDistribution: false, subscriptionRemaining: 999), 120)
        XCTAssertEqual(RecordingPolicy.availableSeconds(localDistribution: false, subscriptionRemaining: -1), 0)
    }

    func testHotkeyBoundaryChoosesToggleOnlyBelow300Milliseconds() {
        XCTAssertTrue(RecordingPolicy.usesToggleMode(heldSeconds: 0.299))
        XCTAssertFalse(RecordingPolicy.usesToggleMode(heldSeconds: 0.3))
    }

    func testClipboardIsRestoredOnlyIfUserHasNotCopiedSomethingElse() {
        XCTAssertTrue(ClipboardRestorationPolicy.shouldRestore(currentChangeCount: 12, insertedChangeCount: 12))
        XCTAssertFalse(ClipboardRestorationPolicy.shouldRestore(currentChangeCount: 13, insertedChangeCount: 12))
    }

    func testDaemonEventDecoderCoversProtocolEvents() {
        guard case .started? = DaemonClient.decodeEvent(["event": "started"]) else {
            return XCTFail("started 解码失败")
        }
        guard case .level(let peak, let voiced)? = DaemonClient.decodeEvent([
            "event": "level", "peak": 4321, "voiced": true,
        ]) else {
            return XCTFail("level 解码失败")
        }
        XCTAssertEqual(peak, 4321)
        XCTAssertTrue(voiced)

        guard case .final(let text)? = DaemonClient.decodeEvent([
            "event": "final", "text": "测试成功",
        ]) else {
            return XCTFail("final 解码失败")
        }
        XCTAssertEqual(text, "测试成功")

        guard case .error(let message)? = DaemonClient.decodeEvent([
            "event": "error", "message": "断网",
        ]) else {
            return XCTFail("error 解码失败")
        }
        XCTAssertEqual(message, "断网")
        XCTAssertNil(DaemonClient.decodeEvent(["event": "future_event"]))
        XCTAssertNil(DaemonClient.decodeEvent([:]))
    }
}
