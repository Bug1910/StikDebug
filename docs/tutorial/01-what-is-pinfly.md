# 第 1 章：這是什麼、需要什麼

**重點**：PinFly 可將 iPhone 的位置設為選定的地點。首次設定需要電腦，之後的操作都在手機上完成。

## 1.1 PinFly 能做什麼

1. 在地圖上搜尋地點，或貼上座標，將 iPhone 的位置設為該地點。
2. 點選地點即前往該地點；開啟「位置微飄」時，位置會在落點 4 公尺內輕微漂移。
3. 點選「停止模擬」，手機約 10 秒內回到真實位置。
4. 每 7 天自動續簽（第 5 章），不會刪除地點。

## 1.2 PinFly 不能做什麼

- 只變更位置，不變更其他 App 的資料。
- 不能在 App Store 下載，只能用第 2 章的方法安裝。
- 不會代為登入網站或申請任何服務。

## 1.3 需要什麼

| 項目 | 要求 | 說明 |
|---|---|---|
| iPhone | iOS 17.4 以上 〔待確認：是否支援 iOS 26 與 iPad 實機〕 | iOS 是 iPhone 的系統名稱。請到「設定 → 一般 → 關於本機」查版本 |
| 電腦 | 一台 Windows 電腦 〔待確認：Mac 是否可用〕 | 只在安裝與產生配對檔時使用 |
| USB 傳輸線 | 可傳輸資料的線 | 只能充電的線無法連線 |
| iTunes | 裝在電腦上 〔待確認：新版 Windows 是否仍需要〕 | 電腦連接 iPhone 所需的程式 |
| Apple ID | 一組免費的 Apple ID 即可 | 用來簽名，不需要付費開發者帳號 〔待確認〕 |
| LocalDevVPN | 免費 App | 第 4 章說明 |
| 網路 | Wi-Fi 或行動網路 | 續簽、搜尋地點需要網路；定位模擬需要 Wi-Fi 或 LocalDevVPN 的連線（第 4 章） |

LocalDevVPN 下載位置（App Store）：`https://apps.apple.com/us/app/localdevvpn/id6755608044`

## 1.4 名詞表

| 詞 | 說明 |
|---|---|
| 側載（sideload） | 不透過 App Store，直接把 App 裝到自己的 iPhone |
| IPA | App 的安裝檔，副檔名是 `.ipa` |
| Apple ID | 登入 iCloud 與 App Store 使用的 Apple 帳號 |
| 簽名（signing） | Apple 對 App 的身分證明。免費 Apple ID 的簽名只有 7 天 |
| 續簽（renew） | 更新 7 天簽名，App 才能繼續開啟 |
| 描述檔（provisioning profile） | 承載簽名的檔案，安裝至 iPhone 後 App 才能使用 |
| 配對檔（pairing file） | 讓 PinFly 連線至此 iPhone 的檔案，只需產生一次 |
| LocalDevVPN | 在 iPhone 內建立本機 VPN 連線，讓 PinFly 連線至手機的定位服務 |
| 開發者映像（DDI） | iOS 模擬位置所需的系統元件，第一次使用時下載，約數十 MB |
| 捷徑（Shortcuts） | iPhone 內建的自動化 App，可將多個動作組成一個捷徑 |
| 飛航模式 | 關閉手機的無線網路與行動網路，用來切換連線狀態 |

## 1.5 流程總覽

1. 第 2 章：把 PinFly 裝到 iPhone，信任開發者並開啟開發者模式（新手機請照 1.6 的順序）。
2. 第 3 章：在電腦上產生配對檔，匯入 PinFly。
3. 第 4 章：安裝並連線 LocalDevVPN。
4. 第 5 章：登入 Apple ID。
5. 第 6 章：選地點，開始定位。
6. 第 7 章（選做）：設定捷徑自動續簽。


## 1.6 從新手機開始（完整順序）

新 iPhone 請依下列順序操作，每一步只做一件事。App 內「設定 › 使用教學 › 從新手機開始」是同一份步驟。截圖中的黃框為點選位置。

### 安裝前

1. 完成 iPhone 初始設定，並登入 Apple ID。
2. 連上 Wi-Fi。
3. 以可傳輸資料的 USB 線連接電腦，iPhone 出現「信任這部電腦」時點選「信任」，並輸入 iPhone 密碼（Apple 說明：https://support.apple.com/zh-tw/109054）。
4. 在電腦以 iloader 安裝 PinFly（第 2 章 2.2）。

### 信任開發者

5. 開啟「設定」›「一般」，點選「VPN 與裝置管理」。

   ![](images/guide_sys_12.png)

6. 有「開發者 App」區塊時，點選安裝時使用的 Apple ID，點選「信任」。此區塊不一定會出現（下圖即未出現），未出現時略過此步驟。

   ![](images/guide_sys_02.png)

### 開發者模式

7. 開啟「設定」›「隱私權與安全性」，捲到最下方，點選「安全性」區的「開發者模式」。

   ![](images/guide_sys_04.png)

8. 開啟「開發者模式」開關。

   ![](images/guide_sys_13.png)

9. 在警示中確認重新啟動。 〔待確認：繁中按鈕文字，Apple 英文文件為「Restart」〕
10. 開機後解鎖，在警示中確認開啟，並輸入 iPhone 密碼。 〔待確認：繁中按鈕文字，Apple 英文文件為「Enable」〕

「開發者模式」要在 iPhone 與電腦配對過後才會出現（https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device）。

### LocalDevVPN

11. 在 App Store 搜尋「LocalDevVPN」，點選「取得」安裝（已安裝時改為開啟 App 的按鈕）。

    ![](images/guide_sys_07.png)

12. 開啟 LocalDevVPN，畫面顯示「已中斷連線」。

    ![](images/guide_sys_14.png)

13. 點選「連線」。
14. 第一次連線時，iOS 詢問是否加入 VPN 設定，點選「允許」並輸入 iPhone 密碼。 〔待確認：提示文字〕
15. 確認畫面顯示「已連線」。

    ![](images/guide_sys_08.png)

### PinFly

16. 在 PinFly 開啟「設定」›「進階」，於「配對檔」點選「匯入配對檔」（已由 iloader 放置時可略過，見第 3 章）。

    ![](images/guide_ch1_01.png)

17. 依「使用引導」確認每一步皆為「已完成」。

    ![](images/guide_ch1_02.png)

![](images/ch01-01.png)

*截圖說明：`iPhone 設定 › 一般 › 關於本機` 中，「軟體版本」那一行，顯示 17.4 以上的版本號。*

![](images/ch01-02.png)

*截圖說明：電腦桌面上的 USB 傳輸線與 iPhone 的連接照片（或示意圖）。*
