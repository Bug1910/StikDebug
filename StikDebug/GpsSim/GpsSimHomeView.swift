//
//  GpsSimHomeView.swift
//  StikDebug (GpsSim fork)
//
//  The app's root screen: status pill, edge-to-edge map with place circles, search,
//  place list. One tap on a place = send a random landing inside its circle, no confirmation;
//  a toast with "回到上一個" is the safety net instead.
//  Layout is built from fixed-size pieces (top bar, map, 55% list, 56 pt bottom bar)
//  so nothing jumps when the state changes.
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

/// Something the user picked on the map / in search, waiting for a send decision.
/// `place` set = a saved place (random landing inside its circle); nil = an exact point.
private struct GpsCandidate: Equatable {
    var coordinate: CLLocationCoordinate2D
    var title: String
    var place: GpsPlace?

    static func == (a: GpsCandidate, b: GpsCandidate) -> Bool {
        a.title == b.title && a.place?.id == b.place?.id &&
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
    var action: (() -> Void)?
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?
}

/// A toast with an optional action button. `id` lets a delayed auto-clear check it is still
/// the toast it was scheduled for (a newer toast must never be wiped by an older timer).
private struct GpsToast: Identifiable {
    let id = UUID()
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?
}

/// Own coordinate parser so the home view can say *why* a pasted pair was rejected
/// (works whatever shape GpsGeo.parseCoordinate has).
private enum GpsCoordinateInput {
    case valid(CLLocationCoordinate2D)
    case outOfRange
    case notCoordinate

