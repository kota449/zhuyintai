// SPDX-License-Identifier: Apache-2.0
// TWKeyboard 的 macOS `IMKInputController`。
//
// **這個檔案刻意保持薄**（spec §3 的三層架構）：
//   IMKInputController（本檔）── 把 IMK 的入口翻譯成 `MacKeyEvent`，其餘什麼都不做
//     └─ MacClientSession ───── per-client 的狀態機持有者＋轉接層（`CandidateMode/`）
//          └─ MacCandidateModeMachine ── 純邏輯，零 AppKit／IMK，`tools/test_mac_candidate_mode.sh` 測得到
//
// 🔴 **不要把狀態放回這裡。** 每個 client app 各有一個 controller 實例。候選窗仍是
// process-wide 單例；引擎是這個 controller 自己的一份，交給 session（G8 Stage 2）。
//
// 物理鍵→注音符號沿用標準（大千式）注音鍵盤排列——這份對照表是憑既有知識手打的，
// **沒有在 repo 內找到對應的既有資料源可以核對**（`tools/native_benchmark/decode_keys.py`
// 是另一種給 iOS 原生 TextInputCJK 用的羅馬拼音對照，不是這個），
// 「已知風險，正式產品化前建議另外核對」，不影響本輪的結論。

import Carbon.HIToolbox
import Cocoa
import InputMethodKit

@objc(TWKeyboardMacSpikeController)
final class TWKeyboardMacSpikeController: IMKInputController {
    /// 這個 client 的引擎。跟 session 一起活，不跟別的 app 共用組字狀態。
    private let engine: any MacZhuyinEnginePort = MacEngineFactory.make()

    /// per-client 狀態。引擎與 session 都是這個 client 私有的。
    ///
    /// session 延後建立而不是放在欄位初始式：`MacClientSession` 是 `@MainActor`
    /// （它要實作 `@MainActor` 的 `CtlCandidateDelegate`），而 `IMKInputController.init` 是
    /// nonisolated ⇒ 直接在欄位初始式裡建會編不過。IMK 的每一個入口都在主執行緒，
    /// 所以第一次取用時才建是安全的。

    private var storedSession: MacClientSession?

    @MainActor
    private var session: MacClientSession {
        if let existing = storedSession { return existing }
        let created = MacClientSession(engine: engine)
        // R7：把 controller 的 `ObjectIdentifier` 交給 session 記進 log。
        // **這是判斷「IMK 到底有沒有重用 controller 實例」的唯一依據**，
        // 而那是 G8 設計的關鍵未知數（IMK 標頭說 controller 是 per input session、不是 per app）。
        created.ownerIdentifier = Self.identifier(of: self)
        storedSession = created
        created.logLifecycle("init")
        return created
    }

