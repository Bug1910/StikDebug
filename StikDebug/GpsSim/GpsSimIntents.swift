//
//  GpsSimIntents.swift
//  StikDebug (GpsSim fork)
//
//  The "buttons" the iOS Shortcuts app can press: 定位儀連線 / 定位到地點 / 停止定位.
//  The one-tap Shortcut the owner built 2026-10-15 (only cellular available):
//    VPN connect -> Airplane Mode ON -> Wi-Fi ON -> 定位到地點 (ask) -> Airplane Mode OFF -> cellular ON.
//  定位儀連線 is no longer needed there: it waits on the JIT tunnel, which the location link doesn't use.
//  Once the tunnel is up it keeps working after airplane mode goes off (verified on device).
//
//  Background vs foreground: openAppWhenRun is false on all three. Reason: the existing
//  KillProcessIntent in App/Intents.swift already starts the same tunnel (startTunnelInBackground)
//  from a background intent, and simulate_location / clear_simulated_location are plain FFI calls
//  that need no UI. Not yet verified on a device; if a Shortcut run ever reports a timeout while the
//  app works when opened by hand, flip openAppWhenRun to true.
//
//  The AppShortcutsProvider entries live in StikDebugShortcuts (App/Intents.swift): an app may have
//  only one provider.
//

import AppIntents
import Contacts
import CoreLocation
import Foundation

// MARK: - Place entity (what the Shortcut's picker lists)

struct GpsPlaceEntity: AppEntity, Sendable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "地點"
    static var defaultQuery = GpsPlaceQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct GpsPlaceQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [GpsPlaceEntity] {
        await MainActor.run {
            GpsPlaceStore.shared.reload()
            return GpsPlaceStore.shared.sorted
                .filter { identifiers.contains($0.id) }
                .map { GpsPlaceEntity(id: $0.id, name: $0.name) }
        }
    }

    func suggestedEntities() async throws -> [GpsPlaceEntity] {
        await MainActor.run {
            GpsPlaceStore.shared.reload()
            return GpsPlaceStore.shared.sorted.map { GpsPlaceEntity(id: $0.id, name: $0.name) }
        }
    }
}

// MARK: - Shared waiting logic

