// SPDX-License-Identifier: Apache-2.0
// G5 標點鍵位表：「哪個實體鍵＋修飾鍵 → 哪個中文標點」，**每一格都帶證據**。
//
// 🔴 **這張表不是憑印象填的。** 大千式排列上 `1 2 5 8 9 0 -`、大部分字母與 `; , . /` 都是注音符號鍵，
// `3 4 6 7` 是聲調鍵，空白鍵是一聲——標點到底怎麼打不能推理，只能查。每一格記錄「哪個來源說了什麼」
//（`claims`），`status` 必須與證據相符，這由 `tools/mac_input_tables_probe` 逐格機械檢查
//（`testEvidenceInvariants`），而不是靠人自律。
//
// 證據來源（查證日 2026-09-21，macOS 26.5.2）：
//   • `appleKeyboardLayout`：這台機器上 `com.apple.keylayout.ZhuyinBopomofo`（內建注音使用的標準／大千式
//     鍵盤層），用 `TISGetInputSourceProperty(kTISPropertyUnicodeKeyLayoutData)` ＋ `UCKeyTranslate`
//     唯讀查詢。**第一手，且每次跑測試都會重新對照（live 核對）。**
//     ⚠️ 限制：這是「鍵盤層輸出什麼字元」，不是「Apple 的 IME 收到之後做了什麼」。鍵盤層給 ASCII 的
//     格子（`? ! : ( )`），IME 是否轉全形無法離線觀測 ⇒ 只能標 `corroborated`，不能標 `confirmed`。
//   • `mcBopomofo`：McBopomofo 的 `Source/Data/BPMFPunctuations.txt`（MIT，資料檔）。
//   • `libchewing`：libchewing 的 `src/conversion/symbol.rs` 的對照表。**LGPL，只取鍵位事實，
//     沒有複製任何程式碼。**
//   • `vChewing`：`Sources/vChewingIME_macOS/Resources/en.lproj/shortcuts.html` 與 `Localizable.strings`
//     （MulanPSL-2.0 的外殼文件）＋ 測試詞庫的鍵集合。**引擎側（LGPL）一行沒讀來抄，只取快捷鍵事實。**
//   • `twkeyboardIOS`：我們自己 iOS 端的既有決策。
//
// 狀態的定義（`CellStatus`）：
//   • `.confirmed`     — Apple 鍵盤層第一手直接輸出該字元。與其他來源不同時，依「macOS 內建優先」採 Apple，
//                        差異寫在 `note`（使用者可以推翻，見 spec）。
//   • `.corroborated`  — Apple 鍵盤層只給 ASCII；≥2 個非 Apple 實作一致地把它轉成**全形對應字元**
//                        （純寬度轉換，不是重新指派按鍵）。**Apple 內建注音實際是否如此：請實機核對。**
//   • `.unconfirmed`   — 其他一切：來源互相矛盾、只有非 Apple 來源支持的「重新指派」、或根本找不到和弦。
//                        **`lookup` 不給輸出值**；答案列進 spec 的待決清單。

import Foundation

extension MacInputTables {
    public enum Source: Equatable {
        case appleKeyboardLayout
        case mcBopomofo
        case libchewing
        case vChewing
        case twkeyboardIOS
    }

    /// 一則證據：某來源在**這個和弦**上說了什麼。`value == nil` ＝ 該來源在這個和弦上沒有這個字元
    ///（`detail` 說明它把這個字元或這個和弦放在哪、是什麼意思）。
    public struct Claim: Equatable {
        public let source: Source
        public let value: String?
        public let detail: String
    }

    public enum Confidence: Equatable {
        case confirmed
        case corroborated
    }

    public enum PendingReason: Equatable {
        /// 來源之間互相矛盾（同一個字元在不同來源放在不同鍵／同一個鍵在不同來源意義不同）。
        case sourcesConflict
        /// 只有非 Apple 來源支持這個「重新指派」，Apple 的鍵盤層在這個和弦上給的是 ASCII ⇒ 無法確認 Apple 內建的行為。
        case placementNotVerifiedByApple
        /// 沒有任何來源給出直接和弦（只能靠候選選字、符號選單或面板）。
        case noChordFoundInAnySource
        /// 半形模式本身還沒決定，`.half` 下表內每一格都是這個原因。
        case halfWidthUndecided
    }

