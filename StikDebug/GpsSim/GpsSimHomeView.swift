//
//  GpsSimHomeView.swift
//  StikDebug (GpsSim fork)
//
//  The app's root screen, map first (Apple Maps / Google Maps pattern, owner 2026-10-15):
//  - full-screen satellite map, saved places are pins; tapping a pin flies there at once
//  - one floating status line + search on top, map tools on the right
//  - a bottom card with the saved places by name: one tap = fly (random point in its circle)
//  - long-press the map (or the ＋ button, or a search result) -> card with the name prefilled,
//    size 小/中/大, 「＋ 存成地點」 saves in one tap
//  - stop is one tap and always on screen while simulating; stop and switch both get a 10 s undo
//  No radius numbers, distances or "N seconds ago": the owner only wants to fly somewhere.
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

/// The three place sizes. The owner does not want metres on screen; the icon and the live
/// circle on the map show the size instead.
enum GpsSize: CaseIterable, Identifiable {
    case small, medium, large

    var id: String { axID }
    var meters: Double {
        switch self {
        case .small: return 25
        case .medium: return 100
        case .large: return 300
        }
    }
    var title: String {
        switch self {
        case .small: return "小"
        case .medium: return "中"
        case .large: return "大"
        }
    }
    var spoken: String { title + "範圍" }
    var axID: String {
        switch self {
        case .small: return "size.s"
        case .medium: return "size.m"
        case .large: return "size.l"
        }
    }
    /// Icon circle diameter in points (small/medium/large ring).
    var iconSize: CGFloat {
        switch self {
        case .small: return 8
        case .medium: return 14
        case .large: return 20
        }
    }

    /// Exact match only: a place saved with another radius (e.g. from the PC) shows no size
    /// selected and keeps its radius until one of the three is tapped.
    static func matching(_ radius: Double?) -> GpsSize? {
        let r = radius ?? GpsGeo.defaultRadius
        return allCases.first { abs($0.meters - r) < 0.5 }
    }
}

/// A new place being made (long-press, ＋ button or search result), not saved yet.
private struct GpsDraft {
    var coordinate: CLLocationCoordinate2D
    var name: String
    var nameEdited = false
    var size: GpsSize = .small
    /// ＋ button: the point follows the map centre (crosshair) until saved.
    var followsCenter = false
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

    /// Satellite (hybrid: imagery + road names) by default; the owner asked for it 2026-10-15.
    @AppStorage("gpsSim.mapSatellite") private var mapSatellite = true
    @State private var position: MapCameraPosition = .region(GpsTheme.taiwanRegion)
    @State private var mapCenter: CLLocationCoordinate2D?
    @State private var draft: GpsDraft?
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var isSearching = false
    @State private var searchMessage: String?
    /// Lat/lon swapped version of an out-of-range paste, offered via the 「對調」 button.
    @State private var swappedSuggestion: CLLocationCoordinate2D?
    @State private var editing: GpsPlace?
    @State private var managing = false
    @State private var showSettings = false
    @State private var showPlacesImporter = false
    @State private var pairingExists = GpsSimEngine.pairingExists
    @State private var tunnelGraceOver = false
    @State private var didInitialFit = false
    @State private var toast: GpsToast?
    @State private var sendingPlaceID: String?
    /// Guards against a double tap sending twice (the second tap would land somewhere else).
    @State private var lastFly: (id: String, at: Date)?
    @State private var geocoder = CLGeocoder()
    /// Ticks every second so pins and the place card re-evaluate freshness together with the status line.
    @State private var now = Date()
    @FocusState private var searchFocused: Bool
    @FocusState private var draftNameFocused: Bool

    private var visiblePlaces: [GpsPlace] { store.sorted.filter { !$0.isHidden } }
    private var isSimulating: Bool { session.isActive || engine.activeName != nil }
    private var simulatedPoint: CLLocationCoordinate2D? { engine.current ?? session.coordinate }

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
    /// lastLinkOK also counts a successful stop, so 停止 on 4G does not raise a false banner.
    private var locationLinkAlive: Bool {
        guard !engine.connectionLost, let t = engine.lastLinkOK else { return false }
        return Date().timeIntervalSince(t) <= 15
    }
    private var linkUp: Bool { tunnel.isConnected || locationLinkAlive }

