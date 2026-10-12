// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// 詞庫分頁的詞庫類別。漸進式：先看到三個大類（日常、網路用語、專業領域），不寫詞數、每類附幾個例詞；
/// 點開「專業領域」才看到細項開關；完整詞表收在最裡層的「看全部」。
/// 原生 Form section，不自訂顏色、不自畫背景。開關的 id 與預設值都沿用 `MacDomainPackCatalog.all`。
struct MacDomainPackSection: View {
    @Binding var professionalExpanded: Bool
    @State private var listRequest: MacWordListRequest?

    private var webSlang: MacDomainPackInfo? { MacDomainPackCatalog.all.first { $0.slug == MacDomainPackCatalog.webSlangSlug } }
    private var professional: [MacDomainPackInfo] { MacDomainPackCatalog.all.filter { $0.slug != MacDomainPackCatalog.webSlangSlug } }

    var body: some View {
        Section {
            MacCoreRow()
            if let webSlang {
                MacDomainPackToggle(pack: webSlang) { listRequest = MacWordListRequest(pack: webSlang) }
            }
            DisclosureGroup(isExpanded: $professionalExpanded) {
                ForEach(professional) { pack in
                    MacDomainPackToggle(pack: pack) { listRequest = MacWordListRequest(pack: pack) }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("專業領域")
                    Text("理工、生醫、人文社會藝術等。展開後可以分別開關。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Label("詞庫", systemImage: "books.vertical")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("日常一律開啟。網路用語預設開啟，專業領域預設關閉。")
                Text("開啟後會加入該領域的專業詞，打字時就能直接選到。")
            }
        }
        .sheet(item: $listRequest) { request in
            MacWordListSheet(request: request)
        }
    }
}

private func exampleLine(_ words: [String]) -> some View {
    Text("例：" + words.joined(separator: "、"))
        .font(.caption)
        .foregroundStyle(.secondary)
}

/// 「日常」：出貨詞庫（含 core.txt），永遠載入、沒有開關，所以只標「一律開啟」。
/// 不放「看全部詞表」：內建詞庫有十幾萬詞列不完，要確認某個詞就用上面的查詞框。
private struct MacCoreRow: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("日常")
                Text("內建詞庫，日常打字用到的詞。要確認某個詞有沒有，用上面的查詞框。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                exampleLine(LexiconExamples.core)
            }
            Spacer()
            Text("一律開啟")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct MacDomainPackToggle: View {
    let pack: MacDomainPackInfo
    let seeAll: () -> Void
    @AppStorage private var enabled: Bool

    init(pack: MacDomainPackInfo, seeAll: @escaping () -> Void) {
        self.pack = pack
        self.seeAll = seeAll
        _enabled = AppStorage(wrappedValue: MacDomainPackCatalog.defaultValue(for: pack), MacDomainPackCatalog.defaultsKey(for: pack.slug))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pack.title)
                    Text(pack.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    exampleLine(LexiconExamples.words(forPackSlug: pack.slug))
                }
            }
            Button("看全部詞表…", action: seeAll)
                .buttonStyle(.link)
                .font(.caption)
        }
        .onChange(of: enabled) { _, _ in
            MacUserPhraseReload.postChange()
        }
    }
}

// MARK: - 看全部

struct MacWordListRequest: Identifiable {
    let id = UUID()
    var title: String
    var files: [String]

    init(title: String, files: [String]) {
        self.title = title
        self.files = files
    }

    init(pack: MacDomainPackInfo) {
        self.init(title: pack.title, files: pack.files)
    }
}

/// 最裡層：一類的完整詞表，依出貨檔分段。不顯示詞數。
struct MacWordListSheet: View {
    let request: MacWordListRequest
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""
    @State private var sections: [Section] = []

    struct Entry: Identifiable {
        var term: String
        var readings: [String]
        var id: String { term }
    }

    struct Section: Identifiable {
        var title: String
        var entries: [Entry]
        var id: String { title }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(request.title).font(.headline)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .top], 16)
            TextField("找詞或注音", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(16)
            List {
                ForEach(filtered) { section in
                    SwiftUI.Section(section.title) {
                        ForEach(section.entries) { entry in
                            LabeledContent(entry.term, value: entry.readings.joined(separator: "　"))
                        }
                    }
                }
            }
        }
        .frame(minWidth: 440, minHeight: 520)
        .task { sections = Self.load(files: request.files) }
    }

    private var filtered: [Section] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return sections }
        return sections.compactMap { section in
            let entries = section.entries.filter { entry in
                entry.term.contains(needle) || entry.readings.contains { $0.contains(needle) }
            }
            return entries.isEmpty ? nil : Section(title: section.title, entries: entries)
        }
    }

    /// 同一個詞的多個讀音併成一列。
    static func load(files: [String]) -> [Section] {
        files.compactMap { file in
            guard let url = MacDomainPackCatalog.fileURL(slug: file) else { return nil }
            var order: [String] = []
            var readings: [String: [String]] = [:]
            for row in MacDomainPackCatalog.rows(at: url) {
                if readings[row.term] == nil { order.append(row.term) }
                if !(readings[row.term] ?? []).contains(row.key) { readings[row.term, default: []].append(row.key) }
            }
            return Section(
                title: MacDomainPackCatalog.fileTitle(file),
                entries: order.map { Entry(term: $0, readings: readings[$0] ?? []) })
        }
    }
}
