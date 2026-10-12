// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import UpdateCheck

/// `checkAutomatically()`：對外宣稱「自動檢查每天最多一次」的依據。
/// 與 `check(manual:)` 的差別只有一點——**失敗的嘗試也算一次**（否則 feed 還不存在或斷網時，
/// 每次啟用輸入法都會重打一次請求）。`check(manual:)` 本身的行為不變（既有測試仍釘著「失敗不更新檢查時間」）。
@Suite("checkAutomatically（失敗也計入 24 小時節流）")
struct AutomaticCheckTests {
    private func makeChecker(fetcher: FakeFetcher, store: InMemoryCheckStore, clock: ManualClock) -> UpdateChecker {
        UpdateChecker(
            currentVersion: SemanticVersion("0.1.0-beta.1")!,
            currentMacOSVersion: "14.5",
            feedURL: TestFeed.url,
            fetcher: fetcher,
            store: store,
            clock: clock
        )
    }

    @Test("網路失敗：第一次丟錯並記下嘗試；24 小時內第二次被節流且不再打網路；24 小時後才再試一次")
    func failureCountsTowardThrottle() async throws {
        let now = Date()
        let clock = ManualClock(now)
        let store = InMemoryCheckStore(last: nil, skipped: nil)
        let fetcher = FakeFetcher(.error(UpdateCheckError.networkFailure("斷線")))
        let checker = makeChecker(fetcher: fetcher, store: store, clock: clock)

        await #expect(throws: UpdateCheckError.networkFailure("斷線")) {
            try await checker.checkAutomatically()
        }
        #expect(await fetcher.callCount == 1)
        #expect(store.lastCheckDate == now)

        // 同一時刻再來一次：被節流，不打網路
        await #expect(throws: UpdateCheckError.throttled(nextAllowedDate: now.addingTimeInterval(24 * 60 * 60))) {
            try await checker.checkAutomatically()
        }
        #expect(await fetcher.callCount == 1)

        // 23 小時後仍被節流
        clock.advance(by: 23 * 60 * 60)
        await #expect(throws: (any Error).self) { try await checker.checkAutomatically() }
        #expect(await fetcher.callCount == 1)

        // 超過 24 小時才再試一次
        clock.advance(by: 2 * 60 * 60)
        await #expect(throws: UpdateCheckError.networkFailure("斷線")) {
            try await checker.checkAutomatically()
        }
        #expect(await fetcher.callCount == 2)
    }

    @Test("節流本身不算新的嘗試：被擋下時不改寫上次檢查時間")
    func throttleDoesNotRewriteTimestamp() async throws {
        let now = Date()
        let last = now.addingTimeInterval(-60 * 60)
        let clock = ManualClock(now)
        let store = InMemoryCheckStore(last: last, skipped: nil)
        let fetcher = FakeFetcher(.error(UpdateCheckError.networkFailure("斷線")))
        let checker = makeChecker(fetcher: fetcher, store: store, clock: clock)
        await #expect(throws: (any Error).self) { try await checker.checkAutomatically() }
        #expect(store.lastCheckDate == last)
        #expect(await fetcher.callCount == 0)
    }

    @Test("成功行為與 check(manual: false) 相同：回傳新版並記時間")
    func successSameAsCheck() async throws {
        let now = Date()
        let clock = ManualClock(now)
        let store = InMemoryCheckStore(last: nil, skipped: nil)
        let fetcher = FakeFetcher(.data(try TestFeed.data([("0.1.0-beta.2", "14.0", "https://example.com/a.pkg", false, nil)])))
        let checker = makeChecker(fetcher: fetcher, store: store, clock: clock)
        let release = try await checker.checkAutomatically()
        #expect(release?.version == "0.1.0-beta.2")
        #expect(store.lastCheckDate == now)
    }

    @Test("check(manual: true) 的失敗仍然不更新檢查時間（既有行為不變）")
    func manualFailureStillNotRecorded() async throws {
        let clock = ManualClock(Date())
        let store = InMemoryCheckStore(last: nil, skipped: nil)
        let fetcher = FakeFetcher(.error(UpdateCheckError.networkFailure("斷線")))
        let checker = makeChecker(fetcher: fetcher, store: store, clock: clock)
        await #expect(throws: (any Error).self) { try await checker.check(manual: true) }
        #expect(store.lastCheckDate == nil)
    }
}
