//
//  GpsSimIntents.swift
//  StikDebug (GpsSim fork)
//
//  The "buttons" the iOS Shortcuts app can press: PinFly連線 (legacy) / 定位到地點 / 停止模擬 / 看真實位置.
//  Signing and status actions live in GpsSimRenewIntents.swift; the shared return value PinFly狀態
//  in GpsSimIntentStatus.swift. Never rename an intent type or @Parameter property: Shortcuts stores
//  actions by type name and parameters by property name, so a rename breaks the owner's Shortcuts.
//  The one-tap Shortcut the owner built 2026-10-15 (only cellular available):
//    VPN connect -> Airplane Mode ON -> Wi-Fi ON -> 定位到地點 (ask) -> Airplane Mode OFF -> cellular ON.
//  PinFly連線 is no longer needed there: it waits on the JIT tunnel, which the location link doesn't use.
//  Once the tunnel is up it keeps working after airplane mode goes off (verified on device).
//
//  Background vs foreground: openAppWhenRun is false on all three. Reason: the existing
//  KillProcessIntent in App/Intents.swift already starts the same tunnel (startTunnelInBackground)
//  from a background intent, and simulate_location / clear_simulated_location are plain FFI calls
//  that need no UI. Not yet verified on a device; if a Shortcut run ever reports a timeout while the
//  app works when opened by hand, flip openAppWhenRun to true.
//
//  The AppShortcutsProvider entries live in StikDebugShortcuts (App/Intents.swift): an app may have
//  only one provider.
//

import AppIntents
import Contacts
import CoreLocation
import Foundation

// MARK: - Place entity (what the Shortcut's picker lists)

struct GpsPlaceEntity: AppEntity, Sendable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "地點"
    static var defaultQuery = GpsPlaceQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct GpsPlaceQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [GpsPlaceEntity] {
        await MainActor.run {
            GpsPlaceStore.shared.reload()
            return GpsPlaceStore.shared.sorted
                .filter { identifiers.contains($0.id) }
                .map { GpsPlaceEntity(id: $0.id, name: $0.name) }
        }
    }

    func suggestedEntities() async throws -> [GpsPlaceEntity] {
        await MainActor.run {
            GpsPlaceStore.shared.reload()
            return GpsPlaceStore.shared.sorted.map { GpsPlaceEntity(id: $0.id, name: $0.name) }
        }
    }
}

// MARK: - Shared waiting logic

