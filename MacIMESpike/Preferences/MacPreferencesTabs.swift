// SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI

/// 偏好設定視窗的分頁清單。產品視窗與截圖 harness 共用這一份。
enum MacPreferencesTab: String, CaseIterable, Identifiable {
    case typing
    case keys
    case lexicon
    case privacy
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .typing: return "輸入"
        case .keys: return "按鍵"
        case .lexicon: return "詞庫"
        case .privacy: return "隱私"
        case .about: return "關於"
        }
    }

    var symbol: String {
        switch self {
        case .typing: return "keyboard"
        case .keys: return "command"
        case .lexicon: return "books.vertical"
        case .privacy: return "hand.raised"
        case .about: return "info.circle"
        }
    }

    /// 視窗固定大小，所有分頁一樣、使用者不能拖拉（2026-10-07 使用者：以「按鍵」分頁目前的大小為準）。
    /// 按鍵分頁量到的內容區是 520×640；其他分頁內容超出由各自的 Form 垂直捲動，不再改視窗大小。
    static let fixedContentSize = NSSize(width: 520, height: 640)

    var contentSize: NSSize { Self.fixedContentSize }

    @MainActor
    var content: AnyView {
        switch self {
        case .typing: return AnyView(MacTypingTab())
        case .keys: return AnyView(MacKeysTab())
        case .lexicon: return AnyView(MacLexiconTab())
        case .privacy: return AnyView(MacPrivacyTab())
        case .about: return AnyView(MacAboutTab())
        }
    }
}

/// 工具列分頁（像 Safari／Mail 的設定視窗）：macOS 26 的工具列由系統套 Liquid Glass，舊系統是一般工具列。
///
/// ⌘W 只走這裡，轉成 `performClose:`（標準關閉：會走 close button，不是直接 `close()`）。
/// 不在主選單最上層另加項目。
final class MacPreferencesWindow: NSWindow {
    /// 使用者在這扇視窗內按了滑鼠。`MacPreferencesFrontSession` 靠它判斷「使用者接手」，才放手 level。
    var onUserMouseDown: (() -> Void)?
    /// 診斷 log 用：有人對這扇視窗呼叫 `-orderOut:`。只通知，行為不變。
    /// ⚠️ 只攔得到 `-orderOut:` 這個入口：`orderWindow(_:relativeTo:)` 的 `.out`、app 隱藏、Space 切換都不經過這裡，
    /// 所以 log 裡**沒有** `what=orderOut` 不能當成「沒人把視窗藏起來」的證據。
    var onOrderOut: (() -> Void)?

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        onOrderOut?()
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            onUserMouseDown?()
        default:
            break
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if MacPreferencesCommandW.invokesPerformClose(
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control)
        ) {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
enum MacPreferencesWindowFactory {

    static func makeWindow(selecting selected: MacPreferencesTab = .typing) -> NSWindow {
        let controller = NSTabViewController()
        controller.tabStyle = .toolbar
        for tab in MacPreferencesTab.allCases {
            let host = NSHostingController(
                rootView: tab.content.frame(width: tab.contentSize.width, height: tab.contentSize.height))
            host.sizingOptions = [.preferredContentSize]
            host.title = tab.title
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            controller.addTabViewItem(item)
        }
        controller.selectedTabViewItemIndex = MacPreferencesTab.allCases.firstIndex(of: selected) ?? 0

        let window = MacPreferencesWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.setContentSize(MacPreferencesTab.fixedContentSize)
        window.contentMinSize = MacPreferencesTab.fixedContentSize
        window.contentMaxSize = MacPreferencesTab.fixedContentSize
        return window
    }
}
