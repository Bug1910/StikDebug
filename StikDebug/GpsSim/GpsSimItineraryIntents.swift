//
//  GpsSimItineraryIntents.swift
//  PinFly
//
//  【這個檔案的角色】「預排行程」的兩個捷徑動作（規格 12.3.2、12.4）：
//  - 開始行程（StartItineraryIntent）：選行程＋開始時間（依行程設定／立即／延後 N 分鐘），
//    在背景開始，不開啟 App（openAppWhenRun = false），25 秒內回傳。
//  - 停止行程（StopItineraryIntent）：沒有參數；手機停在目前位置並保持模擬（不回真實位置）。
//  以及捷徑的行程選單（GpsItineraryEntity／Query）與開始時間選項（GpsItineraryStart）。
//
//  【為什麼這樣設計】
//  - 型別名、@Parameter 屬性名、AppEnum rawValue 永不改：「捷徑」App 用它們存使用者的設定（規格 12.2）。
//  - 失敗不丟錯：回傳「PinFly 狀態」的結果＝失敗＋原因，捷徑可用「如果 結果 是 失敗」分支（12.2 第 3 點）。
//  - 錯誤 26～29 只給捷徑層級；App 內「已有行程進行中」用錯誤 38（ItinMessage.appAlreadyActive）。
//  - 錯誤 21 另設行程版文字，不改「前往地點」的錯誤 21（GpsShortcutMessage.firstStepFailed）。
//  - 實際的開始／停止都交給 GpsItineraryRunner；本檔只做參數換算與訊息。
//

import AppIntents
import Foundation

// MARK: - 行程選單（捷徑的「行程」參數）

struct GpsItineraryEntity: AppEntity, Sendable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "行程"
    static var defaultQuery = GpsItineraryQuery()

    let id: String
    let name: String
    /// 「4 個項目・14:00 開始」
    let subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)")
    }

    init(id: String, name: String, subtitle: String) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
    }

    init(_ itinerary: Itinerary) {
        self.init(id: itinerary.id, name: itinerary.name, subtitle: itinerary.listSubtitle)
    }
}

struct GpsItineraryQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [GpsItineraryEntity] {
        await MainActor.run {
            let store = GpsItineraryStore.shared
            store.reload()
            return store.itineraries
                .filter { identifiers.contains($0.id) }
                .map { GpsItineraryEntity($0) }
        }
    }

    func suggestedEntities() async throws -> [GpsItineraryEntity] {
        await MainActor.run {
            let store = GpsItineraryStore.shared
            store.reload()
            return store.itineraries.map { GpsItineraryEntity($0) }
        }
    }
}

// MARK: - 開始時間選項（rawValue 永不改名）

enum GpsItineraryStart: String, AppEnum {
    case scheduled
    case now
    case delayed

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "開始時間"
    static var caseDisplayRepresentations: [GpsItineraryStart: DisplayRepresentation] = [
        .scheduled: "依行程設定",
        .now: "立即",
        .delayed: "延後",
    ]
}

// MARK: - 訊息（錯誤 21 行程版、26～29；格式「發生了什麼。下一步怎麼做。（錯誤 N）」）

enum GpsItineraryShortcutMessage {
    static func missing(_ name: String) -> String {
        "找不到行程「\(name)」，此行程已刪除。請在捷徑中重新選擇行程。（錯誤 26）"
    }

    static func alreadyActive(_ name: String) -> String {
        "行程「\(name)」正在進行。請先執行「停止行程」，再重新執行此捷徑。（錯誤 27）"
    }

    static func allFinished(_ name: String) -> String {
        "行程「\(name)」的所有項目都已結束。請將開始時間改為「立即」，或在 PinFly 修改時間。（錯誤 28）"
    }

    static let notActive = "目前沒有進行中的行程。不需要執行此動作。（錯誤 29）"

    /// 錯誤 21 的行程版（不改「前往地點」的 GpsShortcutMessage.firstStepFailed）。
    static let firstSendFailed = "無法送出行程的第一個位置，未開始行程。請解鎖手機並確認 LocalDevVPN 已連線，再重新執行此捷徑。（錯誤 21）"

    static let keepOpenReminder = "行程期間請保持 App 開啟、螢幕亮著、接上電源。"

