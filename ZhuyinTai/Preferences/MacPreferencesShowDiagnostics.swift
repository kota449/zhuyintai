// SPDX-License-Identifier: Apache-2.0
import Foundation

/// 點「偏好設定…」當下、0.5 秒後與 3 秒後，視窗與前景的狀態（另有視窗事件）。純資料，沒有 AppKit；真值由 `MacPreferencesLiveSnapshot` 讀。
///
/// 為什麼要記：「點一兩次才跳出來」離線只能用模型重現，實機是哪條路徑（沒收到點擊／收到但沉下去／
/// 在別的桌面／縮在 Dock）只有 log 答得出來。使用者下次再遇到，grep `entry=prefs` 就能看出來。
/// 欄位只有視窗狀態與 bundle id，沒有任何輸入內容。
struct MacPreferencesShowSnapshot {
    var phase = ""
    /// 第幾次點「偏好設定…」（這個 diagnostics 實例內從 1 起算；產品只有 `MacPreferencesPresenter` 一個實例，等於行程內）。
    /// click／settled／late 三筆同號，連點時對得起來是哪次的結果；視窗事件掛在最近一次點擊的號碼下。記錄關著時照樣累計，開啟後序號不會倒退。
    var clickSeq: Int?
    var path: MacPreferencesShowPath?
    var requester = "-"
    var client = "-"
    var windowExists = false
    var isVisible = false
    var isMiniaturized = false
    var isOccludedFromView = false
    var level: MacPreferencesWindowLevel?
    var isKey = false
    var appActive = false
    var frontApp = "-"
    /// `NSApp.activationPolicy`：accessory／regular／prohibited。
    var policy = "-"
    /// 視窗是否在目前桌面（別的桌面／全螢幕空間是 false）。視窗不存在時 nil。
    var onActiveSpace: Bool?
    /// 在螢幕上所有視窗由前到後的順序（0＝最前）。不在螢幕上／視窗不存在時 nil。
    var zOrder: Int?
    var sinceLastShow_ms: Int?
    /// 最近一次放手的原因（`MacPreferencesReleaseReason.rawValue`）與距今毫秒。
    var lastRelease: (reason: String, ago_ms: Int)?
    /// 視窗最近一次成為 key 距今毫秒。
    var keyAgo_ms: Int?
    /// 視窗 frame（`x,y,w,h`，螢幕座標，取整）。只有量到才有。
    var frame: String?
    /// 視窗所在螢幕在 `NSScreen.screens` 的 index；不在任何螢幕上是 `none`。沒量到 nil。
    /// 「0.5 秒時可見」不等於使用者看到：frame 落在螢幕外／別的螢幕時 visible=1 但看不到。
    var screen: String?
    /// phase=event 時是哪種視窗事件（willClose／orderOut／miniaturize／appHide…）。
    var event: String?

    /// 有序的 `key=value`，接在 `entry=prefs` 後面。**只在有值時才印**，不印假的 0。
    func fields() -> [(String, String)] {
        var out: [(String, String)] = [("phase", phase)]
        if let event { out.append(("what", event)) }
        if let clickSeq { out.append(("n", String(clickSeq))) }
        if let path { out.append(("path", path == .firstOpen ? "firstOpen" : "alreadyOpen")) }
        if phase == "click" {
            out.append(("ctrl", requester))
            out.append(("client", client))
        }
        if let sinceLastShow_ms { out.append(("sinceLastShow_ms", String(sinceLastShow_ms))) }
        out.append(("exists", Self.flag(windowExists)))
        if windowExists {
            out.append(("visible", Self.flag(isVisible)))
            out.append(("mini", Self.flag(isMiniaturized)))
            out.append(("occluded", Self.flag(isOccludedFromView)))
            if let level { out.append(("level", level == .floating ? "floating" : "normal")) }
            out.append(("key", Self.flag(isKey)))
            if let onActiveSpace { out.append(("space", Self.flag(onActiveSpace))) }
            if let zOrder { out.append(("z", String(zOrder))) }
            if let frame { out.append(("frame", frame)) }
            if let screen { out.append(("screen", screen)) }
        }
        out.append(("appActive", Self.flag(appActive)))
        out.append(("front", frontApp))
        out.append(("policy", policy))
        if windowExists {
            if let lastRelease {
                out.append(("lastRelease", lastRelease.reason))
                out.append(("lastReleaseAgo_ms", String(lastRelease.ago_ms)))
            }
            if let keyAgo_ms { out.append(("keyAgo_ms", String(keyAgo_ms))) }
        }
        return out
    }

    private static func flag(_ value: Bool) -> String { value ? "1" : "0" }

    /// `x,y,w,h`（取整）。**不可 trap**：診斷碼不能讓輸入法 crash；顯示器拔掉、視窗還沒排版時 frame 可能是
    /// NaN／無限／超出 Int 範圍，`Int(_:)` 會直接 trap，所以這幾種印成可辨識的字。
    static func formatFrame(x: Double, y: Double, width: Double, height: Double) -> String {
        func piece(_ v: Double) -> String {
            if v.isNaN { return "nan" }
            if v.isInfinite { return v < 0 ? "-inf" : "inf" }
            if abs(v) >= 1e15 { return v < 0 ? "-big" : "big" }
            return String(Int(v.rounded()))
        }
        return [x, y, width, height].map(piece).joined(separator: ",")
    }
}

