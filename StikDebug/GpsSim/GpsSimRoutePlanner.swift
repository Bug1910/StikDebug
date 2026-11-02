//
//  GpsSimRoutePlanner.swift
//  PinFly
//
//  【這個檔案的角色】「移動過去／原地漫步」的地圖規劃員＋量尺。
//  它不送任何座標給手機，只負責回答三種問題：
//    1. 從 A 到 B 要走哪一條線？（直線，或向 Apple 地圖 MKDirections 問路線）
//    2. 這條線每 10 公尺切一個點，累積走了幾公尺時人應該站在哪？
//    3. 原地漫步時，下一個要走去的目標點在哪、到了要停幾秒？
//
//  【為什麼這樣設計】
//  - 幾乎全是「純函式」（同樣輸入永遠同樣輸出、不碰網路與手機），單元測試不必連手機、
//    也不必呼叫 MKDirections 就能驗證距離、內插、漫步不出圈。亂數來源可以從外面塞進來，
//    測試用固定種子，結果可重現。
//  - 位置一律依「已走距離」查表，而不是「第幾跳」：背景計時器被系統延後時，移動器用
//    實際經過時間（wall-clock）算距離，再來這裡查座標，不會累積誤差（規格 3.3）。
//  - MKDirections 只包一層：8 秒沒回應、沒網路、沒路線 → 直接改走直線並標記
//    fellBackToStraight，畫面再提示「找不到路線，改走直線」（規格 3.3；4G 流程下是常態）。
//  - 上游 StikDebug 的 MapSelectionView 有相同演算法，但都是 private 函式拿不到，
//    所以這裡照它的作法（每 10 公尺取樣、逐段線性內插）重寫一份。
//  - 加減速參考 Skysafe64/iphone-gps-spoofer（MIT）backend.py：速度乘上 0.3～1 的 ramp
//    係數、AR(1) 回歸到 1 的步調係數；本檔改成「起步 3～5 秒線性加速、抵達前 max(5 公尺, 速度×3 秒) 減速」。
//

import Foundation
import CoreLocation
import MapKit

// MARK: - 型別

/// 怎麼移動：沿道路、直線、或在圈內原地漫步。
enum MoveMode: String, Codable, CaseIterable {
    case route
    case straight
    case wander
}

/// 三種速度預設（km/h）；另可自訂 3.6～100 km/h（規格第 8 節）。
enum MoveSpeedPreset: String, Codable, CaseIterable {
    case walk
    case bike
    case drive

    var kmh: Double {
        switch self {
        case .walk: return 5
        case .bike: return 15
        case .drive: return 40
        }
    }

    var label: String {
        switch self {
        case .walk: return "步行"
        case .bike: return "單車"
        case .drive: return "駕車"
        }
    }

    /// 向 MKDirections 要哪一種路線。MapKit 沒有穩定的單車路線，單車先借步行路線。
    var transportType: MKDirectionsTransportType {
        switch self {
        case .walk, .bike: return .walking
        case .drive: return .automobile
        }
    }

    /// 單車借用步行路線，畫面要註明（使用者已同意）。
    var borrowsWalkingRoute: Bool { self == .bike }

    static let borrowedRouteNote = "沿步行路線"

    /// 自訂速度範圍（AnyGo 同款 3.6～100 km/h）。
    static let customRange: ClosedRange<Double> = 3.6...100

    static func clampCustom(_ kmh: Double) -> Double {
        guard kmh.isFinite else { return walk.kmh }
        return min(max(kmh, customRange.lowerBound), customRange.upperBound)
    }
}

/// 一趟規劃好的路徑：每 10 公尺一點，cumulative[i] = 起點到 path[i] 的累積公尺。
struct MovePlan {
    let path: [CLLocationCoordinate2D]
    let cumulative: [Double]
    let mode: MoveMode
    /// 原本要走路線，但 MKDirections 失敗／逾時，改走直線。
    let fellBackToStraight: Bool

    var totalMeters: Double { cumulative.last ?? 0 }
    var start: CLLocationCoordinate2D? { path.first }
    var destination: CLLocationCoordinate2D? { path.last }

