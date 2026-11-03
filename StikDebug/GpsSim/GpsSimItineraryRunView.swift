//
//  GpsSimItineraryRunView.swift
//  PinFly
//
//  【這個檔案的角色】預排行程的「開始確認視窗」「執行畫面」與首頁「行程進度卡」（規格 10.6.3、10.6.8）。
//  - GpsItineraryStartSheet：點選「開始行程」後的確認視窗（保持開啟提醒、不再顯示、
//    第一項已過時的兩種接續方式、另一個行程進行中的錯誤 38）。
//  - GpsSimItineraryRunView：執行畫面（狀態、目前項目、下一項倒數、三顆按鈕、時間軸）。
//  - GpsItineraryProgressCard：執行畫面被關閉後，首頁底部取代「模擬移動」進度卡。
//  - ItinText：三個畫面共用的文字（類型名稱、範圍、速度、倒數），用語依 docs/ui-terminology.md。
//
//  【為什麼這樣設計】
//  - 畫面只讀 GpsItineraryRunner 的公開狀態、只呼叫它的動作；計時與分派都不在畫面裡做，
//    畫面關掉行程照跑。
//  - 倒數每秒重畫，但 VoiceOver 的值每分鐘才變一次（規格 10.6.11，避免每秒朗讀）。
//

import SwiftUI
import Combine
import UIKit

// MARK: - 共用文字

enum ItinText {
    static func typeLabel(_ type: ItinEventType) -> String {
        GpsItineraryRunner.typeLabel(type)
    }

    static func typeIcon(_ e: ItinEvent) -> String {
        switch e.type {
        case .stay: return "mappin.circle"
        case .move: return e.moveMode == .route ? "arrow.triangle.turn.up.right.circle" : "arrow.up.right.circle"
        case .wander: return "figure.walk.circle"
        case .stop: return "location.slash.circle"
        }
    }

    static func sizeLabel(_ size: WanderSize) -> String {
        switch size {
        case .small: return "小"
        case .medium: return "中"
        case .large: return "大"
        }
    }

    static func speedLabel(_ e: ItinEvent) -> String {
        if let kmh = e.customKmh { return "時速 \(Int(MoveSpeedPreset.clampCustom(kmh).rounded())) 公里" }
        return e.speedPreset.label
    }

    static func place(_ e: ItinEvent) -> String {
        if let name = e.placeName, !name.isEmpty { return name }
        return e.coord == nil ? "" : "地圖上的位置"
    }

    static func distance(_ meters: Double) -> String {
        meters < 1000 ? "\(Int(meters.rounded())) 公尺" : String(format: "%.1f 公里", meters / 1000)
    }

    static func minutes(_ seconds: TimeInterval) -> String {
        let m = max(1, Int((seconds / 60).rounded(.up)))
        if m < 60 { return "\(m) 分" }
        return m % 60 == 0 ? "\(m / 60) 小時" : "\(m / 60) 小時 \(m % 60) 分"
    }

    /// 倒數：> 10 分鐘顯示分鐘；≤ 10 分鐘顯示 mm:ss（規格 10.6.8）。
    static func countdown(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        if s > 600 { return minutes(TimeInterval(s)) }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// VoiceOver 用：只到分鐘。
    static func spokenCountdown(_ seconds: TimeInterval) -> String {
        minutes(seconds)
    }

    static func clock(_ date: Date, _ tz: TimeZone) -> String {
        GpsItineraryRunner.timeText(date, timeZone: tz)
    }

    /// 行程時區與手機不同時的註明：「時間以 台北時間（GMT+8）計算」。
    static func timeZoneNote(_ tz: TimeZone) -> String? {
        guard tz.identifier != TimeZone.current.identifier,
              tz.secondsFromGMT() != TimeZone.current.secondsFromGMT() else { return nil }
        let name = tz.localizedName(for: .generic, locale: Locale(identifier: "zh_Hant_TW")) ?? tz.identifier
        let secs = tz.secondsFromGMT()
        let h = abs(secs) / 3600
        let m = (abs(secs) % 3600) / 60
        let offset = "GMT" + (secs >= 0 ? "+" : "-") + (m == 0 ? "\(h)" : String(format: "%d:%02d", h, m))
        return "時間以 \(name)（\(offset)）計算"
    }
}

// MARK: - 開始確認視窗

/// 開始流程的請求（清單、編輯頁共用）；Identifiable 給 .sheet(item:)。
struct GpsItineraryStartRequest: Identifiable, Equatable {
    let id = UUID()
    let itineraryID: String
}

struct GpsItineraryStartSheet: View {
    let itineraryID: String
    var onStarted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var runner = GpsItineraryRunner.shared
    @ObservedObject private var store = GpsItineraryStore.shared
    @AppStorage("itinerary.skipStartNotice") private var skipNotice = false
    @State private var starting = false
    @State private var errorText: String?
    @State private var autoStarted = false

