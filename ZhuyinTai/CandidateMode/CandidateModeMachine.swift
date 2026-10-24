// SPDX-License-Identifier: Apache-2.0
// Mac 輸入法的純邏輯狀態機：`(State, KeyEvent, EngineFacts) -> (State, [Effect])`。
//
// 🔴 **不得 import AppKit／InputMethodKit／ZhuyinEngine**（理由見 `CandidateModeTypes.swift` 檔頭）。
// 規格（兩張轉換表 §4.3／§4.4、六條不變式 §4.1）由本檔實作；測試是 `MacCandidateModeCLIProbe/main.swift`
// （`tools/test_mac_candidate_mode.sh`）。
//
// 🔴 G5（標點）接線（2026-09-22）：`.punctuation` 分支呼叫
// `MacInputTables.lookup`（`ZhuyinTai/InputTables/`，同一個 module、零 AppKit，
// `tools/test_mac_candidate_mode.sh` 已把它加進編譯來源）。查表查得到才動作，查不到
// （未確認／表外）一律維持原本的放行——這是把查表純函式接上按鍵處理路徑的接線本體。
//
// 🔴 **引擎餵食模型＝iOS 模型，不是原 spike 模型。**
// 原 spike（143 行那版）只有聲調鍵／空白鍵才 `engine.input`，注音鍵只動緩衝區。
// iOS（`keyboard/` 的按鍵閘門）則是**每一個注音鍵都餵引擎**
// （`input`／`replaceLastKey`），於是有一條不變式：**「composer 正在拼的內容，
// 同時存在於引擎 `keys` 的游標前那一格」**。
// `Shared/LegalKeyBackspacePlan` 的五個決策、它的 14 個 iOS 測試、A9 與 Bug A 的全部推導
// 都綁在那條不變式上 —— 而 spec §6 明文要求「決策本體零改動、照抄執行端」。
// ⇒ 本檔採 iOS 模型。代價：
// 這改變了打字路徑的行為，而打字路徑**本輪無法實機驗證**。

import Foundation

public struct MacCandidateModeMachine {
    // MARK: - 狀態

    public private(set) var state: MacCandidateModeState = .idle

    /// G6 正交狀態。本輪沒有切換入口，永遠是 `.zh`；位置先留好（spec §7）。
    public var language: MacInputLanguage = .zh

    private var composer = LegalKeySyllableComposer()
    private let firstToneMark: Character
    /// 被嗶掉的鍵／相鄰韻母的處置策略。公開版＝不救援；官方版由 `MacKeyRescueFactory` 注入（見 `MacKeyRescuePolicy`）。
    private let keyRescue: any MacKeyRescuePolicy

    /// `.reopenTail` 送出後、引擎回報前的待決資訊（見 `MacIMEEffect.engineReopenTail`）。
    private var pendingReopen: (reduced: String, fallbackPrevious: String?)?

    /// - Parameter firstToneMark: 一聲符號。正本在引擎側的組音緩衝，
    ///   由轉接層注入——直接 import 會把整個引擎側
    ///   拖進這一層的純 swiftc 測試。注入之後出貨路徑用的仍是正本那個字元，不可能漂移。
    public init(firstToneMark: Character = "ˉ") {
        self.init(firstToneMark: firstToneMark, keyRescue: MacKeyRescueFactory.make())
    }

    /// - Parameter keyRescue: 鄰鍵救援策略。測試要明確指定不救援時傳 `MacNoKeyRescue()`。
    public init(firstToneMark: Character, keyRescue: any MacKeyRescuePolicy) {
        self.firstToneMark = firstToneMark
        self.keyRescue = keyRescue
    }

    /// 正在拼、尚未收尾的注音符號。空字串 ⇒ `Typing/settled`。
    public var composerBuffer: String { composer.currentBuffer }

    /// spec §4.1 的子相：緩衝區非空 ⇒ `partial`。
    public var isPartial: Bool { !composer.currentBuffer.isEmpty }

    // MARK: - 入口

    public mutating func handle(_ event: MacKeyEvent, facts: MacEngineFacts) -> [MacIMEEffect] {
        // 不變式（spec §4.1 正交狀態）：`en` 時一律放行，窗不可能開著。
        guard language == .zh else { return [.passThroughToClient] }

        switch state {
        case .idle: return handleIdle(event, facts: facts)
        case .typing: return handleTyping(event, facts: facts)
        case .selecting: return handleSelecting(event, facts: facts)
        }
    }

