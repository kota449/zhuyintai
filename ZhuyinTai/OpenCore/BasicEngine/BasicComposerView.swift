// SPDX-License-Identifier: Apache-2.0
// Megrez 組字器的窄檢視，給顯示層複製、挖掉未收尾的 key。

#if canImport(Megrez)
import Megrez
#endif
import Foundation

final class BasicComposerView: MacComposerView {
    private let compositor: Megrez.Compositor

    init(compositor: Megrez.Compositor) {
        self.compositor = compositor
    }

    var keys: [String] { compositor.keys }

    var cursor: Int {
        get { compositor.cursor }
        set { compositor.cursor = newValue }
    }

    var assembledGrams: [MacComposedGram] {
        compositor.assembledSentence.map {
            MacComposedGram(keyArray: $0.keyArray, value: $0.value)
        }
    }

    func copy() -> any MacComposerView {
        BasicComposerView(compositor: compositor.copy)
    }

    @discardableResult
    func dropRearKey() -> Bool {
        compositor.dropKey(direction: .rear)
    }
}
