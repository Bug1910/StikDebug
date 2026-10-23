//
//  GpsSimRenewCenter.swift
//  StikDebug (GpsSim fork)
//
//  The "renew the 7-day signature on the phone" front desk. The screens (settings 簽名 section,
//  home reminder card, sign-in sheet) only talk to `GpsRenewCenter`; the center talks to whatever
//  implements `RenewServicing`. Today that is a fake (screenshots) or a placeholder that says the
//  build cannot renew yet; the real RenewService (Apple login + anisette + misagent) plugs in at
//  `GpsRenewCenter.makeService()` without touching any screen.
//  Also here: the local reminder notifications (48 / 24 / 3 hours before expiry, no network).
//

import Combine
import Foundation
import SwiftUI
import UserNotifications

// MARK: - Interface for the real renew backend

/// The four steps of one renewal, in the order they happen (shown numbered on screen).
enum RenewStep: Int, CaseIterable, Comparable {
    case anisette = 1
    case signIn = 2
    case fetchProfile = 3
    case install = 4

    var title: String {
        switch self {
        case .anisette: return "連到驗證伺服器"
        case .signIn: return "登入 Apple"
        case .fetchProfile: return "取得新的 7 天簽名"
        case .install: return "裝到這支手機"
        }
    }

    static func < (a: RenewStep, b: RenewStep) -> Bool { a.rawValue < b.rawValue }
}

enum RenewSignInResult {
    case signedIn
    /// Apple sent a 6-digit code; call `submit2FA`.
    case needsCode
}

/// Every way a renewal or sign-in can fail. The backend maps its own errors onto these;
/// the screens turn each one into a plain reason plus the right next button (spec 1.8).
enum RenewFailure: Error, Equatable {
    /// Anisette server too slow (>16 s or timed out). `seconds` = how long we waited.
    /// `seconds` nil = the engine did not report how long it waited.
    case anisetteTimeout(seconds: Int?)
    /// Apple 1100 (session expired). Usually a slow anisette server, not a real expiry.
    case sessionExpired
    /// Apple refused the login for now (-80045, 503 and the like).
    case loginBlocked
    case wrongPassword
    /// The 6-digit code was wrong or expired.
    case wrongCode
    case noNetwork
    /// New profile fetched but could not be put on the phone (tunnel / LocalDevVPN down).
    /// The backend keeps the profile; the next `renewNow` starts at step 4.
    case installUnreachable
    /// Free Apple ID: 10 App IDs per 7 days used up. `availableAgain` when known.
    case appIDLimit(availableAgain: Date?)
    case deviceNotRegistered
    /// Backend error code as text (the renew core reports string codes).
    case other(code: String)
    /// No saved Apple account (renewNow called before signIn).
    case notSignedIn
    /// This build has no renew backend yet.
    case unavailable
    /// Anisette server answered with an error instead of data (not just slow).
    case anisetteUnavailable
    /// Apple wants an app-specific password for this account.
    case appSpecificPassword
    /// A sign-in is already open.
    case signInBusy
    /// Signed in with an Apple ID that did not sign this app.
    case accountMismatch
    /// The new profile cannot be used safely (missing App ID or different certificate): the PC must renew.
    case needsComputer(code: String)
    /// The phone already holds an equally new or newer profile: nothing to do, not a failure.
    case notNeeded
    /// Signed in, but the Keychain refused to save the login (e.g. -34018, missing entitlement).
    case keychain
}

struct RenewServiceStatus: Equatable {
    var signedIn: Bool
    /// Full Apple ID (screens mask it); also pre-fills the sign-in form.
    var appleID: String?
    /// Already-masked form ("ab•••@gmail.com") for engines that never expose the full ID.
    var maskedAppleID: String? = nil
    var lastSuccess: Date?
    /// Step 4 failed earlier and the fetched profile is still waiting to be installed.
    var pendingInstall = false
}

/// One anisette ("驗證伺服器") choice for the advanced page.
struct RenewAnisetteServer: Identifiable, Equatable {
    let id: String
    let name: String
    let host: String
    var isDefault = false
}

