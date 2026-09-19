import SwiftUI

enum DoggoMotionPhase: Equatable {
    case idle
    case listening
    case speaking
    case finishing
    case delivered
}

/// 轻量 12 帧狗子动画。
///
/// 不播放视频、不常驻解码器：每秒只计算 12 个离散姿态帧，利用同一张透明品牌
/// 素材做呼吸、侧耳、点头和收尾动作。音量会直接影响 speaking 帧的幅度，因此
/// 狗子和波形来自同一份实时数据；降低动态效果时自动收成静态姿态。
struct DoggoMotionView: View {
    let phase: DoggoMotionPhase
    var level: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 12)) { context in
            let frame = reduceMotion ? 0 : Int(context.date.timeIntervalSinceReferenceDate * 12) % 12
            let pose = pose(for: frame)

            ZStack {
                if phase == .listening || phase == .speaking {
                    listeningRings(frame: frame)
                }

                Image("MascotListening")
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(x: pose.scaleX, y: pose.scaleY, anchor: .bottom)
                    .rotationEffect(.degrees(pose.rotation), anchor: .bottom)
                    .offset(x: pose.x, y: pose.y)
                    .shadow(color: Color.black.opacity(0.10), radius: 7, y: 4)

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
            .drawingGroup()
        }
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private func listeningRings(frame: Int) -> some View {
        let breath = CGFloat(frame) / 11
        ForEach(0..<2, id: \.self) { index in
            Circle()
                .stroke(HUDBrand.accent.opacity(0.18 - Double(index) * 0.05), lineWidth: 2)
                .scaleEffect(0.72 + breath * 0.10 + CGFloat(index) * 0.12)
                .opacity(1 - breath * 0.52)
        }
    }

    private func pose(for frame: Int) -> Pose {
        let angle = Double(frame) / 12 * Double.pi * 2
        let wave = sin(angle)
        let quick = sin(angle * 2)
        let audio = max(0, min(1, level))

        switch phase {
        case .idle:
            return Pose(scaleX: 1 - wave * 0.006, scaleY: 1 + wave * 0.012, x: 0, y: -wave * 0.7, rotation: wave * 0.5)
        case .listening:
            return Pose(scaleX: 1 - wave * 0.008, scaleY: 1 + wave * 0.016, x: wave * 0.8, y: -1.5 - abs(wave), rotation: -2 + wave * 1.2)
        case .speaking:
            return Pose(
                scaleX: 1 - quick * (0.010 + audio * 0.018),
                scaleY: 1 + abs(quick) * (0.014 + audio * 0.038),
                x: wave * (0.8 + audio * 1.2),
                y: -abs(quick) * (1 + audio * 3.2),
                rotation: wave * (1.0 + audio * 2.2)
            )
        case .finishing:
            return Pose(scaleX: 1, scaleY: 1, x: wave * 0.5, y: 0, rotation: 4 + wave * 1.2)
        case .delivered:
            return Pose(scaleX: 1 + abs(wave) * 0.012, scaleY: 1 + abs(wave) * 0.02, x: 0, y: -abs(wave) * 1.5, rotation: -3 + wave)
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

    private struct Pose {
        let scaleX: CGFloat
        let scaleY: CGFloat
        let x: CGFloat
        let y: CGFloat
        let rotation: Double
    }
}
