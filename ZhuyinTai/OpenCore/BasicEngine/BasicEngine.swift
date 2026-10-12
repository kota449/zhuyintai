// SPDX-License-Identifier: Apache-2.0
// 公開版注音引擎。Megrez 組字，詞庫只用小麥 MIT 資料。
// 沒有選字學習。目標是能打字：輸入、組字、候選、選字、退格、移動游標。

#if canImport(Megrez)
import Megrez
#endif
import Foundation

final class BasicEngine: MacZhuyinEnginePort {
    /// 組字區音節上限。再長就拒絕，避免格子無限長大。
    static let maxCompositionKeys = 48
    static let contextWindowChars = 32

    private let lexicon: McBopomofoLexicon
    private let compositor: Megrez.Compositor
    private let view: BasicComposerView
    private var unsealed: [(content: String, keyCount: Int)] = []
    private var externalLeftContextStorage = ""

    init(lexicon: McBopomofoLexicon = .shared) {
        self.lexicon = lexicon
        let compositor = Megrez.Compositor(with: lexicon)
        self.compositor = compositor
        self.view = BasicComposerView(compositor: compositor)
    }

    @discardableResult
    func input(_ char: String) -> Bool {
        guard lexicon.accepts(char) else { return false }
        guard compositor.keys.count < Self.maxCompositionKeys else { return false }
        guard compositor.insertKey(char) else { return false }
        alignSingleKeyNodesWithSentence()
        return true
    }

    @discardableResult
    func replaceLastKey(from oldKey: String, to newKey: String) -> Bool {
        guard compositor.cursor > 0 else { return false }
        let index = compositor.cursor - 1
        guard compositor.keys.indices.contains(index), compositor.keys[index] == oldKey else { return false }
        guard lexicon.accepts(newKey) else { return false }
        compositor.cursor = index + 1
        guard compositor.dropKey(direction: .rear) else { return false }
        if compositor.insertKey(newKey) {
            alignSingleKeyNodesWithSentence()
            return true
        }
        _ = compositor.insertKey(oldKey)
        alignSingleKeyNodesWithSentence()
        return false
    }

    func backspace() {
        _ = compositor.dropKey(direction: .rear)
        let count = compositor.keys.count
        unsealed.removeAll { $0.keyCount > count }
        alignSingleKeyNodesWithSentence()
    }

    func clear() {
        compositor.clear()
        unsealed.removeAll()
        lastOverrideApplied = nil
    }

    func markAutoFlushedAsUnsealed(content: String, keyCount: Int) {
        if unsealed.contains(where: { $0.content == content && $0.keyCount == keyCount }) { return }
        unsealed.append((content: content, keyCount: keyCount))
    }

    func clearAutoFlushedUnsealedRecord(content: String, keyCount: Int) {
        unsealed.removeAll { $0.content == content && $0.keyCount == keyCount }
    }

    func markImplicitFirstToneForCurrentTail() {
        let count = compositor.keys.count
        guard count > 0 else { return }
        let key = compositor.keys[count - 1]
        unsealed.removeAll { $0.keyCount == count && $0.content == key }
    }

    @discardableResult
    func scrubCompositionCursor(by requestedOffset: Int) -> CompositionCursorMovementPlan {
        let plan = CompositionCursorMovementPlan.plan(
            requestedOffset: requestedOffset,
            cursor: compositor.cursor,
            compositionLength: compositor.length
        )
        compositor.cursor += plan.consumedOffset
        return plan
    }

    @discardableResult
    func setHighlightedCandidate(index: Int) -> String? {
        let pairs = candidatePairs()
        guard pairs.indices.contains(index) else {
            lastOverrideApplied = false
            return nil
        }
        let pair = pairs[index]
        let applied = compositor.overrideCandidate(
            pair,
            at: compositor.cursor,
            isExplicitlyOverridden: true
        )
        lastOverrideApplied = applied
        if applied { alignSingleKeyNodesWithSentence() }
        return applied ? pair.value : nil
    }

