// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// 查詞框用到的詞表。每次查詢現讀：core.txt＋各包只有幾千行，毫秒級；出貨詞庫走已掃好的 catalog。
enum MacLexiconLookupInputs {
    static func make(isInShippedLexicon: @escaping (String) -> Bool, customWords: Set<String>) -> LexiconLookup.Sources {
        let core = Set(wordsInFile(slug: "core"))
        let packs = MacDomainPackCatalog.all.map { pack in
            LexiconLookup.PackSource(
                slug: pack.slug,
                title: pack.title,
                words: Set(pack.files.flatMap(wordsInFile(slug:))),
                enabled: MacDomainPackCatalog.isEnabled(pack.slug)
            )
        }
        return LexiconLookup.Sources(
            coreWords: core,
            isInShippedLexicon: isInShippedLexicon,
            customWords: customWords,
            packs: packs
        )
    }

    private static func wordsInFile(slug: String) -> [String] {
        guard let url = MacDomainPackCatalog.fileURL(slug: slug) else { return [] }
        return MacDomainPackCatalog.rows(at: url).map(\.term)
    }
}

/// 詞庫分頁最上面的查詞框。查詢只在按 Enter／按「查詢」時跑（出貨詞庫第一次要掃一遍，放背景執行緒），
/// 不在打字路徑上。加入詞走既有的「自訂詞」路徑（`MacCustomPhrasesModel`），讀音由使用者確認。
@MainActor
@Observable
final class MacLexiconLookupModel {
    var query = ""
    private(set) var outcome: LexiconLookup.Outcome = .empty
    /// `outcome` 是針對哪個詞算的（輸入框之後被改掉時，結果與詞對不上就清掉）。
    private(set) var searchedWord = ""
    private(set) var isAddingPhrase = false
    /// 每次查詢加一；背景查詢回來時代號對不上就丟掉（連按「開啟」、改字再查，舊結果不能蓋新結果）。
    private var searchGeneration = 0
    let phrases: MacCustomPhrasesModel

    init(phrases: MacCustomPhrasesModel? = nil) {
        self.phrases = phrases ?? MacCustomPhrasesModel()
    }

    /// 截圖 harness 用：直接進到某個結果狀態，不查詞庫。產品路徑不呼叫。
    init(previewing outcome: LexiconLookup.Outcome, word: String, adding: Bool = false) {
        let phrases = MacCustomPhrasesModel()
        self.phrases = phrases
        self.query = word
        self.searchedWord = word
        self.outcome = outcome
        if adding {
            phrases.word = word
            phrases.lookupReadings()
            isAddingPhrase = true
        }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    func onAppear() {
        phrases.reload()
    }

    func queryEdited() {
        guard trimmedQuery != searchedWord else { return }
        clearResult()
    }

    private func clearResult() {
        searchGeneration += 1
        outcome = .empty
        searchedWord = ""
        isAddingPhrase = false
        phrases.resetDraft()
    }

    func search() {
        let word = trimmedQuery
        guard !word.isEmpty else {
            clearResult()
            return
        }
        let custom = Set(phrases.entries.map(\.word))
        searchGeneration += 1
        let generation = searchGeneration
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                return LexiconLookup.lookup(
                    word,
                    in: MacLexiconLookupInputs.make(
                        isInShippedLexicon: { MacReadingCatalog.containsSurface($0) }, customWords: custom))
            }.value
            guard let self else { return }
            // 查的途中使用者又改了字、又查了一次：丟掉這個過期的結果。
            guard self.searchGeneration == generation, self.trimmedQuery == word else { return }
            self.searchedWord = word
            self.outcome = result
            // 新結果出來，舊的新增草稿（讀音格子）就作廢，要重新確認讀音。
            self.isAddingPhrase = false
            self.phrases.resetDraft()
        }
    }

    func enablePack(slug: String) {
        UserDefaults.standard.set(true, forKey: MacDomainPackCatalog.defaultsKey(for: slug))
        MacUserPhraseReload.postChange()
        search()
    }

    func beginAdding() {
        // 分頁出現時 `reload()` 可能留下「無法讀取儲存位置」；真的加不進去時 `add()` 會再報一次。
        phrases.status = ""
        phrases.word = searchedWord
        phrases.lookupReadings()
        isAddingPhrase = true
    }

    func cancelAdding() {
        isAddingPhrase = false
        phrases.resetDraft()
    }

    func confirmAdding() {
        phrases.add()
        // `add()` 成功會清掉草稿與狀態；失敗時 `status` 有錯誤句，留在原地讓使用者改讀音。
        guard phrases.status.isEmpty else { return }
        isAddingPhrase = false
        search()
    }
}