    /// `.reopenTail` 的引擎回饋入口。轉接層執行完 `engineReopenTail` 後**必須**呼叫，
    /// 否則緩衝區會停在「還沒定案」的空字串。
    public mutating func resolveReopenTail(succeeded: Bool) {
        guard let pending = pendingReopen else { return }
        pendingReopen = nil
        if succeeded {
            composer.reopen(pending.reduced)
        } else if let previous = pending.fallbackPrevious, !previous.isEmpty {
            // 引擎接不住縮短後的內容 ⇒ 那個音節整個消失（等同 `.dropTail`），
            // 於是後面那個未收尾的音節裸露出來 ⇒ 套用同一條 A9 規則。
            composer.reopen(previous)
        } else {
            composer.reset()
        }
    }

    /// `.confirmComposedTextOnEnter` 的轉接層回饋（選項 C，2026-09-26）。
    ///
    /// `committed == false`：轉接層發現畫面≠即將送出的內容，只更新了畫面、沒有送出，
    /// 把 `.enter` 樂觀轉的 `.idle` 退回 `.typing`——composer 已經在 `.enter` 那一刻
    /// 清空（sealing 已套用），所以退回的是合法的 settled 狀態。`committed == true`
    /// 什麼都不用做（已經在 `.idle`，跟樂觀轉的結果一致）。
    public mutating func resolveEnterCommit(committed: Bool) {
        guard !committed else { return }
        state = .typing
    }

    /// `.confirmCandidateAtSelectionKey` 的回饋入口。
    ///
    /// 本頁有沒有那一格只有窗知道（`candidateIndexAtKeyLabelIndex(_:)` 超出本頁回 `nil`），
    /// 而 spec §4.4 規定那種情形是「吃掉＋嗶」——**窗不能關**。所以轉接層解析失敗時要
    /// 呼叫這個把狀態退回 `.selecting`，並中止後面的 `closeCandidateWindow`／`updateMarkedText`。
    public mutating func resolveSelectionKeyConfirmation(succeeded: Bool) {
        guard !succeeded else { return }
        state = .selecting
    }

    /// 離開 `Selecting` 回到 `Typing/settled`。
    ///
    /// 給「不是從按鍵進來」的離開路徑用——目前只有滑鼠點候選（窗自己走
    /// `candidatePairSelectionConfirmed(at:)`，不經過 `handle`）。
    public mutating func leaveSelecting() {
        guard state == .selecting else { return }
        state = .typing
    }

    // MARK: - Idle

    private mutating func handleIdle(
        _ event: MacKeyEvent, facts: MacEngineFacts
    ) -> [MacIMEEffect] {
        switch event {
        case .zhuyinSymbol(let symbol):
            guard composer.decision(for: symbol) != .reject else { return [.beep] }
            let (_, newBuffer, _) = composer.press(symbol)
            state = .typing
            // 空緩衝起手＝iOS 的 `start-empty` 分支：直接 input，沒有前一個音節要標記。
            return [.engineInput(newBuffer), .updateMarkedText]

        // G5：`Idle` 沒有組字可上屏，查得到就直接插入；查不到（未確認／不在表裡）維持放行。
        case .punctuation(let symbol):
            guard let text = punctuationOutput(for: symbol) else { return [.passThroughToClient] }
            return [.insertText(text)]

        // 🔴 2026-09-24 產品決策改規格：「打輸入法打 3 是打聲調符號出來不是數字，
        // 這樣比較合理吧」——`Idle` 按聲調鍵原本跟其他鍵一起放行（見下面那組 case），
        // 後果是聲調鍵的原始實體鍵字元（3/4/6/7）直接變成宿主文件裡的數字。
        //
        // 為什麼不做成「進組字區」（McBopomofo 預設設定下的參考行為——`allowChangingPriorTone`／
        // `keepReadingUponCompositionError` 兩個偏好都預設 `false` 時，idle 與 settled 按裸
        // 聲調鍵都會把它放進 reading buffer 當 marked text 顯示，`KeyHandler.mm:594`
        // `buildInputtingState`；對照上游 McBopomofo 原始碼，confirmed by
        // source reading，非 corroborated by test——McBopomofo 自己的測試裡也沒有這個確切邊角
        // 案例）：那個模型要求 `composer.currentBuffer` 能放進裸聲調符號，而
        // `Megrez.Compositor.insertKey` 的 `langModel.hasUnigramsFor` 守衛對一個沒有聲母／
        // 韻母的裸聲調字串必然找不到 unigram、`.engineInput` 會失敗，`engine.keys` 因此不變——
        // 這會讓 `底線非空 ⇔ engine.keys 非空` 這條不變式恆假
        // （`MacClientSessionCLIProbe/TypingRig.checkInvariants` 的 I1，既有測試 harness
        // 真的會擋下來，不是臆測）。改用跟 G5 標點同一條路：`Idle` 直接插入，不進組字、
        // 不動 composer、不動引擎，狀態留在 `Idle`。
        //
        // `Typing/settled`（已另行調整過的那格）刻意**不**套用同一招：那格的 buffer 空但
        // `engine.keys` 非空（前面還有沒 commit 的句子），要插入符號勢必得先
        // `.commitComposedText` 才能維持不變式——等於「意外多按一次聲調鍵」會強制把整句送出，
        // 比嗶一聲的副作用大得多，也會弄壞既有情境測試最後一條斷言（吃掉之後
        // 後續音節仍正常組字）。維持 `.beep`（見 `handleTyping` 的 `.tone` 分支）。
        case .tone(let tone):
            return [.insertText(String(tone))]

        // 沒有組字就沒有東西可吃：`Idle` 整欄放行（spec §4.3），這是「不要讓使用者
        // 切到這個輸入法之後連 Enter／方向鍵都不能用」的那條線。
        case .space, .shiftSpace, .enter, .escape, .backspace, .deleteForward,
             .moveLeft, .moveRight, .moveUp, .moveDown, .pageUp, .pageDown,
             .modifierCombo, .otherCharacter, .selectionKey:
            return [.passThroughToClient]

        // 🔴 R8：`Idle` 也**不能**放行 Option 組合——放行的話宿主用 ABC 排列翻譯，
        // Option+1 會打出 `¡`。中文輸入法裡它的語意是一次性 ASCII 逃逸（G5 實作）。
        case .optionCombo:
            return []

        case .clientCursorMoved, .deactivate:
            return []
        }
    }

