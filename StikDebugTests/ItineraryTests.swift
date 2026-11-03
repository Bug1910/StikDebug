//
//  ItineraryTests.swift
//  StikDebugTests
//
//  【這個檔案的角色】「預排行程」資料本與時刻表的單元測試（規格 10.1、10.2、10.6.7、10.6.9、11.3）。
//  只測純函式（ItinSchedule、ItinTransfer、ItinMessage）與存檔（GpsItineraryStore 讀寫暫存資料夾），
//  不連手機、不呼叫 MKDirections，模擬器或 CI 上都能跑。
//  時間一律用整秒的 UTC 時刻，台北＝UTC+8（無日光節約）、東京＝UTC+9，結果不受執行機器時區影響。
//

import Foundation
import Testing
@testable import StikDebug

// MARK: - 共用工具

private let taipei = TimeZone(identifier: "Asia/Taipei")!
private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

/// "2026-11-05T06:00:00Z" → Date
private func utc(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text)!
}

private let pointA = ItinCoord(lat: 25.0000, lon: 121.5000)
/// A 往北 0.009 度 ≈ 1001.9 公尺（GpsGeo 的平面近似：每度 111,320 公尺）。
private let pointB = ItinCoord(lat: 25.0090, lon: 121.5000)
private let abMeters = 0.009 * 111_320.0

private func stay(_ c: ItinCoord, minutes: Int?, at: Date? = nil, name: String? = nil) -> ItinEvent {
    ItinEvent(type: .stay, startRule: at.map { ItinStartRule(kind: .at, at: $0) } ?? .afterPreviousRule,
              placeName: name, coord: c, minutes: minutes)
}

private func move(_ c: ItinCoord, mode: ItinMoveMode = .straight, speed: MoveSpeedPreset = .walk,
                  customKmh: Double? = nil, at: Date? = nil, name: String? = nil) -> ItinEvent {
    ItinEvent(type: .move, startRule: at.map { ItinStartRule(kind: .at, at: $0) } ?? .afterPreviousRule,
              placeName: name, coord: c, moveMode: mode, speedPreset: speed, customKmh: customKmh)
}

private func wander(_ c: ItinCoord, minutes: Int?, size: WanderSize = .medium, at: Date? = nil) -> ItinEvent {
    ItinEvent(type: .wander, startRule: at.map { ItinStartRule(kind: .at, at: $0) } ?? .afterPreviousRule,
              coord: c, wanderRadius: size, minutes: minutes)
}

private func stopEvent(at: Date? = nil) -> ItinEvent {
    ItinEvent(type: .stop, startRule: at.map { ItinStartRule(kind: .at, at: $0) } ?? .afterPreviousRule)
}

private func itinerary(_ events: [ItinEvent], mode: ItinDateMode = .today, tz: TimeZone = taipei,
                       name: String = "下午散步") -> Itinerary {
    Itinerary(id: "it-1", name: name, timeZoneID: tz.identifier, events: events,
              updatedAt: utc("2026-11-01T00:00:00Z"), dateMode: mode)
}

private func slots(_ it: Itinerary, anchor: Date, shift: TimeInterval = 0) -> [ItinSlot] {
    ItinSchedule.compute(events: it.events, anchor: anchor, durations: ItinSchedule.moveDurations(events: it.events),
                         dateMode: it.dateMode, timeZone: it.timeZone, shift: shift)
}

private func near(_ a: TimeInterval, _ b: TimeInterval, _ tolerance: TimeInterval = 0.01) -> Bool {
    abs(a - b) <= tolerance
}

private func codes(_ issues: [ItinIssue]) -> [Int] {
    issues.map(\.code)
}

/// 台北 14:00（2026-11-05）
private let anchor1400 = utc("2026-11-05T06:00:00Z")

struct ItineraryScheduleTests {

    // MARK: compute

    @Test func computeChainsAfterPrevious() {
        let it = itinerary([stay(pointA, minutes: 20), move(pointB), wander(pointB, minutes: 30)])
        let s = slots(it, anchor: anchor1400)
        let walkSeconds = abMeters / (5 / 3.6)
        #expect(s.count == 3)
        #expect(s[0].start == anchor1400)
        #expect(s[0].end == anchor1400.addingTimeInterval(1200))
        #expect(s[1].start == anchor1400.addingTimeInterval(1200))
        #expect(near(s[1].end!.timeIntervalSince(s[1].start), walkSeconds))
        #expect(s[2].start == s[1].end)
        #expect(near(s[2].end!.timeIntervalSince(s[2].start), 1800))
    }

    @Test func computeTodayModeUsesOnlyHourAndMinute() {
        // at 是 1/1 的台北 14:30；today 模式只取時分，放到 anchor（11/5 台北 10:00）那天。
        let it = itinerary([stay(pointA, minutes: 10, at: utc("2026-01-01T06:30:00Z"))])
        let s = slots(it, anchor: utc("2026-11-05T02:00:00Z"))
        #expect(s[0].start == utc("2026-11-05T06:30:00Z"))
    }

