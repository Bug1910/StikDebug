//
//  RenewService.swift
//  StikDebug (GpsSim fork) - experimental renew copy
//
//  The one entry point the renew screen and App Intents use:
//    signIn(appleID:password:)  -> .needs2FA(prompt) or .signedIn
//    submit2FA(code:)           -> .needs2FA(prompt with error) or .signedIn
//    cancelSignIn() / signOut()
//    renewNow()                 -> RenewOutcome (throws RenewProblem)
//    status()                   -> RenewStatus
//  The password is only held inside the running sign-in call; it is never stored or logged.
//  GPSSIM_RENEW_MOCK=1 swaps in MockRenewBackend (separate Keychain service) for the simulator.
//

import Combine
import Foundation

enum RenewSignInStep: Equatable, Sendable {
    case needs2FA(RenewTwoFactorPrompt)
    case signedIn(maskedAppleID: String)
}

struct RenewStatus: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case signingIn
        case waitingForCode(RenewTwoFactorPrompt)
        case renewing
    }

    var phase: Phase
    var isSignedIn: Bool
    var maskedAppleID: String?
    var sessionExpiry: Date?
    var sessionExpired: Bool
    /// This app's signing expiry (embedded profile, or a newer one we installed and verified).
    var profileExpiry: Date?
    var lastRenewAt: Date?
    var lastProblem: RenewProblem?
    var isMock: Bool
}

@MainActor
final class RenewService: ObservableObject {
    static let shared = RenewService()

    @Published private(set) var current: RenewStatus

    private let backend: RenewBackend
    private var flow: RenewSignInFlow?
    private var flowTask: Task<Void, Never>?
    /// The renewal in flight, if any. A second caller (Shortcut vs. screen) awaits this same Task.
    private var renewTask: Task<RenewOutcome, Error>?
    /// Unique id of the latest renewal run (stays after it ends); lets callers that joined the same run record it once.
    private(set) var renewRunID: UUID?
    var hasOpenSignIn: Bool { flow != nil }
    private var mockProfileExpiry: Date?

    private static let lastRenewKey = "gpssim.renew.lastRenewAt"

    private init(backend: RenewBackend? = nil) {
        let chosen = backend ?? (MockRenewBackend.isEnabled ? MockRenewBackend() : LiveRenewBackend())
        self.backend = chosen
        self.current = RenewStatus(phase: .idle, isSignedIn: false, maskedAppleID: nil, sessionExpiry: nil,
                                   sessionExpired: false, profileExpiry: nil, lastRenewAt: nil, lastProblem: nil,
                                   isMock: chosen is MockRenewBackend)
        refreshStatus()
    }

    // MARK: - Sign in

    func signIn(appleID: String, password: String) async throws -> RenewSignInStep {
        guard flow == nil else { throw RenewProblem(.signInInProgress) }
        let trimmed = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !password.isEmpty else { throw RenewProblem(.wrongPassword) }

        let flow = RenewSignInFlow()
        self.flow = flow
        current.phase = .signingIn
        current.lastProblem = nil
        let backend = self.backend
        flowTask = Task.detached(priority: .userInitiated) {
            do {
                let session = try await backend.signIn(appleID: trimmed, password: password,
                                                       codeProvider: { prompt in try await flow.requestCode(prompt) })
                flow.post(.finished(.success(session)))
            } catch {
                flow.post(.finished(.failure(error)))
            }
        }
        return try await handle(await waitForEvent(flow), from: flow)
    }

    func submit2FA(code: String) async throws -> RenewSignInStep {
        guard let flow else { throw RenewProblem(.twoFactorFailed) }
        let digits = code.filter(\.isNumber)
        guard flow.provide(.code(digits)) else { throw RenewProblem(.twoFactorFailed) }
        current.phase = .signingIn
        return try await handle(await waitForEvent(flow), from: flow)
    }

    /// If the caller's task is cancelled (screen closed, Shortcut stopped), the sign-in is cancelled too
    /// instead of leaving a 2FA callback waiting forever.
    private func waitForEvent(_ flow: RenewSignInFlow) async -> RenewSignInFlow.Event {
        await withTaskCancellationHandler {
            await flow.nextEvent()
        } onCancel: {
            flow.cancel()   // the backend then finishes with "cancelled", which resumes nextEvent()
            Task { @MainActor [weak self] in
                if self?.flow === flow { self?.cancelSignIn() }
            }
        }
    }

    func cancelSignIn() {
        flow?.cancel()
        flowTask?.cancel()
        flow = nil
        flowTask = nil
        // Only undo a sign-in phase; a renewal that is running keeps its own phase.
        switch current.phase {
        case .signingIn, .waitingForCode: current.phase = .idle
        case .idle, .renewing: break
        }
    }

    func signOut() {
        cancelSignIn()
        RenewKeychain.deleteSession(service: backend.keychainService)
        if backend is LiveRenewBackend { RenewAnisette.clearCaches() }
        mockProfileExpiry = nil
        refreshStatus()
    }

    /// 設定頁「重設驗證資料」: sign out AND forget the anisette identity (adi.pb, device id, machine ID
    /// hash), so a new machine ID is never paired with an old token. Next renew needs a fresh sign-in + 2FA.
    func resetVerificationData() {
        signOut()
        if backend is LiveRenewBackend { RenewAnisette.resetAll() }
        current.lastProblem = nil
        refreshStatus()
    }