@MainActor
private enum GpsSimIntentRunner {
    /// Starts the tunnel if needed and polls up to `seconds`; re-kicks the start every 5 s
    /// (TunnelManager ignores a start while one is already running).
    static func waitForTunnel(seconds: Int = 20) async -> Bool {
        let tunnel = TunnelManager.shared
        if tunnel.isConnected { return true }
        guard GpsSimEngine.pairingExists else { return false }
        startTunnelInBackground(showErrorUI: false)
        for tick in 1...(seconds * 4) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if tunnel.isConnected { return true }
            if tick % 20 == 0 { startTunnelInBackground(showErrorUI: false) }
        }
        return tunnel.isConnected
    }

    /// Runs a device call and, while it fails with "not connected" (3) or "connection dropped" (9),
    /// retries for up to `seconds`. Replaces waiting on TunnelManager: that is the JIT tunnel,
    /// which the location link does not use and which never comes up on 4G (cost 20 s per run).
    static func retryingLink(seconds: Int = 12, _ call: @escaping (@escaping (Int32) -> Void) -> Void) async -> Int32 {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while true {
            await waitUntilIdle()
            let code: Int32 = await withCheckedContinuation { continuation in
                call { continuation.resume(returning: $0) }
            }
            guard code == 3 || code == 9, Date() < deadline else { return code }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    static func waitUntilIdle(seconds: Int = 5) async {
        for _ in 0..<(seconds * 4) where GpsSimEngine.shared.isBusy {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    static func tunnelFailureMessage() -> String {
        guard GpsSimEngine.pairingExists else { return "尚無配對檔。請依使用教學以電腦產生配對檔。" }
        let reason = GpsSimNetwork.shared.onWiFi ? GpsSimNetwork.checkVPNMessage : GpsSimNetwork.noWifiMessage
        return "無法連線至手機的定位服務（已等候 20 秒）。\(reason)"
    }

    /// Engine status code → Shortcuts dialog text. Code 1's app text points at the in-app 「改回預設」
    /// banner button, which Shortcuts does not have, so the dialog sends the user into the app instead.
    static func failureMessage(_ code: Int32) -> String {
        code == 1 ? "目標 IP 錯誤。請開啟 PinFly，點選「改回預設」。（錯誤 1）" : GpsSimIssue.from(code: code).message
    }

    /// Shortcuts have no 「重試」 button: the app's "再點選「重試」／後重試／再重試" becomes
    /// "再重新執行此捷徑" (spec 12.2 rule 4). Busy maps to error 24.
    static func shortcutFailure(_ code: Int32) -> String {
        if code == GpsSimEngine.busyCode { return GpsShortcutMessage.busy }
        return failureMessage(code)
            .replacingOccurrences(of: "再點選「重試」", with: "再重新執行此捷徑")
            .replacingOccurrences(of: "後重試", with: "後再重新執行此捷徑")
            .replacingOccurrences(of: "再重試", with: "再重新執行此捷徑")
    }
}

/// Shortcut-level errors 20～24 (spec 12.2 rule 6, 12.3.1). Format: 發生了什麼。下一步怎麼做。（錯誤 N）
enum GpsShortcutMessage {
    static func placeMissing(_ name: String) -> String {
        "找不到地點「\(name)」，此地點已刪除。請在捷徑中重新選擇地點。（錯誤 20）"
    }

    /// The first point of a route／straight move or a wander was not accepted within 8 s
    /// (phone locked → code 11, or no LocalDevVPN link). The move is stopped, the location unchanged.
    static let firstStepFailed = "無法送出移動的第一個位置，未開始移動。請解鎖手機並確認 LocalDevVPN 已連線，再重新執行此捷徑。（錯誤 21）"
    static let noOrigin = "無法取得起點位置。請先以「直接前往」前往一個地點，或至「設定 › PinFly › 位置」開啟權限。（錯誤 22）"
    static let tooLong = "預計移動時間超過 12 小時。請改用較快的速度或「直接前往」。（錯誤 23）"
    static let busy = "PinFly 正在處理其他操作。請稍後再重新執行此捷徑。（錯誤 24）"
}

// MARK: - Intents

struct ConnectIntent: AppIntent {
    static var title: LocalizedStringResource = "建立連線"
    // Kept (an old Shortcut may still use it; Shortcuts finds actions by type name) but off App Shortcuts.
    static var description = IntentDescription("建立定位連線，最多等候 20 秒。適合放在「開啟飛航模式」與「關閉飛航模式」之間確認連線；「前往地點」會自動連線，一般捷徑不需要此動作。")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await GpsSimAutoReturn.shared.settle(timeout: 3)
        let ok = await GpsSimIntentRunner.waitForTunnel()
        let message = ok ? "已建立連線，可關閉飛航模式。" : GpsSimIntentRunner.tunnelFailureMessage()
        return .result(dialog: "\(message)")
    }
}

/// 前往地點 (spec 12.3.1). Type name and the `place` property never change (old Shortcuts keep
/// working); every new parameter has a default and the defaults reproduce the old behaviour
/// (直接前往, no time limit). New property names are prefixed on purpose so none of them can
/// shadow a method (a parameter named `start` once broke the CI build).
///
/// Everything runs in the background (openAppWhenRun false, no foreground continuation):
/// 路線／直線／原地漫步 rely on the background audio／location session the move starts
/// (LocationSimulationSession.start), and perform() returns as soon as the first point is accepted.
/// Budget ≤ 25 s: wait-idle 5 s + planning 8 s + first-point confirm 8 s (+ ≤ 4 s GPS for the origin).
struct SendToPlaceIntent: AppIntent {
    static var title: LocalizedStringResource = "前往地點"
    static var description = IntentDescription("將手機位置設為已儲存的地點，落點為該地點範圍內的隨機位置。可選擇直接前往、沿路線或直線移動，或前往後原地漫步。")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "地點", requestValueDialog: "要前往哪個地點？")
    var place: GpsPlaceEntity

    @Parameter(title: "方式",
               description: "直接前往：立即出現在地點範圍內。路線、直線：以設定的速度沿途移動。原地漫步：前往後在範圍內隨機走動。移動與漫步在背景進行，期間請勿從 App 切換器關閉 PinFly。",
               default: .direct)
    var moveMode: GpsMoveMethod

    @Parameter(title: "速度", description: "方式為「路線」或「直線」時使用。單車沿步行路線。", default: .walk)
    var speedPreset: GpsMoveSpeed

    @Parameter(title: "自訂速度（km/h）", description: "速度為「自訂」時使用，範圍 3.6～100 km/h，超出時以上下限計算。", default: 5)
    var customKmh: Double

    @Parameter(title: "抵達後", description: "方式為「路線」或「直線」時使用。原地漫步沿用 App 內上次選擇的範圍。", default: .stay)
    var afterArrival: GpsAfterArrival

    @Parameter(title: "漫步範圍", description: "方式為「原地漫步」時使用。", default: .app)
    var wanderRadius: GpsWanderRange

    @Parameter(title: "持續時間（分鐘）",
               description: "未填寫時持續模擬，直到執行「停止模擬」。填寫 1～720 分鐘後即回到真實位置：直接前往、原地漫步自執行時起算；路線、直線自抵達時起算。抵達後為「停止模擬」時不使用此設定。")
    var durationMinutes: Int?

    // Kept to the simplest form that is known to compile: top-level Switch, only key paths inside
    // each Summary's braces, no When nested anywhere. 自訂速度 therefore shows for every 路線／直線
    // (its description says it only applies when 速度＝自訂).
    static var parameterSummary: some ParameterSummary {
        Switch(\.$moveMode) {
            Case(.direct) {
                Summary("前往 \(\.$place)，方式 \(\.$moveMode)") {
                    \.$durationMinutes
                }
            }
            Case(.wander) {
                Summary("前往 \(\.$place)，方式 \(\.$moveMode)") {
                    \.$wanderRadius
                    \.$durationMinutes
                }
            }
            DefaultCase {
                Summary("前往 \(\.$place)，方式 \(\.$moveMode)，速度 \(\.$speedPreset)") {
                    \.$customKmh
                    \.$afterArrival
                    \.$durationMinutes
                }
            }
        }
    }

    // Failures stay a dialog (not a throw), as before; 結果＝失敗 lets a Shortcut branch on it.
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<GpsSimStatusEntity> & ProvidesDialog {
        // Counted inside the runner's 25 s budget (started before this call).
        let started = Date()
        await GpsSimAutoReturn.shared.settle(timeout: 3)
        let request = GpsMoveRequest.make(method: moveMode, speed: speedPreset, customKmh: customKmh,
                                          afterArrival: afterArrival, wanderRange: wanderRadius,
                                          appWanderSize: GpsMoveRequest.appWanderSize(),
                                          durationMinutes: durationMinutes)
        let outcome = await GpsSendToPlaceRunner.run(placeID: place.id, placeName: place.name, request: request,
                                                     started: started)
        let value = await GpsSimIntentStatus.make(outcome.ok ? .succeeded : .failed,
                                                  reason: outcome.ok ? "" : outcome.message)
        return .result(value: value, dialog: "\(outcome.message)")
    }
}

/// The work behind 前往地點, split by method. Returns the full dialog text (spec 12.3.1 tables).
@MainActor
private enum GpsSendToPlaceRunner {
    struct Outcome {
        let ok: Bool
        let message: String
    }

    static let budgetSeconds: TimeInterval = 25
    /// Kept back for building the returned status (GpsSimIntentStatus.make, no network).
    static let statusReserveSeconds: TimeInterval = 1
    static let confirmSeconds: TimeInterval = 8
    /// 原地漫步's initial 前往 retries for at most this long (wait-idle 5 + 8 + confirm ≤ 8 stays in budget).
    static let wanderLinkSeconds = 8
    static let originGPSSeconds: TimeInterval = 4
    /// Closer than this to the destination: no move needed (spec 12.3.1 「已位於」).
    static let alreadyThereMeters: Double = 5

    static func failure(_ message: String, log: String) -> Outcome {
        GpsSimIntentLog.error("前往地點 failed: \(log)")
        return Outcome(ok: false, message: message)
    }

    static func success(_ message: String, log: String) -> Outcome {
        GpsSimIntentLog.info("前往地點 ok: \(log)")
        return Outcome(ok: true, message: message)
    }

    /// Seconds left of the 25 s budget, minus the reserve for building the status (never negative).
    static func secondsLeft(_ started: Date) -> TimeInterval {
        max(0, budgetSeconds - statusReserveSeconds - Date().timeIntervalSince(started))
    }

    /// `started` = when perform() began, so the auto-return settle counts against the budget too.
    static func run(placeID: String, placeName: String, request: GpsMoveRequest, started: Date) async -> Outcome {
        let speedText = request.kmh.map { String(Int($0.rounded())) } ?? "-"
        let durationText = request.durationMinutes.map { String($0) } ?? "-"
        GpsSimIntentLog.info("前往地點 start: kind=\(request.kind) kmh=\(speedText) arrival=\(request.arrival) minutes=\(durationText)")
        let store = GpsPlaceStore.shared
        store.reload()
        guard let saved = store.places.first(where: { $0.id == placeID }) else {
            return failure(GpsShortcutMessage.placeMissing(placeName), log: "place missing (20)")
        }
        await GpsSimIntentRunner.waitUntilIdle()
        if GpsSimEngine.shared.isBusy || GpsSimRouteMover.shared.isPlanning {
            return failure(GpsShortcutMessage.busy, log: "busy (24)")
        }
        switch request.kind {
        case .direct:
            return await self.direct(saved, all: store.places, request: request, started: started)
        case .wander:
            return await self.wander(saved, all: store.places, request: request, started: started)
        case .route, .straight:
            return await self.move(saved, all: store.places, request: request, started: started)
        }
    }

    // MARK: 直接前往

    static func direct(_ saved: GpsPlace, all: [GpsPlace], request: GpsMoveRequest, started: Date) async -> Outcome {
        let engine = GpsSimEngine.shared
        let landing = GpsGeo.sampleLanding(saved, among: all)
        let linkSeconds = min(12, Int(self.secondsLeft(started)))
        let code = await GpsSimIntentRunner.retryingLink(seconds: linkSeconds) { done in
            engine.send(to: landing, name: saved.name, center: saved.coordinate, placeID: saved.id, completion: done)
        }
        guard code == 0 else {
            return failure(GpsSimIntentRunner.shortcutFailure(code), log: "direct code \(code)")
        }
        let meters = Int(GpsGeo.meters(saved.coordinate, landing).rounded())
        var text = "已前往 \(saved.name)（距中心 \(meters) 公尺）"
        if let seconds = request.durationSeconds {
            // engine.send cleared any earlier deadline; this one counts from now.
            let end = Date().addingTimeInterval(seconds)
            GpsSimAutoReturn.shared.arm(at: end)
            text += "，將於 \(GpsMoveEstimate.clockText(end)) 回到真實位置"
        }
        return success(text + "。", log: "direct")
    }

    // MARK: 原地漫步

    static func wander(_ saved: GpsPlace, all: [GpsPlace], request: GpsMoveRequest, started: Date) async -> Outcome {
        let engine = GpsSimEngine.shared
        let mover = GpsSimRouteMover.shared
        let size = request.wanderSize ?? .medium
        let radius = GpsSimWanderPlanner.radius(size: size, placeRadius: GpsGeo.radius(of: saved))
        // Same order as the app's wander switch: be at the place first, then start wandering.
        let atPlace = engine.activeName != nil && engine.activePlaceID == saved.id && !engine.isMoving
        if !atPlace {
            let landing = GpsGeo.sampleLanding(saved, among: all)
            let linkSeconds = min(wanderLinkSeconds, Int(self.secondsLeft(started)))
            let code = await GpsSimIntentRunner.retryingLink(seconds: linkSeconds) { done in
                engine.send(to: landing, name: saved.name, center: saved.coordinate, placeID: saved.id, completion: done)
            }
            guard code == 0 else {
                return failure(GpsSimIntentRunner.shortcutFailure(code), log: "wander send code \(code)")
            }
        }
        mover.startWander(center: saved.coordinate, radius: radius, name: saved.name, placeID: saved.id,
                          from: engine.current)
        let serial = mover.runSerial
        guard await self.confirmFirstStep(serial: serial, seconds: min(confirmSeconds, self.secondsLeft(started))) else {
            if mover.runSerial == serial { mover.stopMoving() }
            return failure(GpsShortcutMessage.firstStepFailed, log: "wander first step (21) code \(self.codeText(mover.lastStepCode))")
        }
        var text = "已前往 \(saved.name)，開始原地漫步（範圍：\(self.sizeLabel(size))）。"
        if let seconds = request.durationSeconds {
            let end = Date().addingTimeInterval(seconds)
            GpsSimAutoReturn.shared.arm(at: end)
            text += "將於 \(GpsMoveEstimate.clockText(end)) 回到真實位置。"
        }
        text += "漫步期間請勿從 App 切換器關閉 PinFly。"
        return success(text, log: "wander \(size.rawValue)")
    }

    // MARK: 路線／直線

    static func move(_ saved: GpsPlace, all: [GpsPlace], request: GpsMoveRequest, started: Date) async -> Outcome {
        let engine = GpsSimEngine.shared
        let mover = GpsSimRouteMover.shared
        guard let preset = request.speedPreset, let kmh = request.kmh else {
            return failure(GpsShortcutMessage.busy, log: "invalid request")
        }
        guard GpsSimEngine.pairingExists else {
            return failure(GpsSimIntentRunner.shortcutFailure(2), log: "no pairing file")
        }
        // Origin: the simulated point if simulating (also one left by an earlier launch), else real GPS.
        let origin: CLLocationCoordinate2D
        if engine.activeName != nil, let here = engine.current ?? engine.landing {
            origin = here
        } else if let stale = engine.staleTarget {
            origin = stale.coordinate
        } else if let fix = await GpsRealFix.read(timeout: originGPSSeconds) {
            origin = fix.coordinate
        } else {
            return failure(GpsShortcutMessage.noOrigin, log: "no origin (22)")
        }
        let destination = GpsGeo.sampleLanding(saved, among: all)
        let arrival: MoveArrivalAction
        switch request.arrival {
        case .stay:
            arrival = .stay
        case .wander:
            let size = request.wanderSize ?? .medium
            arrival = .wander(radius: GpsSimWanderPlanner.radius(size: size, placeRadius: GpsGeo.radius(of: saved)))
        case .stopSimulation:
            arrival = .stopSimulation
        }

        let straightMeters = GpsGeo.meters(origin, destination)
        if straightMeters <= alreadyThereMeters {
            return await self.alreadyThere(saved, destination: destination, arrival: arrival, request: request,
                                           started: started)
        }
        if GpsMoveEstimate.isTooLong(meters: straightMeters, kmh: kmh) {
            return failure(GpsShortcutMessage.tooLong, log: "too long (23) straight")
        }
        let planMode: MoveMode = request.kind == .route ? .route : .straight
        let plan = await GpsSimRoutePlanner.plan(from: origin, to: destination, mode: planMode, speed: preset)
        guard plan.start != nil else {
            return failure(GpsShortcutMessage.firstStepFailed, log: "empty plan")
        }
        if GpsMoveEstimate.isTooLong(meters: plan.totalMeters, kmh: kmh) {
            return failure(GpsShortcutMessage.tooLong, log: "too long (23) route")
        }
        if GpsSimEngine.shared.isBusy {
            return failure(GpsShortcutMessage.busy, log: "busy after planning (24)")
        }
        mover.start(plan: plan, name: saved.name, placeID: saved.id, center: saved.coordinate, kmh: kmh,
                    afterArrival: arrival, autoReturnAfter: request.durationSeconds)
        let serial = mover.runSerial
        // Budget nearly used up → 0 s: only checks whether a point was already accepted, no waiting.
        guard await self.confirmFirstStep(serial: serial, seconds: min(confirmSeconds, self.secondsLeft(started))) else {
            // Nothing (or nothing new) reached the phone: stopping hands the phone back where it was.
            if mover.runSerial == serial { mover.stopMoving() }
            return failure(GpsShortcutMessage.firstStepFailed, log: "move first step (21) code \(self.codeText(mover.lastStepCode))")
        }

        let modeText = plan.mode == .route ? "路線" : "直線"
        let eta = Date().addingTimeInterval(plan.estimatedSeconds(kmh: kmh))
        var text = "已開始移動至 \(saved.name)：\(request.speedLabel)，\(modeText) \(GpsMoveEstimate.distanceText(plan.totalMeters))，預計 \(GpsMoveEstimate.clockText(eta)) 抵達。"
        if plan.fellBackToStraight { text += "已改為直線。" }
        switch request.arrival {
        case .stay:
            break
        case .wander:
            text += "抵達後將原地漫步。"
        case .stopSimulation:
            text += "抵達後將回到真實位置。"
        }
        if let minutes = request.durationMinutes {
            text += "抵達 \(minutes) 分鐘後將回到真實位置。"
        }
        text += "移動期間請勿從 App 切換器關閉 PinFly。"
        return success(text, log: "\(modeText) \(Int(plan.totalMeters)) m")
    }

    /// Already within 5 m of the destination: no move; the 抵達後 setting still applies.
    static func alreadyThere(_ saved: GpsPlace, destination: CLLocationCoordinate2D,
                             arrival: MoveArrivalAction, request: GpsMoveRequest, started: Date) async -> Outcome {
        let engine = GpsSimEngine.shared
        let linkSeconds = min(12, Int(self.secondsLeft(started)))
        if arrival == .stopSimulation {
            let code = await GpsSimIntentRunner.retryingLink(seconds: linkSeconds) { done in engine.stop(completion: done) }
            guard code == 0 else {
                return failure(GpsSimIntentRunner.shortcutFailure(code), log: "already there, stop code \(code)")
            }
            return success("已位於 \(saved.name)，不需要移動。已回到真實位置。", log: "already there + stop")
        }
        let code = await GpsSimIntentRunner.retryingLink(seconds: linkSeconds) { done in
            engine.send(to: destination, name: saved.name, center: saved.coordinate, placeID: saved.id, completion: done)
        }
        guard code == 0 else {
            return failure(GpsSimIntentRunner.shortcutFailure(code), log: "already there, send code \(code)")
        }
        GpsSimRouteMover.shared.runArrivalAction(arrival, autoReturnAfter: request.durationSeconds,
                                                  at: destination, name: saved.name,
                                                  placeID: saved.id, center: saved.coordinate)
        return success("已位於 \(saved.name)，不需要移動。", log: "already there")
    }

    /// Waits until the run `serial` has had one point accepted by the phone. False when it was
    /// taken over, paused by 3 failed sends (code 11 locked / connection lost) or the time ran out.
    static func confirmFirstStep(serial: Int, seconds: TimeInterval) async -> Bool {
        let mover = GpsSimRouteMover.shared
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            guard mover.runSerial == serial else { return false }
            if mover.deliveredSteps > 0 { return true }
            switch mover.state {
            case .idle:
                return false
            case .paused(let reason) where reason != .user:
                return false
            default:
                break
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return mover.runSerial == serial && mover.deliveredSteps > 0
    }

    static func codeText(_ code: Int32?) -> String {
        guard let code else { return "-" }
        return String(code)
    }

    static func sizeLabel(_ size: WanderSize) -> String {
        switch size {
        case .small: return "小"
        case .medium: return "中"
        case .large: return "大"
        }
    }
}

/// Shown by Shortcuts when 停止模擬 could not clear the phone.
enum GpsSimStopError: Error, CustomLocalizedStringResourceConvertible {
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .failed(let reason): return "停止失敗：\(reason)"
        }
    }
}

