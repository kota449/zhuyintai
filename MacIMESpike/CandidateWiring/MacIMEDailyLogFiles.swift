// SPDX-License-Identifier: Apache-2.0
// 打字事件 log「每天一個檔」的**搬檔層**：把 `MacIMEDailyLog`（純邏輯）算出來的改名計畫真的執行。
//
// 🔴 **這個檔案從頭到尾沒有任何刪除呼叫，只有改名（`moveItem`）。**
// 使用者的要求是「每一天都是新的 log，這樣子就不會被刪掉了」（2026-10-01）——舊制的刪除式輪替
// 正是資料消失的原因。（2026-10-06 另決定只留約一週：過期修剪的刪檔不在這一層，在 `Shared/MacUsageLogCleaner.swift`。）`tools/test_mac_ime_event_log.sh` 開頭用 grep 守住這一點（註解行不算）。
// `moveItem` 在目標已存在時會**丟錯而不是覆蓋**——撞名時寧可搬不成（來源原封不動、下次再試），
// 也不會蓋掉任何一個既有檔案。
//
// 只用 Foundation（不 import AppKit／InputMethodKit／os），而且**目錄由呼叫端傳進來**：
// 測試在暫存目錄裡真的搬檔（`MacIMEEventLogCLIProbe`），不需要沙盒容器、不碰使用者的 log 目錄。
//
// 呼叫端（`MacIMEEventLogSink`）一律在自己的背景佇列上呼叫，這裡不碰任何執行緒。

import Foundation

enum MacIMEDailyLogFiles {
    struct Failure {
        let move: MacIMEDailyLog.Move
        let message: String
    }

    struct Outcome {
        /// 成功搬完的改名（依執行順序）。
        var moved: [MacIMEDailyLog.Move] = []
        /// 搬不動的改名：**來源檔案原封不動**，呼叫端應繼續寫現行檔、稍後重試。
        var failed: [Failure] = []
        /// 現行檔已經不是呼叫端開著的那一個（別的輸入法行程已經換過檔）⇒ 沒有搬，
        /// 呼叫端必須關掉舊 handle 重開，否則會一直寫進已經被封存的舊檔。
        var skippedBecauseReplaced = false
    }

    // MARK: - 讀

    /// 目錄裡**屬於我們的** log 檔（`MacIMEDailyLog.classify` 認得的名字）與其大小、mtime。
    /// 目錄不存在 ⇒ 空。
    static func listing(in directory: URL) -> [String: MacIMEDailyLog.FileStat] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [:] }
        var result: [String: MacIMEDailyLog.FileStat] = [:]
        for name in names where MacIMEDailyLog.classify(name) != nil {
            if let stat = stat(of: directory.appendingPathComponent(name)) { result[name] = stat }
        }
        return result
    }

    /// 單一檔案的大小與 mtime；檔案不存在或讀不到 ⇒ `nil`。
    static func stat(of url: URL) -> MacIMEDailyLog.FileStat? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              let modified = attrs[.modificationDate] as? Date
        else { return nil }
        return MacIMEDailyLog.FileStat(size: size, modified: modified)
    }

    /// 檔案的 inode 號（`systemFileNumber`）。改名後再建同名新檔，路徑相同但 inode 不同——
    /// 用它分辨「我開著的是不是還是現行檔」。檔案不存在 ⇒ `nil`。
    static func fileID(of url: URL) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    // MARK: - 寫（只有改名）

    /// 依序執行改名。每一個獨立成敗：前面失敗不影響後面（後面的目標名稱在計畫階段就已經避開撞名）。
    static func execute(_ moves: [MacIMEDailyLog.Move], in directory: URL) -> Outcome {
        var outcome = Outcome()
        for move in moves {
            do {
                try FileManager.default.moveItem(
                    at: directory.appendingPathComponent(move.source),
                    to: directory.appendingPathComponent(move.target))
                outcome.moved.append(move)
            } catch {
                outcome.failed.append(Failure(move: move, message: "\(error)"))
            }
        }
        return outcome
    }

    /// 啟動遷移：舊制 `.N` → 日檔、過期的現行檔 → 它那天的日檔（見 `MacIMEDailyLog.startupPlan`）。
    static func migrateOnStartup(in directory: URL, now: Date, calendar: Calendar) -> Outcome {
        let plan = MacIMEDailyLog.startupPlan(listing: listing(in: directory), now: now, calendar: calendar)
        return execute(plan, in: directory)
    }

    /// 換檔（跨日或單日超量）：把現行檔搬成封存檔。
    ///
    /// 🔴 **搬之前重新看一眼現行檔**——兩個輸入法行程可能同時存在（重裝時新舊並存，mem0 `78792eb8`
    /// 已經撞過一次交錯寫入）。若現行檔的 inode 不是 `expectedFileID`（呼叫端開著的那個），代表別的
    /// 行程已經換過檔、現在的現行檔是它剛建的新檔：再搬一次只會把今天的內容封存成昨天的日檔。
    /// - Parameter fileDay: 現行檔**內容**屬於哪一天（呼叫端記的，不是「現在是哪天」）。
    static func rollover(
        reason: MacIMEDailyLog.RolloverReason,
        fileDay: String,
        expectedFileID: UInt64?,
        in directory: URL
    ) -> Outcome {
        var outcome = Outcome()
        let currentURL = directory.appendingPathComponent(MacIMEDailyLog.currentFileName)
        guard let id = fileID(of: currentURL) else {
            outcome.skippedBecauseReplaced = true
            return outcome
        }
        if let expectedFileID, expectedFileID != id {
            outcome.skippedBecauseReplaced = true
            return outcome
        }
        let files = listing(in: directory)
        guard let current = files[MacIMEDailyLog.currentFileName],
              let move = MacIMEDailyLog.rolloverMove(
                  reason: reason, fileDay: fileDay, currentBytes: current.size, existing: Set(files.keys))
        else { return outcome }
        return execute([move], in: directory)
    }
}
