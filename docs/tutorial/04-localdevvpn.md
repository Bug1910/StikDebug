# 第 4 章：LocalDevVPN

**重點**：PinFly 經由 LocalDevVPN 連線至手機的定位服務。無法前往地點或畫面顯示「無法連線」時，多數是 LocalDevVPN 未開啟或未連線。

## 4.1 LocalDevVPN 是什麼

| 詞 | 說明 |
|---|---|
| VPN（虛擬私人網路） | iPhone 內建的網路連線設定。LocalDevVPN 以此建立供 PinFly 使用的本機連線 |
| LocalDevVPN | 免費 App，負責建立此連線 |
| 本機連線 | 只在此 iPhone 內部使用的連線，不作為上網用途 〔待確認：實際流量走向〕 |

## 4.2 安裝 LocalDevVPN

1. 開啟 App Store。
2. 搜尋「LocalDevVPN」，或直接開啟 `https://apps.apple.com/us/app/localdevvpn/id6755608044`。
3. 點選「取得」安裝。

![](images/ch04-01.png)

*截圖說明：App Store 中 LocalDevVPN 的頁面，標出「取得」按鈕。*

## 4.3 開啟 LocalDevVPN

1. 開啟 LocalDevVPN。
2. 點選「連線」或畫面上的開關。 〔待確認：按鈕文字〕
3. iPhone 詢問是否加入 VPN 設定時，點選「允許」，再輸入 iPhone 密碼。
4. 確認畫面顯示已連線。
5. 回到 PinFly，點選「重試」。

![](images/ch04-02.png)

*截圖說明：LocalDevVPN 主畫面，顯示已連線的開關。 〔待確認：為實際截圖〕*

![](images/ch04-03.png)

*截圖說明：iPhone 跳出「加入 VPN 設定」的確認視窗。*

## 4.4 有 Wi-Fi 時的連線

PinFly 的定位模擬需要 **Wi-Fi 已連上** 且 **LocalDevVPN 已連線**。

1. 確認 iPhone 已連上 Wi-Fi。
2. 開啟 LocalDevVPN。
3. 回到 PinFly，點選「重試」。

LocalDevVPN 已開啟但仍無法連線時，App 會顯示：

> LocalDevVPN 已開啟但無法連線。請關閉後重新開啟 LocalDevVPN，再點選「重試」。

請關閉 LocalDevVPN 後重新開啟，再點選「重試」。

## 4.5 僅有行動網路時（沒有 Wi-Fi）

PinFly 設定頁列出以下 5 個步驟。 〔待確認：每一步的實機效果〕

1. 開啟 LocalDevVPN。
2. 開啟「飛航模式」。
3. 開啟 Wi-Fi（飛航模式下仍可單獨開啟 Wi-Fi）。 〔待確認：iOS 版本差異〕
4. 回到 PinFly，點選地點。
5. 關閉「飛航模式」。

完成後，模擬位置會保留，即使連線中斷，位置仍維持在原地點。 〔待確認：斷線後保留的時間長度〕

> 第 7 章說明如何以「捷徑」執行這 5 個步驟。

![](images/ch04-04.png)

*截圖說明：PinFly 設定頁「進階」展開後，顯示「僅使用行動網路時：依下列 5 個步驟操作」的清單。*
