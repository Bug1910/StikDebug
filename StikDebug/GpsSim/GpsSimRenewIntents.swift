//
//  GpsSimRenewIntents.swift
//  StikDebug (GpsSim fork) - experimental renew copy
//
//  Shortcut actions for signing (spec part 2.3 #3, #4) and simulation status (#6).
//  All of them return PinFly狀態 (GpsSimIntentStatus.swift) so a Shortcut can branch on it.
//
//  Why 續簽PinFly runs in the background (openAppWhenRun = false) with its own deadline:
//   - The owner's automation fires when his weekday alarm is stopped, often with the phone locked.
//     openAppWhenRun = true would need an unlock to bring the app forward, so the step would fail there.
//   - ForegroundContinuableIntent.requestToContinueInForeground shows a "continue in app?" prompt that
//     someone has to tap; in a locked alarm automation nobody does, and when it is declined it throws,
//     which would stop the whole Shortcut (the spec wants failure NOT to stop it by default). Not used.
//   - A background intent is cut off by iOS after roughly 30 s (SideStore's Refresh intent hits this at
//     about 27 s, RefreshAllAppsIntent.swift:144). So the action waits at most `maxSeconds` (≤25 s) and
//     always answers before iOS would kill it: 結果＝失敗 with 「太慢」 instead of a silent cut-off.
//   - The renew itself runs inside this app (RenewService.renewNow, no SideStore), wrapped in a
//     UIApplication background task, so when the deadline passes the renew keeps going for the extra
//     background time iOS grants; a later 查簽名剩幾天 shows whether it landed.
//  Not verified on a device yet: how long a locked phone really lets this run.
//

import AppIntents
import Foundation
import UIKit

// MARK: - 兩個續簽動作
//
// 續簽PinFly (RenewNowIntent): always renews.
// 剩幾天內才續簽PinFly (RenewSigningIntent): renews only when N days or fewer are left. The type name
// RenewSigningIntent is unchanged on purpose: saved Shortcuts find actions by type name, so the
// owner's existing automations keep working (they now read as the 「剩幾天內才…」 action).