    private var isConnecting: Bool { !demoReady && pairingExists && !linkUp && !tunnelGraceOver }
    private var isMountingNow: Bool {
        !demoReady && pairingExists && tunnel.isConnected && !mounting.coolisMounted && mounting.mountingThread != nil
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

    /// Floating controls never stretch wider than this (iPad keeps the map full width).
    private static let controlWidth: CGFloat = 520

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
        // Read `now` here so the 15 s freshness expiry always re-renders the whole screen.
        let _ = now
        // Map above, fixed solid panel below (owner: 「下面不用縮回去可以讓我直接點擊」).
        // The panel is not floated over the map, so pins, map text and the Apple Maps legal
        // label are never covered, and the keyboard pushes the panel up instead of hiding it.
        return VStack(spacing: 0) {
            ZStack {
                map.ignoresSafeArea(edges: [.top, .horizontal])
                if draft?.followsCenter == true {
                    GpsCrosshair().ignoresSafeArea(edges: [.top, .horizontal]).allowsHitTesting(false)
                }
                VStack(spacing: 8) {
                    topControls
                    HStack {
                        Spacer()
                        mapTools
                    }
                    .frame(maxWidth: Self.controlWidth)
                    Spacer(minLength: 0)
                    mapMessages
                        .frame(maxWidth: Self.controlWidth)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            bottomPanel
                .frame(maxWidth: Self.controlWidth)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity)
                .background(GpsTheme.background.ignoresSafeArea(edges: .bottom))
        }
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .background(GpsTheme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(GpsTheme.mint)
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
                showToast("已飛到 \(name)", autoClear: true)
            }
        }
        // Only the first places (empty -> some) refit the camera; adding one more must not jump away.
        .onChange(of: store.places.count) { old, _ in if old == 0 { fitAllPlaces() } }
        .onChange(of: engine.isBusy) { _, busy in
            if !busy { sendingPlaceID = nil }
        }
        // Only state changes are announced; sends are announced by their toast.
        .onChange(of: isSimulating) { _, simulating in
            if !simulating { AccessibilityAnnouncer.announce("已回到真實位置") }
        }
        // linkUp, not tunnel.isConnected: on 4G the JIT tunnel never changes, the location link does.
        .onChange(of: linkUp) { _, up in
            // "Down" only matters while simulating; after 停止 the link simply ages out.
            if up {
                AccessibilityAnnouncer.announce("已連上手機")
            } else if engine.activeName != nil {
                AccessibilityAnnouncer.announce("和手機的連線中斷")
            }
        }
        // Wi-Fi came back (e.g. the 4G airplane + Wi-Fi trick): the JIT tunnel can come up now.
        .onChange(of: network.onWiFi) { _, onWiFi in
            if onWiFi, Self.demoState == nil, pairingExists, !tunnel.isConnected { retryTunnel() }
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
    }

    // MARK: - Top: status line, settings, search

    private var topControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                statusPill
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.body)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(GpsTheme.card.opacity(0.94), in: Circle())
                        .overlay(Circle().stroke(GpsTheme.line, lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("設定")
                .accessibilityIdentifier("btn.settings")
            }
            searchBar
            if let msg = searchMessage {
                searchMessageRow(msg)
            }
            if !searchResults.isEmpty {
                searchResultsList
            }
        }
        .frame(maxWidth: Self.controlWidth)
        .padding(.top, 2)
    }

    /// Fresh = the phone accepted a point within the last 15 s (heartbeat is every 4 s).
    /// Only then do the pulse and the mint colour show, so the screen never claims more than we know.
    private func confirmation(at now: Date) -> Bool {
        guard engine.activeName != nil else { return false }
        if let demo = Self.demoState {
            if demo == "simulating" { return true }
            if demo == "simulatingStale" { return false }
        }
        guard !engine.connectionLost, let t = engine.lastSendSucceeded else { return false }
        return now.timeIntervalSince(t) <= 15
    }

    private var statusPill: some View {
        // TimelineView ticks once a second so the 15 s freshness limit stays current.
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            let fresh = confirmation(at: context.date)
            let line = statusLine(fresh: fresh)
            HStack(spacing: 8) {
                GpsPulseDot(fresh: fresh, active: isSimulating)
                Text(line)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                // Spinner lives inside the pill so connecting/sending never adds a row.
                if engine.isBusy || isConnecting || isMountingNow { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44, alignment: .leading)
            .background(GpsTheme.card.opacity(0.94), in: Capsule())
            .overlay(Capsule().stroke(fresh ? GpsTheme.mint.opacity(0.6) : GpsTheme.line, lineWidth: 1))
            .contentShape(Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line)
            .accessibilityIdentifier("status.pill")
            .onTapGesture {
                if !isSimulating { showToast("點下面的地點就會飛過去", autoClear: true) }
            }
        }
    }

    /// One short line, always text (never only colour or animation).
    private func statusLine(fresh: Bool) -> String {
        if let name = engine.activeName {
            return fresh ? "在 \(name)" : "\(name)・連線中斷（定位仍保留）"
        }
        if session.isActive { return "在外部連結的位置" }
        if let stale = engine.staleTarget { return "上次在 \(stale.name)（定位可能仍保留）" }
        if isConnecting { return "連線中…" }
        if isMountingNow { return "準備中…" }
        return "真實位置"
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(GpsTheme.sub)
            TextField("搜尋地點或貼上座標", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit(runSearch)
                .accessibilityLabel("搜尋地點")
                .accessibilityIdentifier("search.field")
            if isSearching { ProgressView().controlSize(.small) }
            if !searchText.isEmpty {
                Button {
                    clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(GpsTheme.sub)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜尋")
                .accessibilityIdentifier("search.clear")
            }
        }
        .padding(.leading, 14)
        .frame(minHeight: 44)
        .background(GpsTheme.card.opacity(0.94), in: Capsule())
        .overlay(Capsule().stroke(GpsTheme.line, lineWidth: 1))
    }

    private func searchMessageRow(_ msg: String) -> some View {
        HStack(spacing: 8) {
            Text(msg)
                .font(.subheadline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let swapped = swappedSuggestion {
                Button {
                    swappedSuggestion = nil
                    searchMessage = nil
                    startDraft(at: swapped, name: String(format: "%.5f, %.5f", swapped.latitude, swapped.longitude))
                } label: {
                    Text("對調")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .foregroundStyle(GpsTheme.mint)
                        .overlay(Capsule().stroke(GpsTheme.mint, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(GpsTheme.card.opacity(0.96), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var searchResultsList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(searchResults.enumerated()), id: \.offset) { i, item in
                    Button {
                        let c = coordinate(of: item)
                        searchResults = []
                        searchFocused = false
                        startDraft(at: c, name: item.name ?? String(format: "%.5f, %.5f", c.latitude, c.longitude))
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name ?? "（未命名）")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            if let sub = addressText(of: item) {
                                Text(sub).font(.footnote).foregroundStyle(GpsTheme.sub).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .padding(.horizontal, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.name ?? "未命名")
                    .accessibilityHint("在地圖上標出，可以存成地點")
                    .accessibilityIdentifier("search.result.\(i)")
                    if i < searchResults.count - 1 {
                        Rectangle().fill(GpsTheme.line).frame(height: 1).padding(.leading, 14)
                    }
                }
            }
        }
        .frame(maxHeight: 260)
        .fixedSize(horizontal: false, vertical: true)
        .background(GpsTheme.card.opacity(0.97), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func clearSearch() {
        searchText = ""
        searchResults = []
        searchMessage = nil
        swappedSuggestion = nil
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
            searchFocused = false
            startDraft(at: c, name: String(format: "%.5f, %.5f", c.latitude, c.longitude))
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
                searchResults = Array(items.prefix(6))
                searchMessage = items.isEmpty ? "找不到「\(q)」。換個關鍵字，或長按地圖直接新增。" : nil
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

    // MARK: - Map tools (right edge, Apple Maps style)

    private var mapTools: some View {
        VStack(spacing: 8) {
            Button {
                mapSatellite.toggle()
            } label: {
                Image(systemName: mapSatellite ? "map" : "globe.asia.australia.fill")
                    .font(.body)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(GpsTheme.card.opacity(0.94), in: Circle())
                    .overlay(Circle().stroke(GpsTheme.line, lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(mapSatellite ? "切換成一般地圖" : "切換成衛星地圖")
            .accessibilityIdentifier("btn.mapStyle")
            if !store.places.isEmpty {
                Button {
                    clearToast()
                    draft = nil
                    fitAllPlaces(animated: true)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.body)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(GpsTheme.card.opacity(0.94), in: Circle())
                        .overlay(Circle().stroke(GpsTheme.line, lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("看全部地點")
                .accessibilityIdentifier("btn.fitAll")
                Button {
                    clearToast()
                    draft = nil
                    managing.toggle()
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.body)
                        .foregroundStyle(managing ? GpsTheme.background : .white)
                        .frame(width: 44, height: 44)
                        .background(managing ? GpsTheme.mint : GpsTheme.card.opacity(0.94), in: Circle())
                        .overlay(Circle().stroke(GpsTheme.line, lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("管理地點")
                .accessibilityHint("改名、改範圍、隱藏或刪除")
                .accessibilityIdentifier("btn.editPlaces")
            }
        }
    }

    // MARK: - Map

    /// Pins: white normally, mint while confirmed there, grey while there but unconfirmed.
    private func pinColor(_ p: GpsPlace) -> Color {
        guard isActivePlace(p) else { return .white }
        return confirmation(at: now) ? GpsTheme.mint : GpsTheme.sub
    }

    private var draftPoint: CLLocationCoordinate2D? {
        guard let d = draft else { return nil }
        return d.followsCenter ? (mapCenter ?? d.coordinate) : d.coordinate
    }

    private var map: some View {
        MapReader { proxy in
            Map(position: $position) {
                ForEach(visiblePlaces) { p in
                    let c = pinColor(p)
                    MapCircle(center: p.coordinate, radius: GpsGeo.radius(of: p))
                        .foregroundStyle(c.opacity(isActivePlace(p) ? 0.18 : 0.10))
                        .stroke(c.opacity(0.85), lineWidth: 1.5)
                }
                ForEach(visiblePlaces) { p in
                    Annotation(p.name, coordinate: p.coordinate, anchor: .bottom) {
                        GpsPinView(color: pinColor(p))
                    }
                }
                if let point = draftPoint, let d = draft {
                    MapCircle(center: point, radius: d.size.meters)
                        .foregroundStyle(GpsTheme.mint.opacity(0.16))
                        .stroke(GpsTheme.mint, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    if !d.followsCenter {
                        Annotation(d.name, coordinate: point, anchor: .bottom) {
                            GpsPinView(color: GpsTheme.mint)
                        }
                        .annotationTitles(.hidden)
                    }
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
            // Hybrid keeps road names on the imagery; the muted standard map keeps white pins readable.
            .mapStyle(mapSatellite ? .hybrid(elevation: .flat) : .standard(emphasis: .muted))
            .mapControls { MapCompass() }
            // Pins duplicate the place card for VoiceOver: places are read once there.
            .accessibilityHidden(true)
            .onMapCameraChange(frequency: .continuous) { context in
                mapCenter = context.region.center
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                if draft?.followsCenter == true { suggestName(for: context.region.center) }
            }
            .onTapGesture { location in
                guard let c = proxy.convert(location, from: .local) else { return }
                searchFocused = false
                draftNameFocused = false
                if var d = draft {
                    // While making a place, a tap moves its point (quick correction).
                    if !d.followsCenter {
                        d.coordinate = c
                        draft = d
                        suggestName(for: c)
                    }
                    return
                }
                if let hit = placeHit(at: location, proxy: proxy) { fly(hit) }
            }
            // Long-press anywhere -> new place there (Apple Maps "drop a pin"). The drag after the
            // press only exists to read where the finger is; the ＋ button is the visible alternative.
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.45)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                    .onEnded { value in
                        guard case .second(true, let drag?) = value,
                              let c = proxy.convert(drag.location, from: .local) else { return }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        startDraft(at: c, name: nil)
                    }
            )
        }
    }

    /// Screen-space hit test: the pin (up to 44 pt above the centre), a 22 pt touch radius
    /// around the centre, or the circle itself (radius converted to points).
    private func placeHit(at location: CGPoint, proxy: MapProxy) -> GpsPlace? {
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
            let inPin = abs(location.x - center.x) <= 22 &&
                location.y >= center.y - 44 && location.y <= center.y
            if dist <= max(22, radiusPoints) || inPin {
                if best == nil || dist < best!.dist { best = (p, dist) }
            }
        }
        return best?.place
    }

    /// The top controls cover the upper part of the map, so the camera aims a little north
    /// (negative lift) and the point sits slightly below the middle of the visible map.
    private static let cameraLift = -0.05
    /// Visible north-south extent for a region of `span` metres (the screen is taller than wide).
    private static var screenAspect: Double {
        let b = UIScreen.main.bounds
        return max(Double(b.height / max(b.width, 1)), 1)
    }

    private func focus(on c: CLLocationCoordinate2D, radius: Double) {
        let span = max(radius * 2 + 300, 450)
        let liftMeters = span * Self.screenAspect * Self.cameraLift
        let center = CLLocationCoordinate2D(latitude: c.latitude - liftMeters / 111_320, longitude: c.longitude)
        withAnimation(.easeInOut(duration: 0.4)) {
            position = .region(MKCoordinateRegion(center: center, latitudinalMeters: span, longitudinalMeters: span))
        }
    }

    private func fitAllPlaces(animated: Bool = false) {
        let pts = visiblePlaces
        guard !pts.isEmpty else { return }
        if pts.count == 1 {
            focus(on: pts[0].coordinate, radius: GpsGeo.radius(of: pts[0]))
            return
        }
        // Bounds include each place's circle (not just the pin).
        var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
        for p in pts {
            let r = GpsGeo.radius(of: p)
            let dLat = r / 111_320
            let dLon = r / (111_320 * max(cos(p.lat * Double.pi / 180), 0.01))
            minLat = min(minLat, p.lat - dLat); maxLat = max(maxLat, p.lat + dLat)
            minLon = min(minLon, p.lon - dLon); maxLon = max(maxLon, p.lon + dLon)
        }
        // 2.0x: room for the top controls and the pin heads.
        let latDelta = max((maxLat - minLat) * 2.0, 0.01)
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2 - latDelta * Self.cameraLift,
                                            longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: latDelta,
                                    longitudeDelta: max((maxLon - minLon) * 1.8, 0.01))
        let region = MKCoordinateRegion(center: center, span: span)
        if animated {
            withAnimation(.easeInOut(duration: 0.4)) { position = .region(region) }
        } else {
            position = .region(region)
        }
    }

    // MARK: - Fly

    private func isActivePlace(_ p: GpsPlace) -> Bool {
        (engine.activePlaceID == p.id && isSimulating)
            || (demoSimulating && p.id == visiblePlaces.first?.id)
    }

    /// One tap on a saved place: random point inside its circle (GpsGeo.sampleLanding via the engine).
    private func fly(_ p: GpsPlace) {
        if let last = lastFly, last.id == p.id, Date().timeIntervalSince(last.at) < 0.8 { return }
        guard !engine.isBusy else {
            showToast("正在送出，請稍候", autoClear: true, duration: 2)
            return
        }
        lastFly = (p.id, Date())
        clearToast()
        searchFocused = false
        sendingPlaceID = p.id
        focus(on: p.coordinate, radius: GpsGeo.radius(of: p))
        engine.send(place: p)
    }

    // MARK: - Bottom: toast, banners, then the place card / new-place card / stop bar

    /// Toast and banners float at the bottom of the map. While a card is open (new place /
    /// manage) a banner shrinks to one line so only one card is ever large on screen.
    private var mapMessages: some View {
        VStack(spacing: 8) {
            toastView
            ForEach(orderedBanners) { b in
                GpsBannerRow(banner: b, compact: draft != nil || managing)
            }
        }
    }

    private var bottomPanel: some View {
        VStack(spacing: 10) {
            if let d = draft {
                draftCard(d)
            } else if managing {
                manageCard
            } else if store.places.isEmpty {
                emptyCard
            } else {
                placesCard
            }
            if isSimulating && draft == nil {
                stopBar
            }
        }
    }

    /// Fixed card, never collapses (owner 2026-10-15: 「下面不用縮回去可以讓我直接點擊」).
    /// Two columns on a phone (three when wide); about three rows show, the rest scroll inside.
    private var placesCard: some View {
        GeometryReader { geo in
            let columns = Array(repeating: GridItem(.flexible(), spacing: 8),
                                count: geo.size.width >= 480 ? 3 : 2)
            ScrollViewReader { reader in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(visiblePlaces) { p in
                            placeChip(p).id(p.id)
                        }
                        addCell
                    }
                    .padding(10)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: engine.activePlaceID) { _, id in
                    guard let id else { return }
                    withAnimation { reader.scrollTo(id) }
                }
            }
        }
        .frame(height: placesCardHeight)
        .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(GpsTheme.line, lineWidth: 1))
    }

    /// Up to three rows of 48 pt cells plus padding; fewer places = shorter card, more map.
    private var placesCardHeight: CGFloat {
        let cells = visiblePlaces.count + 1
        let rows = min(3, (cells + 1) / 2)
        // A peek of the fourth row tells the list scrolls when there are more.
        let peek: CGFloat = (cells + 1) / 2 > 3 ? 22 : 0
        return CGFloat(rows) * 48 + CGFloat(max(rows - 1, 0)) * 8 + 20 + peek
    }

    private var addCell: some View {
        Button {
            startDraftAtCenter()
        } label: {
            Text("＋ 新增地點")
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(GpsTheme.mint)
                .frame(maxWidth: .infinity, minHeight: 48)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(GpsTheme.mint.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("新增地點")
        .accessibilityHint("也可以長按地圖")
        .accessibilityIdentifier("btn.addPlace")
    }

    private func placeChip(_ p: GpsPlace) -> some View {
        let active = isActivePlace(p)
        let fresh = active && confirmation(at: now)
        let sending = sendingPlaceID == p.id && engine.isBusy
        var label = p.name
        if fresh { label += "，現在在這裡" } else if active { label += "，連線中斷，定位仍保留" }
        return Button {
            fly(p)
        } label: {
            HStack(spacing: 6) {
                if sending {
                    ProgressView().controlSize(.small).tint(fresh ? GpsTheme.background : .white)
                } else if active {
                    Image(systemName: fresh ? "location.fill" : "location")
                        .font(.footnote.weight(.bold))
                }
                Text(p.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(fresh ? GpsTheme.background : .white)
            .background(fresh ? GpsTheme.mint : Color.white.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(active && !fresh ? GpsTheme.sub : Color.clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityHint("點一下就飛過去")
        .accessibilityIdentifier("place.row.\(p.id)")
        .accessibilityAction(named: "編輯") { editing = p }
        .accessibilityAction(named: "刪除") { deletePlace(p) }
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

    /// Rare path: every place (hidden ones too) as a plain list; a row opens the edit sheet.
    private var manageCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("管理地點")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    managing = false
                } label: {
                    Text("結束")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(GpsTheme.mint)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("btn.editDone")
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(store.sorted) { p in
                        Button {
                            editing = p
                        } label: {
                            HStack(spacing: 8) {
                                Text(p.name)
                                    .font(.body)
                                    .foregroundStyle(p.isHidden ? GpsTheme.sub : .white)
                                    .lineLimit(1)
                                if p.isHidden {
                                    Text("已隱藏").font(.footnote).foregroundStyle(GpsTheme.sub)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(GpsTheme.sub)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(p.isHidden ? "\(p.name)，已隱藏" : p.name)
                        .accessibilityHint("開啟編輯")
                        .accessibilityIdentifier("place.edit.\(p.id)")
                        Rectangle().fill(GpsTheme.line).frame(height: 1).padding(.leading, 16)
                    }
                }
            }
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 6)
        .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(GpsTheme.line, lineWidth: 1))
    }

    private var emptyCard: some View {
        VStack(spacing: 10) {
            Text("長按地圖或搜尋，新增第一個地點")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button {
                    startDraftAtCenter()
                } label: {
                    Text("＋ 新增地點")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(GpsTheme.background)
                        .background(GpsTheme.mint, in: Capsule())
                }
                .accessibilityIdentifier("btn.addPlace")
                Button {
                    showPlacesImporter = true
                } label: {
                    Text("匯入地點檔")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(GpsTheme.mint)
                        .overlay(Capsule().stroke(GpsTheme.mint, lineWidth: 1.5))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: - New place card

    private func draftCard(_ d: GpsDraft) -> some View {
        let nameBinding = Binding<String>(
            get: { draft?.name ?? "" },
            set: { draft?.name = $0; draft?.nameEdited = true }
        )
        let sizeBinding = Binding<GpsSize?>(
            get: { draft?.size },
            set: { if let s = $0 { draft?.size = s } }
        )
        return VStack(spacing: 10) {
            if d.followsCenter {
                Text("拖動地圖，讓十字對準位置")
                    .font(.footnote)
                    .foregroundStyle(GpsTheme.sub)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                TextField("地點名稱", text: nameBinding)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .submitLabel(.done)
                    .focused($draftNameFocused)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel("地點名稱")
                    .accessibilityIdentifier("draft.name")
                Button {
                    draftNameFocused = false
                    draft = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(GpsTheme.sub)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("取消新增")
                .accessibilityIdentifier("draft.cancel")
            }
            GpsSizePicker(selection: sizeBinding)
            HStack(spacing: 8) {
                Button {
                    flyDraftOnly()
                } label: {
                    Text("只飛過去")
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(GpsTheme.mint)
                        .overlay(Capsule().stroke(GpsTheme.mint, lineWidth: 1.5))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint("不存，飛到這個圈內")
                .accessibilityIdentifier("draft.flyOnly")
                Button {
                    saveDraft()
                } label: {
                    Text("＋ 存成地點")
                        .font(.body.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(GpsTheme.background)
                        .background(GpsTheme.mint, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("draft.save")
            }
        }
        .padding(12)
        .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(GpsTheme.mint.opacity(0.45), lineWidth: 1))
    }

    private var defaultDraftName: String { "新地點" }

    private func startDraft(at c: CLLocationCoordinate2D, name: String?) {
        clearToast()
        managing = false
        draft = GpsDraft(coordinate: c, name: name ?? defaultDraftName, nameEdited: name != nil)
        focus(on: c, radius: GpsSize.small.meters)
        if name == nil { suggestName(for: c) }
    }

    private func startDraftAtCenter() {
        clearToast()
        managing = false
        let c = mapCenter ?? GpsTheme.taiwanRegion.center
        draft = GpsDraft(coordinate: c, name: defaultDraftName, followsCenter: true)
        suggestName(for: c)
    }

    /// Prefills the name from the address under the point, unless the user already typed one.
    private func suggestName(for c: CLLocationCoordinate2D) {
        guard draft?.nameEdited == false else { return }
        geocoder.cancelGeocode()
        geocoder.reverseGeocodeLocation(CLLocation(latitude: c.latitude, longitude: c.longitude),
                                        preferredLocale: Locale(identifier: "zh_Hant_TW")) { marks, _ in
            guard let m = marks?.first else { return }
            let candidates = [m.areasOfInterest?.first, m.name, m.thoroughfare, m.locality]
            guard let name = candidates.compactMap({ $0 }).first(where: { !$0.isEmpty }) else { return }
            DispatchQueue.main.async {
                guard var d = draft, !d.nameEdited else { return }
                d.name = name
                draft = d
            }
        }
    }

    private func saveDraft() {
        guard let d = draft else { return }
        draftNameFocused = false
        let trimmed = d.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let point = draftPoint ?? d.coordinate
        let place = GpsPlace(name: trimmed.isEmpty ? defaultDraftName : trimmed,
                             lat: point.latitude, lon: point.longitude, radius: d.size.meters)
        store.upsert(place)
        draft = nil
        showToast("已存「\(place.name)」", actionTitle: "飛過去", action: {
            fly(store.places.first(where: { $0.id == place.id }) ?? place)
        }, autoClear: true, duration: 6)
    }

    /// Fly without saving: still a fresh random point inside the chosen circle.
    private func flyDraftOnly() {
        guard let d = draft else { return }
        guard !engine.isBusy else {
            showToast("正在送出，請稍候", autoClear: true, duration: 2)
            return
        }
        draftNameFocused = false
        let point = draftPoint ?? d.coordinate
        let trimmed = d.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let temp = GpsPlace(id: "draft", name: trimmed.isEmpty ? defaultDraftName : trimmed,
                            lat: point.latitude, lon: point.longitude, radius: d.size.meters)
        draft = nil
        clearToast()
        engine.send(to: GpsGeo.sampleLanding(temp, among: []), name: temp.name, center: point)
    }

    // MARK: - Stop bar (always one tap while simulating; 復原 in the toast undoes a switch or stop)

    private var stopBar: some View {
        HStack(spacing: 8) {
            // Single tap, no hold, no confirm: the undo toast afterwards is the safety net.
            Button {
                clearToast()
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                engine.stop()
            } label: {
                Text("停止模擬，回到真實位置")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(.white)
                    .background(GpsTheme.stopRed, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(engine.isBusy)
            .accessibilityLabel("停止模擬")
            .accessibilityHint("讓手機回到真實位置")
            .accessibilityIdentifier("btn.stop")
        }
    }

    private func deletePlace(_ p: GpsPlace) {
        clearToast()
        store.delete(id: p.id)
        showToast("已刪除「\(p.name)」", actionTitle: "復原", action: { store.undoDelete() }, autoClear: false)
    }

    // MARK: - Banners (errors only; "connecting" lives in the status line)

    /// Errors (file, issue) always show first; only the device banners are capped.
    private var orderedBanners: [GpsBanner] {
        let all = banners
        let errors = all.filter { $0.id == "file" } + all.filter { $0.id == "issue" }
        let device = all.filter { $0.id != "file" && $0.id != "issue" }
        return errors + Array(device.prefix(1))
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
        } else if !demoReady, tunnel.isConnected, !mounting.coolisMounted, mounting.mountingThread == nil {
            // Needs the JIT tunnel: on 4G only the location link is up and mounting cannot work.
            list.append(GpsBanner(
                id: "ddi", color: GpsTheme.orange,
                title: "DDI（開發者映像）還沒掛載",
                detail: "模擬定位需要先掛載 DDI（開發者映像），按右邊按鈕（第一次會先下載，約數十 MB）。",
                buttonTitle: "掛載 DDI",
                action: { mountDDI() }
            ))
        }
        // One banner per cause: a send error that only repeats the device banner above
        // (no Wi-Fi / VPN, no pairing file, DDI) is not shown a second time.
        let deviceBannerShown = !list.isEmpty
        if let issue = engine.issue, engine.activeName == nil,
           !(deviceBannerShown && [.tunnel, .pairing, .ddi].contains(issue.kind)) {
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
        withAnimation(.easeOut(duration: 0.2)) { toast = new }
        AccessibilityAnnouncer.announce(text)
        if autoClear {
            // Compare ids so an older timer never wipes a newer toast.
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                if toast?.id == new.id { withAnimation(.easeIn(duration: 0.2)) { toast = nil } }
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
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let title = t.actionTitle, let action = t.action {
                    Button {
                        let id = t.id
                        action()
                        if toast?.id == id { toast = nil }
                    } label: {
                        Text(title)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(GpsTheme.mint)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("toast.action")
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(minHeight: 44)
            .background(GpsTheme.background.opacity(0.96), in: Capsule())
            .overlay(Capsule().stroke(GpsTheme.mint.opacity(0.5), lineWidth: 1))
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
            case "selected", "newPlace":
                // A new place just long-pressed near the first place (public demo data only).
                if let p = first {
                    let c = CLLocationCoordinate2D(latitude: p.lat + 0.004, longitude: p.lon + 0.003)
                    draft = GpsDraft(coordinate: c, name: "新地點")
                    focus(on: c, radius: GpsSize.small.meters)
                }
            case "manage":
                managing = true
            case "simulating", "simulatingStale":
                let taipei101 = CLLocationCoordinate2D(latitude: 25.0339, longitude: 121.5645)
                engine.applyDemoSimulation(name: "台北101", coordinate: taipei101)
                focus(on: taipei101, radius: 200)
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
        // Retry the JIT tunnel only where it can come up (Wi-Fi); on 4G it only spins,
        // and the location link works without it.
        if startTunnel, pairingExists, !tunnel.isConnected {
            if network.onWiFi {
                retryTunnel()
            } else {
                // No retry on 4G, so end the 「連線中…」 grace now (only retryTunnel's timer would).
                tunnelGraceOver = true
            }
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
                fitAllPlaces(animated: true)
            } catch {
                store.lastLoadError = "匯入失敗：\(error.localizedDescription)"
            }
        case .failure(let error):
            store.lastLoadError = "匯入失敗：\(error.localizedDescription)"
        }
    }
}

// MARK: - Small views

/// Three size buttons (小/中/大) with a ring icon each; shared by the new-place card and the edit sheet.
struct GpsSizePicker: View {
    @Binding var selection: GpsSize?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(GpsSize.allCases) { s in
                let selected = selection == s
                Button {
                    selection = s
                    Haptics.selection()
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .stroke(selected ? GpsTheme.background : GpsTheme.mint, lineWidth: 2)
                            .frame(width: s.iconSize, height: s.iconSize)
                            .frame(width: 20, height: 20)
                        Text(s.title)
                            .font(.body.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(selected ? GpsTheme.background : .white)
                    .background(selected ? GpsTheme.mint : Color.white.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(s.spoken)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier(s.axID)
            }
        }
    }
}

/// Crosshair at the screen centre while the ＋ flow follows the map centre.
private struct GpsCrosshair: View {
    var body: some View {
        ZStack {
            Circle().stroke(Color.black.opacity(0.35), lineWidth: 4).frame(width: 26, height: 26)
            Circle().stroke(GpsTheme.mint, lineWidth: 2).frame(width: 26, height: 26)
            Circle().fill(GpsTheme.mint).frame(width: 5, height: 5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
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
            GpsPinShape().stroke(GpsTheme.background.opacity(0.6), lineWidth: 1)
            Circle()
                .fill(GpsTheme.background)
                .frame(width: 10, height: 10)
                .offset(y: 8.5)
        }
        .frame(width: 28, height: 37)
        .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
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
                .fill(fresh ? GpsTheme.mint : (active ? GpsTheme.sub : Color.white.opacity(0.45)))
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
    /// One line (title + button) while another card is open.
    var compact = false
    @State private var expanded = false
    /// The cause and next step are always shown in full (never truncated, no chevron).
    private var showsDetailInline: Bool { true }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(banner.color).frame(width: 4, height: 24)
                Text(banner.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
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
            if !compact && (expanded || (showsDetailInline && !banner.detail.isEmpty)) {
                Text(banner.detail)
                    .font(.footnote)
                    .foregroundStyle(GpsTheme.sub)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 10)
                    .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
    /// iPad (regular width) gets form-sheet sizing; iPhone keeps medium/large detents.
    @ViewBuilder
    func editSheetSizing(regular: Bool) -> some View {
        if regular {
            self.gpsSimPadSheetSizing()
        } else {
            // Large only: at the medium detent 刪除地點 sat under the bottom edge.
            self.presentationDetents([.large])
        }
    }
}

// MARK: - Edit sheet (rename, size, hide, move, delete)

struct GpsPlaceEditSheet: View {
    let mapCenter: CLLocationCoordinate2D?
    let onSave: (GpsPlace) -> Void
    let onDelete: (GpsPlace) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    private let original: GpsPlace
    @State private var draft: GpsPlace
    /// nil = the stored radius is not one of 小/中/大; it is kept until a size is tapped.
    @State private var size: GpsSize?
    @State private var sizeTouched = false
    @State private var movedNote = false

    init(place: GpsPlace, mapCenter: CLLocationCoordinate2D?,
         onSave: @escaping (GpsPlace) -> Void, onDelete: @escaping (GpsPlace) -> Void) {
        self.mapCenter = mapCenter
        self.onSave = onSave
        self.onDelete = onDelete
        original = place
        _draft = State(initialValue: place)
        _size = State(initialValue: GpsSize.matching(place.radius))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名稱") {
                    TextField("地點名稱", text: $draft.name)
                        .accessibilityIdentifier("edit.name")
                }
                Section {
                    GpsSizePicker(selection: Binding(
                        get: { size },
                        set: { size = $0; sizeTouched = true }
                    ))
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                } header: {
                    Text("範圍")
                }
                Section {
                    DisclosureGroup("更多") {
                    Toggle("在地圖上隱藏", isOn: Binding(
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
                        Text("已移到地圖中心（按「完成」才會存）")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    }
                }
                Section {
                    // No confirm dialog: the home screen shows 「復原」 until the next action.
                    Button(role: .destructive) {
                        onDelete(original)
                        dismiss()
                    } label: {
                        Text("刪除地點").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .accessibilityIdentifier("edit.delete")
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
                        // Untouched = keep exactly what was stored (even a PC radius like 2000 m).
                        if sizeTouched, let s = size {
                            saved.radius = s.meters
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