    // MARK: - Typing

    private mutating func handleTyping(
        _ event: MacKeyEvent, facts: MacEngineFacts
    ) -> [MacIMEEffect] {
        switch event {
        case .zhuyinSymbol(let symbol):
            return pressZhuyin(symbol, facts: facts)

        case .tone(let tone):
            // 空緩衝按聲調不成音節 ⇒ 吃掉＋嗶（不放行）。
            //
            // 🔴 2026-09-24 修正：這裡原本回 `.passThroughToClient`，把「不成音節」誤翻成
            // 「放行給宿主」。兩者不同——這一格只在 `handleTyping`（`state == .typing`，
            // 亦即畫面上還有 marked text）才會被呼叫到，不是真正的 `Idle`。放行的後果是
            // `MacClientSession.dispatch` 判定 `consumed=false`，IMK 因此把聲調鍵的**原始
            // 實體鍵字元**（3/4/6/7）直接交給宿主，在組字途中的文件裡憑空冒出一個數字
            // （實機 log seq=85→86／1664→1665：兩個音節各自收尾後緊接著再按一次聲調鍵）——
            // 症狀是「打聲調會變數字」。這也是「字被吃掉」其中一種成因：seq=1665 漏出的
            // 數字之後，使用者按 ⌫ 想刪掉它，但 IME 仍在 settled，⌫ 吃掉的是僅有的那個音節，
            // 誤冒出的數字反而留在文件裡。
            // 對齊本檔既有的「reject 只嗶，不動引擎也不動緩衝」模式（`pressZhuyin` 的
            // `.reject` 分支）與 iOS 對照路徑（`keyboard/` 的按鍵閘門
            // 對同樣情形回 `tone-ignored-empty-buffer`，一個 no-op，從不放行）。
            // 少了這個守衛，裸聲調會被當音節餵進引擎（2026-09-03 實機證據：
            // `key='˙' bufferBefore='' → 所以這樣是˙`）——這部分沒有變。
            guard !LegalKeySyllableComposer.shouldIgnoreTonePress(currentBuffer: composer.currentBuffer)
            else { return [.beep] }
            // 不完整音節（只有聲母的 `ㄈ`、`ㄏ`）加聲調不是合法讀音：嗶，收掉組音緩衝
            // （回到 settled，方向鍵才走得動），但不把聲調併進 engine key。
            // `pressTone` 會把緩衝收成 `ㄈˇ` 再 `replaceLastKey`；`ㄈˇ` 換得進去，
            // 畫面與 Enter 就送出 `ˇ`（2026-09-28 seq=3111，ok=1）。
            // 聲母 key 留著：09m 的 `ㄏ`＋誤按 `ˊ` 要靠它留在原位，游標才移得到
            // （`ScenariosEditing.swift` 09m）。砍掉 key 或留在 partial，那條都會紅。
            guard composer.isCompleteSyllable else {
                composer.reset()
                return [.beep, .updateMarkedText]
            }
            let previous = composer.currentBuffer
            let committed = composer.pressTone(tone)
            return [.engineReplaceLastKey(from: previous, to: committed), .updateMarkedText]

        case .space:
            // 「空白＝一聲」是硬約束。
            // settled（緩衝空、組字區非空）：2026-10-01 產品決策「跟威注音一樣」——
            // 威注音預設 `SpaceKeyBehaviorAgainstICB=1`（`callCandidateState`）＝開選字窗，
            // 跟 ↓ 同一條路。原本放行會讓宿主在 marked text 還在畫面上
            // 時插入空白，落在組字區前面。
            guard isPartial else {
                guard facts.candidateCount > 0 else { return [.beep] }
                state = .selecting
                return [.openCandidateWindow]
            }
            return applyImplicitFirstTone() + [.updateMarkedText]

        case .enter:
            // partial 時先補一聲，否則畫面上看得到的東西會在 commit 時憑空消失。
            // 例外（2026-10-04 產品決策「沒拼完的注音」三選一）：緩衝是殘段（組不成合法音節，
            // 例：裸聲母 ㄒ）且政策不是「補一聲」⇒ 不補。留著／丟掉由轉接層在 `confirmComposedTextOnEnter` 處理。
            let leavesFragment = facts.unfinishedPolicy != .seal
                && MacUnfinishedZhuyin.isFragment(composer.currentBuffer)
            let sealing = (isPartial && !leavesFragment) ? applyImplicitFirstTone() : []
            composer.reset()
            // 樂觀轉 idle：多數情況畫面＝即將送出的內容，轉接層會直接送出。選項 C
            // （G1，2026-09-26 產品決策）發現兩者不同時，轉接層只更新畫面、不送出，
            // 並呼叫 `resolveEnterCommit(committed: false)` 把這裡樂觀轉的 idle 退回
            // `.typing`——sealing 已經套用、composer 已清空，退回的是合法的 settled
            // 狀態，不是半吊子，下一鍵無論是再按 Enter、繼續打字還是刪字都走原本的
            // `.typing` 正常路徑，不需要另外的「待確認」狀態。
            state = .idle
            return sealing + [.confirmComposedTextOnEnter]

        case .escape:
            composer.reset()
            state = .idle
            return [.engineClear, .updateMarkedText]

        // 2026-09-23 使用者：⌫ 整字刪掉，fn+⌫（系統送 ⌦）才退回注音。
        // 還在拼的注音不是「字」，⌫ 照舊一次刪一個符號（走 G4 那套）。
        case .backspace:
            return composer.currentBuffer.isEmpty
                ? dropWholeSyllable(facts: facts)
                : handleBackspace(facts: facts)

        case .deleteForward:
            return handleBackspace(facts: facts)

        case .moveLeft, .moveRight:
            // 第一版就支援 `←→`。`partial` 時不動游標（spec §4.3）。
            // R4a：**至少要嗶**——實機 log seq=41/42/43 顯示這幾格是 `fx=[]`（完全無聲），
            // 使用者的體感就是「我按了它沒反應」，跟當機分不開。
            guard !isPartial else { return [.beep] }
            let offset = (event == .moveLeft) ? -1 : 1
            return [.engineScrubCursor(by: offset), .updateMarkedText]

        case .moveDown:
            // `partial` 不開窗——不替使用者補一個他沒按的聲調。
            // 同樣補嗶聲。「要不要改成先補一聲再開窗」屬規格問題（當初訂「不補」的理由是不要偷偷加聲調）。
            guard !isPartial else { return [.beep] }
            guard facts.candidateCount > 0 else { return [.beep] }
            state = .selecting
            return [.openCandidateWindow]

        case .moveUp, .pageUp, .pageDown, .shiftSpace:
            // 不變式 5：組字期間導覽鍵一律吃掉，不讓它漏給宿主 app 在 marked text 底下亂動。
            // R4a：`partial` 時補嗶，讓「我吃掉了但不做事」跟「當機了」區分得開。
            return isPartial ? [.beep] : []

        case .modifierCombo:
            return [.passThroughToClient]

        // 🔴 R8：Option 組合**絕不放行**（理由見 `MacKeyEvent.optionCombo`）。
        // G5 接上 ASCII 逃逸之前先吃掉——吃掉只是「還沒做」，放行是「做錯」。
        case .optionCombo:
            return []

        // G5：查表查得到就「先上屏、再插入標點」——settled 直接上屏；partial 先補一聲
        // 收尾（不能讓畫面上看得到的音節憑空消失，跟 `.enter` 的 partial 分支同一套規則），
        // 再上屏、再插入。未確認的格子不准自己猜一個答案（`MacInputTables.PunctuationTable` 檔頭）。
        //
        // 2026-10-01：查不到的格子（未確認／表外）與其他字元（Shift+字母）原本放行，但**組字中不能放行**——
        // 放行時 marked text 還在畫面上，宿主把字元插在組字區前面、或直接吃掉（日用 log：
        // LINE「謝謝」+`~`、Excel「…標ㄓ」+`'`、LINE「明年嗎」+`XX`，使用者每次都回頭刪）。
        // 改成跟查得到的格子同一條路，只是插入的是**交付字元原樣**：不猜全形值，只修順序。
        case .punctuation(let symbol):
            return commitThenInsert(punctuationOutput(for: symbol) ?? String(symbol))

        // 控制字元（Tab 等）不是「要打進文件的字」，是宿主要收的鍵（表單換欄、終端補全），
        // 插成文字會弄壞它們——維持放行。
        case .otherCharacter(let character):
            let isControl = character.unicodeScalars.allSatisfy {
                CharacterSet.controlCharacters.contains($0)
            }
            guard !isControl else { return [.passThroughToClient] }
            return commitThenInsert(String(character))

        case .selectionKey:
            // `Typing` 中數字鍵是注音鍵，轉接層不會送出這個事件；防禦性放行。
            return [.passThroughToClient]

        case .clientCursorMoved:
            // G7：宿主把游標移出組字區。已組好的字上屏到原 marked range，未完成注音丟掉，
            // 然後清空。依據見 `commitBecauseClientCursorMoved()`。
            return commitBecauseClientCursorMoved()

        case .deactivate:
            // 本輪決定：**保留該 client 自己的組字**，不 commit 到別人那裡（W3）。
            // 沒有窗開著，所以沒有要關的東西。
            return []
        }
    }