struct MacLexiconLookupSection: View {
    @Bindable var model: MacLexiconLookupModel

    var body: some View {
        Section {
            HStack {
                TextField("詞", text: $model.query, prompt: Text("輸入一個詞，看看有沒有"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.search() }
                    .onChange(of: model.query) { _, _ in model.queryEdited() }
                MacLexiconButton("查詢", prominent: true) { model.search() }
            }
            result
        } header: {
            Label("查詞", systemImage: "magnifyingglass")
        } footer: {
            Text("看看某個詞是不是已經打得出來，或要另外開啟哪一類詞庫。")
        }
        .onAppear { model.onAppear() }
    }

    @ViewBuilder
    private var result: some View {
        let word = model.searchedWord
        switch model.outcome {
        case .empty:
            EmptyView()
        case .builtIn(let origin):
            resultLabel(
                symbol: "checkmark.circle.fill", tint: .green,
                title: "「\(word)」已內建",
                detail: builtInDetail(origin))
        case .inCustom:
            resultLabel(
                symbol: "checkmark.circle.fill", tint: .green,
                title: "「\(word)」已在你的詞庫裡",
                detail: "往下捲到「我的自訂詞」可以管理。")
        case .inPacks(let hits):
            ForEach(hits, id: \.slug) { hit in
                HStack(alignment: .firstTextBaseline) {
                    resultLabel(
                        symbol: "arrow.down.circle", tint: .accentColor,
                        title: "「\(word)」在「\(hit.title)」裡",
                        detail: "這一類目前沒開。")
                    Spacer()
                    MacLexiconButton("開啟", prominent: true) { model.enablePack(slug: hit.slug) }
                }
            }
        case .notFound:
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    resultLabel(
                        symbol: "questionmark.circle", tint: .secondary,
                        title: "「\(word)」目前沒有",
                        detail: "內建詞庫和各類詞庫都找不到。")
                    Spacer()
                    if !model.isAddingPhrase {
                        MacLexiconButton("加入我的詞庫", prominent: true) { model.beginAdding() }
                    }
                }
                if model.isAddingPhrase { addingBlock }
            }
        }
    }

    private var addingBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("請確認每個字的讀音；破音字用選單選，查不到的字自己打注音。")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                if #available(macOS 26, *) {
                    GlassEffectContainer(spacing: 12) { slotsRow }
                } else {
                    slotsRow
                }
            }
            if !model.phrases.status.isEmpty {
                Text(model.phrases.status).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                MacLexiconButton("取消", prominent: false) { model.cancelAdding() }
                MacLexiconButton("加入", prominent: true) { model.confirmAdding() }
            }
        }
    }

    private var slotsRow: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Bindable(model.phrases).slots) { $slot in
                MacReadingSlotView(slot: $slot)
            }
        }
        .padding(.vertical, 2)
    }

    private func builtInDetail(_ origin: LexiconLookup.BuiltInOrigin) -> String {
        switch origin {
        case .core, .shipped: return "打字時就能直接選到。"
        case .pack(let title): return "在已開啟的「\(title)」裡。"
        }
    }

    private func resultLabel(symbol: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// 設定頁共用的小按鈕：macOS 26 用玻璃樣式（跟「自訂詞」的「新增」同一套），舊系統退回 bordered。
struct MacLexiconButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void

    init(_ title: String, prominent: Bool, action: @escaping () -> Void) {
        self.title = title
        self.prominent = prominent
        self.action = action
    }

    var body: some View {
        if #available(macOS 26, *) {
            if prominent {
                Button(title, action: action).buttonStyle(.glassProminent)
            } else {
                Button(title, action: action).buttonStyle(.glass)
            }
        } else {
            if prominent {
                Button(title, action: action).buttonStyle(.borderedProminent)
            } else {
                Button(title, action: action).buttonStyle(.bordered)
            }
        }
    }
}
