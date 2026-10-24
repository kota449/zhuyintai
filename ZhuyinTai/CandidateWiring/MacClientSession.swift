// SPDX-License-Identifier: Apache-2.0
// per-client session：狀態機、組音緩衝、候選窗轉接層，全部收在這裡（產品決策）。
//
// 🔴 **為什麼是 per-client 而不是掛在 controller 上的 process-wide 可變狀態**
// （spec §7／§8 缺口③）：`IMKServer` 會替**每一個 client app** 建一個
// `IMKInputController` 實例，但候選窗（`private static let thePool`／`currentView`）
// 候選窗是 process-wide 單例。引擎不是：每個 session 在建構時拿到自己的那一份
// （G8 Stage 2）。G2 的狀態機、緩衝、窗的 delegate 也在這個物件上。
//
// 🔴 不變式 1：窗是 process-wide 單例 ⇒ **同一時間至多一個 client 處於 `Selecting`**。
// `deactivateServer` 一律先關窗。

import AppKit
import InputMethodKit

// MARK: - 行程內唯一的候選窗

/// 候選窗控制器的 process-wide 單例。
///
/// `CtlCandidateGSI4AppKit` 的資料池與視圖本來就是 `static`（上游設計），
/// 每 new 一個控制器就多一個 `NSPanel` 共用同一個池 ⇒ 只能有一個。
/// `delegate` 則是 per-client：進入 `Selecting` 前指到該 client 的 session。
@MainActor
enum MacCandidateWindow {
    /// 生產路徑用的實體窗（上游控制器）。`CandidatePool4AppKit` 的資料池與視圖本來就是
    /// `static`，每 new 一個控制器就多一個 `NSPanel` 共用同一個池 ⇒ 只能有一個。
    static let shared: GSI4AppKit.CtlCandidateGSI4AppKit = .init(.horizontal)

    /// 🔴 **測試注入點。** `MacClientSession` 只透過這裡取得窗，而且只認
    /// `MacCandidateWindowPresenting` —— headless 測試塞一個假的進來，就能在
    /// **不建 `NSPanel`、不裝上機器、不用人按鍵**的情況下斷言整條 session 路徑。
    /// 理由全文見 `MacCandidateWindowPresenting.swift` 檔頭（它不是為抽象而抽象）。
    static var current: MacCandidateWindowPresenting = shared
}

// MARK: - G7 游標離開組字區

/// 偵測到宿主游標離開 marked range 時要不要真的定案。
///
/// 預設 `.observe`：只記 `entry=cursorMovedWouldFire`，不送 `.clientCursorMoved`。
/// 真 app（Electron、瀏覽器、終端機）回報的 range 可能不準，誤判會在正常打字時提前送字。
/// `.enabled` 維持 `434e5aa5`：偵測到就定案。狀態機對 `.clientCursorMoved` 的處理不變。
enum MacG7CursorLeavePolicy: Equatable {
    case observe
    case enabled
}

// MARK: - Mac 輸入法專用的效能調校（輸出不變）

/// 只有 Mac 輸入法打開、iOS 不碰的「輸出不變」加速開關（2026-09-30 長句逐鍵延遲）。
///
/// 每一項都必須滿足：**關掉與打開的輸出逐位元相同**，且各自在
/// `MacLongLatencyEquivalenceCLI` 有等價性＋速度回歸測試。會改變輸出的東西不准放這裡
/// （那是產品取捨，要產品決策）。
///
/// 呼叫端：`TWKeyboardMacSpikeController.init`（真輸入法，**預設開**；關閉逃生口見 `disableDefaultsKey`）、`MacLongLatencyReplayCLI`（重播量測）。
enum MacIMEPerfTuning {
    /// KenLM 查詢結果快取（每代筆數；兩代約 2 倍）。每筆約 200 B ⇒ 上限約 6MB，
    /// 對 ~60MB 的輸入法常駐記憶體可以接受。
    static let kenLMScoreCacheCapacity = 16384

    /// 整批推論結果記憶（每代批數；兩代約 2 倍）。每批約 1KB ⇒ 上限約 1MB。
    /// 只在對應功能開啟時才有東西可記；關閉時完全不佔記憶。
    static let neuralScoreMemoCapacity = 512

    /// 關閉逃生口：`defaults write com.kota.xrich.inputmethod.TWKeyboard TWKDisablePerfTuning -bool YES`
    /// 然後重啟輸入法（登出入或 `killall TWKeyboard`）。**Mac 輸入法預設是開的**（預設關的話
    /// 使用者裝上去不會變快）；萬一發現任何行為差異，用這條立刻退回改前的路徑而不必重裝。
    static let disableDefaultsKey = "TWKDisablePerfTuning"

    static func apply() {
        guard !UserDefaults.standard.bool(forKey: disableDefaultsKey) else { return }
        MacEngineTuning.setScoreCacheCapacities(kenLM: kenLMScoreCacheCapacity, neural: neuralScoreMemoCapacity)
    }
}

/// Mac 輸入法專用、**會改變輸出**的行為開關（與上面「輸出不變」的 `MacIMEPerfTuning` 分開）。
/// 出貨 json 是 iOS／Mac 共用的，iOS 沒量過 ⇒ 開關不放 json，由 Mac 輸入法啟動時打開。
///
/// 目前只有一項：單鍵＋左文空時同音字改看詞庫排序（嗎≠媽），
/// **只對終端機宿主開**（終端機是特例，其他 app 應從根本修好）。
/// 終端機回報游標＝0、讀不到上文，與真句首同一個訊號，所以只能看 bundle id；真句首與其他 app 維持原行為。
/// 關閉逃生口：`defaults write com.kota.xrich.inputmethod.TWKeyboard TWKDisableLoneKeyHomophoneOrder -bool YES`
/// 然後重啟輸入法。反過來「不分宿主一律開」：`TWKLoneKeyHomophoneOrderAllHosts -bool YES`（出貨預設關）。
enum MacIMEShippingBehavior {
    static let disableLoneKeyHomophoneOrderDefaultsKey = "TWKDisableLoneKeyHomophoneOrder"
    static let allHostsDefaultsKey = "TWKLoneKeyHomophoneOrderAllHosts"

    /// 終端機類宿主的 bundle id。**查證狀態**（2026-10-07，`mdls -name kMDItemCFBundleIdentifier` 本機實測）：
    /// cmux／Terminal／Ghostty 已實機查證；iTerm2／Warp／kitty／Alacritty／WezTerm 本機沒裝，
    /// 拼字來自各專案公開文件，**未實機查證**——拼錯的後果只是那個 app 沒套用（維持原行為），不會誤傷別的 app。
    static let terminalBundleIDs: Set<String> = [
        "com.cmuxterm.app",             // 已查證
        "com.apple.Terminal",           // 已查證
        "com.mitchellh.ghostty",        // 已查證
        "com.googlecode.iterm2",        // 未實機查證
        "dev.warp.Warp-Stable",         // 未實機查證
        "net.kovidgoyal.kitty",         // 未實機查證
        "org.alacritty",                // 未實機查證
        "com.github.wez.wezterm",       // 未實機查證
    ]

    static func isTerminalHost(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return terminalBundleIDs.contains(bundleID)
    }

    static func apply() {
        let defaults = UserDefaults.standard
        let disabled = defaults.bool(forKey: disableLoneKeyHomophoneOrderDefaultsKey)
        MacEngineTuning.loneKeyHomophoneOrderTerminalHosts = !disabled
        MacEngineTuning.loneKeyHomophoneOrderAllHosts = !disabled && defaults.bool(forKey: allHostsDefaultsKey)
    }
}

// MARK: - session

@MainActor
final class MacClientSession: NSObject, CtlCandidateDelegate {
    /// 預設觀察模式。劇本 21a–21d 在開場改成 `.enabled`。
    static var cursorLeavePolicy: MacG7CursorLeavePolicy = .observe

    /// 「接上文」的關閉逃生口（比照 `MacIMEPerfTuning.disableDefaultsKey`）：
    /// `defaults write com.kota.xrich.inputmethod.TWKeyboard TWKDisableLeftContext -bool YES`
    /// 然後重啟輸入法（登出入或 `killall TWKeyboard`）。**預設＝開**。設了就**完全不讀 client、不餵引擎**
    /// （Mac 回到接線前的行為）——離線量測 EPUB 偏負、真宿主可能丟 NSException 時，這是不必重裝就能退回的路。
    /// 第一次用到時讀一次 defaults（＝行程啟動後，要重啟才生效）；劇本直接改 `leftContextEnabled`。
    static let disableLeftContextDefaultsKey = "TWKDisableLeftContext"
    static var leftContextEnabled = !UserDefaults.standard.bool(forKey: disableLeftContextDefaultsKey)
    // MARK: 狀態

    private var machine = MacCandidateModeMachine(
        firstToneMark: MacZhuyinConstants.firstToneMark
    )
    private let engine: any MacZhuyinEnginePort

    /// Q-P1=b：全形預設、半形是這個 client 自己的開關。不進引擎（不影響組字），
    /// 切走也不重置——跟組字緩衝一樣跟著 session 活著。
    /// Stage 2 預留，尚未接線：目前只有 `SessionEnginePortChecks` 讀寫，輸入路徑還沒讀它。
    var isHalfWidthPunctuation = false

