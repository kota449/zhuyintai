// SPDX-License-Identifier: Apache-2.0
// 組字區（marked text）要顯示什麼。**純邏輯，零 AppKit／IMK／引擎型別。**
//
// ## 這個檔案存在的原因：三份證據、同一個病
//
// ① **使用者回報**：「我打一個注音，它就會出現兩個注音」
// ② **稽核**：洞 A（`⌫` 重開已收尾音節被畫兩次）、
//    洞 B（`.startNew` auto-flush 的音節從畫面消失）
// ③ **實機 log —— 真兇**：
//    ```
//    seq=30  keys=[ㄅㄨˊ,ㄕ,ㄓ,ㄏ]  comp=不是隻黑
//    seq=31  keys=[ㄅㄨˊ,ㄕ,ㄓ]     comp=不是之
//    ```
//    `ㄕ`／`ㄓ`／`ㄏ` 使用者**從沒按過聲調**（`.startNew` 自動 flush 進引擎的），
//    引擎照樣把它們解析成漢字 ⇒ 畫面出現一整排他沒打完、也沒選過的字，
//    **而且每按一鍵整句重跳一次**。這就是「打字體驗差到不行」的主要來源。
//
// 病根一句話：**顯示層在用「這個 key 在不在引擎裡」決定要不要顯示漢字。**
// 正確的判準是「**使用者有沒有親手收尾過這個音節**」。
//
// ## 規則
//
// 逐個 `gram`（引擎 `assembledSentence` 的一段，可能覆蓋多個 key）決定顯示形式：
//
// | 情況 | 顯示 |
// |---|---|
// | 這一段包含「正在拼的那個 key」 | 逐 key 展開，該 key 換成**緩衝區**內容 |
// | 這一段的每個 key 都 sealed | `gram.value`（**漢字**） |
// | 任一 key unsealed | 該段的 key 原文（**注音**） |
//
// 多 key 的詞只要有一個 key 沒收尾就整段退回注音——否則那個沒打完的音節會以
// 「詞的一部分」的形式偷偷變成字，等於換個地方犯同一個錯。
//
// sealed 的判準用引擎既有的 `ZhuyinEngine.isSealed(key:atKeyCount:)`（public，
// G4 執行端已經在用同一套帳）。轉接層負責把 `assembledSentence` 與 sealed 旗標
// 打包成 `MacComposedSegment` 餵進來，這一層就完全不必認識 `Megrez`／`ZhuyinEngine`。
//
// ## 這一版取代了什麼
//
// 第一版用「上一次緩衝區為空(settled)時的 composed」當**快取前綴**——稽核 #1 指出
// 它有兩個洞（前綴只在緩衝區為空時更新，但 reopen 與 startNew 都不經過那一刻）。
// 第二版改成「用游標前那一格切開 composed」——修掉了洞 A／洞 B，但**修不掉 R3**：
// 它只處理最尾端那一格，前面那些 auto-flush 的音節照樣顯示成漢字。
// 這一版是三條一起解的那個機制。

import Foundation

/// 注音浮窗的一欄（見 `MacMarkedTextState.readingColumns`）。
public struct MacReadingColumn: Equatable {
    /// 組字區顯示的字（沒收尾的音節就是注音本身）。
    public let text: String
    /// 使用者實際打的注音。
    public let reading: String
    /// 游標前那一欄（退格／候選窗改的就是它）。
    public let isEdited: Bool
}

/// 引擎 `assembledSentence` 的一段，加上「每個 key 使用者有沒有親手收尾」。
public struct MacComposedSegment: Equatable {
    /// 這一段覆蓋的 key（注音原文，含聲調）。多於一個 ⇒ 這是一個詞。
    public let keys: [String]
    /// 引擎替這一段組出來的漢字。
    public let value: String
    /// 與 `keys` 一一對應：該 key 是否已被使用者親手收尾（`ZhuyinEngine.isSealed`）。
    public let sealedFlags: [Bool]

