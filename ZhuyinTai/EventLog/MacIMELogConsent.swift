// SPDX-License-Identifier: Apache-2.0
// 打字 log 的**記錄狀態**：未回答（預設開）／同意／拒絕。只用 Foundation，所以能用純 swiftc 測
// （`tools/test_mac_ime_event_log.sh`）。
//
// 🔴 使用者 2026-10-06 決定（取代 10-03 的「第一次啟用彈窗問、預設關」）：**預設開、不彈同意窗**；
// 改在安裝說明與設定頁告知（只存本機、只留約一週、不會自己送到任何地方、可隨時關）。
// 這一層只管「狀態存取」，設定頁在 `MacLogConsentViews.swift`。
//
// 🔴 **誰算「開」**（`isRecordingEnabled`）：
//   · `stateKey` **根本沒有值**（從沒回答過）→ 開；
//   · `granted` → 開；
//   · `denied` → **關，而且永遠不會被預設開蓋掉**——使用者在 beta.1 的彈窗或設定頁明確按過「不要」，
//     就算之後磁碟上有舊 log、行程重啟、版本更新都一樣；
//   · 值存在但看不懂（被手改、被別的工具寫過、未來版本新增的狀態）→ **關**。它不是「從沒回答過」，
//     寧可少記也不要把可能是拒絕的人翻成開。
// 預設開**不寫回** defaults：寫了就分不出「沒回答過」與「按過同意」，之後想改預設時會誤傷。
//
// 存在哪：App 自己 container 的 `UserDefaults`（沙盒內），一個字串值。
// 為什麼不快取：註解說過可能同時有多個 IME 行程，設定頁改了值，別的行程下一次讀就要看到。
// `UserDefaults.object(forKey:)` 實測約 0.26 µs／次量級（2026-10-03，arm64 `swiftc -O`，20 萬次平均）；每鍵 `isEnabled` 讀個位數次，
// 加起來 < 3 µs，可以接受。
//
// 升級路徑（沿用）：狀態還是「未回答」時，如果 log 目錄裡已經有我們的 log 檔，記成 `granted`、標成 `legacyInstall`
// 並寫回 defaults——現在效果與預設開相同，保留是為了啟動診斷（`consent=…`）仍能分辨「升級而來」。
// 「拒絕」永遠不會被這條翻成同意。

import Foundation

enum MacIMELogConsentState: String {
    /// 從沒回答過。2026-10-06 起視為「開」。
    case unasked
    case granted
    case denied
}

/// 記錄是怎麼開的。寫進啟動診斷那一筆（`consent=…`），之後查 log 就知道這份資料是使用者選的、升級來的還是預設開。
enum MacIMELogConsentProvenance: String {
    /// 使用者在設定頁（或 beta.1 的彈窗）親自選的。
    case user
    /// 升級判定：沒問過、但磁碟上已有 log。
    case legacyInstall
    /// 從沒回答過、預設開（2026-10-06 起）。
    case defaultOn
}

final class MacIMELogConsent {
    /// 記錄狀態改變時（設定頁開關）發出，設定頁靠它保持顯示同步。
    static let didChangeNotification = Notification.Name("TWKeyboard.eventLogConsentDidChange")

    static let stateKey = "TWKeyboard.eventLogConsent"
    static let provenanceKey = "TWKeyboard.eventLogConsentSource"

    // `shared`（行程唯一的實例）在 `CandidateWiring/MacIMEEventLogSink.swift` 的 extension 裡：
    // 它要知道真正的 log 目錄，而 `EventLog/` 必須能單獨編譯（`tools/mac_guardrails` 的 fixture generator 就只編這個目錄）。

    private let defaults: UserDefaults
    private let legacyLogExists: () -> Bool
    private let lock = NSLock()
    /// 舊 log 偵測（要列目錄）每個行程最多做一次；結果是「否」也不再重做。
    private var legacyChecked = false

    init(defaults: UserDefaults, legacyLogExists: @escaping () -> Bool) {
        self.defaults = defaults
        self.legacyLogExists = legacyLogExists
    }

    var state: MacIMELogConsentState {
        switch stored() {
        case .value(let state): return state
        case .unrecognized: return .denied   // 看不懂的值不是「從沒回答過」：寧可關
        case .absent: return resolveUnasked()
        }
    }

    /// 現在該不該記：沒回答過或同意 ⇒ 是；拒絕（含看不懂的值）⇒ 否。
    var isRecordingEnabled: Bool { state != .denied }

    var provenance: MacIMELogConsentProvenance {
        guard state != .unasked else { return .defaultOn }
        let raw = defaults.string(forKey: Self.provenanceKey)
        return raw.flatMap(MacIMELogConsentProvenance.init(rawValue:)) ?? .user
    }

    /// 使用者的明確選擇（設定頁開關）。一律記成 `user`。
    func set(_ newState: MacIMELogConsentState) {
        lock.lock()
        defaults.set(newState.rawValue, forKey: Self.stateKey)
        defaults.set(MacIMELogConsentProvenance.user.rawValue, forKey: Self.provenanceKey)
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    // MARK: - 內部

    private enum Stored {
        case absent
        case value(MacIMELogConsentState)
        case unrecognized
    }

    /// `stateKey` 的內容：根本沒有 ／ 認得的狀態 ／ 有值但看不懂（含非字串）。
    private func stored() -> Stored {
        guard let raw = defaults.object(forKey: Self.stateKey) else { return .absent }
        if let text = raw as? String, let state = MacIMELogConsentState(rawValue: text) { return .value(state) }
        return .unrecognized
    }

    /// 沒有任何紀錄：第一次要不要視為升級。只在行程內做一次目錄偵測。
    private func resolveUnasked() -> MacIMELogConsentState {
        lock.lock()
        defer { lock.unlock() }
        // 等鎖的期間別的執行緒可能已經寫了（升級或使用者在設定頁按了開關）。
        switch stored() {
        case .value(let state): return state
        case .unrecognized: return .denied
        case .absent: break
        }
        guard !legacyChecked else { return .unasked }
        legacyChecked = true
        guard legacyLogExists() else { return .unasked }
        defaults.set(MacIMELogConsentState.granted.rawValue, forKey: Self.stateKey)
        defaults.set(MacIMELogConsentProvenance.legacyInstall.rawValue, forKey: Self.provenanceKey)
        return .granted
    }

    /// 目錄裡有任何我們的 log 檔（`classify` 認得的：現行檔、日檔、舊制 `.N`）。
    /// 目錄不存在、解析不到、只有別人的檔案都回 `false`。
    static func legacyLogExists(in directory: URL?) -> Bool {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return false }
        return names.contains { MacIMEDailyLog.classify($0) != nil }
    }
}
