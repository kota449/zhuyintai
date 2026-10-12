// SPDX-License-Identifier: Apache-2.0
// 候選窗在 session 眼中的樣子。
//
// 🔴 **這個 protocol 存在的唯一理由，是讓 `MacClientSession` 能在 headless 下被測。**
// 不是為了抽象而抽象——請不要因為「只有一個實作」就把它拆掉。
//
// 背景（2026-09-21）：使用者的原話是
// 「照理來說這個應該都會有一些紅綠燈測試 TDD 來去搞定這些東西啊，
//   其實我覺得很多東西應該是不需要我測才對」。
// 維護者數過：`MacClientSession` 483 行、實機 bug 全部出在它裡面，而它在 1,029 行測試裡
// **出現 0 次**。原因很具體——它直接 new 了一個 `NSPanel`（上游候選窗），
// 純 swiftc 的 headless CLI 建不起來，於是整個 session 層無法被測。
//
// 把窗換成這個 protocol 之後，測試可以塞一個假的實作進去，
// 於是「按了什麼鍵 → 畫面上實際顯示什麼」終於可以在**不裝上機器、不用人按鍵**的
// 情況下被斷言。那是這一輪所有顯示 bug（重複顯示、洞 A／洞 B、unsealed 音節變漢字）
// 之所以能被逐一釘住的前提。
//
// 成員取自 `CtlCandidateProtocol` 裡 session 真正會用到的那些（spec §8.2）；
// 其餘（`currentLayout`／`appearanceOverride`／`expanded`／`currentMenu`…）v1 不用，不列。

import Foundation

@MainActor
protocol MacCandidateWindowPresenting: AnyObject {
    /// 資料來源與事件回報對象。進入 `Selecting` 前指向該 client 的 session。
    var delegate: CtlCandidateDelegate? { get set }
    /// 窗開著沒有。`false → true` 會通知 delegate 高亮 0。
    var visible: Bool { get set }
    /// 目前高亮的**全域**候選 index（窗為準；確認時才單向寫進引擎）。
    var highlightedIndex: Int { get set }

    func reloadData()

    /// 🔴 回傳值的語意見 spec §5：越界時**回 `false` 但高亮已經跳到另一端**。
    /// 它只能拿來決定要不要嗶，**不可以**直接當成 IMK 的「這個鍵我有沒有吃掉」回傳。
    @discardableResult func showNextPage() -> Bool
    @discardableResult func showPreviousPage() -> Bool
    @discardableResult func showNextLine() -> Bool
    @discardableResult func showPreviousLine() -> Bool
    @discardableResult func highlightNextCandidate() -> Bool
    @discardableResult func highlightPreviousCandidate() -> Bool

    /// 把「按下第 N 個選字鍵」轉成全域候選 index；**超出本頁回 `nil`**
    ///（那時 spec §4.4 要求「吃掉＋嗶」而且**窗不關**）。
    func candidateIndexAtKeyLabelIndex(_ id: Int) -> Int?
}

// 上游控制器本來就有這些成員，直接宣告遵從即可（零行為改動）。
extension GSI4AppKit.CtlCandidateGSI4AppKit: MacCandidateWindowPresenting {}
