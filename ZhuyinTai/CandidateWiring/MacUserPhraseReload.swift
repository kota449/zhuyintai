// SPDX-License-Identifier: Apache-2.0
import Foundation

/// 自訂詞新增或刪除之後，通知同一個 process 裡每一顆引擎重讀詞庫。
enum MacUserPhraseReload {
    static let didChange = Notification.Name("TWKeyboard.userPhrasesDidChange")

    /// 劇本沒有沙箱家目錄，`platformContainerURL()` 會是 nil。測兩顆引擎時指到暫存容器。
    static var containerOverride: URL?

    static func postChange() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func containerURL() -> URL? {
        containerOverride ?? MacUserPhrasesLocation.platformContainerURL()
    }
}
