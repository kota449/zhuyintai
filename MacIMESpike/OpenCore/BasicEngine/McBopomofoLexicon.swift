// SPDX-License-Identifier: Apache-2.0
// 讀小麥注音 MIT 資料，做成 Megrez 的語言模型。
//
// phrase.occ：`詞 次數`（整數）。BPMFMappings.txt：`詞 讀音…`，沒有分數。
// BPMFBase.txt：`字 注音 拼音 編碼欄 編碼`。第四欄不是明文次數，這裡不用。
//
// Megrez 組句把節點分數相加。次數先換成 ln(次數)−ln(正次數總和)，
// 詞組才不會被兩個高頻單字的次數加總壓過。沒有正次數的詞用固定保守分：
// 比「出現 1 次」再低 `conservativeGap`（1）。

#if canImport(Megrez)
import Megrez
#endif
import Foundation

final class McBopomofoLexicon: LangModelProtocol {
    static let shared = McBopomofoLexicon()
    static let conservativeGap = 1.0
    private static let unitSeparator = "\u{1}"
    private static let maxReadings = 10
    private static let toneMarks: Set<Character> = ["ˉ", "ˊ", "ˇ", "ˋ", "˙"]

    /// 開放樹匯出的那 6 個上游檔。內容不改、不加標頭，bundle 裡要能整組找到。
    static let resourceFileNames = [
        "BPMFBase.txt",
        "BPMFMappings.txt",
        "phrase.occ",
        "heterophony1.list",
        "heterophony2.list",
        "heterophony3.list",
    ]

    let dataDirectory: URL
    let scoredEntryCount: Int
    let unscoredEntryCount: Int
    let skippedZhuyinEntryCount: Int
    let skippedLongEntryCount: Int
    let conservativeScore: Double

    private let exactSingle: [String: [Megrez.Unigram]]
    private let anyTone: [String: [Megrez.Unigram]]
    private let phrases: [String: [Megrez.Unigram]]
    private let syllables = SyllableTable()

    /// 先用 bundle 的 resource（App 把 6 個檔放進 `Bundle.main.resourceURL`），
    /// 找不到再從這個原始檔往上走到 `Vendor/McBopomofo/Source/Data`。
    /// 公開版打字探針沒有 App bundle，靠第二步。兩邊都沒有就停下來，不要變成空詞庫。
    init(bundle: Bundle = .main, sourceFile: String = #filePath) {
        guard let directory = Self.locateDataDirectory(bundle: bundle, sourceFile: sourceFile) else {
            fatalError("McBopomofoLexicon: 找不到小麥注音上游資料（bundle resource 與原始檔路徑皆無）")
        }
        guard let loaded = Self.load(from: directory) else {
            fatalError("McBopomofoLexicon: 小麥注音上游資料無法讀取：\(directory.path)")
        }
        self.dataDirectory = directory
        self.exactSingle = loaded.exactSingle
        self.anyTone = loaded.anyTone
        self.phrases = loaded.phrases
        self.scoredEntryCount = loaded.scoredEntryCount
        self.unscoredEntryCount = loaded.unscoredEntryCount
        self.skippedZhuyinEntryCount = loaded.skippedZhuyinEntryCount
        self.skippedLongEntryCount = loaded.skippedLongEntryCount
        self.conservativeScore = loaded.conservativeScore
    }

    func unigramsFor(keyArray: [String]) -> [Megrez.Unigram] {
        if keyArray.count == 1, let reading = keyArray.first {
            guard accepts(reading) else { return [] }
            // 音節還沒拼完。Megrez.insertKey 沒有 unigram 會回 false，
            // 外殼又是逐鍵 replace，所以這裡給一個原文等於 key 的低分占位。
            if !isCompleteSyllable(reading) {
                return [Megrez.Unigram(keyArray: keyArray, value: reading, score: conservativeScore)]
            }
            if let found = singleReadings(reading), !found.isEmpty {
                return retarget(found, keyArray: keyArray)
            }
            return [Megrez.Unigram(keyArray: keyArray, value: reading, score: conservativeScore)]
        }
        guard keyArray.count > 1, keyArray.allSatisfy(isCompleteSyllable) else { return [] }
        let normalized = keyArray.map(Self.normalize)
        guard let found = phrases[normalized.joined(separator: Self.unitSeparator)], !found.isEmpty else {
            return []
        }
        return retarget(found, keyArray: keyArray)
    }

