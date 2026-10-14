//
//  GpsSimHomeView.swift
//  StikDebug (GpsSim fork)
//
//  The app's root screen: status pill, map with place circles, search, place list.
//  One tap on a place = send a random landing inside its circle, no confirmation.
//

import SwiftUI
import MapKit
import CoreLocation
import UniformTypeIdentifiers

enum GpsTheme {
    static let background = Color(red: 0.047, green: 0.067, blue: 0.102)   // #0C111A
    static let card = Color(red: 0.082, green: 0.110, blue: 0.157)         // #151C28
    static let line = Color.white.opacity(0.10)
    static let mint = Color(red: 0.161, green: 0.827, blue: 0.776)         // #29D3C6
    static let yellow = Color(red: 0.918, green: 0.702, blue: 0.031)       // #EAB308
    static let red = Color(red: 0.937, green: 0.267, blue: 0.267)          // #EF4444
    static let orange = Color(red: 0.976, green: 0.451, blue: 0.086)       // #F97316
    static let blue = Color(red: 0.231, green: 0.510, blue: 0.965)         // #3B82F6
    static let sub = Color.white.opacity(0.68)

    /// Whole of Taiwan incl. Penghu/Kinmen-ish; used for the first camera and MKLocalSearch.
    static let taiwanRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 23.7, longitude: 120.95),
        span: MKCoordinateSpan(latitudeDelta: 4.2, longitudeDelta: 3.6)
    )
}

private struct GpsCandidate: Equatable {
    var coordinate: CLLocationCoordinate2D
    var title: String

    static func == (a: GpsCandidate, b: GpsCandidate) -> Bool {
        a.title == b.title &&
            a.coordinate.latitude == b.coordinate.latitude &&
            a.coordinate.longitude == b.coordinate.longitude
    }
}

private struct GpsBanner: Identifiable {
    let id: String
    let color: Color
    let title: String
    let detail: String
    var buttonTitle: String?
    var busy = false
    var action: (() -> Void)?
}

struct GpsSimHomeView: View {
    @ObservedObject private var engine = GpsSimEngine.shared
    @ObservedObject private var store = GpsPlaceStore.shared
    @ObservedObject private var session = LocationSimulationSession.shared
    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var mounting = MountingProgress.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(GpsGeo.defaultRadiusKey) private var defaultRadius: Double = 25

    @State private var position: MapCameraPosition = .region(GpsTheme.taiwanRegion)
    @State private var mapCenter: CLLocationCoordinate2D?
    @State private var candidate: GpsCandidate?
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var isSearching = false
    @State private var searchMessage: String?
    @State private var editing: GpsPlace?
    @State private var showHidden = false
    @State private var showSettings = false
    @State private var showPlacesImporter = false
    @State private var showSaveName = false
    @State private var newPlaceName = ""
    @State private var pairingExists = GpsSimEngine.pairingExists
    @State private var tunnelGraceOver = false
    @State private var didInitialFit = false
    @FocusState private var searchFocused: Bool

