// SPDX-License-Identifier: Apache-2.0
/// 音節內延伸的詞彙常用度。回答的是「這個鍵能延伸目前這個不完整音節，但常不常用」。
///
/// ⚠️ **目前沒有產品端呼叫者。** 音節邊界的兩張表已於 2026-08-08 刪除——邊界上任一
/// 注音符號都能合法開始下一個字（實測 37/37），沒有合法性訊號，把統計建議畫進亮度
/// 通道就會被讀成「這個字打不出來」。
///
/// 留下這一張是因為音節**內**是唯一符合「使用者必然要從亮的那幾顆裡選」的位置。
/// 要接線之前注意：它是建議不是 gate，不能借亮度通道。
public struct SyllableSuccessorTable {
    /// 共用實例。三張表加起來近 1700 列要 parse，view 每次 render 都重建會浪費。
    public static let shared = SyllableSuccessorTable()

    /// 一個符號在當前位置有多常見。
    ///
    /// 分三段而不是二段，是因為單一門檻必然造成截斷誤差：涵蓋 90% 的門檻會把
    /// 「第 91 百分位」和「第 100 百分位」的符號畫成同一種「不常見」，那 10% 就是
    /// 純粹的誤導。分段之後最外圈的鍵仍有自己的亮度，「涵蓋率之外」就不再是一個
    /// 二元的懸崖。
    public enum Commonness: Equatable {
        case strong
        case weak
        case rare
    }

    /// 一張「鍵 → (強建議集合, 弱建議集合)」的表。三個位置各有一張，語意不可互換
    /// （見 `SyllableSuccessorData` 檔頭）。
    private struct Segments {
        let strong: [String: Set<Character>]
        let weak: [String: Set<Character>]

        init(raw: String) {
            var s: [String: Set<Character>] = [:]
            var w: [String: Set<Character>] = [:]
            for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
                let parts = line.split(
                    separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3, !parts[0].isEmpty else { continue }
                let key = String(parts[0])
                if !parts[1].isEmpty { s[key] = Set(parts[1]) }
                if !parts[2].isEmpty { w[key] = Set(parts[2]) }
            }
            strong = s
            weak = w
        }

        /// `nil` = 這個鍵沒有統計資料。呼叫端必須據此降級成「不給建議」，
        /// 不能當成 `.rare`——那會把一整排合法鍵標成罕見，比沒有這層還糟。
        func commonness(of symbol: Character, after key: String) -> Commonness? {
            let s = strong[key]
            let w = weak[key]
            guard s != nil || w != nil else { return nil }
            if s?.contains(symbol) == true { return .strong }
            if w?.contains(symbol) == true { return .weak }
            return .rare
        }

        var keys: Set<String> { Set(strong.keys).union(weak.keys) }
    }

    private let extending: Segments

    public init() {
        extending = Segments(raw: SyllableSuccessorData.syllableExtension)
    }

    /// 音節內延伸：buffer 是不完整音節，`symbol` 延續**同一個字**。
    /// 使用者必然會打其中一個 —— 這是原本三張表裡唯一留下的一張（另兩張見檔頭）。
    public func extensionCommonness(of symbol: Character, after prefix: String) -> Commonness? {
        extending.commonness(of: symbol, after: prefix)
    }

    // MARK: - 內省（測試與診斷用）

    public var extensionPrefixCount: Int { extending.keys.count }
    public var allExtensionPrefixes: [String] { Array(extending.keys) }

    /// 強建議 ∪ 弱建議。給只需要「有沒有被建議」的呼叫端與測試用。
    public func extensionSuccessors(after prefix: String) -> Set<Character>? {
        let s = extending.strong[prefix]
        let w = extending.weak[prefix]
        guard s != nil || w != nil else { return nil }
        return (s ?? []).union(w ?? [])
    }
}
