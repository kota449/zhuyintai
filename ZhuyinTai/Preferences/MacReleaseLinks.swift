// SPDX-License-Identifier: Apache-2.0
import Foundation

/// 偏好設定裡指向發行頁的連結：「網站」（repo 首頁）、「下載頁」（releases，檢查更新連不上時使用者自己去看有沒有新版）
/// 與「隱私說明」（repo 內的 docs/PRIVACY.md）。
///
/// 依據：2026-10-06 決定——發行物放公開 repo `kota449/zhuyintai`。
/// ⚠️ 該 repo 目前是 PRIVATE：外部使用者現在點了會 404（上線前要改公開；本檔不處理）。
/// `release/` 資料夾的內容會原樣放到那個 repo 的根目錄，所以 `release/docs/PRIVACY.md` ＝ 網址裡的 `docs/PRIVACY.md`
/// （`tools/test_mac_release_links.sh` 守住這個對應）。
///
/// 純 Foundation（render_mac_prefs.sh 用純 swiftc 編偏好設定）。
enum MacReleaseLinks {
    static let homePage = "https://github.com/kota449/zhuyintai"
    static let releasesPage = "https://github.com/kota449/zhuyintai/releases"
    static let privacyPage = "https://github.com/kota449/zhuyintai/blob/main/docs/PRIVACY.md"

    static var homeURL: URL? { URL(string: homePage) }
    static var releasesURL: URL? { URL(string: releasesPage) }
    static var privacyURL: URL? { URL(string: privacyPage) }
}
