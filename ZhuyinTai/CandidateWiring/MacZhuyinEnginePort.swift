// SPDX-License-Identifier: Apache-2.0
// Mac session 看引擎的埠。
//
// session 依賴這個 protocol，測試塞假引擎就能斷言「兩個 client 的字各送各的」，
// 不必帶 KenLM。出貨實作由 `MacEngineFactory` 提供。成員是 `MacClientSession` 與
// `MacComposedSegmentBuilder` 實際呼叫的那些，不是一份想像的介面。

import Foundation

protocol MacZhuyinEnginePort: AnyObject {
    @discardableResult func input(_ char: String) -> Bool
    @discardableResult func replaceLastKey(from oldKey: String, to newKey: String) -> Bool
    func backspace()
    func clear()
    func markAutoFlushedAsUnsealed(content: String, keyCount: Int)
    func clearAutoFlushedUnsealedRecord(content: String, keyCount: Int)
    func markImplicitFirstToneForCurrentTail()
    @discardableResult func scrubCompositionCursor(by requestedOffset: Int) -> CompositionCursorMovementPlan
    @discardableResult func setHighlightedCandidate(index: Int) -> String?
    func getComposedText() -> String
    func currentCandidates(limit: Int) -> [String]
    func highlightedCandidate() -> String?
    var compositorKeys: [String] { get }
    var compositionCursor: Int { get }
    var autoFlushedUnsealedSyllables: [(content: String, keyCount: Int)] { get }
    var effectiveExternalLeftContext: String { get }
    func setExternalLeftContext(_ context: String?)
    /// 這一輪組字的宿主是不是終端機（`MacIMEShippingBehavior.isTerminalHost`），session 在組字第一鍵設定。
    var leftContextHostIsTerminal: Bool { get set }
    /// 左文送進引擎前的長度上限（字元數）。
    var kenLMContextWindowChars: Int { get }
    var lastOverrideApplied: Bool? { get }
    /// 唯讀的組字器檢視（選字後游標位置、顯示層分段用）。
    var composerView: (any MacComposerView)? { get }
    /// 預熱（載入詞庫與模型）。假引擎不用做。
    func warmUp()
    /// 選字學習：把學習層（重新）接到引擎；沙箱外／開關關 ⇒ 學習層整個關閉。啟用時會再呼叫一次（開關變更下次啟用生效）。假引擎不用做。
    func refreshChoiceLearning()
    func isSealed(key: String, atKeyCount keyCount: Int) -> Bool
    /// 自訂詞檔改了之後，用既有的載入入口重讀。假引擎不用做。
    @discardableResult func reloadUserPhrases(fromContainer container: URL) -> Int
    /// 選字學習：使用者按下確認後呼叫（spec §4.1）。假引擎不用做。
    func noteUserConfirmedSelection()
    /// 選字學習：到目前為止自動套用過幾段（log 的 `learned=` 欄位用，算差值）。假引擎＝0。
    var learnedChoicesAppliedTotal: Int { get }
}

extension MacZhuyinEnginePort {
    func currentCandidates() -> [String] { currentCandidates(limit: Int.max) }
    func warmUp() {}
    func refreshChoiceLearning() {}
    func reloadUserPhrases(fromContainer _: URL) -> Int { 0 }
    func noteUserConfirmedSelection() {}
    var learnedChoicesAppliedTotal: Int { 0 }
}