    public enum CellStatus: Equatable {
        case confirmed
        case corroborated
        case unconfirmed(PendingReason)
    }

    public struct Cell {
        public let id: String
        /// 這一格要輸出的字串（**未確認的格子也記著它「想」輸出什麼，但 `lookup` 不會給出去**）。
        public let glyph: String
        /// `nil` ＝ 沒有任何來源提供直接和弦。
        public let chord: Chord?
        public let status: CellStatus
        public let claims: [Claim]
        public let note: String
    }

    /// 查表結果。`.unconfirmed` 與 `.notHandled` 對呼叫端都是「不由本表處理」，但語意不同：
    /// 前者是「這格有、答案還沒定」，值得 log／在實機時回報；後者是「根本不是這張表的鍵」。
    public enum Lookup: Equatable {
        /// 已查證：上屏這個字串。`Confidence` 讓 spec 的實機核對清單能對到格子。
        case output(String, Confidence)
        /// 不是本表的鍵（或 `Language == .en`）⇒ 交給下一層（注音／聲調／原封放行）。
        case notHandled
        /// 表裡有這格，但答案未確認 ⇒ **呼叫端不得自己編值**；建議當 `.notHandled` 放行並記錄。
        case unconfirmed(cellID: String, reason: PendingReason)
    }

    // MARK: - 證據記帳

    private static func apple(_ value: String?, _ detail: String) -> Claim {
        Claim(source: .appleKeyboardLayout, value: value, detail: "Apple ZhuyinBopomofo 鍵盤層：" + detail)
    }

    private static func mcb(_ value: String?, _ detail: String) -> Claim {
        Claim(source: .mcBopomofo, value: value, detail: "McBopomofo BPMFPunctuations.txt：" + detail)
    }

    private static func chewing(_ value: String?, _ detail: String) -> Claim {
        Claim(source: .libchewing, value: value, detail: "libchewing symbol.rs：" + detail)
    }

    private static func vchewing(_ value: String?, _ detail: String) -> Claim {
        Claim(source: .vChewing, value: value, detail: "vChewing：" + detail)
    }

    // MARK: - 表

