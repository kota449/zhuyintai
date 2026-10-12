// SPDX-License-Identifier: Apache-2.0
// 英文模式提示：單押 Shift 切到英文後，游標旁常駐一個小「英」，切回中文才消失。
//
// 2026-10-08 使用者原話：「切換英文模式時後要出現提示然使用者不會一意識到切到英文模式」；
// 外觀選定「英文期間一直顯示」（不是閃一下）。
//
// 這個檔案只放「session 眼中的浮標」（協定）、行程單例的取用點與位置的純邏輯；
// 畫出來的視窗在 `MacEnglishIndicatorPanel.swift`。理由同 `MacCandidateWindowPresenting`：
// 讓 `MacClientSession` 的顯示／隱藏時機能在 headless 下被劇本斷言。

import AppKit

@MainActor
protocol MacEnglishIndicatorPresenting: AnyObject {
    /// 在 `caretRect`（宿主回報的游標行矩形，螢幕座標）旁顯示。`owner` 是發出這次顯示的 session。
    func show(caretRect: NSRect, owner: AnyObject)
    /// `owner` 非 nil ⇒ 只有目前的擁有者就是它才藏（IMK 的 activate／deactivate 沒有時序保證：
    /// B 先 activate、A 才 deactivate 時，A 不得把 B 剛顯示的浮標藏掉）。nil ⇒ 無條件藏（語言切回中文）。
    func hide(owner: AnyObject?)
}

@MainActor
enum MacEnglishIndicator {
    /// 行程唯一的浮標。劇本換成假的；生產路徑用真視窗（第一次 `show` 才建）。
    static var current: MacEnglishIndicatorPresenting = MacEnglishIndicatorPanel.shared

    private static let languageObserver: Void = {
        MacInputModeState.onLanguageChange = { _, new in
            // 所有「英 → 中」的路徑（單押 Shift、關掉單押開關、切到別的輸入方式）都經過語言 setter，
            // 在這裡統一藏起來，比每條路徑各藏一次不會漏。
            guard new == .zh else { return }
            MainActor.assumeIsolated { MacEnglishIndicator.current.hide(owner: nil) }
        }
    }()

    /// 把「語言變回中文就藏浮標」接上。冪等；`MacClientSession.init` 呼叫。
    static func installLanguageObserver() { _ = languageObserver }
}

/// `hide(owner:)` 的擁有者規則（真視窗與劇本的假浮標共用，免得兩邊各寫一份而劇本替 bug 說謊）。
enum MacEnglishIndicatorOwnership {
    /// - Parameters:
    ///   - requested: 發出 hide 的 session；nil ＝ 無條件藏（語言切回中文）。
    ///   - current: 目前顯示中浮標的擁有者（弱引用，session 釋放後是 nil）。
    /// - Returns: 只在「有一個還活著、而且不是 `requested`」的擁有者時才不藏（遲到的 deactivate 不得藏掉新擁有者）；
    ///   擁有者已釋放（nil）＝孤兒浮標，要藏。
    static func shouldHide(requested: AnyObject?, current: AnyObject?) -> Bool {
        guard let requested, let current else { return true }
        return requested === current
    }
}

/// 浮標放哪裡（純函式，劇本直接測）。
enum MacEnglishIndicatorPlacement {
    /// 游標在哪一個螢幕：用游標矩形的**中點**判斷，不用「矩形相交」。游標矩形寬度常是 0（游標線），
    /// 跨螢幕邊界時相交可能兩邊都算或都不算；中點只會落在一個螢幕。都不在 ⇒ `nil`（呼叫端退回主螢幕）。
    static func screenIndex(containing caretRect: NSRect, frames: [NSRect]) -> Int? {
        let center = NSPoint(x: caretRect.midX, y: caretRect.midY)
        return frames.firstIndex { $0.contains(center) }
    }

    /// 游標行矩形的右下方，不蓋住剛打的字（字在游標左邊、同一行）。底下放不下就翻到那一行上方；左右夾在螢幕內。
    /// - Returns: 視窗左下角；`caretRect` 是零矩形（宿主給不出位置）⇒ `nil`，呼叫端要藏起來而不是亂放。
    static func origin(caretRect: NSRect, size: NSSize, visibleFrame: NSRect) -> NSPoint? {
        // 高度為 0 ＝ 宿主沒給（零矩形）。寬度 0 是常態（游標線），不能拿來判斷。
        guard caretRect.height > 0 else { return nil }
        let gapX: CGFloat = 4
        let gapY: CGFloat = 2
        var origin = NSPoint(x: caretRect.maxX + gapX, y: caretRect.minY - gapY - size.height)
        if origin.y < visibleFrame.minY {
            origin.y = caretRect.maxY + gapY
        }
        origin.x = min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - size.width)
        origin.y = min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - size.height)
        return origin
    }
}