@MainActor
private enum GpsSimIntentRunner {
    /// Starts the tunnel if needed and polls up to `seconds`; re-kicks the start every 5 s
    /// (TunnelManager ignores a start while one is already running).
    static func waitForTunnel(seconds: Int = 20) async -> Bool {
        let tunnel = TunnelManager.shared
        if tunnel.isConnected { return true }
        guard GpsSimEngine.pairingExists else { return false }
        startTunnelInBackground(showErrorUI: false)
        for tick in 1...(seconds * 4) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if tunnel.isConnected { return true }
            if tick % 20 == 0 { startTunnelInBackground(showErrorUI: false) }
        }
        return tunnel.isConnected
    }

    /// Runs a device call and, while it fails with "not connected" (3) or "connection dropped" (9),
    /// retries for up to `seconds`. Replaces waiting on TunnelManager: that is the JIT tunnel,
    /// which the location link does not use and which never comes up on 4G (cost 20 s per run).
    static func retryingLink(seconds: Int = 12, _ call: @escaping (@escaping (Int32) -> Void) -> Void) async -> Int32 {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while true {
            await waitUntilIdle()
            let code: Int32 = await withCheckedContinuation { continuation in
                call { continuation.resume(returning: $0) }
            }
            guard code == 3 || code == 9, Date() < deadline else { return code }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    static func waitUntilIdle(seconds: Int = 5) async {
        for _ in 0..<(seconds * 4) where GpsSimEngine.shared.isBusy {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    static func tunnelFailureMessage() -> String {
        guard GpsSimEngine.pairingExists else { return "還沒有配對檔。請在電腦上用 iloader 放配對檔。" }
        let reason = GpsSimNetwork.shared.onWiFi ? GpsSimNetwork.checkVPNMessage : GpsSimNetwork.noWifiMessage
        return "連不上手機的定位服務（等了 20 秒）。\(reason)"
    }
}

// MARK: - Intents

struct ConnectIntent: AppIntent {
    static var title: LocalizedStringResource = "定位儀連線"
    static var description = IntentDescription("連上手機的定位服務。連上後可以關掉飛航模式。")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = await GpsSimIntentRunner.waitForTunnel()
        let message = ok ? "已連線，可以關掉飛航模式了" : GpsSimIntentRunner.tunnelFailureMessage()
        return .result(dialog: "\(message)")
    }
}

struct SendToPlaceIntent: AppIntent {
    static var title: LocalizedStringResource = "定位到地點"
    static var description = IntentDescription("把手機定位送到一個已存的地點（圓圈內隨機落點）。")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "地點", requestValueDialog: "要定位到哪裡？")
    var place: GpsPlaceEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = GpsPlaceStore.shared
        store.reload()
        guard let saved = store.places.first(where: { $0.id == place.id }) else {
            return .result(dialog: "找不到地點「\(place.name)」，可能已被刪除。")
        }
        let engine = GpsSimEngine.shared
        let landing = GpsGeo.sampleLanding(saved, among: store.places)
        let code = await GpsSimIntentRunner.retryingLink { done in
            engine.send(to: landing, name: saved.name, center: saved.coordinate, placeID: saved.id, completion: done)
        }
        guard code == 0 else {
            let reason = code == GpsSimEngine.busyCode ? "定位儀正在忙，請稍後再試。" : GpsSimIssue.from(code: code).message
            return .result(dialog: "定位失敗：\(reason)")
        }
        let meters = Int(GpsGeo.meters(saved.coordinate, landing).rounded())
        return .result(dialog: "已定位到 \(saved.name)（離圓心 \(meters) 公尺）")
    }
}

struct StopSimulationIntent: AppIntent {
    static var title: LocalizedStringResource = "停止定位"
    static var description = IntentDescription("讓手機回到真實位置。")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let code = await GpsSimIntentRunner.retryingLink { done in GpsSimEngine.shared.stop(completion: done) }
        guard code == 0 else {
            let reason = code == GpsSimEngine.busyCode ? "定位儀正在忙，請稍後再試。" : GpsSimIssue.from(code: code).message
            return .result(dialog: "停止失敗：\(reason)")
        }
        return .result(dialog: "已回到真實位置")
    }
}

/// 看真實位置: stop → read one real GPS fix → put the fake location back where it was.
/// While simulating, iOS hands every app (Shortcuts included) the fake point, so the only way
/// to see the real one is a short stop. Returns the real place so a Shortcut can show or share it.
struct PeekRealLocationIntent: AppIntent {
    static var title: LocalizedStringResource = "看真實位置"
    static var description = IntentDescription("暫停模擬幾秒，抓到真實位置後自動定位回原本的地點。")
    static var openAppWhenRun: Bool = false

