// SPDX-License-Identifier: Apache-2.0
// Mac 輸入表的共用值型別（G5 標點／G6 中英切換）。
//
// 🔴 **本目錄所有檔案都不得 import AppKit／InputMethodKit。** 理由與 `CandidateMode/` 相同：
// mac target 沒有測試、加 test target 要改 pbxproj，唯一便宜的機械測法是純 swiftc
// （`tools/test_mac_input_tables.sh`）。
//
// 型別全收進 `MacInputTables` 命名空間：`MacIMESpike/` 是 Xcode 同步群組，這裡的檔案會被編進
// 與 `CandidateMode/` 同一個 module。`mac-ime-wiring` 那條線已用了 `MacInputLanguage`／
// `MacKeyEvent.punctuation` 等名字，用命名空間才不會在合併時撞名，也不必等它們先定案。
//
// 和弦（`Chord`）用「實體鍵＋修飾鍵」而不是「IMK 給的字串」建模，理由有兩個：
//   1. `inputText:client:` 給的字串已被 Shift／Option 翻譯過（ABC 排列的 Option+1 是「¡」、
//      Option+, 是「≤」）。要辨識「這是 Option+1」只能回頭看實體鍵。
//   2. `NSEvent.charactersIgnoringModifiers` 仍會保留 Shift 的翻譯（Shift+, 得到 `<`），
//      在各家 app／IMK 版本下的行為也不一致 ⇒ 不拿它當鍵的身份。
// 所以轉接層要用 `keyCode` ＋ `modifierFlags` 建 `Chord`（`Chord.init?(keyCode:modifiers:)`）。
//
// ⚠️ 範圍：`ansiKeyCodes` 只涵蓋 **ANSI（美式）實體排列**。ISO／JIS 的 keyCode 與符號位置不同
// （例如 JIS 沒有 `~` 鍵、`\` 的位置也不一樣），本輪**未確認**，遇到就回 `nil` ⇒ 放行。

import Foundation

public enum MacInputTables {
    /// 中／英模式。與 `mac-ime-wiring` 的 `MacInputLanguage` 語意相同（`en` 時一律放行）；
    /// 接線時做一次 1:1 對映即可。
    public enum Language: Equatable {
        case zh
        case en
    }

    /// 標點全形／半形。**這是要產品決策的題目**（見 spec Q-P1）：目前只有 `.full` 有內容，
    /// `.half` 下表內每一格都回 `.unconfirmed(.halfWidthUndecided)`，不偷偷給答案。
    public enum WidthMode: Equatable {
        case full
        case half
    }

    /// 修飾鍵。**Caps Lock 不在這裡**：它是鎖定狀態不是和弦修飾，語意屬於 G6（`SwitchEvent.capsLock`）。
    public struct Modifiers: OptionSet, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    /// 一次按鍵＝「哪個實體鍵」＋「按住哪些修飾鍵」。
    public struct Chord: Hashable {
        /// 該實體鍵在 **US 排列、無修飾**時產生的字元（`,` `.` `[` `1` `a` …；空白鍵是 `" "`）。
        public let key: Character
        public let modifiers: Modifiers
        /// 數字鍵盤上的鍵。與主鍵區同字元的鍵是**不同的和弦**（`.` 在主鍵區是注音 ㄡ，在數字鍵盤是小數點）。
        public let isNumpad: Bool

        public init(key: Character, modifiers: Modifiers = [], isNumpad: Bool = false) {
            self.key = key
            self.modifiers = modifiers
            self.isNumpad = isNumpad
        }

        /// 從 IMK `inputText:client:` 交付的**字串入口**反推和弦：只涵蓋 ASCII（無修飾或 Shift）。
        ///
        /// 為什麼有這個：現行 controller 的入口只拿得到「被 Shift 翻譯過的字元」（Shift+, → `<`）。
        /// G5 的 confirmed／corroborated 格子全都只靠 Shift／無修飾，所以**字串入口就夠接線**，
        /// 不必等 `mac-ime-wiring` 決定要不要換成 keyCode 入口。
        /// ⚠️ 涵蓋不到 Option／Ctrl／數字鍵盤（Option+1 交付的是 `¡`、Ctrl+; 是控制字元）⇒ 那些需要 keyCode。
        public init?(deliveredCharacter c: Character) {
            guard let (key, shift) = MacInputTables.usBaseKey(ofDelivered: c) else { return nil }
            self.init(key: key, modifiers: shift ? .shift : [])
        }

        /// 從 `NSEvent.keyCode` 建。不在表內的鍵（方向鍵、功能鍵、ISO／JIS 專屬鍵…）回 `nil` ⇒ 轉接層放行。
        public init?(keyCode: UInt16, modifiers: Modifiers) {
            if let key = MacInputTables.ansiKeyCodes[keyCode] {
                self.init(key: key, modifiers: modifiers)
            } else if let key = MacInputTables.numpadKeyCodes[keyCode] {
                self.init(key: key, modifiers: modifiers, isNumpad: true)
            } else {
                return nil
            }
        }
    }

    /// ANSI 主鍵區：keyCode → 無修飾字元（26 字母＋10 數字＋11 符號＋空白 ＝ 48 鍵）。
    /// 出處：`tools/mac_input_tables_probe` 的 live 核對每次都會拿它去對 Apple 標準注音鍵盤層
    ///（`UCKeyTranslate` 對每個 keyCode 實測），抄錯會紅。
    public static let ansiKeyCodes: [UInt16: Character] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b",
        12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p",
        37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "n", 46: "m", 47: ".",
        49: " ", 50: "`",
    ]

    /// 數字鍵盤：keyCode → 字元（0–9 與 `. * + / - =`，共 16 鍵）。
    public static let numpadKeyCodes: [UInt16: Character] = [
        65: ".", 67: "*", 69: "+", 75: "/", 78: "-", 81: "=",
        82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9",
    ]

    private static let baseKeys = Set(ansiKeyCodes.values)

    private static let usShifted: [Character: Character] = [
        "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
        "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?", "`": "~",
    ]

    private static let shiftedToBase: [Character: Character] = Dictionary(
        uniqueKeysWithValues: usShifted.map { ($0.value, $0.key) })

    /// `usASCII` 的反函數：一個交付的 ASCII 字元是「哪顆鍵、有沒有按 Shift」。非 ASCII 回 `nil`。
    static func usBaseKey(ofDelivered c: Character) -> (key: Character, shift: Bool)? {
        guard c.isASCII else { return nil }
        if baseKeys.contains(c) { return (c, false) }
        if c.isLetter, c.isUppercase, baseKeys.contains(Character(c.lowercased())) {
            return (Character(c.lowercased()), true)
        }
        if let base = shiftedToBase[c] { return (base, true) }
        return nil
    }

    /// US 鍵盤上這顆鍵（加或不加 Shift）會打出的 ASCII 字元。空白鍵與不在主鍵區的字元回 `nil`。
    public static func usASCII(key: Character, shift: Bool) -> Character? {
        guard key != " ", baseKeys.contains(key) else { return nil }
        guard shift else { return key }
        if key.isLetter { return Character(key.uppercased()) }
        return usShifted[key]
    }
}