    init(path: [CLLocationCoordinate2D], mode: MoveMode, fellBackToStraight: Bool = false) {
        self.path = path
        self.cumulative = GpsSimRoutePlanner.cumulativeDistances(path)
        self.mode = mode
        self.fellBackToStraight = fellBackToStraight
    }

    /// 已走 distance 公尺時應在的位置。
    func coordinate(atDistance distance: Double) -> CLLocationCoordinate2D? {
        GpsSimRoutePlanner.coordinate(atDistance: distance, path: path, cumulative: cumulative)
    }

    /// 預估秒數（不含加減速，給畫面顯示「約 N 分鐘」）。
    func estimatedSeconds(kmh: Double) -> TimeInterval {
        let mps = kmh / 3.6
        return mps > 0 ? totalMeters / mps : 0
    }
}

/// 漫步範圍三檔（規格 9.1）。
enum WanderSize: String, Codable, CaseIterable {
    case small
    case medium
    case large

    var meters: Double {
        switch self {
        case .small: return 30
        case .medium: return 100
        case .large: return 300
        }
    }
}

// MARK: - 路線規劃（直線、MKDirections、取樣、依距離取點）

enum GpsSimRoutePlanner {
    /// 取樣間距（沿用上游 RouteSimulationDefaults.pathSamplingDistance）。
    static let samplingMeters: Double = 10
    /// MKDirections 最多等幾秒（規格 3.3）。
    static let directionsTimeout: TimeInterval = 8

    /// 直線：起終點線性內插、每 10 公尺一點（< 500 km 誤差可忽略）。
    static func straightPath(from start: CLLocationCoordinate2D,
                             to end: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
        resample([start, end], spacing: samplingMeters)
    }

    /// 把折線每 spacing 公尺切一點；原本的轉折點全部保留（不會切掉轉角）。
    static func resample(_ coords: [CLLocationCoordinate2D], spacing: Double) -> [CLLocationCoordinate2D] {
        guard let first = coords.first else { return [] }
        guard coords.count > 1, spacing > 0 else { return coords }
        var out = [first]
        for (a, b) in zip(coords, coords.dropFirst()) {
            let d = GpsGeo.meters(a, b)
            guard d > 0 else { continue }
            let n = max(1, Int((d / spacing).rounded(.up)))
            for i in 1...n {
                out.append(interpolate(a, b, Double(i) / Double(n)))
            }
        }
        return out
    }

    static func interpolate(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D,
                            _ t: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                               longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    /// cumulative[0] = 0，cumulative[i] = 前 i 段長度總和（公尺）。
    static func cumulativeDistances(_ path: [CLLocationCoordinate2D]) -> [Double] {
        guard !path.isEmpty else { return [] }
        var out = [0.0]
        out.reserveCapacity(path.count)
        for (a, b) in zip(path, path.dropFirst()) {
            out.append(out[out.count - 1] + GpsGeo.meters(a, b))
        }
        return out
    }

    /// 已走 distance 公尺時的座標：二分搜尋找段，再段內線性內插。超出範圍就夾在起點／終點。
    static func coordinate(atDistance distance: Double, path: [CLLocationCoordinate2D],
                           cumulative: [Double]) -> CLLocationCoordinate2D? {
        guard let first = path.first, path.count == cumulative.count else { return nil }
        guard path.count > 1, let total = cumulative.last, total > 0 else { return first }
        if !(distance > 0) { return first }
        if distance >= total { return path[path.count - 1] }
        // 找最後一個 cumulative[lo] <= distance。
        var lo = 0
        var hi = cumulative.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= distance { lo = mid } else { hi = mid }
        }
        let segLen = cumulative[hi] - cumulative[lo]
        let t = segLen > 0 ? (distance - cumulative[lo]) / segLen : 0
        return interpolate(path[lo], path[hi], t)
    }

