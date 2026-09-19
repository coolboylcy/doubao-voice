import XCTest

final class DoubaoVoiceUITests: XCTestCase {
    @MainActor
    func testFirstRunSettingsAndMenuBarAreUsable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        print(app.debugDescription)
        XCTAssertTrue(app.staticTexts["Doubao Voice"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["macOS 全局语音输入"].exists)
        XCTAssertTrue(app.staticTexts["Doubao Voice 本地版"].exists)
        XCTAssertTrue(app.staticTexts["离线识别已激活 · 音频不会发送到云端"].exists)
        XCTAssertTrue(app.staticTexts["FunASR 本地模型已随 App 安装，可离线使用"].exists)
        XCTAssertTrue(app.staticTexts["权限状态"].exists)
        XCTAssertTrue(app.staticTexts["麦克风"].exists)
        XCTAssertTrue(app.staticTexts["辅助功能"].exists)
        XCTAssertTrue(app.staticTexts["输入监控"].exists)
        XCTAssertTrue(app.staticTexts["启动行为"].exists)

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Doubao Voice 本地版设置页"
        attachment.lifetime = .keepAlways
        add(attachment)

        let settingsWindow = app.windows["Doubao Voice 设置"]
        XCTAssertTrue(settingsWindow.exists)
        settingsWindow.buttons[XCUIIdentifierCloseWindow].click()

        let statusMenuBar = app.menuBars.element(boundBy: 1)
        XCTAssertTrue(statusMenuBar.exists)
        let statusItem = statusMenuBar.descendants(matching: .any).firstMatch
        XCTAssertTrue(statusItem.exists)
        statusItem.click()
        XCTAssertTrue(app.descendants(matching: .any)["开始听写"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["设置与订阅"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["退出 Doubao Voice"].exists)

        // 菜单栏 App 必须保持可响应，并能在退出时干净结束。
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 2) || app.state == .runningBackground)
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    }
}
