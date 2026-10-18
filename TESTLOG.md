# 測試紀錄（定位儀 App）

每一輪測試記一筆：版本、測了什麼、結果、因此改了什麼。改動細節看 `CHANGELOG.md`，這裡只記「測試」。

**規則（他 2026-10-16 訂）**：每輪測試與更改項目都要記在這裡；**不要重複測試**。
派測試前先看「已測過」表：那一塊程式沒改過就不重測，只測這一版改到的地方。
雲端：公開 fork `Bug1910/StikDebug`（10/16 起重新啟用，不扣額度）。兄弟帳號 `PinFly-ci` 10 月額度已用完。
下載結果一律用小檔 `tester-summary-*`／`screens-summary-*`（每份 1～3 MB）；大檔 artifact 不抓（他用手機熱點）。

## 已測過（程式沒改到就不必重測）

| 範圍 | 最後通過的版本 | 怎麼測的 | 會讓它要重測的改動 |
|---|---|---|---|
| 權限說明卡片（只在未決定時出現、不卡住、捷徑背景不擋） | v1.0.6 | 程式審查 3 輪 | `GpsSimLocationPrimer.swift`、`AlertPresenter.swift`、`BackgroundLocationManager.swift` |
| 3 位雲端測試員劇本（novice／offline／ipad）全步驟 | v1.0.11（127 步 0 失敗） | `sim_testers.yml` | `ci/scenarios/*.json` 用到的按鈕文字或 id 被改 |
| 字級放大、4G 單欄、大字露出下一格、圓鈕不重疊、刪除鈕完整、設定頁捷徑鈕 | v1.0.11 | 截圖逐項驗收 | 主畫面版面、`GpsSimHomeView.swift` 版面區塊 |
| SE 頂部不被推進狀態列、提示卡在地圖與清單之間、4G 收進「看步驟」、送失敗灰色虛線＋提示不重複、設定頁無重複字 | v1.0.13 | 截圖逐項驗收 | 主畫面版面、提示卡、送出流程 |
| 簽名到期讀取與顯示 | v1.0.10 | 程式審查＋實機（設定頁） | `GpsSimSigning.swift` |
| 安裝腳本 `iloader_import.ps1` | 8887310 後實跑 2 次成功 | 實機安裝 v1.0.8、v1.0.10 | iloader 改版、腳本改動 |
| Legal 底帶貼地圖底（全狀態、iPhone／iPad、大字級）、101 圖釘不被搜尋列蓋 | v1.0.15 | 雲端截圖逐張＋與前版並排 | `updateLegalScrim`／`GpsLegalProbe`、地圖或底部面板版面 |
| 一鍵續簽 `resign.ps1`（桌面「定位儀續簽」） | 36bce93，10/16 01:51 實跑成功 | 實機：01:26→01:52 | 腳本改動 |
| 實機：安裝、5 個地點保留、模擬中隨機落點在圈內 | v1.0.10 | 遠端截圖 | 地點存檔格式、送定位流程 |

## 還沒測過（下一輪要測的）

- 小問題（不擋）：地圖本身的店名／路名會畫在底帶上面、疊到 Legal（17ProMax newPlace、SE simulating）；可考慮讓地圖不在底帶那條顯示 POI
- 測試員小問題（v1.0.14 發現，不擋）：offline 36_shot_back_home 步驟算過但畫面仍在設定頁；novice 28 搜尋結果截圖時還在轉圈；simulating_dark＝light 是 App 寫死深色（GpsSimHomeView:369 等），不是 CI 壞
- v1.0.14/15 實機：拖地圖時 Legal 底帶會不會抖（抖就改 onMapCameraChange(.onEnd)）；上游 DDI 修正後送定位照常
- 🔴 只有他能做：實機長按新增地點、反查地名、4G 流程、權限卡片（要先把定位權限改回「下次詢問」）、手機「每天自動續簽」捷徑跑一次後讀到期日
- 純 4G 時 SideStore 自動續簽能否成功（兩份研究都無法證實）
- ✅ SideStore 登入 Apple ID：**10/18 12:34 成功**（見紀錄）；✅ 10/18 15:04 Wi-Fi 下 SideStore 自己 Refresh 成功（到 10/25）；🔴 還沒測：純 4G 的 Cellular Refresh（TurnOffData／TurnOnData 捷徑）、定位儀自己用 misagent 換描述檔
- 電腦續簽改 Wi-Fi（不插 USB）：iloader 原始碼支援 Network 裝置，未實測；手機當熱點時大概率找不到手機