    func hasUnigramsFor(keyArray: [String]) -> Bool {
        !unigramsFor(keyArray: keyArray).isEmpty
    }

    /// 完整音節，或某個合法音節的前綴。聲調只准標在完整音節上。
    func accepts(_ reading: String) -> Bool {
        let (body, tone) = Self.splitTone(reading)
        guard !body.isEmpty else { return false }
        if body.contains(where: { Self.toneMarks.contains($0) }) { return false }
        if tone != nil { return syllables.isValidSyllable(body) }
        return syllables.isValidPrefix(body)
    }

    func isCompleteSyllable(_ reading: String) -> Bool {
        let (body, _) = Self.splitTone(reading)
        guard !body.isEmpty else { return false }
        if body.contains(where: { Self.toneMarks.contains($0) }) { return false }
        return syllables.isValidSyllable(body)
    }

    private func singleReadings(_ reading: String) -> [Megrez.Unigram]? {
        let (body, tone) = Self.splitTone(reading)
        if tone == "ˉ" {
            return exactSingle[body]
        }
        if tone == nil {
            return anyTone[body]
        }
        return exactSingle[reading]
    }

    private func retarget(_ list: [Megrez.Unigram], keyArray: [String]) -> [Megrez.Unigram] {
        list.map { gram in
            gram.keyArray == keyArray ? gram.copy() : gram.copy(withKeyArray: keyArray)
        }
    }