/// What the real RenewService implements. All calls may run off the main actor; the center hops
/// back itself. Cancellation: `renewNow` should check `Task.isCancelled` between steps 1-3.
/// After a successful `renewNow` the new profile must already be installed and remembered through
/// `GpsProfileRenew` (so `GpsSigning.expiration` reads the new date).
protocol RenewServicing: AnyObject {
    /// Sign-in step 2/3. `progress` reports .anisette then .signIn.
    func signIn(appleID: String, password: String,
                progress: @escaping (RenewStep) -> Void) async throws -> RenewSignInResult
    /// Sign-in step 3/3 (6-digit code).
    func submit2FA(code: String) async throws
    /// Full renewal; reports each step as it starts; returns the new expiry date (nil = installed but the date could not be read back).
    /// Throws RenewFailure.notNeeded when the phone already has an equally new profile.
    func renewNow(progress: @escaping (RenewStep) -> Void) async throws -> Date?
    func status() async -> RenewServiceStatus

    // Optional (defaults below).
    func signOut() async
    /// Clears the anisette provisioning data (adi.pb); a new sign-in is needed afterwards.
    func resetAuthData() async
    func anisetteServers() async -> [RenewAnisetteServer]
    func selectedAnisetteServerID() async -> String?
    func selectAnisetteServer(id: String) async
    /// Seconds per server id; nil value = no answer.
    func measureAnisette() async -> [String: Double?]
}

extension RenewServicing {
    func signOut() async {}
    func resetAuthData() async {}
    func anisetteServers() async -> [RenewAnisetteServer] { [RenewAnisetteServer.sideStoreNew] }
    func selectedAnisetteServerID() async -> String? { RenewAnisetteServer.sideStoreNew.id }
    func selectAnisetteServer(id: String) async {}
    func measureAnisette() async -> [String: Double?] { [:] }
}

extension RenewAnisetteServer {
    /// 10/18 the only server that could sign in; 10/22 fast (<4 s) answers succeeded 7 of 8 times.
    static let sideStoreNew = RenewAnisetteServer(id: "sidestore-new", name: "SideStore (New)",
                                                  host: "new.ani.sidestore.io", isDefault: true)
}

// MARK: - Shared wording

enum GpsRenewCopy {
    /// One place to switch the app name used in renewal wording (the app is being renamed).
    static let appName = "PinFly"
    /// The PC desktop shortcut that renews over USB.
    static let pcRenewName = "定位儀續簽"

    static func dateTime(_ d: Date) -> String { format(d, "M/d HH:mm") }
    static func time(_ d: Date) -> String { format(d, "HH:mm") }
    static func day(_ d: Date) -> String { format(d, "M/d") }

    private static func format(_ d: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.dateFormat = pattern
        return f.string(from: d)
    }

    /// 「lol•••@gmail.com」: first 3 characters, dots, domain (safe in screenshots).
    static func masked(_ appleID: String) -> String {
        let parts = appleID.split(separator: "@", maxSplits: 1).map(String.init)
        // An empty string splits into no parts: indexing parts[0] trapped (crashed the account page).
        guard let first = parts.first else { return "•••" }
        let head = String(first.prefix(3)) + "•••"
        return parts.count == 2 ? head + "@" + parts[1] : head
    }

    /// 「簽名到 10/29 17:46 前照常能用。」 (every failure says it, to take the fright out).
    static func stillWorks(_ expiry: Date?) -> String {
        guard let expiry else { return "" }
        return "簽名到 \(dateTime(expiry)) 前照常能用。"
    }
}

/// A next-step button under a failure.
enum RenewAction: Equatable {
    case retry, signInAgain, reenterCode, install, acknowledge, changeServer, signInAndRenew
    var title: String {
        switch self {
        case .retry: return "再試一次"
        case .signInAgain: return "重新登入"
        case .reenterCode: return "重新輸入"
        case .install: return "裝上"
        case .acknowledge: return "知道了"
        case .changeServer: return "換伺服器"
        case .signInAndRenew: return "登入並續簽"
        }
    }
}

/// The words and buttons for one failure (spec 1.8). No apologies; reconnecting is never the first advice.
struct RenewFailureText {
    let title: String
    let detail: String
    /// 「錯誤代碼：N（給 Claude 看用）」, last line in small grey text.
    var codeLine: String?
    let primary: RenewAction
    var secondary: RenewAction?

