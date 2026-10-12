// SPDX-License-Identifier: Apache-2.0
// TWKeyboard 自寫（不衍生自上游文字）。授權：本專案自己的。
//
// 為什麼需要它：上游 `NSMenuItem.act(_ block:)`（MulanPSL，見
// Upstream/Support/AppKitImpl_NSView_Extract.swift）需要一個 `NSMenuActionTrampoline`
// 當選單項的 target，上游把它寫在另一個 Objective-C target。我們是單一 Swift module、
// 不想為了一個 20 行的類別多開 ObjC target，所以用 Swift 自己寫。
//
// 介面（`init(block:)`、`actionBlock`、`fire(_:)`）完全由上游呼叫點決定：
//   NSMenuActionTrampoline(block: { block(oldBlock) })
//   oldTrampoline?.actionBlock            // 型別是 (() -> ())?
//   #selector(NSMenuActionTrampoline.fire(_:))

import AppKit

final class NSMenuActionTrampoline: NSObject {
    let actionBlock: (() -> ())?

    init(block: @escaping () -> ()) {
        actionBlock = block
        super.init()
    }

    @objc func fire(_: Any?) {
        actionBlock?()
    }
}
