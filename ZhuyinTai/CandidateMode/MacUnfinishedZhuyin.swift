// SPDX-License-Identifier: Apache-2.0
// 「沒拼完的注音」與「單押 Shift 切英文」的純邏輯：偏好值、殘段判準、行程共用的語言狀態。
//
// 使用者 2026-10-04 早上（語音輸入）原話：「沒有拼完的注音的話留著因為有些人可能要打注音文，
// 所以說可以讓這個自願留著的」「因為他們有時候會要需要打英文的功能，或許在設定裡面可以有這個東西」。
// 維護者建議、使用者回「先修正這些東西」＝照做：三選一（預設留著注音）＋單押 Shift（預設開）。
//
// 放在 `CandidateMode/`：零 AppKit，`tools/test_mac_candidate_mode.sh` 編得到。

import Foundation

// MARK: - 沒拼完的注音

public enum MacUnfinishedZhuyinPolicy: String, CaseIterable, Identifiable {
    /// 殘段原樣送出（預設，給打注音文的人）。
    case keep
    /// 殘段丟掉，前面的字照舊上屏。
    case discard
    /// 補一聲成字＝2026-10-04 之前的行為。
    case seal

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .keep: return "留著注音（可以打注音文）"
        case .discard: return "丟掉"
        case .seal: return "補一聲成字"
        }
    }

    /// 沒設定、或存了看不懂的值 ⇒ 預設 `.keep`。
    static func from(raw: String?) -> MacUnfinishedZhuyinPolicy {
        guard let raw, let policy = MacUnfinishedZhuyinPolicy(rawValue: raw) else { return .keep }
        return policy
    }
}

enum MacUnfinishedZhuyin {
    private static let syllableTable = SyllableTable()

    /// 這個 key 是不是「殘段」：沒有聲調符號、而且組不成合法音節（例：裸聲母 ㄒ、ㄈ）。
    ///
    /// 完整音節**不算**（ㄓ、ㄟ、ㄔ 本身是合法音節，照舊組字）。
    /// 有聲調符號的 key 不算：引擎本來就不收不完整音節加聲調（#330），收得進去的都是完整讀音。
    static func isFragment(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        if key.unicodeScalars.contains(where: { toneScalars.contains($0.value) }) { return false }
        return !syllableTable.isValidSyllable(key)
    }

    /// 組字區**最後一個 key** 若是殘段就回傳它；否則 nil。游標在哪裡不影響（殘段永遠是最後一段）。
    static func trailingFragment(keys: [String]) -> String? {
        guard let last = keys.last, isFragment(last) else { return nil }
        return last
    }

    private static let toneScalars: Set<UInt32> = [0x02C9, 0x02CA, 0x02C7, 0x02CB, 0x02D9]
}

// MARK: - 單押 Shift 的行程共用語言

/// 中／英模式是**整個輸入法行程共用一個狀態**（不分 app）。
///
/// 為什麼不放 per-client 的 `MacClientSession`：使用者在 A app 切到英文，換到 B app 時
/// 預期仍是英文（跟系統切輸入方式一致）；放進 session 就會每個 app 各一份、切過去又變回中文。
/// activate／deactivate 都不重設它。
///
/// 跨**輸入方式**（切到 ABC 等再切回來）則重設成中文，否則切回來還卡在英文像壞掉（N19 ②）：
/// 由 controller 監聽系統的「選取的輸入方式改變」通知，呼叫 `inputSourceChanged`。
enum MacInputModeState {
    static var language: MacInputLanguage = .zh {
        didSet { if oldValue != language { onLanguageChange?(oldValue, language) } }
    }

    /// 語言實際改變時通知（舊值、新值）。英文模式浮標用它在「英 → 中」時藏起來（`MacEnglishIndicator`）。
    static var onLanguageChange: ((MacInputLanguage, MacInputLanguage) -> Void)?

    /// 系統選取的輸入方式改變了。新輸入方式不是我們自己 ⇒ 重設成中文（人已經離開我們了，之後切回來是全新的開始）。
    /// 是我們自己（輸入方式 ID 以 bundle id 開頭，例如 `<bundle>.Zhuyin`）、或讀不到 ID／不知道自己的
    /// bundle id ⇒ 不動（寧可維持現狀，跨 app 保留英文不受影響：換 app 本身不會送這個通知）。
    static func inputSourceChanged(selectedID: String?, ownBundleID: String?) {
        guard let selectedID, let ownBundleID, !ownBundleID.isEmpty else { return }
        if !selectedID.hasPrefix(ownBundleID) { language = .zh }
    }
}

// MARK: - 建置戳（實機驗收分辨「跑的是哪一版」）

/// 行程啟動時間早於執行檔的修改時間 ⇒ 磁碟上的檔案已換新、跑的卻是舊行程（安裝後沒重啟輸入法）。
/// N20：實機 P20 兩項「FAIL」的 log 全是同一個 pid（14:14:52 啟動），執行檔卻是 15:20:43 換的，
/// 舊程式的行為（Shift＋⌫ 走 UNMAPPED、沒有輸入方式通知）與 FAIL 完全吻合——需要一行 log 把這件事講明白。
enum MacBuildStamp {
    /// 容許兩秒（安裝完立刻啟動時，檔案時間與行程時間可能差幾百毫秒）。
    static func isStale(binaryModified: Date?, processStarted: Date?) -> Bool? {
        guard let binaryModified, let processStarted else { return nil }
        return binaryModified.timeIntervalSince(processStarted) > 2
    }
}
