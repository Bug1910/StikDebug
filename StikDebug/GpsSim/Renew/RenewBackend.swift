//
//  RenewBackend.swift
//  StikDebug (GpsSim fork) - experimental renew copy
//
//  The part that really talks to Apple through SideSign (GPL-3.0):
//  sign in (Apple ID + password -> 2FA) and renew (team -> this app's App ID -> download the team
//  provisioning profile -> same certificate serials as the installed app -> GpsProfileRenew install).
//  Safety rules: never creates App IDs, never registers devices, never revokes certificates.
//  Nothing here logs the Apple ID, password, token or anisette headers.
//

import Foundation
import Security
import SideSign

// MARK: - Shared types (no SideSign types leak to the UI)

struct RenewTwoFactorPrompt: Equatable, Sendable {
    enum Channel: String, Sendable { case trustedDevice, sms, voice }
    let channel: Channel
    /// Masked number as Apple sends it ("••••••12"), only for SMS / voice.
    let maskedPhone: String?
    /// Set when the previous code was wrong.
    let errorMessage: String?
}

enum RenewTwoFactorAnswer: Sendable {
    case code(String)
    case cancel
}

typealias RenewCodeProvider = @Sendable (RenewTwoFactorPrompt) async throws -> RenewTwoFactorAnswer

struct RenewOutcome: Equatable, Sendable {
    /// Newest expiry of this app's profile read back from the phone (nil when the read-back failed).
    let expiry: Date?
    let message: String
    /// The phone already had an equally new or newer profile: nothing was installed (not a renewal).
    var alreadyUpToDate = false
    /// Download step only: a new profile now waits in RenewPendingProfile (nothing installed yet);
    /// `expiry` is then the WAITING profile's expiry, not what the app runs on.
    var pendingOnly = false
    /// Download step only: the waiting profile was already there, so Apple was not contacted.
    var reusedPending = false
    /// Install step only: nothing (usable) was waiting, so nothing was done. A success, never an error:
    /// the install action also sits in the owner's everyday 出門改定位 Shortcut, where usually nothing waits.
    var nothingToInstall = false
    /// With nothingToInstall: the waiting profile failed the checks and was deleted (the app's 「裝上」 says so).
    var droppedUnusable = false
    /// With nothingToInstall: skipped because a sign-in / 2FA screen was open.
    var skippedBusy = false
}

/// Renewing is two halves (see RenewPendingProfile): download (internet, no tunnel) and install
/// (tunnel, no internet). On 4G the phone cannot do both at once, so a Shortcut runs them separately
/// with a cellular toggle in between; on Wi-Fi `renew` does both in one go.
protocol RenewBackend: Sendable {
    var keychainService: String { get }
    func signIn(appleID: String, password: String, codeProvider: @escaping RenewCodeProvider) async throws -> RenewStoredSession
    /// One shot: a fresh waiting profile is installed first (no Apple, `session` may be nil); otherwise
    /// download, then install. Without a tunnel the downloaded profile is kept and
    /// RenewProblem(.pendingNeedsTunnel) is thrown. `quick` = no retries (Shortcut time budget).
    func renew(session: RenewStoredSession?, quick: Bool) async throws -> RenewOutcome
    /// Step 1 (下載PinFly描述檔): never needs the tunnel. Success = pendingOnly or alreadyUpToDate.
    func download(session: RenewStoredSession, quick: Bool) async throws -> RenewOutcome
    /// Step 2 (安裝PinFly描述檔): never contacts Apple or anisette.
    func installPending() async throws -> RenewOutcome
    /// Expiry of the profile waiting to be installed, nil when nothing waits.
    func pendingProfileExpiry() -> Date?
}

// MARK: - One-shot renew (live and mock share the order)

enum RenewOneShot {
    /// Errors after which a kept profile is still worth installing: no internet / server trouble.
    static let offlineKinds: [RenewProblem.Kind] = [.network, .anisetteTimeout, .anisetteUnavailable, .serviceUnavailable503]

