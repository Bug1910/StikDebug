//
//  RoutePlannerTests.swift
//  StikDebugTests
//
//  【這個檔案的角色】「移動過去／原地漫步」引擎的單元測試。
//  只測純幾何與純計算（GpsSimRoutePlanner、GpsSimMotion、GpsSimWanderPlanner、SpeedWobble、
//  PositionJitter），不呼叫 MKDirections、不連手機，所以模擬器或 CI 上都能跑。
//  亂數用固定種子的 SplitMix64，結果每次都一樣，失敗時可以重現。
//

import Foundation
import CoreLocation
import MapKit
import Testing
@testable import StikDebug

/// 固定種子亂數（SplitMix64），讓漫步測試可重現。
private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct RoutePlannerTests {

    private let a = CLLocationCoordinate2D(latitude: 25.0, longitude: 121.5)
    /// a 往北約 1113 公尺。
    private let b = CLLocationCoordinate2D(latitude: 25.01, longitude: 121.5)

    // MARK: 直線距離與內插

    @Test func straightPathDistanceAndSpacing() async throws {
        let path = GpsSimRoutePlanner.straightPath(from: a, to: b)
        let plan = MovePlan(path: path, mode: .straight)
        let expected = GpsGeo.meters(a, b)
        #expect(abs(plan.totalMeters - expected) < 0.5)
        #expect(abs(expected - 1113.2) < 1)
        // 每段不超過 10 公尺、首尾就是起終點。
        for (p, q) in zip(path, path.dropFirst()) {
            #expect(GpsGeo.meters(p, q) <= GpsSimRoutePlanner.samplingMeters + 1e-6)
        }
        #expect(path.count == Int((expected / 10).rounded(.up)) + 1)
        #expect(path.first!.latitude == a.latitude && path.last!.latitude == b.latitude)
    }

    @Test func coordinateAtDistanceInterpolatesAndClamps() async throws {
        let plan = MovePlan(path: GpsSimRoutePlanner.straightPath(from: a, to: b), mode: .straight)
        let mid = try #require(plan.coordinate(atDistance: plan.totalMeters / 2))
        #expect(abs(mid.latitude - 25.005) < 1e-6)
        #expect(abs(mid.longitude - 121.5) < 1e-9)
        let quarter = try #require(plan.coordinate(atDistance: plan.totalMeters / 4))
        #expect(abs(GpsGeo.meters(a, quarter) - plan.totalMeters / 4) < 0.5)
        #expect(plan.coordinate(atDistance: -5)!.latitude == a.latitude)
        #expect(plan.coordinate(atDistance: plan.totalMeters + 50)!.latitude == b.latitude)
    }

    @Test func resampleKeepsCorners() async throws {
        // L 形：先北 100 公尺、再東 100 公尺；轉角那點必須保留。
        let corner = GpsSimWanderPlanner.offset(a, east: 0, north: 100)
        let end = GpsSimWanderPlanner.offset(corner, east: 100, north: 0)
        let path = GpsSimRoutePlanner.resample([a, corner, end], spacing: 10)
        #expect(path.contains { GpsGeo.meters($0, corner) < 1e-6 })
        let plan = MovePlan(path: path, mode: .route)
        #expect(abs(plan.totalMeters - 200) < 0.5)
    }

    @Test func zeroLengthPlanArrivesImmediately() async throws {
        let plan = MovePlan(path: GpsSimRoutePlanner.straightPath(from: a, to: a), mode: .straight)
        #expect(plan.totalMeters == 0)
        #expect(plan.coordinate(atDistance: 10)!.latitude == a.latitude)
    }

    // MARK: 依時間算位置（加減速＋wall-clock）

    @Test func rampFactorAccelerationAndBraking() async throws {
        let walk = 5 / 3.6
        #expect(GpsSimMotion.rampFactor(movingSeconds: 0, rampUpSeconds: 4, remainingMeters: 500, speedMps: walk) == 0.3)
        #expect(abs(GpsSimMotion.rampFactor(movingSeconds: 2, rampUpSeconds: 4, remainingMeters: 500, speedMps: walk) - 0.5) < 1e-9)
        #expect(GpsSimMotion.rampFactor(movingSeconds: 4, rampUpSeconds: 4, remainingMeters: 500, speedMps: walk) == 1)
        // 步行減速區 5 公尺：剩 2.5 公尺時係數 0.5。
        #expect(GpsSimMotion.brakeMeters(speedMps: walk) == 5)
        #expect(abs(GpsSimMotion.rampFactor(movingSeconds: 60, rampUpSeconds: 4, remainingMeters: 2.5, speedMps: walk) - 0.5) < 1e-9)
        #expect(GpsSimMotion.rampFactor(movingSeconds: 60, rampUpSeconds: 4, remainingMeters: 0, speedMps: walk) == 0.3)
        // 開車 40 km/h：減速區＝速度×3 秒≈33.3 公尺，剩 20 公尺就已經在減速。
        let drive = 40 / 3.6
        #expect(abs(GpsSimMotion.brakeMeters(speedMps: drive) - drive * 3) < 1e-9)
        #expect(GpsSimMotion.rampFactor(movingSeconds: 60, rampUpSeconds: 4, remainingMeters: 20, speedMps: drive) < 1)
    }

    /// 照移動器的算法跑：每跳 dt 秒，速度＝目標×加減速（不加起伏），回傳每跳已走距離。
    private func simulate(totalMeters: Double, kmh: Double, ticks: [Double], rampUp: Double = 4) -> [Double] {
        var traveled = 0.0
        var moving = 0.0
        var out: [Double] = []
        for dt in ticks {
            moving += dt
            let ramp = GpsSimMotion.rampFactor(movingSeconds: moving, rampUpSeconds: rampUp,
                                               remainingMeters: totalMeters - traveled, speedMps: kmh / 3.6)
            traveled = GpsSimMotion.advance(traveled: traveled, total: totalMeters,
                                            speedMps: kmh / 3.6 * ramp, dt: dt)
            out.append(traveled)
        }
        return out
    }

    @Test func positionFollowsWallClockTime() async throws {
        // 步行 5 km/h 走 60 秒：理想 83.3 公尺，扣掉起步加速損失約 2 公尺（約 81.3）。
        let d = simulate(totalMeters: 10_000, kmh: 5, ticks: Array(repeating: 1, count: 60)).last!
        #expect(d > 78 && d < 83.4)
        // 計時器被延後：10 跳 1 秒 vs 1 跳延遲 5 秒＋5 跳 1 秒，加速後走的距離一樣。
        let steady = simulate(totalMeters: 10_000, kmh: 5, ticks: Array(repeating: 1, count: 20)).last!
        let delayed = simulate(totalMeters: 10_000, kmh: 5,
                               ticks: Array(repeating: 1, count: 10) + [5] + Array(repeating: 1, count: 5)).last!
        #expect(abs(steady - delayed) < 1e-9)
        // 位置由已走距離查出。
        let plan = MovePlan(path: GpsSimRoutePlanner.straightPath(from: a, to: b), mode: .straight)
        let here = plan.coordinate(atDistance: d)!
        #expect(abs(GpsGeo.meters(a, here) - d) < 0.5)
    }

    @Test func movementArrivesAndNeverOvershoots() async throws {
        let ds = simulate(totalMeters: 100, kmh: 5, ticks: Array(repeating: 1, count: 200))
        #expect(ds.allSatisfy { $0 <= 100 })
        let arrivedAt = try #require(ds.firstIndex { $0 >= 100 })
        // 100 公尺／1.39 m/s ≈ 72 秒，加上加減速損失約 77 秒到。
        #expect(arrivedAt > 70 && arrivedAt < 90)
        // 開車 40 km/h 走 1 公里：理想 90 秒，加減速後約 95 秒，也不會超過終點。
        let car = simulate(totalMeters: 1000, kmh: 40, ticks: Array(repeating: 1, count: 300))
        #expect(car.allSatisfy { $0 <= 1000 })
        let carArrived = try #require(car.firstIndex { $0 >= 1000 })
        #expect(carArrived > 88 && carArrived < 105)
    }

    @Test func clampPullsPointsBackInsideCircle() async throws {
        let outside = GpsSimWanderPlanner.offset(a, east: 40, north: 0)
        let pulled = GpsSimWanderPlanner.clamp(outside, center: a, radius: 30)
        #expect(GpsGeo.meters(a, pulled) <= 30)
        #expect(GpsGeo.meters(a, pulled) > 29.9)
        let inside = GpsSimWanderPlanner.offset(a, east: 10, north: 5)
        #expect(GpsSimWanderPlanner.clamp(inside, center: a, radius: 30).latitude == inside.latitude)
    }

    @Test func speedWobbleStaysWithinBand() async throws {
        var rng = SeededRNG(seed: 7)
        var w = SpeedWobble(amplitude: 0.08)
        var prev = 1.0
        for _ in 0..<2000 {
            let f = w.next(using: &rng)
            #expect(f >= 0.92 - 1e-12 && f <= 1.08 + 1e-12)
            // 低通：相鄰兩秒不會從一端跳到另一端。
            #expect(abs(f - prev) < 0.08)
            prev = f
        }
    }

    @Test func positionJitterStaysOneToThreeMeters() async throws {
        var rng = SeededRNG(seed: 11)
        var j = PositionJitter()
        for _ in 0..<2000 {
            _ = j.next(using: &rng)
            #expect(j.magnitude >= 1 - 1e-9 && j.magnitude <= 3 + 1e-9)
            #expect(abs(GpsGeo.meters(a, j.apply(to: a)) - j.magnitude) < 0.05)
        }
    }

    @Test func customSpeedIsClamped() async throws {
        #expect(MoveSpeedPreset.clampCustom(1) == 3.6)
        #expect(MoveSpeedPreset.clampCustom(250) == 100)
        #expect(MoveSpeedPreset.clampCustom(.nan) == 5)
        #expect(MoveSpeedPreset.walk.kmh == 5 && MoveSpeedPreset.bike.kmh == 15 && MoveSpeedPreset.drive.kmh == 40)
        #expect(MoveSpeedPreset.bike.transportType == .walking)
    }

    // MARK: 漫步

    @Test func wanderTargetsStayInsideCircle() async throws {
        var rng = SeededRNG(seed: 42)
        for size in WanderSize.allCases {
            let r = GpsSimWanderPlanner.radius(size: size, placeRadius: nil)
            var here = a
            var heading: Double?
            for _ in 0..<500 {
                let t = GpsSimWanderPlanner.nextTarget(center: a, radius: r, from: here,
                                                       previousHeading: heading, using: &rng)
                #expect(GpsGeo.meters(a, t) <= r + 0.05)
                heading = GpsSimWanderPlanner.heading(from: here, to: t)
                // 一段之內每個取樣點也都在圈內（圓是凸的，直線不會出圈）。
                let seg = GpsSimRoutePlanner.straightPath(from: here, to: t)
                #expect(seg.allSatisfy { GpsGeo.meters(a, $0) <= r + 0.05 })
                here = t
            }
        }
    }

    @Test func wanderRadiusNeverExceedsPlaceCircle() async throws {
        #expect(GpsSimWanderPlanner.radius(size: .large, placeRadius: 25) == 25)
        #expect(GpsSimWanderPlanner.radius(size: .small, placeRadius: 500) == 30)
        #expect(GpsSimWanderPlanner.radius(size: .medium, placeRadius: nil) == 100)
    }

    @Test func wanderAvoidsTurningBackMostOfTheTime() async throws {
        var rng = SeededRNG(seed: 99)
        var here = a
        var heading: Double?
        var sharpTurns = 0
        let n = 1000
        for _ in 0..<n {
            let t = GpsSimWanderPlanner.nextTarget(center: a, radius: 100, from: here,
                                                   previousHeading: heading, using: &rng)
            let h = GpsSimWanderPlanner.heading(from: here, to: t)
            if let prev = heading, GpsSimWanderPlanner.angleBetween(prev, h) >= 120 { sharpTurns += 1 }
            heading = h
            here = t
        }
        // 只有連續 5 次挑不到（貼著圈邊）才放寬，折返應是少數。
        #expect(sharpTurns < n / 5)
    }

    @Test func wanderDwellAndSpeedRanges() async throws {
        var rng = SeededRNG(seed: 5)
        for _ in 0..<500 {
            let s = GpsSimWanderPlanner.dwellSeconds(using: &rng)
            #expect(s >= 3 && s <= 15)
            let k = GpsSimWanderPlanner.segmentKmh(using: &rng)
            #expect(k >= 4.5 * 0.8 - 1e-9 && k <= 4.5 * 1.2 + 1e-9)
        }
    }

    @Test func wanderStopsAfterFourHours() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(GpsSimWanderPlanner.maxDuration == 4 * 3600)
        #expect(!GpsSimWanderPlanner.isExpired(startedAt: start, now: start.addingTimeInterval(4 * 3600 - 1)))
        #expect(GpsSimWanderPlanner.isExpired(startedAt: start, now: start.addingTimeInterval(4 * 3600)))
        #expect(GpsSimWanderPlanner.isExpired(startedAt: start, now: start.addingTimeInterval(5 * 3600)))
    }

    @Test func angleBetweenWrapsAround() async throws {
        #expect(GpsSimWanderPlanner.angleBetween(350, 10) == 20)
        #expect(GpsSimWanderPlanner.angleBetween(0, 180) == 180)
        #expect(abs(GpsSimWanderPlanner.heading(from: a, to: b) - 0) < 1e-6)
    }
}