    init(_ failure: RenewFailure, expiry: Date?, timeoutStreak: Int = 0, sessionStreak: Int = 0) {
        let keep = GpsRenewCopy.stillWorks(expiry)
        let app = GpsRenewCopy.appName
        switch failure {
        case .anisetteTimeout(let seconds):
            title = "驗證伺服器太慢"
            let server = "驗證伺服器（幫忙登入 Apple 的公開伺服器，不是 Apple 的）"
            let waited = seconds.map { "等了 \($0) 秒" } ?? "等太久"
            // No 「換伺服器」 for now: the build has exactly one server, so the button would do nothing.
            let text = "\(server)\(waited)沒有回應，這是伺服器端的問題，跟密碼無關。過 1～2 分鐘再按一次通常就會過。"
            detail = text + keep
            primary = .retry
        case .sessionExpired:
            title = "Apple 要求重新驗證"
            detail = "Apple 不接受這次登入，請按重新登入；仍失敗請回報。" + keep
            primary = .signInAgain
        case .loginBlocked:
            title = "Apple 暫時擋下登入"
            let until = expiry.map { "簽名到 \(GpsRenewCopy.dateTime($0)) 前\(app)照常能用；" } ?? ""
            detail = "不是密碼錯。連續重試可能被擋更久，請隔 1 小時再試。\(until)急的話可以接電腦按「\(GpsRenewCopy.pcRenewName)」。"
            primary = .acknowledge
        case .wrongPassword:
            title = "Apple ID 或密碼不對"
            detail = "請重新輸入。" + keep
            primary = .signInAgain
        case .wrongCode:
            title = "驗證碼不對或過期"
            detail = "請再輸入一次 Apple 傳來的 6 位數。" + keep
            primary = .reenterCode
        case .noNetwork:
            title = "沒有網路"
            detail = "續簽要連到 Apple。開行動數據或 Wi-Fi 後再按一次。" + keep
            primary = .retry
        case .installUnreachable:
            title = "新簽名拿到了，還沒裝上"
            detail = "要先連 LocalDevVPN。有 Wi-Fi：打開 LocalDevVPN 再按「裝上」；只有 4G：照「只有 4G 的 5 步」。新簽名已存在手機，不用重新登入。" + keep
            primary = .install
        case .appIDLimit(let again):
            title = "這週 Apple 帳號能簽的數量用完了"
            let back = again.map { "\(GpsRenewCopy.day($0)) 後恢復。" } ?? ""
            let now = expiry.map { "現在的簽名到 \(GpsRenewCopy.dateTime($0)) 前照常能用。" } ?? ""
            detail = "免費 Apple ID 每 7 天最多 10 個 App ID。\(back)\(now)"
            primary = .acknowledge
        case .deviceNotRegistered:
            title = "這支手機還沒登記到 Apple 帳號"
            detail = "請接電腦用 iloader 裝一次\(app)，手機就會登記。" + keep
            primary = .acknowledge
        case .other(let code):
            title = "沒續簽成功"
            detail = keep
            codeLine = "錯誤代碼：\(code)（給 Claude 看用）"
            primary = .retry
        case .notSignedIn:
            title = "還沒登入 Apple"
            detail = "登入一次之後，\(app)可以自己續簽。" + keep
            primary = .signInAndRenew
        case .anisetteUnavailable:
            title = "驗證伺服器回了錯誤"
            detail = "驗證伺服器（幫忙登入 Apple 的公開伺服器，不是 Apple 的）不是太慢，是回了無法使用的資料。過幾分鐘再按一次。" + keep
            primary = .retry
        case .appSpecificPassword:
            title = "這個帳號要用 App 專用密碼"
            detail = "到 appleid.apple.com 產生「App 專用密碼」，用它登入。" + keep
            primary = .signInAgain
        case .signInBusy:
            title = "登入還在進行中"
            detail = "先完成或取消目前的登入，再按一次。" + keep
            primary = .acknowledge
        case .accountMismatch:
            title = "這個 Apple ID 不是簽\(app)的帳號"
            detail = "請用當初裝\(app)時的 Apple ID 登入。什麼都沒有改動。" + keep
            primary = .signInAgain
        case .needsComputer(let code):
            title = "這支手機沒辦法自己續簽"
            detail = "為了不把\(app)弄壞，已停止，什麼都沒裝。請接電腦按「\(GpsRenewCopy.pcRenewName)」。" + keep
            codeLine = "錯誤代碼：\(code)（給 Claude 看用）"
            primary = .acknowledge
        case .keychain:
            title = "登入成功，但存不了登入資料"
            detail = "這支手機不讓\(app)把登入資料存進鑰匙圈（Keychain）。請重新安裝\(app)後再試。" + keep
            codeLine = "錯誤代碼：keychain（給 Claude 看用）"
            primary = .acknowledge
        case .notNeeded:
            title = "不用續簽"
            detail = "手機上的簽名已經是最新的。" + keep
            primary = .acknowledge
        case .unavailable:
            title = "這個版本還不能在手機上續簽"
            detail = "請打開 SideStore 按 Refresh All，或接電腦按「\(GpsRenewCopy.pcRenewName)」。" + keep
            primary = .acknowledge
        }
    }
}

