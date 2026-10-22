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

- v1.0.16 匯入描述檔（已併 main `964e8a5`）：雲端編譯／截圖／測試員／落點全過；🔴 實機 misagent 換描述檔、新描述檔 UUID 與 App 內嵌的不同時 iOS 是否採用，都還沒測（缺新描述檔來源）
- 手機自動化「續 SideStore」（LocalDevVPN `ControlLocalDevVPNIntent` 啟用 → 等 30 秒 → SideStore Refresh All → 打開 SideStore；觸發＝鬧鐘停止）：還沒建、沒測
- 小問題（不擋）：地圖本身的店名／路名會畫在底帶上面、疊到 Legal（17ProMax newPlace、SE simulating）；可考慮讓地圖不在底帶那條顯示 POI
- 測試員小問題（v1.0.14 發現，不擋）：offline 36_shot_back_home 步驟算過但畫面仍在設定頁；novice 28 搜尋結果截圖時還在轉圈；simulating_dark＝light 是 App 寫死深色（GpsSimHomeView:369 等），不是 CI 壞
- v1.0.14/15 實機：拖地圖時 Legal 底帶會不會抖（抖就改 onMapCameraChange(.onEnd)）；上游 DDI 修正後送定位照常
- 🔴 只有他能做：實機長按新增地點、反查地名、4G 流程、權限卡片（要先把定位權限改回「下次詢問」）、手機「每天自動續簽」捷徑跑一次後讀到期日
- 純 4G 時 SideStore 自動續簽能否成功（兩份研究都無法證實）
- ✅ SideStore 登入 Apple ID：**10/18 12:34 成功**（見紀錄）；✅ 10/18 15:04 Wi-Fi 下 SideStore 自己 Refresh 成功（到 10/25）；🔴 還沒測：純 4G 的 Cellular Refresh（TurnOffData／TurnOnData 捷徑）、定位儀自己用 misagent 換描述檔
- 電腦續簽改 Wi-Fi（不插 USB）：iloader 原始碼支援 Network 裝置，未實測；手機當熱點時大概率找不到手機

## 紀錄

### 2026-10-22（17:46～18:01，SHUN，電腦續定位儀＋4G 續 SideStore）
- 研究（5 支 agent：SideStore 原始碼 12ff39c6／上網／定位儀程式／電腦端／挑毛病）：TurnOnData 失敗最可能是 SideStore 被 TurnOffData 擠到背景開不了網址 → 兩個捷徑結尾各加「打開 App：SideStore」
- 17:46 電腦 `resign.ps1`（iloader 裝 GpsSim-app-dd008c9）：✅ 定位儀 10/25 19:15 → **10/29 17:46**；🔴 副作用：**SideStore My Apps 清單裡的定位儀消失**（不再歸 SideStore 管）→ 改由 SideStore 管後別再用 iloader 續；要接回＝Wi-Fi 下 SideStore ＋ 重裝
- 17:52～17:53 他在捷徑 App 給 TurnOffData／TurnOnData 結尾加「打開 SideStore」（截圖確認兩個都只有原本一行＋新一行）
- 17:58～18:00 Refresh All 失敗 4 次：`session has expired (code 1100)`（Apple 登入過期，-1）、`-1009 offline`（上一次關掉的數據還沒開）、`request timed out`
- 18:00:56 再按（4G、LocalDevVPN 已連）：✅ TurnOffData success true → minimuxer ready → **TurnOnData success true**（10/18 是 false）→ SUCCESS，9 秒；SideStore 到 **10/29 18:01**（provision list）。紀錄 `console_20261022_180050_097.log`
- 因此改了什麼：手機捷徑兩個；沒改程式
- 18:09 建自動化「08:20（平日）鬧鐘停止時、立即執行」：Enable LocalDevVPN → 等待 10 秒 → 打開 SideStore → Refresh All Apps。編輯器內按 ▶：18:09:57 refresh 被叫起 ✅、18:10:17 Apple 回 1100 ❌（同一 session 時好時壞，距 18:01 成功只 9 分）→ 自動化步驟有跑到，失敗在 Apple 端
- 還沒測：10/23 08:20 鬧鐘實際觸發；1100 反覆出現是否要重新登入

