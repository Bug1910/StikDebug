//
//  GpsSimRouteMover.swift
//  PinFly
//
//  【這個檔案的角色】「移動過去／原地漫步」的司機。
//  拿到規劃員（GpsSimRoutePlanner）畫好的路徑後，每秒（1 Hz）算一次「現在該站在哪」，
//  交給 GpsSimEngine.sendMoveStep 送進手機；也負責暫停、繼續、斷線自動暫停、抵達、
//  漫步停留與 4 小時自動停止。
//
//  【為什麼這樣設計】
//  - 狀態機只有五態：idle（沒在動）、moving（往目的地走）、paused（使用者或斷線暫停）、
//    arrived（到了，交回 4 秒微飄）、wandering（原地漫步，waiting＝停留中）。
//  - 計時用主執行緒 Timer 加進 RunLoop .common（與 LocationSimulationSession 的 4 秒 Timer 同一套），
//    不用 Task.sleep 迴圈：上游那種寫法在背景較容易被延後（規格 3.6）。
//  - 距離用實際經過時間（wall-clock）累積：計時器被系統延後 5 秒，下一跳就補 5 秒的距離，
//    不會因為少跳幾次而越走越落後（規格 3.3）。暫停期間、以及上一點送失敗時的時間都不算，
//    恢復後才不會一下子跳很遠。
//  - 起步 3～5 秒線性加速、抵達前 max(5 公尺, 速度×3 秒) 開始減速，速度再乘 ±8% 的低通起伏
//    （漫步 ±20%），位置另加 1～3 公尺緩慢漂移的抖動，看起來比較像真人（研究員 11/02 補充、規格 10.5）。
//  - 「世代」generation：每次開始、停止、被接手都加 1。問路線的 8 秒、送點回呼回來時先比對世代，
//    不一致就丟掉，舊的一趟不會動到新一趟的狀態。
//  - 送點時上一點還沒回來就跳過本跳的「送」（序列佇列不堆積，規格第 5 節）。
//  - 連續 3 次送失敗就自動暫停（code 11＝手機鎖屏，其他＝連線中斷），之後每 4 秒試送一次，
//    成功就從原本的已走距離接著走。使用者暫停時也每 4 秒重送原地，讓模擬保持住。
//  - 抵達時先由移動器送出終點（不加抖動），回來後才交還 4 秒微飄。
//  - 「停止移動」＝停在原地、模擬繼續（交回 GpsSimEngine 的 4 秒微飄）；不是回真實位置。
//  - App 被系統殺掉後不續跑、來回／多點都不做（v2）。
//

import Foundation
import CoreLocation

/// 暫停原因：畫面依此顯示不同提示。
enum MovePauseReason: Equatable {
    case user
    /// 連續 3 次送失敗（code 3/9 等）：「連線中斷，連上後自動繼續」。
    case connectionLost
    /// code 11：手機鎖屏拒收，「請解鎖手機」。
    case deviceLocked
}

/// 抵達後要做的事（捷徑「抵達後」參數；App 內一律 .stay）。
enum MoveArrivalAction: Equatable {
    case stay
    /// 在抵達的地點原地漫步；radius＝已取「檔位與地點範圍」較小者。
    case wander(radius: Double)
    /// 回到真實位置（engine.stop）。
    case stopSimulation
}

enum MoveState: Equatable {
    case idle
    case moving
    case paused(MovePauseReason)
    case arrived
    /// waiting＝在目標點停留中（3～15 秒）。
    case wandering(waiting: Bool)
}

@MainActor
final class GpsSimRouteMover: ObservableObject {
    static let shared = GpsSimRouteMover()

    // MARK: 給畫面看的狀態

    @Published private(set) var state: MoveState = .idle
    /// 正在問 MKDirections（最多 8 秒）；畫面可顯示「規劃路線中…」。
    @Published private(set) var isPlanning = false
    @Published private(set) var plan: MovePlan?
    /// 已走公尺（移動模式）。
    @Published private(set) var traveledMeters: Double = 0
    /// 目前速度（km/h，含加減速與起伏），給進度卡顯示。
    @Published private(set) var currentKmh: Double = 0
    /// 設定的目標速度（km/h）。
    @Published private(set) var targetKmh: Double = 0
    @Published private(set) var destinationName: String?
    /// 漫步停留剩幾秒（畫面「剩餘停留 N 秒」）。
    @Published private(set) var dwellRemaining: Int = 0
    /// 漫步開始時間（4 小時上限依此計算）。
    @Published private(set) var wanderStartedAt: Date?
    /// 最近一次 4 小時自動停止的時間；畫面可據此 toast。
    @Published private(set) var wanderAutoStoppedAt: Date?

