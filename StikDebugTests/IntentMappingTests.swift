//
//  IntentMappingTests.swift
//  StikDebugTests
//
//  【這個檔案的角色】「前往地點」捷徑參數換算與時間估算的單元測試（規格 12.3.1）。
//  只測純函式（GpsMoveRequest.make、GpsMoveEstimate、GpsSimAutoReturn.isDue），
//  不連手機、不碰 UserDefaults 以外的狀態，模擬器或 CI 上都能跑。
//

import Foundation
import Testing
@testable import StikDebug

struct IntentMappingTests {

    /// 只填地點時的參數組合（@Parameter 的預設值）。
    private func defaults(method: GpsMoveMethod = .direct, speed: GpsMoveSpeed = .walk, customKmh: Double = 5,
                          afterArrival: GpsAfterArrival = .stay, wanderRange: GpsWanderRange = .app,
                          appWanderSize: WanderSize = .medium, durationMinutes: Int? = nil) -> GpsMoveRequest {
        GpsMoveRequest.make(method: method, speed: speed, customKmh: customKmh, afterArrival: afterArrival,
                            wanderRange: wanderRange, appWanderSize: appWanderSize,
                            durationMinutes: durationMinutes)
    }

    // MARK: 預設值＝舊行為

    @Test func defaultsEqualLegacyBehavior() {
        #expect(defaults() == GpsMoveRequest.legacyDirect)
        #expect(defaults().durationSeconds == nil)
        #expect(defaults().kind == .direct)
    }

    // MARK: 速度

    @Test func presetSpeedsMapToPlannerPresets() {
        let walk = defaults(method: .route, speed: .walk)
        #expect(walk.kind == .route)
        #expect(walk.speedPreset == .walk)
        #expect(walk.kmh == MoveSpeedPreset.walk.kmh)
        #expect(walk.isCustomSpeed == false)

        let bike = defaults(method: .line, speed: .bike)
        #expect(bike.kind == .straight)
        #expect(bike.speedPreset == .bike)
        #expect(bike.kmh == 15)

        let drive = defaults(method: .route, speed: .drive)
        #expect(drive.kmh == 40)
        #expect(drive.speedLabel == "駕車")
    }

    @Test func customSpeedIsClamped() {
        #expect(defaults(method: .route, speed: .custom, customKmh: 1).kmh == 3.6)
        #expect(defaults(method: .route, speed: .custom, customKmh: 500).kmh == 100)
        #expect(defaults(method: .route, speed: .custom, customKmh: 6).kmh == 6)
        #expect(defaults(method: .route, speed: .custom, customKmh: .nan).kmh == MoveSpeedPreset.walk.kmh)
        #expect(defaults(method: .route, speed: .custom, customKmh: 6).speedLabel == "自訂 6 km/h")
        #expect(defaults(method: .route, speed: .custom, customKmh: 6).isCustomSpeed)
    }

    @Test func customSpeedPicksRouteTransport() {
        #expect(defaults(method: .route, speed: .custom, customKmh: 6).speedPreset == .walk)
        #expect(defaults(method: .route, speed: .custom, customKmh: 60).speedPreset == .drive)
    }

    @Test func speedIgnoredForDirectAndWander() {
        #expect(defaults(method: .direct, speed: .drive).kmh == nil)
        #expect(defaults(method: .wander, speed: .custom, customKmh: 80).kmh == nil)
        #expect(defaults(method: .wander, speed: .drive).speedPreset == nil)
    }

    // MARK: 抵達後

    @Test func afterArrivalIgnoredForDirectAndWander() {
        #expect(defaults(method: .direct, afterArrival: .stop).arrival == .stay)
        #expect(defaults(method: .direct, afterArrival: .wander).arrival == .stay)
        #expect(defaults(method: .wander, afterArrival: .stop).arrival == .stay)
        // 直接前往選了「停止模擬」也照樣保留持續時間。
        #expect(defaults(method: .direct, afterArrival: .stop, durationMinutes: 30).durationMinutes == 30)
    }

    @Test func afterArrivalForRouteAndStraight() {
        #expect(defaults(method: .route, afterArrival: .stay).arrival == .stay)
        let wander = defaults(method: .line, afterArrival: .wander, appWanderSize: .large)
        #expect(wander.arrival == .wander)
        #expect(wander.wanderSize == .large)
        #expect(defaults(method: .route, afterArrival: .stop).arrival == .stopSimulation)
        #expect(defaults(method: .route, afterArrival: .stay).wanderSize == nil)
    }

