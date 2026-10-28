//
//  GpsSimIntentStatus.swift
//  StikDebug (GpsSim fork) - experimental renew copy
//
//  The one value every GpsSim Shortcut action hands back (spec part 2.2): PinFly狀態.
//  A Shortcut can then branch with 「如果 結果 是 失敗」 or read 簽名剩幾天 / 模擬中 / 目前地點.
//  TransientAppEntity (iOS 16+): built fresh on every run, never looked up by id, never stored.
//

import AppIntents
import Foundation

/// 結果 property. Shown values are what the Shortcuts "If" picker lists.
enum GpsIntentOutcome: String, AppEnum {
    case renewed
    case notNeeded
    case failed
    case succeeded

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "結果"
    static var caseDisplayRepresentations: [GpsIntentOutcome: DisplayRepresentation] = [
        .renewed: "已續簽",
        .notNeeded: "不用續簽",
        .failed: "失敗",
        .succeeded: "成功",
    ]
}

struct GpsSimStatusEntity: TransientAppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "PinFly 狀態"

    @Property(title: "結果")
    var outcome: GpsIntentOutcome

    @Property(title: "簽名到期")
    var signingExpiry: Date?

    /// Whole days left, rounded down (5.9 days -> 5); 0 once expired.
    @Property(title: "簽名剩幾天")
    var daysLeft: Int?

    @Property(title: "簽名剩幾小時")
    var hoursLeft: Int?

    @Property(title: "模擬中")
    var simulating: Bool

    /// Empty when nothing is simulated.
    @Property(title: "目前地點")
    var placeName: String

    /// Empty on success; on failure the same title + advice the renew screen shows.
    @Property(title: "原因")
    var reason: String

    init() {
        outcome = .succeeded
        signingExpiry = nil
        daysLeft = nil
        hoursLeft = nil
        simulating = false
        placeName = ""
        reason = ""
    }

    var displayRepresentation: DisplayRepresentation {
        let outcomeText = Self.label(outcome)
        if !reason.isEmpty {
            return DisplayRepresentation(title: "\(outcomeText)", subtitle: "\(reason)")
        }
        if let daysLeft {
            return DisplayRepresentation(title: "\(outcomeText)", subtitle: "簽名剩 \(daysLeft) 天")
        }
        return DisplayRepresentation(title: "\(outcomeText)")
    }

    static func label(_ outcome: GpsIntentOutcome) -> String {
        switch outcome {
        case .renewed: return "已續簽"
        case .notNeeded: return "不用續簽"
        case .failed: return "失敗"
        case .succeeded: return "成功"
        }
    }
}

// MARK: - Building the value

@MainActor
enum GpsSimIntentStatus {
    /// Reads signing (RenewService, no network) and simulation state (GpsSimEngine) into one value.
    /// `signingExpiry` lets a caller pass a fresher date (e.g. the one renewNow() just read back).
    static func make(_ outcome: GpsIntentOutcome, reason: String = "", signingExpiry: Date? = nil) async -> GpsSimStatusEntity {
        let renew = await RenewService.shared.status()
        var value = GpsSimStatusEntity()
        value.outcome = outcome
        value.reason = reason
        let expiry = signingExpiry ?? renew.profileExpiry
        value.signingExpiry = expiry
        if let expiry {
            let left = max(0, expiry.timeIntervalSinceNow)
            value.daysLeft = Int(left / 86_400)
            value.hoursLeft = Int(left / 3_600)
        }
        let place = currentPlace()
        value.simulating = place != nil
        value.placeName = place?.name ?? ""
        return value
    }

    /// What is simulated right now. After a relaunch (a Shortcut can start the app fresh) activeName
    /// is nil, but the last sent target stays persisted until a stop clears it, so it still counts.
    static func currentPlace() -> (name: String, confirmed: Bool)? {
        let engine = GpsSimEngine.shared
        if let name = engine.activeName { return (name, true) }
        if let stale = engine.staleTarget { return (stale.name, false) }
        return nil
    }

    /// 「簽名到 10/29 17:46，剩 6 天」, or nil when the expiry is unknown.
    static func signingSentence(_ value: GpsSimStatusEntity) -> String? {
        guard let expiry = value.signingExpiry else { return nil }
        let when = GpsProfileRenew.expiryText(expiry)
        if expiry.timeIntervalSinceNow <= 0 { return "簽名已在 \(when) 到期" }
        if let days = value.daysLeft, days >= 1 { return "簽名到 \(when)，剩 \(days) 天" }
        return "簽名到 \(when)，剩 \(value.hoursLeft ?? 0) 小時"
    }
}

/// Thrown only when the user asked a Shortcut to stop on failure (續簽PinFly › 失敗時停止捷徑).
enum GpsSimIntentError: Error, CustomLocalizedStringResourceConvertible {
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .failed(let reason): return "\(reason)"
        }
    }
}
