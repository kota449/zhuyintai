// SPDX-License-Identifier: Apache-2.0
// 詞庫讀音目錄的窄介面（設定頁：新增自訂詞時預選破音字讀音、查詞框問「出貨詞庫有沒有這個詞」）。
// 公開版沒有目錄：查不到任何讀音（使用者手打）、出貨詞庫一律「沒有」；官方版由 `TWK_CLOSED_CORE` 注入。

import Foundation

protocol MacReadingCatalogProviding {
    func choices(for word: String) -> [MacLexiconReadingChoice]
    func containsSurface(_ word: String) -> Bool
}

struct MacNoReadingCatalog: MacReadingCatalogProviding {
    func choices(for word: String) -> [MacLexiconReadingChoice] {
        word.map { MacLexiconReadingChoice(character: $0, readings: [], preferred: nil) }
    }

    func containsSurface(_ word: String) -> Bool { false }
}

enum MacReadingCatalog {
    static var provider: any MacReadingCatalogProviding = {
        #if TWK_CLOSED_CORE
        return TWKClosedCore.makeReadingCatalog()
        #else
        return MacNoReadingCatalog()
        #endif
    }()

    static func choices(for word: String) -> [MacLexiconReadingChoice] { provider.choices(for: word) }
    static func containsSurface(_ word: String) -> Bool { provider.containsSurface(word) }
}
