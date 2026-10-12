// SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI

// MARK: - 選單

enum MacThirdPartyNotices {
    static func show() {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") else {
            NSLog("[TWKeyboard] 找不到 ThirdPartyNotices.txt")
            return
        }
        NSWorkspace.shared.open(url)
    }
}

enum MacDiagnostics {
    /// 版本與 macOS build。不含網址、不含 email。
    static func report(bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return "注音台 \(version) (\(build))\n\(os)"
    }

    /// 關於頁顯示用的一行版本（診斷文字仍用 `report`）。
    static func versionLine(bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "版本 \(version)（\(build)）"
    }
}

// MARK: - 輸入分頁的偏好

/// 只寫 UserDefaults。日用打字 log 是否記錄看 `MacIMELogConsent`（見 `MacLogConsentViews.swift`），不看這裡。
enum MacGeneralPreferences {
    static let candidateTextSizeKey = "TWKeyboard.candidateTextSize"

    /// 中＝目前候選窗的 16pt（`PrefMgr.candidateListTextSize` 的既有預設）。
    enum CandidateTextSize: String, CaseIterable, Identifiable {
        case small
        case medium
        case large

        var id: String { rawValue }

        var label: String {
            switch self {
            case .small: return "小"
            case .medium: return "中"
            case .large: return "大"
            }
        }

        var points: Double {
            switch self {
            case .small: return 13
            case .medium: return 16
            case .large: return 20
            }
        }

        static func from(raw: String?) -> CandidateTextSize {
            guard let raw, let size = CandidateTextSize(rawValue: raw) else { return .medium }
            return size
        }
    }

    static func applySavedCandidateTextSize() {
        let raw = UserDefaults.standard.string(forKey: candidateTextSizeKey)
        applyCandidateTextSize(CandidateTextSize.from(raw: raw), reloadIfVisible: false)
    }

    static func applyCandidateTextSize(_ size: CandidateTextSize, reloadIfVisible: Bool) {
        PrefMgr.sharedSansDidSetOps.candidateListTextSize = size.points
        guard reloadIfVisible else { return }
        MainActor.assumeIsolated {
            let presenter = MacCandidateWindow.current
            if presenter.visible {
                presenter.reloadData()
            }
        }
    }
}

enum MacCustomPhraseLocation {
    static func libraryDirectory() -> URL? {
        guard let container = MacUserPhrasesLocation.platformContainerURL() else { return nil }
        guard MacUserPhrasesLocation.ensureDirectoryExists(inContainer: container) else { return nil }
        return container.appendingPathComponent(MacUserPhrasesLocation.libraryDirectoryName, isDirectory: true)
    }
}

// MARK: - 視窗

