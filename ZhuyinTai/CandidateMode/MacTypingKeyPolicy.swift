// SPDX-License-Identifier: Apache-2.0
// 偏好設定第二批的純邏輯：選字鍵對映、刪除鍵怎麼分工、選字後游標停哪。
//
// 放在 `CandidateMode/`：零 AppKit，`tools/test_mac_candidate_mode.sh` 編得到。
// 預設值對齊改這批之前的出貨行為（選字鍵 `123456`、⌫ 刪整個字、fn＋⌫ 退回注音、
// 選字後不另外挪引擎游標）。

import Foundation

// MARK: - 選字鍵

enum MacSelectionKeyChoice: String, CaseIterable, Identifiable {
    case digits = "123456"
    case asdf = "asdfgh"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .digits: return "1 2 3 4 5 6"
        case .asdf: return "a s d f g h"
        }
    }

    static func from(raw: String?) -> MacSelectionKeyChoice {
        guard let raw, let choice = MacSelectionKeyChoice(rawValue: raw) else { return .digits }
        return choice
    }
}

// MARK: - 選字後游標

enum MacCursorAfterSelection: String, CaseIterable, Identifiable {
    /// 游標留在所選詞後面。引擎選字本來就不挪游標，而候選是「在游標處結束」的詞，
    /// 所以這就是現在的行為（微軟注音：選完停在詞後面）。
    case afterWord
    /// 只在游標本來就在組字區中間時，把游標挪到所選詞的開頭（漢音）。
    case beforeWord

    var id: String { rawValue }

    var label: String {
        switch self {
        case .afterWord: return "放在詞後面（像微軟注音）"
        case .beforeWord: return "放在詞前面（像漢音）"
        }
    }

    static func from(raw: String?) -> MacCursorAfterSelection {
        guard let raw, let placement = MacCursorAfterSelection(rawValue: raw) else { return .afterWord }
        return placement
    }
}

struct MacSelectionCursorGram {
    var keyCount: Int
    var value: String
}

enum MacSelectionCursor {
    /// 選字之後引擎游標（1-based）該停在哪。
    ///
    /// 游標已經在整段組字的頭或尾時，兩種設定都不動——平常打完直接選字不能被這項改掉。
    /// `.afterWord` 維持選字前的游標（詞的結尾）。`.beforeWord` 停在涵蓋這個游標、
    /// 而且字等於所選候選的那一詞的開頭。
    static func targetCursor(
        cursor: Int,
        keyCount: Int,
        grams: [MacSelectionCursorGram],
        chosen: String,
        placement: MacCursorAfterSelection
    ) -> Int {
        guard cursor > 0, cursor < keyCount else { return cursor }
        guard placement == .beforeWord else { return cursor }
        var start = 0
        var matchedStart: Int?
        for gram in grams {
            let end = start + gram.keyCount
            if gram.value == chosen, cursor > start, cursor <= end {
                matchedStart = start
                if cursor == end { break }
            }
            start = end
        }
        return matchedStart ?? cursor
    }
}

// MARK: - 刪除鍵

enum MacBackspaceRole: String, CaseIterable, Identifiable {
    /// ⌫：緩衝是空的就砍掉整個音節；還在拼的注音一次刪一個符號。這是現在的 ⌫。
    case wholeCharacter
    /// ⌫：走現在 fn＋⌫ 的路（把字退回注音，逐個刪）。
    case perSymbol

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wholeCharacter: return "刪整個字"
        case .perSymbol: return "逐個注音刪"
        }
    }

    static func from(raw: String?) -> MacBackspaceRole {
        guard let raw, let role = MacBackspaceRole(rawValue: raw) else { return .wholeCharacter }
        return role
    }
}

struct MacDeleteKeyPolicy: Equatable {
    var backspaceRole: MacBackspaceRole
    var forwardDoesTheOther: Bool

    /// ⌫ 刪整個字、fn＋⌫ 做另一種。等於把事件原樣送進狀態機。
    static let current = MacDeleteKeyPolicy(backspaceRole: .wholeCharacter, forwardDoesTheOther: true)

    /// 狀態機眼中的 ⌫（刪整個字＝`.backspace`，逐個注音＝`.deleteForward`）。
    var primaryEvent: MacKeyEvent {
        backspaceRole == .wholeCharacter ? .backspace : .deleteForward
    }

    var otherEvent: MacKeyEvent {
        backspaceRole == .wholeCharacter ? .deleteForward : .backspace
    }
}

enum MacDeleteKeyRouting {
    /// 把 ⌫／fn＋⌫ 改寫成狀態機已經有的兩種刪法。其他鍵原樣返回。
    ///
    /// 組字區空的時候兩種刪法都會 `.passThroughToClient`，宿主收到的仍是原本那顆鍵
    /// （fn＋⌫ 就是往後刪）。這裡不另外分岐。
    static func route(_ event: MacKeyEvent, policy: MacDeleteKeyPolicy) -> MacKeyEvent {
        switch event {
        case .backspace:
            return policy.primaryEvent
        case .deleteForward:
            return policy.forwardDoesTheOther ? policy.otherEvent : policy.primaryEvent
        default:
            return event
        }
    }
}

// MARK: - 字元 → 事件

