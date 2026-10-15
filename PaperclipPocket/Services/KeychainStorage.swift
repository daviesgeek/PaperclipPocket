import Foundation
import Security

enum KeychainStorage {
    private static let service = "dev.paperclippocket.configuration"
    private static let account = "default"

    static func load() -> AppConfiguration {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let config = try? JSONDecoder().decode(AppConfiguration.self, from: data)
        else { return AppConfiguration() }
        return config
    }

    static func save(_ config: AppConfiguration) throws {
        let data = try JSONEncoder().encode(config)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let result = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard result == errSecSuccess else { throw KeychainError.status(result) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }

    enum KeychainError: LocalizedError {
        case status(OSStatus)
        var errorDescription: String? { "Could not save settings securely (\(self))." }
    }
}