@MainActor
enum MacPreferencesPresenter {
    private static var window: NSWindow?
    private static let levelRestorer = MacPreferencesLevelRestorer()
    /// 每次點「偏好設定…」記三筆 `entry=prefs`（點下去當下、0.5 秒後、3 秒後），另有視窗事件，見 `MacPreferencesShowDiagnostics`。
    private static let diagnostics = MacPreferencesShowDiagnostics(
        read: { levelRestorer.snapshot(of: window) },
        emit: { snapshot in
            let sink = MacIMEEventLogSink.shared
            sink.append(
                MacIMEEventRecord(
                    seq: sink.nextSequence(),
                    timestamp: Date(),
                    fields: [("entry", "prefs"), ("pid", String(ProcessInfo.processInfo.processIdentifier))]
                        + snapshot.fields()
                )
            )
        },
        scheduleAfter: { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated { work() }
            }
        },
        isEnabled: { MacIMEEventLogSink.shared.isEnabled }
    )

    /// controller 的進入點記錄（`menu()`／`showPreferences` 開頭，MainActor hop 之前）。
    /// 走 thread-safe 的 sink，任何執行緒都能呼叫；log 關著就什麼都不做。
    nonisolated static func logEntry(phase: String, ctrl: String, client: String, item: String? = nil) {
        let sink = MacIMEEventLogSink.shared
        guard sink.isEnabled else { return }
        sink.append(
            MacIMEEventRecord(
                seq: sink.nextSequence(),
                timestamp: Date(),
                fields: [("entry", "prefs"), ("pid", String(ProcessInfo.processInfo.processIdentifier))]
                    + MacPreferencesEntryLog.fields(phase: phase, ctrl: ctrl, client: client, onMain: Thread.isMainThread, item: item)
            )
        )
    }

    /// 使用者在偏好設定開著時按 Cmd-Q／Dock 右鍵「結束」：輸入法不能跟著結束，只關設定視窗並切回 accessory。
    /// 視窗沒開（只剩 regular 殘留）就單純切回 accessory。
    static func closeForQuitRequest() {
        if let window, window.isVisible || window.isMiniaturized {
            window.performClose(nil)   // → windowWillClose → release(.closed)：切回 accessory、deactivate
        }
        if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// 結束確認窗要掛在哪個視窗上：偏好設定視窗（縮到 Dock 的先還原、排到最前）。沒有視窗回 nil。
    static func windowForQuitConfirmation() -> NSWindow? {
        guard let window else { return nil }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.orderFrontRegardless()
        return window
    }

    /// 輸入法是 `LSUIElement`（不在 Dock／Cmd-Tab）。
    /// `orderFrontRegardless()` 只把視窗搬到該層最前面，不改 key window；
    /// `makeKey()` 要等 app 作用中才會真的變成 key（標題列才不是灰的）。
    /// macOS 14 的 `NSApp.activate()` 是協作式、不保證成功，這支背景 app 先前會靜默失敗，
    /// 所以改呼叫 `activate(ignoringOtherApps: true)`。level 暫時 `.floating`，**浮著直到使用者接手**
    /// （點別的 app／點這扇視窗／關窗）才還原；成為 key 與下一個 run loop 都不還原（見
    /// `MacPreferencesFrontSession.arm` 的註解）。
    /// ⌘W 由視窗的 `performKeyEquivalent` 轉成 `performClose:`。
    /// - Parameters:
    ///   - requester: 觸發點擊的 controller 識別，只進診斷 log。
    ///   - client: 觸發當下的前景 client bundle id，只進診斷 log。
    static func show(requester: String = "-", client: String = "-") {
        levelRestorer.onWindowEvent = { diagnostics.recordEvent($0) }
        let path: MacPreferencesShowPath = self.window == nil ? .firstOpen : .alreadyOpen
        diagnostics.record(path: path, requester: requester, client: client) {
            let window: NSWindow
            if let existing = self.window {
                window = existing
            } else {
                let created = MacPreferencesWindowFactory.makeWindow()
                created.isReleasedWhenClosed = false
                created.center()
                self.window = created
                window = created
            }
            MacPreferencesFrontApplier.apply(path, to: window, restorer: levelRestorer)
        }
    }
}

// MARK: - 自訂詞

@MainActor
@Observable
final class MacCustomPhrasesModel {
    var entries: [UserCustomPhrasesStore.Phrase] = []
    var word = ""
    var slots: [MacReadingSlot] = []
    var status = ""
    private var directory: URL?
    private var lookedUpWord: String?
    @ObservationIgnored private nonisolated(unsafe) var changeObserver: NSObjectProtocol?

