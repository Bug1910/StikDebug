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
            return GpsSimIssue(kind: .tunnel, message: "連不到手機的定位服務。請打開 LocalDevVPN 並連上 Wi-Fi，再按一次。（錯誤 \(code)）")
        case 10:
            return GpsSimIssue(kind: .ddi, message: "定位服務打不開，多半是開發者磁碟映像（DDI）還沒掛載。請按上方「掛載 DDI」後再試。（錯誤 10）")
        case 11:
            return GpsSimIssue(kind: .other, message: "位置送不進手機（錯誤 11）。請解鎖手機後再按一次。")
        default:
            return GpsSimIssue(kind: .other, message: "定位失敗（錯誤 \(code)）。請確認 LocalDevVPN 已連線、DDI 已掛載後再試。")
        }
    }
}

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
    @Published var issue: GpsSimIssue?
    @Published var toast: String?

    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var failStreak = 0

    private init() {}

    static var pairingFilePath: String { PairingFileStore.prepareURL().path }

    static var pairingExists: Bool {
        FileManager.default.fileExists(atPath: pairingFilePath)
    }

    private var driftEnabled: Bool {
        UserDefaults.standard.object(forKey: GpsGeo.driftKey) as? Bool ?? true
    }

    /// One tap on a place: random landing inside its circle (union with overlapping circles).
    func send(place: GpsPlace, among all: [GpsPlace]) {
        let pt = GpsGeo.sampleLanding(place, among: all)
        send(to: pt, name: place.name, center: place.coordinate, placeID: place.id)
    }

    /// Send an exact coordinate (map tap / search result / place landing).
    func send(to coordinate: CLLocationCoordinate2D, name: String,
              center: CLLocationCoordinate2D? = nil, placeID: String? = nil) {
        guard !isBusy else { return }
        guard Self.pairingExists else {
            issue = GpsSimIssue(kind: .pairing, message: "還沒有配對檔。請在電腦上用 iloader 放配對檔。")
            return
        }
        isBusy = true
        let path = Self.pairingFilePath
        let ip = DeviceConnectionContext.targetIPAddress
        LocationSimulationCommandQueue.shared.async {
            let code = simulate_location(ip, coordinate.latitude, coordinate.longitude, path)
            DispatchQueue.main.async {
                self.isBusy = false
                guard code == 0 else {
                    self.issue = GpsSimIssue.from(code: code)
                    Haptics.light()
                    return
                }
                self.issue = nil
                self.failStreak = 0
                self.activeName = name
                self.activePlaceID = placeID
                self.activeCenter = center
                self.landing = coordinate
                self.current = coordinate
                self.beginBackgroundTask()
                LocationSimulationSession.shared.clearRoute()
                // Same 4 s keep-alive timer StikDebug uses (MapSelectionView.startResendLoop),
                // but each tick picks a fresh point within 4 m of the landing.
                LocationSimulationSession.shared.startResending(at: coordinate) { [weak self] in
                    self?.resendTick()
                }
                Haptics.medium()
            }
        }
    }

    /// Runs on the main run loop (LocationSimulationSession's Timer).
    private func resendTick() {
        guard let landing else { return }
        let next = driftEnabled ? GpsGeo.offset(landing.latitude, landing.longitude, GpsGeo.jitter) : landing
        current = next
        LocationSimulationSession.shared.updateCoordinate(next)
        let path = Self.pairingFilePath
        let ip = DeviceConnectionContext.targetIPAddress
        LocationSimulationCommandQueue.shared.async {
            let code = simulate_location(ip, next.latitude, next.longitude, path)
            DispatchQueue.main.async {
                if code == 0 {
                    self.failStreak = 0
                    return
                }
                // Like the web tool: after 3 failures in a row, say so instead of
                // pretending the blue dot is still being delivered.
                self.failStreak += 1
                if self.failStreak == 3 {
                    self.issue = GpsSimIssue.from(code: code)
                }
            }
        }
    }

    /// 停止模擬: stop the timer first so no resend can re-enable simulation after the clear.
    func stop() {
        guard !isBusy else { return }
        isBusy = true
        LocationSimulationSession.shared.pauseResending()
        LocationSimulationSession.shared.clearRoute()
        LocationSimulationCommandQueue.shared.async {
            let code = clear_simulated_location()
            DispatchQueue.main.async {
                self.isBusy = false
                // Code 12 also means "no open simulation handle in this process" (nothing of
                // ours to clear; the service connection is already gone), so treat it as done.
                if code == 0 || code == 12 {
                    self.issue = nil
                    self.toast = "已回到真實位置"
                } else {
                    self.issue = GpsSimIssue.from(code: code)
                }
                self.activeName = nil
                self.activePlaceID = nil
                self.activeCenter = nil
                self.landing = nil
                self.current = nil
                LocationSimulationSession.shared.stop()
                self.endBackgroundTask()
            }
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}
