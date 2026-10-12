// SPDX-License-Identifier: Apache-2.0
// 打字事件 log「每天一個檔、只留 7 天」的**純邏輯層**：檔名、讀取順序、什麼時候該換檔、
// 啟動時要搬哪些舊檔、哪些檔已過期。
//
// 由來（2026-10-01 使用者原話）：「log 你就要把它做成就是每一天都是新的 log，這樣子就不會被刪掉了」。
// 舊制是「單檔 4MB ＋ 1 份 `.1`」，滿了就**刪掉**舊的 `.1` 再輪替——實機約一天就蓋掉一輪，
// 昨天的打字紀錄（驗證器、重播工具的原料）隔天就消失。
// 2026-10-06 使用者另外決定「只留約一週」：換檔仍只改名，過期修剪是另一條路（`expiredLogNames` 選名單、
// `MacUsageLogCleaner.deleteFiles` 刪）；這個檔仍不做任何 I/O。
//
// 🔴 **不得 import AppKit／InputMethodKit，也不做任何 I/O。** 同 `MacIMEEventLog.swift`：
// 這層用純 swiftc 測（`tools/test_mac_ime_event_log.sh`）。實際搬檔在
// `MacIMESpike/CandidateWiring/MacIMEDailyLogFiles.swift`，那一層**從頭到尾沒有任何刪除呼叫**——
// 這個性質由 `tools/test_mac_ime_event_log.sh` 的 grep 檢查守住。
//
// 檔名（目錄 `…/Logs/TWKeyboard/`）：
//   typing_events.log            現行檔（正在寫的那一個）
//   typing_events-D.log          D 那天封存的日檔（D ＝ `YYYY-MM-DD`，本地時區）
//   typing_events-D.N.log        D 那天內再切出來的檔（N 從 1 起；單日寫滿上限、或該天已有檔時日終封存接續編號）
//   typing_events.log.N          **舊制**輪替檔（N 大者較舊）——只在升級後第一次啟動時搬成日檔
//
// 讀取順序＝時間順序：舊制 `.N`（N 大者較舊）→ 日檔（日期、序號數字升冪）→ 現行檔。
// ⚠️ Python 側的對應實作在 `tools/mac_ime_log_files.py`，兩邊的命名與排序規則必須一致
// （兩邊的測試用同一份檔名清單與預期順序）。

import Foundation

public enum MacIMEDailyLog {
    public static let baseName = "typing_events"
    public static let currentFileName = "typing_events.log"

    // MARK: 型別

    /// 一個檔案的狀態（由 I/O 層從檔案系統取得，這層不碰檔案系統）。
    public struct FileStat: Equatable {
        public let size: Int
        public let modified: Date

        public init(size: Int, modified: Date) {
            self.size = size
            self.modified = modified
        }
    }

    public enum MoveReason: Equatable {
        /// 升級後第一次啟動：舊制 `.N` 改名成日檔。
        case migrateLegacy
        /// 跨日（或啟動時發現現行檔是前一天的）：現行檔封存成它那天的日檔。
        case dayChanged
        /// 同一天內寫滿上限：切成 `D.N.log`。
        case sizeSplit
    }

    /// 一次改名。`source`／`target` 都是**檔名**（不含目錄）。
    public struct Move: Equatable {
        public let source: String
        public let target: String
        public let reason: MoveReason

        public init(source: String, target: String, reason: MoveReason) {
            self.source = source
            self.target = target
            self.reason = reason
        }
    }

    public enum RolloverReason: Equatable {
        case dayChanged
        case sizeExceeded
    }

    public enum FileKind: Equatable {
        case current
        case legacy(generation: Int)
        case archive(day: String, index: Int)
    }

    // MARK: 日期

