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
import Combine
import MapKit
import CoreLocation
import UniformTypeIdentifiers

enum GpsTheme {
    static let background = Color(red: 0.047, green: 0.067, blue: 0.102)   // #0C111A
    static let card = Color(red: 0.078, green: 0.106, blue: 0.153)         // #141B27
    static let line = Color.white.opacity(0.10)
    static let mint = Color(red: 0.239, green: 0.961, blue: 0.769)         // #3DF5C4
    static let yellow = Color(red: 0.918, green: 0.702, blue: 0.031)       // #EAB308
    static let red = Color(red: 0.937, green: 0.267, blue: 0.267)          // #EF4444
    static let orange = Color(red: 0.976, green: 0.451, blue: 0.086)       // #F97316
    static let blue = Color(red: 0.231, green: 0.510, blue: 0.965)         // #3B82F6
    static let sub = Color(red: 0.604, green: 0.643, blue: 0.698)          // #9AA4B2
    static let stopRed = Color(red: 0.706, green: 0.137, blue: 0.165)      // #B4232A
    static let panelTop = Color(red: 0.075, green: 0.106, blue: 0.161)     // #131B29

    /// Stable per-place hue: FNV-1a over the id's UTF-8 bytes (never hashValue, which changes per launch).
    static func hue(for id: String) -> Color {
        var h: UInt32 = 2_166_136_261
        for byte in id.utf8 {
            h ^= UInt32(byte)
            h = h &* 16_777_619
        }
        return Color(hue: Double(h % 360) / 360.0, saturation: 0.38, brightness: 1.0)
    }

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
    /// `swapped` is the lat/lon-reversed pair when that would be valid (the UI can offer 「對調」).
    case outOfRange(swapped: CLLocationCoordinate2D?)
    /// Two parts where one is a number and the other is not; never sent to MKLocalSearch.
    case malformed(String)
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
        guard parts.count == 2 else { return .notCoordinate }
        let first = Double(parts[0])
        let second = Double(parts[1])
        guard let lat = first, let lon = second else {
            if first == nil && second == nil { return .notCoordinate }
            let which = first == nil ? "緯度" : "經度"
            return .malformed("座標格式不對：\(which)不是數字（範例：24.1443, 120.6851）")
        }
        guard (-90.0...90.0).contains(lat), (-180.0...180.0).contains(lon) else {
            let swappedValid = (-90.0...90.0).contains(lon) && (-180.0...180.0).contains(lat)
            return .outOfRange(swapped: swappedValid ? CLLocationCoordinate2D(latitude: lon, longitude: lat) : nil)
        }
        return .valid(CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }
}

struct GpsSimHomeView: View {
    @ObservedObject private var engine = GpsSimEngine.shared
    @ObservedObject private var store = GpsPlaceStore.shared
    @ObservedObject private var session = LocationSimulationSession.shared
    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var mounting = MountingProgress.shared
    @ObservedObject private var network = GpsSimNetwork.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(GpsGeo.defaultRadiusKey) private var defaultRadius: Double = 25

    /// Satellite (hybrid: imagery + road names) by default; the owner asked for it 2026-10-15.
    @AppStorage("gpsSim.mapSatellite") private var mapSatellite = true
    @State private var position: MapCameraPosition = .region(GpsTheme.taiwanRegion)
    @State private var mapSelection: String?
    @State private var mapCenter: CLLocationCoordinate2D?
    @State private var candidate: GpsCandidate?
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var isSearching = false
    @State private var searchMessage: String?
    /// Lat/lon swapped version of an out-of-range paste, offered via the 「對調」 button.
    @State private var swappedSuggestion: CLLocationCoordinate2D?
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
    @State private var topHeight: CGFloat = 120
    /// Ticks every second so cards and map re-evaluate freshness together with the pill.
    @State private var now = Date()
    @FocusState private var searchFocused: Bool

    private var visiblePlaces: [GpsPlace] { store.sorted.filter { !$0.isHidden } }
    private var hiddenPlaces: [GpsPlace] { store.sorted.filter { $0.isHidden } }
    private var isSimulating: Bool { session.isActive || engine.activeName != nil }
    private var simulatedPoint: CLLocationCoordinate2D? { engine.current ?? session.coordinate }

    /// Waiting for the tunnel (first seconds after launch / retry).
    /// Screenshot demo (`-GpsSimDemo <state>`); nil in normal use, which leaves every path untouched.
    private static let demoState: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-GpsSimDemo"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()
    /// Demo states other than "error" pretend the phone chain is healthy.
    private var demoReady: Bool { Self.demoState != nil && !demoIsError }

