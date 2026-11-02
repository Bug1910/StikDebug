# 規格：模擬移動（路線／直線）

> 畫面用語（使用者定案，文件內一律照此）：瞬間到達「前往」；移動按鈕「移動」；卡片標題「模擬移動」；移動方式「路線」「直線」；交通方式「步行」「單車」「駕車」「自訂」；單車註記「沿步行路線」；控制「暫停」「繼續」「結束移動」「停止模擬」；「原地漫步」；狀態提示「已抵達」「已暫停」「已改為直線」；行程「開始行程」「停止行程」。功能名稱＝「模擬移動」。

狀態：規格草案，尚未實作。要等「拖動圖釘／點圖釘跳出編輯、前往」那位設計師做完 GpsSimHomeView.swift 後才動工（同一批檔案，避免衝突）。
日期：2026-11-02　分支：public-release

## 1. 現況（讀碼結論）

| 項目 | 現況 | 出處 |
|---|---|---|
| 送座標 | `simulate_location(ip, lat, lon, pairing)` 經序列佇列 `LocationSimulationCommandQueue`；底層 `location_simulation_set`（已開著就只送一次 set，很輕） | IdeviceFFIBridge.swift:803 |
| 頻率 | `LocationSimulationSession` 的 4 秒 Timer，每跳 `GpsSimEngine.resendTick()` | LocationSimulationSession.swift:28 |
| 位置微飄 | 有。每跳在 landing 周圍 `GpsGeo.jitter`（4 公尺）內隨機，可關（driftKey） | GpsSimEngine.swift:338 |
| 背景 | Info.plist 有 audio、location；`BackgroundAudioManager`＋`BackgroundLocationManager` 在 session.start 時開；`beginBackgroundTask` 輔助 | Info.plist:36 |
| 既有路線播放 | 上游 StikDebug 的 `MapSelectionView` 已有完整做法：MKDirections(.automobile)→每 10 公尺取樣→每 0.5 秒送一點→失敗退回原地。PinFly 首頁沒用這個 View（只有註解提到），可借用演算法不借用畫面 | MapSelectionView.swift:103/306/1374/1593 |
| `LocationSimulationSession.startRoute/routeCoordinates/isCurrentRoute` | 已存在可直接用，放路線線條與「目前是哪一次路線」的世代 ID | Session:33 |

結論：**可以固定頻率連續送**。上游已證明 0.5 秒一點可行，本功能取 **1 秒一點**（夠順、省電、避開佇列塞車）。移動期間必須暫停 4 秒重送與微飄，由移動器自己每秒送；抵達後把終點交回既有 4 秒微飄流程。

## 2. 同類產品做法（搜尋結果有限，標註可信度）

| 產品 | 查到的 | 可信度 |
|---|---|---|
| EaseUS MobiAnyGo（AnyGo 系） | 兩點／多點模式；步行、單車、駕車三種速度；可設來回次數；多點可「首尾 50 公尺內問是否封閉路線」 | 官方說明文字，中 |
| AnyGo／iAnyGo | 速度滑桿、「擬真模式」（速度自然起伏）、搖桿 | 只有二手轉述，低 |
| iTools、3uTools、LocaChange | 本次搜尋未取得可核實內容 | 待驗證，規格不依賴它們 |
| 暫停／繼續、km/h 預設值 | 本次沒找到任何來源寫明 | 待驗證，以下數值為本規格自訂 |

通用 UX（取交集）：①先選起點終點→②選步行／單車／駕車／自訂→③地圖畫路徑→④開始、暫停、停止→⑤速度略有起伏才像真人。PinFly 要比它們簡單：只做「現在位置→一個地點」，多點與來回列為第二版。

## 3. 規格

### 3.1 出發點
- 正在模擬：用 `engine.current`（最近送出的點）。
- 沒在模擬：用真實位置（`CLLocationManager` 單次取得；取不到就提示「請先定位到一個起點」，不猜）。
- 不做「自選起點」（第二版）。

### 3.2 速度預設（km/h）
| 模式 | 預設 | 滑桿範圍 | 路線規劃用的 MKDirections 類型 |
|---|---|---|---|
| 步行 | 5 | 1–8 | walking |
| 單車 | 15 | 8–30 | walking（MapKit 沒有穩定的單車路線，⚠️ iOS 26 是否新增待驗證；先「沿步行路線」） |
| 駕車 | 40 | 20–120 | automobile |
- 滑桿可微調；記住上次選擇（UserDefaults）。
- 擬真：每秒速度在設定值 ±8% 內緩慢起伏（低通濾波，不是白噪音）；直線模式與路線模式同樣套用。開關放在設定頁，預設開。
- 長距離警告：預估 > 12 小時，開始前確認一次。

### 3.3 路線 vs 直線
- 使用者選「路線」或「直線」。
- 選「路線」但 MKDirections 失敗、逾時（8 秒）、無網路、無可行路線 → **自動改直線**，toast「已改為直線」，並在進度卡標「直線」。
- 4G 流程（飛航＋Wi-Fi）下多半沒網路，所以直線是常態備援，不是錯誤，不跳紅色橫幅。
- 直線：起終點之間線性內插（< 500 km 誤差可忽略）。路線：MKPolyline 座標、每 10 公尺重新取樣（沿用上游常數）。
- 播放依「已走距離」計算位置（距離 = ∫ 速度 dt，用 wall-clock 時間差），不是依第幾跳，避免背景計時器被延遲造成累積誤差。

### 3.4 畫面
- 入口：現有「前往」旁加「移動」按鈕（與設計師協調，放在其點圖釘跳出的卡片裡）。
- 「移動」開啟底部「模擬移動」卡片：兩段選擇「路線｜直線」＋速度三顆預設（步行／單車／駕車／自訂）＋預估距離與時間＋「開始」。
- 地圖：虛線畫預覽路徑（起點到終點）；移動中已走的部分實線、未走的虛線，藍點沿線移動並跟隨（可關跟隨）。
- 移動中：頂部或底部進度卡：進度條、已走／總距離、剩餘時間、目前速度、〔暫停／繼續〕〔結束移動〕。
- 「結束移動」＝停在目前位置、**保持模擬**（既有微飄繼續）。既有紅色「停止模擬」仍是回真實位置，兩者並存、文案要區分。
- 抵達：toast「已抵達 <名稱>」＋輕觸覺；停在終點（若終點是已存地點，使用 `GpsGeo.sampleLanding` 的圓內落點，與「前往」一致）；不來回。
- 中途又點別的地點「前往」→ 先取消移動再瞬移（沿用既有行為，不彈確認）；點「模擬移動」→ 以目前位置為新起點重新規劃。

### 3.5 中斷處理
| 情況 | 處理 |
|---|---|
| 連續 3 次送失敗（code 3/9：斷線） | 自動暫停，進度卡顯示「連線中斷，連上後自動繼續」；每 4 秒探測一次，成功即從原本已走距離繼續（時鐘不計暫停期間）；沿用既有 `connectionLost` 語意，不報紅色錯誤 |
| 失敗 code 11（手機鎖屏拒收） | 同上暫停，提示「請解鎖手機」 |
| App 被系統殺掉 | 手機保留最後一點（與現行一致），重開顯示「上次定位」；v1 不續跑（第二版可存 {終點、已走距離、速度} 續走） |
| 使用者手動暫停 | 停止送點、保持最後一點、微飄繼續（避免位置凍結得太「死」） |
| 抵達前使用者按停止模擬 | 取消移動並照既有 stop() 流程 |

### 3.6 背景與鎖屏
- 現有 audio＋location 背景模式與 4 秒 Timer 已能在鎖屏維持（使用者日常使用的前提）。移動器沿用同一個 session（`session.start`／`startRoute`）與 `beginBackgroundTask`，**不新增權限**。
- 計時用主執行緒 `Timer`（`.common`）或 DispatchSourceTimer，與現有一致；不用 `Task.sleep` 迴圈（上游用它，背景時較易被延後）。
- ⚠️ 待實機驗證：1 秒頻率鎖屏 30 分鐘是否不掉點、耗電；需驗收項。
- 手機鎖屏時 DVT 可能拒收（code 11）→ 見 3.5。

### 3.7 捷徑動作
> 已由第 12 節取代：不新增 `MoveToPlaceIntent`，改為在既有「前往地點」（`SendToPlaceIntent`）加「方式」等參數。以下為原草案，僅供參考。

新增 **「移動到地點」**（`MoveToPlaceIntent`）：參數＝地點、方式（路線／直線，預設路線）、速度（步行／單車／駕車，預設步行）。動作「開始後立刻回傳」，不等抵達（捷徑執行時限約 30 秒）。回傳 `GpsSimStatusEntity`（目前狀態）。另可選第二個動作「結束移動」（停在原地）；第一版先不做，只做上述一個。受限：僅在連線與 LocalDevVPN 已就緒時有用，與既有「定位到地點」相同。⚠️ 背景執行時 MKDirections 在 intent 內是否可呼叫待驗證，不行就在 intent 內固定走直線並於說明寫明。

