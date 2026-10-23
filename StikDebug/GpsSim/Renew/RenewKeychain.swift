//
//  RenewKeychain.swift
//  StikDebug (GpsSim fork) - experimental renew copy
//
//  The app's own safe box (Keychain, service "tw.gpssim.renew"). Holds only what renewing needs:
//  the Apple sign-in session (dsid + token, never the password), the anisette device id and adi.pb.
//  The mock backend uses a separate service so a simulator run never touches a real session.
//  Nothing stored here is ever logged.
//

import Foundation
import Security

/// What is kept after a successful sign-in. The password is NOT part of it.
struct RenewStoredSession: Codable, Equatable, Sendable {
    var appleID: String
    var dsid: String
    var authToken: String
    var tokenExpiry: Date?
    var xcodeVersion: String
    var signedInAt: Date
    /// SHA-256 of the machine ID the anisette data had at sign-in (diagnostics only; nil for older sessions).
    var anisetteHash: String? = nil

    /// "ab***@gmail.com" style, safe for the screen (never for logs).
    var maskedAppleID: String { RenewKeychain.mask(appleID) }

    var isExpired: Bool {
        guard let tokenExpiry else { return false }
        return tokenExpiry <= Date()
    }
}

enum RenewKeychain {
    static let liveService = "tw.gpssim.renew"
    static let mockService = "tw.gpssim.renew.mock"

    private enum Account: String {
        case session = "session"
        case anisetteIdentifier = "anisette.identifier"
        case adiBlob = "anisette.adi"
    }

    // MARK: - Session

    static func loadSession(service: String) -> RenewStoredSession? {
        guard let data = read(.session, service: service) else { return nil }
        return try? JSONDecoder().decode(RenewStoredSession.self, from: data)
    }

    static func saveSession(_ session: RenewStoredSession, service: String) throws {
        let data = try JSONEncoder().encode(session)
        try write(data, for: .session, service: service)
    }

    static func deleteSession(service: String) {
        delete(.session, service: service)
    }

    // MARK: - Anisette identity (live only)

    /// Stable per install; created on first use.
    static func anisetteIdentifier() throws -> UUID {
        if let data = read(.anisetteIdentifier, service: liveService),
           let text = String(data: data, encoding: .utf8),
           let uuid = UUID(uuidString: text) {
            return uuid
        }
        let fresh = UUID()
        try write(Data(fresh.uuidString.utf8), for: .anisetteIdentifier, service: liveService)
        return fresh
    }

    static var adiBlob: Data? { read(.adiBlob, service: liveService) }

    static func setAdiBlob(_ blob: Data) throws {
        try write(blob, for: .adiBlob, service: liveService)
    }

    /// Forget the anisette identity (a fresh provisioning happens on next use).
    static func resetAnisette() {
        delete(.adiBlob, service: liveService)
        delete(.anisetteIdentifier, service: liveService)
    }

    // MARK: - Helpers

    static func mask(_ appleID: String) -> String {
        let parts = appleID.split(separator: "@", maxSplits: 1).map(String.init)
        guard let name = parts.first, !name.isEmpty else { return "***" }
        let head = String(name.prefix(2))
        return parts.count == 2 ? "\(head)***@\(parts[1])" : "\(head)***"
    }

    private static func baseQuery(_ account: Account, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
    }

    private static func read(_ account: Account, service: String) -> Data? {
        var query = baseQuery(account, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    struct WriteError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "無法寫入鑰匙圈（\(status)）。" }
    }

    private static func write(_ data: Data, for account: Account, service: String) throws {
        let query = baseQuery(account, service: service)
        // AfterFirstUnlock so a Shortcut / App Intent can renew while the phone is locked after the first unlock.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            attributes.forEach { add[$0] = $1 }
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw WriteError(status: added) }
        } else if status != errSecSuccess {
            throw WriteError(status: status)
        }
    }

    private static func delete(_ account: Account, service: String) {
        SecItemDelete(baseQuery(account, service: service) as CFDictionary)
    }
}
