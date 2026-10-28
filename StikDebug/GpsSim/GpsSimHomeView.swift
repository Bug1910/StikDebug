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
    static let stopRedPressed = Color(red: 0.557, green: 0.106, blue: 0.129) // #8E1B21
    static let stopBorder = Color(red: 1.0, green: 0.42, blue: 0.42)        // #FF6B6B
    /// Idle stop button outline: card alone vs a dark (forest) satellite map was 1.15:1, this is 4.87:1.
    static let idleBorder = Color(red: 0.541, green: 0.580, blue: 0.639)    // #8A94A3
    /// Text on mint or yellow fills (13.56:1 on mint, 9.86:1 on yellow).
    static let onAccent = Color(red: 0.047, green: 0.067, blue: 0.102)      // #0C111A
    /// Text of destructive buttons (登出、重設); #EF4444 as text on card is only 4.59:1.
    static let dangerText = Color(red: 1.0, green: 0.42, blue: 0.42)        // #FF6B6B
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

    /// Whole world, for the second search when Taiwan has no name match.
    static let worldRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 179.9, longitudeDelta: 359.9)
    )

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
    /// Address line of a search result, shown in grey under the name.
    var address: String?
    var size: GpsSize = .small
    /// ＋ button: the point follows the map centre (crosshair) until saved.
    var followsCenter = false
}

/// What the camera framed on its own (re-applied when the overlays change size).
private enum GpsFraming {
    case all
    case place(CLLocationCoordinate2D, Double)
}

private struct GpsBanner: Identifiable {
    let id: String
    let color: Color
    var title: String
    let detail: String
    var buttonTitle: String?
    var action: (() -> Void)?
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?
    /// Short numbered steps shown instead of `detail` (detail stays as the VoiceOver value).
    var steps: [String] = []
    /// A full-width link under the steps (e.g. run the owner's shortcut).
    var linkTitle: String?
    var linkURL: URL?
    /// Runs when iOS cannot open `linkURL` (e.g. the Shortcuts app was removed).
    var onLinkFailed: (() -> Void)?
    /// Set = a one-line status: the whole row is a button that opens Settings at this part.
    var settingsTarget: GpsSettingsTarget?
}

/// A toast with an optional action button. `id` lets a delayed auto-clear check it is still
/// the toast it was scheduled for (a newer toast must never be wiped by an older timer).
private struct GpsToast: Identifiable {
    let id = UUID()
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?
}

/// Hands a search answer back exactly once: whichever comes first, Apple's answer or the timer.
/// The second caller gets false and nothing happens (a continuation resumed twice would crash).
private final class ResumeOnce<T> {
    private var continuation: CheckedContinuation<T, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(_ value: T) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return false }
        pending.resume(returning: value)
        return true
    }
}

/// Own coordinate parser so the home view can say *why* a pasted pair was rejected
/// (works whatever shape GpsGeo.parseCoordinate has).
private enum GpsCoordinateInput {
    case valid(CLLocationCoordinate2D)
    /// `swapped` is the lat/lon-reversed pair when that would be valid (the UI can offer 「對調」).
    case outOfRange(swapped: CLLocationCoordinate2D?)
    /// Two parts made only of digits, signs, dots and 「°」, but one is not a real number
    /// (「25..03, 121」); never sent to MKLocalSearch. Any letter or Chinese = a place name instead.
    case malformed(String)
    case notCoordinate

    static func parse(_ text: String) -> GpsCoordinateInput {
        // Same splitting as GpsGeo.parseCoordinateResult, so 「Taipei 101」 is a name in both.
        guard let parts = GpsGeo.coordinateParts(text) else { return .notCoordinate }
        let first = Double(parts[0])
        let second = Double(parts[1])
        guard let lat = first, let lon = second else {
            let which = first == nil ? "緯度" : "經度"
            return .malformed("座標格式不對：\(which)不是數字（範例：48.8584, 2.2945）")
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
    @ObservedObject private var renew = GpsRenewCenter.shared
    /// Sign-in sheet for 「登入並續簽」 on the home reminder card.
    @State private var showRenewSignIn = false
    @Environment(\.scenePhase) private var scenePhase
    /// The system text size as set (the screen itself caps it at maxTypeSize below).
    @Environment(\.dynamicTypeSize) private var systemTypeSize
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn
    @Environment(\.openURL) private var openURL

    /// Satellite (hybrid: imagery + road names) by default; the owner asked for it 2026-10-15.
    @AppStorage("gpsSim.mapSatellite") private var mapSatellite = true
    @State private var position: MapCameraPosition = .region(GpsTheme.taiwanRegion)
    @State private var mapCenter: CLLocationCoordinate2D?
    @State private var draft: GpsDraft?
    /// Just-saved place: flashFreshID drives the short highlight, lastSavedPlaceID is where the manage list opens.
    @State private var flashFreshID: String?
    @State private var lastSavedPlaceID: String?
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var isSearching = false
    @State private var searchMessage: String?
    /// Rows of searchResults whose name is far from what was typed: shown with a 「最接近」 tag.
    /// Reset with every finished search; rows are looked up by index, so a stale set never outlives its list.
    @State private var approximateRows: Set<Int> = []
    /// Changes on every new search and on clear: a slow older search must not overwrite a newer one.
    @State private var searchID = UUID()
    /// Lat/lon swapped version of an out-of-range paste, offered via the 「對調」 button.
    @State private var swappedSuggestion: CLLocationCoordinate2D?
    @State private var editing: GpsPlace?
    @State private var managing = false
    @State private var showSettings = false
    /// Set by the 4G banner 「步驟」 so Settings opens with 進階 already expanded.
    @State private var settingsTarget: GpsSettingsTarget = .none
    @State private var showPairingImporter = false
    @State private var pairingCardDismissed = false
    @State private var showPlacesImporter = false
    @State private var pairingExists = GpsSimEngine.pairingExists
    @State private var tunnelGraceOver = false
    @State private var didInitialFit = false
    @State private var toast: GpsToast?
    /// Clock for the signing reminder: ticks every minute and on return to the app, so the days
    /// left stay current while the app stays open.
    @State private var signNow = Date()
    /// The place whose last send failed: drawn grey and dashed until a send succeeds.
    @State private var failedPlaceID: String?
    /// Screen frames of the map and of what floats over it, so the camera frames places in the
    /// open part of the map (pins were hidden under the search bar, the right buttons and banners).
    @State private var mapFrame: CGRect = .zero
    @State private var legalScrim: [CLLocationCoordinate2D] = []
    @State private var legalProbe = GpsLegalProbe()
    @State private var topBarFrame: CGRect = .zero
    @State private var toolsFrame: CGRect = .zero
    /// What the camera last framed on its own; re-applied when the overlays change size,
    /// unless the person has moved the map since.
    @State private var lastFraming: GpsFraming?
    @State private var sendingPlaceID: String?
    /// The red 停止模擬 button is waiting for the phone (shows 「停止中」).
    @State private var stopping = false
    /// Screenshot-only: the red button was tapped in a `simulating` demo, so the demo now shows the stopped state.
    @State private var demoStopped = false
    /// Guards against a double tap sending twice (the second tap would land somewhere else).
    @State private var lastFly: (id: String, at: Date)?
    @State private var geocoder = CLGeocoder()
    /// Ticks every second so pins and the place card re-evaluate freshness together with the status line.
    @State private var now = Date()
    @FocusState private var searchFocused: Bool
    /// Full-screen search page (like Google Maps). Stays open until 取消 or a pick, so runSearch
    /// dropping the keyboard focus never flickers the page away.
    @State private var searchMode = false
    @FocusState private var draftNameFocused: Bool

    private var visiblePlaces: [GpsPlace] { store.sorted.filter { !$0.isHidden } }

    /// Created once: a publisher built inside `body` was rebuilt on every redraw (every second while simulating).
    private static let secondTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private static let minuteTick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    /// Text follows the system size up to accessibility2; beyond that the map would vanish.
    static let maxTypeSize = DynamicTypeSize.accessibility2
    private var typeSize: DynamicTypeSize { min(systemTypeSize, Self.maxTypeSize) }
    /// Accessibility sizes: one place per row and taller rows, so names never shrink to fit.
    private var largeText: Bool { typeSize.isAccessibilitySize }
    /// 48 pt at the default size, grown like body text (capped like the text itself).
    private var placeCellHeight: CGFloat {
        let category = UIContentSizeCategory(typeSize)
        return UIFontMetrics(forTextStyle: .body)
            .scaledValue(for: 48, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
    }
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
    private var demoSimulating: Bool { Self.demoState?.hasPrefix("simulating") == true && !demoStopped }
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
                // Measured inside ignoresSafeArea: outside it the frame stops at the status bar, so the
                // camera maths ran on a map 62 pt too short and pins landed under the search bar (v1.0.14).
                map.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { mapFrame = $0 }
                    .ignoresSafeArea(edges: [.top, .horizontal])
                if draft?.followsCenter == true {
                    GpsCrosshair().ignoresSafeArea(edges: [.top, .horizontal]).allowsHitTesting(false)
                }
                VStack(spacing: 8) {
                    topControls
                        .layoutPriority(1)
                    // While search results or a search message are open they get the room
                    // (on an iPhone SE the map area is short; the list was squeezed to nothing).
                    HStack {
                        Spacer()
                        mapTools
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { toolsFrame = $0 }
                    }
                    .frame(maxWidth: Self.controlWidth)
                    Spacer(minLength: 0)
                    toastView
                        .frame(maxWidth: Self.controlWidth)
                        // Apple Maps logo and Legal link sit in the bottom ~26 pt; they must stay visible.
                        .padding(.bottom, Self.legalClearance)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                // Never taller than the map: on an iPhone SE the floating controls used to make
                // this stack taller than the screen, pushing the status line under the system bar.
                .frame(maxHeight: .infinity, alignment: .top)
                // Overflow (SE at the largest text) is cut at the map's bottom edge, so the toast
                // can never spill over the banners or the place card below.
                .clipped()
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            if !orderedBanners.isEmpty {
                bannerStack
                    .frame(maxWidth: Self.controlWidth)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity)
                    .background(GpsTheme.background)
            }
            bottomPanel
                .frame(maxWidth: Self.controlWidth)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity)
                .background(GpsTheme.background.ignoresSafeArea(edges: .bottom))
        }
        .dynamicTypeSize(...Self.maxTypeSize)
        .background(GpsTheme.background.ignoresSafeArea())
        .accessibilityHidden(searchMode)
        .overlay {
            if searchMode {
                searchPage.transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: searchMode)
        .preferredColorScheme(.dark)
        .tint(GpsTheme.mint)
        .onReceive(Self.secondTick) { d in if isSimulating { now = d } }
        .onReceive(Self.minuteTick) { signNow = $0 }
        .onAppear(perform: handleAppear)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                signNow = Date()
                refreshFromDisk(startTunnel: true)
                // Re-plans the expiry reminders and, if due, renews once (foreground only).
                renew.appBecameActive()
            }
        }
        .onChange(of: engine.toast) { _, value in
            guard let value else { return }
            // After a stop the previous target is the one just stopped: offer an undo. 3 s as the
            // owner asked; VoiceOver keeps 10 s so 復原 can still be reached (WCAG 2.2.1).
            if value.hasPrefix("已回到真實位置") || value.hasPrefix("已經是真實位置"), engine.previous != nil {
                showToast(value, actionTitle: "復原", action: { engine.undoLastSend() }, autoClear: true,
                          duration: voiceOverOn ? 10 : 3)
            } else {
                showToast(value, autoClear: true)
            }
            engine.toast = nil
        }
        // `landing` changes only on a real send (resend ticks only move `current`), so keying on it
        // avoids re-toasting every 4 s heartbeat.
        .onChange(of: engine.landing.map { "\($0.latitude),\($0.longitude)" }) { _, key in
            guard key != nil else { return }
            // Any successful send (undo, shortcut, link, search) clears the failed mark; the 4 s
            // heartbeat does not change `landing`, so it cannot clear a newer failure.
            failedPlaceID = nil
            let name = engine.activeName ?? "新位置"
            if engine.previous != nil {
                showToast("已換到 \(name)", actionTitle: "復原", action: { engine.undoLastSend() }, autoClear: true, duration: 10)
            } else {
                showToast("已飛到 \(name)", autoClear: true)
            }
        }
        // Only the first places (empty -> some) refit the camera; adding one more must not jump away.
        .onChange(of: store.places.count) { old, _ in if old == 0 { fitAllPlaces() } }
        // Overlays changed size (banner, toast, bigger text, bottom card): frame the same thing
        // again in the new open area, unless the person moved the map themselves.
        .onChange(of: [mapInsets.top, mapInsets.bottom, mapInsets.trailing,
                       mapFrame.width.rounded(), mapFrame.height.rounded()]) { _, _ in
            // While the search page covers the map its readings (keyboard resize) are stale.
            guard !searchMode, let framing = lastFraming, !position.positionedByUser else { return }
            apply(framing, animated: true)
        }
        .onChange(of: renew.successToast) { _, text in
            guard let text else { return }
            signNow = Date()
            showToast(text, autoClear: true, duration: 3)
            renew.successToast = nil
        }
        .onChange(of: engine.isBusy) { _, busy in
            if !busy { sendingPlaceID = nil }
        }
        // Only state changes are announced; sends are announced by their toast.
        .onChange(of: isSimulating) { _, simulating in
            if !simulating { AccessibilityAnnouncer.announce("已回到真實位置，地圖約 10 秒內更新") }
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
        .sheet(isPresented: $showSettings, onDismiss: { settingsTarget = .none; refreshFromDisk(startTunnel: true) }) {
            GpsSimSettingsView(startTarget: settingsTarget, onImportPlaces: {
                showSettings = false
                // Let the settings sheet finish dismissing before presenting the picker.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showPlacesImporter = true }
            }, onMountDDI: {
                // Close Settings first so the home screen shows progress and any download error banner.
                showSettings = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { mountDDI() }
            })
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showRenewSignIn) {
            GpsRenewSignInSheet(origin: .renewAfter).preferredColorScheme(.dark)
        }
        .fileImporter(isPresented: $showPlacesImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            importPlaces(result)
        }
        // A second fileImporter on the same view silently stops working, so the pairing one hangs off a background view.
        .background(
            Color.clear.fileImporter(isPresented: $showPairingImporter,
                                     allowedContentTypes: PairingFileStore.supportedContentTypes,
                                     allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first, (try? PairingFileStore.importFromPicker(url)) != nil {
                    pairingExists = true
                    markTunnelDisconnected()
                    startTunnelInBackground(showErrorUI: false)
                    NotificationCenter.default.post(name: .pairingFileImported, object: nil)
                } else {
                    showToast("配對檔匯入失敗，請確認選的是電腦產生的配對檔。", autoClear: true, duration: 6)
                }
            }
        )
    }

