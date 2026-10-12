// SPDX-License-Identifier: Apache-2.0
// 打字事件 log 的**純邏輯層**：一筆記錄長什麼樣、序號怎麼發、單日超量上限。
// （每天一個檔、只留 7 天的檔名／換檔／啟動遷移規則在同目錄的 `MacIMEDailyLog.swift`。）
//
// 由來（2026-09-21 使用者實機試打後）：「我只能講說這個打字的體驗真的差到不行」
// ＋「你這個輸入法可不可以做個 log 檔案啊，記錄一下我每次打字發生任何情況，
// 這樣子你就可以直接知道哪裡有問題了」。
//
// 🔴 **標準只有一條：事後能從 log 重建「他到底按了什麼、每一步發生什麼」。**
// 「體驗差到不行」對我們是一句無法行動的話；有 log 它才是資料。
// ⇒ 寧可多印一個欄位，也不要在判讀時發現缺了關鍵的一格。
//
// 🔴 **不得 import AppKit／InputMethodKit，也不做任何 I/O。**
// 檔案寫入在 `MacIMESpike/CandidateWiring/MacIMEEventLogSink.swift`。
// 分兩層是為了讓這一層能用純 swiftc 測（`tools/test_mac_ime_event_log.sh`）——
// sink 要在沙盒容器裡才驗得到，那是本輪驗不到的東西。
//
// 格式：**一筆一行、欄位以 tab 分隔、每欄 `key=value`**。
// 選 tab 而不是 JSON：這個檔是要給人 `grep` 與肉眼掃的（維護者會直接讀），
// 而 JSON 一行的可讀性差、逐鍵事件量又大。值裡的控制字元一律轉義，
// 一個沒轉義的換行就會把記錄切成兩行、讓序號對不上。

import Foundation

// MARK: - 序號

/// 單調遞增的事件序號（從 1 開始）。
///
/// 為什麼要鎖：兩筆記錄的時間戳可能落在同一毫秒，那時**序號是唯一能定先後的東西**，
/// 而判讀 log 時「誰先誰後」正是最常要問的問題。目前呼叫端都在主執行緒，
/// 但 sink 的 flush 在背景佇列，將來若有別的地方取號，重複的序號會直接讓 log 失去意義。
public final class MacIMELogSequence {
    private var value = 0
    private let lock = NSLock()

    public init() {}

    public func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

// MARK: - 換檔上限

public enum MacIMELogRotation {
    /// 單日檔的**安全閥**：64 MB。超過就在同一天內切成 `typing_events-D.N.log`（見 `MacIMEDailyLog`）。
    ///
    /// 🔴 這不再是「保留多少」的上限——log 現在是每天一個檔、換檔不刪（2026-10-01 使用者要求；2026-10-06 起另有「只留 7 天」的過期修剪，見 `MacIMEDailyLog.expiredLogNames`；
    /// 舊制是單檔 4 MB ＋ 1 份 `.1`，滿了就刪舊的，約一天就蓋掉一輪）。64 MB 只是防止單一檔案
    /// 大到編輯器開不了；實機一天約 4 MB，正常使用碰不到。
    public static let defaultMaxBytes = 64 * 1024 * 1024

    /// - Returns: 寫入這筆之前要不要先換檔（單日超量切檔）。
    ///
    /// `currentBytes == 0` 時一律不換——空檔案換檔只會產生一個空檔，
    /// 把真正有內容的上一份擠到後面。單筆就超過上限時也是如此（寧可讓那一筆超標）。
    public static func shouldRotate(currentBytes: Int, incoming: Int, maxBytes: Int) -> Bool {
        guard currentBytes > 0 else { return false }
        return currentBytes + incoming > maxBytes
    }
}

// MARK: - 一筆記錄

/// 確認候選字（`confirm(at:)`）之後**引擎到底有沒有套用**的證據（loop C，2026-09-30）。
/// `applied`：這一輪唯一一次 `getComposedText()`（`updateMarkedText`）是否含所選字；`engineValueAtIndex`：
/// 引擎 `activeCandidatePairs[index]` 的值（跟窗的快照不同就是 index 錯位）；`overrideApplied`：
/// `Megrez.overrideCandidate` 的回傳（`nil` ⇒ 沒走到）。
public struct ConfirmApplyOutcome: Equatable {
    public let applied: Bool
    public let engineValueAtIndex: String?
    public let overrideApplied: Bool?

