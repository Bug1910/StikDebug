//
//  GpsSimItinerary.swift
//  PinFly
//
//  【這個檔案的角色】「預排行程」的資料本＋時刻表計算機（規格 10.1、10.2.1、10.7）。
//  - 資料型別：ItinCoord（座標）、ItinStartRule（開始方式）、ItinEvent（一個項目）、
//    Itinerary（一個行程）、ItineraryFile（存檔外殼）。全部 Codable、扁平。
//  - ItinSchedule：純函式（不碰手機、不碰網路），算每個項目幾點開始／結束、現在該在第幾項、
//    移動走了幾公尺、行程能不能儲存（錯誤 30～36）。單元測試直接呼叫。
//  - GpsItineraryStore：把行程存在 Application Support/itineraries.json（原子寫入），
//    壞檔改名 .corrupt（同 GpsSimPlaces.swift 的作法）。
//
//  【為什麼這樣設計】
//  - CLLocationCoordinate2D 不是 Codable，另做 ItinCoord{lat,lon}。
//  - 每個 init(from:) 都用 decodeIfPresent＋預設值：舊版存檔、匯入檔少欄位也讀得進來
//    （dateMode 缺＝today、routeKey／cachedPath 缺＝沒有快取）。
//  - 不取 Event／Timeline／Schedule 這類裸名，避免和系統框架型別撞名（工程規劃第四節）。
//  - 專案是 Swift 5 語言模式、沒有預設 MainActor 隔離，所以頂層 enum 本來就不屬於任何 actor
//    （＝規劃寫的 nonisolated enum），不另加 nonisolated 關鍵字。
//
//  - ItinTransfer：匯入匯出用的 11.3 格式（加 name、date_mode；不含 cachedPath），
//    匯入時不默默修改：每個調整都寫進 adjustments 給畫面列出（規格 10.6.9）。
//  - ItinMessage：錯誤 30～38 的完整文字（格式「發生了什麼。下一步怎麼做。（錯誤 N）」）。
//  - Store 每次存檔後通知 App Shortcuts 更新行程清單（捷徑「開始行程」的片語參數）。
//

import AppIntents
import Foundation
import CoreLocation

// MARK: - 座標

/// 可存檔的座標（CLLocationCoordinate2D 不是 Codable）。
struct ItinCoord: Codable, Equatable, Hashable {
    var lat: Double
    var lon: Double

    init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.lat = coordinate.latitude
        self.lon = coordinate.longitude
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private enum CodingKeys: String, CodingKey {
        case lat, lon
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 座標缺任何一個就沒意義 → 一律丟錯，讓上層決定略過或判定壞檔。
        guard let lat = try c.decodeIfPresent(Double.self, forKey: .lat),
              let lon = try c.decodeIfPresent(Double.self, forKey: .lon) else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath,
                                                    debugDescription: "ItinCoord 缺少 lat 或 lon"))
        }
        self.lat = lat
        self.lon = lon
    }
}

// MARK: - 開始方式

/// 「在 HH:mm」或「接續上一項」（第一項的「接續上一項」＝「開始行程時」）。
struct ItinStartRule: Codable, Equatable {
    enum Kind: String, Codable {
        case at
        case afterPrevious
    }

    var kind: Kind
    /// kind == .at 時使用；存 UTC。dateMode == .today 時只取它在行程時區下的時與分。
    var at: Date?

    init(kind: Kind, at: Date? = nil) {
        self.kind = kind
        self.at = at
    }

    static let afterPreviousRule = ItinStartRule(kind: .afterPrevious)

    private enum CodingKeys: String, CodingKey {
        case kind, at
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let at = try c.decodeIfPresent(Date.self, forKey: .at)
        let raw = try c.decodeIfPresent(String.self, forKey: .kind)
        // 缺 kind：有時間就當「在 HH:mm」，否則「接續上一項」。未知值同樣處理。
        self.kind = raw.flatMap(Kind.init(rawValue:)) ?? (at != nil ? .at : .afterPrevious)
        self.at = at
    }
}

// MARK: - 項目

/// 項目類型：停留／移動／原地漫步／停止模擬（rawValue 寫進檔案，永不改）。
enum ItinEventType: String, Codable, CaseIterable {
    case move
    case wander
    case stay
    case stop
}

/// 移動項目怎麼走（行程只有這兩種；漫步是獨立的項目類型）。
enum ItinMoveMode: String, Codable, CaseIterable {
    case route
    case straight

    var moveMode: MoveMode {
        switch self {
        case .route: return .route
        case .straight: return .straight
        }
    }
}

/// 行程中的一個項目。
struct ItinEvent: Codable, Equatable, Identifiable {
    var id: String
    var type: ItinEventType
    var startRule: ItinStartRule
    /// 連到「地點」的 id；地點被刪除後仍用 coord 副本執行。
    var placeID: String?
    var placeName: String?
    /// 停留／漫步＝位置（中心）；移動＝終點；停止模擬＝nil。
    var coord: ItinCoord?
    var moveMode: ItinMoveMode
    /// 決定速度與路線類型（單車借步行路線）；customKmh 有值時速度改用自訂。
    var speedPreset: MoveSpeedPreset
    /// 自訂速度 3.6～100 km/h；nil＝用 speedPreset。
    var customKmh: Double?
    var wanderRadius: WanderSize
    /// 停留：1～720 或 nil（直到下一項）；漫步：1～240（必填）；移動／停止模擬不用。
    var minutes: Int?
    /// 儲存行程時規劃好的路線（不匯出）。
    var cachedPath: [ItinCoord]?
    /// 規劃 cachedPath 時的 routeKey；與目前值不同＝快取過期。
    var routeKey: String?

