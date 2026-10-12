// SPDX-License-Identifier: Apache-2.0
// 公開版 BasicEngine 的行為測試。
// 以 `-D BASIC_ENGINE_TESTS` 編譯時，這個檔案自帶進入點。

import Foundation

enum BasicEngineTestSuite {
    private static var passed = 0
    private static var failed = 0

    static func run() -> Int {
        passed = 0
        failed = 0
        let lexicon = fixtureLexicon
        print("data=\(lexicon.dataDirectory.path)")
        print("scored=\(lexicon.scoredEntryCount) unscored=\(lexicon.unscoredEntryCount) skippedZhuyin=\(lexicon.skippedZhuyinEntryCount) skippedLong=\(lexicon.skippedLongEntryCount) conservative=\(lexicon.conservativeScore)")

        testEmptyAndIllegal()
        testTypeComposeCandidatesAndSelect()
        testPhraseBackspaceClearAndCursor()
        testReplaceToneUnsealedAndContext()
        testOverlongAndNoOps()
        testKeyByKeyLikeSession()

        print("passed=\(passed) failed=\(failed)")
        return failed
    }

    private static func expect(_ condition: Bool, _ name: String, _ detail: String = "") {
        if condition {
            passed += 1
            return
        }
        failed += 1
        print("FAIL \(name) \(detail)")
    }