    var isActive: Bool {
        switch state {
        case .idle, .arrived: return false
        default: return true
        }
    }

    /// 每次 start／startWander 加 1：捷徑動作用來確認「還是自己開始的那一趟」。
    private(set) var runSerial = 0
    /// 本趟已被手機接受的點數（含抵達點）；捷徑動作等第一點成功才回報。
    private(set) var deliveredSteps = 0
    /// 本趟最近一次送點的結果代碼（0＝成功；busyCode 不記）。
    private(set) var lastStepCode: Int32?

    /// 剩餘公尺：只在路線／直線移動中（含暫停）有值。
    var remainingMeters: Int? {
        guard let plan else { return nil }
        switch state {
        case .moving, .paused:
            return GpsMoveEstimate.remainingMeters(total: plan.totalMeters, traveled: traveledMeters)
        default:
            return nil
        }
    }

    /// 依目標速度推算的抵達時間：只在移動中（未暫停）有值。
    var estimatedArrival: Date? {
        guard state == .moving, let left = remainingMeters else { return nil }
        return GpsMoveEstimate.eta(remainingMeters: Double(left), kmh: targetKmh, now: Date())
    }

    // MARK: 常數

    static let tickInterval: TimeInterval = 1
    static let routeWobble = 0.08
    static let wanderWobble = 0.20
    static let failLimit = 3
    /// 暫停後每幾秒重送一次（斷線＝試送；使用者暫停＝保持模擬）。
    static let probeEvery: TimeInterval = 4
    /// 漫步停留時每幾秒送一次（位置不變，省電；規格 9.5）。
    static let dwellSendEvery: TimeInterval = 2
    /// 漫步時一跳最多補幾秒：背景被凍結很久回來，不要一口氣走完好幾段。
    static let wanderMaxDt: TimeInterval = 5

    // MARK: 內部

    private var timer: Timer?
    private var lastTick: Date?
    private var movingSeconds: Double = 0
    private var rampUpSeconds: Double = 4
    private var wobble = SpeedWobble(amplitude: routeWobble)
    private var jitter = PositionJitter()
    private var rng = SystemRandomNumberGenerator()
    private var sendInFlight = false
    private var failStreak = 0
    private var lastProbe: Date?
    private var routeID: UUID?
    /// 每次開始／停止／被接手加 1；非同步回來的結果世代不同就丟掉。
    private var generation = 0
    /// 最近一次算出的「路徑上」位置（不含抖動）；停止移動就停在這裡。
    private var basePoint: CLLocationCoordinate2D?
    private var resumeTarget: MoveState?
    private var pausedAt: Date?

    // 漫步專用
    private var wanderCenter: CLLocationCoordinate2D?
    private var wanderRadius: Double = 0
    /// false＝不套用 4 小時自動停止（預排行程的漫步項目）。
    private var wanderAutoStop = true
    private var wanderSegment: MovePlan?
    private var wanderHeading: Double?
    private var dwellUntil: Date?
    private var lastDwellSend: Date?
    private var engine: GpsSimEngine { GpsSimEngine.shared }

    // 抵達後（捷徑）
    private var arrivalAction: MoveArrivalAction = .stay
    /// 抵達後幾秒回到真實位置（持續時間自抵達時起算）；nil＝不限。
    private var arrivalAutoReturn: TimeInterval?
    private var arrivalPlaceID: String?
    private var arrivalCenter: CLLocationCoordinate2D?

    private init() {}

    // MARK: - 開始

