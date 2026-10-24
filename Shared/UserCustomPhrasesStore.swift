// SPDX-License-Identifier: Apache-2.0
import Foundation

/// 偏好設定視窗裡「使用者自己加的詞」。
///
/// 只讀寫 `customFilename`（必須與引擎側載入的檔名一致）。`user_phrases.txt`（領域補詞、出貨詞）
/// 不在這裡打開寫入，也不算進上限。引擎只有一個槽（`loadUserPhrasesData` 先 clear），
/// 合併發生在引擎載入端，用暫存檔，不改既有行。
///
/// ## 檔案保留
///
/// 已出貨的 beta.1 每次新增／刪除都會 parse 整檔再整檔重寫，它讀不懂的行必然消失，而那份程式碼改不了。
/// 所以從新版的寫法下手（產品決策）：
/// - **主檔** `user_custom_phrases.txt` 新版寫出時只含 beta.1 讀得懂的「三欄、空白分隔」行（外加檔頭註解與格式標記）。
/// - beta.1 讀不懂的行（使用者的註解、Tab 分隔的詞、四欄行的原文、無法解析的行）**原文**存進
///   **附屬檔** `user_custom_phrases.extra.txt`（beta.1 不讀也不寫）。四欄以上但前三欄合格的行，
///   主檔放它的三欄版本（引擎本來就會載入這種行），附屬檔放原文。降級後 beta.1 怎麼重寫主檔都碰不到附屬檔。
/// - **一次性備份**：第一次要改寫主檔前，把原檔原樣複製成 `user_custom_phrases.txt.bak-<時間戳>`；
///   目錄裡已經有任何 `.bak-` 檔就不再做（只做一次、不累積）。
/// - 檔案存在但讀不到、或不是合法 UTF-8 時，新增／刪除一律拒寫（`saveFailed`），不覆寫。
/// - 主檔檔頭有 `# twk-custom-phrases-format: N` 標記（無標記＝v0，第一次寫入時補上；N 比自己新就原樣保留）。
/// - 只讀不寫時完全不碰任何檔。
///
/// 新增時的分數固定為 -6.0，介面不讓使用者填。
/// 依據：引擎載入端註明分數必填，省略會變成 `defaultScore = 0`（絕對優先）。
/// `tools/user_phrases/user_phrases.txt` 檔頭與另一份評分設定裡「競爭者是亂組」那一檔
/// 都是 -6，讓指定的詞在自己的讀音下排得上。-10 是句級會搶鄰字的詞才用的，
/// 這個視窗在新增當下做不了那次句級判斷。
enum UserCustomPhrasesStore {

    struct Phrase: Equatable, Hashable {
        var reading: String
        var word: String
        var score: Double
    }

    enum Failure: Equatable, Error {
        case emptyWord
        case emptyReading
        case invalidReading
        case syllableCountMismatch
        case duplicate
        case limitReached
        case saveFailed

        /// 給介面顯示的句子。上限那句不准帶數量。
        var message: String {
            switch self {
            case .emptyWord: return "請輸入詞"
            case .emptyReading: return "請輸入注音讀音"
            case .invalidReading: return "讀音格式不正確"
            case .syllableCountMismatch: return "音節數要和字數相同"
            case .duplicate: return "這個詞已經在清單裡"
            case .limitReached: return "已達上限"
            case .saveFailed: return "無法儲存"
            }
        }
    }

    /// 只算這個檔裡的詞，不算 `user_phrases.txt`。介面不顯示這個數字。
    static let maxEntryCount = 50
    static let defaultScore = -6.0

    private static let toneMarks: Set<Character> = ["ˊ", "ˇ", "ˋ", "˙"]
    private static let syllableTable = SyllableTable()

    static func fileURL(inLibraryDirectory directory: URL) -> URL {
        directory.appendingPathComponent(customFilename)
    }