/// Renamed 停止定位 -> 停止模擬 (same name as the home-screen button). Only the title, phrases and
/// shortTitle changed: Shortcuts stores an action by its type name, so `StopSimulationIntent` must
/// never be renamed or the owner's 「出門改定位」 step would turn into "unknown action".
struct StopSimulationIntent: AppIntent {
    static var title: LocalizedStringResource = "停止模擬"
    static var description = IntentDescription("清除手機上的模擬位置，回到真實位置。地圖約 10 秒內更新。")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<GpsSimStatusEntity> & ProvidesDialog {
        // engine.stop also cancels a move or wander (takeOverFromMove) and, on success, the 持續時間.
        // 停止模擬也停止行程（含上次中斷、存著的執行狀態），否則行程會再送點或下次開啟提示「接續行程」。
        GpsItineraryRunner.shared.stopForStopSimulationIntent()
        let code = await GpsSimIntentRunner.retryingLink { done in GpsSimEngine.shared.stop(completion: done) }
        guard code == 0 else {
            let reason = GpsSimIntentRunner.shortcutFailure(code)
            GpsSimIntentLog.error("停止模擬 failed: code \(code)")
            // Throw (not just a dialog) so Shortcuts marks the step failed instead of looking fine.
            throw GpsSimStopError.failed(reason)
        }
        GpsSimIntentLog.info("停止模擬 ok")
        let value = await GpsSimIntentStatus.make(.succeeded)
        return .result(value: value, dialog: "已回到真實位置，地圖約 10 秒內更新。")
    }
}

