// SPDX-License-Identifier: Apache-2.0
// 打字事件 log 的**寫入層**：路徑解析、背景批次 flush、換檔（每天一個檔）、失敗時的降級。
//
// 純邏輯（記錄格式、序號、檔名／換檔決策／啟動遷移計畫）在 `MacIMESpike/EventLog/`
// （`MacIMEEventLog.swift`、`MacIMEDailyLog.swift`），那一層用純 swiftc 測得到。真的搬檔在
// `MacIMEDailyLogFiles.swift`（只有改名、**沒有任何刪除呼叫**）。這一層的狀態機
// （flush → 換檔 → 寫入）可以注入目錄與時鐘，所以也在暫存目錄裡測過（`tools/test_mac_ime_event_log.sh`）；
// 但「真的在沙盒容器裡寫得進去」仍然只有裝上去跑才算數。
//
// 🔴 **每天一個檔、換檔只改名、過期才刪**（2026-10-01 使用者原話：「每一天都是新的 log，這樣子就不會被刪掉了」；
// 2026-10-06 使用者決定「本機 log 預設開、只留約一週」——**取代**原本的「永不刪除」，但只取代這一項）。
// 舊制是單檔 4 MB ＋ 1 份 `.1`，滿了就刪掉舊的——實機約一天就蓋掉一輪。現在：
//   `typing_events.log`          現行檔
//   `typing_events-D.log`        D 那天封存的日檔（午夜之後第一次 flush 時把現行檔改名成它）
//   `typing_events-D.N.log`      同一天寫滿 64 MB 時切出來的檔（只切檔、不刪）
// **換檔只靠改名**（`MacIMEDailyLogFiles` 沒有任何刪除呼叫，`tools/test_mac_ime_event_log.sh` 仍用 grep 守著）。
// **唯一會刪檔的地方是保留期限修剪**：內容整個超過 7 天的日檔（`MacIMEDailyLog.expiredLogNames` 純計算選名單，
// `Shared/MacUsageLogCleaner.deleteFiles` 實際刪），時機是**每個行程啟動一次**與**跨日換檔之後**，都在背景佇列、
// 不在按鍵熱路徑。修剪只認得 `classify` 認得的檔名——選字記憶、自訂詞、詞庫永遠選不到。
// 修剪失敗（檔被鎖、別的行程搶先刪了）一律逐檔吞掉，**不能**讓檔案記錄降級。
//
// 四條硬條件（維護者指定，也是最容易做壞的地方）：
//
// ① **路徑要實際可寫，不能用假設的。**
//    app 是 sandboxed（`MacIMESpike.entitlements` 的 `com.apple.security.app-sandbox=true`）。
//    在 sandbox 裡 `FileManager.urls(for: .libraryDirectory, in: .userDomainMask)` 會**自動**
//    指向容器內的 `…/Containers/<bundleid>/Data/Library`，那是 app 自己的目錄、不需要任何
//    額外 entitlement。⇒ **不寫死路徑**，用這個 API 拿；並且第一筆記錄就把**實際解析到的路徑**
//    寫進 log，裝上去第一次就知道有沒有解對。
//    ⚠️ 即便如此，「真的寫得進去」仍然只有裝上去跑才算數——所以有 ②。
//
// ② **寫不進去不能讓輸入法壞掉。** 任何 I/O 失敗一律吞掉，並自動降級（之後的內容全丟，系統 log 只留一筆失敗註記）
//    🔴 2026-10-08 使用者決定：降級後**不再把整行內容寫進系統 log**（以前用 `privacy: .public` 寫，
//    那份不受「清除使用紀錄」與一週限制管，也不在 PRIVACY.md 寫的資料夾）。現在系統 log 只有一筆
//    「寫檔失敗、原因、時間」註記；代價是檔案那條完全失敗時沒有備援資料（`tools/dump_mac_ime_log.sh` 的系統 log 那條撈不到內容）。
//    🔴 **換檔失敗不算「寫不進去」**：搬不動就繼續寫現行檔、60 秒後重試、只報一次——降級是永久的，
//    不能因為一次改名失敗就讓之後整天的記錄都不進檔案。
//
// ③ **不得阻塞按鍵熱路徑**（專案硬規則：鍵盤熱路徑不做同步阻塞 I/O）。
//    `append` 只把字串丟進背景佇列，真正的 write 在那邊批次做。換檔檢查每次 flush 只比一次時間
//    （`now >= nextMidnight`），啟動遷移也在這個佇列上跑，`append` 一行都沒動。
//
// ④ **單日 64 MB 安全閥**（只切檔、不刪），不讓單一檔案大到打不開。
//
// 🔴 **記錄開關（2026-10-06 使用者決定：預設開、不彈同意窗；取代 10-03 的「彈窗問、預設關」）**：
// 記錄狀態（`MacIMELogConsent`）是「拒絕」就**一律不記**——`append`、啟動診斷、降級註記
// 都算記錄，都不做。從沒回答過與「同意」都記；已經按過「不要」的人永遠不會被預設開蓋掉。
// `isEnabled` 是「旗標 && 記錄狀態不是拒絕」，所以 `MacClientSession` 裡十幾處
// `guard isEnabled` 自動遵守，那支一行都不用動。flush 時會**再查一次**：使用者在設定頁關掉記錄時，
// 已經排進佇列、還沒寫出的行也不會被寫出去。
//
// 🔴 **密碼欄（隱私）**：`secureInputProbe`（`shared` 用系統的 `IsSecureEventInputEnabled()`）為真時，這一筆不記。
// 它是**全系統**狀態（某個 app 開著「安全鍵盤輸入」也會為真），所以不是靜默丟：進入／離開各留一筆
// `kind=secureInput` 註記（只有 state，沒有任何內容），事後看得出哪段被抑制。

