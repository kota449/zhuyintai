// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import UpdateCheck

/// 語意化版本解析與比較測試。
@Suite("SemanticVersion 解析與比較")
struct SemanticVersionTests {
    /// 比較表：(較小版, 較大版)，至少 12 組，含預發行版數字與字母混合。
    @Test("版本先後順序", arguments: [
        ("1.0.0-alpha", "1.0.0-alpha.1"),
        ("1.0.0-alpha.1", "1.0.0-alpha.beta"),
        ("1.0.0-alpha.beta", "1.0.0-beta"),
        ("1.0.0-beta", "1.0.0-beta.2"),
        ("1.0.0-beta.2", "1.0.0-beta.10"),
        ("1.0.0-beta.10", "1.0.0-beta.a"),
        ("1.0.0-beta.a", "1.0.0-rc.1"),
        ("1.0.0-rc.1", "1.0.0"),
        ("0.1.0-beta.2", "0.1.0-beta.10"),
        ("0.1.0-beta.10", "0.1.0"),
        ("1.2.3", "2.0.0"),
        ("1.2.3", "1.10.0"),
        ("1.0.0-alpha+001", "1.0.0-alpha+002"), // 建構資訊不參與比較，故兩者相等（此組改由相等測試處理）
        ("2.1.1", "2.2.0"),
    ] as [(String, String)])
    func ordering(smaller: String, larger: String) throws {
        // 建構資訊不同的兩筆視為相等，跳過大小比較。
        if smaller == "1.0.0-alpha+001" {
            let a = try #require(SemanticVersion(smaller))
            let b = try #require(SemanticVersion(larger))
            #expect(a == b)
            return
        }
        let a = try #require(SemanticVersion(smaller))
        let b = try #require(SemanticVersion(larger))
        #expect(a < b)
        #expect(b > a)
        #expect(a != b)
    }

    /// 額外 12 組純比較（含數字與字母混合）。
    @Test("更多比較組合", arguments: [
        ("0.1.0-alpha", "0.1.0"),
        ("0.1.0-1", "0.1.0-a"),
        ("0.1.0-2", "0.1.0-10"),
        ("1.0.0-x.7.z.92", "1.0.0-x.7.z.93"),
        ("1.0.0-0.3.7", "1.0.0-0.3.8"),
        ("1.0.0-a.b", "1.0.0-a.b.1"),
        ("1.0.0-a.1", "1.0.0-a.2"),
        ("1.0.0-a.2", "1.0.0-a.10"),
        ("1.0.0-a.10", "1.0.0-a.b"),
        ("1.0.0-9", "1.0.0-a"),
        ("0.0.1", "0.0.2"),
        ("10.0.0", "2.0.0").self, // 反向：10 > 2，此組期望 a > b
    ] as [(String, String)])
    func moreOrdering(smaller: String, larger: String) throws {
        let a = try #require(SemanticVersion(smaller))
        let b = try #require(SemanticVersion(larger))
        if smaller == "10.0.0" {
            #expect(a > b)
        } else {
            #expect(a < b)
        }
    }

    @Test("相等：建構資訊不參與比較")
    func buildMetadataIgnored() throws {
        let a = try #require(SemanticVersion("1.0.0+20130313"))
        let b = try #require(SemanticVersion("1.0.0+exp.sha.5114f85"))
        #expect(a == b)
        #expect(!(a < b) && !(b < a))
    }

    @Test("相等版本的 Hashable 不含 build")
    func equalVersionsShareHashDespiteBuild() throws {
        let a = try #require(SemanticVersion("1.0.0+a"))
        let b = try #require(SemanticVersion("1.0.0+b"))
        #expect(a == b)
        #expect(Set([a, b]).count == 1)
        var hasherA = Hasher()
        a.hash(into: &hasherA)
        var hasherB = Hasher()
        b.hash(into: &hasherB)
        #expect(hasherA.finalize() == hasherB.finalize())
    }

    @Test("壞字串回 nil", arguments: [
        "", "1", "1.2", "1.2.3.4", "a.b.c", "1.02.3", "1.2.3-01",
        "1.2.3-", "1.2.3+", "1.2.3-..", "1.2.3+..", "  ", "v1.2.3",
        "1.2.3-beta..1", "1.2.3-α",
    ] as [String])
    func invalidReturnsNil(_ raw: String) {
        #expect(SemanticVersion(raw) == nil)
    }

    @Test("往返描述")
    func roundTrip() throws {
        for raw in ["1.2.3", "0.1.0-beta.2", "1.0.0-alpha.1+build.5"] {
            let v = try #require(SemanticVersion(raw))
            #expect(v.description == raw)
        }
    }
}
