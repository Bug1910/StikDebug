//
//  GpsSimMoveIntentTypes.swift
//  PinFly
//
//  【這個檔案的角色】「前往地點」捷徑動作的選項與換算表（規格 12.3.1）。
//  - 四個 AppEnum：方式、速度、抵達後、漫步範圍。「捷徑」App 以 rawValue 儲存選項，
//    rawValue 永不改名（規格 12.2 第 2 條）；顯示文字可以改。
//  - GpsMoveRequest.make：把捷徑參數換算成一筆「要做什麼」的純資料（可單元測試，不碰手機）。
//    預設參數組合＝舊版「前往地點」的行為（直接前往、不限時間）。
//  - GpsMoveEstimate：剩餘距離、預計抵達、是否超過 12 小時、時間與距離文字（純函式）。
//

import AppIntents
import Foundation

// MARK: - 捷徑選項（AppEnum）

/// 方式。
enum GpsMoveMethod: String, AppEnum {
    case direct
    case route
    case line
    case wander

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "方式"
    static var caseDisplayRepresentations: [GpsMoveMethod: DisplayRepresentation] = [
        .direct: "直接前往",
        .route: "路線",
        .line: "直線",
        .wander: "原地漫步",
    ]
}

/// 速度（路線、直線時使用）。
enum GpsMoveSpeed: String, AppEnum {
    case walk
    case bike
    case drive
    case custom

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "速度"
    static var caseDisplayRepresentations: [GpsMoveSpeed: DisplayRepresentation] = [
        .walk: "步行",
        .bike: DisplayRepresentation(title: "單車", subtitle: "沿步行路線"),
        .drive: "駕車",
        .custom: "自訂",
    ]
}

/// 抵達後（路線、直線時使用）。
enum GpsAfterArrival: String, AppEnum {
    case stay
    case wander
    case stop

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "抵達後"
    static var caseDisplayRepresentations: [GpsAfterArrival: DisplayRepresentation] = [
        .stay: "停留",
        .wander: "原地漫步",
        .stop: "停止模擬",
    ]
}

/// 漫步範圍（方式＝原地漫步時使用）。
enum GpsWanderRange: String, AppEnum {
    case app
    case small
    case medium
    case large

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "漫步範圍"
    static var caseDisplayRepresentations: [GpsWanderRange: DisplayRepresentation] = [
        .app: "依 App 設定",
        .small: "小",
        .medium: "中",
        .large: "大",
    ]
}

// MARK: - 換算（純資料，可測試）

/// 一次「前往地點」要做的事。只由 make() 產生；捷徑層依 kind 分流。
struct GpsMoveRequest: Equatable {
    enum Kind: Equatable {
        case direct
        case route
        case straight
        case wander
    }

    enum Arrival: Equatable {
        case stay
        case wander
        case stopSimulation
    }

    var kind: Kind
    /// 路線、直線才有；向 MKDirections 要哪種路線也看它。
    var speedPreset: MoveSpeedPreset?
    /// 路線、直線才有：實際目標時速（自訂已夾在 3.6～100）。
    var kmh: Double?
    var isCustomSpeed: Bool
    /// 直接前往、原地漫步一律 .stay（抵達後只對路線、直線有意義）。
    var arrival: Arrival
    /// 原地漫步、或抵達後原地漫步時的範圍檔位；其他為 nil。
    var wanderSize: WanderSize?
    /// 持續時間（分鐘，已夾在 1～720）；nil＝不限。抵達後＝停止模擬時一律 nil。
    var durationMinutes: Int?
    /// true＝持續時間自抵達時起算（路線、直線）；false＝自執行時起算（直接前往、原地漫步）。
    var durationFromArrival: Bool

    static let durationRange: ClosedRange<Int> = 1...720
    /// 自訂速度高於此值時改向 MKDirections 要駕車路線（App 內自訂沿用上次的預設，捷徑沒有「上次」）。
    static let customDriveFromKmh: Double = 25

    /// 舊版「前往地點」（只有地點參數）的行為。
    static let legacyDirect = GpsMoveRequest(kind: .direct, speedPreset: nil, kmh: nil, isCustomSpeed: false,
                                             arrival: .stay, wanderSize: nil, durationMinutes: nil,
                                             durationFromArrival: false)

    var durationSeconds: TimeInterval? {
        durationMinutes.map { TimeInterval($0) * 60 }
    }

    static func clampDuration(_ minutes: Int?) -> Int? {
        guard let minutes else { return nil }
        return min(max(minutes, durationRange.lowerBound), durationRange.upperBound)
    }