    /// 規劃一趟：route 先問 MKDirections（最多 8 秒），失敗就改直線；straight 直接直線。
    /// 漫步不走這裡（由 GpsSimWanderPlanner 一段一段產生）。
    /// query：可傳入 GpsSimRouteQuery，之後呼叫 cancel() 會立刻停止 MKDirections 並改走直線。
    @MainActor
    static func plan(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D,
                     mode: MoveMode, speed: MoveSpeedPreset, query: GpsSimRouteQuery? = nil) async -> MovePlan {
        if mode == .route,
           let coords = await directionsCoordinates(from: start, to: end, transport: speed.transportType,
                                                    query: query),
           coords.count > 1 {
            // MKDirections 的折線起訖點是「最近的道路」，前後補上真正的起點與終點，
            // 才不會一開始就瞬移到馬路上、或停在離目的地幾十公尺的路邊。
            var full = coords
            if GpsGeo.meters(start, full[0]) > 1 { full.insert(start, at: 0) }
            if GpsGeo.meters(end, full[full.count - 1]) > 1 { full.append(end) }
            return MovePlan(path: resample(full, spacing: samplingMeters), mode: .route)
        }
        return MovePlan(path: straightPath(from: start, to: end), mode: .straight,
                        fellBackToStraight: mode == .route)
    }

    /// MKDirections 包裝：回傳路線折線座標；逾時、沒網路、沒路線都回 nil（不丟錯，呼叫端改直線）。
    @MainActor
    static func directionsCoordinates(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D,
                                      transport: MKDirectionsTransportType,
                                      timeout: TimeInterval = directionsTimeout,
                                      query: GpsSimRouteQuery? = nil) async -> [CLLocationCoordinate2D]? {
        if query?.isCancelled == true { return nil }
        let request = MKDirections.Request()
        request.source = mapItem(start)
        request.destination = mapItem(end)
        request.requestsAlternateRoutes = false
        request.transportType = transport
        let directions = MKDirections(request: request)
        let once = DirectionsOnce()
        query?.attach(directions: directions, once: once)
        return await withCheckedContinuation { (cont: CheckedContinuation<[CLLocationCoordinate2D]?, Never>) in
            once.continuation = cont
            directions.calculate { response, _ in
                // 先在這裡把座標抽成值型別，再跳回主執行緒，不把 MKDirections.Response 帶過去。
                let coords = response?.routes.first.map { polylineCoordinates($0.polyline) }
                Task { @MainActor in once.finish(coords) }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                if !once.done { directions.cancel() }
                once.finish(nil)
            }
        }
    }

    /// iOS 26 起 MKPlacemark 棄用，改用 MKMapItem(location:address:)；舊系統保留舊寫法。
    @MainActor
    static func mapItem(_ c: CLLocationCoordinate2D) -> MKMapItem {
        if #available(iOS 26.0, *) {
            return MKMapItem(location: CLLocation(latitude: c.latitude, longitude: c.longitude), address: nil)
        }
        return MKMapItem(placemark: MKPlacemark(coordinate: c))
    }

    static func polylineCoordinates(_ polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        let n = polyline.pointCount
        guard n > 0 else { return [] }
        var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(latitude: 0, longitude: 0), count: n)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: n))
        return coords
    }
}

/// 可取消的路線查詢：畫面關掉卡片時呼叫 cancel()，MKDirections 立刻停止、等待中的規劃改走直線。
@MainActor
final class GpsSimRouteQuery {
    private(set) var isCancelled = false
    private var directions: MKDirections?
    private var once: DirectionsOnce?

    init() {}

    fileprivate func attach(directions: MKDirections, once: DirectionsOnce) {
        self.directions = directions
        self.once = once
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        if once?.done == false { directions?.cancel() }
        once?.finish(nil)
        directions = nil
        once = nil
    }
}

/// 保證 continuation 只 resume 一次（MKDirections 回來與 8 秒逾時誰先到用誰）。只在主執行緒用。
@MainActor
fileprivate final class DirectionsOnce {
    var continuation: CheckedContinuation<[CLLocationCoordinate2D]?, Never>?
    private(set) var done = false

    func finish(_ value: [CLLocationCoordinate2D]?) {
        guard !done else { return }
        done = true
        continuation?.resume(returning: value)
        continuation = nil
    }
}

// MARK: - 速度：加減速＋擬真起伏（純計算，亂數可注入）

enum GpsSimMotion {
    /// 起步加速秒數範圍（每趟隨機挑一個值）。
    static let rampUpSecondsRange: ClosedRange<Double> = 3...5
    /// 減速區最短幾公尺（步行用這個；使用者覺得 5 公尺比較自然）。
    static let minBrakeMeters: Double = 5
    /// 減速區＝目前速度走幾秒的距離（開車 40 km/h 約 33 公尺）。
    static let brakeSeconds: Double = 3
    /// 加減速最低係數：避免起步第一秒、最後幾公尺速度趨近 0 而永遠走不到。
    static let minRampFactor: Double = 0.3