    /// 1. Any waiting profile first (fresh or not; install checks it is newer than the phone), no Apple.
    /// 2. Otherwise / dropped: download (needs a session), then install.
    /// No tunnel for a FRESH waiting profile = stop there (downloading again would not help); a stale one
    /// is refreshed first while there may be internet. A download that fails offline falls back to the
    /// kept profile (which then reports "downloaded, not installed yet" if the tunnel is still missing).
    static func run(session: RenewStoredSession?, pending: RenewPendingProfile.Pending?,
                    install: () async throws -> RenewOutcome,
                    download: (RenewStoredSession) async throws -> RenewOutcome) async throws -> RenewOutcome {
        if let pending {
            do {
                let first = try await install()
                if first.alreadyUpToDate || !first.nothingToInstall { return first }
                // Dropped as unusable: fetch a new one below.
            } catch let problem as RenewProblem where problem.kind == .pendingNeedsTunnel {
                guard session != nil, !RenewPendingProfile.isFresh(pending) else { throw problem }
                RenewDiagLog.write("renew: no tunnel and the pending one is stale; refreshing it first")
            }
        }
        guard let session else { throw RenewProblem(.notSignedIn) }
        let downloaded: RenewOutcome
        do {
            downloaded = try await download(session)
        } catch {
            guard pending != nil, offlineKinds.contains(RenewErrorClassifier.explain(error).kind) else { throw error }
            RenewDiagLog.write("renew: download failed offline; falling back to the kept pending")
            let fallback = try await install()
            if fallback.alreadyUpToDate || !fallback.nothingToInstall { return fallback }
            throw error
        }
        if downloaded.alreadyUpToDate { return downloaded }
        let installed = try await install()
        // Just downloaded and checked, so "nothing usable" here is a real problem, not a no-op.
        if installed.nothingToInstall { throw RenewProblem(.install, detail: installed.message) }
        return installed
    }
}

// MARK: - Live backend

struct LiveRenewBackend: RenewBackend {
    static let xcodeVersion = "26.0 (26A242)"   // SideStore's default (AnisetteConfigManager.resolvedXcodeVersion)

    var keychainService: String { RenewKeychain.liveService }

    /// Default headers only; there is no way to change them from the app (B4).
    private var portal: DeveloperPortal { DeveloperPortal(customHeaders: SideSignHeaders()) }

    init() {
        // Verbose SideSign logging prints the Apple ID, M1 and tokens: keep it off.
        SideSignLogging.setLogging(false)
    }

    // All entry points run with SideSign's console output muted in Release (see RenewQuietOutput).
    func signIn(appleID: String, password: String, codeProvider: @escaping RenewCodeProvider) async throws -> RenewStoredSession {
        try await RenewQuietOutput.run {
            try await signInUnmuted(appleID: appleID, password: password, codeProvider: codeProvider)
        }
    }

    func renew(session stored: RenewStoredSession?, quick: Bool) async throws -> RenewOutcome {
        try await RenewQuietOutput.run { () async throws -> RenewOutcome in
            try await RenewOneShot.run(session: stored, pending: RenewPendingProfile.load(mock: false),
                                       install: { try await installPendingUnmuted() },
                                       download: { try await downloadUnmuted(session: $0, quick: quick) })
        }
    }

    func download(session stored: RenewStoredSession, quick: Bool) async throws -> RenewOutcome {
        try await RenewQuietOutput.run { try await downloadUnmuted(session: stored, quick: quick) }
    }

    func installPending() async throws -> RenewOutcome {
        try await RenewQuietOutput.run { try await installPendingUnmuted() }
    }

    func pendingProfileExpiry() -> Date? { RenewPendingProfile.expiry(mock: false) }