    /// The location link (simulate_location's own "StikDebugLocation" tunnel) is separate from
    /// TunnelManager's JIT tunnel, which can't come up on 4G. A send or resend accepted in the
    /// last 15 s proves the link works, so the UI must not call it disconnected (seen 2026-10-15).
    private var locationLinkAlive: Bool {
        guard !engine.connectionLost, let t = engine.lastSendSucceeded, engine.activeName != nil else { return false }
        return Date().timeIntervalSince(t) <= 15
    }
    private var linkUp: Bool { tunnel.isConnected || locationLinkAlive }

    private var isConnecting: Bool { !demoReady && pairingExists && !linkUp && !tunnelGraceOver }
    private var isMountingNow: Bool {
        !demoReady && pairingExists && tunnel.isConnected && !mounting.coolisMounted && mounting.mountingThread != nil
    }
    /// Device chain not ready: rows show orange "先打開 LocalDevVPN" instead of the normal subtitle.
    private var deviceNotReady: Bool { !demoReady && !locationLinkAlive && (!tunnel.isConnected || !mounting.coolisMounted) }
    private var deviceHint: String {
        if isConnecting { return "連線中…" }
        if !linkUp && engine.activeName != nil { return GpsSimNetwork.disconnectedHint }
        return network.onWiFi ? network.deviceHint(tunnelConnected: tunnel.isConnected) : "先連上 Wi-Fi"
    }
    /// Any of the `simulating*` demo states.
    private var demoSimulating: Bool { Self.demoState?.hasPrefix("simulating") == true }
    private var demoIsError: Bool {
        ["error", "errorNoWifi", "errorVPN"].contains(Self.demoState ?? "")
    }

