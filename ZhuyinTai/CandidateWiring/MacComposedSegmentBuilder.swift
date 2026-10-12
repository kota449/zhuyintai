// SPDX-License-Identifier: Apache-2.0
// 把引擎的組字結果打包成顯示層要的 `MacComposedSegment`。
//
// **只碰引擎、不碰 AppKit** ⇒ 可以用純 swiftc 接真引擎測（`tools/test_mac_display_engine.sh`）。
// 這是從 `MacClientSession` 抽出來的：原本它是 session 裡一個 private 函式，
// 於是「真引擎會吐出什麼樣的 segments」這一段**從來沒被測過**——而稽核 #4 就是在這裡
// 找到兩個使用者一定看得到的閃爍。
//
// ## 🔴 為什麼「正在拼」時不能直接用引擎現有的 `assembledSentence`（稽核 #4-1，已實測）
//
// 引擎把**半個音節也放進 keys 裡一起解碼**（iOS 餵食模型），於是兩個現象：
//
// (a) 含 pending 的詞被逐 key 展開，已收尾的字退回注音：
//     引擎把 `[ㄋㄧˇ, ㄏㄠ(pending)]` 併成同一個 2-key 詞「你好」，該 gram 含 pending ⇒
//     整段逐 key 展開、非 pending 的 key 用原文 ⇒ 畫面「你ㄏ」→ **「ㄋㄧˇㄏㄠ」** → 「你好」，
//     每打詞的第二個音節就閃一下。「現在」同：「現ㄗ」→ **「ㄒㄧㄢˋㄗㄞ」** → 「現在」。
// (b) 已收尾的字被下一個半音節重新解碼：
//     打「你好世界」時「你好是ㄐ」→ **「你好ㄕˋㄐㄧ」**（已收尾的「是」變成注音）→「你好世界」。
//
// ## 解法（稽核員提出、我用真引擎重現並量過成本）
//
// **在 compositor 的複本上先移除 pending 那個 key，再解碼**——複本的 `assembledSentence`
// 裡沒有任何 gram 跨越 sealed／pending 的邊界，已收尾的字也不會受半音節影響；
// 再把 pending 當成獨立的一格插回它原本的位置。
//
// 實測（`probe_copy_assemble`，真引擎，「你好世界」「現在」）：
// - 三個原本會閃的情境全部正確：`你ㄏㄠ`、`你好是ㄐㄧ`、`現ㄗㄞ`
// - 成本：額外平均 30～381µs、最大約 1.0ms（相對 G9 首份實測 p50 4.5ms 可忽略）
//
// 🔴 **跨界詞（15a/15b，2026-09-22 修）**：上一段講的「已知限度」原本以為只是「顯示短暫
// 錯位一格」，真引擎複現後發現其實是**內容錯亂**，不是單純位移。根因在下面迴圈：pending
// 被移除後，前後兩個各自已收尾的 key 會被引擎重新併回同一個多 key 詞（例如「你好」），
// 這個詞的 span 在複本的 key 編號裡是連續的兩格；但 `pendingIndex` 是用**原始**（含 pending）
// 的編號算的，數值上剛好落在這個 span 「內部」，卻從來不等於任何 gram 的**起點**
// （迴圈的插入判斷只比對 `copyKeyIndex == pendingIndex`，只認得到 gram 邊界）。於是 pending
// 插入判斷全部落空、被丟到迴圈結束後 append 在最後面——但下游 `MacMarkedTextState.renderPieces`
// 是照 segment 出現順序、用「這一段的 key 範圍」重新算連續全域索引，並不知道這裡漏插了一格。
// 結果它會把 span 剛好蓋住 `pendingIndex` 的那個**完全無關、已收尾**的詞誤判成「含 pending
// 的那一段」，逐 key 展開＋用 pending 內容蓋掉其中一個 key ——這正是「你」被打回注音
// `ㄋㄧˇ`、「好」被蓋成 `ㄒ`、真正的 pending 段又在最後面重複印一次 `ㄒ` 的原因。
//
// 修法：偵測 `pendingIndex` 落在某個多 key 詞**內部**（嚴格介於起訖之間，不是邊界）時，
// 不要把整個 gram 當一個 segment，改成逐 key 拆開（`gram.value` 字數與 key 數對得上時，
// 每個 key 對一個字；對不上就照舊規則保守地整段退回注音——見 `MacMarkedTextState` 同一個
// 「寧可多顯示注音也不亂猜對位」原則），這樣 pending 才能插在正確的兩個 key 之間，
// 下游的連續索引也才會對得上真正的引擎游標。
//
// 另：`ˉ`（一聲）收尾在引擎裡 416/416 被拒絕（稽核 #4 實測），所以「引擎 key 沒有 ˉ」是常態，
// 不能假設查得到它。sealed 判準靠 `ZhuyinEngine.isSealed`（預設 true，只有精準命中
// unsealed 記錄才是 false），與是否有聲調符號無關。
//
// 🔴 **sealed 值未釘進圖（2026-09-22 修，mac-session-tests I3/I4 結構完整性 fuzz 抓到，
// 最小複現 4 鍵 `ㄍ␣ㄣㄋ`）**：`isSealed` 從頭到尾只是查表用的旗標，從不影響
// `PathFinder` 怎麼選路徑。使用者打完「ㄍ」按空白收尾成「高」之後，只要接著打出
// 一個會觸發 `.startNew` 自動 flush 的 unsealed 音節（例如 `ㄣㄋ`），PathFinder
// 完全可能把已收尾的「ㄍ」跟後面這些 unsealed key 併成同一個多 key gram——組出來的
// 字數一旦跟 key 數對不上，`MacMarkedTextState` 那條「無法對位時保守地整段退回注音」
// 的規則（本檔上面已經在用）就會把**已收尾**的那一截也一起打回注音，「高」整個
// 變回「ㄍ」。範圍比 15a/15b 的跨界詞（兩個都是 sealed，PathFinder 併對了、只是顯示層
// 插入點算錯）大得多：這裡是 PathFinder 選錯，不是顯示層算錯。
//
// **第一版修法（已廢棄，見下）**：試過在複本上把每個已收尾 key 的單 key 節點呼叫
// `selectOverrideUnigram` 釘死成它自己的當下值。編得過、`ㄍ␣ㄣㄋ` 也真的修好了，但
// 跑全套劇本時炸出新回歸——劇本 07（`你好ㄉㄨ世界`）裡「世」被單獨釘死成它自己
// context-free 的 top candidate「是」，蓋掉了「世」跟後面已收尾的「界」原本該合出來
// 的正確結果「世界」。根因：逐一釘死每個 sealed key 會**同時**擋掉「不該發生的
// sealed／unsealed 跨界合併」（要擋）跟「該發生的 sealed／sealed 多字詞合併」
// （不該擋，15a/15b 跟劇本07 的「世界」都是這種）——`selectOverrideUnigram` 只能
// 二選一地把某個位置焊死成單 key，沒辦法「只擋跨界那種合併」。
//
// **這一版修法**：把「移除 pending」（稽核 #4-1 的舊解法）跟「移除 sealed 值未釘進圖」
// 這兩個病灶用同一套機制解決，而不是另外疊一層 override——**複本上把所有『使用者還沒
// 親手收尾』的 key 整批挖掉**（正在拼的 pending、以及每一個 `isSealed==false` 的
// auto-flushed unsealed key），剩下的複本裡每一個 key 都保證是 sealed，PathFinder
// 才有辦法在它們之間自由組出正確的多字詞（「世界」「你好」……都不受影響，因為它們
// 全部留在複本裡、彼此之間完全沒有被硬性拆開）；被挖掉的那些位置事後照原本在陣列裡
// 的位置插回去。原本「pending 落在合併詞內部就逐 key 拆開」的邏輯完整保留，只是從
// 「只認 pending 一種 gap」推廣成「認所有 gap」（pending＋unsealed 皆可觸發）。
//
// 🔴 **b0a6cc5a（2026-09-22）拿掉了上面這段「整批挖洞」，只留 pending 一種 gap**——
// 理由是要讓沒收尾但已切出去的音節（`.startNew` 自動 flush 的）顯示漢字，不再黏著注音
// 留在畫面上（小麥注音／微軟新注音的行為：沒按聲調就開下一字，前一個音節自動當一聲）。
// 副作用：sealed 值未釘進圖的舊病灶跟著復發（09n，PR #214 review 抓到）——最小複現
// `ㄍ␣ㄣㄋ`：複本 `[ㄍ,ㄣ]` 解出來是兩個各自獨立的 1-key gram（不是併成一個詞），但
// 光是 ㄣ 還在複本裡，`ㄍ` 這個位置選到的候選字就從獨立解碼時的「高」換成了字面 `ㄍ`。
//
// **這一版修法（2026-09-24）**：sealed 那一側恢復「整批挖洞」（上面那段，不再因為
// b0a6cc5a 而退化成只挖 pending），已收尾的字重新拿回跟未收尾鄰居完全隔離的解碼環境；
// 沒收尾但已切出去的 key（非 pending 的 gap）另外用**只挖 pending 的複本**（`perKeyCharacters`，
// 等同 b0a6cc5a 讓它顯示漢字時的那份上下文，也正是 03／04／04b／05a／07 這幾條劇本已經
// 釘住的確切字）逐 key 取值，插回對應位置；查不到（gram 字數跟 key 數對不上）就照舊
// fallback 成 key 原文。兩份複本各司其職、互不影響：sealed 的值只信任 sealed-only 那份，
// unsealed 的字只信任 pending-only 那份，PathFinder 選路徑時的上下文污染不會互相傳染。
//
// 🔴 **成本（/code-review 抓到：這一版多了第二份複本+解碼，沒量過）**：只在畫面上真的有
// 「非 pending 的未收尾 key」時才會多跑（`gapOriginalIndices.contains(where: { $0 != pendingIndex })`
// 短路，settled／只有 pending 沒有 unsealed 的一般情況完全不受影響）。實測（暫時計時，跑一次
// `tools/test_mac_session_scripts.sh` 全套劇本，21 次命中這個分支）：額外平均 0.41ms、
// 最大約 1.52ms——跟本檔第一版修法量到的單份複本成本（平均 30～381µs、最大約 1.0ms）同量級，
// 相對 60fps 的 16ms UI 更新預算仍有餘裕；樣本數小
// （21 次），量法沿用同一套「暫時印時間差」手法，不是常駐的效能埋點。