    private func signInUnmuted(appleID: String, password: String, codeProvider: @escaping RenewCodeProvider) async throws -> RenewStoredSession {
        let anisette = try await RenewAnisette.fetch()
        let verification: DeveloperPortal.VerificationHandler = { request in
            try await Self.answer(request, codeProvider: codeProvider)
        }
        let auth = try await portal.authenticate(
            appleID: appleID,
            password: password,
            anisetteData: anisette,
            xcodeVersion: Self.xcodeVersion,
            machinePassword: nil,
            accountRepairHandler: { _, _ in .cancel },   // never act on an account-repair page silently
            verificationHandler: verification
        )
        // Diagnostics: does the token work right now with the same session, as SideStore checks?
        // Only the result is recorded; a failure here does not fail the sign-in.
        let signInHash = RenewAnisette.machineIDHash(auth.session.anisetteData)
        let (path, server) = RenewDiagLog.lastPath()
        do {
            let teams = try await portal.fetchTeams(for: auth.account, session: auth.session)
            RenewDiagLog.write("signIn ok; fetchTeams ok (\(teams.count) teams); anisetteHash=\(signInHash.prefix(8)); path=\(path); server=\(server)")
        } catch {
            RenewDiagLog.write("signIn ok; fetchTeams FAILED \(RenewDiagLog.describe(error)); anisetteHash=\(signInHash.prefix(8)); path=\(path); server=\(server)")
        }
        return RenewStoredSession(
            appleID: auth.account.appleID.isEmpty ? appleID : auth.account.appleID,
            dsid: auth.session.dsid,
            authToken: auth.session.authToken,
            tokenExpiry: auth.session.expirationDate,
            xcodeVersion: Self.xcodeVersion,
            signedInAt: Date(),
            anisetteHash: signInHash,
            anisetteServer: RenewAnisette.primaryHost
        )
    }

    /// Maps SideSign's 2FA requests to our prompt. Delivery is chosen automatically:
    /// trusted device when Apple prefers it (or no phone is listed), otherwise SMS to the first number.
    private static func answer(_ request: TwoFactorRequest, codeProvider: RenewCodeProvider) async throws -> TwoFactorResponse {
        let prompt: RenewTwoFactorPrompt
        switch request {
        case .selectDeliveryMethod(let preferred, let phones):
            if preferred == .trustedDevice || phones.isEmpty { return .requestTrustedDevice }
            return .requestSMS(phoneID: phones[0].id)
        case .trustedDevice(let error):
            prompt = RenewTwoFactorPrompt(channel: .trustedDevice, maskedPhone: nil, errorMessage: error.map { _ in "驗證碼不對，請再輸入一次。" })
        case .sms(let phones, let activeID, let error):
            prompt = RenewTwoFactorPrompt(channel: .sms, maskedPhone: phones.first(where: { $0.id == activeID })?.number,
                                          errorMessage: error.map { _ in "驗證碼不對，請再輸入一次。" })
        case .voice(let phones, let activeID, let error):
            prompt = RenewTwoFactorPrompt(channel: .voice, maskedPhone: phones.first(where: { $0.id == activeID })?.number,
                                          errorMessage: error.map { _ in "驗證碼不對，請再輸入一次。" })
        }
        switch try await codeProvider(prompt) {
        case .code(let code): return .verificationCode(code)
        case .cancel: return .cancel
        }
    }

    // MARK: Step 1 - download (internet, no tunnel)

    private func downloadUnmuted(session stored: RenewStoredSession, quick: Bool) async throws -> RenewOutcome {
        do {
            return try await downloadBody(session: stored, quick: quick)
        } catch {
            // Without this line a failure before the first traced step (retries) left no trace at all.
            RenewDiagLog.write("download FAILED \(RenewDiagLog.describe(error))")
            throw error
        }
    }

