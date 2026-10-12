// SPDX-License-Identifier: Apache-2.0
import Foundation

/// 偏好設定（UserDefaults `TWKeyboard.*`）的 schema 版本與遷移掛點（G14）。
///
/// - 缺版本鍵＝v0（beta.1 以前沒有這個鍵）。
/// - `stored < current`：依序跑 `migrations[stored..<current]`，再寫入目前版本。
///   目前 0→1 **沒有任何格式變更**，所以是 no-op：所有 key 原樣保留，只多一個版本鍵。
/// - `stored > current`（降級）：什麼都不做，不寫、不降版本號。舊版程式碼會忽略不認得的鍵。
///
/// 🔴 遷移只能「轉譯」使用者設過的值；**不得替使用者補預設值、不得回答他沒回答過的問題**
/// （例如 log 同意缺鍵要維持缺鍵——讀取端另有升級偵測，見 `MacIMELogConsent`）。
enum MacPrefsSchema {
    static let versionKey = "TWKeyboard.prefsSchemaVersion"
    static let currentVersion = 1

    /// key ＝舊版本號，value ＝把該版本的資料轉成「舊版本號 + 1」。
    static let migrations: [Int: (UserDefaults) -> Void] = [
        0: { _ in /* v0 → v1：沒有格式變更。 */ },
    ]

    /// `target` 與 `table` 只給測試注入；正式呼叫用預設值。
    static func migrateIfNeeded(
        defaults: UserDefaults = .standard,
        target: Int = MacPrefsSchema.currentVersion,
        table: [Int: (UserDefaults) -> Void] = MacPrefsSchema.migrations
    ) {
        let stored = (defaults.object(forKey: versionKey) as? Int) ?? 0
        guard stored < target else { return }
        // 漏登記任何一步就不前進版本號：寫成目前版本之後那一步就再也不會被補跑。
        guard (stored..<target).allSatisfy({ table[$0] != nil }) else { return }
        for from in stored..<target {
            table[from]?(defaults)
        }
        defaults.set(target, forKey: versionKey)
    }
}