## 4. 實作清單

| 檔案 | 動作 |
|---|---|
| `StikDebug/GpsSim/GpsSimRoutePlanner.swift`（新） | `MKDirections` 包裝＋純幾何：取樣、累積距離、依距離取座標。純函式，易單元測試 |
| `StikDebug/GpsSim/GpsSimRouteMover.swift`（新） | `@MainActor` 狀態機＋1 Hz 計時＋送點＋暫停續行 |
| `StikDebug/GpsSim/GpsSimEngine.swift` | 新增 `sendMoveStep(_:)`（只送一點、不動 landing）、`beginMove()`／`endMove(at:)`（暫停 resendTick、結束後 landing=抵達點再 startTimer）；`resendTick` 在移動中直接 return |
| `StikDebug/GpsSim/GpsSimHomeView.swift` | 「移動」按鈕、`GpsMoveSheet`、進度卡、地圖 polyline／已走線（⚠️ 與設計師衝突，最後做） |
| `StikDebug/GpsSim/GpsSimIntents.swift` | `MoveToPlaceIntent`（＋AppShortcut 註冊） |
| `StikDebug/Services/LocationSimulationSession.swift` | 基本不動，沿用 `startRoute/routeCoordinates/isCurrentRoute` |
| `StikDebug/GpsSim/GpsSimSettingsView.swift` | 「擬真速度起伏」開關、速度預設 |
| `StikDebugTests/`（新）`RoutePlannerTests.swift` | 取樣、依距離內插、直線、速度積分 |
| 本地化字串、`TESTLOG.md`、`CHANGELOG.md` | 更新 |

新型別：`MoveMode { route, line }`、`MoveSpeedPreset { walk, bike, drive }`（含 km/h）、`MovePlan { path, cumulative, totalMeters, mode, fellBackToLine }`、`MoveState { idle, planning, moving, paused(reason), arrived }`、`GpsSimRouteMover`、`GpsSimRoutePlanner`、`MoveToPlaceIntent`。

## 5. 風險

| 風險 | 說明／對策 |
|---|---|
| 與設計師同檔衝突 | 等對方 commit 後再動 HomeView；Planner／Mover／Engine 可先做（不碰 HomeView） |
| 微飄與移動互打 | 移動中停用 resendTick；抵達才恢復，否則藍點會被拉回 |
| 送點佇列塞車 | 序列佇列，1 Hz 夠輕；若上一點尚未完成就跳過本跳（不堆積） |
| 鎖屏／背景掉點 | 以 wall-clock 距離積分；實機長測 |
| MKDirections 限流或無網路 | 8 秒逾時＋自動直線 |
| 單車路線借步行 | 會走行人路、不一定合法騎行；UI 標「沿步行路線」 |
| 超長直線（跨海） | 預估時間警告；直線不代表可行 |
| 被其他 App 偵測瞬移／速度異常 | 擬真起伏＋連續送點已降低；不承諾 |
| 4G 流程中途開飛航 | 見 3.5，自動暫停續行 |
| 測試環境 | 模擬器無 DVT；單元測試覆蓋幾何，路線與背景只能實機（遵守 PinFly 只派模擬真實使用者的測試員） |

## 6. 工時估計（單人，含自測）

| 項目 | 天 |
|---|---|
| Planner＋單元測試 | 0.5 |
| Mover 狀態機＋Engine 掛鉤 | 1.5 |
| HomeView UI（卡片、地圖線、進度、停止） | 1.5 |
| 捷徑動作 | 0.5 |
| 設定頁、字串、文件 | 0.5 |
| 審查修正＋實機驗收（鎖屏、4G、斷線） | 1 |
| 合計 | 約 5.5 天（可分兩段：先引擎＋直線 3 天，再路線＋UI＋捷徑） |

## 7. 待使用者拍板
1. 單車「沿步行路線」可以嗎（推薦：可以，UI 標註）。
2. 「結束移動」停在原地保持模擬（推薦）還是直接回真實位置。
3. 第二版再做：來回、多點、搖桿、續跑（推薦先不做）。

## 8. 研究員補充（2026-11-02，以下與前文衝突時以本節為準）

出處由研究員提供，本規格作者未獨立核實。

| 來源 | 內容 | 對本規格的影響 |
|---|---|---|
| AnyGo（https://itoolab.com/gps-location-changer/） | 速度範圍 3.6～100 km/h；有暫停、繼續；可設重複圈數 | 保留步行／單車／駕車三段預設，另加「自訂速度」滑桿，範圍改為 3.6～100 km/h（取代 3.2 表內各模式滑桿範圍）；圈數屬來回，列 v2 |
| iMyFone AnyTo | 兩點模式只走道路；多點模式不受道路限制 | 與本規格「路線／直線」切換同一概念，不用改 |
| Dr.Fone | 「Pause」「Clear 回原位」「Move Here」是分開按鈕 | 移動中畫面做 3 個獨立按鈕：「暫停／繼續」、「結束移動（停在原地，保持模擬）」、「停止模擬（回真實位置）」。三者各自一顆、文案與顏色清楚區分（停止模擬維持紅色），不合併成單一按鈕或選單 |

開放問題：「到終點就停」或「兩點之間來回走」尚待使用者回答。**v1 預設先做「到終點就停」，來回（含重複圈數）列入 v2 清單**（與 3.4、第 7 節一致）。

## 9. 原地漫步（使用者新增需求：「自動行進，讓手機以為在走路」）

### 9.1 行為
- 範圍：以目前模擬地點的圓心為中心，分 小 30 公尺／中 100 公尺／大 300 公尺三檔；實際半徑取「檔位」與「該地點自身圈半徑（`GpsGeo.radius(of:)`，5～5000 公尺）」較小者，所以永遠不會走出使用者畫的圈。若目前是地圖點／搜尋結果（沒有地點圈），以落點為圓心用檔位半徑。
- 速度：步行 4～5 km/h（中心 4.5），每段隨機起伏 ±20%（每段取一次目標速度，段內以低通濾波平滑變化，避免每秒跳變）。
- 走法：在圈內均勻隨機挑目標點 → 走到 → 停 3～15 秒（隨機）→ 再挑。新目標需與「上一段方向」夾角小於 120 度（不折返），且距目前位置至少為半徑的 25%（避免原地抖）；連續 5 次挑不到就放寬條件。
- 停留時照常每秒送點（位置固定，由 GPS 噪聲式 ±1 公尺小抖動即可，不用 4 公尺微飄）。
- 與微飄互斥：漫步開著就停用 `resendTick` 的 jitter（和「模擬移動」移動中一樣）；關閉漫步時恢復微飄，落點用當下位置。

### 9.2 開關與記憶
- 位置：模擬狀態列旁一顆「原地漫步」開關＋小／中／大三段（點開展開），地點卡片只顯示狀態小圖示。與「模擬移動」同一塊 UI 區域，注意與設計師的圖釘卡片協調。
- 建議：**記住上次的檔位，但不記住開關**（預設每次新定位都是關）。理由：自動行走會耗電、且使用者可能忘了開著；開關預設開會讓人驚訝，違背「定位後位置就在那」的預期。可在設定頁加「定位後自動漫步」選項（預設關）給想要的人。
- 漫步中再按「前往」其他地點＝取消漫步並瞬移，與 3.4 一致；「結束移動」「停止模擬」按鈕語意同第 8 節三按鈕。

### 9.3 與「模擬移動」共用引擎
- `GpsSimRouteMover` 的 `MoveMode` 加 `.wander`（`{ route, line, wander }`）；`MovePlan` 的 path 由漫步規劃器每段動態產生（一段＝兩點直線），播放、暫停、斷線續行、1 Hz 送點全部沿用。
- 新增 `GpsSimWanderPlanner`（純函式：給圓心、半徑、上一段方向、亂數源，回傳下一目標與停留秒數；亂數源可注入以便單元測試）。
- 選項「抵達後自動漫步」（預設關，放在「模擬移動」卡片與設定頁）：打開時抵達終點的 `arrived` 狀態轉成 `.wander`，圓心＝終點、範圍檔位沿用上次。關閉則維持 v1「到終點就停」。
- `MoveState` 新增 `wandering(waiting: Bool)`（走路中／停留中）；進度卡漫步時改顯示「漫步中・剩餘停留 N 秒」，不顯示進度條。

### 9.4 捷徑
> 已由第 12 節取代：不加布林參數，改為「方式＝原地漫步」與「抵達後＝原地漫步」。以下為原草案。