import Foundation

enum MacComposedSegmentBuilder {
    /// - Parameter pendingBuffer: `LegalKeySyllableComposer.currentBuffer`。空字串＝`settled`，
    ///   直接用引擎現有的 `assembledSentence`（沒有半音節，不會有上面兩個問題）。
    static func segments(engine: any MacZhuyinEnginePort, pendingBuffer: String) -> [MacComposedSegment] {
        guard let real = engine.composerView else { return [] }

        // 正在拼的 key ＝ `keys[cursor-1]`（游標相對，同 G4 的 Bug A）。
        let pendingIndex = pendingBuffer.isEmpty ? -1 : real.cursor - 1
        let originalKeys = real.keys

        // 所有「使用者還沒親手收尾」的原始位置：正在拼的 pending（若有），加上每一個
        // `isSealed==false` 的 auto-flushed unsealed key（`.startNew` flush 進 compositor.keys、
        // 從沒被使用者按聲調鍵確認過的那些）。這些位置全部要從複本挖掉再解碼——不只是為了
        // 避免它們跟已收尾的 key 併成同一個詞，`isSealed` 從不影響 PathFinder 選路徑，
        // 光是留在複本裡（哪怕最後各自落單、沒被併進同一個 gram）就可能改變已收尾 key
        // 本身選到的候選字（09n 實測：複本 `[ㄍ,ㄣ]` 解出兩個各自獨立的 1-key gram
        // `(["ㄍ"],"ㄍ")`、`(["ㄣ"],"恩")`——不是併成一個詞，但「ㄍ」單獨在場時解得出
        // 「高」，一旦 ㄣ 也在複本裡，「ㄍ」這個位置就換成了字面 `ㄍ`）。
        var gapOriginalIndices: [Int] = []
        for (index, key) in originalKeys.enumerated() {
            if index == pendingIndex {
                gapOriginalIndices.append(index)
                continue
            }
            // `isSealed` 的 keyCount 是 1-based 位置。
            if !engine.isSealed(key: key, atKeyCount: index + 1) {
                gapOriginalIndices.append(index)
            }
        }
        let gapIndexSet = Set(gapOriginalIndices)

        // 沒收尾但已切出去的 key（不含 pending）仍要以漢字現身（b0a6cc5a 的目的：小麥注音／
        // 微軟新注音都是沒按聲調就開下一字、前一個音節自動當一聲）——但不能用上面那份
        // 「跟已收尾完全隔離」的複本取值，那份複本存在的目的就是不讓它們互相污染已收尾的字。
        // 改用「只挖掉 pending」的複本（等同這個回歸之前、b0a6cc5a 當下的產品行為）取值：
        // 那份複本才有原本的上下文，也正是 03／04／04b／05a／07 這幾條劇本已經釘住的確切
        // 結果——這裡只是把它解出來的字借出來給對應的 key 用，完全不影響上面 sealed 那一側
        // 的隔離（sealed 的值一律只信任 sealed-only 的複本）。
        var unsealedCharacters: [Int: String] = [:]
        if gapOriginalIndices.contains(where: { $0 != pendingIndex }) {
            let pendingOnlyGaps: Set<Int> = pendingIndex >= 0 ? [pendingIndex] : []
            let pendingOnlyOwner = MacComposedSegmentBuilder.compositorCopy(
                from: real, dropping: pendingOnlyGaps)
            unsealedCharacters = MacComposedSegmentBuilder.perKeyCharacters(
                sentence: pendingOnlyOwner.assembledGrams, originalKeys: originalKeys,
                excluding: pendingOnlyGaps)
        }

        let sentenceOwner = MacComposedSegmentBuilder.compositorCopy(
            from: real, dropping: gapIndexSet)

        // 複本索引 → 原索引：把 gap 從原始位置陣列裡濾掉，剩下的依序對回複本裡的 key。
        let copyToOriginal: [Int] = originalKeys.indices.filter { !gapIndexSet.contains($0) }
        let sortedGaps = gapOriginalIndices.sorted()

        var segments: [MacComposedSegment] = []
        var nextGapPointer = 0

        func insertGap(at original: Int) {
            if original == pendingIndex {
                segments.append(
                    MacComposedSegment(keys: [pendingBuffer], value: pendingBuffer, sealedFlags: [false]))
            } else {
                let key = originalKeys[original]
                let value = unsealedCharacters[original] ?? key
                segments.append(MacComposedSegment(keys: [key], value: value, sealedFlags: [false]))
            }
        }

        /// 把原始索引 `<= boundary` 的 gap 依序插入（維持它們在畫面上原本的先後順序）。
        func flushGaps(upTo boundary: Int) {
            while nextGapPointer < sortedGaps.count, sortedGaps[nextGapPointer] <= boundary {
                insertGap(at: sortedGaps[nextGapPointer])
                nextGapPointer += 1
            }
        }

        var copyKeyIndex = 0 // 複本裡已走過幾個 key
        for gram in sentenceOwner.assembledGrams {
            let keys = gram.keyArray
            let copyRange = copyKeyIndex ..< (copyKeyIndex + keys.count)
            defer { copyKeyIndex = copyRange.upperBound }
            guard !copyRange.isEmpty else { continue }

            let originalStart = copyToOriginal[copyRange.lowerBound]
            let originalEnd = copyToOriginal[copyRange.upperBound - 1]
            flushGaps(upTo: originalStart - 1)

            // 這個 gram 涵蓋的 key 在原始座標系裡是不是連續的（沒有 gap 卡在中間）？
            // 複本裡的 key 全部保證 sealed，唯一會不連續的原因是有 gap 插在中間
            // （跨界詞：這個 gram 合併前，中間曾經卡著一個 pending／unsealed key）。
            if originalEnd - originalStart + 1 == keys.count {
                segments.append(
                    MacComposedSegment(
                        keys: keys, value: gram.value, sealedFlags: Array(repeating: true, count: keys.count)))
                continue
            }

            // 跨界詞：逐 key 拆開才塞得進正確位置（字數與 key 數對得上時每個 key 對一個字；
            // 對不上就照 `MacMarkedTextState` 同一個「寧可多顯示注音也不亂猜對位」原則，
            // 這裡先用 key 原文頂著，交給下游用同一套規則統一處理）。
            let characters = Array(gram.value)
            let canSplitPerKey = characters.count == keys.count
            for (offset, key) in keys.enumerated() {
                let original = copyToOriginal[copyRange.lowerBound + offset]
                flushGaps(upTo: original - 1)
                let value = canSplitPerKey ? String(characters[offset]) : key
                segments.append(MacComposedSegment(keys: [key], value: value, sealedFlags: [true]))
            }
        }
        flushGaps(upTo: originalKeys.count - 1)

        // 引擎還沒組出句子（暖機中、或 key 全被拒）——至少讓每個 key 以注音現身，
        // 畫面上一片空白會像當機。（沿用原 `composedSegments()` 的 fallback。）
        if segments.isEmpty {
            return engine.compositorKeys.enumerated().map { index, key in
                MacComposedSegment(
                    keys: [key], value: key,
                    sealedFlags: [engine.isSealed(key: key, atKeyCount: index + 1)])
            }
        }
        return segments.map(Self.readingCompatibleSegment)
    }

