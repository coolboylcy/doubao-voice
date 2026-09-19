import Foundation

enum BuildConfiguration {
    /// 本地 DMG 使用随包附带的 FunASR，不依赖 App Store 订阅或云端凭证。
    /// 正式商店归档不会定义 `LOCAL_DISTRIBUTION`，仍走 StoreKit + 豆包授权。
    static var isLocalDistribution: Bool {
#if LOCAL_DISTRIBUTION
        true
#else
        false
#endif
    }
}

enum RecordingPolicy {
    static let maximumSessionSeconds: TimeInterval = 120
    static let toggleThreshold: TimeInterval = 0.3
    /// 整段录音的峰值低于它，基本可以断定是系统输入增益太低，而不是没说话。
    ///
    /// daemon 侧 voice_threshold 是 500（单包 50ms 的有声判定），这里取 4 倍
    /// 作为整段的健康下限。实测：系统输入音量 37% 时整段峰值只有 1300 上下，
    /// SenseVoice 必然返回空；调到 85% 后平均就有 2000+，识别正常。
    /// 区分这两种「空结果」很重要——否则用户只看到「没有听到内容」，完全
    /// 无从知道是自己没说话还是麦克风增益不够。
    static let lowGainPeakThreshold = 2000

    static func isLikelyLowGain(sessionPeak: Int) -> Bool {
        sessionPeak > 0 && sessionPeak < lowGainPeakThreshold
    }

    static func hasAccess(localDistribution: Bool, isSubscribed: Bool) -> Bool {
        localDistribution || isSubscribed
    }

    static func availableSeconds(
        localDistribution: Bool,
        subscriptionRemaining: TimeInterval
    ) -> TimeInterval {
        localDistribution
            ? maximumSessionSeconds
            : min(maximumSessionSeconds, max(0, subscriptionRemaining))
    }

    static func usesToggleMode(heldSeconds: TimeInterval) -> Bool {
        heldSeconds < toggleThreshold
    }
}

enum ClipboardRestorationPolicy {
    static func shouldRestore(currentChangeCount: Int, insertedChangeCount: Int) -> Bool {
        currentChangeCount == insertedChangeCount
    }
}
