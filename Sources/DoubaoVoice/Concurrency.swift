import Foundation

/// 可取消的等待。
///
/// 直接写 `try? await Task.sleep(...)` 是个陷阱：Task 被取消时 sleep 会立刻
/// 返回，`CancellationError` 被 `try?` 吞掉，**后面的代码照常执行**。
///
/// 这个项目在这上面栽过一次，代价不小：`armSilenceCancellation` 里的静音定时
/// 器就是这么写的，而音频电平事件每 50ms 一个、每个 voiced 都会重新 arm 一次
/// ——上一个 task 被 cancel 后立即醒来，看到 `isRecording` 仍为 true，就把正在
/// 进行的录音取消掉。外部表现是「一出声波形就闪没了」，从现象完全看不出源头。
///
/// 所以不要再散落地写 `try? await Task.sleep` 加一句 `guard !Task.isCancelled`
/// ——那种约定迟早会漏。统一走这里，调用方被返回值逼着表态。
enum Sleep {
    /// 睡满 `duration` 返回 true；中途被取消返回 false。
    static func completed(for duration: Duration) async -> Bool {
        do {
            try await Task.sleep(for: duration)
        } catch {
            return false
        }
        // sleep 正常返回后仍可能已被取消（取消发生在唤醒与恢复之间）
        return !Task.isCancelled
    }
}
