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

// MARK: - 續簽PinFly

struct RenewSigningIntent: AppIntent {
    static var title: LocalizedStringResource = "續簽PinFly"
    static var description = IntentDescription("換新的 7 天簽名，不用接電腦。要先在PinFly › 設定 › 簽名登入 Apple 一次（捷徑裡不能登入，驗證碼要人輸入）。預設最多等 20 秒；失敗時預設不會讓捷徑停下來，請用「如果 結果 是 失敗」判斷。只有 4G 時，裝上新簽名那一步需要 LocalDevVPN。")
    static var openAppWhenRun: Bool = false

    /// 0 = renew no matter how many days are left.
    @Parameter(title: "只在剩幾天內才續簽", default: 3, inclusiveRange: (0, 7))
    var withinDays: Int

    @Parameter(title: "失敗時停止捷徑", default: false)
    var stopOnFailure: Bool

    @Parameter(title: "最多等幾秒", default: 20, inclusiveRange: (10, 25))
    var maxSeconds: Int

    static var parameterSummary: some ParameterSummary {
        Summary("續簽PinFly（剩 \(\.$withinDays) 天內才續簽）") {
            \.$stopOnFailure
            \.$maxSeconds
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<GpsSimStatusEntity> & ProvidesDialog {
        await GpsProfileRenew.refreshFromPhone()
        let before = await RenewService.shared.status()
        let reason: String
        if !before.isSignedIn {
            reason = "還沒登入 Apple。請打開PinFly › 設定 › 簽名，登入一次。"
        } else {
            if withinDays > 0, let expiry = before.profileExpiry,
               expiry.timeIntervalSinceNow > Double(withinDays) * 86_400 {
                let value = await GpsSimIntentStatus.make(.notNeeded)
                return .result(value: value, dialog: "簽名還有 \(value.daysLeft ?? withinDays) 天，不用續簽")
            }
            switch await GpsRenewRace.run(seconds: min(max(maxSeconds, 10), 25)) {
            case .done(let outcome) where outcome.alreadyUpToDate:
                let value = await GpsSimIntentStatus.make(.notNeeded)
                return .result(value: value, dialog: "簽名已經是最新的，不用續簽")
            case .done(let outcome):
                let value = await GpsSimIntentStatus.make(.renewed, signingExpiry: outcome.expiry)
                let until = value.signingExpiry.map { "，簽名到 \(GpsProfileRenew.expiryText($0))" } ?? ""
                return .result(value: value, dialog: "已續簽\(until)")
            case .failed(let error):
                let problem = (error as? RenewProblem) ?? RenewErrorClassifier.explain(error)
                let code = problem.code.map { "（代碼 \($0)）" } ?? ""
                reason = "\(problem.title)。\(problem.advice)\(code)"
            case .timedOut(let seconds):
                reason = "驗證伺服器太慢（等了 \(seconds) 秒）。續簽還在背景繼續，過 1 分鐘再用「查簽名剩幾天」確認。"
            }
        }
        var value = await GpsSimIntentStatus.make(.failed)
        // Spec 1.8: every failure says until when the app keeps working, to keep it calm.
        let safe = value.signingExpiry.flatMap { expiry in
            expiry.timeIntervalSinceNow > 0 ? "簽名到 \(GpsProfileRenew.expiryText(expiry)) 前照常能用。" : nil
        } ?? ""
        value.reason = safe.isEmpty ? reason : "\(reason)\(safe)"
        let message = "沒續簽成功：\(value.reason)"
        if stopOnFailure { throw GpsSimIntentError.failed(message) }
        return .result(value: value, dialog: "\(message)")
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

    static func run(seconds: Int) async -> Finish {
        let state = State()
        state.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "GpsSimRenewIntent") {
            MainActor.assumeIsolated { state.endBackgroundTask() }
        }
        return await withCheckedContinuation { continuation in
            state.continuation = continuation
            Task { @MainActor in
                do {
                    let outcome = try await RenewService.shared.renewNow()
                    state.answer(.done(outcome))
                    GpsRenewCenter.shared.externalRenewFinished(expiry: outcome.expiry, failure: nil,
                                                                alreadyUpToDate: outcome.alreadyUpToDate)
                } catch {
                    state.answer(.failed(error))
                    GpsRenewCenter.shared.externalRenewFinished(expiry: nil, failure: error)
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