import Carbon.HIToolbox
import Foundation
import os

final class MacIMEEventLogSink {
    /// 真正的單例：secure input 用系統的 `IsSecureEventInputEnabled()`（實測約 0.85 µs／次，每筆都查沒問題）。
    /// 建構子的預設探針是「永遠 false」——測試不能因為跑測試的終端機開著「安全鍵盤輸入」就莫名其妙紅掉。
    static let shared = MacIMEEventLogSink(secureInputProbe: { IsSecureEventInputEnabled() })

    /// 程式面的總開關（測試與劇本靠它關掉，預設開）。
    /// 🔴 對外讀到的 `isEnabled` 還要再加上「使用者沒有關掉記錄」——關掉就是沒開，不管這個旗標。
    private var enabledFlag = true
    private let enabledLock = NSLock()

    /// 只看程式面旗標（不含記錄狀態）：修剪過期檔用——關掉記錄的人，舊檔也要在一週後消失。
    private var programmaticFlag: Bool {
        enabledLock.lock()
        defer { enabledLock.unlock() }
        return enabledFlag
    }

    var isEnabled: Bool {
        get {
            enabledLock.lock()
            let flag = enabledFlag
            enabledLock.unlock()
            return flag && consent.isRecordingEnabled
        }
        set {
            enabledLock.lock()
            enabledFlag = newValue
            enabledLock.unlock()
        }
    }

    /// 測試用：同步留下每一筆已經序列化的行，不寫檔。
    /// 劇本要斷言 log 內容時開這個；`isEnabled` 仍維持 false，避免寫進使用者的 log 目錄。
    var mirrorToMemory = false
    private(set) var memoryMirror: [String] = []

    func clearMemoryMirror() {
        memoryMirror.removeAll(keepingCapacity: true)
    }

    private let sequence = MacIMELogSequence()
    /// `.utility` 而不是 `.userInitiated`：log 永遠不該跟按鍵處理搶 CPU。
    private let queue = DispatchQueue(label: "com.kota.xrich.twkeyboard.eventlog", qos: .utility)
    /// 系統 log 的出口。🔴 **只准寫「出事了」的註記（寫檔失敗、原因、時間），不准帶任何一行 log 內容**：
    /// 系統 log 不在「記錄資料夾」、不被「清除使用紀錄」刪、也不受一週限制（2026-10-08 使用者決定）。
    /// 測試注入收集用的閉包，斷言它收到的字串不含輸入內容。
    private let systemLog: (String) -> Void
    private static let systemLogger = Logger(subsystem: "com.kota.xrich.inputmethod.TWKeyboard", category: "eventlog")