/// 看真實位置: stop → read one real GPS fix → put the fake location back where it was.
/// While simulating, iOS hands every app (Shortcuts included) the fake point, so the only way
/// to see the real one is a short stop. Returns the real place so a Shortcut can show or share it.
struct PeekRealLocationIntent: AppIntent {
    static var title: LocalizedStringResource = "查看真實位置"
    static var description = IntentDescription("暫停模擬數秒以取得真實位置，完成後自動回到原本的地點。")
    static var openAppWhenRun: Bool = false

    // Kept short on purpose: stop + GPS + resume must finish before Shortcuts gives up on the
    // intent (~30 s), or the phone would be left on the real location (review 2026-10-15).
    @Parameter(title: "GPS 等候上限（秒）", default: 8, inclusiveRange: (3, 10))
    var seconds: Int

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<CLPlacemark?> & ProvidesDialog {
        let engine = GpsSimEngine.shared
        let deadline = Date().addingTimeInterval(24)
        // A 持續時間 already due ends first (awaited, ≤ 3 s of the 24 s): otherwise the point put back
        // below would undo that return to the real location.
        await GpsSimAutoReturn.shared.settle(timeout: 3)
        // Putting the point back is a send, which cancels a 持續時間: remember it and re-arm after.
        let autoReturnAt = GpsSimAutoReturn.shared.deadline
        let wasActive = engine.activeName
        // A point sent in an earlier launch may still be on the phone (staleTarget): stop it too,
        // or every fix would be the fake one and the message would wrongly blame GPS.
        let stale = wasActive == nil ? engine.staleTarget : nil
        if wasActive != nil || stale != nil {
            let code = await GpsSimIntentRunner.retryingLink(seconds: 5) { done in engine.stop(full: false, completion: done) }
            guard code == 0 else {
                let reason = GpsSimIntentRunner.shortcutFailure(code)
                return .result(value: nil, dialog: "無法暫停模擬：\(reason)")
            }
        }
        // Leave at least 8 s of the budget for putting the fake location back.
        let gpsWait = min(TimeInterval(seconds), max(deadline.timeIntervalSinceNow - 8, 2))
        let fix = await GpsRealFix.read(timeout: gpsWait)
        var resumed = true
        if wasActive != nil {
            // stop() saved the stopped target as `previous`; undo re-sends that exact point.
            // (Side effect: afterwards 回上一個 leads to the real location, not the place before.)
            let code = await GpsSimIntentRunner.retryingLink(seconds: 5) { done in
                engine.undoLastSend(completion: done)
            }
            resumed = code == 0
        } else if let stale {
            let code = await GpsSimIntentRunner.retryingLink(seconds: 5) { done in
                engine.send(to: stale.coordinate, name: stale.name, placeID: stale.placeID, completion: done)
            }
            resumed = code == 0
        }
        if resumed, let autoReturnAt, GpsSimAutoReturn.shared.deadline == nil {
            GpsSimAutoReturn.shared.arm(at: autoReturnAt)
        }
        let back = (wasActive ?? stale?.name).map { resumed ? "，已回到「\($0)」" : "，但無法回到「\($0)」，請重新前往" } ?? ""
        guard let fix else {
            let why = GpsRealFix.authorized ? "\(Int(gpsWait.rounded())) 秒內未取得 GPS 位置（室內需要較長時間）" : "PinFly 沒有位置權限。請至「設定 › PinFly › 位置」開啟。"
            return .result(value: nil, dialog: "\(why)\(back)")
        }
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(fix).first
        let text = placemark.flatMap { [$0.locality, $0.subLocality, $0.thoroughfare, $0.subThoroughfare].compactMap { $0 }.joined() }
        let where_ = (text?.isEmpty == false ? text! : String(format: "%.5f, %.5f", fix.coordinate.latitude, fix.coordinate.longitude))
        let value = placemark ?? CLPlacemark(location: fix, name: "真實位置", postalAddress: nil)
        return .result(value: value, dialog: "真實位置：\(where_)（誤差約 \(Int(fix.horizontalAccuracy)) 公尺）\(back)")
    }
}

