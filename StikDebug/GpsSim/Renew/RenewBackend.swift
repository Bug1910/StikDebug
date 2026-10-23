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
}

protocol RenewBackend: Sendable {
    var keychainService: String { get }
    func signIn(appleID: String, password: String, codeProvider: @escaping RenewCodeProvider) async throws -> RenewStoredSession
    func renew(session: RenewStoredSession) async throws -> RenewOutcome
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

    // Both entry points run with SideSign's console output muted in Release (see RenewQuietOutput).
    func signIn(appleID: String, password: String, codeProvider: @escaping RenewCodeProvider) async throws -> RenewStoredSession {
        try await RenewQuietOutput.run {
            try await signInUnmuted(appleID: appleID, password: password, codeProvider: codeProvider)
        }
    }

    func renew(session stored: RenewStoredSession) async throws -> RenewOutcome {
        try await RenewQuietOutput.run { try await renewUnmuted(session: stored) }
    }

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
            RenewDiagLog.write("signIn ok; fetchTeams ok (\(teams.count) teams); anisetteHash=\(signInHash); path=\(path); server=\(server)")
        } catch {
            RenewDiagLog.write("signIn ok; fetchTeams FAILED \(RenewDiagLog.describe(error)); anisetteHash=\(signInHash); path=\(path); server=\(server)")
        }
        return RenewStoredSession(
            appleID: auth.account.appleID.isEmpty ? appleID : auth.account.appleID,
            dsid: auth.session.dsid,
            authToken: auth.session.authToken,
            tokenExpiry: auth.session.expirationDate,
            xcodeVersion: Self.xcodeVersion,
            signedInAt: Date(),
            anisetteHash: signInHash
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

    private func renewUnmuted(session stored: RenewStoredSession) async throws -> RenewOutcome {
        guard let bundleID = Bundle.main.bundleIdentifier, let embedded = GpsProfileRenew.embedded() else {
            throw RenewProblem(.install, detail: "讀不到這個 App 目前的簽名（模擬器沒有）。")
        }
        // Tunnel first: with no Wi-Fi + LocalDevVPN the profile could not be installed anyway,
        // so Apple is not contacted at all (saves sign-in attempts against rate limits).
        try await GpsProfileRenew.requireTunnel()
        let profileData = try await RenewRetry.run { () async throws -> Data in
            let anisette = try await RenewAnisette.fetch()
            let session = SideSign.Session(dsid: stored.dsid, authToken: stored.authToken,
                                  anisetteData: anisette, xcodeVersion: stored.xcodeVersion)
            let account = SideSign.Account(appleID: stored.appleID, identifier: stored.dsid)
            let nowHash = RenewAnisette.machineIDHash(anisette)
            let (path, server) = RenewDiagLog.lastPath()
            let sameIdentity = stored.anisetteHash.map { $0 == nowHash ? "same" : "DIFFERENT" } ?? "unknown"
            let context = "sessionHash=\(stored.anisetteHash ?? "-"); nowHash=\(nowHash); machineID \(sameIdentity); path=\(path); server=\(server)"
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
            return RenewOutcome(expiry: GpsProfileRenew.effectiveExpiration(embedded: embedded.expiration),
                                message: "手機上已有同樣新或更新的描述檔，不用續簽。", alreadyUpToDate: true)
        }
        // Every other check (team, app id, newer, devices, entitlements) + misagent install + read-back.
        let outcome = try await GpsProfileRenew.install(profileData)
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
/// (`mismatch` / `network`) or from the Apple ID typed in (contains "mismatch" / "network").
/// Password "wrong" -> wrong password; 2FA code "123456" -> accepted, anything else -> "wrong code".
struct MockRenewBackend: RenewBackend {
    enum Scenario: String, Sendable { case success, mismatch, network }

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

    func renew(session: RenewStoredSession) async throws -> RenewOutcome {
        try await Task.sleep(nanoseconds: 900_000_000)
        switch Self.scenario(appleID: session.appleID) {
        case .success:
            let expiry = Date().addingTimeInterval(7 * 86_400)
            return RenewOutcome(expiry: expiry, message: "已換新描述檔，簽名到 \(GpsProfileRenew.expiryText(expiry))（模擬）")
        case .mismatch:
            throw RenewProblem(.certMismatch)
        case .network:
            throw RenewProblem(.network)
        }
    }
}
