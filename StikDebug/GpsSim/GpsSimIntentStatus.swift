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
        .notNeeded: "不需要續簽",
        .failed: "失敗",
        .succeeded: "成功",
    ]
}

/// 移動狀態 property（規格 12.4，只增不改）。rawValue 永不改名。
enum GpsMoveStatus: String, AppEnum {
    case idle
    case moving
    case paused
    case arrived
    case wandering

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "移動狀態"
    static var caseDisplayRepresentations: [GpsMoveStatus: DisplayRepresentation] = [
        .idle: "未移動",
        .moving: "移動中",
        .paused: "已暫停",
        .arrived: "已抵達",
        .wandering: "漫步中",
    ]

    init(_ state: MoveState) {
        switch state {
        case .idle: self = .idle
        case .moving: self = .moving
        case .paused: self = .paused
        case .arrived: self = .arrived
        case .wandering: self = .wandering
        }
    }
}

struct GpsSimStatusEntity: TransientAppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "PinFly 狀態"

    @Property(title: "結果")
    var outcome: GpsIntentOutcome

    @Property(title: "簽名到期")
    var signingExpiry: Date?

    /// Whole days left, rounded down (5.9 days -> 5); 0 once expired.
    @Property(title: "簽名剩餘天數")
    var daysLeft: Int?

    @Property(title: "簽名剩餘小時數")
    var hoursLeft: Int?

    @Property(title: "模擬中")
    var simulating: Bool

    /// Empty when nothing is simulated.
    @Property(title: "目前地點")
    var placeName: String

    /// Empty on success; on failure the same title + advice the renew screen shows.
    @Property(title: "原因")
    var reason: String

    /// 路線、直線、原地漫步的狀態（App 內或捷徑開始的都算）。
    @Property(title: "移動狀態")
    var moveStatus: GpsMoveStatus

    /// 移動或漫步的地點名稱；未移動時為空。
    @Property(title: "目的地")
    var destinationName: String

    /// 路線、直線移動中（含暫停）才有值。
    @Property(title: "剩餘距離（公尺）")
    var remainingMeters: Int?

    /// 依目前速度推算；暫停時為空。
    @Property(title: "預計抵達")
    var arrivalTime: Date?

    /// 捷徑設定了持續時間時，回到真實位置的時間。
    @Property(title: "預計結束")
    var endTime: Date?

    init() {
        outcome = .succeeded
        signingExpiry = nil
        daysLeft = nil
        hoursLeft = nil
        simulating = false
        placeName = ""
        reason = ""
        moveStatus = .idle
        destinationName = ""
        remainingMeters = nil
        arrivalTime = nil
        endTime = nil
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
        case .notNeeded: return "不需要續簽"
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
        let mover = GpsSimRouteMover.shared
        value.moveStatus = GpsMoveStatus(mover.state)
        value.destinationName = value.moveStatus == .idle ? "" : (mover.destinationName ?? "")
        value.remainingMeters = mover.remainingMeters
        value.arrivalTime = mover.estimatedArrival
        value.endTime = GpsSimAutoReturn.shared.deadline
        return value
    }

    /// 「目前模擬狀態」的完成訊息（規格 12.4）。
    static func statusSentence(_ value: GpsSimStatusEntity) -> String {
        let name = value.destinationName
        let endNote = value.endTime.map { "將於 \(GpsMoveEstimate.clockText($0)) 回到真實位置。" } ?? ""
        switch value.moveStatus {
        case .moving:
            var text = "移動中：前往 \(name)"
            if let left = value.remainingMeters { text += "，剩餘 \(GpsMoveEstimate.distanceText(Double(left)))" }
            if let eta = value.arrivalTime { text += "，預計 \(GpsMoveEstimate.clockText(eta)) 抵達" }
            return text + "。" + endNote
        case .paused:
            var text = "移動已暫停：前往 \(name)"
            if let left = value.remainingMeters { text += "，剩餘 \(GpsMoveEstimate.distanceText(Double(left)))" }
            return text + "。" + endNote
        case .wandering:
            return "漫步中：\(name)。" + endNote
        case .idle, .arrived:
            guard let place = currentPlace() else { return "未在模擬。" }
            // After a relaunch only the persisted last target is known; a stop always clears it.
            let note = place.confirmed ? "" : "（PinFly 曾重新開啟，此為上次送出的地點）"
            return "模擬中：\(place.name)。\(note)" + endNote
        }
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