    /// R7：`deinit` 用的識別資料。
    ///
    /// **為什麼不直接透過 session 記**：`deinit` 是 nonisolated，而 session 是 `@MainActor`。
    /// 在 `deinit` 裡 `MainActor.assumeIsolated` 若剛好不在主執行緒會 **trap**——
    /// 那等於「log 把輸入法弄掛」，違反「log 壞掉不能讓輸入法壞掉」這條硬條件。
    /// 所以 `deinit` 只走 thread-safe 的 `MacIMEEventLogSink`（自己有佇列與鎖），
    /// 需要的字串在 controller 上自備（純值，任何執行緒都能讀）。
    private var lifecycleControllerID = "?"
    private var lastKnownClientBundleID = "?"

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        lifecycleControllerID = Self.identifier(of: self)
        MacIMEPerfTuning.apply()   // 輸出不變的加速開關（Mac 專用），要在 warmUp 之前
        MacIMEShippingBehavior.apply()   // 會改輸出的 Mac 專用行為（iOS 不開），出貨 json 不放這條
        engine.warmUp()
        engine.refreshChoiceLearning()   // 選字學習；activateServer 會再取一次（開關變更下次啟用生效）
        // 啟動診斷：記下 log 實際解析到的路徑。這是「路徑有沒有解對」的唯一證據——
        // 沙盒容器裡能不能寫，只有真的裝上去跑才算數（見 `MacIMEEventLogSink` 檔頭）。
        MacIMEEventLogSink.shared.logStartupDiagnostics()
    }

    /// `ObjectIdentifier` 的十六進位字串——判斷「IMK 有沒有重用 controller 實例」的唯一依據。
    private static func identifier(of object: AnyObject) -> String {
        String(UInt(bitPattern: ObjectIdentifier(object).hashValue), radix: 16)
    }

    // MARK: - 生命週期（R7，G8 階段 0 探針）

    /// 🔴 `-(void)inputControllerWillClose`（macOS 10.7+，`IMKInputController.h:344`）。
    ///
    /// 注意：`IMKInputController` 有 willClose 這個 override 點。標頭是 ISO-8859 編碼且含長行，
    /// 用一般 grep 查不到（連確定存在的 `activateServer` 也查不到），要用 `LC_ALL=C grep -a` 查。
    override func inputControllerWillClose() {
        super.inputControllerWillClose()
        MacIMEEventLogSink.shared.append(
            .lifecycle(
                seq: MacIMEEventLogSink.shared.nextSequence(),
                timestamp: Date(),
                kind: "inputControllerWillClose",
                controllerID: lifecycleControllerID,
                clientBundleID: lastKnownClientBundleID,
                markedRange: nil,
                msSinceLastDeactivate: nil,
                processID: ProcessInfo.processInfo.processIdentifier
            )
        )
    }

    /// controller 被釋放。配合 `init` 的 `ctrl` 就能回答「IMK 是不是每次都新建、用完就丟」。
    /// 只走 thread-safe 的 sink，理由見 `lifecycleControllerID` 的註解。
    deinit {
        MacIMEEventLogSink.shared.append(
            .lifecycle(
                seq: MacIMEEventLogSink.shared.nextSequence(),
                timestamp: Date(),
                kind: "deinit",
                controllerID: lifecycleControllerID,
                clientBundleID: lastKnownClientBundleID,
                markedRange: nil,
                msSinceLastDeactivate: nil,
                processID: ProcessInfo.processInfo.processIdentifier
            )
        )
    }

    // MARK: - 焦點

    /// 系統「選取的輸入方式改變」通知，整個行程只掛一次。新輸入方式不是我們自己 ⇒ 英文模式重設成中文
    /// （判斷在純函式 `MacInputModeState.inputSourceChanged`，有情境測試涵蓋）。**接線本身未實機驗證**：
    /// 通知沒送到＝維持現狀（跨輸入方式仍保留英文），不會更糟。
    private static let inputSourceObserver: Void = {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { _ in
            var selectedID: String?
            if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
               let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
            {
                selectedID = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
            }
            MainActor.assumeIsolated {
                let before = MacInputModeState.language
                MacInputModeState.inputSourceChanged(selectedID: selectedID, ownBundleID: Bundle.main.bundleIdentifier)
                // N20：實機驗收要能分辨「通知沒送到」與「送到了但 ID 對不上」。
                logProcessLifecycle(
                    "inputSourceChanged id=\(selectedID ?? "<nil>") lang=\(before)->\(MacInputModeState.language)")
            }
        }
    }()

    /// 與 session 無關的行程層 lifecycle log（沒有 client／controller 可用）。
    private static func logProcessLifecycle(_ kind: String) {
        guard MacIMEEventLogSink.shared.isEnabled else { return }
        MacIMEEventLogSink.shared.append(
            .lifecycle(
                seq: MacIMEEventLogSink.shared.nextSequence(),
                timestamp: Date(),
                kind: kind,
                controllerID: "-",
                clientBundleID: "-",
                markedRange: nil,
                msSinceLastDeactivate: nil,
                processID: ProcessInfo.processInfo.processIdentifier
            )
        )
    }

    /// N20：行程第一次 activate 記一行建置戳——執行檔修改時間、行程啟動時間、是否是安裝後沒重啟的舊行程。
    /// 實機 P20 的兩項 FAIL，log 全是同一個 pid（14:14:52 啟動）而執行檔 15:20:43 才換，靠人工比對才看得出來。
    private static let buildStampLogged: Void = {
        let iso = ISO8601DateFormatter()
        var binaryModified: Date?
        if let url = Bundle.main.executableURL {
            binaryModified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
        var processStarted: Date?
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        if sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 {
            let started = info.kp_proc.p_un.__p_starttime
            processStarted = Date(timeIntervalSince1970: TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000)
        }
        let stale = MacBuildStamp.isStale(binaryModified: binaryModified, processStarted: processStarted)
        logProcessLifecycle(
            "buildStamp binaryMtime=\(binaryModified.map(iso.string) ?? "?") procStart=\(processStarted.map(iso.string) ?? "?") stale=\(stale.map(String.init) ?? "?")")
    }()

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        _ = Self.inputSourceObserver
        _ = Self.buildStampLogged
        MacUpdateState.shared.requestAutomaticCheck()   // 更新檢查：只派發背景工作（24 小時節流＋開關在裡面），不等結果、不彈視窗
        if let bundleID = (sender as? IMKTextInput)?.bundleIdentifier() {
            lastKnownClientBundleID = bundleID
        }
        // 選字學習：沙箱外／開關關 ⇒ nil（學習層整個關閉）；開關變更在下次啟用時生效。
        engine.refreshChoiceLearning()
        MainActor.assumeIsolated {
            session.activate(client: sender as? IMKTextInput)
        }
    }

    override func deactivateServer(_ sender: Any!) {
        // 🔴 不變式 1：窗是 process-wide 單例 ⇒ 切走的 client 一律先關窗，
        // 否則下一個 app 會看到別人的候選窗掛在那裡。
        //
        // **組字刻意不 commit**：這時前景已經換人了，`insertText` 會把字送進**下一個** app
        // （那正是 G8 要避免的漏字）。代價見 `MacClientSession.deactivate` 的註解。
        MainActor.assumeIsolated {
            session.deactivate()
        }
        MacChoiceLearning.flush()   // 選字學習：落檔（去抖之外的保險）
        super.deactivateServer(sender)
    }

    /// 系統在切換焦點等時機要求「把現在的組字定下來」。
    ///
    /// 窗開著時先關窗再上屏：直接送 `.enter` 會被 `Selecting` 解讀成「確認目前高亮」
    /// （確認是**進組字**，不是上屏）⇒ 使用者切個視窗就等於替他按了一個他沒選的候選。
    override func commitComposition(_ sender: Any!) {
        MainActor.assumeIsolated {
            let client = sender as? IMKTextInput
            session.logLifecycle("commitComposition")
            // 窗開著先關窗再上屏、一律 `forceImmediateCommit`（選項 C 的逃生口）：
            // 邏輯在 `MacClientSession.flushComposition`，單押 Shift 切英文共用同一條；
            // 但點走（`clickAway`）「沒拼完的注音」一律留著、不照設定（實機證實這時宿主已不回應這個 client，『丟掉』『補一聲』落不了地）。
            session.flushComposition(client: client, clickAway: true)
            // 診斷：commit 之後宿主的 markedRange（實機驗收用，留一行）。
            session.logLifecycle("commitCompositionDone")
        }
    }

    // MARK: - 字元入口

    override func inputText(_ string: String!, client sender: Any!) -> Bool {
        guard let client = sender as? IMKTextInput else { return false }
        guard let raw = string, raw.count == 1, let symbol = raw.first else {
            // 多字元輸入（注音拼字階段不該出現）也記一筆——「按了沒反應」的來源之一。
            MainActor.assumeIsolated {
                session.logUnmapped(entry: "inputText", raw: string ?? "<nil>", client: client)
            }
            return false
        }
        return MainActor.assumeIsolated {
            guard let event = keyEvent(for: symbol) else {
                session.logUnmapped(entry: "inputText", raw: raw, client: client)
                return false
            }
            // G7 的游標偵測在 `MacClientSession.handle`：這一筆若發現
            // `selectedRange` 已離開 marked range，會先送 `.clientCursorMoved`。
            return session.handle(event, client: client, entry: "inputText", raw: raw)
        }
    }

    /// 有些 host app／IMK 版本不是把 Return 當字元送進 `inputText:client:`，而是轉成
    /// `insertNewline:` 命令。方向鍵、Esc、Backspace、翻頁鍵也走這條（它們不是字元，
    /// `inputText:` 根本收不到）。
    ///
    /// 🔴 **這整條路徑本輪未經實機驗證**（spec §9 #1、§4.2）：`moveDown:` / `cancelOperation:`
    /// 等 selector 是否真的會送到這裡，只有裝上去打字才知道。若實機發現收不到，
    /// 就要整個改走 `handleEvent:client:` ——那是全有或全無的切換，但**狀態機與它的
    /// 130+ 條測試一行都不用動**（`MacKeyEvent` 刻意獨立於 IMK 入口形式）。
    override func didCommand(by aSelector: Selector!, client sender: Any!) -> Bool {
        guard let client = sender as? IMKTextInput else { return false }
        let selectorName = aSelector.map { NSStringFromSelector($0) } ?? "<nil>"
        guard let event = Self.commandEvent(for: aSelector) else {
            // 🔑 **這一筆是最有診斷價值的記錄之一**：spec §4.2 說「`didCommand` 收不收得到
            // 方向鍵」未經驗證。收到但我們沒對映的 selector 會在 log 裡以 `ev=UNMAPPED` 出現，
            // 一個 grep 就知道實機上到底送了哪些 selector 進來。
            MainActor.assumeIsolated {
                session.logUnmapped(entry: "didCommand", raw: selectorName, client: client)
            }
            return false
        }
        return MainActor.assumeIsolated {
            session.handle(event, client: client, entry: "didCommand", raw: selectorName)
        }
    }

    // MARK: - 單押 Shift（flagsChanged）與 keyDown 入口

    /// 單押 Shift 要收 `flagsChanged`，所以事件遮罩加上它；點走要收滑鼠按下（N7）。
    ///
    /// 🔴 N8 (3)：遮罩**固定**包含 flagsChanged／leftMouseDown／rightMouseDown，不依偏好決定。
    /// 原因：IMK 不一定在偏好改變後重問遮罩，而 `handle` 是無條件覆寫的；遮罩若跟偏好走，
    /// 就會出現「遮罩說不要、handle 卻在收」的不一致。開關只在 `handle` 內判斷（單押 Shift 關閉時
    /// `handleFlagsChanged` 什麼都不做；滑鼠按下照常 commit（N14：點走一律留著注音），行為與開關無關）。
    ///
    /// 🔴 兩個已知代價（IMK 標頭＋spec E4，未實機驗證）：
    ///   1. 不是「只回 keyDown」⇒ IMK 不再在『使用者在組字區外點滑鼠』時送 `commitComposition:`，
    ///      由 `handle` 收到滑鼠按下時補回（`handleMouseDown`）。⚠️ 已知限制：滑鼠座標對不上宿主的組字範圍，
    ///      點在組字區**內**也會上屏。
    ///   2. controller 有 `handle(_:client:)` 之後 keyDown 也走那條路（全有或全無），見 `handle`。
    override func recognizedEvents(_ sender: Any!) -> Int {
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]
        return Int(bitPattern: UInt(mask.rawValue))
    }

    /// `flagsChanged` → 單押 Shift 偵測；`keyDown` → 與 `inputText`／`didCommand` 兩條舊路徑逐鍵相同的翻譯
    /// （`MacNSEventKeyMapper`，純函式、有單元測試）。其他事件一律不處理。
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event else { return false }
        let client = sender as? IMKTextInput
        switch event.type {
        case .flagsChanged:
            let flags = event.modifierFlags
            MainActor.assumeIsolated {
                _ = session.handleFlagsChanged(
                    shiftDown: flags.contains(.shift),
                    otherModifiersDown: !flags.intersection([.command, .option, .control]).isEmpty,
                    client: client)
            }
            return false
        case .leftMouseDown, .rightMouseDown:
            MainActor.assumeIsolated { _ = session.handleMouseDown(client: client) }
            return false
        case .keyDown:
            guard let client else { return false }
            return MainActor.assumeIsolated {
                let flags = event.modifierFlags
                var modifiers: MacKeyModifiers = []
                if flags.contains(.shift) { modifiers.insert(.shift) }
                if flags.contains(.control) { modifiers.insert(.control) }
                if flags.contains(.option) { modifiers.insert(.option) }
                if flags.contains(.command) { modifiers.insert(.command) }
                // N21：帶修飾鍵時 log 的 raw 後面加 ` mods=shift` 之類；沒有修飾鍵＝與以前完全相同。
                let modsSuffix = MacNSEventKeyMapper.modifierLabel(modifiers).map { " mods=\($0)" } ?? ""
                guard let mapped = MacNSEventKeyMapper.event(
                    keyCode: event.keyCode, characters: event.characters, modifiers: modifiers,
                    isSelecting: session.isSelecting, selectionKeys: session.selectionKeys)
                else {
                    session.logUnmapped(
                        entry: "handle",
                        raw: "keyCode=\(event.keyCode) chars=\(event.characters ?? "<nil>")" + modsSuffix,
                        client: client)
                    return false
                }
                return session.handle(
                    mapped, client: client, entry: "handle",
                    raw: (event.characters ?? "keyCode=\(event.keyCode)") + modsSuffix)
            }
        default:
            return false
        }
    }

    // MARK: - 輸入法選單（G11）

    /// 選單打開隨 bundle 附帶的授權全文。用系統預設 app 開文字檔，不另做視窗。
    override func menu() -> NSMenu! {
        MacPreferencesPresenter.logEntry(phase: "menu", ctrl: lifecycleControllerID, client: lastKnownClientBundleID)
        let menu = NSMenu(title: "Input Method Menu")
        menu.addItem(
            withTitle: "偏好設定…",
            action: #selector(showPreferences(_:)),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: "開放原始碼授權…",
            action: #selector(showThirdPartyNotices(_:)),
            keyEquivalent: ""
        )
        // 有新版才多一項；點了才出現提示視窗（不主動彈窗，免得搶打字焦點）。
        if let title = MacUpdateState.shared.menuItemTitle {
            menu.addItem(withTitle: title, action: #selector(showUpdatePrompt(_:)), keyEquivalent: "")
        }
        return menu
    }

    /// `IMKInputController` 既有的 `showPreferences:`。選單「偏好設定…」走這裡。
    override func showPreferences(_ sender: Any?) {
        MacPreferencesPresenter.logEntry(phase: "action", ctrl: lifecycleControllerID, client: lastKnownClientBundleID, item: "prefs")
        let requester = lifecycleControllerID
        let client = lastKnownClientBundleID
        MainActor.assumeIsolated {
            MacPreferencesPresenter.show(requester: requester, client: client)
        }
    }

    @objc private func showThirdPartyNotices(_ sender: Any?) {
        MacPreferencesPresenter.logEntry(phase: "action", ctrl: lifecycleControllerID, client: lastKnownClientBundleID, item: "notices")
        MacThirdPartyNotices.show()
    }

    @objc private func showUpdatePrompt(_ sender: Any?) {
        MacPreferencesPresenter.logEntry(phase: "action", ctrl: lifecycleControllerID, client: lastKnownClientBundleID, item: "update")
        MacUpdateState.shared.presentPrompt()
    }

    // MARK: - 按鍵翻譯

    private static func commandEvent(for selector: Selector?) -> MacKeyEvent? {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): return .enter
        case #selector(NSResponder.cancelOperation(_:)): return .escape
        case #selector(NSResponder.deleteBackward(_:)): return .backspace
        case #selector(NSResponder.deleteForward(_:)): return .deleteForward
        case #selector(NSResponder.moveUp(_:)): return .moveUp
        case #selector(NSResponder.moveDown(_:)): return .moveDown
        case #selector(NSResponder.moveLeft(_:)): return .moveLeft
        case #selector(NSResponder.moveRight(_:)): return .moveRight
        case #selector(NSResponder.pageUp(_:)): return .pageUp
        case #selector(NSResponder.pageDown(_:)): return .pageDown
        default: return nil
        }
    }

    /// 字元 → 事件。選字鍵標籤每次現讀，偏好設定切換後下一次開窗就生效。
    @MainActor
    private func keyEvent(for symbol: Character) -> MacKeyEvent? {
        MacKeyEventTranslator.event(
            for: symbol,
            isSelecting: session.isSelecting,
            selectionKeys: session.selectionKeys
        )
    }
}