    private func handle(_ event: RenewSignInFlow.Event, from eventFlow: RenewSignInFlow) async throws -> RenewSignInStep {
        // An older flow that finishes late must not touch the newer one (or save its session).
        guard flow === eventFlow else { throw RenewProblem(.cancelled) }
        switch event {
        case .needCode(let prompt):
            current.phase = .waitingForCode(prompt)
            return .needs2FA(prompt)
        case .finished(.success(let session)):
            do {
                try RenewKeychain.saveSession(session, service: backend.keychainService)
            } catch {
                NSLog("[RenewService] saveSession failed: %@", String(describing: error))
                // OSStatus such as -34018 (errSecMissingEntitlement) = signed in fine, but the Keychain refused the write.
                let problem = RenewProblem(.keychain, detail: error.localizedDescription)
                endFlow(problem: problem)
                throw problem
            }
            endFlow(problem: nil)
            return .signedIn(maskedAppleID: session.maskedAppleID)
        case .finished(.failure(let error)):
            let problem = RenewErrorClassifier.explain(error)
            endFlow(problem: problem)
            throw problem
        }
    }

    private func endFlow(problem: RenewProblem?) {
        flow = nil
        flowTask = nil
        current.phase = .idle
        current.lastProblem = problem
        refreshStatus()
    }

    // MARK: - Renew

    @discardableResult
    func renewNow() async throws -> RenewOutcome {
        // Join a renewal that is already running instead of failing: the screen and a Shortcut
        // then both get the real result. The Task is not tied to the caller, so closing a screen or
        // a Shortcut timing out does not abort a half-done install.
        if let running = renewTask { return try await running.value }
        let task = Task { try await self.runRenew() }
        renewTask = task
        renewRunID = UUID()
        defer { renewTask = nil }
        return try await task.value
    }

    private func runRenew() async throws -> RenewOutcome {
        // Not while renewing or while a sign-in / 2FA is open (that phase must not be overwritten).
        guard current.phase == .idle else { throw RenewProblem(.signInInProgress) }
        guard let session = RenewKeychain.loadSession(service: backend.keychainService) else {
            current.lastProblem = RenewProblem(.notSignedIn)
            throw RenewProblem(.notSignedIn)
        }
        guard !session.isExpired else {
            current.lastProblem = RenewProblem(.sessionExpired)
            throw RenewProblem(.sessionExpired)
        }
        current.phase = .renewing
        current.lastProblem = nil
        defer { if current.phase == .renewing { current.phase = .idle } }
        let backend = self.backend
        do {
            let outcome = try await Task.detached(priority: .userInitiated) {
                try await backend.renew(session: session)
            }.value
            if !outcome.alreadyUpToDate {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastRenewKey)
            }
            if backend is MockRenewBackend { mockProfileExpiry = outcome.expiry }
            refreshStatus()
            return outcome
        } catch {
            let problem = RenewErrorClassifier.explain(error)
            current.lastProblem = problem
            refreshStatus()
            throw problem
        }
    }

    // MARK: - Status

    func status() async -> RenewStatus {
        refreshStatus()
        return current
    }

    func refreshStatus() {
        let session = RenewKeychain.loadSession(service: backend.keychainService)
        current.isSignedIn = session != nil
        current.maskedAppleID = session?.maskedAppleID
        current.sessionExpiry = session?.tokenExpiry
        current.sessionExpired = session?.isExpired ?? false
        if backend is MockRenewBackend {
            current.profileExpiry = mockProfileExpiry
        } else if let embedded = GpsProfileRenew.embedded() {
            current.profileExpiry = GpsProfileRenew.effectiveExpiration(embedded: embedded.expiration)
        } else {
            current.profileExpiry = nil
        }
        let last = UserDefaults.standard.double(forKey: Self.lastRenewKey)
        current.lastRenewAt = last > 0 ? Date(timeIntervalSince1970: last) : nil
    }
}

// MARK: - 2FA bridge

/// Turns SideSign's single "authenticate with a code callback" call into two steps
/// (signIn returns when a code is needed, submit2FA hands the code in). Lock-based, no actor hops.
final class RenewSignInFlow: @unchecked Sendable {
    enum Event {
        case needCode(RenewTwoFactorPrompt)
        case finished(Result<RenewStoredSession, Error>)
    }

    private let lock = NSLock()
    private var events: [Event] = []
    private var eventWaiter: CheckedContinuation<Event, Never>?
    private var codeWaiter: CheckedContinuation<RenewTwoFactorAnswer, Error>?
    private var cancelled = false

    /// Called from the backend's 2FA callback: publishes the prompt and waits for submit2FA / cancel.
    func requestCode(_ prompt: RenewTwoFactorPrompt) async throws -> RenewTwoFactorAnswer {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RenewTwoFactorAnswer, Error>) in
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(returning: .cancel)
                return
            }
            codeWaiter = continuation
            lock.unlock()
            post(.needCode(prompt))
        }
    }

    /// Hands a code (or cancel) to the waiting callback. False when nobody is waiting.
    func provide(_ answer: RenewTwoFactorAnswer) -> Bool {
        lock.lock()
        let waiter = codeWaiter
        codeWaiter = nil
        lock.unlock()
        guard let waiter else { return false }
        waiter.resume(returning: answer)
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let waiter = codeWaiter
        codeWaiter = nil
        lock.unlock()
        waiter?.resume(returning: .cancel)
    }

    func post(_ event: Event) {
        lock.lock()
        if let waiter = eventWaiter {
            eventWaiter = nil
            lock.unlock()
            waiter.resume(returning: event)
        } else {
            events.append(event)
            lock.unlock()
        }
    }

    func nextEvent() async -> Event {
        await withCheckedContinuation { (continuation: CheckedContinuation<Event, Never>) in
            lock.lock()
            if !events.isEmpty {
                let event = events.removeFirst()
                lock.unlock()
                continuation.resume(returning: event)
            } else {
                eventWaiter = continuation
                lock.unlock()
            }
        }
    }
}