    /// Screenshot-only: `-GpsSimDemoWidth <pt>` (and optional `-GpsSimDemoHeight <pt>`), honoured only
    /// together with `-GpsSimDemo`. Squeezes the screen to that size so CI can show Display Zoom widths.
    private static func demoSize(_ key: String) -> CGFloat? {
        guard demoState != nil else { return nil }
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: key), i + 1 < args.count, let v = Double(args[i + 1]), v > 0 else { return nil }
        return CGFloat(v)
    }

    var body: some View {
        if let width = Self.demoSize("-GpsSimDemoWidth") {
            let height = Self.demoSize("-GpsSimDemoHeight")
            ZStack {
                Color(white: 0.5).ignoresSafeArea()
                mainContent
                    .frame(width: width, height: height)
                    .clipped()
            }
        } else {
            mainContent
        }
    }

    private var mainContent: some View {
        // Why a fixed 55% panel instead of a bottom sheet with detents: the app already uses
        // sheets (edit, settings, importer), and a persistent sheet would fight them
        // (only one sheet at a time). A plain split layout is simpler and cannot be dismissed.
        GeometryReader { geo in
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    topBar
                    searchBar
                }
                .background(GpsTopHeightReader())
                map
                    .frame(minHeight: 200, maxHeight: .infinity)
                    .layoutPriority(1)
                placesPanel
                    .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
                    .frame(height: max(176, min(geo.size.height * 0.46, geo.size.height - topHeight - 200)))
            }
        }
        .ignoresSafeArea(.keyboard)
        .background(GpsTheme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(GpsTheme.mint)
        .overlay(alignment: .bottom) { toastView.padding(.bottom, 66) }
        .onPreferenceChange(GpsTopHeightKey.self) { topHeight = $0 }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { d in if isSimulating { now = d } }
        .onAppear(perform: handleAppear)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshFromDisk(startTunnel: true) }
        }
        .onChange(of: engine.toast) { _, value in
            guard let value else { return }
            // After a stop the previous target is the one just stopped: offer a 10 s undo.
            if value == "已回到真實位置", engine.previous != nil {
                showToast(value, actionTitle: "復原", action: { engine.undoLastSend() }, autoClear: true, duration: 10)
            } else {
                showToast(value, autoClear: true)
            }
            engine.toast = nil
        }
        // `landing` changes only on a real send (resend ticks only move `current`), so keying on it
        // avoids re-toasting every 4 s heartbeat.
        .onChange(of: engine.landing.map { "\($0.latitude),\($0.longitude)" }) { _, key in
            guard key != nil else { return }
            let name = engine.activeName ?? "新位置"
            if engine.previous != nil {
                showToast("已換到 \(name)", actionTitle: "復原", action: { engine.undoLastSend() }, autoClear: true, duration: 10)
            } else {
                showToast("已傳到 \(name)", autoClear: true)
            }
        }
        .onChange(of: store.places.count) { _, _ in fitAllPlaces() }
        .onChange(of: engine.isBusy) { _, busy in
            if !busy { sendingPlaceID = nil }
        }
        // Only state changes are announced; sends are announced by their toast.
        .onChange(of: isSimulating) { _, simulating in
            if !simulating { AccessibilityAnnouncer.announce("已回到真實位置") }
        }
        .onChange(of: tunnel.isConnected) { _, connected in
            guard connected || !locationLinkAlive else { return }
            AccessibilityAnnouncer.announce(connected ? "已連上手機" : "和手機的連線中斷")
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
            // A sheet is its own presentation: the root's .preferredColorScheme does not reach it,
            // so in light system appearance it came up white-on-white.
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showSettings, onDismiss: { refreshFromDisk(startTunnel: true) }) {
            GpsSimSettingsView(onImportPlaces: {
                showSettings = false
                // Let the settings sheet finish dismissing before presenting the picker.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showPlacesImporter = true }
            })
            .preferredColorScheme(.dark)
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
        HStack(spacing: 8) {
            statusPill
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(GpsTheme.card, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("設定")
            .accessibilityIdentifier("btn.settings")
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 2)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    /// Fresh = the phone accepted a point within the last 15 s (heartbeat is every 4 s).
    /// Only then do the pulse and the mint stroke show, so the animation never claims more than we know.
    private func confirmation(at now: Date) -> (fresh: Bool, age: Int?) {
        guard engine.activeName != nil else { return (false, nil) }
        if let demo = Self.demoState {
            if demo == "simulating" { return (true, 3) }
            if demo == "simulatingStale" { return (false, nil) }
        }
        guard engine.statusNote == nil, let t = engine.lastSendSucceeded else { return (false, nil) }
        let age = max(Int(now.timeIntervalSince(t)), 0)
        return (age <= 15, age)
    }

    private var statusPill: some View {
        // TimelineView ticks once a second so 「N 秒前」 and the 15 s freshness limit stay current.
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            let conf = confirmation(at: context.date)
            let line = statusLine(stale: isSimulating && !conf.fresh)
            HStack(spacing: 8) {
                GpsPulseDot(fresh: conf.fresh, active: isSimulating)
                VStack(alignment: .leading, spacing: 0) {
                    Text(line)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if conf.fresh, let age = conf.age {
                        Text("已確認 · \(age) 秒前")
                            .font(.caption2)
                            .foregroundStyle(GpsTheme.sub)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                // Spinner lives inside the pill so connecting/sending never adds a row.
                if engine.isBusy || isConnecting || isMountingNow { ProgressView() }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40, alignment: .leading)
            .background(GpsTheme.card, in: Capsule())
            .overlay(Capsule().stroke(conf.fresh ? GpsTheme.mint.opacity(0.5) : GpsTheme.line, lineWidth: 1))
            .contentShape(Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line)
            .accessibilityValue(conf.fresh ? "已確認" : "")
            .onTapGesture {
                if !isSimulating { showToast("目前沒有在模擬，點下面的地點就會開始", autoClear: true) }
            }
        }
    }

    /// Always plain text (never only color or animation). `stale` = simulating but not freshly confirmed.
    private func statusLine(stale: Bool) -> String {
        if let note = engine.statusNote { return note }
        if isSimulating {
            let name = engine.activeName ?? "外部連結的位置"
            if stale { return "已定位：\(name)（連線中斷，未確認）" }
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

    // MARK: - Bottom bar (fixed 56 pt in both states, so nothing jumps)

    private var showsBackButton: Bool { engine.previous != nil || demoSimulating }

    private var bottomBar: some View {
        Group {
            if isSimulating {
                HStack(spacing: 8) {
                    if showsBackButton {
                        Button {
                            clearToast()
                            engine.undoLastSend()
                        } label: {
                            Text("回上一個")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .foregroundStyle(GpsTheme.mint)
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(GpsTheme.mint, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: 120)
                        .disabled(engine.isBusy)
                        .accessibilityIdentifier("btn.back")
                        .accessibilityHint("回到上一個定位")
                    }
                    // Single tap, no hold, no confirm: the undo toast afterwards is the safety net.
                    Button {
                        clearToast()
                        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                        engine.stop()
                    } label: {
                        Text("停止模擬（回到真實位置）")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(.white)
                            .background(GpsTheme.stopRed, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .layoutPriority(1)
                    .disabled(engine.isBusy)
                    .accessibilityIdentifier("btn.stop")
                    .accessibilityHint("讓手機回到真實位置")
                }
            } else {
                Text("點地點開始定位")
                    .font(.footnote)
                    .foregroundStyle(GpsTheme.sub)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 56)
        .padding(.horizontal, 12)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
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
                .accessibilityLabel("搜尋地點")
                .accessibilityIdentifier("search.field")
            if isSearching { ProgressView() }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchResults = []
                    searchMessage = nil
                    swappedSuggestion = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(GpsTheme.sub)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("清除搜尋")
            }
        }
        .padding(.leading, 14)
        .frame(minHeight: 44)
        .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func runSearch() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        clearToast()
        searchMessage = nil
        swappedSuggestion = nil
        switch GpsCoordinateInput.parse(q) {
        case .valid(let c):
            searchResults = []
            setCandidate(c, title: String(format: "%.6f, %.6f", c.latitude, c.longitude))
            searchFocused = false
            return
        case .malformed(let reason):
            searchResults = []
            searchMessage = reason
            return
        case .outOfRange(let swapped):
            swappedSuggestion = swapped
            searchResults = []
            searchMessage = "座標超出範圍：緯度要在 -90～90、經度要在 -180～180，請檢查有沒有填反。"
            return
        case .notCoordinate:
            break
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = q
        request.region = GpsTheme.taiwanRegion
        searchFocused = false
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
                    let hue = markColor(p)
                    let r = GpsGeo.radius(of: p)
                    MapCircle(center: p.coordinate, radius: r)
                        .foregroundStyle(hue.opacity(0.14))
                        .stroke(hue, lineWidth: 1.5)
                    // Dashed inner ring at half radius.
                    MapCircle(center: p.coordinate, radius: r * 0.5)
                        .foregroundStyle(Color.clear)
                        .stroke(hue.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                ForEach(visiblePlaces) { p in
                    Annotation(p.name, coordinate: p.coordinate, anchor: .bottom) {
                        GpsPinView(color: markColor(p))
                    }
                    .annotationTitles(.hidden)
                    .tag(p.id)
                }
                if let c = candidate, c.place == nil {
                    Marker(c.title, coordinate: c.coordinate)
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
            // Muted base map keeps overlapping hued circles readable in dark mode; hybrid keeps road names on the imagery.
            .mapStyle(mapSatellite ? .hybrid(elevation: .flat) : .standard(emphasis: .muted))
            // Circles, pins and the blue dot are duplicates of the list for VoiceOver: places are read once there.
            .accessibilityHidden(true)
            .onMapCameraChange { context in
                mapCenter = context.region.center
            }
            .onTapGesture { location in
                guard let c = proxy.convert(location, from: .local) else { return }
                clearToast()
                searchFocused = false
                // Near a place's centre/balloon or inside its circle -> that place (random landing);
                // otherwise the exact point.
                if let hit = placeHit(at: location, tapped: c, proxy: proxy) {
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
        .overlay(alignment: .topTrailing) {
            Button {
                mapSatellite.toggle()
            } label: {
                Label(mapSatellite ? "地圖" : "衛星", systemImage: mapSatellite ? "map" : "globe.asia.australia.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(GpsTheme.card.opacity(0.92), in: Capsule())
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .padding(.top, 6)
            .padding(.trailing, 10)
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            .accessibilityLabel(mapSatellite ? "切換成一般地圖" : "切換成衛星地圖")
            .accessibilityIdentifier("btn.mapStyle")
        }
    }

    /// Screen-space hit test: the marker balloon (up to 44 pt above the centre), a 22 pt
    /// touch radius around the centre, or the circle itself (radius converted to points).
    private func placeHit(at location: CGPoint, tapped c: CLLocationCoordinate2D, proxy: MapProxy) -> GpsPlace? {
        var best: (place: GpsPlace, dist: CGFloat)?
        for p in visiblePlaces {
            guard let center = proxy.convert(p.coordinate, to: .local) else { continue }
            let r = GpsGeo.radius(of: p)
            let edge = CLLocationCoordinate2D(
                latitude: p.lat,
                longitude: p.lon + r / (111_320 * max(cos(p.lat * Double.pi / 180), 0.01))
            )
            var radiusPoints: CGFloat = 0
            if let e = proxy.convert(edge, to: .local) {
                radiusPoints = hypot(e.x - center.x, e.y - center.y)
            }
            let dist = hypot(location.x - center.x, location.y - center.y)
            let inBalloon = abs(location.x - center.x) <= 22 &&
                location.y >= center.y - 44 && location.y <= center.y
            if dist <= max(22, radiusPoints) || inBalloon {
                if best == nil || dist < best!.dist { best = (p, dist) }
            }
        }
        return best?.place
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
        // Bounds include each place's radius circle (not just the pin), then 1.6x padding
        // so pins at the edge are not clipped by the top bar / candidate card.
        var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
        for p in pts {
            let r = GpsGeo.radius(of: p)
            let dLat = r / 111_320
            let dLon = r / (111_320 * max(cos(p.lat * Double.pi / 180), 0.01))
            minLat = min(minLat, p.lat - dLat); maxLat = max(maxLat, p.lat + dLat)
            minLon = min(minLon, p.lon - dLon); maxLon = max(maxLon, p.lon + dLon)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.6, 0.01),
                                    longitudeDelta: max((maxLon - minLon) * 1.6, 0.01))
        position = .region(MKCoordinateRegion(center: center, span: span))
    }

    private func setCandidate(_ c: CLLocationCoordinate2D, title: String) {
        candidate = GpsCandidate(coordinate: c, title: title, place: nil)
        focus(on: c, radius: GpsGeo.defaultRadius)
    }

    // MARK: - Places panel

    private var placesPanel: some View {
        GeometryReader { geo in
            let columnCount = geo.size.width >= 700 ? 3 : 2
            let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: columnCount)
            ScrollView {
                VStack(spacing: 10) {
                    // At most 2 device banners so they can never push every place card off a small screen.
                    ForEach(orderedBanners) { b in
                        GpsBannerRow(banner: b)
                    }
                    if let msg = searchMessage {
                        HStack(spacing: 8) {
                            Text(msg)
                                .font(.subheadline)
                                .foregroundStyle(GpsTheme.sub)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let swapped = swappedSuggestion {
                                Button {
                                    swappedSuggestion = nil
                                    searchMessage = nil
                                    setCandidate(swapped, title: String(format: "%.6f, %.6f", swapped.latitude, swapped.longitude))
                                } label: {
                                    Text("對調")
                                        .font(.subheadline.weight(.semibold))
                                        .padding(.horizontal, 14)
                                        .frame(minHeight: 44)
                                        .foregroundStyle(GpsTheme.mint)
                                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(GpsTheme.mint, lineWidth: 1.5))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    ForEach(searchResults, id: \.self) { item in
                        searchRow(item)
                    }
                    if store.places.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(visiblePlaces) { p in placeCard(p) }
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
                            if showHidden {
                                LazyVGrid(columns: columns, spacing: 10) {
                                    ForEach(hiddenPlaces) { p in placeCard(p).opacity(0.75) }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 900)
                .padding(12)
                .frame(maxWidth: .infinity)
            }
            .contentMargins(.bottom, toast == nil ? 0 : 64, for: .scrollContent)
            .refreshable {
                refreshFromDisk(startTunnel: false)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .background(
            LinearGradient(colors: [GpsTheme.panelTop, GpsTheme.background], startPoint: .top, endPoint: .bottom)
        )
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

    /// The place being simulated right now (the demo has no place id, so it fakes the first card).
    /// Map color: mint only while confirmed, grey when active but unconfirmed, else the place hue.
    private func markColor(_ p: GpsPlace) -> Color {
        guard isActivePlace(p) else { return GpsTheme.hue(for: p.id) }
        return isFresh ? GpsTheme.mint : GpsTheme.sub
    }

    private var isFresh: Bool { confirmation(at: now).fresh }

    private func isActivePlace(_ p: GpsPlace) -> Bool {
        (engine.activePlaceID == p.id && isSimulating)
            || (demoSimulating && p.id == visiblePlaces.first?.id)
    }

    private func placeCard(_ p: GpsPlace) -> some View {
        let placeActive = isActivePlace(p)
        let active = placeActive && isFresh          // mint / glow / 「模擬中」
        let unconfirmed = placeActive && !isFresh    // grey outline / 「未確認」
        let hue = GpsTheme.hue(for: p.id)
        let radiusM = Int(GpsGeo.radius(of: p).rounded())
        let county = p.county ?? ""
        let sending = sendingPlaceID == p.id && engine.isBusy
        var label = p.name
        if !county.isEmpty { label += "，\(county)" }
        label += "，半徑 \(radiusM) 公尺"
        if active { label += "，模擬中" }
        if unconfirmed { label += "，已定位未確認" }
        if deviceNotReady { label += "，\(deviceHint)" }
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return ZStack(alignment: .topTrailing) {
            Button {
                clearToast()
                searchFocused = false
                sendingPlaceID = p.id
                focus(on: p.coordinate, radius: GpsGeo.radius(of: p))
                engine.send(place: p)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(active ? GpsTheme.mint : .white)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                        .padding(.trailing, 26)
                    Spacer(minLength: 0)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(radiusM)")
                            .font(.system(.title2, design: .rounded).bold())
                            .foregroundStyle(hue)
                        Text("m")
                            .font(.caption)
                            .foregroundStyle(hue)
                        Spacer(minLength: 4)
                        // Badge slot: spinner while sending, 「模擬中」 capsule when active.
                        if sending {
                            ProgressView()
                        } else if unconfirmed {
                            Text("未確認")
                                .font(.caption2.bold())
                                .foregroundStyle(GpsTheme.background)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(GpsTheme.sub, in: Capsule())
                        } else if active {
                            Text("模擬中")
                                .font(.caption2.bold())
                                .foregroundStyle(GpsTheme.background)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(GpsTheme.mint, in: Capsule())
                        }
                    }
                    if deviceNotReady {
                        Text(deviceHint)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(GpsTheme.orange)
                            .lineLimit(1)
                    } else {
                        Text(county.isEmpty ? " " : county)
                            .font(.caption)
                            .foregroundStyle(GpsTheme.sub)
                            .lineLimit(1)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                .background(
                    ZStack {
                        shape.fill(GpsTheme.card)
                        shape.fill(LinearGradient(colors: [hue.opacity(0.16), Color.clear],
                                                  startPoint: .topLeading, endPoint: .center))
                    }
                )
                .overlay(shape.stroke(active ? GpsTheme.mint : (unconfirmed ? GpsTheme.sub : Color.white.opacity(0.06)), lineWidth: (active || unconfirmed) ? 1.5 : 1))
                .shadow(color: active ? GpsTheme.mint.opacity(0.35) : .clear, radius: 12)
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .disabled(engine.isBusy)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityHint("點一下就把手機定位傳到這裡")
            .accessibilityIdentifier("place.row.\(p.id)")
            .accessibilityAction(named: "刪除") { deletePlace(p) }

            // 28 pt visual pencil in the corner, 44 pt hit area, separate from the send tap.
            Button {
                editing = p
            } label: {
                Image(systemName: "pencil")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GpsTheme.sub)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
            .accessibilityLabel("編輯\(p.name)")
            .accessibilityIdentifier("place.edit.\(p.id)")
        }
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
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name ?? "（未命名）").font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                if let sub = addressText(of: item) {
                    Text(sub).font(.footnote).foregroundStyle(GpsTheme.sub).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 12)
            .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Candidate card (floats over the bottom of the map, so the list never shifts)

    private func candidateCard(_ c: GpsCandidate) -> some View {
        let coords = String(format: "%.6f, %.6f", c.coordinate.latitude, c.coordinate.longitude)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(c.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if c.title != coords {
                    Text(coords)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(GpsTheme.sub)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }
            HStack(spacing: 8) {
                if let place = c.place {
                    cardButton("傳到「\(place.name)」（圈內隨機）", filled: true) {
                        clearToast()
                        sendingPlaceID = place.id
                        engine.send(place: place)
                    }
                } else {
                    cardButton("📍 傳送到這裡", filled: true) {
                        clearToast()
                        // Exact point, no scatter.
                        engine.send(to: c.coordinate, name: c.title)
                    }
                    cardButton("＋ 存成地點", filled: false) {
                        newPlaceName = c.title
                        showSaveName = true
                    }
                }
                Button {
                    candidate = nil
                    mapSelection = nil
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(GpsTheme.sub)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("關閉")
            }
        }
        .padding(10)
        .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(GpsTheme.mint.opacity(0.5), lineWidth: 1))
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    private func cardButton(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(filled ? GpsTheme.background : GpsTheme.mint)
                .background(filled ? GpsTheme.mint : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(GpsTheme.mint, lineWidth: filled ? 0 : 1.5))
        }
        .buttonStyle(.plain)
        .disabled(engine.isBusy && filled)
    }

    private func saveCandidate() {
        guard let c = candidate else { return }
        let name = newPlaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = GpsPlace(
            name: name.isEmpty ? c.title : name,
            lat: c.coordinate.latitude,
            lon: c.coordinate.longitude
        )
        store.upsert(place)
        candidate = nil
        showToast("已存成地點：\(place.name)", autoClear: true)
    }

    // MARK: - Banners (errors only; "connecting" lives in the status pill)

    /// Errors (file, issue) always show first; only the device banners are capped.
    private var orderedBanners: [GpsBanner] {
        let all = banners
        let errors = all.filter { $0.id == "file" } + all.filter { $0.id == "issue" }
        let device = all.filter { $0.id != "file" && $0.id != "issue" }
        return errors + Array(device.prefix(2))
    }

    private var banners: [GpsBanner] {
        var list: [GpsBanner] = []
        if !pairingExists {
            list.append(GpsBanner(
                id: "pairing", color: GpsTheme.red,
                title: "還沒有配對檔",
                detail: "請到「設定 › 匯入配對檔」放入配對檔（檔案在電腦上用 iloader 簽名工具產生）。",
                buttonTitle: "去設定",
                action: { showSettings = true }
            ))
        } else if !demoReady && !linkUp {
            if tunnelGraceOver {
                list.append(GpsBanner(
                    id: "tunnel", color: GpsTheme.orange,
                    title: network.onWiFi ? "連不到手機" : GpsSimNetwork.noWifiTitle,
                    detail: engine.activeName != nil ? GpsSimNetwork.disconnectedHint : (network.onWiFi ? GpsSimNetwork.checkVPNMessage : GpsSimNetwork.noWifiMessage),
                    buttonTitle: "重試",
                    action: { retryTunnel() }
                ))
            }
        } else if !demoReady, !mounting.coolisMounted, mounting.mountingThread == nil {
            list.append(GpsBanner(
                id: "ddi", color: GpsTheme.orange,
                title: "DDI（開發者映像）還沒掛載",
                detail: "模擬定位需要先掛載 DDI（開發者映像），按右邊按鈕（第一次會先下載，約數十 MB）。",
                buttonTitle: "掛載 DDI",
                action: { mountDDI() }
            ))
        }
        if let issue = engine.issue, engine.activeName == nil {
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

    // MARK: - Toast

    private func showToast(_ text: String, actionTitle: String? = nil, action: (() -> Void)? = nil,
                           autoClear: Bool, duration: Double = 3) {
        let new = GpsToast(text: text, actionTitle: actionTitle, action: action)
        toast = new
        AccessibilityAnnouncer.announce(text)
        if autoClear {
            // Compare ids so an older timer never wipes a newer toast.
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
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
        if let state = Self.demoState {
            runDemo(state)
            return
        }
        refreshFromDisk(startTunnel: true)
        if !didInitialFit {
            didInitialFit = true
            fitAllPlaces()
        }
    }

    /// Screenshot states for the CI simulator job. Touches only view state and the
    /// engine's published fields; never the tunnel, DDI or device.
    private func runDemo(_ state: String) {
        store.reload()
        pairingExists = true
        tunnelGraceOver = ["error", "errorNoWifi", "errorVPN"].contains(state)
        didInitialFit = true
        fitAllPlaces()
        let first = visiblePlaces.first
        // Small delay so sheets present after the first frame is on screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            switch state {
            case "selected":
                if let p = first {
                    mapSelection = p.id
                    candidate = GpsCandidate(coordinate: p.coordinate, title: p.name, place: p)
                    focus(on: p.coordinate, radius: GpsGeo.radius(of: p))
                }
            case "simulating", "simulatingStale":
                let taipei101 = CLLocationCoordinate2D(latitude: 25.0339, longitude: 121.5645)
                engine.applyDemoSimulation(name: "台北101", coordinate: taipei101)
                focus(on: taipei101, radius: 100)
            case "edit":
                editing = first
            case "settings":
                showSettings = true
            case "search":
                searchText = "台北"
                runSearch()
            case "undoToast":
                if let p = first { deletePlace(p) }
            case "errorNoWifi":
                engine.applyDemoIssue(noWifi: true)
            case "errorVPN":
                engine.applyDemoIssue(noWifi: false)
            default:
                break   // "home" and "error" need no extra action
            }
        }
    }

    /// Re-read places.json (the PC may have pushed a new one) and re-check the device chain.
    private func refreshFromDisk(startTunnel: Bool) {
        if Self.demoState != nil {
            store.reload()
            return
        }
        store.reload()
        pairingExists = GpsSimEngine.pairingExists
        // A working location link needs no JIT tunnel; retrying it on 4G only spins.
        if startTunnel, pairingExists, !linkUp {
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

private struct GpsTopHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 120
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Reports the top bar + search bar height so the list panel can leave the map >= 200 pt.
private struct GpsTopHeightReader: View {
    var body: some View {
        GeometryReader { g in
            Color.clear.preference(key: GpsTopHeightKey.self, value: g.size.height)
        }
    }
}

/// App-icon style pin: round head with a dark hole plus a tip, drawn as a Shape.
private struct GpsPinShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r = rect.width / 2
        var path = Path()
        path.addEllipse(in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.width))
        path.move(to: CGPoint(x: rect.midX - r * 0.72, y: rect.minY + r * 1.45))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX + r * 0.72, y: rect.minY + r * 1.45))
        path.closeSubpath()
        return path
    }
}

private struct GpsPinView: View {
    let color: Color
    var body: some View {
        ZStack(alignment: .top) {
            GpsPinShape().fill(color)
            Circle()
                .fill(GpsTheme.background)
                .frame(width: 11, height: 11)
                .offset(y: 9.5)
        }
        .frame(width: 30, height: 40)
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }
}

/// Status dot. Rings pulse only while the last confirmation is fresh; static with Reduce Motion.
private struct GpsPulseDot: View {
    let fresh: Bool
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if fresh && !reduceMotion {
                GpsPulseRing(delay: 0)
                GpsPulseRing(delay: 0.8)
            }
            Circle()
                .fill(fresh ? GpsTheme.mint : (active ? Color.gray : Color.white.opacity(0.45)))
                .frame(width: 10, height: 10)
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

private struct GpsPulseRing: View {
    let delay: Double
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(GpsTheme.mint, lineWidth: 1.5)
            .frame(width: 10, height: 10)
            .scaleEffect(expanded ? 2.2 : 1)
            .opacity(expanded ? 0 : 0.6)
            .onAppear {
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false).delay(delay)) {
                    expanded = true
                }
            }
    }
}

/// One-line banner; the explanation hides behind a chevron so banners stay short.
private struct GpsBannerRow: View {
    let banner: GpsBanner
    @State private var expanded = false
    /// Error causes are shown inline; only device-setup banners use the chevron.
    private var showsDetailInline: Bool { banner.id == "issue" || banner.id == "file" || banner.id == "pairing" }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(banner.color).frame(width: 4, height: 24)
                Text(banner.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if !banner.detail.isEmpty && !showsDetailInline {
                    Button {
                        withAnimation { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .foregroundStyle(GpsTheme.sub)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "收起說明" : "展開說明")
                }
                if let title = banner.buttonTitle, let action = banner.action {
                    chip(title, action: action)
                }
                if let title = banner.secondaryTitle, let action = banner.secondaryAction {
                    chip(title, action: action)
                }
            }
            if expanded || (showsDetailInline && !banner.detail.isEmpty) {
                Text(banner.detail)
                    .font(.footnote)
                    .foregroundStyle(GpsTheme.sub)
                    .lineLimit(showsDetailInline ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 10)
                    .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityValue(banner.detail)
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(minHeight: 36)
                .background(banner.color.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    /// iPad (regular width) gets engineer C's sizing; iPhone keeps medium/large detents.
    @ViewBuilder
    func editSheetSizing(regular: Bool) -> some View {
        if regular {
            self.gpsSimPadSheetSizing()
        } else {
            self.presentationDetents([.medium, .large])
        }
    }

    /// Pill / gear background: Liquid Glass on iOS 26, the dark card material before that.
    /// Applied in place (chrome is not floated over the map; keeps the layout math simple).
    @ViewBuilder
    func gpsChrome<S: Shape>(_ shape: S, stroke: Color) -> some View {
        if #available(iOS 26, *) {
            self
                .glassEffect(.regular, in: shape)
                .overlay(shape.stroke(stroke, lineWidth: 1))
        } else {
            self
                .background(GpsTheme.card, in: shape)
                .overlay(shape.stroke(stroke, lineWidth: 1))
        }
    }

    /// Flat list row with the native separator, no card.
    func plainRowStyle() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(GpsTheme.line)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 8))
    }

    /// Transparent, separator-free, tightly inset List row so rows look like the old card stack.
    func listRowStyle() -> some View {
        self
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
    }
}

// MARK: - Edit sheet

struct GpsPlaceEditSheet: View {
    let mapCenter: CLLocationCoordinate2D?
    let onSave: (GpsPlace) -> Void
    let onDelete: (GpsPlace) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
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
        .editSheetSizing(regular: sizeClass == .regular)
    }
}
