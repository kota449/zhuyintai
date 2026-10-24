// SPDX-License-Identifier: Apache-2.0
// Mac IME：InputMethodKit 標準進入點。
//
// IMKServer 會依 Info.plist 的 `InputMethodServerControllerClass` 自動幫每個連進來的
// client 建立一個 `TWKeyboardMacSpikeController` 實例——這裡不用手動接線。
//
// 🔴 `install` 子命令為什麼非有不可（2026-09-19 實測確認）
// ------------------------------------------------------------------------
// **`TISEnableInputSource()` 必須由輸入法「自己的 process」呼叫才會生效。**
// 從外部工具呼叫它會回 `noErr` 卻完全沒作用（`Enabled` 始終 false），接著
// `TISSelectInputSource()` 就回 `-50 paramErr`——我實測踩過，浪費了一輪。
//
// 正規安裝流程（照 vChewing-macOS 的 `ValueAdd/PKGInstallerAssets/pkgPostInstall.sh`，
// MulanPSL-2.0，© The vChewing Project）：
//   1. 複製 .app 到 `~/Library/Input Methods/`
//   2. `killall TextInputMenuAgent` 然後 `sleep 0.5`
//   3. 執行 `<app>/Contents/MacOS/<exe> install`  ← 就是本檔這段
// 該腳本的註解明講這樣做是為了讓重生的 agent 收錄新輸入源，
// **"without requiring the user to log out and back in"** ⇒ 正規流程不需要登出或重開機。
//
// ⚠️ 不要把這段搬到外部腳本或另一支 CLI——那正是會失敗的那條路。

import Cocoa
import Carbon
import InputMethodKit

/// 本輸入法在 TIS 裡的所有實例（bundle 本身 ＋ `ComponentInputModeDict` 裡的各輸入模式）。
private func registeredInstancesOfThisInputMethod() -> [TISInputSource] {
    guard let bundleID = Bundle.main.bundleIdentifier,
          let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource]
    else { return [] }
    return list.filter { source in
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyBundleID) else { return false }
        return (Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String) == bundleID
    }
}

private func identifier(of source: TISInputSource) -> String {
    guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "?" }
    return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
}

/// 重新列舉，回傳本 bundle **目前真的處於 enabled** 的那些 input source id。
///
/// ⚠️ 一定要重新 `TISCreateInputSourceList`，不要拿舊的 `TISInputSource` 再問一次——
/// 舊物件身上的屬性是當時的快照，同意之後不會自己更新。
private func currentlyEnabledIdentifiers() -> Set<String> {
    var result = Set<String>()
    for source in registeredInstancesOfThisInputMethod() {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled) else { continue }
        if CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue()) {
            result.insert(identifier(of: source))
        }
    }
    return result
}