    @Test func computeTodayModeEarlierTimeIsNextDay() {
        // 23:00 停留直到下一項 → 01:00（早於上一項開始）＝隔天 01:00。
        let it = itinerary([stay(pointA, minutes: nil, at: utc("2026-11-05T15:00:00Z")),
                            stay(pointB, minutes: 10, at: utc("2026-11-04T17:00:00Z"))])
        let s = slots(it, anchor: utc("2026-11-05T02:00:00Z"))
        #expect(s[0].start == utc("2026-11-05T15:00:00Z"))
        #expect(s[1].start == utc("2026-11-05T17:00:00Z"))
        // 「直到下一項」的結束＝下一項開始。
        #expect(s[0].end == s[1].start)
    }

    @Test func computeTodayModeFirstItemAcrossMidnight() {
        // 台北 23:58 開始，第一項「在 00:01」＝隔天 00:01（不是 23 小時前），不會一開始就全部結束（錯誤 28）。
        let anchor = utc("2026-11-05T15:58:00Z")
        let it = itinerary([stay(pointA, minutes: 5, at: utc("2026-11-01T16:01:00Z")),
                            move(pointB)])
        let s = slots(it, anchor: anchor)
        #expect(s[0].start == utc("2026-11-05T16:01:00Z"))
        #expect(ItinSchedule.resolve(slots: s, now: anchor) == .notYet)
        // 只早幾分鐘（台北 14:05 開始、第一項 14:00）仍是今天已過，交給「從目前的項目接續」。
        let late = slots(itinerary([stay(pointA, minutes: 10, at: anchor1400)]),
                         anchor: anchor1400.addingTimeInterval(300))
        #expect(late[0].start == anchor1400)
    }

    @Test func computeFixedModeUsesExactDate() {
        let at = utc("2026-12-24T10:00:00Z")
        let it = itinerary([stay(pointA, minutes: 10, at: at)], mode: .fixed)
        let s = slots(it, anchor: anchor1400)
        #expect(s[0].start == at)
        #expect(s[0].end == at.addingTimeInterval(600))
    }

    @Test func computeShiftMovesEverything() {
        let it = itinerary([stay(pointA, minutes: 20), stay(pointB, minutes: 5, at: utc("2026-11-05T07:00:00Z"))])
        let plain = slots(it, anchor: anchor1400)
        let shifted = slots(it, anchor: anchor1400, shift: 600)
        for i in plain.indices {
            #expect(shifted[i].start == plain[i].start.addingTimeInterval(600))
            #expect(shifted[i].end == plain[i].end?.addingTimeInterval(600))
        }
    }

    @Test func computeAcrossTimeZones() {
        // at＝UTC 11/5 15:30：東京 11/6 00:30、台北 11/5 23:30。anchor＝UTC 11/5 01:00（兩地都是 11/5）。
        let at = utc("2026-11-05T15:30:00Z")
        let anchor = utc("2026-11-05T01:00:00Z")
        let inTokyo = itinerary([stay(pointA, minutes: 10, at: at)], tz: tokyo)
        let inTaipei = itinerary([stay(pointA, minutes: 10, at: at)], tz: taipei)
        #expect(slots(inTokyo, anchor: anchor)[0].start == utc("2026-11-04T15:30:00Z"))
        #expect(slots(inTaipei, anchor: anchor)[0].start == utc("2026-11-05T15:30:00Z"))
        #expect(inTokyo.listSubtitle == "1 個項目・00:30 開始")
        #expect(inTaipei.listSubtitle == "1 個項目・23:30 開始")
        #expect(itinerary([stay(pointA, minutes: 5)]).listSubtitle == "1 個項目・開始後立即執行")
    }

    // MARK: resolve

