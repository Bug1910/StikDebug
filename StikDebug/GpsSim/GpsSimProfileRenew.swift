//
//  GpsSimProfileRenew.swift
//  StikDebug (GpsSim fork)
//
//  The "swap the 7-day pass" helper. The app's signing certificate lasts a year; only the
//  provisioning profile (the 7-day pass) runs out. A new .mobileprovision made on the PC can be
//  checked here and put on the phone through misagent (iOS's profile service, reached over
//  LocalDevVPN) without reinstalling the app, so the saved places are never touched.
//  Nothing is installed unless EVERY check passes; profile contents are never logged.
//

import AppIntents
import Foundation
import UniformTypeIdentifiers

enum GpsProfileRenew {
    static let maxFileBytes = 64 * 1024
    private static let renewedExpiryKey = "gpssim.renewedProfileExpiry"
    static let needTunnelMessage = "需要 Wi-Fi 並且 LocalDevVPN 已連線（只有 4G 不行）。請在 Wi-Fi 下重新連線 LocalDevVPN 後再試。"

    static let fileTypes: [UTType] = {
        var types: [UTType] = []
        if let t = UTType(filenameExtension: "mobileprovision") { types.append(t) }
        types.append(.data)
        return types
    }()

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Parsed {
        let uuid: String
        let team: String
        let appID: String
        let expiration: Date
        let certs: Set<Data>
        let devices: Set<String>
        let entitlements: [String: Any]
    }

    // MARK: - Parse and validate

