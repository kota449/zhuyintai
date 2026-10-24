// SPDX-License-Identifier: Apache-2.0
// G6 中英切換：切換事件 → 新的語言 ＋「切走時組字怎麼辦」的決定。純函式，不碰 IMK。
//
// ✅ 產品決策（有些人需要快速切英文，設定裡應可開關）：**單押 Shift 切英文，預設開**；離開中文時組字 `.commit`
// （完整音節照舊上屏，殘段照「沒拼完的注音」三選一，見 `MacUnfinishedZhuyin.swift`）。
// 出貨路徑的設定在 `MacClientSession.switchLanguageFromShiftTap`；這裡仍只把「選項空間」做成資料，
// 沒有 `default`／`recommended` 常數——預設值的唯一正本是 `MacTypingPreferences`。
// ⚠️ 其他切換鍵（controlSpace／jisEisu）與 `.discard` 仍未定案，不要順手啟用。
//
// ⚠️ 要分清兩條路（都是「切到英文」，但機制不同）：
//   • 系統層：Caps Lock（系統設定「用大寫鎖定鍵切換」）／Ctrl+Space（上一個輸入方式）**切的是輸入方式**
//     ＝ 整個換成 ABC。IME 不需要實作切換，只要在 `deactivateServer`／`commitComposition` 時把組字上屏
//     （現行 controller 已有）。`Info.plist` 的 `TICapsLockLanguageSwitchCapable = true` 就是在申報這條路——
//     Apple 自己的內建注音也宣告了同一個鍵。**宣告 ≠ 已驗證能用**（見 spec 實機清單）。
//   • IME 內：IME 自己維護 `Language`，`en` 時放行所有鍵。需要處理 `flagsChanged` 事件（Shift 單押）
//     ＝ 要走 `handle(_:client:)`，跟狀態機的事件入口決定連動；還會多一份 per-client 狀態（G8）。
// 本檔的函式服務第二條路；第一條路不需要它。

import Foundation

extension MacInputTables {
    /// 切換的觸發方式（候選鍵）。
    public enum SwitchKind: Hashable, CaseIterable {
        case shiftTap  // 單押 Shift（vChewing 有；Apple 內建注音沒有）
        case capsLock  // Caps Lock 鎖定狀態（McBopomofo／libchewing／vChewing 有；系統層也有同名功能）
        case controlSpace  // ⚠️ 與系統「上一個輸入方式」預設快捷鍵重疊；系統會先吃掉（推論，未驗證）
        case jisEisu  // JIS 鍵盤的「英數」鍵（vChewing 有）
    }

    public enum SwitchEvent: Equatable {
        case shiftTap
        case controlSpace
        case jisEisu
        /// Caps Lock 是**鎖定狀態**（level-triggered）：亮＝英文、滅＝中文；不是每按一下翻一次。
        case capsLock(isOn: Bool)

        var kind: SwitchKind {
            switch self {
            case .shiftTap: return .shiftTap
            case .controlSpace: return .controlSpace
            case .jisEisu: return .jisEisu
            case .capsLock: return .capsLock
            }
        }
    }

    /// 由中文切走時，還沒送出的組字怎麼處置。
    public enum ComposingPolicy: Equatable {
        case commit  // 上屏（McBopomofo 切 Caps Lock 時上屏；iOS 打標點時也是先上屏——2026-08-09 資料遺失事故）
        case discard  // 取消（vChewing 有這個選項）
    }

    /// 切換當下要對組字做什麼。
    public enum ComposingDisposition: Equatable {
        case none
        case commit
        case discard
    }

    public struct SwitchConfig: Equatable {
        public var enabled: Set<SwitchKind>
        public var onLeavingChinese: ComposingPolicy

        public init(enabled: Set<SwitchKind>, onLeavingChinese: ComposingPolicy) {
            self.enabled = enabled
            self.onLeavingChinese = onLeavingChinese
        }
    }

    public struct SwitchOutcome: Equatable {
        public let language: Language
        public let composing: ComposingDisposition

        public init(language: Language, composing: ComposingDisposition) {
            self.language = language
            self.composing = composing
        }
    }

    /// 收到切換事件時：新的語言，以及組字要怎麼處置。
    ///
    /// - 事件種類沒被 `config.enabled` 啟用 ⇒ 什麼都不發生（**連組字都不動**）。
    /// - 沒有實際換語言（例如已是 `en` 又收到 Caps Lock 亮）⇒ 組字也不動。
    /// - 只有「中文 → 英文」且正在組字時才需要處置；英文 → 中文不會有組字（`en` 時窗與組字都不存在）。
    public static func switchLanguage(
        from current: Language, event: SwitchEvent, isComposing: Bool, config: SwitchConfig
    ) -> SwitchOutcome {
        let unchanged = SwitchOutcome(language: current, composing: .none)
        guard config.enabled.contains(event.kind) else { return unchanged }

        let target: Language
        switch event {
        case .capsLock(let isOn): target = isOn ? .en : .zh
        case .shiftTap, .controlSpace, .jisEisu: target = current == .zh ? .en : .zh
        }
        guard target != current else { return unchanged }

        guard current == .zh, isComposing else { return SwitchOutcome(language: target, composing: .none) }
        let disposition: ComposingDisposition = config.onLeavingChinese == .commit ? .commit : .discard
        return SwitchOutcome(language: target, composing: disposition)
    }

    /// 「單押 Shift」偵測：Shift 按下、放開，中間沒有任何其他鍵（含其他修飾鍵）。
    ///
    /// 為什麼要獨立成純狀態機：Shift 同時是「打大寫」與「切換」的鍵，誤觸（打 `Shift+A` 結果切了語言）
    /// 是這個方案最大的風險，所以判斷規則要能被逐條測試。
    ///
    /// ⚠️ **刻意沒有時間門檻**：我沒有找到任何參考實作公開它用多少毫秒，不憑空給數字。
    /// 若實機發現「按住 Shift 想很久再放開」也會誤觸，再補（spec Q-L3）。
    public struct ShiftTapDetector: Equatable {
        public enum Input: Equatable {
            case shiftDown
            case shiftUp
            /// 任何非 Shift 的按鍵事件（含其他修飾鍵按下）。
            case otherKeyDown
        }

        private var isShiftHeld = false
        private var stillATap = false

        public init() {}

        /// 餵入一個事件；回傳 `true` ＝ 這次 `shiftUp` 構成一次單押。
        public mutating func feed(_ input: Input) -> Bool {
            switch input {
            case .shiftDown:
                // 已經按著時再收到 shiftDown（被取消後）不可重新武裝，必須等放開。
                if !isShiftHeld {
                    isShiftHeld = true
                    stillATap = true
                }
                return false
            case .otherKeyDown:
                stillATap = false
                return false
            case .shiftUp:
                let isTap = isShiftHeld && stillATap
                isShiftHeld = false
                stillATap = false
                return isTap
            }
        }
    }
}