    /// 規劃並開始「移動過去」：路線模式先問 MKDirections（最多 8 秒），失敗自動改直線。
    /// 回傳規劃結果（fellBackToStraight＝畫面要 toast「找不到路線，改走直線」）；
    /// 規劃期間使用者按了停止／前往（世代改變）就丟掉結果、回 nil。
    @discardableResult
    func moveTo(_ destination: CLLocationCoordinate2D, name: String, placeID: String? = nil,
                center: CLLocationCoordinate2D? = nil, from start: CLLocationCoordinate2D,
                mode: MoveMode, speed: MoveSpeedPreset, kmh: Double? = nil,
                afterArrival: MoveArrivalAction = .stay,
                autoReturnAfter: TimeInterval? = nil) async -> MovePlan? {
        // 上一趟還在跑就正常收尾（停在原地交還微飄）；沒在跑也要讓舊的規劃作廢。
        if state != .idle { stopMoving() } else { cancelForTakeover() }
        let token = generation
        isPlanning = true
        let planMode: MoveMode = mode == .wander ? .straight : mode
        let plan = await GpsSimRoutePlanner.plan(from: start, to: destination, mode: planMode, speed: speed)
        guard token == generation else { return nil }
        isPlanning = false
        guard !plan.path.isEmpty else { return nil }
        // 參數 `from start:` 會遮住同名方法，必須寫 self.start。
        self.start(plan: plan, name: name, placeID: placeID, center: center,
                   kmh: kmh.map(MoveSpeedPreset.clampCustom) ?? speed.kmh,
                   afterArrival: afterArrival, autoReturnAfter: autoReturnAfter)
        return plan
    }

    /// 用已經規劃好的路徑開始（行程預先規劃、測試用）。
    /// afterArrival／autoReturnAfter：捷徑用；App 內呼叫沿用預設（停留、不限時間）。
    /// startAtMeters：從路徑上第幾公尺開始（行程補位：斷線、鎖定、App 重開後直接接到應在的位置，
    /// 規格 10.2.3）；預設 0＝從起點走。超過全長＝下一跳就抵達。
    func start(plan: MovePlan, name: String, placeID: String? = nil,
               center: CLLocationCoordinate2D? = nil, kmh: Double,
               afterArrival: MoveArrivalAction = .stay, autoReturnAfter: TimeInterval? = nil,
               startAtMeters: Double = 0) {
        guard let origin = plan.start else { return }
        let skipMeters = startAtMeters.isFinite ? min(max(0, startAtMeters), plan.totalMeters) : 0
        let first = skipMeters > 0 ? (plan.coordinate(atDistance: skipMeters) ?? origin) : origin
        finishPreviousRun()
        tearDown()
        // 新的移動取消之前的「持續時間」（規格 12.3.1）。
        GpsSimAutoReturn.shared.clear(reason: "new move")
        beginRunCounters()
        arrivalAction = afterArrival
        arrivalAutoReturn = afterArrival == .stopSimulation ? nil : autoReturnAfter
        arrivalPlaceID = placeID
        arrivalCenter = center ?? plan.destination
        self.plan = plan
        destinationName = name
        targetKmh = MoveSpeedPreset.clampCustom(kmh)
        traveledMeters = skipMeters
        movingSeconds = 0
        rampUpSeconds = Double.random(in: GpsSimMotion.rampUpSecondsRange, using: &rng)
        wobble = SpeedWobble(amplitude: Self.routeWobble)
        jitter = PositionJitter()
        failStreak = 0
        basePoint = first
        wanderAutoStoppedAt = nil
        engine.beginMove(name: name, placeID: placeID, center: center, at: first)
        routeID = LocationSimulationSession.shared.startRoute(at: first, coordinates: plan.path)
        state = .moving
        startTimer()
    }

    /// 開始原地漫步。center＝圈心、radius＝已取「檔位與地點圈」較小者
    /// （GpsSimWanderPlanner.radius(size:placeRadius:)）；from＝目前位置（預設圈心）。
    /// autoStop：漫步滿 4 小時自動停止；預排行程傳 false（項目結束由行程決定，
    /// 暫停過的漫步項目才不會被 4 小時上限提早結束，工程規劃第四節第 6 點）。
    func startWander(center: CLLocationCoordinate2D, radius: Double, name: String,
                     placeID: String? = nil, from current: CLLocationCoordinate2D? = nil,
                     autoStop: Bool = true) {
        finishPreviousRun()
        tearDown()
        GpsSimAutoReturn.shared.clear(reason: "new wander")
        beginRunCounters()
        wanderAutoStop = autoStop
        let here = current.map { GpsSimWanderPlanner.clamp($0, center: center, radius: max(1, radius)) } ?? center
        plan = nil
        destinationName = name
        wanderCenter = center
        wanderRadius = max(1, radius)
        wanderHeading = nil
        wanderStartedAt = Date()
        wanderAutoStoppedAt = nil
        wobble = SpeedWobble(amplitude: Self.wanderWobble)
        jitter = PositionJitter()
        failStreak = 0
        basePoint = here
        engine.beginMove(name: name, placeID: placeID, center: center, at: here)
        beginWanderSegment(from: here)
        state = .wandering(waiting: false)
        startTimer()
    }

