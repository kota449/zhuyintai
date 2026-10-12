// SPDX-License-Identifier: Apache-2.0
// 「匯出 log」：把目錄裡我們的所有 log 檔，依時間順序串成**一份純文字檔**，給試用者自己傳給開發者。
// 只用 Foundation，純 swiftc 測得到。
//
// 🔴 **全程唯讀**：來源檔只開來讀，不改名、不截斷、不刪（連 `removeItem` 都沒有——
// `tools/test_mac_ime_event_log.sh` 的「換檔不刪」守門也看得到這支）。
// 🔴 **不上傳**：這裡只寫使用者在存檔面板選的路徑，沒有任何網路呼叫。
//
// 為什麼不是 zip：沙盒 app 不能呼叫 `zip`，而且 log 是純文字，串成一份 txt 最容易被
// 對方直接開。每段前有檔頭（`===== 檔名 (N bytes) =====`），要拆回去也看得出界線。
//
// 順序＝時間順序：舊制 `.N`（N 越大越舊）→ 日檔（日期、同日序號遞增）→ 現行檔。
// 每個來源檔只讀到**開始匯出那一刻**的大小，現行檔匯出途中還在長也不會追著讀。

import Foundation

enum MacIMELogExport {
    enum ExportError: Error, Equatable {
        /// 目錄裡沒有任何我們的 log 檔（還沒同意過、或剛裝好）。
        case noLogFiles
    }

    struct Summary: Equatable {
        /// 實際匯出的檔案（依輸出順序）。
        let fileNames: [String]
        /// 列目錄之後、開檔之前就不見的檔案（午夜封存改名、被人搬走）：跳過並在輸出裡留一行註記。
        let skippedNames: [String]
        /// 實際複製的位元組數（不含檔頭與註記）。
        let byteCount: Int
    }

    private static let chunkSize = 1 << 20

    /// - Parameters:
    ///   - directory: log 目錄（只讀）。
    ///   - destination: 目的檔（存在就整個覆蓋）。
    ///   - preamble: 放在最前面的一段（版本與 macOS build，讓對方知道這是哪個 build 的 log）。
    /// - Parameter afterListing: 測試用的縫：列完目錄、開檔之前呼叫，模擬那個空窗期發生的改名／搬走。
    static func export(
        from directory: URL, to destination: URL, preamble: String, afterListing: (() -> Void)? = nil
    ) throws -> Summary {
        let sources = try sourceFiles(in: directory)
        guard !sources.isEmpty else { throw ExportError.noLogFiles }
        afterListing?()

        // 直接寫目的檔（`createFile` 會把既有檔清成空的）：使用者在存檔面板已經確認過要覆蓋，
        // 而且不另開暫存檔，這支就連「刪暫存檔」都不需要，維持整層沒有任何刪除呼叫。
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var total = 0
        var exported: [String] = []
        var skipped: [String] = []
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        try out.write(contentsOf: Data((preamble + "\n").utf8))
        for source in sources {
            // 🔴 列目錄到開檔之間可能遇到午夜封存（改名）：來源不見就跳過並註記，**不中止**
            // （中止會留下被截斷的目的檔）。開檔成功之後再被改名不影響：已開的 handle 照樣讀得到完整內容。
            guard let input = try? FileHandle(forReadingFrom: source.url) else {
                skipped.append(source.name)
                try out.write(contentsOf: Data("略過 \(source.name)（已不存在）\n".utf8))
                continue
            }
            defer { try? input.close() }
            // 檔頭的 bytes 用**開檔當下**實際讀到的大小（不是更早之前列目錄時的），
            // 之後只複製到這個大小，現行檔匯出途中還在長也不會追著讀。
            let size = Int(try input.seekToEnd())
            try input.seek(toOffset: 0)
            try out.write(contentsOf: Data("===== \(source.name) (\(size) bytes) =====\n".utf8))
            let copied = try copy(input, upTo: size, to: out)
            total += copied
            exported.append(source.name)
            if copied != size {
                try out.write(contentsOf: Data("（實際只複製 \(copied) bytes：來源在匯出途中變小）\n".utf8))
            }
        }
        try out.synchronize()
        guard !exported.isEmpty else { throw ExportError.noLogFiles }
        return Summary(fileNames: exported, skippedNames: skipped, byteCount: total)
    }

    // MARK: - 內部

    private struct Source {
        let name: String
        let url: URL
    }

    private static func sourceFiles(in directory: URL) throws -> [Source] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let classified: [(kind: MacIMEDailyLog.FileKind, name: String)] = names.compactMap { name in
            MacIMEDailyLog.classify(name).map { ($0, name) }
        }
        func rank(_ kind: MacIMEDailyLog.FileKind) -> (Int, String, Int) {
            switch kind {
            case .legacy(let generation): return (0, "", -generation)     // 世代大＝較舊 ⇒ 排前面
            case .archive(let day, let index): return (1, day, index)
            case .current: return (2, "", 0)
            }
        }
        return classified
            .sorted { rank($0.kind) < rank($1.kind) }
            .map { Source(name: $0.name, url: directory.appendingPathComponent($0.name)) }
    }

    /// 分段複製，大檔（單日上限 64 MB）不會整份載進記憶體。回傳實際複製的位元組數。
    private static func copy(_ input: FileHandle, upTo size: Int, to out: FileHandle) throws -> Int {
        var remaining = size
        var copied = 0
        while remaining > 0 {
            guard let chunk = try input.read(upToCount: min(chunkSize, remaining)), !chunk.isEmpty else { break }
            try out.write(contentsOf: chunk)
            remaining -= chunk.count
            copied += chunk.count
        }
        return copied
    }
}