## 紀錄

### 2026-10-18（下午，SHUN，兩個 App 續簽）

- 版本：定位儀 v1.0.15（`92bf258`）；SideStore 0.7.0 沒動
- 測什麼：① 電腦 `resign.ps1` 續定位儀 ② 手機 SideStore 在 Wi-Fi 下 Refresh All（含自動登記裝置）。電腦每 3 秒截手機最新一張（他授權「背景監看」）帶他按
- 結果：① ✅ 定位儀 10/24 02:07 → **10/25 14:54**。② 第一次 ❌「unable to reach the device endpoint … DeviceEndpointNotInitialized」＝LocalDevVPN 是「已中斷連線」；開 LocalDevVPN 按連線（通道 10.7.1.1／裝置 10.7.0.1）→ My Apps 小點紅轉綠 → Refresh All ✅ SideStore 10/21 17:29 → **10/25 15:04**；沒跳登記錯誤；顯示「7 App IDs Remaining」。電腦 `-CheckOnly` 讀手機確認兩個日期
- 因此改了什麼：沒改程式。教訓：SideStore 續簽前先確認 LocalDevVPN「已連線」

### 2026-10-18（中午，SHUN，實機 SideStore 登入）

- 版本：手機 SideStore 0.7.0-20261013.1503+12ff39c6；定位儀 v1.0.15 沒動
- 測什麼：手機上 SideStore 重新登入 Apple（10/12 起全球被擋）。電腦每 5 秒截手機畫面（他授權）＋畫面變化通知，一步步帶
- 做法：伺服器清單選 **#16「SideStore (New)」https://new.ani.sidestore.io**（他手機不是網路說的 #5）、Auto Rotation 關、On-Device Anisette 關 → User Customizations「Reset adi.pb」（沒跳 keep headers，會登出）→ Anisette Client Configuration 裡 10/16 手填的 Windows 字串還在，清空後 Save Overrides 按不下 → 最底「Reset to Defaults」回預設 Mac 字串 → Sign in → 驗證方式 Apple Devices → 本機跳 6 位數 → **Authenticated**
- 結果：✅ 登入成功（Free Developer Account）。❌ 接著「Device Registration Error：No wifi interface satisfied」（只有 4G）→ Skip → 「還沒登記，不能裝或續簽」
- 因此改了什麼：沒改程式。原始碼研究（6 支 agent）：開 Cellular Refresh 會跳過 Wi-Fi 檢查（minimuxer MinimuxerWrapper.swift:202-204）；登記會向 Apple 查清單比對 UDID；SideStore 重裝定位儀＝新 App（地點會丟），定位儀要自己 misagent 換描述檔

### 2026-10-16（凌晨，SHUN）