/// One real GPS fix, skipping points still flagged as simulated right after the stop
/// (pymobiledevice3 #572: the first fixes after a clear can be stale or coarse).
@MainActor
final class GpsRealFix: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var best: CLLocation?
    private var finish: ((CLLocation?) -> Void)?
    /// Fixes older than the read are CoreLocation's cache (e.g. home hours ago), not where he is now.
    private let started = Date()

    static var authorized: Bool {
        let s = CLLocationManager().authorizationStatus
        return s == .authorizedAlways || s == .authorizedWhenInUse
    }

    static func read(timeout: TimeInterval) async -> CLLocation? {
        guard authorized else { return nil }
        let reader = GpsRealFix()
        return await withCheckedContinuation { continuation in
            reader.finish = { continuation.resume(returning: $0) }
            reader.manager.delegate = reader
            reader.manager.desiredAccuracy = kCLLocationAccuracyBest
            // The intent runs in the background (openAppWhenRun = false); UIBackgroundModes has location.
            reader.manager.allowsBackgroundLocationUpdates = true
            reader.manager.startUpdatingLocation()
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { reader.done(reader.best) }
        }
    }

    private func done(_ location: CLLocation?) {
        guard let finish else { return }
        self.finish = nil
        manager.stopUpdatingLocation()
        finish(location)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            for l in locations where l.horizontalAccuracy >= 0 && l.timestamp >= started
                && l.sourceInformation?.isSimulatedBySoftware != true {
                if best == nil || l.horizontalAccuracy < best!.horizontalAccuracy { best = l }
            }
            if let best, best.horizontalAccuracy <= 50 { done(best) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