「定位到地點」（`SendToPlaceIntent`）新增布林參數「原地漫步」，預設關閉；開啟時定位成功後立即以預設檔位開始漫步，沿用上次記住的檔位。回傳狀態實體加欄位「漫步中」。與「移動到地點」可組合：加「抵達後漫步」參數（預設關）。

### 9.5 風險（新增）
| 風險 | 說明／對策 |
|---|---|
| 鎖屏長時間 1 Hz 送點的耗電 | 持續 audio 背景＋每秒一次 DVT 呼叫，預期比現行 4 秒一次耗電高；對策：停留階段降為 2 秒一次（位置不變，節流）；設定頁顯示「漫步會增加耗電」；實機量測 30 分鐘、2 小時兩種電量曲線（待實測，未知） |
| iOS 背景限制 | 依賴 audio 與 location 背景模式維持行程；系統記憶體吃緊或音訊被其他 App 搶走時可能被暫停。對策：用 wall-clock 位置積分，恢復時補到正確位置；超過 60 秒沒送成功就轉「暫停」並提示（沿用 3.5 斷線處理）。⚠️ 長時間（>1 小時）鎖屏是否穩定待實機驗證 |
| 「像真人」程度 | 只是位置軌跡；不模擬加速度計／計步器／羅盤，遇到會交叉比對感測器的 App 仍可能被判斷為假。不承諾 |
| 與圖釘卡片衝突 | 同 HomeView，維持「最後才動 UI」 |
| 使用者忘了關 | 漫步中狀態列常駐顯示；預設不記住開關；可選「漫步 N 小時後自動停止」（建議預設 4 小時，⚠️ 待使用者決定） |

### 9.6 工時更新
| 項目 | 原估 | 新估 |
|---|---|---|
| Planner＋單元測試 | 0.5 | 0.5 |
| Mover 狀態機＋Engine 掛鉤 | 1.5 | 1.5 |
| 漫步規劃器（`GpsSimWanderPlanner`）＋測試 | — | 0.5 |
| Mover 加 `.wander`、停留、抵達接漫步 | — | 0.5 |
| HomeView UI（含漫步開關三檔、進度卡） | 1.5 | 2.0 |
| 捷徑（移動到地點＋定位到地點加漫步參數） | 0.5 | 0.75 |
| 設定頁、字串、文件 | 0.5 | 0.5 |
| 審查修正＋實機驗收（鎖屏、4G、斷線、漫步耗電） | 1 | 1.5 |
| 合計 | 5.5 | 約 8 天 |

建議分三段：①引擎＋直線＋漫步規劃器（約 3.5 天）→ ②路線＋UI（約 2.5 天）→ ③捷徑＋實機長測（約 2 天）。

## 10. 預排行程（使用者原話：「自動行進是我預先規劃好，某個時間點我會在那邊，使用手機模擬動態，我移動時手機的感測」）

目的：事先排好「幾點在哪、幾點開始走去哪」，時間到手機自動照做，GPS 軌跡看起來像真的在移動。

### 10.1 行程表資料
行程＝多個「時段」依序排列，每段是下列三種之一：

| 時段類型 | 欄位 |
|---|---|
| 停留 | 地點 X、是否漫步（沿用第 9 節，檔位小／中／大） |
| 移動 | 起點 X（預設＝上一段終點）、終點 Y、路線或直線、速度（三段預設或自訂 3.6～100 km/h） |
| 停止模擬 | 無（回真實位置） |

- 開始時間二選一：**絕對時間**（如 14:30，可含日期）或 **接續上一段**（上一段結束即開始；「停留」段需再填停留多久，「移動」段結束於抵達）。第一段必須是絕對時間或「按開始行程的當下」。
- 資料型別：`Itinerary { id, name, segments: [ItinSegment] }`、`ItinSegment { kind(stay/move/stop), start(absolute(Date)/chained), duration?, place, wander, moveMode, speed }`；存 UserDefaults/JSON（與 GpsPlaceStore 同風格），上限 20 段。
- 編輯時就算出「預估每段實際開始／結束時間」，並檢查衝突：移動預估時間超過下一段絕對開始時間 → 紅字警告「走不到」，仍允許存（下一段到點強制接手）。

### 10.2 執行與時鐘校正
- 執行器 `GpsSimItineraryRunner`（`@MainActor`），建立在 `GpsSimRouteMover` 之上：把行程展開成「時間軸」（每段的起訖 wall-clock 與位置函式），**位置永遠由「現在時間」查表算出**，不依賴累積的跳數。
- 時間到自動切段；不使用逐秒倒數，而用 1 Hz 計時器（沿用 Mover）檢查「現在落在哪一段」。
- 補跑：App 被暫停後恢復、或開始行程時已經過了某些時段，直接從「現在應該在的位置」接上——落在移動段就算出沿路線已走距離，落在停留段就在該點，已全過就執行最後一段（若最後是停止模擬就停止）。「晚了」的上限：晚太久（超過整個行程）則提示「行程已結束」不執行。
- 手機時鐘：用系統時間（`Date()`）。時區變動或使用者手動調時間時，時間軸以絕對時間為準重新定位；偵測時鐘大幅跳動（>5 分）時 toast 提示。
- 移動段路線規劃：開始行程時（有網路）預先為所有移動段算好路徑並快取；任何一段失敗自動改直線並標記。鎖屏或沒網路時不依賴即時規劃。⚠️ MKDirections 能否在背景執行待驗證，所以「開始行程」一律在前景先規劃完才進入執行。

### 10.3 觸發方式
1. App 內「行程」頁按「開始行程」（立即照表跑；若第一段是未來的絕對時間，則進入「待命」狀態，到點才開始）。
2. 捷徑動作「開始行程」（`StartItineraryIntent`，參數＝行程）：可掛在 iOS「特定時間」自動化。動作開 App（`openAppWhenRun`）→ 前景規劃路徑 → 回傳。⚠️ 自動化時手機若鎖屏，iOS 可能要求解鎖才能開 App（實機已知類似限制見 TESTLOG 10/27 捷徑「設定行動數據」鎖屏不跑），需實測。
3. 另提供捷徑動作「停止行程」（停在原地，不回真實位置）。

### 10.4 前景執行（使用者已決定：「預排行程會提醒使用者開著手機」；本小節取代下方原兩案比較，原比較僅留作 v2 參考）

v1 採**前景執行**：
1. 行程執行中 PinFly 必須在前景，並設 `UIApplication.shared.isIdleTimerDisabled = true`（螢幕不自動鎖）；行程結束、停止、暫停都要還原為 false。
2. 提醒三個時間點：
   - **開始前**：按「開始行程」跳出提示「行程進行中請保持 PinFly 開啟、螢幕亮著、接上電源」，使用者點選「開始」才開始（「知道了」為禁用語，見用語規範 3.6）。
   - **每段開始前 N 分鐘**：本機通知（`UNUserNotificationCenter`，需通知權限，第一次按「開始行程」時才請求）；N 預設 5 分鐘，設定頁可調（1～30）。已在前景時不重複發。
   - **執行中被切背景或鎖屏**：偵測 `scenePhase`／`UIApplication.didEnterBackgroundNotification`，立刻發通知「行程已暫停，請回到 PinFly」。回前景後依時間軸從「現在應在的位置」接著跑（沿用 10.2 補位）。背景期間不主動送點。
3. 背景續跑（audio＋location 背景模式、鎖屏照跑）列為 **v2 待評估**，下方原比較保留供評估。
4. 副作用：螢幕常亮＋每秒送點，耗電仍高，故要求接電源（⚠️ 耗電數字未實測）。被切背景期間手機停在最後一點，回前景後會瞬移補位（速度尖峰），畫面需寫明「保持開啟才會像真的在走」。
5. 通知文案只用行程名稱與地點名稱，不含其他個資。

#### （v2 參考）原兩案比較

| | 方案 A：鎖屏照跑（推薦做成可選，預設 A） | 方案 B：鎖屏就暫停，解鎖補位 |
|---|---|---|
| 做法 | 沿用現有 audio＋location 背景模式，鎖屏每秒送點 | 鎖屏或進背景時停止送點（手機停在最後一點）；回前景時用時間軸補到「現在應在位置」 |
| 耗電 | 最高：持續音訊會話＋每秒一次 DVT 呼叫＋定位背景。預估比現行 4 秒一次明顯多，**未實測、數字未知**；停留段降為 2 秒一次可省 | 低：鎖屏期間幾乎不耗 |
| 軌跡品質 | 連續，外界看到的速度、路徑接近真實 | 鎖屏期間位置不動，解鎖時瞬移到新位置，速度出現尖峰，**不像在走路**；與使用者目的（「移動時手機的感測」）相衝 |
| 風險 | iOS 背景被系統暫停／音訊被搶走→掉點；>1 小時長時間穩定性待實機驗證；手機鎖屏時 DVT 可能回 code 11 拒收（已知現象） | 實質等於放棄「預先排好、人不用碰手機」的目的 |
| 建議 | 預設 A；設定頁提供「省電模式（B）」開關；行程頁顯示預估耗電警語 | 僅作為使用者嫌耗電時的選項 |

