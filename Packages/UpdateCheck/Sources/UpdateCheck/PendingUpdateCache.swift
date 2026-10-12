// SPDX-License-Identifier: Apache-2.0
import Foundation

/// 記住「已找到、使用者還沒處理」的新版，讓提示能跨 App／輸入法重啟存活。
///
/// 為什麼需要：24 小時節流的時間存在 `UserDefaults`，重啟後 `checkAutomatically()` 會被節流擋掉、
/// 不會再抓 feed；若新版只存在記憶體，重啟後選單項與關於頁提示會消失最多 24 小時。
///
/// 讀出時會重新驗證（不信任存下來的東西）：目前版本已經 ≥ 快取版本、被使用者略過（重大更新除外）、
/// 下載連結不是 `https`、資料壞掉 ⇒ 一律回 `nil`。
public final class PendingUpdateCache: @unchecked Sendable {
    public static let defaultKey = "UpdateCheck.pendingRelease"

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults, key: String = PendingUpdateCache.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func save(_ release: Release) {
        guard let data = try? JSONEncoder().encode(release) else { return }
        lock.lock(); defer { lock.unlock() }
        defaults.set(data, forKey: key)
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: key)
    }

    public func load(currentVersion: SemanticVersion, skippedVersion: String?) -> Release? {
        lock.lock()
        let data = defaults.data(forKey: key)
        lock.unlock()
        guard let data,
              let release = try? JSONDecoder().decode(Release.self, from: data),
              let version = release.semanticVersion,
              version > currentVersion,
              release.downloadURL.scheme?.lowercased() == "https"
        else { return nil }
        if !release.critical, let skippedVersion, skippedVersion == release.version { return nil }
        return release
    }
}