/// 選單／action 的進入點記錄。`menu()`（IMK 要選單）與選單 action（`showPreferences` 等）開頭各記一筆，
/// **在 MainActor hop 之前**：點了「偏好設定…」但 `phase=click` 沒出現時，靠這兩筆分辨是 action 根本沒送到、
/// 還是送到了卻沒走進 presenter。只有 controller 識別碼、前景 client bundle id、是否在主執行緒，沒有輸入內容。
///
/// ⚠️ `phase=menu` 的次數**不等於**使用者打開選單的次數：unified log 實測 IMK 在**每次 activateServer 之後**
/// 都會呼叫 `menu()`（TWKeyboard 的 InputMethodKit 活動 "Menu" 緊跟在 "Activate Server" 後）。
/// 判讀時 `phase=menu` 只能說「這個 controller 在這個時間被要過選單」。
enum MacPreferencesEntryLog {
    /// - Parameters:
    ///   - phase: `menu`（`menu()` 被呼叫）或 `action`（選單 action 被呼叫）。
    ///   - item: `action` 時是哪一列：`prefs`／`notices`／`update`。其他情況 nil（不印）。
    ///     unified log 的 `TextInputMenuAgent "perform action for menu item"` 沒對上 `phase=click` 時，
    ///     靠它分辨是點到別列還是 action 沒送到。
    static func fields(phase: String, ctrl: String, client: String, onMain: Bool, item: String? = nil) -> [(String, String)] {
        var out: [(String, String)] = [("phase", phase), ("ctrl", ctrl), ("client", client), ("main", onMain ? "1" : "0")]
        if let item { out.append(("item", item)) }
        return out
    }
}

/// 每次點「偏好設定…」記三筆（click／settled／late），之後視窗事件另記 phase=event：
/// **套用前**（點下去那一刻是什麼狀態）、**0.5 秒後**、**3 秒後**（使用者真正看到的結果）。
/// 讀值、寫 log、延遲排程都注入，離屏測試不需要視窗伺服器。
final class MacPreferencesShowDiagnostics {
    static let settleDelay: TimeInterval = 0.5
    /// 0.5 秒時可見不等於使用者看到（視窗可能之後才被收掉／沉下去）；3 秒後再量一次。
    static let lateDelay: TimeInterval = 3

    private let read: () -> MacPreferencesShowSnapshot
    private let emit: (MacPreferencesShowSnapshot) -> Void
    private let scheduleAfter: (TimeInterval, @escaping () -> Void) -> Void
    private let now: () -> Date
    private let isEnabled: () -> Bool
    private var lastShowAt: Date?
    private var clickCount = 0

    /// - Parameter isEnabled: log 關著（使用者沒同意記錄）時不量快照——量一次要查 WindowServer 的視窗清單。
    init(
        read: @escaping () -> MacPreferencesShowSnapshot,
        emit: @escaping (MacPreferencesShowSnapshot) -> Void,
        scheduleAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void,
        now: @escaping () -> Date = Date.init,
        isEnabled: @escaping () -> Bool = { true }
    ) {
        self.read = read
        self.emit = emit
        self.scheduleAfter = scheduleAfter
        self.now = now
        self.isEnabled = isEnabled
    }

    /// `applyFront` 是真正把視窗浮到前面的動作；先記「套用前」，再套用，再排 0.5 秒後那筆。
    func record(path: MacPreferencesShowPath, requester: String, client: String, applyFront: () -> Void) {
        let clickAt = now()
        clickCount += 1
        let seq = clickCount
        guard isEnabled() else {
            lastShowAt = clickAt
            applyFront()
            return
        }
        var click = read()
        click.phase = "click"
        click.clickSeq = seq
        click.path = path
        click.requester = requester
        click.client = client
        if let lastShowAt {
            click.sinceLastShow_ms = Int((clickAt.timeIntervalSince(lastShowAt) * 1000).rounded())
        }
        lastShowAt = clickAt
        emit(click)

        applyFront()

        for (delay, phase) in [(Self.settleDelay, "settled"), (Self.lateDelay, "late")] {
            scheduleAfter(delay) { [weak self] in
                // 排程當下記錄開著，不代表 3 秒後還開著；關掉了就不查 WindowServer。
                guard let self, self.isEnabled() else { return }
                var sample = self.read()
                sample.phase = phase
                sample.clickSeq = seq
                sample.path = path
                self.emit(sample)
            }
        }
    }

    /// 視窗事件（關窗、orderOut、縮到 Dock、app 被隱藏）。掛在最近一次點擊的序號下（還沒點過就不帶 n）。
    /// 補 `visible=0` 的缺口：只看 click 當下的快照分不出是使用者關的、被藏的還是被收掉的。
    func recordEvent(_ what: String) {
        guard isEnabled() else { return }
        var snapshot = read()
        snapshot.phase = "event"
        snapshot.event = what
        if clickCount > 0 { snapshot.clickSeq = clickCount }
        emit(snapshot)
    }
}
