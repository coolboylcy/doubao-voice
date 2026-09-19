import AVFoundation
import XCTest
@testable import Voice_Doggo

final class VoiceDoggoTests: XCTestCase {
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

    /// 引导顺序不是随手排的：麦克风能在 App 内弹窗解决，另外两项必须把人送进
    /// 系统设置。最省事的排第一，用户第一步就有正反馈。改顺序前先想清楚这点。
    func testGuidedSetupStartsWithTheOnlyStepThatNeedsNoSystemSettings() {
        XCTAssertEqual(PermissionCenter.Step.allCases.first, .microphone)
        XCTAssertFalse(PermissionCenter.Step.microphone.needsManualToggle)
        XCTAssertTrue(PermissionCenter.Step.inputMonitoring.needsManualToggle)
        XCTAssertTrue(PermissionCenter.Step.accessibility.needsManualToggle)
    }

    /// 只有输入监控要求重启。这个标记决定引导会不会在那一步停下来等用户重开
    /// App——标错了，引导要么白等到超时，要么连弹两次系统设置。
    func testOnlyInputMonitoringRequiresRestart() {
        XCTAssertTrue(PermissionCenter.Step.inputMonitoring.requiresRestart)
        XCTAssertFalse(PermissionCenter.Step.microphone.requiresRestart)
        XCTAssertFalse(PermissionCenter.Step.accessibility.requiresRestart)
    }

    /// tccutil 的服务名跟枚举名对不上（输入监控叫 ListenEvent）。写错的话
    /// 「重置授权」会静默少重置一项，症状跟没点一样。
    func testTCCServiceNamesMatchWhatTccutilExpects() {
        XCTAssertEqual(PermissionCenter.Step.microphone.tccService, "Microphone")
        XCTAssertEqual(PermissionCenter.Step.inputMonitoring.tccService, "ListenEvent")
        XCTAssertEqual(PermissionCenter.Step.accessibility.tccService, "Accessibility")
    }

    /// 只有麦克风分得清「没问过」和「问过被拒」。另外两项 App 读不到这个区别，
    /// 谎称读得到会让引导走进一条永远送用户去设置页的死路。
    func testOnlyMicrophoneCanReportExplicitDenial() {
        XCTAssertFalse(PermissionCenter.isExplicitlyDenied(.inputMonitoring))
        XCTAssertFalse(PermissionCenter.isExplicitlyDenied(.accessibility))
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

// MARK: - 回归测试
//
// 下面每一条都对应一个真实踩过的 bug：全都是「静默失败」，从现象反推源头
// 的代价极高，所以固化下来防止倒退。

final class HotkeyFlagsTests: XCTestCase {
    /// 曾经用 CGEventSource.keyState 在 tap 回调里查键盘状态，而 headInsert 的
    /// 回调发生在事件进入系统之前，按下读到 false、松开读到 true，热键全程静默。
    func testRightOptionReadFromEventFlagsNotGlobalKeyboardState() {
        // 实测抓到的真实 flags：按下 0x80140，松开 0x100
        XCTAssertTrue(GlobalHotkeyMonitor.isRightOptionHeld(flags: 0x80140))
        XCTAssertFalse(GlobalHotkeyMonitor.isRightOptionHeld(flags: 0x100))
    }

    /// 左 Option 是 0x20，不能把它误判成右 Option——否则左 Option 也会触发录音。
    func testLeftOptionDoesNotTriggerRightOption() {
        let leftOptionOnly: UInt64 = 0x80120
        XCTAssertFalse(GlobalHotkeyMonitor.isRightOptionHeld(flags: leftOptionOnly))
        // 两个 Option 同时按住时，右 Option 仍须判为按下
        XCTAssertTrue(GlobalHotkeyMonitor.isRightOptionHeld(flags: 0x80160))
    }
}

final class CancellableSleepTests: XCTestCase {
    /// 核心回归：被取消的 Task 必须让调用方能看出来。
    /// 原来写成 `try? await Task.sleep`，CancellationError 被吞掉，取消后代码
    /// 照常执行——静音定时器因此把每一次正常录音都掐断了。
    func testCancelledSleepReportsIncomplete() async {
        let started = expectation(description: "task 已进入 sleep")
        let finished = expectation(description: "task 已结束")
        var completedNormally: Bool?

        let task = Task {
            started.fulfill()
            let ok = await Sleep.completed(for: .seconds(30))
            completedNormally = ok
            finished.fulfill()
        }

        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await fulfillment(of: [finished], timeout: 2)

        XCTAssertEqual(completedNormally, false, "被取消却报告睡满了，调用方会继续执行后续动作")
    }

    func testUncancelledSleepReportsCompleted() async {
        let ok = await Sleep.completed(for: .milliseconds(10))
        XCTAssertTrue(ok)
    }
}

@MainActor
final class ClipboardSnapshotTests: XCTestCase {
    /// 原来直接留存 pasteboardItems 的原对象再 writeObjects 回去。
    /// NSPasteboardItem 归原 pasteboard 所有，二次写入抛 ObjC 异常 → SIGABRT，
    /// 而且崩在识别成功之后，表现成「第一段好用、第二段按键没反应」。
    func testRestoringSnapshotDoesNotCrashAndKeepsContent() {
        let pasteboard = NSPasteboard(name: .init("VoiceDoggoTest.restore"))
        pasteboard.clearContents()
        pasteboard.setString("原始内容", forType: .string)

        let snapshot = AppModel.snapshotPasteboard(pasteboard)
        XCTAssertEqual(snapshot.count, 1)

        pasteboard.clearContents()
        pasteboard.setString("识别结果", forType: .string)
        XCTAssertEqual(pasteboard.string(forType: .string), "识别结果")

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects(snapshot), "快照必须能写回，否则恢复剪贴板就会崩")
        XCTAssertEqual(pasteboard.string(forType: .string), "原始内容")
    }

    /// 快照必须是深拷贝：clearContents 之后仍然拿得到数据。
    func testSnapshotSurvivesClearContents() {
        let pasteboard = NSPasteboard(name: .init("VoiceDoggoTest.deepcopy"))
        pasteboard.clearContents()
        pasteboard.setString("会被清掉", forType: .string)

        let snapshot = AppModel.snapshotPasteboard(pasteboard)
        pasteboard.clearContents()

        XCTAssertEqual(snapshot.first?.string(forType: .string), "会被清掉")
    }

    func testEmptyPasteboardYieldsEmptySnapshot() {
        let pasteboard = NSPasteboard(name: .init("VoiceDoggoTest.empty"))
        pasteboard.clearContents()
        XCTAssertTrue(AppModel.snapshotPasteboard(pasteboard).isEmpty)
    }
}

final class LowGainDetectionTests: XCTestCase {
    /// 系统输入音量过低时 FunASR 静默返回空，用户只看到「没有听到内容」，
    /// 完全无从判断是自己没说话还是麦克风增益不够。
    func testLowGainIsDistinguishedFromSilence() {
        // 实测：输入音量 37% 时整段峰值约 1300，识别必空
        XCTAssertTrue(RecordingPolicy.isLikelyLowGain(sessionPeak: 1310))
        // 调到 85% 后平均 2000+、峰值近万，属于正常
        XCTAssertFalse(RecordingPolicy.isLikelyLowGain(sessionPeak: 9780))
        // 完全没有音频数据不算低增益——那是另一类故障，不该误导用户去调音量
        XCTAssertFalse(RecordingPolicy.isLikelyLowGain(sessionPeak: 0))
    }
}