    /// `YYYY-MM-DD`（用傳進來的日曆＝本地時區）。
    public static func dayKey(for date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `date` 所在那天的**下一個**午夜（恰好午夜時回傳再隔一天，不是自己）。
    public static func nextMidnight(after date: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(86_400)
    }

    // MARK: 檔名

    public static func archiveFileName(day: String, index: Int) -> String {
        index <= 0 ? "\(baseName)-\(day).log" : "\(baseName)-\(day).\(index).log"
    }

    /// 認得出是我們的 log 檔才回傳；其餘（`.bak`、`.0`、`.DS_Store`、別人的檔案）一律 `nil`
    /// ——**不是我們的檔案就不搬、不讀**。序號只收正整數、不接受前導零（同一個檔只有一種寫法）。
    public static func classify(_ name: String) -> FileKind? {
        if name == currentFileName { return .current }

        let legacyPrefix = "\(currentFileName)."
        if name.hasPrefix(legacyPrefix) {
            guard let generation = positiveInt(String(name.dropFirst(legacyPrefix.count))) else { return nil }
            return .legacy(generation: generation)
        }

        let archivePrefix = "\(baseName)-"
        let suffix = ".log"
        guard name.hasPrefix(archivePrefix), name.hasSuffix(suffix),
              name.count > archivePrefix.count + suffix.count
        else { return nil }
        let middle = String(name.dropFirst(archivePrefix.count).dropLast(suffix.count))  // D 或 D.N
        let parts = middle.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 1 || parts.count == 2, isDay(parts[0]) else { return nil }
        if parts.count == 1 { return .archive(day: parts[0], index: 0) }
        guard let index = positiveInt(parts[1]) else { return nil }
        return .archive(day: parts[0], index: index)
    }

    private static func positiveInt(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0 >= "0" && $0 <= "9" }), text.first != "0" else { return nil }
        return Int(text)
    }

    private static func isDay(_ text: String) -> Bool {
        let pieces = text.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              pieces.allSatisfy({ $0.allSatisfy { $0 >= "0" && $0 <= "9" } }),
              let month = Int(pieces[1]), let day = Int(pieces[2]),
              (1 ... 12).contains(month), (1 ... 31).contains(day)
        else { return false }
        return true
    }

    /// 這一天要封存時用哪個檔名。**絕不回傳已存在的名字**，而且**一律排在這天既有檔案之後**
    /// （取「最大序號 ＋ 1」，不是找第一個空位）——讀取順序靠序號，空位會讓時序倒掉。
    /// - Parameter forceIndexed: 單日超量切檔一律帶序號（從 `.1` 起）；日終封存沒有既有檔時才用不帶序號的 `D.log`。
    public static func nextArchiveFileName(day: String, existing: Set<String>, forceIndexed: Bool) -> String {
        var used: [Int] = []
        for name in existing {
            if case let .archive(d, index)? = classify(name), d == day { used.append(index) }
        }
        guard let highest = used.max() else {
            return archiveFileName(day: day, index: forceIndexed ? 1 : 0)
        }
        return archiveFileName(day: day, index: highest + 1)
    }

    /// 讀取順序＝時間順序；不是我們的檔案一律不收。
    public static func chronologicalOrder(_ names: [String]) -> [String] {
        func key(_ kind: FileKind) -> (Int, String, Int) {
            switch kind {
            case let .legacy(generation): return (0, "", -generation)   // N 大者較舊 ⇒ 排前面
            case let .archive(day, index): return (1, day, index)
            case .current: return (2, "", 0)
            }
        }
        return names
            .compactMap { name in classify(name).map { (name, key($0)) } }
            .sorted { lhs, rhs in
                if lhs.1.0 != rhs.1.0 { return lhs.1.0 < rhs.1.0 }
                if lhs.1.1 != rhs.1.1 { return lhs.1.1 < rhs.1.1 }
                return lhs.1.2 < rhs.1.2
            }
            .map(\.0)
    }

    // MARK: 保留期限（2026-10-06 使用者決定：只留約一週）

    /// 打字事件 log 保留幾天。
    public static let retentionDays = 7

    /// 該刪的檔名（純計算，不做任何 I/O；實際刪檔在 `Shared/MacUsageLogCleaner.swift`）。
    ///
    /// 規則：**整個檔的內容都超過 `retentionDays` 天**才刪。日檔 `D` 的最後一筆最晚在 `D` 當天 24:00，
    /// 所以「今天的 0 點 − D 日 24:00 > 7 天」＝ 日差 ≥ 8 才刪；日差 7 天（含）以內留著。
    /// - 日檔（`typing_events-D.log`／`D.N.log`）：看**檔名裡的日期**（內容屬於哪天），不看 mtime。
    /// - 舊制 `.N`：還沒被啟動遷移改名成日檔時，看 mtime 當作內容的最後一天。
    /// - 現行檔 `typing_events.log` 永遠不刪（它是正在寫的那個；過期的現行檔先由遷移／換檔封存成日檔）。
    /// - `classify` 不認得的名字（選字記憶、自訂詞、別人的檔案）在這裡一律選不到。
    /// 日差用日曆算（跨月、DST 都正確），不是字串或秒數比較。
    public static func expiredLogNames(
        listing: [String: FileStat], now: Date, calendar: Calendar, retentionDays: Int = MacIMEDailyLog.retentionDays
    ) -> [String] {
        let today = calendar.startOfDay(for: now)
        func ageInDays(fromDay day: Date) -> Int? {
            calendar.dateComponents([.day], from: calendar.startOfDay(for: day), to: today).day
        }
        var expired: [String] = []
        for (name, stat) in listing {
            let contentDay: Date?
            switch classify(name) {
            case let .archive(day, _)?: contentDay = date(fromDayKey: day, calendar: calendar)
            case .legacy?: contentDay = min(stat.modified, now)
            case .current?, nil: contentDay = nil
            }
            guard let contentDay, let age = ageInDays(fromDay: contentDay), age > retentionDays else { continue }
            expired.append(name)
        }
        return expired.sorted()
    }

    /// `YYYY-MM-DD`（`classify` 已驗過格式）→ 那天 0 點。
    private static func date(fromDayKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    // MARK: 換檔決策

    /// 寫入這批之前要不要先換檔。跨日優先於超量；呼叫端每次 flush 只需做這一個比較。
    /// 空檔案跨日也回報 `.dayChanged`（呼叫端要藉此更新「今天」的狀態），只是之後不會有搬檔動作。
    public static func rolloverReason(
        now: Date, nextMidnight: Date, currentBytes: Int, incoming: Int, maxBytes: Int
    ) -> RolloverReason? {
        if now >= nextMidnight { return .dayChanged }
        if MacIMELogRotation.shouldRotate(currentBytes: currentBytes, incoming: incoming, maxBytes: maxBytes) {
            return .sizeExceeded
        }
        return nil
    }

    /// 換檔要做的那一次改名。空檔不搬（搬了只會產生一個空的日檔）。
    /// - Parameter fileDay: 現行檔**內容**屬於哪一天（不是「現在是哪天」）。
    public static func rolloverMove(
        reason: RolloverReason, fileDay: String, currentBytes: Int, existing: Set<String>
    ) -> Move? {
        guard currentBytes > 0 else { return nil }
        switch reason {
        case .dayChanged:
            return Move(
                source: currentFileName,
                target: nextArchiveFileName(day: fileDay, existing: existing, forceIndexed: false),
                reason: .dayChanged)
        case .sizeExceeded:
            return Move(
                source: currentFileName,
                target: nextArchiveFileName(day: fileDay, existing: existing, forceIndexed: true),
                reason: .sizeSplit)
        }
    }

    // MARK: 啟動遷移

    /// 啟動時要做的所有改名，**依序執行**（後面的改名假設前面的已完成）。
    ///
    /// ① 舊制 `.N` 由舊到新（N 大者較舊）改名成日檔，日期取 mtime（最後一次寫入＝內容結束的那天）；
    /// ② 再把「過期的現行檔」（mtime 不是今天）封存成它那天的日檔。
    /// 先 ① 後 ② 是為了讓同一天的舊內容拿到較小的序號（`D.log` 先於 `D.1.log`），讀取時才是先舊後新。
    /// mtime 在未來（時鐘被調過）視為今天；空檔不搬；不是我們的檔案不碰。
    ///
    /// ⚠️ 升級前的現行檔若跨過午夜（舊 build 不會換檔），它會整份算成 mtime 那天——
    /// 一次性的誤差，內容不會遺失。
    public static func startupPlan(
        listing: [String: FileStat], now: Date, calendar: Calendar
    ) -> [Move] {
        var taken = Set(listing.keys)
        var plan: [Move] = []
        let today = dayKey(for: now, calendar: calendar)

        func dayOf(_ stat: FileStat) -> String { dayKey(for: min(stat.modified, now), calendar: calendar) }

        let legacy: [(name: String, generation: Int)] = listing.keys.compactMap { name in
            if case let .legacy(generation)? = classify(name) { return (name, generation) }
            return nil
        }.sorted { $0.generation > $1.generation }

        for item in legacy {
            guard let stat = listing[item.name], stat.size > 0 else { continue }
            let target = nextArchiveFileName(day: dayOf(stat), existing: taken, forceIndexed: false)
            taken.insert(target)
            plan.append(Move(source: item.name, target: target, reason: .migrateLegacy))
        }

        if let current = listing[currentFileName], current.size > 0, dayOf(current) != today {
            let target = nextArchiveFileName(day: dayOf(current), existing: taken, forceIndexed: false)
            plan.append(Move(source: currentFileName, target: target, reason: .dayChanged))
        }
        return plan
    }
}
