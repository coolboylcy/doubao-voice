import XCTest

final class VoiceDoggoUITests: XCTestCase {
    /// 设置页要能打开，且该有的几块都在。
    ///
    /// 这条测试默认不跑：XCUITest 的 runner 需要自动化权限，无人值守时会卡在
    /// 「Timed out while enabling automation mode」。verify-release.sh 里用
    /// VERIFY_UI_TESTS=1 显式开启，并在跳过时打印提示。
    @MainActor
    func testSettingsWindowShowsEverythingUserNeeds() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        let settings = app.windows["语音狗子设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))

        // 标题区
        XCTAssertTrue(app.staticTexts["语音狗子"].exists)
        XCTAssertTrue(app.staticTexts["macOS 全局语音输入 · 离线识别"].exists)

        // 快捷键：新用户装完最需要知道的事
        XCTAssertTrue(app.staticTexts["快捷键"].exists)
        XCTAssertTrue(app.staticTexts["按住说话，松手上屏"].exists)

        // 权限三项
        XCTAssertTrue(app.staticTexts["权限状态"].exists)
        for permission in ["麦克风", "辅助功能", "输入监控"] {
            XCTAssertTrue(app.staticTexts[permission].exists, "缺少权限项：\(permission)")
        }

        // 识别服务必须说明是本机离线——这是这个 App 最重要的卖点
        XCTAssertTrue(app.staticTexts["识别服务"].exists)
        XCTAssertTrue(app.staticTexts["本机离线识别"].exists)

        XCTAssertTrue(app.staticTexts["启动行为"].exists)

        // 本地版不该出现任何订阅/额度字样
        XCTAssertFalse(app.staticTexts["本周期用量"].exists)
        XCTAssertFalse(app.staticTexts["订阅 Pro"].exists)

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "语音狗子设置页"
        attachment.lifetime = .keepAlways
        add(attachment)

        settings.buttons[XCUIIdentifierCloseWindow].click()
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    }
}
