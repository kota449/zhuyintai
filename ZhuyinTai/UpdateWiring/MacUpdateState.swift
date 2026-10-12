// SPDX-License-Identifier: Apache-2.0
import Foundation

// 更新檢查在 app 端的「狀態與接點」。
//
// 🔴 這支**只能 import Foundation**：偏好設定的離屏渲染（`tools/render_mac_prefs.sh`）用純 swiftc 編，
// 關於頁／輸入法選單只依賴這支，不 import UpdateCheck；真正連網的是只給 Xcode 編的 `MacUpdateService`，
// 它在 main.swift 把 `checkHook`／`promptHook` 接進來。沒接（例如渲染 probe）⇒ 呼叫都是無害的空操作。
//
// 設計取捨（對 `Packages/UpdateCheck/README.md`「顯示提示視窗」的**刻意偏離**）：
// 輸入法是背景行程，隨時可能有人正在打字；自己彈視窗會搶焦點、打斷輸入。
// 所以檢查在背景做，有新版只在輸入法選單多一項、關於頁顯示；提示視窗只在使用者主動點開時才出現。

/// 可用的新版本（App 端的精簡型別，不依賴 UpdateCheck 的 `Release`）。
struct MacUpdateInfo: Equatable, Sendable {
    let version: String
    let downloadURL: URL
    let notes: String?
    let isCritical: Bool
}

enum MacUpdateStatus: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(MacUpdateInfo)
    /// 網路或解析失敗。刻意不帶技術細節給使用者看。
    case failed

    var isIdle: Bool { self == .idle }
}

final class MacUpdateState: @unchecked Sendable {
    static let shared = MacUpdateState()

    /// 「自動檢查新版」開關的 UserDefaults 鍵（預設開）。
    static let autoCheckKey = "TWKeyboard.autoUpdateCheck"
    /// 狀態改變時發出（物件是這個 state）。關於頁靠它重畫。
    static let didChange = Notification.Name("TWKeyboard.MacUpdateState.didChange")

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let lock = NSLock()
    private var _status: MacUpdateStatus = .idle

    /// 實際去檢查的動作（參數＝是否使用者手動觸發）。由 main.swift 接上 `MacUpdateService`。
    var checkHook: ((_ manual: Bool) -> Void)?
    /// 顯示提示視窗的動作。由 main.swift 接上。
    var promptHook: (() -> Void)?

    init(defaults: UserDefaults = .standard, notificationCenter: NotificationCenter = .default) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
    }

    // MARK: 開關

    var autoCheckEnabled: Bool {
        get { defaults.object(forKey: Self.autoCheckKey) == nil ? true : defaults.bool(forKey: Self.autoCheckKey) }
        set { defaults.set(newValue, forKey: Self.autoCheckKey) }
    }

    // MARK: 狀態

    var status: MacUpdateStatus {
        lock.lock(); defer { lock.unlock() }
        return _status
    }

    /// 設定狀態；值真的變了才發通知。
    func setStatus(_ new: MacUpdateStatus) {
        lock.lock()
        let changed = _status != new
        _status = new
        lock.unlock()
        if changed { notificationCenter.post(name: Self.didChange, object: self) }
    }

    /// 輸入法選單要加的那一項；沒有新版就是 nil。
    var menuItemTitle: String? {
        if case .available(let info) = status { return "有新版本 \(info.version)…" }
        return nil
    }

    /// 關於頁顯示的一行狀態（idle 為空字串）。
    var statusLine: String {
        switch status {
        case .idle: return ""
        case .checking: return "檢查中…"
        case .upToDate: return "目前已是最新版。"
        case .available(let info): return "有新版本 \(info.version) 可以下載。"
        case .failed: return "暫時無法檢查。可以按下方「下載頁」看有沒有新版。"
        }
    }

    // MARK: 動作

    /// 自動檢查（啟用輸入法、啟動時呼叫）：開關關著就**完全不呼叫**，不會有任何請求。
    /// 24 小時節流由 UpdateCheck 的 `UpdateChecker` 負責，這裡不重複實作。
    func requestAutomaticCheck() {
        guard autoCheckEnabled else { return }
        checkHook?(false)
    }

    /// 手動檢查（關於頁的按鈕）：不受開關與 24 小時節流影響。
    func requestManualCheck() {
        checkHook?(true)
    }

    /// 顯示提示視窗；只有「有新版」時才有效。
    func presentPrompt() {
        guard case .available = status else { return }
        promptHook?()
    }
}
