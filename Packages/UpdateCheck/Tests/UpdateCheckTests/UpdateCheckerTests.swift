// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import UpdateCheck

/// 測試用的假 fetcher（不發出任何真的網路請求）。
actor FakeFetcher: FeedFetcher {
    enum Behaviour: Sendable {
        case data(Data)
        case error(Error)
    }
    var behaviour: Behaviour
    private(set) var callCount = 0

    init(_ behaviour: Behaviour) { self.behaviour = behaviour }

    func fetch(from url: URL) async throws -> Data {
        callCount += 1
        switch behaviour {
        case .data(let d): return d
        case .error(let e): throw e
        }
    }
}

/// 測試用的記憶體儲存。
final class InMemoryCheckStore: UpdateCheckStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _last: Date?
    private var _skipped: String?
    init(last: Date? = nil, skipped: String? = nil) { _last = last; _skipped = skipped }
    var lastCheckDate: Date? { lock.lock(); defer { lock.unlock() }; return _last }
    var skippedVersion: String? { lock.lock(); defer { lock.unlock() }; return _skipped }
    func setLastCheckDate(_ date: Date?) { lock.lock(); defer { lock.unlock() }; _last = date }
    func setSkippedVersion(_ version: String?) { lock.lock(); defer { lock.unlock() }; _skipped = version }
}

/// 測試用的手動時鐘。
final class ManualClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ now: Date) { _now = now }
    var now: Date { lock.lock(); defer { lock.unlock() }; return _now }
    func advance(by interval: TimeInterval) { lock.lock(); defer { lock.unlock() }; _now = _now.addingTimeInterval(interval) }
}

/// 共用測試工具。
enum TestFeed {
    static let url = URL(string: "https://example.com/feed.json")!

    /// 以 release 陣列組成 feed JSON。
    static func data(_ releases: [(version: String, minimumMacOS: String?, downloadURL: String, critical: Bool, notes: String?)]) throws -> Data {
        let arr = releases.map { r -> [String: Any?] in
            ["version": r.version, "build": 1, "minimumMacOS": r.minimumMacOS as Any?,
             "publishedAt": "2026-10-20T10:00:00+08:00",
             "downloadURL": r.downloadURL, "notes": r.notes as Any?, "critical": r.critical]
        }
        // 手動組 JSON（保留 nil 欄位省略）。
        let cleaned: [[String: Any]] = arr.map { dict in
            var out: [String: Any] = [:]
            for (k, v) in dict { if let v { out[k] = v } }
            return out
        }
        let root: [String: Any] = ["schemaVersion": 1, "releases": cleaned]
        return try JSONSerialization.data(withJSONObject: root)
    }
}

@Suite("UpdateChecker 行為")
struct UpdateCheckerTests {
    /// 目前版本固定為 beta.1，方便與 beta.2 比較。
    private func makeChecker(
        fetcher: FakeFetcher,
        store: InMemoryCheckStore,
        clock: ManualClock,
        currentMacOS: String = "14.5"
    ) -> UpdateChecker {
        UpdateChecker(
            currentVersion: SemanticVersion("0.1.0-beta.1")!,
            currentMacOSVersion: currentMacOS,
            feedURL: TestFeed.url,
            fetcher: fetcher,
            store: store,
            clock: clock
        )
    }

