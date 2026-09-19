import Foundation
import Security

/// 仅供本地开发兼容旧版 helper。正式商业版应改为服务端签发的短期 token。
final class ASRCredentialStore {
    struct Credentials {
        var apiKey = ""
        var appID = ""
        var accessKey = ""

        var isConfigured: Bool {
            (!apiKey.isEmpty) || (!appID.isEmpty && !accessKey.isEmpty)
        }
    }

    static let shared = ASRCredentialStore()

    private let service = "com.voicedoggo.asr"

    func load() -> Credentials {
        let stored = Credentials(
            apiKey: read(account: "api_key") ?? "",
            appID: read(account: "app_id") ?? "",
            accessKey: read(account: "access_key") ?? ""
        )
        guard !stored.isConfigured else { return stored }

        // 从旧版 ~/.voice-doggo/config.json 迁移一次到 Keychain，避免升级后凭证丢失。
        let legacyURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".voice-doggo/config.json")
        guard let data = try? Data(contentsOf: legacyURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return stored
        }
        let migrated = Credentials(
            apiKey: json["api_key"] as? String ?? "",
            appID: json["app_id"] as? String ?? "",
            accessKey: json["access_key"] as? String ?? ""
        )
        guard migrated.isConfigured else { return stored }
        save(migrated)
        return migrated
    }

    func save(_ credentials: Credentials) {
        update(credentials.apiKey, account: "api_key")
        update(credentials.appID, account: "app_id")
        update(credentials.accessKey, account: "access_key")
    }

    private func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func update(_ value: String, account: String) {
        if value.isEmpty {
            delete(account: account)
            return
        }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) != errSecSuccess {
            var item = query
            item[kSecValueData as String] = data
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    private func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