    /// 注音鍵：`extend`／`startNew`／`reject` 三條，逐行對齊
    /// iOS 按鍵閘門的非聲調分支。
    private mutating func pressZhuyin(
        _ symbol: Character, facts: MacEngineFacts
    ) -> [MacIMEEffect] {
        // 🔴 不變式 4：`.reject` **不再清緩衝**（那是 G4 的病根——原 spike 在這裡
        // `buffer.reset()`，使用者打錯一個符號整段重來）。回到組音器本來的語意：
        // `press` 遇 `.reject` 本來就是 no-op。
        // 嗶之前先問救援策略（`keyRescue`），策略不救才嗶。
        guard composer.decision(for: symbol) != .reject else {
            return applyRescue(for: symbol, facts: facts) ?? [.beep]
        }

        let previous = composer.currentBuffer
        if let replacement = keyRescue.replaceAdjacentFinal(
            previous: previous, symbol: symbol, composer: composer
        ) {
            return replaceBuffer(from: previous, to: replacement)
        }
        let (_, newContent, startedNew) = composer.press(symbol)

        if startedNew {
            // A9：`previous` 從沒被 `pressTone()` 收尾過（能收尾就不會撞進 `.startNew`）。
            //
            // 🔴 位置用 **`facts.cursor`** 而不是 `keys.count`。`previous` 就是 `keys[cursor-1]`，
            // 它的 1-based 位置因此等於 `cursor`。兩者只有在「游標在尾端」時才相等——
            // 而 `←→` 讓句中補打字成為第一版就可達的狀態。
            // 用 `keys.count` 的後果：記錄位置比真實位置大，而查詢端
            //（`keyBeforeCursorAdjacent` / `isSealed`）是游標相對的 ⇒ 對不上 ⇒
            // A9 認不出「這個音節沒收尾過」，`.dropTailAndReopenPrevious` 退化成 `.dropTail`；
            // 連帶 R3 的顯示規則也靠同一份記錄 ⇒ 被 flush 的音節被誤判成已收尾而顯示成漢字。
            //（稽核 #3-2，純邏輯探針實測。iOS 的按鍵閘門同病，但它沒有 `←→`。）
            return [
                .engineMarkAutoFlushedAsUnsealed(content: previous, keyCount: facts.cursor),
                .engineInput(newContent),
                .updateMarkedText,
            ]
        }
        if previous.isEmpty {
            return [.engineInput(newContent), .updateMarkedText]
        }
        return [.engineReplaceLastKey(from: previous, to: newContent), .updateMarkedText]
    }