    /// 複製一份 `real`，挖掉 `gaps` 指定的原始索引（1-based cursor、`dropRearKey()`）。
    /// 由大到小依序砍：砍掉較大索引的 key 不會影響還沒處理的較小索引，才能直接用原始
    /// 索引當 cursor 位置，不必另外做位移換算。`gaps` 空 ⇒ 不複製，直接借用 `real`。
    private static func compositorCopy(from real: any MacComposerView, dropping gaps: Set<Int>) -> any MacComposerView {
        guard !gaps.isEmpty else { return real }
        let copy = real.copy()
        for gap in gaps.sorted(by: >) {
            copy.cursor = gap + 1
            _ = copy.dropRearKey()
        }
        return copy
    }

    /// 把某個 compositor 解出來的句子，逐 key 對回「原始 key 索引 → 對應字」。
    /// `excluding`：這份句子的複本本身挖掉了哪些原始索引（用來把複本索引換算回原始索引，
    /// 同 `segments()` 主迴圈的 `copyToOriginal`）。只在 gram 的字數跟 key 數對得上時才收，
    /// 對不上的 key 保守地不收——呼叫端 fallback 用原文，跟其他地方同一條
    /// 「寧可多顯示注音也不亂猜對位」原則。
    private static func perKeyCharacters(
        sentence: [MacComposedGram], originalKeys: [String], excluding gapIndices: Set<Int>
    ) -> [Int: String] {
        let copyToOriginal = originalKeys.indices.filter { !gapIndices.contains($0) }
        var result: [Int: String] = [:]
        var copyKeyIndex = 0
        for gram in sentence {
            let keys = gram.keyArray
            defer { copyKeyIndex += keys.count }
            guard !keys.isEmpty else { continue }
            let characters = Array(gram.value)
            guard characters.count == keys.count else { continue }
            for offset in keys.indices {
                result[copyToOriginal[copyKeyIndex + offset]] = String(characters[offset])
            }
        }
        return result
    }

