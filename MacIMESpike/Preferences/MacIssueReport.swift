// SPDX-License-Identifier: Apache-2.0
import Foundation

/// 關於頁「回報問題」：組出發行 repo 的 issue form 網址，title 與版本資訊用 query 預填。
///
/// 依據：2026-10-06 決定②——回報走發行 repo（`kota449/zhuyintai`）的 GitHub Issues。
/// ⚠️ 該 repo 目前是 PRIVATE：外部使用者現在點了會 404（上線前要改公開並開 Issues）。
///
/// 預填規則（GitHub 官方文件）：
/// - `template=<檔名>` 直接開該 issue form，不經範本選單；`title` 預填標題。
///   https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/creating-an-issue#creating-an-issue-from-a-url-query
/// - 表單欄位用該欄位的 `id` 當 query key 預填（文件只明講 custom text fields，即 input／textarea；
///   dropdown／checkboxes 文件未記載，所以不預填）。
///   https://docs.github.com/en/communities/using-templates-to-encourage-useful-issues-and-pull-requests/syntax-for-githubs-form-schema#keys
/// - **不帶 `labels`**：文件寫明用 query 加標籤要有對應權限，沒權限整條網址回 404；
///   標籤改由 yml 的 `labels:` 自動掛。也不帶 `body`：用 form 就不該再塞 markdown 內文。
///
/// 隱私：網址只放 `MacDiagnostics.report()`（版本與 macOS build）與固定的 template／title；
/// **不帶任何打字內容或 log**。純 Foundation（render_mac_prefs.sh 用純 swiftc 編偏好設定）。
enum MacIssueReport {
    static let issuesNewBase = "https://github.com/kota449/zhuyintai/issues/new"
    /// 發行 repo `.github/ISSUE_TEMPLATE/` 底下的 issue form 檔名（本 repo 的副本在 `release/.github/ISSUE_TEMPLATE/`）。
    static let templateName = "bug_report.yml"
    static let title = "[回報] "
    /// 該 form 裡接版本資訊的欄位 id（`input`，單行）。
    static let versionFieldID = "version"
    /// 網址總長上限。瀏覽器與 GitHub 對過長 URL 會 414；診斷文字異常長時截斷，不產生壞網址。
    static let maxURLLength = 6000
    private static let lineSeparator = " ／ "

    /// `version` 是單行 input：瀏覽器會把 value 裡的換行直接剝掉，兩行會黏成一串，
    /// 所以組網址時把診斷文字的換行換成固定分隔字（剪貼簿裡的原文不動）。
    static func versionField(report: String) -> String {
        report
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: lineSeparator)
    }

    static func url(report: String) -> URL? {
        var text = report
        while true {
            let candidate = build(report: text)
            if candidate.count <= maxURLLength { return URL(string: candidate) }
            guard !text.isEmpty else { return nil }
            text = String(text.prefix(max(0, text.count / 2)))
        }
    }

    private static func build(report: String) -> String {
        let query = [
            "template=\(encode(templateName))",
            "title=\(encode(title))",
            "\(versionFieldID)=\(encode(versionField(report: report)))",
        ].joined(separator: "&")
        return "\(issuesNewBase)?\(query)"
    }

    /// 只放行 RFC 3986 的 unreserved 字元；`+`、`&`、`=`、`#`、`%`、空白、中文、換行全部百分比編碼
    /// （`URLQueryItem` 不編 `+`，GitHub 會把它讀成空白）。
    private static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
