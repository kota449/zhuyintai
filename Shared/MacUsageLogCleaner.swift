// SPDX-License-Identifier: Apache-2.0
import Foundation

/// 只刪「呼叫端認定是使用紀錄」的檔。自訂詞、`user_phrases.txt`、詞庫都不在這支的判斷裡：
/// 那些檔名不會被 `MacIMEDailyLog.classify` 認成 log，呼叫端傳進來的閉包就不會選中它們。
enum MacUsageLogCleaner {
    static func deleteClassifiedLogs(
        in directory: URL,
        fileManager: FileManager = .default,
        isLogFile: (String) -> Bool
    ) throws -> [String] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }
        let names = try fileManager.contentsOfDirectory(atPath: directory.path)
        var deleted: [String] = []
        for name in names.sorted() where isLogFile(name) {
            try fileManager.removeItem(at: directory.appendingPathComponent(name))
            deleted.append(name)
        }
        return deleted
    }

    /// 逐檔刪指定的檔名；單一檔刪不掉（別的行程搶先刪了、被鎖住）不影響其他檔。
    static func deleteFiles(
        named names: [String],
        in directory: URL,
        fileManager: FileManager = .default
    ) -> (deleted: [String], failed: [String]) {
        var deleted: [String] = []
        var failed: [String] = []
        for name in names {
            // 只收「目錄裡的檔名」：帶路徑分隔符的一律不刪，免得呼叫端的錯誤名單跑出這個目錄。
            guard !name.isEmpty, !name.contains("/") else { failed.append(name); continue }
            do {
                try fileManager.removeItem(at: directory.appendingPathComponent(name))
                deleted.append(name)
            } catch {
                failed.append(name)
            }
        }
        return (deleted, failed)
    }
}