    static func parse(_ text: String) -> GpsCoordinateInput {
        let normalized = text
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "、", with: ",")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = normalized
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]) else {
            return .notCoordinate
        }
        guard (-90.0...90.0).contains(lat), (-180.0...180.0).contains(lon) else { return .outOfRange }
        return .valid(CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }
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
    @State private var mapSelection: String?
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
    @State private var toast: GpsToast?
    @State private var sendingPlaceID: String?
    @FocusState private var searchFocused: Bool

    private var visiblePlaces: [GpsPlace] { store.sorted.filter { !$0.isHidden } }
    private var hiddenPlaces: [GpsPlace] { store.sorted.filter { $0.isHidden } }
    private var isSimulating: Bool { session.isActive || engine.activeName != nil }
    private var simulatedPoint: CLLocationCoordinate2D? { engine.current ?? session.coordinate }

    /// Waiting for the tunnel (first seconds after launch / retry).
    private var isConnecting: Bool { pairingExists && !tunnel.isConnected && !tunnelGraceOver }
    private var isMountingNow: Bool {
        pairingExists && tunnel.isConnected && !mounting.coolisMounted && mounting.mountingThread != nil
    }
    /// Device chain not ready: rows show orange "先打開 LocalDevVPN" instead of the normal subtitle.
    private var deviceNotReady: Bool { !tunnel.isConnected || !mounting.coolisMounted }

    var body: some View {
        // Why a fixed 55% panel instead of a bottom sheet with detents: the app already uses
        // sheets (edit, settings, importer), and a persistent sheet would fight them
        // (only one sheet at a time). A plain split layout is simpler and cannot be dismissed.
        GeometryReader { geo in
            VStack(spacing: 0) {
                topBar
                searchBar
                map
                    .frame(minHeight: 200, maxHeight: .infinity)
                    .layoutPriority(1)
                placesPanel
                    .frame(height: max(220, geo.size.height * 0.55))
            }
        }
        .ignoresSafeArea(.keyboard)
        .background(GpsTheme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(GpsTheme.mint)
        .overlay(alignment: .bottom) { toastView.padding(.bottom, 12) }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .onAppear(perform: handleAppear)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshFromDisk(startTunnel: true) }
        }
        .onChange(of: engine.toast) { _, value in
            guard let value else { return }
            showToast(value, autoClear: true)
            engine.toast = nil
        }
        .onChange(of: engine.lastSendSucceeded) { _, value in
            guard value != nil else { return }
            let name = engine.activeName ?? "新位置"
            if engine.previous != nil {
                showToast("已傳到 \(name)", actionTitle: "↩ 回到上一個", action: { engine.undoLastSend() }, autoClear: false)
            } else {
                showToast("已傳到 \(name)", autoClear: true)
            }
        }
        .onChange(of: engine.isBusy) { _, busy in
            if !busy { sendingPlaceID = nil }
        }
        .onChange(of: statusText) { _, text in
            AccessibilityAnnouncer.announce(text)
        }
        .onChange(of: mapSelection) { _, id in
            guard let id, let p = store.places.first(where: { $0.id == id }) else { return }
            clearToast()
            searchFocused = false
            candidate = GpsCandidate(coordinate: p.coordinate, title: p.name, place: p)
        }
        .sheet(item: $editing) { place in
            GpsPlaceEditSheet(
                place: place,
                mapCenter: mapCenter,
                onSave: { store.upsert($0) },
                onDelete: { deletePlace($0) }
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
            Text("半徑先用預設 \(Int(defaultRadius)) 公尺，之後可按鉛筆圖示修改。")
        }
    }

    // MARK: - Top bar / status

    private var topBar: some View {
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
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            // Spinner lives inside the pill so connecting/sending never adds a row.
            if engine.isBusy || isConnecting || isMountingNow { ProgressView() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(GpsTheme.card, in: Capsule())
        .overlay(Capsule().stroke(isSimulating ? GpsTheme.mint.opacity(0.6) : GpsTheme.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        if isSimulating {
            let name = engine.activeName ?? "外部連結的位置"
            if let center = engine.activeCenter, let cur = simulatedPoint {
                let d = Int(GpsGeo.meters(center, cur).rounded())
                return "模擬中：\(name)（離圓心 \(d) 公尺）"
            }
            return "模擬中：\(name)"
        }
        if isConnecting { return "正在連線手機…" }
        if isMountingNow { return "正在掛載開發者磁碟映像…" }
        return "真實位置"
    }

    // MARK: - Bottom bar (fixed height, never changes size)

    private var bottomBar: some View {
        Group {
            if isSimulating {
                Button {
                    clearToast()
                    engine.stop()
                } label: {
                    Text("⏹ 停止模擬")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .foregroundStyle(.white)
                        .background(GpsTheme.red, in: RoundedRectangle(cornerRadius: 14))
                }
                .disabled(engine.isBusy)
                .accessibilityHint("讓手機回到真實位置")
            } else {
                Text("真實位置")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .foregroundStyle(GpsTheme.sub)
                    .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(GpsTheme.background)
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
        clearToast()
        searchMessage = nil
        switch GpsCoordinateInput.parse(q) {
        case .valid(let c):
            searchResults = []
            setCandidate(c, title: String(format: "%.6f, %.6f", c.latitude, c.longitude))
            searchFocused = false
            return
        case .outOfRange:
            searchResults = []
            searchMessage = "座標超出範圍：緯度要在 -90～90、經度要在 -180～180，請檢查有沒有填反。"
            return
        case .notCoordinate:
            break
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

    private func coordinate(of item: MKMapItem) -> CLLocationCoordinate2D {
        if #available(iOS 26, *) {
            return item.location.coordinate
        }
        return item.placemark.coordinate
    }

    private func addressText(of item: MKMapItem) -> String? {
        if #available(iOS 26, *) {
            return item.address?.fullAddress
        }
        return item.placemark.title
    }

    // MARK: - Map

    private var map: some View {
        MapReader { proxy in
            Map(position: $position, selection: $mapSelection) {
                ForEach(visiblePlaces) { p in
                    MapCircle(center: p.coordinate, radius: GpsGeo.radius(of: p))
                        .foregroundStyle(GpsTheme.yellow.opacity(0.18))
                        .stroke(GpsTheme.yellow, lineWidth: 1.5)
                }
                ForEach(visiblePlaces) { p in
                    Marker(p.name, coordinate: p.coordinate)
                        .tint(GpsTheme.yellow)
                        .tag(p.id)
                }
                if let c = candidate, c.place == nil {
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
                clearToast()
                searchFocused = false
                mapSelection = nil
                // Inside a saved circle -> that place (random landing); otherwise the exact point.
                if let hit = placeContaining(c) {
                    candidate = GpsCandidate(coordinate: hit.coordinate, title: hit.name, place: hit)
                } else {
                    candidate = GpsCandidate(
                        coordinate: c,
                        title: String(format: "%.6f, %.6f", c.latitude, c.longitude),
                        place: nil
                    )
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let c = candidate {
                candidateCard(c)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
    }

    /// Nearest-centre place whose circle contains the point.
    private func placeContaining(_ c: CLLocationCoordinate2D) -> GpsPlace? {
        visiblePlaces
            .map { (place: $0, dist: GpsGeo.meters($0.coordinate, c)) }
            .filter { $0.dist <= GpsGeo.radius(of: $0.place) }
            .min { $0.dist < $1.dist }?
            .place
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
        candidate = GpsCandidate(coordinate: c, title: title, place: nil)
        focus(on: c, radius: GpsGeo.defaultRadius)
    }

    // MARK: - Places panel

    private var placesPanel: some View {
        List {
            ForEach(banners) { b in
                bannerView(b).listRowStyle()
            }
            if let msg = searchMessage {
                Text(msg)
                    .font(.subheadline)
                    .foregroundStyle(GpsTheme.sub)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowStyle()
            }
            ForEach(searchResults, id: \.self) { item in
                searchRow(item).listRowStyle()
            }
            if store.places.isEmpty {
                emptyState.listRowStyle()
            } else {
                ForEach(visiblePlaces) { p in
                    placeRow(p)
                        .listRowStyle()
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                deletePlace(p)
                            } label: {
                                Label("刪除", systemImage: "trash")
                            }
                            Button {
                                editing = p
                            } label: {
                                Label("編輯", systemImage: "pencil")
                            }
                            .tint(GpsTheme.blue)
                        }
                }
                if !hiddenPlaces.isEmpty {
                    Button {
                        withAnimation { showHidden.toggle() }
                    } label: {
                        Text(showHidden ? "‹ 收起已隱藏地點" : "👁 顯示 \(hiddenPlaces.count) 個已隱藏地點")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(GpsTheme.sub)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .listRowStyle()
                    if showHidden {
                        ForEach(hiddenPlaces) { p in
                            placeRow(p).opacity(0.75)
                                .listRowStyle()
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        deletePlace(p)
                                    } label: {
                                        Label("刪除", systemImage: "trash")
                                    }
                                    Button {
                                        editing = p
                                    } label: {
                                        Label("編輯", systemImage: "pencil")
                                    }
                                    .tint(GpsTheme.blue)
                                }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(GpsTheme.background)
        .refreshable {
            refreshFromDisk(startTunnel: false)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("還沒有地點").font(.headline).foregroundStyle(.white)
            Text("匯入電腦版的 places.json，或在地圖上點一下新增。")
                .font(.subheadline)
                .foregroundStyle(GpsTheme.sub)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button {
                    showPlacesImporter = true
                } label: {
                    Text("匯入地點檔")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(GpsTheme.background)
                        .background(GpsTheme.mint, in: RoundedRectangle(cornerRadius: 12))
                }
                Button {
                    addByMapTap()
                } label: {
                    Text("點地圖新增")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(GpsTheme.mint)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(GpsTheme.mint, lineWidth: 1.5))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 14))
    }

    /// Puts a candidate at the current map centre so "＋ 存成地點" is one tap away.
    private func addByMapTap() {
        let c = mapCenter ?? GpsTheme.taiwanRegion.center
        candidate = GpsCandidate(
            coordinate: c,
            title: String(format: "%.6f, %.6f", c.latitude, c.longitude),
            place: nil
        )
        showToast("先把地圖移到想要的位置，點一下地圖，再按「＋ 存成地點」", autoClear: true)
    }

    private func placeRow(_ p: GpsPlace) -> some View {
        let active = engine.activePlaceID == p.id && isSimulating
        var parts: [String] = []
        if let county = p.county { parts.append(county) }
        parts.append("半徑 \(Int(GpsGeo.radius(of: p).rounded())) m")
        let subtitle = parts.joined(separator: " · ")
        return HStack(spacing: 0) {
            Button {
                clearToast()
                searchFocused = false
                sendingPlaceID = p.id
                focus(on: p.coordinate, radius: GpsGeo.radius(of: p))
                engine.send(place: p)
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.name)
                            .font(.headline)
                            .foregroundStyle(active ? GpsTheme.mint : .white)
                            .lineLimit(nil)
                        if deviceNotReady {
                            Text("先打開 LocalDevVPN")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(GpsTheme.orange)
                                .lineLimit(nil)
                        } else {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(GpsTheme.sub)
                                .lineLimit(nil)
                        }
                    }
                    Spacer(minLength: 0)
                    if sendingPlaceID == p.id && engine.isBusy { ProgressView() }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.vertical, 10)
                .padding(.leading, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(engine.isBusy)
            .accessibilityLabel(deviceNotReady ? "\(p.name)，先打開 LocalDevVPN" : "\(p.name)，\(subtitle)")
            .accessibilityHint("點一下就把手機定位傳到這裡")

            Button {
                editing = p
            } label: {
                Image(systemName: "pencil")
                    .font(.body)
                    .foregroundStyle(GpsTheme.sub)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("編輯\(p.name)")
        }
        .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(active ? GpsTheme.mint : GpsTheme.line, lineWidth: 1))
        .contextMenu {
            Button {
                editing = p
            } label: {
                Label("編輯", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deletePlace(p)
            } label: {
                Label("刪除", systemImage: "trash")
            }
        }
    }

    private func deletePlace(_ p: GpsPlace) {
        clearToast()
        store.delete(id: p.id)
        showToast("已刪除「\(p.name)」", actionTitle: "復原", action: { store.undoDelete() }, autoClear: false)
    }

    private func searchRow(_ item: MKMapItem) -> some View {
        Button {
            let c = coordinate(of: item)
            searchResults = []
            searchFocused = false
            setCandidate(c, title: item.name ?? String(format: "%.6f, %.6f", c.latitude, c.longitude))
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name ?? "（未命名）").font(.body.weight(.semibold)).foregroundStyle(.white)
                if let sub = addressText(of: item) {
                    Text(sub).font(.footnote).foregroundStyle(GpsTheme.sub).lineLimit(nil)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Candidate card (floats over the bottom of the map, so the list never shifts)

    private func candidateCard(_ c: GpsCandidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.title).font(.headline).foregroundStyle(.white).lineLimit(nil)
                    Text(String(format: "%.6f, %.6f", c.coordinate.latitude, c.coordinate.longitude))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(GpsTheme.sub)
                        .textSelection(.enabled)
                }
                Spacer()
                Button {
                    candidate = nil
                    mapSelection = nil
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(GpsTheme.sub)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("關閉")
            }
            if let place = c.place {
                Button {
                    clearToast()
                    sendingPlaceID = place.id
                    engine.send(place: place)
                } label: {
                    Text("傳到「\(place.name)」（圈內隨機）")
                        .font(.headline)
                        .lineLimit(nil)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(GpsTheme.background)
                        .background(GpsTheme.mint, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(engine.isBusy)
            } else {
                HStack(spacing: 8) {
                    Button {
                        clearToast()
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
        showToast("已存成地點：\(place.name)", autoClear: true)
    }

    // MARK: - Banners (errors only; "connecting" lives in the status pill)

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
                    title: "LocalDevVPN 沒開：到主畫面打開它 → 回來按重試",
                    detail: "",
                    buttonTitle: "重試",
                    action: { retryTunnel() }
                ))
            }
        } else if !mounting.coolisMounted, mounting.mountingThread == nil {
            list.append(GpsBanner(
                id: "ddi", color: GpsTheme.orange,
                title: "開發者磁碟映像（DDI）尚未掛載",
                detail: "模擬定位需要先掛載 DDI，按右邊按鈕（第一次會先下載，約數十 MB）。",
                buttonTitle: "掛載 DDI",
                action: { mountDDI() }
            ))
        }
        if let issue = engine.issue {
            var banner = GpsBanner(
                id: "issue", color: GpsTheme.red,
                title: "定位沒有送出",
                detail: issue.message,
                buttonTitle: "知道了",
                action: { engine.issue = nil }
            )
            // Error code 1 = target IP changed away from LocalDevVPN's default. DeviceConnectionContext
            // has no reset function, so write the default back to the same UserDefaults key it reads.
            if issue.message.hasPrefix("目標 IP") {
                banner.secondaryTitle = "改回預設"
                banner.secondaryAction = {
                    UserDefaults.standard.set(DeviceConnectionContext.defaultTargetIPAddress,
                                              forKey: UserDefaults.Keys.targetDeviceIP)
                    engine.issue = nil
                    retryTunnel()
                }
            }
            list.append(banner)
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
                Text(b.title).font(.subheadline.weight(.bold)).foregroundStyle(.white).lineLimit(nil)
                if !b.detail.isEmpty {
                    Text(b.detail).font(.footnote).foregroundStyle(GpsTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                if let title = b.buttonTitle, let action = b.action {
                    bannerButton(title, color: b.color, action: action)
                }
                if let title = b.secondaryTitle, let action = b.secondaryAction {
                    bannerButton(title, color: b.color, action: action)
                }
            }
        }
        .padding(10)
        .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private func bannerButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(color.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Toast

    private func showToast(_ text: String, actionTitle: String? = nil, action: (() -> Void)? = nil, autoClear: Bool) {
        let new = GpsToast(text: text, actionTitle: actionTitle, action: action)
        toast = new
        AccessibilityAnnouncer.announce(text)
        if autoClear {
            // Compare ids so an older timer never wipes a newer toast.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if toast?.id == new.id { toast = nil }
            }
        }
    }

    private func clearToast() {
        toast = nil
    }

    @ViewBuilder
    private var toastView: some View {
        if let t = toast {
            HStack(spacing: 12) {
                Text(t.text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(nil)
                if let title = t.actionTitle, let action = t.action {
                    Button {
                        let id = t.id
                        action()
                        if toast?.id == id { toast = nil }
                    } label: {
                        Text(title)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(GpsTheme.mint)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(GpsTheme.card, in: Capsule())
            .overlay(Capsule().stroke(GpsTheme.mint.opacity(0.6), lineWidth: 1))
            .padding(.horizontal, 16)
            .transition(.opacity)
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
                showToast("已匯入 \(n) 個地點", autoClear: true)
                fitAllPlaces()
            } catch {
                store.lastLoadError = "匯入失敗：\(error.localizedDescription)"
            }
        case .failure(let error):
            store.lastLoadError = "匯入失敗：\(error.localizedDescription)"
        }
    }
}

private extension View {
    /// Transparent, separator-free, tightly inset List row so rows look like the old card stack.
    func listRowStyle() -> some View {
        self
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }
}

// MARK: - Edit sheet

struct GpsPlaceEditSheet: View {
    let mapCenter: CLLocationCoordinate2D?
    let onSave: (GpsPlace) -> Void
    let onDelete: (GpsPlace) -> Void

    @Environment(\.dismiss) private var dismiss
    private let original: GpsPlace
    @State private var draft: GpsPlace
    @State private var useDefaultRadius: Bool
    @State private var radius: Double
    @State private var radiusTouched = false
    @State private var showDeleteDialog = false
    @State private var movedNote = false

    init(place: GpsPlace, mapCenter: CLLocationCoordinate2D?,
         onSave: @escaping (GpsPlace) -> Void, onDelete: @escaping (GpsPlace) -> Void) {
        self.mapCenter = mapCenter
        self.onSave = onSave
        self.onDelete = onDelete
        original = place
        _draft = State(initialValue: place)
        _useDefaultRadius = State(initialValue: place.radius == nil)
        // No clamping here: an existing 2000 m radius must survive opening and saving the sheet.
        _radius = State(initialValue: max(place.radius ?? GpsGeo.defaultRadius, 5))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名稱") {
                    TextField("地點名稱", text: $draft.name)
                }
                Section {
                    Toggle("使用預設半徑（\(Int(GpsGeo.defaultRadius)) 公尺）", isOn: Binding(
                        get: { useDefaultRadius },
                        set: { useDefaultRadius = $0; radiusTouched = true }
                    ))
                    if !useDefaultRadius {
                        let radiusBinding = Binding<Double>(
                            get: { radius },
                            set: { radius = $0; radiusTouched = true }
                        )
                        HStack {
                            Text("半徑 \(Int(radius)) 公尺").monospacedDigit().lineLimit(nil)
                            Spacer()
                            Stepper("半徑", value: radiusBinding, in: 5...max(5000, radius), step: 5).labelsHidden()
                        }
                        if radius <= 1000 {
                            Slider(value: radiusBinding, in: 5...1000, step: 5)
                                .accessibilityLabel("半徑")
                        }
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
                    Button(role: .destructive) {
                        showDeleteDialog = true
                    } label: {
                        Text("刪除地點").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .confirmationDialog("刪除「\(draft.name)」？", isPresented: $showDeleteDialog, titleVisibility: .visible) {
                        Button("刪除", role: .destructive) {
                            onDelete(original)
                            dismiss()
                        }
                        Button("取消", role: .cancel) {}
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
                        // nil = follow the default setting; untouched = keep exactly what was stored.
                        if useDefaultRadius {
                            saved.radius = nil
                        } else if radiusTouched {
                            saved.radius = radius
                        } else {
                            saved.radius = original.radius
                        }
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
