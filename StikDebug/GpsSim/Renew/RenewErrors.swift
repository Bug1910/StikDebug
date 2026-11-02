//
//  RenewErrors.swift
//  StikDebug (GpsSim fork) - experimental renew copy
//
//  Plain-language error table for the renew screen (B5) and the "is this worth one more try?" rule (B3).
//  Raw SideSign errors can carry server payloads, so their text is NEVER shown or logged; only the
//  kind and code below are.
//

import Foundation
import SideSign

struct RenewProblem: LocalizedError, Equatable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        case wrongPassword, appSpecificPassword, twoFactorFailed, wrongCode, tooManyAttempts
        case appleRefused80045, appleRefused80046, serviceUnavailable503, appleSession1100
        case anisetteTimeout, anisetteUnavailable, network
        case notSignedIn, sessionExpired, signInInProgress, cancelled
        case teamMismatch, appIDMissing, certMismatch, profileNotNewer
        case tunnelRwAfc, deviceEndpointNil, needTunnel, install
        /// Downloaded and kept, but the install half could not reach the phone (no LocalDevVPN path).
        case pendingNeedsTunnel
        /// 安裝PinFly描述檔 started while a download (or a whole renew) was still running.
        case downloadInProgress
        case keychain
        case unknown
    }

    let kind: Kind
    /// Short code shown in small print ("-80045", "1100"...), nil when there is none.
    let code: String?
    let title: String
    let advice: String
    /// Extra text that is known to be safe (our own messages, e.g. from GpsProfileRenew.Failure).
    var detail: String? = nil

    var errorDescription: String? {
        [title, detail, advice].compactMap { $0 }.joined(separator: "\n")
    }

    static func == (a: RenewProblem, b: RenewProblem) -> Bool { a.kind == b.kind && a.code == b.code }

    init(_ kind: Kind, code: String? = nil, detail: String? = nil) {
        let entry = RenewErrorTable.entry(for: kind)
        self.kind = kind
        self.code = code ?? entry.code
        self.title = entry.title
        self.advice = entry.advice
        self.detail = detail
    }
}

/// The table the UI shows. Codes listed here are the ones seen on this phone (TESTLOG 10/12～10/22).
enum RenewErrorTable {
    struct Entry: Sendable {
        let code: String?
        let title: String
        let advice: String
    }

