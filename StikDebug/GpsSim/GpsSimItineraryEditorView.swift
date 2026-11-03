//
//  GpsSimItineraryEditorView.swift
//  PinFly
//
//  【這個檔案的角色】行程編輯頁＋項目編輯＋地點選擇（規格 10.6.5～10.6.7）。
//  - GpsSimItineraryEditorView：名稱、日期模式、項目列表（時間軸預覽、拖動排序、上移／下移、
//    複製、刪除附「復原」）、驗證錯誤 30～36 與修正按鈕、底部摘要與「開始行程」。
//    「儲存」時規劃快取過期的移動項目路線（每項最多 8 秒，失敗改直線），寫入 cachedPath／routeKey，
//    再要求通知權限（規格 10.4.2：在前景、第一次儲存時）。
//  - GpsItineraryItemEditor：單一項目（開始方式、地點、各類型欄位、推算時間）。
//  - GpsItineraryPlacePicker／GpsItineraryMapPicker：選已儲存地點、上一項的終點、或從地圖選擇。
//
//  【為什麼這樣設計】
//  - 編輯的是一份草稿（@State draft），按「儲存」才寫進 GpsItineraryStore；
//    行程進行中或待命時整頁唯讀（Runner 用的是開始時讀出的副本，但仍避免使用者誤會已生效）。
//  - 固定時間與推算時間用寫法區分：「在 HH:mm」白色粗體＋時鐘圖示；推算的寫「約 14:42」（規格 10.6.2）。
//  - 項目編輯時就先規劃路線並暫存在項目上，儲存時只補規劃仍過期的項目。
//

import SwiftUI
import MapKit
import CoreLocation

struct GpsSimItineraryEditorView: View {
    let isNew: Bool
    let initialNotice: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @ObservedObject private var store = GpsItineraryStore.shared
    @ObservedObject private var runner = GpsItineraryRunner.shared
    @ObservedObject private var places = GpsPlaceStore.shared
    @ObservedObject private var network = GpsSimNetwork.shared

    @State private var draft: Itinerary
    @State private var saved: Itinerary
    @State private var everSaved: Bool
    @State private var noticeText: String?
    @State private var errorText: String?
    @State private var previewAnchor = Date()
    @State private var itemRequest: GpsItinItemRequest?
    @State private var showDiscard = false
    @State private var planning: GpsItinPlanningStep?
    @State private var planQuery: GpsSimRouteQuery?
    /// 儲存時路線規劃失敗、改為直線的項目 id。
    @State private var straightIDs: Set<String> = []
    @State private var notificationsDenied = false
    @State private var startRequest: GpsItineraryStartRequest?
    @State private var showRun = false
    @State private var removed: GpsItinRemovedItem?

    init(itinerary: Itinerary, isNew: Bool, initialNotice: String?) {
        self.isNew = isNew
        self.initialNotice = initialNotice
        _draft = State(initialValue: itinerary)
        _saved = State(initialValue: itinerary)
        _everSaved = State(initialValue: !isNew)
        _noticeText = State(initialValue: initialNotice)
    }

    private var readOnly: Bool { runner.isActive && runner.activeItineraryID == draft.id }
    private var dirty: Bool { !everSaved || draft != saved }
    private var tz: TimeZone { draft.timeZone }

    /// 每一列都會讀 slots／issues（時間、等候、VoiceOver、錯誤）：同一份 draft＋anchor 只算一次。
    @State private var computed = GpsItinEditorCache()

    private var slots: [ItinSlot] {
        if readOnly, runner.slots.count == draft.events.count { return runner.slots }
        return computed.plannedSlots(for: draft, anchor: previewAnchor)
    }

    private var issues: [ItinIssue] { computed.issues(for: draft, anchor: previewAnchor) }

    var body: some View {
        List {
            if readOnly { readOnlySection }
            if let noticeText {
                Section {
                    Text(noticeText)
                        .font(.footnote)
                        .foregroundStyle(Color.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .listRowBackground(GpsTheme.card)
            }
            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(GpsTheme.dangerText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .listRowBackground(GpsTheme.card)
            }
            headerSection
            itemsSection
            summarySection
        }
        .scrollContentBackground(.hidden)
        .background(GpsTheme.background.ignoresSafeArea())
        .navigationTitle(draft.name.isEmpty ? "行程" : draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar { toolbarContent }
        .disabled(planning != nil)
        .overlay { if let planning { planningOverlay(planning) } }
        .safeAreaInset(edge: .bottom) { if let removed { undoBar(removed) } }
        .confirmationDialog("放棄變更？", isPresented: $showDiscard, titleVisibility: .hidden) {
            Button("放棄變更", role: .destructive) { dismiss() }
            Button("繼續編輯", role: .cancel) {}
        }
        .sheet(item: $itemRequest) { request in
            GpsItineraryItemEditor(request: request, timeZone: tz, dateMode: draft.dateMode,
                                   previewSlot: { previewSlot(for: $0, request: request) }) { event in
                commitItem(event, request: request)
            }
            .preferredColorScheme(.dark)
        }
        .sheet(item: $startRequest) { request in
            GpsItineraryStartSheet(itineraryID: request.itineraryID) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showRun = true }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showRun) {
            GpsSimItineraryRunView().preferredColorScheme(.dark)
        }
        .onChange(of: draft.dateMode) { _, mode in
            if mode == .fixed { rebaseFixedDates(onto: Date()) }
        }
        .task {
            previewAnchor = Date()
            if everSaved { notificationsDenied = await GpsItineraryRunner.notificationsDenied() }
        }
    }

    // MARK: 工具列

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(readOnly ? "關閉" : "取消") {
                if dirty && !readOnly && !(isNew && draft.events.isEmpty) {
                    showDiscard = true
                } else {
                    dismiss()
                }
            }
            .accessibilityIdentifier("itin.edit.cancel")
        }
        if !readOnly {
            ToolbarItem(placement: .confirmationAction) {
                Button("儲存") { save(thenStart: false) }
                    .accessibilityIdentifier("itin.edit.save")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        Task { @MainActor in await planRoutes(force: true) }
                    } label: {
                        Label("重新規劃路線", systemImage: "arrow.triangle.turn.up.right.diamond")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("更多")
            }
        }
    }

    // MARK: 區段

