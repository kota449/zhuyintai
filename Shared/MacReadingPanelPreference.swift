// SPDX-License-Identifier: Apache-2.0
import Foundation

/// 「顯示注音浮窗」開關。缺鍵時預設開，跟 `@AppStorage` 的預設值同一套。
enum MacReadingPanelPreference {
    static let defaultsKey = "TWKeyboard.showReadingPanel"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: defaultsKey) != nil else { return true }
        return defaults.bool(forKey: defaultsKey)
    }

    /// 關掉、沒有欄位、或錨點未知時，`show` 應直接藏起來。
    static func shouldPresent(enabled: Bool, hasColumns: Bool, anchorIsKnown: Bool) -> Bool {
        enabled && hasColumns && anchorIsKnown
    }
}