    static func straightFallback(_ count: Int) -> String {
        "\(count) 個移動項目改為直線。"
    }

    /// 完成訊息裡的項目描述：「停留在 台北101」「移動至 中正紀念堂」「原地漫步（台北101）」「停止模擬」。
    static func eventText(_ event: ItinEvent) -> String {
        let place = event.placeName ?? "指定位置"
        switch event.type {
        case .stay: return "停留在 \(place)"
        case .move: return "移動至 \(place)"
        case .wander: return "原地漫步（\(place)）"
        case .stop: return "停止模擬"
        }
    }
}

// MARK: - 開始行程

struct StartItineraryIntent: AppIntent {
    static var title: LocalizedStringResource = "開始行程"
    static var description = IntentDescription("依預排的時間自動停留、移動、原地漫步。在背景開始，不開啟 App；行程期間請保持 PinFly 開啟、螢幕亮著、接上電源。暫停與繼續請在 App 內操作。")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "行程", requestValueDialog: "要開始哪個行程？")
    var itinerary: GpsItineraryEntity

    @Parameter(title: "開始時間",
               description: "依行程設定：照行程排定的時間；已過的項目依目前時間接續。立即、延後：第一項在現在或指定分鐘後開始，其餘項目依序平移。",
               default: .scheduled)
    var startMode: GpsItineraryStart

    @Parameter(title: "延後（分鐘）", description: "開始時間為「延後」時使用，範圍 1～720 分鐘，超出時以上下限計算。", default: 10)
    var delayMinutes: Int

    // 與「前往地點」相同的最簡形式：頂層 Switch、每個 Summary 不巢狀 When。
    static var parameterSummary: some ParameterSummary {
        Switch(\.$startMode) {
            Case(.delayed) {
                Summary("開始行程 \(\.$itinerary)，開始時間 \(\.$startMode) \(\.$delayMinutes) 分鐘")
            }
            DefaultCase {
                Summary("開始行程 \(\.$itinerary)，開始時間 \(\.$startMode)")
            }
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<GpsSimStatusEntity> & ProvidesDialog {
        await GpsSimAutoReturn.shared.settle(timeout: 3)
        let outcome = await GpsStartItineraryRunner.run(itineraryID: itinerary.id, itineraryName: itinerary.name,
                                                        mode: startMode, delayMinutes: delayMinutes)
        let value = await GpsSimIntentStatus.make(outcome.ok ? .succeeded : .failed,
                                                  reason: outcome.ok ? "" : outcome.message)
        return .result(value: value, dialog: "\(outcome.message)")
    }
}

/// 開始行程的實際步驟（規格 12.3.2 執行流程 2～6）。
@MainActor
enum GpsStartItineraryRunner {
    struct Outcome {
        let ok: Bool
        let message: String
    }

    static let delayRange: ClosedRange<Int> = 1...720

    static func clampDelay(_ minutes: Int) -> Int {
        min(max(minutes, delayRange.lowerBound), delayRange.upperBound)
    }

    /// 開始時間選項 → 全部項目平移秒數（依行程設定＝0）。
    static func startShift(for itinerary: Itinerary, mode: GpsItineraryStart, delayMinutes: Int,
                           now: Date = Date()) -> TimeInterval {
        switch mode {
        case .scheduled:
            return 0
        case .now:
            return ItinSchedule.shiftToStart(itinerary, at: now, now: now)
        case .delayed:
            let target = now.addingTimeInterval(TimeInterval(clampDelay(delayMinutes)) * 60)
            return ItinSchedule.shiftToStart(itinerary, at: target, now: now)
        }
    }

    static func failure(_ message: String, log: String) -> Outcome {
        GpsSimIntentLog.error("[Itinerary] 開始行程 failed: \(log)")
        return Outcome(ok: false, message: message)
    }

    static func run(itineraryID: String, itineraryName: String, mode: GpsItineraryStart,
                    delayMinutes: Int) async -> Outcome {
        let store = GpsItineraryStore.shared
        store.reload()
        guard let itin = store.itinerary(id: itineraryID) else {
            return failure(GpsItineraryShortcutMessage.missing(itineraryName), log: "not found (26)")
        }
        let runner = GpsItineraryRunner.shared
        if runner.isActive {
            let activeName = runner.activeItineraryName ?? itin.name
            return failure(GpsItineraryShortcutMessage.alreadyActive(activeName), log: "already active (27)")
        }
        let shift = self.startShift(for: itin, mode: mode, delayMinutes: delayMinutes)
        GpsSimIntentLog.info("[Itinerary] 開始行程 start: mode=\(mode.rawValue) events=\(itin.events.count) shift=\(Int(shift))")
        do {
            try await runner.start(itineraryID: itin.id, startShift: shift)
        } catch let error as ItinRunError {
            switch error {
            case .notFound:
                return failure(GpsItineraryShortcutMessage.missing(itineraryName), log: "not found (26)")
            case .alreadyActive(let name):
                return failure(GpsItineraryShortcutMessage.alreadyActive(name.isEmpty ? itin.name : name),
                               log: "already active (27)")
            case .allFinished:
                return failure(GpsItineraryShortcutMessage.allFinished(itin.name), log: "all finished (28)")
            case .firstSendFailed:
                return failure(GpsItineraryShortcutMessage.firstSendFailed, log: "first send (21)")
            case .invalid(let issue):
                return failure(ItinMessage.text(for: issue, timeZone: itin.timeZone),
                               log: "invalid (\(issue.code))")
            }
        } catch {
            return failure(GpsItineraryShortcutMessage.firstSendFailed, log: "unexpected: \(error.localizedDescription)")
        }
        let message = self.successMessage(itin, state: runner.state, slots: runner.slots,
                                          straightCount: runner.straightFallbackIndices.count)
        GpsSimIntentLog.info("[Itinerary] 開始行程 ok")
        return Outcome(ok: true, message: message)
    }

    /// 完成訊息（規格 12.3.2 表格；不含 App 名稱）。
    static func successMessage(_ itin: Itinerary, state: ItinRunState, slots: [ItinSlot],
                               straightCount: Int) -> String {
        var text: String
        switch state {
        case .armed:
            let first = slots.first.map { ItinSchedule.clockText($0.start, timeZone: itin.timeZone) } ?? "--:--"
            text = "行程「\(itin.name)」已待命，第 1 項 \(first) 開始。"
        case .running(let index) where itin.events.indices.contains(index):
            let item = GpsItineraryShortcutMessage.eventText(itin.events[index])
            if index == 0 {
                text = "已開始行程「\(itin.name)」，共 \(itin.events.count) 個項目，目前為第 1 項：\(item)。"
            } else {
                text = "已開始行程「\(itin.name)」，依目前時間從第 \(index + 1) 項接續：\(item)。"
            }
        default:
            text = "已開始行程「\(itin.name)」，共 \(itin.events.count) 個項目。"
        }
        text += GpsItineraryShortcutMessage.keepOpenReminder
        if straightCount > 0 {
            text += GpsItineraryShortcutMessage.straightFallback(straightCount)
        }
        return text
    }
}

// MARK: - 停止行程

struct StopItineraryIntent: AppIntent {
    static var title: LocalizedStringResource = "停止行程"
    static var description = IntentDescription("結束進行中或待命的行程，手機停在目前位置並保持模擬。要回到真實位置，請接著使用「停止模擬」（「停止模擬」也會一併停止行程）。")
    static var openAppWhenRun: Bool = false

    // 沒有參數：不另寫 parameterSummary（同「停止模擬」），「捷徑」App 顯示標題「停止行程」。

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<GpsSimStatusEntity> & ProvidesDialog {
        let runner = GpsItineraryRunner.shared
        guard runner.isActive else {
            GpsSimIntentLog.info("[Itinerary] 停止行程: nothing active (29)")
            let value = await GpsSimIntentStatus.make(.failed, reason: GpsItineraryShortcutMessage.notActive)
            return .result(value: value, dialog: "\(GpsItineraryShortcutMessage.notActive)")
        }
        var wasArmed = false
        if case .armed = runner.state { wasArmed = true }
        let name = runner.activeItineraryName ?? ""
        runner.stopItinerary()
        GpsSimIntentLog.info("[Itinerary] 停止行程 ok (armed=\(wasArmed))")
        let message = wasArmed ? "行程已停止（「\(name)」的待命已取消）。" : "行程已停止，停留在目前位置。"
        let value = await GpsSimIntentStatus.make(.succeeded)
        return .result(value: value, dialog: "\(message)")
    }
}