| 版本 | 測了什麼 | 結果 | 因此改了什麼 |
|---|---|---|---|
| v1.0.1 | 實機安裝（iloader，Apple 登入 -90010 一次，他重登後成功） | ✅ 5 地點在、版本 1.0.1 | — |
| v1.0.2～1.0.6 | M5 權限說明：程式審查 3 輪＋研究 Apple 5.1.1／HIG＋設計審查 | 抓到 3 個卡住路徑、空白訊息、版號混亂 | 1.0.3～1.0.6 逐一修；設計改成底部卡片只留「繼續」 |
| v1.0.6 | 雲端截圖＋測試員；實機安裝 | ✅；實機模擬中落點在圈內 | — |
| 工具 | 安裝腳本審查 3 輪 | 會謊報成功、舊訊息干擾、副檔名 | 1582624 → 8887310 → 32a25b6 |
| v1.0.6 截圖 | 3 位扮演審查（爸爸／本人 4G／無障礙） | 多數決 5 項＋Apple Legal | v1.0.7 |
| v1.0.7 | 程式審查 | 地圖每次提示跳兩下、搜尋時舊尺寸、捷徑失敗無回饋 | v1.0.8 |
| v1.0.8 | 實機安裝 | ✅ | — |
| 研究 | 自動續簽 2 份交叉研究 | SideStore 0.7.0 支援；純 4G 未證實 | 手機捷徑自動化（他建）＋v1.0.9 倒數＋桌面一鍵續簽 |
| v1.0.9 | 程式審查＋雲端截圖＋測試員 | 4G 時簽名提醒永遠被蓋住；小檔 artifact 是空的 | v1.0.10；1ec3257 |
| v1.0.10 | 雲端測試員 127 步 0 失敗；邏輯＋設計回饋；實機用 resign.ps1 安裝 | 5/6 舊項修好；新：大字只剩一格、圓鈕重疊、送失敗像成功等 | v1.0.11 |
| v1.0.11 | 程式審查＋截圖驗收 | 5/7 修好；SE 頂部被推進狀態列、灰圈清除不完整、Legal 仍被蓋 | v1.0.12 |
| v1.0.12 | 程式審查（未編譯：兄弟帳號額度用完） | 4G 換地點失敗沒原因 | v1.0.13 |
| v1.0.13 | 公開 fork 雲端：編譯＋截圖＋測試員（runs 38851030319／38851033190／38851035960） | ✅ 127 步 0 失敗 | — |
| v1.0.13 | 截圖驗收（只驗 v1.0.12／13 改的 6 項） | 4 已修；台北101 圖釘頭被搜尋列蓋一半（17ProMax error）；Legal 在模擬中深色、SE 離線、新手第 39 步仍看不到（360px 縮圖可能太小看不清，待原尺寸確認） | 待下一版 |
| v1.0.13 | 實機：桌面「定位儀續簽」安裝（12:48） | ✅ 版本 1.0.13；簽名 10/23 01:52→10/23 12:48 | — |
| SideStore 自動續簽 | 12:36 讀到期日 | ❌ 仍 10/21 17:29，手機捷徑自動化還沒跑過 | 等他建捷徑並手動跑一次 |

### 2026-10-16（下午，SHUN，星巴克 Wi-Fi，他操作、Claude 每 5 秒截圖監看）

