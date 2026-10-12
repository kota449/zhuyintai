// SPDX-License-Identifier: Apache-2.0
import AppKit
import Foundation
import SwiftUI
import UpdateCheck

// 更新檢查的連網端（只給 Xcode 建置編；偏好設定的純 swiftc 渲染 probe 不編這支）。
//
// 行為：
// - 觸發＝每次 `activateServer` ＋ main.swift 啟動（`MacUpdateState.requestAutomaticCheck`）；
//   「每天最多一次」由 `UpdateChecker` 的 24 小時節流擋掉（失敗的自動嘗試也計入，見套件的 `checkAutomatically`）。
// - **資料不全或 slug 是佔位 ⇒ `UpdateCheckConfiguration` 回 nil ⇒ 不發任何請求**。
// - 背景非同步執行，不阻塞 `activateServer`；同時只跑一個（in-flight 防重入）。
// - 自動檢查失敗（含網路不通、feed 還沒上線）一律靜默；只有手動檢查會在關於頁顯示「暫時無法檢查。可以按下方「下載頁」看有沒有新版。」
// - 只通知，不下載、不安裝：「前往下載」是開瀏覽器。
// - 只會連線到 raw.githubusercontent.com 抓 feed.json；請求不帶任何打字內容。

@MainActor
final class MacUpdateService {
    static let shared = MacUpdateService()

    private let state: MacUpdateState
    private let store = UserDefaultsCheckStore(defaults: .standard)
    private let pending = PendingUpdateCache(defaults: .standard)
    private var inFlight = false
    /// 檢查進行中使用者又按了「檢查更新」：等這一輪結束後補跑一次真正的手動檢查（不是只顯示「檢查中…」就沒下文）。
    private var manualQueued = false
    private var latestRelease: Release?
    private var promptWindow: NSWindow?

    init(state: MacUpdateState = .shared) {
        self.state = state
    }

    /// 在 main.swift 呼叫一次：把狀態物件的 hook 接到這個服務，並還原上次找到的新版。
    static func install() {
        let service = MacUpdateService.shared
        MacUpdateState.shared.checkHook = { manual in
            Task { @MainActor in service.check(manual: manual) }
        }
        MacUpdateState.shared.promptHook = {
            Task { @MainActor in service.showPrompt() }
        }
        service.restorePendingRelease()
    }

    private func makeConfiguration() -> UpdateCheckConfiguration? {
        UpdateCheckConfiguration(infoDictionary: Bundle.main.infoDictionary)
    }

    private func makeChecker(_ config: UpdateCheckConfiguration) -> UpdateChecker {
        UpdateChecker(
            currentVersion: config.currentVersion,
            currentMacOSVersion: UpdateCheckConfiguration.macOSVersionString(ProcessInfo.processInfo.operatingSystemVersion),
            feedURL: config.feedURL,
            fetcher: URLSessionFeedFetcher(),
            store: store
        )
    }

    /// 24 小時節流存在 UserDefaults、跨重啟；新版若只放記憶體，輸入法一重啟提示就消失最多一天。
    /// 所以找到新版時一併存檔，啟動與被節流時從檔案還原（讀出時會重新驗證版本、略過、https）。
    private func restorePendingRelease() {
        guard let config = makeConfiguration(),
              let release = pending.load(currentVersion: config.currentVersion, skippedVersion: store.skippedVersion)
        else { return }
        publish(release)
    }

    private func publish(_ release: Release) {
        latestRelease = release
        state.setStatus(.available(MacUpdateInfo(
            version: release.version,
            downloadURL: release.downloadURL,
            notes: release.notes,
            isCritical: release.critical)))
    }

    func check(manual: Bool) {
        guard let config = makeConfiguration() else {
            // 佔位 slug／缺版本資料 ⇒ 不發請求；手動按鈕要有回應，不能按了沒反應。
            if manual { state.setStatus(.failed) }
            return
        }
        if inFlight {
            if manual {
                state.setStatus(.checking)
                manualQueued = true
            }
            return
        }
        let checker = makeChecker(config)
        inFlight = true
        if manual { state.setStatus(.checking) }
        Task { @MainActor in
            defer {
                inFlight = false
                if manualQueued {
                    manualQueued = false
                    check(manual: true)
                }
            }
            do {
                // 自動檢查走 checkAutomatically：失敗的嘗試也計入 24 小時節流（有套件測試）；手動檢查不受節流。
                let found = manual ? try await checker.check(manual: true) : try await checker.checkAutomatically()
                if let release = found {
                    pending.save(release)
                    publish(release)
                } else {
                    pending.clear()
                    latestRelease = nil
                    state.setStatus(.upToDate)
                }
            } catch UpdateCheckError.throttled {
                // 24 小時內檢查過：沒有新資訊，用上次存下的新版還原提示（沒有就保持原狀）。
                restorePendingRelease()
            } catch {
                // 自動檢查靜默；手動檢查才告訴使用者。
                if manual { state.setStatus(.failed) }
            }
        }
    }

    /// 使用者主動點開時才出現；絕不自動彈出（會搶打字焦點）。
    func showPrompt() {
        guard let release = latestRelease, let config = makeConfiguration() else { return }
        let checker = makeChecker(config)
        if let window = promptWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = UpdatePromptView(
            release: release,
            onSkip: { [weak self] in
                checker.skip(version: release.version)
                self?.pending.clear()
                self?.latestRelease = nil
                self?.state.setStatus(.idle)
                self?.closePrompt()
            },
            onLater: { [weak self] in self?.closePrompt() })
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "注音台有新版本"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        promptWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func closePrompt() {
        promptWindow?.close()
        promptWindow = nil
    }
}