    // 注入點（`shared` 用預設值＝使用者的 log 目錄、系統時鐘；測試傳暫存目錄與假時鐘）。
    private let directoryProvider: () -> URL?
    private let clock: () -> Date
    private let calendar: Calendar
    private let maxBytes: Int
    private let consent: MacIMELogConsent
    private let secureInputProbe: () -> Bool
    /// 上一筆 `append` 看到的 secure input 狀態：只在切換時留註記。`append` 可能在任何執行緒呼叫，所以上鎖。
    private var lastSecureInput = false
    private let secureLock = NSLock()

    private var pending: [String] = []
    private var flushScheduled = false
    private var handle: FileHandle?
    private var bytesWritten = 0
    /// 檔案那條走不通時降級：之後的 log 內容一律丟掉（不寫系統 log），只留一筆「寫檔失敗」註記，不要每鍵洗版。
    private var degraded = false
    private var reportedDegradeReason = false

    // 每日一檔的狀態（以下全部只在 `queue` 上讀寫）。
    private var startupMigrationDone = false
    /// 本行程是否已做過保留期限修剪（啟動那一次）。
    private var startupPruneDone = false
    /// 開檔當下現行檔的 inode：之後每次 flush 比對，不一樣就是別的輸入法行程換過檔。
    private var openedFileID: UInt64?
    /// 現行檔**內容**屬於哪一天／下一個午夜。每次（重新）開檔時推得；換檔失敗時 handle 不關，
    /// 這兩個值**保持不變**，重試才會用對的日期封存（失敗期間寫進去的今天的行也歸在昨天的日檔）。
    private var currentFileDay: String?
    private var nextMidnight: Date?
    private var rolloverRetryAfter: Date?
    private var reportedRolloverFailure = false
    private static let rolloverRetryInterval: TimeInterval = 60

    init(
        directoryProvider: @escaping () -> URL? = { MacIMEEventLogSink.logDirectoryURL() },
        clock: @escaping () -> Date = { Date() },
        calendar: Calendar = .autoupdatingCurrent,
        maxBytes: Int = MacIMELogRotation.defaultMaxBytes,
        consent: MacIMELogConsent = .shared,
        secureInputProbe: @escaping () -> Bool = { false },
        systemLog: ((String) -> Void)? = nil
    ) {
        self.directoryProvider = directoryProvider
        self.clock = clock
        self.calendar = calendar
        self.maxBytes = maxBytes
        self.consent = consent
        self.secureInputProbe = secureInputProbe
        self.systemLog = systemLog ?? { message in
            MacIMEEventLogSink.systemLogger.error("\(message, privacy: .public)")
        }
    }

    // MARK: - 對外

    func nextSequence() -> Int { sequence.next() }

    /// 熱路徑唯一的入口。**這裡不做 I/O**，只把已經組好的字串丟給背景佇列。
    func append(_ record: MacIMEEventRecord) {
        let line = record.serialized()
        if mirrorToMemory {
            memoryMirror.append(line)
        }
        guard isEnabled else { return }
        if suppressedBySecureInput() { return }
        queue.async { [weak self] in
            self?.enqueue(line)
        }
    }

    /// 密碼欄（secure input）開著 ⇒ 這一筆不記，回傳 `true`。切換時（進入／離開）各留一筆註記。
    /// 註記本身只有 state，沒有任何按鍵內容。
    private func suppressedBySecureInput() -> Bool {
        let secure = secureInputProbe()
        secureLock.lock()
        let changed = secure != lastSecureInput
        lastSecureInput = secure
        secureLock.unlock()
        if changed {
            let note = MacIMEEventRecord.note(
                seq: sequence.next(), timestamp: clock(), kind: "secureInput",
                detail: [("state", secure ? "suppressed" : "resumed")]
            ).serialized()
            queue.async { [weak self] in self?.enqueue(note) }
        }
        return secure
    }

    /// 啟動時記一筆，內容包含**實際解析到的 log 路徑**——這是「路徑有沒有解對」的唯一證據。
    /// （每個 controller 的 `init` 都會呼叫，所以一個行程內可能呼叫很多次；啟動遷移只做一次。）
    func logStartupDiagnostics() {
        // 關掉記錄的人沒有 flush，過期檔要在這裡修剪（開著的人在第一次 flush 修剪，順便留註記）。
        // 程式面旗標關著（測試與劇本）一個檔都不動。
        if programmaticFlag, !consent.isRecordingEnabled {
            queue.async { [weak self] in self?.pruneAtStartupIfNeeded() }
        }
        guard isEnabled else { return }
        let path = directoryProvider()?
            .appendingPathComponent(MacIMEDailyLog.currentFileName).path ?? "<解析不到 Library 目錄>"
        append(
            .note(
                seq: sequence.next(),
                timestamp: Date(),
                kind: "startup",
                detail: [
                    ("path", path),
                    ("sandboxHome", NSHomeDirectory()),
                    ("bundle", Bundle.main.bundleIdentifier ?? "?"),
                    ("consent", consent.provenance.rawValue),
                ]
            )
        )
        queue.async { [weak self] in self?.flushLocked() }
    }