兩案都要做：斷線（連續 3 次失敗）時暫停並在連上後依時間軸補位（沿用 3.5）。

### 10.5 感測器能做到什麼、做不到什麼（誠實揭露）
研究員讀原始碼結論：
- DVT 的 `simulateLocationWithLatitude:longitude:` 只收經緯度，**送不了** speed、course、altitude、accuracy。
- 系統顯示的速度，推測是由「連續位置＋時間差」算出（推測，非官方文件）。
- CoreMotion（計步、動作狀態「步行」、加速度）在沒越獄時**無法模擬**。
- 來源（2026-11-02 已 fetch 原始碼核實，selector 皆為 `simulateLocationWithLatitude:longitude:`，只帶 latitude、longitude 兩個參數）：
  - pymobiledevice3：https://raw.githubusercontent.com/doronz88/pymobiledevice3/master/pymobiledevice3/services/dvt/instruments/location_simulation.py 第 10–11 行（宣告與簽名）、第 30–34 行（`set()`）
  - idevice：https://raw.githubusercontent.com/jkcoxson/idevice/master/idevice/src/services/dvt/location_simulation.rs 第 92–93 行（`set(latitude, longitude)` 內組 selector）
  - 行號為 master 當日內容，上游改動可能位移。「速度由位置時間差推算」仍是推測，原始碼只證實只送經緯度。

因此 PinFly 只能把 **GPS 軌跡**做得像在走路：

| 參數 | 值 |
|---|---|
| 更新頻率 | 每 1 秒一點 |
| 步行速度 | 1.2～1.5 m/s（約 4.3～5.4 km/h），每秒 ±10% 變動 |
| 轉角 | 相鄰兩秒方向變化 ≤ 10～20° |
| 偶爾停 | 隨機停 2～5 秒（出現頻率：平均每 60～120 秒一次，⚠️ 數值為本規格自訂） |
| 位置抖動 | 1～3 公尺（取代平常的 4 公尺微飄） |
| 駕車／單車 | 速度依第 3.2 節預設，其餘規則照上（轉角限制依路徑本身） |

**誠實聲明（畫面與文件必須寫明）**：計步器、動作狀態（步行／駕車）、加速度、氣壓高度都**不會**跟著變；只有「位置」會動。需要讀取這些感測器的 App 看到的會是手機靜止。UI 在「行程」頁與說明頁用固定文案：「只模擬位置軌跡，計步器與動作感測不會增加」；README 同文。不得宣稱能騙過任何偵測。

### 10.6 畫面
- 新分頁或首頁入口「行程」：清單、編輯（時段列表，上下拖曳排序、每段展開編輯）、時間軸預覽（各段預估起訖時間＋路線距離）、「開始行程」「停止行程」。
- 執行中：進度卡顯示「第 N／M 段・現在：停留在 X／正在往 Y・下一段 hh:mm」；三顆獨立按鈕沿用第 8 節（暫停、結束移動、停止模擬）。「暫停」暫停的是時間軸（之後不再補位，從暫停位置接續；需明示）。
- 與設計師協調：此頁為新畫面，可與首頁圖釘卡片工作並行，只在首頁加入口按鈕。

### 10.7 檔案與型別（新增）
`GpsSimItinerary.swift`（資料型別＋存取＋時間軸展開，純函式）、`GpsSimItineraryRunner.swift`、`GpsSimItineraryView.swift`（編輯與執行 UI）、`GpsSimWalkingModel.swift`（10.5 的速度／轉角／停頓／抖動，亂數源可注入）、Intents 加 `StartItineraryIntent`／`StopItineraryIntent`、`StikDebugTests/ItineraryTimelineTests.swift`（補位、衝突、時鐘跳動）。型別：`Itinerary`、`ItinSegment`、`ItinState { idle, armed, running(seg), paused, finished }`、`WalkingModel`。

### 10.8 風險（新增）
| 風險 | 對策 |
|---|---|
| 自動化觸發時手機鎖屏／App 起不來 | 實機驗證；失敗時行程進入「待命」並提示；不承諾無人值守 |
| 前景預先規劃需要網路 | 規劃失敗自動直線；無網路出發前先預存 |
| 時間軸與實際落差（斷線、暫停） | 位置一律由 wall-clock 查表；斷線恢復即補位 |
| 使用者誤以為感測器也被模擬 | 固定誠實文案、說明頁、README |
| 耗電（方案 A） | 見 10.4；停留段降頻；實機量測 |
| 與設計師衝突 | 新頁面獨立，HomeView 只加入口 |

### 10.9 工時估計（取代 9.6 合計，全功能版）
| 項目 | 天 |
|---|---|
| 第 1～9 節原估（含漫步） | 8.0 |
| 行程資料型別＋時間軸展開＋補位＋測試 | 1.5 |
| Runner（切段、時鐘校正、待命；只做前景，不含鎖屏兩案） | 1.0 |
| 前景提醒（螢幕常亮、開始前提示、段前本機通知、切背景通知） | 0.5 |
| 步行擬真模型（速度／轉角／停頓／抖動）＋測試 | 0.75 |
| 行程編輯與執行 UI（新分頁） | 2.5 |
| 捷徑（開始／停止行程）＋自動化實測 | 0.75 |
| 文案、說明頁、誠實聲明、README | 0.5 |
| 審查修正＋實機測（前景常亮耗電、通知、時鐘補位；不含鎖屏長測） | 1.0 |
| 合計 | 約 16.5 天（原含鎖屏兩案 17 天；背景續跑移到 v2 評估，另計） |

建議拆版：v1＝「模擬移動」＋三按鈕（約 5.5 天）；v1.1＝原地漫步＋擬真模型（約 3 天）；v2＝預排行程前景版（約 8 天）；背景續跑列 v2 待評估。若使用者最在意預排行程，可調整為先做引擎底層（時間軸、擬真模型）再往上疊。

## 11. 參考專案與資料格式（研究員 GitHub 調查，本節作者未逐一 clone 核實授權與程式內容）

### 11.1 參考專案 Top 5
| # | 專案 | 授權 | 可以抄的點 | 能否直接參考程式碼 |
|---|---|---|---|---|
| 1 | Skysafe64/iphone-gps-spoofer | MIT | iPhone 定位模擬的整體做法與流程 | 可以 |
| 2 | iOSRealRun/iOSRealRun-cli-17（383 星） | MPL-2.0 | 跑步軌跡產生、速度起伏、繞圈跑的邏輯；README 寫明**無法模擬計步**（與第 10.5 節一致） | 可以，但改到的 MPL 檔案要開源 |
| 3 | ma5ter/MockLock | GPL-3.0 | 設計與功能取向 | 只能參考設計，不可複製程式碼 |
| 4 | samueltung-dev/SimuMaster | 授權不明 | 設計與功能取向 | 只看設計，不複製 |
| 5 | Schlaubischlump/LocationSimulator | GPL-3.0 | macOS 端的導航、路線移動與速度控制 UX | 只能參考設計，不可複製程式碼 |

PinFly 公開版若採寬鬆授權，不得併入 GPL 程式碼；MPL 檔案若引用須另置獨立檔並維持 MPL。⚠️ 實際授權文字開工前再核對各 repo 的 LICENSE。

### 11.2 發現
- GitHub 上幾乎沒有「依時間排程的行程表」類專案：這是 PinFly 的差異化。
- iOSRealRun 明寫無法模擬計步，印證 10.5 的誠實聲明。
- 商業產品（AnyGo 等）的行程排程功能這次沒查到：待查。

### 11.3 行程表檔案格式（匯入／匯出用）
採 **JSON**（不用 GPX）：頂層 `version`、`tz`（時區，如 `Asia/Taipei`）、`events[]`。每個 event 的 `type` 三種，且必有 `at`（絕對時間，ISO 8601）或 `after_prev`（接在上一段後面，可帶偏移秒數）：

| type | 欄位 |
|---|---|
| `move` | `to`（地點名稱或 `{lat,lon}`）、`route`（`straight`／`road`／`gpx:檔名`）、`speed_mps`、`speed_jitter`（比例，如 0.1） |
| `wander` | `center`、`radius_m`、`duration_min`、`pause_prob` |
| `stay` | `duration_min` |

