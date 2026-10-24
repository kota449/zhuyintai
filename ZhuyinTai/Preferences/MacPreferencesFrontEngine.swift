// SPDX-License-Identifier: Apache-2.0
import Foundation

/// 偏好設定視窗的可測表面。真的 `NSWindow` 與測試假物件都走這組方法。
protocol MacPreferencesFrontWindow: AnyObject {
    var isVisible: Bool { get }
    var isMiniaturized: Bool { get }
    var isKeyWindow: Bool { get }
    var level: MacPreferencesWindowLevel { get set }
    var frontDelegate: MacPreferencesFrontWindowDelegate? { get set }
    func deminiaturize()
    func orderFrontRegardless()
    func makeKey()
    func moveToActiveSpace()
}

protocol MacPreferencesFrontWindowDelegate: AnyObject {
    func frontWindowDidBecomeKey(_ window: MacPreferencesFrontWindow)
    /// 使用者在視窗內按了滑鼠（左／右／其他鍵）。這才是「使用者接手」；成為 key 不是。
    func frontWindowDidReceiveUserClick(_ window: MacPreferencesFrontWindow)
    func frontWindowWillClose(_ window: MacPreferencesFrontWindow)
}

/// level 還原成 normal 的原因。診斷 log 的 `lastRelease` 用它區分「使用者接手」與其他路徑。
enum MacPreferencesReleaseReason: String, Equatable {
    /// 使用者去點了別的 app。
    case takeover
    /// 使用者點了偏好設定視窗本身。
    case userClick
    /// 視窗關閉（含 arm 時發現視窗已關）。
    case closed
    /// 浮著超過上限仍沒有人接手（Cmd-Tab、Mission Control、快捷鍵這類沒有滑鼠事件的離開方式）。
    case timeout
}

protocol MacPreferencesFrontApp: AnyObject {
    var isActive: Bool { get }
    func activate()
    func deactivate()
    /// 暫時切 `.regular`（冪等）。見 `MacPreferencesFrontAction.promoteToRegularPolicy`。
    func promoteToRegularPolicy()
    /// 切回 `.accessory`（冪等）。
    func restoreAccessoryPolicy()
    /// 在主選單最上層加一個 ⌘W → `performClose:`。LSUIElement 不該靠這個。
    func installCommandWMenu()
    /// 偵測「使用者自己去點了別的 app」（別的 app 收到滑鼠按下）。偵測到呼叫 `onTakeover` 一次。
    /// 選單收起、前景 app 被系統還原**不算**：那不是使用者的動作，沒有滑鼠事件。
    func watchUserTakeover(_ onTakeover: @escaping () -> Void)
    func stopWatchingUserTakeover()
}

/// `MacPreferencesPresenter` 實際套用的那條路徑。測試用假視窗驅動同一個型別。
final class MacPreferencesFrontSession: MacPreferencesFrontWindowDelegate {
    /// 診斷 log 用：最近一次放手（level 回 normal）的原因與時間；`apply` 時清掉。
    private(set) var lastRelease: (reason: MacPreferencesReleaseReason, at: Date)?
    /// 診斷 log 用：最近一次視窗成為 key 的時間；`apply` 時清掉。
    private(set) var lastBecameKeyAt: Date?
    /// 診斷 log 用：每一次**有意義的**放手都通知（每代第一次，以及 `.closed`——它會切回 accessory，
    /// 而且 `arm` 發現視窗不可見時也會走，完全不經 `windowWillClose`）。`lastRelease` 只留第一次，單看它推不出最後狀態。
    /// 使用者在視窗內連按滑鼠的 `.userClick` 重複放手不通知（會洗版）。
    var onRelease: ((MacPreferencesReleaseReason) -> Void)?
    /// 同步路徑已呼叫 `deminiaturize`。動畫期間 `isMiniaturized` 已假、`isVisible` 仍假，不能當成已關閉。
    private var deminiaturizeRequested = false
    private let app: MacPreferencesFrontApp
    private let schedule: (@escaping () -> Void) -> Void
    private let scheduleAfter: (TimeInterval, @escaping () -> Void) -> Void
    private let now: () -> Date
    /// 每次 `apply` +1。排程中的 arm／計時器帶著自己那一代，過期的不動作（連點時舊的不能干擾新的）。
    private var generation = 0
    /// 這一代已放手。放手只做一次：之後每一次點視窗都會再走 release，不能覆蓋第一次的原因。
    private var released = true

    /// 浮著的時間上限。只需要撐過「選單收起、前景 app 取回」那一兩秒；超過還沒人接手就放手。
    static let holdTimeout: TimeInterval = 8
    /// 全域滑鼠監聽收到別的 app 的點擊後，等這麼久再確認我們是不是真的失去 active。
    /// 切 regular 後 Dock 有我們的圖示：點它也會觸發監聽，但那之後我們是 active，不算接手。
    static let takeoverConfirmDelay: TimeInterval = 0.2

    init(
        app: MacPreferencesFrontApp,
        schedule: @escaping (@escaping () -> Void) -> Void,
        scheduleAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void = { _, _ in },
        now: @escaping () -> Date = Date.init
    ) {
        self.app = app
        self.schedule = schedule
        self.scheduleAfter = scheduleAfter
        self.now = now
    }

