//
//  GpsSimIntents.swift
//  StikDebug (GpsSim fork)
//
//  The "buttons" the iOS Shortcuts app can press: 定位儀連線 / 定位到地點 / 停止定位.
//  The intended one-tap Shortcut when only cellular is available:
//    Airplane Mode ON -> Wi-Fi ON -> 定位儀連線 -> Airplane Mode OFF -> open 定位儀.
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
        // Waited, not required: the connect step may already have been done earlier.
        _ = await GpsSimIntentRunner.waitForTunnel()
        await GpsSimIntentRunner.waitUntilIdle()
        let engine = GpsSimEngine.shared
        let landing = GpsGeo.sampleLanding(saved, among: store.places)
        let code: Int32 = await withCheckedContinuation { continuation in
            engine.send(to: landing, name: saved.name, center: saved.coordinate, placeID: saved.id) {
                continuation.resume(returning: $0)
            }
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
        _ = await GpsSimIntentRunner.waitForTunnel()
        await GpsSimIntentRunner.waitUntilIdle()
        let code: Int32 = await withCheckedContinuation { continuation in
            GpsSimEngine.shared.stop { continuation.resume(returning: $0) }
        }
        guard code == 0 else {
            let reason = code == GpsSimEngine.busyCode ? "定位儀正在忙，請稍後再試。" : GpsSimIssue.from(code: code).message
            return .result(dialog: "停止失敗：\(reason)")
        }
        return .result(dialog: "已回到真實位置")
    }
}