### 2026-10-18（19:00～19:16，SHUN，捷徑內續簽＋裝 v1.0.17）
- 研究（2 支 agent：SideStore 原始碼＋上網）：捷徑「Refresh All Apps」動作沒有 Cellular Refresh 處理；網路上能自動續簽的配方全在 Wi-Fi 下；4G 從捷徑續簽 0 篇回報
- 19:00 「出門改定位」改成 VPN → 打開 SideStore → 等待 60 秒 → …，他在 SideStore 手動按 Refresh All：✅ 兩個 App 到 **10/25 19:00**（provision list）；❌ 4G 沒回來、捷徑沒往下跑。SideStore 紀錄 `Documents/ConsoleLogs/console_20261018_184801_898.log`：19:00:52 TurnOffData 有開、19:00:53 TurnOnData `Shortcut URL open completed with success: false`（SideStore 不在前景、被外層捷徑擠掉）→ 續簽不能放進正在跑的捷徑
- 19:10 SideStore ＋ 裝 GpsSim-1.0.17.ipa（4G、沒關數據）：❌ `ensureRPConnection() failed because deviceEndpointIp is nil` → `RwAfc`；安裝流程 `isCellularRefreshGroup = false` 不會先跑 TurnOffData，只在最後跑 TurnOnData（所以畫面跳捷徑 App）→ 4G 下「安裝」要先手動關行動數據或連 Wi-Fi
- 19:16 連星巴克 Wi-Fi 再裝：✅ v1.0.17（main `423021a`、tag v1.0.17、IPA 來自 run 39120250089 dd008c9 重新打包）；5 個地點與備份 hash 相同
- v1.0.17 雲端：Screenshots 39120252336 ✅、Testers 39120254890 ✅；新手看截圖找到 3 個下版要改：閒置時透明停止鈕在衛星地圖上看不到、閒置也寫「停止模擬」像在模擬中、最大字級只剩紅方塊；3 種提示沒有截圖；offline 劇本 5 步、novice 2 步失敗（第 10 張白畫面、找不到「進階」「回定位儀」、搜尋無結果）待查
- 還沒測：v1.0.17 實機按紅色停止鈕；捷徑尾端「有 Wi-Fi 才 Refresh All」