    public init(applied: Bool, engineValueAtIndex: String?, overrideApplied: Bool?) {
        self.applied = applied
        self.engineValueAtIndex = engineValueAtIndex
        self.overrideApplied = overrideApplied
    }

    /// 序列化成 log 欄位。`applied` 一律印；失敗時多印哨兵與證據（同 `DISP_MISMATCH`：
    /// 只在異常時出現，`grep CONFIRM_NOT_APPLIED` 一次撈全部）。
    var fields: [(String, String)] {
        var out: [(String, String)] = [("applied", applied ? "1" : "0")]
        if !applied {
            out.append(("CONFIRM_NOT_APPLIED", "1"))
            out.append(("engVal", engineValueAtIndex ?? "-"))
            out.append(("ovOK", overrideApplied.map { $0 ? "1" : "0" } ?? "-"))
        }
        return out
    }
}

public struct MacIMEEventRecord {
    public let seq: Int
    public let timestamp: Date
    /// 有序的 `key=value`；**順序就是可讀性**，所以用陣列不用字典。
    public let fields: [(String, String)]

    public init(seq: Int, timestamp: Date, fields: [(String, String)]) {
        self.seq = seq
        self.timestamp = timestamp
        self.fields = fields
    }

    public func serialized() -> String {
        var parts = ["seq=\(seq)", "t=\(Self.formatter.string(from: timestamp))"]
        parts.append(contentsOf: fields.map { "\($0.0)=\(Self.escape($0.1))" })
        return parts.joined(separator: "\t")
    }

    /// 毫秒解析度。沒有毫秒就看不出兩鍵之間隔多久，而「卡頓」正是使用者抱怨的那類症狀。
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    /// 值裡的控制字元轉義。
    ///
    /// 使用者打的字、宿主 app 的 bundle id、selector 名稱都可能帶任何東西；
    /// 一個沒轉義的 tab 會讓欄位數爆掉、一個換行會把記錄切成兩行。
    /// 轉成 `\t`／`\n`／`\r` 而不是刪掉，是為了**判讀時還看得出原本有什麼**。
    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    // MARK: 計算欄位（機械哨兵）
    //
    // 🔴 稽核 #2（`mac-model-drift`）的核心指摘：舊版 `dump_mac_ime_log.sh` 裡那句
    // 「同一個音節同時出現在兩邊＝bug 回來了」**只是一行給人讀的註解**，沒有任何欄位在判它，
    // 而且肉眼也比不出來（`comp` 是漢字、`buf` 是注音，不會出現同字串）。
    // 以下是把它變成真的機械判斷。

    /// 顯示層走過的 key 數與引擎 `compositorKeys.count` 不一致 ⇒ 顯示漏了或多了一段。
    ///
    /// **與稽核 #2 給的公式不同，這是刻意的。** 原式
    /// `dispUnits = (disp 字數 − buf 字數) + (buf 空 ? 0 : 1)` 假設「一個 key 顯示一個字」，
    /// 而 R3 修好之後 unsealed 的音節顯示的是**注音原文**（1～3 個字元不等）
    /// ⇒ 正常情形也會被標記（哨兵每次都響＝等於沒有哨兵）。
    /// 顯示層本來就是逐 key 組的，直接讓它回報走過幾個 key，與字元數無關。
    public static func hasDisplayMismatch(displayedKeyCount: Int, keyCount: Int) -> Bool {
        displayedKeyCount != keyCount
    }

    /// 新模型的不變式：`partial` 時「正在拼的緩衝區」必須等於引擎的 `keys[cursor-1]`。
    ///
    /// 不成立 ⇒ 引擎拒絕了 `replaceLastKey`（或 `input` 失敗），composer 與引擎錯位。
    /// 那是 G4 那幾條 fallback 的來源，也是「畫面跟我打的不一樣」最可能的機制。
    /// 🔴 比對 `keys[cursor-1]` 而不是 `keys.last`——游標相對，同 G4 的 Bug A。
    public static func hasBrokenInvariant(
        buffer: String, compositorKeys: [String], cursor: Int
    ) -> Bool {
        guard !buffer.isEmpty else { return false }   // settled 不適用
        let index = cursor - 1
        guard index >= 0, index < compositorKeys.count else { return true }
        return compositorKeys[index] != buffer
    }

