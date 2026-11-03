//
//  GpsSimItineraryListView.swift
//  PinFly
//
//  【這個檔案的角色】「行程」清單（首頁「行程」圓鈕開啟的 sheet，規格 10.6.4、10.6.9、10.6.10）。
//  列出所有行程；新增、匯入、匯出、複製、重新命名、刪除（附「復原」）、開始行程；
//  （上次 PinFly 關閉時中斷的行程只在首頁「行程」圓鈕提示接續，規格 10.4.3。）
//
//  【為什麼這樣設計】
//  - 刪除不跳確認，改底部「復原」提示，留到使用者做下一個動作才收（NN/g，規格 10.6.1）。
//  - 新行程先當草稿推入編輯頁，按「儲存」才寫進 store（取消就不留空行程）。
//  - 匯出用系統分享表單（UIActivityViewController），檔案先寫到暫存資料夾。
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 清單推入編輯頁的路由。
enum GpsItineraryRoute: Hashable {
    case existing(id: String)
    case draft(id: String)
}

struct GpsSimItineraryListView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = GpsItineraryStore.shared
    @ObservedObject private var runner = GpsItineraryRunner.shared
    @ObservedObject private var places = GpsPlaceStore.shared

    @State private var path: [GpsItineraryRoute] = []
    /// 尚未儲存的新行程（推入編輯頁用）。
    @State private var drafts: [String: Itinerary] = [:]
    /// 推入編輯頁時要顯示一次的提示（匯入結果）。
    @State private var editorNotices: [String: String] = [:]
    @State private var showUndo = false
    @State private var undoName = ""
    @State private var renaming: Itinerary?
    @State private var renameText = ""
    @State private var showImporter = false
    @State private var shareItem: GpsShareItem?
    @State private var startRequest: GpsItineraryStartRequest?
    @State private var showRun = false
    @State private var message: String?

    var body: some View {
        NavigationStack(path: $path) {
            content
                .background(GpsTheme.background.ignoresSafeArea())
                .navigationTitle("行程")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("關閉") { dismiss() }
                            .accessibilityIdentifier("itin.list.close")
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Menu {
                            Button {
                                clearTransient()
                                showImporter = true
                            } label: {
                                Label("匯入行程", systemImage: "square.and.arrow.down")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("更多")
                        .accessibilityIdentifier("itin.list.more")
                        Button {
                            newItinerary(sample: false)
                        } label: {
                            Image(systemName: "plus")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("新增行程")
                        .accessibilityIdentifier("itin.list.add")
                    }
                }
                .navigationDestination(for: GpsItineraryRoute.self) { route in
                    destination(route)
                }
        }
        .preferredColorScheme(.dark)
        .dynamicTypeSize(...GpsSimHomeView.maxTypeSize)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            importFile(result)
        }
        .sheet(item: $shareItem) { item in
            GpsActivityView(items: [item.url])
                .presentationDetents([.medium, .large])
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
        .alert("重新命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("行程名稱", text: $renameText)
            Button("取消", role: .cancel) { renaming = nil }
            Button("儲存") { commitRename() }
        }
    }

    // MARK: 內容

    @ViewBuilder
    private var content: some View {
        if store.itineraries.isEmpty && !showUndo {
            emptyState
        } else {
            List {
                if let message {
                    Section {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(GpsTheme.dangerText)
                    }
                    .listRowBackground(GpsTheme.card)
                }
                Section {
                    ForEach(store.itineraries) { item in
                        row(item)
                    }
                } footer: {
                    Text(GpsItineraryRunner.sensorDisclaimer)
                        .font(.footnote)
                        .foregroundStyle(GpsTheme.sub)
                }
                .listRowBackground(GpsTheme.card)
            }
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .bottom) {
                if showUndo { undoBar }
            }
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "list.bullet.clipboard")
                    .font(.system(size: 44))
                    .foregroundStyle(GpsTheme.mint)
                    .accessibilityHidden(true)
                Text("尚未建立行程")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.white)
                Text("依時間自動停留、移動、原地漫步。" + GpsItineraryRunner.sensorDisclaimer)
                    .font(.body)
                    .foregroundStyle(GpsTheme.sub)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    newItinerary(sample: false)
                } label: {
                    Text("新增行程")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(GpsTheme.onAccent)
                        .background(GpsTheme.mint, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("itin.empty.add")
                Button {
                    showImporter = true
                } label: {
                    Text("匯入行程")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(GpsTheme.mint)
                        .overlay(Capsule().stroke(GpsTheme.mint, lineWidth: 1.5))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("itin.empty.import")
                if places.places.count >= 2 {
                    Button("以範例建立") { newItinerary(sample: true) }
                        .font(.body)
                        .foregroundStyle(GpsTheme.mint)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("itin.empty.sample")
                }
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(GpsTheme.dangerText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
        }
    }

    private func statusText(_ item: Itinerary) -> String? {
        guard runner.activeItineraryID == item.id else { return nil }
        return runner.state == .armed ? "待命" : "進行中"
    }

    private func row(_ item: Itinerary) -> some View {
        let active = runner.activeItineraryID == item.id
        return Button {
            clearTransient()
            path.append(.existing(id: item.id))
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name.isEmpty ? "未命名行程" : item.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.white)
                    Text(subtitle(item))
                        .font(.footnote)
                        .foregroundStyle(GpsTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                if let status = statusText(item) {
                    Text(status)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(GpsTheme.mint)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(GpsTheme.sub)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("itin.row")
        .swipeActions(edge: .trailing, allowsFullSwipe: !active) {
            if active {
                Button("停止行程") { runner.stopItinerary() }
                    .tint(GpsTheme.orange)
            } else {
                Button("刪除", role: .destructive) { delete(item) }
                    .accessibilityIdentifier("itin.delete")
                Button("複製") { duplicate(item) }
                    .tint(GpsTheme.blue)
            }
        }
        .contextMenu {
            Button {
                clearTransient()
                startRequest = GpsItineraryStartRequest(itineraryID: item.id)
            } label: {
                Label("開始行程", systemImage: "play.circle")
            }
            .disabled(active)
            Button {
                clearTransient()
                renameText = item.name
                renaming = item
            } label: {
                Label("重新命名", systemImage: "pencil")
            }
            Button {
                duplicate(item)
            } label: {
                Label("複製行程", systemImage: "plus.square.on.square")
            }
            Button {
                export(item)
            } label: {
                Label("匯出行程", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("itin.export")
            if !active {
                Button(role: .destructive) {
                    delete(item)
                } label: {
                    Label("刪除行程", systemImage: "trash")
                }
            }
        }
    }

    /// 「4 個項目・14:00 開始・約 1 小時 20 分・6.1 公里」。
    private func subtitle(_ item: Itinerary) -> String {
        var parts = [item.listSubtitle]
        let slots = GpsItineraryRunner.plannedSlots(for: item)
        if let first = slots.first, let last = slots.last {
            let span = (last.end ?? last.start).timeIntervalSince(first.start)
            if span >= 60 { parts.append("約 " + ItinText.minutes(span)) }
        }
        let meters = GpsSimItineraryEditorView.totalMoveMeters(item.events)
        if meters > 0 { parts.append(ItinText.distance(meters)) }
        return parts.joined(separator: "・")
    }

    private var undoBar: some View {
        HStack {
            Text("已刪除「\(undoName)」。")
                .font(.footnote)
                .foregroundStyle(Color.white)
            Spacer()
            Button("復原") {
                store.undoDelete()
                showUndo = false
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(GpsTheme.mint)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityIdentifier("itin.undo")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func destination(_ route: GpsItineraryRoute) -> some View {
        switch route {
        case .existing(let id):
            if let item = store.itinerary(id: id) {
                GpsSimItineraryEditorView(itinerary: item, isNew: false, initialNotice: editorNotices[id])
            } else {
                Text("找不到行程。")
                    .foregroundStyle(GpsTheme.sub)
            }
        case .draft(let id):
            if let item = drafts[id] {
                GpsSimItineraryEditorView(itinerary: item, isNew: true, initialNotice: nil)
            } else if let saved = store.itinerary(id: id) {
                GpsSimItineraryEditorView(itinerary: saved, isNew: false, initialNotice: nil)
            }
        }
    }

    // MARK: 動作

    /// 使用者做了下一個動作：收起「復原」提示與一次性訊息。
    private func clearTransient() {
        if showUndo { store.clearUndo() }
        showUndo = false
        message = nil
    }

    private func newItinerary(sample: Bool) {
        clearTransient()
        var item = Itinerary(name: sample ? "範例行程" : "新行程")
        if sample {
            let sorted = places.sorted
            if sorted.count >= 2 {
                let a = sorted[0]
                let b = sorted[1]
                item.events = [
                    ItinEvent(type: .stay, placeID: a.id, placeName: a.name, coord: ItinCoord(a.coordinate), minutes: 10),
                    ItinEvent(type: .move, placeID: b.id, placeName: b.name, coord: ItinCoord(b.coordinate),
                              moveMode: .route, speedPreset: .walk),
                    ItinEvent(type: .wander, placeID: b.id, placeName: b.name, coord: ItinCoord(b.coordinate),
                              wanderRadius: .small, minutes: 15)
                ]
            }
        }
        drafts[item.id] = item
        path.append(.draft(id: item.id))
    }

    private func duplicate(_ item: Itinerary) {
        clearTransient()
        store.duplicate(id: item.id)
    }

    private func delete(_ item: Itinerary) {
        guard runner.activeItineraryID != item.id else { return }
        message = nil
        store.delete(id: item.id)
        undoName = item.name
        showUndo = true
    }

    private func commitRename() {
        guard let item = renaming else { return }
        renaming = nil
        store.rename(id: item.id, to: renameText)
    }

    private func export(_ item: Itinerary) {
        clearTransient()
        do {
            let data = try store.exportData(id: item.id)
            let fileName = ItinTransfer.exportFileName(item)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ItineraryExport", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: url)
            try data.write(to: url, options: .atomic)
            shareItem = GpsShareItem(url: url)
        } catch {
            message = "無法匯出行程。請稍後重試。"
        }
    }

    private func importFile(_ result: Result<[URL], Error>) {
        clearTransient()
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let imported = try store.importItinerary(from: data, places: places.places)
            let item = imported.itinerary
            var lines = ["已匯入「\(item.name)」。請檢查後點選「儲存」以規劃路線。"]
            lines.append(contentsOf: imported.adjustments)
            // 規格 10.6.9：照樣匯入並開啟編輯頁讓使用者修正；無法儲存的錯誤列在提示裡
            // （修正前開始行程會被 Runner.start 的驗證擋下，不會瞬移）。
            let blocking = ItinSchedule.validate(item, anchor: Date()).filter { $0.severity == .blocking }
            lines.append(contentsOf: blocking.map { ItinMessage.text(for: $0, timeZone: item.timeZone) })
            if store.itinerary(id: item.id) != nil {
                editorNotices[item.id] = lines.joined(separator: "\n")
                path.append(.existing(id: item.id))
            } else {
                drafts[item.id] = item
                path.append(.draft(id: item.id))
            }
        } catch {
            message = ItinMessage.importFailed
        }
    }

}

// MARK: - 分享表單

struct GpsShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// 系統分享表單（存到「檔案」App 或傳給他人）。
struct GpsActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