/// One line of 續簽紀錄.
struct RenewRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    let at: Date
    let succeeded: Bool
    var expiry: Date?
    /// Failure title (spec 1.8), plus seconds for a slow server.
    var reason: String?
}

// MARK: - The center the screens observe

@MainActor
final class GpsRenewCenter: ObservableObject {
    static let shared = GpsRenewCenter()

    enum Phase: Equatable {
        case idle
        /// `durations`: seconds each finished step took (shown as 「2.8 秒」).
        case running(step: RenewStep, startedAt: Date, stepStartedAt: Date, durations: [RenewStep: Double])
        case failed(RenewFailure, at: Date)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = RenewServiceStatus(signedIn: false)
    @Published private(set) var history: [RenewRecord] = []
    /// Home shows this as a 3 s toast (「已續簽，簽名到 11/05 08:21」), then clears it.
    @Published var successToast: String?
    /// Bumped whenever the signature date may have changed, so views re-read GpsSigning.
    @Published private(set) var signTick = 0
    @Published private(set) var timeoutStreak = 0
    @Published private(set) var sessionStreak = 0

    /// Default on (Sideloadly also defaults to on). Runs only when the app comes to the front.
    @Published var autoRenew: Bool {
        didSet { UserDefaults.standard.set(autoRenew, forKey: Self.autoRenewKey) }
    }

    private(set) var service: RenewServicing
    private var task: Task<Void, Never>?
    /// Ignores a late answer from a renewal that was cancelled.
    private var attemptID = UUID()

    private static let historyKey = "gpssim.renewHistory"
    private static let snoozeKey = "gpssim.signSnoozeUntil"
    private static let lastAttemptKey = "gpssim.lastRenewAttempt"
    private static let pausedKey = "gpssim.autoRenewPausedUntil"
    private static let autoRenewKey = "gpssim.autoRenew"

    nonisolated static var isDemo: Bool { ProcessInfo.processInfo.arguments.contains("-GpsSimDemo") }

    /// True now: makeService() returns RenewServiceAdapter (the real engine). When false the home card
    /// keeps the 「打開 SideStore」 button (the screenshot demo always shows the new card).
    nonisolated static let hasRenewBackend = true
    nonisolated static var showsRenewButtons: Bool { hasRenewBackend || isDemo }

    /// The one line to change when the real RenewService lands.
    static func makeService() -> RenewServicing {
        isDemo ? GpsDemoRenewService() : RenewServiceAdapter.shared
    }

    /// True while `phase` mirrors a renewal that a Shortcut started (not this center's own task).
    private var mirroringExternal = false
    private var corePhaseWatch: AnyCancellable?
    /// Id of the last engine run this center wrote a 續簽紀錄 for (so a Shortcut waiting on the same run does not repeat it).
    private var recordedRunID: UUID?

    /// False once the sign-in was cancelled (e.g. sheet closed); then a code can no longer be entered.
    var signInFlowOpen: Bool { (service as? RenewServiceAdapter)?.hasOpenSignIn ?? true }

    private init() {
        service = Self.makeService()
        autoRenew = UserDefaults.standard.object(forKey: Self.autoRenewKey) as? Bool ?? true
        if Self.isDemo {
            history = GpsDemoRenewService.seedHistory
        } else if let data = UserDefaults.standard.data(forKey: Self.historyKey),
                  let saved = try? JSONDecoder().decode([RenewRecord].self, from: data) {
            history = saved
        }
        Task { await refreshStatus() }
        if service is RenewServiceAdapter {
            // A Shortcut renews through RenewService.shared without going through this center:
            // follow the engine's phase so the home card and settings show the same thing.
            corePhaseWatch = RenewService.shared.$current
                .map(\.phase)
                .removeDuplicates()
                .sink { [weak self] corePhase in
                    Task { @MainActor in self?.coreServicePhaseChanged(corePhase) }
                }
        }
    }