/// 登記並啟用自己。回傳 process exit code（0 = 成功）。
///
/// 🔴 `waitSeconds` 為什麼非有不可（2026-09-19 實測）
/// ------------------------------------------------------------------------
/// **`TISEnableInputSource()` 對第三方輸入法會觸發一個使用者同意 sheet**
///（「要允許『X』啟用『Y』嗎？」，掛在系統設定的「鍵盤」面板上），
/// **而且它立刻回 `noErr`**——回傳值只代表「請求送出了」，不代表已啟用。
/// 使用者按下「允許」之前，`kTISPropertyInputSourceIsEnabled` 一直是 false。
///
/// 舊版這裡呼叫完就 `exit`，於是印出 `enabled: <id>` 並回 exit 0 ——
/// 那是**假的成功回報**（什麼都沒啟用），正是第十七／十八棒卡住一整晚、
/// 誤判成「TIS 環境問題」的那個現象。
///
/// ⇒ 現在改成：送出請求後**留在 run loop 輪詢真實 enabled 狀態**，直到成功或逾時，
///   並且**只有真的 enabled 才回 exit 0**。
///
/// ⚠️ **這個修法的正當性只來自「`noErr` ≠ enabled，要輪詢真實狀態才能誠實回報」。**
/// 實測另外看過 sheet 出現約 1 秒就消失的情形，但**那個現象的成因至今未定**
///（候選：請求端進程 exit／合成點擊被記成關閉／當下狀態剛好已翻）。
/// **不要把「進程活著 sheet 才活著」寫成已證實的因果**——那個實驗從來沒真的跑成：
/// 新版第一次上場時就讀到 already-enabled、直接 exit 0，sheet 一次都沒出現。
private func runSelfInstall(waitSeconds: TimeInterval) -> Int32 {
    // 一律先登記一次。**不要用「已經有實例就跳過登記」當捷徑**——那會讓「日後在
    // ComponentInputModeDict 新增輸入模式（例如再加一套鍵盤佈局）之後重跑 install」
    // 整個跳過登記：新模式永遠註冊不到，而 install 還是回 exit 0，靜默失敗。
    // 參考實作 vChewing 的 `registerInputMethod()` 有這個縫，**我們刻意不照抄**。
    // （code review 抓到，實測重複登記安全。）
    //
    // ⚠️ 已登記過的 bundle 再登記一次會回什麼狀態不保證，所以**不把回傳值當致命錯誤**——
    // 真正的判準是「登記後列舉得不得到實例」。`TISRegisterInputSource` 回 noErr 也不代表
    // 真的登記成功，本專案今天實測踩過。
    print("[install] registering input source: \(Bundle.main.bundleURL.path)")
    let registerStatus = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
    if registerStatus != noErr {
        print("[install] TISRegisterInputSource returned \(registerStatus) (continuing; enumeration is the real check)")
    }

    let instances = registeredInstancesOfThisInputMethod()
    guard !instances.isEmpty else {
        print("[install] TIS lists no instance of this bundle after registration")
        return 1
    }

    let wanted = Set(instances.map(identifier(of:)))
    let alreadyEnabled = currentlyEnabledIdentifiers()

    // 🔴 **呼叫失敗**與**等待同意**必須分開記。
    // 兩者都會讓某個 id 留在「還沒 enabled」的集合裡，但成因完全不同，
    // 混在一起就會拿「去按允許」去回答一個根本沒跳出對話框的失敗——
    // 那是把這支程式原本的謊話換個位置再講一次。
    var failedToRequest: [String: OSStatus] = [:]
    var awaitingConsent = Set<String>()

    for source in instances {
        let id = identifier(of: source)
        if alreadyEnabled.contains(id) {
            print("[install] 已啟用（不需重新請求）: \(id)")
            continue
        }
        let status = TISEnableInputSource(source)
        if status == noErr {
            // 🔴 措辭刻意不寫 "enabled"：noErr 只代表請求送出。
            print("[install] 已送出啟用請求: \(id)")
            awaitingConsent.insert(id)
        } else {
            // 例如本檔開頭講的 `-50 paramErr`（從錯誤的 process 呼叫）。
            // 這種情形**不會有對話框**，所以不要放進等待集合、也不要叫人去按「允許」。
            print("[install] ❌ TISEnableInputSource 呼叫失敗 \(id): \(status)")
            failedToRequest[id] = status
        }
    }

    func reportFailures() {
        for (id, status) in failedToRequest.sorted(by: { $0.key < $1.key }) {
            print("[install] ❌ 呼叫失敗（沒有對話框，按「允許」救不了）: \(id) status=\(status)")
        }
        if failedToRequest.values.contains(OSStatus(paramErr)) {
            print("[install] 提示：`-50 paramErr` 通常代表不是由輸入法自己的 process 呼叫的。")
        }
    }

    awaitingConsent.subtract(currentlyEnabledIdentifiers())
    if awaitingConsent.isEmpty, failedToRequest.isEmpty { return 0 }

    if waitSeconds <= 0 {
        if !awaitingConsent.isEmpty {
            print("[install] --no-wait：等待同意中的有 \(awaitingConsent.sorted().joined(separator: ", "))")
            print("[install] 需在系統設定 →「鍵盤」上按「允許」；之後重跑 install 確認。")
        }
        reportFailures()
        return 1
    }

    if !awaitingConsent.isEmpty {
        print("[install] 等待使用者在系統設定 →「鍵盤」上按「允許」（最多 \(Int(waitSeconds)) 秒）…")
        // ⚠️ 刻意**不**在這裡印「本進程必須活著對話框才不會被撤掉」。
        // 那個因果沒有被證實（見上方 doc comment），對使用者講沒根據的話
        // 跟對使用者謊報成功是同一種病。
        let deadline = Date().addingTimeInterval(waitSeconds)
        while !awaitingConsent.isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            awaitingConsent.subtract(currentlyEnabledIdentifiers())
        }
    }

    if awaitingConsent.isEmpty, failedToRequest.isEmpty {
        print("[install] ✅ 全部已啟用: \(wanted.sorted().joined(separator: ", "))")
        return 0
    }
    if !awaitingConsent.isEmpty {
        print("[install] ❌ 逾時，仍未啟用: \(awaitingConsent.sorted().joined(separator: ", "))")
        print("[install] 這通常代表同意對話框沒有被按「允許」（或被按了「不允許」）。")
    }
    reportFailures()
    return 1
}

let arguments = CommandLine.arguments.dropFirst().map { $0.lowercased() }
if arguments.first == "install" {
    // pkg postinstall 之類不能久候的情境用 `install --no-wait`。
    let wait: TimeInterval = arguments.contains("--no-wait") ? 0 : 120
    exit(runSelfInstall(waitSeconds: wait))
}

let kConnectionName = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String
let server = IMKServer(
    name: kConnectionName,
    bundleIdentifier: Bundle.main.bundleIdentifier
)

MacPrefsSchema.migrateIfNeeded()   // G14：偏好設定 schema 版本（0→1 為 no-op；降級後版本更新就不動）
MacGeneralPreferences.applySavedCandidateTextSize()
// 更新檢查：接 hook 後在背景檢查一次（佔位 slug／缺版本資料 ⇒ 不發請求；開關關著 ⇒ 不發請求）。
MainActor.assumeIsolated { MacUpdateService.install() }   // 頂層程式碼跑在主執行緒，但編譯器視為 nonisolated
MacUpdateState.shared.requestAutomaticCheck()
// 使用者從 Dock 右鍵結束或在設定視窗按 Cmd-Q，輸入法要留著、只關設定視窗；系統登出／關機照常結束。
// `NSApplication.delegate` 是弱參照，所以放在頂層 let 持有。
let appDelegate = MacIMEAppDelegate()
NSApplication.shared.delegate = appDelegate
NSApplication.shared.run()
