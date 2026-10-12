// SPDX-License-Identifier: Apache-2.0
import Foundation

/// 把 App 的 Info.plist 轉成更新檢查所需的設定（純函式，可單獨測試）。
///
/// 核心不變式：**資料不全、格式不合、或 slug 還是佔位值 ⇒ 回 `nil` ⇒ 呼叫方不發任何網路請求。**
///
/// - 目前版本取自 `TWKReleaseVersion`（完整 SemVer，例如 `0.1.0-beta.1`），**不可**退回
///   `CFBundleShortVersionString`：後者只能放 `0.1.0`，而 `0.1.0 > 0.1.0-beta.N`，
///   會讓 beta 使用者永遠收不到下一個 beta。
/// - feed 網址由 `TWKReleaseRepo`（`擁有者/repo` slug）組成：
///   `https://raw.githubusercontent.com/<slug>/main/feed.json`（不用 `releases/latest/download`，
///   因為 latest 不含 pre-release）。
public struct UpdateCheckConfiguration: Sendable, Equatable {
    /// 目前 App 的完整語意化版本。
    public let currentVersion: SemanticVersion
    /// feed JSON 網址。
    public let feedURL: URL

    public init(currentVersion: SemanticVersion, feedURL: URL) {
        self.currentVersion = currentVersion
        self.feedURL = feedURL
    }

    /// 從 Info.plist 字典建立；任何一項缺漏或不合法就回 `nil`。
    public init?(infoDictionary: [String: Any]?) {
        guard let info = infoDictionary,
              let rawVersion = (info["TWKReleaseVersion"] as? String)?.trimmingCharacters(in: .whitespaces),
              let version = SemanticVersion(rawVersion),
              let rawRepo = (info["TWKReleaseRepo"] as? String)?.trimmingCharacters(in: .whitespaces),
              let slug = Self.validatedSlug(rawRepo),
              let url = URL(string: "https://raw.githubusercontent.com/\(slug)/main/feed.json")
        else { return nil }
        self.init(currentVersion: version, feedURL: url)
    }

    /// 把 `OperatingSystemVersion` 組成「主.次.修」字串（供 `minimumMacOS` 比較）。
    ///
    /// 🔴 不可用 `ProcessInfo.operatingSystemVersionString`：它長得像
    /// `Version 27.0.1 (Build 26A434)`，被點分數字解析會變成 `[0, 1]`，
    /// 讓 feed 的 `minimumMacOS: "14.0"` 永遠判為不符 ⇒ 更新永遠不提示。
    public static func macOSVersionString(_ v: OperatingSystemVersion) -> String {
        "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// slug 必須是 `擁有者/名稱`（各段只含英數、`.`、`_`、`-`，且不是 `.`／`..`），
    /// 並且不得是佔位值（`OWNER` 或 `RELEASE-REPO`）。合格回 slug，否則 `nil`。
    static func validatedSlug(_ raw: String) -> String? {
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        for p in parts {
            guard !p.isEmpty, p != ".", p != "..",
                  p.unicodeScalars.allSatisfy({ allowed.contains($0) })
            else { return nil }
        }
        if parts[0] == "OWNER" || parts[1] == "RELEASE-REPO" { return nil }
        return raw
    }
}
