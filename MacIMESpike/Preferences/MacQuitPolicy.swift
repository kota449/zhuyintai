// SPDX-License-Identifier: Apache-2.0
import Foundation

enum MacQuitDecision: Equatable {
    /// 放行：系統登出／關機／重開，或不認得的原因（寧可結束，也不擋住系統）。
    case terminate
    /// 使用者要求結束：不能靜默結束（輸入法會停掉），也不能靜默取消（使用者按了結束卻沒反應）——跳確認窗，
    /// 說明後果，預設只關設定視窗。
    case askUser
}

/// 輸入法是常駐行程，**使用者想關的是設定視窗，不是輸入法**。
/// 偏好設定開著時我們暫時是 `.regular`（Dock 有圖示、有 Cmd-Q），這兩條路會把整個輸入法結束掉：
/// Dock 右鍵「結束」、設定視窗是 key 時按 Cmd-Q。
///
/// 怎麼分辨使用者與系統：Apple 標頭 `AERegistry.h` 寫明 `kAEQuitApplication` 事件的 `kAEQuitReason`（'why?'）
/// 若存在，值為 `kAEQuitAll`／`kAEShutDown`／`kAERestart`／`kAEReallyLogOut`，也就是系統送來的。
/// Cmd-Q 呼叫 `terminate:` 沒有 Apple event；Dock 右鍵結束的 quit 事件沒有 reason。
/// ⇒ **沒有 reason＝使用者要求**；有 reason＝系統。另外收到 `willPowerOff`（登出／關機／重開）通知也放行，
/// 雙保險：被我們擋下的登出會讓 loginwindow 跳「App 取消了登出」。
///
/// 安裝／更新／解除安裝腳本用 `killall`／`pkill`（SIGTERM），不經過 `applicationShouldTerminate`，不受影響。
enum MacQuitPolicy {
    /// `kAEQuitReason`＝'why?'。
    static let quitReasonKeyword: UInt32 = 0x7768_793F

    static func decide(quitReason: UInt32?, powerOffNoticed: Bool) -> MacQuitDecision {
        if powerOffNoticed { return .terminate }
        // 有 reason 一律放行（含不認得的）：fail-open，擋住系統登出的代價遠大於多結束一次輸入法。
        guard quitReason == nil else { return .terminate }
        return .askUser
    }
}

/// 結束確認窗的文案。使用者 10-08 原話：「按結束的時候它會出現一個視窗說按結束的話會怎麼樣…要有這個機制才可以」。
enum MacQuitConfirmationCopy {
    /// 輸入法被結束後，下次打字到第一個字能組出來的秒數。**實測值**：`python3 tools/mac_cold_start/cold_start_measure.py`，
    /// 5 次全新行程，整個行程牆鐘 p50 0.42 s／max 0.43 s（取 0.4）；檔案快取熱的情況，不含系統啟動 app 與 IMK 連線。
    static let measuredColdStartSeconds = 0.4

    static let title = "要結束注音台嗎？"
    /// 第一個按鈕＝預設（Return）：使用者按結束多半只是想關設定視窗。
    static let onlyCloseSettings = "只關閉設定視窗"
    static let quit = "結束注音台"

    static var message: String {
        let seconds = String(format: "%.1f", measuredColdStartSeconds)
        // 「通常會自動重新啟動」：系統在下次打字時重啟輸入法這件事只有行程冷啟動量過，沒有在實機驗證，不寫成保證。
        return "結束後輸入法會停止，各個 App 暫時打不出注音。下次切到注音台打字時，系統通常會自動重新啟動它，"
            + "第一個字大約會慢約 \(seconds) 秒。只是想關掉設定視窗的話，請選「\(onlyCloseSettings)」。"
    }
}