    init(id: String = UUID().uuidString,
         type: ItinEventType,
         startRule: ItinStartRule = .afterPreviousRule,
         placeID: String? = nil,
         placeName: String? = nil,
         coord: ItinCoord? = nil,
         moveMode: ItinMoveMode = .route,
         speedPreset: MoveSpeedPreset = .walk,
         customKmh: Double? = nil,
         wanderRadius: WanderSize = .medium,
         minutes: Int? = nil,
         cachedPath: [ItinCoord]? = nil,
         routeKey: String? = nil) {
        self.id = id
        self.type = type
        self.startRule = startRule
        self.placeID = placeID
        self.placeName = placeName
        self.coord = coord
        self.moveMode = moveMode
        self.speedPreset = speedPreset
        self.customKmh = customKmh
        self.wanderRadius = wanderRadius
        self.minutes = minutes
        self.cachedPath = cachedPath
        self.routeKey = routeKey
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, startRule, placeID, placeName, coord, moveMode, speedPreset, customKmh,
             wanderRadius, minutes, cachedPath, routeKey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try c.decodeIfPresent(String.self, forKey: .type)
        guard let rawType, let parsedType = ItinEventType(rawValue: rawType) else {
            // 未知類型不猜：丟錯，由 Itinerary 的解碼略過這一項（見 Itinerary.init(from:)）。
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath,
                                                    debugDescription: "未知的項目類型 \(rawType ?? "nil")"))
        }
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.type = parsedType
        self.startRule = try c.decodeIfPresent(ItinStartRule.self, forKey: .startRule) ?? .afterPreviousRule
        self.placeID = try c.decodeIfPresent(String.self, forKey: .placeID)
        self.placeName = try c.decodeIfPresent(String.self, forKey: .placeName)
        self.coord = try c.decodeIfPresent(ItinCoord.self, forKey: .coord)
        self.moveMode = (try c.decodeIfPresent(String.self, forKey: .moveMode))
            .flatMap(ItinMoveMode.init(rawValue:)) ?? .route
        self.speedPreset = (try c.decodeIfPresent(String.self, forKey: .speedPreset))
            .flatMap(MoveSpeedPreset.init(rawValue:)) ?? .walk
        self.customKmh = try c.decodeIfPresent(Double.self, forKey: .customKmh)
        self.wanderRadius = (try c.decodeIfPresent(String.self, forKey: .wanderRadius))
            .flatMap(WanderSize.init(rawValue:)) ?? .medium
        self.minutes = try c.decodeIfPresent(Int.self, forKey: .minutes)
        self.cachedPath = try c.decodeIfPresent([ItinCoord].self, forKey: .cachedPath)
        self.routeKey = try c.decodeIfPresent(String.self, forKey: .routeKey)
    }

    /// 實際速度（km/h）：自訂優先（夾在 3.6～100），否則預設檔位。
    var effectiveKmh: Double {
        if let customKmh { return MoveSpeedPreset.clampCustom(customKmh) }
        return speedPreset.kmh
    }

    /// 依「起點＋終點＋移動方式（含路線類型）」組出的快取鍵。
    /// 起點、終點座標取 5 位小數（約 1 公尺）；單車與步行同屬步行路線，互換不會讓快取過期。
    static func routeKey(from origin: ItinCoord, to destination: ItinCoord,
                         moveMode: ItinMoveMode, speedPreset: MoveSpeedPreset) -> String {
        let way: String
        switch moveMode {
        case .straight:
            way = "straight"
        case .route:
            // 同 MoveSpeedPreset.transportType：只有駕車走汽車路線，步行／單車都走步行路線。
            way = speedPreset == .drive ? "route-automobile" : "route-walking"
        }
        return String(format: "%.5f,%.5f>%.5f,%.5f|", origin.lat, origin.lon, destination.lat, destination.lon) + way
    }

    /// 以 origin（上一項的終點）算出本項目前應有的 routeKey；不是移動或缺座標＝nil。
    func expectedRouteKey(from origin: ItinCoord?) -> String? {
        guard type == .move, let origin, let coord else { return nil }
        return Self.routeKey(from: origin, to: coord, moveMode: moveMode, speedPreset: speedPreset)
    }

    /// cachedPath 可直接使用：有路徑（≥2 點）且 routeKey 與目前值相同。
    func hasValidCachedPath(from origin: ItinCoord?) -> Bool {
        guard let cachedPath, cachedPath.count >= 2, let routeKey,
              let expected = expectedRouteKey(from: origin) else { return false }
        return routeKey == expected
    }
}

// MARK: - 行程

/// 日期模式：today＝開始當天（只看時與分，預設）／fixed＝指定日期。
enum ItinDateMode: String, Codable, CaseIterable {
    case today
    case fixed
}

struct Itinerary: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    /// 建立時＝手機時區；計算「在 HH:mm」一律用這個時區。
    var timeZoneID: String
    var events: [ItinEvent]
    var updatedAt: Date
    var dateMode: ItinDateMode

    init(id: String = UUID().uuidString,
         name: String,
         timeZoneID: String = TimeZone.current.identifier,
         events: [ItinEvent] = [],
         updatedAt: Date = Date(),
         dateMode: ItinDateMode = .today) {
        self.id = id
        self.name = name
        self.timeZoneID = timeZoneID
        self.events = events
        self.updatedAt = updatedAt
        self.dateMode = dateMode
    }

    /// timeZoneID 無效時退回手機時區。
    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }

    private enum CodingKeys: String, CodingKey {
        case id, name, timeZoneID, events, updatedAt, dateMode
    }

    /// 解碼時逐項嘗試，未知類型或壞掉的項目略過，不讓整個行程讀不進來。
    private struct LossyEvent: Decodable {
        let value: ItinEvent?
        init(from decoder: Decoder) throws {
            value = try? ItinEvent(from: decoder)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.timeZoneID = try c.decodeIfPresent(String.self, forKey: .timeZoneID) ?? TimeZone.current.identifier
        let lossy = try c.decodeIfPresent([LossyEvent].self, forKey: .events) ?? []
        self.events = lossy.compactMap { $0.value }
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        self.dateMode = (try c.decodeIfPresent(String.self, forKey: .dateMode))
            .flatMap(ItinDateMode.init(rawValue:)) ?? .today
    }
}

/// App 內部存檔外殼（不是匯入匯出格式；匯入匯出見 ItinTransfer／規格 11.3）。
struct ItineraryFile: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var itineraries: [Itinerary]

    init(version: Int = ItineraryFile.currentVersion, itineraries: [Itinerary] = []) {
        self.version = version
        self.itineraries = itineraries
    }

    private enum CodingKeys: String, CodingKey {
        case version, itineraries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? ItineraryFile.currentVersion
        self.itineraries = try c.decodeIfPresent([Itinerary].self, forKey: .itineraries) ?? []
    }

    /// 存檔用的編碼器／解碼器：日期一律 ISO 8601。
    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