    private var readOnlySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("行程進行中，無法編輯。請先停止行程。")
                    .font(.body)
                    .foregroundStyle(Color.white)
                Button("停止行程") { runner.stopItinerary() }
                    .buttonStyle(.borderless)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(GpsTheme.mint)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("itin.edit.stopItin")
            }
        }
        .listRowBackground(GpsTheme.card)
    }

    private var headerSection: some View {
        Section {
            HStack {
                Text("名稱").foregroundStyle(Color.white)
                TextField("行程名稱", text: $draft.name)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(Color.white)
                    .accessibilityIdentifier("itin.edit.name")
            }
            Picker("日期", selection: $draft.dateMode) {
                Text("開始當天").tag(ItinDateMode.today)
                Text("指定日期").tag(ItinDateMode.fixed)
            }
            .foregroundStyle(Color.white)
            if draft.dateMode == .fixed {
                DatePicker("指定日期", selection: fixedDateBinding, displayedComponents: .date)
                    .environment(\.timeZone, tz)
                    .foregroundStyle(Color.white)
            } else {
                Text("開始當天：時間套用在點選「開始行程」或捷徑執行的那一天。")
                    .font(.footnote)
                    .foregroundStyle(GpsTheme.sub)
            }
            if let note = ItinText.timeZoneNote(tz) {
                Text(note).font(.footnote).foregroundStyle(GpsTheme.sub)
            }
        }
        .disabled(readOnly)
        .listRowBackground(GpsTheme.card)
    }

    private var itemsSection: some View {
        Section {
            if draft.events.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("新增第一個項目。第一項需為停留或原地漫步，用來決定起點。")
                        .font(.footnote)
                        .foregroundStyle(GpsTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("新增停留項目") { openNewItem(.stay, at: 0) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(GpsTheme.mint)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("itin.edit.addFirstStay")
                }
            }
            ForEach(Array(draft.events.enumerated()), id: \.element.id) { pair in
                itemRow(pair.offset)
            }
            .onMove(perform: readOnly ? nil : moveRows)
            .onDelete(perform: readOnly ? nil : deleteRows)
            if !readOnly { addMenu }
        }
        .listRowBackground(GpsTheme.card)
    }

    private var addMenu: some View {
        let full = draft.events.count >= ItinSchedule.maxEvents
        return VStack(alignment: .leading, spacing: 6) {
            Menu {
                Button { openNewItem(.stay, at: draft.events.count) } label: { Label("停留", systemImage: "mappin.circle") }
                    .accessibilityIdentifier("itin.add.stay")
                Button { openNewItem(.move, at: draft.events.count) } label: {
                    Label("移動", systemImage: "arrow.triangle.turn.up.right.circle")
                }
                .accessibilityIdentifier("itin.add.move")
                Button { openNewItem(.wander, at: draft.events.count) } label: { Label("原地漫步", systemImage: "figure.walk.circle") }
                    .accessibilityIdentifier("itin.add.wander")
                Button { openNewItem(.stop, at: draft.events.count) } label: { Label("停止模擬", systemImage: "location.slash.circle") }
                    .accessibilityIdentifier("itin.add.stop")
            } label: {
                Label("新增項目", systemImage: "plus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(full ? GpsTheme.sub : GpsTheme.mint)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .disabled(full)
            .accessibilityIdentifier("itin.edit.addItem")
            if full {
                issueLabel("行程最多 \(ItinSchedule.maxEvents) 個項目。請刪除項目或另建行程。（錯誤 31）")
            }
        }
    }

    private var summarySection: some View {
        Section {
            Text(summaryText)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(GpsTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(issues.enumerated()), id: \.offset) { pair in
                if pair.element.eventIndex == nil, pair.element.code != 31 {
                    issueLabel(ItinMessage.text(for: pair.element, timeZone: tz))
                }
            }
            if !readOnly {
                Button {
                    startTapped()
                } label: {
                    Text(dirty ? "儲存並開始" : "開始行程")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(GpsTheme.onAccent)
                        .background(canStart ? GpsTheme.mint : GpsTheme.sub, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.borderless)
                .disabled(!canStart)
                .accessibilityIdentifier("itin.edit.start")
            }
            if notificationsDenied {
                Text("通知已關閉，行程無法在項目開始前提醒。可至「設定 › 通知 › PinFly」開啟。")
                    .font(.footnote)
                    .foregroundStyle(GpsTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .listRowBackground(GpsTheme.card)
    }

    private var canStart: Bool {
        !draft.events.isEmpty && !issues.contains { $0.severity == .blocking }
    }

    /// 「共 4 個項目・14:00～約 15:50・移動 4.1 公里」。
    private var summaryText: String {
        guard !draft.events.isEmpty else { return "共 0 個項目" }
        var parts = ["共 \(draft.events.count) 個項目"]
        let s = slots
        if let first = s.first, let last = s.last {
            let firstText = draft.events[0].startRule.kind == .at ? clockText(first.start) : "開始時"
            if let end = last.end {
                parts.append("\(firstText)～約 \(clockText(end))")
            } else {
                parts.append("\(firstText) 起")
            }
        }
        let meters = Self.totalMoveMeters(draft.events)
        if meters > 0 { parts.append("移動 \(ItinText.distance(meters))") }
        return parts.joined(separator: "・")
    }

    // MARK: 項目列

    @ViewBuilder
    private func itemRow(_ i: Int) -> some View {
        if draft.events.indices.contains(i) {
            let e = draft.events[i]
            VStack(alignment: .leading, spacing: 6) {
                if let gap = gapBefore(i) {
                    HStack(spacing: 6) {
                        Image(systemName: "ellipsis")
                            .accessibilityHidden(true)
                        Text("等候 \(ItinText.minutes(gap))")
                    }
                    .font(.footnote)
                    .foregroundStyle(GpsTheme.sub)
                    .accessibilityElement(children: .combine)
                }
                Button {
                    guard !readOnly else { return }
                    clearTransient()
                    itemRequest = GpsItinItemRequest(index: i, event: e, isNew: false, context: context(for: i, isNew: false))
                } label: {
                    rowContent(e, index: i)
                }
                .buttonStyle(.borderless)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spokenRow(e, index: i))
                .accessibilityAction(named: "上移") { moveItem(i, by: -1) }
                .accessibilityAction(named: "下移") { moveItem(i, by: 1) }
                .accessibilityIdentifier("itin.edit.row")
                ForEach(rowNotes(e, index: i), id: \.self) { note in
                    Text(note).font(.footnote).foregroundStyle(GpsTheme.sub)
                }
                ForEach(Array(issues.enumerated()), id: \.offset) { pair in
                    if pair.element.eventIndex == i {
                        issueView(pair.element)
                    }
                }
            }
            .padding(.vertical, 2)
            .contextMenu {
                if !readOnly {
                    Button {
                        itemRequest = GpsItinItemRequest(index: i, event: e, isNew: false, context: context(for: i, isNew: false))
                    } label: { Label("編輯", systemImage: "pencil") }
                    Button { moveItem(i, by: -1) } label: { Label("上移", systemImage: "arrow.up") }
                        .disabled(i == 0)
                        .accessibilityIdentifier("itin.row.moveUp")
                    Button { moveItem(i, by: 1) } label: { Label("下移", systemImage: "arrow.down") }
                        .disabled(i >= draft.events.count - 1)
                        .accessibilityIdentifier("itin.row.moveDown")
                    Button { duplicateItem(i) } label: { Label("複製項目", systemImage: "plus.square.on.square") }
                        .disabled(draft.events.count >= ItinSchedule.maxEvents)
                    Button(role: .destructive) { removeItem(at: i) } label: { Label("刪除項目", systemImage: "trash") }
                }
            }
        }
    }

    @ViewBuilder
    private func rowContent(_ e: ItinEvent, index i: Int) -> some View {
        let current = readOnly && runner.currentIndex == i
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                timeLabel(index: i)
                summaryLine(e, index: i, current: current)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                timeLabel(index: i)
                    .frame(minWidth: 72, alignment: .leading)
                summaryLine(e, index: i, current: current)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
    }

    private func summaryLine(_ e: ItinEvent, index i: Int, current: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: ItinText.typeIcon(e))
                .foregroundStyle(current ? GpsTheme.mint : Color.white)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(ItinText.typeLabel(e.type))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.white)
                let detail = rowDetail(e, index: i)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(GpsTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func timeLabel(index i: Int) -> some View {
        let e = draft.events[i]
        let s = slots
        if i == 0 && e.startRule.kind == .afterPrevious {
            Text("開始時")
                .font(.footnote)
                .foregroundStyle(GpsTheme.sub)
        } else if s.indices.contains(i) {
            if e.startRule.kind == .at {
                HStack(spacing: 3) {
                    Text(clockText(s[i].start))
                        .font(.body.weight(.bold).monospacedDigit())
                        .foregroundStyle(Color.white)
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(Color.white)
                        .accessibilityHidden(true)
                }
            } else {
                Text("約 \(clockText(s[i].start))")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(GpsTheme.sub)
            }
        }
    }

    /// 停留「台北101・直到下一項」、移動「中正紀念堂・步行・路線 4.1 公里」、漫步「中正紀念堂・範圍 中・30 分」。
    private func rowDetail(_ e: ItinEvent, index i: Int) -> String {
        let place = ItinText.place(e)
        switch e.type {
        case .stay:
            let time = e.minutes.map { ItinText.minutes(TimeInterval($0) * 60) } ?? "直到下一項"
            return place.isEmpty ? time : "\(place)・\(time)"
        case .move:
            var parts: [String] = []
            if !place.isEmpty { parts.append(place) }
            parts.append(ItinText.speedLabel(e))
            let origin = ItinSchedule.origins(of: draft.events)[i]
            if let meters = Self.moveMeters(e, origin: origin) {
                if e.moveMode == .straight {
                    parts.append("直線 \(ItinText.distance(meters))")
                } else if straightIDs.contains(e.id) {
                    parts.append("已改為直線 \(ItinText.distance(meters))")
                } else if e.hasValidCachedPath(from: origin) {
                    parts.append("路線 \(ItinText.distance(meters))")
                } else {
                    parts.append("直線估算 \(ItinText.distance(meters))")
                }
                let mps = e.effectiveKmh / 3.6
                if mps > 0 { parts.append("約 \(ItinText.minutes(meters / mps))") }
            }
            return parts.joined(separator: "・")
        case .wander:
            var parts: [String] = []
            if !place.isEmpty { parts.append(place) }
            parts.append("範圍 \(ItinText.sizeLabel(e.wanderRadius))")
            if let m = e.minutes { parts.append(ItinText.minutes(TimeInterval(m) * 60)) }
            return parts.joined(separator: "・")
        case .stop:
            return ""
        }
    }

    /// 非錯誤的提示：起點與終點相同、地點已刪除。
    private func rowNotes(_ e: ItinEvent, index i: Int) -> [String] {
        var notes: [String] = []
        if e.type == .move, let origin = ItinSchedule.origins(of: draft.events)[i], let dest = e.coord,
           GpsGeo.meters(origin.clCoordinate, dest.clCoordinate) <= 5 {
            notes.append("起點與終點相同，此項目不會移動。")
        }
        if let id = e.placeID, !places.places.contains(where: { $0.id == id }) {
            notes.append("地點「\(e.placeName ?? "")」已刪除，此項目使用儲存時的位置。")
        }
        return notes
    }

    /// VoiceOver：「第 2 項，移動，在 14:30 開始，步行沿路線前往 中正紀念堂，4.1 公里，約 50 分鐘」。
    private func spokenRow(_ e: ItinEvent, index i: Int) -> String {
        var parts = ["第 \(i + 1) 項", ItinText.typeLabel(e.type)]
        let s = slots
        if i == 0 && e.startRule.kind == .afterPrevious {
            parts.append("開始行程時開始")
        } else if s.indices.contains(i) {
            parts.append(e.startRule.kind == .at ? "在 \(clockText(s[i].start)) 開始" : "約 \(clockText(s[i].start)) 開始")
        }
        let detail = rowDetail(e, index: i)
        if !detail.isEmpty { parts.append(detail.replacingOccurrences(of: "・", with: "，")) }
        if let gap = gapBefore(i) { parts.insert("等候 \(ItinText.minutes(gap))", at: 0) }
        return parts.joined(separator: "，")
    }

    /// 上一項結束到本項開始的空檔（≥ 1 分鐘才顯示）。
    private func gapBefore(_ i: Int) -> TimeInterval? {
        let s = slots
        guard i > 0, s.indices.contains(i), let end = s[i - 1].end else { return nil }
        let gap = s[i].start.timeIntervalSince(end)
        return gap >= 60 ? gap : nil
    }

    // MARK: 錯誤與修正

    private func issueLabel(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(GpsTheme.dangerText)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func issueView(_ issue: ItinIssue) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            issueLabel(ItinMessage.text(for: issue, timeZone: tz))
            if !readOnly, let fix = fixAction(issue) {
                Button(fix.title) {
                    clearTransient()
                    fix.run()
                }
                .buttonStyle(.borderless)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(GpsTheme.mint)
                .frame(minHeight: 44)
                .accessibilityIdentifier("itin.fix.\(issue.code)")
            }
        }
    }

    private struct FixAction {
        let title: String
        let run: () -> Void
    }

    private func fixAction(_ issue: ItinIssue) -> FixAction? {
        guard let i = issue.eventIndex, draft.events.indices.contains(i) else { return nil }
        switch issue.code {
        case 30:
            return FixAction(title: "新增停留項目") { openNewItem(.stay, at: 0) }
        case 32:
            let e = draft.events[i]
            guard e.speedPreset != .drive || e.customKmh != nil else { return nil }
            var trial = draft
            trial.events[i].speedPreset = .drive
            trial.events[i].customKmh = nil
            let stillOver = ItinSchedule.validate(trial, anchor: previewAnchor).contains { $0.code == 32 && $0.eventIndex == i }
            guard !stillOver else { return nil }
            return FixAction(title: "改為駕車") {
                draft.events[i].speedPreset = .drive
                draft.events[i].customKmh = nil
            }
        case 34:
            let e = draft.events[i]
            guard e.type == .stay || e.type == .wander else { return nil }
            let target = Self.roundUp5(issue.suggestedDate ?? slots[i].start)
            return FixAction(title: "改為在 \(clockText(target)) 開始") {
                draft.events[i].startRule = ItinStartRule(kind: .at, at: target)
            }
        case 35:
            guard let m = issue.relatedIndex, draft.events.indices.contains(m), let arrive = issue.suggestedDate else { return nil }
            let target = Self.roundUp5(arrive)
            return FixAction(title: "延後第 \(m + 1) 項至 \(clockText(target))") {
                draft.events[m].startRule = ItinStartRule(kind: .at, at: target)
            }
        case 36:
            guard let suggested = issue.suggestedDate else { return nil }
            let target = Self.roundUp5(suggested)
            return FixAction(title: "改為 \(clockText(target))") {
                draft.events[i].startRule = ItinStartRule(kind: .at, at: target)
            }
        default:
            return nil
        }
    }

    // MARK: 項目操作

    private func clearTransient() {
        removed = nil
        errorText = nil
    }

    private func moveRows(from source: IndexSet, to destination: Int) {
        clearTransient()
        draft.events.move(fromOffsets: source, toOffset: destination)
    }

    private func deleteRows(_ offsets: IndexSet) {
        if let i = offsets.first { removeItem(at: i) }
    }

    private func moveItem(_ i: Int, by step: Int) {
        let j = i + step
        guard !readOnly, draft.events.indices.contains(i), draft.events.indices.contains(j) else { return }
        clearTransient()
        draft.events.swapAt(i, j)
    }

    private func duplicateItem(_ i: Int) {
        guard draft.events.indices.contains(i), draft.events.count < ItinSchedule.maxEvents else { return }
        clearTransient()
        var copy = draft.events[i]
        copy.id = UUID().uuidString
        draft.events.insert(copy, at: i + 1)
    }

    private func removeItem(at i: Int) {
        guard !readOnly, draft.events.indices.contains(i) else { return }
        errorText = nil
        removed = GpsItinRemovedItem(event: draft.events[i], index: i)
        draft.events.remove(at: i)
    }

    private func undoBar(_ item: GpsItinRemovedItem) -> some View {
        HStack {
            Text("已刪除第 \(item.index + 1) 項。")
                .font(.footnote)
                .foregroundStyle(Color.white)
            Spacer()
            Button("復原") {
                let at = min(item.index, draft.events.count)
                draft.events.insert(item.event, at: at)
                removed = nil
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(GpsTheme.mint)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityIdentifier("itin.edit.undo")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func openNewItem(_ type: ItinEventType, at index: Int) {
        guard !readOnly, draft.events.count < ItinSchedule.maxEvents else { return }
        clearTransient()
        let at = min(max(0, index), draft.events.count)
        let ctx = context(for: at, isNew: true)
        var e = ItinEvent(type: type)
        switch type {
        case .stay:
            e.placeID = ctx.previousEnd?.placeID
            e.placeName = ctx.previousEnd?.name
            e.coord = ctx.previousEnd?.coord
            e.minutes = 30
        case .wander:
            e.placeID = ctx.previousEnd?.placeID
            e.placeName = ctx.previousEnd?.name
            e.coord = ctx.previousEnd?.coord
            e.wanderRadius = .medium
            e.minutes = 30
        case .move:
            e.moveMode = .route
            e.speedPreset = .walk
        case .stop:
            break
        }
        // 「停止模擬」之後只能接在指定時間開始的項目（規格 10.1）。
        if at > 0, draft.events[at - 1].type == .stop {
            e.startRule = ItinStartRule(kind: .at, at: Self.roundUp5(ctx.defaultAt))
        }
        itemRequest = GpsItinItemRequest(index: at, event: e, isNew: true, context: ctx)
    }

    private func commitItem(_ event: ItinEvent, request: GpsItinItemRequest) {
        var e = event
        e.minutes = ItinSchedule.clampedMinutes(e.minutes, for: e.type)
        if request.isNew {
            let at = min(request.index, draft.events.count)
            draft.events.insert(e, at: at)
        } else if let i = draft.events.firstIndex(where: { $0.id == e.id }) {
            draft.events[i] = e
        }
        straightIDs.remove(e.id)
    }

    /// 項目編輯需要的前後文：上一項的終點、下一項的開始方式、預設時間。
    private func context(for index: Int, isNew: Bool) -> GpsItinItemContext {
        let events = draft.events
        let ends = ItinSchedule.endpoints(of: events)
        var previous: GpsItinEndpoint?
        if index > 0, ends.indices.contains(index - 1), let c = ends[index - 1] {
            var name: String?
            var placeID: String?
            for k in stride(from: index - 1, through: 0, by: -1) {
                let ev = events[k]
                if ev.type == .stop { break }
                if ev.coord != nil {
                    name = ev.placeName
                    placeID = ev.placeID
                    break
                }
            }
            previous = GpsItinEndpoint(name: name ?? "上一項的終點", placeID: placeID, coord: c)
        }
        let nextIndex = isNew ? index : index + 1
        let nextKind: ItinStartRule.Kind? = events.indices.contains(nextIndex) ? events[nextIndex].startRule.kind : nil
        let s = slots
        var defaultAt = Date()
        if index > 0, s.indices.contains(index - 1) {
            defaultAt = s[index - 1].end ?? s[index - 1].start
        }
        return GpsItinItemContext(isFirst: index == 0, previousEnd: previous, nextKind: nextKind,
                                  defaultAt: Self.roundUp5(defaultAt))
    }

    /// 項目編輯底部「約 14:30 開始，約 14:58 抵達」：把編輯中的項目放進行程再算一次。
    private func previewSlot(for event: ItinEvent, request: GpsItinItemRequest) -> ItinSlot? {
        var trial = draft
        let index: Int
        if request.isNew {
            index = min(request.index, trial.events.count)
            trial.events.insert(event, at: index)
        } else if let i = trial.events.firstIndex(where: { $0.id == event.id }) {
            index = i
            trial.events[i] = event
        } else {
            return nil
        }
        let s = GpsItineraryRunner.plannedSlots(for: trial, anchor: previewAnchor)
        return s.indices.contains(index) ? s[index] : nil
    }

    // MARK: 日期

    private var fixedDateBinding: Binding<Date> {
        Binding(
            get: { draft.events.first(where: { $0.startRule.kind == .at })?.startRule.at ?? Date() },
            set: { rebaseFixedDates(onto: $0) }
        )
    }

    /// 指定日期：把所有「在指定時間」的日期整串移到新日期（維持各項之間的天數差與時分）。
    private func rebaseFixedDates(onto day: Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        guard let firstAt = draft.events.first(where: { $0.startRule.kind == .at })?.startRule.at else { return }
        let from = cal.startOfDay(for: firstAt)
        let to = cal.startOfDay(for: day)
        let days = cal.dateComponents([.day], from: from, to: to).day ?? 0
        guard days != 0 else { return }
        for i in draft.events.indices {
            guard draft.events[i].startRule.kind == .at, let at = draft.events[i].startRule.at else { continue }
            draft.events[i].startRule.at = cal.date(byAdding: .day, value: days, to: at) ?? at
        }
    }

    private func clockText(_ date: Date) -> String {
        if draft.dateMode == .today {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz
            let anchor = slots.first?.start ?? previewAnchor
            let hm = GpsItineraryRunner.timeText(date, timeZone: tz, now: date)
            return cal.isDate(date, inSameDayAs: anchor) ? hm : "隔天 \(hm)"
        }
        return GpsItineraryRunner.timeText(date, timeZone: tz, now: previewAnchor)
    }

    static func roundUp5(_ date: Date) -> Date {
        let step: TimeInterval = 300
        let t = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (t / step).rounded(.up) * step)
    }

    // MARK: 距離

    static func moveMeters(_ e: ItinEvent, origin: ItinCoord?) -> Double? {
        guard e.type == .move, let origin, let dest = e.coord else { return nil }
        if e.hasValidCachedPath(from: origin), let path = e.cachedPath {
            return ItinSchedule.pathMeters(path)
        }
        return GpsGeo.meters(origin.clCoordinate, dest.clCoordinate)
    }

    static func totalMoveMeters(_ events: [ItinEvent]) -> Double {
        let origins = ItinSchedule.origins(of: events)
        var total = 0.0
        for i in events.indices {
            total += moveMeters(events[i], origin: origins[i]) ?? 0
        }
        return total
    }

    // MARK: 儲存、開始

    private func startTapped() {
        clearTransient()
        if dirty {
            save(thenStart: true)
        } else {
            startRequest = GpsItineraryStartRequest(itineraryID: draft.id)
        }
    }

    private func save(thenStart: Bool) {
        clearTransient()
        previewAnchor = Date()
        if let blocking = issues.first(where: { $0.severity == .blocking }) {
            errorText = ItinMessage.text(for: blocking, timeZone: tz)
            return
        }
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.name = trimmed.isEmpty ? "新行程" : trimmed
        Task { @MainActor in
            await planRoutes(force: false)
            // 路線規劃後距離可能比直線長很多：重新驗證，才擋得到 32（移動 > 12 小時）、33（總長 > 24 小時）。
            if let blocking = ItinSchedule.validate(draft, anchor: previewAnchor)
                .first(where: { $0.severity == .blocking }) {
                errorText = ItinMessage.text(for: blocking, timeZone: tz)
                return
            }
            store.upsert(draft)
            saved = draft
            everSaved = true
            _ = await GpsItineraryRunner.requestNotificationPermissionIfNeeded()
            notificationsDenied = await GpsItineraryRunner.notificationsDenied()
            if thenStart {
                startRequest = GpsItineraryStartRequest(itineraryID: draft.id)
            } else {
                dismiss()
            }
        }
    }

    /// 規劃快取過期（force＝全部）的路線移動項目；每項最多 8 秒，失敗改直線並標示。
    private func planRoutes(force: Bool) async {
        let origins = ItinSchedule.origins(of: draft.events)
        let todo = draft.events.indices.filter { i in
            let e = draft.events[i]
            guard e.type == .move, e.moveMode == .route, origins[i] != nil, e.coord != nil else { return false }
            return force || !e.hasValidCachedPath(from: origins[i])
        }
        guard !todo.isEmpty else { return }
        guard network.hasNetwork else {
            for i in todo { straightIDs.insert(draft.events[i].id) }
            noticeText = "無法規劃路線，路線項目暫時以直線計算。連上網路後點選「重新規劃路線」。"
            return
        }
        for (n, i) in todo.enumerated() {
            guard draft.events.indices.contains(i), let origin = origins[i], let dest = draft.events[i].coord else { continue }
            let e = draft.events[i]
            let query = GpsSimRouteQuery()
            planQuery = query
            planning = GpsItinPlanningStep(step: n + 1, total: todo.count, name: ItinText.place(e), startedAt: Date())
            let plan = await GpsSimRoutePlanner.plan(from: origin.clCoordinate, to: dest.clCoordinate,
                                                     mode: .route, speed: e.speedPreset, query: query)
            guard draft.events.indices.contains(i), draft.events[i].id == e.id else { continue }
            if plan.fellBackToStraight || plan.path.count < 2 {
                draft.events[i].cachedPath = nil
                draft.events[i].routeKey = nil
                straightIDs.insert(e.id)
            } else {
                draft.events[i].cachedPath = plan.path.map { ItinCoord($0) }
                draft.events[i].routeKey = draft.events[i].expectedRouteKey(from: origin)
                straightIDs.remove(e.id)
            }
        }
        planning = nil
        planQuery = nil
    }

    private func planningOverlay(_ step: GpsItinPlanningStep) -> some View {
        VStack(spacing: 12) {
            ProgressView().tint(GpsTheme.mint)
            Text("規劃路線 \(step.step)／\(step.total)：\(step.name)…")
                .font(.body)
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.center)
            TimelineView(.periodic(from: step.startedAt, by: 1)) { ctx in
                Text("已用 \(max(0, Int(ctx.date.timeIntervalSince(step.startedAt)))) 秒")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(GpsTheme.sub)
            }
            Button("略過，改為直線") { planQuery?.cancel() }
                .font(.body.weight(.semibold))
                .foregroundStyle(GpsTheme.mint)
                .frame(minHeight: 44)
                .accessibilityIdentifier("itin.edit.skipRoute")
        }
        .padding(20)
        .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(32)
        // 整頁 disabled 時仍要能按「略過」。
        .disabled(false)
    }
}

// MARK: - 編輯頁的小型別

struct GpsItinPlanningStep: Equatable {
    var step: Int
    var total: Int
    var name: String
    var startedAt: Date
}

struct GpsItinRemovedItem: Equatable {
    var event: ItinEvent
    var index: Int
}

struct GpsItinEndpoint: Equatable {
    var name: String
    var placeID: String?
    var coord: ItinCoord
}

struct GpsItinItemContext: Equatable {
    var isFirst: Bool
    var previousEnd: GpsItinEndpoint?
    /// 下一項的開始方式（nil＝本項是最後一項）；決定停留能不能選「直到下一項」。
    var nextKind: ItinStartRule.Kind?
    var defaultAt: Date
}

struct GpsItinItemRequest: Identifiable {
    let id = UUID()
    var index: Int
    var event: ItinEvent
    var isNew: Bool
    var context: GpsItinItemContext
}

// MARK: - 項目編輯

private enum GpsItinItemRoute: Hashable {
    case place
    case map
}

/// 速度選項：三個預設＋自訂。
private enum GpsItinSpeedChoice: Hashable {
    case preset(MoveSpeedPreset)
    case custom
}

struct GpsItineraryItemEditor: View {
    let request: GpsItinItemRequest
    let timeZone: TimeZone
    let dateMode: ItinDateMode
    let previewSlot: (ItinEvent) -> ItinSlot?
    let onCommit: (ItinEvent) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var event: ItinEvent
    @State private var navPath: [GpsItinItemRoute] = []
    @State private var routeInfo: String?
    @State private var minutesText = ""

    init(request: GpsItinItemRequest, timeZone: TimeZone, dateMode: ItinDateMode,
         previewSlot: @escaping (ItinEvent) -> ItinSlot?, onCommit: @escaping (ItinEvent) -> Void) {
        self.request = request
        self.timeZone = timeZone
        self.dateMode = dateMode
        self.previewSlot = previewSlot
        self.onCommit = onCommit
        _event = State(initialValue: request.event)
    }

    private var ctx: GpsItinItemContext { request.context }

    private var untilNextAllowed: Bool { ctx.nextKind == nil || ctx.nextKind == .at }

    private var canCommit: Bool {
        switch event.type {
        case .stop: return true
        case .stay: return event.coord != nil && (event.minutes != nil || untilNextAllowed)
        case .wander: return event.coord != nil && event.minutes != nil
        case .move: return event.coord != nil
        }
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            Form {
                startSection
                if event.type != .stop { placeSection }
                typeSection
                Section {
                    Text(estimateText)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(GpsTheme.sub)
                }
                .listRowBackground(GpsTheme.card)
            }
            .scrollContentBackground(.hidden)
            .background(GpsTheme.background.ignoresSafeArea())
            .navigationTitle(ItinText.typeLabel(event.type))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .accessibilityIdentifier("itin.item.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(request.isNew ? "新增" : "儲存") {
                        onCommit(event)
                        dismiss()
                    }
                    .disabled(!canCommit)
                    .accessibilityIdentifier("itin.item.commit")
                }
            }
            .navigationDestination(for: GpsItinItemRoute.self) { route in
                switch route {
                case .place:
                    GpsItineraryPlacePicker(previousEnd: ctx.previousEnd,
                                            onMap: { navPath.append(.map) },
                                            onPick: { pick($0, $1, $2) })
                case .map:
                    GpsItineraryMapPicker(initial: event.coord?.clCoordinate ?? ctx.previousEnd?.coord.clCoordinate) { name, coord in
                        pick(nil, name, coord)
                    }
                }
            }
        }
        .presentationDetents([.large])
        .dynamicTypeSize(...GpsSimHomeView.maxTypeSize)
        .onAppear {
            if let m = event.minutes { minutesText = String(m) }
        }
        .task(id: routeTaskKey) { await refreshRoute() }
    }

    private func pick(_ placeID: String?, _ name: String, _ coord: ItinCoord) {
        event.placeID = placeID
        event.placeName = name
        event.coord = coord
        navPath = []
    }

    // MARK: 開始

    private var startSection: some View {
        Section("開始") {
            Picker("開始", selection: kindBinding) {
                if ctx.isFirst {
                    Text("開始行程時").accessibilityIdentifier("itin.time.after").tag(ItinStartRule.Kind.afterPrevious)
                    Text("在指定時間").accessibilityIdentifier("itin.time.fixed").tag(ItinStartRule.Kind.at)
                } else {
                    Text("在指定時間").accessibilityIdentifier("itin.time.fixed").tag(ItinStartRule.Kind.at)
                    Text("接續上一項").accessibilityIdentifier("itin.time.after").tag(ItinStartRule.Kind.afterPrevious)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("itin.item.startKind")
            if event.startRule.kind == .at {
                DatePicker("時間", selection: atBinding, displayedComponents: timeComponents)
                    .datePickerStyle(.compact)
                    .environment(\.timeZone, timeZone)
                    .foregroundStyle(Color.white)
                    .accessibilityIdentifier("itin.item.time")
            }
            if event.type == .stop {
                Text("回到真實位置。下一項需在指定時間開始。")
                    .font(.footnote)
                    .foregroundStyle(GpsTheme.sub)
            }
        }
        .listRowBackground(GpsTheme.card)
    }

    private var timeComponents: DatePickerComponents {
        dateMode == .fixed ? [.date, .hourAndMinute] : .hourAndMinute
    }

    private var kindBinding: Binding<ItinStartRule.Kind> {
        Binding(
            get: { event.startRule.kind },
            set: { kind in
                if kind == .at {
                    event.startRule = ItinStartRule(kind: .at, at: event.startRule.at ?? ctx.defaultAt)
                } else {
                    event.startRule = ItinStartRule(kind: .afterPrevious, at: nil)
                }
            }
        )
    }

    private var atBinding: Binding<Date> {
        Binding(
            get: { event.startRule.at ?? ctx.defaultAt },
            set: { event.startRule = ItinStartRule(kind: .at, at: $0) }
        )
    }

    // MARK: 地點

    private var placeSection: some View {
        Section {
            NavigationLink(value: GpsItinItemRoute.place) {
                HStack {
                    Text(event.type == .move ? "目的地" : "地點")
                        .foregroundStyle(Color.white)
                    Spacer()
                    Text(event.coord == nil ? "選擇地點" : ItinText.place(event))
                        .foregroundStyle(event.coord == nil ? GpsTheme.mint : GpsTheme.sub)
                        .lineLimit(1)
                }
            }
            .accessibilityIdentifier("itin.item.place")
        }
        .listRowBackground(GpsTheme.card)
    }

    // MARK: 類型欄位

    @ViewBuilder
    private var typeSection: some View {
        switch event.type {
        case .stay:
            Section("停留時間") {
                if untilNextAllowed {
                    Picker("停留時間", selection: stayUntilNextBinding) {
                        Text("直到下一項").tag(true)
                        Text("指定時間長度").tag(false)
                    }
                    .pickerStyle(.segmented)
                } else {
                    Text("下一項為「接續上一項」，請指定停留時間。")
                        .font(.footnote)
                        .foregroundStyle(GpsTheme.sub)
                }
                if event.minutes != nil || !untilNextAllowed {
                    minutesStepper(range: ItinSchedule.stayMinuteRange)
                }
            }
            .listRowBackground(GpsTheme.card)
        case .move:
            Section("方式") {
                Picker("方式", selection: $event.moveMode) {
                    Text("路線").tag(ItinMoveMode.route)
                    Text("直線").tag(ItinMoveMode.straight)
                }
                .pickerStyle(.segmented)
                Picker("速度", selection: speedBinding) {
                    Text("步行").accessibilityIdentifier("itin.speed.walk").tag(GpsItinSpeedChoice.preset(.walk))
                    Text("單車").accessibilityIdentifier("itin.speed.bike").tag(GpsItinSpeedChoice.preset(.bike))
                    Text("駕車").accessibilityIdentifier("itin.speed.drive").tag(GpsItinSpeedChoice.preset(.drive))
                    Text("自訂").accessibilityIdentifier("itin.speed.custom").tag(GpsItinSpeedChoice.custom)
                }
                .pickerStyle(.segmented)
                if let kmh = event.customKmh {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("時速 \(Int(kmh.rounded())) 公里")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(Color.white)
                        Slider(value: customKmhBinding, in: MoveSpeedPreset.customRange, step: 0.5)
                            .tint(GpsTheme.mint)
                            .accessibilityLabel("自訂速度")
                            .accessibilityValue("時速 \(Int(kmh.rounded())) 公里")
                    }
                }
                if event.speedPreset.borrowsWalkingRoute && event.moveMode == .route && event.customKmh == nil {
                    Text(MoveSpeedPreset.borrowedRouteNote)
                        .font(.footnote)
                        .foregroundStyle(GpsTheme.sub)
                }
                if let routeInfo {
                    Text(routeInfo)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(GpsTheme.sub)
                }
                if ctx.previousEnd == nil {
                    Text("上一項沒有位置，無法決定起點。")
                        .font(.footnote)
                        .foregroundStyle(GpsTheme.dangerText)
                }
            }
            .listRowBackground(GpsTheme.card)
        case .wander:
            Section("原地漫步") {
                Picker("範圍", selection: $event.wanderRadius) {
                    ForEach(WanderSize.allCases, id: \.self) { size in
                        Text(ItinText.sizeLabel(size)).accessibilityIdentifier("itin.wander.\(size.rawValue)").tag(size)
                    }
                }
                .pickerStyle(.segmented)
                minutesStepper(range: ItinSchedule.wanderMinuteRange)
            }
            .listRowBackground(GpsTheme.card)
        case .stop:
            EmptyView()
        }
    }

    private var stayUntilNextBinding: Binding<Bool> {
        Binding(
            get: { event.minutes == nil },
            set: { untilNext in
                if untilNext {
                    event.minutes = nil
                } else if event.minutes == nil {
                    event.minutes = 30
                    minutesText = "30"
                }
            }
        )
    }

    private var speedBinding: Binding<GpsItinSpeedChoice> {
        Binding(
            get: { event.customKmh != nil ? .custom : .preset(event.speedPreset) },
            set: { choice in
                switch choice {
                case .preset(let preset):
                    event.speedPreset = preset
                    event.customKmh = nil
                case .custom:
                    event.customKmh = event.customKmh ?? event.speedPreset.kmh
                }
            }
        )
    }

    private var customKmhBinding: Binding<Double> {
        Binding(
            get: { event.customKmh ?? event.speedPreset.kmh },
            set: { event.customKmh = MoveSpeedPreset.clampCustom($0) }
        )
    }

    /// 5 分鐘一格的步進器，另可直接輸入數字（規格 10.6.6）。
    private func minutesStepper(range: ClosedRange<Int>) -> some View {
        let value = event.minutes ?? 30
        return HStack {
            Text(event.type == .wander ? "持續時間" : "時間長度")
                .foregroundStyle(Color.white)
            Spacer()
            TextField("分鐘", text: $minutesText)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 70)
                .foregroundStyle(Color.white)
                .onChange(of: minutesText) { _, text in
                    if let n = Int(text) {
                        event.minutes = min(max(n, range.lowerBound), range.upperBound)
                    }
                }
                .accessibilityLabel("分鐘")
                .accessibilityIdentifier("itin.unit.minute")
            Text("分").foregroundStyle(GpsTheme.sub)
            Stepper("", onIncrement: {
                let next = min(range.upperBound, (value / 5 + 1) * 5)
                event.minutes = next
                minutesText = String(next)
            }, onDecrement: {
                let prev = max(range.lowerBound, value % 5 == 0 ? value - 5 : (value / 5) * 5)
                event.minutes = prev
                minutesText = String(prev)
            })
            .labelsHidden()
            .accessibilityLabel(event.type == .wander ? "持續時間" : "時間長度")
            .accessibilityValue("\(value) 分鐘")
        }
        .onAppear {
            if event.minutes == nil, event.type == .wander || !untilNextAllowed {
                event.minutes = 30
                minutesText = "30"
            }
        }
    }

    // MARK: 推算與路線

    private var estimateText: String {
        guard let slot = previewSlot(event) else { return "" }
        let begin = GpsItineraryRunner.timeText(slot.start, timeZone: timeZone, now: slot.start)
        let startPart = event.startRule.kind == .at ? "\(begin) 開始" : "約 \(begin) 開始"
        guard let end = slot.end else { return startPart }
        let finish = GpsItineraryRunner.timeText(end, timeZone: timeZone, now: slot.start)
        switch event.type {
        case .move: return "\(startPart)，約 \(finish) 抵達"
        case .stop: return startPart
        default: return "\(startPart)，約 \(finish) 結束"
        }
    }

    private var routeTaskKey: String {
        guard event.type == .move, let origin = ctx.previousEnd?.coord else { return "none" }
        return event.expectedRouteKey(from: origin) ?? "none"
    }

    /// 移動項目：路線模式在編輯時就規劃並暫存（儲存行程時不必重查）。
    private func refreshRoute() async {
        guard event.type == .move, let origin = ctx.previousEnd?.coord, let dest = event.coord else {
            routeInfo = nil
            return
        }
        if event.moveMode == .straight {
            let meters = GpsGeo.meters(origin.clCoordinate, dest.clCoordinate)
            routeInfo = "直線距離 \(ItinText.distance(meters))・約 \(ItinText.minutes(meters / max(0.1, event.effectiveKmh / 3.6)))"
            return
        }
        if event.hasValidCachedPath(from: origin), let path = event.cachedPath {
            let meters = ItinSchedule.pathMeters(path)
            routeInfo = "路線距離 \(ItinText.distance(meters))・約 \(ItinText.minutes(meters / max(0.1, event.effectiveKmh / 3.6)))"
            return
        }
        routeInfo = "查詢路線中…"
        let plan = await GpsSimRoutePlanner.plan(from: origin.clCoordinate, to: dest.clCoordinate,
                                                 mode: .route, speed: event.speedPreset)
        guard !Task.isCancelled, event.type == .move, event.coord == dest else { return }
        let meters = plan.totalMeters
        let eta = ItinText.minutes(meters / max(0.1, event.effectiveKmh / 3.6))
        if plan.fellBackToStraight || plan.path.count < 2 {
            event.cachedPath = nil
            event.routeKey = nil
            routeInfo = "無法規劃路線，以直線估算 \(ItinText.distance(meters))・約 \(eta)"
        } else {
            event.cachedPath = plan.path.map { ItinCoord($0) }
            event.routeKey = event.expectedRouteKey(from: origin)
            routeInfo = "路線距離 \(ItinText.distance(meters))・約 \(eta)"
        }
    }
}

// MARK: - 地點選擇

struct GpsItineraryPlacePicker: View {
    let previousEnd: GpsItinEndpoint?
    let onMap: () -> Void
    let onPick: (String?, String, ItinCoord) -> Void

    @ObservedObject private var places = GpsPlaceStore.shared
    @State private var search = ""

    private var filtered: [GpsPlace] {
        let all = places.sorted
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        List {
            if let previousEnd, search.isEmpty {
                Button {
                    onPick(previousEnd.placeID, previousEnd.name, previousEnd.coord)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("上一項的終點").foregroundStyle(Color.white)
                        Text(previousEnd.name).font(.footnote).foregroundStyle(GpsTheme.sub)
                    }
                }
                .listRowBackground(GpsTheme.card)
            }
            Section {
                ForEach(filtered) { p in
                    Button {
                        onPick(p.id, p.name, ItinCoord(p.coordinate))
                    } label: {
                        Text(p.name).foregroundStyle(Color.white)
                    }
                    // id 用地點名稱：地點 id 是每台手機各自產生的 UUID，測試劇本無法事先知道
                    .accessibilityIdentifier("itin.place.row.\(p.name)")
                }
            }
            .listRowBackground(GpsTheme.card)
            Button {
                onMap()
            } label: {
                Label("從地圖選擇", systemImage: "map")
                    .foregroundStyle(GpsTheme.mint)
            }
            .listRowBackground(GpsTheme.card)
            .accessibilityIdentifier("itin.place.map")
        }
        .scrollContentBackground(.hidden)
        .background(GpsTheme.background.ignoresSafeArea())
        .searchable(text: $search, prompt: "搜尋地點")
        .navigationTitle("地點")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct GpsItineraryMapPicker: View {
    let onPick: (String, ItinCoord) -> Void

    @State private var position: MapCameraPosition
    @State private var center: CLLocationCoordinate2D
    @State private var name = ""
    @State private var nameEdited = false
    @State private var lookupID = 0

    init(initial: CLLocationCoordinate2D?, onPick: @escaping (String, ItinCoord) -> Void) {
        self.onPick = onPick
        let c = initial ?? GpsTheme.taiwanRegion.center
        _center = State(initialValue: c)
        if let initial {
            _position = State(initialValue: .region(MKCoordinateRegion(center: initial, latitudinalMeters: 800,
                                                                        longitudinalMeters: 800)))
        } else {
            _position = State(initialValue: .region(GpsTheme.taiwanRegion))
        }
    }

    var body: some View {
        ZStack {
            Map(position: $position)
                .mapStyle(.standard)
                .onMapCameraChange(frequency: .onEnd) { context in
                    center = context.region.center
                    lookUpName()
                }
            Image(systemName: "plus")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(GpsTheme.mint)
                .shadow(color: .black.opacity(0.6), radius: 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .ignoresSafeArea(edges: .bottom)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                TextField("名稱", text: Binding(get: { name }, set: { name = $0; nameEdited = true }))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("itin.map.name")
                Button {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    onPick(trimmed.isEmpty ? "地圖上的位置" : trimmed, ItinCoord(center))
                } label: {
                    Text("使用此位置")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(GpsTheme.onAccent)
                        .background(GpsTheme.mint, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("itin.map.use")
            }
            .padding(16)
            .background(GpsTheme.card)
        }
        .navigationTitle("從地圖選擇")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { lookUpName() }
    }

    /// 反查地名當預設名稱（使用者改過名稱就不覆蓋）。
    private func lookUpName() {
        lookupID += 1
        let token = lookupID
        let c = center
        Task { @MainActor in
            let placemark = try? await CLGeocoder().reverseGeocodeLocation(
                CLLocation(latitude: c.latitude, longitude: c.longitude),
                preferredLocale: Locale(identifier: "zh_Hant_TW")).first
            guard token == lookupID, !nameEdited, let placemark else { return }
            name = placemark.name ?? placemark.locality ?? ""
        }
    }
}

// MARK: - 編輯頁的計算快取

/// 編輯頁的時間表與驗證結果快取：draft 與 anchor 都沒變就沿用上次結果。
/// 每一列各自讀 slots／issues，沒有快取時一次畫面更新要重算 n×(驗證＋時間表)＝O(n²)。
/// 純計算結果、不是畫面狀態，所以用參考型別放在 @State 裡，讀取時更新不會觸發重畫。
final class GpsItinEditorCache {
    private var slotsKey: (itinerary: Itinerary, anchor: Date)?
    private var cachedSlots: [ItinSlot] = []
    private var issuesKey: (itinerary: Itinerary, anchor: Date)?
    private var cachedIssues: [ItinIssue] = []

    func plannedSlots(for itinerary: Itinerary, anchor: Date) -> [ItinSlot] {
        if let key = slotsKey, key.anchor == anchor, key.itinerary == itinerary { return cachedSlots }
        // 與 GpsItineraryRunner.plannedSlots 相同算法；直接呼叫純函式，不受 Runner 的 @MainActor 限制。
        cachedSlots = ItinSchedule.compute(events: itinerary.events, anchor: anchor,
                                           durations: ItinSchedule.moveDurations(events: itinerary.events),
                                           dateMode: itinerary.dateMode, timeZone: itinerary.timeZone)
        slotsKey = (itinerary, anchor)
        return cachedSlots
    }

    func issues(for itinerary: Itinerary, anchor: Date) -> [ItinIssue] {
        if let key = issuesKey, key.anchor == anchor, key.itinerary == itinerary { return cachedIssues }
        cachedIssues = ItinSchedule.validate(itinerary, anchor: anchor)
        issuesKey = (itinerary, anchor)
        return cachedIssues
    }
}
