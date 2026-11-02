# 第 4 章：LocalDevVPN

**先看這裡**：PinFly 透過 LocalDevVPN 連到手機自己的定位服務。定位送不出去、或畫面顯示「連不到手機」時，幾乎都是 LocalDevVPN 沒開或沒連上。

## 4.1 LocalDevVPN 是什麼

| 詞 | 白話說明 |
|---|---|
| VPN（虛擬私人網路） | iPhone 內建的一種網路通道設定。LocalDevVPN 用它建立一條給 PinFly 使用的本機通道 |
| LocalDevVPN | 一支免費 App，負責開啟這條通道 |
| 本機通道 | 只在這支 iPhone 內部使用的連線，不是讓你上網的 VPN 〔待確認：實際流量走向〕 |

## 4.2 安裝 LocalDevVPN

1. 打開 App Store。
2. 搜尋「LocalDevVPN」，或直接開啟 `https://apps.apple.com/us/app/localdevvpn/id6755608044`。
3. 按「取得」安裝。

![](images/ch04-01.png)

*截圖說明：App Store 中 LocalDevVPN 的頁面，標出「取得」按鈕。*

## 4.3 開啟 LocalDevVPN

1. 打開 LocalDevVPN。
2. 按「連線」或畫面上的開關。 〔待確認：按鈕文字〕
3. 如果 iPhone 跳出「要加入 VPN 設定」，按「允許」，再輸入 iPhone 密碼。
4. 確認畫面顯示已連線。
5. 回到 PinFly，按「重試」。

![](images/ch04-02.png)

*截圖說明：LocalDevVPN 主畫面，顯示已連線的開關。 〔待確認：為實際截圖〕*

![](images/ch04-03.png)

*截圖說明：iPhone 跳出「加入 VPN 設定」的確認視窗。*

## 4.4 有 Wi-Fi 時的連線

PinFly 的定位模擬需要 **Wi-Fi 已連上** 而且 **LocalDevVPN 已連線**，兩個都要。

1. 確認 iPhone 已連上 Wi-Fi。
2. 開啟 LocalDevVPN。
3. 回到 PinFly，按「重試」。

如果 LocalDevVPN 開著仍連不上，App 會顯示：

> LocalDevVPN 開著還是連不到：請把它關掉再打開，然後按「重試」。

照做即可：關掉 LocalDevVPN，再打開，然後按「重試」。

## 4.5 只有 4G 時（沒有 Wi-Fi）

PinFly 內建的說明是以下 5 步。 〔待確認：每一步的實機效果〕

1. 開 LocalDevVPN。
2. 開啟「飛航模式」。
3. 開啟 Wi-Fi（飛航模式下仍可單獨開 Wi-Fi）。 〔待確認：iOS 版本差異〕
4. 回到 PinFly，點地點。
5. 關閉「飛航模式」。

完成後，假定位會保留。 App 的說明是「假定位會保留」，也就是即使你斷線，定位仍會維持原來的地點。 〔待確認：斷線後保留的時間長度〕

> 第 7 章會教你用「捷徑」把這 5 步做成一鍵。

![](images/ch04-04.png)

*截圖說明：PinFly 設定頁「進階」展開後，顯示「只有 4G：照這 5 步」的清單。*