// MARK: - 時刻表計算（純函式）

/// 一個項目的預估開始／結束時間；end == nil＝「直到下一項／直到停止行程」。
struct ItinSlot: Equatable {
    var start: Date
    var end: Date?
}

/// 「現在在第幾項、該項已進行多久」。
struct ItinCursor: Equatable {
    var index: Int
    var offset: TimeInterval
}

enum ItinResolution: Equatable {
    case notYet
    case current(ItinCursor)
    case finished
}

/// 驗證結果（錯誤 30～36）；訊息文字由畫面依 code 與欄位組（規格 10.6.7）。
struct ItinIssue: Equatable {
    enum Severity: Equatable {
        /// 無法儲存（31 為無法新增）
        case blocking
        /// 可儲存（35）
        case warning
    }

    var code: Int
    var severity: Severity
    /// 出錯的項目（0 起算）；nil＝整個行程。
    var eventIndex: Int?
    /// 相關的另一個項目（35：被趕不上的下一項；36：比較的上一項）。
    var relatedIndex: Int?
    /// 35：預計抵達時間；34／36：推算的建議時間。
    var suggestedDate: Date?
    /// 35：被趕不上的下一項開始時間；36：比較的上一項開始時間。
    var relatedDate: Date?
}

enum ItinSchedule {
    static let maxEvents = 20
    static let maxMoveSeconds: TimeInterval = 12 * 3600
    static let maxTotalSeconds: TimeInterval = 24 * 3600
    static let stayMinuteRange: ClosedRange<Int> = 1...720
    static let wanderMinuteRange: ClosedRange<Int> = 1...240
    /// today 模式第一項「在 HH:mm」最多算到 anchor 前幾秒；再早就當隔天（跨午夜）。
    static let firstItemLookBack: TimeInterval = 12 * 3600

    /// 每個項目結束時手機所在位置（停止模擬之後＝nil＝未知）。
    static func endpoints(of events: [ItinEvent]) -> [ItinCoord?] {
        var result: [ItinCoord?] = []
        var last: ItinCoord?
        for e in events {
            switch e.type {
            case .stay, .wander, .move:
                if let c = e.coord { last = c }
            case .stop:
                last = nil
            }
            result.append(last)
        }
        return result
    }

    /// 每個項目開始時手機所在位置（＝上一項的終點）。
    static func origins(of events: [ItinEvent]) -> [ItinCoord?] {
        let ends = endpoints(of: events)
        return events.indices.map { $0 == 0 ? nil : ends[$0 - 1] }
    }

    /// 移動項目預估秒數（有效快取用路線長度，否則直線距離）；非移動或起點未知＝nil。
    static func moveDurations(events: [ItinEvent]) -> [TimeInterval?] {
        let froms = origins(of: events)
        return events.indices.map { i -> TimeInterval? in
            let e = events[i]
            guard e.type == .move, let origin = froms[i], let dest = e.coord else { return nil }
            let meters: Double
            if e.hasValidCachedPath(from: origin), let path = e.cachedPath {
                meters = pathMeters(path)
            } else {
                meters = GpsGeo.meters(origin.clCoordinate, dest.clCoordinate)
            }
            let mps = e.effectiveKmh / 3.6
            return mps > 0 ? meters / mps : nil
        }
    }

    static func pathMeters(_ path: [ItinCoord]) -> Double {
        guard path.count >= 2 else { return 0 }
        var total = 0.0
        for i in 1..<path.count {
            total += GpsGeo.meters(path[i - 1].clCoordinate, path[i].clCoordinate)
        }
        return total
    }

    /// 依序算出每個項目的預估開始／結束時間。
    /// - anchor：「開始行程時」的時間，也是 today 模式「當天」的基準。
    /// - durations：與 events 對齊的移動秒數（moveDurations(events:) 的結果；非移動填 nil）。
    /// - shift：最後加到所有時間上（捷徑「立即／延後」把整串平移用）。
    static func compute(events: [ItinEvent], anchor: Date, durations: [TimeInterval?],
                        dateMode: ItinDateMode = .today, timeZone: TimeZone = .current,
                        shift: TimeInterval = 0) -> [ItinSlot] {
        var slots: [ItinSlot] = []
        var previousStart: Date?
        var previousEnd: Date?
        for (i, e) in events.enumerated() {
            let begin: Date
            if e.startRule.kind == .at, let fixedAt = e.startRule.at {
                switch dateMode {
                case .fixed:
                    begin = fixedAt
                case .today:
                    // 第一項沒有上一項可比：早於 anchor 超過 12 小時＝指的是隔天（例：23:58 開始、第一項 00:01）；
                    // 只早一點（例：14:05 開始、第一項 14:00）仍算今天已過，交給「從目前的項目接續」處理（10.6.8）。
                    let earliest: Date? = i == 0 ? anchor.addingTimeInterval(-firstItemLookBack) : previousStart
                    begin = todayTime(fixedAt, onDayOf: anchor, notBefore: earliest, timeZone: timeZone)
                }
            } else if i == 0 {
                begin = anchor
            } else {
                // 上一項沒有結束時間（直到下一項）時不合法，退回上一項的開始以免當掉（validate 另報）。
                begin = previousEnd ?? previousStart ?? anchor
            }
            let finish: Date?
            switch e.type {
            case .stay:
                finish = e.minutes.map { begin.addingTimeInterval(TimeInterval($0) * 60) }
            case .wander:
                finish = begin.addingTimeInterval(TimeInterval(e.minutes ?? 0) * 60)
            case .move:
                let secs = i < durations.count ? (durations[i] ?? 0) : 0
                finish = begin.addingTimeInterval(secs)
            case .stop:
                finish = begin
            }
            slots.append(ItinSlot(start: begin, end: finish))
            previousStart = begin
            previousEnd = finish
        }
        // 停留「直到下一項」：下一項是「在 HH:mm」時，結束＝下一項開始。
        for i in slots.indices where slots[i].end == nil && i + 1 < slots.count {
            slots[i].end = slots[i + 1].start
        }
        guard shift != 0 else { return slots }
        return slots.map { ItinSlot(start: $0.start.addingTimeInterval(shift),
                                    end: $0.end?.addingTimeInterval(shift)) }
    }