    /// 詞庫頁有兩個 model（查詞框那一側加詞、下方「我的自訂詞」列表）。任何一側加入／刪除都會發變更通知，
    /// 另一側靠它重讀，所以查詞框「加入我的詞庫」加完，同頁下方立刻看得到。
    init() {
        changeObserver = NotificationCenter.default.addObserver(
            forName: MacUserPhraseReload.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshEntries() }
        }
    }

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    }

    /// 收到變更通知只重讀列表，**不動 `status`**：詞庫包開關也會發同一個通知，不能把使用者正在看的錯誤句蓋掉；
    /// 還沒 `reload()` 過（不知道目錄）就不做事，等分頁出現時的 `reload()`。
    private func refreshEntries() {
        guard let directory else { return }
        entries = UserCustomPhrasesStore.load(from: directory)
    }

    func reload() {
        guard let directory = MacCustomPhraseLocation.libraryDirectory() else {
            self.directory = nil
            entries = []
            status = "無法讀取自訂詞的儲存位置"
            return
        }
        self.directory = directory
        entries = UserCustomPhrasesStore.load(from: directory)
    }

    func lookupReadings() {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        // 同一個詞再查一次會把使用者已改的破音字選項清掉。
        guard lookedUpWord != trimmed else { return }
        lookedUpWord = trimmed
        guard !trimmed.isEmpty else {
            slots = []
            return
        }
        let choices = MacReadingCatalog.choices(for: trimmed)
        slots = MacReadingSlot.slots(from: choices)
    }

    func add() {
        guard let directory else {
            status = "無法讀取自訂詞的儲存位置"
            return
        }
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        if lookedUpWord != trimmed { lookupReadings() }
        let reading = MacReadingSlot.reading(of: slots)
        switch UserCustomPhrasesStore.add(word: trimmed, reading: reading, in: directory) {
        case .success:
            resetDraft()
            entries = UserCustomPhrasesStore.load(from: directory)
            MacUserPhraseReload.postChange()
        case .failure(let error):
            status = error.message
        }
    }

    /// 清掉正在新增的草稿（詞、讀音格子、錯誤句）。`lookedUpWord` 也要清，否則同一個詞再查會被當成已查過。
    func resetDraft() {
        word = ""
        slots = []
        lookedUpWord = nil
        status = ""
    }

    func remove(_ phrase: UserCustomPhrasesStore.Phrase) {
        guard let directory else { return }
        switch UserCustomPhrasesStore.remove(word: phrase.word, reading: phrase.reading, in: directory) {
        case .success(let phrases):
            status = ""
            entries = phrases
            MacUserPhraseReload.postChange()
        case .failure(let error):
            status = error.message
        }
    }
}

/// 詞庫頁最下面的「我的自訂詞」：新增列＋已新增的詞。是 Form 裡的兩個 Section，不是獨立分頁。
struct MacCustomPhrasesSection: View {
    /// 由 `MacLexiconTab` 建一次再傳進來（不在 body 裡 new：每次 body 重算都建一個 model＋註冊通知觀察者）。
    @Bindable var model: MacCustomPhrasesModel
    @FocusState private var wordFieldFocused: Bool

    var body: some View {
        Group {
            Section {
                HStack {
                    TextField("詞", text: $model.word, prompt: Text("想加入的詞"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .focused($wordFieldFocused)
                        .onSubmit { model.lookupReadings() }
                    addButton
                }
                .onChange(of: wordFieldFocused) { _, focused in
                    if !focused { model.lookupReadings() }
                }
                if !model.slots.isEmpty {
                    ScrollView(.horizontal) {
                        if #available(macOS 26, *) {
                            GlassEffectContainer(spacing: 12) {
                                readingSlotsRow
                            }
                        } else {
                            readingSlotsRow
                        }
                    }
                }
                if !model.status.isEmpty {
                    Text(model.status)
                        .foregroundStyle(.red)
                }
            } header: {
                Label("新增自訂詞", systemImage: "plus")
            } footer: {
                Text("輸入詞之後按 Enter，或點到別處，就會帶出讀音。破音字用選單改，查不到的字請自行打注音。")
            }

            Section {
                if model.entries.isEmpty {
                    ContentUnavailableView("還沒有從這裡新增的詞", systemImage: "text.badge.plus")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                } else {
                    ForEach(model.entries, id: \.self) { phrase in
                        LabeledContent {
                            HStack {
                                Text(phrase.reading)
                                    .foregroundStyle(.secondary)
                                Button("刪除", role: .destructive) { model.remove(phrase) }
                            }
                        } label: {
                            Text(phrase.word)
                        }
                    }
                }
            } header: {
                Label("我的自訂詞", systemImage: "text.badge.plus")
            }
        }
        .onAppear { model.reload() }
    }

    private var readingSlotsRow: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach($model.slots) { $slot in
                MacReadingSlotView(slot: $slot)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var addButton: some View {
        if #available(macOS 26, *) {
            Button("新增") { model.add() }
                .buttonStyle(.glassProminent)
        } else {
            Button("新增") { model.add() }
                .buttonStyle(.borderedProminent)
        }
    }
}

struct MacReadingSlotView: View {
    @Binding var slot: MacReadingSlot

