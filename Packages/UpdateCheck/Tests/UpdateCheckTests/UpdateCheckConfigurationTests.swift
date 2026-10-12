// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import UpdateCheck

/// Info.plist → 更新檢查設定。核心不變式：**資料不全或 slug 是佔位 ⇒ nil ⇒ 呼叫方不發任何網路請求**。
@Suite("UpdateCheckConfiguration（Info.plist → 設定）")
struct UpdateCheckConfigurationTests {
    private func plist(version: Any? = "0.1.0-beta.1", repo: Any? = "kota449/zhuyintai") -> [String: Any] {
        var d: [String: Any] = [:]
        if let version { d["TWKReleaseVersion"] = version }
        if let repo { d["TWKReleaseRepo"] = repo }
        return d
    }

    @Test("正常資料：currentVersion 取 TWKReleaseVersion（完整 SemVer，含 -beta.1）、feedURL 由 slug 組")
    func happyPath() throws {
        let c = try #require(UpdateCheckConfiguration(infoDictionary: plist()))
        #expect(c.currentVersion == SemanticVersion("0.1.0-beta.1"))
        #expect(c.feedURL.absoluteString == "https://raw.githubusercontent.com/kota449/zhuyintai/main/feed.json")
    }

    @Test("beta.1 比 0.1.0-beta.2 舊（接線後 beta 使用者收得到下一個 beta）")
    func betaOrdering() throws {
        let c = try #require(UpdateCheckConfiguration(infoDictionary: plist()))
        #expect(c.currentVersion < SemanticVersion("0.1.0-beta.2")!)
    }

    @Test("佔位 slug → nil（不發請求）", arguments: ["OWNER/RELEASE-REPO", "OWNER/zhuyintai", "kota449/RELEASE-REPO"])
    func placeholderRepo(repo: String) {
        #expect(UpdateCheckConfiguration(infoDictionary: plist(repo: repo)) == nil)
    }

    @Test("缺 TWKReleaseVersion → nil（不可退回 CFBundleShortVersionString：0.1.0 > 0.1.0-beta.N 會誤判）")
    func missingVersion() {
        var d = plist(version: nil)
        d["CFBundleShortVersionString"] = "0.1.0"
        #expect(UpdateCheckConfiguration(infoDictionary: d) == nil)
    }

    @Test("缺 slug／空字串／未展開的 $(…)／格式不合 → nil",
          arguments: [nil, "", "   ", "$(TWK_RELEASE_REPO)", "no-slash", "a/b/c", "a b/c", "/x", "x/", "evil.com/../x"] as [String?])
    func badRepo(repo: String?) {
        #expect(UpdateCheckConfiguration(infoDictionary: plist(repo: repo)) == nil)
    }

    @Test("版本字串不合法／未展開 → nil", arguments: ["", "$(TWK_RELEASE_VERSION)", "0.1", "abc"])
    func badVersion(version: String) {
        #expect(UpdateCheckConfiguration(infoDictionary: plist(version: version)) == nil)
    }

    @Test("字典是 nil、值型別不是字串 → nil")
    func wrongTypes() {
        #expect(UpdateCheckConfiguration(infoDictionary: nil) == nil)
        #expect(UpdateCheckConfiguration(infoDictionary: plist(version: 1)) == nil)
        #expect(UpdateCheckConfiguration(infoDictionary: plist(repo: 5)) == nil)
    }

    @Test("macOS 版本字串用主.次.修（不可用 operatingSystemVersionString——它會被解析成 [0,1]，minimumMacOS 永遠判不符）")
    func macOSVersionString() {
        #expect(UpdateCheckConfiguration.macOSVersionString(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 1)) == "27.0.1")
        #expect(UpdateCheckConfiguration.macOSVersionString(OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)) == "14.5.0")
        // 與既有比較邏輯相容：feed 要求 14.0 在 27.0.1 上判為符合
        #expect(UpdateChecker.isMacOSCompatible(minimum: "14.0", current: "27.0.1"))
    }
}