    /// today 模式：取 at 在 timeZone 下的時與分，放到 anchor 那一天；早於 floor（上一項開始）＝隔天。
    static func todayTime(_ at: Date, onDayOf anchor: Date, notBefore floor: Date?,
                          timeZone: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let hm = cal.dateComponents([.hour, .minute], from: at)
        let day = cal.startOfDay(for: anchor)
        var result = cal.date(bySettingHour: hm.hour ?? 0, minute: hm.minute ?? 0, second: 0, of: day) ?? at
        if let floor {
            var bumps = 0
            while result < floor && bumps < 2 {
                result = cal.date(byAdding: .day, value: 1, to: result) ?? result.addingTimeInterval(86_400)
                bumps += 1
            }
        }
        return result
    }

    /// 現在應在第幾項、該項已進行多久；或尚未開始／全部結束。
    /// 移動提早抵達、等下一個「在 HH:mm」時仍回該移動項目（offset ≥ 移動時間＝停在終點等候）。
    /// ⚠️ 注意兩種「跳過」：(1) 最後一項是「停止模擬」（長度 0）時，到它的開始時間就回 .finished；
    /// (2) 多個項目同一時刻開始時只回最後一個。呼叫端（Runner）換項時要把中間沒分派過的項目
    /// （尤其是停止模擬）補做，不能只看回傳的 index。
    static func resolve(slots: [ItinSlot], now: Date) -> ItinResolution {
        guard let first = slots.first else { return .finished }
        if now < first.start { return .notYet }
        var index = 0
        for i in slots.indices where slots[i].start <= now { index = i }
        let slot = slots[index]
        if index == slots.count - 1, let end = slot.end, now >= end {
            return .finished
        }
        return .current(ItinCursor(index: index, offset: now.timeIntervalSince(slot.start)))
    }

    /// 移動項目進行 offset 秒時已走幾公尺（夾在 0～total）。
    static func metersAt(offset: TimeInterval, kmh: Double, total: Double) -> Double {
        guard offset.isFinite, kmh.isFinite, total.isFinite, total > 0 else { return 0 }
        let meters = max(offset, 0) * kmh / 3.6
        return min(max(meters, 0), total)
    }

    /// 驗證行程（錯誤 30～36）。anchor 只用來推算時間（today 模式的「當天」）。
    static func validate(_ itinerary: Itinerary, anchor: Date) -> [ItinIssue] {
        let events = itinerary.events
        var issues: [ItinIssue] = []
        guard !events.isEmpty else { return issues }

        if events.count > maxEvents {
            issues.append(ItinIssue(code: 31, severity: .blocking, eventIndex: nil))
        }
        if events[0].type != .stay && events[0].type != .wander {
            issues.append(ItinIssue(code: 30, severity: .blocking, eventIndex: 0))
        }

        let durations = moveDurations(events: events)
        let slots = compute(events: events, anchor: anchor, durations: durations,
                            dateMode: itinerary.dateMode, timeZone: itinerary.timeZone)

        for i in events.indices {
            let e = events[i]
            if e.type == .move, let secs = durations[i], secs > maxMoveSeconds {
                issues.append(ItinIssue(code: 32, severity: .blocking, eventIndex: i))
            }
            if i > 0, events[i - 1].type == .stop {
                let ok = (e.type == .stay || e.type == .wander) && e.startRule.kind == .at
                if !ok {
                    issues.append(ItinIssue(code: 34, severity: .blocking, eventIndex: i,
                                            suggestedDate: slots[i].start))
                }
            }
            if e.type == .move, i + 1 < events.count, events[i + 1].startRule.kind == .at,
               let arrive = slots[i].end, arrive > slots[i + 1].start {
                issues.append(ItinIssue(code: 35, severity: .warning, eventIndex: i,
                                        relatedIndex: i + 1, suggestedDate: arrive,
                                        relatedDate: slots[i + 1].start))
            }
            // 「直到下一項」的停留，下一項卻是「接續上一項」→ 停留長度無法決定（compute 會算成 0、
            // 執行時被跳過）。歸在 36（時間順序類）：relatedIndex 在 eventIndex 之後＝這一種，
            // ItinMessage 依此選文字。兩種日期模式都檢查。
            if e.type == .stay, e.minutes == nil, !untilNextAllowed(events: events, index: i) {
                issues.append(ItinIssue(code: 36, severity: .blocking, eventIndex: i,
                                        relatedIndex: i + 1))
            }
            if itinerary.dateMode == .fixed, i > 0, e.startRule.kind == .at,
               slots[i].start < slots[i - 1].start {
                issues.append(ItinIssue(code: 36, severity: .blocking, eventIndex: i,
                                        relatedIndex: i - 1,
                                        suggestedDate: slots[i - 1].end ?? slots[i - 1].start,
                                        relatedDate: slots[i - 1].start))
            }
        }

        if let firstStart = slots.first?.start, let last = slots.last {
            let lastTime = last.end ?? last.start
            if lastTime.timeIntervalSince(firstStart) > maxTotalSeconds {
                issues.append(ItinIssue(code: 33, severity: .blocking, eventIndex: nil))
            }
        }
        // 停留 1～720、漫步 1～240 分鐘不另設錯誤代碼：編輯畫面的步進器與匯入都用
        // clampedMinutes 夾限，存進來的值本來就在範圍內（規格 10.1、10.6.6）。
        return issues
    }

    // MARK: 欄位規則（給編輯畫面與匯入共用）

    /// 停留／漫步分鐘數夾在範圍內；停留 nil＝直到下一項（保留）；漫步 nil＝nil（必填，由畫面要求）。
    static func clampedMinutes(_ minutes: Int?, for type: ItinEventType) -> Int? {
        guard let minutes else { return nil }
        switch type {
        case .stay: return min(max(minutes, stayMinuteRange.lowerBound), stayMinuteRange.upperBound)
        case .wander: return min(max(minutes, wanderMinuteRange.lowerBound), wanderMinuteRange.upperBound)
        case .move, .stop: return nil
        }
    }

    /// 停留可選「直到下一項」：下一項是「在 HH:mm」，或本項是最後一項（規格 10.1）。
    static func untilNextAllowed(events: [ItinEvent], index: Int) -> Bool {
        guard events.indices.contains(index) else { return false }
        let next = index + 1
        return next >= events.count || events[next].startRule.kind == .at
    }

