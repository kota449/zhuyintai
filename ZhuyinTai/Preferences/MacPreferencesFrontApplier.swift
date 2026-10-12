// SPDX-License-Identifier: Apache-2.0
import AppKit
import CoreGraphics

/// 把 `MacPreferencesFrontSession` 套到真的 `NSWindow`。判斷在 session 裡，這裡只轉呼叫。
/// Session 的 protocol 不是 MainActor；方法標 `nonisolated`，裡面再回到 main（呼叫端本來就在 main）。
@MainActor
final class MacPreferencesNSWindowBox: MacPreferencesFrontWindow {
    let ns: NSWindow
    nonisolated(unsafe) weak var frontDelegate: MacPreferencesFrontWindowDelegate?

    init(_ ns: NSWindow) {
        self.ns = ns
    }

    nonisolated var isVisible: Bool { MainActor.assumeIsolated { ns.isVisible } }
    nonisolated var isMiniaturized: Bool { MainActor.assumeIsolated { ns.isMiniaturized } }
    nonisolated var isKeyWindow: Bool { MainActor.assumeIsolated { ns.isKeyWindow } }

    nonisolated var level: MacPreferencesWindowLevel {
        get { MainActor.assumeIsolated { ns.level == .floating ? .floating : .normal } }
        set { MainActor.assumeIsolated { ns.level = newValue == .floating ? .floating : .normal } }
    }

    nonisolated func deminiaturize() {
        MainActor.assumeIsolated { ns.deminiaturize(nil) }
    }

    nonisolated func orderFrontRegardless() {
        MainActor.assumeIsolated { ns.orderFrontRegardless() }
    }

    nonisolated func makeKey() {
        MainActor.assumeIsolated { ns.makeKey() }
    }

    nonisolated func moveToActiveSpace() {
        MainActor.assumeIsolated {
            var behavior = ns.collectionBehavior
            behavior.insert(.moveToActiveSpace)
            ns.collectionBehavior = behavior
        }
    }
}

/// macOS 14 起 `NSApp.activate()` 是協作式請求：SDK 寫明不保證 app 會變成作用中。
/// 這支 LSUIElement 輸入法先前實機已量到該呼叫靜默失敗，視窗開了卻留在別的 app 後面。
/// `activate(ignoringOtherApps:)` 的契約是 `true` 時不管別的 app 也要作用中
/// （標成將來會棄用、請改呼叫 `activate()`，但後者不強制）。
/// 使用者剛從輸入法選單點了「偏好設定…」，這是明確要這扇視窗的意圖。
@MainActor
enum MacPreferencesActivation {
    static func request() {
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class MacPreferencesLiveApp: MacPreferencesFrontApp {
    private nonisolated(unsafe) var takeoverMonitor: Any?

    nonisolated var isActive: Bool { MainActor.assumeIsolated { NSApp.isActive } }

    nonisolated func activate() {
        MainActor.assumeIsolated { MacPreferencesActivation.request() }
    }

    nonisolated func deactivate() {
        MainActor.assumeIsolated { NSApp.deactivate() }
    }

    nonisolated func promoteToRegularPolicy() {
        MainActor.assumeIsolated {
            if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        }
    }

    nonisolated func restoreAccessoryPolicy() {
        MainActor.assumeIsolated {
            if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
        }
    }

    nonisolated func installCommandWMenu() {
        // 故意空白。⌘W 只走視窗的 performKeyEquivalent → performClose。
    }

    /// 全域監聽只會收到「別的 app」的滑鼠按下（點自己的視窗不會進來），而且不需要輔助使用權限。
    /// 鍵盤事件要輸入監控權限，這裡不用。
    nonisolated func watchUserTakeover(_ onTakeover: @escaping () -> Void) {
        MainActor.assumeIsolated {
            stopWatchingUserTakeover()
            takeoverMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { _ in
                MainActor.assumeIsolated { onTakeover() }
            }
        }
    }

    nonisolated func stopWatchingUserTakeover() {
        MainActor.assumeIsolated {
            if let monitor = takeoverMonitor {
                NSEvent.removeMonitor(monitor)
                takeoverMonitor = nil
            }
        }
    }
}

@MainActor
final class MacPreferencesLevelRestorer: NSObject, NSWindowDelegate {
    private let session: MacPreferencesFrontSession
    private var box: MacPreferencesNSWindowBox?
    /// 診斷 log 用：視窗事件（willClose／orderOut／miniaturize／appHide…）。不影響前景邏輯。
    var onWindowEvent: ((String) -> Void)?
    private nonisolated(unsafe) var appObservers: [NSObjectProtocol] = []

    override init() {
        let app = MacPreferencesLiveApp()
        session = MacPreferencesFrontSession(
            app: app,
            schedule: { work in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        work()
                    }
                }
            },
            scheduleAfter: { delay, work in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated {
                        work()
                    }
                }
            }
        )
        super.init()
        session.onRelease = { [weak self] reason in
            MainActor.assumeIsolated { self?.onWindowEvent?("release:\(reason.rawValue)") }
        }
        // Cmd-H／系統隱藏 app 時視窗 isVisible 會變 false；快照單看 visible=0 分不出是關窗還是被隱藏。
        for (name, what) in [(NSApplication.didHideNotification, "appHide"), (NSApplication.didUnhideNotification, "appUnhide")] {
            appObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onWindowEvent?(what) }
            })
        }
    }

    deinit {
        for observer in appObservers { NotificationCenter.default.removeObserver(observer) }
    }

    func apply(_ path: MacPreferencesShowPath, to window: NSWindow) {
        let box = MacPreferencesNSWindowBox(window)
        self.box = box
        window.delegate = self
        (window as? MacPreferencesWindow)?.onUserMouseDown = { [weak self, weak box] in
            guard let self, let box else { return }
            self.session.frontWindowDidReceiveUserClick(box)
        }
        (window as? MacPreferencesWindow)?.onOrderOut = { [weak self] in self?.onWindowEvent?("orderOut") }
        session.apply(path, to: box)
    }

    /// 診斷 log 用：量現在的視窗與前景狀態。`window` 為 nil＝視窗還沒建。
    func snapshot(of window: NSWindow?, now: Date = Date()) -> MacPreferencesShowSnapshot {
        var snapshot = MacPreferencesLiveSnapshot.read(window: window)
        if window != nil {
            if let release = session.lastRelease {
                snapshot.lastRelease = (release.reason.rawValue, Int((now.timeIntervalSince(release.at) * 1000).rounded()))
            }
            if let keyAt = session.lastBecameKeyAt {
                snapshot.keyAgo_ms = Int((now.timeIntervalSince(keyAt) * 1000).rounded())
            }
        }
        return snapshot
    }

    @objc func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let box, box.ns === window else { return }
        session.frontWindowDidBecomeKey(box)
    }

    @objc func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let box, box.ns === window else { return }
        session.frontWindowWillClose(box)
        onWindowEvent?("willClose")
    }

    @objc func windowDidMiniaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let box, box.ns === window else { return }
        onWindowEvent?("miniaturize")
    }
}