    @Test func resolveCoversAllCases() {
        let it = itinerary([stay(pointA, minutes: 20), move(pointB), wander(pointB, minutes: 30)])
        let s = slots(it, anchor: anchor1400)
        #expect(ItinSchedule.resolve(slots: s, now: anchor1400.addingTimeInterval(-1)) == .notYet)
        #expect(ItinSchedule.resolve(slots: s, now: anchor1400.addingTimeInterval(60))
                == .current(ItinCursor(index: 0, offset: 60)))
        #expect(ItinSchedule.resolve(slots: s, now: anchor1400.addingTimeInterval(1300))
                == .current(ItinCursor(index: 1, offset: 100)))
        #expect(ItinSchedule.resolve(slots: s, now: s[2].end!.addingTimeInterval(1)) == .finished)
        #expect(ItinSchedule.resolve(slots: [], now: anchor1400) == .finished)
    }

    @Test func resolveWaitsAtDestinationUntilFixedItem() {
        // 14:00 停留 10 分 → 步行約 12 分（14:22 抵達）→ 15:00 停留；14:25 仍在第 2 項（停在終點等候）。
        let it = itinerary([stay(pointA, minutes: 10), move(pointB),
                            stay(pointB, minutes: 10, at: utc("2026-11-05T07:00:00Z"))])
        let s = slots(it, anchor: anchor1400)
        let r = ItinSchedule.resolve(slots: s, now: utc("2026-11-05T06:25:00Z"))
        #expect(r == .current(ItinCursor(index: 1, offset: 900)))
    }

    @Test func resolveOpenEndedLastStayNeverFinishes() {
        let it = itinerary([stay(pointA, minutes: nil)])
        let s = slots(it, anchor: anchor1400)
        #expect(s[0].end == nil)
        #expect(ItinSchedule.resolve(slots: s, now: anchor1400.addingTimeInterval(86_400))
                == .current(ItinCursor(index: 0, offset: 86_400)))
    }

    // MARK: 暫停順延（規格 10.2.4）

    @Test func pauseShiftsUntilNextFixedItem() {
        let it = itinerary([stay(pointA, minutes: 10), stay(pointA, minutes: 10),
                            stay(pointA, minutes: 10, at: utc("2026-11-05T07:00:00Z")), stay(pointA, minutes: 10)])
        let s = slots(it, anchor: anchor1400)
        let p = ItinSchedule.applyingPause(s, events: it.events, currentIndex: 0, pause: 300)
        #expect(p[0].start == s[0].start.addingTimeInterval(300))
        #expect(p[0].end == s[0].end?.addingTimeInterval(300))
        #expect(p[1].start == s[1].start.addingTimeInterval(300))
        #expect(p[1].end == s[1].end?.addingTimeInterval(300))
        // 「在 15:00」項目與其後：順延歸零。
        #expect(p[2] == s[2])
        #expect(p[3] == s[3])
    }

    @Test func pauseKeepsUntilNextEnd() {
        let it = itinerary([stay(pointA, minutes: nil), stay(pointB, minutes: 10, at: utc("2026-11-05T07:00:00Z"))])
        let s = slots(it, anchor: anchor1400)
        let p = ItinSchedule.applyingPause(s, events: it.events, currentIndex: 0, pause: 600)
        #expect(p[0].start == s[0].start.addingTimeInterval(600))
        #expect(p[0].end == s[0].end)
        #expect(p[1] == s[1])
        #expect(ItinSchedule.applyingPause(s, events: it.events, currentIndex: 5, pause: 600) == s)
    }

    // MARK: metersAt

    @Test func metersAtIsClamped() {
        #expect(ItinSchedule.metersAt(offset: 3600, kmh: 5, total: 1000) == 1000)
        #expect(near(ItinSchedule.metersAt(offset: 36, kmh: 5, total: 1000), 50))
        #expect(ItinSchedule.metersAt(offset: -10, kmh: 5, total: 1000) == 0)
        #expect(ItinSchedule.metersAt(offset: 100, kmh: 5, total: 0) == 0)
        #expect(ItinSchedule.metersAt(offset: .nan, kmh: 5, total: 1000) == 0)
    }

    // MARK: validate（錯誤 30～36）

    @Test func validItineraryHasNoIssues() {
        let it = itinerary([stay(pointA, minutes: 20), move(pointB), wander(pointB, minutes: 30), stopEvent()])
        #expect(ItinSchedule.validate(it, anchor: anchor1400).isEmpty)
        #expect(ItinSchedule.validate(itinerary([]), anchor: anchor1400).isEmpty)
    }

    @Test func validate30FirstMustHavePosition() {
        let issues = ItinSchedule.validate(itinerary([move(pointB), stay(pointB, minutes: 5)]), anchor: anchor1400)
        #expect(codes(issues).contains(30))
        #expect(issues.first(where: { $0.code == 30 })?.severity == .blocking)
    }

    @Test func validate31TooManyEvents() {
        let events = (0..<21).map { _ in stay(pointA, minutes: 1) }
        #expect(codes(ItinSchedule.validate(itinerary(events), anchor: anchor1400)).contains(31))
        let twenty = (0..<20).map { _ in stay(pointA, minutes: 1) }
        #expect(!codes(ItinSchedule.validate(itinerary(twenty), anchor: anchor1400)).contains(31))
    }

    @Test func validate32MoveLongerThan12Hours() {
        // 往北 0.63 度 ≈ 70 公里，步行 5 km/h ≈ 14 小時。
        let far = ItinCoord(lat: 25.63, lon: 121.5)
        let issues = ItinSchedule.validate(itinerary([stay(pointA, minutes: 1), move(far)]), anchor: anchor1400)
        let has32: Bool = issues.contains(where: { (i: ItinIssue) -> Bool in i.code == 32 && i.eventIndex == 1 })
        #expect(has32)
        let byCar = ItinSchedule.validate(itinerary([stay(pointA, minutes: 1), move(far, speed: .drive)]),
                                          anchor: anchor1400)
        #expect(!codes(byCar).contains(32))
    }

    @Test func validate33TotalLongerThan24Hours() {
        let it = itinerary([stay(pointA, minutes: 720), stay(pointA, minutes: 720), stay(pointA, minutes: 1)])
        #expect(codes(ItinSchedule.validate(it, anchor: anchor1400)).contains(33))
        let ok = itinerary([stay(pointA, minutes: 720), stay(pointA, minutes: 720)])
        #expect(!codes(ItinSchedule.validate(ok, anchor: anchor1400)).contains(33))
    }

    @Test func validate34AfterStopNeedsFixedStayOrWander() {
        let bad = itinerary([stay(pointA, minutes: 10), stopEvent(), move(pointB)])
        let has34: Bool = ItinSchedule.validate(bad, anchor: anchor1400).contains(where: { (i: ItinIssue) -> Bool in i.code == 34 && i.eventIndex == 2 })
        #expect(has34)
        let badStay = itinerary([stay(pointA, minutes: 10), stopEvent(), stay(pointB, minutes: 10)])
        #expect(codes(ItinSchedule.validate(badStay, anchor: anchor1400)).contains(34))
        let ok = itinerary([stay(pointA, minutes: 10), stopEvent(),
                            wander(pointB, minutes: 10, at: utc("2026-11-05T08:00:00Z"))])
        #expect(!codes(ItinSchedule.validate(ok, anchor: anchor1400)).contains(34))
    }

    @Test func validate35ArrivalAfterNextFixedStartIsWarning() {
        // 14:10 出發步行約 12 分 → 14:22 抵達，晚於 14:15 的下一項。
        let it = itinerary([stay(pointA, minutes: 10), move(pointB),
                            stay(pointB, minutes: 10, at: utc("2026-11-05T06:15:00Z"))])
        let issues = ItinSchedule.validate(it, anchor: anchor1400)
        let warning = issues.first(where: { $0.code == 35 })
        #expect(warning?.severity == .warning)
        #expect(warning?.eventIndex == 1)
        #expect(warning?.relatedIndex == 2)
        #expect(warning?.relatedDate == utc("2026-11-05T06:15:00Z"))
        let text = ItinMessage.text(for: warning!, timeZone: taipei, now: anchor1400)
        #expect(text.contains("晚於第 3 項的開始時間 14:15"))
        #expect(text.hasSuffix("（錯誤 35）"))
        // 和現在不同天（例：前一天編輯）→ 帶日期。
        let earlier = ItinMessage.text(for: warning!, timeZone: taipei, now: anchor1400.addingTimeInterval(-86_400))
        #expect(earlier.contains("晚於第 3 項的開始時間 11/5 14:15"))
    }

    @Test func validate36FixedDatesOutOfOrder() {
        let it = itinerary([stay(pointA, minutes: 10, at: utc("2026-11-05T07:00:00Z")),
                            stay(pointB, minutes: 10, at: utc("2026-11-05T06:00:00Z"))], mode: .fixed)
        let issues = ItinSchedule.validate(it, anchor: anchor1400)
        // Evaluated outside #expect: Xcode 26 timed out type-checking the closure inside the macro.
        let has36: Bool = issues.contains(where: { (i: ItinIssue) -> Bool in i.code == 36 && i.eventIndex == 1 && i.relatedIndex == 0 })
        #expect(has36)
        // today 模式同樣的時間＝隔天，不算錯。
        let today = itinerary(it.events, mode: .today)
        #expect(!codes(ItinSchedule.validate(today, anchor: anchor1400)).contains(36))
    }

    @Test func validate36UntilNextNeedsFixedNextItem() {
        // 停留「直到下一項」但下一項接續上一項 → 長度 0，無法儲存（兩種日期模式都檢查）。
        let bad = itinerary([stay(pointA, minutes: nil), move(pointB)])
        let issue = ItinSchedule.validate(bad, anchor: anchor1400).first(where: { $0.code == 36 })
        #expect(issue?.severity == .blocking)
        #expect(issue?.eventIndex == 0)
        #expect(issue?.relatedIndex == 1)
        let text = ItinMessage.text(for: issue!, timeZone: taipei)
        #expect(text.hasPrefix("第 1 項的停留時間為「直到下一項」，但第 2 項是「接續上一項」"))
        let fixedBad = itinerary(bad.events, mode: .fixed)
        #expect(codes(ItinSchedule.validate(fixedBad, anchor: anchor1400)).contains(36))
        // 下一項在指定時間、或最後一項 → 可以「直到下一項」。
        let ok = itinerary([stay(pointA, minutes: nil), stay(pointB, minutes: nil, at: utc("2026-11-05T07:00:00Z"))])
        #expect(!codes(ItinSchedule.validate(ok, anchor: anchor1400)).contains(36))
    }

    @Test func fieldRules() {
        #expect(ItinSchedule.clampedMinutes(300, for: .wander) == 240)
        #expect(ItinSchedule.clampedMinutes(0, for: .stay) == 1)
        #expect(ItinSchedule.clampedMinutes(800, for: .stay) == 720)
        #expect(ItinSchedule.clampedMinutes(nil, for: .stay) == nil)
        #expect(ItinSchedule.clampedMinutes(10, for: .move) == nil)
        let events = [stay(pointA, minutes: nil), move(pointB), stay(pointB, minutes: nil, at: anchor1400)]
        #expect(!ItinSchedule.untilNextAllowed(events: events, index: 0))
        #expect(ItinSchedule.untilNextAllowed(events: events, index: 1))
        #expect(ItinSchedule.untilNextAllowed(events: events, index: 2))
    }

    // MARK: routeKey（快取過期）

    @Test func routeKeyDetectsStaleCache() {
        let key = ItinEvent.routeKey(from: pointA, to: pointB, moveMode: .route, speedPreset: .walk)
        var e = move(pointB, mode: .route)
        e.cachedPath = [pointA, pointB]
        e.routeKey = key
        #expect(e.hasValidCachedPath(from: pointA))
        // 起點改過 → 過期
        #expect(!e.hasValidCachedPath(from: ItinCoord(lat: 25.001, lon: 121.5)))
        // 單車與步行同一種路線 → 不過期；駕車、直線 → 過期
        e.speedPreset = .bike
        #expect(e.hasValidCachedPath(from: pointA))
        e.speedPreset = .drive
        #expect(!e.hasValidCachedPath(from: pointA))
        e.speedPreset = .walk
        e.moveMode = .straight
        #expect(!e.hasValidCachedPath(from: pointA))
        // 只有 1 點不算路徑
        e.moveMode = .route
        e.cachedPath = [pointA]
        #expect(!e.hasValidCachedPath(from: pointA))
    }

    // MARK: 開始平移、時鐘

    @Test func shiftToStartMovesFirstItemToTarget() {
        let fixed = itinerary([stay(pointA, minutes: 10, at: anchor1400), stay(pointB, minutes: 10)])
        let now = utc("2026-11-05T07:00:00Z")   // 台北 15:00：14:00 的第一項要往後 1 小時
        #expect(ItinSchedule.shiftToStart(fixed, at: now, now: now) == 3600)
        let relative = itinerary([stay(pointA, minutes: 10)])
        #expect(ItinSchedule.shiftToStart(relative, at: now.addingTimeInterval(600), now: now) == 600)
        #expect(ItinSchedule.shiftToStart(itinerary([]), at: now, now: now) == 0)
    }

    @Test func clockJumpThreshold() {
        #expect(!ItinSchedule.clockJumped(wallElapsed: 100, uptimeElapsed: 100))
        #expect(!ItinSchedule.clockJumped(wallElapsed: 400, uptimeElapsed: 100))
        #expect(ItinSchedule.clockJumped(wallElapsed: 401, uptimeElapsed: 100))
        #expect(ItinSchedule.clockJumped(wallElapsed: -300, uptimeElapsed: 1))
        #expect(!ItinSchedule.clockJumped(wallElapsed: .nan, uptimeElapsed: 1))
    }
}