    // 🔴 這裡**沒有**「候選是不是這一鍵的」欄位，而且不該有。
    //
    // 曾經有 `candLag`（兩個累加器的差，會永久漂移——稽核 #2）與接替它的 `candStale`
    //（只在候選指紋變了才更新快照，犯同類錯誤）。兩個都被證明無效，已移除。
    // 根本原因：log 在 input 後**微秒內**取樣，引擎候選更新有約 20ms 的 debounce
    // ⇒ **每一列的 `cand`／`candN` 本來就是上一鍵的清單**，「是不是這一鍵的」在打字列上
    // 幾乎恆為否，沒有訊號。`cand`／`candN` 的語意固定為「事件當下同步取樣」，
    // **不可拿來推論候選過期**。詳見 `MacIMEEventLogCLIProbe` 的反向釘子
    // `testRecordDoesNotClaimCandidateStaleness`。

    // MARK: 工廠

    /// 一個按鍵事件的完整記錄。
    ///
    /// 欄位順序刻意固定成「**發生了什麼 → 我怎麼解讀 → 狀態怎麼變 → 引擎長怎樣 → 候選 → 耗時**」，
    /// 肉眼由左往右掃就是事件的因果順序。
    public static func forKeyEvent(
        seq: Int,
        timestamp: Date,
        entry: String,
        raw: String,
        clientBundleID: String,
        keyEvent: String,
        stateBefore: String,
        stateAfter: String,
        effects: [String],
        /// R5c：`fx` 記的是「計畫」，引擎到底接不接得住沒記——**而那正是 composer↔引擎
        /// 錯位的來源**。有結果的 effect 在這裡帶 `true`／`false`。
        effectResults: [String: Bool],
        buffer: String,
        composed: String,
        compositorKeys: [String],
        cursor: Int,
        /// R5b：**畫面上實際是什麼**。沒有它，一個畫面 bug 的 log 等於沒有——
        /// 洞 A 的 log 是 `buf=ㄏㄠ comp=你好 keys=[ㄋㄧˇ,ㄏㄠ]`，看不出畫面其實是「你好ㄏㄠ」。
        displayedMarkedText: String,
        selectionLocation: Int,
        /// 顯示層走過幾個 key（見 `hasDisplayMismatch`）。負數 ⇒ 這次沒有更新畫面，不判。
        displayedKeyCount: Int = -1,
        candidateCount: Int,
        candidatePreview: [String],
        durationMicroseconds: Int,
        /// Z5（日用 log 驗證器，`m1_guardrails_20260926.md` §五）：`lifecycle` 已經有 pid，
        /// 按鍵事件本來沒有——兩個 process 交錯寫進同一份物理檔案時（mem0 `78792eb8`），
        /// 沒有 pid 就不能安全做跨行核對。預設值讓既有呼叫端不用逐一補這個參數。
        processID: Int32 = Int32(ProcessInfo.processInfo.processIdentifier),
        /// Z5：確認候選字（`confirmHighlightedCandidate`／`confirmCandidateAtSelectionKey`）
        /// 那一行才有值，直接是 `confirm(at:)` 用掉的 `candidateSnapshot[index]`——
        /// **不是驗證器重算的**，重算會跟自己的答案互相印證，等於沒驗。
        /// `nil` ⇒ 這一行不是確認事件，不印這個欄位（欄位存在與否本身就是訊號）。
        chosenCandidate: String? = nil,
        /// B4（loop B，2026-09-26，`g1_commit_mismatch_20260926.md`）：`composed` 參數
        /// （`comp` 欄位）是上一鍵 `updateMarkedText()` 留下的快照——`.enter` 從不呼叫
        /// `updateMarkedText()`，所以 commit 那一行的 `comp` 不是這一行真正送給
        /// `client.insertText()` 的字串。這個值直接是 `commitComposedText()` 裡另外
        /// 呼叫一次 `getComposedText()` 算出來、實際送出去的那個字串——**不是重算的**，
        /// 同 `chosenCandidate` 的道理。`nil` ⇒ 這一行沒有 commit，不印這個欄位。
        committedText: String? = nil,
        /// loop C：確認候選字那一行才有值——引擎套用成功與否的直接證據，見 `ConfirmApplyOutcome`。
        confirmApply: ConfirmApplyOutcome? = nil,
        /// 選字學習：這一鍵讓引擎自動套用了幾段「記住的選字」（`engine.learnedChoicesAppliedTotal`
        /// 的差值）。0 ⇒ 不印——功能關掉或沒命中時 log 與舊版逐字相同。
        learnedApplied: Int = 0
    ) -> MacIMEEventRecord {
        var fields: [(String, String)] = [
            ("entry", entry),
            ("raw", raw),
            ("app", clientBundleID),
            ("pid", String(processID)),
            ("ev", keyEvent),
            ("st", "\(stateBefore)->\(stateAfter)"),
            // effect **逐個列出**（不是只印數量）：狀態機吐了什麼正是「為什麼畫面變成那樣」
            // 的答案。有引擎回饋的在名字後面接 `=1`／`=0`（R5c）。
            ("fx", "[" + effects.map { effect in
                guard let ok = effectResults[effect] else { return effect }
                return "\(effect)|ok=\(ok ? 1 : 0)"
            }.joined(separator: ",") + "]"),
        ]
        if let chosenCandidate {
            fields.append(("chosen", chosenCandidate))
        }
        if let confirmApply {
            fields.append(contentsOf: confirmApply.fields)
        }
        if let committedText {
            fields.append(("committed", committedText))
        }
        if learnedApplied > 0 {
            fields.append(("learned", String(learnedApplied)))
        }
        fields.append(contentsOf: [
            ("buf", buffer),
            ("comp", composed),
            ("disp", displayedMarkedText),
            ("sel", String(selectionLocation)),
            ("keys", "[" + compositorKeys.joined(separator: ",") + "]"),
            ("cur", String(cursor)),
            // 候選：**事件當下同步取樣**＝上一鍵的清單（debounce ≈20ms），
            // 不可拿來推論「候選過期」（見上方註解）。
            ("candN", String(candidateCount)),
            ("cand", "[" + candidatePreview.joined(separator: ",") + "]"),
            // 每鍵耗時：順便把護欄 G9（逐鍵延遲 p95）的原始資料收掉。
            ("dur_us", String(durationMicroseconds)),
        ])
        // 🔴 兩個機械哨兵：**只在異常時出現**，這樣 `grep` 一次就撈得到全部可疑的事件。
        if displayedKeyCount >= 0,
           hasDisplayMismatch(displayedKeyCount: displayedKeyCount, keyCount: compositorKeys.count)
        {
            fields.append(("DISP_MISMATCH", "1"))
            fields.append(("dispKeys", String(displayedKeyCount)))
        }
        if hasBrokenInvariant(buffer: buffer, compositorKeys: compositorKeys, cursor: cursor) {
            fields.append(("INV_BROKEN", "1"))
        }
        return MacIMEEventRecord(seq: seq, timestamp: timestamp, fields: fields)
    }

