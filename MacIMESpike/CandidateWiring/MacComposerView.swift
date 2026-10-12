// SPDX-License-Identifier: Apache-2.0
// 外殼看組字器（Megrez 那一層）的窄介面。
//
// 外殼只需要：目前的 key 序列、游標、組好的句子（每格的 key 與字）、複製一份、從游標處往後刪一個 key。
// 實作在引擎那一側（由 `MacEngineFactory` 注入的引擎提供）。

import Foundation

/// 組好的句子裡的一格（一個詞）。
struct MacComposedGram: Equatable {
    var keyArray: [String]
    var value: String
}

protocol MacComposerView: AnyObject {
    var keys: [String] { get }
    /// 1-based：游標在第幾個 key 之後。可設定（只用在複本上）。
    var cursor: Int { get set }
    var assembledGrams: [MacComposedGram] { get }
    func copy() -> any MacComposerView
    /// 刪掉游標前面的 key（`cursor` 往後退一格）。
    @discardableResult func dropRearKey() -> Bool
}