    private func downloadBody(session stored: RenewStoredSession, quick: Bool) async throws -> RenewOutcome {
        guard let bundleID = Bundle.main.bundleIdentifier, let embedded = GpsProfileRenew.embedded() else {
            throw RenewProblem(.install, detail: "讀不到這個 App 目前的簽名（模擬器沒有）。")
        }
        RenewDiagLog.write("download start\(quick ? " (no retries)" : "")")
        // A profile downloaded earlier and still fresh (≤24 h old, ≥6 days left): keep it instead of asking
        // Apple again (every Apple call spends sign-in / rate-limit budget). Rechecked, since the phone may
        // have been renewed another way (PC, SideStore) in the meantime. A stale one that is still newer
        // than the phone is NOT deleted before asking Apple: if the download fails it is still installable;
        // a successful save simply replaces it.
        if let pending = RenewPendingProfile.load(mock: false) {
            do {
                try Self.requireSameCertificates(newProfile: pending.profile)
                if RenewPendingProfile.isFresh(pending) {
                    RenewDiagLog.write("pending reused (expiry \(GpsProfileRenew.expiryText(pending.expiry))); Apple not contacted")
                    return RenewOutcome(expiry: pending.expiry,
                                        message: "新描述檔已下載（簽名可到 \(GpsProfileRenew.expiryText(pending.expiry))），等安裝。",
                                        pendingOnly: true, reusedPending: true)
                }
                RenewDiagLog.write("pending stale; asking Apple, old one kept until a new one is saved")
            } catch let problem as RenewProblem where problem.kind == .profileNotNewer {
                // The phone already has this one or newer: nothing to fetch either, so Apple is not asked.
                RenewDiagLog.write("pending dropped: phone already as new; Apple not contacted")
                RenewPendingProfile.delete(mock: false)
                return RenewOutcome(expiry: GpsProfileRenew.effectiveExpiration(embedded: embedded.expiration),
                                    message: "手機上已有同樣新或更新的描述檔，不用續簽。", alreadyUpToDate: true)
            } catch {
                RenewDiagLog.write("pending dropped \(RenewDiagLog.describe(error))")
                RenewPendingProfile.delete(mock: false)
            }
        }
        // A session made under another anisette server's identity would get Apple's 1100: drop it and the
        // old device identity (adi.pb, id), and make the user sign in again on the current server.
        guard stored.anisetteServer == RenewAnisette.primaryHost else {
            RenewDiagLog.write("renew: session server=\(stored.anisetteServer ?? "-") differs from current primary=\(RenewAnisette.primaryHost); identity cleared, sign-in required")
            RenewAnisette.resetAll()
            throw RenewProblem(.notSignedIn)
        }
        RenewDiagLog.write("renew: session server=\(RenewAnisette.primaryHost)")
        // No tunnel check here any more: on 4G the tunnel only works with cellular data OFF, and then
        // Apple cannot be reached (renew-diag 10/27). The install step checks the tunnel itself.
        let profileData = try await RenewRetry.run(retries: !quick) { () async throws -> Data in
            RenewDiagLog.write("anisette start")
            let anisette: AnisetteData
            do {
                anisette = try await RenewAnisette.fetch()
                RenewDiagLog.write("anisette ok")
            } catch {
                RenewDiagLog.write("anisette FAILED \(RenewDiagLog.describe(error))")
                throw error
            }
            let session = SideSign.Session(dsid: stored.dsid, authToken: stored.authToken,
                                  anisetteData: anisette, xcodeVersion: stored.xcodeVersion)
            let account = SideSign.Account(appleID: stored.appleID, identifier: stored.dsid)
            let nowHash = RenewAnisette.machineIDHash(anisette)
            let (path, server) = RenewDiagLog.lastPath()
            let sameIdentity = stored.anisetteHash.map { $0 == nowHash ? "same" : "DIFFERENT" } ?? "unknown"
            let context = "sessionHash=\((stored.anisetteHash ?? "-").prefix(8)); nowHash=\(nowHash.prefix(8)); machineID \(sameIdentity); path=\(path); server=\(server)"
            let teams = try await RenewDiagLog.trace("renew fetchTeams", context: context) {
                try await portal.fetchTeams(for: account, session: session)
            }
            // Only the team that signed the installed app; never fall back to another team.
            guard let team = teams.first(where: { $0.identifier == embedded.team }) else {
                throw RenewProblem(.teamMismatch)
            }
            let appIDs = try await portal.fetchAppIDs(for: team, session: session)
            guard let appID = appIDs.first(where: { $0.bundleIdentifier == bundleID }) else {
                throw RenewProblem(.appIDMissing)   // never create one
            }
            let profile = try await portal.downloadProvisioningProfile(
                for: appID, isTeamProfile: true, subPlatform: nil, deviceType: .iPhone, team: team, session: session)
            return profile.data
        }
        do {
            try Self.requireSameCertificates(newProfile: profileData)
        } catch let problem as RenewProblem where problem.kind == .profileNotNewer {
            // Not a failure: report "no renewal needed" with the date the phone already has.
            RenewDiagLog.write("download ok; phone already up to date, nothing saved")
            RenewPendingProfile.delete(mock: false)   // a kept stale one is older still: useless now
            return RenewOutcome(expiry: GpsProfileRenew.effectiveExpiration(embedded: embedded.expiration),
                                message: "手機上已有同樣新或更新的描述檔，不用續簽。", alreadyUpToDate: true)
        }
        // requireSameCertificates just parsed it, so this cannot fail; kept as try for the type.
        let expiry = try GpsProfileRenew.parse(profileData).expiration
        RenewDiagLog.write("download ok")
        try RenewPendingProfile.save(profileData, expiry: expiry, mock: false)
        return RenewOutcome(expiry: expiry,
                            message: "新描述檔已下載（簽名可到 \(GpsProfileRenew.expiryText(expiry))），等安裝。",
                            pendingOnly: true)
    }

