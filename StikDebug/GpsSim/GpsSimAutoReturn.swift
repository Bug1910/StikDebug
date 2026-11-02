//
//  GpsSimAutoReturn.swift
//  PinFly
//
//  【這個檔案的角色】「持續時間」的鬧鐘：時間到就停止模擬、回到真實位置（規格 12.3.1）。
//  - 結束時間存在 UserDefaults（App 被系統關掉再開也記得）；App 啟動、回到前景、
//    任何捷徑動作執行時都會檢查一次，已超過就立刻停止。
//  - App 在跑時另有 15 秒一次的計時器（RunLoop .common，與移動器的 1 Hz 計時器同一套），
//    背景靠既有的背景音訊／定位工作階段保持執行。
//  - 成功停止模擬（engine.stop，完整清除）或任何新的「前往／移動」都會取消鬧鐘。
//  - 停止失敗（例如手機鎖定）時保留鬧鐘、15 秒後再試，失敗通知同一個結束時間只發一次。
//
//  GpsSimIntentLog：捷徑動作的紀錄，寫進 App 既有的 LogManager（設定內可看）。
//

import Foundation
import UserNotifications

@MainActor
final class GpsSimAutoReturn: ObservableObject {
    static let shared = GpsSimAutoReturn()

    static let defaultsKey = "gpsSim.autoReturnAt"
    static let checkInterval: TimeInterval = 15

    /// 回到真實位置的時間；nil＝沒有設定持續時間。
    @Published private(set) var deadline: Date? = nil

    private var timer: Timer?
    private var stopping = false
    /// 已為哪一個結束時間發過「無法回到真實位置」通知（避免每 15 秒一則）。
    private var failureNotifiedFor: Date?

    private init() {
        let stamp = UserDefaults.standard.double(forKey: Self.defaultsKey)
        deadline = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    /// 純函式（單元測試用）：到時間了沒。
    nonisolated static func isDue(deadline: Date?, now: Date) -> Bool {
        guard let deadline else { return false }
        return now >= deadline
    }

    func arm(at date: Date) {
        deadline = date
        failureNotifiedFor = nil
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.defaultsKey)
        startTimer()
        GpsSimIntentLog.info("auto-return armed for \(date)")
    }

    func arm(after seconds: TimeInterval) {
        arm(at: Date().addingTimeInterval(seconds))
    }

    /// 取消鬧鐘（成功停止模擬、或新的前往／移動）。沒有設定時什麼都不做。
    func clear(reason: String) {
        guard deadline != nil else { return }
        deadline = nil
        failureNotifiedFor = nil
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        timer?.invalidate()
        timer = nil
        GpsSimIntentLog.info("auto-return cleared (\(reason))")
    }

    /// App 啟動、回前景時呼叫：補開計時器並立即檢查一次（不等結果）。
    func resume() {
        guard deadline != nil else { return }
        if timer == nil { startTimer() }
        check()
    }

    /// 捷徑動作開始時呼叫：與 resume 相同，但已到期時等停止模擬的結果（最多 timeout 秒），
    /// 之後讀到的狀態才是真的（不會在回到真實位置的途中回報「模擬中」）。
    func settle(timeout: TimeInterval = 6) async {
        guard deadline != nil else { return }
        if timer == nil { startTimer() }
        guard Self.isDue(deadline: deadline, now: Date()) else { return }
        check()
        let end = Date().addingTimeInterval(timeout)
        while stopping && Date() < end {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// 已到期但尚未回到真實位置（停止失敗或仍在進行）。
    var isOverdue: Bool {
        Self.isDue(deadline: deadline, now: Date())
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: Self.checkInterval, repeats: true) { _ in
            Task { @MainActor in GpsSimAutoReturn.shared.check() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func check(now: Date = Date()) {
        guard !stopping, Self.isDue(deadline: deadline, now: now) else { return }
        let due = deadline
        stopping = true
        GpsSimIntentLog.info("auto-return due, stopping simulation")
        GpsSimEngine.shared.stop { [weak self] code in
            guard let self else { return }
            self.stopping = false
            if code == 0 {
                self.clear(reason: "returned")
                Self.notify("已回到真實位置。", id: "gpsSim.autoReturn.done")
                return
            }
            // 引擎正忙（使用者剛好在前往／停止）：下一輪再試，不算失敗。
            if code == GpsSimEngine.busyCode { return }
            GpsSimIntentLog.error("auto-return stop failed (code \(code))")
            if self.failureNotifiedFor != due {
                self.failureNotifiedFor = due
                Self.notify("無法回到真實位置。請開啟 PinFly 並點選「停止模擬」。（錯誤 12）",
                            id: "gpsSim.autoReturn.failed")
            }
        }
    }

    /// 本機通知（未授權時系統自動略過）。
    nonisolated static func notify(_ body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = "PinFly"
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { GpsSimIntentLog.error("notification failed: \(error.localizedDescription)") }
        }
    }
}

/// 捷徑動作的紀錄（App 既有 LogManager；只寫地點名稱、方式與錯誤代碼，不寫座標）。
enum GpsSimIntentLog {
    static func info(_ message: String) {
        LogManager.shared.addInfoLog("[Shortcut] \(message)")
    }

    static func error(_ message: String) {
        LogManager.shared.addErrorLog("[Shortcut] \(message)")
    }
}
