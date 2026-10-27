//
//  GpsSimSigning.swift
//  StikDebug (GpsSim fork)
//
//  How long until this install's signature runs out. A free Apple ID signs for 7 days; after
//  that iOS will not open the app until it is re-signed (SideStore 「Refresh All」 or the PC's
//  「PinFly續簽」). The date comes from the app's own embedded.mobileprovision, a CMS-signed
//  plist: the XML part is cut out and read, no signature checking is needed for a date.
//

import Foundation

enum GpsSigning {
    /// SideStore registers the `sidestore` URL scheme (its Info.plist, 0.6.0 through develop).
    static let sideStoreURL = URL(string: "sidestore://")!

    /// nil on the simulator / CI (no provisioning profile) and outside the screenshot demo.
    static let embeddedExpiration: Date? = {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-GpsSimDemo"), i + 1 < args.count {
            // Screenshot-only values: 1.5 days triggers the home banner, 6 days only the settings row,
            // 5 hours the 「剩 N 小時」 wording.
            let days: Double
            switch args[i + 1] {
            case "signExpiring", "signNotLoggedIn", "renewRunning", "renewFailed", "settingsSign", "signPending", "settingsSignPending": days = 1.5
            case "signHours": days = 5.1 / 24
            default: days = 6.2
            }
            return Date().addingTimeInterval(days * 86_400)
        }
        #if DEBUG
        // Simulator + GPSSIM_RENEW_MOCK: a fake 1.5-day profile so the 簽名 section (and sign-in sheet) is reachable in CI.
        if MockRenewBackend.isEnabled { return Date().addingTimeInterval(1.5 * 86_400) }
        #endif
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = FileManager.default.contents(atPath: path),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }()

    /// The bundled profile never changes after a swap, so a profile installed by 匯入描述檔 counts too.
    static var expiration: Date? {
        guard let embeddedExpiration else { return nil }
        if let demoRenewedExpiry { return demoRenewedExpiry }
        return GpsProfileRenew.effectiveExpiration(embedded: embeddedExpiration)
    }

    /// Screenshot demo only: the date a fake 立即續簽 "renewed" to (never set outside -GpsSimDemo).
    static var demoRenewedExpiry: Date?

    /// Whole hours left (5.7 hours -> 5).
    static func hoursLeft(now: Date = Date()) -> Int? {
        guard let expiration else { return nil }
        return Int((expiration.timeIntervalSince(now) / 3_600).rounded(.down))
    }

    /// Whole days left (6.4 days -> 6); negative or zero once less than a day is left.
    static func daysLeft(now: Date = Date()) -> Int? {
        guard let expiration else { return nil }
        return Int((expiration.timeIntervalSince(now) / 86_400).rounded(.down))
    }

    static func isExpired(now: Date = Date()) -> Bool {
        guard let expiration else { return false }
        return expiration <= now
    }

    /// 「剩 6 天」/「剩 5 小時」/「剩不到 1 小時」 (under a day says hours: 「剩不到 1 天」 was too vague).
    static func remainingText(now: Date = Date()) -> String? {
        guard let days = daysLeft(now: now), let hours = hoursLeft(now: now) else { return nil }
        if days >= 1 { return "剩 \(days) 天" }
        return hours >= 1 ? "剩 \(hours) 小時" : "剩不到 1 小時"
    }

    /// Settings row: 「簽名到期：10/23 01:26（剩 6 天）」 or 「簽名已過期，需要重簽」.
    static func settingsText(now: Date = Date()) -> String? {
        guard let expiration, let remaining = remainingText(now: now) else { return nil }
        if isExpired(now: now) { return "簽名已過期，需要重簽" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.dateFormat = "M/d HH:mm"
        return "簽名到期：\(f.string(from: expiration))（\(remaining)）"
    }

    /// Home banner shows from 2 days left.
    static func needsWarning(now: Date = Date()) -> Bool {
        guard let days = daysLeft(now: now) else { return false }
        return days <= 2
    }
}