    static func entry(for kind: RenewProblem.Kind) -> Entry {
        switch kind {
        case .appleRefused80045:
            return Entry(code: "-80045", title: "Apple 拒絕此次登入",
                         advice: "請數小時後再試，避免連續重試，以免遭到限速。")
        case .appleRefused80046:
            // Meaning not documented by Apple (未驗證); seen next to -80045 in SideStore reports.
            return Entry(code: "-80046", title: "Apple 拒絕此次登入",
                         advice: "請數小時後再試，避免連續重試。")
        case .serviceUnavailable503:
            return Entry(code: "503", title: "Apple 或驗證伺服器暫時無法使用",
                         advice: "伺服器忙碌或維護中。請稍後再試。")
        case .appleSession1100:
            return Entry(code: "1100", title: "Apple 開發者服務回傳錯誤",
                         advice: "驗證伺服器回應過慢時會發生，已自動重試 1 次。請數分鐘後再試。")
        case .anisetteTimeout:
            return Entry(code: nil, title: "驗證伺服器回應逾時",
                         advice: "主要與備用伺服器皆未在 6 秒內回應，已自動重試 2 次。請更換網路或稍後再試。")
        case .anisetteUnavailable:
            return Entry(code: nil, title: "無法連線至驗證伺服器",
                         advice: "請稍後再試。")
        case .network:
            return Entry(code: nil, title: "沒有網路連線",
                         advice: "請連上 Wi-Fi 或行動網路後再試。")
        case .wrongPassword:
            return Entry(code: "-22406", title: "Apple ID 或密碼不正確", advice: "請重新輸入。")
        case .appSpecificPassword:
            return Entry(code: "-20101", title: "此帳號需使用 App 專用密碼",
                         advice: "請至 appleid.apple.com 產生 App 專用密碼，再以此密碼登入。")
        case .twoFactorFailed:
            return Entry(code: nil, title: "雙重認證未完成", advice: "請重新登入，並輸入收到的 6 位數驗證碼。")
        case .wrongCode:
            return Entry(code: "-21669", title: "驗證碼不正確", advice: "請重新輸入收到的 6 位數驗證碼。")
        case .tooManyAttempts:
            return Entry(code: "-21668", title: "嘗試次數過多", advice: "Apple 暫時限制登入。請數小時後再試。")
        case .notSignedIn:
            return Entry(code: nil, title: "尚未登入 Apple ID", advice: "請至「設定 › 簽名」登入。")
        case .sessionExpired:
            return Entry(code: nil, title: "登入已過期", advice: "請重新登入，並輸入新的驗證碼。")
        case .signInInProgress:
            return Entry(code: nil, title: "登入尚未完成", advice: "請完成或取消目前的登入。")
        case .cancelled:
            return Entry(code: nil, title: "已取消", advice: "需要時請重新開始。")
        case .teamMismatch:
            return Entry(code: nil, title: "此 Apple ID 與安裝 PinFly 的帳號不同",
                         advice: "請改用安裝 PinFly 時的 Apple ID 登入。目前設定未變更。")
        case .appIDMissing:
            return Entry(code: nil, title: "Apple 帳號中找不到 PinFly 的 App ID",
                         advice: "為避免占用 App ID 數量，不會自動建立。請用電腦重新安裝 PinFly。")
        case .certMismatch:
            return Entry(code: nil, title: "新描述檔的憑證與目前的 App 不同",
                         advice: "安裝後 App 將無法開啟，因此未安裝。請用電腦重新安裝 PinFly。")
        case .profileNotNewer:
            return Entry(code: nil, title: "沒有較新的描述檔", advice: "目前的簽名已是最新。")
        case .tunnelRwAfc:
            return Entry(code: "RwAfc", title: "LocalDevVPN 未連線",
                         advice: "請開啟 LocalDevVPN 後重試；僅使用行動網路時，請先關閉行動數據。")
        case .deviceEndpointNil:
            return Entry(code: "deviceEndpointIp nil", title: "無法取得手機的連線位址",
                         advice: "請開啟 LocalDevVPN 後重試；僅使用行動網路時，請先關閉行動數據。")
        case .needTunnel:
            return Entry(code: nil, title: "需要 LocalDevVPN 連線",
                         advice: "請開啟 LocalDevVPN 後重試；僅使用行動網路時，請先關閉行動數據。")
        case .install:
            return Entry(code: nil, title: "描述檔安裝失敗", advice: "目前的描述檔未變更。請稍後再試。")
        case .pendingNeedsTunnel:
            return Entry(code: nil, title: "描述檔已下載，尚未安裝",
                         advice: "請關閉行動數據並開啟 LocalDevVPN，再執行捷徑動作「安裝 PinFly 描述檔」，或在 PinFly 點選「安裝描述檔」。不需要重新下載或登入。")
        case .downloadInProgress:
            return Entry(code: nil, title: "下載尚未完成",
                         advice: "請待「下載 PinFly 描述檔」完成（約 1 分鐘）後，再執行「安裝 PinFly 描述檔」。")
        case .keychain:
            return Entry(code: "keychain", title: "登入成功，但無法儲存登入資料",
                         advice: "PinFly 無法將登入資料存入鑰匙圈。請重新安裝 PinFly 後再試。")
        case .unknown:
            return Entry(code: nil, title: "續簽失敗", advice: "請稍後再試；持續失敗時，請用電腦重新安裝 PinFly。")
        }
    }

    /// Every row, for a "錯誤碼說明" list in the UI.
    static var all: [(kind: RenewProblem.Kind, entry: Entry)] {
        RenewProblem.Kind.allCases.map { ($0, entry(for: $0)) }
    }
}

// MARK: - Classification

