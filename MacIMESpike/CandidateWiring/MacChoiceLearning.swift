// SPDX-License-Identifier: Apache-2.0
// 選字學習的窄介面。公開版沒有選字學習（`MacNoChoiceLearning`），設定頁隱藏相關開關；
// 官方版由 `TWK_CLOSED_CORE` 經 `TWKClosedCore.makeChoiceLearning()` 注入。
// 把學習層接到引擎走 `MacZhuyinEnginePort.refreshChoiceLearning()`，不經這裡。

import Foundation

protocol MacChoiceLearningProviding {
    /// 這個建置有沒有選字學習。
    var isAvailable: Bool { get }
    /// 落檔（去抖之外的保險）。
    func flush()
    /// 忘掉所有已記住的選字。
    func clearAll()
}

struct MacNoChoiceLearning: MacChoiceLearningProviding {
    var isAvailable: Bool { false }
    func flush() {}
    func clearAll() {}
}

enum MacChoiceLearning {
    /// 開關的 `UserDefaults` key。必須與注入端（`TWK_CLOSED_CORE` 建置）用的同名常數一致。
    static let enabledDefaultsKey = "TWKeyboard.choiceLearningEnabled"

    static var provider: any MacChoiceLearningProviding = {
        #if TWK_CLOSED_CORE
        return TWKClosedCore.makeChoiceLearning()
        #else
        return MacNoChoiceLearning()
        #endif
    }()

    static var isAvailable: Bool { provider.isAvailable }
    static func flush() { provider.flush() }
    static func clearAll() { provider.clearAll() }
}