    /// bundle 優先。`sourceFile` 只在 bundle 沒有那 6 個檔時，從該路徑往上找上游資料目錄。
    static func locateDataDirectory(bundle: Bundle, sourceFile: String) -> URL? {
        if let bundled = dataDirectory(in: bundle) { return bundled }
        var url = URL(fileURLWithPath: sourceFile).deletingLastPathComponent()
        let manager = FileManager.default
        for _ in 0 ..< 12 {
            let candidate = url.appendingPathComponent("Vendor/McBopomofo/Source/Data", isDirectory: true)
            let complete = resourceFileNames.allSatisfy { name in
                manager.fileExists(atPath: candidate.appendingPathComponent(name).path)
            }
            if complete { return candidate }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return nil
    }

    /// 6 個檔要在同一個 resource 目錄。先看 bundle 根，再看 `McBopomofo` 子目錄。
    static func dataDirectory(in bundle: Bundle) -> URL? {
        var candidates: [URL] = []
        if let root = bundle.resourceURL {
            candidates.append(root)
            candidates.append(root.appendingPathComponent("McBopomofo", isDirectory: true))
        }
        if let mapped = bundle.url(forResource: "BPMFMappings", withExtension: "txt", subdirectory: "McBopomofo") {
            candidates.append(mapped.deletingLastPathComponent())
        }
        if let mapped = bundle.url(forResource: "BPMFMappings", withExtension: "txt") {
            candidates.append(mapped.deletingLastPathComponent())
        }
        let manager = FileManager.default
        for directory in candidates {
            let complete = resourceFileNames.allSatisfy { name in
                manager.fileExists(atPath: directory.appendingPathComponent(name).path)
            }
            if complete { return directory }
        }
        return nil
    }

    private struct Loaded {
        var exactSingle: [String: [Megrez.Unigram]]
        var anyTone: [String: [Megrez.Unigram]]
        var phrases: [String: [Megrez.Unigram]]
        var scoredEntryCount: Int
        var unscoredEntryCount: Int
        var skippedZhuyinEntryCount: Int
        var skippedLongEntryCount: Int
        var conservativeScore: Double
    }

    private struct ScoreCell {
        var score: Double
        var fromOccurrence: Bool
    }

    private struct Bag {
        var cells: [String: ScoreCell] = [:]

        mutating func add(value: String, score: Double, fromOccurrence: Bool) {
            if let old = cells[value] {
                if score > old.score {
                    cells[value] = ScoreCell(score: score, fromOccurrence: fromOccurrence)
                } else if score == old.score, fromOccurrence {
                    cells[value] = ScoreCell(score: score, fromOccurrence: true)
                }
            } else {
                cells[value] = ScoreCell(score: score, fromOccurrence: fromOccurrence)
            }
        }
    }

    private static func load(from directory: URL) -> Loaded? {
        func text(named name: String) -> String? {
            try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        }
        guard
            let occText = text(named: "phrase.occ"),
            let mapText = text(named: "BPMFMappings.txt"),
            let baseText = text(named: "BPMFBase.txt"),
            let hetero1 = text(named: "heterophony1.list"),
            let hetero2 = text(named: "heterophony2.list"),
            let hetero3 = text(named: "heterophony3.list")
        else { return nil }

        var occurrences: [String: Int] = [:]
        occurrences.reserveCapacity(170_000)
        var positiveTotal = 0
        for raw in occText.split(whereSeparator: \.isNewline) {
            guard let space = raw.lastIndex(of: " ") else { continue }
            let word = String(raw[..<space])
            guard let count = Int(raw[raw.index(after: space)...]) else { continue }
            occurrences[word] = count
            if count > 0 { positiveTotal += count }
        }
        let logTotal = positiveTotal > 0 ? log(Double(positiveTotal)) : 0
        let conservative = -logTotal - conservativeGap

        func score(for word: String) -> (Double, Bool) {
            let count = occurrences[word] ?? 0
            if count > 0, positiveTotal > 0 {
                return (log(Double(count)) - logTotal, true)
            }
            return (conservative, false)
        }

        var exactBags: [String: Bag] = [:]
        var anyToneBags: [String: Bag] = [:]
        var phraseBags: [String: Bag] = [:]
        var scoredIDs = Set<String>()
        var unscoredIDs = Set<String>()
        var skippedZhuyin = 0
        var skippedLong = 0

        func ingest(value: String, readings: [String]) {
            if isRawZhuyinOrTone(value) {
                skippedZhuyin += 1
                return
            }
            if readings.isEmpty || readings.count > maxReadings {
                skippedLong += 1
                return
            }
            let (points, fromOccurrence) = score(for: value)
            let id = readings.joined(separator: unitSeparator) + "\u{2}" + value
            if fromOccurrence {
                unscoredIDs.remove(id)
                scoredIDs.insert(id)
            } else if !scoredIDs.contains(id) {
                unscoredIDs.insert(id)
            }
            if readings.count == 1, let reading = readings.first {
                exactBags[reading, default: Bag()].add(value: value, score: points, fromOccurrence: fromOccurrence)
                let (body, _) = splitTone(reading)
                anyToneBags[body, default: Bag()].add(value: value, score: points, fromOccurrence: fromOccurrence)
                return
            }
            let key = readings.joined(separator: unitSeparator)
            phraseBags[key, default: Bag()].add(value: value, score: points, fromOccurrence: fromOccurrence)
        }

        for raw in baseText.split(whereSeparator: \.isNewline) {
            let parts = raw.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            ingest(value: String(parts[0]), readings: [String(parts[1])])
        }
        for raw in mapText.split(whereSeparator: \.isNewline) {
            let parts = raw.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            ingest(value: String(parts[0]), readings: parts.dropFirst().map(String.init))
        }
        for hetero in [hetero1, hetero2, hetero3] {
            for raw in hetero.split(whereSeparator: \.isNewline) {
                let parts = raw.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 2 else { continue }
                ingest(value: String(parts[0]), readings: [String(parts[1])])
            }
        }

        return Loaded(
            exactSingle: freeze(exactBags) { [$0] },
            anyTone: freeze(anyToneBags) { [$0] },
            phrases: freeze(phraseBags) { $0.split(separator: Character(unitSeparator)).map(String.init) },
            scoredEntryCount: scoredIDs.count,
            unscoredEntryCount: unscoredIDs.count,
            skippedZhuyinEntryCount: skippedZhuyin,
            skippedLongEntryCount: skippedLong,
            conservativeScore: conservative
        )
    }

    private static func freeze(
        _ bags: [String: Bag],
        keyArray: (String) -> [String]
    ) -> [String: [Megrez.Unigram]] {
        var result: [String: [Megrez.Unigram]] = [:]
        result.reserveCapacity(bags.count)
        for (key, bag) in bags {
            let readings = keyArray(key)
            result[key] = bag.cells.map { value, cell in
                Megrez.Unigram(keyArray: readings, value: value, score: cell.score)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.value < rhs.value
            }
        }
        return result
    }

    private static func splitTone(_ reading: String) -> (body: String, tone: Character?) {
        guard let tone = reading.last, toneMarks.contains(tone) else {
            return (reading, nil)
        }
        return (String(reading.dropLast()), tone)
    }

    private static func normalize(_ reading: String) -> String {
        let (body, tone) = splitTone(reading)
        if tone == "ˉ" { return body }
        return reading
    }

    private static func isRawZhuyinOrTone(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        guard !scalars.isEmpty else { return true }
        return scalars.allSatisfy { scalar in
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
}
