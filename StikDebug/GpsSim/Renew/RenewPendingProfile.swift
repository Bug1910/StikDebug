//
//  RenewPendingProfile.swift
//  StikDebug (GpsSim fork) - experimental renew copy (PinFly)
//
//  The "downloaded but not installed yet" 7-day profile. Renewing is split in two because on 4G the
//  phone cannot do both halves at once: downloading from Apple needs internet, while installing it
//  (misagent over LocalDevVPN) only works with cellular data OFF. The download step leaves the
//  profile here; the install step picks it up (no Apple / anisette contact) and deletes it once
//  installed. One file in this app's own Application Support folder (not a shared App Group),
//  written atomically and readable while the phone is locked (alarm automations run locked).
//  Profile contents are never logged; only the expiry date is.
//

import Foundation

enum RenewPendingProfile {
    struct Pending: Codable, Sendable {
        /// The profile's ExpirationDate, parsed when it was saved (the mock cannot parse its fake bytes).
        let expiry: Date
        let savedAt: Date
        let profile: Data
    }

    private static func fileURL(mock: Bool) -> URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true) else { return nil }
        let folder = base.appendingPathComponent("GpsSimRenew", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(mock ? "pending-profile-mock.plist" : "pending-profile.plist")
    }

    /// The waiting profile, or nil. An expired one is deleted on the way.
    static func load(mock: Bool) -> Pending? {
        guard let url = fileURL(mock: mock), let data = try? Data(contentsOf: url) else { return nil }
        guard let pending = try? PropertyListDecoder().decode(Pending.self, from: data) else {
            delete(mock: mock)   // unreadable leftovers would block nothing but confuse the status
            return nil
        }
        guard pending.expiry > Date() else {
            RenewDiagLog.write("pending expired (\(GpsProfileRenew.expiryText(pending.expiry))); deleted")
            delete(mock: mock)
            return nil
        }
        return pending
    }

    /// Older than this, a waiting profile is not reused by a download / renew (a fresh one is fetched).
    static let maxAge: TimeInterval = 24 * 3_600
    /// Less validity left than this, likewise (Apple hands out 7 days; a fresh one is clearly better).
    static let minValidity: TimeInterval = 6 * 86_400

    /// Like `load`, but a stale one (see maxAge / minValidity) is deleted and nil returned.
    /// The install step itself uses `load`: an older but still newer profile is better than none.
    static func loadFresh(mock: Bool) -> Pending? {
        guard let pending = load(mock: mock) else { return nil }
        let ageHours = Int(Date().timeIntervalSince(pending.savedAt) / 3_600)
        let leftHours = Int(pending.expiry.timeIntervalSinceNow / 3_600)
        guard Date().timeIntervalSince(pending.savedAt) <= maxAge, pending.expiry.timeIntervalSinceNow >= minValidity else {
            RenewDiagLog.write("pending stale (saved \(ageHours) h ago, \(leftHours) h left); deleted")
            delete(mock: mock)
            return nil
        }
        return pending
    }

    static func save(_ profile: Data, expiry: Date, mock: Bool) throws {
        guard let url = fileURL(mock: mock) else {
            throw RenewProblem(.install, detail: "新描述檔存不進手機（找不到 App 的資料夾）。")
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(Pending(expiry: expiry, savedAt: Date(), profile: profile))
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            throw RenewProblem(.install, detail: "新描述檔存不進手機。")
        }
        RenewDiagLog.write("pending saved (expiry \(GpsProfileRenew.expiryText(expiry)))")
    }

    static func delete(mock: Bool) {
        guard let url = fileURL(mock: mock), FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
        RenewDiagLog.write("pending deleted")
    }

    /// Expiry of the waiting profile (for the status / 「裝上」 button), nil when nothing waits.
    static func expiry(mock: Bool) -> Date? { load(mock: mock)?.expiry }

    /// Cheap check without decoding (the install intent answers "nothing to do" in well under a second).
    static func exists(mock: Bool) -> Bool {
        guard let url = fileURL(mock: mock) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}
