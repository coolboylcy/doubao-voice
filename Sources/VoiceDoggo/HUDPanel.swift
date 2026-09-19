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
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 94),
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

struct HUDView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var urgent: Bool { model.remainingSeconds <= 10 }
    private var recording: Bool { model.isRecording }

    var body: some View {
        Group {
            if recording {
                VStack(spacing: 7) {
                    HStack(spacing: 13) {
                        // 呼吸红点本来就是设计里写明的，只是之前没做动画
                        Circle()
                            .fill(urgent ? BrandHUD.brick : Color.red)
                            .frame(width: 8, height: 8)
                            .shadow(color: (urgent ? BrandHUD.brick : Color.red).opacity(0.72), radius: 5)
                            .opacity(pulse ? 0.4 : 1)
                            .animation(
                                reduceMotion ? nil : .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                                value: pulse
                            )
                            .onAppear { pulse = !reduceMotion }

                        Waveform(levels: model.levels, urgent: urgent)
                            .frame(maxWidth: .infinity)

                        Text(timeText)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(urgent ? BrandHUD.brick : BrandHUD.cream.opacity(0.76))
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }

                    // 红点已经在表达「正在录音」，右侧不再重复一个 REC 标签
                    Text(statusText)
                        .font(.system(size: 12, weight: urgent ? .semibold : .regular))
                        .foregroundStyle(urgent ? BrandHUD.brick : BrandHUD.cream.opacity(0.72))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .opacity(isProcessing ? 1 : 0)
                    Text(statusText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isError ? BrandHUD.brick : BrandHUD.cream.opacity(0.90))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(BrandHUD.warmBlack.opacity(0.96), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(urgent ? BrandHUD.brick.opacity(0.95) : BrandHUD.cream.opacity(0.16), lineWidth: urgent ? 1.5 : 1)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: urgent)
    }

    private var timeText: String {
        let value = max(0, model.remainingSeconds)
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    private var statusText: String {
        if urgent && recording { return "即将自动结束 · 还剩 \(model.remainingSeconds) 秒" }
        if case .processing = model.recordingState { return "识别中……" }
        if case .paywall = model.recordingState { return "订阅后即可开始听写" }
        if case .error(let message) = model.recordingState { return message }
        if !model.transientHUDMessage.isEmpty { return model.transientHUDMessage }
        return model.partialText.isEmpty ? "正在听写" : model.partialText
    }

    private var isProcessing: Bool {
        if case .processing = model.recordingState { return true }
        return false
    }

    private var isError: Bool {
        if case .error = model.recordingState { return true }
        return false
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
    private static let slotCount = 14
    private static let spacing: CGFloat = 4.5
    /// 每格聚合多少个电平样本。14 格 × 3 × 50ms ≈ 2.1 秒可见历史，与改版前一致。
    private static let samplesPerSlot = 3
    /// 静音时保留一条细基线，而不是让条消失——空白会让人以为程序卡住了。
    private static let baselineHeight: CGFloat = 3.5

    var body: some View {
        GeometryReader { geometry in
            let totalSpacing = CGFloat(Self.slotCount - 1) * Self.spacing
            let barWidth = max(3, (geometry.size.width - totalSpacing) / CGFloat(Self.slotCount))
            let maxHeight = geometry.size.height

            HStack(alignment: .center, spacing: Self.spacing) {
                ForEach(0..<Self.slotCount, id: \.self) { slot in
                    Capsule(style: .continuous)
                        .fill(gradient(for: slot))
                        .frame(width: barWidth, height: height(for: slot, maxHeight: maxHeight))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 38)
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
        let shaped = pow(max(0, min(1, level)), 0.7)
        return max(Self.baselineHeight, shaped * maxHeight)
    }

    /// 越靠右越亮：右端是正在说的话，左端是 2 秒前的历史，自然淡出。
    private func gradient(for slot: Int) -> LinearGradient {
        let recency = Double(slot) / Double(Self.slotCount - 1)
        let hasData = level(for: slot) != nil
        let base: Color = urgent ? BrandHUD.brick : BrandHUD.moss
        let opacity = hasData
            ? 0.30 + 0.65 * pow(recency, 1.6)
            : 0.12
        return LinearGradient(
            colors: [base.opacity(opacity), base.opacity(opacity * 0.72)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private enum BrandHUD {
    static let warmBlack = Color(red: 36 / 255, green: 31 / 255, blue: 27 / 255)
    static let cream = Color(red: 234 / 255, green: 220 / 255, blue: 197 / 255)
    static let moss = Color(red: 143 / 255, green: 174 / 255, blue: 151 / 255)
    static let brick = Color(red: 208 / 255, green: 123 / 255, blue: 108 / 255)
}
