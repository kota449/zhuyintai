// SPDX-License-Identifier: Apache-2.0
import Foundation

/// 抓取遠端 feed 的抽象層（方便測試注入假 fetcher）。
///
/// 正式環境請用 `URLSessionFeedFetcher`（內部只用 `URLSession`）；
/// 測試一律用假 fetcher，不可發出真的網路請求。
public protocol FeedFetcher: Sendable {
    /// 從指定網址抓取原始資料。
    /// - Parameter url: 建構時注入的 feed JSON 網址。
    /// - Returns: feed 的原始 JSON 資料。
    func fetch(from url: URL) async throws -> Data
}

/// 以 `URLSession` 實作的 fetcher（逾時 10 秒）。
///
/// 只會發出單一 `GET` 請求，不下載檔案、不執行外部程式。
public struct URLSessionFeedFetcher: FeedFetcher, Sendable {
    /// 逾時秒數（規格要求 10 秒）。
    public let timeoutSeconds: TimeInterval
    /// 使用的 session（預設共用 session；測試不應使用此型別）。
    private let session: URLSession

    /// 建立 fetcher。
    /// - Parameters:
    ///   - timeoutSeconds: 逾時秒數，預設 10 秒。
    ///   - session: 要使用的 `URLSession`。
    public init(timeoutSeconds: TimeInterval = 10, session: URLSession = .shared) {
        self.timeoutSeconds = timeoutSeconds
        self.session = session
    }

    public func fetch(from url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeoutSeconds)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw UpdateCheckError.invalidResponse
            }
            return data
        } catch let error as UpdateCheckError {
            throw error
        } catch {
            // 將系統逾時對應為明確的逾時錯誤，其餘包成網路失敗。
            if (error as NSError).code == NSURLErrorTimedOut {
                throw UpdateCheckError.timeout
            }
            if error is URLError, (error as? URLError)?.code == .timedOut {
                throw UpdateCheckError.timeout
            }
            throw UpdateCheckError.networkFailure(String(describing: error))
        }
    }
}