    /// 減速區長度＝max(5 公尺, 速度 × 3 秒)。speedMps 用設定的目標速度（不含加減速），區長才穩定。
    static func brakeMeters(speedMps: Double) -> Double {
        max(minBrakeMeters, max(0, speedMps) * brakeSeconds)
    }

    /// 加減速係數（0.3～1）：起步 rampUpSeconds 內線性升到 1，剩下減速區內線性降。
    static func rampFactor(movingSeconds: Double, rampUpSeconds: Double, remainingMeters: Double,
                           speedMps: Double) -> Double {
        let up = rampUpSeconds > 0 ? movingSeconds / rampUpSeconds : 1
        let down = remainingMeters / brakeMeters(speedMps: speedMps)
        return min(1, max(minRampFactor, min(up, down)))
    }

    /// 走一跳後的新已走距離（不會超過 total）。
    static func advance(traveled: Double, total: Double, speedMps: Double, dt: Double) -> Double {
        guard dt > 0, speedMps > 0 else { return traveled }
        return min(total, traveled + speedMps * dt)
    }
}

/// 速度起伏：AR(1) 低通濾波，每秒往 1 回歸並加一點雜訊，夾在 1±amplitude。
/// 不是白噪音，所以相鄰兩秒速度不會跳（規格 3.2；漫步用 ±20%）。
struct SpeedWobble {
    let amplitude: Double
    private(set) var factor: Double = 1

    init(amplitude: Double) {
        self.amplitude = max(0, amplitude)
    }

    mutating func next<R: RandomNumberGenerator>(using rng: inout R) -> Double {
        guard amplitude > 0 else { return 1 }
        let noise = Double.random(in: -1...1, using: &rng) * amplitude * 0.35
        factor = 1 + 0.85 * (factor - 1) + noise
        factor = min(1 + amplitude, max(1 - amplitude, factor))
        return factor
    }
}

/// 1～3 公尺位置抖動：偏移向量每秒小幅漂移（像 GPS 雜訊），長度夾在 1～3 公尺。
/// 不每秒重抽方向，否則相鄰兩點會跳 6 公尺、比走路還快。
struct PositionJitter {
    static let range: ClosedRange<Double> = 1...3
    private(set) var east: Double = 0
    private(set) var north: Double = 0

    var magnitude: Double { (east * east + north * north).squareRoot() }

    mutating func next<R: RandomNumberGenerator>(using rng: inout R) -> (east: Double, north: Double) {
        if magnitude == 0 {
            let ang = Double.random(in: 0..<(2 * Double.pi), using: &rng)
            let r = Double.random(in: Self.range, using: &rng)
            east = r * cos(ang)
            north = r * sin(ang)
        } else {
            east += Double.random(in: -0.5...0.5, using: &rng)
            north += Double.random(in: -0.5...0.5, using: &rng)
        }
        let m = magnitude
        if m < Self.range.lowerBound || m > Self.range.upperBound {
            let target = min(Self.range.upperBound, max(Self.range.lowerBound, m))
            if m > 0 {
                east *= target / m
                north *= target / m
            } else {
                east = target
            }
        }
        return (east, north)
    }

    func apply(to c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        GpsSimWanderPlanner.offset(c, east: east, north: north)
    }
}

// MARK: - 原地漫步規劃（規格 9.1／9.3）

enum GpsSimWanderPlanner {
    /// 漫步滿 4 小時自動停止（使用者已同意）。
    static let maxDuration: TimeInterval = 4 * 3600
    /// 步行速度中心 4.5 km/h、每段 ±20%。
    static let baseKmh: Double = 4.5
    static let speedSpread: Double = 0.20
    /// 每到一點停 3～15 秒。
    static let dwellRange: ClosedRange<Double> = 3...15
    /// 新方向與上一段方向夾角要小於 120 度（不走回頭路）。
    static let maxTurnDegrees: Double = 120
    /// 新目標至少離目前位置「半徑 × 25%」。
    static let minHopFraction: Double = 0.25
    /// 連續幾次挑不到就放寬條件。
    static let strictTries = 5