    static func load(
        from directory: URL,
        fileManager: FileManager = .default
    ) -> [Phrase] {
        let url = fileURL(inLibraryDirectory: directory)
        guard fileManager.isReadableFile(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return parse(text)
    }

    @discardableResult
    static func add(
        word: String,
        reading: String,
        in directory: URL,
        fileManager: FileManager = .default
    ) -> Result<Phrase, Failure> {
        lock.lock(); defer { lock.unlock() }
        // 上限與重複都以「引擎看得到的詞行」為準（含主檔裡四欄、兩欄的行），不只介面列得出來的三欄行。
        let existing = engineVisiblePhrases(in: directory, fileManager: fileManager)
        if existing.count >= maxEntryCount {
            return .failure(.limitReached)
        }
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWord.isEmpty else { return .failure(.emptyWord) }
        guard !trimmedWord.contains(where: \.isWhitespace) else { return .failure(.invalidReading) }
        guard let normalized = normalizedReading(reading) else { return .failure(.emptyReading) }
        guard readingIsTypeable(normalized) else { return .failure(.invalidReading) }
        let syllables = normalized.split(separator: "-").map(String.init)
        guard syllables.count == trimmedWord.count else { return .failure(.syllableCountMismatch) }
        if existing.contains(where: { $0.reading == normalized && $0.word == trimmedWord }) {
            return .failure(.duplicate)
        }
        let phrase = Phrase(reading: normalized, word: trimmedWord, score: defaultScore)
        let newLine = Data("\(phrase.reading) \(phrase.word) \(formatScore(phrase.score))".utf8)
        do {
            try rewrite(in: directory, fileManager: fileManager) { phrases, _ in phrases.append(newLine) }
        } catch {
            return .failure(.saveFailed)
        }
        return .success(phrase)
    }

    @discardableResult
    static func remove(
        word: String,
        reading: String,
        in directory: URL,
        fileManager: FileManager = .default
    ) -> Result<[Phrase], Failure> {
        lock.lock(); defer { lock.unlock() }
        let existing = load(from: directory, fileManager: fileManager)
        let updated = existing.filter { !($0.word == word && $0.reading == reading) }
        guard updated.count != existing.count else { return .success(existing) }
        do {
            try rewrite(in: directory, fileManager: fileManager) { phrases, archive in
                let matches: (Data) -> Bool = { line in
                    guard let text = String(data: line, encoding: .utf8),
                          let phrase = extendedPhrase(text)?.phrase else { return false }
                    return phrase.word == word && phrase.reading == reading
                }
                phrases.removeAll(where: matches)
                archive.removeAll(where: matches)
            }
        } catch {
            return .failure(.saveFailed)
        }
        return .success(updated)
    }

    // MARK: - 檔案

    static let formatMarkerPrefix = "# twk-custom-phrases-format:"
    static let currentFormatVersion = 1
    static let extraFilename = "user_custom_phrases.extra.txt"
    /// 自訂詞主檔檔名。必須等於引擎載入端讀的那個檔名。
    static let customFilename = "user_custom_phrases.txt"
    static let backupInfix = ".bak-"
    private static let utf8BOM = Data([0xEF, 0xBB, 0xBF])
    private static let newline = UInt8(0x0A)

    private struct FileError: Error {}

    /// 同一個行程內的新增／刪除序列化（設定視窗與輸入法在同一行程）。跨行程沒有鎖：輸入法只有一個行程。
    private static let lock = NSLock()

    /// 主檔裡引擎會載入的詞行（比介面列出的寬：兩欄、四欄、行尾 `\r` 都算）。讀不到或非 UTF-8 回空。
    private static func engineVisiblePhrases(in directory: URL, fileManager: FileManager) -> [Phrase] {
        let url = fileURL(inLibraryDirectory: directory)
        guard fileManager.isReadableFile(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { extendedPhrase(String($0))?.phrase }
    }

    static func extraFileURL(inLibraryDirectory directory: URL) -> URL {
        directory.appendingPathComponent(extraFilename)
    }

    /// 附屬檔裡存的原文行（給診斷與測試看；引擎與介面都不讀它）。檔案不存在或讀不到回空。
    static func preservedLines(from directory: URL, fileManager: FileManager = .default) -> [String] {
        let url = extraFileURL(inLibraryDirectory: directory)
        guard let raw = try? Data(contentsOf: url), String(data: raw, encoding: .utf8) != nil else { return [] }
        // 在 bytes 上切：Swift 的 `String` 把 `\r\n` 當成一個字元，用 "\n" 切不開 CRLF。
        return splitLines(raw).filter { !$0.isEmpty }.compactMap { String(data: $0, encoding: .utf8) }
    }

    /// 目錄裡已存在的一次性備份檔（`user_custom_phrases.txt.bak-*`）。
    static func backupFiles(in directory: URL, fileManager: FileManager = .default) -> [URL] {
        let prefix = customFilename + backupInfix
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }.sorted().map { directory.appendingPathComponent($0) }
    }

    /// 讀主檔與附屬檔 → 分類 → 交給 `edit`（可改主檔詞行與附屬檔行）→ 先寫附屬檔、再寫主檔。
    /// 任何一個檔存在但讀不到／不是合法 UTF-8 ⇒ 丟錯、不寫（呼叫端回 `saveFailed`）。
    private static func rewrite(
        in directory: URL,
        fileManager: FileManager,
        edit: (_ phrases: inout [Data], _ archive: inout [Data]) -> Void
    ) throws {
        let url = fileURL(inLibraryDirectory: directory)
        let extraURL = extraFileURL(inLibraryDirectory: directory)

        var phrases: [Data] = []
        var archive: [Data] = []
        var marker = "\(formatMarkerPrefix) \(currentFormatVersion)"
        var original: Data?
        var needsBackup = false

        if fileManager.fileExists(atPath: extraURL.path) {
            let raw = try Data(contentsOf: extraURL)
            guard String(data: raw, encoding: .utf8) != nil else { throw FileError() }
            archive = splitLines(raw).filter { !$0.isEmpty }
        }
        if fileManager.fileExists(atPath: url.path) {
            let raw = try Data(contentsOf: url)
            guard String(data: raw, encoding: .utf8) != nil else { throw FileError() }
            original = raw
            var sawMarker = false
            for (index, rawLine) in splitLines(raw).enumerated() {
                let line = index == 0 && rawLine.starts(with: utf8BOM) ? Data(rawLine.dropFirst(utf8BOM.count)) : rawLine
                let text = String(data: line, encoding: .utf8) ?? ""
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix(formatMarkerPrefix) {
                    if !sawMarker {
                        marker = trimmed; sawMarker = true
                        // 比這個程式新的格式：不重寫它不認得的內容（與選字記憶的 `.newer` 唯讀保護一致）。
                        if let version = Int(trimmed.dropFirst(formatMarkerPrefix.count).trimmingCharacters(in: .whitespaces)),
                           version > currentFormatVersion { throw FileError() }
                    }
                } else if trimmed.isEmpty || standardHeader.contains(trimmed) {
                    continue
                } else if parseLine(text) != nil {
                    phrases.append(line)
                } else if let extended = extendedPhrase(text) {
                    phrases.append(Data(extended.canonical.utf8))
                    needsBackup = true
                    appendUnique(line, to: &archive)
                } else {
                    needsBackup = true
                    appendUnique(line, to: &archive)
                }
            }
            if !sawMarker { needsBackup = true }   // 沒有標記＝beta.1 寫的（或手改的）舊檔
        }

        edit(&phrases, &archive)

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if let original, !original.isEmpty, needsBackup { try backupOnce(original: original, in: directory, fileManager: fileManager) }
        if fileManager.fileExists(atPath: extraURL.path) || !archive.isEmpty {
            try joinLines(archive).write(to: extraURL, options: .atomic)   // 先寫附屬檔：中途失敗時主檔原文還在
        }
        let header = standardHeader.map { Data($0.utf8) } + [Data(marker.utf8), Data()]
        try joinLines(header + phrases).write(to: url, options: .atomic)
    }

    private static let standardHeader = [
        "# 從偏好設定新增的詞。",
        "# user_phrases.txt 的既有內容不在這個檔，也不會被這裡改寫。",
        "# 格式：<注音 keyChain> <詞> <分數>",
    ]

    private static func appendUnique(_ line: Data, to lines: inout [Data]) {
        if !lines.contains(line) { lines.append(line) }
    }

    /// 第一次要改寫主檔前，把原檔原樣複製一份。目錄裡已有任何備份就不再做。
    private static func backupOnce(original: Data, in directory: URL, fileManager: FileManager) throws {
        guard backupFiles(in: directory, fileManager: fileManager).isEmpty else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = customFilename + backupInfix + formatter.string(from: Date())
        try original.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    /// 以 0x0A 切行（UTF-8 裡 0x0A 只會是換行，切在 bytes 上不會切壞字元）。檔尾換行不產生空元素。
    private static func splitLines(_ raw: Data) -> [Data] {
        var lines: [Data] = []
        var start = raw.startIndex
        for index in raw.indices where raw[index] == newline {
            lines.append(raw[start..<index])
            start = raw.index(after: index)
        }
        if start < raw.endIndex { lines.append(raw[start...]) }
        return lines.map { Data($0) }
    }

    private static func joinLines(_ lines: [Data]) -> Data {
        var out = Data()
        for line in lines {
            out.append(line)
            out.append(newline)
        }
        return out
    }

    static func parse(_ text: String) -> [Phrase] {
        var phrases: [Phrase] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let phrase = parseLine(String(raw)) { phrases.append(phrase) }
        }
        return phrases
    }

    /// 一行 → 詞。只收空白分隔恰三欄、分數可轉 Double 的行（beta.1 的 `parse` 也只收這種）；其餘回 nil。
    private static func parseLine(_ raw: String) -> Phrase? {
        var text = raw
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let line = text.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { return nil }
        let parts = line.split(separator: " ").map(String.init)
        guard parts.count == 3, let score = Double(parts[2]), !parts[0].isEmpty, !parts[1].isEmpty else {
            return nil
        }
        return Phrase(reading: parts[0], word: parts[1], score: score)
    }

    /// 引擎（詞庫的逐行解析）會載入的詞行：以空白切欄、至少兩欄；第三欄若是數字就是分數，
    /// 否則（缺或不是數字）引擎用 `defaultScore`＝0；更多欄位引擎不看。比 `parseLine` 寬：兩欄、四欄以上、行尾帶 `\r` 都算。
    /// 回傳的 `canonical` 是等價的三欄行（缺分數寫 `0.0`，與引擎相同），主檔放這個，beta.1 才讀得懂。
    /// Tab 分隔的行引擎讀不到，這裡也不收。
    private static func extendedPhrase(_ raw: String) -> (phrase: Phrase, canonical: String)? {
        var text = raw
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.hasPrefix("#") { return nil }
        let parts = line.split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let score = parts.count > 2 ? Double(parts[2]) : nil
        let scoreField = score != nil ? parts[2] : "0.0"
        let phrase = Phrase(reading: parts[0], word: parts[1], score: score ?? 0)
        return (phrase, "\(parts[0]) \(parts[1]) \(scoreField)")
    }

    private static func formatScore(_ score: Double) -> String {
        String(format: "%.1f", score)
    }

    // MARK: - 讀音

    /// 空白或連字號都當成音節分隔，存檔一律用 `-`。空音節（連續分隔）回 nil。
    static func normalizedReading(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let replaced = trimmed.replacingOccurrences(of: "－", with: "-")
        let parts = replaced.split(omittingEmptySubsequences: false) { character in
            character == "-" || character == " " || character == "\t" || character == "　"
        }.map(String.init)
        if parts.isEmpty || parts.contains(where: \.isEmpty) { return nil }
        return parts.joined(separator: "-")
    }

    /// 每個音節去掉結尾聲調後必須在 `SyllableTable` 裡。跟出貨詞表護欄同一套表。
    static func readingIsTypeable(_ reading: String) -> Bool {
        let syllables = reading.split(separator: "-").map(String.init)
        if syllables.isEmpty { return false }
        for syllable in syllables {
            var base = syllable
            if let last = base.last, toneMarks.contains(last) {
                base.removeLast()
            }
            if base.isEmpty || !syllableTable.isValidSyllable(base) { return false }
        }
        return true
    }
}
