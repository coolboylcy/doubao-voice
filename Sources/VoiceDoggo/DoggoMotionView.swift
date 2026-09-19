import SwiftUI

enum DoggoMotionPhase: Equatable {
    case idle
    case listening
    case speaking
    case finishing
    case delivered
}

/// 逐帧播放的狗子动画。
///
/// 之前是拿同一张图做 scale / rotate / offset——狗的姿态从头到尾一个样，只是在
/// 缩放旋转，看着就是一张贴图在抽搐。现在是四张真正不同姿态的画：抬头闭嘴、
/// 低头闭眼吐舌、歪头、张嘴说话。区别在于嘴、眼睛、头的朝向真的在变。
///
/// 帧序列走 1→2→3→4→3→2 的来回，不是 1→2→3→4→1 的跳回。跳回那一下是硬切，
/// 循环起来每轮都咯噔一次；来回播放两端自然转向，看不出接缝。
struct DoggoMotionView: View {
    let phase: DoggoMotionPhase
    var level: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 四张图来回播是 6 个位置：1 2 3 4 3 2，再回到 1。
    private static let sequence = [0, 1, 2, 3, 2, 1]
    private static let frameNames = (1...4).map { "MascotFrame\($0)" }

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 30)) { context in
            let tick = context.date.timeIntervalSinceReferenceDate
            let index = frameIndex(at: tick)

            ZStack {
                if phase == .listening || phase == .speaking {
                    listeningRings(at: tick)
                }

                Image(Self.frameNames[index])
                    .resizable()
                    .scaledToFit()
                    // 逐帧已经提供了主要动作，这里只留一点点起伏，
                    // 免得说话时整只狗显得钉在原地。
                    .offset(y: bob(at: tick))
                    .shadow(color: Color.black.opacity(0.10), radius: 7, y: 4)

                badge
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    /// 当前该显示第几帧。
    ///
    /// 帧率跟着音量走：不出声时慢慢喘气，说得越响切得越快。这样狗的动作和波形
    /// 来自同一份实时数据，看起来才像在听同一个人说话。
    private func frameIndex(at tick: TimeInterval) -> Int {
        guard !reduceMotion else { return 0 }

        let audio = max(0, min(1, level))
        let fps: Double
        switch phase {
        case .idle: fps = 2.5
        case .listening: fps = 5
        case .speaking: fps = 7 + audio * 7
        case .finishing: fps = 3
        case .delivered: return 3
        }

        let step = Int(tick * fps) % Self.sequence.count
        return Self.sequence[step]
    }

    private func bob(at tick: TimeInterval) -> CGFloat {
        guard !reduceMotion else { return 0 }
        let audio = max(0, min(1, level))
        let amplitude: CGFloat
        switch phase {
        case .idle: amplitude = 0.8
        case .listening: amplitude = 1.2
        case .speaking: amplitude = 1.2 + CGFloat(audio) * 2.4
        case .finishing, .delivered: amplitude = 0.6
        }
        return -abs(sin(tick * 3.1)) * amplitude
    }

    @ViewBuilder
    private var badge: some View {
        if phase == .finishing {
            ProgressView()
                .controlSize(.small)
                .tint(HUDBrand.accent)
                .padding(6)
                .background(.white.opacity(0.92), in: Circle())
                .offset(x: 35, y: -34)
        } else if phase == .delivered {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color.green, in: Circle())
                .offset(x: 35, y: -34)
        }
    }

    @ViewBuilder
    private func listeningRings(at tick: TimeInterval) -> some View {
        let breath = reduceMotion ? 0.5 : (sin(tick * 2.2) + 1) / 2
        ForEach(0..<2, id: \.self) { index in
            Circle()
                .stroke(HUDBrand.accent.opacity(0.18 - Double(index) * 0.05), lineWidth: 2)
                .scaleEffect(0.72 + breath * 0.10 + CGFloat(index) * 0.12)
                .opacity(1 - breath * 0.52)
        }
    }

    private var accessibilityLabel: String {
        switch phase {
        case .idle: return "狗子待命"
        case .listening: return "狗子正在听"
        case .speaking: return "狗子跟随声音动起来"
        case .finishing: return "狗子正在整理文字"
        case .delivered: return "文字已输入"
        }
    }
}
