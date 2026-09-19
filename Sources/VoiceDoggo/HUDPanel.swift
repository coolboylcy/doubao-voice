import AppKit
import SwiftUI

@MainActor
final class HUDPanelController {
    private let model: AppModel
    private var panel: NSPanel?
    private var presentationGeneration = 0

    init(model: AppModel) { self.model = model }

    func show() {
        presentationGeneration += 1
        if panel == nil {
            let view = HUDView(model: model)
            let hosting = NSHostingView(rootView: view)
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 150),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.contentView = hosting
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .floating
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel = p
        }
        position()
        panel?.orderFrontRegardless()
    }

    func hide() {
        presentationGeneration += 1
        panel?.orderOut(nil)
    }
    func showProcessing() { show() }

    func showPaywall() {
        show()
        hide(after: 2.4)
    }

    func showQuotaExhausted() {
        show()
        hide(after: 2.4)
    }

    func showMessage(_ message: String) {
        model.setTransientHUDMessage(message)
        show()
        hide(after: 1.5)
    }

    func showError(_ message: String) {
        model.setTransientHUDMessage(message)
        show()
        hide(after: 3.5)
    }

    private func hide(after delay: TimeInterval) {
        let generation = presentationGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.presentationGeneration == generation else { return }
            self.hide()
        }
    }

    private func position() {
        guard let screen = NSScreen.main, let panel else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.minY + 80
        ))
    }
}

/// 录音浮层。
///
/// 按产品设计稿实现：浅色卡片、吉祥物在左、蓝色粗波形居中、右侧状态与时间、
/// 底部一条剩余时间进度条。
///
/// 设计稿里有停止按钮、关闭叉、中英切换三个控件，这里**故意没做**——浮层是
/// `ignoresMouseEvents` 的（否则会挡住你正在输入的窗口），上面任何按钮都点不了；
/// 中英切换则是产品没有的功能。画一个点不动的按钮比不画更糟。
struct HUDView: View {
    @ObservedObject var model: AppModel
    @State private var pulse = false

    private var urgent: Bool { model.remainingSeconds <= 10 }
    private var recording: Bool { model.isRecording }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Image("MascotListening")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 66, height: 66)
                    .opacity(recording ? 1 : 0.55)

                if recording {
                    Waveform(levels: model.levels, urgent: urgent)
                        .frame(maxWidth: .infinity)

                    VStack(alignment: .trailing, spacing: 3) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(urgent ? HUDBrand.warn : HUDBrand.rec)
                                .frame(width: 7, height: 7)
                                .opacity(pulse ? 0.35 : 1)
                                .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: pulse)
                            Text(urgent ? "即将结束" : "正在听写")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        Text(timeText)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(HUDBrand.sub)
                    }
                    .frame(width: 118, alignment: .trailing)
                } else {
                    Text(statusText)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if recording {
                // 进度条表示的是「还能说多久」，走完自动收尾
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(HUDBrand.track)
                        Capsule()
                            .fill(urgent ? HUDBrand.warn : HUDBrand.accent)
                            .frame(width: geo.size.width * remainingFraction)
                    }
                }
                .frame(height: 6)

                Text(partialOrHint)
                    .font(.system(size: 12))
                    .foregroundStyle(HUDBrand.sub)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(HUDBrand.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(HUDBrand.edge, lineWidth: 1)
        }
        .onAppear { pulse = true }
        .animation(.easeOut(duration: 0.15), value: urgent)
    }

    /// 剩余占比。总时长用策略上限，不写死，免得改了上限这里对不上。
    private var remainingFraction: Double {
        let total = RecordingPolicy.maximumSessionSeconds
        guard total > 0 else { return 0 }
        return max(0, min(1, Double(model.remainingSeconds) / total))
    }

    private var timeText: String {
        let left = max(0, model.remainingSeconds)
        let total = Int(RecordingPolicy.maximumSessionSeconds)
        return String(format: "%02d:%02d / %02d:%02d", left / 60, left % 60, total / 60, total % 60)
    }

    private var partialOrHint: String {
        model.partialText.isEmpty ? "松开按键，文字自动输入到当前光标位置" : model.partialText
    }

    private var statusText: String {
        if case .processing = model.recordingState { return "识别中……" }
        if case .paywall = model.recordingState { return "订阅后即可开始听写" }
        if case .error(let message) = model.recordingState { return message }
        if !model.transientHUDMessage.isEmpty { return model.transientHUDMessage }
        return "正在听写"
    }
}

