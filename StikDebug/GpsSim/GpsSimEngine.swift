//
//  GpsSimEngine.swift
//  StikDebug (GpsSim fork)
//
//  Thin layer over StikDebug's own location plumbing — no FFI code of its own:
//    simulate_location / clear_simulated_location   (Device/IdeviceFFIBridge.swift)
//    LocationSimulationCommandQueue                   (same file; all FFI calls stay serial)
//    LocationSimulationSession.shared                 (Services/; keep-alive audio+location, 4 s timer)
//  What it adds is GpsSim's behaviour: remember the landing point and, on every 4 s resend,
//  jitter within 4 m of it (web: JITTER drift) instead of resending the exact same point.
//

import Foundation
import CoreLocation
import UIKit
import Network

/// Watches whether the phone is on Wi-Fi. StikDebug's heartbeat needs LocalDevVPN ON *and* Wi-Fi
/// connected, so on 4G only the VPN being on is not enough (error 3).
@MainActor
final class GpsSimNetwork: ObservableObject {
    static let shared = GpsSimNetwork()

    nonisolated static let noWifiTitle = "沒有連上 Wi-Fi"
    /// The 4G route the owner confirmed on his phone 2026-10-15 (the fake point stays after airplane mode is off).
    nonisolated static let fourGSteps = "只有 4G 時：開 LocalDevVPN → 開飛航 → 開 Wi-Fi → 回定位儀點地點 → 關飛航（假定位會保留）。或用捷徑一鍵完成。"
    /// The same route as numbered steps for the banner (each short enough for an iPhone SE column).
    nonisolated static let fourGStepList = ["開 LocalDevVPN", "開飛航模式", "開 Wi-Fi", "回來點地點", "關飛航模式"]
    /// The owner's own shortcut that runs the route above (built and tested by him 2026-10-15).
    nonisolated static let shortcutName = "出門改定位"
    nonisolated static var shortcutURL: URL? {
        var c = URLComponents(string: "shortcuts://run-shortcut")
        c?.queryItems = [URLQueryItem(name: "name", value: shortcutName)]
        return c?.url
    }
    nonisolated static let noWifiMessage = fourGSteps
    nonisolated static let disconnectedHint = "連線中斷，定位仍保留。要換地點：" + fourGSteps
    nonisolated static let checkVPNMessage = "LocalDevVPN 開著還是連不到：請把它關掉再打開，然後按「重試」。"

    @Published private(set) var onWiFi = true
    /// A utun interface holding a 10.7.0.x address was seen (LocalDevVPN's range). Used only as a
    /// positive signal; "not seen" is never reported as "VPN is off" because this is unverified on device.
    @Published private(set) var vpnSeen = false
    /// Screenshot-only override from `-GpsSimDemo errorNoWifi` / `errorVPN`.
    private var demoOnWiFi: Bool?

    /// Mirror for non-main readers (GpsSimIssue.from); written only on the main actor.
    nonisolated(unsafe) static var onWiFiNow = true

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.usesInterfaceType(.wifi)
            let vpn = Self.detectVPNUp()
            Task { @MainActor in self?.apply(wifi: wifi, vpn: vpn) }
        }
        monitor.start(queue: DispatchQueue(label: "gpssim.netmonitor"))
    }

    private func apply(wifi: Bool, vpn: Bool) {
        guard demoOnWiFi == nil else { return }
        onWiFi = wifi
        vpnSeen = vpn
        Self.onWiFiNow = wifi
    }

    func applyDemo(onWiFi wifi: Bool) {
        demoOnWiFi = wifi
        onWiFi = wifi
        Self.onWiFiNow = wifi
    }

    /// Row hint when the device chain is not ready. `tunnelConnected` is StikDebug's own tunnel flag.
    func deviceHint(tunnelConnected: Bool) -> String {
        if !onWiFi { return Self.noWifiMessage }
        return tunnelConnected ? "先掛載開發者映像（DDI）" : Self.checkVPNMessage
    }

    nonisolated private static func detectVPNUp() -> Bool {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return false }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let ifa = entry.pointee
            if String(cString: ifa.ifa_name).hasPrefix("utun"),
               let addr = ifa.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) {
                let octets = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    withUnsafeBytes(of: $0.pointee.sin_addr.s_addr) { Array($0) }
                }
                if octets.count == 4, octets[0] == 10, octets[1] == 7, octets[2] == 0 { return true }
            }
            cursor = ifa.ifa_next
        }
        return false
    }
}

