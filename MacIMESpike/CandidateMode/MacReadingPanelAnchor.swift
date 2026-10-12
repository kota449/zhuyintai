// SPDX-License-Identifier: Apache-2.0
// 注音浮窗要貼在哪：右緣貼齊游標前那個字的右緣（使用者 2026-09-24：
// 浮窗會隨注音多寡變寬變窄，最右邊一定要貼齊最後一個字）。
//
// 🔴 **不要去問「最後那個字」的位置。** 2026-09-24 實機記錄（備忘錄）三版都栽在這：
// - 第 i 格回的是寬 1 的直線、在字的左邊，不是字框；
// - 最後那幾格時有時無：「還是不行ㄧ」第 4 格問不到，「還是不行ㄧㄣ」第 5 格問得到、
//   第 4 格又問不到——等 30ms 再問也一樣；
// ⇒ 每按一鍵在「右貼／左貼」兩種算法之間切換，浮窗亂跳。
// 唯一在每一筆記錄都穩定的是**第 0 格（組字區開頭）**：備忘錄 779、cmux 503。
// 所以右緣＝開頭 ＋ 用客體字型量出游標前那段字的寬度；量不到就老實左貼開頭。
//
// 純邏輯、零 AppKit：開頭矩形與寬度由轉接層量好餵進來。

import CoreGraphics

public enum MacReadingPanelAnchor: Equatable {
    /// 浮窗右緣放在 `x`；`lineRect` 是那一行，決定上下位置。
    case rightEdge(x: CGFloat, lineRect: CGRect)
    /// 右緣不可知（客體沒給字型）：浮窗左緣貼 `x`（組字區開頭）。
    case leftEdge(x: CGFloat, lineRect: CGRect)
    /// 開頭都問不到：不顯示。
    case unknown

    /// - Parameters:
    ///   - start: 客體第 0 格的矩形；問不到是原點 (0,0)（小麥注音 `InputMethodController.swift:893` 同一判準）。
    ///   - prefixWidth: 組字區開頭到最後一個要對齊的字為止的寬度；量不到給 `nil`。
    public static func resolve(start: CGRect, prefixWidth: CGFloat?) -> MacReadingPanelAnchor {
        guard start.origin != .zero else { return .unknown }
        guard let prefixWidth, prefixWidth > 0 else {
            return .leftEdge(x: start.minX, lineRect: start)
        }
        return .rightEdge(x: start.minX + prefixWidth, lineRect: start)
    }
}
