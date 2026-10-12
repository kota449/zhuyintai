// SPDX-License-Identifier: Apache-2.0
// 游標底下的注音浮窗：游標前最多三個字的注音，正在改的那個標強調色。
//
// 2026-09-23 使用者：打太快拼錯時，分不出是自己打錯還是它選錯。
// 第一版上排也放字，使用者看過之後：字跟組字區重複、整排太長，只要前三個字的注音。
// 欄位怎麼切是純邏輯（`MacMarkedTextState.readingColumns`／`readingWindow`，swiftc 測得到）；
// 這裡只負責畫出來、放到游標底下。
//
// - 不搶焦點（`.nonactivatingPanel`）、不吃滑鼠（`ignoresMouseEvents`）。
// - 層級比候選窗低一格：兩個剛好疊到時，候選窗在上面。
// - 客體給不出組字區位置（零矩形）時不顯示，不像候選窗那樣退到滑鼠位置——
//   浮窗飛到螢幕別處比不顯示更誤導。

import AppKit

@MainActor
final class MacReadingPanel {
    static let shared = MacReadingPanel()

    /// 第一次真的要顯示時才建，只呼叫 `hide()` 的路徑（含 CLI 測試）不會碰到 AppKit 視窗。
    private var panel: NSPanel?
    private var row: NSStackView?

    private init() {}

    func show(_ columns: [MacReadingColumn], anchor: MacReadingPanelAnchor) {
        guard MacReadingPanelPreference.shouldPresent(
            enabled: MacReadingPanelPreference.isEnabled(),
            hasColumns: !columns.isEmpty,
            anchorIsKnown: anchor != .unknown
        ) else {
            hide()
            return
        }
        let (panel, row) = makePanelIfNeeded()
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for column in columns {
            row.addArrangedSubview(Self.columnView(column))
        }
        row.layoutSubtreeIfNeeded()
        let size = row.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(Self.origin(for: size, anchor: anchor))
        panel.orderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: - 內部

    private func makePanelIfNeeded() -> (NSPanel, NSStackView) {
        if let panel, let row { return (panel, row) }
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: true)
        panel.level = NSWindow.Level(Int(max(CGShieldingWindowLevel(), kCGPopUpMenuWindowLevel)) + 1)
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            row.topAnchor.constraint(equalTo: background.topAnchor),
            row.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        self.panel = panel
        self.row = row
        return (panel, row)
    }

    private static func columnView(_ column: MacReadingColumn) -> NSView {
        label(column.reading, size: 13, color: column.isEdited ? .controlAccentColor : .secondaryLabelColor)
    }

    private static func label(_ string: String, size: CGFloat, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.font = .systemFont(ofSize: size)
        field.textColor = color
        return field
    }

    /// 右緣貼齊最後一個字的右緣（客體給得出來時）、放在那一行正下方；
    /// 底下放不下就翻到那一行上面。左右夾在螢幕內。
    private static func origin(for size: NSSize, anchor: MacReadingPanelAnchor) -> NSPoint {
        let (x, lineRect): (CGFloat, CGRect)
        switch anchor {
        case .rightEdge(let edge, let line): (x, lineRect) = (edge - size.width, line)
        case .leftEdge(let edge, let line): (x, lineRect) = (edge, line)
        case .unknown: return .zero
        }
        let gap: CGFloat = 3
        let screen = NSScreen.screens.first { $0.frame.intersects(lineRect) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .infinite
        var origin = NSPoint(x: x, y: lineRect.minY - gap - size.height)
        if origin.y < visible.minY {
            origin.y = lineRect.maxY + gap
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        return origin
    }
}
