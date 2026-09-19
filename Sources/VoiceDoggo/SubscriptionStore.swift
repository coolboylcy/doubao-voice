import AppKit
import Foundation
import StoreKit

@MainActor
final class SubscriptionStore: ObservableObject {
    // 上架前需要在 App Store Connect 创建同名的 macOS 自动续订商品。
    static let monthlyProductID = "com.voicedoggo.pro.monthly"
    static let monthlyQuota: TimeInterval = 10 * 60 * 60

    @Published private(set) var product: Product?
    @Published private(set) var isSubscribed = false
    @Published private(set) var remainingSeconds = monthlyQuota
    @Published private(set) var purchaseError = ""
    @Published private(set) var periodEnd: Date?

    private var updatesTask: Task<Void, Never>?
    private let usageStore = SecureUsageStore()
    private var periodKey = "unassigned"

    init() {
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(result)
            }
        }
        Task { await refresh() }
    }

    deinit { updatesTask?.cancel() }

    var monthlyQuotaHours: Int { Int(Self.monthlyQuota / 3600) }
    var quotaProgress: Double { max(0, min(1, remainingSeconds / Self.monthlyQuota)) }
    var quotaText: String {
        let minutes = max(0, Int(remainingSeconds) / 60)
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }

    func refresh() async {
        do {
            product = try await Product.products(for: [Self.monthlyProductID]).first
        } catch {
            purchaseError = "暂时无法读取订阅商品"
        }

        var active = false
        var activeExpiration: Date?
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.monthlyProductID,
               transaction.revocationDate == nil,
               transaction.expirationDate.map({ $0 > Date() }) ?? true {
                active = true
                activeExpiration = transaction.expirationDate
            }
        }
        isSubscribed = active
        periodEnd = activeExpiration
        if let activeExpiration {
            let newPeriodKey = String(Int(activeExpiration.timeIntervalSince1970))
            if newPeriodKey != periodKey { periodKey = newPeriodKey }
        }
        reloadUsage()
    }

    func purchase() async {
        guard let product else {
            purchaseError = "订阅商品尚未准备好，请稍后重试"
            return
        }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                await handle(verification)
            case .userCancelled:
                break
            case .pending:
                purchaseError = "购买正在等待确认"
            @unknown default:
                purchaseError = "购买状态未知"
            }
        } catch {
            purchaseError = "购买失败：\(error.localizedDescription)"
        }
    }

    func restore() async {
        do {
            try await AppStore.sync()
            await refresh()
        } catch {
            purchaseError = "恢复购买失败：\(error.localizedDescription)"
        }
    }

    func consume(seconds: TimeInterval) {
        guard isSubscribed else { return }
        let key = usageKey
        let used = usageStore.double(for: key)
        usageStore.set(used + max(0, seconds), for: key)
        reloadUsage()
    }

    func openManagement() {
        if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
            NSWorkspace.shared.open(url)
        }
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else {
            purchaseError = "无法验证购买凭证"
            return
        }
        if transaction.productID == Self.monthlyProductID {
            isSubscribed = true
            periodEnd = transaction.expirationDate
            if let expirationDate = transaction.expirationDate {
                periodKey = String(Int(expirationDate.timeIntervalSince1970))
            }
            reloadUsage()
        }
        await transaction.finish()
    }

    private var usageKey: String {
        "period.\(periodKey)"
    }

    private func reloadUsage() {
        remainingSeconds = max(0, Self.monthlyQuota - usageStore.double(for: usageKey))
    }
}
