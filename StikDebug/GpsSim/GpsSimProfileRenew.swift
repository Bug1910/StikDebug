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
    private static let renewedForUUIDKey = "gpssim.renewedForEmbeddedUUID"
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
        guard new.expiration > current.expiration else {
            throw Failure(message: "這個描述檔不比目前的新，沒有必要換。")
        }
        guard !new.certs.isDisjoint(with: current.certs) else {
            throw Failure(message: "描述檔的簽名憑證和目前的不同，換了會打不開，已拒絕。")
        }
        // The app cannot read its own UDID, so the current profile's device list stands in for it.
        guard current.devices.isEmpty || current.devices.isSubset(of: new.devices) else {
            throw Failure(message: "這份描述檔沒有包含這支手機，已拒絕。")
        }
        // Same keys AND same values (application-identifier, team, keychain groups, get-task-allow...).
        guard NSDictionary(dictionary: new.entitlements).isEqual(to: current.entitlements) else {
            throw Failure(message: "描述檔的權限內容和目前的不一樣（多了、少了或不同），已拒絕。")
        }
        return new
    }

    // MARK: - Install

    /// Install after validating; returns the newest expiry of this app's profiles read back from the phone.
    static func install(_ data: Data) async throws -> Date {
        let parsed = try validate(data)
        try await requireTunnel()
        return try await Task.detached(priority: .userInitiated) { () throws -> Date in
            // "Newer" is judged against what is really on the phone, not a remembered date.
            let before = try ownProfiles(appID: parsed.appID).map(\.expiration).max() ?? .distantPast
            guard parsed.expiration > before else {
                throw Failure(message: "手機上已經有同樣新或更新的描述檔，沒有必要換。")
            }
            try withTunnelRetry { try JITEnableContext.shared.addProfile(data) }
            // Read back instead of trusting the install call.
            guard let newest = try ownProfiles(appID: parsed.appID).map(\.expiration).max(), newest >= parsed.expiration else {
                throw Failure(message: "裝完後在手機上沒讀到新的描述檔，請再試一次。")
            }
            remember(newest)
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
            let own = try ownProfiles(appID: ownID)
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
    /// The remembered date only counts while the bundled profile is the same one it was read against.
    static func effectiveExpiration(embedded: Date) -> Date {
        let stored = UserDefaults.standard.double(forKey: renewedExpiryKey)
        guard stored > 0, UserDefaults.standard.string(forKey: renewedForUUIDKey) == Self.embedded()?.uuid else {
            return embedded
        }
        return max(embedded, Date(timeIntervalSince1970: stored))
    }

    private static func remember(_ date: Date) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: renewedExpiryKey)
        UserDefaults.standard.set(embedded()?.uuid, forKey: renewedForUUIDKey)
    }

    private static func ownProfiles(appID: String) throws -> [Parsed] {
        try withTunnelRetry { try JITEnableContext.shared.fetchAllProfiles() }
            .compactMap { try? parse($0) }
            .filter { $0.appID == appID }
    }

    /// Re-reads the phone (only if the tunnel is already up) so the shown date is verified, not remembered.
    @MainActor
    static func refreshFromPhone() async {
        guard TunnelManager.shared.isConnected, let current = embedded(), let bundleID = Bundle.main.bundleIdentifier else { return }
        let ownID = "\(current.team).\(bundleID)"
        let newest = await Task.detached(priority: .utility) { () -> Date? in
            try? ownProfiles(appID: ownID).map(\.expiration).max()
        }.value
        if let newest { remember(newest) }
    }

    /// Runs a blocking misagent call. Tunnel errors become the Wi-Fi/LocalDevVPN message; others keep their cause.
    private static func withTunnelRetry<T>(_ call: () throws -> T) throws -> T {
        do {
            return try call()
        } catch {
            // No startTunnel() here: it frees handles other threads may hold. The user reconnects instead.
            if isTunnelError(error) { throw Failure(message: needTunnelMessage) }
            throw Failure(message: "手機回報錯誤：\(error.localizedDescription)")
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

    @Parameter(title: "描述檔")
    var file: IntentFile

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Throws on any failure so the Shortcut stops instead of carrying on as if it had worked.
        let expiry = try await GpsProfileRenew.install(file.data)
        return .result(dialog: "已換新描述檔，簽名到 \(GpsProfileRenew.expiryText(expiry))")
    }
}