    /// R7：生命週期事件（`init`／`activateServer`／`deactivateServer`／`commitComposition`／`deinit`）。
    ///
    /// 這是 G8 設計的**階段 0 探針**。三個關鍵未知數只有實機 log 能回答：
    /// ① IMK 到底有沒有重用 controller 實例（`ctrl` 的 `ObjectIdentifier`）
    /// ② IMK 標頭說 controller 是 **per input session**（不是 per app）——實際如何
    /// ③ `activate`／`deactivate` **沒有時序保證**——實際順序與間隔（`sinceDeact_ms`）
    ///
    /// 它順便回答 R4d：實機 log 中途冒出第二筆 `kind=startup`，到底是 IMK 正常行為還是 crash。
    /// - Parameter processID: `ProcessInfo.processInfo.processIdentifier`。
    ///
    /// 🔴 加這個欄位的理由是 log 會說謊的**第三種形態**（維護者指名，drift 的 D8 系列）：
    /// 前兩種是欄位語意錯（`candLag` 是會漂移的累加器、`cand` 欄其實是上一鍵的），
    /// 這一種是**來源混同**——輸入法重裝時，舊 process 收尾與新 process 啟動的 lifecycle 行
    /// 可能交錯寫進同一份物理 log 檔（`MacIMEEventLogSink.shared` 是 process-wide 單例，
    /// 但那個「process-wide」只在單一 process 內成立；兩個 process 各自的單例都寫同一個檔案路徑）。
    /// R4d 查真的重啟事件時撞到一筆對不上的 `kind=deinit`，當時沒有 pid 無法證實是不是這個原因。
    /// `ctrl`（ObjectIdentifier）不夠：它只在單一 process 位址空間內保證唯一，兩個 process
    /// 的物件理論上可能撞到相同的位元組樣式。pid 才是真正跨 process 的身分。
    public static func lifecycle(
        seq: Int,
        timestamp: Date,
        kind: String,
        controllerID: String,
        clientBundleID: String,
        markedRange: String?,
        msSinceLastDeactivate: Int?,
        processID: Int32
    ) -> MacIMEEventRecord {
        var fields: [(String, String)] = [
            ("entry", "lifecycle"),
            ("kind", kind),
            ("pid", String(processID)),
            ("ctrl", controllerID),
            ("app", clientBundleID),
        ]
        if let markedRange { fields.append(("mrange", markedRange)) }
        // 第一次啟動沒有「上一次 deactivate」可言——不要印一個假的 0，
        // 那會讓判讀的人誤以為是瞬間切回來。
        if let msSinceLastDeactivate {
            fields.append(("sinceDeact_ms", String(msSinceLastDeactivate)))
        }
        return MacIMEEventRecord(seq: seq, timestamp: timestamp, fields: fields)
    }

