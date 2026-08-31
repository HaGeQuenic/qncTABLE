import Foundation
import CryptoKit
import Security

struct SecureSettingsStore {
    private let service = "qncTABLE.settings.encryption"
    private let account = "encryption-key"
    private let fileName = "settings.enc"

    // MARK: Public API
    func load() throws -> AppSettings {
        let url = try settingsFileURL()
        let data = try Data(contentsOf: url)
        let key = try fetchOrCreateSymmetricKey()
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        let decrypted = try AES.GCM.open(sealedBox, using: key)
        return try JSONDecoder().decode(AppSettings.self, from: decrypted)
    }

    func save(_ settings: AppSettings) throws {
        let url = try settingsFileURL()
        let key = try fetchOrCreateSymmetricKey()
        let json = try JSONEncoder().encode(settings)
        let sealed = try AES.GCM.seal(json, using: key)
        let combined = sealed.combined!
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try combined.write(to: url, options: .atomic)
    }

    // MARK: - File URL
    private func settingsFileURL() throws -> URL {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return dir.appendingPathComponent(fileName)
    }

    // MARK: - Keychain
    private func fetchOrCreateSymmetricKey() throws -> SymmetricKey {
        if let keyData = try readKeyFromKeychain() {
            return SymmetricKey(data: keyData)
        }
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        try storeKeyInKeychain(keyData)
        return key
    }

    private func readKeyFromKeychain() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess {
            return item as? Data
        } else if status == errSecItemNotFound {
            return nil
        } else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private func storeKeyInKeychain(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