    // MARK: - 鄰鍵救援

    /// 組音器判定 `.reject` 時問策略要不要救。`nil` ⇒ 不救（呼叫端嗶）。
    /// 策略只回答動作；套用在這裡，所以遞迴與狀態轉移的順序跟策略實作無關。
    private mutating func applyRescue(
        for symbol: Character, facts: MacEngineFacts
    ) -> [MacIMEEffect]? {
        guard let action = keyRescue.rescueRejected(symbol, composer: composer) else { return nil }
        switch action {
        case .pressInstead(let substitute):
            return pressZhuyin(substitute, facts: facts)
        case .replaceBuffer(let replacement):
            return replaceBuffer(from: composer.currentBuffer, to: replacement)
        case .swallow:
            return []
        }
    }

    private mutating func replaceBuffer(from previous: String, to replacement: String) -> [MacIMEEffect] {
        composer.reopen(replacement)
        return [.engineReplaceLastKey(from: previous, to: replacement), .updateMarkedText]
    }

    /// 組字中插入字元：partial 先補一聲收尾，整句上屏，再插入 `text`。
    private mutating func commitThenInsert(_ text: String) -> [MacIMEEffect] {
        let sealing = isPartial ? applyImplicitFirstTone() : []
        composer.reset()
        state = .idle
        return sealing + [.commitComposedText, .insertText(text)]
    }