    init(engine: any MacZhuyinEnginePort) {
        self.engine = engine
        super.init()
        MacEnglishIndicator.installLanguageObserver()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userPhrasesDidChange),
            name: MacUserPhraseReload.didChange,
            object: nil
        )
    }

    /// 自訂詞檔改了。下一輪組字走重讀後的詞庫；不切輸入法。
    @objc private func userPhrasesDidChange() {
        guard let container = MacUserPhraseReload.containerURL() else { return }
        engine.reloadUserPhrases(fromContainer: container)
    }

    /// 開窗當下的候選**快照**（不變式 6）。
    ///
    /// 🔴 **接線端不得對它去重／過濾／重排**——窗的 index 必須與
    /// `engine.setHighlightedCandidate(index:)` 的 index 一一對應，兩邊只要有一邊動過順序，
    /// 使用者按下的就會是另一個字。
    private var candidateSnapshot: [String] = []

    /// 這個 session 對應的 client。IMK 每次呼叫都會把 client 傳進來，這裡只留最後一次的，
    /// 給窗的定位（`candidateWindowOriginInfo`）與 `deactivateServer` 用。
    private weak var client: IMKTextInput?

    var isActive = false

    /// 最後一個被啟用的 session（行程唯一）。英文模式浮標只聽它的：IMK 的 deactivate 可能晚到，
    /// 這時舊 session 手上若還有排程中的位置更新，不得把新 session 的浮標搶回去
    ///（擁有者檢查只擋 hide，擋不住 show）。
    private static weak var latestActivated: MacClientSession?

    // MARK: 偏好（可注入，劇本用）

    /// 非 nil ⇒ 蓋過偏好（劇本注入用，不寫 UserDefaults）。
    var unfinishedPolicyOverride: MacUnfinishedZhuyinPolicy?
    var shiftTapEnabledOverride: Bool?

    // MARK: 生命週期

    func activate(client: IMKTextInput?) {
        self.client = client
        isActive = true
        Self.latestActivated = self
        // 換 client（或同一個 client 回來）：上文一律不沿用，下一次開始組字時向這個 client 重讀。
        resetLeftContext()
        logLifecycle("activateServer")
        // 換 app 時語言是行程共用的，仍是英文就要在這個 app 的游標旁顯示（G15）。
        // 排到下一圈 run loop：activate 當下宿主的游標位置可能還沒就緒。
        if MacInputModeState.language == .en { scheduleEnglishIndicatorUpdate() }
    }

    /// R7（G8 階段 0 探針）：生命週期事件。
    ///
    /// 三個 G8 設計的關鍵未知數只有實機 log 能回答：
    /// ① IMK 到底有沒有**重用 controller 實例**（`ctrl` 的 `ObjectIdentifier`）
    /// ② controller 是 per input session 還是 per app（IMK 標頭說前者）
    /// ③ `activate`／`deactivate` 的實際順序與間隔（`sinceDeact_ms`；標頭說沒有時序保證）
    ///
    /// 它順便回答 R4d：實機 log 中途冒出第二筆 `kind=startup`，到底是 IMK 正常行為還是 crash。
    func logLifecycle(_ kind: String) {
        guard MacIMEEventLogSink.shared.isEnabled else { return }
        let gap = lastDeactivateAt.map { Int(Date().timeIntervalSince($0) * 1000) }
        MacIMEEventLogSink.shared.append(
            .lifecycle(
                seq: MacIMEEventLogSink.shared.nextSequence(),
                timestamp: Date(),
                kind: kind,
                controllerID: ownerIdentifier,
                clientBundleID: client?.bundleIdentifier() ?? "?",
                markedRange: client.map { String(describing: $0.markedRange()) },
                msSinceLastDeactivate: gap,
                processID: ProcessInfo.processInfo.processIdentifier
            )
        )
    }

    /// 持有這個 session 的 `IMKInputController` 的 `ObjectIdentifier`（十六進位）。
    /// 由 controller 在建立時填入——**判斷 IMK 有沒有重用實例的唯一依據**。
    var ownerIdentifier = "?"
    /// 上一次 `deactivate` 的時刻，用來算 `sinceDeact_ms`。
    private var lastDeactivateAt: Date?
    /// 這次 deactivate 之後，是否已經記過「第一個按鍵」那一筆（每次 deactivate 重置）。
    private var reportedFirstKeySinceDeactivate = false

    /// 失去焦點。
    ///
    /// **本輪的做法：保留這個 client 自己的組字，不 commit 到別人那裡。**
    ///
    /// ⚠️ **這個選擇建立在一個未實測的推論上**（`mac-g8-design` 指出，已核實）：
    /// 我原本寫「`deactivateServer` 之後 `insertText` 會落在下一個 app」——**那是推論不是實測**。
    /// 而且 **McBopomofo 在 `deactivate` 時正是 commit 給該 client**，做法與我相反。
    /// 另外 IMK 標頭說 controller 是 **per input session（不是 per app）**，
    /// 且 `activate`／`deactivate` **沒有時序保證**。
    /// ⇒ 哪一種對是 **需要產品決策的**。生命週期 log 上機之後
    /// 就能實測（`sinceDeact_ms`、`ctrl` 的 `ObjectIdentifier`）。
    func deactivate() {
        isActive = false
        if Self.latestActivated === self { Self.latestActivated = nil }
        // A 的上文留在 A 自己的引擎上。組字進行中引擎會忽略這次清除（守衛），
        // 切回來仍是這份組字的左文；B 用的是另一份引擎，讀不到 A 的值。
        resetLeftContext()
        logLifecycle("deactivateServer")
        lastDeactivateAt = Date()
        reportedFirstKeySinceDeactivate = false
        // 「丟掉」的處理要在 `.deactivate` 之前——machine 轉狀態之後再送 ⌫ 可能被忽略。
        // 候選窗開著時第一個 ⌫ 只關窗，迴圈會再送一次真正拿掉殘段的 ⌫。
        dropTrailingFragmentOnDeactivateIfDiscarding()
        dispatch(.deactivate)
        // 不變式 1 的兜底：即使狀態機認為沒窗（例如狀態已在 typing），也強制關一次。
        if MacCandidateWindow.current.delegate === self {
            MacCandidateWindow.current.visible = false
        }
        composedReadingColumns = []
        refreshReadingPanel()
        // 只藏自己的：IMK 沒有 activate／deactivate 的時序保證，B 先啟用、A 才失去焦點時，
        // A 不得把 B 剛顯示的浮標藏掉（浮標記著擁有者）。
        // 中文模式根本沒有浮標（英→中的路徑已統一藏掉），不必白呼叫。
        if MacInputModeState.language == .en { MacEnglishIndicator.current.hide(owner: self) }
    }

    // MARK: 英文模式浮標（G15）

    /// 按鍵之後等多久才查游標位置（秒）：放行之後宿主還要一點時間把字插進去，太早查會落後一格。
    static var englishIndicatorSettleDelay: TimeInterval = 0.06
    /// 兩次位置查詢的最短間隔（秒）。實際間隔還會依上一次查詢的耗時拉長（慢宿主自動查得更稀）。
    static var englishIndicatorMinInterval: TimeInterval = 0.12
    /// 連續打字時，位置更新最久等多久（秒）：不讓「一直有新鍵」把更新無限往後推。
    static var englishIndicatorMaxWait: TimeInterval = 0.3
    /// 依耗時拉長後的查詢間隔上限（秒）：一次偶發的慢查詢不能讓浮標好幾秒不更新。
    static var englishIndicatorMaxInterval: TimeInterval = 0.5

    /// 有一筆合併中的位置更新排著。
    private var englishIndicatorUpdatePending = false
    private var englishIndicatorPendingSince = Date()
    private var englishIndicatorLastKeyAt = Date.distantPast
    /// 上一次位置查詢的開始時刻與耗時：下一次查詢的最短間隔＝max(固定下限, 耗時 × 8)，慢宿主自動查得更稀。
    private var englishIndicatorLastQueryAt: Date?
    private var englishIndicatorLastQueryCost: TimeInterval = 0
    /// 上一次更新是不是拿得到游標位置（只在翻轉時寫 log，免得英文連打每鍵一行）。
    private var englishIndicatorHadCaretRect: Bool?

    /// 英文模式每鍵／點擊之後更新浮標位置。三個設計：
    /// - **放行之後才做**：位置查詢是跨行程呼叫，同步做會把成本加在每一鍵送到宿主之前（G9）。
    /// - **等宿主插入字元**（`englishIndicatorSettleDelay`）：放行之後宿主還要一點時間把字插進去，
    ///   太早查拿到的是插字前的游標，浮標會落後一格。連續打字最久等 `englishIndicatorMaxWait`，不被無限往後推。
    /// - **節流**：兩次查詢至少隔 `englishIndicatorMinInterval`，且依上一次查詢耗時自動拉長
    ///   （Electron 等慢宿主不能被每鍵一次的跨行程查詢拖慢）。連打合併成一筆，打完最後一次位置仍會更新。
    private func scheduleEnglishIndicatorUpdate() {
        let now = Date()
        englishIndicatorLastKeyAt = now
        guard !englishIndicatorUpdatePending else { return }
        englishIndicatorUpdatePending = true
        englishIndicatorPendingSince = now
        let interval = min(
            max(Self.englishIndicatorMinInterval, englishIndicatorLastQueryCost * 8), Self.englishIndicatorMaxInterval)
        let sinceLastQuery = englishIndicatorLastQueryAt.map { now.timeIntervalSince($0) } ?? .infinity
        fireEnglishIndicatorUpdate(after: max(Self.englishIndicatorSettleDelay, interval - sinceLastQuery))
    }

    private func fireEnglishIndicatorUpdate(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date()
                let sinceKey = now.timeIntervalSince(self.englishIndicatorLastKeyAt)
                let waited = now.timeIntervalSince(self.englishIndicatorPendingSince)
                // 剛又按了鍵（宿主可能還沒插字）⇒ 再等一下；等太久（連續打字）就照常更新。
                if sinceKey < Self.englishIndicatorSettleDelay, waited < Self.englishIndicatorMaxWait {
                    self.fireEnglishIndicatorUpdate(after: Self.englishIndicatorSettleDelay - sinceKey)
                    return
                }
                self.englishIndicatorUpdatePending = false
                self.refreshEnglishIndicator()
                // 撐到 maxWait 被強制更新時，距最後一鍵可能還不到 settle（宿主可能還沒插完最後一個字）。
                // 這時若使用者剛好停手就不會有新鍵再觸發更新，浮標會停在少一格——補排一次。
                if sinceKey < Self.englishIndicatorSettleDelay {
                    self.englishIndicatorUpdatePending = true
                    self.englishIndicatorPendingSince = Date()
                    self.fireEnglishIndicatorUpdate(after: Self.englishIndicatorSettleDelay - sinceKey)
                }
            }
        }
    }

    /// 英文模式且有游標位置 ⇒ 顯示在游標旁；否則藏（只藏自己的）。拿不到位置寧可不顯示，不放在錯的地方。
    private func refreshEnglishIndicator() {
        // 不是最後啟用的 session（舊 client，deactivate 還沒到）：不顯示也不藏，浮標歸新的那個管。
        guard Self.latestActivated === self else { return }
        guard MacInputModeState.language == .en, isActive else {
            MacEnglishIndicator.current.hide(owner: self)
            return
        }
        let queryStart = Date()
        let rect = englishIndicatorCaretRect()
        englishIndicatorLastQueryAt = queryStart
        englishIndicatorLastQueryCost = Date().timeIntervalSince(queryStart)
        logEnglishIndicatorAnchor(rect)
        guard let rect else {
            // 目前作用中的 client 拿不到位置：無條件藏。若只藏「自己的」，別的 client 留下、
            // 還沒等到 deactivate 的浮標會殘留在舊位置（B 在 Finder 之類沒有游標的地方時）。
            MacEnglishIndicator.current.hide(owner: nil)
            return
        }
        MacEnglishIndicator.current.show(caretRect: rect, owner: self)
    }

    /// 宿主游標所在行的螢幕矩形。英文模式沒有組字區，所以取**宿主游標**（`selectedRange`）那個字元；
    /// 游標在文件尾端時該字元不存在，退一格取前一個字元。都給不出（零矩形、或游標位置讀不到）⇒ `nil`。
    private func englishIndicatorCaretRect() -> NSRect? {
        guard let client else { return nil }
        let caret = client.selectedRange()
        guard caret.location != NSNotFound else { return nil }
        var rect = NSRect.zero
        _ = client.attributes(forCharacterIndex: caret.location, lineHeightRectangle: &rect)
        if rect.height <= 0, caret.location > 0 {
            _ = client.attributes(forCharacterIndex: caret.location - 1, lineHeightRectangle: &rect)
        }
        return rect.height > 0 ? rect : nil
    }

    private func logEnglishIndicatorAnchor(_ rect: NSRect?) {
        let had = rect != nil
        defer { englishIndicatorHadCaretRect = had }
        guard englishIndicatorHadCaretRect != had, MacIMEEventLogSink.shared.isEnabled else { return }
        let rectAtZero = clientLineRect(at: 0)
        MacIMEEventLogSink.shared.append(
            .note(
                seq: MacIMEEventLogSink.shared.nextSequence(),
                timestamp: Date(),
                kind: "englishIndicatorAnchor",
                detail: [
                    ("rect", rect.map { NSStringFromRect($0) } ?? "nil"),
                    ("caret", client.map { "\($0.selectedRange())" } ?? "nil"),
                    // 實機驗證 index 語意用：候選窗／注音浮窗用 index 0（相對組字區）。若 rect 常為 nil 而
                    // rect@0 有值，代表英文模式該改用 index 0。只在 log 開著、有無位置翻轉時多問一次。
                    ("rect@0", rectAtZero.height > 0 ? NSStringFromRect(rectAtZero) : "nil"),
                    ("app", client?.bundleIdentifier() ?? "?"),
                ]))
    }

    // MARK: 單押 Shift 切中／英

    /// 單押 Shift 的偵測狀態。語言本身是行程共用的（`MacInputModeState`），偵測器是 per-session
    /// 沒關係：Shift 按下到放開之間不會換 client。
    private var shiftTapDetector = MacInputTables.ShiftTapDetector()

    private var shiftTapEnabled: Bool {
        shiftTapEnabledOverride ?? MacTypingPreferences.shiftTapSwitchesToEnglish
    }

    private func resetLanguageIfShiftTapDisabled() {
        if MacInputModeState.language == .en, !shiftTapEnabled { MacInputModeState.language = .zh }
    }

    /// 點走（`commitComposition`／滑鼠按下）flush 進行中：一律當「留著注音」，不讀設定也不讀劇本 override。
    /// 設計決定：實機證實 `commitComposition` 時宿主已不回應這個 client，
    /// 『丟掉』『補一聲』送出的文字落不了地，與其讓三種設定在這條路徑結果不一致，不如固定留著。
    private var clickAwayForcesKeep = false

    var effectiveUnfinishedPolicy: MacUnfinishedZhuyinPolicy {
        if clickAwayForcesKeep { return .keep }
        return unfinishedPolicyOverride ?? MacTypingPreferences.unfinishedZhuyin
    }

    /// controller `handle(_:client:)` 收到 `flagsChanged` 時呼叫（永遠不吃掉事件，回 `false`）。
    ///
    /// - Parameters:
    ///   - shiftDown: 事件之後 Shift 是不是按著。
    ///   - otherModifiersDown: Command／Option／Control 有沒有按著——Shift 按著時又按別的修飾鍵不算單押。
    @discardableResult
    func handleFlagsChanged(shiftDown: Bool, otherModifiersDown: Bool, client: IMKTextInput?) -> Bool {
        if let client { self.client = client }
        guard shiftTapEnabled else {
            shiftTapDetector = MacInputTables.ShiftTapDetector()
            resetLanguageIfShiftTapDisabled()
            return false
        }
        if otherModifiersDown { _ = shiftTapDetector.feed(.otherKeyDown) }
        if shiftTapDetector.feed(shiftDown ? .shiftDown : .shiftUp) {
            switchLanguageFromShiftTap()
        }
        return false
    }

    /// 切語言。組字照 `LanguageSwitch.switchLanguage`（離開中文＝上屏）：完整音節照舊上屏、
    /// 殘段照「沒拼完的注音」設定（走跟 Enter 同一條 `confirmComposedTextOnEnter`；點走不照設定，一律留著）。
    private func switchLanguageFromShiftTap() {
        let current: MacInputTables.Language = MacInputModeState.language == .zh ? .zh : .en
        let outcome = MacInputTables.switchLanguage(
            from: current, event: .shiftTap, isComposing: !engine.compositorKeys.isEmpty,
            config: MacInputTables.SwitchConfig(enabled: [.shiftTap], onLeavingChinese: .commit))
        // 先上屏、後換語言：英文模式下 `handle` 一律放行，順序反了就送不出去。
        if outcome.composing == .commit { flushComposition(client: client) }
        MacInputModeState.language = outcome.language == .zh ? .zh : .en
        logLifecycle("languageSwitch=\(outcome.language == .zh ? "zh" : "en")")
        // 切到英文：立刻在游標旁顯示（罕見事件，同步做；使用者要的就是切換當下看到）。
        // 切回中文不用在這裡藏——語言 setter 的觀察者（`MacEnglishIndicator`）會藏。
        if MacInputModeState.language == .en { refreshEnglishIndicator() }
    }

    /// controller `handle(_:client:)` 收到滑鼠按下（`leftMouseDown`／`rightMouseDown`）。永遠放行（回 `false`），點擊本身照常作用。
    ///
    /// 為什麼需要：`recognizedEvents` 含 flagsChanged（單押 Shift）時，IMK 不再在「點到組字區外」送
    /// `commitComposition:`（標頭）。這裡補回——(a) 作廢待判的單押 Shift（Shift＋點擊是延伸選取）
    /// (b) 組字區有字就 commit（點走一律留著注音、不照設定），跟開關關掉時的 `commitComposition` 同一條 `flushComposition(clickAway: true)`。
    /// ⚠️ 不分點在組字區裡或外：事件座標對不上宿主的組字範圍，點組字區內也會上屏（既定規格）。
    @discardableResult
    func handleMouseDown(client: IMKTextInput?) -> Bool {
        if let client { self.client = client }
        _ = shiftTapDetector.feed(.otherKeyDown)
        if !engine.compositorKeys.isEmpty {
            flushComposition(client: client, clickAway: true)
        }
        // 英文模式點擊會挪游標：浮標跟過去（排到點擊被宿主處理之後）。
        if MacInputModeState.language == .en { scheduleEnglishIndicatorUpdate() }
        return false
    }

    /// 系統／切語言要求「把現在的組字定下來」：窗開著先關窗再上屏，不確認高亮候選（理由見 controller `commitComposition`）。
    ///
    /// - Parameter clickAway: 點走（`commitComposition`、滑鼠按下）傳 `true`——「沒拼完的注音」一律留著，不照設定
    ///   （見 `clickAwayForcesKeep`）。單押 Shift 切英文傳預設 `false`，照設定走。
    func flushComposition(client: IMKTextInput?, clickAway: Bool = false) {
        let flush = {
            if self.isSelecting {
                self.handle(.escape, client: client)
            }
            self.handle(.enter, client: client, forceImmediateCommit: true)
        }
        if clickAway { runAsClickAway(flush) } else { flush() }
    }

    /// 在 `body` 執行期間把「沒拼完的注音」固定成留著（見 `clickAwayForcesKeep`），結束就還原。
    /// 劇本的 `TypingRig.commitComposition` 也走這條，免得 rig 與 controller 各寫一份。
    func runAsClickAway(_ body: () -> Void) {
        clickAwayForcesKeep = true
        defer { clickAwayForcesKeep = false }
        body()
    }

    /// 切輸入法／切 app 時「丟掉」設定的處理：W3 不在這裡 insert（前景可能已經換人），
    /// 只把殘段從保留下來的組字裡拿掉。走狀態機的 ⌫（跟使用者自己按 ⌫ 同一條，composer 與引擎一起收），
    /// 游標不在尾端時不動（殘段在尾端，游標在句中時 ⌫ 會刪到別的字）。
    private func dropTrailingFragmentOnDeactivateIfDiscarding() {
        guard effectiveUnfinishedPolicy == .discard else { return }
        var guardCount = 0   // 殘段最多幾個符號；多給一點，絕不無限迴圈
        while guardCount < 8, engine.compositionCursor == engine.compositorKeys.count,
              MacUnfinishedZhuyin.trailingFragment(keys: engine.compositorKeys) != nil
        {
            guardCount += 1
            _ = dispatch(.backspace, entry: "deactivate", raw: "discard-unfinished")
        }
    }

    // MARK: 事件入口

    /// - Parameter forceImmediateCommit: 選項 C（G1，2026-09-26）的逃生口——系統強制
    ///   flush（`commitComposition`，例如切走焦點）沒有「等下一次 Enter」的機會，一律
    ///   直接送出，不論畫面跟送出值是否相同。使用者真正按下的 Enter 鍵（`inputText`／
    ///   `didCommand` 兩條路徑）都不傳這個參數，走正常的「畫面≠送出值就先預覽」流程。
    /// - Returns: IMK 的「這個鍵有沒有被我們吃掉」。
    @discardableResult
    func handle(
        _ event: MacKeyEvent, client: IMKTextInput?, entry: String = "-", raw: String = "-",
        forceImmediateCommit: Bool = false
    ) -> Bool {
        if let client { self.client = client }
        // 單押 Shift：任何按鍵都讓「Shift 單押」作廢（Shift＋字母是打大寫，不是切換）。
        _ = shiftTapDetector.feed(.otherKeyDown)
        // N8 (1)：單押 Shift 關掉時沒有任何方式能切回中文——英文模式中途關掉開關，language 一律視為中文。
        resetLanguageIfShiftTapDisabled()
        // 英文模式（行程共用）：所有鍵放行給宿主。系統強制 flush（`forceImmediateCommit`）照走——
        // 那是要把其他 client 留下的組字定下來。
        if MacInputModeState.language == .en, !forceImmediateCommit {
            scheduleEnglishIndicatorUpdate()   // 排到下一圈 run loop，放行之後才執行（見該函式註解）
            return false
        }
        // R7：「該 client 的**第一個按鍵**距離上一次 deactivate 幾毫秒」——
        // 這與 `activateServer` 列上的 `sinceDeact_ms` 是**不同的量**（前者是 IMK 通知的間隔，
        // 後者是使用者實際開始打字的間隔）。G8 要知道的是後者：切回來之後多快就有人打字。
        if lastDeactivateAt != nil, !reportedFirstKeySinceDeactivate {
            reportedFirstKeySinceDeactivate = true
            logLifecycle("firstKeyAfterDeactivate")
        }
        // G7：IMK 沒有「游標移走」callback。滑鼠點走、或方向鍵真的讓宿主選取區離開
        // marked range 之後，下一筆 `inputText`／`didCommand` 會帶著新的 `selectedRange`。
        // 先定案再處理這一筆，新字才不會改寫舊的底線。`.deactivate` 排除：切 app 仍保留組字（W3）。
        // `forceImmediateCommit`（`commitComposition` 的合成 Enter）排除：那不是使用者動作，宿主本來就在 flush。
        if event != .clientCursorMoved, event != .deactivate, !forceImmediateCommit,
            clientCaretLeftMarkedText()
        {
            switch Self.cursorLeavePolicy {
            case .observe:
                logCursorMovedWouldFire()
            case .enabled:
                _ = dispatch(.clientCursorMoved, entry: entry, raw: "cursor")
            }
            invalidateOwnLeftContext()
        }
        // 終端機宿主旗標（單鍵同音字排序，見 `MacIMEShippingBehavior`）：每輪組字第一鍵設一次；
        // 功能關著就不白付 bundleIdentifier 的跨行程呼叫。
        if MacEngineTuning.loneKeyHomophoneOrderTerminalHosts, case .zhuyinSymbol = event,
            engine.compositorKeys.isEmpty
        {
            engine.leftContextHostIsTerminal = MacIMEShippingBehavior.isTerminalHost(
                bundleID: self.client?.bundleIdentifier())
        }
        // 🔴 左文只在「開始組字的那一鍵」更新（compositor 為空、且這一鍵是注音符號）：
        // 引擎守衛本來就會丟掉組字中途的更新，逐鍵餵只是白付跨行程呼叫，
        // 還會重演 2026-08-09 的自我污染（host 回傳的 before-input 含我們自己的 marked text）。
        if Self.leftContextEnabled, case .zhuyinSymbol = event, engine.compositorKeys.isEmpty,
            let client = self.client
        {
            refreshLeftContext(client: client)
        }
        let routed = MacDeleteKeyRouting.route(event, policy: MacTypingPreferences.deletePolicy)
        return dispatch(routed, entry: entry, raw: raw, forceImmediateCommit: forceImmediateCommit)
    }

    /// 觀察模式：這一筆若走啟用模式就會定案。只記 log，不送 `.clientCursorMoved`。
    private func logCursorMovedWouldFire() {
        guard let client else { return }
        let marked = client.markedRange()
        let selected = client.selectedRange()
        MacIMEEventLogSink.shared.append(
            .cursorMovedWouldFire(
                seq: MacIMEEventLogSink.shared.nextSequence(),
                timestamp: Date(),
                clientBundleID: client.bundleIdentifier() ?? "?",
                markedRange: "\(marked.location),\(marked.length)",
                selectedRange: "\(selected.location),\(selected.length)",
                displayedMarkedText: lastDisplayedMarkedText
            )
        )
    }

    /// 宿主插入點不在底線裡面（也不在底線正後方）。底線正後方是組字游標的正常位置。
    ///
    /// 只當輔助：主路徑是宿主的 `commitComposition`。日用 log 的 111 筆誤判有兩種形狀：
    /// 很多宿主（Chromium／Electron／終端機）回報**組字區內相對座標**的 `selectedRange`（`[0, length]`），
    /// 還有宿主回 `NSNotFound`。兩者都不算離開。
    private func clientCaretLeftMarkedText() -> Bool {
        guard machine.state != .idle, let client else { return false }
        let marked = client.markedRange()
        guard marked.location != NSNotFound, marked.length > 0 else { return false }
        let caret = client.selectedRange().location
        guard caret != NSNotFound else { return false }
        let end = marked.location + marked.length
        let outsideAbsolute = caret < marked.location || caret > end
        let outsideRelative = caret > marked.length
        return outsideAbsolute && outsideRelative
    }

    var isSelecting: Bool { machine.state == .selecting }

    // MARK: - effect 執行

    @discardableResult
    private func dispatch(
        _ event: MacKeyEvent, entry: String = "-", raw: String = "-",
        forceImmediateCommit: Bool = false
    ) -> Bool {
        // 選項 C：只有 `.enter` 才可能延續「上一次 Enter 顯示的預覽」；其餘任何事件
        // （繼續打字、刪字、選字、切 app……）都算「放棄待確認」——③ 的要求：不得卡在
        // 待確認狀態，照一般流程處理。
        if pendingConfirmText != nil, event != .enter {
            pendingConfirmText = nil
        }
        pendingConfirmForcesImmediateCommit = forceImmediateCommit
        let startedAt = CFAbsoluteTimeGetCurrent()
        let stateBefore = describeState()
        effectResults.removeAll(keepingCapacity: true)
        lastConfirmedCandidate = nil
        lastConfirmApply = nil
        confirmApplyPending = false
        lastCommittedText = nil
        lastDisplayedKeyCount = -1   // 這一鍵沒更新畫面的話就不判 DISP_MISMATCH
        let effects = machine.handle(event, facts: currentFacts())
        var consumed = true
        for effect in effects {
            if case .passThroughToClient = effect { consumed = false }
            if !apply(effect) { break }
        }
        // 開始組字那一鍵在 `handle` 先讀了一次 client 文字，那段是使用者實際等的時間，
        // 算進 `dur_us`（G9 的口徑）——不然新增的跨行程呼叫在日用 log 裡是隱形的。
        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt + preDispatchSeconds
        preDispatchSeconds = 0
        logEvent(
            entry: entry, raw: raw, event: event, stateBefore: stateBefore, effects: effects,
            elapsed: elapsed
        )
        return consumed
    }

    // MARK: - 事件 log
    //
    // 由來：需要一份記錄每次打字發生什麼事的 log，方便事後直接看出哪裡有問題。
    // 標準：**事後能從 log 重建「他到底按了什麼、每一步發生什麼」**。

    /// 候選清單與引擎 keys 各自的「世代」。
    ///
    /// 用途是讓 **debounce 造成的候選落後**在 log 裡看得出來：引擎的候選更新在非 immediate
    /// 時走 `asyncAfter`，所以按 ↓ 當下 `currentCandidates()` 可能還是上一鍵的清單。
    /// keys 換了幾代 vs 候選換了幾代，差值就是落後量（`candLag`）。
    /// R5b：log 要記「畫面上實際是什麼」。沒有它，一個畫面 bug 的 log 等於沒有。
    private var lastDisplayedMarkedText = ""
    private var lastSelectionLocation = 0
    /// 注音浮窗該有的欄位（跟著組字區算）。候選窗開著時仍保留，關窗後直接拿來重畫。
    private var composedReadingColumns: [MacReadingColumn] = []
    /// 注音浮窗此刻實際顯示的欄位；空 ⇒ 收起來。
    private(set) var readingColumns: [MacReadingColumn] = []
    /// 顯示層走過幾個 key（哨兵 `DISP_MISMATCH` 用）。-1 ⇒ 這次沒更新畫面，不判。
    private var lastDisplayedKeyCount = -1
    /// R5c：`fx` 只記計畫不記結果，而引擎接不接得住正是 composer↔引擎錯位的來源。
    private var effectResults: [String: Bool] = [:]
    /// R5d：`getComposedText()` 這一輪唯一那次呼叫的結果（見 `logEvent`）。
    private var lastComposedText = ""
    /// G2 驗證用：這次 `dispatch()` 期間使用者確認的候選（`confirm(at:)` 存的意圖，
    /// 不管 `setHighlightedCandidate` 套用成不成功都記——套用失敗時 log 會看到
    /// commit 不含這個字，那正是 G2 驗證器要抓的 FAIL）。
    /// ⚠️ 只覆蓋鍵盤路徑：滑鼠點選（`candidatePairSelectionConfirmed`）呼叫
    /// `confirm(at:)` 時不在 `dispatch()` 內，設了值也不會被下面的 `logEvent()` 讀到，
    /// 下一次 `dispatch()` 開頭就被清掉——G2 log 驗證器因此只算鍵盤選字。
    private var lastConfirmedCandidate: String?
    /// 最近一次 `confirm(at:)` 之後**引擎有沒有真的套用**的證據。
    /// 曾有選「收尾」畫面仍顯示「收委」的情形，`confirm` 丟掉 `setHighlightedCandidate` 的結果，
    /// log 只有 `chosen=` ⇒ 事後分不出是哪一步丟掉。失敗時 log 會有 `CONFIRM_NOT_APPLIED=1`。
    /// 鍵盤路徑由 `logEvent()` 讀；滑鼠路徑由 `candidatePairSelectionConfirmed` 自己寫。
    private(set) var lastConfirmApply: ConfirmApplyOutcome?
    /// `confirm(at:)` 已經套用候選，但 `applied` 要等這一輪唯一一次
    /// `getComposedText()`（在 `updateMarkedText()`）才填。提前再叫一次會改寫
    /// collapse 修復靠的 `lastKeysSnapshot`。
    private var confirmApplyPending = false
    /// `commitComposedText()` 裡實際送給
    /// `client.insertText()` 的字串。`comp` 欄位（`lastComposedText`）是上一鍵
    /// `updateMarkedText()` 留下的快照，`.enter` 不會呼叫 `updateMarkedText()`，
    /// 所以這個值必須另外記，不能靠 `comp` 推。
    private var lastCommittedText: String?
    /// 選項 C（G1，2026-09-26 產品決策）：上一次 Enter 因為畫面≠即將送出的內容而
    /// 只更新了畫面、沒有送出時，這裡存那份「使用者剛剛看到」的字串。下一次 Enter
    /// 直接送出這份快照（不重新呼叫 `getComposedText()`——R5d 已註明它不是純函式，
    /// 重呼叫可能又不相等，會卡在永遠待確認），保證送出的逐字等於剛剛顯示的畫面。
    /// `dispatch()` 一開頭，只要事件不是 `.enter` 就清掉——放棄待確認、照一般流程走。
    private var pendingConfirmText: String?
    /// 本次 `dispatch()` 是不是系統強制 flush（`commitComposition`）——那個時機沒有
    /// 「等下一次 Enter」的機會，`confirmComposedTextOnEnter()` 看到這個是 true 時
    /// 一律直接送出，不管畫面跟送出值是否相同。
    private var pendingConfirmForcesImmediateCommit = false

    private func describeState() -> String {
        switch machine.state {
        case .idle: return "idle"
        case .typing: return machine.isPartial ? "typing/partial" : "typing/settled"
        case .selecting: return "selecting"
        }
    }

    /// 選字學習：上一次 `logEvent` 看到的 `engine.learnedChoicesAppliedTotal`，用來算「這一鍵新套用了幾段」。
    private var lastLearnedAppliedTotal = 0

    private func logEvent(
        entry: String, raw: String, event: MacKeyEvent, stateBefore: String,
        effects: [MacIMEEffect], elapsed: CFTimeInterval
    ) {
        // 基準在 guard 之前推進：log 關著時也要追上，否則開 log 後第一行會帶一大筆累計值。
        let learnedTotal = engine.learnedChoicesAppliedTotal
        let learnedDelta = max(0, learnedTotal - lastLearnedAppliedTotal)
        lastLearnedAppliedTotal = learnedTotal
        guard MacIMEEventLogSink.shared.isEnabled else { return }

        // 🔴 R5d：**一個事件只呼叫一次 `getComposedText()`。**
        // 它不是純函式——`resolveComposedText()` 每次呼叫都會改寫
        // `stableComposedValuesByKey`／`lastKeysSnapshot`，而 collapse 修復靠「上次呼叫的 keys」。
        // `updateMarkedText` 已經叫過一次，這裡再叫一次不保證回同一個字，
        // **而且會讓 log 本身擾動行為**。改成讀那一次的結果。
        let keys = engine.compositorKeys
        // 🔴 `candidates` 是**即時取樣**＝上一鍵的清單（引擎候選更新有約 20ms debounce，
        // 而這裡在 input 後微秒內就讀）。不可拿來推論「候選過期」——見 `MacIMEEventLog`。
        let candidates = engine.currentCandidates()

        let record = MacIMEEventRecord.forKeyEvent(
            seq: MacIMEEventLogSink.shared.nextSequence(),
            timestamp: Date(),
            entry: entry,
            raw: raw,
            clientBundleID: client?.bundleIdentifier() ?? "?",
            keyEvent: String(describing: event),
            stateBefore: stateBefore,
            stateAfter: describeState(),
            effects: effects.map { String(describing: $0) },
            effectResults: effectResults,
            buffer: machine.composerBuffer,
            composed: lastComposedText,
            compositorKeys: keys,
            cursor: engine.compositionCursor,
            displayedMarkedText: lastDisplayedMarkedText,
            selectionLocation: lastSelectionLocation,
            displayedKeyCount: lastDisplayedKeyCount,
            candidateCount: candidates.count,
            candidatePreview: Array(candidates.prefix(10)),
            // 耗時順便把護欄 G9（逐鍵延遲 p95）的原始資料收掉。
            durationMicroseconds: Int((elapsed * 1_000_000).rounded()),
            processID: ProcessInfo.processInfo.processIdentifier,
            chosenCandidate: lastConfirmedCandidate,
            committedText: lastCommittedText,
            confirmApply: lastConfirmedCandidate == nil ? nil : lastConfirmApply,
            learnedApplied: learnedDelta
        )
        MacIMEEventLogSink.shared.append(record)
    }

    /// 翻不出 `MacKeyEvent` 的原始輸入 —— **最可能是使用者抱怨「按了沒反應」的來源**，
    /// 所以即使我們什麼都沒做也要記一筆。
    func logUnmapped(entry: String, raw: String, client: IMKTextInput?) {
        _ = shiftTapDetector.feed(.otherKeyDown)   // 對不到事件的按鍵也是「Shift 之間有別的鍵」
        guard MacIMEEventLogSink.shared.isEnabled else { return }
        MacIMEEventLogSink.shared.append(
            .forUnmappedInput(
                seq: MacIMEEventLogSink.shared.nextSequence(),
                timestamp: Date(),
                entry: entry,
                raw: raw,
                clientBundleID: client?.bundleIdentifier() ?? "?"
            )
        )
    }

    /// - Returns: `false` ⇒ 中止後續 effect（目前只有選字鍵解析失敗會用到）。
    private func apply(_ effect: MacIMEEffect) -> Bool {
        switch effect {
        // MARK: 引擎
        case .engineInput(let key):
            engine.input(key)
        case .engineReplaceLastKey(let from, let to):
            // 以 `ˉ` 結尾 ⇒ 這是空白鍵補一聲（四顆聲調鍵是 ˊ ˇ ˋ ˙，產不出 `ˉ`）。
            // 詞庫對一聲有兩種編碼；帶 `ˉ` 的換不進去就退到「只在顯示層標記已收尾」、
            // 引擎的 key 維持無聲調——照抄 iOS 按鍵閘門的補一聲收尾。
            // 其餘情形換不成就讓內容只留在緩衝區（iOS 的「等更多輸入」fallback）。
            let replaced = engine.replaceLastKey(from: from, to: to)
            // R5c：引擎接不接得住要記——**那正是 composer↔引擎錯位的來源**。
            effectResults[String(describing: effect)] = replaced
            if !replaced, to.hasSuffix(String(MacZhuyinConstants.firstToneMark)) {
                engine.markImplicitFirstToneForCurrentTail()
            }
        case .engineBackspace:
            engine.backspace()
        case .engineClear:
            engine.clear()
        case .engineMarkAutoFlushedAsUnsealed(let content, let keyCount):
            engine.markAutoFlushedAsUnsealed(content: content, keyCount: keyCount)
        case .engineClearAutoFlushedUnsealedRecord(let content, let keyCount):
            engine.clearAutoFlushedUnsealedRecord(content: content, keyCount: keyCount)
        case .engineMarkImplicitFirstTone:
            engine.markImplicitFirstToneForCurrentTail()
        case .engineScrubCursor(let offset):
            engine.scrubCompositionCursor(by: offset)

        case .engineReopenTail(let from, let to, let fallbackPrevious, let fallbackKeyCount):
            // 唯一需要把結果餵回狀態機的一格（見 `MacIMEEffect.engineReopenTail`）。
            let succeeded = engine.replaceLastKey(from: from, to: to)
            // R5c：這一格的成敗決定 composer 要 reopen 哪一個，是最該被記下來的一筆。
            effectResults[String(describing: effect)] = succeeded
            if !succeeded {
                engine.backspace()
                if let previous = fallbackPrevious, !previous.isEmpty {
                    engine.clearAutoFlushedUnsealedRecord(
                        content: previous, keyCount: fallbackKeyCount)
                }
            }
            machine.resolveReopenTail(succeeded: succeeded)

        // MARK: 候選窗（零引擎副作用——不變式 3）
        case .openCandidateWindow:
            openWindow()
        case .closeCandidateWindow:
            closeWindow()
        case .candidateHighlightNext:
            // 設計決定「停在頭尾＋嗶」：**在轉接層先判斷**，不呼叫窗。
            // 窗本身保持上游原樣（越界會環繞且回 `false`），方便日後對上游 diff。
            if MacCandidateWindow.current.highlightedIndex >= candidateSnapshot.count - 1 {
                NSSound.beep()
            } else {
                MacCandidateWindow.current.highlightNextCandidate()
            }
        case .candidateHighlightPrevious:
            if MacCandidateWindow.current.highlightedIndex <= 0 {
                NSSound.beep()
            } else {
                MacCandidateWindow.current.highlightPreviousCandidate()
            }
        case .candidateNextPage:
            MacCandidateWindow.current.showNextPage()
        case .candidatePreviousPage:
            MacCandidateWindow.current.showPreviousPage()
        case .candidateNextLine:
            MacCandidateWindow.current.showNextLine()
        case .candidatePreviousLine:
            MacCandidateWindow.current.showPreviousLine()

        // MARK: 確認（確認進組字，Enter 才整句上屏）
        case .confirmHighlightedCandidate:
            confirm(at: MacCandidateWindow.current.highlightedIndex)
        case .confirmCandidateAtSelectionKey(let labelIndex):
            guard let index = MacCandidateWindow.current.candidateIndexAtKeyLabelIndex(labelIndex)
            else {
                // 本頁沒有那一格：吃掉＋嗶，**窗不關**（spec §4.4）。
                NSSound.beep()
                machine.resolveSelectionKeyConfirmation(succeeded: false)
                return false
            }
            machine.resolveSelectionKeyConfirmation(succeeded: true)
            confirm(at: index)

        // MARK: client
        case .updateMarkedText:
            updateMarkedText()
        case .commitComposedText:
            commitComposedText()
        case .confirmComposedTextOnEnter:
            confirmComposedTextOnEnter(forceImmediateCommit: pendingConfirmForcesImmediateCommit)
        case .insertText(let text):
            // G5：與引擎無關的純文字（標點）。呼叫端已經決定過要不要先 `commitComposedText`
            // （settled／partial 分支會在這之前送一個），這裡只管把字串交給宿主。
            client?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            noteInsertedIntoClient(text)
        case .passThroughToClient:
            // 放行給宿主（方向鍵、⌫、英文字元……）：宿主可能已經改動文字或移動游標，
            // 我們自己記的「游標前是什麼」不再可信。
            invalidateOwnLeftContext()
        case .beep:
            NSSound.beep()
        }
        return true
    }

    // MARK: - 左文
    //
    // 需求：跟 iPhone 一樣根據上下文重排，兩個版本都應該要有。
    // iPhone 每一鍵餵 `documentContextBeforeInput`；Mac 在此之前**零呼叫**，所以引擎既有的
    // KenLM 上文重排與 path-level LM 的 `initialContext` 在 Mac 上
    // 永遠是「沒有上文」。**這不是另一個功能**：只是把既有入口接上。
    //
    // 設計取捨：
    //   • 時機：只在「開始組字那一鍵」讀（`handle` 裡），組字中途不讀。
    //   • 來源優先序：① 向 client 讀游標前 `kenLMContextWindowChars` 個字 ② 讀不到時，
    //     用本輸入法在這個 client 剛上屏的尾巴（`knownLeft`），且**只有插入點與上屏後一致才用**。
    //   • 讀不到又沒有可用後備 ⇒ 仍然明確餵 nil（不能「跳過」：跳過會讓上一句的上文留在單例引擎裡）。
    //   • 失效：放行給宿主的鍵、游標離開組字區、activate／deactivate 全部清掉。
    //   • ⚠️ NSException 未攔：真宿主對越界範圍可能丟 ObjC 例外，Swift 接不到；
    //     我們只送 `[max(0, caret-K), caret)`，永遠在文件範圍內。

    /// 我們相信「游標前」是什麼（來自 client 讀取或本輸入法自己的上屏）。只在 `knownLeftCaret`
    /// 與宿主當下插入點相同時才可當後備。
    private var knownLeft = ""
    private var knownLeftCaret: Int?
    /// 開始組字那一鍵讀 client 花掉的時間，`dispatch` 併進該鍵的 `dur_us`。
    private var preDispatchSeconds: CFTimeInterval = 0

    private static func validCaret(_ location: Int) -> Int? {
        location == NSNotFound || location < 0 ? nil : location
    }

    /// 切掉開頭被截斷的 surrogate 後半、只留最後一段（換行＝新句）、最多 `limit` 字。
    static func clipLeftContext(_ raw: String, limit: Int) -> String {
        guard limit > 0, !raw.isEmpty else { return "" }
        var text = raw as NSString
        if text.length > 0, UTF16.isTrailSurrogate(text.character(at: 0)) {
            text = text.substring(from: 1) as NSString
        }
        var result = text as String
        if let cut = result.lastIndex(where: { $0.isNewline }) {
            result = String(result[result.index(after: cut)...])
        }
        return String(result.suffix(limit))
    }

    private func resetLeftContext() {
        // 終端機宿主旗標住在共用的單例引擎上：換 client／停用時一併清掉，不讓上一個宿主的判定留到下一輪組字
        // （下一輪第一鍵會重設；這裡是兜底，與左文功能開關無關）。
        engine.leftContextHostIsTerminal = false
        guard Self.leftContextEnabled else { return }
        invalidateOwnLeftContext()
        applyLeftContext("")
    }

    /// 只有值真的變了才叫引擎：`setExternalLeftContext` 每次都會清 KenLM 單字快取，
    /// 左文沒變（最常見：沒上文→沒上文）時清快取是白白浪費，還會讓延遲 A/B 看到假的成本。
    /// 值有變（含「舊上文→空」）一定會呼叫，所以「讀不到就跳過」的錯誤實作仍會被 24c-stale 抓到。
    private func applyLeftContext(_ text: String) {
        guard engine.effectiveExternalLeftContext != text else { return }
        engine.setExternalLeftContext(text.isEmpty ? nil : text)
    }

    private func invalidateOwnLeftContext() {
        knownLeft = ""
        knownLeftCaret = nil
    }

    private func noteInsertedIntoClient(_ text: String) {
        guard Self.leftContextEnabled, let client else { return }
        let limit = engine.kenLMContextWindowChars
        knownLeft = Self.clipLeftContext(knownLeft + text, limit: limit)
        knownLeftCaret = Self.validCaret(client.selectedRange().location)
    }

    private func refreshLeftContext(client: IMKTextInput) {
        let started = CFAbsoluteTimeGetCurrent()
        let limit = engine.kenLMContextWindowChars
        let caret = Self.validCaret(client.selectedRange().location)
        var source = "none"
        var text = ""
        if let caret {
            if caret == 0 {
                // 文件開頭：這是「真的沒有上文」，不是「讀不到」，不能走後備。
                source = "client"
            } else if limit > 0 {
                let start = max(0, caret - limit)
                let range = NSRange(location: start, length: caret - start)
                if let read = client.attributedSubstring(from: range)?.string, !read.isEmpty {
                    source = "client"
                    text = Self.clipLeftContext(read, limit: limit)
                } else if knownLeftCaret == caret, !knownLeft.isEmpty {
                    source = "fallback"
                    text = knownLeft
                }
            }
        }
        // 🔴 一律明確設定（含 nil；值沒變時 `applyLeftContext` 才略過）：跳過會讓上一句的左文留在單例引擎裡影響這一句。
        applyLeftContext(text)
        knownLeft = text
        knownLeftCaret = caret
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        preDispatchSeconds = elapsed
        guard MacIMEEventLogSink.shared.isEnabled else { return }
        // 只記長度與來源，**不記游標前的文字**：那可能不是用本輸入法打的（密碼欄旁的內容、他人文件）。
        MacIMEEventLogSink.shared.append(
            .note(
                seq: MacIMEEventLogSink.shared.nextSequence(),
                timestamp: Date(),
                kind: "leftContext",
                detail: [
                    ("src", source),
                    ("len", "\(engine.effectiveExternalLeftContext.count)"),
                    // 這一輪被判成終端機宿主嗎（單鍵同音字修法有沒有資格套用）；白名單漏／拼錯時靠它診斷。
                    ("term", engine.leftContextHostIsTerminal ? "1" : "0"),
                    ("us", "\(Int((elapsed * 1_000_000).rounded()))"),
                    ("app", client.bundleIdentifier() ?? "?"),
                ]))
    }

    // MARK: - 引擎事實快照

    private func currentFacts() -> MacEngineFacts {
        let candidates = engine.currentCandidates()
        return MacEngineFacts(
            keys: engine.compositorKeys,
            cursor: engine.compositionCursor,
            unsealed: engine.autoFlushedUnsealedSyllables.map {
                MacUnsealedRecord(content: $0.content, keyCount: $0.keyCount)
            },
            candidateCount: candidates.count,
            highlightedCandidateIndex: engine.highlightedCandidate()
                .flatMap { candidates.firstIndex(of: $0) } ?? -1,
            unfinishedPolicy: effectiveUnfinishedPolicy
        )
    }

    // MARK: - 窗

    private func openWindow() {
        // 不變式 6：**這一刻**的清單就是窗接下來要用的全部內容，中途不再問引擎。
        candidateSnapshot = engine.currentCandidates()
        guard !candidateSnapshot.isEmpty else { return }
        let window = MacCandidateWindow.current
        window.delegate = self
        window.reloadData()
        // 起始高亮：引擎已經選過字就從那格開始，否則 0（spec §4.5）。
        let start = engine.highlightedCandidate().flatMap { candidateSnapshot.firstIndex(of: $0) } ?? 0
        window.highlightedIndex = max(0, min(start, candidateSnapshot.count - 1))
        window.visible = true
        refreshReadingPanel()
    }

    private func closeWindow() {
        let window = MacCandidateWindow.current
        if window.delegate === self {
            window.visible = false
            window.delegate = nil
        }
        candidateSnapshot = []
        refreshReadingPanel()
    }

    /// 注音浮窗：候選窗開著時收起（候選窗上方已經有注音），沒有組字也收起。
    private func refreshReadingPanel() {
        readingColumns = machine.state == .selecting ? [] : composedReadingColumns
        if readingColumns.isEmpty {
            MacReadingPanel.shared.hide()
        } else {
            MacReadingPanel.shared.show(readingColumns, anchor: readingPanelAnchor())
        }
    }

    /// 浮窗右緣要貼齊游標前那個字的右緣：組字區開頭 ＋ 用客體字型量出的寬度。
    /// 為什麼不問最後那個字的位置，見 `MacReadingPanelAnchor` 檔頭（實機三版的教訓）。
    private func readingPanelAnchor() -> MacReadingPanelAnchor {
        var start = NSRect.zero
        var attributes: [AnyHashable: Any]?
        if let client {
            attributes = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &start)
        }
        let font = attributes?[NSAttributedString.Key.font] as? NSFont
            ?? attributes?[NSAttributedString.Key.font.rawValue] as? NSFont
        // 要對齊的是游標前那個字；游標在最前面時是第一個字（浮窗標的也是它）。
        let text = lastDisplayedMarkedText as NSString
        let firstLength = text.length == 0 ? 0 : text.rangeOfComposedCharacterSequence(at: 0).length
        let end = min(max(lastSelectionLocation, firstLength), text.length)
        let width = font.map {
            NSAttributedString(string: text.substring(to: end), attributes: [.font: $0]).size().width
        }
        let anchor = MacReadingPanelAnchor.resolve(start: start, prefixWidth: width)
        // 實機位置不對時看這一筆：開頭在哪、有沒有拿到字型、量出多寬、採用哪一種。
        if MacIMEEventLogSink.shared.isEnabled {
            MacIMEEventLogSink.shared.append(
                .note(
                    seq: MacIMEEventLogSink.shared.nextSequence(),
                    timestamp: Date(),
                    kind: "readingPanelAnchor",
                    detail: [
                        ("caret", "\(lastSelectionLocation)"),
                        ("start", NSStringFromRect(start)),
                        ("font", font.map { "\($0.fontName) \($0.pointSize)" } ?? "nil"),
                        ("attrKeys", attributes.map { $0.keys.map { "\($0)" }.sorted().joined(separator: ",") } ?? "nil"),
                        ("width", width.map { "\($0)" } ?? "nil"),
                        ("anchor", "\(anchor)"),
                        ("app", client?.bundleIdentifier() ?? "?"),
                    ]))
        }
        return anchor
    }

    /// 客體組字區第 `index` 個字（UTF-16）那一行的螢幕矩形。
    /// 給不出來時是零矩形（某些 Electron app）。
    private func clientLineRect(at index: Int = 0) -> NSRect {
        var lineRect = NSRect.zero
        if let client {
            _ = client.attributes(forCharacterIndex: index, lineHeightRectangle: &lineRect)
        }
        return lineRect
    }

    /// 注音符號（U+3105–U+3129、U+31A0–U+31BF）或聲調符號（ˉˊˇˋ˙）。
    /// 這些可以出現在組字讀音裡，但不能當候選字或送出的文字。
    private static func containsRawZhuyinOrTone(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3105 ... 0x3129, 0x31A0 ... 0x31BF:
                return true
            case 0x02C7, 0x02C9, 0x02CA, 0x02CB, 0x02D9:
                return true
            default:
                return false
            }
        }
    }

    /// 套用 override → 關窗 → 用 `getComposedText()` 更新 marked text → 回 `Typing/settled`。
    /// **不是**整句上屏（那是 Enter 的事）。
    private func confirm(at index: Int) {
        guard candidateSnapshot.indices.contains(index) else {
            NSSound.beep()
            return
        }
        // G2：記使用者「選了誰」的意圖，不管下面套用成不成功都記
        // ——套用失敗時 commit 不含這個字，才是 G2 驗證器要抓的 FAIL。
        let chosen = candidateSnapshot[index]
        // 詞庫把注音符號本身也當成候選（factory `theKey=P` → `ㄟ`）。
        // 2026-09-28 seq=1721：高亮落在 `ㄟ`，`setHighlightedCandidate` 把畫面從「喔」蓋成「ㄟ」，
        // 下一手 Enter 就把注音送出。注音／聲調符號不是可以上屏的字。
        if Self.containsRawZhuyinOrTone(chosen) {
            NSSound.beep()
            return
        }
        lastConfirmedCandidate = chosen
        let cursorBeforeSelection = engine.compositionCursor
        // 套用前先記引擎這個 index 上的候選：跟窗的快照不同 ⇒ index 錯位（套的不是使用者看到的那個）。
        let engineCandidates = engine.currentCandidates()
        let engineValue = engineCandidates.indices.contains(index) ? engineCandidates[index] : nil
        // 🔴 這是整條路徑上**唯一**寫引擎的候選操作（不變式 3）。
        // `setHighlightedCandidate` 會 `applyOverride` 並重建候選清單——所以它絕不能
        // 掛在高亮變更上，只能掛在確認上。
        _ = engine.setHighlightedCandidate(index: index)
        engine.noteUserConfirmedSelection()      // 選字學習：確認當下入庫（spec §4.1）；自動套用不經過這裡
        placeCursorAfterSelection(cursorBefore: cursorBeforeSelection, chosen: chosen)
        // 以前這裡 `_ =` 丟掉結果，套用失敗完全無聲。現在把「畫面上會不會有所選字」量出來、
        // 交給 log（`applied`／`CONFIRM_NOT_APPLIED`）。行為不變：失敗時仍照舊走完（不 beep、
        // 不換別的候選）——那是使用者可見的行為改動，要產品決策，不在這裡擅自決定。
        // `applied` 不在這裡呼叫 `getComposedText()`：它不是純函式（R5d），這一輪
        // 後面的 `updateMarkedText()` 還會叫一次。先記下其餘證據，等那一次的結果再填。
        lastConfirmApply = ConfirmApplyOutcome(
            applied: false,
            engineValueAtIndex: engineValue,
            overrideApplied: engine.lastOverrideApplied
        )
        confirmApplyPending = true
    }

    /// 預設（詞後面）不碰游標。漢音那一檔只在游標原本就在組字區中間時，
    /// 把游標挪到所選詞的開頭。平常在句尾選字不受影響。
    private func placeCursorAfterSelection(cursorBefore: Int, chosen: String) {
        guard MacTypingPreferences.cursorAfterSelection == .beforeWord else { return }
        guard let backend = engine.composerView else { return }
        let grams = backend.assembledGrams.map {
            MacSelectionCursorGram(keyCount: $0.keyArray.count, value: $0.value)
        }
        let target = MacSelectionCursor.targetCursor(
            cursor: cursorBefore,
            keyCount: engine.compositorKeys.count,
            grams: grams,
            chosen: chosen,
            placement: .beforeWord
        )
        let delta = target - engine.compositionCursor
        guard delta != 0 else { return }
        _ = engine.scrubCompositionCursor(by: delta)
    }

    // MARK: - marked text / commit

    // 🔴 把引擎組字結果打包成顯示層 segments 的邏輯**搬到了 `MacComposedSegmentBuilder`**
    //（它只碰引擎、不碰 AppKit，所以能用純 swiftc 接**真引擎**測：
    // `tools/test_mac_display_engine.sh`）。原本它是這裡的 private 函式，於是「真引擎會吐出
    // 什麼樣的 segments」從來沒被測過——稽核 #4 就是在那一段找到兩個使用者一定看得到的閃爍。
    // 「正在拼」時要在 compositor 複本上先移除 pending key 再解碼，理由與量測見該檔頭。

    private func updateMarkedText() {
        guard let client else { return }
        // 🔴 **不可以寫回 `composed + composerBuffer`**（舊 spike 的公式），
        // 也不可以直接用 `getComposedText()`：引擎會把使用者**從沒收尾過**的音節
        // 一併解析成漢字（實機 seq=30：`keys=[ㄅㄨˊ,ㄕ,ㄓ,ㄏ]` → `comp=不是隻黑`），
        // 畫面因此每按一鍵整句重跳。規則與全部證據見 `MacMarkedTextState`。
        // R5d：這是本輪**唯一**一次呼叫 `getComposedText()`，結果同時餵給顯示與 log。
        // 選字確認的 `applied` 也用這一次的字串，不再另外叫。
        lastComposedText = engine.getComposedText()
        if confirmApplyPending, let chosen = lastConfirmedCandidate, let prior = lastConfirmApply {
            confirmApplyPending = false
            lastConfirmApply = ConfirmApplyOutcome(
                applied: lastComposedText.contains(chosen),
                engineValueAtIndex: prior.engineValueAtIndex,
                overrideApplied: prior.overrideApplied
            )
        }
        let pendingBuffer = machine.composerBuffer
        let segments = MacComposedSegmentBuilder.segments(engine: engine, pendingBuffer: pendingBuffer)
        // 正在拼的 key ＝ `keys[cursor-1]`（游標相對，同 G4 的 Bug A）。
        let pendingKeyIndex = pendingBuffer.isEmpty ? -1 : engine.compositionCursor - 1
        let display = MacMarkedTextState.display(
            segments: segments, pendingBuffer: pendingBuffer, pendingKeyIndex: pendingKeyIndex)
        let caret = MacMarkedTextState.selectionLocation(
            segments: segments,
            pendingBuffer: pendingBuffer,
            pendingKeyIndex: pendingKeyIndex,
            cursorKeyIndex: engine.compositionCursor
        )
        // R5b：log 要看得到「畫面上實際是什麼」——沒有它，畫面 bug 的 log 等於沒有。
        lastDisplayedMarkedText = display
        lastDisplayedKeyCount = MacMarkedTextState.displayedKeyCount(
            segments: segments, pendingBuffer: pendingBuffer, pendingKeyIndex: pendingKeyIndex)
        composedReadingColumns = display.isEmpty ? [] : MacMarkedTextState.readingWindow(
            MacMarkedTextState.readingColumns(
                segments: segments,
                pendingBuffer: pendingBuffer,
                pendingKeyIndex: pendingKeyIndex,
                cursorKeyIndex: engine.compositionCursor
            ))
        defer { refreshReadingPanel() }

        guard !display.isEmpty else {
            lastSelectionLocation = 0
            client.setMarkedText(
                "",
                selectionRange: NSRange(location: 0, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            return
        }
        // 小麥注音 InputState.Inputting、唯音 doSetMarkedText：
        // 整段同一粗細的底線，selectionRange 長度必須是 0。
        // 長度不是 0 時，游標會黏在組字區最前面，或是我們自己畫的線會蓋到字上。
        // 游標由客體畫在字縫裡，不佔字寬、也不蓋墨。
        lastSelectionLocation = caret
        let marked = NSAttributedString(
            string: display,
            attributes: [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .markedClauseSegment: 0,
            ]
        )
        client.setMarkedText(
            marked,
            selectionRange: NSRange(location: caret, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
    }

    private func commitComposedText() {
        composedReadingColumns = []
        refreshReadingPanel()
        guard client != nil else { return }
        insertComposedTextAndClearEngine(engine.getComposedText())
    }

    /// 真正把一段**已經算好**的文字送出去──呼叫端負責決定送什麼，這裡只管執行，
    /// **不呼叫 `engine.getComposedText()`**（R5d：它不是純函式，同一鍵內只能呼叫一次）。
    private func insertComposedTextAndClearEngine(_ composed: String) {
        guard let client else { return }
        guard !composed.isEmpty else {
            engine.clear()
            lastDisplayedMarkedText = ""
            lastSelectionLocation = 0
            // 只剩未完成注音、被 G7 剪掉之後沒有字可上屏，底線仍要清掉，
            // 否則畫面上的注音會留下而引擎已經空了。
            client.setMarkedText(
                "",
                selectionRange: NSRange(location: 0, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            return
        }
        lastCommittedText = composed
        if pendingConfirmForcesImmediateCommit {
            flushInsert(composed, client: client)
        } else {
            client.insertText(composed, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        // 明確清掉 marked text：靠 insertText 隱式清除在各家 app 表現不一致。
        client.setMarkedText(
            "",
            selectionRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        engine.clear()
        noteInsertedIntoClient(composed)
    }

    /// 系統／點走／切語言 flush 把 `composed` 送進宿主：用明確的 marked range 取代底線，
    /// 不依賴宿主怎麼解讀 `NSNotFound`（N10；實機「留著」在這個寫法上落地）。
    private func flushInsert(_ composed: String, client: IMKTextInput) {
        let marked = client.markedRange()
        let hasMark = marked.location != NSNotFound && marked.length > 0
        client.insertText(composed, replacementRange: hasMark ? marked : NSRange(location: NSNotFound, length: 0))
    }

    /// `.confirmComposedTextOnEnter` 的執行端（選項 C，G1，2026-09-26 產品決策）。
    ///
    /// - `pendingConfirmText` 有值 ⇒ 這是「使用者看到預覽後再按一次 Enter」，原樣送出
    ///   那份快照，逐字等於剛剛顯示的畫面。
    /// - `forceImmediateCommit`（系統強制 flush，例如切走焦點）⇒ 不論畫面跟送出值是否
    ///   相同，一律直接送出——那個時機沒有「等下一次 Enter」的機會。
    /// - 否則比較 **Enter 前使用者實際看到的畫面**（`lastDisplayedMarkedText`，上一鍵
    ///   `updateMarkedText()` 留下的快照，`.enter` 本身不叫它）跟 sealing 之後的
    ///   `getComposedText()`：相同就直接送出（④：不多按）；不同就只更新畫面、不送出
    ///   （①②：`_has_unexplained_unsealed_gap` 那個機制造成的落差，讓使用者先看到
    ///   正確答案）。
    private func confirmComposedTextOnEnter(forceImmediateCommit: Bool) {
        // 客體可能已經釋放（weak）。不能在這裡提前 return：狀態機在 `.enter`
        // 已經樂觀轉 idle，跳過 `resolveEnterCommit` 與清組字的話，下一鍵從 Idle
        // 起手會把新音節接在殘留 keys 後面。
        if let pending = pendingConfirmText {
            pendingConfirmText = nil
            composedReadingColumns = []
            refreshReadingPanel()
            if client != nil {
                insertComposedTextAndClearEngine(pending)
            } else {
                discardCompositionWithoutClient()
            }
            machine.resolveEnterCommit(committed: true)
            return
        }
        // 沒拼完的注音（2026-10-04 產品決策三選一）：最後一個 key 是殘段、且政策不是「補一聲」⇒
        // 先把它從引擎拿掉，前面的字照舊解碼；「留著」再把原文接在後面。「補一聲」維持原樣（machine 已補一聲）。
        let policy = effectiveUnfinishedPolicy
        let fragment = policy == .seal ? nil : MacUnfinishedZhuyin.trailingFragment(keys: engine.compositorKeys)
        let cursorBeforeDrop = engine.compositionCursor
        if fragment != nil { dropTrailingKey() }
        // R5d：這是本輪（`.enter` 這一鍵）**唯一**一次呼叫 `getComposedText()`。
        var composed = engine.getComposedText()
        var displayedForCompare = lastDisplayedMarkedText
        if let fragment {
            if policy == .keep { composed += fragment }
            // 「丟掉」時畫面上的殘段不會送出，拿掉再比，免得每次 Enter 都被當成畫面≠送出值。
            if policy == .discard, displayedForCompare.hasSuffix(fragment) {
                displayedForCompare.removeLast(fragment.count)
            }
        }
        guard forceImmediateCommit || composed == displayedForCompare else {
            // 預覽分支：使用者還可能放棄預覽繼續打字，殘段要放回引擎、游標還原，不丟字。
            if let fragment { restoreTrailingKey(fragment, cursor: cursorBeforeDrop) }
            pendingConfirmText = composed
            if let client {
                showPendingConfirmPreview(composed, client: client)
            }
            machine.resolveEnterCommit(committed: false)
            return
        }
        composedReadingColumns = []
        refreshReadingPanel()
        if client != nil {
            insertComposedTextAndClearEngine(composed)
        } else {
            discardCompositionWithoutClient()
        }
        machine.resolveEnterCommit(committed: true)
    }

    /// 把最後一個 key 從引擎拿掉。游標不在尾端時先挪到尾端（引擎的 `backspace` 砍的是游標前那個 key）。
    private func dropTrailingKey() {
        let keyCount = engine.compositorKeys.count
        let cursor = engine.compositionCursor
        if cursor < keyCount { engine.scrubCompositionCursor(by: keyCount - cursor) }
        engine.backspace()
    }

    /// `dropTrailingKey` 的反操作：把 key 放回尾端、游標還原到 `cursor`。
    private func restoreTrailingKey(_ key: String, cursor: Int) {
        engine.input(key)
        let now = engine.compositionCursor
        if cursor != now { engine.scrubCompositionCursor(by: cursor - now) }
    }

    /// 沒有客體可 `insertText`。組字仍要清掉，否則 idle 加殘留 keys 會污染下一鍵。
    private func discardCompositionWithoutClient() {
        engine.clear()
        lastDisplayedMarkedText = ""
        lastComposedText = ""
        lastSelectionLocation = 0
    }

    /// 選項 C 的「先顯示再送」：把即將送出的內容更新到畫面上（底線、marked text），
    /// 不 commit。格式比照 `updateMarkedText()` 最後那段——整段同一粗細底線、
    /// `selectionRange` 長度 0，游標放在字串尾端（沒有「正在拼」的那一個 pending key）。
    private func showPendingConfirmPreview(_ text: String, client: IMKTextInput) {
        lastDisplayedMarkedText = text
        lastComposedText = text
        composedReadingColumns = []
        refreshReadingPanel()
        guard !text.isEmpty else {
            lastSelectionLocation = 0
            client.setMarkedText(
                "",
                selectionRange: NSRange(location: 0, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            return
        }
        let caret = (text as NSString).length
        lastSelectionLocation = caret
        let marked = NSAttributedString(
            string: text,
            attributes: [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .markedClauseSegment: 0,
            ]
        )
        client.setMarkedText(
            marked,
            selectionRange: NSRange(location: caret, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
    }

    // MARK: - CtlCandidateDelegate（spec §8.1 的 20 個成員）

    var isCandidateState: Bool { machine.state == .selecting }
    var isVerticalCandidateWindow: Bool { false }            // 橫排
    // 候選窗形態（沿革）：
    //   09-21：原本的「橫排單行」是看到實物前的預設值 ⇒ 改成多行，一開就展開 4 行、選字鍵 9 個、字級 18。
    //   10-01 現行：看過實物後覺得選字框太大，改為比照威注音的選字框；三個值量自
    //     威注音 4.7.4 的 `defaults read org.atelierInmu.inputmethod.vChewing`：
    //       AlwaysExpandCandidateWindow=0（先 1 行，按 ↓ 才展開成 4 行）
    //       CandidateKeys=123456（選字鍵 6 個）　CandidateListTextSize=16（字級，在 `Shim/CandidateUIShim.swift`）
    //       CandidateWindowShowOnlyOneLine=0、UseHorizontalCandidateList=1（與下面兩行相同）
    //
    // **`isCandidateWindowSingleLine` 必須維持 false**，讀上游碼確認過（`CandidatePool4AppKit`）：
    //   `maxLinesPerPage: Int { isExpanded ? _maxLinesPerPage : 1 }`   ← 沒展開就強制回 1 行
    //   `_maxLinesPerPage` 來自控制器 `reloadData()`：`isCandidateWindowSingleLine ? 1 : 4`
    // ⇒ 設成 true 就永遠只有 1 行，↓ 展不開。「收合」與「多行」是兩個開關，不是同一件事：
    // `shouldAutoExpandCandidates` 只決定「開窗時是不是已展開」。
    //
    // 收合狀態下的按鍵（上游 `CandidatePool4AppKit`）：↓／↑ 先展開再移一行；**Space／PageDown 只展開、
    // 不翻頁**（第二下才翻）。這是威注音原樣，也是相對 09-21 版的行為變更（劇本 19e 釘住）。
    var isCandidateWindowSingleLine: Bool { false }          // ⇒ _maxLinesPerPage = 4
    var shouldAutoExpandCandidates: Bool { false }           // ⇒ isExpanded = false（開窗收合）
    /// `123456` —— **決定一行最多幾個**（`selectionKeys.count`；上游橫排按顯示寬度排行，
    /// 多字詞多時一行會更少）。09-21 至 09-30 是 `123456789`。
    /// 單一來源：controller 判斷「這個數字鍵是不是選字鍵」也讀它，不再各存一份。
    /// 選字狀態按 7／8／9 不再是選字鍵：照狀態機「先 Esc 再打字」（劇本 19g）。
    /// 出貨預設。controller 與劇本在沒改偏好時讀到的就是這串。
    nonisolated static let selectionKeyLabels = "123456"
    /// 每次現讀。候選窗 `reloadData` 用它當標籤，也決定一行幾個。
    var selectionKeys: String { MacTypingPreferences.selectionKeys }
    var localeForFontFallbacks: String { "zh-Hant" }
    /// 候選窗上方那一行：游標前那個字的注音。
    ///
    /// 不用 `candidateBarReadingText()`：組得出詞的時候它只回最後一個音節，
    /// 左右鍵移到前面的字時，上方仍顯示句尾的讀音，看不出正在改哪一個。
    var unfinishedReading: String? {
        let keys = engine.compositorKeys.filter { !$0.isEmpty }
        guard !keys.isEmpty else { return nil }
        let index = engine.compositionCursor - 1
        if index >= 0, index < keys.count { return keys[index] }
        return keys[0]
    }
    var showCodePointForCurrentCandidate: Bool { false }
    /// **必須維持 false**：本專案沒有使用者詞庫調權，右鍵選單會叫出無法履行的動作。
    var isCandidateContextMenuEnabled: Bool { false }
    var clientAccentColor: HSBA? { nil }                     // 不跟隨

    func candidatePairs(conv _: Bool) -> [CandidateInState] {
        // 第一版**不**在 `Shared/ZhuyinEngine` 加 `currentCandidatePairs`
        //（那要走 baseline diff，不是 Gate M）⇒ `keyArray` 先給空陣列。
        // 代價：窗的「讀音消歧」顯示退化（`segLength` 退為 1）。單字候選本來就同音，影響小。
        candidateSnapshot.map { (keyArray: [], value: $0) }
    }

    func getCandidate(at index: Int) -> CandidateInState? {
        // 🔴 快照，**不重新問引擎**（不變式 6）。
        guard candidateSnapshot.indices.contains(index) else { return nil }
        return (keyArray: [], value: candidateSnapshot[index])
    }

    func candidateToolTip(shortened _: Bool) -> String { "" }
    func reverseLookup(for _: String) -> [String?] { [] }    // 引擎沒有反查，也不需要
    func checkIsMacroTokenResult(_: Int) -> Bool { false }

    /// 缺口②：窗要開在哪，**與 `ZhuyinEngine` 完全無關**，來源是 IMK 的客戶端游標矩形。
    ///
    /// ⚠️ **完全未實機驗證**（spec §9 #2）：某些 app（Electron 系）常回零矩形。
    /// 這裡的 fallback 是「用滑鼠指標位置」——那只是個不會讓窗飛到螢幕角落的保底值，
    /// **不是對的答案**；要等實機看過才知道該怎麼修。
    func candidateWindowOriginInfo() -> (topLeft: CGPoint, heightDelta: Double) {
        let lineRect = clientLineRect()
        guard lineRect.width > 0 || lineRect.height > 0 else {
            let mouse = NSEvent.mouseLocation
            return (topLeft: mouse, heightDelta: 0)
        }
        // `adjustedTopLeft` 會在下方空間不足時用 `heightDelta` 把窗翻到游標**上面**，
        // 所以 rawTopLeft 給游標行的左下角、heightDelta 給行高。
        return (topLeft: CGPoint(x: lineRect.minX, y: lineRect.minY),
                heightDelta: Double(lineRect.height))
    }

    /// 🔴 **只是 UI 本地高亮變更，絕不可以在這裡呼叫 `setHighlightedCandidate`**（不變式 3）。
    /// 接錯的後果：每按一下方向鍵就 `applyOverride` ＋整句重新解析，窗下的清單被換掉。
    func candidatePairHighlightChanged(at _: Int?) {}

    func candidatePairSelectionConfirmed(at index: Int) {
        // 滑鼠點候選：窗自己走這條。走與鍵盤確認同一個出口。
        // G2：這條路徑不經過 `dispatch()`，`lastConfirmedCandidate` 不會被
        // `logEvent()` 讀到（下一次 `dispatch()` 開頭就清掉）——獨立記一筆
        // `forCandidateConfirm`，不依賴 dispatch-cycle 才有意義的側欄位。
        // 這裡重算一次「index 是否有效」而不是信任 `confirm(at:)` 內部設的
        // `lastConfirmedCandidate`：index 無效時 `confirm` 直接 beep 返回，
        // 那個欄位會停在上一個 dispatch 留下的舊值，用它記錯的選字。
        let chosen = candidateSnapshot.indices.contains(index) ? candidateSnapshot[index] : nil
        lastConfirmApply = nil   // index 無效時 `confirm` 直接返回，不可讀到上一次的舊值
        confirmApplyPending = false
        confirm(at: index)
        closeWindow()
        machine.leaveSelecting()
        // `applied` 在 `updateMarkedText()` 那一次 `getComposedText()` 之後才填得準。
        updateMarkedText()
        let apply = lastConfirmApply
        // log 改在 `updateMarkedText()` **之後**寫——日用 log 驗證器要看「確認後畫面
        // （disp）含不含 chosen」，之前寫的話這一行沒有確認後的畫面可記。
        if let chosen, MacIMEEventLogSink.shared.isEnabled {
            MacIMEEventLogSink.shared.append(
                .forCandidateConfirm(
                    seq: MacIMEEventLogSink.shared.nextSequence(),
                    timestamp: Date(),
                    processID: ProcessInfo.processInfo.processIdentifier,
                    clientBundleID: client?.bundleIdentifier() ?? "?",
                    chosenCandidate: chosen,
                    displayedMarkedText: lastDisplayedMarkedText,
                    composed: lastComposedText,
                    confirmApply: apply
                )
            )
        }
    }

    func candidatePairContextMenuActionTriggered(
        at _: Int, action _: CandidateContextMenuAction
    ) {
        // 選單已關閉（`isCandidateContextMenuEnabled == false`），不會被呼叫。
    }

    func callError(_ message: String) {
        NSSound.beep()
        NSLog("[TWKeyboard] candidate window error: %@", message)
    }
}