    private func coreServicePhaseChanged(_ corePhase: RenewStatus.Phase) {
        if corePhase == .renewing, case .idle = phase {
            mirroringExternal = true
            let now = Date()
            phase = .running(step: .anisette, startedAt: now, stepStartedAt: now, durations: [:])
        } else if corePhase != .renewing, mirroringExternal {
            mirroringExternal = false
            if case .running = phase { phase = .idle }
            signTick += 1
            Task { await refreshStatus() }
        }
    }

    /// A Shortcut action finished a renewal on its own (success, failure, or after its time limit).
    /// Writes the 續簽紀錄 and reminders the screens would have written. Skipped when this center's own
    /// task is waiting on the same renewal: that task records it.
    func externalRenewFinished(expiry: Date?, failure: Error?, alreadyUpToDate: Bool = false) {
        if isRunning, !mirroringExternal { return }
        mirroringExternal = false
        if case .running = phase { phase = .idle }
        signTick += 1
        if alreadyUpToDate { Task { await refreshStatus() }; return }
        // Each renewal Task has a unique id; the center's own task may have recorded this very run already.
        if let runID = RenewService.shared.renewRunID {
            if runID == recordedRunID { return }
            recordedRunID = runID
        }
        if let failure {
            let mapped = (RenewServiceAdapter.translate(failure) as? RenewFailure) ?? .other(code: "intent")
            if mapped != .notNeeded {
                record(RenewRecord(at: Date(), succeeded: false, reason: failureText(mapped).title))
            }
        } else {
            UserDefaults.standard.removeObject(forKey: Self.snoozeKey)
            record(RenewRecord(at: Date(), succeeded: true, expiry: expiry))
            GpsRenewReminders.clearDelivered()
            GpsRenewReminders.reschedule(expiry: expiry ?? GpsSigning.expiration)
        }
        Task { await refreshStatus() }
    }

    var isRunning: Bool { if case .running = phase { return true } else { return false } }
    var currentStep: RenewStep? { if case .running(let s, _, _, _) = phase { return s } else { return nil } }
    var failure: RenewFailure? { if case .failed(let f, _) = phase { return f } else { return nil } }
    var lastRecord: RenewRecord? { history.first }

    func failureText(_ f: RenewFailure) -> RenewFailureText {
        RenewFailureText(f, expiry: GpsSigning.expiration, timeoutStreak: timeoutStreak, sessionStreak: sessionStreak)
    }

    func refreshStatus() async {
        status = await service.status()
    }

    // MARK: Renew

    /// Returns false when nobody is signed in (the caller opens the sign-in sheet instead).
    @discardableResult
    func renewNow() -> Bool {
        guard !isRunning else { return true }
        guard status.signedIn else { return false }
        let id = UUID()
        attemptID = id
        let start = Date()
        UserDefaults.standard.set(start, forKey: Self.lastAttemptKey)
        let first: RenewStep = status.pendingInstall ? .install : .anisette
        phase = .running(step: first, startedAt: start, stepStartedAt: start, durations: [:])
        announceStep(first)
        // Ask iOS for extra time so a renewal that is half done when the app leaves the screen can
        // finish (otherwise the spinner would hang until the app is opened again). Same pattern as the Shortcut.
        let background = GpsRenewBackgroundTask()
        background.begin()
        task = Task { [weak self] in
            defer { background.end() }
            guard let self else { return }
            do {
                let expiry = try await self.service.renewNow { step in
                    Task { @MainActor in self.advance(to: step, attempt: id) }
                }
                guard self.attemptID == id else { return }
                self.finishSuccess(expiry, startedAt: start)
            } catch is CancellationError {
                // Only ours to undo if this attempt is still the current one (cancel() already reset otherwise).
                if self.attemptID == id { self.phase = .idle }
                return
            } catch RenewFailure.notNeeded {
                guard self.attemptID == id else { return }
                self.finishNotNeeded()
            } catch let f as RenewFailure {
                guard self.attemptID == id else { return }
                self.finishFailure(f, startedAt: start)
            } catch {
                guard self.attemptID == id else { return }
                self.finishFailure(.other(code: String((error as NSError).code)), startedAt: start)
            }
        }
        return true
    }

    /// Steps 1-3 only: nothing on the phone has changed yet. Step 4 (installing) cannot be stopped.
    /// The real engine reports no per-step progress and a half-cancelled install is worse than a finished one,
    /// so with it only the demo can be cancelled.
    var canCancel: Bool { !(service is RenewServiceAdapter) && (currentStep ?? .install) < .install }