範例：
```json
{
  "version": 1,
  "tz": "Asia/Taipei",
  "events": [
    {"type": "stay", "at": "2026-11-05T14:00:00+08:00", "duration_min": 20},
    {"type": "move", "after_prev": true, "to": {"lat": 25.0330, "lon": 121.5654},
     "route": "road", "speed_mps": 1.3, "speed_jitter": 0.1},
    {"type": "wander", "after_prev": true, "center": {"lat": 25.0330, "lon": 121.5654},
     "radius_m": 100, "duration_min": 30, "pause_prob": 0.05}
  ]
}
```
選 JSON 不選 GPX 的理由：GPX 沒有「某時刻原地漫步」這類欄位；路線本身仍可用 `gpx:檔名` 引用標準 GPX。
與 10.1 的內部型別對應：`move`↔移動段、`stay`↔停留段（`wander` 為停留且漫步，圓心與半徑直接寫在 event）、停止模擬可加 `{"type":"stop"}`（本格式補充，研究員版未列）；`ItinSegment` 讀寫此 JSON，存檔格式即此 JSON，可由「檔案」App 匯入分享。

## 12. 捷徑動作（2026-11-03 定案方向，取代 3.7、9.4，並細化 10.3）

產品負責人核准的原則：每個捷徑動作**一步完成一件完整的事**，或**刻意拆開**，讓使用者在兩步之間插入系統動作（例：續簽拆成「下載 PinFly 描述檔」「安裝 PinFly 描述檔」，中間可切換 LocalDevVPN、飛航模式）。

> **實作定案（2026-11-03，設計與工程規劃協調後；與本節其他文字衝突時以本框為準）**
> 1. **不切前景**：路線、直線、原地漫步都在背景開始（`openAppWhenRun = false`，不用 `supportedModes`、`requestToContinueInForeground`），靠移動開始時啟動的背景音訊／定位工作階段讓 1 Hz 計時器繼續跑；第一點送出成功即回傳。時間預算：等候閒置 5 秒＋規劃 8 秒＋確認第一點 8 秒（起點需要 GPS 時另加最多 4 秒）。第一點無法送出（手機鎖定＝錯誤代碼 11、或 LocalDevVPN 未連線）→ 停止移動、回錯誤 21，位置不變。
> 2. **持續時間起算點**：路線、直線**自抵達時**起算；直接前往、原地漫步自執行時起算。以 App 內鬧鐘 `GpsSimAutoReturn` 實作：結束時間存 UserDefaults，15 秒計時器（RunLoop .common），App 啟動、回前景、任何捷徑動作執行時也檢查；成功「停止模擬」或任何新的前往／移動即取消；「查看真實位置」保留原結束時間。
> 3. **抵達後**：移動器抵達、交回微飄後依 `MoveArrivalAction`（停留／原地漫步（半徑）／停止模擬）分派；App 內呼叫沿用預設「停留」。
> 4. **上游 JIT 動作**：移出 App Shortcuts，並設 `isDiscoverable = false` 完全隱藏（12.10 第 2 題採推薦做法）。
> 5. **Swift 屬性名**（避免遮住方法，型別名與 `place` 不變）：`moveMode`（方式）、`speedPreset`（速度）、`customKmh`（自訂速度）、`afterArrival`（抵達後）、`wanderRadius`（漫步範圍，型別 `GpsWanderRange`）、`durationMinutes`（持續時間）。下表「屬性名」欄已改。
> 6. **摘要句採最簡形式**：最外層 `Switch(\.$moveMode)`，各 `Summary` 大括號內只放參數，不巢狀 `When`；因此「自訂速度」在路線、直線時一律顯示於展開區（說明寫「速度為「自訂」時使用」）。
> 7. **「PinFly 狀態」**改用一個「移動狀態」AppEnum（未移動／移動中／已暫停／已抵達／漫步中）取代 `moving`、`wandering` 兩個 Bool，見 12.4。
> 8. **捷徑動作開始時檢查持續時間**：前往地點、目前模擬狀態、查看真實位置、建立連線、續簽群組（續簽 PinFly、到期前續簽、下載／安裝 PinFly 描述檔、查詢簽名期限、匯入描述檔）開始時都呼叫 `GpsSimAutoReturn.settle()`：已到期就先停止模擬並**等結果**（目前模擬狀態最多 6 秒，其餘最多 3 秒）。「停止模擬」不檢查（本身就會回到真實位置並取消持續時間）。「目前模擬狀態」等完仍未回到真實位置（停止失敗或仍在進行）時，訊息開頭加「持續時間已到期，正在回到真實位置。」。
> 9. **時間預算**：前往地點自 perform() 開始計時，含上述檢查，總計 ≤ 25 秒（保留 1 秒建立回傳狀態）：直接前往連線重試 ≤ 12 秒；原地漫步的先前往 ≤ 8 秒；確認第一點 ≤ 剩餘時間（剩 0 秒時只檢查、不等候）。
> 10. **抵達後動作只在正常抵達時執行**：終點送出成功、且移動正常結束（不是「一點都沒送成功而還原」）才執行「原地漫步」「停止模擬」並登記自抵達起算的持續時間；否則寫入紀錄並略過（4 秒重送會繼續讓手機停在終點）。
> 11. **持續時間何時被取消**：成功的「直接前往」、任何「路線／直線／原地漫步」開始時（**即使之後第一點送出失敗、回錯誤 21**）、成功的「停止模擬」。失敗的「直接前往」不取消原本的持續時間。

### 12.1 設計依據（皆為本次讀取的官方來源）

| 依據 | 內容（原文摘錄） | 本節採用方式 |
|---|---|---|
| WWDC22〈Dive into App Intents〉 https://developer.apple.com/videos/play/wwdc2022/10032/ | 「you should always provide a Parameter Summary for every intent」；可用 When／Otherwise、Switch／Case 依參數值改變摘要 | 每個動作都定義 `parameterSummary`；「前往地點」用 Switch／When 隱藏與目前方式無關的參數 |
| `ParameterSummaryWhenCondition` https://developer.apple.com/documentation/appintents/parametersummarywhencondition | 支援 Equatable、OneOf、HasValue 等條件，iOS 16 起 | 「自訂速度」只在「速度＝自訂」時出現 |
| WWDC22〈Design App Shortcuts〉 https://developer.apple.com/videos/play/wwdc2022/10169/ | 「key features … captured in two to five high-quality app shortcuts」；可依「remembering a prior selection」假設值；確認步驟「only use this step for consequential actions」；陣列第一個 App Shortcut 會在 Spotlight 頂端 | 預設值一律等於舊行為；不加確認對話框；「前往地點」排第一 |
| HIG〈App Shortcuts〉 https://developer.apple.com/design/human-interface-guidelines/app-shortcuts | 「Each app can include up to 10 App Shortcuts」；片語必須含 App 名稱；「Include all critical information in the full dialogue text」；「Keep voice interactions simple」 | 10 格分配見 12.6；完成訊息本身包含結果與下一步；Siri 只帶地點 |
| HIG〈Siri〉 https://developer.apple.com/design/human-interface-guidelines/siri | 「Help people understand errors and failures」，錯誤要針對當下情況；「Omit your app name from responses」 | 錯誤沿用「發生了什麼。下一步怎麼做。（錯誤 N）」；完成訊息不寫「PinFly」 |
| 〈Configuring the runtime behavior of your app intents〉 https://developer.apple.com/documentation/appintents/configuring-the-runtime-behavior-of-your-app-intents | `supportedModes` 只是建議；先以 `systemContext.currentMode.canContinueInForeground` 判斷，再呼叫 `continueInForeground` | 本版不採用（實作定案第 1 點：全程背景）；第 3 階段「開始行程」才需要 |
| WWDC25〈Explore new advances in App Intents〉 https://developer.apple.com/videos/play/wwdc2025/275/ | `.foreground(.dynamic)`「allows the intent to decide whether or not to launch the app」；`alwaysConfirm: false` 在最近幾秒有操作時不詢問；被系統或使用者拒絕時 `continueInForeground` 丟出錯誤 | 本版不採用（實作定案第 1 點） |
| `isDiscoverable` https://developer.apple.com/documentation/appintents/appintent/isdiscoverable | 設為 `false` 時 Siri、Spotlight、「捷徑」App 都無法使用該動作，iOS 17 起 | 上游 JIT 動作的處理見 12.10 第 2 題 |

未查到：Apple 對「捷徑動作背景執行時限」的官方秒數。沿用專案既有依據（SideStore 約 27 秒，見 GpsSimRenewIntents.swift 檔頭），本節所有動作以 **25 秒內回應**為上限。

### 12.2 共用規則