    @Test("自動檢查 24 小時內節流，不打網路")
    func throttledWithin24h() async throws {
        let now = Date()
        let clock = ManualClock(now)
        let store = InMemoryCheckStore(last: now, skipped: nil)
        let fetcher = FakeFetcher(.data(try TestFeed.data([("0.1.0-beta.2", "14.0", "https://example.com/a.pkg", false, nil)])))
        let checker = makeChecker(fetcher: fetcher, store: store, clock: clock)
        await #expect(throws: UpdateCheckError.throttled(nextAllowedDate: now.addingTimeInterval(24 * 60 * 60))) {
            try await checker.check(manual: false)
        }
        #expect(await fetcher.callCount == 0)
    }

    @Test("超過 24 小時後自動檢查放行")
    func allowedAfter24h() async throws {
        let now = Date()
        let clock = ManualClock(now)
        let store = InMemoryCheckStore(last: now.addingTimeInterval(-25 * 60 * 60), skipped: nil)
        let fetcher = FakeFetcher(.data(try TestFeed.data([("0.1.0-beta.2", "14.0", "https://example.com/a.pkg", false, nil)])))
        let checker = makeChecker(fetcher: fetcher, store: store, clock: clock)
        let release = try await checker.check(manual: false)
        #expect(release?.version == "0.1.0-beta.2")
        #expect(await fetcher.callCount == 1)
    }

    @Test("手動檢查不受節流限制")
    func manualIgnoresThrottle() async throws {
        let now = Date()
        let clock = ManualClock(now)
        let store = InMemoryCheckStore(last: now, skipped: nil)
        let fetcher = FakeFetcher(.data(try TestFeed.data([("0.1.0-beta.2", "14.0", "https://example.com/a.pkg", false, nil)])))
        let checker = makeChecker(fetcher: fetcher, store: store, clock: clock)
        let release = try await checker.check(manual: true)
        #expect(release?.version == "0.1.0-beta.2")
        #expect(await fetcher.callCount == 1)
    }

    @Test("略過版本後不再提示該版")
    func skippedVersionSuppressed() async throws {
        let clock = ManualClock(Date())
        let store = InMemoryCheckStore(last: nil, skipped: "0.1.0-beta.2")
        let fetcher = FakeFetcher(.data(try TestFeed.data([("0.1.0-beta.2", "14.0", "https://example.com/a.pkg", false, nil)])))
        let checker = makeChecker(fetcher: fetcher, store: store, clock: clock)
        let release = try await checker.check(manual: true)
        #expect(release == nil)
    }

    @Test("更新的版本照樣提示（略過舊版不影響新版）")
    func newerThanSkippedStillNotifies() async throws {
        let clock = ManualClock(Date())
        let store = InMemoryCheckStore(last: nil, skipped: "0.1.0-beta.2")
        let fetcher = FakeFetcher(.data(try TestFeed.data([
            ("0.1.0-beta.2", "14.0", "https://example.com/a.pkg", false, nil),
            ("0.1.0-beta.3", "14.0", "https://example.com/b.pkg", false, nil),
        ])))
        let checker = makeChecker(fetcher: fetcher, store: store, clock: clock)
        let release = try await checker.check(manual: true)
        #expect(release?.version == "0.1.0-beta.3")
    }

    @Test("重大更新無視略過")
    func criticalIgnoresSkip() async throws {
        let clock = ManualClock(Date())
        let store = InMemoryCheckStore(last: nil, skipped: "0.1.0-beta.2")
        let fetcher = FakeFetcher(.data(try TestFeed.data([("0.1.0-beta.2", "14.0", "https://example.com/a.pkg", true, nil)])))
        let checker = makeChecker(fetcher: fetcher, store: store, clock: clock)
        let release = try await checker.check(manual: true)
        #expect(release?.version == "0.1.0-beta.2")
        #expect(release?.critical == true)
    }

    @Test("最低系統版本不符會被過濾")
    func minimumMacOSFiltered() async throws {
        let clock = ManualClock(Date())
        let store = InMemoryCheckStore()
        let fetcher = FakeFetcher(.data(try TestFeed.data([("0.1.0", "15.0", "https://example.com/a.pkg", false, nil)])))
        let checker = makeChecker(fetcher: fetcher, store: store, clock: clock, currentMacOS: "14.5")
        let release = try await checker.check(manual: true)
        #expect(release == nil)
    }

    @Test("非 https 下載連結被拒")
    func insecureURLRejected() async throws {
        let clock = ManualClock(Date())
        let store = InMemoryCheckStore()
        let fetcher = FakeFetcher(.data(try TestFeed.data([("0.1.0-beta.2", "14.0", "http://example.com/a.pkg", false, nil)])))
        let checker = makeChecker(fetcher: fetcher, store: store, clock: clock)
        await #expect(throws: UpdateCheckError.insecureDownloadURL("http://example.com/a.pkg")) {
            try await checker.check(manual: true)
        }
    }

    @Test("抓取失敗不 crash，回明確錯誤且不更新檢查時間")
    func fetchErrorSurfaced() async throws {
        let now = Date()
        let clock = ManualClock(now)
        let store = InMemoryCheckStore(last: nil, skipped: nil)
        let fetcher = FakeFetcher(.error(UpdateCheckError.networkFailure("斷線")))
        let checker = makeChecker(fetcher: fetcher, store: store, clock: clock)
        await #expect(throws: UpdateCheckError.networkFailure("斷線")) {
            try await checker.check(manual: true)
        }
        #expect(store.lastCheckDate == nil)
    }

    @Test("壞 JSON 不 crash，回解析錯誤")
    func badJSONSurfaced() async throws {
        let clock = ManualClock(Date())
        let store = InMemoryCheckStore()
        let fetcher = FakeFetcher(.data(Data("不是 JSON".utf8)))
        let checker = makeChecker(fetcher: fetcher, store: store, clock: clock)
        do {
            _ = try await checker.check(manual: true)
            Issue.record("預期丟出 decodingFailure，但沒有丟出")
        } catch let e as UpdateCheckError {
            guard case .decodingFailure = e else {
                Issue.record("錯誤型別不符：\(e)")
                return
            }
        }
        #expect(store.lastCheckDate == nil)
    }

    @Test("逾時不 crash，回逾時錯誤")
    func timeoutSurfaced() async throws {
        let clock = ManualClock(Date())
        let store = InMemoryCheckStore()
        let fetcher = FakeFetcher(.error(UpdateCheckError.timeout))
        let checker = makeChecker(fetcher: fetcher, store: store, clock: clock)
        await #expect(throws: UpdateCheckError.timeout) {
            try await checker.check(manual: true)
        }
        #expect(store.lastCheckDate == nil)
    }

    @Test("系統逾時 URLError 會被轉為逾時錯誤")
    func urlErrorTimeoutMapped() async throws {
        let clock = ManualClock(Date())
        let store = InMemoryCheckStore()
        let fetcher = FakeFetcher(.error(URLError(.timedOut)))
        let checker = makeChecker(fetcher: fetcher, store: store, clock: clock)
        await #expect(throws: UpdateCheckError.timeout) {
            try await checker.check(manual: true)
        }
    }

    @Test("已是最新版時回 nil（成功檢查）")
    func noUpdateReturnsNil() async throws {
        let clock = ManualClock(Date())
        let store = InMemoryCheckStore()
        let fetcher = FakeFetcher(.data(try TestFeed.data([("0.1.0-beta.1", "14.0", "https://example.com/a.pkg", false, nil)])))
        let checker = makeChecker(fetcher: fetcher, store: store, clock: clock)
        let release = try await checker.check(manual: true)
        #expect(release == nil)
        #expect(store.lastCheckDate != nil)
    }
}
