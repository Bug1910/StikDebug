# 預排行程工程規劃（Plan agent，基準 itin worktree fcb2e6b；舊視窗 gpssim-4b 轉來）

> 2026-11-03 依設計規格（`docs/spec-route-move.md` 第 10 節、12.3.2）與審查結果修正；兩份衝突時以規格為準。

## 一、可沿用＋缺口
- GpsSimRouteMover.swift: start(plan:) :195、startWander :227、stopMoving :269、cancelForTakeover :284、runSerial :93；世代 :142 :296；arrive :402；抵達後動作 :438；斷線暫停/續走 :551–575
- 缺口1：start(plan:) 加 startAtMeters: Double = 0（:216 附近設 traveledMeters）
- 缺口2：GpsSimEngine 加 private(set) var controlSerial，send(to:) :287、stop :402 開頭 +1（takeOverFromMove :589）
- 路線 GpsSimRoutePlanner.plan :198（MKDirections 8 秒，失敗直線）；Timer 寫法同 GpsSimAutoReturn.swift:94、RouteMover:321；log GpsSimIntentLog（AutoReturn:138）前綴 [Itinerary]
- 背景保活：LocationSimulationSession.swift:16-21 只在送點時啟動背景音訊／定位；待命沒送點 → 要自己呼叫 BackgroundAudioManager.shared.requestStart()／requestStop()
- 通知權限：目前只有 GpsSimRenewCenter.swift:861 會要求；行程在「儲存行程」時另外要求