    /// 偏好設定「清除使用紀錄」。在這條佇列上先丟掉還沒寫出的行、關掉現行檔，
    /// 再刪目錄裡 `MacIMEDailyLog.classify` 認得的 log。自訂詞與詞庫不在這個目錄的判斷裡。
    @discardableResult
    func clearAll() -> Bool {
        queue.sync {
            pending.removeAll()
            flushScheduled = false
            closeHandleAndForgetFileState()
            guard let directory = directoryProvider() else { return true }
            do {
                _ = try MacUsageLogCleaner.deleteClassifiedLogs(in: directory) { name in
                    MacIMEDailyLog.classify(name) != nil
                }
                return true
            } catch {
                return false
            }
        }
    }

    /// 測試用：把已丟進佇列的記錄同步寫完（佇列是序列的，所以排在前面的 `append` 一定先處理完）。
    func flushForTesting() {
        queue.sync { flushLocked() }
    }

    /// 測試用：是否已降級（寫檔失敗、之後的內容全丟）。
    var isDegradedForTesting: Bool {
        queue.sync { degraded }
    }

    // MARK: - 背景佇列（以下全部只在 `queue` 上跑）

    private func enqueue(_ line: String) {
        pending.append(line)
        // 批次：逐行 write 在快速連打時會變成每鍵一次 syscall。
        // 200ms 或累積 64 行就 flush，兩者取先到。
        if pending.count >= 64 {
            flushLocked()
            return
        }
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.flushScheduled = false
            self?.flushLocked()
        }
    }

    private func flushLocked() {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)

        // 🔴 記錄開關第二道：排進佇列之後、寫出之前使用者可能關掉了。關掉的當下起就不能再有任何一行落地
        //（檔案或系統 log 都不行）；這批直接丟掉，重新打開後也不補寫。
        guard consent.isRecordingEnabled else { return }

        // 降級之後內容一律丟掉：不寫系統 log（那裡不受「清除使用紀錄」與一週限制管）。
        if degraded { return }

        do {
            guard let directory = directoryProvider() else {
                throw NSError(
                    domain: "TWKeyboardEventLog", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "無法解析 Library 目錄"])
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let now = clock()

            // 這次要寫的行：換檔／遷移的註記排在最前面（新檔的第一行就是「我是怎麼來的」）。
            var lines: [String] = []
            if !startupMigrationDone {
                startupMigrationDone = true
                lines.append(contentsOf: migrateOnStartup(in: directory, now: now))
                lines.append(contentsOf: pruneAtStartupIfNeeded(in: directory, now: now))
            }
            _ = try openedHandle(in: directory, now: now)
            let incoming = batch.reduce(0) { $0 + $1.utf8.count + 1 }
            lines.append(contentsOf: rolloverIfNeeded(in: directory, now: now, incoming: incoming))

            let target = try openedHandle(in: directory, now: now)
            let payload = (lines + batch).joined(separator: "\n") + "\n"
            guard let data = payload.data(using: .utf8) else { return }
            try target.seekToEnd()
            try target.write(contentsOf: data)
            bytesWritten += data.count
        } catch {
            // ② 寫檔失敗一律吞掉、降級，**絕不讓 log 把輸入法弄壞**。
            degradeAndDropContent(reason: "\(error)")
        }
    }

    /// 回傳現行檔的 handle；沒開就開，開著但現行檔已被別的行程換過（inode 不同或檔案不見）就重開。
    private func openedHandle(in directory: URL, now: Date) throws -> FileHandle {
        let url = directory.appendingPathComponent(MacIMEDailyLog.currentFileName)
        if let handle {
            if let openedFileID, MacIMEDailyLogFiles.fileID(of: url) == openedFileID { return handle }
            closeHandleAndForgetFileState()
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let opened = try FileHandle(forWritingTo: url)
        handle = opened
        openedFileID = MacIMEDailyLogFiles.fileID(of: url)
        let stat = MacIMEDailyLogFiles.stat(of: url)
        bytesWritten = stat?.size ?? 0
        // 現行檔有內容就以它最後寫入的那天為準（正常情況＝今天；上次換檔失敗留下的＝昨天，
        // 這時 nextMidnight 已經過了，下面 `rolloverIfNeeded` 會立刻再試一次改名）。
        // 只有「重新開檔」才會走到這裡；換檔搬不動時 handle 留著沒關，所以記住的日期不會被 mtime 蓋掉。
        let basis = (stat?.size ?? 0) > 0 ? min(stat?.modified ?? now, now) : now
        currentFileDay = MacIMEDailyLog.dayKey(for: basis, calendar: calendar)
        nextMidnight = MacIMEDailyLog.nextMidnight(after: basis, calendar: calendar)
        return opened
    }

    private func closeHandleAndForgetFileState() {
        try? handle?.close()
        handle = nil
        bytesWritten = 0
        openedFileID = nil
        currentFileDay = nil
        nextMidnight = nil
    }

    /// 啟動遷移：舊制 `.N` → 日檔、過期的現行檔 → 它那天的日檔。回傳要寫進 log 的註記行。
    /// 🔴 一律回傳一筆 `kind=logRoll reason=startup`（即使一個都沒搬）——裝機後 `grep logRoll`
    /// 就能確定「新 build 真的在跑」，而不是看到舊 build 留下的檔案就以為好了。
    private func migrateOnStartup(in directory: URL, now: Date) -> [String] {
        let outcome = MacIMEDailyLogFiles.migrateOnStartup(in: directory, now: now, calendar: calendar)
        if let failure = outcome.failed.first {
            reportRolloverFailureOnce("啟動遷移搬不動 \(failure.move.source)：\(failure.message)")
        }
        var detail: [(String, String)] = [
            ("reason", "startup"),
            ("moved", String(outcome.moved.count)),
            ("failed", String(outcome.failed.count)),
        ]
        if !outcome.moved.isEmpty {
            detail.append(("moves", outcome.moved.map { "\($0.source)>\($0.target)" }.joined(separator: ";")))
        }
        return [logRollNote(now: now, detail: detail)]
    }

    /// 每個行程最多一次：修剪過期日檔。`queue` 上呼叫。回傳要寫進 log 的註記行（沒刪也沒失敗＝空）。
    @discardableResult
    private func pruneAtStartupIfNeeded(in directory: URL? = nil, now: Date? = nil) -> [String] {
        guard !startupPruneDone else { return [] }
        startupPruneDone = true
        guard let directory = directory ?? directoryProvider() else { return [] }
        return pruneExpiredLogs(in: directory, now: now ?? clock(), reason: "startup")
    }

    /// 刪掉內容整個超過 `MacIMEDailyLog.retentionDays` 天的日檔。
    /// 🔴 逐檔容錯、整體不丟錯：修剪失敗不能影響寫檔，也不能讓 sink 降級。
    /// 目錄不存在就什麼都不做（不建目錄）。回傳註記行（刪了或刪不掉才有）。
    private func pruneExpiredLogs(in directory: URL, now: Date, reason: String) -> [String] {
        let listing = MacIMEDailyLogFiles.listing(in: directory)
        let expired = MacIMEDailyLog.expiredLogNames(listing: listing, now: now, calendar: calendar)
        guard !expired.isEmpty else { return [] }
        let result = MacUsageLogCleaner.deleteFiles(named: expired, in: directory)
        if !result.failed.isEmpty {
            systemLog("[TWKeyboard] 事件 log 過期檔刪不掉 \(result.failed.count) 個，下次再試")
        }
        guard programmaticFlag, consent.isRecordingEnabled else { return [] }   // 沒在記錄就不留註記
        return [logRollNote(now: now, detail: [
            ("reason", reason), ("removed", String(result.deleted.count)), ("failed", String(result.failed.count)),
        ], kind: "logPrune")]
    }

    /// 這批寫入之前要不要換檔（跨日／單日超量）；要的話改名並回傳註記行。
    private func rolloverIfNeeded(in directory: URL, now: Date, incoming: Int) -> [String] {
        guard let fileDay = currentFileDay, let midnight = nextMidnight else { return [] }
        if let retryAfter = rolloverRetryAfter, now < retryAfter { return [] }
        guard let reason = MacIMEDailyLog.rolloverReason(
            now: now, nextMidnight: midnight, currentBytes: bytesWritten, incoming: incoming, maxBytes: maxBytes)
        else { return [] }

        let outcome = MacIMEDailyLogFiles.rollover(
            reason: reason, fileDay: fileDay, expectedFileID: openedFileID, in: directory)
        let reasonName = reason == .dayChanged ? "dayChanged" : "sizeSplit"

        if let failure = outcome.failed.first {
            // 搬不動：來源原封不動，**繼續寫現行檔**、退避後重試；狀態（內容屬於哪天）保持不變。
            rolloverRetryAfter = now.addingTimeInterval(Self.rolloverRetryInterval)
            reportRolloverFailureOnce("換檔搬不動 \(failure.move.source) → \(failure.move.target)：\(failure.message)")
            return []
        }
        // 成功、別的行程已經換過、或空檔不用搬：舊 handle 都不能再用，狀態重推。
        closeHandleAndForgetFileState()
        rolloverRetryAfter = nil
        reportedRolloverFailure = false
        if let move = outcome.moved.first {
            var notes = [logRollNote(now: now, detail: [
                ("reason", reasonName), ("from", move.source), ("to", move.target),
            ])]
            // 跨日：昨天的檔剛封存、有檔剛好變成「超過 7 天」。單日超量切檔不會改變誰過期，不必重做。
            if reason == .dayChanged { notes.append(contentsOf: pruneExpiredLogs(in: directory, now: now, reason: "dayChanged")) }
            return notes
        }
        if outcome.skippedBecauseReplaced {
            return [logRollNote(now: now, detail: [("reason", reasonName), ("result", "replacedByOtherProcess")])]
        }
        return []
    }

    private func logRollNote(now: Date, detail: [(String, String)], kind: String = "logRoll") -> String {
        MacIMEEventRecord.note(seq: sequence.next(), timestamp: now, kind: kind, detail: detail).serialized()
    }

    private func reportRolloverFailureOnce(_ message: String) {
        guard !reportedRolloverFailure else { return }
        reportedRolloverFailure = true
        systemLog("[TWKeyboard] 事件 log 換檔失敗，繼續寫現行檔、稍後重試：\(message)")
    }

    /// 寫檔失敗：永久降級（本行程之後不再寫檔，內容全丟），系統 log **只留這一筆**註記——失敗、原因、時間，沒有內容。
    private func degradeAndDropContent(reason: String) {
        degraded = true
        closeHandleAndForgetFileState()
        guard !reportedDegradeReason else { return }
        reportedDegradeReason = true
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        systemLog("[TWKeyboard] 事件 log 寫檔失敗，本次執行不再記錄（內容已丟棄，不寫入系統 log）。時間 \(formatter.string(from: clock()))；原因：\(reason)")
    }

    // MARK: - 路徑

    /// 🔴 **不寫死路徑。** sandbox 會把 `.libraryDirectory` 自動重導向到容器內
    /// （`~/Library/Containers/<bundleid>/Data/Library`），那是 app 自己的目錄；
    /// 萬一哪天 sandbox 設定變了，這個 API 仍然會給出「當下真正該寫的地方」，
    /// 而寫死的字串不會。實際解析到什麼由 `logStartupDiagnostics()` 記進 log 第一筆。
    static func logDirectoryURL() -> URL? {
        guard let library = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask).first
        else { return nil }
        return library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("TWKeyboard", isDirectory: true)
    }

    /// 現行檔（`typing_events.log`）的完整路徑。
    static func logFileURL() -> URL? {
        logDirectoryURL()?.appendingPathComponent(MacIMEDailyLog.currentFileName)
    }
}

extension MacIMELogConsent {
    /// 行程唯一的實例：存 App 自己的 `UserDefaults.standard`，舊 log 偵測看真正的 log 目錄。
    /// （放在這裡而不是 `EventLog/`：那個目錄必須能單獨編譯，不能引用 sink。）
    static let shared = MacIMELogConsent(
        defaults: .standard,
        legacyLogExists: { MacIMELogConsent.legacyLogExists(in: MacIMEEventLogSink.logDirectoryURL()) }
    )
}