    func cancel() {
        guard canCancel else { return }
        attemptID = UUID()
        task?.cancel()
        task = nil
        phase = .idle
        AccessibilityAnnouncer.announce("已取消續簽")
    }

    /// Closes the failure card (稍後 / 知道了) without changing anything else.
    func dismissFailure() {
        if case .failed = phase { phase = .idle }
    }

    private func advance(to step: RenewStep, attempt: UUID) {
        guard attempt == attemptID,
              case .running(let current, let start, let stepStart, var durations) = phase,
              step > current else { return }
        let now = Date()
        durations[current] = now.timeIntervalSince(stepStart)
        phase = .running(step: step, startedAt: start, stepStartedAt: now, durations: durations)
        announceStep(step)
    }

    private func announceStep(_ step: RenewStep) {
        AccessibilityAnnouncer.announce("第 \(step.rawValue) 步，\(step.title)")
    }

    /// The phone already had an equally new profile: say so, record nothing as renewed.
    private func finishNotNeeded() {
        phase = .idle
        timeoutStreak = 0
        sessionStreak = 0
        signTick += 1
        let text = "簽名已經是最新的，不用續簽"
        successToast = text
        AccessibilityAnnouncer.announce(text)
        Task { await refreshStatus() }
    }

    /// `expiry` nil = installed, but the date could not be read back (screens then say 「到期日讀取中」).
    private func finishSuccess(_ expiry: Date?, startedAt: Date) {
        if Self.isDemo, let expiry { GpsSigning.demoRenewedExpiry = expiry }
        phase = .idle
        timeoutStreak = 0
        sessionStreak = 0
        UserDefaults.standard.removeObject(forKey: Self.snoozeKey)
        record(RenewRecord(at: Date(), succeeded: true, expiry: expiry))
        signTick += 1
        let text = expiry.map { "已續簽，簽名到 \(GpsRenewCopy.dateTime($0))" } ?? "已續簽，到期日讀取中"
        successToast = text
        AccessibilityAnnouncer.announce(text)
        GpsRenewReminders.clearDelivered()
        GpsRenewReminders.reschedule(expiry: expiry ?? GpsSigning.expiration)
        Task { await refreshStatus() }
    }

    private func finishFailure(_ f: RenewFailure, startedAt: Date) {
        if case .anisetteTimeout = f { timeoutStreak += 1 } else { timeoutStreak = 0 }
        if f == .sessionExpired { sessionStreak += 1 } else { sessionStreak = 0 }
        if f == .loginBlocked {
            // Retrying while Apple blocks makes the block longer: no automatic tries for 6 hours.
            UserDefaults.standard.set(Date().addingTimeInterval(6 * 3_600), forKey: Self.pausedKey)
        }
        var reason = failureText(f).title
        if case .anisetteTimeout(let s?) = f { reason += "（\(s) 秒）" }
        record(RenewRecord(at: Date(), succeeded: false, reason: reason))
        phase = .failed(f, at: Date())
        let text = failureText(f)
        AccessibilityAnnouncer.announce("\(text.title)。\(text.detail)")
        Task { await refreshStatus() }
    }

    private func record(_ r: RenewRecord) {
        if service is RenewServiceAdapter, !mirroringExternal { recordedRunID = RenewService.shared.renewRunID ?? recordedRunID }
        history.insert(r, at: 0)
        history = Array(history.prefix(5))
        guard !Self.isDemo, let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: Self.historyKey)
    }

    // MARK: Automatic renewal (foreground only)

    /// Called when the app comes to the front. Renews once when 3 days or less are left, nothing
    /// was tried in the last 6 hours, and Apple is not blocking. No background schedule: the
    /// owner's network is a phone hotspot, so timed network jobs are unreliable.
    func appBecameActive(now: Date = Date()) {
        guard !Self.isDemo else { return }
        signTick += 1
        GpsRenewReminders.reschedule(expiry: GpsSigning.expiration)
        Task {
            await refreshStatus()
            guard autoRenew, status.signedIn, !isRunning,
                  let hours = GpsSigning.hoursLeft(now: now), hours <= 72 else { return }
            if let paused = UserDefaults.standard.object(forKey: Self.pausedKey) as? Date, paused > now { return }
            if let last = UserDefaults.standard.object(forKey: Self.lastAttemptKey) as? Date,
               now.timeIntervalSince(last) < 6 * 3_600 { return }
            renewNow()
        }
    }

    // MARK: Home reminder card

