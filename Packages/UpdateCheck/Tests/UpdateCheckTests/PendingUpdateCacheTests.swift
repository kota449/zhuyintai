// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import UpdateCheck

/// 「已找到、還沒處理的新版」要能跨輸入法重啟存活：
/// 24 小時節流存在 UserDefaults，重啟後 `checkAutomatically()` 會被節流擋掉，
/// 若新版只存在記憶體，選單項與關於頁的提示會在重啟後消失最多 24 小時。
@Suite("PendingUpdateCache（新版提示跨重啟）")
struct PendingUpdateCacheTests {
    private func makeCache() -> PendingUpdateCache {
        let name = "PendingUpdateCacheTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return PendingUpdateCache(defaults: d)
    }

    private func release(_ v: String, critical: Bool = false) -> Release {
        Release(version: v, build: 2, minimumMacOS: "14.0", publishedAt: nil,
                downloadURL: URL(string: "https://example.com/\(v).pkg")!, notes: "說明", critical: critical)
    }

    private let current = SemanticVersion("0.1.0-beta.1")!

    @Test("存檔後讀回同一版（欄位完整）")
    func roundTrip() {
        let cache = makeCache()
        cache.save(release("0.1.0-beta.2", critical: true))
        let r = cache.load(currentVersion: current, skippedVersion: nil)
        #expect(r?.version == "0.1.0-beta.2")
        #expect(r?.downloadURL.absoluteString == "https://example.com/0.1.0-beta.2.pkg")
        #expect(r?.notes == "說明")
        #expect(r?.critical == true)
    }

    @Test("沒存過 → nil")
    func empty() {
        #expect(makeCache().load(currentVersion: current, skippedVersion: nil) == nil)
    }

    @Test("使用者已更新到該版（目前版本 ≥ 快取版本）→ nil，不再提示舊的新版")
    func alreadyUpdated() {
        let cache = makeCache()
        cache.save(release("0.1.0-beta.2"))
        #expect(cache.load(currentVersion: SemanticVersion("0.1.0-beta.2")!, skippedVersion: nil) == nil)
        #expect(cache.load(currentVersion: SemanticVersion("0.1.0")!, skippedVersion: nil) == nil)
    }

    @Test("略過的版本 → nil；但重大更新無視略過")
    func skipped() {
        let cache = makeCache()
        cache.save(release("0.1.0-beta.2"))
        #expect(cache.load(currentVersion: current, skippedVersion: "0.1.0-beta.2") == nil)
        cache.save(release("0.1.0-beta.3", critical: true))
        #expect(cache.load(currentVersion: current, skippedVersion: "0.1.0-beta.3")?.version == "0.1.0-beta.3")
    }

    @Test("clear 之後讀不到")
    func clear() {
        let cache = makeCache()
        cache.save(release("0.1.0-beta.2"))
        cache.clear()
        #expect(cache.load(currentVersion: current, skippedVersion: nil) == nil)
    }

    @Test("非 https 下載連結即使被存進去也不會被讀出（與 UpdateChecker 同一條安全規則）")
    func insecureRejected() {
        let cache = makeCache()
        cache.save(Release(version: "0.1.0-beta.2", downloadURL: URL(string: "http://example.com/a.pkg")!))
        #expect(cache.load(currentVersion: current, skippedVersion: nil) == nil)
    }

    @Test("壞資料不當機 → nil")
    func corrupt() {
        let name = "PendingUpdateCacheTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.set(Data("not json".utf8), forKey: PendingUpdateCache.defaultKey)
        #expect(PendingUpdateCache(defaults: d).load(currentVersion: current, skippedVersion: nil) == nil)
    }
}