    // MARK: - Top: status line, settings, search

    private var topControls: some View {
        VStack(spacing: 8) {
            if largeText {
                // Accessibility sizes: status + settings on one row, the stop button on its own
                // full-width row with its text (HIG Typography: stack, never icon only).
                HStack(alignment: .top, spacing: 8) {
                    statusPill
                    settingsButton
                }
                stopButton(fullWidth: true)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    statusPill
                    stopButton(fullWidth: false)
                    settingsButton
                }
            }
            searchBar
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { topBarFrame = $0 }
        }
        .frame(maxWidth: Self.controlWidth)
        .padding(.top, 2)
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(Self.roundIconFont)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(GpsTheme.card.opacity(0.94), in: Circle())
                .overlay(Circle().stroke(GpsTheme.line, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("設定")
        .accessibilityIdentifier("btn.settings")
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
                GpsPulseDot(fresh: fresh, active: isSimulating, kept: engine.activeName != nil)
                // The 「・連線中斷」 tail is its own Text with higher layout priority, so a long place
                // name is what gets cut (at the end), never the part that says something is wrong.
                Text(line)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(largeText ? 2 : 1)
                    .truncationMode(.tail)
                if let tail = statusTail(fresh: fresh) {
                    Text(tail)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GpsTheme.orange)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Spacer(minLength: 0)
                // Spinner lives inside the pill so connecting/sending never adds a row.
                if engine.isBusy || isConnecting || isMountingNow { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, largeText ? 6 : 0)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(GpsTheme.card.opacity(0.94), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(fresh ? GpsTheme.mint.opacity(0.6) : (engine.activeName != nil ? GpsTheme.orange.opacity(0.7) : GpsTheme.line),
                        lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line + (statusTail(fresh: fresh) ?? ""))
            .accessibilityHint("點一下看說明")
            .accessibilityIdentifier("status.pill")
            .onTapGesture {
                if engine.activeName != nil, !fresh {
                    showToast("和手機的連線中斷。假定位通常還在，不用重按；要換地點或停止，先連上 LocalDevVPN。", autoClear: true, duration: 8)
                } else if !isSimulating {
                    showToast("現在是手機的真實位置。點下方地點開始模擬。", autoClear: true, duration: 6)
                }
            }
        }
    }

    /// One short line, always text (never only colour or animation).
    private func statusLine(fresh: Bool) -> String {
        if let name = engine.activeName {
            return fresh ? "在 \(name)" : name
        }
        if session.isActive { return "在外部連結的位置" }
        if let stale = engine.staleTarget { return "上次在 \(stale.name)（定位可能仍保留）" }
        if isConnecting { return "連線中…" }
        if isMountingNow { return "準備中…" }
        return "點下方地點開始模擬"
    }

    /// Orange tail shown after the place name when the phone has not confirmed the point lately.
    private func statusTail(fresh: Bool) -> String? {
        engine.activeName != nil && !fresh ? "・連線中斷" : nil
    }

    /// Home version: looks like a search field but is a button that opens the full-screen page.
    private var searchBar: some View {
        Button {
            openSearch()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(GpsTheme.sub)
                Text("搜尋地點或貼上座標")
                    .foregroundStyle(GpsTheme.sub)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(GpsTheme.card.opacity(0.94), in: Capsule())
            .overlay(Capsule().stroke(GpsTheme.line, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("搜尋地點")
        .accessibilityIdentifier("search.field")
    }

    private func openSearch() {
        searchMode = true
        // Focus after the page exists; setting it in the same pass is ignored by SwiftUI.
        DispatchQueue.main.async { searchFocused = true }
    }

    private func closeSearch() {
        clearSearch()
        searchFocused = false
        searchMode = false
    }

    /// Full-screen search: field + 取消 on top (inside the safe area), the one-line simulation row,
    /// then messages / results filling everything above the keyboard.
    private var searchPage: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(GpsTheme.sub)
                    TextField("搜尋地點或貼上座標", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused($searchFocused)
                        .onAppear { searchFocused = true }
                        .onSubmit(runSearch)
                        .accessibilityLabel("搜尋地點")
                        .accessibilityIdentifier("search.field")
                    if isSearching { ProgressView().controlSize(.small) }
                    if !searchText.isEmpty {
                        Button {
                            clearSearch()
                            searchFocused = true
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
                .background(GpsTheme.card, in: Capsule())
                .overlay(Capsule().stroke(GpsTheme.line, lineWidth: 1))
                Button("取消") { closeSearch() }
                    .foregroundStyle(GpsTheme.mint)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("search.cancel")
            }
            if let name = engine.activeName {
                HStack(spacing: 8) {
                    Text("模擬中：\(name)")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    stopButton(fullWidth: false)
                }
            }
            if let msg = searchMessage {
                searchMessageRow(msg)
            }
            if !searchResults.isEmpty {
                searchResultsList
            }
            Spacer(minLength: 0)
            toastView
                .frame(maxWidth: Self.controlWidth)
        }
        .frame(maxWidth: Self.controlWidth)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .dynamicTypeSize(...Self.maxTypeSize)
        .accessibilityAddTraits(.isModal)
        .background(GpsTheme.background.ignoresSafeArea())
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
                    startDraft(at: swapped, name: nil)
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
                        // The pick moves into the new-place card; an empty field is ready for the next search.
                        clearSearch()
                        searchFocused = false
                        searchMode = false
                        startDraft(at: c, name: item.name ?? String(format: "%.5f, %.5f", c.latitude, c.longitude),
                                   address: addressText(of: item))
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(item.name ?? "（未命名）")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                if approximateRows.contains(i) {
                                    Text("最接近")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(GpsTheme.orange)
                                        .fixedSize()
                                }
                            }
                            if let sub = resultSubtitle(of: item) {
                                Text(sub).font(.footnote).foregroundStyle(GpsTheme.sub).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .padding(.horizontal, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(approximateRows.contains(i) ? "\(item.name ?? "未命名")，最接近的結果，名稱不同"
                                                                    : (item.name ?? "未命名"))
                    .accessibilityHint("在地圖上標出，可以存成地點")
                    .accessibilityIdentifier("search.result.\(i)")
                    if i < searchResults.count - 1 {
                        Rectangle().fill(GpsTheme.line).frame(height: 1).padding(.leading, 14)
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.immediately)
        .background(GpsTheme.card.opacity(0.97), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func clearSearch() {
        searchID = UUID()
        isSearching = false
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
        // A link from Google/Apple Maps 「分享→複製連結」: read the place from the link itself.
        if let link = Self.pastedMapLink(q) {
            openMapLink(link)
            return
        }
        switch GpsCoordinateInput.parse(q) {
        case .valid(let c):
            clearSearch()
            searchFocused = false
            startDraft(at: c, name: nil)
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
        let normalizedQuery = Self.normalizeQuery(q)
        guard !normalizedQuery.isEmpty else {
            searchResults = []
            searchMessage = "找不到「\(q)」。試試英文名稱，或長按地圖直接新增。"
            return
        }
        searchFocused = false
        isSearching = true
        let myID = UUID()
        searchID = myID
        Task {
            guard let first = await searchCore(q, normalized: normalizedQuery, myID: myID) else { return }
            var (m, f, nf) = (first.matched, first.fallback, first.networkFailed)
            // Some Apple call got no answer in time: when nothing is listed, say the network is slow.
            var slow = first.timedOut
            var shorterQuery: String?
            // Nothing at all and not a network problem: vague or colloquial names (「台北海線」).
            if m.isEmpty && f.isEmpty && !nf {
                // The whole fallback stops after 8 s on 4G: past that, the plain 「找不到」 is kinder.
                let deadline = Date().addingTimeInterval(Self.searchBudgetSeconds)
                // a. The geocoder knows addresses and areas that the place search does not list.
                if await MainActor.run(body: { searchID != myID }) { return }
                let geo = await Self.geocode(q, timeout: deadline.timeIntervalSinceNow)
                if Date() < deadline { f = geo.items }
                nf = geo.networkFailed
                if geo.timedOut { slow = true }
                // b. Chinese: drop trailing characters (at least 2 left, at most 3 tries), one Taiwan
                // search each. A name containing the shorter text wins; other answers are only kept
                // as the 「沒有名稱完全相符」 list.
                if f.isEmpty && !nf && Self.hasCJK(q) {
                    let chars = Array(normalizedQuery)
                    var tried: Set<String> = [normalizedQuery]
                    var length = chars.count - 1
                    while length >= 2 && tried.count <= 3 && Date() < deadline {
                        let short = String(chars.prefix(length)).trimmingCharacters(in: .whitespaces)
                        length -= 1
                        guard short.count >= 2, tried.insert(short).inserted else { continue }
                        if await MainActor.run(body: { searchID != myID }) { return }
                        let r = await Self.mapSearch(short, region: GpsTheme.taiwanRegion,
                                                     timeout: deadline.timeIntervalSinceNow)
                        if r.timedOut { slow = true; break }
                        guard Date() < deadline else { break }
                        if r.networkFailed { nf = f.isEmpty; break }
                        let key = Self.fold(short)
                        let named = Self.uniqueItems(r.items.filter { Self.fold($0.name ?? "").contains(key) })
                        if !named.isEmpty {
                            m = named
                            shorterQuery = short
                            break
                        }
                        if f.isEmpty { f = Self.uniqueItems(r.items) }
                    }
                }
            }
            let (fm, ff, fnf, short, fslow) = (m, f, nf, shorterQuery, slow)
            await MainActor.run {
                // Cleared or replaced by a newer search while we waited: drop this answer.
                guard searchID == myID else { return }
                isSearching = false
                approximateRows = []
                if let short, !fm.isEmpty {
                    searchResults = Array(fm.prefix(6))
                    searchMessage = "找不到「\(q)」，以下是「\(short)」的結果"
                } else if !fm.isEmpty {
                    searchResults = Array(fm.prefix(6))
                    searchMessage = nil
                } else if !ff.isEmpty {
                    // The fallback can still hold the right place under another spelling (「Taipei 101」 →
                    // 「台北101」): those go first and need no warning; the rest are marked 「最接近」.
                    let close = ff.filter { Self.nameMatches(query: q, name: $0.name) }
                    let shown = Array((close + ff.filter { !Self.nameMatches(query: q, name: $0.name) }).prefix(6))
                    searchResults = shown
                    approximateRows = Set(shown.indices.filter { !Self.nameMatches(query: q, name: shown[$0].name) })
                    searchMessage = close.isEmpty ? "沒有名稱完全相符的結果，請看清楚再選；也可以試試英文名稱。" : nil
                } else if fslow {
                    searchResults = []
                    // No seconds in the text: the name search and the vague-name fallback each get
                    // searchBudgetSeconds, so the wait can be anything up to twice that.
                    searchMessage = "網路太慢，搜尋等太久沒有回應。請換個網路再試，或長按地圖直接新增。"
                } else if fnf {
                    searchResults = []
                    searchMessage = "搜尋需要網路，請確認連線後再試"
                } else {
                    searchResults = []
                    searchMessage = "找不到「\(q)」。試試英文名稱，或長按地圖直接新增。"
                }
            }
        }
    }

    // MARK: - Pasted map links

    /// What a 「複製連結」 paste holds: the link, plus the other lines (shop name, then address).
    private struct PastedMapLink {
        let url: URL
        let name: String?
        let address: String?
    }

    private func openMapLink(_ link: PastedMapLink) {
        // Name: the first non-link line of the paste, else the 「/place/名稱/」 part of the link,
        // else nil so the draft asks the reverse geocoder like a long-press does.
        let name = link.name ?? Self.mapLinkName(link.url)
        if let c = Self.mapLinkCoordinate(link.url) {
            clearSearch()
            searchFocused = false
            startDraft(at: c, name: name, address: link.address)
            return
        }
        guard Self.isShortMapLink(link.url) else {
            searchLinkText(name ?? link.address)
            return
        }
        searchFocused = false
        isSearching = true
        let myID = UUID()
        searchID = myID
        Task {
            let resolved = await Self.resolveMapLink(link.url)
            await MainActor.run {
                // Cleared or replaced by a newer search while we waited: drop this answer.
                guard searchID == myID else { return }
                isSearching = false
                if let final = resolved.url, let c = Self.mapLinkCoordinate(final) {
                    clearSearch()
                    searchFocused = false
                    startDraft(at: c, name: name ?? Self.mapLinkName(final), address: link.address)
                } else if resolved.networkFailed {
                    searchResults = []
                    searchMessage = "打開連結需要網路，請確認連線後再試"
                } else {
                    searchLinkText(name ?? resolved.url.flatMap { Self.mapLinkName($0) } ?? link.address)
                }
            }
        }
    }

    /// No position in the link: search its name (or address) the normal way instead.
    private func searchLinkText(_ text: String?) {
        // A name that is itself a link would come straight back here: treat it as no name.
        guard let text, !text.isEmpty, Self.pastedMapLink(text) == nil else {
            searchResults = []
            searchMessage = "這個連結裡找不到位置。請改貼地點名稱，或長按地圖直接新增。"
            return
        }
        searchText = text
        runSearch()
    }

    private static func pastedMapLink(_ text: String) -> PastedMapLink? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let whole = NSRange(text.startIndex..., in: text)
        guard let match = detector.matches(in: text, range: whole).first(where: {
                  ["http", "https"].contains($0.url?.scheme?.lowercased() ?? "") }),
              let found = match.url, let range = Range(match.range, in: text) else { return nil }
        let raw = String(text[range])
        // Map links only, with or without 「https://」 (upgraded below): google.<國碼>/maps…,
        // maps.google.*, and the share domains. 「google.com」 or any other site searches normally.
        let host = found.host?.lowercased() ?? ""
        let path = found.path.lowercased()
        let googleDomain = "google\\.(com|[a-z]{2})(\\.[a-z]{2})?$"
        let isMatch = { (pattern: String) in host.range(of: pattern, options: .regularExpression) != nil }
        let mapHost = (isMatch("^(www\\.)?" + googleDomain) && path.hasPrefix("/maps"))
            || isMatch("^maps\\." + googleDomain)
            || host == "maps.app.goo.gl" || (host == "goo.gl" && path.hasPrefix("/maps"))
            || host == "g.co" || host == "maps.apple" || host == "maps.apple.com"
        guard mapHost else { return nil }
        var parts = URLComponents(url: found, resolvingAgainstBaseURL: false)
        if parts?.scheme?.lowercased() == "http" && !raw.lowercased().hasPrefix("http") { parts?.scheme = "https" }
        guard let url = parts?.url else { return nil }
        // Each line with the link cut out; whatever text is left is the name, then the address.
        let lines = text.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: raw, with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return PastedMapLink(url: url, name: lines.first, address: lines.dropFirst().first)
    }

    /// Share links that only redirect: 「maps.app.goo.gl/…」, 「goo.gl/maps/…」, Apple 「maps.apple/p/…」.
    private static func isShortMapLink(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        if host == "maps.app.goo.gl" || host == "g.co" || host == "maps.apple" { return true }
        if host == "goo.gl" { return path.hasPrefix("/maps") || path.hasPrefix("/app") }
        if host.hasSuffix("maps.apple.com") { return path.hasPrefix("/p/") }
        return false
    }

    /// No cookies kept: a share link must not leave a Google session behind.
    private static let linkSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 8
        return URLSession(configuration: config)
    }()

    /// The whole redirect chain gets 8 s in total (timeoutInterval alone is per idle gap); past that
    /// the request is cancelled and treated like no network.
    private static func resolveMapLink(_ url: URL) async -> (url: URL?, networkFailed: Bool) {
        await withTaskGroup(of: (url: URL?, networkFailed: Bool)?.self) { group in
            group.addTask { await Self.followMapLink(url) }
            group.addTask {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? (nil, true)
        }
    }

    /// Follows the redirects with GET (some short links do not answer HEAD) and cancels as soon as
    /// the headers arrive, so the page itself is never downloaded on 4G.
    private static func followMapLink(_ url: URL) async -> (url: URL?, networkFailed: Bool) {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "GET"
        do {
            let (bytes, response) = try await linkSession.bytes(for: request)
            bytes.task.cancel()
            guard var final = response.url else { return (nil, false) }
            // Google's cookie page keeps the real address in 「continue=」.
            if let next = URLComponents(url: final, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "continue" })?.value, let nextURL = URL(string: next) {
                final = nextURL
            }
            return (final, false)
        } catch {
            NSLog("PinFly map link failed: %@", String(describing: error))
            return (nil, error is URLError)
        }
    }

    private static let linkNumber = "(-?\\d{1,3}(?:\\.\\d+)?)"

    private static func numberPair(_ pattern: String, in text: String) -> CLLocationCoordinate2D? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges >= 3,
              let r1 = Range(m.range(at: 1), in: text), let r2 = Range(m.range(at: 2), in: text),
              let lat = Double(text[r1]), let lon = Double(text[r2]) else { return nil }
        let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        return CLLocationCoordinate2DIsValid(c) && !(lat == 0 && lon == 0) ? c : nil
    }

    /// 「25.03,121.56」 or 「loc:25.03,121.56」 as a whole query value (not a place name).
    private static func coordinateValue(_ value: String) -> CLLocationCoordinate2D? {
        let v = value.replacingOccurrences(of: "+", with: " ")
        return numberPair("^\\s*(?:loc:)?\\s*\(linkNumber)\\s*,\\s*\(linkNumber)\\s*$", in: v)
    }

    /// Best first: 「!3d…!4d…」 is the place itself; q/query/ll/daddr (Apple: ll, coordinate, q)
    /// are a pin; 「/@lat,lng,」 is only where the map was looking, so it is used last and only on a
    /// 「/place/」 link (on /search or /dir it is just the screen, and the name is searched instead).
    private static func mapLinkCoordinate(_ url: URL) -> CLLocationCoordinate2D? {
        let text = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        if let c = numberPair("!3d\(linkNumber)!4d\(linkNumber)", in: text) { return c }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        for key in ["q", "query", "ll", "daddr", "coordinate"] {
            if let value = items.first(where: { $0.name == key })?.value, let c = coordinateValue(value) { return c }
        }
        guard url.pathComponents.contains("place") else { return nil }
        return numberPair("/@\(linkNumber),\(linkNumber)", in: text)
    }

    /// 「/place/Taipei+101/」 or 「/search/茶道/」, or a q/query/name value that is not a coordinate.
    private static func mapLinkName(_ url: URL) -> String? {
        let parts = url.pathComponents
        if let i = parts.firstIndex(where: { $0 == "place" || $0 == "search" }), i + 1 < parts.count {
            let piece = parts[i + 1].removingPercentEncoding ?? parts[i + 1]
            let name = piece.replacingOccurrences(of: "+", with: " ").trimmingCharacters(in: .whitespaces)
            if !name.isEmpty && !name.hasPrefix("@") { return name }
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        for key in ["q", "query", "name"] {
            guard let value = items.first(where: { $0.name == key })?.value, coordinateValue(value) == nil else { continue }
            let name = value.replacingOccurrences(of: "+", with: " ").trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return nil
    }

    private static func hasCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value >= 0x2E80 }
    }

    /// One full name search (Taiwan, then the world). nil = cleared or replaced by a newer search.
    private func searchCore(_ q: String, normalized normalizedQuery: String,
                            myID: UUID) async -> (matched: [MKMapItem], fallback: [MKMapItem], networkFailed: Bool, timedOut: Bool)? {
        // Taiwan first (fast, local names), then the whole world: a Taiwan-only search answered
        // 「大英博物館」 with a street in Taitung. Results whose name or address does not contain
        // the typed words are never listed first, and the message says so.
        let hasCJK = Self.hasCJK(q)
        // CJK: brackets and company suffixes removed; at most 3 Taiwan queries + 1 world query.
        let plan = Self.namePlan(normalizedQuery)
        let words = Self.queryWords(hasCJK ? normalizedQuery : q)
        // list = score 2+ (listed as real matches); weak = core name only, shown first in the fallback.
        let rank: ([MKMapItem]) -> (list: [MKMapItem], weak: [MKMapItem]) = { items in
            let scored: [(item: MKMapItem, score: Int)] = items.map { item in
                let name = Self.fold(item.name ?? "")
                let hay = Self.fold((item.name ?? "") + " " + (addressText(of: item) ?? ""))
                let legacy = Self.matches(item, words: words, address: addressText(of:)) ? 3 : 0
                return (item, max(legacy, hasCJK ? plan.score(name: name, haystack: hay) : 0))
            }
            let kept = scored.enumerated().filter { $0.element.score >= 2 }
                .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            return (kept.map { $0.element.item }, scored.filter { $0.score == 1 }.map { $0.item })
        }
        let taiwanQueries = hasCJK ? plan.taiwanQueries : [q]
        // All the Apple calls below share one budget; each is cancelled when the time left runs out.
        let deadline = Date().addingTimeInterval(Self.searchBudgetSeconds)
        let taiwan = await Self.mapSearch(taiwanQueries[0], region: GpsTheme.taiwanRegion, timeout: deadline.timeIntervalSinceNow)
        var pool = Self.uniqueItems(taiwan.items)
        var networkFailed = taiwan.networkFailed
        var timedOut = taiwan.timedOut
        var ranked = rank(pool)
        if hasCJK {
            var next = 1
            while ranked.list.isEmpty && next < taiwanQueries.count && !timedOut {
                if await MainActor.run(body: { searchID != myID }) { return nil }
                let extra = await Self.mapSearch(taiwanQueries[next], region: GpsTheme.taiwanRegion,
                                                 timeout: deadline.timeIntervalSinceNow)
                networkFailed = networkFailed && extra.networkFailed
                timedOut = timedOut || extra.timedOut
                pool = Self.uniqueItems(pool + extra.items)
                ranked = rank(pool)
                next += 1
            }
        }
        var matched = ranked.list
        var fallback = Self.uniqueItems(ranked.weak + pool)
        // Chinese query: ask the world when Taiwan has no name match. English query: names come
        // back in Chinese so they cannot be checked; ask the world when Taiwan is empty or its
        // first answer is outside Taiwan, and merge both lists (Taiwan first, no duplicates).
        let firstOutsideTaiwan = taiwan.items.first.map { $0.placemark.isoCountryCode != "TW" } ?? true
        if hasCJK ? ranked.list.isEmpty : (taiwan.items.isEmpty || firstOutsideTaiwan) {
            if await MainActor.run(body: { searchID != myID }) { return nil }
            let world = await Self.mapSearch(hasCJK ? plan.worldQuery : q, region: GpsTheme.worldRegion,
                                             timeout: deadline.timeIntervalSinceNow)
            networkFailed = networkFailed && world.networkFailed
            timedOut = timedOut || world.timedOut
            if hasCJK {
                let all = Self.uniqueItems(pool + world.items)
                let worldRanked = rank(all)
                matched = worldRanked.list
                fallback = Self.uniqueItems(worldRanked.weak + (world.items.isEmpty ? pool : world.items))
            } else {
                let merged = Self.uniqueItems(taiwan.items + world.items)
                matched = merged
                fallback = merged
            }
        }
        if await MainActor.run(body: { searchID != myID }) { return nil }
        return (matched, fallback, networkFailed, timedOut)
    }

    /// One Apple answer. `timedOut`: no answer within the time left, the request was cancelled
    /// (also counted as `networkFailed`, so callers that only look at that still stop).
    typealias SearchAnswer = (items: [MKMapItem], networkFailed: Bool, timedOut: Bool)

    /// Seconds the name search (and, separately, the vague-name fallback) may take in total on a slow 4G.
    static let searchBudgetSeconds: TimeInterval = 8

    /// Fallback for vague names: the geocoder (addresses, districts, areas), as plain map items.
    /// `networkFailed`: only kCLErrorNetwork; "not found" and other errors are just an empty list.
    /// CLGeocoder has no timeout of its own: after `timeout` seconds it is cancelled and reported as timedOut.
    private static func geocode(_ query: String, timeout: TimeInterval) async -> SearchAnswer {
        guard timeout > 0 else { return ([], true, true) }
        let geocoder = CLGeocoder()
        return await withCheckedContinuation { (continuation: CheckedContinuation<SearchAnswer, Never>) in
            let once = ResumeOnce(continuation)
            geocoder.geocodeAddressString(query, in: nil, preferredLocale: Locale(identifier: "zh_Hant_TW")) { marks, error in
                if let error {
                    NSLog("PinFly geocode failed: %@", String(describing: error))
                    if let cl = error as? CLError, cl.code == .network { once.resume(([], true, false)) }
                    else { once.resume(([], false, false)) }
                    return
                }
                let items = (marks ?? []).compactMap { mark -> MKMapItem? in
                    guard mark.location != nil else { return nil }
                    let item = MKMapItem(placemark: MKPlacemark(placemark: mark))
                    item.name = mark.name ?? mark.locality ?? query
                    return item
                }
                once.resume((items, false, false))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                // Only when the answer has not come yet; the late answer is then ignored.
                if once.resume(([], true, true)) {
                    NSLog("PinFly geocode timed out after %.1f s", timeout)
                    geocoder.cancelGeocode()
                }
            }
        }
    }

    /// `networkFailed`: the search itself errored for a reason other than "nothing found".
    /// MKLocalSearch has no timeout of its own: after `timeout` seconds it is cancelled and reported as timedOut.
    private static func mapSearch(_ query: String, region: MKCoordinateRegion, timeout: TimeInterval) async -> SearchAnswer {
        guard timeout > 0 else { return ([], true, true) }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = region
        let search = MKLocalSearch(request: request)
        return await withCheckedContinuation { (continuation: CheckedContinuation<SearchAnswer, Never>) in
            let once = ResumeOnce(continuation)
            search.start { response, error in
                if let error {
                    NSLog("PinFly search failed: %@", String(describing: error))
                    if let mk = error as? MKError, mk.code == .placemarkNotFound { once.resume(([], false, false)) }
                    else { once.resume(([], true, false)) }
                    return
                }
                once.resume((response?.mapItems ?? [], false, false))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                // Whether cancel() still calls the completion handler does not matter: ResumeOnce ignores it.
                if once.resume(([], true, true)) {
                    NSLog("PinFly search timed out after %.1f s", timeout)
                    search.cancel()
                }
            }
        }
    }

    /// Same text after folding case, full/half width, accents, simplified→traditional, 台→臺, and
    /// dropping spaces and punctuation, so 「台北 101」 finds 「臺北101」.
    private static let foldDropped = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)

    private static func fold(_ text: String) -> String {
        let hant = text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
        let folded = hant.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "台", with: "臺")
        return String(folded.unicodeScalars.filter { !foldDropped.contains($0) })
    }

    /// English words Apple answers in Chinese (Taiwan place names, common place types), longest first
    /// so 「sun moon lake」 is replaced before shorter words. Only used to compare names, never sent to Apple.
    private static let nameAliases: [(String, String)] = [
        ("sun moon lake", "日月潭"), ("night market", "夜市"), ("main station", "車站"),
        ("taipei", "臺北"), ("new taipei", "新北"), ("taichung", "臺中"), ("tainan", "臺南"),
        ("kaohsiung", "高雄"), ("taoyuan", "桃園"), ("hsinchu", "新竹"), ("keelung", "基隆"),
        ("chiayi", "嘉義"), ("changhua", "彰化"), ("miaoli", "苗栗"), ("nantou", "南投"),
        ("yunlin", "雲林"), ("pingtung", "屏東"), ("yilan", "宜蘭"), ("hualien", "花蓮"),
        ("taitung", "臺東"), ("penghu", "澎湖"), ("kinmen", "金門"), ("matsu", "馬祖"),
        ("tamsui", "淡水"), ("jiufen", "九份"), ("kenting", "墾丁"), ("alishan", "阿里山"),
        ("taroko", "太魯閣"), ("ximending", "西門町"), ("beitou", "北投"), ("shilin", "士林"),
        ("taiwan", "臺灣"), ("station", "車站"), ("airport", "機場"), ("museum", "博物館"),
        ("university", "大學"), ("park", "公園"), ("zoo", "動物園"), ("temple", "廟"),
    ].sorted { $0.0.count > $1.0.count }

    /// fold() plus the English aliases above, so 「Taipei 101」 and 「台北 101」 both become 「臺北101」.
    private static func aliasFold(_ text: String) -> String {
        var lower = text.lowercased()
        // Whole words only (「park」 inside 「parking」 stays), but digits may touch: 「taipei101」.
        for (english, chinese) in nameAliases {
            lower = lower.replacingOccurrences(of: "(?<![a-z])" + english + "(?![a-z])", with: chinese,
                                               options: .regularExpression)
        }
        return fold(lower)
    }

    /// A result counts as what was typed when the two names, folded (case, spaces, full/half width,
    /// 台/臺, simplified/traditional, English aliases), are equal or one contains the other.
    /// Two characters at least on each side, so a one-letter name never matches everything.
    static func nameMatches(query: String, name: String?) -> Bool {
        guard let name else { return false }
        let q = aliasFold(query)
        let n = aliasFold(name)
        guard q.count >= 2, n.count >= 2 else { return q == n && !q.isEmpty }
        return q.contains(n) || n.contains(q)
    }

    // Brackets and separators that Google Maps names carry (the full-width brackets around a branch name), turned into spaces.
    private static let queryPunctuation = CharacterSet(charactersIn: "【】「」『』()（）[]［］、,，;；:：·・｜|")

    static func normalizeQuery(_ query: String) -> String {
        let spaced = String(query.unicodeScalars.map { queryPunctuation.contains($0) ? Character(" ") : Character($0) })
        return spaced.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // Longest first so 股份有限公司 is not left as 股份有限 after dropping 公司.
    private static let companySuffixes = ["股份有限公司", "有限公司", "企業社", "分公司", "公司"]
    private static let branchTails = ["分公司", "營業所", "園區", "分廠", "廠", "分行", "門市", "分店", "店"]

    /// Same place seen twice (two queries) shows once; Apple hands out new objects per request, so compare by name and spot.
    static func uniqueItems(_ items: [MKMapItem]) -> [MKMapItem] {
        var seen = Set<String>()
        return items.filter {
            let c = $0.placemark.coordinate
            return seen.insert("\($0.name ?? "")|\(Int(c.latitude * 1000))|\(Int(c.longitude * 1000))").inserted
        }
    }

    /// What to ask Apple and how to judge answers: 台灣糖業股份有限公司【虎尾糖廠】 becomes
    /// core 台灣糖業, branch 虎尾糖廠 (stem 虎尾糖). Queries: normalized, 台灣 虎尾糖, 台灣糖業 (Apple may
    /// name the POI differently from Google Maps), and 台灣糖業 虎尾糖廠 as the one world query.
    struct NamePlan {
        let taiwanQueries: [String]
        let worldQuery: String
        let core: String
        let shortCore: String
        let stem: String
        /// More than two pieces typed (core, branch, something else): never better than 2 unless every word matched.
        let extraPieces: Bool

        /// 3 = core and branch stem found, 2 = stem plus short core in the NAME, 1 = core only although a branch was typed, 0 = no.
        /// Stem and short core are checked against the name only: addresses carry 臺灣 / road names and would match anything.
        func score(name: String, haystack: String) -> Int {
            guard !core.isEmpty else { return 0 }
            let hasCore = haystack.contains(core)
            var result = 0
            if stem.isEmpty {
                result = hasCore ? 3 : 0
            } else {
                let stemInName = name.contains(stem)
                if hasCore && stemInName { result = 3 }
                else if stemInName && name.contains(shortCore) { result = 2 }
                else if hasCore { result = 1 }
            }
            return extraPieces ? min(result, 2) : result
        }
    }

    static func namePlan(_ normalized: String) -> NamePlan {
        var stripped = normalized
        for suffix in companySuffixes { stripped = stripped.replacingOccurrences(of: suffix, with: " ") }
        let pieces = stripped.split(separator: " ").map(String.init)
        guard let core = pieces.first else {
            return NamePlan(taiwanQueries: [normalized], worldQuery: normalized, core: "", shortCore: "", stem: "", extraPieces: false)
        }
        let branch = pieces.count > 1 ? pieces[1] : ""
        var stem = branch
        if let tail = branchTails.first(where: { branch.hasSuffix($0) && branch.count > $0.count }) {
            stem = String(branch.dropLast(tail.count))
        }
        let shortCore = core.count >= 4 ? String(core.prefix(2)) : core
        var queries = [normalized]
        let candidates = [branch.isEmpty ? "" : "\(shortCore) \(stem)", core, branch.isEmpty ? "" : "\(core) \(branch)"]
        for candidate in candidates where !candidate.isEmpty && !queries.contains(candidate) {
            queries.append(candidate)
        }
        let world = queries.last ?? normalized
        let taiwan = (!branch.isEmpty && queries.count > 1) ? Array(queries.dropLast()) : queries
        return NamePlan(taiwanQueries: taiwan, worldQuery: world, core: fold(core), shortCore: fold(shortCore),
                        stem: fold(stem), extraPieces: pieces.count > 2)
    }

    /// The typed words, folded once per search (not once per result).
    private static func queryWords(_ query: String) -> [String] {
        query.split(whereSeparator: { $0 == " " || $0 == "　" }).map { fold(String($0)) }.filter { !$0.isEmpty }
    }

    /// Every typed word appears in the result's name or address.
    private static func matches(_ item: MKMapItem, words: [String], address: (MKMapItem) -> String?) -> Bool {
        let haystack = fold((item.name ?? "") + " " + (address(item) ?? ""))
        return !words.isEmpty && words.allSatisfy { haystack.contains($0) }
    }

    private func coordinate(of item: MKMapItem) -> CLLocationCoordinate2D {
        if #available(iOS 26, *) {
            return item.location.coordinate
        }
        return item.placemark.coordinate
    }

    /// 「國家・城市」 so a same-named place in another country is told apart at a glance.
    private func resultSubtitle(of item: MKMapItem) -> String? {
        let mark = item.placemark
        let parts = [mark.country, mark.locality ?? mark.administrativeArea].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? addressText(of: item) : parts.joined(separator: "・")
    }

    private func addressText(of item: MKMapItem) -> String? {
        if #available(iOS 26, *) {
            return item.address?.fullAddress
        }
        return item.placemark.title
    }

    // MARK: - Map tools (right edge, Apple Maps style)

    /// Round 44 pt buttons keep a fixed icon size: scaled with text they outgrew their circles.
    private static let roundIconFont = Font.system(size: 17, weight: .regular)

    /// The round buttons go in one row under the search bar when a column would not fit beside
    /// the toast room (large text, landscape, iPhone SE with banners); a column otherwise.
    private var toolsInRow: Bool {
        if largeText { return true }
        guard mapFrame.height > 1, topBarFrame.height > 1 else { return false }
        let count: CGFloat = store.places.isEmpty ? 2 : 4
        let column = count * 44 + (count - 1) * 8
        // 8 above the column, 8 below it, the toast room, the Legal label and the stack's bottom padding.
        let need = 8 + column + 8 + Self.toastReserve + Self.legalClearance + 8
        return mapFrame.maxY - topBarFrame.maxY < need
    }

    private var mapTools: some View {
        let layout = toolsInRow ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 8))
        return layout {
            Button {
                mapSatellite.toggle()
            } label: {
                Image(systemName: mapSatellite ? "map" : "globe.asia.australia.fill")
                    .font(Self.roundIconFont)
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
                        .font(Self.roundIconFont)
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
                        .font(Self.roundIconFont)
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
            shortcutsMenu
        }
        .fixedSize()
    }

    /// The owner's own shortcuts, one tap away even without the 4G banner (owner request 2026-10-27).
    private var shortcutsMenu: some View {
        Menu {
            if let url = GpsSimNetwork.renewShortcutURL {
                Button {
                    openShortcut(url)
                } label: {
                    Label(GpsSimNetwork.renewShortcutName, systemImage: "arrow.clockwise")
                }
            }
            if let url = GpsSimNetwork.shortcutURL {
                Button {
                    openShortcut(url)
                } label: {
                    Label(GpsSimNetwork.shortcutName, systemImage: "bolt.fill")
                }
            }
            if let url = URL(string: "shortcuts://") {
                Button {
                    openShortcut(url)
                } label: {
                    Label("打開捷徑 App", systemImage: "square.stack.3d.up")
                }
            }
        } label: {
            Image(systemName: "square.stack.3d.up.fill")
                .font(Self.roundIconFont)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(GpsTheme.card.opacity(0.94), in: Circle())
                .overlay(Circle().stroke(GpsTheme.line, lineWidth: 1))
                .contentShape(Circle())
        }
        // Keep the written order; the system would otherwise flip it when the menu opens upward.
        .menuOrder(.fixed)
        .accessibilityLabel("捷徑")
        .accessibilityHint("執行「出門改定位續簽」或「出門改定位」，或打開「捷徑」App")
        .accessibilityIdentifier("btn.shortcuts")
    }

    /// Opens the Shortcuts app; only a missing app is reported here (a missing shortcut is shown by Shortcuts itself).
    private func openShortcut(_ url: URL) {
        clearToast()
        openURL(url) { accepted in
            if !accepted { showToast("打不開「捷徑」App，請確認它沒有被刪除", autoClear: true) }
        }
    }

    // MARK: - Map

    /// Pins: white normally, mint while confirmed there, amber while kept but unconfirmed (offline).
    private func pinColor(_ p: GpsPlace) -> Color {
        guard isActivePlace(p) else { return failedPlaceID == p.id ? GpsTheme.sub : .white }
        return confirmation(at: now) ? GpsTheme.mint : GpsTheme.orange
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
                    let failed = failedPlaceID == p.id && !isActivePlace(p)
                    MapCircle(center: p.coordinate, radius: GpsGeo.radius(of: p))
                        .foregroundStyle(c.opacity(isActivePlace(p) ? 0.18 : (failed ? 0.04 : 0.10)))
                        .stroke(c.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: failed ? [6, 4] : []))
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
                // Dark band under the Apple Maps logo and Legal link, drawn as map content so it sits
                // beneath them (a SwiftUI overlay sat on top and dimmed the label itself, v1.0.13).
                // Above map labels and opaque: place names showed through and collided with "Maps".
                if legalScrim.count == 4 {
                    MapPolygon(coordinates: legalScrim)
                        .foregroundStyle(Color.black)
                        .mapOverlayLevel(level: .aboveLabels)
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
                updateLegalScrim(proxy)
            }
            .onChange(of: mapFrame) { _, _ in
                // MKMapView lays out a beat after SwiftUI reports the new frame (panel/banners resized):
                // recompute now and again after layout so the band never keeps a stale height.
                updateLegalScrim(proxy, refreshAttribution: true)
                DispatchQueue.main.async { updateLegalScrim(proxy, refreshAttribution: true) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { updateLegalScrim(proxy, refreshAttribution: true) }
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

    /// Corners of the band behind the Apple Maps logo and Legal link.
    /// Why UIKit: converting SwiftUI points with MapProxy put the band 29-75 pt above the
    /// map's bottom edge, growing with the bottom panel height (v1.0.14 screenshots), so the logo and Legal sat below it. The band is also recomputed after every map size change.
    /// The proxy's local space is not the space the logo is drawn in. We now ask the real MKMapView:
    /// its own bounds, the visible bottom edge (SwiftUI's mapFrame mapped into MKMapView coordinates)
    /// and the actual logo / attribution views, and convert with the view that draws the polygon.
    /// If no MKMapView is found we fall back to the proxy maths.
    /// `refreshAttribution` re-reads the logo position (cheap view-tree walk); camera frames reuse the cached value.
    private func updateLegalScrim(_ proxy: MapProxy, refreshAttribution: Bool = false) {
        let size = mapFrame.size
        guard size.width > 1, size.height > 1 else { return }
        var coords: [CLLocationCoordinate2D]
        if let mapView = legalProbe.mapView(matching: mapFrame) {
            let visibleBottom = mapView.convert(CGPoint(x: 0, y: mapFrame.maxY), from: nil).y
            let bottom = min(mapView.bounds.maxY, visibleBottom)
            if refreshAttribution || legalProbe.logoHeight == nil {
                var height = Self.legalBandHeight
                for view in Self.attributionViews(in: mapView) {
                    let frame = view.convert(view.bounds, to: mapView)
                    if frame.maxY > bottom - 80 { height = max(height, bottom - frame.minY + 4) }
                }
                legalProbe.logoHeight = height
            }
            // Clamp: a misread attribution view must not turn the band into a big dark slab.
            let top = bottom - min(60, max(Self.legalBandHeight, legalProbe.logoHeight ?? Self.legalBandHeight))
            let left = mapView.bounds.minX, right = mapView.bounds.maxX
            let pts = [CGPoint(x: left, y: top), CGPoint(x: right, y: top),
                       CGPoint(x: right, y: bottom), CGPoint(x: left, y: bottom)]
            coords = pts.map { mapView.convert($0, toCoordinateFrom: mapView) }
        } else {
            let top = size.height - Self.legalBandHeight, bottom = size.height
            let pts = [CGPoint(x: 0, y: top), CGPoint(x: size.width, y: top),
                       CGPoint(x: size.width, y: bottom), CGPoint(x: 0, y: bottom)]
            coords = pts.compactMap { proxy.convert($0, from: .local) }
        }
        // MKMapView returns invalid coordinates for points it cannot place: drop the band instead of drawing junk.
        coords = coords.filter { CLLocationCoordinate2DIsValid($0) }
        guard coords.count == 4 else { legalScrim = []; return }
        // Zoomed out across the ±180° line the corners flip sign and the polygon would wrap the globe.
        let lons = coords.map(\.longitude)
        if let lo = lons.min(), let hi = lons.max(), hi - lo > 180 { legalScrim = []; return }
        legalScrim = coords
    }

    private static let legalBandHeight: CGFloat = 32

    /// Apple Maps logo / Legal views inside the map, matched by class name. Read-only: never modified.
    private static func attributionViews(in root: UIView) -> [UIView] {
        var result: [UIView] = []
        func walk(_ view: UIView) {
            let name = String(describing: type(of: view))
            if name.contains("Attribution") || name.contains("AppleLogo") { result.append(view); return }
            view.subviews.forEach(walk)
        }
        walk(root)
        return result
    }

    /// Room the Apple Maps logo and Legal link need at the bottom-left of the map.
    private static let legalClearance: CGFloat = 22
    private static let toastReserve: CGFloat = 52

    /// Parts of the map covered by the floating controls, in points (rounded so tiny layout
    /// jitter does not refit the camera).
    private var mapInsets: EdgeInsets {
        guard mapFrame.width > 1 else { return EdgeInsets(top: 120, leading: 8, bottom: 40, trailing: 88) }
        let top = max(0, topBarFrame.maxY - mapFrame.minY)
        // Banners are outside the map now; only the toast floats over it: fixed room for it
        // (44 pt + spacing) above the Apple Maps logo, shown or not, so the map never jumps.
        let bottom = Self.legalClearance + 8 + Self.toastReserve
        // A row of buttons under the search bar covers the top, not the right edge.
        if toolsInRow, toolsFrame != .zero {
            let rowTop = max(top, toolsFrame.maxY - mapFrame.minY)
            return EdgeInsets(top: rowTop.rounded(), leading: 8, bottom: bottom.rounded(), trailing: 8)
        }
        // +24: a pin's name hangs out to the right of the pin, so leave room beyond the button column.
        let trailing = toolsFrame == .zero ? 88 : max(0, mapFrame.maxX - toolsFrame.minX) + 24
        return EdgeInsets(top: top.rounded(), leading: 8, bottom: bottom.rounded(), trailing: trailing.rounded())
    }

    private func focus(on c: CLLocationCoordinate2D, radius: Double) {
        apply(.place(c, radius), animated: true)
    }

    private func fitAllPlaces(animated: Bool = false) {
        guard !visiblePlaces.isEmpty else { return }
        apply(.all, animated: animated)
    }

    private func apply(_ framing: GpsFraming, animated: Bool) {
        lastFraming = framing
        let box: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)
        switch framing {
        case .place(let c, let radius):
            let half = max(radius * 2 + 300, 450) / 2
            let dLat = half / 111_320
            let dLon = half / (111_320 * max(cos(c.latitude * Double.pi / 180), 0.01))
            box = (c.latitude - dLat, c.latitude + dLat, c.longitude - dLon, c.longitude + dLon)
        case .all:
            let pts = visiblePlaces
            guard !pts.isEmpty else { return }
            if pts.count == 1 {
                apply(.place(pts[0].coordinate, GpsGeo.radius(of: pts[0])), animated: animated)
                lastFraming = .all
                return
            }
            // Bounds include each place's circle (not just the pin).
            var b = (minLat: 90.0, maxLat: -90.0, minLon: 180.0, maxLon: -180.0)
            for p in pts {
                let r = GpsGeo.radius(of: p)
                let dLat = r / 111_320
                let dLon = r / (111_320 * max(cos(p.lat * Double.pi / 180), 0.01))
                b.minLat = min(b.minLat, p.lat - dLat); b.maxLat = max(b.maxLat, p.lat + dLat)
                b.minLon = min(b.minLon, p.lon - dLon); b.maxLon = max(b.maxLon, p.lon + dLon)
            }
            box = b
        }
        let region = Self.region(fitting: box, in: mapFrame.size == .zero ? UIScreen.main.bounds.size : mapFrame.size,
                                 insets: mapInsets)
        if animated {
            withAnimation(.easeInOut(duration: 0.4)) { position = .region(region) }
        } else {
            position = .region(region)
        }
    }

    /// The region that shows `box` inside the open band of a map of `size` (Web Mercator, small
    /// spans: 1 pt is k degrees of longitude and k·cos(lat) degrees of latitude). The region has
    /// the map's own aspect, so MapKit shows it exactly and the band offset holds.
    private static func region(fitting box: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double),
                               in size: CGSize, insets: EdgeInsets) -> MKCoordinateRegion {
        let w = Double(max(size.width, 1)), h = Double(max(size.height, 1))
        // Pin heads stand 37 pt above their point and names hang ~18 pt below it.
        let top = Double(insets.top) + 44, bottom = Double(insets.bottom) + 22
        let left = Double(insets.leading) + 16, right = Double(insets.trailing) + 16
        let bandW = max(w - left - right, 80), bandH = max(h - top - bottom, 80)
        let midLat = (box.minLat + box.maxLat) / 2, midLon = (box.minLon + box.maxLon) / 2
        let cosLat = max(cos(midLat * Double.pi / 180), 0.01)
        let k = max((box.maxLon - box.minLon) / bandW, (box.maxLat - box.minLat) / (bandH * cosLat), 1e-7)
        let bandX = left + bandW / 2, bandY = top + bandH / 2
        let center = CLLocationCoordinate2D(latitude: midLat + (bandY - h / 2) * k * cosLat,
                                            longitude: midLon + (w / 2 - bandX) * k)
        return MKCoordinateRegion(center: center,
                                  span: MKCoordinateSpan(latitudeDelta: min(h * k * cosLat, 170),
                                                         longitudeDelta: min(w * k, 350)))
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
        engine.send(place: p) { code in sendFinished(code, placeID: p.id) }
    }

    /// A send that did not reach the phone must not look like one that did.
    private func sendFinished(_ code: Int32, placeID: String?) {
        guard code != GpsSimEngine.busyCode else { return }
        if code == 0 {
            failedPlaceID = nil
            return
        }
        // A failed new-place send (no id) must not wipe an earlier failed place's mark.
        if let placeID { failedPlaceID = placeID }
        // The red banner already explains a failure while nothing is simulating; a toast on top
        // repeated it. Only when no banner speaks for it (e.g. switching places) does a toast show.
        // Explained = a visible banner describes this very failure: the issue banner itself, or a
        // device banner of the same kind (on 4G the tunnel banner is always up, so a switch that
        // fails for another reason still needs its own toast).
        let kind = GpsSimIssue.from(code: code).kind
        let shownIDs = Set(orderedBanners.map(\.id))
        let explained = shownIDs.contains("issue")
            || (kind == .tunnel && shownIDs.contains("tunnel"))
            || (kind == .pairing && shownIDs.contains("pairing"))
            || (kind == .ddi && shownIDs.contains("ddi"))
        if !explained {
            showToast("沒送出：\(shortReason(code))", autoClear: true, duration: 8)
        }
    }

    private func shortReason(_ code: Int32) -> String {
        switch GpsSimIssue.from(code: code).kind {
        case .pairing: return "沒有配對檔"
        case .tunnel: return network.onWiFi ? "連不到手機" : "未連線（只有 4G）"
        case .ddi: return "DDI 還沒掛載"
        case .other: return "錯誤 \(code)"
        }
    }

    /// Sending can work now (otherwise the save toast does not offer 飛過去).
    private var canSend: Bool { demoReady || (pairingExists && linkUp) }

    // MARK: - Bottom: toast, banners, then the place card / new-place card / stop bar

    /// Banners sit under the map (not over it). While a card is open (new place / manage) a
    /// banner shrinks to one line so only one card is ever large on screen. On short screens and
    /// at large text the 4G steps fold behind 「看步驟」 so the place card stays reachable.
    private var bannerStack: some View {
        VStack(spacing: 8) {
            ForEach(orderedBanners) { b in
                if b.settingsTarget != nil {
                    GpsStatusLineRow(banner: b) {
                        settingsTarget = b.settingsTarget ?? .none
                        showSettings = true
                    }
                } else {
                    GpsBannerRow(banner: b, compact: draft != nil || managing,
                                 foldSteps: UIScreen.main.bounds.height < 700 || largeText)
                }
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
        }
    }

    /// Fixed card, never collapses (owner 2026-10-15: 「下面不用縮回去可以讓我直接點擊」).
    /// Two columns on a phone (three when wide); about three rows show, the rest scroll inside.
    private var placesCard: some View {
        GeometryReader { geo in
            let columns = Array(repeating: GridItem(.flexible(), spacing: 8),
                                count: largeText ? 1 : (geo.size.width >= 480 ? 3 : 2))
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
                .scrollIndicators(.visible)
                .scrollIndicatorsFlash(onAppear: true)
                .onChange(of: engine.activePlaceID) { _, id in
                    guard let id else { return }
                    withAnimation { reader.scrollTo(id) }
                }
                // A newly saved place can sit below the cut-off: scroll it into view (it also flashes).
                .onChange(of: flashFreshID) { _, id in
                    guard let id else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        withAnimation { reader.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
        .frame(height: placesCardHeight)
        .overlay(alignment: .bottom) {
            // More places below: fade the cut-off row and show a chevron so it reads as scrollable.
            if placesOverflow {
                ZStack(alignment: .bottom) {
                    LinearGradient(colors: [GpsTheme.card.opacity(0), GpsTheme.card], startPoint: .top, endPoint: .bottom)
                        .frame(height: 30)
                    Image(systemName: "chevron.compact.down")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(GpsTheme.sub)
                        .padding(.bottom, 2)
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(GpsTheme.line, lineWidth: 1))
    }

    /// Up to three rows of 48 pt cells plus padding; fewer places = shorter card, more map.
    private var placesRows: (all: Int, max: Int) {
        let perRow = largeText ? 1 : 2
        let all = (visiblePlaces.count + 1 + perRow - 1) / perRow
        // Large text: two tall rows still leave the map in view on an iPhone SE.
        return (all, largeText ? 2 : 3)
    }
    private var placesOverflow: Bool { placesRows.all > placesRows.max }

    private var placesCardHeight: CGFloat {
        let rows = min(placesRows.max, placesRows.all)
        // A peek of the next row (40 % of it) tells the list scrolls when there are more.
        let peek: CGFloat = placesOverflow ? max(22, placeCellHeight * 0.4) : 0
        return CGFloat(rows) * placeCellHeight + CGFloat(max(rows - 1, 0)) * 8 + 20 + peek
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
                .frame(maxWidth: .infinity, minHeight: placeCellHeight)
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
            .frame(maxWidth: .infinity, minHeight: placeCellHeight)
            .foregroundStyle(fresh ? GpsTheme.background : .white)
            // Kept but unconfirmed (offline): amber tint + 2 pt amber edge, still clearly "this one".
            .background(fresh ? GpsTheme.mint : (active ? GpsTheme.orange.opacity(0.22) : Color.white.opacity(0.09)),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(active && !fresh ? GpsTheme.orange : Color.clear, lineWidth: 2))
            // Last send to this place did not go out: grey dashed edge until a send succeeds.
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(failedPlaceID == p.id && !active ? GpsTheme.sub : Color.clear,
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(GpsTheme.mint, lineWidth: 3)
                .opacity(flashFreshID == p.id ? 1 : 0))
            .scaleEffect(flashFreshID == p.id ? 1.04 : 1)
            .animation(.easeInOut(duration: 0.3), value: flashFreshID)
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
            ScrollViewReader { manageReader in
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
                        .id(p.id)
                        Rectangle().fill(GpsTheme.line).frame(height: 1).padding(.leading, 16)
                    }
                }
            }
            // Order stays as the person arranged it; the list just opens scrolled to the newest save.
            .onAppear {
                guard let id = lastSavedPlaceID, store.sorted.contains(where: { $0.id == id }) else { return }
                DispatchQueue.main.async { manageReader.scrollTo(id, anchor: .center) }
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
            if let address = d.address, !address.isEmpty {
                Text(address)
                    .font(.footnote)
                    .foregroundStyle(GpsTheme.sub)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .accessibilityIdentifier("draft.address")
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

    private func startDraft(at c: CLLocationCoordinate2D, name: String?, address: String? = nil) {
        clearToast()
        searchMode = false
        managing = false
        draft = GpsDraft(coordinate: c, name: name ?? defaultDraftName, nameEdited: name != nil, address: address)
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
                                        preferredLocale: Locale(identifier: "zh_Hant_TW")) { marks, error in
            // Cancelled because a newer lookup started (second draft, map moved): that one answers instead.
            if let cl = error as? CLError, cl.code == .geocodeCanceled { return }
            let first = marks?.first
            let candidates = [first?.areasOfInterest?.first, first?.name, first?.thoroughfare, first?.locality]
            let found = candidates.compactMap({ $0 }).first(where: { !$0.isEmpty })
            DispatchQueue.main.async {
                guard var d = draft, !d.nameEdited else { return }
                // A pinned draft must still be at the looked-up point, or an older answer would name a
                // newer draft. (A center-following draft keeps its first coordinate, so it is not compared.)
                if !d.followsCenter {
                    guard abs(d.coordinate.latitude - c.latitude) < 1e-9,
                          abs(d.coordinate.longitude - c.longitude) < 1e-9 else { return }
                }
                if let found {
                    d.name = found
                } else if d.name == defaultDraftName, !d.followsCenter {
                    // Lookup failed or found no name (it has no timeout of its own): a pasted coordinate
                    // keeps its coordinate text as the name.
                    d.name = String(format: "%.5f, %.5f", c.latitude, c.longitude)
                } else { return }
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
        lastSavedPlaceID = place.id
        flashFreshID = place.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if flashFreshID == place.id { flashFreshID = nil }
        }
        guard canSend else {
            showToast("已存「\(place.name)」", autoClear: true)
            return
        }
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
        engine.send(to: GpsGeo.sampleLanding(temp, among: []), name: temp.name, center: point) { code in
            sendFinished(code, placeID: nil)
        }
    }

    // MARK: - Red stop button (top row, always visible, like 「⏹ 停止模擬」 on the PC page)

    /// Red while simulating or while a point from an earlier run may still be on the phone
    /// (staleTarget); otherwise the idle card style with 「已停止」.
    private var stopArmed: Bool { isSimulating || engine.staleTarget != nil }

    /// One tap, no hold, no confirm: the 10 s 復原 toast afterwards is the safety net.
    /// Idle (「已停止」) is never disabled: it still does the full clear, because a killed earlier
    /// run can leave a fake point on the phone that this app no longer knows about. This button is
    /// how the owner removes it.
    /// `fullWidth`: accessibility sizes put the button on its own row, at least 52 pt tall.
    private func stopButton(fullWidth: Bool) -> some View {
        let armed = stopArmed
        let title = stopping ? "停止中" : (armed ? "停止模擬" : "已停止")
        return Button {
            // No clearToast(): a pending 10 s 復原 from an earlier stop must survive an idle press.
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            runStop()
        } label: {
            HStack(spacing: 6) {
                if stopping {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: "stop.fill")
                }
                // The widest label sits hidden underneath, so switching between 停止模擬 and 已停止
                // never changes the button width and the status pill next to it does not jump.
                ZStack {
                    Text("停止模擬").opacity(0).accessibilityHidden(true)
                    Text(title)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(armed ? Color.white : GpsTheme.sub)
            .padding(.horizontal, 14)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: fullWidth ? 52 : 44)
            .frame(minWidth: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(GpsStopButtonStyle(armed: armed))
        // Compact: hug the text. Full width: stretch across the row, keep the natural height.
        .fixedSize(horizontal: !fullWidth, vertical: true)
        .disabled(engine.isBusy || stopping)
        .accessibilityLabel("停止模擬")
        .accessibilityHint("讓手機回到真實位置，10 秒內可復原")
        .accessibilityValue(armed ? "" : "目前已停止，是真實位置")
        .accessibilityIdentifier("btn.stop")
    }

    private func runStop() {
        if Self.demoState != nil { demoStopped = true; engine.applyDemoStop(); return }
        stopping = true
        engine.stop { code in
            stopping = false
            guard code != 0, code != GpsSimEngine.busyCode else { return }
            // The toast carries the reason and 重試; the duplicate red banner is dropped.
            engine.issue = nil
            showToast("沒停止：\(GpsSimIssue.from(code: code).message)", actionTitle: "重試",
                      action: { runStop() }, autoClear: true, duration: 8)
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
        let device = all.filter { $0.id != "file" && $0.id != "issue" && $0.id != "sign" }
        let sign = all.filter { $0.id == "sign" }
        // A day or less left (or expired), or a renewal running / just failed: the signing card takes
        // the device banner's place, since on 4G the tunnel banner never goes away (the status line
        // still says what is wrong).
        let urgent = (GpsSigning.daysLeft(now: signNow) ?? 99) <= 1 || renew.isRunning || renew.failure != nil
        if urgent, !sign.isEmpty {
            return errors + sign
        }
        let shown = errors + Array(device.prefix(1))
        // Otherwise it waits until no error or device banner is showing (one card at a time).
        return shown.isEmpty ? sign : shown
    }

    /// One-line sign status: 「簽名剩 2 天」/「簽名剩 5 小時」; a running or failed renewal says so.
    /// All buttons (立即續簽, 登入, progress, failure reasons) live in Settings now.
    private var signLineTitle: String {
        if renew.isRunning { return "續簽中…" }
        if renew.failure != nil { return "沒續簽成功，點看原因" }
        if renew.status.pendingInstall { return "新簽名已下載，等安裝" }
        guard let expiry = GpsSigning.expiration else { return "簽名快到期" }
        let state = GpsSignState(expiry: expiry, now: signNow)
        return state.level == .expired ? "簽名已過期" : "簽名\(state.remaining)"
    }

    private var banners: [GpsBanner] {
        var list: [GpsBanner] = []
        // Mock mode (renew simulator scripts) has no real phone link: skip the card so the screens
        // behind it can be captured.
        if !pairingExists && MockRenewBackend.isEnabled {
            // nothing: renewal works without a pairing file
        } else if !pairingExists {
            if !pairingCardDismissed {
                // Owner 2026-10-27: home shows one line only; 匯入配對檔 lives in Settings › 進階 › 配對檔.
                // The x button hides it so places can be saved first (same as the old 「先存地點」).
                list.append(GpsBanner(
                    id: "pairing", color: GpsTheme.orange,
                    title: "還沒配對",
                    detail: "第一次使用：配對檔是讓 PinFly 改這支手機定位的鑰匙，要用電腦產生一次。沒有電腦也可以先存地點，之後再匯入。",
                    secondaryTitle: "先隱藏，之後在設定匯入",
                    secondaryAction: { pairingCardDismissed = true },
                    settingsTarget: .pairing
                ))
            }
        } else if !demoReady && !linkUp {
            if tunnelGraceOver {
                var banner = GpsBanner(
                    id: "tunnel", color: GpsTheme.orange,
                    title: network.onWiFi ? "連不到手機" : GpsSimNetwork.noWifiTitle,
                    detail: engine.activeName != nil ? GpsSimNetwork.disconnectedHint : (network.onWiFi ? GpsSimNetwork.checkVPNMessage : GpsSimNetwork.noWifiMessage),
                    buttonTitle: "重試",
                    action: { retryTunnel() }
                )
                if !network.onWiFi {
                    // Owner 2026-10-27: the big 5-step card kept popping up. Home only says "not connected";
                    // the numbered 4G steps + shortcut live in Settings › 進階 › 連不上手機時.
                    banner = GpsBanner(
                        id: "tunnel", color: GpsTheme.orange,
                        title: "未連線（只有 4G）",
                        detail: engine.activeName != nil ? "假定位仍保留。" : "",
                        buttonTitle: "重試",
                        action: { retryTunnel() },
                        secondaryTitle: "步驟",
                        secondaryAction: { settingsTarget = .connection; showSettings = true }
                    )
                }
                list.append(banner)
            }
        } else if !demoReady, tunnel.isConnected, !mounting.coolisMounted, mounting.mountingThread == nil {
            // Needs the JIT tunnel: on 4G only the location link is up and mounting cannot work.
            // Owner 2026-10-27: one line on home; 掛載 DDI lives in Settings › 進階 › 開發者映像（DDI）.
            list.append(GpsBanner(
                id: "ddi", color: GpsTheme.orange,
                title: "DDI 還沒掛載",
                detail: "模擬定位需要先掛載 DDI（開發者映像）。第一次會先下載，約數十 MB。",
                settingsTarget: .ddi
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
        // One-line status; the renew buttons, sign-in and failures live in Settings › 簽名.
        if renew.signCardVisible(now: signNow) {
            let expiry = GpsSigning.expiration ?? Date()
            let state = GpsSignState(expiry: expiry, now: signNow)
            // A downloaded signature waiting to be installed is good news: mint, not a warning colour.
            let pendingOnly = renew.status.pendingInstall && !renew.isRunning && renew.failure == nil
            let signColor: Color = pendingOnly ? GpsTheme.mint
                : (state.level == .expired || renew.failure != nil) ? GpsTheme.red
                : (state.level == .today ? GpsTheme.orange : GpsTheme.yellow)
            var signBanner = GpsBanner(id: "sign", color: signColor, title: signLineTitle,
                                       detail: "\(signLineTitle)。續簽、登入和失敗原因都在設定。",
                                       secondaryTitle: "稍後提醒",
                                       secondaryAction: { renew.snooze(now: signNow) },
                                       settingsTarget: .renew)
            // Under 3 hours left: a one-tap 續簽 on the line itself (same call as the Settings button;
            // false = not signed in yet, so send them to the renew section instead).
            if pendingOnly {
                // No ✕ / 稍後提醒: the line stays while a signature waits, so snoozing would do nothing.
                signBanner.secondaryTitle = nil
                signBanner.secondaryAction = nil
                // Installs the waiting signature (no Apple, no sign-in needed).
                signBanner.buttonTitle = "裝上"
                signBanner.action = {
                    if !renew.renewNow() { settingsTarget = .renew; showSettings = true }
                }
            } else if !renew.isRunning, state.level != .expired, state.hours < 3 {
                signBanner.buttonTitle = "續簽"
                signBanner.action = {
                    if !renew.renewNow() { settingsTarget = .renew; showSettings = true }
                }
            }
            list.append(signBanner)
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
            // Accessibility sizes: text on top, the action underneath, so 復原 is never squeezed out.
            let layout = largeText
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                : AnyLayout(HStackLayout(spacing: 12))
            let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
            layout {
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
                            .fixedSize()
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .layoutPriority(1)
                    .accessibilityIdentifier("toast.action")
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.top, largeText ? 8 : 0)
            .frame(minHeight: 44)
            .background(GpsTheme.background.opacity(0.96), in: shape)
            .overlay(shape.stroke(GpsTheme.mint.opacity(0.5), lineWidth: 1))
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
        // scenePhase does not change on the first launch, so the reminders and auto-renew check run here too.
        // Not during a background launch (background download, Shortcut): only when he really opened the app.
        // (`!= .background`, not `== .active`: a normal cold launch can still be `.inactive` here.)
        if UIApplication.shared.applicationState != .background { renew.appBecameActive() }
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
                let eiffelTower = CLLocationCoordinate2D(latitude: 48.8584, longitude: 2.2945)
                engine.applyDemoSimulation(name: "艾菲爾鐵塔", coordinate: eiffelTower)
                focus(on: eiffelTower, radius: 200)
            case "edit":
                editing = first
            case "settings":
                showSettings = true
            case "search":
                searchMode = true
                searchText = "艾菲爾"
                runSearch()
            case "undoToast":
                if let p = first { deletePlace(p) }
            case "errorNoWifi":
                engine.applyDemoIssue(noWifi: true)
            case "errorVPN":
                engine.applyDemoIssue(noWifi: false)
            case "renewRunning":
                Task {
                    await renew.refreshStatus()
                    renew.renewNow()
                }
            case "renewFailed":
                renew.applyDemoFailure(.anisetteTimeout(seconds: 17))
            case "settingsSign", "settingsSignPending":
                showSettings = true
            case "signIn":
                showRenewSignIn = true
            case "primer":
                // The first-time location line; 繼續 here only closes it (CI already granted location).
                GpsLocationPrimer.present { _ in }
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
    /// A saved place is kept on the phone but not confirmed lately: amber, never the grey of 真實位置.
    var kept = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if fresh && !reduceMotion {
                GpsPulseRing(delay: 0)
                GpsPulseRing(delay: 0.8)
            }
            Circle()
                .fill(fresh ? GpsTheme.mint : (active && kept ? GpsTheme.orange : (active ? GpsTheme.sub : Color.white.opacity(0.45))))
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

/// A setup status squeezed into one tappable line (colored bar, title, chevron). Tapping opens
/// Settings at the right part; an optional x (the banner's secondary action) hides it.
private struct GpsStatusLineRow: View {
    let banner: GpsBanner
    let open: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(banner.color).frame(width: 4, height: 24)
                        .accessibilityHidden(true)
                    Text(banner.title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(GpsTheme.sub)
                        .accessibilityHidden(true)
                }
                .padding(.leading, 8)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(banner.title + "。" + banner.detail)
            .accessibilityHint("點兩下打開設定")
            .accessibilityIdentifier("banner." + banner.id)
            if let title = banner.buttonTitle, let action = banner.action {
                Button(action: action) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .background(GpsTheme.mint, in: Capsule())
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("banner." + banner.id + ".primary")
            }
            if let label = banner.secondaryTitle, let dismiss = banner.secondaryAction {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(GpsTheme.sub)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .accessibilityIdentifier("banner." + banner.id + ".dismiss")
            }
        }
        .padding(.horizontal, 8)
        .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// One-line banner; the explanation hides behind a chevron so banners stay short.
private struct GpsBannerRow: View {
    let banner: GpsBanner
    /// One line (title + button) while another card is open.
    var compact = false
    /// Steps start folded behind 「看步驟」 (short screens, large text).
    var foldSteps = false
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
            if !compact && !banner.steps.isEmpty && foldSteps {
                // Folded: the one-tap shortcut stays visible, the five steps open on demand.
                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    Label(expanded ? "收起步驟" : "看步驟", systemImage: expanded ? "chevron.up" : "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 10)
                .accessibilityIdentifier("banner.steps")
                stepsView(showSteps: expanded)
            } else if !compact && !banner.steps.isEmpty {
                stepsView(showSteps: true)
            } else if !compact && (expanded || (showsDetailInline && !banner.detail.isEmpty)) {
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

    /// ①…⑤ in reading order, one per line.
    private func stepsView(showSteps: Bool) -> some View {
        let marks = ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨"]
        return VStack(alignment: .leading, spacing: 6) {
            // One column, read top to bottom (two columns read as ①② / ③④ and confused reviewers).
            if showSteps {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(banner.steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(i < marks.count ? marks[i] : "\(i + 1).")
                            .foregroundStyle(banner.color)
                        Text(step)
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.subheadline)
                    .accessibilityElement(children: .combine)
                }
            }
            }
            if let title = banner.linkTitle, let url = banner.linkURL {
                Button {
                    UIApplication.shared.open(url) { opened in
                        if !opened { banner.onLinkFailed?() }
                    }
                } label: {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GpsTheme.mint)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(GpsTheme.mint.opacity(0.7), lineWidth: 1.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("打開「捷徑」App 執行")
                .accessibilityIdentifier("banner.shortcut")
            }
        }
        .padding(.leading, 10)
        .padding(.bottom, 6)
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
                        Text("刪除地點")
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .accessibilityIdentifier("edit.delete")
                }
                .listSectionSpacing(28)
            }
            // Room under the last row so 刪除地點 scrolls fully clear of the bottom edge.
            .contentMargins(.bottom, 40, for: .scrollContent)
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
        .dynamicTypeSize(...GpsSimHomeView.maxTypeSize)
    }
}


/// Remembers the MKMapView behind SwiftUI's Map (weakly) and the logo height, so the Legal band
/// does not walk the whole view tree on every camera frame.
final class GpsLegalProbe {
    weak var cachedMapView: MKMapView?
    var logoHeight: CGFloat?

    /// The MKMapView whose window-space frame matches SwiftUI's `mapFrame` (several windows/maps may exist).
    func mapView(matching mapFrame: CGRect) -> MKMapView? {
        if let cached = cachedMapView, cached.window != nil { return cached }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        var candidates: [MKMapView] = []
        func walk(_ view: UIView) {
            if let map = view as? MKMapView { candidates.append(map); return }
            view.subviews.forEach(walk)
        }
        windows.forEach(walk)
        let match = candidates.first { map in
            let frame = map.convert(map.bounds, to: nil)
            return abs(frame.minX - mapFrame.minX) < 4 && abs(frame.minY - mapFrame.minY) < 4
                && abs(frame.width - mapFrame.width) < 4
        }
        cachedMapView = match ?? candidates.first
        logoHeight = nil
        return cachedMapView
    }
}

/// 停止模擬 capsule. Armed (simulating or leftover point): solid red, darker while pressed.
/// Idle: the same opaque card as the status pill with a grey outline. A transparent idle button
/// measured 1.84:1 against bright satellite imagery, which is why it could not be seen.
private struct GpsStopButtonStyle: ButtonStyle {
    let armed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if armed {
                    Capsule().fill(configuration.isPressed ? GpsTheme.stopRedPressed : GpsTheme.stopRed)
                } else {
                    ZStack {
                        Capsule().fill(GpsTheme.card.opacity(0.94))
                        if configuration.isPressed { Capsule().fill(Color.white.opacity(0.08)) }
                    }
                }
            }
            .overlay(Capsule().stroke(armed ? GpsTheme.stopBorder : GpsTheme.idleBorder,
                                      lineWidth: armed ? 1 : 1.5))
    }
}