    // MARK: 漫步範圍

    @Test func wanderRangeResolves() {
        #expect(defaults(method: .wander, wanderRange: .app, appWanderSize: .small).wanderSize == .small)
        #expect(defaults(method: .wander, wanderRange: .large, appWanderSize: .small).wanderSize == .large)
        #expect(defaults(method: .wander, wanderRange: .medium).wanderSize == .medium)
        #expect(defaults(method: .direct, wanderRange: .large).wanderSize == nil)
    }

    @Test func appWanderSizeReadsAppSetting() throws {
        let suite = "IntentMappingTests.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        #expect(GpsMoveRequest.appWanderSize(store) == .medium)
        store.set("large", forKey: "gpsSim.wanderSize")
        #expect(GpsMoveRequest.appWanderSize(store) == .large)
        store.set("bogus", forKey: "gpsSim.wanderSize")
        #expect(GpsMoveRequest.appWanderSize(store) == .medium)
    }

    // MARK: 持續時間

    @Test func durationBounds() {
        #expect(defaults(durationMinutes: 0).durationMinutes == 1)
        #expect(defaults(durationMinutes: -5).durationMinutes == 1)
        #expect(defaults(durationMinutes: 1).durationMinutes == 1)
        #expect(defaults(durationMinutes: 720).durationMinutes == 720)
        #expect(defaults(durationMinutes: 721).durationMinutes == 720)
        #expect(defaults(durationMinutes: 15).durationSeconds == 900)
        #expect(defaults(durationMinutes: nil).durationMinutes == nil)
    }

    @Test func durationStartPoint() {
        #expect(defaults(method: .direct, durationMinutes: 5).durationFromArrival == false)
        #expect(defaults(method: .wander, durationMinutes: 5).durationFromArrival == false)
        #expect(defaults(method: .route, durationMinutes: 5).durationFromArrival == true)
        #expect(defaults(method: .line, durationMinutes: 5).durationFromArrival == true)
        // 抵達後＝停止模擬時不使用持續時間。
        #expect(defaults(method: .route, afterArrival: .stop, durationMinutes: 5).durationMinutes == nil)
        #expect(defaults(method: .route, afterArrival: .wander, durationMinutes: 5).durationMinutes == 5)
    }

    // MARK: 估算

    @Test func etaFromRemainingAndSpeed() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // 3.6 km/h = 1 m/s → 1000 公尺 1000 秒。
        let eta = try #require(GpsMoveEstimate.eta(remainingMeters: 1000, kmh: 3.6, now: now))
        #expect(abs(eta.timeIntervalSince(now) - 1000) < 0.001)
        #expect(GpsMoveEstimate.eta(remainingMeters: 1000, kmh: 0, now: now) == nil)
        #expect(GpsMoveEstimate.eta(remainingMeters: -50, kmh: 5, now: now) == now)
    }

    @Test func remainingNeverNegative() {
        #expect(GpsMoveEstimate.remainingMeters(total: 100, traveled: 150) == 0)
        #expect(GpsMoveEstimate.remainingMeters(total: 100, traveled: 100) == 0)
        #expect(GpsMoveEstimate.remainingMeters(total: 100, traveled: 39.6) == 60)
        #expect(GpsMoveEstimate.remainingMeters(total: .infinity, traveled: 0) == 0)
    }

    @Test func tooLongThreshold() {
        // 步行 5 km/h × 12 小時 = 60 公里。
        #expect(GpsMoveEstimate.isTooLong(meters: 59_000, kmh: 5) == false)
        #expect(GpsMoveEstimate.isTooLong(meters: 61_000, kmh: 5) == true)
        #expect(GpsMoveEstimate.isTooLong(meters: 10, kmh: 0) == true)
    }

    @Test func distanceText() {
        #expect(GpsMoveEstimate.distanceText(850) == "850 公尺")
        #expect(GpsMoveEstimate.distanceText(2300) == "2.3 公里")
    }

    // MARK: 持續時間鬧鐘

    @Test func autoReturnIsDue() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        #expect(GpsSimAutoReturn.isDue(deadline: nil, now: now) == false)
        #expect(GpsSimAutoReturn.isDue(deadline: now.addingTimeInterval(1), now: now) == false)
        #expect(GpsSimAutoReturn.isDue(deadline: now, now: now) == true)
        #expect(GpsSimAutoReturn.isDue(deadline: now.addingTimeInterval(-60), now: now) == true)
    }
}