    // MARK: Step 2 - install the waiting profile (tunnel, no internet)

    private func installPendingUnmuted() async throws -> RenewOutcome {
        do {
            return try await installPendingBody()
        } catch {
            RenewDiagLog.write("install FAILED \(RenewDiagLog.describe(error))")
            throw error
        }
    }

    private func installPendingBody() async throws -> RenewOutcome {
        RenewDiagLog.write("install start")
        // Nothing waiting = the normal case in the everyday 出門改定位 Shortcut: a quick no-op, never an
        // error (it must not stop that Shortcut). A failed download is reported by the download step itself.
        guard let pending = RenewPendingProfile.load(mock: false) else {
            RenewDiagLog.write("install: nothing pending, nothing to do")
            return RenewOutcome(expiry: nil, message: "沒有等著安裝的描述檔，不用裝。", nothingToInstall: true)
        }
        // Recheck before touching the phone: it may have been renewed another way since the download
        // (no longer newer), or the profile cannot be used (other certificate / entitlements). Either way
        // retrying would never help: drop it and finish as a no-op; the next download fetches a fresh one.
        do {
            try Self.requireSameCertificates(newProfile: pending.profile)
            _ = try GpsProfileRenew.validate(pending.profile)
        } catch {
            RenewDiagLog.write("install: pending not usable \(RenewDiagLog.describe(error)); dropped")
            RenewPendingProfile.delete(mock: false)
            let notNewer = (error as? RenewProblem)?.kind == .profileNotNewer
            // alreadyUpToDate too when not newer, so a one-shot renew stops there instead of asking Apple.
            return RenewOutcome(expiry: nil,
                                message: notNewer ? "手機上已有同樣新或更新的描述檔，不用安裝。" : "下載的描述檔不能用，已丟掉，不用安裝。",
                                alreadyUpToDate: notNewer, nothingToInstall: true, droppedUnusable: !notNewer)
        }
        RenewDiagLog.write("tunnel check start")
        do {
            try await GpsProfileRenew.requireTunnel()
            RenewDiagLog.write("tunnel ok")
        } catch {
            RenewDiagLog.write("tunnel FAILED \(RenewDiagLog.describe(error))")
            throw RenewProblem(.pendingNeedsTunnel)   // the profile stays saved for the next try
        }
        let outcome: GpsProfileRenew.InstallOutcome
        do {
            // Every other check (team, app id, newer, devices, entitlements) + misagent install + read-back.
            outcome = try await GpsProfileRenew.install(pending.profile)
        } catch {
            let tunnelKinds: [RenewProblem.Kind] = [.needTunnel, .tunnelRwAfc, .deviceEndpointNil]
            if tunnelKinds.contains(RenewErrorClassifier.explain(error).kind) {
                RenewDiagLog.write("install: tunnel dropped \(RenewDiagLog.describe(error))")
                throw RenewProblem(.pendingNeedsTunnel)
            }
            throw error   // pending kept: a phone-side hiccup is worth another try without re-downloading
        }
        RenewDiagLog.write(outcome.alreadyUpToDate
                           ? "install ok; phone already had an equal or newer profile"
                           : "install ok (expiry \(outcome.expiry.map(GpsProfileRenew.expiryText) ?? "read-back failed"))")
        RenewPendingProfile.delete(mock: false)
        return RenewOutcome(expiry: outcome.expiry, message: outcome.message, alreadyUpToDate: outcome.alreadyUpToDate)
    }

