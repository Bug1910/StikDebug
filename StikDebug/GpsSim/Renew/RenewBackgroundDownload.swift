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
import UIKit

enum RenewBackgroundDownload {
    /// Must match Info.plist BGTaskSchedulerPermittedIdentifiers.
    static let identifier = "com.stik.stikdebug.pinfly.download"
    static let interval: TimeInterval = 6 * 3_600
    static let withinDays: Double = 3

    /// Set once per process (main thread only): registering twice is not allowed.
    private static var registered = false
    private static var attempted = false
    /// "foreground" / "background": how this process was launched, for the log lines.
    private static var launchContext = "unknown"

    /// Called from the App's init. iOS only accepts registration before launch finishes, and a process
    /// launched in the background (a locked-phone Shortcut running an intent) got register = false and
    /// submit code 3 (notPermitted) on the phone (renew-diag 10/27). So in a background launch nothing is
    /// registered: registering later (on the first .active) is not attempted either, because BGTaskScheduler
    /// raises an exception for launch handlers registered after launch. The next foreground launch registers.
    @MainActor
    @discardableResult
    static func registerAtLaunch() -> Bool {
        guard !attempted else { return registered }
        attempted = true
        let background = UIApplication.shared.applicationState == .background
        launchContext = background ? "background" : "foreground"
        guard !background else {
            RenewDiagLog.write("bg download: not registered (launch=background); the next foreground launch registers")
            return false
        }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refresh)
        }
        RenewDiagLog.write("bg download: register \(registered ? "ok" : "failed") (launch=\(launchContext))")
        if registered { scheduleIfNone() }
        return registered
    }

    /// Each scenePhase .active: make sure one request is planned (only in a process that registered).
    @MainActor
    static func appBecameActive() {
        guard registered else { return }
        scheduleIfNone()
    }

    /// Only when nothing is planned yet: submitting replaces the request, so doing it on every launch /
    /// activation would push earliestBeginDate 6 h ahead each time and the task might never run.
    private static func scheduleIfNone() {
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            if !requests.contains(where: { $0.identifier == identifier }) { schedule() }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(interval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Simulator / background refresh switched off: nothing to do, the foreground paths still work.
            RenewDiagLog.write("bg download: schedule failed code=\((error as NSError).code) (launch=\(launchContext))")
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
        let holder = WorkHolder()
        // Set before the work starts, so an early expiry is never missed.
        task.expirationHandler = {
            // The download Task inside RenewService is not tied to this one (a half-saved profile is never
            // left: the file is written atomically at the very end), so only our wait is cancelled here.
            RenewDiagLog.write("bg download expired")
            holder.cancel()
            completion.finish(success: false)
        }
        holder.set(Task { @MainActor in
            let success = await runOnce()
            completion.finish(success: success)
        })
    }

    /// Lets the expiration handler (set first) cancel the Task created after it.
    private final class WorkHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var work: Task<Void, Never>?
        private var cancelled = false

        func set(_ task: Task<Void, Never>) {
            lock.lock()
            work = task
            let cancelNow = cancelled
            lock.unlock()
            if cancelNow { task.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = work
            lock.unlock()
            task?.cancel()
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
