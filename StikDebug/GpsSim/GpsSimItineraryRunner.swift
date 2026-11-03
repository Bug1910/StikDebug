//
//  GpsSimItineraryRunner.swift
//  PinFly
//
//  【這個檔案的角色】「預排行程」的值班司機（規格 10.2.2～10.4、10.7）。
//  開始行程後每秒（1 Hz）看一次時鐘，用 ItinSchedule.resolve 算出「現在該在第幾項」，
//  換項時把工作分派給既有的移動器（移動／原地漫步）或引擎（停留／停止模擬）。
//
//  【為什麼這樣設計】
//  - 開始時不規劃路線（沒有 planning 狀態）：只用儲存時的 cachedPath，沒有或過期就改直線，
//    所以捷徑在背景也能開始（規格 10.4.1）。
//  - 位置永遠由「現在時間」查表算出：斷線、鎖定、App 被凍結期間時間軸照走，
//    恢復後落後超過 30 秒就用 startAtMeters 直接接到應在的位置（規格 10.2.3）。
//  - 每個項目各有一個順延秒數（shifts）：暫停 P 秒＝目前項目與其後「接續上一項」的項目 +P，
//    遇到下一個「在 HH:mm」項目就停（規格 10.2.4）；移動實際抵達比預估早或晚，
//    下一個「接續上一項」起算點改成實際抵達時間，也是同一套順延（規格 10.2.2）。
//  - 手動接手判斷：引擎 controlSerial、移動器 runSerial 與「上次記下的值」不同＝別人操作過。
//    Runner 自己每次分派完（send／stop／start／startWander 都會讓序號加 1）立刻重記，
//    才不會把自己的動作誤判成手動接手（工程規劃步驟 3）。
//  - 待命時沒有送點，背景音訊不會自己啟動 → 進入待命時 requestStart、離開時 requestStop，
//    讓 1 Hz 計時器在背景繼續跑（規格 10.4.3）。
//  - 執行狀態存 UserDefaults（itinerary.runState），App 被關閉後重開可「接續行程」。
//  - 手機時鐘檢查用 CLOCK_MONOTONIC（含裝置睡眠時間）：systemUptime 在睡眠時不走，
//    鎖屏一段時間回來會被誤判成「時間被改過」。
//  - 不用 start／stop／pause 當參數或區域變數名（GpsSimRouteMover 註解提過的編譯坑）。
//  - 紀錄一律經 GpsSimIntentLog，前綴 [Itinerary]，只寫項目編號、類型與錯誤代碼，不寫座標。
//

import Foundation
import CoreLocation
import UIKit
import UserNotifications

/// 行程執行狀態。
enum ItinRunState: Equatable {
    case idle
    /// 已開始、第一項還沒到時間（待命）。
    case armed
    /// 正在執行第 index 項（0 起算）。
    case running(index: Int)
    /// 暫停：使用者暫停、連線中斷、手機鎖定（後兩者時間軸照走，只是送不出位置）。
    case paused(MovePauseReason)
    case finished
    case cancelled(ItinCancelReason)
}

/// 行程為什麼結束（未跑完）。
enum ItinCancelReason: Equatable {
    /// 使用者按「停止行程」或捷徑「停止行程」。
    case user
    /// 使用者手動前往／移動／停止模擬（控制序號改變）。
    case manualTakeover
    /// 第一個位置送不出（錯誤 21 行程版）。
    case firstSendFailed
    /// 執行中的行程被刪除。
    case itineraryDeleted
}

/// start(itineraryID:startShift:) 丟出的錯誤；代碼對應捷徑錯誤（規格 12.3.2），
/// App 內「已有行程進行中」改顯示錯誤 38。
enum ItinRunError: Error, Equatable {
    /// 26：找不到行程。
    case notFound
    /// 27（捷徑）／38（App 內）：已有行程進行中或待命。
    case alreadyActive(name: String)
    /// 28：所有項目都已結束。
    case allFinished
    /// 21（行程版）：第一個位置無法送出，行程未開始。
    case firstSendFailed
    /// 30～36（無法儲存的錯誤）：行程內容不合法（例：匯入的舊檔），不開始。
    case invalid(ItinIssue)
}

/// 存在 UserDefaults 的執行狀態（App 被關閉後「接續行程」用）。
struct ItinRunRecord: Codable, Equatable {
    var itineraryID: String
    var itineraryName: String
    /// 開始行程的時間（today 模式「當天」的基準）。
    var anchor: Date
    /// 開始平移量（捷徑「立即／延後」、App「從第 1 項立即開始」）。
    var startShift: TimeInterval
    /// 每個項目的順延秒數（暫停、實際抵達）；長度與項目數相同。
    var shifts: [TimeInterval]
    /// 目前項目（0 起算）；nil＝待命。只供顯示與紀錄，接續時依現在時間重新查表。
    var currentIndex: Int?
    /// 使用者暫停中：暫停開始時間與暫停的項目；接續時還原成暫停狀態（舊紀錄沒有＝未暫停）。
    var pausedAt: Date? = nil
    var pausedIndex: Int? = nil
}

@MainActor
final class GpsItineraryRunner: ObservableObject {
    static let shared = GpsItineraryRunner()

    // MARK: UserDefaults 鍵（規格 10.4.2、工程規劃步驟 3）
    static let runStateKey = "itinerary.runState"
    static let notifyLeadMinutesKey = "itinerary.notifyLeadMinutes"
    static let skipStartNoticeKey = "itinerary.skipStartNotice"
    static let defaultNotifyLeadMinutes = 5
    static let notifyLeadMinuteRange: ClosedRange<Int> = 1...30

    // MARK: 畫面文字（docs/ui-terminology.md）
    static let startNoticeText = "行程進行期間請保持 PinFly 開啟、螢幕亮著、接上電源。手機鎖定後無法送出模擬位置。只模擬位置軌跡，計步器與動作感測不會變化。"
    static let sensorDisclaimer = "只模擬位置軌跡，計步器與動作感測不會變化。"
    static let keepOpenHint = "保持 PinFly 開啟、螢幕亮著"
    static let takeoverNotice = "已改為手動操作，行程已停止。"
    static let stoppedNotice = "行程已停止，停留在目前位置。"
    static let finishedNotice = "行程已結束。"
    static let clockChangedNotice = "手機時間已變更，行程已依目前時間重新定位。"
    /// 錯誤 21 行程版（App 內）；捷徑版文字在 GpsSimItineraryIntents.swift。
    static let firstSendFailedText = "無法送出行程的第一個位置，未開始行程。請解鎖手機並確認 LocalDevVPN 已連線，再點選「開始行程」。（錯誤 21）"