// MARK: - 存檔格式與匯入匯出

struct ItineraryTransferTests {

    private func sample() -> Itinerary {
        var mv = move(pointB, mode: .straight, customKmh: 6, name: "中正紀念堂")
        mv.cachedPath = [pointA, pointB]
        mv.routeKey = "x"
        return itinerary([stay(pointA, minutes: 20, at: anchor1400, name: "台北101"),
                          mv,
                          wander(pointB, minutes: 30, size: .large),
                          stopEvent(),
                          stay(pointB, minutes: nil, at: utc("2026-11-05T08:00:00Z"), name: "中正紀念堂")],
                         mode: .fixed)
    }

    @Test func internalFileRoundTrip() throws {
        let file = ItineraryFile(itineraries: [sample()])
        let data = try ItineraryFile.makeEncoder().encode(file)
        let back = try ItineraryFile.makeDecoder().decode(ItineraryFile.self, from: data)
        #expect(back == file)
        #expect(back.version == 1)
    }

    @Test func internalFileMissingFieldsAndUnknownType() throws {
        let json = """
        {"version":1,"itineraries":[{"id":"x","name":"n","timeZoneID":"Asia/Taipei",
         "events":[{"type":"stay","coord":{"lat":25,"lon":121.5}},{"type":"teleport"}],
         "updatedAt":"2026-11-05T06:00:00Z"}]}
        """
        let file = try ItineraryFile.makeDecoder().decode(ItineraryFile.self, from: Data(json.utf8))
        let it = try #require(file.itineraries.first)
        #expect(it.dateMode == .today)
        #expect(it.events.count == 1)
        #expect(it.events[0].startRule.kind == .afterPrevious)
        #expect(it.events[0].cachedPath == nil)
        #expect(it.events[0].routeKey == nil)
    }

