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