1. **不改型別名與既有 `@Parameter` 屬性名**（`SendToPlaceIntent.place`、`StopSimulationIntent` 等）。新參數一律有預設值，預設值組合＝舊行為；舊捷徑開啟後顯示新參數的預設值，執行結果與舊版相同。
2. **AppEnum 的 rawValue 永不改名**（「捷徑」App 以 rawValue 儲存選項）。顯示文字可改，rawValue 不可改。
3. 失敗不丟出錯誤（沿用「前往地點」現況）：回傳「PinFly 狀態」的「結果＝失敗」與「原因」，捷徑繼續執行，可用「如果 結果 是 失敗」分支。例外：「停止模擬」失敗時丟出錯誤（現況，避免手機停在模擬位置卻看似成功）。
4. 錯誤訊息格式：「發生了什麼。下一步怎麼做。（錯誤 N）」。App 內訊息的「點選「重試」」在捷徑內改為「再重新執行此捷徑」（捷徑沒有「重試」按鈕）。不再加「前往失敗：」前綴（第一句已說明結果）。
5. 完成訊息以句號結尾、不含 App 名稱、含使用者需要的全部資訊（地點、方式、預計時間），只聽語音也能理解。
6. 新錯誤代碼 20～29 保留給捷徑層級；1、2、3、9、10、11、12 沿用 `GpsSimIssue`（GpsSimEngine.swift:118）。

### 12.3 一步完成的動作

#### 12.3.1 前往地點（`SendToPlaceIntent`，加強）

| 屬性名（Swift） | 標題 | 型別 | 預設 | 選項／範圍 | 何時顯示 |
|---|---|---|---|---|---|
| `place`（既有） | 地點 | `GpsPlaceEntity` | 無（必填，詢問「要前往哪個地點？」） | 已儲存的地點 | 一律 |
| `moveMode` | 方式 | `GpsMoveMethod` | 直接前往 | 直接前往 `direct`／路線 `route`／直線 `line`／原地漫步 `wander` | 一律（摘要句內） |
| `speedPreset` | 速度 | `GpsMoveSpeed` | 步行 | 步行 `walk` 5 km/h／單車 `bike` 15 km/h（副標題「沿步行路線」）／駕車 `drive` 40 km/h／自訂 `custom` | 方式＝路線、直線 |
| `customKmh` | 自訂速度（km/h） | `Double` | 5 | 3.6～100（程式夾限，不用 `inclusiveRange`）；自訂 > 25 km/h 時向 MKDirections 要駕車路線 | 方式＝路線、直線（一律顯示，說明寫「速度為「自訂」時使用」） |
| `afterArrival` | 抵達後 | `GpsAfterArrival` | 停留 | 停留 `stay`／原地漫步 `wander`／停止模擬 `stop` | 方式＝路線、直線 |
| `wanderRadius` | 漫步範圍 | `GpsWanderRange` | 依 App 設定 | 依 App 設定 `app`／小 `small`／中 `medium`／大 `large` | 方式＝原地漫步 |
| `durationMinutes` | 持續時間（分鐘） | `Int?` | 未填（不限） | 1～720（程式夾限） | 一律（展開區） |

- 「抵達後＝原地漫步」的範圍沿用 App 內上次的檔位（9.2），不另加參數，避免巢狀條件。
- 「抵達後＝停止模擬」時忽略持續時間（參數說明寫明），不再用巢狀條件隱藏。
- 參數說明（`@Parameter(description:)`）：
  - 方式：「直接前往：立即出現在地點範圍內。路線、直線：以設定的速度沿途移動。原地漫步：前往後在範圍內隨機走動。移動與漫步在背景進行，期間請勿從 App 切換器關閉 PinFly。」
  - 持續時間：「未填寫時持續模擬，直到執行「停止模擬」。填寫 1～720 分鐘後即回到真實位置：直接前往、原地漫步自執行時起算；路線、直線自抵達時起算。抵達後為「停止模擬」時不使用此設定。」

**摘要句（parameterSummary）**

| 條件 | 摘要句（〔 〕為可點選參數） | 展開後的其他參數 |
|---|---|---|
| 方式＝直接前往 | 前往〔地點〕，方式〔直接前往〕 | 持續時間（分鐘） |
| 方式＝原地漫步 | 前往〔地點〕，方式〔原地漫步〕 | 漫步範圍、持續時間（分鐘） |
| 方式＝路線／直線 | 前往〔地點〕，方式〔路線〕，速度〔步行〕 | 自訂速度（km/h）、抵達後、持續時間（分鐘） |

程式（實作定案第 6 點：最簡形式，不巢狀 `When`）：

```swift
static var parameterSummary: some ParameterSummary {
    Switch(\.$moveMode) {
        Case(.direct) { Summary("前往 \(\.$place)，方式 \(\.$moveMode)") { \.$durationMinutes } }
        Case(.wander) { Summary("前往 \(\.$place)，方式 \(\.$moveMode)") { \.$wanderRadius; \.$durationMinutes } }
        DefaultCase {
            Summary("前往 \(\.$place)，方式 \(\.$moveMode)，速度 \(\.$speedPreset)") { \.$customKmh; \.$afterArrival; \.$durationMinutes }
        }
    }
}
```

**執行流程與時間預算（總計 ≤ 25 秒）**

1. 讀地點；不存在 → 錯誤 20。
2. 引擎忙碌 → 錯誤 24。
3. 方式＝直接前往：沿用現行流程（`retryingLink` 最多 12 秒），**不切前景**。成功後若有持續時間，登記結束時間（見下方「持續時間」）。
4. 方式＝原地漫步：未在該地點模擬時先「直接前往」（失敗回該錯誤代碼的訊息），再在背景開始漫步；8 秒內第一點未送出 → 停止漫步、錯誤 21。
5. 方式＝路線／直線（全程背景，實作定案第 1 點）：
   1. 決定起點：正在模擬 → `engine.current`；上次啟動留下的模擬點 → 該點；未模擬 → `GpsRealFix.read(timeout: 4)`；取不到 → 錯誤 22。起點與終點相距 ≤ 5 公尺 → 不移動，「抵達後」照常套用。
   2. 估算時間：直線距離÷速度 > 12 小時 → 錯誤 23（路線距離在規劃後再檢查一次）。
   3. 規劃：路線用 MKDirections，逾時 8 秒或失敗 → 改直線，完成訊息加「已改為直線。」。
   4. 啟動 `GpsSimRouteMover`，等第一點被手機接受（最多 8 秒、不超過總預算）後**立即回傳**（不等抵達）。第一點無法送出（錯誤代碼 11、LocalDevVPN 未連線、被其他操作接手）→ 停止移動、錯誤 21，**位置不變更**。
6. 移動或漫步中 App 在背景：計時器繼續（背景音訊／定位工作階段）；不暫停、不發通知。

**持續時間**：直接前往、原地漫步自執行時起算；路線、直線自抵達時起算。到時呼叫 `engine.stop()`，成功後發本機通知「已回到真實位置。」；失敗發通知「無法回到真實位置。請開啟 PinFly 並點選「停止模擬」。（錯誤 12）」（同一結束時間只發一次，15 秒後再試）。結束時間存入 UserDefaults，App 下次啟動或回前景時若已超過就立即停止。⚠️ 待實機驗證：手機鎖定 60 分鐘後由背景計時器停止是否準時（依賴既有 audio 背景模式，第 1 節）。

**完成訊息**

| 情況 | 訊息 |
|---|---|
| 直接前往 | 已前往 台北101（距中心 32 公尺）。 |
| 直接前往＋持續 | 已前往 台北101（距中心 32 公尺），將於 15:30 回到真實位置。 |
| 路線／直線 | 已開始移動至 台北101：步行，路線 2.3 公里，預計 14:32 抵達。移動期間請勿從 App 切換器關閉 PinFly。 |
| 路線失敗改直線 | 已開始移動至 台北101：步行，直線 2.0 公里，預計 14:28 抵達。已改為直線。移動期間請勿從 App 切換器關閉 PinFly。 |
| 抵達後＝停止模擬／原地漫步 | 「預計…抵達。」之後加「抵達後將回到真實位置。」／「抵達後將原地漫步。」 |
| 路線／直線＋持續時間 | 「預計…抵達。」之後加「抵達 15 分鐘後將回到真實位置。」 |
| 自訂速度 | 速度寫「自訂 6 km/h」 |
| 原地漫步 | 已前往 台北101，開始原地漫步（範圍：中）。漫步期間請勿從 App 切換器關閉 PinFly。（有持續時間時在「。」後加「將於 15:30 回到真實位置。」） |
| 已在目的地 5 公尺內（路線／直線） | 已位於 台北101，不需要移動。（結果＝成功，抵達後設定照常套用） |

**錯誤訊息**（結果＝失敗，原因＝下列全文）

