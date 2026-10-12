# UpdateCheck（Beta 更新檢查套件）

獨立 Swift 套件：定期檢查是否有新版，有的話提示使用者前往下載。
**只負責「通知」，不下載、不安裝任何東西。**

## 系統需求

- macOS 14+、Swift 6、Swift Testing（`import Testing`）。
- 本套件不會寫入 `~/Library/Input Methods`，不會下載檔案，不會執行外部程式。
- 唯一網路行為：以 `URLSession` `GET` 一個建構時注入的 feed JSON 網址（逾時 10 秒）。

## 整合方式

### 1. 加入套件

將本目錄作為本地套件加入主專案，或複製 `Sources/UpdateCheck` 內的檔案。

### 2. 準備 feed JSON（放置位置由你們決定）

feed 由你們託管（例如官網靜態檔案或 CDN），格式見 `Examples/feed.json`：

```json
{"schemaVersion":1,
 "releases":[{"version":"0.1.0-beta.2","build":12,"minimumMacOS":"14.0",
              "publishedAt":"2026-10-20T10:00:00+08:00",
              "downloadURL":"https://example.com/ZhuyinTai-0.1.0-beta.2.pkg",
              "notes":"修正……","critical":false}]}
```

（發行用的範本在 `release/feed/feed.json`，版號由 `Config/Version.xcconfig` 決定。）

欄位說明：`version` 必須是 SemVer 2.0（壞字串會被跳過）；`minimumMacOS`
缺省表示無系統限制；`downloadURL` 只接受 `https`；`critical=true`
表示重大更新（無視「略過這個版本」）。

### 3. 建構參數與呼叫範例

```swift
import UpdateCheck

// 建構參數：全部由呼叫方注入。
let store = UserDefaultsCheckStore(
    defaults: UserDefaults(suiteName: "com.example.TWKeyboard.updatecheck")!
)
guard let raw = Bundle.main.object(forInfoDictionaryKey: "TWKReleaseVersion") as? String,
      let currentVersion = SemanticVersion(raw) else { return } // 沒有完整版號就不做更新檢查
let checker = UpdateChecker(
    // 完整 SemVer 讀 Info.plist 的 TWKReleaseVersion（含 -beta.N）；不要用 CFBundleShortVersionString：
    // 它依 Apple 規定只能是 0.1.0，而 0.1.0 > 0.1.0-beta.N，裝了 beta 的人會永遠看不到下一個 beta。
    // 不要強制解包：app 若不是用 Config/Version.xcconfig 建的，鍵會不存在——跳過檢查比閃退好。
    currentVersion: currentVersion,
    // ⚠️ 不要傳 operatingSystemVersionString：它長得像 "Version 27.0.1 (Build 26A434)"，
    // compareDottedNumeric 會解析成 [0, 1]（2026-10-06 實測），minimumMacOS 永遠判不符、更新永遠不提示。
    // 要傳 operatingSystemVersion 組出的 "主.次.修"：
    currentMacOSVersion: {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }(),
    feedURL: URL(string: "https://example.com/feed.json")!,
    fetcher: URLSessionFeedFetcher(), // 內部只用 URLSession，逾時 10 秒
    store: store
)

// 自動檢查（24 小時最多一次；被節流時丟出 `.throttled`，請直接忽略）：
Task {
    do {
        if let release = try await checker.check(manual: false) {
            await MainActor.run { showPrompt(for: release) }
        }
    } catch UpdateCheckError.throttled {
        // 節流中：什麼都不做。
    } catch {
        // 記錄日誌即可，不要打擾使用者（也不算一次成功檢查）。
        print("更新檢查失敗：\(error)")
    }
}
```

手動檢查（「檢查更新」按鈕）：`try await checker.check(manual: true)`，
不受 24 小時節流限制。

### 4. 顯示提示視窗

```swift
import SwiftUI

UpdatePromptView(
    release: release,
    onSkip: { checker.skip(version: release.version) }, // 「略過這個版本」
    onLater: { /* 關閉視窗，下次再提醒 */ }              // 「稍後提醒」
)
// 「前往下載」會經由 URLOpener 用 NSWorkspace.open 開瀏覽器。
```

### 5. 執行緒假設與 MainActor

- `UpdateChecker.check(manual:)`、`FeedFetcher`、`UpdateCheckStore`、
  `Clock`：可在任意執行緒呼叫（皆為 `Sendable`，檢查本身跑在背景）。
- 必須在 MainActor：`UpdatePromptView`（SwiftUI View）、`URLOpener.open(_:)`
  （內部呼叫 `NSWorkspace.shared.open`）。
- `UserDefaultsCheckStore` 內部以鎖保護，可在背景執行緒讀寫。

### 6. 錯誤處理對照

| 情況 | 行為 |
|---|---|
| 被 24 小時節流擋下 | 丟出 `.throttled(nextAllowedDate:)`，不打網路 |
| 抓取失敗／逾時（10 秒） | 丟出 `.networkFailure`／`.timeout`，不更新上次檢查時間 |
| JSON 壞掉 | 丟出 `.decodingFailure`，不 crash |
| 非 `https` 下載連結 | 丟出 `.insecureDownloadURL`，視為沒有更新並記錄錯誤（內部已寫 `Logger`） |
| 無更新／已略過／系統不符 | 回傳 `nil`，並更新上次檢查時間 |

## 測試

```sh
swift test --disable-sandbox
```

測試一律用假 fetcher，不發出真的網路請求。