    /// G5：交付字元查標點表。`nil` ⇒ 不是我們能回答的格子（未確認／不在表裡／不是
    /// 我們能反推的和弦），呼叫端不得自己填一個值（組字中改插入交付字元原樣）
    /// （`MacInputTables.PunctuationTable` 檔頭：查不到就是查不到）。
    ///
    /// 到這裡時 `language` 保證是 `.zh`（`handle(_:facts:)` 頂端已 guard），所以寫死 `.zh`；
    /// `MacInputTables` 是 `ZhuyinTai/InputTables/` 底下的純值型別（零 AppKit，同一個
    /// module，不需要 import），`tools/test_mac_candidate_mode.sh` 已把它加進編譯來源。
    private func punctuationOutput(for symbol: Character) -> String? {
        guard let chord = MacInputTables.Chord(deliveredCharacter: symbol),
            case .output(let text, _) = MacInputTables.lookup(chord, language: .zh)
        else { return nil }
        return text
    }

    /// 空白鍵補一聲。
    ///
    /// ⚠️ 真正讓「西安」不被併成「先」的是 **composer 清空**（下一鍵因此開新音節），
    /// 不是聲調符號本身——所以 `pressTone` 一定要走到，引擎那邊換不換得成是次要的。
    /// 詞庫對一聲有兩種編碼，帶 `ˉ` 的換不進去就退到「只在顯示層標記已收尾」
    /// （`engineMarkImplicitFirstTone`），引擎的 key 維持無聲調。
    private mutating func applyImplicitFirstTone() -> [MacIMEEffect] {
        let previous = composer.currentBuffer
        guard !previous.isEmpty else { return [] }
        let committed = composer.pressTone(firstToneMark)
        return [.engineReplaceLastKey(from: previous, to: committed)]
    }

    // MARK: - G4 backspace（spec §6）