| 範圍 | 測了什麼 | 結果 | 因此改了什麼 |
|---|---|---|---|
| 捷徑「出門改定位」計時 | 加「附加到文字檔案 定位儀計時.txt」（送出／結束＋目前日期，時間格式中）；實跑 2 次 | ✅ 寫入成功；按 ▶ 到定位成功約 10 秒、等他按「完成」約 6 秒、送出→結束 <1 秒；Apple 地圖確認藍點在矽品中工 | 「開始」那行還沒加；備份「出門改定位 1」被他刪掉 |
| 捷徑加 SideStore「Refresh All Apps」 | 實跑 1 次 | ❌ SideStore 沒配對檔（10/14 夜間版轉檔後讀不到） | 下一列 |
| SideStore 配對檔 | 電腦用 AFC 放入：合併檔→「ambiguous」拒收；只留 lockdown→收下但 iOS 26 lockdown 連線 early eof；只留 RemoteRP（同定位儀那份）→ ✅ connection test SUCCEEDED | SideStore 改走 rppairing；PC 暫存的配對檔副本已刪 |
| SideStore 登入 Apple ID | 他登入 2 次 | ❌ GSA -80045（init 階段就拒，未驗密碼）；7 支 agent 查：Apple 10/12 起擋遠端／Android anisette，全球同症狀；SideStore PR #1660 未合併 | 停止重試；續簽暫走電腦 resign.ps1；建議刪捷徑裡 Refresh All Apps 那步 |
| 電腦續簽 | 時間量測（逐字稿）| resign.ps1 全程 35～36 秒（iloader 那段約 21 秒）；今天 12:48 仍成功＝PC 的 iloader 登入沒被擋 | — |
| SideStore 登入（B 方案，只試 1 次） | 關 On-Device Anisette、伺服器選 #19 jkcoxson (Windows ADI)、Client Info／User Agent 改 Windows 值並 Save Overrides、Auto Rotation 關、Reset adi.pb 後登入 1 次 | ❌ Apple 回 503 Service Temporarily Unavailable（init 階段被擋，同 #1652 回報的 503） | 停止重試；續簽維持電腦 resign.ps1；手機上的三個設定值暫存檔已刪 |
| v1.0.14 | 程式審查（code-reviewer×2）：上游 734361b 逐行相同、不碰定位路徑；Legal 底帶 MapPolygon 編譯 OK、抓到跨換日線會整片黑 | ✅ 合併；換日線已修（aa4d899） | main fefa102、tag v1.0.14；Build Debug IPA 成功 |

### 2026-10-17（凌晨，SHUN）

| 版本 | 測了什麼 | 結果 | 因此改了什麼 |
|---|---|---|---|
| v1.0.14 | 雲端測試員 3 位（run 38877840008） | ✅ 127 步 0 失敗 | — |
| v1.0.14 | 截圖驗收（run 38877836214；主對話＋2 位審查員各自看） | ✅ 101 圖釘頭完整在搜尋列下；❌ Legal 底帶浮在地圖底上方，面板越高浮越多（SE error 約 29pt、17ProMax simulating 約 33pt、17ProMax error 約 65pt、iPad error 約 75pt），模擬中 Legal 看不到 | 不裝手機；v1.0.15 改用底層 MKMapView 座標＋面板變高後延遲重算 |
| v1.0.15 | 程式審查（code-reviewer）×2 輪 | 可合併；建議：無效座標過濾、快取地圖 view、依 frame 挑對的地圖、Attribution 高度上限、說明文字更正 | 6d95e75 全部修 |
| v1.0.15 | 雲端測試員 3 位（run 38942533552） | ✅ 127 步 0 失敗 | — |
| v1.0.15 | 實機安裝（resign.ps1，10/17 02:07；第 1 次 NO PICKER，資料夾有 2 個 IPA→舊的移到 old\ 後第 2 次成功） | ✅ 手機讀到 1.0.15「定位儀」；簽名 10/23 12:48→10/24 02:07 | 舊 IPA 收到 Installers\iOS-StikDebug\old\ |
| v1.0.15 | 雲端編譯＋截圖（run 38939778423／38939773898）；主對話看 6 張＋ux-design-lead 看全部 46 張與 v1.0.14 並排 | ✅ 編譯過；底帶在所有狀態（含 iPad、axxxl）貼齊地圖底、Maps＋Legal 在帶上；v1.0.14 的 iPad 白畫面／灰圖這版正常（判定為截圖時機） | 併 main 92bf258、tag v1.0.15、同步 PinFly |
| PinFly | v1.0.7～1.0.14 共 23 版搬到私人 Bug1910/PinFly（commit-tree 照順序重放、作者與時間保留、tag v1.0.7～v1.0.14） | ✅ 最後 tree 563e002 與公開版 main 完全相同；PinFly Actions 仍關 | — |
| 改名 v1.1.0 | 研究 isideload 原始碼＋issue | 改名＝新 App ID（免費帳號每 7 天 10 個）；註冊用 app token 但存檔登入怎麼用沒查清；登入被擋時無人回報成功註冊 | 暫緩，等 10/23 前續簽完或 iloader 登入修好 |