| 錯誤 | 訊息 |
|---|---|
| 20 地點不存在 | 找不到地點「台北101」，此地點已刪除。請在捷徑中重新選擇地點。（錯誤 20） |
| 21 第一點無法送出 | 無法送出移動的第一個位置，未開始移動。請解鎖手機並確認 LocalDevVPN 已連線，再重新執行此捷徑。（錯誤 21） |
| 22 無法取得起點 | 無法取得起點位置。請先以「直接前往」前往一個地點，或至「設定 › PinFly › 位置」開啟權限。（錯誤 22） |
| 23 時間過長 | 預計移動時間超過 12 小時。請改用較快的速度或「直接前往」。（錯誤 23） |
| 24 忙碌 | PinFly 正在處理其他操作。請稍後再重新執行此捷徑。（錯誤 24） |
| 3／9 連線 | 無法連線至手機的定位服務。請確認已連上 Wi-Fi 且 LocalDevVPN 已連線，再重新執行此捷徑。（錯誤 3） |
| 1、2、10、11 | 沿用 `GpsSimIssue` 全文；錯誤 1 沿用現況 `failureMessage` 的「請開啟 PinFly，點選「改回預設」」 |

#### 12.3.2 開始行程（`StartItineraryIntent`，第 3 階段，本版只定規格）

| 屬性名 | 標題 | 型別 | 預設 | 說明 |
|---|---|---|---|---|
| `itinerary` | 行程 | `GpsItineraryEntity` | 無（必填，詢問「要開始哪個行程？」） | 已儲存的行程 |
| `startMode` | 開始時間 | `GpsItineraryStart` | 依行程設定 `scheduled` | 依行程設定／立即 `now`（第一段改為立即開始，其餘依序順延） |

- 摘要句：「開始行程〔行程〕，開始時間〔依行程設定〕」。
- 一律需要前景：iOS 26 起 `supportedModes = [.foreground(.immediate)]`；iOS 17.4～25 `openAppWhenRun = true`。前景內預先規劃所有移動段（10.2），完成後回傳。
- 完成訊息：「已開始行程「下午散步」，共 4 段，第 1 段 14:00 開始。行程期間請保持 App 開啟、螢幕亮著、接上電源。」；第一段在未來時：「行程「下午散步」已待命，第 1 段 14:00 開始。行程期間請保持 App 開啟、螢幕亮著、接上電源。」
- 錯誤：26「找不到行程「下午散步」，此行程已刪除。請在捷徑中重新選擇行程。（錯誤 26）」；27「行程「上午」正在進行。請先執行「停止行程」。（錯誤 27）」；28「行程「下午散步」的所有時段都已結束。請在 PinFly 修改時間後再執行。（錯誤 28）」；無法切到前景用錯誤 21（句中「未開始移動」改為「未開始行程」）。
- 10.4 的開始前提示在捷徑執行時略過，改由完成訊息告知；否則自動化會停在提示畫面。

### 12.4 拆開的動作（積木）

| 標題 | 型別 | 本版變更 | 參數 | 摘要句 | 完成訊息 | 前景 |
|---|---|---|---|---|---|---|
| 建立連線 | `ConnectIntent`（既有） | 改說明 | 無 | 建立連線 | 已建立連線，可關閉飛航模式。 | 背景 |
| 停止模擬 | `StopSimulationIntent`（既有） | 一併取消移動、漫步、持續計時 | 無 | 停止模擬 | 已回到真實位置，地圖約 10 秒內更新。 | 背景 |
| 目前模擬狀態 | `SimulationStatusIntent`（既有） | 擴充回傳與訊息 | 無 | 取得目前模擬狀態 | 見下 | 背景 |
| 停止行程 | `StopItineraryIntent`（新，第 3 階段） | 規格 | 停止後：停留在目前位置 `stay`（預設）／停止模擬 `stop` | 停止行程，停止後〔停留在目前位置〕 | 已停止行程，停留在目前位置。／已停止行程並回到真實位置。 | 背景 |
| 續簽群組（續簽 PinFly、到期前續簽 PinFly、下載／安裝 PinFly 描述檔、查詢簽名期限、匯入描述檔） | 既有 | 不變 | — | — | — | 背景 |

- 建立連線說明改為：「建立定位連線，最多等候 20 秒。適合放在「開啟飛航模式」與「關閉飛航模式」之間確認連線；「前往地點」會自動連線，一般捷徑不需要此動作。」
- 停止行程錯誤：29「目前沒有進行中的行程。不需要執行此動作。（錯誤 29）」，結果＝失敗、不中斷捷徑。
- 不另做「結束移動」動作：需要停在原地時，以「前往地點（直接前往）」覆蓋，或在 App 內點選「結束移動」。

**「PinFly 狀態」新增屬性**（`GpsSimStatusEntity`，只增不改）

| 屬性名 | 標題 | 型別 | 說明 |
|---|---|---|---|
| `moveStatus` | 移動狀態 | `GpsMoveStatus` | 未移動 `idle`／移動中 `moving`／已暫停 `paused`／已抵達 `arrived`／漫步中 `wandering`（實作定案第 7 點，取代原規劃的 `moving`、`wandering` 兩個 Bool） |
| `destinationName` | 目的地 | String | 移動或漫步的地點名稱；未移動時為空 |
| `remainingMeters` | 剩餘距離（公尺） | Int? | 路線、直線移動中（含暫停）才有值 |
| `arrivalTime` | 預計抵達 | Date? | 依目標速度推算；暫停時為空 |
| `endTime` | 預計結束 | Date? | 有設定持續時間時，回到真實位置的時間 |
| `itineraryName`（第 3 階段） | 行程 | String | 進行中的行程名稱 |

- 既有「目前地點」維持現況（只增不改）：第一點送出成功後即為目的地名稱；「模擬中」在移動期間為真。舊捷徑的「如果 模擬中」判斷不受影響。
- 目前模擬狀態的完成訊息：
  - 「未在模擬。」
  - 「模擬中：台北101。」；有持續時間時加「將於 15:30 回到真實位置。」
  - 「移動中：前往 台北101，剩餘 1.2 公里，預計 14:32 抵達。」；暫停時「移動已暫停：前往 台北101，剩餘 1.2 公里。」
  - 「漫步中：台北101。」（移動器不記檔位，不寫範圍）；移動中、漫步中有持續時間時同樣加「將於 15:30 回到真實位置。」
  - App 重新開啟後只知道上次地點時，沿用現況補註「（PinFly 曾重新開啟，此為上次送出的地點）」。

### 12.5 不做的動作（產品負責人決定）

| 項目 | 理由 |
|---|---|
| 遊戲冷卻計時器 | 屬於特定遊戲的輔助，不是定位工具的核心工作 |
| 出勤、打卡自動化 | 會被用於規避出勤管理，不提供 |
| 接近工作地點時自動模擬 | 同上；另「抵達」類自動化在模擬中讀到的是模擬位置，觸發不可靠 |

### 12.6 App Shortcuts 的 10 格與 Siri 片語

規則：只放「單獨用 Siri、Spotlight、動作按鈕就有意義」的動作；積木（建立連線、匯入描述檔）不佔格子，仍可在「捷徑」App 的動作清單中使用。上游 `EnableJITIntent`、`KillProcessIntent` 移出提供者，型別保留編譯。片語一律含 `\(.applicationName)`；第 1 格會出現在 Spotlight 頂端（WWDC22 10169）。

| 格 | 動作 | 片語 | shortTitle | 圖示 |
|---|---|---|---|---|
| 1 | 前往地點 | 用\(.applicationName)前往\(\.$place)／\(.applicationName)前往\(\.$place)／用\(.applicationName)前往地點 | 前往地點 | `mappin.and.ellipse` |
| 2 | 停止模擬 | 用\(.applicationName)停止模擬／\(.applicationName)停止模擬／用\(.applicationName)回到真實位置 | 停止模擬 | `location.slash` |
| 3 | 目前模擬狀態 | \(.applicationName)目前模擬狀態／用\(.applicationName)查詢模擬狀態 | 目前模擬狀態 | `info.circle` |
| 4 | 查看真實位置 | 用\(.applicationName)查看真實位置／\(.applicationName)查看真實位置 | 查看真實位置 | `location.magnifyingglass` |
| 5 | 續簽 PinFly | 用\(.applicationName)續簽／\(.applicationName)續簽 | 續簽 PinFly | `signature` |
| 6 | 到期前續簽 PinFly | \(.applicationName)到期前續簽／用\(.applicationName)到期前續簽 | 到期前續簽 PinFly | `calendar.badge.clock` |
| 7 | 查詢簽名期限 | \(.applicationName)簽名期限／用\(.applicationName)查詢簽名期限 | 查詢簽名期限 | `calendar` |
| 8 | 下載 PinFly 描述檔 | 用\(.applicationName)下載描述檔／\(.applicationName)下載描述檔 | 下載 PinFly 描述檔 | `arrow.down.circle` |
| 9 | 安裝 PinFly 描述檔 | 用\(.applicationName)安裝描述檔／\(.applicationName)安裝描述檔 | 安裝 PinFly 描述檔 | `square.and.arrow.down` |
| 10 | 保留給第 3 階段 | — | — | — |

