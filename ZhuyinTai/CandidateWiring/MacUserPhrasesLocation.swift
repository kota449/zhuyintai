// SPDX-License-Identifier: Apache-2.0
// 自訂詞檔存放位置的窄介面。公開版沒有位置（`nil`）⇒ 設定頁顯示「無法讀取自訂詞的儲存位置」；
// 官方版由 `TWK_CLOSED_CORE` 經 `TWKClosedCore.makeUserPhrasesLocation()` 注入。

import Foundation

protocol MacUserPhrasesLocationProviding {
    /// 容器（沙箱內 App Group／Application Support）。`nil`＝讀不到。
    func platformContainerURL() -> URL?
    func ensureDirectoryExists(inContainer container: URL) -> Bool
    /// 容器底下放自訂詞的資料夾名。
    var libraryDirectoryName: String { get }
}

struct MacNoUserPhrasesLocation: MacUserPhrasesLocationProviding {
    func platformContainerURL() -> URL? { nil }
    func ensureDirectoryExists(inContainer container: URL) -> Bool { false }
    var libraryDirectoryName: String { "Library" }
}

enum MacUserPhrasesLocation {
    static var provider: any MacUserPhrasesLocationProviding = {
        #if TWK_CLOSED_CORE
        return TWKClosedCore.makeUserPhrasesLocation()
        #else
        return MacNoUserPhrasesLocation()
        #endif
    }()

    static func platformContainerURL() -> URL? { provider.platformContainerURL() }
    static func ensureDirectoryExists(inContainer container: URL) -> Bool {
        provider.ensureDirectoryExists(inContainer: container)
    }
    static var libraryDirectoryName: String { provider.libraryDirectoryName }
}