    // MARK: - 控制

    func pause() {
        guard isActive else { return }
        if case .paused = state { return }
        resumeTarget = state
        pausedAt = Date()
        lastProbe = Date()
        state = .paused(.user)
    }

    func resume() {
        guard case .paused = state else { return }
        failStreak = 0
        resumeFromPause()
    }

    /// 停止移動：停在目前位置，模擬繼續（交回 4 秒微飄）。
    func stopMoving() {
        let here = basePoint
        let wasRunning = state != .idle
        tearDown()
        state = .idle
        if wasRunning, let here { engine.endMove(at: here) }
    }

    /// 換一趟之前先把上一趟正常收尾（停在原地交回微飄），引擎才不會留著舊的移動狀態。
    private func finishPreviousRun() {
        if state != .idle { stopMoving() }
    }

    /// 別的動作（前往其他地點、停止模擬）接手、或規劃中被取消時呼叫：
    /// 只停計時器並讓所有進行中的非同步結果作廢，不交回微飄（接手者自己處理）。
    func cancelForTakeover() {
        tearDown()
        state = .idle
    }

    private func beginRunCounters() {
        runSerial &+= 1
        deliveredSteps = 0
        lastStepCode = nil
    }

    private func tearDown() {
        generation &+= 1
        arrivalAction = .stay
        arrivalAutoReturn = nil
        arrivalPlaceID = nil
        arrivalCenter = nil
        isPlanning = false
        timer?.invalidate()
        timer = nil
        lastTick = nil
        sendInFlight = false
        lastProbe = nil
        resumeTarget = nil
        pausedAt = nil
        dwellUntil = nil
        lastDwellSend = nil
        wanderSegment = nil
        wanderCenter = nil
        wanderStartedAt = nil
        currentKmh = 0
        if routeID != nil {
            routeID = nil
            LocationSimulationSession.shared.clearRoute()
        }
    }