- 第 3 階段：第 10 格放「開始行程」（用\(.applicationName)開始行程\(\.$itinerary)／\(.applicationName)開始行程）；第 9 格改放「停止行程」（用\(.applicationName)停止行程／\(.applicationName)停止行程）。「安裝 PinFly 描述檔」只在「下載」之後才有意義，屬積木，退出提供者後仍可在動作清單使用。
- 第 7 格圖示由 `calendar.badge.clock` 改為 `calendar`，避免與第 6 格相同；第 2 格由 `location.fill` 改為 `location.slash`，與第 1 格區分。
- Siri 以片語執行「前往地點」時只帶地點，其他參數用預設值（直接前往），不需要前景，符合 HIG「Keep voice interactions simple」。

### 12.7 使用教學用的自動化範例（App 內「使用教學 › 捷徑」）

| # | 名稱 | 觸發 | 步驟 | 注意 |
|---|---|---|---|---|
| 1 | 一鍵前往常用地點 | 手動（主畫面、動作按鈕、Siri） | 前往地點（地點：常用地點；方式：直接前往） | 可加入主畫面 |
| 2 | 僅有行動網路時前往 | 手動 | 設定 VPN（LocalDevVPN，連線）→ 設定飛航模式（開啟）→ 設定 Wi-Fi（開啟）→ 前往地點（每次詢問）→ 設定飛航模式（關閉）→ 設定行動數據（開啟） | 拆開設計的範例 |
| 3 | 限時模擬 | 手動 | 前往地點（方式：直接前往；持續時間：60） | 時間到自動回到真實位置並通知 |
| 4 | 沿路線步行 | 手動 | 前往地點（方式：路線；速度：步行；抵達後：停留） | 背景執行；手機鎖定時回錯誤 21，自動化中建議用「直接前往」 |
| 5 | 抵達後原地漫步 | 手動 | 前往地點（方式：路線；速度：單車；抵達後：原地漫步） | 單車沿步行路線 |
| 6 | 連上住家 Wi-Fi 時停止模擬 | 自動化「Wi-Fi：加入住家網路」 | 目前模擬狀態 → 如果「模擬中」為真 → 停止模擬 → 顯示通知「已回到真實位置。」 | 不使用「抵達」類觸發（模擬中讀到的是模擬位置） |
| 7 | 每天到期前續簽 | 自動化「鬧鐘：停止時」 | 到期前續簽 PinFly（剩 3 天內） | 可加「如果 結果 是 失敗 → 顯示通知 原因」 |
| 8 | 行動網路下續簽 | 手動或自動化 | 下載 PinFly 描述檔 → 設定行動數據（關閉）→ 設定 VPN（LocalDevVPN，連線）→ 安裝 PinFly 描述檔 → 設定行動數據（開啟） | 拆開設計的範例 |

### 12.8 真實使用者測試劇本（iOS 模擬器「捷徑」App）

測試員角色：第一次自建捷徑的使用者，只拿到「任務」欄文字，不看本規格。每步記錄花費秒數、是否需要回頭尋找、畫面原文訊息、截圖。

前置（由主對話準備，不交給測試員）：
- 安裝測試版並設定啟動參數 `GPSSIM_LINK_MOCK=1`：送點與清除一律回 0，並把每次送出的座標寫入 log；正式版不讀此參數。⚠️ 此參數尚未實作，為本節驗收的前置工作。
- 預先儲存三個地點：台北101、國立故宮博物院、中正紀念堂。
- 先確認模擬器內有「捷徑」App；沒有則停止並回報，改排實機測試。
- 準備一份舊版建立的捷徑檔「舊版前往台北101.shortcut」（只有「前往地點：台北101」一步）。

| # | 任務（給測試員的原文） | 預期結果（通過條件） |
|---|---|---|
| 1 | 開啟「捷徑」App，找到 PinFly 提供的捷徑。 | App 捷徑區有 9 個中文項目，第 1 個是「前往地點」；沒有 Enable JIT、Kill Process。 |
| 2 | 建一個捷徑，讓手機出現在台北101，然後執行。 | 加入「前往地點」後摘要句為「前往 地點，方式 直接前往」；選台北101 後執行，5 秒內出現「已前往 台北101（距中心 N 公尺）。」；PinFly 未切到前景。 |
| 3 | 匯入「舊版前往台北101」並執行。 | 匯入時無「未知的動作」；方式顯示「直接前往」；結果與任務 2 相同。 |
| 4 | 把任務 2 的捷徑改成沿路線過去，速度設為每小時 6 公里。 | 方式改「路線」後摘要句出現「速度 步行」，展開有「自訂速度（km/h）」「抵達後」「持續時間」；速度改「自訂」、自訂速度填 6；方式改回「直接前往」時速度相關參數消失。 |
| 5 | 執行任務 4 的捷徑。 | PinFly **不切到前景**；完成訊息含「已開始移動至 台北101：自訂 6 km/h」「預計 HH:mm 抵達」；開啟 PinFly 時畫面有模擬移動進度卡；log 每秒一點。 |
| 6 | 再建一個捷徑，顯示 PinFly 現在的狀態（是否移動中、還剩多遠）。 | 使用「目前模擬狀態」＋「顯示結果」；可選到「移動中」「目的地」「剩餘距離（公尺）」「預計抵達」；值與 App 進度卡一致。 |
| 7 | 讓手機到故宮後在附近隨意走動，範圍小一點。 | 方式選「原地漫步」後摘要句不出現速度；展開有「漫步範圍」；選「小」執行後訊息為「已前往 國立故宮博物院，開始原地漫步（範圍：小）。漫步期間請勿從 App 切換器關閉 PinFly。」 |
| 8 | 讓手機到中正紀念堂，2 分鐘後自動恢復成真實位置。 | 持續時間填 2；訊息含「將於 HH:mm 回到真實位置」；2 分鐘後收到通知「已回到真實位置。」；目前模擬狀態回「未在模擬。」 |
| 9 | 在 PinFly 裡刪除「中正紀念堂」，再執行任務 8 的捷徑。 | 訊息全文為「找不到地點「中正紀念堂」，此地點已刪除。請在捷徑中重新選擇地點。（錯誤 20）」；捷徑未中斷；「如果 結果 是 失敗」可分支。 |
| 10 | （主對話先移除 `GPSSIM_LINK_MOCK`）再執行任務 2 的捷徑。 | 訊息以「再重新執行此捷徑。（錯誤 3）」結尾，不出現「點選「重試」」。 |
| 11 | 移動途中，用捷徑讓手機回到真實位置。 | 「停止模擬」後移動停止、進度卡消失；目前模擬狀態的「移動中」「模擬中」皆為否。 |
| 12 | （主對話先鎖定模擬器，再以 `xcrun simctl openurl` 開啟 `shortcuts://run-shortcut?name=…` 執行任務 4 的捷徑） | 回傳錯誤 21 全文；log 無新座標。 |
| 13 | 在 Spotlight 搜尋「前往」。 | 出現 PinFly「前往地點」。 |

通過標準：1～11、13 必須通過；12 若模擬器無法重現鎖定狀態，標「模擬器無法測」並列入實機清單。所有畫面文字另以用語規範第 5 節的禁用字樣搜尋一次。

### 12.9 實作清單（捷徑部分）

| 檔案 | 動作 |
|---|---|
| `StikDebug/GpsSim/GpsSimIntents.swift` | 四個 AppEnum（`GpsMoveMethod`、`GpsMoveSpeed`、`GpsAfterArrival`、`GpsWanderRange`）、`SendToPlaceIntent` 新參數與摘要、持續時間登記；AppEnum 與換算在 `GpsSimMoveIntentTypes.swift`、持續時間鬧鐘在 `GpsSimAutoReturn.swift`；`ConnectIntent` 說明；錯誤 20～24 |
| `StikDebug/GpsSim/GpsSimIntentStatus.swift` | 新屬性；`make()` 讀取 `GpsSimRouteMover` 狀態 |
| `StikDebug/GpsSim/GpsSimRenewIntents.swift` | `SimulationStatusIntent` 完成訊息 |
| `StikDebug/App/Intents.swift` | 提供者 10 格（12.6）；`EnableJITIntent`、`KillProcessIntent` 移出 |
| 第 3 階段 | `StartItineraryIntent`、`StopItineraryIntent`、`GpsItineraryEntity`、錯誤 26～29 |

### 12.10 待產品負責人決定

1. 自動化在手機鎖定時執行「路線／直線／原地漫步」：**回傳錯誤 21、位置不變**（已實作；第一點無法送出即停止）。
2. 上游 JIT 動作：**已設 `isDiscoverable = false` 完全隱藏**（代價：已使用這兩個動作的捷徑會失效；PinFly 使用者不需要 JIT）。
3. 持續時間：**路線、直線自抵達時起算**；直接前往、原地漫步自執行時起算（已實作）。