    /// 整句選中的詞（例如「注音」）跟「把未收尾 key 挖掉再解一次」用的是不同上下文。
    /// 挖掉之後單鍵節點會回到詞頻最高的字（「注」變成「著」），畫面和 Enter 送出的字不一致。
    /// 這裡在組句之後，把單鍵節點的索引指到整句那個字，但不抬分數，
    /// 所以下一輪組句仍由詞組節點贏；顯示層的複本挖掉鄰居後，留下的字還是整句的那個字。
    private func alignSingleKeyNodesWithSentence() {
        for segment in compositor.segments {
            guard let node = segment[1] else { continue }
            guard !node.isExplicitlyOverridden, node.currentOverrideType == nil else { continue }
            guard node.currentUnigramIndex != 0 else { continue }
            node.overrideStatus = NodeOverrideStatus(
                overridingScore: node.overridingScore,
                currentOverrideType: nil,
                isExplicitlyOverridden: false,
                currentUnigramIndex: 0
            )
        }
        compositor.assembledSentenceDirty = true
        var offset = 0
        for gram in compositor.assembledSentence {
            let characters = Array(gram.value)
            let length = gram.segLength
            if length > 1, characters.count == length {
                for index in 0 ..< length {
                    let position = offset + index
                    guard compositor.segments.indices.contains(position),
                          let node = compositor.segments[position][1],
                          !node.isExplicitlyOverridden,
                          node.currentOverrideType == nil
                    else { continue }
                    let character = String(characters[index])
                    guard node.value != character,
                          let unigramIndex = node.unigrams.firstIndex(where: { $0.value == character })
                    else { continue }
                    node.overrideStatus = NodeOverrideStatus(
                        overridingScore: node.overridingScore,
                        currentOverrideType: nil,
                        isExplicitlyOverridden: false,
                        currentUnigramIndex: unigramIndex
                    )
                }
            }
            offset += length
        }
    }

    func getComposedText() -> String {
        compositor.assembledSentence.map(\.value).joined()
    }

    func currentCandidates(limit: Int) -> [String] {
        let values = candidatePairs().map(\.value)
        guard limit > 0 else { return [] }
        if limit >= values.count { return values }
        return Array(values.prefix(limit))
    }

    func highlightedCandidate() -> String? {
        let sentence = compositor.assembledSentence
        guard !sentence.isEmpty else { return nil }
        guard compositor.cursor > 0 else { return sentence.first?.value }
        return sentence.findGram(at: compositor.cursor - 1)?.gram.value
    }

    var compositorKeys: [String] { compositor.keys }
    var compositionCursor: Int { compositor.cursor }
    var autoFlushedUnsealedSyllables: [(content: String, keyCount: Int)] { unsealed }
    var effectiveExternalLeftContext: String { externalLeftContextStorage }

    func setExternalLeftContext(_ context: String?) {
        let raw = context ?? ""
        if raw.count <= kenLMContextWindowChars {
            externalLeftContextStorage = raw
        } else {
            externalLeftContextStorage = String(raw.suffix(kenLMContextWindowChars))
        }
    }

    var leftContextHostIsTerminal = false
    var kenLMContextWindowChars: Int { Self.contextWindowChars }
    var lastOverrideApplied: Bool?
    var composerView: (any MacComposerView)? { view }

    func warmUp() {
        _ = lexicon.scoredEntryCount
    }

    func isSealed(key: String, atKeyCount keyCount: Int) -> Bool {
        !unsealed.contains { $0.content == key && $0.keyCount == keyCount }
    }

    private func candidatePairs() -> [Megrez.KeyValuePaired] {
        guard !compositor.keys.isEmpty else { return [] }
        let raw = compositor.fetchCandidates(at: compositor.cursor, filter: .endAt)
        var best: [String: Megrez.KeyValuePaired] = [:]
        best.reserveCapacity(raw.count)
        for pair in raw {
            if let old = best[pair.value], old.score >= pair.score { continue }
            best[pair.value] = pair
        }
        return best.values.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.value < rhs.value
        }
    }
}
