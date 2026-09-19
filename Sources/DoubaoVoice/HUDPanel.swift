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

    private var urgent: Bool { model.remainingSeconds <= 10 }
    private var recording: Bool { model.isRecording }

    var body: some View {
        Group {
            if recording {
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(urgent ? Color.orange : Color.red)
                            .frame(width: 9, height: 9)
                            .shadow(color: (urgent ? Color.orange : Color.red).opacity(0.75), radius: 6)

                        Waveform(levels: model.levels)
                            .frame(maxWidth: .infinity)

                        Text(timeText)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(urgent ? Color.orange : Color.white.opacity(0.78))
                            .frame(width: 54, alignment: .trailing)
                    }

                    HStack {
                        Text(statusText)
                            .font(.system(size: 12, weight: urgent ? .semibold : .regular))
                            .foregroundStyle(urgent ? Color.orange : Color.white.opacity(0.72))
                        Spacer()
                        Text("REC")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.red)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .opacity(isProcessing ? 1 : 0)
                    Text(statusText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isError ? Color.orange : Color.white.opacity(0.86))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(urgent ? Color.orange.opacity(0.9) : Color.white.opacity(0.12), lineWidth: urgent ? 1.5 : 1)
        }
        .animation(.easeOut(duration: 0.15), value: urgent)
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

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 3) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                    Capsule()
                        .fill(Color.cyan.opacity(index == levels.count - 1 ? 0.95 : 0.42))
                        .frame(width: max(2, (geometry.size.width - CGFloat(max(0, levels.count - 1)) * 3) / CGFloat(max(1, levels.count))), height: max(3, CGFloat(level) * 34))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 38)
    }
}