    // MARK: 常數
    static let tickInterval: TimeInterval = 1
    /// 第一個位置最多等幾秒（規格 12.3.2）。
    static let firstSendTimeout: TimeInterval = 8
    /// 落後超過幾秒才用 startAtMeters 補位（規格 10.2.3）。
    static let catchUpSeconds: TimeInterval = 30
    /// 停留、停止模擬送失敗後幾秒重試。
    static let retryEvery: TimeInterval = 4
    /// 已在停留點幾公尺內就不重送（落點本來就在 4 公尺內微飄）。
    static let sameSpotMeters: Double = 10
    /// 移動比預估晚抵達時，下一個「接續上一項」最多等多久（至少 2 分鐘或移動時間的 25%）。
    static let arrivalHoldMin: TimeInterval = 120
    static let arrivalHoldFraction = 0.25
    static let clockJumpSeconds: TimeInterval = 300
    private static let notificationPrefix = "itinerary."

    // MARK: 對外狀態
    @Published private(set) var state: ItinRunState = .idle
    /// 執行中（含待命、暫停）的行程 id。
    @Published private(set) var activeItineraryID: String?
    @Published private(set) var activeItineraryName: String?
    /// 本次執行的時間表（已含 startShift 與順延）。
    @Published private(set) var slots: [ItinSlot] = []
    /// 本次執行的項目（開始時從 store 讀出的副本；執行中編輯頁唯讀）。
    @Published private(set) var events: [ItinEvent] = []
    /// 沒有有效路線快取、本次改直線的移動項目（0 起算）。
    @Published private(set) var straightFallbackIndices: [Int] = []
    /// 目前項目的順延秒數（暫停、實際抵達；規格 10.2.4）。
    @Published private(set) var timelineShift: TimeInterval = 0
    /// 目前項目（0 起算）；nil＝待命或未進行。
    @Published private(set) var currentIndex: Int?
    /// 暫停中已到開始時間的「在 HH:mm」項目（0 起算）；畫面顯示「第 3 項的開始時間 15:00 已到。…」。
    @Published private(set) var overdueFixedIndex: Int?
    /// 最近一次執行的行程名稱與時區（結束後執行畫面仍顯示「行程已結束。」用）。
    @Published private(set) var lastRunName: String?
    @Published private(set) var lastRunTimeZone: TimeZone = .current
    /// 給畫面顯示一次的提示（例：「已改為手動操作，行程已停止。」）；畫面顯示後清掉。
    @Published var notice: String?

    /// 待命、執行中、暫停都算「進行中」。
    var isActive: Bool {
        switch state {
        case .armed, .running, .paused: return true
        case .idle, .finished, .cancelled: return false
        }
    }

    /// 使用者按了「暫停」（連線中斷、鎖定不算）。
    var isUserPaused: Bool { userPaused }

    // MARK: 內部
    private var run: ItinRunRecord?
    private var timeZone: TimeZone = .current
    private var plans: [MovePlan?] = []
    /// 只含 startShift 的時間表；加上 run.shifts 才是 slots。
    private var baseSlots: [ItinSlot] = []
    private var timer: Timer?
    private var recordedControlSerial = 0
    private var recordedRunSerial = 0
    /// 目前項目交給移動器（移動、漫步）。
    private var moverOwned = false
    private var dispatchedIndex: Int?
    /// 停留、停止模擬已送達（或不需要送）。
    private var dispatchDone = false
    private var dispatchInFlight = false
    private var dispatchToken = 0
    private var lastDispatchCode: Int32?
    private var lastFailCode: Int32?
    private var nextRetryAt: Date?
    private var linkLostDuringItem = false
    private var arrivalHandledIndex: Int?
    private var userPaused = false
    private var pausedAt: Date?
    private var pausedIndex: Int?
    private var overdueNotifiedIndex: Int?
    private var holdingAudio = false
    /// 中途「停止模擬」送達後模擬工作階段會釋放背景音訊；行程自己持有，下一項分派時才放。
    private var holdingStopAudio = false
    /// 暫停中偵測到時鐘跳動：等使用者點選「繼續」時再依新時間重新定位。
    private var pendingRelocate = false
    private var holdingIdleTimer = false
    private var clockRef: (wall: Date, mono: TimeInterval)?
    private var backgroundNoticeSent = false
    private var lockNoticeSent = false
    private var scheduledNotificationIDs: [String] = []
    private var observers: [NSObjectProtocol] = []

