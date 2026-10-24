// SPDX-License-Identifier: Apache-2.0
/// backspace 該做什麼的決策，抽成 pure function。
///
/// 為什麼不留在 `ZhuyinActionHandler`：那個型別在 `keyboard/` extension target，沒有
/// unit test target（專案規範禁止 `@testable import keyboard`）。這個決策
/// 只吃 (組音緩衝區, 組字區最後一個音節) 兩個字串，抽出來就測得到——跟 keyboard
/// extension 其他純決策函式的既有作法一致。
///
/// **A9 audit（2026-08-10）**：「退回單位＝使用者按過的鍵」這條規範是否每個分支都
/// 對照過？
/// - `.shrinkBuffer`／`.reopenTail`（成功路徑）：只動正在拼或正要重開的那一個音節
///   本身，沒有跨到「後面那個音節」，不會踩到這個坑。
/// - `.dropTail`／`.dropTailAndReopenPrevious`：會，見下方 `plan()` 註解——這是
///   A9 真正的根因分支。
/// - `.reopenTail` 的引擎拒絕 fallback（`ZhuyinActionHandler.handleLegalKeyBackspace`
///   裡 `engine.replaceLastKey` 失敗、退而求其次 `engine.backspace()` 整個砍掉那段）：
///   後果跟 `.dropTail` 一樣是「當前音節整個消失、後面音節裸露」，呼叫端已經套用同一條
///   `previousEngineTail`／`isSealed` 判斷（見該檔案），不是這個 pure function 的
///   case，因為它是「plan 判對了、引擎執行時才失敗」的 call-site 專屬防禦分支，
///   不是輸入決定的。
/// - `.deleteFromDocument`：組字區已空，沒有音節可跨，不適用。
public enum LegalKeyBackspacePlan: Equatable {
    /// 正在拼的音節退一個符號，緩衝區縮短成 `to`。
    case shrinkBuffer(to: String)
    /// **已經用聲調收尾**的音節重新打開，退掉最後一個符號，`to` 回到緩衝區繼續拼。
    case reopenTail(to: String)
    /// 組字區最後一個音節整個退掉（它只剩一個符號，沒得再退）。
    case dropTail
    /// 跟 `dropTail` 一樣整個退掉最後一個音節，但它後面那個音節（`to`）從未被
    /// 使用者真正收尾（無聲調、無 implicit-first-tone 標記，只是 `start-new`
    /// 自動 flush 進引擎）——連同它一起重新打開放回緩衝區，不能留在引擎裡變成
    /// 一個獨立音節（A9：見本檔案下方 `plan()` 註解）。
    case dropTailAndReopenPrevious(to: String)
    /// 組字區已空，往文件本身刪。
    case deleteFromDocument

    /// - Parameters:
    ///   - buffer: `LegalKeySyllableComposer.currentBuffer`，正在拼的音節（不含聲調）。
    ///   - engineTail: `compositor.keys.last`，組字區最後一個音節（可能含聲調）。
    ///   - previousEngineTail: 組字區倒數第二個音節（`dropTail` 真正砍掉
    ///     `engineTail` 之後，它會變成新的尾端）。沒有就傳 `nil`。
    ///   - previousEngineTailIsSealed: `previousEngineTail` 是否已經被使用者真正
    ///     收尾（有聲調符號，或引擎記著它的 implicit-first-tone 標記）。呼叫端用
    ///     `ZhuyinEngine.isSealed(key:atKeyCount:)` 算，這裡不重新驗證。
    ///
    /// **`reopenTail` 是 2026-08-06 補的**。在那之前緩衝區空時一律 `dropTail`，
    /// 而聲調鍵會把整個音節收成引擎裡的**一個 key**——使用者打完 `ㄋㄧˇ` 發現注音
    /// 打錯，按一下 backspace 三個符號一起不見，只能整個重打（打錯一個符號卻要整個刪掉重打，體驗很差）。
    ///
    /// 退回去的音節重新回到緩衝區，所以接下來的行為跟「還在拼」完全一樣——
    /// 可以繼續補符號、可以再按聲調、也可以繼續往前退。
    ///
    /// **`dropTailAndReopenPrevious` 是 2026-08-10 補的（A9）**：`.dropTail` 這條
    /// 分支原本從來不管它後面那個音節有沒有被收尾過。`ㄉㄨ` 打完 `ㄞ`（非法組合）
    /// 觸發 `start-new`，`ㄉㄨ` 被自動 flush 成引擎裡的獨立 key——但這只是引擎的
    /// 內部表示法，使用者從沒替它按過聲調或空白鍵。專案規範的規則
    /// 「backspace 的刪除單位是使用者按下的那一個符號」套上去：退掉 `ㄞ` 這個
    /// 動作,應該完整復原到「剛打完 ㄨ」那一刻的狀態——`ㄉㄨ` 還在拼，不是已經
    /// 收尾的獨立音節。所以退掉 `ㄞ` 的同時，如果後面那個音節從未被真正收尾,
    /// 要把它一併放回緩衝區。
    public static func plan(
        buffer: String,
        engineTail: String?,
        previousEngineTail: String? = nil,
        previousEngineTailIsSealed: Bool = true
    ) -> Self {
        let base: Self = {
            guard buffer.isEmpty else {
                let reduced = String(buffer.dropLast())
                // 縮到空表示這個音節在組字區的 key 也該一起消失，否則引擎會留下
                // 一個沒有緩衝區對應的孤兒鍵。
                return reduced.isEmpty ? .dropTail : .shrinkBuffer(to: reduced)
            }
            guard let tail = engineTail, !tail.isEmpty else { return .deleteFromDocument }
            let reduced = String(tail.dropLast())
            return reduced.isEmpty ? .dropTail : .reopenTail(to: reduced)
        }()
        guard case .dropTail = base,
              let previous = previousEngineTail, !previous.isEmpty,
              !previousEngineTailIsSealed
        else { return base }
        return .dropTailAndReopenPrevious(to: previous)
    }
}