    /// Every certificate serial in the installed app's embedded profile must be in the new profile,
    /// and the new profile must expire later than what the app runs on now (embedded or our verified install).
    static func requireSameCertificates(newProfile: Data) throws {
        guard let embedded = GpsProfileRenew.embedded() else { throw RenewProblem(.certMismatch) }
        let new: GpsProfileRenew.Parsed
        do { new = try GpsProfileRenew.parse(newProfile) } catch { throw RenewProblem(.install, detail: "下載的描述檔讀不出來。") }
        let current = serials(embedded.certs)
        let incoming = serials(new.certs)
        guard !current.isEmpty, current.isSubset(of: incoming) else { throw RenewProblem(.certMismatch) }
        guard new.expiration > GpsProfileRenew.effectiveExpiration(embedded: embedded.expiration) else {
            throw RenewProblem(.profileNotNewer)
        }
    }

    static func serials(_ certs: Set<Data>) -> Set<Data> {
        Set(certs.compactMap { der -> Data? in
            guard let cert = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
            return SecCertificateCopySerialNumberData(cert, nil) as Data?
        })
    }
}

// MARK: - Mock backend (simulator / CI)

/// GPSSIM_RENEW_MOCK=1 (or launch argument `-GPSSIM_RENEW_MOCK 1`). Scenario comes from the env value
/// (`mismatch` / `network` / `notunnel`) or from the Apple ID typed in (contains "mismatch" / "network").
/// Download keeps a fake pending profile (separate file from the live one); install deletes it.
/// Password "wrong" -> wrong password; 2FA code "123456" -> accepted, anything else -> "wrong code".
struct MockRenewBackend: RenewBackend {
    enum Scenario: String, Sendable { case success, mismatch, network, notunnel }

    var keychainService: String { RenewKeychain.mockService }