/// A failure translated into Traditional Chinese with the next step to take.
struct GpsSimIssue: Equatable {
    enum Kind { case pairing, tunnel, ddi, other }
    let kind: Kind
    let message: String

    /// Maps simulate_location / clear_simulated_location status codes
    /// (LocationSimulationStatus in IdeviceFFIBridge.swift) to a user-facing hint.
    static func from(code: Int32) -> GpsSimIssue {
        switch code {
        case 1:
            return GpsSimIssue(kind: .other, message: "目標 IP 設定錯誤（\(DeviceConnectionContext.targetIPAddress)）。請到「進階 (StikDebug)」→ Settings 改回 10.7.0.1。")
        case 2:
            return GpsSimIssue(kind: .pairing, message: "配對檔讀不到或已失效。請在電腦上用 iloader 重新放配對檔。")
        case 3, 9:
            if !GpsSimNetwork.onWiFiNow {
                return GpsSimIssue(kind: .tunnel, message: "\(GpsSimNetwork.noWifiMessage)（錯誤 \(code)）")
            }
            return GpsSimIssue(kind: .tunnel, message: "連不到手機的定位服務。請先確認手機已連上 Wi-Fi，再確認 LocalDevVPN 已連線，然後再按一次。（錯誤 \(code)）")
        case 10:
            return GpsSimIssue(kind: .ddi, message: "定位服務打不開，多半是開發者磁碟映像（DDI）還沒掛載。請按上方「掛載 DDI」後再試。（錯誤 10）")
        case 11:
            return GpsSimIssue(kind: .other, message: "位置送不進手機（錯誤 11）。請解鎖手機後再按一次。")
        case 12:
            return GpsSimIssue(kind: .other, message: "沒能清掉手機上的模擬定位（錯誤 12），手機可能還停在假的位置。請解鎖手機、確認 LocalDevVPN 已連線後再按一次停止。")
        default:
            return GpsSimIssue(kind: .other, message: "定位失敗（錯誤 \(code)）。請確認 LocalDevVPN 已連線、DDI 已掛載後再試。")
        }
    }
}

/// Where a send put the blue dot; used for "回上一個" (undo).
struct GpsSendTarget {
    let name: String
    let placeID: String?
    let coordinate: CLLocationCoordinate2D
}

@MainActor
final class GpsSimEngine: ObservableObject {
    static let shared = GpsSimEngine()

    @Published private(set) var isBusy = false
    /// Name of what we're simulating (place name, or a label for a map point).
    @Published private(set) var activeName: String?
    /// Saved place being simulated (nil for a map point / search result).
    @Published private(set) var activePlaceID: String?
    /// The place's centre, used for "離圓心 N 公尺"; nil when sending an exact map point.
    @Published private(set) var activeCenter: CLLocationCoordinate2D?
    /// Where we landed; drift stays within GpsGeo.jitter of this.
    @Published private(set) var landing: CLLocationCoordinate2D?
    /// Point most recently sent to the device (landing or a drift step).
    @Published private(set) var current: CLLocationCoordinate2D?
    /// What was active before the latest send/stop; nil = the real location.
    @Published private(set) var previous: GpsSendTarget?
    /// Last time the device accepted a point (first send or a 4 s resend).
    @Published var lastSendSucceeded: Date?
    /// Last time the phone accepted any location command (send, resend tick or stop).
    /// Unlike lastSendSucceeded it survives a stop, so the UI does not call the link down
    /// right after 停止 on 4G, where the JIT tunnel never comes up.
    @Published var lastLinkOK: Date?
    /// The tunnel/connection dropped after a successful send (e.g. airplane mode). The phone is
    /// still simulated, so this is NOT an error and not "真實位置".
    @Published private(set) var connectionLost = false
    /// Last target sent in a previous launch (UserDefaults); only shown while nothing is active.
    @Published private(set) var staleTarget: GpsSendTarget?
    @Published var issue: GpsSimIssue?
    @Published var toast: String?