    private enum Phase: Equatable {
        case normal
        /// 第一項時間已過：可從第 index 項接續或從第 1 項立即開始。
        case late(index: Int)
        case allDone
    }

    private var itinerary: Itinerary? { store.itinerary(id: itineraryID) }

    private var phase: Phase {
        guard let itinerary else { return .normal }
        let now = Date()
        switch ItinSchedule.resolve(slots: GpsItineraryRunner.plannedSlots(for: itinerary, anchor: now), now: now) {
        case .notYet: return .normal
        case .finished: return .allDone
        case .current(let cursor):
            // 第一項為「開始行程時」：現在開始就是準時，不算已過。
            if cursor.index == 0 && cursor.offset < 5 { return .normal }
            return .late(index: cursor.index)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if runner.isActive {
                        otherActiveSection
                    } else {
                        Text(GpsItineraryRunner.startNoticeText)
                            .font(.body)
                            .foregroundStyle(Color.white)
                            .fixedSize(horizontal: false, vertical: true)
                        choiceButtons
                        Toggle("不再顯示", isOn: $skipNotice)
                            .tint(GpsTheme.mint)
                            .foregroundStyle(Color.white)
                    }
                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(GpsTheme.dangerText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("取消") { dismiss() }
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(GpsTheme.sub)
                        .accessibilityIdentifier("itin.start.cancel")
                }
                .padding(16)
            }
            .background(GpsTheme.background.ignoresSafeArea())
            .navigationTitle("開始行程「\(itinerary?.name ?? "")」")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(starting)
            .overlay {
                if starting { ProgressView().tint(GpsTheme.mint) }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            // 已選「不再顯示」：準時開始的情況直接開始，不再停在確認視窗。
            guard !autoStarted, skipNotice, !runner.isActive, phase == .normal else { return }
            autoStarted = true
            begin(shift: 0)
        }
    }

    @ViewBuilder
    private var choiceButtons: some View {
        switch phase {
        case .normal:
            primaryButton("開始", id: "itin.start.go") { begin(shift: 0) }
        case .late(let index):
            primaryButton("從目前的項目接續", id: "itin.start.resume") { begin(shift: 0) }
            Text("依目前時間從第 \(index + 1) 項的途中開始。")
                .font(.footnote)
                .foregroundStyle(GpsTheme.sub)
            secondaryButton("從第 1 項立即開始", id: "itin.start.fromFirst") { beginFromFirst() }
            Text("全部時間依序提前或延後，維持各項間隔。")
                .font(.footnote)
                .foregroundStyle(GpsTheme.sub)
        case .allDone:
            Text("行程「\(itinerary?.name ?? "")」的所有項目都已結束。")
                .font(.body)
                .foregroundStyle(Color.white)
            primaryButton("從第 1 項立即開始", id: "itin.start.fromFirst") { beginFromFirst() }
        }
    }

