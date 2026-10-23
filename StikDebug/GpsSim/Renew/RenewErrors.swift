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
            return Entry(code: "-80045", title: "Apple 拒絕這次登入",
                         advice: "10/12 起 Apple 擋這類工具登入。隔幾小時再試一次，不要連續重試（連試會被限速）。")
        case .appleRefused80046:
            // Meaning not documented by Apple (未驗證); seen next to -80045 in SideStore reports.
            return Entry(code: "-80046", title: "Apple 拒絕這次登入",
                         advice: "Apple 沒說明原因。隔幾小時再試一次，不要連續重試。")
        case .serviceUnavailable503:
            return Entry(code: "503", title: "Apple 或 anisette 伺服器暫時不能用",
                         advice: "對方伺服器忙或維修中。過一段時間再按一次。")
        case .appleSession1100:
            return Entry(code: "1100", title: "Apple 開發者服務回 1100",
                         advice: "10/22 紀錄：anisette 回應太慢時出現。已自動重試 1 次；還是不行就過幾分鐘再按。")
        case .anisetteTimeout:
            return Entry(code: nil, title: "anisette 伺服器太慢（超過 6 秒）",
                         advice: "主伺服器和備用伺服器都沒及時回應，已自動重試 2 次。換個網路或稍後再試。")
        case .anisetteUnavailable:
            return Entry(code: nil, title: "連不上 anisette 伺服器",
                         advice: "anisette 是讓 Apple 以為這是一台 Mac 的身分資料。稍後再試。")
        case .network:
            return Entry(code: nil, title: "網路不通",
                         advice: "確認手機有網路（Wi-Fi 或 4G）後再試。")
        case .wrongPassword:
            return Entry(code: "-22406", title: "Apple ID 或密碼不對", advice: "重新輸入一次。")
        case .appSpecificPassword:
            return Entry(code: "-20101", title: "這個帳號要用 App 專用密碼",
                         advice: "到 appleid.apple.com 產生 App 專用密碼，用它登入。")
        case .twoFactorFailed:
            return Entry(code: nil, title: "雙重認證沒有完成", advice: "重新登入，收到 6 位數驗證碼後輸入。")
        case .wrongCode:
            return Entry(code: "-21669", title: "驗證碼不對", advice: "再輸入一次收到的 6 位數。")
        case .tooManyAttempts:
            return Entry(code: "-21668", title: "嘗試次數太多", advice: "Apple 暫時不讓再試，等幾小時。")
        case .notSignedIn:
            return Entry(code: nil, title: "還沒登入 Apple ID", advice: "先在續簽頁登入一次。")
        case .sessionExpired:
            return Entry(code: nil, title: "登入已過期", advice: "重新登入一次（要再收一次驗證碼）。")
        case .signInInProgress:
            return Entry(code: nil, title: "登入還在進行中", advice: "先完成或取消目前的登入。")
        case .cancelled:
            return Entry(code: nil, title: "已取消", advice: "需要時再重新開始。")
        case .teamMismatch:
            return Entry(code: nil, title: "這個 Apple ID 不是簽這個 App 的帳號",
                         advice: "請用當初簽PinFly的 Apple ID 登入。什麼都沒有改動。")
        case .appIDMissing:
            return Entry(code: nil, title: "Apple 帳號裡找不到PinFly的 App ID",
                         advice: "為了不多吃 App ID，這裡不會新建。請用電腦續簽一次。")
        case .certMismatch:
            return Entry(code: nil, title: "新描述檔的簽名憑證和 App 現在用的不同",
                         advice: "換了 App 會打不開，所以已停止，什麼都沒裝。請用電腦續簽。")
        case .profileNotNewer:
            return Entry(code: nil, title: "沒有比較新的描述檔", advice: "目前的簽名已經是最新的。")
        case .tunnelRwAfc:
            return Entry(code: "RwAfc", title: "手機的本機連線沒通",
                         advice: "連上 Wi-Fi 並打開 LocalDevVPN 後再試（只有 4G 不行）。")
        case .deviceEndpointNil:
            return Entry(code: "deviceEndpointIp nil", title: "拿不到手機自己的連線位址",
                         advice: "只有 4G 時會這樣。連上 Wi-Fi 並打開 LocalDevVPN 後再試。")
        case .needTunnel:
            return Entry(code: nil, title: "需要 Wi-Fi 和 LocalDevVPN",
                         advice: "連上 Wi-Fi 並打開 LocalDevVPN 後再試（只有 4G 不行）。")
        case .install:
            return Entry(code: nil, title: "描述檔沒有裝上", advice: "什麼都沒換掉。稍後再試。")
        case .keychain:
            return Entry(code: "keychain", title: "登入成功，但存不了登入資料",
                         advice: "這支手機不讓PinFly把登入資料存進鑰匙圈（Keychain）。請重新安裝PinFly後再試。")
        case .unknown:
            return Entry(code: nil, title: "續簽失敗", advice: "稍後再試；一直失敗就用電腦續簽。")
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

    static func run<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch {
                guard let budget = budget(for: error), attempt < budget else { throw error }
                attempt += 1
                // Only the shared manager (uncapped, not-yet-provisioned path) keeps a 30 s cache.
                // The capped path uses a new AnisetteDataManager per request, so it has no cache to clear.
                RenewAnisette.clearCaches()
                try await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }
    }
}