    /// 翻不出 `MacKeyEvent` 的原始輸入。
    ///
    /// **這類最可能是使用者抱怨的來源**（「按了沒反應」「跑掉了」），所以要大聲標記：
    /// `ev=UNMAPPED` 一個 grep 就撈得出來，`raw` 留著才查得到是哪個鍵。
    public static func forUnmappedInput(
        seq: Int,
        timestamp: Date,
        entry: String,
        raw: String,
        clientBundleID: String
    ) -> MacIMEEventRecord {
        MacIMEEventRecord(
            seq: seq,
            timestamp: timestamp,
            fields: [
                ("entry", entry),
                ("raw", raw),
                ("app", clientBundleID),
                ("ev", "UNMAPPED"),
            ]
        )
    }

    /// 滑鼠點候選確認（`candidatePairSelectionConfirmed`）。
    ///
    /// 這條路徑不經過 `dispatch()`——沒有 `MacKeyEvent`、沒有 effects——所以不塞進
    /// `forKeyEvent`，另立一種輕量記錄。`entry=mouseConfirm` 兼做來源標記（`entry` 欄本來
    /// 就是分辨事件種類的欄位），`chosen`／`pid` 兩個欄位名與 `forKeyEvent` 一致，
    /// G2 驗證器才能用同一套「`chosen=` 之後找下一個 commit」規則核對兩種來源。
    public static func forCandidateConfirm(
        seq: Int,
        timestamp: Date,
        processID: Int32,
        clientBundleID: String,
        chosenCandidate: String,
        /// loop C：確認**之後**的畫面（`updateMarkedText()` 之後的 `lastDisplayedMarkedText`）。
        /// G2 驗證器新口徑「確認後那一行的 `disp` 含 chosen」對滑鼠路徑需要它；`nil` ⇒ 不印
        /// （舊呼叫端）。欄位名與 `forKeyEvent` 一致。
        displayedMarkedText: String? = nil,
        composed: String? = nil,
        confirmApply: ConfirmApplyOutcome? = nil
    ) -> MacIMEEventRecord {
        var fields: [(String, String)] = [
            ("entry", "mouseConfirm"),
            ("app", clientBundleID),
            ("pid", String(processID)),
            ("chosen", chosenCandidate),
        ]
        if let confirmApply {
            fields.append(contentsOf: confirmApply.fields)
        }
        if let composed {
            fields.append(("comp", composed))
        }
        if let displayedMarkedText {
            fields.append(("disp", displayedMarkedText))
        }
        return MacIMEEventRecord(seq: seq, timestamp: timestamp, fields: fields)
    }

    /// G7 觀察模式：偵測到宿主游標離開組字區，但**不**送 `.clientCursorMoved`。
    ///
    /// 真 app 回報的 range 可能不準（PR #246 review）。先把「若啟用會定案」記下來，
    /// 等實機看誤判率再決定要不要打開。`markedRange`／`selectedRange` 是 `location,length`。
    public static func cursorMovedWouldFire(
        seq: Int,
        timestamp: Date,
        clientBundleID: String,
        markedRange: String,
        selectedRange: String,
        displayedMarkedText: String
    ) -> MacIMEEventRecord {
        MacIMEEventRecord(
            seq: seq,
            timestamp: timestamp,
            fields: [
                ("entry", "cursorMovedWouldFire"),
                ("app", clientBundleID),
                ("markedRange", markedRange),
                ("selectedRange", selectedRange),
                ("disp", displayedMarkedText),
            ]
        )
    }

    /// 生命週期／診斷用的自由記錄（啟動、focus 切換、log 自己的狀況…）。
    public static func note(
        seq: Int, timestamp: Date, kind: String, detail: [(String, String)] = []
    ) -> MacIMEEventRecord {
        MacIMEEventRecord(
            seq: seq, timestamp: timestamp, fields: [("entry", "note"), ("kind", kind)] + detail
        )
    }
}
