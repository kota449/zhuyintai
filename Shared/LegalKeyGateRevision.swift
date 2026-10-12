// SPDX-License-Identifier: Apache-2.0
import Combine

/// SwiftUI 重新渲染觸發器：`ZhuyinActionHandler` 是 plain class（非 ObservableObject），
/// 鍵盤格（`ZhuyinReferenceKeyboardView`）原本沒有任何 observable 依賴綁到
/// `legalKeyComposer.currentBuffer`，導致 body 只在初始（空緩衝區）渲染時算過一次
/// legalKeyOpacity/雙擊手勢——之後打字合法性完全不會重新反映在畫面上。
///
/// 這個型別本身不攜帶任何合法性資料——真正的資料仍每次都由 `isLegalNextKey(_:)`
/// 現算。它唯一的工作是讓 SwiftUI 在每次 `.bump()` 後重新呼叫 body。
public final class LegalKeyGateRevision: ObservableObject {
    @Published public private(set) var value: Int = 0

    public init() {}

    public func bump() {
        value &+= 1
    }
}