    /// 稍後 hides the card until the next threshold (1 day left, then 12 hours left).
    func snooze(now: Date = Date()) {
        dismissFailure()
        guard let expiry = GpsSigning.expiration else { return }
        let thresholds = [expiry.addingTimeInterval(-86_400), expiry.addingTimeInterval(-12 * 3_600)]
        guard let next = thresholds.first(where: { $0 > now }) else { return }
        UserDefaults.standard.set(next, forKey: Self.snoozeKey)
        signTick += 1
    }

    /// Running or failed always shows; otherwise from 2 days left, unless 稍後 is still in effect.
    func signCardVisible(now: Date) -> Bool {
        if isRunning || failure != nil { return true }
        guard GpsSigning.needsWarning(now: now) else { return false }
        if let until = UserDefaults.standard.object(forKey: Self.snoozeKey) as? Date, until > now,
           (GpsSigning.hoursLeft(now: now) ?? 0) >= 24 {
            return false
        }
        return true
    }

    // MARK: Account

    func signOut() async {
        guard !isRunning else { return }
        await service.signOut()
        await refreshStatus()
    }

    func resetAuthData() async {
        guard !isRunning else { return }
        await service.resetAuthData()
        await refreshStatus()
    }

    /// The sign-in sheet was dismissed before finishing: drop a half-open sign-in / 2FA wait.
    func signInSheetClosed() {
        (service as? RenewServiceAdapter)?.cancelSignIn()
    }

    func signInFinished() async {
        await refreshStatus()
    }

    func bumpSign() { signTick += 1 }

    /// Screenshot demo only: show a failure card without waiting for the fake steps.
    func applyDemoFailure(_ f: RenewFailure) {
        guard Self.isDemo else { return }
        finishFailure(f, startedAt: Date())
    }
}

