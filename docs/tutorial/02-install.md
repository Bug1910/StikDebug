# 第 2 章：安裝 PinFly 與開發者模式

**重點**：安裝方式有兩種：方法 A 使用電腦上的 iloader（側載安裝工具）；方法 B 使用 iPhone 上的 SideStore（側載工具）。第一次安裝建議使用方法 A。

## 2.1 取得安裝檔

1. 到 PinFly 的 GitHub 發布頁下載最新的 `.ipa` 安裝檔。 〔待確認：正式發布頁網址與檔名〕
2. 將檔案存到電腦的「下載」資料夾。
3. 請勿更改檔名或解壓縮。

## 2.2 方法 A：以電腦上的 iloader 安裝

iloader 是免費的電腦工具，可將 IPA 安裝至 iPhone。 〔待確認：下載網址與最新版本〕

1. 以 USB 傳輸線連接 iPhone 與電腦。
2. 在 iPhone 上點選「信任」，並輸入 iPhone 密碼。 〔待確認：畫面文字〕
3. 開啟 iloader。
4. 確認 iloader 的「目前裝置」顯示你的 iPhone 名稱。 〔待確認：畫面位置〕
5. 點選 `Import IPA`（匯入安裝檔）。 〔待確認：按鈕文字〕
6. 選擇剛才下載的 `.ipa` 檔。
7. 輸入你的 Apple ID 與密碼。
8. 收到 Apple 傳送的 6 位數驗證碼時，輸入至 iloader。
9. 畫面顯示安裝完成後，在 iPhone 主畫面找到 PinFly。

![](images/ch02-01.png)

*截圖說明：iloader 主畫面，標出「目前裝置」與安裝 IPA 的按鈕位置。 〔待確認：畫面為實際截圖後替換〕*

![](images/ch02-02.png)

*截圖說明：iloader 選擇 IPA 檔案的視窗，檔名列表中選中 PinFly 的 `.ipa` 檔。*

## 2.3 方法 B：以 SideStore 安裝

SideStore 是安裝於 iPhone 的側載工具。已使用 SideStore 時可直接安裝。

1. 開啟 SideStore。
2. 點選右上角或下方的「＋」。 〔待確認：按鈕位置〕
3. 選擇 PinFly 的 `.ipa` 檔（請先以「檔案」App 將 IPA 存至 iPhone）。
4. 等待安裝完成。

![](images/ch02-03.png)

*截圖說明：SideStore 的「＋」按鈕與安裝 IPA 的選擇畫面。 〔待確認：畫面為實際截圖後替換〕*

## 2.4 信任開發者（以免費 Apple ID 安裝時）

以免費 Apple ID 側載的 App，第一次開啟前需先信任安裝時使用的 Apple ID。

1. 開啟「設定」›「一般」，點選「VPN 與裝置管理」。
2. 有「開發者 App」區塊時，點選安裝時使用的 Apple ID（此區塊不一定會出現，未出現時略過第 2、3 步）。
3. 點選「信任」，在提示中再確認一次。

Apple 對同一路徑的說明（企業 App 版本）寫明：路徑為「設定」>「一般」>「VPN 與裝置管理」；iOS 18 以後按鈕可能是「允許並重新啟動」，較早版本是「信任」（https://support.apple.com/zh-tw/118254）。 〔待確認：免費 Apple ID 側載的 App 在 iOS 18／26 是否同樣顯示「允許並重新啟動」〕

![](images/guide_sys_02.png)

*截圖說明：「VPN 與裝置管理」頁面，開發者 App 區列出安裝時使用的 Apple ID。*

![](images/guide_sys_03.png)

*截圖說明：點進 Apple ID 後的「信任」按鈕與確認提示。*

## 2.5 開啟開發者模式

PinFly 是開發者簽名的 App。Apple 說明開發者模式用於確認使用者了解安裝開發者簽名軟體的風險；「開發者模式」要在 iPhone 與電腦配對過後才會出現在設定中（https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device）。因此請先完成 2.2 的連接與安裝。

1. 開啟「設定」›「隱私權與安全性」。
2. 捲到最下方，在「安全性」區點選「開發者模式」。
3. 開啟「開發者模式」開關。
4. 在跳出的警示中確認重新啟動。 〔待確認：繁中按鈕文字，Apple 英文文件為「Restart」〕
5. 重新開機後解鎖，在警示中確認開啟（Apple 英文文件為「Enable」） 〔待確認：繁中按鈕文字〕，再輸入 iPhone 密碼。

![](images/guide_sys_04.png)

*截圖說明：「隱私權與安全性」頁面最下方「安全性」區的「開發者模式」列。*

![](images/guide_sys_05.png)

*截圖說明：開發者模式開關已開啟，畫面跳出重新啟動警示。*

![](images/guide_sys_06.png)

*截圖說明：重新開機後出現的開啟開發者模式確認警示。*

## 2.6 第一次開啟

1. 在 iPhone 主畫面點選 PinFly。
2. 首頁會顯示地圖與「尚未配對」提示，請依第 3 章匯入配對檔。
3. 第一次前往地點時，iPhone 會詢問位置權限，請選擇允許（見第 6 章）。

![](images/ch02-04.png)

*截圖說明：第一次開啟 PinFly 時的首頁，上方出現「尚未配對」提示卡。*

> 以免費 Apple ID 安裝的 App 只能使用 7 天，續簽方式請見第 5 章。
