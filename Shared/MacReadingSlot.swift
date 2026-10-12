// SPDX-License-Identifier: Apache-2.0
import Foundation

/// 詞庫對一個字的讀音查詢結果（引擎側的同形型別經橋接轉成這個，外殼只認這個）。
struct MacLexiconReadingChoice: Equatable {
    var character: Character
    /// 這個字在詞庫裡的讀音，最常用的在前。空陣列＝查不到。
    var readings: [String]
    /// 要預選的讀音。整詞詞條的音節優先於單字最常用；查不到則是 nil。
    var preferred: String?
}

/// 一個字一格。破音字給選單（預選整詞詞條的音節，否則最常用的），詞庫沒有的字讓使用者手打。
struct MacReadingSlot: Identifiable, Equatable {
    var id: Int
    var character: String
    var readings: [String]
    var selection: String
    /// 詞庫沒有這個字：用小文字框手打一個音節。
    var manual: Bool

    static func slots(from choices: [MacLexiconReadingChoice]) -> [MacReadingSlot] {
        choices.enumerated().map { index, choice in
            MacReadingSlot(
                id: index,
                character: String(choice.character),
                readings: choice.readings,
                selection: choice.preferred ?? "",
                manual: choice.readings.isEmpty
            )
        }
    }

    /// 存檔用的讀音：各格選的音節去掉頭尾空白後以 `-` 相接。
    static func reading(of slots: [MacReadingSlot]) -> String {
        slots
            .map { $0.selection.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "-")
    }
}
