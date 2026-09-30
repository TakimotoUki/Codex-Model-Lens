import Foundation
import Security
import CryptoKit

public enum CredentialStore {
    private static let service = "app.codex-model-lens.accounts"
    public static func read(_ id: String) throws -> Data? {
        try read(service: service, account: id)
    }
    public static func read(service: String, account: String) throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
        return result as? Data
    }
    public static func save(_ bytes: Data, id: String) throws {
        guard bytes.count <= 128 * 1024 else { throw CredentialError.invalid }
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id] as CFDictionary
        let status = SecItemUpdate(query, [kSecValueData: bytes] as CFDictionary)
        if status == errSecItemNotFound {
            let result = SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id,
                kSecValueData: bytes, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil)
            guard result == errSecSuccess else { throw CredentialError.keychain(result) }
        } else if status != errSecSuccess { throw CredentialError.keychain(status) }
    }
    public static func remove(_ id: String) throws {
        let status = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.keychain(status) }
    }
}
public enum CredentialError: Error, LocalizedError {
    case keychain(OSStatus), invalid
    public var errorDescription: String? {
        switch self { case .keychain(let status): "钥匙串无法访问（\(status)）。请在系统提示中允许访问。"; case .invalid: "凭据格式无效。" }
    }
}
public enum CodexCredentials {
    public static func read(home: URL) throws -> Data {
        let file = home.appendingPathComponent("auth.json")
        let data: Data
        if FileManager.default.fileExists(atPath: file.path) {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size < 128 * 1024 else { throw CredentialError.invalid }
            data = try Data(contentsOf: file)
        } else {
            let canonical = home.resolvingSymlinksInPath().path
            let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
            guard let bytes = try CredentialStore.read(service: "Codex Auth", account: "cli|" + digest.prefix(16)) else { throw OfficialClientError.noLogin }
            data = bytes
        }
        guard isValid(data) else { throw OfficialClientError.noLogin }; return data
    }
    public static func isValid(_ data: Data) -> Bool {
        guard data.count < 128 * 1024, let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = value["tokens"] as? [String: Any], let access = tokens["access_token"] as? String, !access.isEmpty else { return false }
        return value["auth_mode"] as? String == "chatgpt" || value["auth_mode"] == nil
    }
    public static func fingerprint(_ data: Data) -> String {
        // Hashes a stable account identifier when available; no identifiers are written directly.
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let tokens = object?["tokens"] as? [String: Any]
        let identity = (tokens?["account_id"] as? String).map { Data($0.utf8) } ?? data
        return SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }
}
public enum PrivateMetadata {
    public static func save<T: Encodable>(_ value: T, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