    /// 單聲母（組不成音節）若被組成一個讀音對不上的字，畫面留注音。
    ///
    /// 聲調被拒會清掉組音緩衝，顯示層於是露出引擎替這個 key 組的字。
    /// 裸 `ㄈ` 組成「方」（讀音 ㄈㄤ，以 ㄈ 開頭）要留著（劇本 22a）。
    /// 裸 `ㄒ` 組成「日」（讀音 ㄖˋ）要留注音（清帳 #15）。
    /// 完整音節不進這裡：`ㄟ` 按空白仍顯示「喔」（劇本 22b）。
    /// 查不到讀音時不改，避免表沒載入時把合法的字打回注音。不掃詞庫。
    private static func readingCompatibleSurface(key: String, composed: String) -> String {
        guard composed != key, composed.count == 1,
              let initial = key.first, let character = composed.first
        else { return composed }
        guard MacInitialReadingMask.allows(initial: initial, character: character) == false else {
            return composed
        }
        return key
    }

    private static let syllableTable = SyllableTable()

    /// 只有「單個聲母、組不成音節」才檢查。完整音節（含 `ㄟ` 空白收成「喔」）與多鍵的詞不動。
    private static func readingCompatibleSegment(_ segment: MacComposedSegment) -> MacComposedSegment {
        guard segment.keys.count == 1, let key = segment.keys.first,
              key.count == 1, !syllableTable.isValidSyllable(key)
        else { return segment }
        let surface = readingCompatibleSurface(key: key, composed: segment.value)
        guard surface != segment.value else { return segment }
        return MacComposedSegment(keys: segment.keys, value: surface, sealedFlags: segment.sealedFlags)
    }
}
