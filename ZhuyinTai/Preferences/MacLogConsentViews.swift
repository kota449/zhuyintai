// SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI

// 打字 log 的設定頁畫面：「隱私」分頁裡的開關＋匯出＋清除。
//
// 🔴 設計決定：本機打字 log **預設開、不彈同意窗**；改在安裝說明與這一頁告知。
// 文案原則：台灣繁中、白話、不誇大；不提「AI」，也不講「上傳」。
// 要老實講的事：log 裡有**按鍵、候選字，以及最後打出的字**（`committedText`），還有**時間與前景 App 名稱**——所以說明裡都列；
// 密碼欄位不記（`MacIMEEventLogSink` 的 secure input 抑制）。
//
// 這支只依賴 SwiftUI／AppKit 與 `EventLog/` 的純邏輯，可以單獨編進離屏渲染的 probe
// （`tools/render_mac_prefs.sh`），不必起整個輸入法。

// MARK: - 文案

enum MacLogConsentCopy {
    static let settingsToggle = "記錄打字過程"
    static let settingsCaption = "預設開啟：記下你按的鍵、候選字、打出來的字，以及時間和你正在用的 App 名稱（密碼欄位除外）。只存在這台 Mac、只保留約一週，不會自己送到任何地方，可隨時關閉。"
    static let exportButton = "匯出 log…"
}

// MARK: - 設定頁「隱私」分頁的區塊

@MainActor
@Observable
final class MacLogConsentSettingsModel {
    var isOn = false
    var stateLabel = ""
    var exportStatus = ""

    private let consent: MacIMELogConsent
    private let logDirectory: () -> URL?

    init(consent: MacIMELogConsent = .shared,
         logDirectory: @escaping () -> URL? = { MacIMEEventLogSink.logDirectoryURL() }) {
        self.consent = consent
        self.logDirectory = logDirectory
        refresh()
    }

    func refresh() {
        let state = consent.state
        isOn = consent.isRecordingEnabled
        switch state {
        case .granted: stateLabel = "目前：記錄中"
        case .denied: stateLabel = "目前：已關閉"
        case .unasked: stateLabel = "目前：記錄中（預設）"
        }
    }

    func setOn(_ on: Bool) {
        consent.set(on ? .granted : .denied)
        if on { MacIMEEventLogSink.shared.logStartupDiagnostics() }
        refresh()
    }

    /// 匯出前不做任何上傳：只讀 log 目錄、只寫使用者選的路徑。
    func exportLog() {
        guard let directory = logDirectory() else {
            exportStatus = "找不到 log 的位置"
            return
        }
        let panel = NSSavePanel()
        panel.title = "匯出 log"
        panel.nameFieldStringValue = Self.suggestedFileName()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            // 檔案可能很大（每天約 4 MB、最多留一週），離開 main thread 再複製。
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = Result {
                    try MacIMELogExport.export(from: directory, to: destination, preamble: MacDiagnostics.report())
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.exportStatus = Self.message(for: outcome) }
                }
            }
        }
    }

    static func suggestedFileName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "ZhuyinTai-log-\(formatter.string(from: now)).txt"   // 使用者在存檔對話框看得到：用對外名稱
    }

    static func message(for outcome: Result<MacIMELogExport.Summary, Error>) -> String {
        switch outcome {
        case .success(let summary):
            let size = ByteCountFormatter.string(fromByteCount: Int64(summary.byteCount), countStyle: .file)
            return "已匯出 \(summary.fileNames.count) 個檔案（\(size)）"
        case .failure(MacIMELogExport.ExportError.noLogFiles):
            return "目前沒有可匯出的 log"
        case .failure(let error):
            return "匯出失敗：\(error.localizedDescription)"
        }
    }
}

/// 隱私分頁的內容：記錄開關（含目前狀態）、匯出、清除。
/// 「目前：…」那行保留：分得出「預設開」與「使用者自己開」。
struct MacLogConsentSection: View {
    @State private var model = MacLogConsentSettingsModel()
    @State private var confirmClearLogs = false
    @State private var clearLogStatus = ""
    @State private var confirmClearChoices = false
    @State private var clearChoicesStatus = ""

    var body: some View {
        Group {
            Section {
                Toggle(
                    MacLogConsentCopy.settingsToggle,
                    isOn: Binding(get: { model.isOn }, set: { model.setOn($0) })
                )
            } header: {
                Label("打字記錄", systemImage: "hand.raised")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(MacLogConsentCopy.settingsCaption)
                    Text(model.stateLabel)
                }
            }

            // 說明文字以 release/docs/PRIVACY.md 為準，見 MacPrivacyCopy（有測試對照）。
            Section {
                ForEach(MacPrivacyCopy.rows, id: \.title) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(.subheadline.weight(.semibold))
                        Text(row.body)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
                LabeledContent("在瀏覽器看完整說明") {
                    Button(MacPrivacyCopy.fullPolicyButton) {
                        if let url = MacReleaseLinks.privacyURL { NSWorkspace.shared.open(url) }
                    }
                }
            } header: {
                Label(MacPrivacyCopy.sectionTitle, systemImage: "lock.shield")
            }

            Section {
                LabeledContent("把記錄存成一個文字檔") {
                    Button(MacLogConsentCopy.exportButton) { model.exportLog() }
                }
                LabeledContent("刪除這台 Mac 上的所有記錄") {
                    Button("清除使用紀錄", role: .destructive) { confirmClearLogs = true }
                        .confirmationDialog(
                            "要刪除這台 Mac 上注音台記錄的所有使用紀錄嗎？這個動作無法復原。",
                            isPresented: $confirmClearLogs,
                            titleVisibility: .visible
                        ) {
                            Button("刪除", role: .destructive) {
                                clearLogStatus = MacIMEEventLogSink.shared.clearAll() ? "已刪除" : "無法刪除"
                            }
                            Button("取消", role: .cancel) {}
                        }
                }
            } header: {
                Label("紀錄檔", systemImage: "internaldrive")
            } footer: {
                if !model.exportStatus.isEmpty || !clearLogStatus.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        if !model.exportStatus.isEmpty { Text(model.exportStatus) }
                        if !clearLogStatus.isEmpty { Text(clearLogStatus) }
                    }
                }
            }

            if MacChoiceLearning.isAvailable {
                Section {
                    LabeledContent("忘掉注音台記住的所有選字") {
                        Button("清除選字記憶", role: .destructive) { confirmClearChoices = true }
                            .confirmationDialog(
                                "要刪除注音台記住的所有選字嗎？之後同樣的前文與讀音會回到預設排序。這個動作無法復原。",
                                isPresented: $confirmClearChoices,
                                titleVisibility: .visible
                            ) {
                                Button("刪除", role: .destructive) {
                                    MacChoiceLearning.clearAll()
                                    clearChoicesStatus = "已清除"
                                }
                                Button("取消", role: .cancel) {}
                            }
                    }
                } header: {
                    Label("選字記憶", systemImage: "brain")
                } footer: {
                    if !clearChoicesStatus.isEmpty { Text(clearChoicesStatus) }
                }
            }
        }
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: MacIMELogConsent.didChangeNotification)) { _ in
            model.refresh()
        }
    }
}

/// 「隱私」分頁。
struct MacPrivacyTab: View {
    var body: some View {
        Form {
            MacLogConsentSection()
        }
        .formStyle(.grouped)
    }
}