/// Holds one UIKit background-task id. The expiration handler ends it synchronously (iOS kills the app
/// if it does not), so it must not hop to another task first.
@MainActor
final class GpsRenewBackgroundTask {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "GpsSimRenewButton") {
            MainActor.assumeIsolated { self.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

// MARK: - Placeholder backend (until the real RenewService is wired in)

/// Honest stand-in: nobody is signed in and every call says this build cannot renew on the phone,
/// so a real phone never pretends it renewed.
final class GpsUnavailableRenewService: RenewServicing {
    func signIn(appleID: String, password: String,
                progress: @escaping (RenewStep) -> Void) async throws -> RenewSignInResult {
        throw RenewFailure.unavailable
    }
    func submit2FA(code: String) async throws { throw RenewFailure.unavailable }
    func renewNow(progress: @escaping (RenewStep) -> Void) async throws -> Date? { throw RenewFailure.unavailable }
    func status() async -> RenewServiceStatus { RenewServiceStatus(signedIn: false) }
}

// MARK: - Fake backend for screenshots (-GpsSimDemo)

/// Walks the four steps with realistic pauses. `-GpsSimDemo signNotLoggedIn` starts signed out.
/// `-GpsSimRenewCycle` makes each 立即續簽 return the next failure of spec 1.8 in turn, then succeed.
final class GpsDemoRenewService: RenewServicing {
    private var signedIn = !ProcessInfo.processInfo.arguments.contains("signNotLoggedIn")
    private var cycleIndex = 0
    private let cycle = ProcessInfo.processInfo.arguments.contains("-GpsSimRenewCycle")
    static let cycleFailures: [RenewFailure] = [
        .anisetteTimeout(seconds: 17), .sessionExpired, .loginBlocked, .wrongPassword, .wrongCode,
        .noNetwork, .installUnreachable, .appIDLimit(availableAgain: Date().addingTimeInterval(3 * 86_400)),
        .deviceNotRegistered, .other(code: "1100"),
    ]
    static let demoAppleID = "pinfly.demo@icloud.com"

    static var seedHistory: [RenewRecord] {
        let now = Date()
        return [
            RenewRecord(at: now.addingTimeInterval(-5.5 * 86_400), succeeded: true,
                        expiry: now.addingTimeInterval(1.5 * 86_400)),
            RenewRecord(at: now.addingTimeInterval(-5.9 * 86_400), succeeded: false,
                        reason: "驗證伺服器太慢（16 秒）"),
        ]
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func signIn(appleID: String, password: String,
                progress: @escaping (RenewStep) -> Void) async throws -> RenewSignInResult {
        progress(.anisette)
        try await pause(1.5)
        progress(.signIn)
        try await pause(1.5)
        return .needsCode
    }

    func submit2FA(code: String) async throws {
        try await pause(1)
        guard code.count == 6 else { throw RenewFailure.wrongCode }
        signedIn = true
    }

    func renewNow(progress: @escaping (RenewStep) -> Void) async throws -> Date? {
        guard signedIn else { throw RenewFailure.notSignedIn }
        for (step, seconds) in [(RenewStep.anisette, 2.8), (RenewStep.signIn, 3.5), (RenewStep.fetchProfile, 2.5), (RenewStep.install, 2.0)] {
            progress(step)
            try await pause(seconds)
            if cycle, step == .fetchProfile, cycleIndex < Self.cycleFailures.count {
                cycleIndex += 1
                throw Self.cycleFailures[cycleIndex - 1]
            }
        }
        return Date().addingTimeInterval(7 * 86_400)
    }

    func status() async -> RenewServiceStatus {
        RenewServiceStatus(signedIn: signedIn, appleID: Self.demoAppleID,
                           lastSuccess: signedIn ? Date().addingTimeInterval(-5.5 * 86_400) : nil)
    }

    func signOut() async { signedIn = false }
    func measureAnisette() async -> [String: Double?] {
        try? await pause(1.2)
        return [RenewAnisetteServer.sideStoreNew.id: 3.2]
    }
}

// MARK: - Local reminders (no network needed; work while the app is closed)

enum GpsRenewReminders {
    static let ids = ["gpssim.sign.48h", "gpssim.sign.24h", "gpssim.sign.3h"]
    private static let hoursBefore: [Double] = [48, 24, 3]

    /// After a renewal the old 「剩 N 天」 reminders in Notification Center are wrong: remove them.
    static func clearDelivered() {
        guard !GpsRenewCenter.isDemo else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }

    /// Asked only after the first successful sign-in, after the in-app explanation line.
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func permissionUndetermined() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined
    }

    /// Replaces the three reminders for this expiry. Does nothing without permission.
    static func reschedule(expiry: Date?, now: Date = Date()) {
        guard !GpsRenewCenter.isDemo else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        guard let expiry else { return }
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            for (id, hours) in zip(ids, hoursBefore) {
                guard let fire = fireDate(expiry: expiry, hoursBefore: hours), fire > now else { continue }
                let content = UNMutableNotificationContent()
                content.title = "\(GpsRenewCopy.appName)簽名\(leftText(from: fire, to: expiry))"
                content.body = "到期後\(GpsRenewCopy.appName)會打不開。點這裡打開\(GpsRenewCopy.appName)，按「立即續簽」。"
                content.sound = .default
                // Seconds from now, not a wall-clock date: a calendar trigger would fire at the wrong
                // moment after the phone changes time zone (travel), while the expiry is an absolute time.
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fire.timeIntervalSince(now), repeats: false)
                center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            }
        }
    }

    /// `hoursBefore` the expiry, moved out of 22:00-08:00 (he does not deal with it at night):
    /// to 08:00, or to 21:30 the evening before when 08:00 would already be past the expiry.
    static func fireDate(expiry: Date, hoursBefore: Double, calendar: Calendar = .current) -> Date? {
        let raw = expiry.addingTimeInterval(-hoursBefore * 3_600)
        let hour = calendar.component(.hour, from: raw)
        guard hour >= 22 || hour < 8 else { return raw }
        let rawDay = calendar.startOfDay(for: raw)
        let morningDay = hour >= 22 ? calendar.date(byAdding: .day, value: 1, to: rawDay)! : rawDay
        if let morning = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: morningDay), morning < expiry {
            return morning
        }
        let eveningDay = hour >= 22 ? rawDay : calendar.date(byAdding: .day, value: -1, to: rawDay)!
        return calendar.date(bySettingHour: 21, minute: 30, second: 0, of: eveningDay)
    }

    /// 「剩 2 天」/「剩 1 天」/「剩 3 小時」, from the real time left at the (possibly moved) fire time.
    static func leftText(from fire: Date, to expiry: Date) -> String {
        let seconds = expiry.timeIntervalSince(fire)
        let days = Int((seconds / 86_400).rounded(.down))
        if days >= 1 { return "剩 \(days) 天" }
        let hours = Int((seconds / 3_600).rounded(.down))
        return hours >= 1 ? "剩 \(hours) 小時" : "剩不到 1 小時"
    }
}
