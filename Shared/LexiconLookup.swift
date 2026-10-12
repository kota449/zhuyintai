// SPDX-License-Identifier: Apache-2.0
import Foundation

/// 詞庫分頁「查詞框」的判斷：輸入一個詞，回答「已內建」「在某包裡（要開啟）」「已在我的詞庫」「都沒有」。
///
/// 純函式：所有資料（出貨詞庫是否有這個詞、各包的詞、各包目前開不開、自訂詞）都由呼叫端注入，
/// 這裡不碰 sqlite、不碰 UserDefaults、不碰使用者的檔案。查詢只在設定頁按下 Enter 時跑，
/// 不在打字路徑上。
enum LexiconLookup {

    struct PackSource: Equatable {
        var slug: String
        var title: String
        var words: Set<String>
        /// 呼叫端用領域包目錄的 `isEnabled` 算好（舊鍵遷移邏輯在那裡面，不要自己讀 defaults）。
        var enabled: Bool
    }

    struct PackHit: Equatable {
        var slug: String
        var title: String
    }

    struct Sources {
        /// 永遠載入的 core.txt 的詞。
        var coreWords: Set<String>
        /// 出貨詞庫（含 overlay）有沒有這個詞。
        var isInShippedLexicon: (String) -> Bool
        /// 使用者在「自訂詞」分頁加的詞。
        var customWords: Set<String>
        /// 領域包，順序就是結果的順序。
        var packs: [PackSource]
    }

    enum BuiltInOrigin: Equatable {
        case core
        case shipped
        /// 這個詞在一個已開啟的包裡。
        case pack(title: String)
    }

    enum Outcome: Equatable {
        /// 查詞框是空的。
        case empty
        /// 已內建 ✓（不管是 core、出貨詞庫還是已開的包）。
        case builtIn(BuiltInOrigin)
        /// 已經在使用者自己的詞庫（自訂詞）。
        case inCustom
        /// 只在沒開的包裡。可能同時在好幾包。
        case inPacks([PackHit])
        /// 都沒有，可以加入我的詞庫。
        case notFound
    }

    static func lookup(_ rawWord: String, in sources: Sources) -> Outcome {
        let word = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
        if word.isEmpty { return .empty }
        if sources.coreWords.contains(word) { return .builtIn(.core) }
        if sources.isInShippedLexicon(word) { return .builtIn(.shipped) }
        if let pack = sources.packs.first(where: { $0.enabled && $0.words.contains(word) }) {
            return .builtIn(.pack(title: pack.title))
        }
        if sources.customWords.contains(word) { return .inCustom }
        let hits = sources.packs
            .filter { !$0.enabled && $0.words.contains(word) }
            .map { PackHit(slug: $0.slug, title: $0.title) }
        return hits.isEmpty ? .notFound : .inPacks(hits)
    }
}

// MARK: - 設定頁文案用的例詞

/// 設定頁每一類附的 3–5 個例詞（不寫詞數）。手挑的常數；`LexiconLookupTests` 守著每個例詞
/// 都真的在對應的檔裡，詞表改動後例詞消失會變紅。
enum LexiconExamples {
    /// 挑選原則：core.txt 裡「一般人不需要專業背景就會打」的詞——不是術語、不是專名、不是罕用詞，
    /// 而且逐字出現在 core.txt（測試守著）。core.txt 本身大半是專業詞，所以這裡是人工挑的。
    static let core = ["公仔", "彩蛋", "手作", "瑜珈", "會議紀錄"]

    private static let byPack: [String: [String]] = [
        "web_slang": ["崩潰", "傻眼", "躺平", "笑死"],
        "science_tech": ["字型檔", "配線", "冪次", "增壓器", "鍍膜"],
        "life_earth": ["筋膜", "脂溶性", "海馬迴", "鯨鯊"],
        "humanities_social": ["法益", "複合弓", "揭弊", "恐嚇取財"],
    ]

    static func words(forPackSlug slug: String) -> [String] {
        byPack[slug] ?? []
    }
}