    static func parse(_ data: Data) throws -> Parsed {
        guard !data.isEmpty, data.count <= maxFileBytes else {
            throw Failure(message: "這不是描述檔（檔案大小不對）。")
        }
        guard let xml = try? CMSDecoderHelper.decodeCMSData(data),
              let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any],
              let uuid = plist["UUID"] as? String,
              let team = (plist["TeamIdentifier"] as? [String])?.first,
              let expiration = plist["ExpirationDate"] as? Date,
              let entitlements = plist["Entitlements"] as? [String: Any],
              let appID = entitlements["application-identifier"] as? String
        else { throw Failure(message: "讀不出這個描述檔，請確認選的是 .mobileprovision 檔。") }
        return Parsed(
            uuid: uuid, team: team, appID: appID, expiration: expiration,
            certs: Set(plist["DeveloperCertificates"] as? [Data] ?? []),
            devices: Set(plist["ProvisionedDevices"] as? [String] ?? []),
            entitlements: entitlements)
    }

    /// The profile this install carries now (nil on the simulator / CI).
    static func embedded() -> Parsed? {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? parse(data)
    }

    static func validate(_ data: Data, now: Date = Date()) throws -> Parsed {
        let new = try parse(data)
        guard let current = embedded(), let bundleID = Bundle.main.bundleIdentifier else {
            throw Failure(message: "讀不到這個 App 目前的簽名，無法檢查描述檔。")
        }
        guard new.team == current.team else { throw Failure(message: "描述檔的開發者隊伍和目前的簽名不同，已拒絕。") }
        guard new.appID == "\(current.team).\(bundleID)" else {
            throw Failure(message: "描述檔不是給定位儀的（App 識別碼不符），已拒絕。")
        }
        guard new.expiration > now else { throw Failure(message: "這個描述檔已經過期了。") }
        guard new.expiration > effectiveExpiration(embedded: current.expiration) else {
            throw Failure(message: "這個描述檔不比目前的新，沒有必要換。")
        }
        guard !new.certs.isDisjoint(with: current.certs) else {
            throw Failure(message: "描述檔的簽名憑證和目前的不同，換了會打不開，已拒絕。")
        }
        guard current.devices.isSubset(of: new.devices) else {
            throw Failure(message: "描述檔沒有包含這支手機，已拒絕。")
        }
        guard Set(new.entitlements.keys).isSubset(of: Set(current.entitlements.keys)) else {
            throw Failure(message: "描述檔的權限比目前的多，已拒絕。")
        }
        if new.entitlements["get-task-allow"] as? Bool == true, current.entitlements["get-task-allow"] as? Bool != true {
            throw Failure(message: "描述檔的權限比目前的多，已拒絕。")
        }
        return new
    }

    // MARK: - Install

    /// Install after validating; returns the newest expiry of this app's profiles read back from the phone.
    static func install(_ data: Data) async throws -> Date {
        let parsed = try validate(data)
        try await requireTunnel()
        return try await Task.detached(priority: .userInitiated) { () throws -> Date in
            try withTunnelRetry { try JITEnableContext.shared.addProfile(data) }
            // Read back instead of trusting the install call.
            let installed = (try? withTunnelRetry { try JITEnableContext.shared.fetchAllProfiles() }) ?? []
            let newest = installed.compactMap { try? parse($0) }
                .filter { $0.appID == parsed.appID }
                .map(\.expiration).max()
            guard let newest, newest >= parsed.expiration else {
                throw Failure(message: "裝完後在手機上沒讀到新的描述檔，請再試一次。")
            }
            UserDefaults.standard.set(newest.timeIntervalSince1970, forKey: renewedExpiryKey)
            return newest
        }.value
    }

    /// Removes ONLY this app's own profiles that are expired and older than the newest one, and only
    /// after an install of ours succeeded. Allow-list: exact app id match; other apps are never touched.
    static func removeOwnExpired() async throws -> Int {
        guard let current = embedded(), let bundleID = Bundle.main.bundleIdentifier else {
            throw Failure(message: "讀不到這個 App 目前的簽名。")
        }
        guard UserDefaults.standard.double(forKey: renewedExpiryKey) > 0 else {
            throw Failure(message: "要先成功匯入一次新的描述檔，才能清舊的。")
        }
        let ownID = "\(current.team).\(bundleID)"
        try await requireTunnel()
        return try await Task.detached(priority: .userInitiated) { () throws -> Int in
            let own = try withTunnelRetry { try JITEnableContext.shared.fetchAllProfiles() }
                .compactMap { try? parse($0) }
                .filter { $0.appID == ownID }
            guard let newest = own.map(\.expiration).max(), newest > Date() else {
                throw Failure(message: "手機上沒有還有效的新描述檔，不清除。")
            }
            let doomed = own.filter { $0.expiration <= Date() && $0.expiration < newest && $0.uuid != current.uuid }
            for profile in doomed { try withTunnelRetry { try JITEnableContext.shared.removeProfile(withUUID: profile.uuid) } }
            return doomed.count
        }.value
    }

    // MARK: - Helpers

    /// Newest of the bundled profile's expiry and the one we installed ourselves (the bundled file never changes).
    static func effectiveExpiration(embedded: Date) -> Date {
        let stored = UserDefaults.standard.double(forKey: renewedExpiryKey)
        return stored > 0 ? max(embedded, Date(timeIntervalSince1970: stored)) : embedded
    }

    /// Runs a blocking misagent call; on a stale-tunnel error restarts the tunnel and retries once.
    /// Errors are turned into Chinese so raw English never reaches the screen.
    private static func withTunnelRetry<T>(_ call: () throws -> T) throws -> T {
        do {
            return try call()
        } catch {
            guard isTunnelError(error) else { throw Failure(message: "手機回報錯誤：\(error.localizedDescription)") }
            do {
                try JITEnableContext.shared.startTunnel()
                return try call()
            } catch {
                throw Failure(message: needTunnelMessage)
            }
        }
    }

    private static func isTunnelError(_ error: Error) -> Bool {
        let ns = error as NSError
        let text = "\(error.localizedDescription) \(ns)"
        return ns.code == -19 || text.contains("DeviceEndpointNotInitialized") || text.contains("Tunnel is not connected")
    }

    @MainActor
    private static func requireTunnel() async throws {
        let tunnel = TunnelManager.shared
        if !tunnel.isConnected {
            guard GpsSimEngine.pairingExists else { throw Failure(message: "還沒有配對檔。") }
            startTunnelInBackground(showErrorUI: false)
            for _ in 0..<40 where !tunnel.isConnected { try? await Task.sleep(nanoseconds: 250_000_000) }
        }
        guard tunnel.isConnected else { throw Failure(message: needTunnelMessage) }
    }

    /// Reads a picked file while its security-scoped access is open and returns a copy of the bytes.
    static func readPicked(_ url: URL) throws -> Data {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxFileBytes else { throw Failure(message: "這不是描述檔（檔案太大）。") }
        return try Data(contentsOf: url)
    }

    static func expiryText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.dateFormat = "M/d HH:mm"
        return f.string(from: date)
    }
}

struct ImportProfileIntent: AppIntent {
    static var title: LocalizedStringResource = "匯入描述檔"
    static var description = IntentDescription("把新的描述檔（.mobileprovision）裝到手機，不用重裝定位儀。需要 Wi-Fi 且 LocalDevVPN 已連線；檢查有任何一項不過就什麼都不做。")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "描述檔", supportedContentTypes: [.data])
    var file: IntentFile

    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            let expiry = try await GpsProfileRenew.install(file.data)
            return .result(dialog: "已換新描述檔，簽名到 \(GpsProfileRenew.expiryText(expiry))")
        } catch {
            return .result(dialog: "沒有換：\(error.localizedDescription)")
        }
    }
}