/// 浮层配色。取自产品设计稿，与设置页共用一套蓝。
enum HUDBrand {
    static let accent = Color(red: 46 / 255, green: 124 / 255, blue: 246 / 255)
    static let rec = Color(red: 240 / 255, green: 89 / 255, blue: 106 / 255)
    static let warn = Color(red: 240 / 255, green: 150 / 255, blue: 60 / 255)
    static let card = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 30 / 255, green: 34 / 255, blue: 42 / 255, alpha: 0.97)
            : NSColor(red: 244 / 255, green: 248 / 255, blue: 253 / 255, alpha: 0.98)
    })
    static let edge = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.10)
            : NSColor(red: 232 / 255, green: 236 / 255, blue: 241 / 255, alpha: 1)
    })
    static let sub = Color.secondary
    static let track = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.14)
            : NSColor(red: 215 / 255, green: 225 / 255, blue: 239 / 255, alpha: 1)
    })
}

struct Waveform: View {
    let levels: [Double]
    var urgent = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 槽位数固定，不随已有数据量变化。
    ///
    /// 早先是按 `levels.count` 分宽度，而 levels 从空涨到 40——录音头两秒里每根
    /// 条都在不断变窄，还贴着左边生长，看着很毛糙。现在槽位恒定、数据从右侧
    /// 推入，条宽自始至终一样，波形像真正的示波器那样往左滚。
    private static let slotCount = 20
    private static let spacing: CGFloat = 9
    /// 每格聚合多少个电平样本。14 格 × 3 × 50ms ≈ 2.1 秒可见历史，与改版前一致。
    private static let samplesPerSlot = 2
    /// 静音时保留一条细基线，而不是让条消失——空白会让人以为程序卡住了。
    private static let baselineHeight: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            let totalSpacing = CGFloat(Self.slotCount - 1) * Self.spacing
            let barWidth = max(3, (geometry.size.width - totalSpacing) / CGFloat(Self.slotCount))
            let maxHeight = geometry.size.height

            HStack(alignment: .center, spacing: Self.spacing) {
                ForEach(0..<Self.slotCount, id: \.self) { slot in
                    Capsule(style: .continuous)
                        .fill(barColor(for: slot))
                        .frame(width: barWidth, height: height(for: slot, maxHeight: maxHeight))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 52)
        .animation(reduceMotion ? nil : .linear(duration: 0.05), value: levels.count)
    }

    /// 右端是最新一格；数据不足时空槽留在左侧。
    ///
    /// 一格对应多个电平样本，取其中最大值而不是平均：说话是脉冲式的，
    /// 取平均会把短促音节抹平，波形看着像没在动。
    private func level(for slot: Int) -> Double? {
        let need = Self.slotCount * Self.samplesPerSlot
        let tail = levels.suffix(need)
        let offset = Self.slotCount - Int(ceil(Double(tail.count) / Double(Self.samplesPerSlot)))
        let index = slot - offset
        guard index >= 0 else { return nil }
        let start = index * Self.samplesPerSlot
        guard start < tail.count else { return nil }
        let chunk = Array(tail)[start..<min(start + Self.samplesPerSlot, tail.count)]
        return chunk.max()
    }

    private func height(for slot: Int, maxHeight: CGFloat) -> CGFloat {
        guard let level = level(for: slot) else { return Self.baselineHeight }
        // 轻微的幂次压缩：线性映射下正常说话只占满格的三分之一，视觉上太平；
        // 0.7 次幂把中段抬起来，又不至于把底噪也放大成有效信号。
        // 不做幂次压缩。之前用 0.62 想「让弱音更明显」，效果适得其反——
        // 幂次小于 1 会把低值抬起来（0.18 变 0.35），波形高低拉不开，
        // 二十根条看着像一堵墙。设计稿里最矮和最高差着五六倍，线性才对得上。
        let shaped = max(0, min(1, level))
        return max(Self.baselineHeight, shaped * maxHeight)
    }

    /// 越靠右越亮：右端是正在说的话，左端是 2 秒前的历史，自然淡出。
    /// 纯色蓝，只用透明度区分新旧：右端是正在说的话，越往左越淡。
    /// 设计稿里波形不带纵向渐变，加了反而显脏。
    private func barColor(for slot: Int) -> Color {
        let recency = Double(slot) / Double(Self.slotCount - 1)
        let hasData = level(for: slot) != nil
        let base = urgent ? HUDBrand.warn : HUDBrand.accent
        return base.opacity(hasData ? (0.5 + 0.5 * pow(recency, 1.2)) : 0.12)
    }

}

private enum BrandHUD {
    static let warmBlack = Color(red: 36 / 255, green: 31 / 255, blue: 27 / 255)
    static let cream = Color(red: 234 / 255, green: 220 / 255, blue: 197 / 255)
    static let moss = Color(red: 143 / 255, green: 174 / 255, blue: 151 / 255)
    static let brick = Color(red: 208 / 255, green: 123 / 255, blue: 108 / 255)
}