    public init(keys: [String], value: String, sealedFlags: [Bool]) {
        self.keys = keys
        self.value = value
        self.sealedFlags = sealedFlags
    }

    /// 全部 key 都收尾過才准以漢字示人。
    var isFullySealed: Bool {
        !keys.isEmpty && sealedFlags.count == keys.count && sealedFlags.allSatisfy { $0 }
    }
}

public enum MacMarkedTextState {

    /// 要送進 `client.setMarkedText` 的字串。
    ///
    /// - Parameters:
    ///   - segments: 引擎的 `assembledSentence` 加上 sealed 旗標（見 `MacComposedSegment`）。
    ///   - pendingBuffer: `LegalKeySyllableComposer.currentBuffer`（正在拼、未收尾的注音）。
    ///   - pendingKeyIndex: 正在拼的那個 key 的**全域索引**＝`compositionCursor - 1`。
    ///     緩衝區為空時傳 `-1`。
    ///     🔴 用游標相對而不是「最後一格」：`settled` 時把游標 `←←` 移到中間再打字，
    ///     引擎會在**游標處**插入新 key（與 G4 的 Bug A 同一條原則）。
    public static func display(
        segments: [MacComposedSegment], pendingBuffer: String, pendingKeyIndex: Int
    ) -> String {
        renderPieces(
            segments: segments, pendingBuffer: pendingBuffer, pendingKeyIndex: pendingKeyIndex
        ).map(\.text).joined()
    }

    /// 顯示層實際走過幾個 key。
    ///
    /// 🔴 這是 log 的機械哨兵 `DISP_MISMATCH` 的來源：與引擎的 `compositorKeys.count` 不等
    /// ⇒ 顯示層漏了或多了一段。稽核 #2 原本提的公式是拿**字元數**推算的
    /// （`(disp 字數 − buf 字數) + 1`），但 R3 之後 unsealed 音節顯示的是注音原文
    /// （1～3 個字元不等）⇒ 正常情形也會被標記。顯示既然是逐 key 組的，就直接數 key。
    public static func displayedKeyCount(
        segments: [MacComposedSegment], pendingBuffer: String, pendingKeyIndex: Int
    ) -> Int {
        renderPieces(
            segments: segments, pendingBuffer: pendingBuffer, pendingKeyIndex: pendingKeyIndex
        ).last?.keyIndexAfter ?? 0
    }

    /// marked text 裡的游標（插入點）位置，**UTF-16 code unit**。
    ///
    /// 🔴 長度用 `utf16.count` 而不是 `String.count`：`NSRange` 是 UTF-16 語意，
    /// 而 `String.count` 數的是 `Character`。罕見漢字（中日韓擴充 B／C 區，surrogate pair）
    /// 一個 `Character` 佔 2 個 UTF-16 單位 ⇒ 用 `.count` 會讓游標往前偏。
    ///
    /// 有了 `segments`（每段知道自己覆蓋哪幾個 key、顯示成什麼）之後，這個位置是
    /// **精確的**——不再是前兩版那種「一個音節≈一個漢字」的比例近似。
    ///
    /// - Parameter cursorKeyIndex: `ZhuyinEngine.compositionCursor`（游標在第幾個 key 之前）。
    public static func selectionLocation(
        segments: [MacComposedSegment],
        pendingBuffer: String,
        pendingKeyIndex: Int,
        cursorKeyIndex: Int
    ) -> Int {
        let pieces = renderPieces(
            segments: segments, pendingBuffer: pendingBuffer, pendingKeyIndex: pendingKeyIndex
        )
        var location = 0
        for piece in pieces {
            // `keyIndexAfter` ＝ 這一段結束後，已經走過幾個 key。
            if piece.keyIndexAfter <= cursorKeyIndex {
                location += piece.text.utf16.count
                continue
            }
            // 游標落在這一段**內部**（只可能發生在多 key 的詞裡）。
            // 🔴 稽核 #5 實測：舊碼在這裡整段不計，caret 貼到詞的開頭 ——
            //   畫面「你好世界」按 ←：cur=3 卻 sel=2（一次跳 2 格）、再 ← 完全不動、再 ← 跳到 0。
            //   使用者看到 caret 在「好│世」，打下去的字卻插在「世│界」之間。
            let insideKeys = cursorKeyIndex - piece.keyIndexBefore
            if insideKeys > 0 {
                if piece.oneCharPerKey {
                    // 每個 key 剛好一個字 ⇒ 第 n 個 key 之後就是第 n 個字之後（精確）。
                    // 用 `Character` 切、再換算 UTF-16，罕見漢字（surrogate pair）才不會被切在中間。
                    location += String(piece.text.prefix(insideKeys)).utf16.count
                } else if insideKeys * 2 > piece.keyIndexAfter - piece.keyIndexBefore {
                    // 字數 ≠ key 數 ⇒ 沒有可靠的對位。**寧可貼最近的邊界，也不猜一個
                    // 會讓 caret 畫在錯字之間的位置**（顯示層自己猜引擎狀態，
                    // 正是這一輪所有 bug 的來源）。
                    location += piece.text.utf16.count
                }
            }
            break
        }
        return location
    }

