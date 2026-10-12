// SPDX-License-Identifier: Apache-2.0
import Foundation

/// 偏好設定視窗要不要浮到最前面。純資料，沒有 AppKit，給單元測試與視窗套用端共用。
enum MacPreferencesShowPath: Equatable {
    /// 視窗物件還沒建。
    case firstOpen
    /// 視窗已經在（可能被別的 app 蓋住、縮到 Dock，或在別的桌面）。
    case alreadyOpen
}

enum MacPreferencesFrontAction: Equatable {
    /// 視窗在別的桌面時，變成作用中就拉到目前桌面（Apple：`moveToActiveSpace`）。
    case moveToActiveSpace
    /// 高於一般視窗，非作用中的輸入法才蓋得過前景 app。何時還原見 `holdFloatingUntilUserTakesOver`。
    case raiseLevelToFloating
    /// Apple：即使 app 不是作用中，也把視窗移到該層最前面。不會改 key window。
    case orderFrontRegardless
    /// `orderFrontRegardless` 不改 key window，要另外 `makeKey()` 才收得到鍵盤。
    case makeKey
    /// level 浮著，直到使用者接手（點別的 app／點這扇視窗／關窗）才還原。
    /// 不在下一個 run loop、也不在成為 key 時還原：activate 是非同步請求，成為 key 之後前景 app 仍可能取回作用中。
    case holdFloatingUntilUserTakesOver
    /// 暫時把 LSUIElement 輸入法切成 `.regular`（Dock 會出現圖示），**關窗時**才切回 `.accessory`（視窗開著不來回翻）。
    /// 依據：Apple DTS 2026-07 在論壇確認 accessory app 的 `NSApp.activate()` 帶不到視窗到前景
    /// （developer.apple.com/forums/thread/836619）；暫時切 regular 是該串與少數派文章的通用解法。
    case promoteToRegularPolicy
    /// 要求這個 LSUIElement app 變成作用中。`makeKey` 只有在 app 作用中時才會真的變成 key window。
    case activateApp
    /// ⌘W 走標準關閉：對 key window 送 `performClose:`。
    case bindCommandWToPerformClose
}

/// 邏輯層的視窗層級。對應 AppKit 的 `.normal`／`.floating`，這裡不碰 AppKit。
enum MacPreferencesWindowLevel: Equatable {
    case normal
    case floating
}

/// `frontActions` 套完之後，邏輯層看得到的結果。真視窗的非同步啟用這裡摺成「有要求 activate，makeKey 才算數」。
struct MacPreferencesFrontState: Equatable {
    var level: MacPreferencesWindowLevel = .normal
    var activationRequested = false
    var isKey = false
    /// ⌘W 已接到 `performClose:`。
    var commandWCallsPerformClose = false
    var isClosed = false
}

/// ⌘W（不含 Shift／Option／Control）才是標準「關閉視窗」。
enum MacPreferencesCommandW {
    static func invokesPerformClose(
        charactersIgnoringModifiers: String,
        command: Bool,
        shift: Bool,
        option: Bool,
        control: Bool
    ) -> Bool {
        command && !shift && !option && !control
            && charactersIgnoringModifiers.lowercased() == "w"
    }
}

enum MacPreferencesFrontPolicy {
    /// 第一次開與已開著都要做同一串浮前面的動作。差別只在呼叫端要不要先建視窗。
    static func frontActions(for path: MacPreferencesShowPath) -> [MacPreferencesFrontAction] {
        switch path {
        case .firstOpen, .alreadyOpen:
            return [
                .moveToActiveSpace,
                .raiseLevelToFloating,
                .promoteToRegularPolicy,
                .orderFrontRegardless,
                .activateApp,
                .makeKey,
                .holdFloatingUntilUserTakesOver,
                .bindCommandWToPerformClose,
            ]
        }
    }

    /// 兩條路徑都經過這裡，測試才能斷言「有呼叫到浮前面」，而不是只看陣列常數。
    static func perform(_ path: MacPreferencesShowPath, _ handle: (MacPreferencesFrontAction) -> Void) {
        for action in frontActions(for: path) {
            handle(action)
        }
    }

    /// 把一條路徑套到邏輯視窗上。
    ///
    /// `makeKey` 只有在已經要求 `activateApp` 之後才把視窗算成 key
    /// （Apple：`makeKey` 保證的是「app 作用中時這扇是 key window」）。
    /// level 浮著直到使用者接手；成為 key 不會還原（`state.level` 維持 floating）。
    static func projectedState(for path: MacPreferencesShowPath) -> MacPreferencesFrontState {
        var state = MacPreferencesFrontState()
        perform(path) { action in
            switch action {
            case .moveToActiveSpace, .orderFrontRegardless, .promoteToRegularPolicy:
                break
            case .raiseLevelToFloating:
                state.level = .floating
            case .activateApp:
                state.activationRequested = true
            case .makeKey:
                if state.activationRequested {
                    state.isKey = true
                }
            case .holdFloatingUntilUserTakesOver:
                break
            case .bindCommandWToPerformClose:
                state.commandWCallsPerformClose = true
            }
        }
        return state
    }

    /// ⌘W：已接上 `performClose:`、而且視窗是 key，才關得掉。
    static func afterPerformClose(_ state: MacPreferencesFrontState) -> MacPreferencesFrontState {
        var state = state
        if state.commandWCallsPerformClose && state.isKey && MacPreferencesCommandW.invokesPerformClose(
            charactersIgnoringModifiers: "w",
            command: true,
            shift: false,
            option: false,
            control: false
        ) {
            state.isClosed = true
        }
        return state
    }
}