    // MARK: 開始平移、暫停、時鐘（給 Runner 與捷徑共用，可單元測試）

    /// 捷徑「立即／延後」：讓第一項落在 target 所需的平移秒數（全部項目一起平移）。
    static func shiftToStart(_ itinerary: Itinerary, at target: Date, now: Date) -> TimeInterval {
        let events = itinerary.events
        guard !events.isEmpty else { return 0 }
        let slots = compute(events: events, anchor: now, durations: moveDurations(events: events),
                            dateMode: itinerary.dateMode, timeZone: itinerary.timeZone)
        guard let first = slots.first else { return 0 }
        return target.timeIntervalSince(first.start)
    }

    /// 暫停 pause 秒後的時間表（規格 10.2.4）：目前項目與其後「接續上一項」的項目順延，
    /// 遇到下一個「在 HH:mm」項目即停止順延（該項與其後全部照原時間）。
    /// 「直到下一項」的停留結束時間＝下一項開始，不順延。
    static func applyingPause(_ slots: [ItinSlot], events: [ItinEvent], currentIndex: Int,
                              pause: TimeInterval) -> [ItinSlot] {
        guard pause != 0, slots.indices.contains(currentIndex), slots.count == events.count else { return slots }
        var result = slots
        for i in currentIndex..<slots.count {
            if i > currentIndex && events[i].startRule.kind == .at { break }
            result[i].start = slots[i].start.addingTimeInterval(pause)
            let untilNext = events[i].type == .stay && events[i].minutes == nil
            if let end = slots[i].end, !untilNext {
                result[i].end = end.addingTimeInterval(pause)
            }
        }
        return result
    }

    /// 手機時間跳動門檻（規格 10.2.3）。
    static let clockJumpThreshold: TimeInterval = 300

    /// 牆上時鐘（Date）與系統開機時間（systemUptime）走的秒數差超過 300 秒＝手機時間被改過。
    static func clockJumped(wallElapsed: TimeInterval, uptimeElapsed: TimeInterval) -> Bool {
        guard wallElapsed.isFinite, uptimeElapsed.isFinite else { return false }
        return abs(wallElapsed - uptimeElapsed) > clockJumpThreshold
    }

    /// 行程時區下的「14:30」；不同天時「11/4 14:30」。
    static func clockText(_ date: Date, timeZone: TimeZone, now: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.timeZone = timeZone
        f.dateFormat = cal.isDate(date, inSameDayAs: now) ? "HH:mm" : "M/d HH:mm"
        return f.string(from: date)
    }
}

extension Itinerary {
    /// 清單與捷徑選單的副標題：「4 個項目・14:00 開始」或「4 個項目・開始後立即執行」。
    var listSubtitle: String {
        let count = "\(events.count) 個項目"
        guard let first = events.first else { return count }
        if first.startRule.kind == .at, let at = first.startRule.at {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            let hm = cal.dateComponents([.hour, .minute], from: at)
            let text = String(format: "%02d:%02d", hm.hour ?? 0, hm.minute ?? 0)
            return count + "・" + text + " 開始"
        }
        return count + "・開始後立即執行"
    }
}

// MARK: - 訊息（規格 10.6.7、12.2 第 4 點）

enum ItinMessage {
    static let importFailed = "無法讀取行程檔。檔案格式不符或已損毀。請確認是 PinFly 匯出的行程檔。（錯誤 37）"

    /// App 內「已有行程進行中」（捷徑改用錯誤 27）。
    static func appAlreadyActive(_ name: String) -> String {
        "行程「\(name)」正在進行。請先停止該行程。（錯誤 38）"
    }

    /// 驗證錯誤 30～36 的完整文字；項目編號 1 起算，時間以行程時區顯示。
    /// now＝目前時間：和 now 不同天的時間（例：隔天才抵達）顯示「M/d HH:mm」。
    static func text(for issue: ItinIssue, timeZone: TimeZone, now: Date = Date()) -> String {
        let n = (issue.eventIndex ?? 0) + 1
        let m = (issue.relatedIndex ?? 0) + 1
        func clock(_ date: Date?) -> String {
            guard let date else { return "--:--" }
            return ItinSchedule.clockText(date, timeZone: timeZone, now: now)
        }
        switch issue.code {
        case 30:
            return "第一項必須是「停留」或「原地漫步」，才能決定起點。請在最前面新增停留項目。（錯誤 30）"
        case 31:
            return "行程最多 \(ItinSchedule.maxEvents) 個項目。請刪除項目或另建行程。（錯誤 31）"
        case 32:
            return "第 \(n) 項預計移動時間超過 12 小時。請改用較快的速度或縮短距離。（錯誤 32）"
        case 33:
            return "行程總長超過 24 小時。請刪除部分項目或另建行程。（錯誤 33）"
        case 34:
            return "第 \(n) 項是「停止模擬」的下一項，無法決定起點。請將第 \(n) 項改為在指定時間開始的停留或原地漫步。（錯誤 34）"
        case 35:
            return "第 \(n) 項預計 \(clock(issue.suggestedDate)) 抵達，晚於第 \(m) 項的開始時間 \(clock(issue.relatedDate))，屆時移動會中途結束。請提高速度或延後第 \(m) 項。（錯誤 35）"
        case 36 where m > n:
            return "第 \(n) 項的停留時間為「直到下一項」，但第 \(m) 項是「接續上一項」，無法決定停留多久。請指定停留時間，或將第 \(m) 項改為在指定時間開始。（錯誤 36）"
        case 36:
            return "第 \(n) 項的指定日期時間早於第 \(m) 項。請修改時間。（錯誤 36）"
        default:
            return "行程設定有誤。請檢查項目內容。（錯誤 \(issue.code)）"
        }
    }
}

// MARK: - 匯入匯出（規格 11.3、10.6.9）

enum ItinTransferError: Error, Equatable {
    /// 錯誤 37：讀不到或 version 不支援。
    case unreadable
}

/// 匯入結果：新行程＋逐項調整提示（例：「第 3 項的接續偏移 120 秒未匯入。」）。
struct ItinImportResult {
    var itinerary: Itinerary
    var adjustments: [String]
}

