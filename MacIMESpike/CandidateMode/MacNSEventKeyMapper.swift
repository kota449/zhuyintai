// SPDX-License-Identifier: Apache-2.0
// `NSEvent`（keyDown）→ `MacKeyEvent` 的純翻譯，零 AppKit。
//
// 為什麼有這個檔：單押 Shift 要收 `flagsChanged`，而 IMK 的事件入口是**全有或全無**
// （spec 2026-09-20 §4.2、`LanguageSwitch.swift` 檔頭）：controller 一旦 override
// `handle(_:client:)`，keyDown 也會走那條路，原本的 `inputText(_:client:)`／`didCommand(by:)` 不再是
// keyDown 的入口。所以 keyDown 要在 `handle` 裡**復刻**那兩條路已經在做的翻譯，結果必須與舊路徑逐鍵相同：
//   • 特殊鍵（Return／Esc／⌫／fn+⌫／方向鍵／翻頁）：舊路徑由 `didCommand` 的 selector 對映；
//     這裡用 keyCode，且**只認沒有任何修飾鍵**的情形（Option／Shift 加方向鍵等舊路徑是未對映 selector ＝放行）；
//     例外：Return／Enter／⌫／fn＋⌫ 加 Shift，Cocoa 仍是同一個 selector ⇒ 忽略 Shift（N19 ①）。
//   • 字元：舊路徑 `inputText` 收到的字串；這裡用 `event.characters`，交給同一個
//     `MacKeyEventTranslator.event(for:isSelecting:selectionKeys:)`。
//   • Command／Control：舊路徑拿不到（宿主快捷鍵）＝放行。
// 回傳 nil ＝ 放行給宿主（呼叫端記 unmapped）。

import Foundation

struct MacKeyModifiers: OptionSet, Equatable {
    let rawValue: Int
    static let shift = MacKeyModifiers(rawValue: 1 << 0)
    static let control = MacKeyModifiers(rawValue: 1 << 1)
    static let option = MacKeyModifiers(rawValue: 1 << 2)
    static let command = MacKeyModifiers(rawValue: 1 << 3)
}

enum MacNSEventKeyMapper {
    /// log 用：有修飾鍵時才回傳（例：`shift`、`shift+option`），沒有就是 nil——一般打字的 log 不變。
    /// N21：實機 log 原本看不出 ⌫／Return 是不是帶 Shift，逐 App 判讀只能靠 UNMAPPED 推。
    static func modifierLabel(_ modifiers: MacKeyModifiers) -> String? {
        var names: [String] = []
        if modifiers.contains(.shift) { names.append("shift") }
        if modifiers.contains(.control) { names.append("control") }
        if modifiers.contains(.option) { names.append("option") }
        if modifiers.contains(.command) { names.append("command") }
        return names.isEmpty ? nil : names.joined(separator: "+")
    }

    static func event(
        keyCode: UInt16, characters: String?, modifiers: MacKeyModifiers,
        isSelecting: Bool, selectionKeys: String
    ) -> MacKeyEvent? {
        if modifiers.contains(.command) || modifiers.contains(.control) { return nil }

        if let special = specialKey(keyCode) {
            if modifiers.isEmpty { return special }
            // N19 ①：Return／Enter／⌫／fn＋⌫ 加 Shift，Cocoa 仍是 insertNewline:／deleteBackward:／deleteForward:
            // （舊 `didCommand` 路徑照樣收到）⇒ 忽略 Shift；放行會讓宿主自己刪標記文字、引擎不同步。
            // Option／Shift＋Option 是刪字／換行變體（未對映 selector）⇒ 仍放行。
            if modifiers == [.shift], Self.shiftInsensitive.contains(special) { return special }
            return nil
        }
        // 其他沒有字元的鍵（功能鍵、Home／End、Tab 之外的導覽鍵）：放行。
        guard let characters, characters.count == 1, let symbol = characters.first else { return nil }
        if let scalar = symbol.unicodeScalars.first, (0xF700 ... 0xF8FF).contains(scalar.value) { return nil }
        return MacKeyEventTranslator.event(
            for: symbol, isSelecting: isSelecting, selectionKeys: selectionKeys)
    }

    /// 加 Shift 後 Cocoa 的 selector 不變的特殊鍵（方向鍵加 Shift 是 *AndModifySelection＝延伸選取，要放行）。
    private static let shiftInsensitive: [MacKeyEvent] = [.enter, .backspace, .deleteForward]

    private static func specialKey(_ keyCode: UInt16) -> MacKeyEvent? {
        switch keyCode {
        case 36, 76: return .enter          // Return、小鍵盤 Enter
        case 53: return .escape
        case 51: return .backspace
        case 117: return .deleteForward
        case 123: return .moveLeft
        case 124: return .moveRight
        case 125: return .moveDown
        case 126: return .moveUp
        case 116: return .pageUp
        case 121: return .pageDown
        default: return nil
        }
    }
}