    private var visiblePlaces: [GpsPlace] { store.sorted.filter { !$0.isHidden } }
    private var hiddenPlaces: [GpsPlace] { store.sorted.filter { $0.isHidden } }
    private var isSimulating: Bool { session.isActive || engine.activeName != nil }
    private var simulatedPoint: CLLocationCoordinate2D? { engine.current ?? session.coordinate }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            searchBar
            map
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
            bottomPanel
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
        }
        .background(GpsTheme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(GpsTheme.mint)
        .overlay(alignment: .bottom) { toastView }
        .onAppear(perform: handleAppear)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshFromDisk(startTunnel: true) }
        }
        .onChange(of: engine.toast) { _, value in
            guard value != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { engine.toast = nil }
        }
        .sheet(item: $editing) { place in
            GpsPlaceEditSheet(
                place: place,
                mapCenter: mapCenter,
                onSave: { store.upsert($0) },
                onDelete: { store.delete(id: $0.id) }
            )
        }
        .sheet(isPresented: $showSettings, onDismiss: { refreshFromDisk(startTunnel: true) }) {
            GpsSimSettingsView(onImportPlaces: {
                showSettings = false
                // Let the settings sheet finish dismissing before presenting the picker.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showPlacesImporter = true }
            })
        }
        .fileImporter(isPresented: $showPlacesImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            importPlaces(result)
        }
        .alert("存成地點", isPresented: $showSaveName) {
            TextField("地點名稱", text: $newPlaceName)
            Button("儲存") { saveCandidate() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("半徑先用預設 \(Int(defaultRadius)) 公尺，之後可按 ✎ 修改。")
        }
    }

    // MARK: - Top bar / status

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                statusPill
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .background(GpsTheme.card, in: Circle())
                }
                .accessibilityLabel("設定")
            }
            if isSimulating {
                Button {
                    engine.stop()
                } label: {
                    HStack {
                        if engine.isBusy { ProgressView().tint(.white) }
                        Text("⏹ 停止模擬")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(.white)
                    .background(GpsTheme.red, in: RoundedRectangle(cornerRadius: 14))
                }
                .disabled(engine.isBusy)
                .accessibilityHint("讓手機回到真實位置")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isSimulating ? GpsTheme.mint : Color.white.opacity(0.45))
                .frame(width: 10, height: 10)
            Text(statusText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            if engine.isBusy && !isSimulating { ProgressView() }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(GpsTheme.card, in: Capsule())
        .overlay(Capsule().stroke(isSimulating ? GpsTheme.mint.opacity(0.6) : GpsTheme.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        guard isSimulating else { return "真實位置" }
        let name = engine.activeName ?? "外部連結的位置"
        if let center = engine.activeCenter, let cur = simulatedPoint {
            let d = Int(GpsGeo.meters(center, cur).rounded())
            return "模擬中：\(name)（離圓心 \(d) 公尺）"
        }
        return "模擬中：\(name)"
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(GpsTheme.sub)
            TextField("搜尋地點，或貼上「緯度, 經度」", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit(runSearch)
            if isSearching { ProgressView() }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchResults = []
                    searchMessage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(GpsTheme.sub)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("清除搜尋")
            }
        }
        .padding(.leading, 14)
        .frame(minHeight: 48)
        .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func runSearch() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searchMessage = nil
        if let c = GpsGeo.parseCoordinate(q) {
            searchResults = []
            setCandidate(c, title: String(format: "%.6f, %.6f", c.latitude, c.longitude))
            searchFocused = false
            return
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = q
        request.region = GpsTheme.taiwanRegion
        isSearching = true
        Task {
            let items: [MKMapItem]
            do {
                items = try await MKLocalSearch(request: request).start().mapItems
            } catch {
                items = []
            }
            await MainActor.run {
                isSearching = false
                searchResults = Array(items.prefix(8))
                searchMessage = items.isEmpty ? "找不到「\(q)」。換個關鍵字，或直接貼座標。" : nil
            }
        }
    }

    // MARK: - Map

    private var map: some View {
        MapReader { proxy in
            Map(position: $position) {
                ForEach(visiblePlaces) { p in
                    MapCircle(center: p.coordinate, radius: GpsGeo.radius(of: p))
                        .foregroundStyle(GpsTheme.yellow.opacity(0.18))
                        .stroke(GpsTheme.yellow, lineWidth: 1.5)
                }
                ForEach(visiblePlaces) { p in
                    Marker(p.name, coordinate: p.coordinate)
                        .tint(GpsTheme.yellow)
                }
                if let c = candidate {
                    Marker("候選位置", systemImage: "mappin", coordinate: c.coordinate)
                        .tint(GpsTheme.mint)
                }
                if let point = simulatedPoint, isSimulating {
                    Annotation("模擬位置", coordinate: point) {
                        Circle()
                            .fill(GpsTheme.blue)
                            .frame(width: 18, height: 18)
                            .overlay(Circle().stroke(Color.white, lineWidth: 3))
                            .shadow(color: GpsTheme.blue.opacity(0.6), radius: 6)
                            .allowsHitTesting(false)
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard)
            .onMapCameraChange { context in
                mapCenter = context.region.center
            }
            .onTapGesture { location in
                guard let c = proxy.convert(location, from: .local) else { return }
                searchFocused = false
                candidate = GpsCandidate(coordinate: c, title: String(format: "%.6f, %.6f", c.latitude, c.longitude))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
    }

    private func focus(on c: CLLocationCoordinate2D, radius: Double) {
        let span = max(radius * 2 + 200, 300)
        withAnimation(.easeInOut(duration: 0.4)) {
            position = .region(MKCoordinateRegion(center: c, latitudinalMeters: span, longitudinalMeters: span))
        }
    }

    private func fitAllPlaces() {
        let pts = visiblePlaces
        guard !pts.isEmpty else { return }
        if pts.count == 1 {
            focus(on: pts[0].coordinate, radius: GpsGeo.radius(of: pts[0]))
            return
        }
        let lats = pts.map { $0.lat }, lons = pts.map { $0.lon }
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.4, 0.01),
                                    longitudeDelta: max((maxLon - minLon) * 1.4, 0.01))
        position = .region(MKCoordinateRegion(center: center, span: span))
    }

    private func setCandidate(_ c: CLLocationCoordinate2D, title: String) {
        candidate = GpsCandidate(coordinate: c, title: title)
        focus(on: c, radius: GpsGeo.defaultRadius)
    }

    // MARK: - Bottom panel

    private var bottomPanel: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(banners) { bannerView($0) }
                if let c = candidate { candidateCard(c) }
                if let msg = searchMessage {
                    Text(msg).font(.subheadline).foregroundStyle(GpsTheme.sub)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(searchResults, id: \.self) { item in searchRow(item) }

                if store.places.isEmpty {
                    emptyState
                } else {
                    ForEach(visiblePlaces) { placeRow($0) }
                    if !hiddenPlaces.isEmpty {
                        Button {
                            withAnimation { showHidden.toggle() }
                        } label: {
                            Text(showHidden ? "‹ 收起" : "\(hiddenPlaces.count) 個已隱藏")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(GpsTheme.sub)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        if showHidden {
                            ForEach(hiddenPlaces) { placeRow($0).opacity(0.75) }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .refreshable {
            refreshFromDisk(startTunnel: false)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("還沒有地點").font(.headline).foregroundStyle(.white)
            Text("點地圖或搜尋後按「＋ 存成地點」，或在設定裡匯入 places.json。也可以從電腦把 places.json 放進本 App 的文件資料夾，再下拉重新整理。")
                .font(.subheadline)
                .foregroundStyle(GpsTheme.sub)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private func placeRow(_ p: GpsPlace) -> some View {
        let active = engine.activePlaceID == p.id && isSimulating
        var parts: [String] = []
        if let county = p.county { parts.append(county) }
        parts.append("半徑 \(Int(GpsGeo.radius(of: p).rounded())) m")
        let subtitle = parts.joined(separator: " · ")
        return HStack(spacing: 0) {
            Button {
                searchFocused = false
                focus(on: p.coordinate, radius: GpsGeo.radius(of: p))
                engine.send(place: p, among: store.places)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.name)
                        .font(.headline)
                        .foregroundStyle(active ? GpsTheme.mint : .white)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(GpsTheme.sub)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.vertical, 10)
                .padding(.leading, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(engine.isBusy)
            .accessibilityHint("點一下就把手機定位傳到這裡")

            Button {
                editing = p
            } label: {
                Text("✎")
                    .font(.title3)
                    .foregroundStyle(GpsTheme.sub)
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("編輯\(p.name)")
        }
        .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(active ? GpsTheme.mint : GpsTheme.line, lineWidth: 1))
    }

    private func searchRow(_ item: MKMapItem) -> some View {
        Button {
            let c = item.placemark.coordinate
            searchResults = []
            searchFocused = false
            setCandidate(c, title: item.name ?? String(format: "%.6f, %.6f", c.latitude, c.longitude))
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name ?? "（未命名）").font(.body.weight(.semibold)).foregroundStyle(.white)
                if let sub = item.placemark.title {
                    Text(sub).font(.footnote).foregroundStyle(GpsTheme.sub).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func candidateCard(_ c: GpsCandidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.title).font(.headline).foregroundStyle(.white)
                    Text(String(format: "%.6f, %.6f", c.coordinate.latitude, c.coordinate.longitude))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(GpsTheme.sub)
                        .textSelection(.enabled)
                }
                Spacer()
                Button {
                    candidate = nil
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(GpsTheme.sub)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("關閉")
            }
            HStack(spacing: 8) {
                Button {
                    // Exact point, no scatter.
                    engine.send(to: c.coordinate, name: c.title)
                } label: {
                    Text("📍 傳送到這裡")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(GpsTheme.background)
                        .background(GpsTheme.mint, in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(engine.isBusy)
                Button {
                    newPlaceName = c.title
                    showSaveName = true
                } label: {
                    Text("＋ 存成地點")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(GpsTheme.mint)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(GpsTheme.mint, lineWidth: 1.5))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(GpsTheme.mint.opacity(0.5), lineWidth: 1))
    }

    private func saveCandidate() {
        guard let c = candidate else { return }
        let name = newPlaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = GpsPlace(
            name: name.isEmpty ? c.title : name,
            lat: c.coordinate.latitude,
            lon: c.coordinate.longitude,
            order: store.nextOrder()
        )
        store.upsert(place)
        candidate = nil
        engine.toast = "已存成地點：\(place.name)"
    }

    // MARK: - Banners

    private var banners: [GpsBanner] {
        var list: [GpsBanner] = []
        if !pairingExists {
            list.append(GpsBanner(
                id: "pairing", color: GpsTheme.red,
                title: "還沒有配對檔",
                detail: "請在電腦上用 iloader 放配對檔，放好後按「重新檢查」。",
                buttonTitle: "重新檢查",
                action: { refreshFromDisk(startTunnel: true) }
            ))
        } else if !tunnel.isConnected {
            if tunnelGraceOver {
                list.append(GpsBanner(
                    id: "tunnel", color: GpsTheme.orange,
                    title: "連不到手機",
                    detail: "請打開 LocalDevVPN 並連上 Wi-Fi，再按「重試連線」。",
                    buttonTitle: "重試連線",
                    action: { retryTunnel() }
                ))
            } else {
                list.append(GpsBanner(id: "connecting", color: GpsTheme.sub, title: "正在連線手機…", detail: "", busy: true))
            }
        } else if !mounting.coolisMounted {
            if mounting.mountingThread != nil {
                list.append(GpsBanner(id: "mounting", color: GpsTheme.sub, title: "正在掛載開發者磁碟映像（DDI）…", detail: "", busy: true))
            } else {
                list.append(GpsBanner(
                    id: "ddi", color: GpsTheme.orange,
                    title: "開發者磁碟映像（DDI）尚未掛載",
                    detail: "模擬定位需要先掛載 DDI，按右邊按鈕（第一次會先下載，約數十 MB）。",
                    buttonTitle: "掛載 DDI",
                    action: { mountDDI() }
                ))
            }
        }
        if let issue = engine.issue {
            list.append(GpsBanner(
                id: "issue", color: GpsTheme.red,
                title: "定位沒有送出",
                detail: issue.message,
                buttonTitle: "知道了",
                action: { engine.issue = nil }
            ))
        }
        if let err = store.lastLoadError {
            list.append(GpsBanner(
                id: "file", color: GpsTheme.orange,
                title: "地點檔有問題",
                detail: err,
                buttonTitle: "知道了",
                action: { store.lastLoadError = nil }
            ))
        }
        return list
    }

    private func bannerView(_ b: GpsBanner) -> some View {
        HStack(alignment: .center, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(b.color).frame(width: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(b.title).font(.subheadline.weight(.bold)).foregroundStyle(.white)
                if !b.detail.isEmpty {
                    Text(b.detail).font(.footnote).foregroundStyle(GpsTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if b.busy { ProgressView() }
            if let title = b.buttonTitle, let action = b.action {
                Button(action: action) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(b.color.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Toast

    @ViewBuilder
    private var toastView: some View {
        if let text = engine.toast {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(GpsTheme.card, in: Capsule())
                .overlay(Capsule().stroke(GpsTheme.mint.opacity(0.6), lineWidth: 1))
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityAddTraits(.updatesFrequently)
                .onAppear { AccessibilityAnnouncer.announce(text) }
        }
    }

    // MARK: - Lifecycle / device plumbing

    private func handleAppear() {
        refreshFromDisk(startTunnel: true)
        if !didInitialFit {
            didInitialFit = true
            fitAllPlaces()
        }
    }

    /// Re-read places.json (the PC may have pushed a new one) and re-check the device chain.
    private func refreshFromDisk(startTunnel: Bool) {
        store.reload()
        pairingExists = GpsSimEngine.pairingExists
        if startTunnel, pairingExists, !tunnel.isConnected {
            retryTunnel()
        }
        mounting.checkforMounted()
    }

    private func retryTunnel() {
        tunnelGraceOver = false
        // showErrorUI: false — we show our own Chinese banner instead of StikDebug's English alert.
        startTunnelInBackground(showErrorUI: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { tunnelGraceOver = true }
    }

    private func mountDDI() {
        if DeveloperDiskImageService.filesAreReady {
            MountingProgress.shared.pubMount()
            return
        }
        Task {
            do {
                try await DeveloperDiskImageService.shared.downloadMissingFiles()
                await MainActor.run { MountingProgress.shared.pubMount() }
            } catch {
                await MainActor.run {
                    engine.issue = GpsSimIssue(kind: .ddi, message: "DDI 下載失敗：\(error.localizedDescription)。請確認手機有網路後再按一次。")
                }
            }
        }
    }

    private func importPlaces(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let n = try store.importFile(url)
                engine.toast = "已匯入 \(n) 個地點"
                fitAllPlaces()
            } catch {
                store.lastLoadError = "匯入失敗：\(error.localizedDescription)"
            }
        case .failure(let error):
            store.lastLoadError = "匯入失敗：\(error.localizedDescription)"
        }
    }
}

// MARK: - Edit sheet

struct GpsPlaceEditSheet: View {
    let mapCenter: CLLocationCoordinate2D?
    let onSave: (GpsPlace) -> Void
    let onDelete: (GpsPlace) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: GpsPlace
    @State private var useDefaultRadius: Bool
    @State private var radius: Double
    @State private var confirmDelete = false
    @State private var movedNote = false

    init(place: GpsPlace, mapCenter: CLLocationCoordinate2D?,
         onSave: @escaping (GpsPlace) -> Void, onDelete: @escaping (GpsPlace) -> Void) {
        self.mapCenter = mapCenter
        self.onSave = onSave
        self.onDelete = onDelete
        _draft = State(initialValue: place)
        _useDefaultRadius = State(initialValue: place.radius == nil)
        _radius = State(initialValue: min(max(place.radius ?? GpsGeo.defaultRadius, 5), 1000))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名稱") {
                    TextField("地點名稱", text: $draft.name)
                }
                Section {
                    Toggle("使用預設半徑（\(Int(GpsGeo.defaultRadius)) 公尺）", isOn: $useDefaultRadius)
                    if !useDefaultRadius {
                        HStack {
                            Text("半徑 \(Int(radius)) 公尺").monospacedDigit()
                            Spacer()
                            Stepper("半徑", value: $radius, in: 5...1000, step: 5).labelsHidden()
                        }
                        Slider(value: $radius, in: 5...1000, step: 5)
                            .accessibilityLabel("半徑")
                    }
                } header: {
                    Text("落點半徑")
                } footer: {
                    Text("點這個地點時，會在這個圈內隨機挑一個點。")
                }
                Section {
                    Toggle("隱藏（收在「已隱藏」裡）", isOn: Binding(
                        get: { draft.isHidden },
                        set: { draft.hidden = $0 ? true : nil }
                    ))
                    Button("移到地圖中心") {
                        guard let c = mapCenter else { return }
                        draft.lat = c.latitude
                        draft.lon = c.longitude
                        movedNote = true
                    }
                    .disabled(mapCenter == nil)
                    if movedNote {
                        Text(String(format: "新位置 %.6f, %.6f（按「完成」才會存）", draft.lat, draft.lon))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    if confirmDelete {
                        Button(role: .destructive) {
                            onDelete(draft)
                            dismiss()
                        } label: {
                            Text("確定刪除「\(draft.name)」")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        Button("取消刪除") { confirmDelete = false }
                    } else {
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Text("刪除地點").frame(maxWidth: .infinity, minHeight: 44)
                        }
                    }
                }
            }
            .navigationTitle("編輯地點")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        var saved = draft
                        let trimmed = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { saved.name = trimmed }
                        // Only write a radius when the user chose one, so "預設" keeps following the setting.
                        saved.radius = useDefaultRadius ? nil : radius
                        onSave(saved)
                        dismiss()
                    }
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
