// SPDX-License-Identifier: Apache-2.0
// 引擎的唯一出口。`TWK_CLOSED_CORE` 只在官方建置帶；公開樹沒有 `TWKClosedCore`。
// 公開版的 `#else` 直接寫 `BasicEngine()`：基本引擎（S3'）寫好之前公開樹編不過——
// 編譯錯誤擋得住，執行期崩潰擋不住。

import Foundation

enum MacEngineFactory {
    static func make() -> any MacZhuyinEnginePort {
        #if TWK_CLOSED_CORE
        return TWKClosedCore.makeEngine()
        #else
        return BasicEngine()
        #endif
    }
}
