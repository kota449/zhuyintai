// SPDX-License-Identifier: Apache-2.0
// 英文模式浮標的真視窗：游標右下方一個小小的「英」。
//
// 硬限制：
// - 🔴 不搶焦點、不吃按鍵：`.nonactivatingPanel`、`canBecomeKey`／`canBecomeMain` 永遠 false、
//   `ignoresMouseEvents`、`hidesOnDeactivate = false`（NSPanel 預設是 true，輸入法行程失焦就會被藏掉），
//   只用 `orderFrontRegardless`，絕不 `makeKey*`。前例：10-06 同意彈窗吃掉按鍵。
// - 只在第一次顯示時建窗；之後每次只改 frame，不重建視窗（熱路徑成本）。
// - 宿主給不出游標位置（零矩形）⇒ 藏起來，不退到滑鼠位置（飛到別處比不顯示更誤導）。
// - 外觀：macOS 26+ 用液態玻璃（`NSGlassEffectView`，跟候選窗同一套取法），舊系統退回 `NSVisualEffectView`；
//   文字用 `labelColor`，亮暗色自動跟隨。

import AppKit

/// 永遠不成為 key／main 的浮動面板。`.nonactivatingPanel` 只管「點它不啟動 app」，
/// 這裡再把 `canBecomeKey` 釘死，連 `makeKeyAndOrderFront` 誤呼叫也拿不到焦點。
final class MacEnglishIndicatorNSPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class MacEnglishIndicatorPanel: MacEnglishIndicatorPresenting {
    static let shared = MacEnglishIndicatorPanel()
    private init() {}

    static let size = NSSize(width: 26, height: 26)

    private var panel: NSPanel?
    private weak var owner: AnyObject?

    func show(caretRect: NSRect, owner: AnyObject) {
        let screens = NSScreen.screens
        let index = MacEnglishIndicatorPlacement.screenIndex(containing: caretRect, frames: screens.map(\.frame))
        let screen = index.map { screens[$0] } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .infinite
        guard let origin = MacEnglishIndicatorPlacement.origin(
            caretRect: caretRect, size: Self.size, visibleFrame: visible)
        else {
            hide(owner: nil)
            return
        }
        let panel = self.panel ?? makeAndStorePanel()
        self.owner = owner
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide(owner: AnyObject?) {
        guard MacEnglishIndicatorOwnership.shouldHide(requested: owner, current: self.owner) else { return }
        self.owner = nil
        panel?.orderOut(nil)
    }

    private func makeAndStorePanel() -> NSPanel {
        let panel = Self.makePanel()
        self.panel = panel
        return panel
    }

    /// 組好整個視窗（不顯示）。劇本 43m 直接檢查它的性質；離屏截圖用 `makeContentView()`。
    static func makePanel() -> NSPanel {
        let panel = MacEnglishIndicatorNSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: true)
        // 🔴 `isFloatingPanel` 的 setter 會把 level 蓋回 floating(3)，所以 level 必須在它之後設
        // （劇本 43m 讀最終 `panel.level` 釘住；第一版順序反了，實測層級是 3 而不是註解寫的值）。
        panel.isFloatingPanel = true
        // popUpMenu：高過選單列／Dock／一般浮動視窗，但低於鎖定畫面與螢幕保護（shielding）。
        // 不比照注音浮窗用 shielding+1——那會蓋過鎖定畫面。
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = makeContentView()
        return panel
    }

    /// 浮標的畫面：玻璃（或退回的模糊材質）底 ＋ 置中的「英」。
    static func makeContentView() -> NSView {
        let label = NSTextField(labelWithString: "英")
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.isBezeled = false
        label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false

        let radius = size.height / 2   // 膠囊（兩端全圓）
        let container: NSView
        if let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            // macOS 26+ 液態玻璃。用 KVC 取用，避免舊 SDK 編不過（候選窗同一個做法）。
            let glass = glassClass.init()
            glass.setValue(radius, forKey: "cornerRadius")
            let host = NSView(frame: NSRect(origin: .zero, size: size))
            host.addSubview(label)
            glass.setValue(host, forKey: "contentView")
            container = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = radius
            effect.layer?.masksToBounds = true
            effect.addSubview(label)
            container = effect
        }
        container.frame = NSRect(origin: .zero, size: size)
        // 標籤置中。玻璃的 contentView 是 host，所以約束掛在 label 自己的 superview 上。
        if let parent = label.superview {
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: parent.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: parent.centerYAnchor),
            ])
        }
        return container
    }
}
