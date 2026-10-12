// SPDX-License-Identifier: Apache-2.0
/// 合法注音音節表（不含聲調），提供查詢與前綴剪枝
public struct SyllableTable {
    public let syllableSet: Set<String>
    public let prefixSet: Set<String>

    public init() {
        syllableSet = Set(SyllableData.allSyllables)

        var prefixes = Set<String>()
        for syllable in syllableSet {
            let chars = Array(syllable)
            for i in 1..<chars.count {
                prefixes.insert(String(chars.prefix(i)))
            }
        }
        prefixSet = prefixes
    }

    /// 是否為合法完整音節
    public func isValidSyllable(_ s: String) -> Bool {
        return syllableSet.contains(s)
    }

    /// 是否為某個合法音節的前綴（用於格圖生成的早期剪枝）
    public func isValidPrefix(_ s: String) -> Bool {
        return prefixSet.contains(s) || syllableSet.contains(s)
    }
}
