# 從原始碼建置注音台

這份說明給想自己編譯 Mac 版注音台的人。編出來的是能打字的版本。

從原始碼建置的版本，選字結果可能與 Releases 的安裝包不同；要日常使用請下載 Releases 的安裝包。

## 需求

- macOS 14 或更新版本
- Apple Silicon
- Xcode 27.0（本樹的專案檔用 XcodeGen 2.45.4 產生；打開 `ZhuyinTai.xcodeproj` 不需要再裝 XcodeGen）

若要依 `scripts/project.yml` 重新產生專案檔，系統上的 `xcodegen --version` 必須是 `2.45.4`，然後執行（從哪個目錄呼叫都可以，專案檔會寫回本樹根目錄）：

```sh
bash scripts/generate_xcodeproj.sh
```

版本不符時腳本會停下來，不會幫你安裝或升級。

## 打開專案

1. 安裝 Xcode 27.0，並打開一次，讓它裝好 macOS 的命令列工具。
2. 用 Xcode 打開本樹根目錄的 `ZhuyinTai.xcodeproj`。
3. Scheme 選 **TWKeyboard**。

專案裡有兩個 target：輸入法 app `TWKeyboard`，以及 `Megrez`。引擎實作在 `ZhuyinTai/OpenCore/BasicEngine/`。`Tests/` 只給測試，不會編進 app。這些檔要在樹裡才編得過。

## 怎麼編

在本樹根目錄：

```sh
xcodebuild \
  -project ZhuyinTai.xcodeproj \
  -scheme TWKeyboard \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO
```

成功的話，app 在：

```text
build/DerivedData/Build/Products/Debug/TWKeyboard.app
```

不需要 Apple 開發者帳號。上面的指令關掉簽章。

## 裝到自己的電腦

編過之後，若要給自己的帳號用：

1. 自編版複製成 `TWKeyboardOSS.app`，不要蓋掉已經在用的官方版 `TWKeyboard.app`。
2. 複製：

```sh
mkdir -p "$HOME/Library/Input Methods"
cp -R build/DerivedData/Build/Products/Debug/TWKeyboard.app "$HOME/Library/Input Methods/TWKeyboardOSS.app"
```

3. 讓系統登錄這個輸入法（會等你在「系統設定」→「鍵盤」按允許，最多約 120 秒）：

```sh
"$HOME/Library/Input Methods/TWKeyboardOSS.app/Contents/MacOS/TWKeyboard" install
```

4. 到「系統設定」→「鍵盤」→「輸入來源」確認注音台出現，再切換過去。

這份說明只告訴你步驟。請自己執行，不要在還開著輸入法的時候覆蓋同一個檔案。

## 自編版與官方版

這個專案的 bundle id 是 `com.kota.xrich.inputmethod.TWKeyboardOSS`，顯示名稱是「注音台（自編版）」。連線名與輸入來源 ID 也用這個前綴，跟官方版分開，所以自編版與官方版可以並存。

貢獻者可改成自己的 bundle id（例如多人各自編一份）。**下面五處要一起改成同一個前綴**，少一處就會和別的版本撞名，或簽章後打不出字：

1. `scripts/project.yml` 裡 TWKeyboard 的 `PRODUCT_BUNDLE_IDENTIFIER`（改完用 `scripts/generate_xcodeproj.sh` 重產專案檔）。
2. `ZhuyinTai/Info.plist` 的 `InputMethodConnectionName`（必須是 bundle id 加 `_Connection`）。
3. `ZhuyinTai/Info.plist` 的 `TISInputSourceID`、`ComponentInputModeDict` 底下的輸入模式 key 與 `tsVisibleInputModeOrderedArrayKey`。
4. `ZhuyinTai/ZhuyinTai.entitlements` 的 `com.apple.security.temporary-exception.mach-register.global-name`（必須與第 2 項完全相同；沙盒 app 只能註冊 entitlement 列出的名字，這一處沒改，簽章後輸入法登得進去卻打不出字，而且 `CODE_SIGNING_ALLOWED=NO` 的建置完全看不出來）。
5. `ZhuyinTai/Base.lproj/InfoPlist.strings` 與 `ZhuyinTai/zh-Hant.lproj/InfoPlist.strings` 裡輸入模式那一行的 key。

在公開樹裡，`scripts/generate_xcodeproj.sh` 只重產 `.xcodeproj`，不會替你改上面第 2 到 5 項；這幾個檔直接編輯即可。

## 注意事項

- 從原始碼建置的版本，選字結果可能與 Releases 的安裝包不同；要日常使用請下載 Releases 的安裝包。
- 只支援 Apple Silicon 上的 macOS 14 或更新版本。
- 引擎在 `ZhuyinTai/OpenCore/BasicEngine/`。`Tests/` 不會編進 app。
- 已知差異：隱私說明裡的日誌路徑仍寫死官方版容器 `~/Library/Containers/com.kota.xrich.inputmethod.TWKeyboard/Data/Library/Logs/TWKeyboard/`（`MacPrivacyCopy.swift`）。自編版實際寫在自己的容器，路徑裡的 id 是 `TWKeyboardOSS`。程式先不改。
- 詞庫投稿的格式檢查是另一支工具，見 `tools/lexcheck/README.md`。
