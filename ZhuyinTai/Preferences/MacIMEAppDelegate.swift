// SPDX-License-Identifier: Apache-2.0
import AppKit

/// 結束確認窗。使用者按結束（Dock 右鍵、Cmd-Q）時跳出，說明後果；系統登出／關機不經過這裡。
@MainActor
enum MacQuitConfirmationAlert {
    static func make() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = MacQuitConfirmationCopy.title
        alert.informativeText = MacQuitConfirmationCopy.message
        // 第一個按鈕＝預設（Return）。
        alert.addButton(withTitle: MacQuitConfirmationCopy.onlyCloseSettings)
        alert.addButton(withTitle: MacQuitConfirmationCopy.quit)
        return alert
    }

    /// 非阻塞：確認窗以 sheet 掛在偏好設定視窗上（視窗層級的 modal，app 的 run loop 照常跑，IMK 的訊息不會卡住）。
    /// **不能用 `runModal()`**：它跑巢狀 modal run loop，IMK 的訊息不被處理，使用者在別的 App 打字會整個停住，
    /// 確認窗沒人理就一直停。`completion(true)`＝使用者選了「結束注音台」。
    static func present(completion: @escaping (Bool) -> Void) {
        guard let window = MacPreferencesPresenter.windowForQuitConfirmation() else {
            completion(false)   // 沒有可掛的視窗（不該發生：只有設定視窗開著時才會是 regular）
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        make().beginSheetModal(for: window) { response in
            completion(response == .alertSecondButtonReturn)
        }
    }
}

/// 使用者按結束（Dock 右鍵結束、設定視窗是 key 時 Cmd-Q）：跳確認窗；預設只關設定視窗、輸入法留著。
/// 判斷在 `MacQuitPolicy`（純函式、有測試）；這裡只讀 Apple event 的 quit reason 與 willPowerOff 通知。
final class MacIMEAppDelegate: NSObject, NSApplicationDelegate {
    private let quitReason: () -> UInt32?
    private let askUser: (@escaping (Bool) -> Void) -> Void
    private let requestTerminate: () -> Void
    private let closeSettings: () -> Void
    private nonisolated(unsafe) var powerOffObserver: NSObjectProtocol?
    private var powerOffNoticed = false
    /// 確認窗還開著時又來一次結束要求（連按 Cmd-Q）：直接取消，不疊第二個窗。
    private var isAsking = false
    /// 使用者在確認窗選了「結束注音台」，下一次 `applicationShouldTerminate` 放行（只用一次）。
    private var confirmedQuit = false

    /// - Parameters:
    ///   - quitReason: 目前這次結束要求的 quit reason（'why?'）；預設讀目前的 Apple event。
    ///   - askUser: 非阻塞地跳確認窗；使用者回答後呼叫 completion（true＝選了「結束注音台」）。
    ///   - requestTerminate: 使用者確認結束後，重新要求結束（下一次 `applicationShouldTerminate` 放行）。
    ///   - closeSettings: 使用者選「只關閉設定視窗」時要做的事（關設定視窗、切回 accessory）。
    init(
        quitReason: @escaping () -> UInt32? = MacIMEAppDelegate.currentQuitReason,
        askUser: @escaping (@escaping (Bool) -> Void) -> Void = { completion in
            MainActor.assumeIsolated { MacQuitConfirmationAlert.present(completion: completion) }
        },
        requestTerminate: @escaping () -> Void = { NSApp.terminate(nil) },
        closeSettings: @escaping () -> Void = { MainActor.assumeIsolated { MacPreferencesPresenter.closeForQuitRequest() } }
    ) {
        self.quitReason = quitReason
        self.askUser = askUser
        self.requestTerminate = requestTerminate
        self.closeSettings = closeSettings
        super.init()
        powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.powerOffNoticed = true
        }
    }

    deinit {
        if let powerOffObserver { NSWorkspace.shared.notificationCenter.removeObserver(powerOffObserver) }
    }

    static func currentQuitReason() -> UInt32? {
        NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: MacQuitPolicy.quitReasonKeyword)?
            .enumCodeValue
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reason = quitReason()
        let decision = MacQuitPolicy.decide(quitReason: reason, powerOffNoticed: powerOffNoticed)
        switch decision {
        case .terminate:
            logDecision("terminate", answer: nil, reason: reason)
            return .terminateNow
        case .askUser:
            if confirmedQuit {
                confirmedQuit = false
                logDecision("terminate", answer: "confirmed", reason: reason)
                return .terminateNow
            }
            guard !isAsking else { return .terminateCancel }
            isAsking = true
            // 立刻取消這次結束，確認窗非阻塞地問；不在這裡等答案（見 `MacQuitConfirmationAlert.present`）。
            askUser { [weak self] wantsQuit in
                guard let self else { return }
                self.isAsking = false
                self.logDecision("ask", answer: wantsQuit ? "quit" : "closeSettings", reason: reason)
                if wantsQuit {
                    self.confirmedQuit = true
                    self.requestTerminate()
                } else {
                    self.closeSettings()
                }
            }
            return .terminateCancel
        }
    }

    private func logDecision(_ decision: String, answer: String?, reason: UInt32?) {
        let sink = MacIMEEventLogSink.shared
        guard sink.isEnabled else { return }
        sink.append(
            .note(
                seq: sink.nextSequence(), timestamp: Date(), kind: "quitRequest",
                detail: [
                    ("decision", decision),
                    ("answer", answer ?? "-"),
                    ("reason", reason.map(Self.fourCharString) ?? "none"),
                    ("powerOff", powerOffNoticed ? "1" : "0"),
                ]))
    }

    private static func fourCharString(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .macOSRoman) ?? String(code, radix: 16)
    }
}