    var body: some View {
        Group {
            if #available(macOS 26, *) {
                slotContent
                    .padding(8)
                    .glassEffect(.regular, in: .rect(cornerRadius: 10))
            } else {
                slotContent
            }
        }
    }

    private var slotContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(slot.character)
                .font(.caption)
                .foregroundStyle(.secondary)
            if slot.manual {
                TextField("注音", text: $slot.selection)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
            } else if slot.readings.count <= 1 {
                Text(slot.selection)
                    .frame(minWidth: 36, alignment: .leading)
            } else {
                Picker(slot.character, selection: $slot.selection) {
                    ForEach(slot.readings, id: \.self) { reading in
                        Text(reading).tag(reading)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 72)
            }
        }
    }
}

// MARK: - 關於

/// 直接從 bundle 讀圖示；NSApp.applicationIconImage 走系統圖示快取，
/// 輸入法（背景行程）的快取常不更新，會顯示舊圖。
enum MacAboutIcon {
    static func load() -> NSImage {
        NSImage(named: "AppIcon")
            ?? Bundle.main.image(forResource: "AppIcon")
            ?? NSApp.applicationIconImage
    }
}

struct MacAboutTab: View {
    @State private var copied = false
    @State private var updateStatus = MacUpdateState.shared.status
    @State private var autoCheck = MacUpdateState.shared.autoCheckEnabled

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            VStack(spacing: 8) {
                Image(nsImage: MacAboutIcon.load())
                    .resizable()
                    .frame(width: 96, height: 96)
                Text("注音台")
                    .font(.title.bold())
                Text(MacDiagnostics.versionLine())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(.bottom, 8)
            // 更新檢查：只通知、不下載；有新版也不會自己彈窗（輸入法在背景，彈窗會搶打字焦點）。
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    Button("檢查更新") { MacUpdateState.shared.requestManualCheck() }
                        .macPrefsGlassButtonStyle(prominent: false)
                    if case .available = updateStatus {
                        Button("查看新版本…") { MacUpdateState.shared.presentPrompt() }
                            .macPrefsGlassButtonStyle(prominent: true)
                    }
                }
                if !updateStatus.isIdle {
                    Text(MacUpdateState.shared.statusLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Toggle("自動檢查新版", isOn: $autoCheck)
                    .toggleStyle(.checkbox)
                    .onChange(of: autoCheck) { _, on in MacUpdateState.shared.autoCheckEnabled = on }
                Text("只會連到 GitHub 看有沒有新版，不會傳送你打的任何字。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onReceive(NotificationCenter.default.publisher(for: MacUpdateState.didChange)) { _ in
                updateStatus = MacUpdateState.shared.status
            }
            HStack(spacing: 10) {
                Button("網站") {
                    if let url = MacReleaseLinks.homeURL { NSWorkspace.shared.open(url) }
                }
                .macPrefsGlassButtonStyle(prominent: false)
                Button("下載頁") {
                    if let url = MacReleaseLinks.releasesURL { NSWorkspace.shared.open(url) }
                }
                .macPrefsGlassButtonStyle(prominent: false)
                Button("隱私說明") {
                    if let url = MacReleaseLinks.privacyURL { NSWorkspace.shared.open(url) }
                }
                .macPrefsGlassButtonStyle(prominent: false)
            }
            Button("開放原始碼授權…") {
                MacThirdPartyNotices.show()
            }
            .macPrefsGlassButtonStyle(prominent: false)
            Button("回報問題") {
                // 備援：網頁打不開（離線、repo 還沒公開）時，使用者仍可把剪貼簿內容貼給開發者。
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(MacDiagnostics.report(), forType: .string)
                copied = true
                if let url = MacIssueReport.url(report: MacDiagnostics.report()) {
                    NSWorkspace.shared.open(url)
                }
            }
            .macPrefsGlassButtonStyle(prominent: true)
            Text(copied
                ? "已在瀏覽器開啟回報頁，並複製了診斷資訊（網頁打不開時貼給開發者就好）。"
                : "按「回報問題」會在瀏覽器開 GitHub 回報頁，預填版本與系統資訊，不含你打的字。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension View {
    @ViewBuilder
    func macPrefsGlassButtonStyle(prominent: Bool) -> some View {
        if #available(macOS 26, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            self
        }
    }
}