    static func make(method: GpsMoveMethod, speed: GpsMoveSpeed, customKmh: Double,
                     afterArrival: GpsAfterArrival, wanderRange: GpsWanderRange,
                     appWanderSize: WanderSize, durationMinutes: Int?) -> GpsMoveRequest {
        let minutes = clampDuration(durationMinutes)
        switch method {
        case .direct:
            return GpsMoveRequest(kind: .direct, speedPreset: nil, kmh: nil, isCustomSpeed: false,
                                  arrival: .stay, wanderSize: nil, durationMinutes: minutes,
                                  durationFromArrival: false)
        case .wander:
            let size: WanderSize
            switch wanderRange {
            case .app: size = appWanderSize
            case .small: size = .small
            case .medium: size = .medium
            case .large: size = .large
            }
            return GpsMoveRequest(kind: .wander, speedPreset: nil, kmh: nil, isCustomSpeed: false,
                                  arrival: .stay, wanderSize: size, durationMinutes: minutes,
                                  durationFromArrival: false)
        case .route, .line:
            let preset: MoveSpeedPreset
            let kmh: Double
            switch speed {
            case .walk: preset = .walk; kmh = MoveSpeedPreset.walk.kmh
            case .bike: preset = .bike; kmh = MoveSpeedPreset.bike.kmh
            case .drive: preset = .drive; kmh = MoveSpeedPreset.drive.kmh
            case .custom:
                kmh = MoveSpeedPreset.clampCustom(customKmh)
                preset = kmh > customDriveFromKmh ? .drive : .walk
            }
            let arrival: Arrival
            switch afterArrival {
            case .stay: arrival = .stay
            case .wander: arrival = .wander
            case .stop: arrival = .stopSimulation
            }
            return GpsMoveRequest(kind: method == .route ? .route : .straight, speedPreset: preset, kmh: kmh,
                                  isCustomSpeed: speed == .custom, arrival: arrival,
                                  wanderSize: arrival == .wander ? appWanderSize : nil,
                                  durationMinutes: arrival == .stopSimulation ? nil : minutes,
                                  durationFromArrival: true)
        }
    }

    /// App 內「原地漫步」上次選的檔位（GpsSimHomeView 的 @AppStorage("gpsSim.wanderSize")）。
    static func appWanderSize(_ defaults: UserDefaults = .standard) -> WanderSize {
        defaults.string(forKey: "gpsSim.wanderSize").flatMap(WanderSize.init(rawValue:)) ?? .medium
    }

    /// 完成訊息用的速度文字：「步行」「自訂 6 km/h」。
    var speedLabel: String {
        if isCustomSpeed, let kmh { return "自訂 \(Int(kmh.rounded())) km/h" }
        return speedPreset?.label ?? ""
    }
}

// MARK: - 估算（純函式，可測試）

enum GpsMoveEstimate {
    /// 單趟移動上限（規格錯誤 23）。
    static let maxTravelSeconds: TimeInterval = 12 * 3600

    /// 剩餘公尺（四捨五入，永不為負）。
    static func remainingMeters(total: Double, traveled: Double) -> Int {
        guard total.isFinite, traveled.isFinite else { return 0 }
        return max(0, Int((total - traveled).rounded()))
    }

    /// 依目前目標速度推算的抵達時間；速度 ≤ 0 時無法推算。
    static func eta(remainingMeters: Double, kmh: Double, now: Date) -> Date? {
        guard kmh > 0, remainingMeters.isFinite else { return nil }
        return now.addingTimeInterval(max(0, remainingMeters) / (kmh / 3.6))
    }

    static func travelSeconds(meters: Double, kmh: Double) -> TimeInterval {
        guard kmh > 0 else { return .infinity }
        return max(0, meters) / (kmh / 3.6)
    }

    static func isTooLong(meters: Double, kmh: Double) -> Bool {
        travelSeconds(meters: meters, kmh: kmh) > maxTravelSeconds
    }

    /// 「2.3 公里」或「850 公尺」。
    static func distanceText(_ meters: Double) -> String {
        if meters >= 1000 { return String(format: "%.1f 公里", meters / 1000) }
        return "\(Int(max(0, meters).rounded())) 公尺"
    }

    /// 同一天寫「14:32」，跨日寫「11/4 14:32」。
    static func clockText(_ date: Date, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "M/d HH:mm"
        return f.string(from: date)
    }
}