    /// 任務書列的字元 `，。、；：？！「」『』（）—— …　·` 每一個都在這裡有一格（未確認的也要記帳）。
    /// 碼位一律用 `\u{…}` 寫，避免「，」與「,」這類相似字混淆；括號內是該字元本身。
    public static let punctuationCells: [Cell] = [
        // ── confirmed：Apple 鍵盤層第一手 ────────────────────────────────────────
        Cell(
            id: "comma", glyph: "\u{FF0C}",  // ，
            chord: Chord(key: ",", modifiers: .shift), status: .confirmed,
            claims: [
                apple("\u{FF0C}", "keyCode 43 的 Shift 層直接輸出 U+FF0C"),
                mcb("\u{FF0C}", "_punctuation_Standard_<（< ＝ Shift+,）的第一候選"),
                chewing("\u{FF0C}", "'<' 對映 U+FF0C"),
            ], note: "Apple、McBopomofo、libchewing 三方一致。"),
        Cell(
            id: "period", glyph: "\u{3002}",  // 。
            chord: Chord(key: ".", modifiers: .shift), status: .confirmed,
            claims: [
                apple("\u{3002}", "keyCode 47 的 Shift 層直接輸出 U+3002"),
                mcb("\u{3002}", "_punctuation_Standard_>（> ＝ Shift+.）的第一候選"),
                chewing("\u{3002}", "'>' 對映 U+3002"),
            ], note: "Apple、McBopomofo、libchewing 三方一致。"),
        Cell(
            id: "dun", glyph: "\u{3001}",  // 、
            chord: Chord(key: "\\"), status: .confirmed,
            claims: [
                apple("\u{3001}", "keyCode 42（\\ 鍵）無修飾層直接輸出 U+3001"),
                mcb("\u{FF3C}", "\\ 鍵給 ＼（U+FF3C）／；把 、 放在 ' 鍵（見 dun-at-apostrophe）"),
                chewing("\u{FF3C}", "'\\\\' 對映 ＼（U+FF3C）；把 、 放在 '\\'' 鍵"),
            ],
            note: "與兩個開源實作不同：Apple 把 、 放在 \\，小麥／新酷音放在 '。依『macOS 內建優先』採 Apple；"
                + "要不要兩個位置都給，見 spec Q-P2。"),
        Cell(
            id: "corner-open", glyph: "\u{300C}",  // 「
            chord: Chord(key: "["), status: .confirmed,
            claims: [
                apple("\u{300C}", "keyCode 33（[ 鍵）無修飾層直接輸出 U+300C"),
                mcb("\u{300C}", "_punctuation_["),
                chewing("\u{300C}", "'[' 對映 U+300C"),
            ], note: "三方一致。"),
        Cell(
            id: "corner-close", glyph: "\u{300D}",  // 」
            chord: Chord(key: "]"), status: .confirmed,
            claims: [
                apple("\u{300D}", "keyCode 30（] 鍵）無修飾層直接輸出 U+300D"),
                mcb("\u{300D}", "_punctuation_]"),
                chewing("\u{300D}", "']' 對映 U+300D"),
            ], note: "三方一致。"),
        Cell(
            id: "dcorner-open", glyph: "\u{300E}",  // 『
            chord: Chord(key: "[", modifiers: .shift), status: .confirmed,
            claims: [
                apple("\u{300E}", "keyCode 33 的 Shift 層直接輸出 U+300E"),
                mcb("\u{300E}", "_punctuation_{ 的第一候選（其後還有 《 〔 ｛ 〈 【 〖 需選字）"),
                chewing("\u{300E}", "'{' 對映 U+300E"),
            ], note: "三方一致。"),
        Cell(
            id: "dcorner-close", glyph: "\u{300F}",  // 』
            chord: Chord(key: "]", modifiers: .shift), status: .confirmed,
            claims: [
                apple("\u{300F}", "keyCode 30 的 Shift 層直接輸出 U+300F"),
                mcb("\u{300F}", "_punctuation_} 的第一候選"),
                chewing("\u{300F}", "'}' 對映 U+300F"),
            ], note: "三方一致。"),
        Cell(
            id: "middle-dot", glyph: "\u{00B7}",  // ·
            chord: Chord(key: "`"), status: .confirmed,
            claims: [
                apple("\u{00B7}", "keyCode 50（` 鍵）無修飾層直接輸出 U+00B7（MIDDLE DOT，不是 U+2027）"),
                mcb(nil, "` 鍵是「符號選單」觸發鍵（_punctuation_list），不直接輸出字元"),
                chewing(nil, "` 鍵開符號選擇對話框"),
            ],
            note: "與兩個開源實作意義不同：它們的 ` 是符號選單。依『macOS 內建優先』採 Apple；日後若要做符號選單需重新協調這顆鍵。"),
        Cell(
            id: "em-dash-option", glyph: "\u{2014}",  // —
            chord: Chord(key: "-", modifiers: .option), status: .confirmed,
            claims: [
                apple("\u{2014}", "keyCode 27（- 鍵）的 Option 層輸出 U+2014（Option+Shift 層則是 _）"),
                mcb(nil, "把 — 放在 Shift+-（_punctuation__ 第一候選，U+2014），不在 Option 層"),
                chewing(nil, "'_' 對映 U+2014，即 Shift+-，不在 Option 層"),
            ],
            note: "Apple 只給**單一** U+2014；中文常寫的「——」（兩個）要按兩次，見 double-dash。"),

        // ── corroborated：Apple 只給 ASCII，≥2 個非 Apple 實作一致轉全形 ─────────────
        Cell(
            id: "question", glyph: "\u{FF1F}",  // ？
            chord: Chord(key: "/", modifiers: .shift), status: .corroborated,
            claims: [
                apple("?", "keyCode 44 的 Shift 層輸出 ASCII ?（U+003F）；Apple IME 是否轉全形無法離線觀測"),
                mcb("\u{FF1F}", "_punctuation_?"),
                chewing("\u{FF1F}", "'?' 對映 U+FF1F"),
            ], note: "請實機用 Apple 內建注音按 Shift+/ 核對。"),
        Cell(
            id: "exclaim", glyph: "\u{FF01}",  // ！
            chord: Chord(key: "1", modifiers: .shift), status: .corroborated,
            claims: [
                apple("!", "keyCode 18 的 Shift 層輸出 ASCII !（U+0021）；Apple IME 是否轉全形無法離線觀測"),
                mcb("\u{FF01}", "_punctuation_!"),
                chewing("\u{FF01}", "'!' 對映 U+FF01"),
            ], note: "請實機用 Apple 內建注音按 Shift+1 核對。"),
        Cell(
            id: "colon", glyph: "\u{FF1A}",  // ：
            chord: Chord(key: ";", modifiers: .shift), status: .corroborated,
            claims: [
                apple(":", "keyCode 41 的 Shift 層輸出 ASCII :（U+003A）；Apple IME 是否轉全形無法離線觀測"),
                mcb("\u{FF1A}", "_punctuation_Standard_:"),
                chewing("\u{FF1A}", "':' 對映 U+FF1A"),
            ], note: "請實機用 Apple 內建注音按 Shift+; 核對。"),
        Cell(
            id: "paren-open", glyph: "\u{FF08}",  // （
            chord: Chord(key: "9", modifiers: .shift), status: .corroborated,
            claims: [
                apple("(", "keyCode 25 的 Shift 層輸出 ASCII (（U+0028）；Apple IME 是否轉全形無法離線觀測"),
                mcb("\u{FF08}", "_punctuation_("),
                chewing("\u{FF08}", "'(' 對映 U+FF08"),
            ], note: "請實機用 Apple 內建注音按 Shift+9 核對。"),
        Cell(
            id: "paren-close", glyph: "\u{FF09}",  // ）
            chord: Chord(key: "0", modifiers: .shift), status: .corroborated,
            claims: [
                apple(")", "keyCode 29 的 Shift 層輸出 ASCII )（U+0029）；Apple IME 是否轉全形無法離線觀測"),
                mcb("\u{FF09}", "_punctuation_)"),
                chewing("\u{FF09}", "')' 對映 U+FF09"),
            ], note: "請實機用 Apple 內建注音按 Shift+0 核對。"),

        // ── unconfirmed：不給輸出值，列進 spec 的待決清單 ─────────────────────────────
        Cell(
            id: "dun-at-apostrophe", glyph: "\u{3001}",  // 、
            chord: Chord(key: "'"), status: .unconfirmed(.sourcesConflict),
            claims: [
                apple("'", "keyCode 39（' 鍵）無修飾層輸出 ASCII '；Apple 把 、 放在 \\ 鍵（見 dun）"),
                mcb("\u{3001}", "_punctuation_Standard_'"),
                chewing("\u{3001}", "'\\'' 對映 U+3001"),
            ],
            note: "兩個開源實作把 、 放在 '，Apple 放在 \\——同一個字元兩個位置。Apple 的 IME 對 ' 做什麼未知。見 spec Q-P2。"),
        Cell(
            id: "semicolon-at-quote", glyph: "\u{FF1B}",  // ；
            chord: Chord(key: "'", modifiers: .shift), status: .unconfirmed(.placementNotVerifiedByApple),
            claims: [
                apple("\"", "keyCode 39 的 Shift 層輸出 ASCII \"；Apple 把 ； 放在哪未知"),
                mcb("\u{FF1B}", "_punctuation_Standard_\"（\" ＝ Shift+'）"),
                chewing("\u{FF1B}", "'\"' 對映 U+FF1B"),
            ],
            note: "兩個開源實作一致，但這是「重新指派」（把 ； 放在雙引號鍵上）不是寬度轉換，Apple 的位置查不到。見 spec Q-P3。"),
        Cell(
            id: "semicolon-ctrl", glyph: "\u{FF1B}",  // ；
            chord: Chord(key: ";", modifiers: .control), status: .unconfirmed(.placementNotVerifiedByApple),
            claims: [
                apple(nil, "Apple 文件與鍵盤層都沒有 Ctrl+標點這個和弦"),
                mcb("\u{FF1B}", "_ctrl_punctuation_;（McBopomofo 有一整組 Ctrl+ , . ' ; / ! 標點）"),
                vchewing(nil, "測試詞庫有 _ctrl_punctuation_; 這個鍵（只有鍵集合，沒有對應字元）"),
            ],
            note: "只有 McBopomofo 給了值。見 spec Q-P3。"),
        Cell(
            id: "ellipsis", glyph: "\u{2026}",  // …
            chord: nil, status: .unconfirmed(.noChordFoundInAnySource),
            claims: [
                apple(nil, "所有修飾層都沒有 U+2026"),
                mcb("\u{2026}", "只在 _ (Shift+-) 的候選清單第二順位與符號選單裡，需要選字，沒有直接和弦"),
                chewing(nil, "'_' 只對映 —，沒有 …"),
            ], note: "見 spec Q-P4：要不要為它指定和弦。"),
        Cell(
            id: "double-dash", glyph: "\u{2014}\u{2014}",  // ——
            chord: nil, status: .unconfirmed(.noChordFoundInAnySource),
            claims: [
                apple("\u{2014}", "Option+- 只輸出單一 U+2014"),
                mcb("\u{2014}", "_ 的第一候選是單一 U+2014"),
                chewing("\u{2014}", "'_' 對映單一 U+2014"),
            ], note: "沒有任何來源一鍵輸出兩個；按兩次 Option+- 可得「——」（兩個 U+2014）。見 spec Q-P4。"),
        Cell(
            id: "ideographic-space", glyph: "\u{3000}",  // 　（全形空白）
            chord: Chord(key: " ", modifiers: .shift), status: .unconfirmed(.sourcesConflict),
            claims: [
                apple(nil, "Apple 說明頁：Shift-Space 是「顯示結構候選」（不是全形空白）"),
                vchewing("\u{3000}", "shortcuts.html：⇧␣ 在組字區為空時輸入全形空白"),
                chewing(nil, "README：Shift-Space 是切換全形／半形模式"),
            ], note: "三個來源給三種意思。見 spec Q-P5。"),
    ]

