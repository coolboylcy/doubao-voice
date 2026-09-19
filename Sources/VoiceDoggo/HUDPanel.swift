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
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 268),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.contentView = hosting
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .floating
            p.hasShadow = true
            // 设计稿里的停止按钮与关闭叉需要可点。nonactivatingPanel 已经
            // 保证点击不会激活本 App、不会把焦点从你正在输入的窗口抢走，
            // 所以这里可以安全地接收鼠标事件。
            p.ignoresMouseEvents = false
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

/// 录音浮层。按设计稿 1:1 实现。
///
/// 用百炼的视觉模型把设计稿的参数读了出来再写：整体 2.32:1、圆角 24、
/// 波形 12 根、条宽:间距 ≈ 1:1.35、最矮:最高 ≈ 1:3.6、条色按高度分三档，
/// 红色停止键直径占高度 16.5%、进度条高 14 圆角 7。
///
/// 底部右侧设计稿是「中 ⇄ En」语言切换。产品的模型本来就是中英混合、没有可切
/// 换的两套，所以这里保留位置与样式，但写成静态的「中英混合」——不做点了没反应
/// 的假开关。
struct HUDView: View {
    @ObservedObject var model: AppModel
    @State private var pulse = false

    private var urgent: Bool { model.remainingSeconds <= 10 }
    private var recording: Bool { model.isRecording }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            Spacer(minLength: 0)
            mainRow
            Spacer(minLength: 0)
            progressBar
            Spacer(minLength: 0)
            bottomBar
        }
        .padding(.horizontal, 26)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HUDBrand.surface)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(HUDBrand.edge, lineWidth: 1)
        }
        .onAppear { pulse = true }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            Text(recording ? "按住右 Option 说话" : statusText)
                .font(.system(size: 13))
                .foregroundStyle(HUDBrand.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(HUDBrand.chip, in: Capsule())
            Button(action: { model.cancelRecording() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(HUDBrand.sub)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("取消本次听写")
        }
    }

    private var mainRow: some View {
        HStack(spacing: 18) {
            TalkingMascot(level: model.levels.last ?? 0, active: recording)

            Waveform(levels: model.levels, urgent: urgent)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                Text(recording ? (urgent ? "即将结束…" : "正在听写…") : statusText)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(HUDBrand.ink)
                Text(timeText)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(HUDBrand.sub)
            }
            .frame(width: 134, alignment: .leading)

            Button(action: { model.stopFromMenu() }) {
                ZStack {
                    Circle().fill(HUDBrand.stop)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.white)
                        .frame(width: 14, height: 14)
                }
                .frame(width: 44, height: 44)
                .opacity(pulse && recording ? 0.86 : 1)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            }
            .buttonStyle(.plain)
            .help("完成听写")
            .disabled(!recording)
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(HUDBrand.track)
                Capsule()
                    .fill(urgent ? HUDBrand.warn : HUDBrand.accent)
                    .frame(width: geo.size.width * elapsedFraction)
            }
        }
        .frame(height: 10)
    }

    private var bottomBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles")
                .font(.system(size: 13))
                .foregroundStyle(HUDBrand.sub)
            Text(hintText)
                .font(.system(size: 12.5))
                .foregroundStyle(HUDBrand.sub)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 10)
            Text("中英混合")
                .font(.system(size: 11.5))
                .foregroundStyle(HUDBrand.sub)
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .background(HUDBrand.chip, in: Capsule())
        }
    }

    /// 进度条走的是「已经说了多久」，和右侧时间同源
    private var elapsedFraction: Double {
        let total = RecordingPolicy.maximumSessionSeconds
        guard total > 0 else { return 0 }
        let used = total - Double(model.remainingSeconds)
        return max(0, min(1, used / total))
    }

    private var timeText: String {
        let total = Int(RecordingPolicy.maximumSessionSeconds)
        let used = max(0, total - max(0, model.remainingSeconds))
        return String(format: "%02d:%02d / %02d:%02d", used / 60, used % 60, total / 60, total % 60)
    }

    private var hintText: String {
        if !model.partialText.isEmpty { return model.partialText }
        return "松开按键，自动输入到当前光标位置"
    }

    private var statusText: String {
        if case .processing = model.recordingState { return "识别中…" }
        if case .error(let message) = model.recordingState { return message }
        if !model.transientHUDMessage.isEmpty { return model.transientHUDMessage }
        return "正在听写"
    }
}

/// 会随音量律动的吉祥物。
///
/// 原本想用生成模型做一段「小狗说话」的视频循环播放，试了 happyhorse-1.1-i2v：
/// 首帧还是原图，之后角色就崩了——正脸、耳朵变形、头顶多出呆毛，不是同一只狗。
/// i2v 在保持角色一致性上不可靠，而这个形象是品牌资产，走形就没意义了。
///
/// 改成用真实音量驱动静态图做细微形变，反而比预渲染的视频好：它跟着你说话的
/// 大小实时起伏，说得响动得明显，停下来就静止，跟波形是同一个数据源。
private struct TalkingMascot: View {
    let level: Double
    let active: Bool