/// 從真的 AppKit／WindowServer 量 `MacPreferencesShowSnapshot`。不需要螢幕錄製權限
/// （`CGWindowListCopyWindowInfo` 只取 windowNumber 與排序，不取視窗標題）。
@MainActor
enum MacPreferencesLiveSnapshot {
    static func read(window: NSWindow?) -> MacPreferencesShowSnapshot {
        var snapshot = MacPreferencesShowSnapshot()
        snapshot.appActive = NSApp.isActive
        snapshot.frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        switch NSApp.activationPolicy() {
        case .regular: snapshot.policy = "regular"
        case .accessory: snapshot.policy = "accessory"
        default: snapshot.policy = "prohibited"
        }
        guard let window else { return snapshot }
        snapshot.windowExists = true
        snapshot.isVisible = window.isVisible
        snapshot.isMiniaturized = window.isMiniaturized
        snapshot.isOccludedFromView = !window.occlusionState.contains(.visible)
        snapshot.level = window.level == .floating ? .floating : .normal
        snapshot.isKey = window.isKeyWindow
        snapshot.onActiveSpace = window.isOnActiveSpace
        snapshot.zOrder = zOrder(ofWindowNumber: window.windowNumber)
        let f = window.frame
        snapshot.frame = MacPreferencesShowSnapshot.formatFrame(x: f.origin.x, y: f.origin.y, width: f.size.width, height: f.size.height)
        if let screen = window.screen, let index = NSScreen.screens.firstIndex(of: screen) {
            snapshot.screen = String(index)
        } else {
            snapshot.screen = "none"
        }
        return snapshot
    }

    private static func zOrder(ofWindowNumber number: Int) -> Int? {
        guard number > 0,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        return list.firstIndex { ($0[kCGWindowNumber as String] as? Int) == number }
    }
}

@MainActor
enum MacPreferencesFrontApplier {
    static func apply(
        _ path: MacPreferencesShowPath,
        to window: NSWindow,
        restorer: MacPreferencesLevelRestorer
    ) {
        restorer.apply(path, to: window)
    }
}
