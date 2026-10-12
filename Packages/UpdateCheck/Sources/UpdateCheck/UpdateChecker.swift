// SPDX-License-Identifier: Apache-2.0
import Foundation
import os

/// 更新檢查的明確錯誤型別（不會 crash，也不會把失敗算成成功檢查）。
public enum UpdateCheckError: Error, Sendable, Hashable, CustomStringConvertible {
    /// 自動檢查被 24 小時節流擋下（附下次允許時間）。
    case throttled(nextAllowedDate: Date)
    /// 網路抓取失敗（附原因說明）。
    case networkFailure(String)
    /// 非 2xx 或不合理的回應。
    case invalidResponse
    /// JSON 解析失敗（附原因說明）。
    case decodingFailure(String)
    /// 請求逾時（10 秒）。
    case timeout
    /// 下載連結不是 `https`（視為沒有更新，呼叫方應記錄此錯誤）。
    case insecureDownloadURL(String)

    public var description: String {
        switch self {
        case .throttled(let d): return "檢查過於頻繁，下次可檢查時間：\(d)"
        case .networkFailure(let s): return "網路抓取失敗：\(s)"
        case .invalidResponse: return "伺服器回應無效"
        case .decodingFailure(let s): return "版本資訊解析失敗：\(s)"
        case .timeout: return "請求逾時（10 秒）"
        case .insecureDownloadURL(let s): return "下載連結非 https，已拒絕：\(s)"
        }
    }
}

/// 負責「要不要提醒更新」的檢查器（只通知，不下載、不安裝）。
///
/// - 執行緒假設：可在任意執行緒／actor 呼叫，內部為 `Sendable`；只有
///   `UpdatePromptView` 與 `URLOpener` 相關操作需要在 MainActor。
public struct UpdateChecker: Sendable {
    /// 自動檢查的最短間隔：24 小時。
    public static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    private let currentVersion: SemanticVersion
    private let currentMacOSVersion: String
    private let feedURL: URL
    private let fetcher: any FeedFetcher
    private let store: any UpdateCheckStore
    private let clock: any Clock

    /// 建立檢查器。
    /// - Parameters:
    ///   - currentVersion: 目前 App 版本。
    ///   - currentMacOSVersion: 目前 macOS 版本（例如 `14.5`，由呼叫方傳入 `ProcessInfo` 取得的值）。
    ///   - feedURL: 建構時注入的 feed JSON 網址。
    ///   - fetcher: 抓取抽象（正式用 `URLSessionFeedFetcher`，測試用假 fetcher）。
    ///   - store: 記住上次檢查與略過版本的儲存。
    ///   - clock: 時鐘抽象（測試用假時鐘）。
    public init(
        currentVersion: SemanticVersion,
        currentMacOSVersion: String,
        feedURL: URL,
        fetcher: any FeedFetcher,
        store: any UpdateCheckStore,
        clock: any Clock = SystemClock()
    ) {
        self.currentVersion = currentVersion
        self.currentMacOSVersion = currentMacOSVersion
        self.feedURL = feedURL
        self.fetcher = fetcher
        self.store = store
        self.clock = clock
    }