struct RenewSigningIntent: AppIntent {
    static var title: LocalizedStringResource = "剩幾天內才續簽PinFly"
    static var description = IntentDescription("剩下的天數小於等於設定值時才續簽，還夠用就什麼都不做，所以每天固定跑也沒關係。換新的 7 天簽名，不用接電腦。要先在PinFly › 設定 › 簽名登入 Apple 一次（捷徑裡不能登入，驗證碼要人輸入）。預設最多等 20 秒；失敗時預設不會讓捷徑停下來，請用「如果 結果 是 失敗」判斷。只有 4G 時，改用「下載PinFly描述檔」＋「安裝PinFly描述檔」兩步（中間關行動數據、開 LocalDevVPN）。")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "只在剩幾天內才續簽", default: 3, inclusiveRange: (1, 7))
    var withinDays: Int

    @Parameter(title: "失敗時停止捷徑", default: false)
    var stopOnFailure: Bool

    @Parameter(title: "最多等幾秒", default: 20, inclusiveRange: (10, 25))
    var maxSeconds: Int

    static var parameterSummary: some ParameterSummary {
        Summary("剩 \(\.$withinDays) 天內才續簽PinFly") {
            \.$stopOnFailure
            \.$maxSeconds
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<GpsSimStatusEntity> & ProvidesDialog {
        let answer = try await GpsRenewIntentRunner.run(withinDays: withinDays <= 0 ? nil : withinDays,  // old automations saved 0 = "always renew"
                                                        stopOnFailure: stopOnFailure,
                                                        maxSeconds: maxSeconds)
        return .result(value: answer.value, dialog: "\(answer.dialog)")
    }
}

struct RenewNowIntent: AppIntent {
    static var title: LocalizedStringResource = "續簽PinFly"
    static var description = IntentDescription("不管還剩幾天，馬上換新的 7 天簽名，不用接電腦。要先在PinFly › 設定 › 簽名登入 Apple 一次（捷徑裡不能登入，驗證碼要人輸入）。預設最多等 20 秒；失敗時預設不會讓捷徑停下來，請用「如果 結果 是 失敗」判斷。只有 4G 時，改用「下載PinFly描述檔」＋「安裝PinFly描述檔」兩步（中間關行動數據、開 LocalDevVPN）。")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "失敗時停止捷徑", default: false)
    var stopOnFailure: Bool

    @Parameter(title: "最多等幾秒", default: 20, inclusiveRange: (10, 25))
    var maxSeconds: Int

    static var parameterSummary: some ParameterSummary {
        Summary("續簽PinFly") {
            \.$stopOnFailure
            \.$maxSeconds
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<GpsSimStatusEntity> & ProvidesDialog {
        let answer = try await GpsRenewIntentRunner.run(withinDays: nil, stopOnFailure: stopOnFailure,
                                                        maxSeconds: maxSeconds)
        return .result(value: answer.value, dialog: "\(answer.dialog)")
    }
}

// MARK: - 4G 分兩步：下載 → (關行動數據、開 LocalDevVPN) → 安裝
//
// On 4G the LocalDevVPN tunnel only works with cellular data OFF, and then Apple cannot be reached
// (renew-diag 10/27: 續簽PinFly stopped at "tunnel FAILED" before contacting Apple). So an automation runs
// 下載PinFly描述檔 → TurnOffData → Enable LocalDevVPN → wait → 安裝PinFly描述檔 → TurnOnData.

struct DownloadProfileIntent: AppIntent {
    static var title: LocalizedStringResource = "下載PinFly描述檔"
    static var description = IntentDescription("描述檔＝PinFly 的 7 天簽名。續簽的上半段：向 Apple 下載新的 7 天描述檔，先存在PinFly裡，還不會裝上。要有網路（4G 可以），不用 LocalDevVPN。預設只在簽名剩 3 天內才下載；之前下載好還能用的也不再找 Apple。接著關掉行動數據、打開 LocalDevVPN，再跑「安裝PinFly描述檔」。要先在PinFly › 設定 › 簽名登入 Apple 一次。失敗時預設不會讓捷徑停下來。")
    static var openAppWhenRun: Bool = false

    /// On by default (3 days): a daily automation does not ask Apple while there is time left.
    /// A Bool + a defaulted Int (like 剩幾天內才續簽PinFly) instead of an optional Int: both always have a
    /// valid stored value, so an unattended automation is never prompted.
    @Parameter(title: "快到期才下載", default: true)
    var onlyWhenExpiring: Bool

    @Parameter(title: "剩幾天算快到期", default: 3, inclusiveRange: (1, 7))
    var withinDays: Int

    @Parameter(title: "失敗時停止捷徑", default: false)
    var stopOnFailure: Bool

    @Parameter(title: "最多等幾秒", default: 20, inclusiveRange: (10, 25))
    var maxSeconds: Int

    static var parameterSummary: some ParameterSummary {
        Summary("下載PinFly描述檔") {
            \.$onlyWhenExpiring
            \.$withinDays
            \.$stopOnFailure
            \.$maxSeconds
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<GpsSimStatusEntity> & ProvidesDialog {
        let days = min(max(withinDays, 1), 7)
        let answer = try await GpsRenewIntentRunner.download(withinDays: onlyWhenExpiring ? days : nil,
                                                             stopOnFailure: stopOnFailure, maxSeconds: maxSeconds)
        return .result(value: answer.value, dialog: "\(answer.dialog)")
    }
}

struct InstallProfileIntent: AppIntent {
    static var title: LocalizedStringResource = "安裝PinFly描述檔"
    static var description = IntentDescription("描述檔＝PinFly 的 7 天簽名。續簽的下半段：把「下載PinFly描述檔」存好的描述檔裝上。放在『開 LocalDevVPN → 等待 3 秒』之後。要 LocalDevVPN 已連線（只有 4G 時先關掉行動數據），不用網路、不找 Apple。沒有等著安裝的就馬上結束、不算失敗，所以放在每天的捷徑裡也沒關係。失敗時預設不會讓捷徑停下來。")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "失敗時停止捷徑", default: false)
    var stopOnFailure: Bool

    @Parameter(title: "最多等幾秒", default: 20, inclusiveRange: (10, 25))
    var maxSeconds: Int

    static var parameterSummary: some ParameterSummary {
        Summary("安裝PinFly描述檔") {
            \.$stopOnFailure
            \.$maxSeconds
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<GpsSimStatusEntity> & ProvidesDialog {
        let answer = try await GpsRenewIntentRunner.install(stopOnFailure: stopOnFailure, maxSeconds: maxSeconds)
        return .result(value: answer.value, dialog: "\(answer.dialog)")
    }
}

/// The bodies the renew actions share. `withinDays` nil = always renew.
@MainActor
enum GpsRenewIntentRunner {
    static func run(withinDays: Int?, stopOnFailure: Bool, maxSeconds: Int) async throws -> (value: GpsSimStatusEntity, dialog: String) {
        RenewDiagLog.write("intent start withinDays=\(withinDays.map(String.init) ?? "always") maxSeconds=\(maxSeconds) stopOnFailure=\(stopOnFailure)")
        await GpsProfileRenew.refreshFromPhone()
        let before = await RenewService.shared.status()
        let reason: String
        // A downloaded profile waiting to be installed needs no sign-in.
        if !before.isSignedIn, before.pendingExpiry == nil {
            reason = "還沒登入 Apple。請打開PinFly › 設定 › 簽名，登入一次。"
        } else {
            if let withinDays, let expiry = before.profileExpiry,
               expiry.timeIntervalSinceNow > Double(withinDays) * 86_400 {
                let value = await GpsSimIntentStatus.make(.notNeeded)
                return (value, "簽名還有 \(value.daysLeft ?? withinDays) 天，不用續簽")
            }
            switch await GpsRenewRace.run(seconds: min(max(maxSeconds, 10), 25)) {
            case .done(let outcome) where outcome.alreadyUpToDate:
                let value = await GpsSimIntentStatus.make(.notNeeded)
                return (value, "簽名已經是最新的，不用續簽")
            case .done(let outcome):
                let value = await GpsSimIntentStatus.make(.renewed, signingExpiry: outcome.expiry)
                let until = value.signingExpiry.map { "，簽名到 \(GpsProfileRenew.expiryText($0))" } ?? ""
                return (value, "已續簽\(until)")
            case .failed(let error):
                let problem = (error as? RenewProblem) ?? RenewErrorClassifier.explain(error)
                let code = problem.code.map { "（代碼 \($0)）" } ?? ""
                reason = "\(problem.title)。\(problem.advice)\(code)"
            case .timedOut(let seconds):
                RenewDiagLog.write("intent timeout \(seconds)s (renew keeps running in background)")
                reason = "驗證伺服器太慢（等了 \(seconds) 秒）。續簽還在背景繼續，過 1 分鐘再用「查簽名剩幾天」確認。"
            }
        }
        return try await failed(reason, stopOnFailure: stopOnFailure)
    }

    /// 下載PinFly描述檔. `withinDays` nil = always download. Needs internet, never the tunnel.
    static func download(withinDays: Int?, stopOnFailure: Bool, maxSeconds: Int) async throws -> (value: GpsSimStatusEntity, dialog: String) {
        RenewDiagLog.write("intent start step=download withinDays=\(withinDays.map(String.init) ?? "always") maxSeconds=\(maxSeconds) stopOnFailure=\(stopOnFailure)")
        await GpsProfileRenew.refreshFromPhone()
        let before = await RenewService.shared.status()
        // Local only (installed / verified profile expiry): Apple is not contacted when there is time left.
        if let withinDays, let expiry = before.profileExpiry,
           expiry.timeIntervalSinceNow > Double(withinDays) * 86_400 {
            let value = await GpsSimIntentStatus.make(.notNeeded)
            let left = value.daysLeft ?? withinDays
            RenewDiagLog.write("intent download skipped: \(left) days left > \(withinDays)")
            return (value, "簽名還剩 \(left) 天，不用下載")
        }
        let reason: String
        // Signed out but a profile already waits: RenewService reports it ready (fresh) or asks to sign in.
        if !before.isSignedIn, before.pendingExpiry == nil {
            reason = "還沒登入 Apple。請打開PinFly › 設定 › 簽名，登入一次。"
        } else {
            switch await GpsRenewRace.run(seconds: min(max(maxSeconds, 10), 25), operation: .download) {
            case .done(let outcome) where outcome.alreadyUpToDate:
                let value = await GpsSimIntentStatus.make(.notNeeded)
                return (value, "簽名已經是最新的，不用下載")
            case .done(let outcome):
                // 成功 (not 已續簽): nothing is installed yet. 簽名到期 stays the date the app runs on now.
                let value = await GpsSimIntentStatus.make(.succeeded)
                let until = outcome.expiry.map { "（可用到 \(GpsProfileRenew.expiryText($0))）" } ?? ""
                let what = outcome.reusedPending ? "新描述檔之前已下載好" : "新描述檔已下載"
                return (value, "\(what)\(until)。下一步：安裝PinFly描述檔")
            case .failed(let error):
                let problem = (error as? RenewProblem) ?? RenewErrorClassifier.explain(error)
                let code = problem.code.map { "（代碼 \($0)）" } ?? ""
                reason = "\(problem.title)。\(problem.advice)\(code)"
            case .timedOut(let seconds):
                RenewDiagLog.write("intent timeout \(seconds)s (download keeps running in background)")
                reason = "驗證伺服器太慢（等了 \(seconds) 秒）。下載還在背景繼續，過 1 分鐘再跑一次「下載PinFly描述檔」（下載好的不會重抓）。"
            }
        }
        return try await failed(reason, stopOnFailure: stopOnFailure, prefix: "下載沒成功")
    }

    /// 安裝PinFly描述檔. Never contacts Apple or anisette. Nothing waiting is a quick success (no tunnel,
    /// no network, never throws): this action also sits in the owner's everyday 出門改定位 Shortcut.
    static func install(stopOnFailure: Bool, maxSeconds: Int) async throws -> (value: GpsSimStatusEntity, dialog: String) {
        RenewDiagLog.write("intent start step=install maxSeconds=\(maxSeconds) stopOnFailure=\(stopOnFailure)")
        guard RenewService.shared.hasPendingFile else {
            RenewDiagLog.write("intent install: nothing pending, nothing to do")
            let value = await GpsSimIntentStatus.make(.notNeeded)
            return (value, "沒有等著安裝的描述檔，不用裝")
        }
        let reason: String
        switch await GpsRenewRace.run(seconds: min(max(maxSeconds, 10), 25), operation: .install) {
        case .done(let outcome) where outcome.nothingToInstall:
            let value = await GpsSimIntentStatus.make(.notNeeded)
            return (value, outcome.message)
        case .done(let outcome) where outcome.alreadyUpToDate:
            let value = await GpsSimIntentStatus.make(.notNeeded)
            return (value, "簽名已經是最新的，不用安裝")
        case .done(let outcome):
            let value = await GpsSimIntentStatus.make(.renewed, signingExpiry: outcome.expiry)
            let until = value.signingExpiry.map { "，簽名到 \(GpsProfileRenew.expiryText($0))" } ?? ""
            return (value, "已續簽\(until)")
        case .failed(let error):
            let problem = (error as? RenewProblem) ?? RenewErrorClassifier.explain(error)
            let code = problem.code.map { "（代碼 \($0)）" } ?? ""
            reason = "\(problem.title)。\(problem.advice)\(code)"
        case .timedOut(let seconds):
            RenewDiagLog.write("intent timeout \(seconds)s (install keeps running in background)")
            reason = "安裝太慢（等了 \(seconds) 秒）。還在背景繼續，過 1 分鐘再用「查簽名剩幾天」確認。"
        }
        return try await failed(reason, stopOnFailure: stopOnFailure, prefix: "安裝沒成功")
    }

    /// The failure answer all three share: 結果＝失敗 plus until when the app keeps working.
    /// `prefix` names the step (download / install failures are not 「沒續簽成功」).
    private static func failed(_ reason: String, stopOnFailure: Bool,
                               prefix: String = "沒續簽成功") async throws -> (value: GpsSimStatusEntity, dialog: String) {
        var value = await GpsSimIntentStatus.make(.failed)
        // Spec 1.8: every failure says until when the app keeps working, to keep it calm.
        let safe = value.signingExpiry.flatMap { expiry in
            expiry.timeIntervalSinceNow > 0 ? "簽名到 \(GpsProfileRenew.expiryText(expiry)) 前照常能用。" : nil
        } ?? ""
        value.reason = safe.isEmpty ? reason : "\(reason)\(safe)"
        let message = "\(prefix)：\(value.reason)"
        if stopOnFailure { throw GpsSimIntentError.failed(message) }
        return (value, message)
    }
}

/// Runs RenewService.renewNow() against a deadline. Whichever finishes first answers; the renew is
/// never cancelled (a half-cancelled install is worse than one that completes a bit later).
@MainActor
enum GpsRenewRace {
    enum Finish {
        case done(RenewOutcome)
        case failed(Error)
        case timedOut(Int)
    }

    @MainActor
    private final class State {
        var continuation: CheckedContinuation<Finish, Never>?
        var backgroundTask: UIBackgroundTaskIdentifier = .invalid

        func answer(_ finish: Finish) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(returning: finish)
        }

        func endBackgroundTask() {
            guard backgroundTask != .invalid else { return }
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    static func run(seconds: Int, operation: RenewService.Job = .renew) async -> Finish {
        let state = State()
        state.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "GpsSimRenewIntent") {
            RenewDiagLog.write("bgtask expired")
            MainActor.assumeIsolated { state.endBackgroundTask() }
        }
        return await withCheckedContinuation { continuation in
            state.continuation = continuation
            Task { @MainActor in
                do {
                    let outcome: RenewOutcome
                    switch operation {
                    case .renew: outcome = try await RenewService.shared.renewNow(quick: true)
                    case .download: outcome = try await RenewService.shared.downloadProfile(quick: true)
                    case .install: outcome = try await RenewService.shared.installPendingProfile()
                    }
                    state.answer(.done(outcome))
                    GpsRenewCenter.shared.externalRenewFinished(expiry: outcome.expiry, failure: nil,
                                                                alreadyUpToDate: outcome.alreadyUpToDate,
                                                                nothingInstalled: outcome.pendingOnly || outcome.nothingToInstall)
                } catch {
                    state.answer(.failed(error))
                    // downloadInProgress: this install never started; the running job ends the home card itself.
                    if (error as? RenewProblem)?.kind != .downloadInProgress {
                        GpsRenewCenter.shared.externalRenewFinished(expiry: nil, failure: error, nothingInstalled: operation != .renew)
                    }
                }
                // Only now: after a timeout the renew is still worth finishing in the background.
                state.endBackgroundTask()
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                state.answer(.timedOut(seconds))
            }
        }
    }
}

// MARK: - 查簽名剩幾天

/// Offline: reads the installed profile's expiry (or the newer one this app installed itself).
struct SigningStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "查簽名剩幾天"
    static var description = IntentDescription("看PinFly的簽名還能用幾天，不連網路。")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<GpsSimStatusEntity> & ProvidesDialog {
        let value = await GpsSimIntentStatus.make(.succeeded)
        guard let sentence = GpsSimIntentStatus.signingSentence(value) else {
            var unknown = value
            unknown.outcome = .failed
            unknown.reason = "讀不到簽名到期日。"
            return .result(value: unknown, dialog: "讀不到簽名到期日")
        }
        return .result(value: value, dialog: "\(sentence)")
    }
}

// MARK: - 目前模擬狀態

/// Offline and read-only: never touches the phone's location. Not in App Shortcuts (a building block only).
struct SimulationStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "目前模擬狀態"
    static var description = IntentDescription("回傳現在有沒有在模擬、在哪個地點。不連網路、不改定位。")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<GpsSimStatusEntity> & ProvidesDialog {
        let value = await GpsSimIntentStatus.make(.succeeded)
        guard let place = GpsSimIntentStatus.currentPlace() else {
            return .result(value: value, dialog: "沒有在模擬")
        }
        // After a relaunch only the persisted last target is known; a stop always clears it.
        let note = place.confirmed ? "" : "（PinFly重開過，這是上次送出的地點）"
        return .result(value: value, dialog: "正在模擬：\(place.name)\(note)")
    }
}
