//
//  PinFlyGuideContent.swift
//  StikDebug (GpsSim fork)
//
//  Text of the in-app 「使用教學」 (Settings > 使用教學). Pure data, no logic.
//  Every button / label quoted here is copied from the real UI strings (GpsSimHomeView,
//  GpsSimSettingsView, GpsSimRenewViews, GpsSimIntents, GpsSimRenewIntents) so the guide never
//  names a control that does not exist. iOS system screens follow Apple's zh-TW wording
//  (support.apple.com/zh-tw/109054, /118254, /105120; developer.apple.com "Enabling Developer Mode").
//  Screenshots are asset names in Assets.xcassets/Guide; a missing image is simply not shown.
//  待補圖 (imageset exists with no image yet; the step shows text only until the file is added):
//    guide_ch1_01…guide_ch8_03 (PinFly screens, CI capture), guide_sys_01 (信任這部電腦),
//    guide_g4_02…guide_g4_09 (行動網路自動續簽 actions 2–9).
//

import Foundation

/// One screenshot. `name` is the asset name (also docs/tutorial/images/<name>.png);
/// `caption` is the VoiceOver description of what the screenshot shows.
struct PinFlyGuideImage: Hashable {
    let name: String
    let caption: String
    /// Where to tap, as fractions of the screenshot (0...1, origin top-left). Drawn as a frame over the image.
    var highlight: PinFlyGuideRect? = nil
}

/// Normalized rectangle (fractions of the image width / height). Plain Doubles so the type stays Hashable.
struct PinFlyGuideRect: Hashable {
    let x: Double
    let y: Double
    let w: Double
    let h: Double
}

/// One numbered action. One step = one action.
struct PinFlyGuideStep: Hashable {
    let text: String
    var image: PinFlyGuideImage? = nil
}

struct PinFlyGuideSection: Hashable {
    let title: String
    let steps: [PinFlyGuideStep]
    var note: String? = nil
}

/// Optional buttons under a chapter. Only destinations that already exist are offered.
enum PinFlyGuideAction: Hashable {
    /// Opens the iOS Settings app (lands on PinFly's page; the person goes back to the top level).
    case systemSettings
    /// Opens the Shortcuts app.
    case shortcutsApp
    /// LocalDevVPN on the App Store.
    case localDevVPNStore
    /// Pushes the existing 「每天自動續簽」 step page.
    case dailyRenewGuide
    /// Pushes the existing 「Apple 帳號與續簽」 page.
    case renewAccount
    /// Re-opens the first-run 「使用引導」 sheet.
    case onboarding
    /// Pushes the 「用電腦安裝 PinFly」 chapter.
    case pcInstallGuide

    var title: String {
        switch self {
        case .systemSettings: return "開啟「設定」App"
        case .shortcutsApp: return "開啟「捷徑」App"
        case .localDevVPNStore: return "前往 App Store 安裝 LocalDevVPN"
        case .dailyRenewGuide: return "前往「每天自動續簽」"
        case .renewAccount: return "前往「Apple 帳號與續簽」"
        case .onboarding: return "開啟使用引導"
        case .pcInstallGuide: return "前往「用電腦安裝 PinFly」"
        }
    }

    var identifier: String {
        switch self {
        case .systemSettings: return "guide.go.systemSettings"
        case .shortcutsApp: return "guide.go.shortcuts"
        case .localDevVPNStore: return "guide.go.localDevVPN"
        case .dailyRenewGuide: return "guide.go.dailyRenew"
        case .renewAccount: return "guide.go.renewAccount"
        case .onboarding: return "guide.go.onboarding"
        case .pcInstallGuide: return "guide.go.pcInstall"
        }
    }
}

struct PinFlyGuideChapter: Identifiable, Hashable {
    let id: String
    let title: String
    let summary: String
    let symbol: String
    /// The single most important sentence, shown first.
    let lead: String
    let sections: [PinFlyGuideSection]
    var actions: [PinFlyGuideAction] = []
}

private func img(_ name: String, _ caption: String) -> PinFlyGuideImage {
    PinFlyGuideImage(name: name, caption: caption)
}