/// 11.3 格式（研究員版＋本 App 加的 name、date_mode、speed_preset、place、stop）。
/// 匯入用 JSONSerialization 寬鬆解析（after_prev 可能是布林或秒數、to 可能是名稱或座標），
/// 匯出用 JSONEncoder（數字寫成最短表示，不會出現 1.3899999999999999）。
enum ItinTransfer {
    /// 與已儲存地點相距 ≤ 30 公尺就連到該地點（規格 10.6.9）。
    static let linkPlaceMeters: Double = 30
    /// 漫步沒寫時間時的預設分鐘數（匯入時列入調整提示）。
    static let defaultWanderMinutes = 30
    /// 停留沒寫時間、又不能「直到下一項」時的預設分鐘數（匯入時列入調整提示）。
    static let defaultStayMinutes = 30
    static let defaultImportName = "匯入的行程"

    // MARK: 匯出

    private struct ExportPoint: Encodable {
        var lat: Double
        var lon: Double
        var name: String?
    }

    private struct ExportEvent: Encodable {
        var type: String
        var at: String?
        var afterPrev: Bool?
        var place: ExportPoint?
        var to: ExportPoint?
        var center: ExportPoint?
        var durationMin: Int?
        var route: String?
        var speedPreset: String?
        var speedMps: Double?
        var radiusM: Double?

        enum CodingKeys: String, CodingKey {
            case type, at, place, to, center, route
            case afterPrev = "after_prev"
            case durationMin = "duration_min"
            case speedPreset = "speed_preset"
            case speedMps = "speed_mps"
            case radiusM = "radius_m"
        }
    }

    private struct ExportFile: Encodable {
        var version: Int
        var tz: String
        var name: String
        var dateMode: String
        var events: [ExportEvent]

        enum CodingKeys: String, CodingKey {
            case version, tz, name, events
            case dateMode = "date_mode"
        }
    }

    /// 匯出成 11.3 格式（加 name、date_mode；不含 cachedPath、routeKey、placeID）。
    static func exportJSON(_ itinerary: Itinerary) throws -> Data {
        let tz = itinerary.timeZone
        let events = itinerary.events.map { e -> ExportEvent in
            var out = ExportEvent(type: e.type.rawValue)
            if e.startRule.kind == .at, let at = e.startRule.at {
                out.at = isoString(at, timeZone: tz)
            } else {
                out.afterPrev = true
            }
            let point = e.coord.map { ExportPoint(lat: $0.lat, lon: $0.lon, name: e.placeName) }
            switch e.type {
            case .stay:
                out.place = point
                out.durationMin = e.minutes
            case .move:
                out.to = point
                out.route = e.moveMode == .route ? "road" : "straight"
                out.speedPreset = e.speedPreset.rawValue
                out.speedMps = (e.effectiveKmh / 3.6 * 1000).rounded() / 1000
            case .wander:
                out.center = point
                out.radiusM = e.wanderRadius.meters
                out.durationMin = e.minutes
            case .stop:
                break
            }
            return out
        }
        let file = ExportFile(version: ItineraryFile.currentVersion, tz: tz.identifier, name: itinerary.name,
                              dateMode: itinerary.dateMode.rawValue, events: events)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(file)
    }