enum MacKeyEventTranslator {
    /// 標準（大千式）注音鍵盤排列：實體鍵 → 注音符號。
    static let symbolKeyMap: [Character: Character] = [
        "1": "ㄅ", "2": "ㄉ", "5": "ㄓ", "8": "ㄚ", "9": "ㄞ", "0": "ㄢ", "-": "ㄦ",
        "q": "ㄆ", "w": "ㄊ", "e": "ㄍ", "r": "ㄐ", "t": "ㄔ", "y": "ㄗ", "u": "ㄧ", "i": "ㄛ", "o": "ㄟ", "p": "ㄣ",
        "a": "ㄇ", "s": "ㄋ", "d": "ㄎ", "f": "ㄑ", "g": "ㄕ", "h": "ㄘ", "j": "ㄨ", "k": "ㄜ", "l": "ㄠ", ";": "ㄤ",
        "z": "ㄈ", "x": "ㄌ", "c": "ㄏ", "v": "ㄒ", "b": "ㄖ", "n": "ㄙ", "m": "ㄩ", ",": "ㄝ", ".": "ㄡ", "/": "ㄥ",
    ]
    /// 聲調鍵：3=ˇ 4=ˋ 6=ˊ 7=˙（一聲無專屬鍵，用空白鍵補）。
    static let toneKeyMap: [Character: Character] = [
        "3": "ˇ", "4": "ˋ", "6": "ˊ", "7": "˙",
    ]

    /// 字元 → 事件。
    ///
    /// 選字鍵只在候選窗開著時成立。沒開窗時 `a` 仍是ㄇ。開著時不在標籤裡的鍵
    /// （例如 asdf 模式的 1–6）走原本的注音／聲調，狀態機再當成「先關窗再打字」。
    static func event(
        for symbol: Character, isSelecting: Bool, selectionKeys: String
    ) -> MacKeyEvent? {
        if symbol == "\r" || symbol == "\n" || symbol == "\u{3}" { return .enter }
        if symbol == "\u{1b}" { return .escape }
        if symbol == "\u{8}" || symbol == "\u{7f}" { return .backspace }

        if isSelecting, let labelIndex = selectionKeys.firstIndex(of: symbol) {
            return .selectionKey(
                labelIndex: selectionKeys.distance(from: selectionKeys.startIndex, to: labelIndex))
        }
        if symbol == " " { return .space }
        if let tone = toneKeyMap[symbol] { return .tone(tone) }
        if let zhuyin = symbolKeyMap[symbol] { return .zhuyinSymbol(zhuyin) }
        if symbol.isPunctuation || symbol.isSymbol { return .punctuation(symbol) }
        return .otherCharacter(symbol)
    }
}

// MARK: - 快捷鍵說明

enum MacShortcutHelp {
    static func rows(
        role: MacBackspaceRole, forwardDoesTheOther: Bool
    ) -> [(key: String, detail: String)] {
        let whole = "刪掉游標前的整個字。還沒拼完的注音只刪最後一個符號"
        let per = "把游標前的字退回注音，再逐個刪"
        let backspace = role == .wholeCharacter ? whole : per
        let other = role == .wholeCharacter ? per : whole
        let forward = forwardDoesTheOther ? other : "跟 ⌫ 一樣"
        return [
            ("⌫", backspace),
            ("fn＋⌫", forward + "。組字區是空的時候交給 App 往後刪"),
            ("Shift", "單押一下切換中／英（可在「輸入」分頁關閉）"),
            ("Caps Lock", "交給系統切換輸入方式（中／英）"),
            ("空白鍵", "還在拼注音時補一聲；字已經組好時開候選窗；候選窗收合時先展開，展開後翻到下一頁"),
            ("Enter", "候選窗開著時確認目前的候選，留在組字區；否則送出這一段"),
            ("Esc", "候選窗開著時只關窗；組字時清掉整段"),
            ("方向鍵", "組字時 ← → 移動游標，↓ 開候選窗；候選窗開著時 ← → 換候選，↑ ↓ 換行"),
        ]
    }
}

// MARK: - UserDefaults

enum MacTypingPreferences {
    static let selectionKeysDefaultsKey = "TWKeyboard.selectionKeys"
    static let cursorAfterSelectionDefaultsKey = "TWKeyboard.cursorAfterSelection"
    static let backspaceRoleDefaultsKey = "TWKeyboard.backspaceRole"
    static let deleteForwardDoesTheOtherDefaultsKey = "TWKeyboard.deleteForwardDoesTheOther"
    static let unfinishedZhuyinDefaultsKey = "TWKeyboard.unfinishedZhuyin"
    static let shiftTapSwitchesToEnglishDefaultsKey = "TWKeyboard.shiftTapSwitchesToEnglish"

    static var selectionKeys: String {
        MacSelectionKeyChoice.from(raw: UserDefaults.standard.string(forKey: selectionKeysDefaultsKey)).rawValue
    }

    static var cursorAfterSelection: MacCursorAfterSelection {
        MacCursorAfterSelection.from(
            raw: UserDefaults.standard.string(forKey: cursorAfterSelectionDefaultsKey))
    }

    /// 沒拼完的注音怎麼處理。預設 `.keep`（給打注音文的人）。
    static var unfinishedZhuyin: MacUnfinishedZhuyinPolicy {
        MacUnfinishedZhuyinPolicy.from(
            raw: UserDefaults.standard.string(forKey: unfinishedZhuyinDefaultsKey))
    }

    /// 單押 Shift 切中／英。預設開。
    static var shiftTapSwitchesToEnglish: Bool {
        if UserDefaults.standard.object(forKey: shiftTapSwitchesToEnglishDefaultsKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: shiftTapSwitchesToEnglishDefaultsKey)
    }

    static var deletePolicy: MacDeleteKeyPolicy {
        let forward: Bool
        if UserDefaults.standard.object(forKey: deleteForwardDoesTheOtherDefaultsKey) == nil {
            forward = true
        } else {
            forward = UserDefaults.standard.bool(forKey: deleteForwardDoesTheOtherDefaultsKey)
        }
        return MacDeleteKeyPolicy(
            backspaceRole: MacBackspaceRole.from(
                raw: UserDefaults.standard.string(forKey: backspaceRoleDefaultsKey)),
            forwardDoesTheOther: forward
        )
    }
}