    private mutating func handleBackspace(facts: MacEngineFacts) -> [MacIMEEffect] {
        // 🔴 Bug A（2026-08-08）：`engineTail` 必須是游標相對的 `keys[cursor-1]`，
        // 不是 `keys.last`。`Megrez.Compositor` 的 `dropKey(.rear)`／`insertKey` 都是
        // 游標相對的，而 `←→` 已支援 ⇒ 游標偏離尾端是保證會發生的狀態。
        let engineTail = facts.cursorAdjacentKey
        let previousEngineTail = facts.keyBeforeCursorAdjacent
        let previousKeyCount = facts.keyCountOfKeyBeforeCursorAdjacent
        let previousIsSealed = previousEngineTail.map {
            facts.isSealed(key: $0, atKeyCount: previousKeyCount)
        } ?? true

        // 決策本體零改動：`Shared/LegalKeyBackspacePlan`（iOS 已有 14 個測試鎖著）。
        let plan = LegalKeyBackspacePlan.plan(
            buffer: composer.currentBuffer,
            engineTail: engineTail,
            previousEngineTail: previousEngineTail,
            previousEngineTailIsSealed: previousIsSealed
        )

        /// `.dropTail` 之後引擎還剩幾個 key —— 用來決定要不要回 `Idle`。
        func stateAfterDroppingOneKey() -> MacCandidateModeState {
            (composer.currentBuffer.isEmpty && facts.keys.count <= 1) ? .idle : .typing
        }

        switch plan {
        case .shrinkBuffer(let reduced):
            let previous = composer.currentBuffer
            _ = composer.dropLast()
            // 引擎接不住縮短後的內容時 iOS 就讓它只留在緩衝區（「等更多輸入」的
            // fallback），不需要回饋 ⇒ 這裡不用 `engineReopenTail`。
            return [.engineReplaceLastKey(from: previous, to: reduced), .updateMarkedText]

        case .reopenTail(let reduced):
            // 唯一需要引擎回饋的一格：成敗決定 composer 要 reopen 哪一個（見 `resolveReopenTail`）。
            let fallbackPrevious: String? = {
                guard let previous = previousEngineTail, !previous.isEmpty, !previousIsSealed
                else { return nil }
                return previous
            }()
            pendingReopen = (reduced: reduced, fallbackPrevious: fallbackPrevious)
            return [
                .engineReopenTail(
                    from: engineTail ?? "",
                    to: reduced,
                    fallbackPrevious: fallbackPrevious,
                    fallbackPreviousKeyCount: fallbackPrevious == nil ? 0 : previousKeyCount
                ),
                .updateMarkedText,
            ]

        case .dropTail:
            _ = composer.dropLast()
            state = stateAfterDroppingOneKey()
            return [.engineBackspace, .updateMarkedText]

        case .dropTailAndReopenPrevious(let previous):
            // A9：後面那個音節從未被使用者收尾（只是 `start-new` 自動 flush 進引擎），
            // 連它一起放回緩衝繼續拼；unsealed 記錄要清掉，否則同內容/位置意外重現時會誤判。
            _ = composer.dropLast()
            composer.reopen(previous)
            state = .typing
            return [
                .engineBackspace,
                .engineClearAutoFlushedUnsealedRecord(content: previous, keyCount: previousKeyCount),
                .updateMarkedText,
            ]

        case .deleteFromDocument:
            // 🔴 **不可以只看 plan。** `plan` 判成這一格的條件是「`engineTail == nil`」，
            // 而 `cursorAdjacentKey` 在 `cursor == 0` 就回 `nil`——**即使 keys 非空**。
            // 舊模型下「engineTail==nil ⇔ 組字區已空」成立（沒有 `←→`，游標永遠在尾端）；
            // 第一版加入 `←→`、`CompositionCursorMovementPlan` 允許游標夾到 0 之後就不成立了。
            //
            // 兩條都不能做：
            // 1. 放行給宿主 —— 會刪到組字區前面已經上屏的字。
            // 2. 翻成 `.idle` —— Enter 走 Idle 放行，整段組字再也送不出去（稽核 #3-1）。
            //
            // 無聲 `return []` 同樣不行：2026-09-22 LINE「容布袋」游標在最前面，
            // ⌫ 連按 4 下 `fx=[]`，體感跟當機一樣。游標緊貼第一個音節的前面，
            // ⌫ 退的就是那個音節（跟游標在它後面按是同一刀）。
            guard facts.keys.isEmpty else {
                let onFirstSyllable = MacEngineFacts(
                    keys: facts.keys,
                    cursor: 1,
                    unsealed: facts.unsealed,
                    candidateCount: facts.candidateCount,
                    highlightedCandidateIndex: facts.highlightedCandidateIndex
                )
                guard onFirstSyllable.cursorAdjacentKey?.isEmpty == false else { return [.beep] }
                // 引擎的 drop／replace 都是游標相對的。事實快照改成 cursor=1
                // 只影響這次的 plan；引擎游標仍在 0 的話，replace 會直接失敗、字不動。
                // 先把游標移到第一個音節後面，再走原本的退格。
                return [.engineScrubCursor(by: 1)] + handleBackspace(facts: onFirstSyllable)
            }
            state = .idle
            return [.passThroughToClient]
        }
    }

    /// 退格（緩衝為空時）：砍掉游標前那一整個音節。
    ///
    /// 把漢字退回注音的是 ⌦（`handleBackspace`）。這一鍵跳過那個過程，
    /// 直接 `dropKey`，空出位置讓使用者整段注音重打。
    /// 游標在最前面時，砍的是第一個音節（跟退格同一格），所以要先把引擎游標移過去。
    private mutating func dropWholeSyllable(facts: MacEngineFacts) -> [MacIMEEffect] {
        // 只在緩衝區為空時被呼叫（見 `.backspace`），引擎也空 ⇒ 沒有東西可刪，放行給宿主。
        guard !facts.keys.isEmpty else {
            state = .idle
            return [.passThroughToClient]
        }
        composer.reset()
        var effects: [MacIMEEffect] = []
        if facts.cursor == 0 {
            effects.append(.engineScrubCursor(by: 1))
        }
        state = facts.keys.count <= 1 ? .idle : .typing
        effects.append(.engineBackspace)
        effects.append(.updateMarkedText)
        return effects
    }

    // MARK: - Selecting（spec §4.4）

