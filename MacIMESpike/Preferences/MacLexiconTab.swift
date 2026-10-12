// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// 詞庫頁由上到下的區塊。順序就是頁面順序（`MacLexiconTab.body` 照這個迭代）。
enum MacLexiconSection: String, CaseIterable, Identifiable {
    /// 查詞框。
    case lookup
    /// 詞庫包（日常／網路用語／專業領域）。
    case packs
    /// 我的自訂詞（新增列＋已新增的詞）。
    case phrases

    var id: String { rawValue }

    /// 實際要顯示的區塊（順序不變）。沒有領域包資料（公開版）時詞庫包整區不顯示：
    /// 否則會出現只有空的「專業領域」群組、和承諾了卻不存在的開關。官方版 `packsAvailable` 為 true，結果與 `allCases` 相同。
    static func visible(packsAvailable: Bool) -> [MacLexiconSection] {
        allCases.filter { packsAvailable || $0 != .packs }
    }
}

/// 「詞庫」分頁：一頁往下捲。最上面查詞框，中間是漸進式的詞庫類別開關，最下面是我的自訂詞。
struct MacLexiconTab: View {
    @State private var lookup: MacLexiconLookupModel
    @State private var professionalExpanded: Bool
    @State private var customPhrases: MacCustomPhrasesModel

    /// 截圖 harness 要預填查詞狀態、展開專業領域、預填自訂詞時才傳參數；產品路徑不傳。
    @MainActor
    init(
        lookup: MacLexiconLookupModel? = nil,
        professionalExpanded: Bool = false,
        customPhrases: MacCustomPhrasesModel? = nil
    ) {
        _lookup = State(initialValue: lookup ?? MacLexiconLookupModel())
        _professionalExpanded = State(initialValue: professionalExpanded)
        _customPhrases = State(initialValue: customPhrases ?? MacCustomPhrasesModel())
    }

    var body: some View {
        Form {
            ForEach(MacLexiconSection.visible(packsAvailable: !MacDomainPackCatalog.all.isEmpty)) { section in
                switch section {
                case .lookup:
                    MacLexiconLookupSection(model: lookup)
                case .packs:
                    MacDomainPackSection(professionalExpanded: $professionalExpanded)
                case .phrases:
                    MacCustomPhrasesSection(model: customPhrases)
                }
            }
        }
        .formStyle(.grouped)
    }
}
