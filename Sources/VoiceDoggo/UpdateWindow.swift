import AppKit
import SwiftUI

/// 更新提示窗口：狗子来要更新。
///
/// 做成一个小窗口而不是 NSAlert，就是为了能把狗放进来。一个自动更新提示本质上
/// 是在打断用户干活，让它可爱一点是这个 App 该有的样子——但也就到此为止：
/// 「以后再说」和「跳过这版」始终在，不做那种把关闭按钮藏起来逼人更新的事。
struct UpdateWindowView: View {
    @ObservedObject var updater: UpdateChecker
    let release: UpdateChecker.Release

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                // 说话那帧最像在「跟你商量」，比端坐的姿势有戏
                Image("MascotFrame4")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 92, height: 92)

                VStack(alignment: .leading, spacing: 7) {
                    Text(headline)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(UpdatePalette.title)
                    Text("v\(updater.currentVersion) → v\(release.version)")
                        .font(.system(size: 12))
                        .foregroundStyle(UpdatePalette.hint)
                    Text(subline)
                        .font(.system(size: 13))
                        .foregroundStyle(UpdatePalette.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 16)

            if !highlights.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(highlights, id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Circle()
                                .fill(UpdatePalette.accent)
                                .frame(width: 4, height: 4)
                                .offset(y: -2)
                            Text(line)
                                .font(.system(size: 12.5))
                                .foregroundStyle(UpdatePalette.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.bottom, 16)
            }

            statusArea
                .padding(.horizontal, 22)

            Divider()
            buttons
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
        }
        .frame(width: 430)
        .background(UpdatePalette.surface)
    }

    // MARK: - 文案

    private var headline: String {
        switch updater.phase {
        case .downloading: return "狗子正在叼新版本回来…"
        case .verifying: return "闻一闻，确认是正品…"
        case .readyToRestart: return "叼回来了，这就换上"
        case .failed: return "没叼回来，抱歉"
        default: return "有新版本啦，让我换上好不好"
        }
    }

    private var subline: String {
        switch updater.phase {
        case .downloading: return "在下载安装包，别关我。"
        case .verifying: return "正在核对 Apple 的公证签名，确认这个包没被人动过。"
        case .readyToRestart: return "语音狗子马上重开一次，几秒钟就好。"
        case .failed(let message): return message
        default: return "更新只要几秒钟，换完自动回来，不打断你手上的事。"
        }
    }

    /// 从发布说明里挑几条能读的出来。
    ///
    /// 直接把整段 markdown 塞进窗口会很难看——发布说明里有标题、链接、代码块。
    /// 这里只取列表项和短句，最多三条，剩下的交给「查看完整说明」。
    private var highlights: [String] {
        guard case .available = updater.phase else { return [] }
        return release.notes
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard line.count > 4, line.count < 60 else { return false }
                guard !line.hasPrefix("#"), !line.hasPrefix("```"), !line.hasPrefix("---") else { return false }
                return line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("**")
            }
            .prefix(3)
            .map { line in
                line
                    .replacingOccurrences(of: "**", with: "")
                    .replacingOccurrences(of: "- ", with: "")
                    .replacingOccurrences(of: "* ", with: "")
            }
    }

    @ViewBuilder
    private var statusArea: some View {
        switch updater.phase {
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 5) {
                ProgressView(value: progress)
                    .tint(UpdatePalette.accent)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11))
                    .foregroundStyle(UpdatePalette.hint)
            }
            .padding(.bottom, 14)
        case .verifying, .readyToRestart:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 14)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 10) {
            switch updater.phase {
            case .downloading, .verifying, .readyToRestart:
                Spacer()
                Text("请稍候…")
                    .font(.system(size: 12))
                    .foregroundStyle(UpdatePalette.hint)
            case .failed:
                Button("查看发布页") { NSWorkspace.shared.open(release.pageURL) }
                Spacer()
                Button("关掉") { updater.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("再试一次") { updater.install(release) }
                    .keyboardShortcut(.defaultAction)
            default:
                Button("跳过这版") { updater.skip(release) }
                Spacer()
                Button("以后再说") { updater.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("好，换上") { updater.install(release) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private enum UpdatePalette {
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static let accent = Color(red: 22 / 255, green: 119 / 255, blue: 1)
    static let surface = dynamic(
        light: NSColor(red: 248 / 255, green: 250 / 255, blue: 253 / 255, alpha: 1),
        dark: NSColor(red: 32 / 255, green: 34 / 255, blue: 39 / 255, alpha: 1)
    )
    static let title = dynamic(
        light: NSColor(red: 26 / 255, green: 31 / 255, blue: 39 / 255, alpha: 1),
        dark: .white
    )
    static let text = dynamic(
        light: NSColor(red: 62 / 255, green: 70 / 255, blue: 82 / 255, alpha: 1),
        dark: NSColor(red: 218 / 255, green: 222 / 255, blue: 228 / 255, alpha: 1)
    )
    static let hint = dynamic(
        light: NSColor(red: 130 / 255, green: 139 / 255, blue: 152 / 255, alpha: 1),
        dark: NSColor(red: 145 / 255, green: 152 / 255, blue: 161 / 255, alpha: 1)
    )
}

/// 承载更新窗口。
///
/// 单独一个控制器而不是塞进 AppModel：更新是个独立的、可以完全不发生的流程，
/// 窗口的生死跟录音状态没有任何关系。
@MainActor
final class UpdateWindowController {
    private var window: NSWindow?

    func present(updater: UpdateChecker, release: UpdateChecker.Release) {
        let view = UpdateWindowView(updater: updater, release: release)

        if let window {
            window.contentView = NSHostingView(rootView: view)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let created = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        created.title = "语音狗子更新"
        created.titlebarAppearsTransparent = true
        created.titleVisibility = .hidden
        created.isReleasedWhenClosed = false
        created.contentView = NSHostingView(rootView: view)
        created.center()
        window = created

        created.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 内容随阶段变化，窗口高度得跟着走，否则按钮会被切掉。
    func refresh(updater: UpdateChecker, release: UpdateChecker.Release) {
        guard let window, window.isVisible else { return }
        window.contentView = NSHostingView(rootView: UpdateWindowView(updater: updater, release: release))
    }

    func close() {
        window?.close()
    }
}