    private func startTimer() {
        lastTick = Date()
        let t = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    /// 從暫停回到原本狀態；暫停期間的時間不算距離、停留時間順延。
    private func resumeFromPause() {
        let now = Date()
        lastTick = now
        if let until = dwellUntil, let pausedAt {
            dwellUntil = until.addingTimeInterval(now.timeIntervalSince(pausedAt))
        }
        pausedAt = nil
        lastProbe = nil
        state = resumeTarget ?? .moving
        resumeTarget = nil
    }

    // MARK: - 每秒一跳

    private func tick() {
        // 別人清掉了路線（例如 engine.send／stop 呼叫 clearRoute）→ 我們已不是目前的移動。
        if let id = routeID, !LocationSimulationSession.shared.isCurrentRoute(id) {
            routeID = nil
            cancelForTakeover()
            return
        }
        let now = Date()
        let dt = max(0, now.timeIntervalSince(lastTick ?? now))
        lastTick = now

        switch state {
        case .idle, .arrived:
            return
        case .paused:
            if pausedAt == nil { pausedAt = now }
            // 每 4 秒重送原地：斷線＝試試連回來沒；使用者暫停＝讓模擬保持住。
            guard let here = basePoint else { return }
            if let last = lastProbe, now.timeIntervalSince(last) < Self.probeEvery { return }
            lastProbe = now
            send(here)
        case .moving:
            tickMoving(dt: dt)
        case .wandering:
            tickWander(dt: min(dt, Self.wanderMaxDt), now: now)
        }
    }

    /// 上一點送失敗時這跳不前進（時間丟掉），只重送原地，恢復後才不會跳很遠。
    private var canAdvance: Bool { failStreak == 0 }

    private func tickMoving(dt: Double) {
        guard let plan else { return }
        let total = plan.totalMeters
        if canAdvance {
            movingSeconds += dt
            let targetMps = targetKmh / 3.6
            let ramp = GpsSimMotion.rampFactor(movingSeconds: movingSeconds, rampUpSeconds: rampUpSeconds,
                                               remainingMeters: total - traveledMeters, speedMps: targetMps)
            let mps = targetMps * ramp * wobble.next(using: &rng)
            currentKmh = mps * 3.6
            traveledMeters = GpsSimMotion.advance(traveled: traveledMeters, total: total, speedMps: mps, dt: dt)
        } else {
            currentKmh = 0
        }
        guard let base = plan.coordinate(atDistance: traveledMeters) else { return }
        basePoint = base
        if traveledMeters >= total {
            arrive(at: base)
            return
        }
        _ = jitter.next(using: &rng)
        send(jitter.apply(to: base))
    }

    /// 抵達：停計時器，由移動器自己送出終點（不加抖動），回來後才交還 4 秒微飄。
    private func arrive(at point: CLLocationCoordinate2D) {
        timer?.invalidate()
        timer = nil
        currentKmh = 0
        if routeID != nil {
            routeID = nil
            LocationSimulationSession.shared.clearRoute()
        }
        state = .arrived
        let token = generation
        let name = destinationName
        // 之後的 tearDown 會清掉抵達設定，先記下來。
        let action = arrivalAction
        let autoReturn = arrivalAutoReturn
        let placeID = arrivalPlaceID
        let center = arrivalCenter
        engine.sendMoveStep(point) { [weak self] code in
            // 送成功或失敗都交還微飄：失敗時 4 秒重送會繼續試，斷線語意由 resendTick 處理。
            guard let self, token == self.generation else { return }
            if code == 0 { self.deliveredSteps += 1 }
            if code != GpsSimEngine.busyCode { self.lastStepCode = code }
            let endedNormally = self.engine.endMove(at: point, arrivedName: name)
            // 抵達後動作與「自抵達起算」的持續時間只在終點真的送到、移動正常結束時才做；
            // 否則手機可能還不在目的地（4 秒重送會繼續試），不能開始漫步或計時。
            guard code == 0, endedNormally else {
                if action != .stay || autoReturn != nil {
                    GpsSimIntentLog.error("arrival action skipped: final point code \(code), ended normally \(endedNormally)")
                }
                return
            }
            self.runArrivalAction(action, autoReturnAfter: autoReturn, at: point, name: name ?? "",
                                  placeID: placeID, center: center)
        }
    }

    /// 抵達後的動作（捷徑「抵達後」）。也給「已在目的地附近、不需要移動」的捷徑路徑使用。
    func runArrivalAction(_ action: MoveArrivalAction, autoReturnAfter: TimeInterval?,
                          at point: CLLocationCoordinate2D, name: String,
                          placeID: String?, center: CLLocationCoordinate2D?) {
        switch action {
        case .stay:
            if let seconds = autoReturnAfter { GpsSimAutoReturn.shared.arm(after: seconds) }
        case .wander(let radius):
            // startWander 會取消舊的持續時間，所以之後才登記。
            self.startWander(center: center ?? point, radius: radius, name: name, placeID: placeID, from: point)
            if let seconds = autoReturnAfter { GpsSimAutoReturn.shared.arm(after: seconds) }
            GpsSimIntentLog.info("arrival: wander started")
        case .stopSimulation:
            GpsSimIntentLog.info("arrival: stopping simulation")
            engine.stop { code in
                guard code != 0 else { return }
                GpsSimIntentLog.error("arrival stop failed (code \(code))")
                GpsSimAutoReturn.notify("無法回到真實位置。請開啟 PinFly 並點選「停止模擬」。（錯誤 12）",
                                        id: "gpsSim.arrival.stopFailed")
            }
        }
    }

    // MARK: - 漫步

    private func beginWanderSegment(from here: CLLocationCoordinate2D) {
        guard let center = wanderCenter else { return }
        let target = GpsSimWanderPlanner.nextTarget(center: center, radius: wanderRadius, from: here,
                                                    previousHeading: wanderHeading, using: &rng)
        wanderHeading = GpsSimWanderPlanner.heading(from: here, to: target)
        let seg = MovePlan(path: GpsSimRoutePlanner.straightPath(from: here, to: target), mode: .wander)
        wanderSegment = seg
        traveledMeters = 0
        movingSeconds = 0
        rampUpSeconds = Double.random(in: GpsSimMotion.rampUpSecondsRange, using: &rng)
        targetKmh = GpsSimWanderPlanner.segmentKmh(using: &rng)
        routeID = LocationSimulationSession.shared.startRoute(at: here, coordinates: seg.path)
    }

    /// 加抖動後夾回圈內（漫步永遠不走出使用者畫的圈）。
    private func jittered(_ base: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        _ = jitter.next(using: &rng)
        let p = jitter.apply(to: base)
        guard let center = wanderCenter else { return p }
        return GpsSimWanderPlanner.clamp(p, center: center, radius: wanderRadius)
    }

    private func tickWander(dt: Double, now: Date) {
        if wanderAutoStop, let started = wanderStartedAt,
           GpsSimWanderPlanner.isExpired(startedAt: started, now: now) {
            wanderAutoStoppedAt = now
            stopMoving()
            return
        }
        guard let here = basePoint else { return }

        if let until = dwellUntil {
            // 停留中：位置不動，每 2 秒送一次（只加 1～3 公尺抖動）。
            currentKmh = 0
            dwellRemaining = max(0, Int(until.timeIntervalSince(now).rounded(.up)))
            if now >= until {
                dwellUntil = nil
                lastDwellSend = nil
                beginWanderSegment(from: here)
                state = .wandering(waiting: false)
            } else {
                if let last = lastDwellSend, now.timeIntervalSince(last) < Self.dwellSendEvery { return }
                lastDwellSend = now
                send(jittered(here))
                return
            }
        }

        guard let seg = wanderSegment else { beginWanderSegment(from: here); return }
        let total = seg.totalMeters
        if canAdvance {
            movingSeconds += dt
            let targetMps = targetKmh / 3.6
            let ramp = GpsSimMotion.rampFactor(movingSeconds: movingSeconds, rampUpSeconds: rampUpSeconds,
                                               remainingMeters: total - traveledMeters, speedMps: targetMps)
            let mps = targetMps * ramp * wobble.next(using: &rng)
            currentKmh = mps * 3.6
            traveledMeters = GpsSimMotion.advance(traveled: traveledMeters, total: total, speedMps: mps, dt: dt)
        } else {
            currentKmh = 0
        }
        let base = seg.coordinate(atDistance: traveledMeters) ?? here
        basePoint = base
        if traveledMeters >= total {
            let until = now.addingTimeInterval(GpsSimWanderPlanner.dwellSeconds(using: &rng))
            dwellUntil = until
            dwellRemaining = max(0, Int(until.timeIntervalSince(now).rounded(.up)))
            lastDwellSend = now
            state = .wandering(waiting: true)
        }
        send(jittered(base))
    }

    // MARK: - 送點與失敗處理

    private func send(_ point: CLLocationCoordinate2D) {
        // 上一點還沒回來：跳過這次送點，佇列不堆積。
        guard !sendInFlight else { return }
        sendInFlight = true
        let token = generation
        engine.sendMoveStep(point) { [weak self] code in
            // 舊一趟的回呼：不動新一趟的狀態（tearDown 已把 sendInFlight 歸零）。
            guard let self, token == self.generation else { return }
            self.sendInFlight = false
            if code == 0 { self.deliveredSteps += 1 }
            if code != GpsSimEngine.busyCode { self.lastStepCode = code }
            self.handleSendResult(code)
        }
    }

    private func handleSendResult(_ code: Int32) {
        guard isActive else { return }
        if code == 0 {
            failStreak = 0
            if case .paused(let reason) = state, reason != .user {
                // 連回來了：從原本的已走距離繼續，斷線期間不算距離。
                resumeFromPause()
            }
            return
        }
        // 引擎忙（使用者剛按了前往／停止）：不算失敗。
        if code == GpsSimEngine.busyCode { return }
        failStreak += 1
        guard failStreak >= Self.failLimit else { return }
        if case .paused(let reason) = state {
            // 使用者暫停中的保持重送也連續失敗：通知引擎，畫面才看得到斷線。
            if reason == .user && failStreak == Self.failLimit { engine.noteMoveLinkLost(code: code) }
            return
        }
        resumeTarget = state
        pausedAt = Date()
        lastProbe = Date()
        state = .paused(code == 11 ? .deviceLocked : .connectionLost)
        engine.noteMoveLinkLost(code: code)
    }
}