    /// 注音浮窗的欄位：上排是組字區顯示的字，下排是使用者實際打的注音。
    ///
    /// 2026-09-23 使用者：打太快拼錯時，分不出是自己打錯還是它選錯。
    /// 上排直接用 `renderPieces`，保證跟組字區顯示的一模一樣。
    /// 一字一音的詞拆成一欄一字；字數對不上 key 數時整段一欄，不猜字的邊界。
    public static func readingColumns(
        segments: [MacComposedSegment],
        pendingBuffer: String,
        pendingKeyIndex: Int,
        cursorKeyIndex: Int
    ) -> [MacReadingColumn] {
        let pieces = renderPieces(
            segments: segments, pendingBuffer: pendingBuffer, pendingKeyIndex: pendingKeyIndex
        )
        let keys = segments.flatMap(\.keys)
        func reading(at index: Int) -> String {
            if index == pendingKeyIndex || !keys.indices.contains(index) { return pendingBuffer }
            return keys[index]
        }
        let edited = max(cursorKeyIndex - 1, 0)

        var columns: [MacReadingColumn] = []
        for piece in pieces {
            let span = piece.keyIndexBefore ..< piece.keyIndexAfter
            if span.count > 1, piece.oneCharPerKey {
                for (offset, character) in piece.text.enumerated() {
                    let index = span.lowerBound + offset
                    columns.append(MacReadingColumn(
                        text: String(character), reading: reading(at: index), isEdited: index == edited))
                }
            } else {
                columns.append(MacReadingColumn(
                    text: piece.text,
                    reading: span.map(reading(at:)).joined(separator: " "),
                    isEdited: span.contains(edited)))
            }
        }
        return columns
    }

    /// 浮窗實際顯示的欄位：到游標前那一欄為止，往前最多 `limit` 欄。
    ///
    /// 2026-09-23 使用者：字不用再顯示一次（組字區就在正上方），只要前三個字的注音，
    /// 整排太長。窗跟著游標走，左右鍵移到句中時顯示的是正在改的地方。
    public static func readingWindow(_ columns: [MacReadingColumn], limit: Int = 3) -> [MacReadingColumn] {
        guard !columns.isEmpty else { return [] }
        let end = columns.lastIndex(where: \.isEdited) ?? columns.count - 1
        return Array(columns[max(end - limit + 1, 0) ... end])
    }

    // MARK: - 內部

    private struct Piece {
        let text: String
        /// 這一段開始前累計走過的 key 數。
        let keyIndexBefore: Int
        /// 這一段結束後累計走過的 key 數（1-based 邊界）。
        let keyIndexAfter: Int
        /// 這一段是「漢字、且字數 == key 數」——每個 key 剛好對到一個字，
        /// 游標落在內部時才能精確換算成字串位置。
        let oneCharPerKey: Bool