    private var engine: GpsSimEngine { GpsSimEngine.shared }
    private var mover: GpsSimRouteMover { GpsSimRouteMover.shared }

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.appDidEnterBackground() }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleForeground() }
        })
    }

    // MARK: - 對外動作

    /// 開始行程。startShift＝所有項目平移秒數（捷徑「立即／延後」；依行程設定＝0）。
    /// 第一項在未來 → 待命，立即回傳；現在就該執行 → 送出第一個位置並等手機接受（最多 8 秒），
    /// 送不出 → 行程不開始、丟 firstSendFailed（錯誤 21 行程版）。
    func start(itineraryID: String, startShift: TimeInterval) async throws {
        guard let itinerary = GpsItineraryStore.shared.itinerary(id: itineraryID) else {
            throw ItinRunError.notFound
        }
        if isActive {
            throw ItinRunError.alreadyActive(name: activeItineraryName ?? "")
        }
        guard !itinerary.events.isEmpty else { throw ItinRunError.allFinished }
        // 防呆：無法儲存的行程（例：第一項是移動＝起點未知）不開始，否則第一點會瞬移。
        if let blocking = ItinSchedule.validate(itinerary, anchor: Date())
            .first(where: { $0.severity == .blocking }) {
            throw ItinRunError.invalid(blocking)
        }
        // 捷徑設定的「持續時間」到期會呼叫 engine.stop，會被誤判成手動接手：行程開始就取消。
        GpsSimAutoReturn.shared.clear(reason: "itinerary")
        let now = Date()
        let record = ItinRunRecord(itineraryID: itinerary.id, itineraryName: itinerary.name,
                                   anchor: now, startShift: startShift.isFinite ? startShift : 0,
                                   shifts: Array(repeating: 0, count: itinerary.events.count),
                                   currentIndex: nil)
        load(itinerary, record: record)
        let resolution = ItinSchedule.resolve(slots: slots, now: now)
        if resolution == .finished {
            clearLoaded()
            throw ItinRunError.allFinished
        }
        activate()
        log("start \(itinerary.events.count) items, shift \(Int(record.startShift)) s, straight \(straightFallbackIndices.count)")

        guard case .current(let cursor) = resolution else {
            // 第一項在未來：待命（不送點）。
            enterArmed()
            persist()
            rescheduleNotifications()
            updateIdleTimer()
            return
        }
        state = .running(index: cursor.index)
        dispatch(index: cursor.index, offset: cursor.offset)
        let delivered = await waitForFirstDelivery(index: cursor.index)
        guard run != nil else {
            // 等候期間被停止或手動接手：視為沒開始成功。
            throw ItinRunError.firstSendFailed
        }
        guard delivered else {
            abortFirstSend()
            throw ItinRunError.firstSendFailed
        }
        rescheduleNotifications()
        updateState()
    }

    /// 停止行程：停在目前位置，不回到真實位置（規格 10.3 第 3 點）。
    /// 沒有進行中的行程時也會清掉「上次中斷」的紀錄（接續提示的「停止行程」）。
    func stopItinerary() {
        guard isActive else {
            discardSavedRun()
            return
        }
        log("stop by user")
        cancelRun(.user, notice: Self.stoppedNotice)
    }

    /// 執行畫面的「停止模擬」：結束行程並回到真實位置。
    func stopItineraryAndSimulation(completion: ((Int32) -> Void)? = nil) {
        if isActive {
            log("stop with simulation")
            cancelRun(.user, notice: nil)
        }
        engine.stop(completion: completion)
    }

    /// 捷徑「停止模擬」也一併停止行程（規格 10.3、12.4）：先停行程再送清除，避免重試清除時行程又送點。
    /// 沒有進行中的行程（例：App 被凍結後捷徑在背景喚醒）也清掉存著的執行狀態，下次開啟才不會誤提示「接續行程」。
    func stopForStopSimulationIntent() {
        if isActive {
            log("stop by 停止模擬 shortcut")
            cancelRun(.user, notice: nil)
        } else {
            discardSavedRun()
        }
    }

    /// App 內「暫停」：停止送新位置、保持最後一點（微飄繼續）。
    func pauseItinerary() {
        guard run != nil, !userPaused, let index = dispatchedIndex else { return }
        beginPause(at: index)
        if moverOwned, mover.isActive, mover.runSerial == recordedRunSerial {
            mover.pause()
        }
        log("pause at item \(index + 1)")
        persist()
        updateState()
        rescheduleNotifications()
    }

    /// App 內「繼續」：目前項目從暫停處接續；之後「接續上一項」的項目順延暫停時長，
    /// 遇到「在 HH:mm」項目歸零；暫停中已到時間的固定項目 → 依現在時間跳位（規格 10.2.4）。
    func resumeItinerary() {
        guard run != nil, userPaused else { return }
        let index = pausedIndex ?? dispatchedIndex ?? 0
        let paused = max(0, Date().timeIntervalSince(pausedAt ?? Date()))
        userPaused = false
        pausedAt = nil
        pausedIndex = nil
        overdueFixedIndex = nil
        overdueNotifiedIndex = nil
        applyDelay(from: index, delta: paused)
        if moverOwned, case .paused(.user) = mover.state, mover.runSerial == recordedRunSerial {
            mover.resume()
        }
        log("resume after \(Int(paused)) s")
        persist()
        rescheduleNotifications()
        tick()
    }

    /// 待命時「立即開始」：全部項目依序提前，第一項從現在開始。
    func startNowFromArmed() {
        guard var record = run, state == .armed, dispatchedIndex == nil,
              let first = slots.first else { return }
        let delta = Date().timeIntervalSince(first.start)
        record.startShift += delta
        run = record
        rebuildBaseSlots()
        log("start now from armed (\(Int(delta)) s)")
        persist()
        rescheduleNotifications()
        tick()
    }

    /// App 重開時有未完成的行程（UserDefaults runState）→ 畫面提供「接續行程」。
    var hasResumableRun: Bool {
        UserDefaults.standard.data(forKey: Self.runStateKey) != nil
    }

    /// 上次中斷的行程名稱（「行程「下午散步」在 PinFly 關閉時中斷。」）。
    var savedRunName: String? {
        guard !isActive else { return nil }
        return Self.loadRecord()?.itineraryName
    }

    /// 放棄上次中斷的行程（不動目前的模擬位置）。
    func discardSavedRun() {
        UserDefaults.standard.removeObject(forKey: Self.runStateKey)
        objectWillChange.send()
    }

    /// 接續上次未完成的行程：依目前時間查表，必要時補位（規格 10.4.3）。
    func resumeSavedRun() throws {
        if isActive { throw ItinRunError.alreadyActive(name: activeItineraryName ?? "") }
        guard var record = Self.loadRecord() else {
            discardSavedRun()
            throw ItinRunError.notFound
        }
        guard let itinerary = GpsItineraryStore.shared.itinerary(id: record.itineraryID),
              !itinerary.events.isEmpty else {
            discardSavedRun()
            throw ItinRunError.notFound
        }
        GpsSimAutoReturn.shared.clear(reason: "itinerary")
        if record.shifts.count != itinerary.events.count {
            record.shifts = Array(repeating: 0, count: itinerary.events.count)
            record.pausedAt = nil
            record.pausedIndex = nil
        }
        if let index = record.pausedIndex, !itinerary.events.indices.contains(index) {
            record.pausedAt = nil
            record.pausedIndex = nil
        }
        record.itineraryName = itinerary.name
        load(itinerary, record: record)
        if record.pausedAt == nil, ItinSchedule.resolve(slots: slots, now: Date()) == .finished {
            clearLoaded()
            discardSavedRun()
            throw ItinRunError.allFinished
        }
        activate(restoring: record)
        log("resume saved run")
        persist()
        rescheduleNotifications()
        tick()
    }

    /// 回到前景時立即檢查一次（不等計時器）。
    func handleForeground() {
        updateIdleTimer()
        guard run != nil else { return }
        tick()
    }

    // MARK: - 預覽（開始前確認視窗用）

    /// 以 anchor 為「當天」、平移 startShift 後的時間表（與 Runner 執行時算法相同）。
    static func plannedSlots(for itinerary: Itinerary, anchor: Date = Date(),
                             startShift: TimeInterval = 0) -> [ItinSlot] {
        ItinSchedule.compute(events: itinerary.events, anchor: anchor,
                             durations: ItinSchedule.moveDurations(events: itinerary.events),
                             dateMode: itinerary.dateMode, timeZone: itinerary.timeZone, shift: startShift)
    }

    /// 「從第 1 項立即開始」需要的平移秒數（全部項目依序平移，維持間隔）。
    static func shiftToStartNow(_ itinerary: Itinerary, now: Date = Date()) -> TimeInterval {
        guard let first = plannedSlots(for: itinerary, anchor: now).first else { return 0 }
        return now.timeIntervalSince(first.start)
    }

    // MARK: - 通知權限（儲存行程時在前景要求，規格 10.4.2）

    /// 尚未決定就跳系統視窗；回傳是否允許。
    nonisolated static func requestNotificationPermissionIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            return false
        default:
            return true
        }
    }

    /// 使用者已拒絕通知（編輯頁底部顯示提示）。
    nonisolated static func notificationsDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    static var notifyLeadMinutes: Int {
        let raw = UserDefaults.standard.object(forKey: notifyLeadMinutesKey) as? Int ?? defaultNotifyLeadMinutes
        return min(max(raw, notifyLeadMinuteRange.lowerBound), notifyLeadMinuteRange.upperBound)
    }

    // MARK: - 載入與啟動

    private func load(_ itinerary: Itinerary, record: ItinRunRecord) {
        events = itinerary.events
        timeZone = itinerary.timeZone
        let origins = ItinSchedule.origins(of: events)
        var fallback: [Int] = []
        var built: [MovePlan?] = []
        for i in events.indices {
            let e = events[i]
            guard e.type == .move, let origin = origins[i], let dest = e.coord else {
                built.append(nil)
                continue
            }
            if e.hasValidCachedPath(from: origin), let path = e.cachedPath {
                built.append(MovePlan(path: path.map { $0.clCoordinate }, mode: e.moveMode.moveMode))
            } else {
                if e.moveMode == .route { fallback.append(i) }
                built.append(MovePlan(path: GpsSimRoutePlanner.straightPath(from: origin.clCoordinate,
                                                                            to: dest.clCoordinate),
                                      mode: .straight, fellBackToStraight: e.moveMode == .route))
            }
        }
        plans = built
        straightFallbackIndices = fallback
        run = record
        rebuildBaseSlots()
        activeItineraryID = itinerary.id
        activeItineraryName = itinerary.name
        lastRunName = itinerary.name
        lastRunTimeZone = itinerary.timeZone
    }

    private func rebuildBaseSlots() {
        guard let run else { return }
        baseSlots = ItinSchedule.compute(events: events, anchor: run.anchor,
                                         durations: ItinSchedule.moveDurations(events: events),
                                         dateMode: dateMode(), timeZone: timeZone, shift: run.startShift)
        slots = effectiveSlots()
    }

    private func dateMode() -> ItinDateMode {
        guard let id = run?.itineraryID else { return .today }
        return GpsItineraryStore.shared.itinerary(id: id)?.dateMode ?? .today
    }

    /// 開始失敗：清掉載入的內容（還沒啟動計時器）。
    private func clearLoaded() {
        run = nil
        events = []
        plans = []
        baseSlots = []
        slots = []
        straightFallbackIndices = []
        activeItineraryID = nil
        activeItineraryName = nil
    }

    /// 啟動計時器並重設分派狀態。restoring＝接續上次中斷的紀錄：使用者暫停中就還原成暫停，
    /// 不清掉 userPaused（點選「繼續」後依現在時間查表）。
    private func activate(restoring record: ItinRunRecord? = nil) {
        dispatchedIndex = nil
        currentIndex = record?.currentIndex
        moverOwned = false
        dispatchDone = false
        dispatchInFlight = false
        lastDispatchCode = nil
        lastFailCode = nil
        nextRetryAt = nil
        linkLostDuringItem = false
        arrivalHandledIndex = nil
        if let at = record?.pausedAt, let index = record?.pausedIndex {
            userPaused = true
            pausedAt = at
            pausedIndex = index
            state = .paused(.user)
        } else {
            userPaused = false
            pausedAt = nil
            pausedIndex = nil
        }
        overdueFixedIndex = nil
        overdueNotifiedIndex = nil
        pendingRelocate = false
        clockRef = nil
        backgroundNoticeSent = false
        lockNoticeSent = false
        notice = nil
        timelineShift = 0
        rememberSerials()
        timer?.invalidate()
        let t = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - 每秒一跳

    private func tick() {
        guard let record = run else { return }
        let now = Date()
        guard GpsItineraryStore.shared.itinerary(id: record.itineraryID) != nil else {
            log("itinerary deleted while running")
            cancelRun(.itineraryDeleted, notice: Self.stoppedNotice)
            return
        }
        if takeoverDetected() {
            log("manual takeover")
            cancelRun(.manualTakeover, notice: Self.takeoverNotice)
            return
        }
        var redispatch = false
        if clockJumped(now) {
            log("clock changed, relocating")
            notice = Self.clockChangedNotice
            rescheduleNotifications()
            // 暫停中不重新分派（會蓋掉暫停）：記下來，點選「繼續」後再依新時間重新定位。
            if userPaused { pendingRelocate = true } else { redispatch = true }
        }
        if pendingRelocate && !userPaused {
            pendingRelocate = false
            redispatch = true
        }
        adoptExternalPause(now)
        if userPaused {
            checkOverdueWhilePaused(now)
            updateState()
            return
        }
        checkArrival(now)
        guard run != nil else { return }
        let current = effectiveSlots()
        if current != slots { slots = current }

        switch ItinSchedule.resolve(slots: current, now: now) {
        case .notYet:
            if dispatchedIndex == nil { enterArmed() }
        case .finished:
            if let index = dispatchedIndex, shouldHoldForArrival(index, now: now) {
                monitor(index: index, offset: now.timeIntervalSince(current[index].start), now: now)
            } else {
                finishRun()
                return
            }
        case .current(let cursor):
            if let index = dispatchedIndex, cursor.index == index, !redispatch {
                monitor(index: index, offset: cursor.offset, now: now)
            } else if let index = dispatchedIndex, cursor.index > index, !redispatch,
                      shouldHoldForArrival(index, now: now) {
                // 移動比預估晚：下一個「接續上一項」等實際抵達（規格 10.2.2）。
                monitor(index: index, offset: now.timeIntervalSince(current[index].start), now: now)
            } else {
                dispatch(index: cursor.index, offset: cursor.offset)
            }
        }
        updateState()
    }

    /// 手動接手：引擎或移動器的序號不是自己記下的值，或自己的移動／漫步被「結束移動」停掉。
    private func takeoverDetected() -> Bool {
        if engine.controlSerial != recordedControlSerial { return true }
        if mover.runSerial != recordedRunSerial { return true }
        if moverOwned, let index = dispatchedIndex, events.indices.contains(index),
           events[index].type == .move || events[index].type == .wander,
           mover.state == .idle {
            return true
        }
        return false
    }

    /// 移動器被其他地方（例如捷徑）按了暫停：當成行程暫停，避免時間軸繼續走而跳位。
    private func adoptExternalPause(_ now: Date) {
        guard !userPaused, moverOwned, let index = dispatchedIndex,
              case .paused(.user) = mover.state, mover.runSerial == recordedRunSerial else { return }
        beginPause(at: index)
        log("adopted mover pause at item \(index + 1)")
        persist()
    }

    private func beginPause(at index: Int) {
        userPaused = true
        pausedAt = Date()
        pausedIndex = index
    }

    /// 手機時間跳動 > 300 秒（牆上時鐘與單調時鐘走的秒數不同）。
    private func clockJumped(_ now: Date) -> Bool {
        let mono = Self.monotonicSeconds()
        defer { clockRef = (wall: now, mono: mono) }
        guard let ref = clockRef else { return false }
        let wall = now.timeIntervalSince(ref.wall)
        let real = mono - ref.mono
        guard wall.isFinite, real.isFinite else { return false }
        return abs(wall - real) > Self.clockJumpSeconds
    }

    /// 含裝置睡眠時間的單調時鐘（秒）。
    private static func monotonicSeconds() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    /// 移動項目實際抵達：下一個「接續上一項」改從實際抵達時間起算；最後一項抵達＝行程結束。
    private func checkArrival(_ now: Date) {
        guard let index = dispatchedIndex, events.indices.contains(index),
              events[index].type == .move, moverOwned, arrivalHandledIndex != index,
              mover.state == .arrived, mover.runSerial == recordedRunSerial else { return }
        arrivalHandledIndex = index
        log("item \(index + 1) arrived")
        let next = index + 1
        if next >= events.count {
            finishRun()
            return
        }
        guard events[next].startRule.kind == .afterPrevious,
              slots.indices.contains(index), let estimated = slots[index].end else { return }
        let delta = now.timeIntervalSince(estimated)
        guard abs(delta) >= 1 else { return }
        applyDelay(from: next, delta: delta)
        persist()
        rescheduleNotifications()
    }

    private func shouldHoldForArrival(_ index: Int, now: Date) -> Bool {
        guard events.indices.contains(index), events[index].type == .move,
              moverOwned, mover.state == .moving, mover.runSerial == recordedRunSerial,
              slots.indices.contains(index), let end = slots[index].end else { return false }
        let next = index + 1
        if next < events.count, events[next].startRule.kind == .at { return false }
        let duration = max(0, end.timeIntervalSince(slots[index].start))
        let cap = max(Self.arrivalHoldMin, duration * Self.arrivalHoldFraction)
        return now < end.addingTimeInterval(cap)
    }

    /// 目前項目進行中：斷線恢復後補位、停留／停止模擬送失敗重試、鎖定通知。
    private func monitor(index: Int, offset: TimeInterval, now: Date) {
        guard events.indices.contains(index) else { return }
        let e = events[index]
        switch e.type {
        case .move, .wander:
            guard moverOwned else { return }
            if case .paused(let reason) = mover.state, reason != .user {
                linkLostDuringItem = true
                if reason == .deviceLocked { notifyLockedOnce() }
                return
            }
            guard linkLostDuringItem, mover.state == .moving || mover.state == .wandering(waiting: false)
                    || mover.state == .wandering(waiting: true) else { return }
            linkLostDuringItem = false
            lockNoticeSent = false
            guard e.type == .move, let plan = plans[index] else { return }
            let kmh = e.effectiveKmh
            let expected = ItinSchedule.metersAt(offset: offset, kmh: kmh, total: plan.totalMeters)
            if expected - mover.traveledMeters > kmh / 3.6 * Self.catchUpSeconds {
                log("item \(index + 1) catch up after link restored")
                dispatchMove(index, offset: offset, forceCatchUp: true)
                rememberSerials()
            }
        case .stay, .stop:
            guard !dispatchDone, !dispatchInFlight else { return }
            guard let retry = nextRetryAt, now >= retry else { return }
            if e.type == .stay { sendStay(index) } else { sendStop(index) }
            rememberSerials()
        }
    }

    /// 暫停中：下一個「在 HH:mm」項目的時間到了 → 維持暫停、畫面提示、背景時通知一次。
    private func checkOverdueWhilePaused(_ now: Date) {
        guard let index = pausedIndex else { return }
        var found: Int?
        for k in events.indices where k > index && events[k].startRule.kind == .at {
            found = k
            break
        }
        guard let k = found, slots.indices.contains(k), slots[k].start <= now else { return }
        if overdueFixedIndex != k { overdueFixedIndex = k }
        guard overdueNotifiedIndex != k else { return }
        overdueNotifiedIndex = k
        if UIApplication.shared.applicationState != .active {
            let name = run?.itineraryName ?? ""
            let time = Self.timeText(slots[k].start, timeZone: timeZone)
            GpsSimAutoReturn.notify("行程「\(name)」：第 \(k + 1) 項的開始時間 \(time) 已到。點選「繼續」後從第 \(k + 1) 項開始。",
                                    id: Self.notificationPrefix + "overdue")
        }
    }

    // MARK: - 分派

    private func dispatch(index: Int, offset: TimeInterval) {
        guard events.indices.contains(index) else { return }
        let skipped = (dispatchedIndex ?? -1) + 1 < index
        dispatchedIndex = index
        currentIndex = index
        dispatchDone = false
        dispatchInFlight = false
        lastDispatchCode = nil
        lastFailCode = nil
        nextRetryAt = nil
        linkLostDuringItem = false
        if var record = run {
            record.currentIndex = index
            run = record
        }
        timelineShift = run.map { $0.shifts.indices.contains(index) ? $0.shifts[index] : 0 } ?? 0
        leaveArmed()
        let e = events[index]
        log("item \(index + 1)/\(events.count) \(e.type.rawValue), offset \(Int(offset)) s\(skipped ? ", skipped ahead" : "")")
        switch e.type {
        case .move: dispatchMove(index, offset: offset, forceCatchUp: false)
        case .wander: dispatchWander(index)
        case .stay: dispatchStay(index)
        case .stop: sendStop(index)
        }
        // 移動／漫步開始時模擬工作階段已重新持有背景音訊；停留等送達後才放（handleDispatchResult）。
        if e.type == .move || e.type == .wander || (e.type == .stay && dispatchDone) {
            releaseStopAudio()
        }
        rememberSerials()
        persist()
        updateIdleTimer()
        AccessibilityAnnouncer.announce("第 \(index + 1) 項，\(Self.typeLabel(e.type))")
    }

    private func dispatchMove(_ index: Int, offset: TimeInterval, forceCatchUp: Bool) {
        let e = events[index]
        guard let plan = plans[index] else {
            // 起點未知（不應發生，驗證錯誤 34 已擋）：直接停在終點。
            dispatchStay(index)
            return
        }
        let kmh = e.effectiveKmh
        let late = forceCatchUp || offset > Self.catchUpSeconds
        let skip = late ? ItinSchedule.metersAt(offset: offset, kmh: kmh, total: plan.totalMeters) : 0
        moverOwned = true
        dispatchDone = true
        mover.start(plan: plan, name: placeName(e), placeID: e.placeID,
                    center: e.coord?.clCoordinate, kmh: kmh, startAtMeters: skip)
    }

    private func dispatchWander(_ index: Int) {
        let e = events[index]
        guard let c = e.coord else {
            dispatchDone = true
            return
        }
        let place = e.placeID.flatMap { id in GpsPlaceStore.shared.places.first(where: { $0.id == id }) }
        let placeRadius: Double? = place.map { GpsGeo.radius(of: $0) }
        let radius = GpsSimWanderPlanner.radius(size: e.wanderRadius, placeRadius: placeRadius)
        moverOwned = true
        dispatchDone = true
        mover.startWander(center: c.clCoordinate, radius: radius, name: placeName(e),
                          placeID: e.placeID, from: engine.current, autoStop: false)
    }

    private func dispatchStay(_ index: Int) {
        let e = events[index]
        guard let c = e.coord else {
            dispatchDone = true
            moverOwned = false
            return
        }
        // 已在該點（例如移動剛抵達）：不重送，避免落點跳動。
        if !mover.isActive, !engine.isMoving, engine.activeName != nil, let landing = engine.landing,
           GpsGeo.meters(landing, c.clCoordinate) <= Self.sameSpotMeters {
            moverOwned = false
            dispatchDone = true
            return
        }
        sendStay(index)
    }

    private func sendStay(_ index: Int) {
        let e = events[index]
        guard let c = e.coord else { return }
        moverOwned = false
        dispatchInFlight = true
        dispatchToken &+= 1
        let token = dispatchToken
        engine.send(to: c.clCoordinate, name: placeName(e), center: c.clCoordinate, placeID: e.placeID) { [weak self] code in
            self?.handleDispatchResult(code, token: token)
        }
    }

    private func sendStop(_ index: Int) {
        moverOwned = false
        dispatchInFlight = true
        dispatchToken &+= 1
        let token = dispatchToken
        engine.stop { [weak self] code in
            self?.handleDispatchResult(code, token: token)
        }
    }

    private func handleDispatchResult(_ code: Int32, token: Int) {
        guard token == dispatchToken, run != nil else { return }
        dispatchInFlight = false
        lastDispatchCode = code
        if code == 0 {
            dispatchDone = true
            lastFailCode = nil
            lockNoticeSent = false
            nextRetryAt = nil
            if let index = dispatchedIndex, events.indices.contains(index), events[index].type == .stop {
                if index == events.count - 1 {
                    // 最後一項「停止模擬」送達才算行程結束。
                    finishRun()
                    return
                }
                // 中途「停止模擬」：模擬工作階段已釋放背景音訊，行程自己持有，1 Hz 計時才不會在背景停住。
                holdStopAudio()
            } else {
                releaseStopAudio()
            }
            updateState()
            return
        }
        if code != GpsSimEngine.busyCode {
            lastFailCode = code
            log("send failed (code \(code))")
            if code == 11 { notifyLockedOnce() }
        }
        nextRetryAt = Date().addingTimeInterval(code == GpsSimEngine.busyCode ? 1 : Self.retryEvery)
        updateState()
    }

    /// 自己分派完立刻重記序號（自己的 send／stop／start 也會讓序號加 1）。
    private func rememberSerials() {
        recordedControlSerial = engine.controlSerial
        recordedRunSerial = mover.runSerial
    }

    private func placeName(_ e: ItinEvent) -> String {
        if let name = e.placeName, !name.isEmpty { return name }
        return run?.itineraryName ?? "行程"
    }

    /// 第一個位置：移動／漫步等移動器第一點被接受；停留／停止模擬等引擎回呼。最多 8 秒。
    private func waitForFirstDelivery(index: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(Self.firstSendTimeout)
        while Date() < deadline {
            guard run != nil, events.indices.contains(index) else { return false }
            switch events[index].type {
            case .move, .wander:
                if !moverOwned { if dispatchDone && !dispatchInFlight { return true } }
                else {
                    if mover.runSerial != recordedRunSerial { return false }
                    if mover.deliveredSteps > 0 { return true }
                    if case .paused(let reason) = mover.state, reason != .user { return false }
                    if mover.state == .idle { return false }
                }
            case .stay, .stop:
                if dispatchDone { return true }
                if let code = lastDispatchCode, code != 0, code != GpsSimEngine.busyCode { return false }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    /// 第一個位置送不出：收掉移動、回到未開始（位置不變更）。
    private func abortFirstSend() {
        log("first send failed")
        if moverOwned, mover.isActive, mover.runSerial == recordedRunSerial {
            mover.stopMoving()
        }
        teardown(to: .cancelled(.firstSendFailed))
    }

    // MARK: - 結束

    /// 時間表已全部結束時呼叫（tick 每秒、或最後一項「停止模擬」送達時）。
    /// 最後一項是「停止模擬」：送出並等回 0 才結束，失敗依 retryEvery 重試（期間每秒會再進來）。
    private func finishRun() {
        guard run != nil else { return }
        if let last = events.indices.last, events[last].type == .stop {
            if dispatchedIndex != last {
                dispatch(index: last, offset: 0)
                return
            }
            if !dispatchDone {
                if !dispatchInFlight, let retry = nextRetryAt, Date() >= retry {
                    sendStop(last)
                    rememberSerials()
                }
                updateState()
                return
            }
        } else if moverOwned, mover.isActive, mover.runSerial == recordedRunSerial {
            // 漫步（或延誤後仍在移動）收尾：停在目前位置、模擬繼續。
            mover.stopMoving()
        }
        log("finished")
        teardown(to: .finished)
        notice = Self.finishedNotice
        AccessibilityAnnouncer.announce(Self.finishedNotice)
    }

    private func cancelRun(_ reason: ItinCancelReason, notice text: String?) {
        if reason == .user, moverOwned, mover.isActive, mover.runSerial == recordedRunSerial {
            mover.stopMoving()
        }
        teardown(to: .cancelled(reason))
        guard let text else { return }
        notice = text
        engine.toastKind = .plain
        engine.toast = text
        AccessibilityAnnouncer.announce(text)
    }

    private func teardown(to newState: ItinRunState) {
        timer?.invalidate()
        timer = nil
        leaveArmed()
        releaseStopAudio()
        cancelScheduledNotifications()
        run = nil
        plans = []
        baseSlots = []
        slots = []
        events = []
        straightFallbackIndices = []
        activeItineraryID = nil
        activeItineraryName = nil
        dispatchedIndex = nil
        currentIndex = nil
        moverOwned = false
        dispatchInFlight = false
        dispatchToken &+= 1
        userPaused = false
        pausedAt = nil
        pausedIndex = nil
        overdueFixedIndex = nil
        timelineShift = 0
        UserDefaults.standard.removeObject(forKey: Self.runStateKey)
        state = newState
        updateIdleTimer()
    }

    // MARK: - 時間表

    /// baseSlots 加上各項目的順延；「直到下一項」的停留結束＝下一項開始。
    private func effectiveSlots() -> [ItinSlot] {
        guard let run, baseSlots.count == events.count else { return baseSlots }
        var out = baseSlots
        for i in out.indices {
            let shift = run.shifts.indices.contains(i) ? run.shifts[i] : 0
            out[i].start = baseSlots[i].start.addingTimeInterval(shift)
            if !untilNext(i), let end = baseSlots[i].end {
                out[i].end = end.addingTimeInterval(shift)
            }
        }
        for i in out.indices where untilNext(i) {
            out[i].end = i + 1 < out.count ? out[i + 1].start : nil
        }
        return out
    }

    private func untilNext(_ i: Int) -> Bool {
        events[i].type == .stay && events[i].minutes == nil
    }

    /// from 起（含）順延 delta 秒，遇到下一個「在 HH:mm」項目即停（規格 10.2.4）。
    /// 哪些項目順延交給 ItinSchedule.applyingPause（有單元測試）；這裡只把前後時間差
    /// 存回每項的順延秒數（shifts，接續行程要存檔）。實際抵達早到時 delta 為負，同一套規則。
    private func applyDelay(from index: Int, delta: TimeInterval) {
        guard var record = run, record.shifts.indices.contains(index), delta.isFinite, delta != 0 else { return }
        let before = effectiveSlots()
        let after = ItinSchedule.applyingPause(before, events: events, currentIndex: index, pause: delta)
        guard before.count == record.shifts.count, after.count == before.count else { return }
        for k in record.shifts.indices {
            record.shifts[k] += after[k].start.timeIntervalSince(before[k].start)
        }
        run = record
        if let current = dispatchedIndex, record.shifts.indices.contains(current) {
            timelineShift = record.shifts[current]
        }
        slots = effectiveSlots()
    }

    // MARK: - 狀態、待命、螢幕、背景

    private func updateState() {
        guard run != nil else { return }
        let next: ItinRunState
        if userPaused {
            next = .paused(.user)
        } else if let index = dispatchedIndex {
            if let reason = linkReason() {
                next = .paused(reason)
            } else {
                next = .running(index: index)
            }
        } else {
            next = .armed
        }
        guard next != state else { return }
        state = next
        updateIdleTimer()
        switch next {
        case .paused(.user): AccessibilityAnnouncer.announce("行程已暫停")
        case .paused(.connectionLost): AccessibilityAnnouncer.announce("無法連線")
        case .paused(.deviceLocked): AccessibilityAnnouncer.announce("手機已鎖定")
        default: break
        }
    }

    /// 連線中斷或手機鎖定（時間軸照走，只是位置送不出）。
    private func linkReason() -> MovePauseReason? {
        if moverOwned, mover.runSerial == recordedRunSerial, case .paused(let reason) = mover.state, reason != .user {
            return reason
        }
        if !moverOwned, !dispatchDone, let code = lastFailCode {
            return code == 11 ? .deviceLocked : .connectionLost
        }
        if engine.connectionLost { return .connectionLost }
        return nil
    }

    private func enterArmed() {
        if state != .armed { state = .armed }
        guard !holdingAudio else { return }
        holdingAudio = true
        BackgroundAudioManager.shared.requestStart()
        log("armed")
    }

    private func leaveArmed() {
        guard holdingAudio else { return }
        holdingAudio = false
        BackgroundAudioManager.shared.requestStop()
    }

    private func holdStopAudio() {
        guard !holdingStopAudio else { return }
        holdingStopAudio = true
        BackgroundAudioManager.shared.requestStart()
    }

    private func releaseStopAudio() {
        guard holdingStopAudio else { return }
        holdingStopAudio = false
        BackgroundAudioManager.shared.requestStop()
    }

    /// 待命、進行中（含斷線）且 App 在前景：螢幕不自動鎖定；暫停、停止、結束還原。
    private func updateIdleTimer() {
        let wants: Bool
        switch state {
        case .armed, .running: wants = true
        case .paused(let reason): wants = reason != .user
        default: wants = false
        }
        let hold = wants && UIApplication.shared.applicationState == .active
        guard hold != holdingIdleTimer else { return }
        holdingIdleTimer = hold
        UIApplication.shared.isIdleTimerDisabled = hold
    }

    private func appDidEnterBackground() {
        updateIdleTimer()
        guard isActive, !backgroundNoticeSent, let name = run?.itineraryName else { return }
        backgroundNoticeSent = true
        GpsSimAutoReturn.notify("行程「\(name)」在背景進行。請勿從 App 切換器關閉 PinFly；螢幕鎖定後將無法送出模擬位置。",
                                id: Self.notificationPrefix + "background")
    }

    private func notifyLockedOnce() {
        guard !lockNoticeSent else { return }
        lockNoticeSent = true
        log("device locked")
        GpsSimAutoReturn.notify("手機已鎖定，行程無法送出模擬位置。解鎖後將依目前時間接續。",
                                id: Self.notificationPrefix + "locked")
    }

    // MARK: - 項目前通知（規格 10.4.2）

    private func rescheduleNotifications() {
        cancelScheduledNotifications()
        guard let record = run, !userPaused else { return }
        let center = UNUserNotificationCenter.current()
        let lead = TimeInterval(Self.notifyLeadMinutes) * 60
        let now = Date()
        let firstPending = (dispatchedIndex ?? -1) + 1
        var ids: [String] = []
        for i in slots.indices where i >= firstPending {
            let e = events[i]
            let fire = slots[i].start.addingTimeInterval(-lead)
            let wait = fire.timeIntervalSince(now)
            guard wait > 1 else { continue }
            let content = UNMutableNotificationContent()
            content.title = "PinFly"
            content.body = leadBody(e, at: slots[i].start, name: record.itineraryName)
            content.sound = .default
            let id = Self.notificationPrefix + "lead.\(i)"
            let request = UNNotificationRequest(identifier: id, content: content,
                                                trigger: UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false))
            center.add(request) { error in
                if let error { GpsSimIntentLog.error("[Itinerary] notification failed: \(error.localizedDescription)") }
            }
            ids.append(id)
        }
        // 待命保險：第一項開始的那一刻再提醒一次，使用者點選後 App 回前景立即補位（規格 10.4.3）。
        if dispatchedIndex == nil, let first = slots.first, events.indices.contains(0) {
            let wait = first.start.timeIntervalSince(now)
            if wait > 1 {
                let content = UNMutableNotificationContent()
                content.title = "PinFly"
                content.body = leadBody(events[0], at: first.start, name: record.itineraryName)
                content.sound = .default
                let id = Self.notificationPrefix + "first"
                let request = UNNotificationRequest(identifier: id, content: content,
                                                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false))
                center.add(request) { error in
                    if let error { GpsSimIntentLog.error("[Itinerary] notification failed: \(error.localizedDescription)") }
                }
                ids.append(id)
            }
        }
        scheduledNotificationIDs = ids
    }

    private func cancelScheduledNotifications() {
        guard !scheduledNotificationIDs.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: scheduledNotificationIDs)
        scheduledNotificationIDs = []
    }

    /// 「行程「下午散步」：15:00 開始原地漫步（台北101）。請開啟 PinFly 並保持螢幕亮著。」（不含座標）
    private func leadBody(_ e: ItinEvent, at date: Date, name: String) -> String {
        let time = Self.timeText(date, timeZone: timeZone)
        let what: String
        switch e.type {
        case .stop:
            what = "\(time) 停止模擬"
        default:
            let place = e.placeName.map { "（\($0)）" } ?? ""
            what = "\(time) 開始\(Self.typeLabel(e.type))\(place)"
        }
        return "行程「\(name)」：\(what)。請開啟 PinFly 並保持螢幕亮著。"
    }

    // MARK: - 共用文字

    nonisolated static func typeLabel(_ type: ItinEventType) -> String {
        switch type {
        case .stay: return "停留"
        case .move: return "移動"
        case .wander: return "原地漫步"
        case .stop: return "停止模擬"
        }
    }

    /// 行程時區下的「14:30」（不同天加「M/d」）。
    nonisolated static func timeText(_ date: Date, timeZone: TimeZone, now: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.timeZone = timeZone
        f.dateFormat = cal.isDate(date, inSameDayAs: now) ? "HH:mm" : "M/d HH:mm"
        return f.string(from: date)
    }

    // MARK: - 存檔

    private func persist() {
        guard var record = run else { return }
        record.pausedAt = userPaused ? pausedAt : nil
        record.pausedIndex = userPaused ? pausedIndex : nil
        run = record
        if let data = try? JSONEncoder().encode(record) {
            UserDefaults.standard.set(data, forKey: Self.runStateKey)
        }
    }

    private static func loadRecord() -> ItinRunRecord? {
        guard let data = UserDefaults.standard.data(forKey: runStateKey) else { return nil }
        return try? JSONDecoder().decode(ItinRunRecord.self, from: data)
    }

    private func log(_ message: String) {
        GpsSimIntentLog.info("[Itinerary] \(message)")
    }
}