    @Test func exportImportRoundTrip() throws {
        let original = sample()
        let data = try ItinTransfer.exportJSON(original)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("cachedPath"))
        #expect(!text.contains("routeKey"))
        #expect(text.contains("\"date_mode\" : \"fixed\""))
        #expect(text.contains("2026-11-05T14:00:00+08:00"))

        let result = try ItinTransfer.importJSON(data, places: [])
        #expect(result.adjustments.isEmpty)
        let back = result.itinerary
        #expect(back.name == original.name)
        #expect(back.timeZoneID == "Asia/Taipei")
        #expect(back.dateMode == .fixed)
        #expect(back.events.count == original.events.count)
        for (a, b) in zip(original.events, back.events) {
            #expect(a.type == b.type)
            #expect(a.startRule == b.startRule)
            #expect(a.coord == b.coord)
            #expect(a.placeName == b.placeName)
            #expect(b.cachedPath == nil)
        }
        #expect(back.events[0].minutes == 20)
        #expect(back.events[1].moveMode == .straight)
        #expect(back.events[1].speedPreset == .walk)
        #expect(back.events[1].customKmh == 6)
        #expect(back.events[2].wanderRadius == .large)
        #expect(back.events[2].minutes == 30)
        #expect(back.events[4].minutes == nil)
    }

    @Test func importResearchSample() throws {
        // 規格 11.3 的範例原文：第一項停留沒有位置、帶 speed_jitter／pause_prob。
        let json = """
        {
          "version": 1,
          "tz": "Asia/Taipei",
          "events": [
            {"type": "stay", "at": "2026-11-05T14:00:00+08:00", "duration_min": 20},
            {"type": "move", "after_prev": true, "to": {"lat": 25.0330, "lon": 121.5654},
             "route": "road", "speed_mps": 1.3, "speed_jitter": 0.1},
            {"type": "wander", "after_prev": true, "center": {"lat": 25.0330, "lon": 121.5654},
             "radius_m": 100, "duration_min": 30, "pause_prob": 0.05}
          ]
        }
        """
        let result = try ItinTransfer.importJSON(Data(json.utf8), places: [])
        let it = result.itinerary
        #expect(it.name == ItinTransfer.defaultImportName)
        #expect(it.dateMode == .today)
        #expect(it.events.map(\.type) == [.move, .wander])
        #expect(it.events[0].moveMode == .route)
        #expect(it.events[0].customKmh == 4.7)
        #expect(it.events[0].speedPreset == .walk)
        #expect(it.events[1].wanderRadius == .medium)
        #expect(result.adjustments.contains("第 1 項沒有位置，未匯入。"))
        #expect(result.adjustments.contains(where: { $0.contains("speed_jitter") }))
    }

    @Test func importAdjustmentsAreListed() throws {
        var events: [[String: Any]] = [
            ["type": "stay", "place": ["lat": 25.0, "lon": 121.5, "name": "起點"] as [String: Any], "duration_min": 10],
            ["type": "move", "after_prev": 120, "to": ["lat": 25.009, "lon": 121.5], "route": "gpx:walk.gpx"],
            ["type": "wander", "radius_m": 30, "duration_min": 300],
            ["type": "teleport"],
        ]
        for _ in 0..<20 { events.append(["type": "stay", "duration_min": 1]) }
        let root: [String: Any] = ["version": 1, "tz": "Asia/Taipei", "name": "測試", "events": events]
        let data = try JSONSerialization.data(withJSONObject: root)
        let result = try ItinTransfer.importJSON(data, places: [])
        let a = result.adjustments
        #expect(a.contains("第 2 項的接續偏移 120 秒未匯入。"))
        #expect(a.contains("第 2 項的 GPX 路線本版不支援，已改為直線。"))
        #expect(a.contains("第 3 項的漫步時間 300 分鐘超出範圍，已改為 240 分鐘。"))
        #expect(a.contains("第 4 項的類型「teleport」不支援，未匯入。"))
        #expect(a.contains("行程檔有 24 個項目，只匯入前 20 項。"))
        let it = result.itinerary
        #expect(it.events.count == 20)
        #expect(it.events[1].moveMode == .straight)
        #expect(it.events[1].startRule.kind == .afterPrevious)
        // 漫步沒寫中心＝上一項終點；30 公尺＝小。
        #expect(it.events[2].coord == ItinCoord(lat: 25.009, lon: 121.5))
        #expect(it.events[2].wanderRadius == .small)
        #expect(it.events[2].minutes == 240)
        // 停留沒寫位置＝上一項終點。
        #expect(it.events[3].coord == ItinCoord(lat: 25.009, lon: 121.5))
    }

    @Test func importStayWithoutDurationGetsDefaultWhenNextFollows() throws {
        // 第 1 項停留沒寫時間、第 2 項接續上一項 → 給預設分鐘數；最後一項停留沒寫 → 保留「直到停止行程」。
        let json = """
        {"version":1,"tz":"Asia/Taipei","events":[
          {"type":"stay","place":{"lat":25.0,"lon":121.5}},
          {"type":"move","after_prev":true,"to":{"lat":25.009,"lon":121.5},"route":"straight"},
          {"type":"stay","after_prev":true}]}
        """
        let result = try ItinTransfer.importJSON(Data(json.utf8), places: [])
        let it = result.itinerary
        #expect(it.events[0].minutes == ItinTransfer.defaultStayMinutes)
        #expect(it.events[2].minutes == nil)
        #expect(result.adjustments.contains("第 1 項未指定停留時間，已設為 \(ItinTransfer.defaultStayMinutes) 分鐘。"))
        #expect(!codes(ItinSchedule.validate(it, anchor: anchor1400)).contains(36))
    }

    @Test func importLinksNearbySavedPlace() throws {
        let near = GpsPlace(id: "p1", name: "台北101", lat: 25.0001, lon: 121.5)    // 約 11 公尺
        let far = GpsPlace(id: "p2", name: "遠方", lat: 25.0010, lon: 121.5)        // 約 111 公尺
        let json = """
        {"version":1,"tz":"Asia/Taipei","events":[
          {"type":"stay","place":{"lat":25.0,"lon":121.5},"duration_min":5},
          {"type":"move","to":"遠方"}]}
        """
        let result = try ItinTransfer.importJSON(Data(json.utf8), places: [far, near])
        let it = result.itinerary
        #expect(it.events[0].placeID == "p1")
        #expect(it.events[0].placeName == "台北101")
        #expect(it.events[1].placeID == "p2")
        #expect(it.events[1].coord == ItinCoord(lat: 25.0010, lon: 121.5))
    }

    @Test func importRejectsUnreadableFiles() {
        #expect(throws: ItinTransferError.unreadable) {
            try ItinTransfer.importJSON(Data("not json".utf8), places: [])
        }
        #expect(throws: ItinTransferError.unreadable) {
            try ItinTransfer.importJSON(Data(#"{"version":2,"events":[{"type":"stop"}]}"#.utf8), places: [])
        }
        #expect(throws: ItinTransferError.unreadable) {
            try ItinTransfer.importJSON(Data(#"{"version":1,"events":[]}"#.utf8), places: [])
        }
        #expect(throws: ItinTransferError.unreadable) {
            try ItinTransfer.importJSON(Data(#"{"events":[{"type":"stop"}]}"#.utf8), places: [])
        }
        #expect(ItinMessage.importFailed.hasSuffix("（錯誤 37）"))
    }

    @Test func speedResolution() {
        let walk = ItinTransfer.resolveSpeed(preset: nil, mps: 5 / 3.6)
        #expect(walk.preset == .walk && walk.customKmh == nil)
        let fast = ItinTransfer.resolveSpeed(preset: nil, mps: 200 / 3.6)
        #expect(fast.preset == .drive && fast.customKmh == 100 && fast.clamped)
        let keepPreset = ItinTransfer.resolveSpeed(preset: .bike, mps: 2)
        #expect(keepPreset.preset == .bike && keepPreset.customKmh == 7.2)
        let none = ItinTransfer.resolveSpeed(preset: .drive, mps: nil)
        #expect(none.preset == .drive && none.customKmh == nil)
    }

    @Test func exportFileName() {
        #expect(ItinTransfer.exportFileName(itinerary([], name: "下午/散步")) == "下午_散步.json")
        #expect(ItinTransfer.exportFileName(itinerary([], name: " ")) == "行程.json")
    }

    @Test func uniqueNames() {
        #expect(GpsItineraryStore.uniqueName("下午散步", existing: []) == "下午散步")
        #expect(GpsItineraryStore.uniqueName("下午散步", existing: ["下午散步"]) == "下午散步 2")
        #expect(GpsItineraryStore.uniqueName("下午散步", existing: ["下午散步", "下午散步 2"]) == "下午散步 3")
    }

    @Test func messages() {
        let i30 = ItinIssue(code: 30, severity: .blocking, eventIndex: 0)
        #expect(ItinMessage.text(for: i30, timeZone: taipei)
                == "第一項必須是「停留」或「原地漫步」，才能決定起點。請在最前面新增停留項目。（錯誤 30）")
        let i34 = ItinIssue(code: 34, severity: .blocking, eventIndex: 3)
        #expect(ItinMessage.text(for: i34, timeZone: taipei).hasPrefix("第 4 項是「停止模擬」的下一項"))
        #expect(ItinMessage.appAlreadyActive("上午") == "行程「上午」正在進行。請先停止該行程。（錯誤 38）")
    }
}

