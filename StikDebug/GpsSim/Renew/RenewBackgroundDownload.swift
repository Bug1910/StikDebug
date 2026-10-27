//
//  RenewBackgroundDownload.swift
//  StikDebug (GpsSim fork) - experimental renew copy (PinFly)
//
//  The "night shift" for step 1 of renewing: a BGAppRefreshTask (background fetch, works with a free
//  Apple ID; UIBackgroundModes already lists `fetch`) that downloads the new 7-day profile while the app
//  is closed, when 3 days or less are left. It only DOWNLOADS (internet, no tunnel); installing happens
//  the next time the app comes to the front or 安裝PinFly描述檔 runs (e.g. inside 出門改定位).
//  iOS decides when (if ever) this runs; earliest every 6 hours. One attempt, no retries (short budget).
//

import BackgroundTasks
import Foundation

enum RenewBackgroundDownload {
    /// Must match Info.plist BGTaskSchedulerPermittedIdentifiers.
    static let identifier = "com.stik.stikdebug.pinfly.download"
    static let interval: TimeInterval = 6 * 3_600
    static let withinDays: Double = 3

    /// Called from the App's init (iOS requires registration before launch finishes).
    static func register() {
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refresh)
        }
        if !registered { RenewDiagLog.write("bg download: register failed") }
        schedule()
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(interval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Simulator / background refresh switched off: nothing to do, the foreground paths still work.
            RenewDiagLog.write("bg download: schedule failed code=\((error as NSError).code)")
        }
    }

    /// setTaskCompleted exactly once, whether the work or the expiration handler gets there first.
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        let task: BGAppRefreshTask
        init(_ task: BGAppRefreshTask) { self.task = task }

        func finish(success: Bool) {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            if first { task.setTaskCompleted(success: success) }
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()   // always plan the next run first, whatever happens to this one
        RenewDiagLog.write("bg download start")
        let completion = Completion(task)
        let work = Task { @MainActor in
            let success = await runOnce()
            completion.finish(success: success)
        }
        task.expirationHandler = {
            // The download Task inside RenewService is not tied to this one (a half-saved profile is never
            // left: the file is written atomically at the very end), so only our wait is cancelled here.
            RenewDiagLog.write("bg download expired")
            work.cancel()
            completion.finish(success: false)
        }
    }

    /// True when there was nothing to do or the download worked.
    @MainActor
    private static func runOnce() async -> Bool {
        let status = await RenewService.shared.status()
        guard status.isSignedIn, !status.sessionExpired else {
            RenewDiagLog.write("bg download finish: skipped, not signed in")
            return true
        }
        // Local only: the installed / verified expiry. Unknown = do not ask Apple blindly.
        guard let expiry = status.profileExpiry, expiry.timeIntervalSinceNow <= withinDays * 86_400 else {
            RenewDiagLog.write("bg download finish: skipped, more than \(Int(withinDays)) days left or expiry unknown")
            return true
        }
        do {
            // A fresh waiting profile is reused without Apple (RenewBackend.download).
            let outcome = try await RenewService.shared.downloadProfile(quick: true)
            let what = outcome.alreadyUpToDate ? "already up to date" : (outcome.reusedPending ? "pending reused" : "saved")
            RenewDiagLog.write("bg download finish: \(what)")
            if outcome.pendingOnly, !outcome.reusedPending { GpsRenewReminders.notifyDownloaded() }
            return true
        } catch {
            RenewDiagLog.write("bg download finish: FAILED \(RenewDiagLog.describe(error))")
            return false
        }
    }
}