    /// 檢查是否有可用更新。
    ///
    /// - Parameter manual: `true` 為手動檢查（不受 24 小時節流限制）；
    ///   `false` 為自動檢查（24 小時內只檢查一次，被擋下時丟出 `.throttled`）。
    /// - Returns: 可提示的最新版本；`nil` 表示沒有可用更新（含：已是最新、
    ///   被略過、系統版本不符）。
    /// - Throws: `UpdateCheckError` 的明確錯誤；失敗不會更新上次檢查時間。
    @discardableResult
    public func check(manual: Bool = false) async throws -> Release? {
        // 自動檢查的 24 小時節流。
        if !manual, let last = store.lastCheckDate {
            let next = last.addingTimeInterval(Self.automaticCheckInterval)
            if clock.now < next {
                throw UpdateCheckError.throttled(nextAllowedDate: next)
            }
        }

        // 抓取（只打建構時注入的那一個 JSON 網址）。
        let data: Data
        do {
            data = try await fetcher.fetch(from: feedURL)
        } catch let e as UpdateCheckError {
            // 假 fetcher 或 URLSession 丟出的明確錯誤直接透出（尤其逾時）。
            throw e
        } catch {
            if (error as NSError).code == NSURLErrorTimedOut || (error as? URLError)?.code == .timedOut {
                throw UpdateCheckError.timeout
            }
            throw UpdateCheckError.networkFailure(String(describing: error))
        }

        // 解析 JSON（壞掉就回明確錯誤，不 crash）。
        let feed: UpdateFeed
        do {
            feed = try JSONDecoder().decode(UpdateFeed.self, from: data)
        } catch {
            throw UpdateCheckError.decodingFailure(String(describing: error))
        }

        // 挑出「比目前新、minimumMacOS 符合」的最新一版。
        guard let best = Self.newestEligibleRelease(in: feed, newerThan: currentVersion, macOSVersion: currentMacOSVersion) else {
            // 成功檢查（只是沒更新）：記錄時間。
            store.setLastCheckDate(clock.now)
            return nil
        }

        // 「略過這個版本」：只有非重大更新才生效；重大更新無視略過。
        if !best.critical, let skipped = store.skippedVersion, skipped == best.version {
            store.setLastCheckDate(clock.now)
            return nil
        }

        // 只接受 https 的下載連結，否則當成沒有更新並以錯誤回報。
        guard best.downloadURL.scheme?.lowercased() == "https" else {
            let raw = best.downloadURL.absoluteString
            Logger(subsystem: "UpdateCheck", category: "checker").error("拒絕非 https 下載連結：\(raw, privacy: .public)")
            // 規格要求「當成沒有更新並記錄錯誤」：此處以明確錯誤回報，
            // 呼叫方應視為無可用更新、並記錄日誌（見 README）。
            throw UpdateCheckError.insecureDownloadURL(raw)
        }

        store.setLastCheckDate(clock.now)
        return best
    }

    /// 自動檢查（背景、每次啟動／啟用都可能呼叫）：行為同 `check(manual: false)`，
    /// 但**失敗的嘗試也計入 24 小時節流**——否則 feed 還不存在或斷網時，每次呼叫都會重打一次請求，
    /// 「自動檢查每天最多一次」就不成立。被節流擋下（`.throttled`）本身不算新的嘗試、不改寫時間。
    ///
    /// 取捨：開機登入時網路常常還沒好，第一次失敗就會讓當天不再自動檢查（使用者仍可手動檢查）。
    @discardableResult
    public func checkAutomatically() async throws -> Release? {
        do {
            return try await check(manual: false)
        } catch let error as UpdateCheckError {
            if case .throttled = error { throw error }
            store.setLastCheckDate(clock.now)
            throw error
        } catch {
            store.setLastCheckDate(clock.now)
            throw error
        }
    }

    /// 將版本標記為「略過這個版本」。
    public func skip(version: String) {
        store.setSkippedVersion(version)
    }

    /// 清除略過紀錄。
    public func clearSkipped() {
        store.setSkippedVersion(nil)
    }

    // MARK: - 挑選邏輯（可單獨測試的純函式）

    /// 從 feed 挑出符合條件的最新版本。
    static func newestEligibleRelease(in feed: UpdateFeed, newerThan current: SemanticVersion, macOSVersion: String) -> Release? {
        var best: Release?
        var bestVersion: SemanticVersion?
        for release in feed.releases {
            guard let v = SemanticVersion(release.version) else { continue } // 壞版本字串直接跳過
            guard v > current else { continue }
            guard isMacOSCompatible(minimum: release.minimumMacOS, current: macOSVersion) else { continue }
            if bestVersion == nil || v > bestVersion! {
                best = release
                bestVersion = v
            }
        }
        return best
    }

    /// 判斷目前 macOS 是否滿足最低需求（缺省視為符合；以數字段逐段比較）。
    static func isMacOSCompatible(minimum: String?, current: String) -> Bool {
        guard let minimum, !minimum.isEmpty else { return true }
        return compareDottedNumeric(current, minimum) >= 0
    }

    /// 比較 `14.5` 這類點分數字版本（忽略非數字後綴，缺段補零）。
    static func compareDottedNumeric(_ lhs: String, _ rhs: String) -> Int {
        let l = numericComponents(lhs)
        let r = numericComponents(rhs)
        let n = max(l.count, r.count)
        for i in 0..<n {
            let a = i < l.count ? l[i] : 0
            let b = i < r.count ? r[i] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }

    /// 取出版本字串中的前導數字段（例如 `14.5.1` → `[14, 5, 1]`）。
    private static func numericComponents(_ s: String) -> [Int] {
        s.split(separator: ".").compactMap { part in
            let digits = part.prefix(while: \.isNumber)
            return Int(digits)
        }
    }
}