// MARK: - 存檔（暫存資料夾，不碰 App 的正式檔案）

@MainActor
struct ItineraryStoreTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("itin-tests-\(UUID().uuidString)")
            .appendingPathComponent("itineraries.json")
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test func saveAndReload() {
        let url = tempURL()
        defer { cleanup(url) }
        let store = GpsItineraryStore(storeURL: url, notifiesShortcuts: false)
        #expect(store.itineraries.isEmpty)
        store.upsert(itinerary([stay(pointA, minutes: 10)]))
        let again = GpsItineraryStore(storeURL: url, notifiesShortcuts: false)
        #expect(again.itineraries.count == 1)
        #expect(again.itinerary(id: "it-1")?.events.count == 1)
        again.rename(id: "it-1", to: "  晚上  ")
        #expect(again.itinerary(id: "it-1")?.name == "晚上")
    }

    @Test func deleteAndUndoKeepsPosition() {
        let url = tempURL()
        defer { cleanup(url) }
        let store = GpsItineraryStore(storeURL: url, notifiesShortcuts: false)
        for n in ["a", "b", "c"] {
            store.upsert(Itinerary(id: n, name: n, timeZoneID: "Asia/Taipei"))
        }
        store.delete(id: "b")
        #expect(store.itineraries.map(\.id) == ["a", "c"])
        #expect(store.lastDeleted?.id == "b")
        store.undoDelete()
        #expect(store.itineraries.map(\.id) == ["a", "b", "c"])
        #expect(store.lastDeleted == nil)
        store.delete(id: "a")
        store.clearUndo()
        store.undoDelete()
        #expect(store.itineraries.map(\.id) == ["b", "c"])
    }

    @Test func duplicateInsertsBelowWithNewIDs() throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = GpsItineraryStore(storeURL: url, notifiesShortcuts: false)
        store.upsert(itinerary([stay(pointA, minutes: 10)]))
        store.upsert(Itinerary(id: "z", name: "最後", timeZoneID: "Asia/Taipei"))
        let copy = try #require(store.duplicate(id: "it-1"))
        #expect(copy.name == "下午散步 副本")
        #expect(store.itineraries.map(\.id) == ["it-1", copy.id, "z"])
        #expect(copy.events[0].id != store.itinerary(id: "it-1")?.events[0].id)
        #expect(store.duplicate(id: "it-1")?.name == "下午散步 副本 2")
    }

    @Test func corruptFileIsRenamed() throws {
        let url = tempURL()
        defer { cleanup(url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ broken".utf8).write(to: url)
        let store = GpsItineraryStore(storeURL: url, notifiesShortcuts: false)
        #expect(store.itineraries.isEmpty)
        #expect(store.lastLoadError != nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: store.corruptURL.path))
        #expect(store.corruptURL.lastPathComponent == "itineraries.json.corrupt")
    }

    @Test func importRenamesDuplicates() throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = GpsItineraryStore(storeURL: url, notifiesShortcuts: false)
        store.upsert(itinerary([stay(pointA, minutes: 10)]))
        let data = try ItinTransfer.exportJSON(itinerary([stay(pointA, minutes: 10)]))
        let result = try store.importItinerary(from: data, places: [])
        #expect(result.itinerary.name == "下午散步 2")
        #expect(result.itinerary.id != "it-1")
        #expect(store.itineraries.count == 2)
        #expect(throws: ItinTransferError.unreadable) {
            try store.importItinerary(from: Data("x".utf8), places: [])
        }
        #expect(store.itineraries.count == 2)
    }
}