    private var otherActiveSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("行程「\(runner.activeItineraryName ?? "")」正在進行。請先停止該行程。（錯誤 38）",
                  systemImage: "exclamationmark.triangle")
                .font(.body)
                .foregroundStyle(GpsTheme.dangerText)
                .fixedSize(horizontal: false, vertical: true)
            primaryButton("停止並開始此行程", id: "itin.start.replace") {
                runner.stopItinerary()
                begin(shift: 0, skipLateCheck: false)
            }
        }
    }

    private func primaryButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(GpsTheme.onAccent)
                .background(GpsTheme.mint, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func secondaryButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(GpsTheme.mint)
                .overlay(Capsule().stroke(GpsTheme.mint, lineWidth: 1.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func beginFromFirst() {
        guard let itinerary else { return }
        begin(shift: GpsItineraryRunner.shiftToStartNow(itinerary))
    }

    private func begin(shift: TimeInterval, skipLateCheck: Bool = true) {
        if !skipLateCheck, phase != .normal {
            // 停掉別的行程後，這個行程的第一項已過：回到選擇畫面，不自動決定接續方式。
            return
        }
        starting = true
        errorText = nil
        let id = itineraryID
        Task { @MainActor in
            do {
                try await runner.start(itineraryID: id, startShift: shift)
                starting = false
                dismiss()
                onStarted()
            } catch let error as ItinRunError {
                starting = false
                errorText = Self.message(error, name: itinerary?.name ?? "")
            } catch {
                starting = false
                errorText = GpsItineraryRunner.firstSendFailedText
            }
        }
    }

    static func message(_ error: ItinRunError, name: String) -> String {
        switch error {
        case .notFound:
            return "找不到行程「\(name)」，此行程已刪除。"
        case .alreadyActive(let other):
            return ItinMessage.appAlreadyActive(other)
        case .allFinished:
            return "行程「\(name)」的所有項目都已結束。"
        case .firstSendFailed:
            return GpsItineraryRunner.firstSendFailedText
        case .invalid(let issue):
            // 無法儲存的錯誤（30、31、32、33、34、36）文字不含時間，時區不影響。
            return ItinMessage.text(for: issue, timeZone: .current)
        }
    }
}

// MARK: - 執行畫面

struct GpsSimItineraryRunView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var runner = GpsItineraryRunner.shared
    @ObservedObject private var mover = GpsSimRouteMover.shared
    @ObservedObject private var engine = GpsSimEngine.shared
    @State private var now = Date()
    @State private var unplugged = false
    @State private var stopping = false
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var tz: TimeZone { runner.lastRunTimeZone }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    keepOpenBar
                    if let notice = runner.notice {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(Color.white)
                            .accessibilityIdentifier("itin.run.notice")
                    }
                    if let note = ItinText.timeZoneNote(tz), runner.isActive {
                        Text(note).font(.footnote).foregroundStyle(GpsTheme.sub)
                    }
                    if runner.state == .armed {
                        armedSection
                    } else if runner.isActive {
                        currentSection
                    } else {
                        endedSection
                    }
                    if runner.isActive { timeline }
                    Text(GpsItineraryRunner.sensorDisclaimer)
                        .font(.footnote)
                        .foregroundStyle(GpsTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
            .background(GpsTheme.background.ignoresSafeArea())
            .navigationTitle(runner.activeItineraryName ?? runner.lastRunName ?? "行程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { dismiss() }
                        .accessibilityIdentifier("itin.run.close")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .dynamicTypeSize(...GpsSimHomeView.maxTypeSize)
        .onReceive(ticker) { now = $0; refreshBattery() }
        .onAppear {
            UIDevice.current.isBatteryMonitoringEnabled = true
            refreshBattery()
        }
    }

    private func refreshBattery() {
        let unplugNow = UIDevice.current.batteryState == .unplugged
        if unplugNow != unplugged { unplugged = unplugNow }
    }

    // MARK: 頂部

    private var statusWord: (String, Color) {
        switch runner.state {
        case .armed: return ("待命", GpsTheme.mint)
        case .running: return ("進行中", GpsTheme.mint)
        case .paused(.user): return ("已暫停", Color.white)
        case .paused(.connectionLost): return ("無法連線", GpsTheme.orange)
        case .paused(.deviceLocked): return ("手機已鎖定", GpsTheme.orange)
        case .finished, .cancelled, .idle: return ("已結束", GpsTheme.sub)
        }
    }

    private var header: some View {
        HStack {
            Text(runner.activeItineraryName ?? runner.lastRunName ?? "")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.white)
                .lineLimit(2)
            Spacer()
            Text(statusWord.0)
                .font(.body.weight(.semibold))
                .foregroundStyle(statusWord.1)
                .accessibilityIdentifier("itin.run.status")
        }
        .accessibilityElement(children: .combine)
    }

    private var keepOpenBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone")
                .foregroundStyle(GpsTheme.mint)
            Text(GpsItineraryRunner.keepOpenHint)
                .font(.footnote)
                .foregroundStyle(Color.white)
            Spacer(minLength: 4)
            if unplugged {
                Text("未接上電源")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(GpsTheme.orange)
            }
        }
        .padding(10)
        .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: 待命

    private var armedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let first = runner.slots.first, let e = runner.events.first {
                let left = first.start.timeIntervalSince(now)
                Text("第 1 項 \(ItinText.clock(first.start, tz)) 開始（剩 \(ItinText.countdown(left))）")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.white)
                    .accessibilityLabel("第 1 項 \(ItinText.clock(first.start, tz)) 開始")
                    .accessibilityValue("剩 \(ItinText.spokenCountdown(left))")
                    .accessibilityAddTraits(.updatesFrequently)
                Text("\(ItinText.typeLabel(e.type))　\(ItinText.place(e))")
                    .font(.footnote)
                    .foregroundStyle(GpsTheme.sub)
            }
            HStack(spacing: 8) {
                outlineButton("立即開始", id: "itin.run.startNow") { runner.startNowFromArmed() }
                filledButton("停止行程", id: "itin.run.stopItin") { runner.stopItinerary() }
            }
        }
    }

    // MARK: 進行中

    private var currentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let index = runner.currentIndex, runner.events.indices.contains(index) {
                let e = runner.events[index]
                Text("第 \(index + 1)／\(runner.events.count) 項・\(ItinText.typeLabel(e.type))")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(GpsTheme.sub)
                currentItemCard(e, index: index)
                if runner.straightFallbackIndices.contains(index) {
                    Text("第 \(index + 1) 項尚未規劃路線，已改為直線。")
                        .font(.footnote)
                        .foregroundStyle(GpsTheme.sub)
                }
                nextLine(after: index)
            }
            switch runner.state {
            case .paused(.connectionLost):
                Text("連線中斷，連上後依目前時間接續。")
                    .font(.footnote).foregroundStyle(GpsTheme.orange)
            case .paused(.deviceLocked):
                Text("手機已鎖定，解鎖後依目前時間接續。")
                    .font(.footnote).foregroundStyle(GpsTheme.orange)
            default:
                EmptyView()
            }
            if let k = runner.overdueFixedIndex, runner.slots.indices.contains(k) {
                Text("第 \(k + 1) 項的開始時間 \(ItinText.clock(runner.slots[k].start, tz)) 已到。點選「繼續」後從第 \(k + 1) 項開始。")
                    .font(.footnote)
                    .foregroundStyle(Color.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            GpsItineraryControlButtons(stopping: $stopping)
            Text("暫停期間，指定時間的項目仍依原時間開始。")
                .font(.footnote)
                .foregroundStyle(GpsTheme.sub)
        }
    }

    @ViewBuilder
    private func currentItemCard(_ e: ItinEvent, index: Int) -> some View {
        let slot = runner.slots.indices.contains(index) ? runner.slots[index] : nil
        VStack(alignment: .leading, spacing: 8) {
            switch e.type {
            case .stay:
                if let end = slot?.end {
                    Text("停留在 \(ItinText.place(e))・至 \(ItinText.clock(end, tz))（剩 \(ItinText.countdown(end.timeIntervalSince(now)))）")
                        .accessibilityValue("剩 \(ItinText.spokenCountdown(end.timeIntervalSince(now)))")
                        .accessibilityAddTraits(.updatesFrequently)
                } else {
                    Text("停留在 \(ItinText.place(e))")
                }
            case .move:
                Text("前往 \(ItinText.place(e))・\(ItinText.speedLabel(e))・\(e.moveMode == .route && !runner.straightFallbackIndices.contains(index) ? "路線" : "直線")")
                moveProgress
            case .wander:
                if let end = slot?.end {
                    Text("原地漫步 \(ItinText.place(e))・範圍 \(ItinText.sizeLabel(e.wanderRadius))・至 \(ItinText.clock(end, tz))（剩 \(ItinText.countdown(end.timeIntervalSince(now)))）")
                        .accessibilityValue("剩 \(ItinText.spokenCountdown(end.timeIntervalSince(now)))")
                        .accessibilityAddTraits(.updatesFrequently)
                } else {
                    Text("原地漫步 \(ItinText.place(e))・範圍 \(ItinText.sizeLabel(e.wanderRadius))")
                }
            case .stop:
                Text(engine.activeName == nil ? "已回到真實位置" : "停止模擬")
            }
        }
        .font(.body.monospacedDigit())
        .foregroundStyle(Color.white)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(GpsTheme.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("itin.run.current")
    }

    @ViewBuilder
    private var moveProgress: some View {
        if let plan = mover.plan, mover.wanderStartedAt == nil {
            let total = plan.totalMeters
            let left = max(0, total - mover.traveledMeters)
            let secs = mover.targetKmh > 0 ? left / (mover.targetKmh / 3.6) : 0
            ProgressView(value: total > 0 ? min(1, mover.traveledMeters / total) : 1)
                .tint(GpsTheme.blue)
                .accessibilityLabel("進度")
            HStack {
                Text("\(ItinText.distance(mover.traveledMeters))／\(ItinText.distance(total))")
                Spacer()
                Text("時速 \(Int(mover.currentKmh.rounded())) 公里")
            }
            .font(.footnote.monospacedDigit())
            .foregroundStyle(GpsTheme.sub)
            HStack {
                Text("剩餘 \(ItinText.minutes(secs))")
                Spacer()
                Text("預計 \(ItinText.clock(now.addingTimeInterval(secs), tz)) 抵達")
            }
            .font(.footnote.monospacedDigit())
            .foregroundStyle(Color.white)
        } else if mover.state == .arrived {
            Text("已抵達").font(.footnote).foregroundStyle(GpsTheme.sub)
        }
    }

    @ViewBuilder
    private func nextLine(after index: Int) -> some View {
        let next = index + 1
        if runner.events.indices.contains(next), runner.slots.indices.contains(next) {
            let start = runner.slots[next].start
            let left = start.timeIntervalSince(now)
            Text("下一項 \(ItinText.clock(start, tz)) \(ItinText.typeLabel(runner.events[next].type))（\(left > 0 ? ItinText.countdown(left) + " 後" : "即將開始")）")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(GpsTheme.sub)
                .accessibilityValue(left > 0 ? "\(ItinText.spokenCountdown(left)) 後" : "即將開始")
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    // MARK: 已結束

    private var endedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(runner.state == .finished ? GpsItineraryRunner.finishedNotice : (runner.notice ?? GpsItineraryRunner.stoppedNotice))
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.white)
            Text(engine.activeName.map { "停留在 \($0)" } ?? "已回到真實位置")
                .font(.body)
                .foregroundStyle(GpsTheme.sub)
            HStack(spacing: 8) {
                if engine.activeName != nil {
                    stopSimButton
                }
                outlineButton("關閉", id: "itin.run.done") { dismiss() }
            }
        }
    }

    private var stopSimButton: some View {
        Button {
            stopping = true
            runner.stopItineraryAndSimulation { _ in stopping = false }
        } label: {
            Text("停止模擬")
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(Color.white)
                .background(GpsTheme.stopRed, in: Capsule())
                .overlay(Capsule().stroke(GpsTheme.stopBorder, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(engine.isBusy || stopping)
        .accessibilityHint("讓手機回到真實位置")
        .accessibilityIdentifier("itin.run.stopSim")
    }

    // MARK: 時間軸

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("時間軸")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(GpsTheme.sub)
            ForEach(Array(runner.events.enumerated()), id: \.element.id) { pair in
                let i = pair.offset
                let e = pair.element
                let current = runner.currentIndex == i
                let done = (runner.currentIndex ?? -1) > i
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: done ? "checkmark.circle.fill" : ItinText.typeIcon(e))
                        .foregroundStyle(done ? GpsTheme.sub : (current ? GpsTheme.mint : Color.white))
                    Text(runner.slots.indices.contains(i) ? ItinText.clock(runner.slots[i].start, tz) : "--:--")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(GpsTheme.sub)
                    Text("\(ItinText.typeLabel(e.type))　\(ItinText.place(e))")
                        .font(.footnote.weight(current ? .semibold : .regular))
                        .foregroundStyle(current ? Color.white : GpsTheme.sub)
                        .lineLimit(2)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                .accessibilityValue(current ? "目前項目" : (done ? "已完成" : ""))
            }
        }
    }

    // MARK: 按鈕樣式

    private func outlineButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(GpsTheme.mint)
                .overlay(Capsule().stroke(GpsTheme.mint, lineWidth: 1.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func filledButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(GpsTheme.onAccent)
                .background(GpsTheme.mint, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

// MARK: - 三顆控制鈕（執行畫面與首頁進度卡共用）

struct GpsItineraryControlButtons: View {
    @Binding var stopping: Bool
    @ObservedObject private var runner = GpsItineraryRunner.shared
    @ObservedObject private var engine = GpsSimEngine.shared

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if runner.isUserPaused {
                    runner.resumeItinerary()
                } else {
                    runner.pauseItinerary()
                }
            } label: {
                Text(runner.isUserPaused ? "繼續" : "暫停")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(GpsTheme.mint)
                    .overlay(Capsule().stroke(GpsTheme.mint, lineWidth: 1.5))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(runner.state == .armed)
            .accessibilityIdentifier("itin.ctl.pause")
            Button {
                runner.stopItinerary()
            } label: {
                Text("停止行程")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(GpsTheme.onAccent)
                    .background(GpsTheme.mint, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityHint("結束行程，停留在目前位置")
            .accessibilityIdentifier("itin.ctl.stopItin")
            Button {
                stopping = true
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                runner.stopItineraryAndSimulation { _ in stopping = false }
            } label: {
                Text("停止模擬")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(Color.white)
                    .background(GpsTheme.stopRed, in: Capsule())
                    .overlay(Capsule().stroke(GpsTheme.stopBorder, lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(engine.isBusy || stopping)
            .accessibilityHint("結束行程並讓手機回到真實位置")
            .accessibilityIdentifier("itin.ctl.stopSim")
        }
    }
}

// MARK: - 設定頁「行程」區塊（規格 10.4.2）

/// 項目開始前幾分鐘通知（itinerary.notifyLeadMinutes，1～30）與「重設開始提示」
/// （清掉開始確認視窗的「不再顯示」itinerary.skipStartNotice）。
struct GpsItinerarySettingsSection: View {
    @AppStorage("itinerary.notifyLeadMinutes") private var leadMinutes = 5
    @AppStorage("itinerary.skipStartNotice") private var skipStartNotice = false
    @State private var resetDone = false

    var body: some View {
        Section {
            Stepper(value: leadBinding, in: 1...30) {
                HStack {
                    Text("項目開始前通知")
                    Spacer()
                    Text("\(leadBinding.wrappedValue) 分鐘")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("settings.itin.lead")
            Button("重設開始提示") {
                skipStartNotice = false
                resetDone = true
            }
            .disabled(!skipStartNotice)
            .frame(minHeight: 44)
            .accessibilityIdentifier("settings.itin.resetNotice")
        } header: {
            Text("行程")
        } footer: {
            Text(resetDone && !skipStartNotice
                 ? "已重設。點選「開始行程」時將再次顯示提示。"
                 : "App 不在前景時，於行程的項目開始前發出通知。點選「重設開始提示」可再次顯示開始行程時的提示。")
        }
    }

    private var leadBinding: Binding<Int> {
        Binding(
            get: { min(max(leadMinutes, 1), 30) },
            set: { leadMinutes = min(max($0, 1), 30) }
        )
    }
}

// MARK: - 首頁行程進度卡

struct GpsItineraryProgressCard: View {
    var onShow: () -> Void
    @ObservedObject private var runner = GpsItineraryRunner.shared
    @ObservedObject private var mover = GpsSimRouteMover.shared
    @State private var now = Date()
    @State private var stopping = false
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var tz: TimeZone { runner.lastRunTimeZone }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(titleLine)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isLinkIssue ? GpsTheme.orange : Color.white)
                        .lineLimit(1)
                    Text(detailLine)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(GpsTheme.sub)
                        .lineLimit(2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("itin.card.title")
                Spacer(minLength: 8)
                Button("顯示", action: onShow)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(GpsTheme.mint)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityHint("開啟行程執行畫面")
                    .accessibilityIdentifier("itin.card.show")
            }
            if runner.state == .armed {
                Button {
                    runner.stopItinerary()
                } label: {
                    Text("停止行程")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(GpsTheme.onAccent)
                        .background(GpsTheme.mint, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("itin.card.stopItin")
            } else {
                GpsItineraryControlButtons(stopping: $stopping)
            }
        }
        .padding(12)
        .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(GpsTheme.blue.opacity(0.55), lineWidth: 1))
        .onReceive(ticker) { now = $0 }
    }

    private var isLinkIssue: Bool {
        if case .paused(let reason) = runner.state { return reason != .user }
        return false
    }

    private var titleLine: String {
        let name = runner.activeItineraryName ?? ""
        if let index = runner.currentIndex {
            return "行程「\(name)」・第 \(index + 1)／\(runner.events.count) 項"
        }
        return "行程「\(name)」・待命"
    }

    private var detailLine: String {
        if runner.state == .armed, let first = runner.slots.first {
            return "第 1 項 \(ItinText.clock(first.start, tz)) 開始（剩 \(ItinText.countdown(first.start.timeIntervalSince(now)))）"
        }
        guard let index = runner.currentIndex, runner.events.indices.contains(index) else { return "" }
        let e = runner.events[index]
        let slot = runner.slots.indices.contains(index) ? runner.slots[index] : nil
        switch runner.state {
        case .paused(.user): return "已暫停・\(ItinText.typeLabel(e.type)) \(ItinText.place(e))"
        case .paused(.connectionLost): return "無法連線・連上後依目前時間接續"
        case .paused(.deviceLocked): return "手機已鎖定・解鎖後依目前時間接續"
        default: break
        }
        switch e.type {
        case .move:
            if let plan = mover.plan, mover.wanderStartedAt == nil, mover.targetKmh > 0 {
                let secs = max(0, plan.totalMeters - mover.traveledMeters) / (mover.targetKmh / 3.6)
                return "移動至 \(ItinText.place(e))・預計 \(ItinText.clock(now.addingTimeInterval(secs), tz)) 抵達"
            }
            return "移動至 \(ItinText.place(e))"
        case .stay:
            if let end = slot?.end { return "停留在 \(ItinText.place(e))・至 \(ItinText.clock(end, tz))" }
            return "停留在 \(ItinText.place(e))"
        case .wander:
            if let end = slot?.end { return "原地漫步 \(ItinText.place(e))・至 \(ItinText.clock(end, tz))" }
            return "原地漫步 \(ItinText.place(e))"
        case .stop:
            return "停止模擬"
        }
    }
}