    /// 分享表單用的檔名「<行程名稱>.json」（去掉檔名不允許的字元）。
    static func exportFileName(_ itinerary: Itinerary) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.newlines)
        let cleaned = itinerary.name.components(separatedBy: bad).joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
        return (cleaned.isEmpty ? "行程" : cleaned) + ".json"
    }

    static func isoString(_ date: Date, timeZone: TimeZone) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    static func parseISO(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text)
    }

    // MARK: 匯入

    /// 匯入 11.3 格式；places 用來把 ≤30 公尺的座標連到已儲存地點。
    /// 讀不到、不是物件、version 不是 1、或沒有任何可用項目 → ItinTransferError.unreadable（錯誤 37）。
    static func importJSON(_ data: Data, places: [GpsPlace]) throws -> ItinImportResult {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = intValue(root["version"]), version == ItineraryFile.currentVersion,
              let rawEvents = root["events"] as? [Any] else {
            throw ItinTransferError.unreadable
        }
        var adjustments: [String] = []

        var timeZoneID = TimeZone.current.identifier
        if let tz = root["tz"] as? String {
            if TimeZone(identifier: tz) != nil {
                timeZoneID = tz
            } else {
                adjustments.append("時區「\(tz)」無法辨識，已改用手機時區。")
            }
        }
        let rawName = (root["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = rawName.isEmpty ? defaultImportName : rawName
        let dateMode = (root["date_mode"] as? String).flatMap(ItinDateMode.init(rawValue:)) ?? .today

        var events: [ItinEvent] = []
        /// 上一個匯入項目結束時的位置（停止模擬後＝nil）。
        var lastPoint: (coord: ItinCoord, placeID: String?, name: String?)?
        var usedUnsupportedTuning = false
        /// 每個匯入項目在原檔的編號（1 起算），給事後調整的提示用。
        var sourceNumbers: [Int] = []

        for (offset, item) in rawEvents.enumerated() {
            let n = offset + 1
            if events.count >= ItinSchedule.maxEvents {
                adjustments.append("行程檔有 \(rawEvents.count) 個項目，只匯入前 \(ItinSchedule.maxEvents) 項。")
                break
            }
            guard let dict = item as? [String: Any] else {
                adjustments.append("第 \(n) 項無法讀取，未匯入。")
                continue
            }
            let rawType = dict["type"] as? String ?? ""
            guard let type = ItinEventType(rawValue: rawType) else {
                adjustments.append("第 \(n) 項的類型「\(rawType)」不支援，未匯入。")
                continue
            }
            if dict["speed_jitter"] != nil || dict["pause_prob"] != nil { usedUnsupportedTuning = true }

            // 開始方式
            var rule = ItinStartRule.afterPreviousRule
            if let atText = dict["at"] as? String {
                if let at = parseISO(atText) {
                    rule = ItinStartRule(kind: .at, at: at)
                } else {
                    adjustments.append("第 \(n) 項的時間「\(atText)」無法辨識，已改為接續上一項。")
                }
            }
            if rule.kind == .afterPrevious, let offsetSeconds = intValue(dict["after_prev"]), offsetSeconds != 0 {
                adjustments.append("第 \(n) 項的接續偏移 \(offsetSeconds) 秒未匯入。")
            }

            var event = ItinEvent(type: type, startRule: rule)
            switch type {
            case .stay, .wander:
                let key = type == .stay ? "place" : "center"
                let explicit = point(dict[key], places: places)
                if dict[key] != nil && explicit == nil {
                    adjustments.append("第 \(n) 項的地點無法辨識，未匯入。")
                    continue
                }
                guard let resolved = explicit ?? lastPoint else {
                    adjustments.append("第 \(n) 項沒有位置，未匯入。")
                    continue
                }
                event.coord = resolved.coord
                event.placeID = resolved.placeID
                event.placeName = resolved.name
                let rawMinutes = intValue(dict["duration_min"])
                if type == .stay {
                    event.minutes = ItinSchedule.clampedMinutes(rawMinutes, for: .stay)
                    if let rawMinutes, rawMinutes != event.minutes {
                        adjustments.append("第 \(n) 項的停留時間 \(rawMinutes) 分鐘超出範圍，已改為 \(event.minutes ?? 0) 分鐘。")
                    }
                } else {
                    if let rawMinutes {
                        event.minutes = ItinSchedule.clampedMinutes(rawMinutes, for: .wander)
                        if rawMinutes != event.minutes {
                            adjustments.append("第 \(n) 項的漫步時間 \(rawMinutes) 分鐘超出範圍，已改為 \(event.minutes ?? 0) 分鐘。")
                        }
                    } else {
                        event.minutes = defaultWanderMinutes
                        adjustments.append("第 \(n) 項未指定漫步時間，已設為 \(defaultWanderMinutes) 分鐘。")
                    }
                    let radius = doubleValue(dict["radius_m"]) ?? WanderSize.medium.meters
                    event.wanderRadius = radius <= WanderSize.small.meters ? .small
                        : (radius <= WanderSize.medium.meters ? .medium : .large)
                }
            case .move:
                guard let target = point(dict["to"], places: places) else {
                    adjustments.append("第 \(n) 項的目的地無法辨識，未匯入。")
                    continue
                }
                event.coord = target.coord
                event.placeID = target.placeID
                event.placeName = target.name
                let route = (dict["route"] as? String) ?? "road"
                if route == "straight" {
                    event.moveMode = .straight
                } else if route == "road" {
                    event.moveMode = .route
                } else {
                    event.moveMode = .straight
                    if route.hasPrefix("gpx:") {
                        adjustments.append("第 \(n) 項的 GPX 路線本版不支援，已改為直線。")
                    } else {
                        adjustments.append("第 \(n) 項的路線「\(route)」不支援，已改為直線。")
                    }
                }
                let preset = (dict["speed_preset"] as? String).flatMap(MoveSpeedPreset.init(rawValue:))
                let mps = doubleValue(dict["speed_mps"])
                let speed = resolveSpeed(preset: preset, mps: mps)
                event.speedPreset = speed.preset
                event.customKmh = speed.customKmh
                if speed.clamped, let mps {
                    adjustments.append("第 \(n) 項的速度 \(String(format: "%.1f", mps * 3.6)) km/h 超出範圍，已改為 \(String(format: "%.1f", speed.customKmh ?? 0)) km/h。")
                }
            case .stop:
                break
            }
            events.append(event)
            sourceNumbers.append(n)
            if type == .stop {
                lastPoint = nil
            } else if let coord = event.coord {
                lastPoint = (coord, event.placeID, event.placeName)
            }
        }

        // 停留沒寫 duration_min＝「直到下一項」，只在下一項是「在 HH:mm」或本項是最後一項時成立；
        // 否則（下一項接續上一項）改為預設分鐘數並列入提示，避免長度 0、執行時被跳過（錯誤 36）。
        for i in events.indices where events[i].type == .stay && events[i].minutes == nil
            && !ItinSchedule.untilNextAllowed(events: events, index: i) {
            events[i].minutes = defaultStayMinutes
            adjustments.append("第 \(sourceNumbers[i]) 項未指定停留時間，已設為 \(defaultStayMinutes) 分鐘。")
        }
        if usedUnsupportedTuning {
            adjustments.append("速度變動（speed_jitter）與停頓機率（pause_prob）未使用，速度與停頓由 PinFly 決定。")
        }
        guard !events.isEmpty else { throw ItinTransferError.unreadable }
        let itinerary = Itinerary(name: name, timeZoneID: timeZoneID, events: events, dateMode: dateMode)
        return ItinImportResult(itinerary: itinerary, adjustments: adjustments)
    }

    /// 速度：有 speed_preset 且 speed_mps 與該檔位相同（差 < 0.05 km/h）＝檔位；
    /// 不同＝自訂（保留檔位決定路線類型）；只有 speed_mps＝符合的檔位或自訂（自訂時路線類型依速度：> 25 km/h 駕車）。
    static func resolveSpeed(preset: MoveSpeedPreset?, mps: Double?) -> (preset: MoveSpeedPreset, customKmh: Double?, clamped: Bool) {
        guard let mps, mps.isFinite, mps > 0 else { return (preset ?? .walk, nil, false) }
        let kmh = mps * 3.6
        if let preset, abs(kmh - preset.kmh) < 0.05 { return (preset, nil, false) }
        if preset == nil, let match = MoveSpeedPreset.allCases.first(where: { abs(kmh - $0.kmh) < 0.05 }) {
            return (match, nil, false)
        }
        let clampedKmh = MoveSpeedPreset.clampCustom(kmh)
        let rounded = (clampedKmh * 10).rounded() / 10
        let routeType = preset ?? (rounded > 25 ? .drive : .walk)
        return (routeType, rounded, abs(clampedKmh - kmh) > 0.0001)
    }

    /// {lat, lon, name?} 或地點名稱字串 → 座標（連到 30 公尺內的已儲存地點）。
    private static func point(_ value: Any?, places: [GpsPlace]) -> (coord: ItinCoord, placeID: String?, name: String?)? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let place = places.first(where: { $0.name == trimmed }) else { return nil }
            return (ItinCoord(lat: place.lat, lon: place.lon), place.id, place.name)
        }
        guard let dict = value as? [String: Any],
              let lat = doubleValue(dict["lat"]), let lon = doubleValue(dict["lon"]),
              (-90.0...90.0).contains(lat), (-180.0...180.0).contains(lon) else { return nil }
        let coord = ItinCoord(lat: lat, lon: lon)
        let fileName = (dict["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let named = (fileName?.isEmpty == false) ? fileName : nil
        if let place = nearestPlace(to: coord, in: places) {
            return (coord, place.id, named ?? place.name)
        }
        return (coord, nil, named)
    }

    static func nearestPlace(to coord: ItinCoord, in places: [GpsPlace]) -> GpsPlace? {
        var best: (place: GpsPlace, meters: Double)?
        for p in places {
            let m = GpsGeo.meters(coord.lat, coord.lon, p.lat, p.lon)
            if m <= linkPlaceMeters && (best == nil || m < best!.meters) { best = (p, m) }
        }
        return best?.place
    }

    /// JSON 數字（排除布林；JSONSerialization 把 true 也給成 NSNumber）。
    private static func doubleValue(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        guard let d = doubleValue(value), abs(d) < 1e9 else { return nil }
        return Int(d.rounded())
    }
}

// MARK: - Store

@MainActor
final class GpsItineraryStore: ObservableObject {
    static let shared = GpsItineraryStore()

    @Published private(set) var itineraries: [Itinerary] = []
    @Published private(set) var lastLoadError: String?
    /// 最近刪除的一筆，給畫面「復原」；留到使用者做下一個動作（畫面呼叫 clearUndo）才收。
    @Published private(set) var lastDeleted: Itinerary?
    private var lastDeletedIndex: Int?

    nonisolated static var fileURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("itineraries.json")
    }
    nonisolated static var corruptCopyURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("itineraries.json.corrupt")
    }

    /// 這個實例實際讀寫的檔案（單元測試傳暫存資料夾）。
    let storeURL: URL
    private let notifiesShortcuts: Bool

    var corruptURL: URL {
        storeURL.deletingLastPathComponent().appendingPathComponent(storeURL.lastPathComponent + ".corrupt")
    }

    /// shared 用預設檔案；測試用 init(storeURL:notifiesShortcuts: false)。
    init(storeURL: URL = GpsItineraryStore.fileURL, notifiesShortcuts: Bool = true) {
        self.storeURL = storeURL
        self.notifiesShortcuts = notifiesShortcuts
        reload()
    }

    func itinerary(id: String) -> Itinerary? {
        itineraries.first { $0.id == id }
    }

    /// 重新讀檔；壞檔改名 .corrupt（覆蓋舊的 .corrupt）後當作空清單（同 GpsSimPlaces 的作法）。
    func reload() {
        let url = storeURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            itineraries = []
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let file = try ItineraryFile.makeDecoder().decode(ItineraryFile.self, from: data)
            itineraries = file.itineraries
            lastLoadError = nil
        } catch {
            let backup = corruptURL
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            itineraries = []
            lastLoadError = "無法讀取行程檔，已另存為 \(backup.lastPathComponent)。"
        }
    }

    /// 新增或更新（依 id）；更新 updatedAt 後存檔。
    func upsert(_ itinerary: Itinerary) {
        var item = itinerary
        item.updatedAt = Date()
        if let i = itineraries.firstIndex(where: { $0.id == item.id }) {
            itineraries[i] = item
        } else {
            itineraries.append(item)
        }
        save()
    }

    func rename(id: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var item = itinerary(id: id) else { return }
        item.name = trimmed
        upsert(item)
    }

    /// 「複製行程」：產生「<名稱> 副本」（重名再加數字），插在原列下方；項目換新 id。
    @discardableResult
    func duplicate(id: String) -> Itinerary? {
        guard let i = itineraries.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = itineraries[i]
        copy.id = UUID().uuidString
        copy.name = Self.uniqueName(copy.name + " 副本", existing: itineraries.map(\.name))
        copy.events = copy.events.map { e in
            var e2 = e
            e2.id = UUID().uuidString
            return e2
        }
        copy.updatedAt = Date()
        itineraries.insert(copy, at: i + 1)
        save()
        return copy
    }

    func delete(id: String) {
        guard let i = itineraries.firstIndex(where: { $0.id == id }) else { return }
        lastDeleted = itineraries.remove(at: i)
        lastDeletedIndex = i
        save()
    }

    func undoDelete() {
        guard let item = lastDeleted else { return }
        let i = min(lastDeletedIndex ?? itineraries.count, itineraries.count)
        if itinerary(id: item.id) == nil {
            itineraries.insert(item, at: i)
        }
        lastDeleted = nil
        lastDeletedIndex = nil
        save()
    }

    /// 使用者做了下一個動作：收掉「復原」。
    func clearUndo() {
        lastDeleted = nil
        lastDeletedIndex = nil
    }

    /// 匯入一個 11.3 格式檔，同名時加「 2」（再重名加「 3」…）；存檔後回傳新行程與調整提示。
    func importItinerary(from data: Data, places: [GpsPlace]) throws -> ItinImportResult {
        var result = try ItinTransfer.importJSON(data, places: places)
        result.itinerary.name = Self.uniqueName(result.itinerary.name, existing: itineraries.map(\.name))
        result.itinerary.updatedAt = Date()
        itineraries.append(result.itinerary)
        save()
        return result
    }

    func exportData(id: String) throws -> Data {
        guard let item = itinerary(id: id) else { throw ItinTransferError.unreadable }
        return try ItinTransfer.exportJSON(item)
    }

    /// base 不重複就用 base；否則「base 2」「base 3」…
    nonisolated static func uniqueName(_ base: String, existing: [String]) -> String {
        let taken = Set(existing)
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    private func save() {
        let url = storeURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try ItineraryFile.makeEncoder().encode(ItineraryFile(itineraries: itineraries))
            // .atomic＝先寫暫存檔再改名，寫到一半當機也不會留下半個檔案。
            try data.write(to: url, options: .atomic)
            lastLoadError = nil
        } catch {
            lastLoadError = "無法儲存行程：\(error.localizedDescription)"
        }
        if notifiesShortcuts {
            // 捷徑「開始行程」的片語參數（\(\.$itinerary)）要知道行程新增、改名、刪除（規格 12.3.2）。
            StikDebugShortcuts.updateAppShortcutParameters()
        }
    }
}