enum RenewErrorClassifier {
    /// Turns any error into a RenewProblem without ever copying raw server text.
    static func explain(_ error: Error) -> RenewProblem {
        if let problem = error as? RenewProblem { return problem }
        if error is CancellationError { return RenewProblem(.cancelled) }
        if let failure = error as? GpsProfileRenew.Failure {
            // Tunnel symptoms first, so RwAfc / deviceEndpointIp get their own rows instead of "install".
            switch failure.tunnelHint {
            case "RwAfc"?: return RenewProblem(.tunnelRwAfc)
            case "deviceEndpointIp"?: return RenewProblem(.deviceEndpointNil)
            default: break
            }
            if failure.isTunnel || failure.message == GpsProfileRenew.needTunnelMessage { return RenewProblem(.needTunnel) }
            let text = failure.message
            if text.contains("RwAfc") { return RenewProblem(.tunnelRwAfc) }
            if text.contains("deviceEndpointIp") { return RenewProblem(.deviceEndpointNil) }
            // Our own Chinese messages: safe to show as detail.
            return RenewProblem(.install, detail: failure.message)
        }
        if error is RenewAnisette.TimeoutError { return RenewProblem(.anisetteTimeout) }

        if let portal = error as? SideSign.DeveloperPortalError {
            switch portal {
            case .incorrectCredentials: return RenewProblem(.wrongPassword)
            case .appSpecificPasswordRequired: return RenewProblem(.appSpecificPassword)
            case .incorrectVerificationCode: return RenewProblem(.wrongCode)
            case .tooManyAttempts: return RenewProblem(.tooManyAttempts)
            case .requiresTwoFactorAuthentication, .invalid2FAResponse: return RenewProblem(.twoFactorFailed)
            case .userCancelled: return RenewProblem(.cancelled)
            case .noTeams: return RenewProblem(.teamMismatch)
            case .appIDDoesNotExist: return RenewProblem(.appIDMissing)
            case .invalidAnisetteData: return RenewProblem(.anisetteUnavailable)
            default: break
            }
        }
        if let server = error as? SideSign.ServerError, case .underlyingError(let code, _) = server {
            switch code {
            case -80045: return RenewProblem(.appleRefused80045)
            case -80046: return RenewProblem(.appleRefused80046)
            case 1100: return RenewProblem(.appleSession1100)
            case 503: return RenewProblem(.serviceUnavailable503)
            default: return RenewProblem(.unknown, code: String(code))
            }
        }
        if let anisette = error as? SideSign.AnisetteError {
            switch anisette {
            case .badServerResponse(let status, _) where status == 503: return RenewProblem(.serviceUnavailable503)
            default: return RenewProblem(.anisetteUnavailable)
            }
        }
        if let url = error as? URLError {
            return url.code == .timedOut ? RenewProblem(.anisetteTimeout) : RenewProblem(.network)
        }
        // Text matches only for the two SideStore-style install errors (no text is shown to the user).
        let text = String(describing: error)
        if text.contains("RwAfc") { return RenewProblem(.tunnelRwAfc) }
        if text.contains("deviceEndpointIp") { return RenewProblem(.deviceEndpointNil) }
        if text.contains("503") { return RenewProblem(.serviceUnavailable503) }
        return RenewProblem(.unknown)
    }
}

// MARK: - Retry rule (B3)

enum RenewRetry {
    /// Anisette timeout / 5xx / all servers failed / URL timeout.
    static let maxRetries = 2
    /// Apple resultCode 1100: meaning not confirmed, so one retry only.
    static let maxRetriesFor1100 = 1
    static let delayNanoseconds: UInt64 = 3_000_000_000

    /// Retry budget for a transient error, nil for everything else (wrong password, -80045, cert mismatch... never retried).
    static func budget(for error: Error) -> Int? {
        if error is RenewAnisette.TimeoutError { return maxRetries }
        if let server = error as? SideSign.ServerError, case .underlyingError(let code, _) = server, code == 1100 {
            return maxRetriesFor1100
        }
        if let anisette = error as? SideSign.AnisetteError {
            switch anisette {
            case .allServersFailed: return maxRetries
            case .badServerResponse(let status, _) where (500...599).contains(status): return maxRetries
            default: return nil
            }
        }
        if let url = error as? URLError, url.code == .timedOut { return maxRetries }
        return nil
    }

    /// `retries` false = one attempt only (Shortcut actions: iOS cuts a background action off at ~25 s).
    static func run<T>(retries: Bool = true, _ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch {
                guard retries, let budget = budget(for: error), attempt < budget else { throw error }
                attempt += 1
                RenewDiagLog.write("retry \(attempt)/\(budget): \(RenewDiagLog.describe(error))")
                // Only the shared manager (uncapped, not-yet-provisioned path) keeps a 30 s cache.
                // The capped path uses a new AnisetteDataManager per request, so it has no cache to clear.
                RenewAnisette.clearCaches()
                try await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }
    }
}
