// SPDX-License-Identifier: Apache-2.0
// Mac 輸入法狀態機的值型別（spec §3 的「純邏輯」那一層）。
//
// 🔴 **這個檔案與 `CandidateModeMachine.swift` 都不得 import AppKit／InputMethodKit。**
// 理由（spec §4.2）：事件入口目前走 `didCommand(by:client:)`，但那條路徑是否真的收得到
// `moveDown:`／`cancelOperation:` **未經實機驗證**；若實機發現收不到，整個入口要換成
// `handleEvent:client:`——那是全有或全無的切換。把 `MacKeyEvent` 定義成獨立於 IMK 入口
// 形式的列舉，換入口時只要改轉接層，狀態機與它的測試一行都不用動。
//
// 另一個理由是可測性：mac target 一支測試都沒有、加 test target 要改 pbxproj，
// 所以護欄 G2／G3／G4 唯一便宜的機械測法就是用純 swiftc 編這一層
// （`tools/test_mac_candidate_mode.sh`）。

import Foundation

// MARK: - 正交狀態（G6 預留）

/// 中／英模式。spec §4.1：`en` 時一律放行、窗不可能開著。
/// **G6 本輪不實作切換**，這裡只把位置留好，免得之後得拆狀態機。
public enum MacInputLanguage: Equatable {
    case zh
    case en
}

// MARK: - 狀態

/// spec §4.1 的三態。`Typing` 的兩個子相（`partial`／`settled`）**不另立 case**：
/// 它由 `LegalKeySyllableComposer.currentBuffer` 是否為空推導（單一真相，不會漂移）。
public enum MacCandidateModeState: Equatable {
    case idle
    case typing
    case selecting
}

// MARK: - 事件

/// 進到狀態機的按鍵事件。**刻意獨立於 IMK 的入口形式**（見檔頭）。
public enum MacKeyEvent: Equatable {
    /// 已由轉接層用大千排列對映過的注音符號。
    case zhuyinSymbol(Character)
    /// 聲調鍵 `ˇ ˋ ˊ ˙`（一聲沒有專屬鍵，走 `.space`）。
    case tone(Character)
    case space
    case shiftSpace
    case enter
    case escape
    case backspace
    /// Forward Delete（`⌦`／`fn`+退格）。把游標前那個漢字退回注音（原本退格的 G4 行為）。
    case deleteForward
    case moveLeft
    case moveRight
    case moveUp
    case moveDown
    case pageUp
    case pageDown
    /// 選字鍵：第 `labelIndex` 個（0-based）。對到哪個全域候選由窗決定（spec §8.2）。
    case selectionKey(labelIndex: Int)
    /// G5 預留（spec §7）。本輪一律放行。
    case punctuation(Character)
    /// G7 預留（spec §7）：宿主 app 自己把游標移走了。
    case clientCursorMoved
    /// Cmd／Ctrl 組合：一律放行（那是宿主 app 的快捷鍵）。
    case modifierCombo
    /// 🔴 **Option 組合：不可以放行。**
    ///
    /// 放行的話宿主會用 ABC 排列去翻譯，使用者按 Option+1 會打出 `¡`、Option+2 打出 `™`。
    /// 中文輸入法裡 Option＋鍵的正確語意是**一次性 ASCII 逃逸**——那是使用者在中文模式下
    /// 打數字、`@`、網址的方法（Apple 自己的鍵盤層與 vChewing 文件都是如此；
    /// 來源：`mac-punct-lang` 查 Apple 鍵盤層第一手輸出，PR #206）。
    ///
    /// 完整的 ASCII 逃逸實作屬於 **G5，不在本輪範圍**；這裡先把格子留成「吃掉」，
    /// 免得在 G5 接上之前就讓使用者打出 `¡`。
    ///
    /// ⚠️ **目前沒有產生者**：現行入口（`inputText`／`didCommand`）拿不到 modifier 資訊。
    /// 要 keyCode 入口才產得出來——但那只是「多一個窄的補充入口」，不是把整個事件入口
    /// 換成 `handleEvent:client:`。
    case optionCombo
    /// `deactivateServer`：這個 client 失去焦點（G8，spec §4.4 最後一列）。
    case deactivate
    /// 其他字元鍵（英數字母等）。
    case otherCharacter(Character)
}

// MARK: - 引擎事實（唯讀快照）

/// 引擎裡「未被使用者真正收尾」的音節記錄，對應
/// `ZhuyinEngine.autoFlushedUnsealedSyllables` 的一筆。
public struct MacUnsealedRecord: Equatable {
    public let content: String
    public let keyCount: Int

    public init(content: String, keyCount: Int) {
        self.content = content
        self.keyCount = keyCount
    }
}