    /// Completion code meaning "another send/stop was already running" (not a device status code).
    static let busyCode: Int32 = -100

    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var failStreak = 0
    /// Resolved once per send() so the 4 s resend ticks do no disk work (prepareURL touches the file system).
    private var sessionPairingPath: String?
    private var sessionIP: String?

    private static let lastTargetKey = "gpssimLastTarget"

    private init() {
        _ = GpsSimNetwork.shared
        if let d = UserDefaults.standard.dictionary(forKey: Self.lastTargetKey),
           let name = d["name"] as? String, let lat = d["lat"] as? Double, let lon = d["lon"] as? Double {
            staleTarget = GpsSendTarget(name: name, placeID: d["placeID"] as? String,
                                        coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
    }

    /// UI hook: text for the status pill when it is not the plain 「模擬中」 / 「真實位置」, else nil.
    ///  - connection dropped while active: 「已定位：<name>（連線中斷，定位應該還在；要換地點請重新連線）」
    ///  - nothing active but a persisted target: 「上次定位：<name>（可能仍在作用中）」
    var statusNote: String? {
        if let name = activeName, connectionLost { return "已定位：\(name)（連線已中斷，定位仍保留）" }
        if activeName == nil, let stale = staleTarget { return "上次定位：\(stale.name)（可能仍在作用中）" }
        return nil
    }

    private func persistLastTarget(name: String, placeID: String?, coordinate: CLLocationCoordinate2D) {
        var d: [String: Any] = ["name": name, "lat": coordinate.latitude, "lon": coordinate.longitude]
        if let placeID { d["placeID"] = placeID }
        UserDefaults.standard.set(d, forKey: Self.lastTargetKey)
        staleTarget = GpsSendTarget(name: name, placeID: placeID, coordinate: coordinate)
    }

    private func clearLastTarget() {
        UserDefaults.standard.removeObject(forKey: Self.lastTargetKey)
        staleTarget = nil
    }

    /// Screenshot-only: `-GpsSimDemo errorNoWifi` / `errorVPN` — sets the matching error without touching the device.
    func applyDemoIssue(noWifi: Bool) {
        GpsSimNetwork.shared.applyDemo(onWiFi: !noWifi)
        issue = GpsSimIssue.from(code: 3)
    }

    /// Screenshot-only: pretends a simulation is running (`-GpsSimDemo simulating`).
    /// Sets published state only: no device, DVT or StikDebug calls, no timer.
    /// The landing sits `landingOffsetMeters` from the centre (north 60 % / east 80 %), so the
    /// status line's 「離圓心 N 公尺」 is a real, non-zero distance.
    func applyDemoSimulation(name: String, coordinate: CLLocationCoordinate2D, landingOffsetMeters: Double = 18) {
        let north = landingOffsetMeters * 0.6
        let east = landingOffsetMeters * 0.8
        let landed = CLLocationCoordinate2D(
            latitude: coordinate.latitude + north / 111_320,
            longitude: coordinate.longitude + east / (111_320 * cos(coordinate.latitude * Double.pi / 180))
        )
        activeName = name
        activePlaceID = nil
        activeCenter = coordinate
        landing = landed
        current = landed
    }

    static var pairingFilePath: String { PairingFileStore.prepareURL().path }

    static var pairingExists: Bool {
        FileManager.default.fileExists(atPath: pairingFilePath)
    }

    private var driftEnabled: Bool {
        UserDefaults.standard.object(forKey: GpsGeo.driftKey) as? Bool ?? true
    }

    /// What is being simulated right now (nil = real location).
    private var activeTarget: GpsSendTarget? {
        guard let name = activeName, let point = landing else { return nil }
        return GpsSendTarget(name: name, placeID: activePlaceID, coordinate: point)
    }

    /// One tap on a place: random landing inside its circle (union with overlapping circles).
    func send(place: GpsPlace, completion: ((Int32) -> Void)? = nil) {
        let point = GpsGeo.sampleLanding(place, among: GpsPlaceStore.shared.places)
        send(to: point, name: place.name, center: place.coordinate, placeID: place.id, completion: completion)
    }

    /// Send an exact coordinate (map tap / search result / external link / place landing).
    func send(to coordinate: CLLocationCoordinate2D, name: String,
              center: CLLocationCoordinate2D? = nil, placeID: String? = nil,
              completion: ((Int32) -> Void)? = nil) {
        guard !isBusy else { completion?(Self.busyCode); return }
        let path = Self.pairingFilePath
        guard FileManager.default.fileExists(atPath: path) else {
            issue = GpsSimIssue(kind: .pairing, message: "還沒有配對檔。請在電腦上用 iloader 放配對檔。")
            completion?(2)
            return
        }
        isBusy = true
        // The old 4 s timer would otherwise fire during this send and could pull the dot back
        // to the previous place after the new one landed.
        LocationSimulationSession.shared.pauseResending()
        let ip = DeviceConnectionContext.targetIPAddress
        let before = activeTarget
        LocationSimulationCommandQueue.shared.async {
            let code = simulate_location(ip, coordinate.latitude, coordinate.longitude, path)
            Task { @MainActor in
                self.isBusy = false
                guard code == 0 else {
                    self.issue = GpsSimIssue.from(code: code)
                    // The earlier simulation is still on the phone; keep it alive.
                    if let landing = self.landing { self.startTimer(at: landing) }
                    Haptics.light()
                    completion?(code)
                    return
                }
                self.issue = nil
                self.failStreak = 0
                self.connectionLost = false
                self.persistLastTarget(name: name, placeID: placeID, coordinate: coordinate)
                self.sessionPairingPath = path
                self.sessionIP = ip
                self.previous = before
                self.activeName = name
                self.activePlaceID = placeID
                self.activeCenter = center
                self.landing = coordinate
                self.current = coordinate
                self.lastSendSucceeded = Date()
                self.lastLinkOK = Date()
                self.beginBackgroundTask()
                LocationSimulationSession.shared.clearRoute()
                self.startTimer(at: coordinate)
                Haptics.medium()
                completion?(0)
            }
        }
    }

    /// Go back to what was active before the last send: re-send it exactly, or stop if that was the real location.
    func undoLastSend(completion: ((Int32) -> Void)? = nil) {
        guard !isBusy else { completion?(Self.busyCode); return }
        guard let target = previous else {
            stop(completion: completion)
            return
        }
        let center = target.placeID.flatMap { id in
            GpsPlaceStore.shared.places.first(where: { $0.id == id })?.coordinate
        }
        send(to: target.coordinate, name: target.name, center: center, placeID: target.placeID, completion: completion)
    }

    /// Same 4 s keep-alive timer StikDebug uses (MapSelectionView.startResendLoop),
    /// but each tick picks a fresh point within 4 m of the landing.
    private func startTimer(at coordinate: CLLocationCoordinate2D) {
        LocationSimulationSession.shared.startResending(at: coordinate) { [weak self] in
            // Hop explicitly: the session's closure is not main-actor typed. A tick that lands
            // after stop() sees landing == nil and does nothing.
            Task { @MainActor in self?.resendTick() }
        }
    }

    private func resendTick() {
        guard !isBusy, let landing, let path = sessionPairingPath, let ip = sessionIP else { return }
        let next = driftEnabled ? GpsGeo.offset(landing.latitude, landing.longitude, GpsGeo.jitter) : landing
        current = next
        LocationSimulationSession.shared.updateCoordinate(next)
        LocationSimulationCommandQueue.shared.async {
            let code = simulate_location(ip, next.latitude, next.longitude, path)
            Task { @MainActor in
                if code == 0 {
                    self.failStreak = 0
                    self.connectionLost = false
                    self.lastSendSucceeded = Date()
                    self.lastLinkOK = Date()
                    return
                }
                // Like the web tool: after 3 failures in a row, say so instead of
                // pretending the blue dot is still being delivered.
                self.failStreak += 1
                if self.failStreak == 3 {
                    if (code == 3 || code == 9) && self.activeName != nil {
                        // Real disconnect (airplane mode, VPN off): the phone keeps the fake
                        // location, so say that instead of an error banner or 真實位置.
                        self.connectionLost = true
                    } else {
                        self.issue = GpsSimIssue.from(code: code)
                    }
                }
            }
        }
    }

    /// 停止模擬: stop the timer first so no resend can re-enable simulation after the clear.
    /// The UI is only reset when the phone confirmed (code 0); otherwise the stop button stays.
    /// `full` (default) = clear everything on the phone, including a point left by a killed earlier
    /// process. `full: false` = the quick stop of this process's own handle only; 看真實位置 uses it
    /// because it has a 24 s budget and puts the point back right after.
    func stop(full: Bool = true, completion: ((Int32) -> Void)? = nil) {
        guard !isBusy else { completion?(Self.busyCode); return }
        isBusy = true
        beginBackgroundTask()
        let wasSimulating = activeName != nil || LocationSimulationSession.shared.isActive
        LocationSimulationSession.shared.pauseResending()
        LocationSimulationSession.shared.clearRoute()
        // Route playback moves the point through the session, so its coordinate comes first.
        let reopenPoint = LocationSimulationSession.shared.coordinate ?? current ?? landing ?? staleTarget?.coordinate
        let path = sessionPairingPath ?? Self.pairingFilePath
        let ip = sessionIP ?? DeviceConnectionContext.targetIPAddress
        LocationSimulationCommandQueue.shared.async {
            let finalCode: Int32
            if full {
                // A point left by an earlier (killed) process is not ours: clearing only this
                // process's handle used to report success while the phone kept the old place
                // (seen on device 2026-10-18).
                // Set-then-clear fallback only while we are simulating ourselves: from an idle press
                // a failed clear after the set would pin the phone to the stale point.
                let fallback = wasSimulating ? reopenPoint.map { (latitude: $0.latitude, longitude: $0.longitude) } : nil
                finalCode = clear_all_simulated_locations(ip, path, fallbackPoint: fallback)
            } else {
                var code = clear_simulated_location()
                // Code 12 = no open handle in this process: reopen at the current point, then clear.
                if code == 12, let point = reopenPoint {
                    let reopened = simulate_location(ip, point.latitude, point.longitude, path)
                    code = reopened == 0 ? clear_simulated_location() : reopened
                }
                finalCode = code == 12 && reopenPoint == nil ? 0 : code
            }
            Task { @MainActor in
                self.isBusy = false
                guard finalCode == 0 else {
                    self.issue = GpsSimIssue.from(code: finalCode)
                    // Deliberately no timer restart: after a stop attempt we never re-send a fake point.
                    self.endBackgroundTask()
                    Haptics.light()
                    completion?(finalCode)
                    return
                }
                self.clearLastTarget()
                self.connectionLost = false
                self.lastLinkOK = Date()
                self.issue = nil
                // Idle phone + red button = clearing leftovers of an earlier run: say that, not "returned".
                self.toast = wasSimulating ? "已回到真實位置" : "已經是真實位置（已清除殘留）"
                // An idle press must not wipe a pending 10 s undo of an earlier stop.
                if let stopped = self.activeTarget { self.previous = stopped }
                self.activeName = nil
                self.activePlaceID = nil
                self.activeCenter = nil
                self.landing = nil
                self.current = nil
                self.failStreak = 0
                LocationSimulationSession.shared.stop()
                self.endBackgroundTask()
                completion?(0)
            }
        }
    }

    /// Screenshot-only: what a successful 停止模擬 leaves behind, without touching the device.
    func applyDemoStop() {
        previous = activeTarget
        activeName = nil
        activePlaceID = nil
        activeCenter = nil
        landing = nil
        current = nil
        toast = "已回到真實位置"
    }

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}