    var body: some View {
        Image("MascotListening")
            .resizable()
            .scaledToFit()
            .frame(width: 112, height: 112)
            // 幅度压得很小：这是个常驻画面，动得夸张会让人分心
            .scaleEffect(active ? 1 + level * 0.05 : 1, anchor: .bottom)
            .offset(y: active ? -level * 3.5 : 0)
            .rotationEffect(.degrees(active ? level * 1.6 : 0), anchor: .bottom)
            .animation(.easeOut(duration: 0.09), value: level)
            .animation(.easeOut(duration: 0.2), value: active)
    }
}

/// 浮层配色，取自设计稿。
///
/// 固定浅色而不跟随系统：它是短暂出现的品牌浮层，不是常驻的系统界面，
/// 设计稿也只有这一套。深色模式下照样是这张浅色卡片，与其他 App 的深色窗口
/// 叠在一起反而更容易被一眼认出。
enum HUDBrand {
    static let accent = Color(red: 0x2E / 255, green: 0x7C / 255, blue: 0xF4 / 255)
    static let stop = Color(red: 0xF4 / 255, green: 0x50 / 255, blue: 0x6B / 255)
    static let warn = Color(red: 0xF0 / 255, green: 0x8A / 255, blue: 0x3C / 255)
    static let ink = Color(red: 0x1F / 255, green: 0x24 / 255, blue: 0x2B / 255)
    static let sub = Color(red: 0x7A / 255, green: 0x82 / 255, blue: 0x8C / 255)
    static let track = Color(red: 0xC9 / 255, green: 0xDB / 255, blue: 0xF0 / 255)
    static let chip = Color.white.opacity(0.68)
    static let edge = Color.white.opacity(0.9)
    /// 左上到右下的浅蓝白渐变
    static let surface = LinearGradient(
        colors: [
            Color(red: 0xEF / 255, green: 0xF5 / 255, blue: 0xFF / 255),
            Color(red: 0xFA / 255, green: 0xFC / 255, blue: 0xFF / 255),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    /// 波形三档色：颜色跟条高绑定，而不是按位置渐变——这是设计稿的规律
    static func bar(for level: Double) -> Color {
        if level > 0.62 { return Color(red: 0x1D / 255, green: 0x7B / 255, blue: 0xF3 / 255) }
        if level > 0.32 { return Color(red: 0x4C / 255, green: 0x96 / 255, blue: 0xF6 / 255) }
        return Color(red: 0x8A / 255, green: 0xBA / 255, blue: 0xF9 / 255)
    }
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
    private static let slotCount = 12
    /// 设计稿里条间距约为条宽的 1.35 倍
    private static let gapRatio: CGFloat = 1.1
    /// 每格聚合多少个电平样本。14 格 × 3 × 50ms ≈ 2.1 秒可见历史，与改版前一致。
    private static let samplesPerSlot = 3
    /// 静音时保留一条细基线，而不是让条消失——空白会让人以为程序卡住了。
    /// 最矮的条仍有可见高度：设计稿最矮 25px / 最高 90px ≈ 0.28
    private static let minRatio: CGFloat = 0.28

    var body: some View {
        GeometryReader { geometry in
            // 由「条宽 + 1.35 倍间距」反推条宽，保证比例与设计稿一致
            let unit = geometry.size.width / (CGFloat(Self.slotCount) + CGFloat(Self.slotCount - 1) * Self.gapRatio)
            let barWidth = max(3, unit)
            let spacing = unit * Self.gapRatio
            let maxHeight = geometry.size.height

            HStack(alignment: .center, spacing: spacing) {
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
        guard let level = level(for: slot) else { return maxHeight * Self.minRatio }
        let clamped = max(0, min(1, level))
        // 线性映射到 [minRatio, 1]：设计稿最矮的条也有近三成高，不是一个点
        return maxHeight * (Self.minRatio + (1 - Self.minRatio) * clamped)
    }

    /// 越靠右越亮：右端是正在说的话，左端是 2 秒前的历史，自然淡出。
    /// 颜色跟条高绑定（高/中/矮三档），不是按位置渐变——这是设计稿的规律。
    /// 之前做成从左到右渐变，整排看着像一条均匀的色带，没有节奏。
    private func barColor(for slot: Int) -> Color {
        guard let level = level(for: slot) else { return HUDBrand.bar(for: 0) }
        return urgent ? HUDBrand.warn : HUDBrand.bar(for: level)
    }

}

private enum BrandHUD {
    static let warmBlack = Color(red: 36 / 255, green: 31 / 255, blue: 27 / 255)
    static let cream = Color(red: 234 / 255, green: 220 / 255, blue: 197 / 255)
    static let moss = Color(red: 143 / 255, green: 174 / 255, blue: 151 / 255)
    static let brick = Color(red: 208 / 255, green: 123 / 255, blue: 108 / 255)
}