### 2026-10-18（17:34，SHUN，定位儀改由 SideStore 管）
- 他決定走「SideStore 管定位儀」路線。先 house_arrest 備份地點 → `C:\Tools\Installers\iOS-StikDebug\places-backup-20261018.json`（5 個）
- 3 支 agent 讀原始碼：SideStore／iloader 都是「原 bundle id＋.team id」、App ID 已存在就沿用、app group＝原 group＋.team id → 和手機現有的一樣
- IPA `GpsSim-app-92bf258.ipa`（v1.0.15）用 `pymobiledevice3 apps push com.SideStore.SideStore.CJA56ZFU6T <ipa> /Documents/GpsSim-1.0.15.ipa` 推進 SideStore 資料夾（`--documents` 參數會 FILE_OPEN 失敗，要用容器路徑 /Documents/）；拉回比對 hash 相同
- 他在 SideStore：＋ → Choose from Files → 我的 iPhone/SideStore → 檔案 → Install
- ✅ 結果：原地更新，bundle id 仍 `com.stik.stikdebug.CJA56ZFU6T`、簽名者不變、**5 個地點與備份逐位元相同**、App IDs Remaining 仍 7、新描述檔到 **10/25 17:34**、group 不變；My Apps 列出 SideStore＋定位儀
- 🔴 推翻舊結論「別用 SideStore＋重裝定位儀（地點會丟）」：只要 IPA bundle id 是 `com.stik.stikdebug`，裝出來就是同一個 App
- 17:39 ✅ 開定位儀：地圖＋5 地點正常；手機無閃退紀錄（crash ls）
- 17:39 ❌ SideStore Refresh All（Wi-Fi＋LocalDevVPN 已連）→「Failed to refresh 2 apps. Your session has expired. Please log in. (-1)」；描述檔沒變。同訊息 GitHub SideStore #1646（10/13 開、無回應）、#1469
- 17:43 ✅ 改定位：Google 地圖藍點到竹北新寮（他說「有移動過去」；用捷徑或 App 內按未確認）
- 17:45 ✅ **把 SideStore 從多工畫面滑掉、重開、Refresh All 一次** → 成功，SideStore＋AltWidget＋定位儀描述檔都到 **10/25 17:45**（電腦讀 provision list 確認）。→ 遇到 session expired 先「滑掉重開再按一次」，不要連按、不要登出
- 18:18～18:21 捷徑改版（在捷徑 App 內按 ▶）：…→ 打開 setlog → 等待返回 → 停止定位 → 結束計時。✅ 回到捷徑後會接著跑、停止定位打勾。🔴 但 Google 地圖退回「台中美光」（18:18 那次沒停的舊模擬）；電腦 `pymobiledevice3 developer dvt simulate-location clear` 後回真實位置 → 修在 v1.0.17（分支 fix/v1.0.17-full-clear `1775b93`：紅色停止鈕永遠顯示＋同通道新開 handle 再清一次、失敗不假成功）
- 18:33 ✅ **純 4G 續簽成功**：Wi-Fi 關、LocalDevVPN 連、SideStore Refresh All → Cellular Refresh 自動跑 TurnOffData（iOS 跳「已關閉行動數據」提醒，按「好」）→ TurnOnData → 兩個 App 都到 **10/25 18:33**（電腦讀 provision list）。中途停在捷徑 App，按左上「◀ SideStore」回去
- 還沒測：戶外純 4G 跑「出門改定位」（在家捷徑會自動連家裡 Wi-Fi，不準）；從主畫面按捷徑時「等待返回」會不會等

### 2026-10-18（傍晚，SHUN，v1.0.16 匯入描述檔）

- 版本：`c1e6de8` → `4c1a462` → `dee831a`，併 main `964e8a5`，tag v1.0.16
- 測什麼：程式審查 3 輪；雲端 Build Debug IPA（第 1 次 39107129745 ❌ iOS 18 才有的 `@Parameter(supportedContentTypes:)`；之後 39107296783、39107528682、main 39107693253 ✅）；main 上 Simulator Screenshots 39107693217 ✅、Simulator Testers 39107693214 ✅、Landing Randomness 39107693192 ✅
- 結果：審查第 1 輪 7 項（權限單向、到期日記錯、背景重啟隧道、裝置訊息、捷徑不丟錯、ProfileView 限制、try? 吞錯）、第 2 輪 5 項（清舊日期、隧道錯誤重置、內嵌只解一次、畫面即時更新、讀回失敗誤報）全修；剩 3 個小問題不擋（讀回斷線下次才重建、開設定頁與匯入同時跑日期偏早、ProfileView 沒 noteTunnelFailure）
- 因此改了什麼：見 CHANGELOG v1.0.16。誤把 `tools/device/_credread.py` 推上公開分支（無密碼），`ea5e099` 移除；之後 agent 一律用各自 worktree、明確 git add
- 手機：10/18 16:00 建好捷徑 `TurnOnData`（開啟）、`TurnOffData`（關閉），16:22 兩個內容都確認；16:27 SideStore 打開 Cellular Refresh（位置：Settings → ADVANCED SETTINGS → User Customizations → 第 4 區 CELLULAR REFRESH；名稱欄預設就是 TurnOnData／TurnOffData，延遲 1.0 秒；EMProxy(WireGuard) 維持關，兩者不能同開）。原始碼依據 UserCustomizationsView.swift:598-612（12ff39c6）。4G 續簽還沒實測

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
