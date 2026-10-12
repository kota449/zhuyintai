// SPDX-License-Identifier: Apache-2.0
// 「被嗶掉的鍵要不要救」的策略介面。
//
// 狀態機（`MacCandidateModeMachine`）遇到兩種情形會問這個策略：
//   ・組音器判定 `.reject`（原本會嗶）⇒ `rescueRejected`
//   ・組音器判定 `.startNew` 且前一個音節以韻母結尾 ⇒ `replaceAdjacentFinal`
// 策略只回答「要換成什麼」，不碰狀態機的狀態；套用（引擎送什麼、緩衝區怎麼變）一律在狀態機裡，
// 所以不論換哪個策略，效果清單與狀態轉移的形狀都不變。
//
// 公開版（`MacNoKeyRescue`）兩個入口都回 `nil`：該嗶就嗶、該切音節就切。
// 建置旗標 `TWK_CLOSED_CORE` 啟用時，策略實作由 `MacKeyRescueFactory` 注入。

import Foundation

/// `rescueRejected` 的回答。
public enum MacKeyRescueAction: Equatable {
    /// 當成使用者按的是這一鍵（狀態機照一般注音鍵處理）。
    case pressInstead(Character)
    /// 把目前緩衝區整串換成這個字串。
    case replaceBuffer(String)
    /// 吃掉這一鍵：不嗶、不動緩衝區。
    case swallow
}

public protocol MacKeyRescuePolicy {
    /// `symbol` 被組音器判定 `.reject`。回 `nil` ⇒ 不救，狀態機嗶。
    /// `composer` 是呼叫當下組音器的值拷貝，策略可以任意 `reopen`／`decision` 試探。
    func rescueRejected(
        _ symbol: Character, composer: LegalKeySyllableComposer
    ) -> MacKeyRescueAction?

    /// 組音器對 `symbol` 判定 `.startNew`（會切新音節）。回非 `nil` ⇒ 改成把緩衝區換成該字串、
    /// 不切新音節。`previous` 是切之前的緩衝區。
    func replaceAdjacentFinal(
        previous: String, symbol: Character, composer: LegalKeySyllableComposer
    ) -> String?
}

/// 公開版預設：不救援。
public struct MacNoKeyRescue: MacKeyRescuePolicy {
    public init() {}

    public func rescueRejected(
        _ symbol: Character, composer: LegalKeySyllableComposer
    ) -> MacKeyRescueAction? { nil }

    public func replaceAdjacentFinal(
        previous: String, symbol: Character, composer: LegalKeySyllableComposer
    ) -> String? { nil }
}

/// 預設策略的唯一出口。`TWK_CLOSED_CORE` 只在官方建置帶；公開樹沒有 `TWKClosedCore`，
/// 這段 `#if` 在公開樹裡不會被編到。
public enum MacKeyRescueFactory {
    public static func make() -> any MacKeyRescuePolicy {
        #if TWK_CLOSED_CORE
        return TWKClosedCore.makeKeyRescuePolicy()
        #else
        return MacNoKeyRescue()
        #endif
    }
}
