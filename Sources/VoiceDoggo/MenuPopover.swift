import AppKit
import SwiftUI

/// 菜单栏点开后的面板。
///
/// 用 NSPopover + SwiftUI 而不是 NSMenu：设计稿要求顶部有一块「头像 + 名字 +
/// 运行状态」的自定义区域，菜单项要有圆角高亮底。NSMenu 的外观由系统控制，
/// 这两样都做不到。
///
/// 代价是键盘导航、焦点、自动关闭都得自己接：behavior 设为 .transient 让点击
/// 外部自动收起，每个条目是真正的 Button 因而可 Tab 可回车。
struct MenuPopover: View {
    @ObservedObject var model: AppModel

    var onStart: () -> Void
    var onFinish: () -> Void
    var onCancel: () -> Void
    var onMain: () -> Void
    var onSettings: () -> Void
    var onQuit: () -> Void
    var onOpen: (URL) -> Void

    private static let repo = "https://github.com/coolboylcy/voice-doggo"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.horizontal, 12)
            VStack(spacing: 2) {
                if model.isRecording {
                    MenuRow(icon: "checkmark.circle", title: "完成听写", action: onFinish)
                    MenuRow(icon: "xmark.circle", title: "取消本次听写", action: onCancel)
                } else {
                    MenuRow(icon: "mic", title: "开始听写", trailing: "按住\(model.hotkeyTitle)", action: onStart)
                }
                MenuRow(icon: "macwindow", title: "打开语音狗子", action: onMain)
                MenuRow(icon: "gearshape", title: "设置…", action: onSettings)
                MenuRow(icon: "book", title: "使用指南") { onOpen(URL(string: "\(Self.repo)#readme")!) }
                MenuRow(icon: "lightbulb", title: "常见问题") { onOpen(URL(string: "\(Self.repo)#排查")!) }
                MenuRow(icon: "bubble.left.and.bubble.right", title: "反馈建议") {
                    onOpen(URL(string: "\(Self.repo)/issues")!)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider().padding(.horizontal, 12)
            VStack(spacing: 2) {
                MenuRow(icon: "power", title: "退出语音狗子", action: onQuit)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
        .frame(width: 282)
    }

    private var header: some View {
        HStack(spacing: 11) {
            // AppMark 而不是 AppIcon：后者自带 Big Sur 规范的 100px 透明边，
            // 在这种自己定尺寸的容器里会显示成一圈留白。AppMark 本身已经是
            // squircle，所以也不需要再 clipShape。
            if let icon = NSImage(named: "AppMark") ?? NSImage(named: "AppIcon") {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 38, height: 38)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("语音狗子")
                    .font(.system(size: 14, weight: .semibold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 7, height: 7)
                    Text(stateText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }

    private var stateColor: Color {
        switch model.recordingState {
        case .recording: return MenuBrand.rec
        case .processing: return .orange
        case .error, .paywall: return .orange
        case .idle: return model.engineReady ? MenuBrand.ok : .orange
        }
    }

    private var stateText: String {
        switch model.recordingState {
        case .recording: return "正在听写"
        case .processing: return "识别中"
        case .paywall: return "需要订阅"
        case .error(let message): return message
        case .idle: return model.engineReady ? "运行中" : "正在启动识别引擎…"
        }
    }
}

/// 单个菜单条目。hover 时出现圆角高亮底，与设计稿一致。
private struct MenuRow: View {
    let icon: String
    let title: String
    var trailing: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13.5))
                    .frame(width: 17)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 13))
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? MenuBrand.highlight : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

enum MenuBrand {
    /// 设计稿的选中底 #DCE8FB；深色下换成低透明度白，避免亮块刺眼
    static let highlight = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.09)
            : NSColor(red: 220 / 255, green: 232 / 255, blue: 251 / 255, alpha: 1)
    })
    static let ok = Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255)
    static let rec = Color(red: 240 / 255, green: 89 / 255, blue: 106 / 255)
}