/// 狀態機做決策時需要的引擎唯讀事實。
///
/// **為什麼是快照而不是引擎參照**：`ZhuyinEngine` 相依 KenLM／SQLite，純 swiftc 測試編不動它；
/// 而且狀態機一旦能直接呼叫引擎，「導覽絕不碰引擎」（不變式 3）就退化成靠自律。
/// 快照進、effect 出，違反不變式會直接被 effect 序列的斷言抓到。
public struct MacEngineFacts: Equatable {
    /// `compositor.keys`。
    public let keys: [String]
    /// `compositor.cursor`。**游標相對**是 `Megrez` 所有增刪操作的語意（spec §6 Bug A）。
    public let cursor: Int
    public let unsealed: [MacUnsealedRecord]
    /// `currentCandidates(limit:).count`。
    public let candidateCount: Int
    /// `ZhuyinEngine.highlightedCandidateIndex`；沒有選過時是 -1。
    public let highlightedCandidateIndex: Int
    /// 沒拼完的注音怎麼處理。預設 `.seal`＝2026-10-04 之前的行為，純狀態機既有測試不受影響；
    /// 出貨路徑由轉接層從偏好帶進來。
    public let unfinishedPolicy: MacUnfinishedZhuyinPolicy

    /// - Parameter cursor: 省略時等於 `keys.count`（游標在尾端，最常見的情形）。
    public init(
        keys: [String] = [],
        cursor: Int? = nil,
        unsealed: [MacUnsealedRecord] = [],
        candidateCount: Int = 0,
        highlightedCandidateIndex: Int = -1,
        unfinishedPolicy: MacUnfinishedZhuyinPolicy = .seal
    ) {
        self.keys = keys
        self.cursor = cursor ?? keys.count
        self.unsealed = unsealed
        self.candidateCount = candidateCount
        self.highlightedCandidateIndex = highlightedCandidateIndex
        self.unfinishedPolicy = unfinishedPolicy
    }

    /// 游標前面那個 key（`keys[cursor - 1]`）。
    ///
    /// 🔴 **不是 `keys.last`**。`Megrez.Compositor.dropKey(direction:.rear)`／`insertKey()`
    /// 都是游標相對的，砍的是 `keys[cursor - 1]`。Q9 拍板要做 `←→` ⇒ 游標偏離尾端是
    /// **保證會發生**的狀態。用 `keys.last` 算 plan、引擎卻動到游標前那個音節 ⇒ 砍錯字。
    /// （iOS 2026-08-08 Bug A 的根因，見 `ZhuyinActionHandler.handleLegalKeyBackspace`。）
    public var cursorAdjacentKey: String? {
        let index = cursor - 1
        guard index >= 0, index < keys.count else { return nil }
        return keys[index]
    }

    /// 游標前面第二個 key（`keys[cursor - 2]`）——`.dropTail` 砍掉 `cursorAdjacentKey`
    /// 之後，它會變成新的尾端（A9）。
    public var keyBeforeCursorAdjacent: String? {
        let index = cursor - 2
        guard index >= 0, index < keys.count else { return nil }
        return keys[index]
    }

    /// `cursor - 2` 的 1-based 位置（`ZhuyinEngine.isSealed(key:atKeyCount:)` 的參數形式）。
    public var keyCountOfKeyBeforeCursorAdjacent: Int { cursor - 1 }

    /// 對應 `ZhuyinEngine.isSealed(key:atKeyCount:)`：只有精準命中 unsealed 記錄才是 false。
    /// 預設 `true`（安全預設，與 `LegalKeyBackspacePlan.plan` 的參數預設值一致）。
    public func isSealed(key: String, atKeyCount keyCount: Int) -> Bool {
        !unsealed.contains { $0.content == key && $0.keyCount == keyCount }
    }
}

// MARK: - 效果

/// 狀態機的輸出。轉接層逐一執行；測試直接斷言序列。
///
/// 🔴 **導覽類（`candidateHighlight*`／`candidate*Page`）絕不可以在轉接層被翻譯成引擎呼叫**
/// ——不變式 3。`setHighlightedCandidate(index:)` 會 `applyOverride` 並重建候選清單，
/// 掛在每次高亮變更上＝每按一下方向鍵就整句重新解析、窗下的清單被換掉。
public enum MacIMEEffect: Equatable {
    // MARK: 引擎（只有這些才准碰 ZhuyinEngine）

