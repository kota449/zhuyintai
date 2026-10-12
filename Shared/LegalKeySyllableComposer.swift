// SPDX-License-Identifier: Apache-2.0
/// 合法音節鍵約束的確定性狀態機：給定目前已打的原始符號緩衝區，判斷下一個鍵
/// 是延伸目前音節、自動收尾開新音節、還是非法。取代機率式 hypothesis scoring。
public struct LegalKeySyllableComposer {
    public enum Decision: Equatable {
        case extend
        case startNew
        case reject
    }

    public private(set) var currentBuffer: String = ""
    private let syllableTable: SyllableTable

    public init(syllableTable: SyllableTable = SyllableTable()) {
        self.syllableTable = syllableTable
    }

    /// 目前緩衝區加上這個符號，會是延伸、開新音節、還是非法。
    public func decision(for symbol: Character) -> Decision {
        let candidateExtend = currentBuffer + String(symbol)
        if syllableTable.isValidPrefix(candidateExtend) {
            return .extend
        }
        if syllableTable.isValidSyllable(currentBuffer), syllableTable.isValidPrefix(String(symbol)) {
            return .startNew
        }
        return .reject
    }

    /// 按下一個符號鍵。非法且未強制覆蓋時，緩衝區不變（no-op）。
    @discardableResult
    public mutating func press(
        _ symbol: Character,
        forceOverride: Bool = false
    ) -> (previousBuffer: String, newBuffer: String, startedNewSyllable: Bool) {
        let previous = currentBuffer
        switch decision(for: symbol) {
        case .extend:
            currentBuffer += String(symbol)
            return (previous, currentBuffer, false)
        case .startNew:
            currentBuffer = String(symbol)
            return (previous, currentBuffer, true)
        case .reject:
            guard forceOverride else { return (previous, previous, false) }
            currentBuffer += String(symbol)
            return (previous, currentBuffer, false)
        }
    }

    /// 聲調鍵：永遠收尾目前緩衝區（不管緩衝區是否為完整音節——聲調鍵本身就是
    /// 收尾訊號），回傳收尾後的完整讀音，緩衝區清空。
    @discardableResult
    /// 聲調鍵的**政策層**：緩衝區是空的時候按聲調，不成音節 ⇒ caller 應該當 no-op。
    ///
    /// 為什麼不寫進 `pressTone`：`pressTone` 是刻意不含政策的機制層
    /// （見 `LegalKeySyllableComposerTests.testDecisionForToneCharacterAlwaysRejects`
    /// 的註解：「Callers that need tone-aware legality must special-case tone
    /// characters themselves — this composer does not do it for them」）。
    ///
    /// 為什麼需要它：`ZhuyinActionHandler` 有兩條被文件宣稱相同的聲調路徑，但只有
    /// `applyFirstToneUnderLegalKeyGate`（空白鍵補一聲）有 `guard !prevContent.isEmpty`，
    /// `handleLegalKeyKeypress` 的 `isTone` 分支沒有 ⇒ 空 buffer 按聲調時，裸聲調被當成
    /// 音節餵進引擎。2026-09-03 實機證據（531 鍵）：
    /// `key='˙' bufferBefore='' → engineComposition='所以這樣是˙'`。
    /// 把判斷具名放在這裡，兩條路才有單一真相可共用，而不是各自帶各自的 guard。
    public static func shouldIgnoreTonePress(currentBuffer: String) -> Bool {
        currentBuffer.isEmpty
    }

    /// 緩衝區是不是一顆可以加聲調收尾的完整音節（不含聲調）。
    ///
    /// `ㄈ` 只是聲母、不是完整音節；`pressTone` 仍會把它收成 `ㄈˇ`。呼叫端要先問這格，
    /// 不成音節就不要收尾（McBopomofo `KeyHandler.mm:522` 沒有 unigram 就清掉讀音）。
    public var isCompleteSyllable: Bool {
        syllableTable.isValidSyllable(currentBuffer)
    }

    public mutating func pressTone(_ tone: Character) -> String {
        currentBuffer += String(tone)
        let committed = currentBuffer
        currentBuffer = ""
        return committed
    }

    /// backspace 第一層：刪緩衝區最後一個符號，回傳刪除後的新緩衝區。
    @discardableResult
    public mutating func dropLast() -> String {
        guard !currentBuffer.isEmpty else { return currentBuffer }
        currentBuffer.removeLast()
        return currentBuffer
    }

    public mutating func reset() {
        currentBuffer = ""
    }

    /// 把某個既有音節重新放回緩衝區繼續拼。
    ///
    /// 只有 backspace 退回「已經用聲調收尾的音節」時會用到（見
    /// `LegalKeyBackspacePlan.reopenTail`）——內容來自組字區裡本來就存在的 key
    /// 去掉最後一個符號，所以必然是合法音節或其前綴，不需要再驗一次。
    public mutating func reopen(_ syllable: String) {
        currentBuffer = syllable
    }
}