// MARK: - 捷徑（純換算與訊息，不呼叫 Runner）

@MainActor
struct ItineraryIntentTests {

    @Test func startShiftPerMode() {
        let it = itinerary([stay(pointA, minutes: 10, at: anchor1400)])
        let now = utc("2026-11-05T07:00:00Z")
        #expect(GpsStartItineraryRunner.startShift(for: it, mode: .scheduled, delayMinutes: 10, now: now) == 0)
        #expect(GpsStartItineraryRunner.startShift(for: it, mode: .now, delayMinutes: 10, now: now) == 3600)
        #expect(GpsStartItineraryRunner.startShift(for: it, mode: .delayed, delayMinutes: 10, now: now) == 4200)
        // 延後夾在 1～720 分鐘
        #expect(GpsStartItineraryRunner.startShift(for: it, mode: .delayed, delayMinutes: 0, now: now) == 3660)
        #expect(GpsStartItineraryRunner.startShift(for: it, mode: .delayed, delayMinutes: 9999, now: now)
                == 3600 + 720 * 60)
    }

    @Test func successMessages() {
        let it = itinerary([stay(pointA, minutes: 10, name: "台北101"), move(pointB, name: "中正紀念堂")])
        let first = GpsStartItineraryRunner.successMessage(it, state: .running(index: 0), slots: [], straightCount: 0)
        #expect(first == "已開始行程「下午散步」，共 2 個項目，目前為第 1 項：停留在 台北101。行程期間請保持 App 開啟、螢幕亮著、接上電源。")
        let resumed = GpsStartItineraryRunner.successMessage(it, state: .running(index: 1), slots: [], straightCount: 1)
        #expect(resumed == "已開始行程「下午散步」，依目前時間從第 2 項接續：移動至 中正紀念堂。行程期間請保持 App 開啟、螢幕亮著、接上電源。1 個移動項目改為直線。")
        let armed = GpsStartItineraryRunner.successMessage(it, state: .armed, slots: [ItinSlot(start: Date(), end: nil)],
                                                           straightCount: 0)
        #expect(armed.hasPrefix("行程「下午散步」已待命，第 1 項 "))
    }

    @Test func shortcutErrorCodes() {
        #expect(GpsItineraryShortcutMessage.missing("下午散步").hasSuffix("（錯誤 26）"))
        #expect(GpsItineraryShortcutMessage.alreadyActive("上午").hasSuffix("（錯誤 27）"))
        #expect(GpsItineraryShortcutMessage.allFinished("下午散步").hasSuffix("（錯誤 28）"))
        #expect(GpsItineraryShortcutMessage.notActive.hasSuffix("（錯誤 29）"))
        #expect(GpsItineraryShortcutMessage.firstSendFailed.hasPrefix("無法送出行程的第一個位置"))
        // 行程版錯誤 21 與「前往地點」的錯誤 21 文字不同。
        #expect(GpsItineraryShortcutMessage.firstSendFailed != GpsShortcutMessage.firstStepFailed)
        #expect(GpsItineraryStart.allCases.map(\.rawValue) == ["scheduled", "now", "delayed"])
    }
}

// MARK: - 編輯頁計算快取

struct ItineraryEditorCacheTests {
    @Test func cacheMatchesDirectComputationAndRefreshes() {
        let cache = GpsItinEditorCache()
        var it = itinerary([stay(pointA, minutes: 10), move(pointB), wander(pointB, minutes: 15)])
        #expect(cache.plannedSlots(for: it, anchor: anchor1400) == slots(it, anchor: anchor1400))
        #expect(cache.issues(for: it, anchor: anchor1400) == ItinSchedule.validate(it, anchor: anchor1400))
        // draft 改了（第一項改成移動＝錯誤 30）→ 重算，不沿用舊結果。
        it.events[0] = move(pointA)
        #expect(codes(cache.issues(for: it, anchor: anchor1400)).contains(30))
        #expect(cache.plannedSlots(for: it, anchor: anchor1400) == slots(it, anchor: anchor1400))
        // anchor 改了 → 重算。
        let later = anchor1400.addingTimeInterval(600)
        #expect(cache.plannedSlots(for: it, anchor: later) == slots(it, anchor: later))
    }
}
