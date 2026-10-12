// SPDX-License-Identifier: Apache-2.0
import Foundation

/// 時鐘抽象（讓 24 小時節流可測試）。
public protocol Clock: Sendable {
    /// 目前時間。
    var now: Date { get }
}

/// 系統時間（正式環境使用）。
public struct SystemClock: Clock, Sendable {
    /// 建立系統時鐘。
    public init() {}
    public var now: Date { Date() }
}

/// 記住「上次檢查時間」與「略過的版本」的儲存抽象。
///
/// 正式環境請用 `UserDefaultsCheckStore`（以注入的 `UserDefaults` suite 實作）；
/// 測試請用 `InMemoryCheckStore`（見 Tests 內的假實作或自行實作）。
public protocol UpdateCheckStore: Sendable {
    /// 上次成功檢查的時間（失敗不更新）。
    var lastCheckDate: Date? { get }
    /// 使用者按過「略過」的版本字串。
    var skippedVersion: String? { get }
    /// 記錄成功檢查的時間。
    func setLastCheckDate(_ date: Date?)
    /// 記錄略過的版本。
    func setSkippedVersion(_ version: String?)
}

extension UpdateCheckStore {
    /// 記住要略過的版本（便利方法）。
    /// - Parameter version: 要略過的版本字串。
    public func skip(version: String) {
        setSkippedVersion(version)
    }

    /// 清除略過紀錄。
    public func clearSkippedVersion() {
        setSkippedVersion(nil)
    }
}

/// 以 `UserDefaults`（可注入 suite）實作的儲存。
///
/// 鍵名皆有前綴，避免與宿主 App 衝突；執行緒安全（內部以鎖保護）。
public final class UserDefaultsCheckStore: UpdateCheckStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let lastCheckKey: String
    private let skippedVersionKey: String
    private let lock = NSLock()

    /// 建立儲存。
    /// - Parameters:
    ///   - defaults: 注入的 `UserDefaults`（建議用專屬 suite，例如 `UserDefaults(suiteName: "…")`）。
    ///   - lastCheckKey: 上次檢查時間的鍵名。
    ///   - skippedVersionKey: 略過版本的鍵名。
    public init(
        defaults: UserDefaults,
        lastCheckKey: String = "UpdateCheck.lastCheckDate",
        skippedVersionKey: String = "UpdateCheck.skippedVersion"
    ) {
        self.defaults = defaults
        self.lastCheckKey = lastCheckKey
        self.skippedVersionKey = skippedVersionKey
    }

    public var lastCheckDate: Date? {
        lock.lock(); defer { lock.unlock() }
        let t = defaults.double(forKey: lastCheckKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    public var skippedVersion: String? {
        lock.lock(); defer { lock.unlock() }
        return defaults.string(forKey: skippedVersionKey)
    }

    public func setLastCheckDate(_ date: Date?) {
        lock.lock(); defer { lock.unlock() }
        if let date {
            defaults.set(date.timeIntervalSince1970, forKey: lastCheckKey)
        } else {
            defaults.removeObject(forKey: lastCheckKey)
        }
    }

    public func setSkippedVersion(_ version: String?) {
        lock.lock(); defer { lock.unlock() }
        if let version {
            defaults.set(version, forKey: skippedVersionKey)
        } else {
            defaults.removeObject(forKey: skippedVersionKey)
        }
    }
}
