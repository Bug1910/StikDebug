//
//  RenewAnisette.swift
//  StikDebug (GpsSim fork) - experimental renew copy
//
//  Gets "anisette" (the data that makes Apple believe the request comes from a Mac) for sign-in and renew.
//  Fixed settings (B4): remote server https://mac-ani.jkcoxson.com (v3, 10/24: the one iloader signed in with while new.ani.sidestore.io gave 1100), no On-Device anisette, no
//  rotation, default Mac client strings (headers: nil -> SideSign/AnisetteKit defaults); there is no
//  way to type in other client strings.
//  B1, same idea as SideStoreAuto feat-anisette 80f11e1: only when this phone is already provisioned
//  (adi.pb exists) the primary gets a 6 s cap; on any primary failure a backup v3 server is tried once
//  with the same cap and accepted only if its machine ID hashes the same as the primary's last answer.
//  A backup answer never writes adi.pb. With no adi.pb yet the original, uncapped primary-only path runs.
//  Header values, machine IDs and adi.pb are never logged.
//

import CryptoKit
import Foundation
import SideSign

enum RenewAnisette {
    static let primaryServer = URL(string: "https://mac-ani.jkcoxson.com")!
    /// Former primary. Servers are never mixed: its answer is used only when its machine ID equals the primary's.
    static let backupServer = URL(string: "https://new.ani.sidestore.io")!

    /// Host name a session is bound to (a token issued under one server's identity is not valid under another's).
    static var primaryHost: String { primaryServer.host ?? "?" }
    /// 10/22 device log: answers slower than ~16 s always failed, under ~4 s almost always worked.
    static let timeoutSeconds: TimeInterval = 6

    struct TimeoutError: LocalizedError {
        let seconds: TimeInterval
        var errorDescription: String? { "anisette server did not answer within \(Int(seconds)) s" }
    }

    /// SHA-256 of the primary's machine ID (X-Apple-I-MD-M). Only the hash is stored.
    private static let primaryMachineIDHashKey = "gpssim.renew.primaryMachineIDHash"

    static func fetch() async throws -> AnisetteData {
        let identifier = try RenewKeychain.anisetteIdentifier()
        guard let existingBlob = RenewKeychain.adiBlob else {
            // Not provisioned yet: original path, primary only, no timeout (provisioning must not be cut off).
            let result = try await AnisetteDataManager.shared.fetchAnisetteData(
                mode: .remote(server: primaryServer),
                identifier: identifier,
                existingAdiBlob: nil,
                headers: nil
            )
            if let blob = result.newAdiBlob { try RenewKeychain.setAdiBlob(blob) }
            rememberPrimaryMachineID(result.data)
            RenewDiagLog.notePath("fresh (no adi.pb)", server: primaryServer.host ?? "?")
            return result.data
        }

        do {
            let result = try await withTimeout(seconds: timeoutSeconds) {
                // Throw-away manager: a request abandoned after the timeout only writes its own cache.
                try await AnisetteDataManager().fetchAnisetteData(
                    mode: .remote(server: primaryServer),
                    identifier: identifier,
                    existingAdiBlob: existingBlob,
                    headers: nil
                )
            }
            if let blob = result.newAdiBlob { try RenewKeychain.setAdiBlob(blob) }
            rememberPrimaryMachineID(result.data)
            RenewDiagLog.notePath("blob", server: primaryServer.host ?? "?")
            return result.data
        } catch let primaryError {
            if primaryError is CancellationError { throw primaryError }
            do {
                let backup = try await withTimeout(seconds: timeoutSeconds) {
                    try await AnisetteDataManager().fetchAnisetteData(
                        mode: .remote(server: backupServer),
                        identifier: identifier,
                        existingAdiBlob: existingBlob,
                        headers: nil
                    )
                }
                guard backupMatchesPrimary(backup.data) else { throw primaryError }
                RenewDiagLog.notePath("blob (backup)", server: backupServer.host ?? "?")
                return backup.data   // never persist an adi.pb coming from the backup
            } catch {
                // Surface the primary's error so the retry rule classifies it as before.
                throw primaryError
            }
        }
    }

    static func clearCaches() {
        AnisetteDataManager.shared.clearCache()
    }

    /// Forget the device identity (next fetch provisions again on the primary).
    /// Also deletes the saved Apple session: a token issued under the old machine ID must not be
    /// sent with a new one. Called from RenewService.resetVerificationData() (設定頁「重設驗證資料」).
    static func resetAll() {
        clearCaches()
        RenewKeychain.deleteSession(service: RenewKeychain.liveService)
        RenewKeychain.resetAnisette()
        UserDefaults.standard.removeObject(forKey: primaryMachineIDHashKey)
    }

    // MARK: - Machine ID check

    static func machineIDHash(_ data: AnisetteData) -> String {
        SHA256.hash(data: Data(data.machineID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func rememberPrimaryMachineID(_ data: AnisetteData) {
        UserDefaults.standard.set(machineIDHash(data), forKey: primaryMachineIDHashKey)
    }

    /// True only when a primary hash is recorded and the backup's machine ID matches it.
    static func backupMatchesPrimary(_ data: AnisetteData) -> Bool {
        guard let known = UserDefaults.standard.string(forKey: primaryMachineIDHashKey), !known.isEmpty else { return false }
        return known == machineIDHash(data)
    }

    // MARK: - Timeout

    /// Races `operation` against a timer with unstructured tasks, so we return on time even if the
    /// request ignores cancellation (a task group would wait for the child).
    static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let gate = RenewResumeGate()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let work = Task {
                do {
                    let value = try await operation()
                    if gate.claim() { continuation.resume(returning: value) }
                } catch {
                    if gate.claim() { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if gate.claim() {
                    work.cancel()
                    continuation.resume(throwing: TimeoutError(seconds: seconds))
                }
            }
        }
    }
}

/// Makes sure a continuation is resumed exactly once.
final class RenewResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
