// SPDX-License-Identifier: Apache-2.0
// 聲母遮罩（打錯聲母時「這個字有沒有以這個聲母開頭的讀音」）的窄介面。
// 公開版沒有資料 ⇒ 回 `nil`，呼叫端維持原字（與「表缺失」同一條語意）。

import Foundation

protocol MacInitialReadingMaskProviding {
    /// `true`／`false`＝表裡有這個字，而且有／沒有以 `initial` 開頭的讀音；`nil`＝沒有資料。
    func allows(initial: Character, character: Character) -> Bool?
}

struct MacNoInitialReadingMask: MacInitialReadingMaskProviding {
    func allows(initial: Character, character: Character) -> Bool? { nil }
}

enum MacInitialReadingMask {
    static var provider: any MacInitialReadingMaskProviding = {
        #if TWK_CLOSED_CORE
        return TWKClosedCore.makeInitialReadingMask()
        #else
        return MacNoInitialReadingMask()
        #endif
    }()

    static func allows(initial: Character, character: Character) -> Bool? {
        provider.allows(initial: initial, character: character)
    }
}
