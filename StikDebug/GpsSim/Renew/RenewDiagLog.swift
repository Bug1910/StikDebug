//
//  RenewDiagLog.swift
//  StikDebug (GpsSim fork) - experimental renew copy
//
//  The "flight recorder" for renewal problems. Appends one line per event to
//  Documents/renew-diag.log (the Documents folder is visible over USB, e.g. with pymobiledevice3),
//  so a failure on a real phone can be read afterwards.
//  Only hashes, error codes and path names go in: never the Apple ID, password, token or raw anisette headers.
//  The file is cut back to its newest half when it grows past 200 KB.
//

import Foundation
import SideSign

enum RenewDiagLog {
    private static let lock = NSLock()
    private static var lastAnisettePath = "-"
    private static var lastAnisetteServer = "-"
    private static let maxBytes = 200_000

    static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("renew-diag.log")
    }

    /// Which way the last anisette data was obtained ("fresh (no adi.pb)", "blob", "blob (backup)") and from which host.
    static func notePath(_ path: String, server: String) {
        lock.lock()
        lastAnisettePath = path
        lastAnisetteServer = server
        lock.unlock()
    }

    static func lastPath() -> (path: String, server: String) {
        lock.lock()
        defer { lock.unlock() }
        return (lastAnisettePath, lastAnisetteServer)
    }

    static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(message)\n".data(using: .utf8) else { return }
        let url = fileURL
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: data)
            return
        }
        if let size = (try? manager.attributesOfItem(atPath: url.path)[.size]) as? Int, size > maxBytes,
           let old = try? Data(contentsOf: url) {
            var tail = old.suffix(maxBytes / 2)
            if let newline = tail.firstIndex(of: 0x0A) { tail = tail[tail.index(after: newline)...] }  // drop the cut-in-half first line
            try? Data(tail).write(to: url)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        // Flush now: a background intent can be killed by iOS at any moment and unflushed lines would be lost.
        try? handle.synchronize()
    }

    /// Error code and Apple's own short message when it is a server error; otherwise just the kind of error.
    static func describe(_ error: Error) -> String {
        if let server = error as? SideSign.ServerError, case .underlyingError(let code, let message) = server {
            return "ServerError code=\(code) message=\(String(describing: message))"
        }
        let problem = RenewErrorClassifier.explain(error)
        return "\(type(of: error)) -> \(problem.kind.rawValue)\(problem.code.map { " code=\($0)" } ?? "")"
    }

    /// Runs `body`; writes one line saying whether it worked, with `context` (hashes / path / server).
    static func trace<T>(_ name: String, context: String, _ body: () async throws -> T) async throws -> T {
        do {
            let value = try await body()
            write("\(name) ok; \(context)")
            return value
        } catch {
            write("\(name) FAILED \(describe(error)); \(context)")
            throw error
        }
    }
}