    /// 測試用的 bundle 只放指向原檔的符號連結，不複製資料。
    private static let fixtureLexicon: McBopomofoLexicon = {
        let source = canonicalDataDirectory()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("basicengine-mcb.bundle", isDirectory: true)
        let resources = root.appendingPathComponent("Contents/Resources/McBopomofo", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try! FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        for name in McBopomofoLexicon.resourceFileNames {
            try! FileManager.default.createSymbolicLink(
                at: resources.appendingPathComponent(name),
                withDestinationURL: source.appendingPathComponent(name)
            )
        }
        let bundle = Bundle(url: root)!
        return McBopomofoLexicon(bundle: bundle)
    }()

    private static func canonicalDataDirectory() -> URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 8 {
            let candidate = url.appendingPathComponent("Vendor/McBopomofo/Source/Data", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("phrase.occ").path) {
                return candidate
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return URL(fileURLWithPath: "/missing-mcb-data")
    }

    private static func makeEngine() -> BasicEngine {
        BasicEngine(lexicon: fixtureLexicon)
    }

    private static func testEmptyAndIllegal() {
        let emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("basicengine-empty.bundle", isDirectory: true)
        try? FileManager.default.removeItem(at: emptyRoot)
        try! FileManager.default.createDirectory(
            at: emptyRoot.appendingPathComponent("Contents/Resources", isDirectory: true),
            withIntermediateDirectories: true
        )
        let emptyBundle = Bundle(url: emptyRoot)!
        expect(McBopomofoLexicon.dataDirectory(in: emptyBundle) == nil, "missing bundle resources")
        expect(
            McBopomofoLexicon.locateDataDirectory(bundle: emptyBundle, sourceFile: "/no/such/McBopomofoLexicon.swift") == nil,
            "bundle and source both missing"
        )
        let fallback = McBopomofoLexicon(bundle: emptyBundle)
        expect(fallback.scoredEntryCount > 100_000, "source path fallback still loads", "\(fallback.scoredEntryCount)")
        expect(
            fallback.dataDirectory.path.contains("Vendor/McBopomofo/Source/Data"),
            "fallback walks to upstream data",
            fallback.dataDirectory.path
        )
        expect(fixtureLexicon.dataDirectory.path.contains(".bundle/Contents/Resources") == true, "loads from bundle", fixtureLexicon.dataDirectory.path)
        expect(McBopomofoLexicon.resourceFileNames.count == 6, "six upstream files")
        let prefix = fixtureLexicon.unigramsFor(keyArray: ["ㄋ"])
        expect(prefix.count == 1 && prefix.first?.value == "ㄋ", "incomplete key is a placeholder", prefix.map(\.value).joined(separator: ","))
        expect(fixtureLexicon.accepts("ㄋ") && fixtureLexicon.accepts("ㄋㄧ") && fixtureLexicon.accepts("ㄋㄧˇ"), "prefix and syllable accepted")
        expect(fixtureLexicon.accepts("ㄋˇ") == false, "tone on a prefix rejected")

        let engine = makeEngine()
        expect(engine.input("") == false, "empty input rejected")
        expect(engine.compositorKeys.isEmpty, "empty input leaves no keys")
        expect(engine.getComposedText().isEmpty, "empty composition")
        expect(engine.currentCandidates().isEmpty, "empty candidates")
        expect(engine.highlightedCandidate() == nil, "empty highlight")
        expect(engine.input("abc") == false, "latin rejected", engine.compositorKeys.joined(separator: ","))
        expect(engine.input("ㄅㄅㄅ") == false, "illegal zhuyin rejected")
        expect(engine.input("ˇ") == false, "bare tone rejected")
        expect(engine.compositorKeys.isEmpty, "illegal input leaves no keys")
        engine.backspace()
        expect(engine.getComposedText().isEmpty, "backspace on empty stays empty")
    }

    private static func testTypeComposeCandidatesAndSelect() {
        let engine = makeEngine()
        expect(engine.input("ㄋㄧˇ"), "input ni3")
        expect(engine.compositorKeys == ["ㄋㄧˇ"], "keys are the syllable", engine.compositorKeys.joined(separator: ","))
        expect(engine.compositionCursor == 1, "cursor after one syllable", "\(engine.compositionCursor)")
        expect(engine.getComposedText() == "你", "compose 你", engine.getComposedText())
        expect(engine.highlightedCandidate() == "你", "highlight is 你", engine.highlightedCandidate() ?? "nil")
        let candidates = engine.currentCandidates()
        expect(candidates.first == "你", "你 is top candidate", candidates.prefix(5).joined(separator: ","))
        expect(candidates.contains("妳"), "妳 is a candidate")
        expect(engine.currentCandidates(limit: 1) == ["你"], "limit 1")
        expect(engine.currentCandidates(limit: 0).isEmpty, "limit 0")
        guard let index = candidates.firstIndex(of: "妳") else {
            expect(false, "index of 妳")
            return
        }
        expect(engine.setHighlightedCandidate(index: index) == "妳", "select 妳")
        expect(engine.lastOverrideApplied == true, "override applied")
        expect(engine.getComposedText() == "妳", "composed becomes 妳", engine.getComposedText())
        expect(engine.highlightedCandidate() == "妳", "highlight follows selection")
        expect(engine.setHighlightedCandidate(index: -1) == nil, "negative index rejected")
        expect(engine.setHighlightedCandidate(index: 999_999) == nil, "overflow index rejected")
        expect(engine.lastOverrideApplied == false, "failed override recorded")
    }

    private static func testPhraseBackspaceClearAndCursor() {
        let engine = makeEngine()
        expect(engine.input("ㄋㄧˇ"), "phrase first syllable")
        expect(engine.input("ㄏㄠˇ"), "phrase second syllable")
        expect(engine.getComposedText() == "你好", "compose 你好", engine.getComposedText())
        expect(engine.compositionCursor == 2, "cursor at end")
        let plan = engine.scrubCompositionCursor(by: -1)
        expect(plan.consumedOffset == -1 && plan.remainingOffset == 0, "scrub back one", "\(plan)")
        expect(engine.compositionCursor == 1, "cursor after scrub", "\(engine.compositionCursor)")
        let edge = engine.scrubCompositionCursor(by: -100)
        expect(edge.consumedOffset == -1 && edge.remainingOffset == -99, "scrub clamps", "\(edge)")
        expect(engine.compositionCursor == 0, "cursor at start")
        let forward = engine.scrubCompositionCursor(by: 5)
        expect(forward.consumedOffset == 2 && forward.remainingOffset == 3, "scrub clamps forward", "\(forward)")
        expect(engine.compositionCursor == 2, "cursor back at end")
        engine.backspace()
        expect(engine.compositorKeys == ["ㄋㄧˇ"], "backspace drops last key", engine.compositorKeys.joined(separator: ","))
        expect(engine.getComposedText() == "你", "backspace recomposes", engine.getComposedText())
        engine.clear()
        expect(engine.compositorKeys.isEmpty && engine.getComposedText().isEmpty, "clear resets composition")
        expect(engine.compositionCursor == 0, "clear resets cursor")
    }

    private static func testReplaceToneUnsealedAndContext() {
        let engine = makeEngine()
        expect(engine.input("ㄋㄧ"), "input toneless ni")
        expect(engine.replaceLastKey(from: "ㄨ", to: "ㄋㄧˇ") == false, "replace mismatch rejected")
        expect(engine.compositorKeys == ["ㄋㄧ"], "mismatch keeps the key")
        expect(engine.replaceLastKey(from: "ㄋㄧ", to: "not-zhuyin") == false, "replace illegal rejected")
        expect(engine.replaceLastKey(from: "ㄋㄧ", to: "ㄋㄧˇ"), "replace adds tone")
        expect(engine.compositorKeys == ["ㄋㄧˇ"], "key replaced", engine.compositorKeys.joined(separator: ","))
        expect(engine.getComposedText() == "你", "toned key composes 你", engine.getComposedText())

        expect(engine.isSealed(key: "ㄋㄧˇ", atKeyCount: 1), "sealed by default")
        engine.markAutoFlushedAsUnsealed(content: "ㄋㄧˇ", keyCount: 1)
        expect(engine.autoFlushedUnsealedSyllables.count == 1, "unsealed record stored")
        expect(engine.isSealed(key: "ㄋㄧˇ", atKeyCount: 1) == false, "unsealed match")
        expect(engine.isSealed(key: "ㄋㄧˇ", atKeyCount: 2), "other position stays sealed")
        engine.markImplicitFirstToneForCurrentTail()
        expect(engine.isSealed(key: "ㄋㄧˇ", atKeyCount: 1), "implicit first tone seals tail")
        engine.markAutoFlushedAsUnsealed(content: "ㄋㄧˇ", keyCount: 1)
        engine.clearAutoFlushedUnsealedRecord(content: "ㄋㄧˇ", keyCount: 1)
        expect(engine.isSealed(key: "ㄋㄧˇ", atKeyCount: 1), "clear unsealed record")
        expect(engine.autoFlushedUnsealedSyllables.isEmpty, "unsealed list empty")

        let long = String(repeating: "文", count: 40)
        engine.setExternalLeftContext(long)
        expect(engine.effectiveExternalLeftContext.count == engine.kenLMContextWindowChars, "context truncated", "\(engine.effectiveExternalLeftContext.count)")
        expect(engine.kenLMContextWindowChars == 32, "context window")
        engine.setExternalLeftContext(nil)
        expect(engine.effectiveExternalLeftContext.isEmpty, "nil context clears")
        engine.leftContextHostIsTerminal = true
        expect(engine.leftContextHostIsTerminal, "terminal host flag")

        expect(engine.input("ㄏㄠˇ"), "second key for copy")
        let original = engine.getComposedText()
        guard let view = engine.composerView else {
            expect(false, "composer view exists")
            return
        }
        let copy = view.copy()
        expect(copy.dropRearKey(), "copy drops rear key")
        expect(engine.compositorKeys.count == 2, "original keys unchanged", "\(engine.compositorKeys.count)")
        expect(engine.getComposedText() == original, "original text unchanged", engine.getComposedText())
    }

    private static func testOverlongAndNoOps() {
        let engine = makeEngine()
        let cap = BasicEngine.maxCompositionKeys
        var accepted = 0
        for _ in 0 ..< cap {
            if engine.input("ㄕˋ") { accepted += 1 }
        }
        expect(accepted == cap, "accepts up to the cap", "\(accepted)")
        expect(engine.input("ㄕˋ") == false, "overlong input rejected")
        expect(engine.compositorKeys.count == cap, "length stays at cap", "\(engine.compositorKeys.count)")
        expect(engine.getComposedText().isEmpty == false, "overlong composition still has text")
        engine.warmUp()
        engine.refreshChoiceLearning()
        engine.noteUserConfirmedSelection()
        expect(engine.learnedChoicesAppliedTotal == 0, "no choice learning")
        expect(engine.reloadUserPhrases(fromContainer: URL(fileURLWithPath: "/tmp")) == 0, "no user phrases")
        let shi = makeEngine()
        expect(shi.input("ㄕˋ"), "input shi4")
        expect(shi.getComposedText() == "是", "compose 是", shi.getComposedText())
        let shiCandidates = shi.currentCandidates()
        guard let shiIndex = shiCandidates.firstIndex(of: "世") else {
            expect(false, "世 is a candidate", shiCandidates.prefix(8).joined(separator: ","))
            return
        }
        expect(shi.setHighlightedCandidate(index: shiIndex) == "世", "select 世")
        expect(shi.getComposedText() == "世", "composed becomes 世", shi.getComposedText())
    }

    /// 外殼 `MacClientSession.apply` 是逐鍵送目前緩衝：
    /// `input("ㄋ")`，再 `replaceLastKey(from:"ㄋ", to:"ㄋㄧ")`，再換成 `ㄋㄧˇ`。
    private static func testKeyByKeyLikeSession() {
        let ni = makeEngine()
        expect(feedSyllable(ni, "ㄋㄧˇ"), "key by key ㄋㄧˇ")
        expect(ni.compositorKeys == ["ㄋㄧˇ"], "key by key keys", ni.compositorKeys.joined(separator: ","))
        expect(ni.getComposedText() == "你", "key by key 你", ni.getComposedText())
        expect(ni.highlightedCandidate() == "你", "key by key highlight 你", ni.highlightedCandidate() ?? "nil")

        expect(feedSyllable(ni, "ㄏㄠˇ"), "key by key ㄏㄠˇ")
        expect(ni.getComposedText() == "你好", "key by key 你好", ni.getComposedText())
        expect(ni.highlightedCandidate() == "你好", "key by key highlight 你好", ni.highlightedCandidate() ?? "nil")
        ni.backspace()
        expect(ni.getComposedText() == "你", "key by key backspace", ni.getComposedText())

        let ma = makeEngine()
        expect(feedSyllable(ma, "ㄇㄚ"), "key by key ㄇㄚ")
        expect(ma.replaceLastKey(from: "ㄇㄚ", to: "ㄇㄚˉ"), "space applies first tone")
        let maText = ma.getComposedText()
        expect(maText.count == 1 && maText != "ㄇㄚ" && maText != "ㄇㄚˉ", "ㄇㄚ space is one hanzi", maText)

        let zhu = makeEngine()
        expect(feedSyllable(zhu, "ㄓㄨˋ"), "key by key ㄓㄨˋ")
        expect(feedSyllable(zhu, "ㄧㄣ"), "key by key ㄧㄣ")
        expect(zhu.getComposedText() == "注音", "compose 注音", zhu.getComposedText())
        expect(zhu.highlightedCandidate() == "注音", "highlight matches 注音", zhu.highlightedCandidate() ?? "nil")
        zhu.markAutoFlushedAsUnsealed(content: "ㄧㄣ", keyCount: 2)
        guard let view = zhu.composerView else {
            expect(false, "composer view for 注音")
            return
        }
        let isolated = view.copy()
        isolated.cursor = 2
        expect(isolated.dropRearKey(), "drop unsealed ㄧㄣ")
        let sealedOnly = isolated.assembledGrams.map(\.value).joined()
        expect(sealedOnly == "注", "sealed key stays 注 after the neighbor is removed", sealedOnly)
        expect(zhu.getComposedText() == "注音", "live sentence stays 注音", zhu.getComposedText())

        expect(feedSyllable(zhu, "ㄊㄞˊ"), "key by key ㄊㄞˊ")
        let sentence = zhu.getComposedText()
        expect(sentence == "注音台", "compose 注音台", sentence)
        let highlight = zhu.highlightedCandidate() ?? ""
        expect(sentence.contains(highlight) && highlight.contains("台"), "highlight agrees with 注音台", highlight)
    }

    /// 照外殼把一個音節拆成「先 input 第一個符號，後面每次 replaceLastKey」。
    private static func feedSyllable(_ engine: BasicEngine, _ syllable: String) -> Bool {
        var built = ""
        for character in syllable {
            let next = built + String(character)
            let ok: Bool
            if built.isEmpty {
                ok = engine.input(next)
            } else {
                ok = engine.replaceLastKey(from: built, to: next)
            }
            if !ok { return false }
            built = next
        }
        return built == syllable
    }
}

#if BASIC_ENGINE_TESTS
@main
enum BasicEngineTestMain {
    static func main() {
        let failed = BasicEngineTestSuite.run()
        exit(failed == 0 ? 0 : 1)
    }
}
#endif