    static var isEnabled: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment["GPSSIM_RENEW_MOCK"] ?? ""
        if !env.isEmpty && env != "0" { return true }
        return UserDefaults.standard.bool(forKey: "GPSSIM_RENEW_MOCK")
        #else
        return false   // a Release build can never be switched to the fake backend
        #endif
    }

    static func scenario(appleID: String) -> Scenario {
        let env = (ProcessInfo.processInfo.environment["GPSSIM_RENEW_MOCK"] ?? "").lowercased()
        if let s = Scenario(rawValue: env) { return s }
        let id = appleID.lowercased()
        if id.contains("mismatch") { return .mismatch }
        if id.contains("network") { return .network }
        return .success
    }

    func signIn(appleID: String, password: String, codeProvider: @escaping RenewCodeProvider) async throws -> RenewStoredSession {
        try await Task.sleep(nanoseconds: 600_000_000)
        if password == "wrong" { throw RenewProblem(.wrongPassword) }
        var error: String?
        while true {
            switch try await codeProvider(RenewTwoFactorPrompt(channel: .trustedDevice, maskedPhone: nil, errorMessage: error)) {
            case .cancel:
                throw RenewProblem(.cancelled)
            case .code(let code) where code == "123456":
                return RenewStoredSession(appleID: appleID, dsid: "mock-dsid", authToken: "mock-token",
                                          tokenExpiry: Date().addingTimeInterval(30 * 86_400),
                                          xcodeVersion: LiveRenewBackend.xcodeVersion, signedInAt: Date())
            case .code:
                error = "驗證碼不對，請再輸入一次。"
            }
        }
    }

    /// No LocalDevVPN in the simulator: `GPSSIM_RENEW_MOCK=notunnel` (or launch argument
    /// `-GPSSIM_RENEW_MOCK_NOTUNNEL 1`) makes the install step fail like 4G with cellular data on.
    static var tunnelMissing: Bool {
        let env = (ProcessInfo.processInfo.environment["GPSSIM_RENEW_MOCK"] ?? "").lowercased()
        return env == "notunnel" || UserDefaults.standard.bool(forKey: "GPSSIM_RENEW_MOCK_NOTUNNEL")
    }

    func renew(session: RenewStoredSession?, quick: Bool) async throws -> RenewOutcome {
        try await RenewOneShot.run(session: session, pending: RenewPendingProfile.load(mock: true),
                                   install: { try await installPending() },
                                   download: { try await download(session: $0, quick: quick) })
    }

    func download(session: RenewStoredSession, quick: Bool) async throws -> RenewOutcome {
        RenewDiagLog.write("download start (mock)\(quick ? " (no retries)" : "")")
        // Like the live one: a stale pending is kept until the new one is saved over it.
        if let pending = RenewPendingProfile.load(mock: true), RenewPendingProfile.isFresh(pending) {
            RenewDiagLog.write("pending reused (expiry \(GpsProfileRenew.expiryText(pending.expiry))); Apple not contacted (mock)")
            return RenewOutcome(expiry: pending.expiry,
                                message: "新描述檔已下載（簽名可到 \(GpsProfileRenew.expiryText(pending.expiry))），等安裝。（模擬）",
                                pendingOnly: true, reusedPending: true)
        }
        try await Task.sleep(nanoseconds: 600_000_000)
        switch Self.scenario(appleID: session.appleID) {
        case .success, .notunnel:
            let expiry = Date().addingTimeInterval(7 * 86_400)
            RenewDiagLog.write("download ok (mock)")
            try RenewPendingProfile.save(Data("mock-profile".utf8), expiry: expiry, mock: true)
            return RenewOutcome(expiry: expiry,
                                message: "新描述檔已下載（簽名可到 \(GpsProfileRenew.expiryText(expiry))），等安裝。（模擬）",
                                pendingOnly: true)
        case .mismatch:
            RenewDiagLog.write("download FAILED certMismatch (mock)")
            throw RenewProblem(.certMismatch)
        case .network:
            RenewDiagLog.write("download FAILED network (mock)")
            throw RenewProblem(.network)
        }
    }

    func installPending() async throws -> RenewOutcome {
        RenewDiagLog.write("install start (mock)")
        guard let pending = RenewPendingProfile.load(mock: true) else {
            RenewDiagLog.write("install: nothing pending, nothing to do (mock)")
            return RenewOutcome(expiry: nil, message: "沒有等著安裝的描述檔，不用裝。（模擬）", nothingToInstall: true)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        guard !Self.tunnelMissing else {
            RenewDiagLog.write("tunnel FAILED (mock)")
            throw RenewProblem(.pendingNeedsTunnel)
        }
        RenewDiagLog.write("tunnel ok (mock)")
        RenewDiagLog.write("install ok (expiry \(GpsProfileRenew.expiryText(pending.expiry))) (mock)")
        RenewPendingProfile.delete(mock: true)
        return RenewOutcome(expiry: pending.expiry, message: "已換新描述檔，簽名到 \(GpsProfileRenew.expiryText(pending.expiry))（模擬）")
    }

    func pendingProfileExpiry() -> Date? { RenewPendingProfile.expiry(mock: true) }
}