    func apply(_ path: MacPreferencesShowPath, to window: MacPreferencesFrontWindow) {
        lastRelease = nil
        lastBecameKeyAt = nil
        generation += 1
        released = false
        deminiaturizeRequested = false
        app.stopWatchingUserTakeover()
        window.frontDelegate = self
        MacPreferencesFrontPolicy.perform(path) { action in
            switch action {
            case .moveToActiveSpace:
                window.moveToActiveSpace()
            case .raiseLevelToFloating:
                window.level = .floating
            case .promoteToRegularPolicy:
                app.promoteToRegularPolicy()
            case .orderFrontRegardless:
                if window.isMiniaturized {
                    deminiaturizeRequested = true
                    window.deminiaturize()
                }
                window.orderFrontRegardless()
            case .activateApp:
                app.activate()
            case .makeKey:
                window.makeKey()
            case .holdFloatingUntilUserTakesOver:
                arm(window)
            case .bindCommandWToPerformClose:
                // ⌘W 由 MacPreferencesWindow.performKeyEquivalent 轉成 performClose。
                // 不在主選單最上層加項目。
                break
            }
        }
    }

    /// 視窗 level 浮著，直到使用者接手；**既不在下一個 run loop、也不在視窗成為 key 時降回 normal**。
    ///
    /// 實機測得：視窗已開著但被別的視窗蓋住時，點「偏好設定…」第一次沒變化、
    /// 第二次才到最前；兩次作用中的 app 都沒變成注音台——輸入法的 activate 實際上被系統拒絕。
    /// activate 沒用時，視窗能不能留在最前面只剩 level：改前在下一個 run loop 就降回 normal，
    /// 視窗又沉到前景 app 後面（離屏重現：activate 一律被拒時，過 1 秒左右掉到別 app 視窗後面）。
    /// 上游 vChewing 開設定視窗也是 `orderFrontRegardless` ＋ 拉高 level 且之後不還原。
    ///
    /// 第二次修（2026-10-08）：build 3 仍會「點一兩次才跳出」。第一次修把「視窗成為 key」當成使用者接手，
    /// 但 `activate` 是非同步請求——視窗在 arm 之後才成為 key，那一刻就降回 normal；緊接著選單收起、
    /// 原前景 app 取回作用中，視窗是 normal level、我們的 app 不 active ⇒ 沉到前景 app 後面
    /// （離屏模型重現：啟用落地→成為 key→前景 app 取回，level 已是 normal）。
    /// 成為 key 只代表「啟用請求曾經落地」，不代表之後會留在最前面，所以不再當放手條件。
    ///
    /// 放手的時機：①使用者去點了別的 app（全域滑鼠監聽，不需輔助使用權限；等 0.2 秒確認我們真的不再
    /// active，免得點自己的 Dock 圖示被當成接手）②使用者點了這扇視窗本身 ③視窗關閉
    /// ④浮超過 `holdTimeout` 仍沒有人接手（Cmd-Tab 這類沒有滑鼠事件的離開方式）。
    /// 放手後回一般層級，不會一直擋在使用者正在用的 app 上面。
    private func arm(_ window: MacPreferencesFrontWindow) {
        window.frontDelegate = self
        let armed = generation
        scheduleAfter(Self.holdTimeout) { [weak self, weak window] in
            guard let self, let window, armed == self.generation, !self.released else { return }
            self.release(window, because: .timeout)
        }
        schedule { [weak self, weak window] in
            guard let self, let window, armed == self.generation, !self.released else { return }
            let closed = !window.isVisible && !window.isMiniaturized && !self.deminiaturizeRequested
            guard !closed else {
                self.release(window, because: .closed)
                return
            }
            self.app.promoteToRegularPolicy()
            self.app.activate()
            if window.isMiniaturized {
                window.deminiaturize()
            }
            window.orderFrontRegardless()
            if !window.isKeyWindow {
                window.makeKey()
            }
            self.app.watchUserTakeover { [weak self, weak window] in
                guard let self else { return }
                self.scheduleAfter(Self.takeoverConfirmDelay) { [weak self, weak window] in
                    guard let self, let window, armed == self.generation, !self.released else { return }
                    guard !self.app.isActive else { return }
                    self.release(window, because: .takeover)
                }
            }
        }
    }

    /// level 一律回 normal。**activation policy 只在關窗時切回 accessory**：視窗還開著就維持 regular
    /// （Dock 有圖示，跟一般 app 視窗一樣）。
    /// 改前（#371）在「去點別的 app」與 timeout 也切回 accessory；但選單列輸入法圖示的點擊也會被全域監聽當成
    /// 接手，連點時每一次都 regular→accessory→regular 來回翻，而且每次 apply 都在 policy 剛變動時 activate，
    /// 是連點「有些次顯示不出來」的競態候選（離屏模型：6 次連點翻 11 次）。
    private func release(_ window: MacPreferencesFrontWindow, because reason: MacPreferencesReleaseReason) {
        let first = !released
        released = true
        app.stopWatchingUserTakeover()
        if first {
            window.level = .normal
            lastRelease = (reason, now())
        }
        if reason == .closed {
            app.restoreAccessoryPolicy()
        }
        if first || reason == .closed {
            onRelease?(reason)
        }
    }

    /// 只記時間給診斷 log；**不放手**（見 `arm` 的註解）。
    func frontWindowDidBecomeKey(_ window: MacPreferencesFrontWindow) {
        lastBecameKeyAt = now()
    }

    func frontWindowDidReceiveUserClick(_ window: MacPreferencesFrontWindow) {
        release(window, because: .userClick)
    }

    func frontWindowWillClose(_ window: MacPreferencesFrontWindow) {
        // 先記下：切回 accessory 可能讓 app 失去 active，之後才檢查就漏了 deactivate。
        let wasActive = app.isActive
        release(window, because: .closed)
        guard wasActive else { return }
        app.deactivate()
    }
}