    private mutating func handleSelecting(
        _ event: MacKeyEvent, facts: MacEngineFacts
    ) -> [MacIMEEffect] {
        switch event {
        // 🔴 不變式 3：導覽絕不碰引擎。`false` 的越界回傳值只拿來決定要不要嗶
        // （由轉接層判斷，設計上要「停住」），**不可**直接當成 IMK 的「有沒有吃掉」回傳。
        case .moveRight:
            return [.candidateHighlightNext]
        case .moveLeft:
            return [.candidateHighlightPrevious]
        // 🔴 ↑↓ 移動**一行**，不是翻一整頁（多行顯示之後的行為）。
        // 一行最多 `selectionKeys.count` 個（09-21 版 9、10-01 起 6）＝ 原本單行模式的一整頁 ⇒
        // 這樣才維持得住按 ↓ 原本的手感；接 `candidateNextPage` 會變成一次跳 4 行。
        // 10-01 起開窗是收合 1 行：↓／↑ 由窗先展開再移行；Space／PageDown 收合時只展開、不翻頁
        // （上游 `flipPage`，狀態機不知道展開與否，事件表不變）。
        // 翻整頁留給 PageUp／PageDown 與 Space／Shift-Space。
        case .moveDown:
            return [.candidateNextLine]
        case .moveUp:
            return [.candidatePreviousLine]
        case .pageDown, .space:
            return [.candidateNextPage]
        case .pageUp, .shiftSpace:
            return [.candidatePreviousPage]

        // 設計決定：確認**進組字**，不是整句上屏。Enter 才整句上屏。
        case .enter:
            state = .typing
            return [.confirmHighlightedCandidate, .closeCandidateWindow, .updateMarkedText]
        case .selectionKey(let labelIndex):
            state = .typing
            return [
                .confirmCandidateAtSelectionKey(labelIndex: labelIndex),
                .closeCandidateWindow,
                .updateMarkedText,
            ]

        // Esc 與 Backspace 都只關窗，什麼都不改（第二下才是刪除）。
        case .escape, .backspace, .deleteForward:
            state = .typing
            return [.closeCandidateWindow]

        // 按到非選字鍵＝「先 Esc 再打字」。可預測，不會偷偷確認沒選的字。
        case .zhuyinSymbol, .tone, .punctuation, .otherCharacter:
            state = .typing
            return [.closeCandidateWindow] + handleTyping(event, facts: facts)

        case .modifierCombo:
            state = .typing
            return [.closeCandidateWindow, .passThroughToClient]

        // R8：關窗，但不放行（Option 的 ASCII 逃逸由 G5 接手）。
        case .optionCombo:
            state = .typing
            return [.closeCandidateWindow]

        // 不變式 1：窗是 process-wide 單例 ⇒ 切走的 client 一律先關窗。
        // 組字保留（W3 決定），所以回 `.typing` 而不是 `.idle`。
        case .deactivate:
            state = .typing
            return [.closeCandidateWindow]

        // G7：關窗，但不確認高亮（那會把使用者沒選的字送出去）。
        // 已組好的字上屏到原位置，跟 Typing 同一條。
        case .clientCursorMoved:
            return [.closeCandidateWindow] + commitBecauseClientCursorMoved()
        }
    }

    /// 宿主游標離開組字區：把已組好的字 commit 到目前的 marked range，再清空。
    ///
    /// 小麥注音 `KeyHandler.mm:305-318` `handleForceCommit`：先 `_bpmfReadingBuffer->clear()`
    /// （未完成注音不送出），再從 grid 組出 composing buffer 上屏，然後 `clear()`。
    /// 入口是 `InputMethodController.swift:208-211` 的 `commitComposition`。
    /// 威注音 `InputSession.swift:328-330` `commitComposition` 呼叫
    /// `resetInputHandler()`（`SessionCoreProtocol.swift:127-152`，`commitExisting` 預設 true）；
    /// 未完成注音是否剪掉由 `trimUnfinishedReadingsOnCommit` 決定，預設 true
    /// （`UserDef.swift:514`）。`SessionControllerSputnik.swift:139-142` 把這條接在
    /// IMK `commitComposition:`，註解寫「組字中途切換焦點時自動提交」。
    ///
    /// `isPartial` 時先 `.engineBackspace` 丟掉游標前那個尚未收尾的 key，對應「先清 reading」。
    /// 已經收尾的字仍走 `.commitComposedText`（`insertText` 取代 marked range，所以留在原位）。
    private mutating func commitBecauseClientCursorMoved() -> [MacIMEEffect] {
        let dropUnfinished: [MacIMEEffect] = isPartial ? [.engineBackspace] : []
        composer.reset()
        state = .idle
        return dropUnfinished + [.commitComposedText]
    }

    // MARK: - 測試專用注入口

    /// 只給 `MacCandidateModeCLIProbe` 用：直接把狀態擺到某一格，省去逐鍵重演。
    public mutating func forceStateForTesting(_ newState: MacCandidateModeState) {
        state = newState
    }

    public mutating func forceBufferForTesting(_ buffer: String) {
        composer.reopen(buffer)
    }
}