## 二、檔案（StikDebug/GpsSim/，測試 StikDebugTests/）
0 甲：型別骨架先 commit
1 甲 GpsSimItinerary.swift ~400：Codable 扁平；ItinCoord{lat,lon}；ItinStartRule{kind: at|afterPrevious, at: Date?}；ItinEvent{id,type: move|wander|stay|stop,startRule,placeID,placeName,coord,moveMode: route|straight,speedPreset,customKmh,wanderRadius,minutes,cachedPath:[ItinCoord]?,routeKey:String?}；routeKey＝起點座標＋終點座標＋移動方式（含路線類型）組成的字串，與目前值不同＝快取過期（判斷「座標改過」）；Itinerary{id,name,timeZoneID,events,updatedAt,dateMode: today|fixed}（dateMode 用 decodeIfPresent，缺＝today；today 時只取 at 在 timeZoneID 下的時分，早於前一項＝隔天）；ItineraryFile{version:1,itineraries}。GpsItineraryStore @MainActor：Application Support/itineraries.json atomic；壞檔改名 .corrupt（同 GpsSimPlaces.swift:298）；匯入匯出（11.3 格式＋name、date_mode；after_prev 偏移秒數捨棄並列入調整提示，不加欄位；見規格 10.6.9）、刪除復原。nonisolated enum ItinSchedule：validate→[ItinIssue]（錯誤 30～36：第一項須停留／漫步、≤20 項、移動 ≤12 小時、總長 ≤24 小時、停止模擬的下一項須指定時間的停留／漫步、走不到（警告 35）、指定日期倒序；漫步 ≤240 分）；compute(events:anchor:durations:)→[ItinSlot(start,end?)]；resolve(slots:now:)→ItinCursor{index,offset}|.notYet|.finished；metersAt(offset:kmh:total:)
2 乙 引擎/移動器補丁 ~15（兩缺口）
3 乙 GpsSimItineraryRunner.swift ~380：@MainActor final ObservableObject shared；ItinRunState{idle,armed,running(index),paused(MovePauseReason),finished,cancelled(reason)}（無 planning：開始時不規劃路線）；start(itineraryID:startShift:)：只用儲存時的 cachedPath，沒有或 routeKey 不符改直線並標記，不呼叫 MKDirections；進入 armed 呼叫 BackgroundAudioManager.shared.requestStart()，離開 armed（開始第一項、停止、取消）呼叫 requestStop()；1Hz tick：比 generation→比 mover.runSerial/engine.controlSerial 與上次記下的值（不同＝手動接手→取消，toast「已改為手動操作，行程已停止。」）→resolve 換項分派（移動 mover.start(plan:startAtMeters:)、漫步 startWander、停留 engine.send(to:)（已在該點不送）、停止 engine.stop）；**Runner 自己每次分派完成後立即重新記下 controlSerial 與 runSerial**（自己的 send／stop／start 也會讓序號加 1，不重記會誤判為手動接手）。時鐘校正：Date vs systemUptime 差 >300 秒 toast＋重查。接續上一項：正常用實際抵達時間，補位用預估。斷線或鎖定時時間軸照走，恢復落後 >30 秒用 startAtMeters 補。暫停累加 timelineShift：只順延「接續上一項」，遇下一個「在 HH:mm」項目歸零；暫停中到固定時間維持暫停（規格 10.2.4）。執行狀態存 UserDefaults 鍵 itinerary.runState（行程 id、基準時間、開始平移量 startShift、timelineShift、目前項目），App 重開提供「接續行程」。回前景立即 tick；本機通知（項目前 N 分鐘，鍵 itinerary.notifyLeadMinutes 預設 5、1～30；首次進背景一次；鎖定拒收一次）；通知權限在儲存行程時（前景）要求；armed／running 且前景時 isIdleTimerDisabled＝true，結束/停/暫停還原；開始前確認視窗「不再顯示」鍵 itinerary.skipStartNotice
4 甲 GpsSimItineraryIntents.swift ~200：GpsItineraryEntity/Query（照 GpsSimIntents.swift:31–58）；AppEnum GpsItineraryStart{scheduled,now,delayed}（rawValue 永不改）；StartItineraryIntent(@Parameter itinerary、startMode、delayMinutes Int 1～720 預設 10，摘要 Switch 見規格 12.3.2)，openAppWhenRun=false（定案），呼叫 runner.start(itineraryID:startShift:)（now／delayed 把全部項目平移到現在／現在＋N 分）；StopItineraryIntent（無參數，停原地不回真實，toast／訊息「行程已停止，停留在目前位置。」）；捷徑錯誤 26～29；錯誤 21 行程版另設新常數（「無法送出行程的第一個位置，未開始行程。…（錯誤 21）」，不改前往地點的 21）；App 內「已有行程進行中」用錯誤 38（不用 27，遵守規格 12.2 第 6 點：20～29 只給捷徑層級）。Intents.swift:269 起：第 10 格「開始行程」（play.circle）、第 9 格改「停止行程」（stop.circle）、「安裝 PinFly 描述檔」退出提供者；行程變動呼叫 StikDebugShortcuts.updateAppShortcutParameters()
5 乙 畫面 ~650：GpsSimItineraryListView（清單/匯入/匯出/空白狀態）、GpsSimItineraryEditorView（項目列表、拖曳排序＋上移下移、時間軸預覽、驗證錯誤 30～38 與修正按鈕、儲存時規劃路線並寫 cachedPath／routeKey、要求通知權限）、GpsSimItineraryRunView（執行畫面＋三鈕、首頁行程進度卡）；@ObservedObject runner.shared、store；HomeView 只加「行程」圓鈕（list.bullet.clipboard，不用 calendar.badge.clock：Intents.swift:318 第 6 格已用）＋.sheet＋進度卡切換
6 甲 ItineraryTests.swift ~280（Swift Testing）：compute 串接/絕對時間/隔天；resolve 各情況；暫停順延到固定時間歸零；metersAt 上限；validate 30～36；routeKey 過期判斷；跨時區；JSON 來回（version、dateMode 缺欄位預設、after_prev 偏移捨棄、未知 type）；時鐘跳動

## 三、平行
甲＝GpsSimItinerary.swift、GpsSimItineraryIntents.swift、Intents.swift、測試；乙＝RouteMover、Engine、Runner、三畫面、HomeView 入口。依賴只有步驟 0；Intent 只呼叫 runner.start(itineraryID:startShift:)、stopItinerary()，簽名先定

## 四、編譯風險
1 不准用 start/stop/pause 當參數或區域變數名（RouteMover:186 註解）；欄位 startRule；同類別呼叫寫 self.start(...)
2 Timer closure：[weak self] _ in Task { @MainActor in self?.tick() }；純函式放 nonisolated enum
3 CLLocationCoordinate2D 非 Codable→ItinCoord；別取 Event/Timeline/Schedule 裸名
4 AppEntity：static var defaultQuery、id String、Sendable；query 用 MainActor.run 讀 store；片語參數要 AppEntity、query 實作 suggestedEntities；捷徑 ≤10 格、片語含 \(.applicationName)；AppEnum rawValue 永不改
5 選填 decodeIfPresent（dateMode、routeKey、cachedPath）；日期 .iso8601，at 存 UTC Date、時區另存
6 停留項目排除移動器 4 小時自動停止（RouteMover:485）
7 HomeView 只改入口一處
合計 ~1,900 行