    /// 實際半徑＝檔位與地點圈半徑取小（不走出使用者畫的圈）；沒有地點圈就用檔位。
    static func radius(size: WanderSize, placeRadius: Double?) -> Double {
        guard let r = placeRadius, r > 0 else { return size.meters }
        return min(size.meters, r)
    }

    static func isExpired(startedAt: Date, now: Date, limit: TimeInterval = maxDuration) -> Bool {
        now.timeIntervalSince(startedAt) >= limit
    }

    /// 圈內均勻隨機點（sqrt 讓點不擠在圓心）。
    static func randomPoint<R: RandomNumberGenerator>(center: CLLocationCoordinate2D, radius: Double,
                                                      using rng: inout R) -> CLLocationCoordinate2D {
        let ang = Double.random(in: 0..<(2 * Double.pi), using: &rng)
        let d = Double.random(in: 0..<1, using: &rng).squareRoot() * radius
        return offset(center, east: d * cos(ang), north: d * sin(ang))
    }

    /// 下一個目標點。previousHeading＝上一段方向（度，北 0 東 90）；nil 表示第一段不限方向。
    /// 前 strictTries 次要求「不折返＋夠遠」，挑不到就只要求在圈內。
    static func nextTarget<R: RandomNumberGenerator>(center: CLLocationCoordinate2D, radius: Double,
                                                     from current: CLLocationCoordinate2D,
                                                     previousHeading: Double?,
                                                     using rng: inout R) -> CLLocationCoordinate2D {
        guard radius > 0 else { return center }
        let minHop = radius * minHopFraction
        for _ in 0..<strictTries {
            let p = randomPoint(center: center, radius: radius, using: &rng)
            guard GpsGeo.meters(current, p) >= minHop else { continue }
            if let prev = previousHeading,
               angleBetween(prev, heading(from: current, to: p)) >= maxTurnDegrees { continue }
            return p
        }
        // 放寬：只保留「夠遠」，再不行就任何圈內點。
        for _ in 0..<strictTries {
            let p = randomPoint(center: center, radius: radius, using: &rng)
            if GpsGeo.meters(current, p) >= minHop { return p }
        }
        return randomPoint(center: center, radius: radius, using: &rng)
    }

    static func dwellSeconds<R: RandomNumberGenerator>(using rng: inout R) -> Double {
        Double.random(in: dwellRange, using: &rng)
    }

    /// 每段一個目標速度（km/h），4.5 ±20%。
    static func segmentKmh<R: RandomNumberGenerator>(using rng: inout R) -> Double {
        baseKmh * (1 + Double.random(in: -speedSpread...speedSpread, using: &rng))
    }

    /// 方向（度，0＝北、90＝東）。
    static func heading(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let north = (b.latitude - a.latitude) * 111_320
        let east = (b.longitude - a.longitude) * 111_320 * cos((a.latitude + b.latitude) / 2 * Double.pi / 180)
        let deg = atan2(east, north) * 180 / Double.pi
        return deg < 0 ? deg + 360 : deg
    }

    /// 兩方向夾角（0～180 度）。
    static func angleBetween(_ a: Double, _ b: Double) -> Double {
        let d = abs((a - b).truncatingRemainder(dividingBy: 360))
        return d > 180 ? 360 - d : d
    }

    /// 點在圈外就沿圓心方向拉回圈邊（漫步加抖動後用，永遠不出圈）。
    static func clamp(_ p: CLLocationCoordinate2D, center: CLLocationCoordinate2D,
                      radius: Double) -> CLLocationCoordinate2D {
        let d = GpsGeo.meters(center, p)
        guard d > radius, d > 0 else { return p }
        // 留 1 公分餘量：經緯度換算的近似誤差不會讓點剛好落在圈外。
        let t = max(0, radius - 0.01) / d
        return GpsSimRoutePlanner.interpolate(center, p, t)
    }

    static func offset(_ c: CLLocationCoordinate2D, east: Double, north: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: c.latitude + north / 111_320,
            longitude: c.longitude + east / (111_320 * cos(c.latitude * Double.pi / 180))
        )
    }
}
