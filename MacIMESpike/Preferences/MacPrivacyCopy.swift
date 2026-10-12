// SPDX-License-Identifier: Apache-2.0
import Foundation

/// 「隱私」分頁底下「資料怎麼處理」的白話說明。
///
/// 🔴 以 `release/docs/PRIVACY.md` 為準：這裡的句子盡量和它逐字相同，不自己編新的承諾。
/// `docAnchors` 是「兩邊都必須出現」的片段，`tools/test_mac_privacy_copy.sh` 逐一檢查；
/// PRIVACY.md 改了行為、這裡沒跟著改，測試會轉紅。
///
/// 「密碼欄位不記」這句**不放在這裡**：它的實機驗證還沒做（10-06 決定驗不過就刪句），
/// 只留在 `MacLogConsentCopy.settingsCaption` 一處，免得刪句時漏掉。
///
/// 純 Foundation（render_mac_prefs.sh 用純 swiftc 編偏好設定）。
enum MacPrivacyCopy {
    struct Row: Equatable {
        let title: String
        let body: String
    }

    static let sectionTitle = "資料怎麼處理"
    static let fullPolicyButton = "完整隱私說明"

    /// 顯示給使用者看的 log 資料夾（輸入法在 sandbox 裡，實際位置在容器內）。
    static let logDirectoryDisplayPath =
        "~/Library/Containers/com.kota.xrich.inputmethod.TWKeyboard/Data/Library/Logs/TWKeyboard/"

    static let rows: [Row] = [
        Row(
            title: "資料存在哪",
            body: "記錄只存在你自己的 Mac，不會自己送到任何地方。一天一個檔，只保留約一週，放在這個資料夾："
                + "\n" + logDirectoryDisplayPath
        ),
        Row(
            title: "會記什麼",
            body: "你按的鍵、出現的候選字、最後打出來的字，以及時間和你正在打字的 App 的識別名稱。"
                + "\n記錄檔裡有你打的字。要把它交給別人（包括我們）之前，請自己打開看過。"
                + "注音台不會讀取你的剪貼簿。"
        ),
        Row(
            title: "選字記憶",
            body: "打開「記住我的選字」之後，你在候選窗改選過的字會記在你的 Mac 上，下次同樣的前文與讀音優先給你。只存在本機。"
        ),
        Row(
            title: "網路",
            body: "注音台只會連線檢查有沒有新版，不會傳送你打的任何字。"
                + "連到 GitHub 的 raw.githubusercontent.com，讀一份公開的版本資訊檔；"
                + "自動檢查每天最多一次，你在「關於」按「檢查更新」時也會檢查一次。"
                + "\n不傳送你打的字、候選字、你正在用的 App 名稱或任何記錄；"
                + "GitHub 會看到你的 IP 位址與注音台的版本資訊。"
                + "\n想完全不連線，到「關於」把「自動檢查新版」關掉。"
                + "有新版時只通知、不安裝，要不要下載、安裝由你決定。"
        ),
        Row(
            title: "怎麼刪",
            body: "關掉「記錄打字過程」之後不再記錄，過期的舊記錄檔仍會在一週後被刪掉。"
                + "想現在就刪光，按「清除使用紀錄」；記住的選字按「清除選字記憶」。"
        ),
    ]

    /// 必須同時出現在上面的說明與 PRIVACY.md 的片段（PRIVACY.md 的粗體、反引號標記不算）。
    static let docAnchors = [
        "記錄只存在你自己的 Mac",
        "不會自己送到任何地方",
        "只保留約一週",
        "一天一個檔",
        logDirectoryDisplayPath,
        "你按的鍵、出現的候選字、最後打出來的字",
        "記錄檔裡有你打的字",
        "只會連線檢查有沒有新版",
        "raw.githubusercontent.com",
        "每天最多一次",
        "不傳送你打的字、候選字、你正在用的 App 名稱或任何記錄",
        "GitHub 會看到你的 IP 位址與注音台的版本資訊",
        "自動檢查新版",
        "只通知、不安裝",
        "清除使用紀錄",
        "清除選字記憶",
        "不會讀取你的剪貼簿",
        "你在候選窗改選過的字會記在你的 Mac 上",
        "只存在本機",
    ]
}