/// Screenshot with a tap target frame; coordinates are fractions of each screenshot, measured on the real captures.
private func img(_ name: String, _ caption: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> PinFlyGuideImage {
    PinFlyGuideImage(name: name, caption: caption, highlight: PinFlyGuideRect(x: x, y: y, w: w, h: h))
}

enum PinFlyGuideContent {
    static let chapters: [PinFlyGuideChapter] = [newPhone, pcInstall, choosePlace, stop, manage, radius, shortcuts, cellularRenew, renew, errors]

    /// How the guide names the computer-side installer. The installer will be replaced by a
    /// PinFly-made one, so no chapter text names a specific tool; change only this line.
    static let pcInstaller = "電腦安裝程式"

    // MARK: 1 從新手機開始

    static let newPhone = PinFlyGuideChapter(
        id: "newphone",
        title: "從新手機開始",
        summary: "新 iPhone 到第一次定位的完整順序",
        symbol: "iphone",
        lead: "請依序完成。第 4 步需要電腦，其餘在 iPhone 上操作。",
        sections: [
            PinFlyGuideSection(title: "安裝前", steps: [
                PinFlyGuideStep(text: "完成 iPhone 初始設定，並登入 Apple ID。"),
                PinFlyGuideStep(text: "連上 Wi-Fi。"),
                PinFlyGuideStep(text: "以可傳輸資料的 USB 線連接電腦，iPhone 出現「信任這部電腦」時點選「信任」，並輸入 iPhone 密碼。",
                                image: img("guide_sys_01", "iPhone 的「信任這部電腦」提示，有「信任」與「不信任」兩個按鈕")),
                PinFlyGuideStep(text: "以\(pcInstaller)安裝 PinFly（見「用電腦安裝 PinFly」）。"),
            ]),
            PinFlyGuideSection(title: "信任開發者", steps: [
                PinFlyGuideStep(text: "開啟「設定」›「一般」，點選「VPN 與裝置管理」。",
                                image: img("guide_sys_12", "「一般」頁面，框出「VPN 與裝置管理」", 0.05, 0.585, 0.90, 0.054)),
                PinFlyGuideStep(text: "有「開發者 App」區塊時，點選安裝時使用的 Apple ID，點選「信任」。",
                                image: img("guide_sys_02", "「VPN 與裝置管理」頁面，此例沒有「開發者 App」區塊")),
            ], note: "「開發者 App」區塊不一定會出現；未出現時略過此步驟。"),
            PinFlyGuideSection(title: "開發者模式", steps: [
                PinFlyGuideStep(text: "開啟「設定」›「隱私權與安全性」，捲到最下方，點選「安全性」區的「開發者模式」。",
                                image: img("guide_sys_04", "「隱私權與安全性」頁面最下方，框出「開發者模式」", 0.05, 0.793, 0.90, 0.049)),
                PinFlyGuideStep(text: "開啟「開發者模式」開關。",
                                image: img("guide_sys_13", "「開發者模式」頁面，框出開關", 0.77, 0.125, 0.14, 0.040)),
                PinFlyGuideStep(text: "在警示中確認重新啟動。"),
                PinFlyGuideStep(text: "開機後解鎖，在警示中確認開啟，並輸入 iPhone 密碼。"),
            ], note: "「開發者模式」要在 iPhone 與電腦配對過，或裝過 PinFly 之後才會出現；找不到時請先完成「安裝前」。"),
            PinFlyGuideSection(title: "LocalDevVPN", steps: [
                PinFlyGuideStep(text: "在 App Store 搜尋「LocalDevVPN」，點選「取得」安裝。",
                                image: img("guide_sys_07", "App Store 的 LocalDevVPN 頁面，框出安裝按鈕（已安裝時改為開啟 App 的按鈕）", 0.37, 0.193, 0.18, 0.038)),
                PinFlyGuideStep(text: "開啟 LocalDevVPN，畫面顯示「已中斷連線」。",
                                image: img("guide_sys_14", "LocalDevVPN 主畫面，框出「已中斷連線」", 0.48, 0.222, 0.30, 0.054)),
                PinFlyGuideStep(text: "點選「連線」。",
                                image: img("guide_sys_14", "LocalDevVPN 主畫面，框出「連線」按鈕", 0.077, 0.482, 0.846, 0.063)),
                PinFlyGuideStep(text: "第一次連線時，iOS 詢問是否加入 VPN 設定，點選「允許」並輸入 iPhone 密碼。"),
                PinFlyGuideStep(text: "確認畫面顯示「已連線」。",
                                image: img("guide_sys_08", "LocalDevVPN 主畫面，框出「已連線」", 0.53, 0.222, 0.24, 0.054)),
            ]),
            PinFlyGuideSection(title: "PinFly", steps: [
                PinFlyGuideStep(text: "在 PinFly 開啟「設定」›「進階」，於「配對檔」點選「匯入配對檔」（已由\(pcInstaller)放置時可略過）。",
                                image: img("guide_ch1_01", "PinFly 設定頁展開「進階」後的「配對檔」區與「匯入配對檔」按鈕")),
                PinFlyGuideStep(text: "依「使用引導」確認每一步皆為「已完成」。",
                                image: img("guide_ch1_02", "PinFly「使用引導」第 1 步畫面")),
            ]),
        ],
        actions: [.pcInstallGuide, .systemSettings, .localDevVPNStore, .onboarding]
    )

    // MARK: 2 用電腦安裝 PinFly

    static let pcInstall = PinFlyGuideChapter(
        id: "pcinstall",
        title: "用電腦安裝 PinFly",
        summary: "登入、選擇裝置、匯入 IPA、簽名安裝",
        symbol: "desktopcomputer",
        lead: "第一次安裝或簽名已過期時，以\(pcInstaller)安裝。重新安裝不會刪除地點。",
        sections: [
            PinFlyGuideSection(title: "準備", steps: [
                PinFlyGuideStep(text: "下載 PinFly 的 .ipa 安裝檔，存到電腦。"),
                PinFlyGuideStep(text: "以可傳輸資料的 USB 線連接 iPhone，出現「信任這部電腦」時點選「信任」。",
                                image: img("guide_sys_01", "iPhone 的「信任這部電腦」提示，有「信任」與「不信任」兩個按鈕")),
            ], note: "請勿更改 .ipa 檔名，也不要解壓縮。"),
            PinFlyGuideSection(title: "安裝", steps: [
                // Screenshot frames measured on the real installer window captures (2026-11-02).
                PinFlyGuideStep(text: "開啟\(pcInstaller)，登入 Apple ID；收到 6 位數驗證碼時輸入。",
                                image: img("guide_pc_01", "\(pcInstaller)的 Apple ID 區，框出「登入」", 0.094, 0.590, 0.292, 0.072)),
                PinFlyGuideStep(text: "在裝置清單選擇以 USB 連接的 iPhone。",
                                image: img("guide_pc_02", "已登入，裝置清單框出已選擇的 iPhone（USB）", 0.381, 0.315, 0.556, 0.088)),
                PinFlyGuideStep(text: "點選「匯入 IPA」。",
                                image: img("guide_pc_03", "安裝區，框出「匯入 IPA」", 0.665, 0.327, 0.271, 0.089)),
                PinFlyGuideStep(text: "選擇 PinFly 的 .ipa 檔，點選「開啟」。",
                                image: img("guide_pc_04", "檔案視窗，框出 PinFly 的 .ipa 檔整列", 0.165, 0.318, 0.545, 0.034)),
                PinFlyGuideStep(text: "等待簽名並安裝，期間保持 USB 連接。",
                                image: img("guide_pc_05", "簽名並安裝的進度畫面")),
                PinFlyGuideStep(text: "顯示完成後，在 iPhone 主畫面找到 PinFly。",
                                image: img("guide_pc_06", "安裝完成，框出已打勾的「簽名並安裝應用程式」", 0.393, 0.499, 0.201, 0.061)),
            ], note: "請使用登入 PinFly 的同一個 Apple ID。登入被拒時請勿連續重試，數小時後再試。"),
            PinFlyGuideSection(title: "第一次安裝後", steps: [
                PinFlyGuideStep(text: "依「從新手機開始」完成「信任開發者」「開發者模式」與「LocalDevVPN」。"),
            ]),
        ]
    )

    // MARK: 3 選擇地點與開始定位

    static let choosePlace = PinFlyGuideChapter(
        id: "place",
        title: "選擇地點與開始定位",
        summary: "搜尋、貼座標或地圖連結、長按地圖",
        symbol: "mappin.and.ellipse",
        lead: "點選首頁下方的地點，即前往該地點。",
        sections: [
            PinFlyGuideSection(title: "搜尋地名", steps: [
                PinFlyGuideStep(text: "點選首頁的「搜尋地點或貼上座標」。",
                                image: img("guide_ch2_01", "PinFly 首頁，標示搜尋欄與下方地點列表")),
                PinFlyGuideStep(text: "輸入地名，例如「台北101」，按鍵盤的搜尋鍵。",
                                image: img("guide_ch2_02", "搜尋「Taipei 101」後的結果列表")),
                PinFlyGuideStep(text: "點選結果，再點選「儲存地點」；不需儲存時點選「僅前往」。",
                                image: img("guide_ch2_03", "點選搜尋結果後出現的地點卡，有「儲存地點」與「僅前往」")),
            ], note: "找不到時，改用英文名稱，或長按地圖新增。"),
            PinFlyGuideSection(title: "貼上座標或地圖連結", steps: [
                PinFlyGuideStep(text: "在搜尋欄貼上「緯度, 經度」，例如 25.0340, 121.5645，按搜尋鍵。",
                                image: img("guide_ch2_04", "貼上台北101座標後出現的地點卡")),
                PinFlyGuideStep(text: "或貼上 Google 地圖、Apple 地圖的分享連結，按搜尋鍵。",
                                image: img("guide_ch2_07", "貼上 Google 地圖連結後出現的地點卡")),
            ], note: "短網址需要網路。座標超出範圍時，請檢查緯度與經度是否填反。"),
            PinFlyGuideSection(title: "長按地圖新增", steps: [
                PinFlyGuideStep(text: "長按目標位置。",
                                image: img("guide_ch2_05", "長按地圖後出現的「新地點」卡片")),
                PinFlyGuideStep(text: "輸入地點名稱，選擇範圍「小」「中」或「大」。"),
                PinFlyGuideStep(text: "點選「儲存地點」；放棄時點選右上角「×」。"),
            ], note: "位置不正確時，按住圖釘拖動至正確位置，或點一下地圖上的正確位置；名稱會依新位置更新，自行輸入的名稱不會被取代。"),
            PinFlyGuideSection(title: "開始定位", steps: [
                PinFlyGuideStep(text: "點選下方地點列表中的地點。",
                                image: img("guide_ch2_06", "模擬中的首頁，地點已標示為目前位置")),
                PinFlyGuideStep(text: "第一次定位時，依提示允許 PinFly 使用位置。"),
            ], note: "也可點選地圖上的圖釘，再點選「前往」；點選「編輯」可在地圖上修改名稱、範圍或拖動位置。首頁出現「尚未配對」「無法連線」時，請見「常見錯誤」。"),
        ]
    )

    // MARK: 4 停止定位

    static let stop = PinFlyGuideChapter(
        id: "stop",
        title: "停止定位",
        summary: "回到真實位置與復原",
        symbol: "stop.circle",
        lead: "點選「停止模擬」即回到真實位置，不會跳出確認視窗。",
        sections: [
            PinFlyGuideSection(title: "停止", steps: [
                PinFlyGuideStep(text: "點選首頁的「停止模擬」。",
                                image: img("guide_ch2_06", "模擬中的首頁，標示「停止模擬」按鈕")),
                PinFlyGuideStep(text: "確認出現「已回到真實位置，地圖約 10 秒內更新」。",
                                image: img("guide_ch3_01", "停止後的提示「已回到真實位置」與「復原」按鈕")),
            ]),
            PinFlyGuideSection(title: "誤觸時", steps: [
                PinFlyGuideStep(text: "10 秒內點選提示上的「復原」。"),
            ], note: "其他 App 的地圖約 10 秒後才顯示真實位置。顯示「停止失敗」時，解鎖手機並確認 LocalDevVPN 已連線，再點選「重試」。"),
        ]
    )

    // MARK: 5 管理地點

    static let manage = PinFlyGuideChapter(
        id: "manage",
        title: "管理地點",
        summary: "編輯、隱藏、刪除、復原、備份",
        symbol: "list.bullet",
        lead: "刪除不需確認；「復原」會保留到下一個動作。",
        sections: [
            PinFlyGuideSection(title: "編輯", steps: [
                PinFlyGuideStep(text: "點選首頁的「管理地點」（清單圖示）。",
                                image: img("guide_ch4_01", "管理地點清單，列出全部地點")),
                PinFlyGuideStep(text: "點選要修改的地點，開啟「編輯地點」。",
                                image: img("guide_ch4_02", "編輯地點頁，有名稱、範圍與刪除地點")),
                PinFlyGuideStep(text: "修改名稱或範圍。"),
                PinFlyGuideStep(text: "需要時展開「更多」，使用「在地圖上隱藏」或「移到地圖中心」。",
                                image: img("guide_ch4_03", "編輯地點頁展開「更多」，顯示「在地圖上隱藏」與「移到地圖中心」")),
                PinFlyGuideStep(text: "點選「完成」儲存。"),
            ], note: "也可長按首頁的地點，選擇「編輯」或「刪除」。"),
            PinFlyGuideSection(title: "刪除與復原", steps: [
                PinFlyGuideStep(text: "在「編輯地點」點選「刪除地點」。"),
                PinFlyGuideStep(text: "誤刪時，點選首頁提示上的「復原」。",
                                image: img("guide_ch4_04", "刪除地點後首頁提示「已刪除」與「復原」按鈕")),
            ]),
            PinFlyGuideSection(title: "備份", steps: [
                PinFlyGuideStep(text: "開啟「設定」›「進階」，於「地點」點選「匯出地點」。",
                                image: img("guide_ch4_05", "設定頁「進階」內的「地點」區，有「匯出地點」與「匯入地點檔」")),
            ], note: "「匯入地點檔」會取代目前所有地點，請先匯出備份。"),
        ]
    )

    // MARK: 6 範圍與位置微飄

    static let radius = PinFlyGuideChapter(
        id: "radius",
        title: "範圍與位置微飄",
        summary: "每次落點與 GPS 飄動",
        symbol: "scope",
        lead: "每次前往地點時，落點會在該地點範圍內隨機選取。",
        sections: [
            PinFlyGuideSection(title: "範圍", steps: [
                PinFlyGuideStep(text: "在「編輯地點」的「範圍」選擇「小」「中」或「大」。",
                                image: img("guide_ch4_02", "編輯地點頁的範圍選項：小、中、大")),
                PinFlyGuideStep(text: "點選「完成」儲存。"),
            ], note: "範圍越大，每次落點差距越大。"),
            PinFlyGuideSection(title: "位置微飄", steps: [
                PinFlyGuideStep(text: "開啟「設定」，切換「位置微飄」。",
                                image: img("guide_ch5_01", "設定頁的「位置微飄」開關")),
            ], note: "開啟時，位置會在落點附近輕微漂移，距離不超過 4 公尺。預設為開啟。"),
        ]
    )

    // MARK: 7 捷徑自動化

    static let shortcuts = PinFlyGuideChapter(
        id: "shortcuts",
        title: "捷徑自動化",
        summary: "每天自動續簽、僅有行動網路時、鎖定時的限制",
        symbol: "square.stack.3d.up",
        lead: "Apple 不允許 App 自行建立自動化，需在「捷徑」App 建立一次。",
        sections: [
            PinFlyGuideSection(title: "每天自動續簽：何時執行", steps: [
                PinFlyGuideStep(text: "開啟「捷徑」App，點選下方「自動化」。"),
                PinFlyGuideStep(text: "點選「新增自動化操作」（已有自動化時點選右上角「＋」）。",
                                image: img("guide_sys_16", "「自動化」頁面，尚無自動化操作")),
                PinFlyGuideStep(text: "點選「特定時間」。",
                                image: img("guide_sys_17", "「個人自動化操作」清單，框出「特定時間」", 0.05, 0.268, 0.90, 0.073)),
                PinFlyGuideStep(text: "將時間設為每天要續簽的時間，例如 8:00。",
                                image: img("guide_sys_18", "「何時」頁面，框出時間選擇器", 0.07, 0.452, 0.86, 0.037)),
                PinFlyGuideStep(text: "在「重複」選「每天」。",
                                image: img("guide_sys_18", "「何時」頁面，框出「每天」", 0.05, 0.659, 0.90, 0.053)),
                PinFlyGuideStep(text: "點選「立即執行」。",
                                image: img("guide_sys_19", "「何時」頁面，框出已勾選的「立即執行」", 0.05, 0.867, 0.90, 0.052)),
                PinFlyGuideStep(text: "點選右上角「下一步」。",
                                image: img("guide_sys_19", "「何時」頁面，框出右上角「下一步」", 0.81, 0.073, 0.15, 0.036)),
            ], note: "選擇「確認後執行」時，每次需點一下通知才會執行；選擇「立即執行」才能在無人操作時自動續簽。"),
            PinFlyGuideSection(title: "每天自動續簽：執行動作", steps: [
                PinFlyGuideStep(text: "點選「新增空白的自動化操作」。",
                                image: img("guide_sys_20", "新增自動化的動作選擇畫面")),
                PinFlyGuideStep(text: "點選下方「搜尋動作」，輸入「LocalDevVPN」。",
                                image: img("guide_sys_21", "空白的編輯頁，下方有「搜尋動作」")),
                PinFlyGuideStep(text: "點選「Enable LocalDevVPN」加入。",
                                image: img("guide_sys_22", "搜尋結果中的 LocalDevVPN 動作")),
                PinFlyGuideStep(text: "再搜尋「等待」，加入後設為 3 秒。",
                                image: img("guide_sys_26", "已加入「等待 3 秒」動作")),
                PinFlyGuideStep(text: "再搜尋「PinFly」，點選「到期前續簽 PinFly」加入，天數保留 3。",
                                image: img("guide_sys_28", "已加入 PinFly 的續簽動作")),
                PinFlyGuideStep(text: "確認三個動作依序為 LocalDevVPN、等待、到期前續簽 PinFly。",
                                image: img("guide_sys_10", "動作編輯頁，框出三個動作", 0.04, 0.140, 0.92, 0.260)),
                PinFlyGuideStep(text: "點選右上角「完成」。",
                                image: img("guide_sys_10", "動作編輯頁，框出右上角「完成」", 0.85, 0.073, 0.11, 0.036)),
            ], note: "「等待 3 秒」讓 LocalDevVPN 完成連線後再續簽。"),
            PinFlyGuideSection(title: "每天自動續簽：確認", steps: [
                PinFlyGuideStep(text: "確認「自動化」顯示「立即執行」，點選右上角「完成」。",
                                image: img("guide_sys_09", "自動化摘要頁，框出右上角「完成」", 0.85, 0.073, 0.11, 0.036)),
                PinFlyGuideStep(text: "確認「自動化」清單出現此項目。",
                                image: img("guide_sys_29", "「自動化」清單，框出每天執行的續簽項目", 0.05, 0.213, 0.90, 0.137)),
            ], note: "也可改選「鬧鐘」觸發，於關閉鬧鐘時執行。"),
            PinFlyGuideSection(title: "僅有行動網路時", steps: [
                PinFlyGuideStep(text: "改依「行動網路自動續簽」建立自動化。"),
            ], note: "上述自動化需要 Wi-Fi。僅有行動網路時，安裝描述檔前需先開啟飛航模式，再開啟 Wi-Fi。"),
            PinFlyGuideSection(title: "首頁捷徑按鈕", steps: [
                PinFlyGuideStep(text: "點選首頁的捷徑圖示，選擇要執行的捷徑或「開啟「捷徑」App」。",
                                image: img("guide_ch6_01", "首頁捷徑按鈕展開的選單")),
            ], note: "按鈕會執行名稱為「出門改定位續簽」「出門改定位」的捷徑，名稱須完全相同。"),
            PinFlyGuideSection(title: "鎖定時的限制", steps: [
                PinFlyGuideStep(text: "收到續簽失敗通知時，開啟 PinFly，點選「立即續簽」。"),
            ], note: "手機鎖定或螢幕關閉時，部分動作（例如「設定行動數據」）可能不執行。"),
        ],
        actions: [.shortcutsApp]
    )

    // MARK: 8 行動網路自動續簽（4G）
    // Measured on iPhone 13, 2026-10-27: 9-step shortcut renewed in 7 s on cellular only.

    static let cellularRenew = PinFlyGuideChapter(
        id: "cellular",
        title: "行動網路自動續簽",
        summary: "僅有行動網路時，每天定時續簽",
        symbol: "antenna.radiowaves.left.and.right",
        lead: "下載與安裝分為兩個動作：下載描述檔可使用行動網路；安裝需經由 LocalDevVPN，須先開啟飛航模式再開啟 Wi-Fi，完成後再恢復行動數據。",
        sections: [
            PinFlyGuideSection(title: "何時執行", steps: [
                PinFlyGuideStep(text: "開啟「捷徑」App，點選下方「自動化」，點選右上角「＋」。",
                                image: img("guide_sys_16", "「自動化」頁面")),
                PinFlyGuideStep(text: "點選「特定時間」。",
                                image: img("guide_sys_17", "「個人自動化操作」清單，框出「特定時間」", 0.05, 0.268, 0.90, 0.073)),
                PinFlyGuideStep(text: "設定每天固定時間，例如 21:00，「重複」選「每天」。",
                                image: img("guide_sys_18", "「何時」頁面，框出「每天」", 0.05, 0.659, 0.90, 0.053)),
                PinFlyGuideStep(text: "點選「立即執行」。",
                                image: img("guide_sys_19", "「何時」頁面，框出已勾選的「立即執行」", 0.05, 0.867, 0.90, 0.052)),
                PinFlyGuideStep(text: "關閉「執行時通知」。"),
                PinFlyGuideStep(text: "點選右上角「下一步」，再點選「新增空白的自動化操作」。",
                                image: img("guide_sys_20", "新增自動化的動作選擇畫面")),
            ], note: "請挑手機通常解鎖使用中的時間。螢幕鎖定時「設定行動數據」不會執行。"),
            PinFlyGuideSection(title: "動作（依序加入 9 個）", steps: [
                PinFlyGuideStep(text: "下載 PinFly 描述檔：「快到期才下載」開啟，「剩幾天算快到期」：3。",
                                image: img("guide_g4_01", "搜尋「下載」，框出「下載 PinFly 描述檔」", 0.05, 0.338, 0.90, 0.054)),
                PinFlyGuideStep(text: "Enable LocalDevVPN：連線 LocalDevVPN。",
                                image: img("guide_g4_02", "已加入 LocalDevVPN 連線動作")),        // 待補圖
                PinFlyGuideStep(text: "設定飛航模式：開啟。",
                                image: img("guide_g4_03", "已加入「設定飛航模式」，設為開啟")),     // 待補圖
                PinFlyGuideStep(text: "設定 Wi-Fi：開啟。",
                                image: img("guide_g4_04", "已加入「設定 Wi-Fi」，設為開啟")),       // 待補圖
                PinFlyGuideStep(text: "PinFly 建立連線。",
                                image: img("guide_g4_05", "已加入 PinFly 的「建立連線」")),          // 待補圖
                PinFlyGuideStep(text: "前往地點：選擇一個固定地點；不需變更位置時可略過此動作。",
                                image: img("guide_g4_06", "已加入「前往地點」，選定一個地點")),    // 待補圖
                PinFlyGuideStep(text: "安裝 PinFly 描述檔。",
                                image: img("guide_g4_07", "已加入「安裝 PinFly 描述檔」")),         // 待補圖
                PinFlyGuideStep(text: "設定飛航模式：關閉。",
                                image: img("guide_g4_08", "已加入「設定飛航模式」，設為關閉")),     // 待補圖
                PinFlyGuideStep(text: "設定行動數據：開啟。",
                                image: img("guide_g4_09", "9 個動作的完整列表")),                   // 待補圖
            ], note: "「前往地點」請勿選擇「每次詢問」，否則無人操作時會停在詢問畫面。簽名剩超過 3 天時不會下載，後續動作照常執行。"),
            PinFlyGuideSection(title: "確認", steps: [
                PinFlyGuideStep(text: "確認動作順序與上方相同，點選右上角「完成」。"),
                PinFlyGuideStep(text: "確認「自動化」清單出現此項目。"),
            ]),
            PinFlyGuideSection(title: "執行後行動網路未恢復", steps: [
                PinFlyGuideStep(text: "解鎖手機，開啟「控制中心」，開啟行動數據。"),
            ], note: "飛航模式已關閉但沒有行動網路時，表示「設定行動數據」在鎖定時未執行。"),
        ],
        actions: [.shortcutsApp]
    )

    // MARK: 9 續簽與簽名到期

    static let renew = PinFlyGuideChapter(
        id: "renew",
        title: "續簽與簽名到期",
        summary: "7 天簽名、立即續簽、自動續簽",
        symbol: "arrow.clockwise",
        lead: "免費 Apple ID 的簽名每 7 天到期，到期後 PinFly 無法開啟。續簽不會刪除地點。",
        sections: [
            PinFlyGuideSection(title: "立即續簽", steps: [
                PinFlyGuideStep(text: "開啟「設定」，於「簽名」查看剩餘天數。",
                                image: img("guide_ch7_01", "設定頁「簽名」區，顯示剩餘時間與「立即續簽」")),
                PinFlyGuideStep(text: "點選「立即續簽」；尚未登入時點選「登入並續簽」。"),
            ]),
            PinFlyGuideSection(title: "自動續簽", steps: [
                PinFlyGuideStep(text: "於「簽名」點選「Apple 帳號與續簽」。",
                                image: img("guide_ch7_02", "「Apple 帳號與續簽」頁，有「自動續簽」開關與續簽紀錄")),
                PinFlyGuideStep(text: "開啟「自動續簽」。"),
            ], note: "開啟後，開啟 PinFly 時若簽名剩不到 3 天即自動續簽，每 6 小時最多 1 次。"),
            PinFlyGuideSection(title: "描述檔尚未安裝", steps: [
                PinFlyGuideStep(text: "畫面顯示「描述檔已下載，尚未安裝」時，關閉行動數據。",
                                image: img("guide_ch7_03", "設定頁「簽名」區顯示「描述檔已下載，尚未安裝」與「安裝描述檔」")),
                PinFlyGuideStep(text: "開啟 LocalDevVPN。"),
                PinFlyGuideStep(text: "點選「安裝描述檔」。"),
                PinFlyGuideStep(text: "安裝完成後重新開啟行動數據。"),
            ]),
        ],
        actions: [.renewAccount]
    )

    // MARK: 10 常見錯誤

    static let errors = PinFlyGuideChapter(
        id: "errors",
        title: "常見錯誤",
        summary: "畫面訊息與處置",
        symbol: "exclamationmark.triangle",
        lead: "先記下畫面文字與錯誤代碼，再依下列處置。請勿連續重試登入。",
        sections: [
            PinFlyGuideSection(title: "定位", steps: [
                PinFlyGuideStep(text: "「尚未配對」：於「設定」›「進階」點選「匯入配對檔」。"),
                PinFlyGuideStep(text: "「無法連線」（錯誤 3、9）：連上 Wi-Fi，開啟 LocalDevVPN，點選「重試」。",
                                image: img("guide_ch8_02", "首頁「無法連線」提示與「重試」按鈕")),
                PinFlyGuideStep(text: "沒有 Wi-Fi：依「設定」›「進階」›「無法連線時」的步驟操作。",
                                image: img("guide_ch8_01", "首頁沒有連上 Wi-Fi 的提示")),
                PinFlyGuideStep(text: "開發者映像未掛載（錯誤 10）：點選首頁的提示列，在設定頁點選「掛載」；第一次需下載約數十 MB。"),
                PinFlyGuideStep(text: "模擬位置無法送至手機（錯誤 11）：解鎖手機後重試。"),
                PinFlyGuideStep(text: "目標 IP 錯誤（錯誤 1）：點選「改回預設」。"),
            ]),
            PinFlyGuideSection(title: "續簽", steps: [
                PinFlyGuideStep(text: "Apple 拒絕此次登入（-80045）：數小時後再試。",
                                image: img("guide_ch8_03", "續簽失敗的提示與建議處置")),
                PinFlyGuideStep(text: "Apple 或驗證伺服器暫時無法使用（503）、Apple 開發者服務回傳錯誤（1100）：數分鐘後再點選「立即續簽」。"),
                PinFlyGuideStep(text: "持續失敗：依「用電腦安裝 PinFly」重新安裝一次。"),
            ], note: "回報問題時請勿附上 Apple ID 密碼、驗證碼或配對檔。"),
        ],
        actions: [.onboarding]
    )
}