    private static let cellsByChord: [Chord: Cell] = Dictionary(
        punctuationCells.compactMap { cell in cell.chord.map { ($0, cell) } },
        uniquingKeysWith: { first, _ in first })

    // MARK: - 查表

    /// 標點查表。**只回答「這個和弦是不是標點」**——注音鍵、聲調鍵、空白（一聲）都不是這張表的事，
    /// 無修飾時一律 `.notHandled`（大千式硬約束，有測試鎖住）。
    ///
    /// 規則：
    ///   1. `Language == .en` ⇒ 一律 `.notHandled`。
    ///   2. 數字鍵盤 ⇒ `.notHandled`（Apple 鍵盤層直接給 ASCII 數字；vChewing 文件明說不處理數字鍵盤；
    ///      McBopomofo 直接上屏）。
    ///   3. 表內的和弦：`.half` ⇒ `.unconfirmed(.halfWidthUndecided)`；否則依 `status`。
    ///   4. **Option（可加 Shift）＋主鍵區的鍵 ⇒ ASCII 逃逸**：輸出該鍵在 US 鍵盤上的 ASCII 字元
    ///      （`Option+1` → `1`、`Option+Shift+,` → `<`）。證據：Apple 鍵盤層的 Option 層／Option+Shift 層
    ///      對主鍵區每一個鍵都是這樣（例外 `Option+-` ＝ 破折號，是表內的一格）；vChewing 文件也說
    ///      Option+數字鍵輸出半形數字。**為什麼必須由 IME 自己輸出而不是放行**：放行的話宿主 app 會收到
    ///      ABC 排列翻譯後的字元（Option+1 → `¡`）。
    ///   5. 其他（Command、Control、Shift+字母、不在表內的組合）⇒ `.notHandled`。
    public static func lookup(_ chord: Chord, language: Language, width: WidthMode = .full) -> Lookup {
        guard language == .zh, !chord.isNumpad else { return .notHandled }

        if let cell = cellsByChord[chord] {
            if width == .half { return .unconfirmed(cellID: cell.id, reason: .halfWidthUndecided) }
            switch cell.status {
            case .confirmed: return .output(cell.glyph, .confirmed)
            case .corroborated: return .output(cell.glyph, .corroborated)
            case .unconfirmed(let reason): return .unconfirmed(cellID: cell.id, reason: reason)
            }
        }

        if chord.modifiers.subtracting(.shift) == .option,
            let ascii = usASCII(key: chord.key, shift: chord.modifiers.contains(.shift))
        {
            return .output(String(ascii), .confirmed)
        }
        return .notHandled
    }
}
