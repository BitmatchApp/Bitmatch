// KeychainHelper.swift - Simple Keychain wrapper for sensitive data
// Security 17: store bookmark data in Keychain instead of UserDefaults
import Foundation
import Security

enum KeychainHelper {
    private static let service = "com.bitmatch.app"

    static func save(_ data: Data, forKey key: String) -> Bool {
        // Delete any existing item first
        delete(forKey: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func load(forKey key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func save(_ value: String, forKey key: String) -> Bool {
        save(Data(value.utf8), forKey: key)
    }

    @discardableResult
    static func delete(forKey key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Sensitive SFTP authentication material. This type intentionally does not
/// conform to `Codable`, so credentials cannot enter Core Data payloads.
struct RemoteCredential: Equatable, Sendable {
    let password: String

    init(password: String) {
        self.password = password
    }

    /// OpenSSH agent authentication carries no secret through BitMatch.  The
    /// empty marker is retained only to preserve the provider-boundary shape
    /// while profiles migrate away from stored passwords.
    static let sshAgent = RemoteCredential(password: "")

    var isSSHAgentOnly: Bool { password.isEmpty }
}

enum RemoteCredentialStoreError: Error, Equatable {
    case keychainWriteFailed
    case keychainDeleteFailed
    case corruptCredential
}

/// Stores remote credentials exclusively in the Keychain. Core Data may retain
/// the returned account name as an opaque reference, but never credential data.
struct RemoteCredentialStore {
    typealias SaveData = (Data, String) -> Bool
    typealias LoadData = (String) -> Data?
    typealias DeleteData = (String) -> Bool

    private let saveData: SaveData
    private let loadData: LoadData
    private let deleteData: DeleteData

    init(
        saveData: @escaping SaveData = { data, account in
            KeychainHelper.save(data, forKey: account)
        },
        loadData: @escaping LoadData = { account in
            KeychainHelper.load(forKey: account)
        },
        deleteData: @escaping DeleteData = { account in
            KeychainHelper.delete(forKey: account)
        }
    ) {
        self.saveData = saveData
        self.loadData = loadData
        self.deleteData = deleteData
    }

    func accountName(for profileID: UUID) -> String {
        "remote-profile.\(profileID.uuidString.lowercased())"
    }

    func save(_ credential: RemoteCredential, for profileID: UUID) throws {
        guard saveData(Data(credential.password.utf8), accountName(for: profileID)) else {
            throw RemoteCredentialStoreError.keychainWriteFailed
        }
    }

    func credential(for profileID: UUID) throws -> RemoteCredential? {
        guard let data = loadData(accountName(for: profileID)) else { return nil }
        guard let password = String(data: data, encoding: .utf8) else {
            throw RemoteCredentialStoreError.corruptCredential
        }
        return RemoteCredential(password: password)
    }

    func deleteCredential(for profileID: UUID) throws {
        guard deleteData(accountName(for: profileID)) else {
            throw RemoteCredentialStoreError.keychainDeleteFailed
        }
    }
}
