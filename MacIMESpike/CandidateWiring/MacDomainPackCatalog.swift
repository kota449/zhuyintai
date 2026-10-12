// SPDX-License-Identifier: Apache-2.0
// 領域包清單的窄介面（設定頁用）。只暴露「有哪些包、開關、檔名、詞與讀音」；不含分數。
// 公開版沒有領域包資料 ⇒ 清單是空的，設定頁整區隱藏；官方版由 `TWK_CLOSED_CORE` 注入。

import Foundation

struct MacDomainPackInfo: Identifiable, Equatable {
    var slug: String
    var title: String
    var summary: String
    var files: [String]
    var defaultEnabled: Bool
    var id: String { slug }
}

struct MacDomainPackRow: Equatable {
    var key: String
    var term: String
}

protocol MacDomainPackCatalogProviding {
    var all: [MacDomainPackInfo] { get }
    var webSlangSlug: String { get }
    func defaultsKey(for slug: String) -> String
    func defaultValue(for pack: MacDomainPackInfo) -> Bool
    func isEnabled(_ slug: String) -> Bool
    func fileURL(slug: String) -> URL?
    func rows(at url: URL) -> [MacDomainPackRow]
    func fileTitle(_ file: String) -> String
}

struct MacNoDomainPackCatalog: MacDomainPackCatalogProviding {
    var all: [MacDomainPackInfo] { [] }
    var webSlangSlug: String { "web_slang" }
    func defaultsKey(for slug: String) -> String { "TWKeyboard.domainPack.\(slug)" }
    func defaultValue(for pack: MacDomainPackInfo) -> Bool { pack.defaultEnabled }
    func isEnabled(_ slug: String) -> Bool { false }
    func fileURL(slug: String) -> URL? { nil }
    func rows(at url: URL) -> [MacDomainPackRow] { [] }
    func fileTitle(_ file: String) -> String { file }
}

enum MacDomainPackCatalog {
    static var provider: any MacDomainPackCatalogProviding = {
        #if TWK_CLOSED_CORE
        return TWKClosedCore.makeDomainPackCatalog()
        #else
        return MacNoDomainPackCatalog()
        #endif
    }()

    static var all: [MacDomainPackInfo] { provider.all }
    static var webSlangSlug: String { provider.webSlangSlug }
    static func defaultsKey(for slug: String) -> String { provider.defaultsKey(for: slug) }
    static func defaultValue(for pack: MacDomainPackInfo) -> Bool { provider.defaultValue(for: pack) }
    static func isEnabled(_ slug: String) -> Bool { provider.isEnabled(slug) }
    static func fileURL(slug: String) -> URL? { provider.fileURL(slug: slug) }
    static func rows(at url: URL) -> [MacDomainPackRow] { provider.rows(at: url) }
    static func fileTitle(_ file: String) -> String { provider.fileTitle(file) }
}