    // Kept short on purpose: stop + GPS + resume must finish before Shortcuts gives up on the
    // intent (~30 s), or the phone would be left on the real location (review 2026-10-15).
    @Parameter(title: "最多等幾秒抓 GPS", default: 8, inclusiveRange: (3, 10))
    var seconds: Int

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<CLPlacemark?> & ProvidesDialog {
        let engine = GpsSimEngine.shared
        let deadline = Date().addingTimeInterval(24)
        let wasActive = engine.activeName
        // A point sent in an earlier launch may still be on the phone (staleTarget): stop it too,
        // or every fix would be the fake one and the message would wrongly blame GPS.
        let stale = wasActive == nil ? engine.staleTarget : nil
        if wasActive != nil || stale != nil {
            let code = await GpsSimIntentRunner.retryingLink(seconds: 5) { done in engine.stop(completion: done) }
            guard code == 0 else {
                let reason = code == GpsSimEngine.busyCode ? "定位儀正在忙，請稍後再試。" : GpsSimIssue.from(code: code).message
                return .result(value: nil, dialog: "沒辦法暫停模擬：\(reason)")
            }
        }
        // Leave at least 8 s of the budget for putting the fake location back.
        let gpsWait = min(TimeInterval(seconds), max(deadline.timeIntervalSinceNow - 8, 2))
        let fix = await GpsRealFix.read(timeout: gpsWait)
        var resumed = true
        if wasActive != nil {
            // stop() saved the stopped target as `previous`; undo re-sends that exact point.
            // (Side effect: afterwards 回上一個 leads to the real location, not the place before.)
            let code = await GpsSimIntentRunner.retryingLink(seconds: 5) { done in
                engine.undoLastSend(completion: done)
            }
            resumed = code == 0
        } else if let stale {
            let code = await GpsSimIntentRunner.retryingLink(seconds: 5) { done in
                engine.send(to: stale.coordinate, name: stale.name, placeID: stale.placeID, completion: done)
            }
            resumed = code == 0
        }
        let back = (wasActive ?? stale?.name).map { resumed ? "，已定位回「\($0)」" : "，但沒能定位回「\($0)」，請再送一次" } ?? ""
        guard let fix else {
            let why = GpsRealFix.authorized ? "\(Int(gpsWait.rounded())) 秒內抓不到 GPS（室內可能比較久）" : "定位儀沒有定位權限，請到「設定 › 定位儀 › 位置」打開"
            return .result(value: nil, dialog: "\(why)\(back)")
        }
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(fix).first
        let text = placemark.flatMap { [$0.locality, $0.subLocality, $0.thoroughfare, $0.subThoroughfare].compactMap { $0 }.joined() }
        let where_ = (text?.isEmpty == false ? text! : String(format: "%.5f, %.5f", fix.coordinate.latitude, fix.coordinate.longitude))
        let value = placemark ?? CLPlacemark(location: fix, name: "真實位置", postalAddress: nil)
        return .result(value: value, dialog: "真實位置：\(where_)（誤差約 \(Int(fix.horizontalAccuracy)) 公尺）\(back)")
    }
}

/// One real GPS fix, skipping points still flagged as simulated right after the stop
/// (pymobiledevice3 #572: the first fixes after a clear can be stale or coarse).
@MainActor
final class GpsRealFix: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var best: CLLocation?
    private var finish: ((CLLocation?) -> Void)?
    /// Fixes older than the read are CoreLocation's cache (e.g. home hours ago), not where he is now.
    private let started = Date()

    static var authorized: Bool {
        let s = CLLocationManager().authorizationStatus
        return s == .authorizedAlways || s == .authorizedWhenInUse
    }

    static func read(timeout: TimeInterval) async -> CLLocation? {
        guard authorized else { return nil }
        let reader = GpsRealFix()
        return await withCheckedContinuation { continuation in
            reader.finish = { continuation.resume(returning: $0) }
            reader.manager.delegate = reader
            reader.manager.desiredAccuracy = kCLLocationAccuracyBest
            // The intent runs in the background (openAppWhenRun = false); UIBackgroundModes has location.
            reader.manager.allowsBackgroundLocationUpdates = true
            reader.manager.startUpdatingLocation()
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { reader.done(reader.best) }
        }
    }

    private func done(_ location: CLLocation?) {
        guard let finish else { return }
        self.finish = nil
        manager.stopUpdatingLocation()
        finish(location)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            for l in locations where l.horizontalAccuracy >= 0 && l.timestamp >= started
                && l.sourceInformation?.isSimulatedBySoftware != true {
                if best == nil || l.horizontalAccuracy < best!.horizontalAccuracy { best = l }
            }
            if let best, best.horizontalAccuracy <= 50 { done(best) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
