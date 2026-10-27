//
//  RenewServiceAdapter.swift
//  StikDebug (GpsSim fork) - experimental renew copy (PinFly)
//
//  The "interpreter" between the screens and the renew engine. The screens (GpsRenewCenter) speak
//  `RenewServicing` (RenewFailure, 4 steps, RenewServiceStatus); the engine (`RenewService`) speaks
//  RenewProblem / RenewSignInStep / RenewStatus. This file translates both ways and nothing else.
//  It wraps `RenewService.shared`, the same object the Shortcut actions use, so a renewal started
//  from a Shortcut and one started from the screen can never disagree about "is it busy / signed in".
//

import Foundation

@MainActor
final class RenewServiceAdapter: RenewServicing {
    static let shared = RenewServiceAdapter()

    private let core: RenewService

    private init(core: RenewService = .shared) {
        self.core = core
    }

    // MARK: Sign in

    func signIn(appleID: String, password: String,
                progress: @escaping (RenewStep) -> Void) async throws -> RenewSignInResult {
        // The engine gives no per-step events, so only the first step is reported honestly.
        progress(.anisette)
        do {
            switch try await core.signIn(appleID: appleID, password: password) {
            case .needs2FA: return .needsCode
            case .signedIn: return .signedIn
            }
        } catch {
            throw Self.translate(error)
        }
    }

    func submit2FA(code: String) async throws {
        do {
            switch try await core.submit2FA(code: code) {
            case .signedIn: return
            // The engine asks for the code again (with an error text) = the code was wrong.
            case .needs2FA: throw RenewFailure.wrongCode
            }
        } catch {
            throw Self.translate(error)
        }
    }

    var hasOpenSignIn: Bool { core.hasOpenSignIn }

    /// The sign-in sheet was closed halfway (e.g. while waiting for the 6-digit code).
    func cancelSignIn() {
        core.cancelSignIn()
    }

    // MARK: Renew

    func renewNow(progress: @escaping (RenewStep) -> Void) async throws -> Date? {
        // A downloaded profile still waiting (e.g. 4G earlier): the engine installs it without asking Apple again.
        progress(core.current.pendingExpiry != nil ? .install : .anisette)
        do {
            let outcome = try await core.renewNow()
            if outcome.alreadyUpToDate { throw RenewFailure.notNeeded }
            // nil = installed but the read-back failed: the screens say 「到期日讀取中」 instead of a guessed date.
            return outcome.expiry
        } catch {
            throw Self.translate(error)
        }
    }

    /// 「裝上」 / 「裝上新簽名」: install the waiting signature only (no Apple, no sign-in, no download),
    /// so it works in the state the screen asks for (cellular data off + LocalDevVPN, no internet).
    func installPending(progress: @escaping (RenewStep) -> Void) async throws -> Date? {
        progress(.install)
        do {
            let outcome = try await core.installPendingProfile()
            if outcome.alreadyUpToDate || outcome.nothingToInstall { throw RenewFailure.notNeeded }
            return outcome.expiry
        } catch {
            throw Self.translate(error)
        }
    }

    func status() async -> RenewServiceStatus {
        let status = await core.status()
        // The engine only keeps a masked Apple ID, so there is nothing to pre-fill the form with.
        return RenewServiceStatus(signedIn: status.isSignedIn, appleID: nil, maskedAppleID: status.maskedAppleID,
                                  lastSuccess: status.lastRenewAt, pendingInstall: status.pendingExpiry != nil)
    }

    // MARK: Account

    func signOut() async {
        core.signOut()
    }

    func resetAuthData() async {
        core.resetVerificationData()
    }

    // MARK: Error translation

    /// Engine errors -> what the screens know. CancellationError passes through untouched.
    nonisolated static func translate(_ error: Error) -> Error {
        if error is CancellationError || error is RenewFailure { return error }
        let problem = (error as? RenewProblem) ?? RenewErrorClassifier.explain(error)
        switch problem.kind {
        case .cancelled: return CancellationError()
        case .appleSession1100: return RenewFailure.sessionExpired
        case .sessionExpired, .notSignedIn: return RenewFailure.notSignedIn
        case .wrongPassword: return RenewFailure.wrongPassword
        case .appSpecificPassword: return RenewFailure.appSpecificPassword
        case .wrongCode, .twoFactorFailed: return RenewFailure.wrongCode
        case .tooManyAttempts, .appleRefused80045, .appleRefused80046, .serviceUnavailable503:
            return RenewFailure.loginBlocked
        case .anisetteTimeout: return RenewFailure.anisetteTimeout(seconds: nil)
        case .anisetteUnavailable: return RenewFailure.anisetteUnavailable
        case .network: return RenewFailure.noNetwork
        case .signInInProgress: return RenewFailure.signInBusy
        case .downloadInProgress: return RenewFailure.other(code: problem.kind.rawValue)   // Shortcut-only
        case .teamMismatch: return RenewFailure.accountMismatch
        case .appIDMissing, .certMismatch: return RenewFailure.needsComputer(code: problem.kind.rawValue)
        case .profileNotNewer: return RenewFailure.notNeeded
        case .tunnelRwAfc, .deviceEndpointNil, .needTunnel, .pendingNeedsTunnel: return RenewFailure.installUnreachable
        case .keychain: return RenewFailure.keychain
        case .install, .unknown:
            // Leave a trace so a CI log shows what the unmapped error really was (the screen only says the kind).
            NSLog("[RenewAdapter] unmapped %@ detail=%@ underlying=%@", problem.kind.rawValue, problem.detail ?? "-", String(describing: error))
            return RenewFailure.other(code: problem.code ?? problem.kind.rawValue)
        }
    }
}