    case engineInput(String)
    case engineReplaceLastKey(from: String, to: String)
    case engineBackspace
    case engineClear
    case engineMarkAutoFlushedAsUnsealed(content: String, keyCount: Int)
    case engineClearAutoFlushedUnsealedRecord(content: String, keyCount: Int)
    /// `.reopenTail`（G4）專用，**唯一需要引擎回饋的 effect**。
    ///
    /// iOS 執行端只有在 `replaceLastKey(from:to:)` 成功時才 `composer.reopen(to)`；失敗時改成
    /// `engine.backspace()`（該音節整個消失），並套用與 `.dropTail` 同一條 A9 規則——
    /// 前一個音節若從未被收尾，連它一起放回緩衝並清掉 unsealed 記錄。
    /// 純邏輯層事前決定不了成敗，所以把 fallback 需要的一切隨 effect 帶出去，
    /// 轉接層執行完呼叫 `MacCandidateModeMachine.resolveReopenTail(succeeded:)` 讓 composer 定案。
    ///
    /// `fallbackPrevious` 為 `nil` ⇒ 前一個音節已收尾（或不存在），fallback 時緩衝區清空。
    case engineReopenTail(
        from: String, to: String, fallbackPrevious: String?, fallbackPreviousKeyCount: Int)
    /// 一聲的 `replaceLastKey` 失敗時的 fallback：只在顯示層標記這個 key 已收尾。
    case engineMarkImplicitFirstTone
    case engineScrubCursor(by: Int)

    // MARK: 候選窗（零引擎副作用）

    case openCandidateWindow
    case closeCandidateWindow
    case candidateHighlightNext
    case candidateHighlightPrevious
    case candidateNextPage
    case candidatePreviousPage
    /// 多行模式下移動**一行**（spec §8.2 原本標「v1 不用」；使用者 2026-09-21 要求
    /// 「選字可以一次顯示多一點比較多的行數嗎」之後才用上）。
    ///
    /// 🔴 一行**最多** `selectionKeys.count` 個（9 個→10-01 起 6 個；橫排按寬度排行，多字詞多時更少）
    /// ＝ **原本單行模式的一整頁**，所以把 ↑↓ 接到這裡才維持得住使用者原本的手感；接到
    /// `candidateNextPage` 會一次跳 4 行。10-01 起開窗是收合 1 行，↓ 先展開再移一行。
    case candidateNextLine
    case candidatePreviousLine

    // MARK: 確認（唯一會寫引擎的候選操作，Q1 拍板 (a)）

    /// 確認窗目前高亮的那一格。index 只有窗知道（`highlightedIndex`），
    /// 所以由轉接層讀出來再呼叫 `engine.setHighlightedCandidate(index:)`。
    case confirmHighlightedCandidate
    /// 確認選字鍵對到的那一格。`candidateIndexAtKeyLabelIndex(_:)` 超出本頁會回 `nil`
    /// ⇒ 轉接層負責嗶；**狀態機一律把這個鍵吃掉**（不放行給宿主）。
    case confirmCandidateAtSelectionKey(labelIndex: Int)

    // MARK: client

    case updateMarkedText
    /// 整句上屏：`client.insertText(engine.getComposedText())` ＋ 清 marked text ＋ `engine.clear()`。
    /// **只給 `.punctuation` 路徑用**——它一定要立即上屏（標點要接在後面），不能等第二次
    /// Enter。使用者按 Enter 走的是下面的 `.confirmComposedTextOnEnter`。
    case commitComposedText
    /// `.enter`（Typing）專用，選項 C（G1，2026-09-26 產品決策）：轉接層比對
    /// 「Enter 前實際顯示的畫面」跟「即將送出的 `getComposedText()`」，兩者不同時第一次
    /// Enter 只把畫面更新成即將送出的內容、不 commit；使用者看到之後再按一次 Enter
    /// 才真正送出（逐字等於剛剛看到的畫面）。兩者本來就相同時單次 Enter 直接送出。
    ///
    /// 🔴 **名字故意不含 `"commitComposedText"` 這個子字串**——
    /// `tools/mac_guardrails/g1_commit_mismatch.py` 的 `is_commit` 判斷用
    /// `"commitComposedText" in fx`，取名不慎會讓「只是預覽、還沒送出」的 Enter
    /// 被那支分析工具誤算成一次 commit。
    ///
    /// 系統強制 flush（`commitComposition`，例如切走焦點）**不受這道閘限制**——那個
    /// 時機沒有「等下一次 Enter」的機會，轉接層收到這個 effect 時若判斷來源是系統強制
    /// flush，一律直接送出（見 `MacClientSession.handle(forceImmediateCommit:)`）。
    /// 純邏輯層不知道呼叫來源是誰，這個判斷只能在轉接層做。
    case confirmComposedTextOnEnter
    /// G5：把一段**與引擎無關**的純文字插進宿主（標點）。`client.insertText(text)`，
    /// 不碰組字狀態、不碰引擎——組字要不要先上屏是呼叫端的事（見 `.punctuation` 分支：
    /// settled／partial 會先送一個 `.commitComposedText` 再送這個）。
    case insertText(String)
    /// 這個鍵我們不處理，還給宿主 app（IMK 回 `false`）。
    case passThroughToClient
    case beep
}
