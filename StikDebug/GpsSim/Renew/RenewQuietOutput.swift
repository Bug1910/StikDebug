//
//  RenewQuietOutput.swift
//  StikDebug (GpsSim fork) - experimental renew copy
//
//  TEMPORARY workaround: SideSign's debugLog() prints unconditionally (Logging.swift:39, not switched
//  off by SideSignLogging.setLogging(false)); on failures it prints Apple's raw responses and the dsid.
//  While a live sign-in (including the 2FA wait) or renew runs, stdout (fd 1) and stderr (fd 2) are
//  pointed at /dev/null and restored afterwards, also on error or cancellation (defer).
//  Reference-counted under a lock: overlapping sections share ONE redirection, restored by the last one.
//  Release builds only; DEBUG keeps the output for debugging. Remove once SideSign gates debugLog.
//  Side effect while active: the app's own print()/NSLog-to-stderr output is muted too.
//

import Foundation

enum RenewQuietOutput {
    private static let lock = NSLock()
    private static var depth = 0
    private static var savedOut: Int32 = -1
    private static var savedErr: Int32 = -1

    static func run<T>(_ operation: () async throws -> T) async rethrows -> T {
        #if DEBUG
        return try await operation()
        #else
        begin()
        defer { end() }
        return try await operation()
        #endif
    }

    private static func begin() {
        lock.lock()
        defer { lock.unlock() }
        depth += 1
        guard depth == 1 else { return }
        fflush(stdout)
        fflush(stderr)
        let null = open("/dev/null", O_WRONLY)
        guard null >= 0 else { return }
        savedOut = dup(STDOUT_FILENO)
        savedErr = dup(STDERR_FILENO)
        if savedOut >= 0 { dup2(null, STDOUT_FILENO) }
        if savedErr >= 0 { dup2(null, STDERR_FILENO) }
        close(null)
    }

    private static func end() {
        lock.lock()
        defer { lock.unlock() }
        depth = max(0, depth - 1)
        guard depth == 0 else { return }
        fflush(stdout)
        fflush(stderr)
        if savedOut >= 0 { dup2(savedOut, STDOUT_FILENO); close(savedOut); savedOut = -1 }
        if savedErr >= 0 { dup2(savedErr, STDERR_FILENO); close(savedErr); savedErr = -1 }
    }
}