        init(text: String, keyIndexBefore: Int, keyIndexAfter: Int, oneCharPerKey: Bool = false) {
            self.text = text
            self.keyIndexBefore = keyIndexBefore
            self.keyIndexAfter = keyIndexAfter
            self.oneCharPerKey = oneCharPerKey
        }
    }

    private static func renderPieces(
        segments: [MacComposedSegment], pendingBuffer: String, pendingKeyIndex: Int
    ) -> [Piece] {
        var pieces: [Piece] = []
        var keyCursor = 0
        var pendingRendered = false

        for segment in segments {
            let range = keyCursor ..< (keyCursor + segment.keys.count)
            defer { keyCursor = range.upperBound }

            if range.contains(pendingKeyIndex) {
                // 正在拼的那個 key 用緩衝區的注音。已經切出去的其他 key 用漢字
                //（小麥注音／微軟新注音：沒按聲調就開下一字，前一個音節當一聲上屏到組字區）。
                let characters = Array(segment.value)
                let canAlign = characters.count == segment.keys.count
                for (offset, key) in segment.keys.enumerated() {
                    let globalIndex = range.lowerBound + offset
                    let text: String
                    if globalIndex == pendingKeyIndex {
                        text = pendingBuffer
                    } else if canAlign {
                        text = String(characters[offset])
                    } else {
                        text = key
                    }
                    pieces.append(
                        Piece(text: text, keyIndexBefore: globalIndex, keyIndexAfter: globalIndex + 1))
                }
                pendingRendered = true
                continue
            }

            if segment.isFullySealed {
                pieces.append(
                    Piece(
                        text: segment.value,
                        keyIndexBefore: range.lowerBound,
                        keyIndexAfter: range.upperBound,
                        oneCharPerKey: segment.value.count == segment.keys.count))
                continue
            }

            // 有沒收尾的 key。
            //
            // 🔴 使用者回報（實機）：「我只要一按退後鍵它全部字就顯示注音。這個組織邏輯是，
            // 退後鍵只針對不完整的注音去顯示完整的注音的話，它就不要一起變成注音你知道嗎」
            // ⇒ **只有沒收尾的那一格顯示注音，已收尾的字不要跟著變。**
            //
            // 原規則是「整段退回注音」，理由是「沒有可靠的方法把 gram 的 value 按 key 切開」。
            // 那個理由只在「這個詞是語意整體」時成立；而這種 gram 是**引擎在有未收尾 key 存在時
            // 臨時併出來的**，本來就不該當整體。當 `value.count == keys.count`（每個 key 剛好一個字，
            // 也是引擎自己 `heuristicKeyAlignedValues` 用的判準）時，逐 key 對位是精確的。
            let characters = Array(segment.value)
            let canAlignPerKey = characters.count == segment.keys.count
                && segment.sealedFlags.count == segment.keys.count
            for (offset, key) in segment.keys.enumerated() {
                // 對得上字的音節，切出去之後就顯示漢字（含沒按聲調、自動當一聲的）。
                // 對不上才留注音，避免把一個詞猜着切進錯的字。
                let text = canAlignPerKey ? String(characters[offset]) : key
                pieces.append(
                    Piece(
                        text: text,
                        keyIndexBefore: range.lowerBound + offset,
                        keyIndexAfter: range.lowerBound + offset + 1,
                        oneCharPerKey: false))
            }
        }

        // 引擎還沒吃到這一鍵（`input` 失敗、或暖機期間排隊中）時，至少要讓使用者
        // 看得到自己按了什麼——否則畫面會像當機。
        if !pendingBuffer.isEmpty, !pendingRendered {
            pieces.append(
                Piece(text: pendingBuffer, keyIndexBefore: keyCursor, keyIndexAfter: keyCursor + 1))
        }
        return pieces
    }
}
