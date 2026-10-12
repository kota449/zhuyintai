// SPDX-License-Identifier: Apache-2.0
import Foundation

/// 語意化版本（SemVer 2.0）。
///
/// 支援格式：`主版號.次版號.修訂號[-預發行版][+建構資訊]`，
/// 例如 `1.2.3`、`0.1.0-beta.2`、`1.0.0-alpha+001`。
///
/// 比較規則（SemVer 2.0 第 11 條）：
/// - 先比 `主版號 → 次版號 → 修訂號`（數字比大小）。
/// - 無預發行版 > 有預發行版（例如 `1.0.0 > 1.0.0-beta.2`）。
/// - 預發行版逐段比較：純數字段 < 字母段；數字比數值、字母比 ASCII；
///   前綴相同時段數少者較小。
/// - 建構資訊（`+` 之後）不參與比較。
public struct SemanticVersion: Sendable, Hashable, Codable, Comparable, CustomStringConvertible, LosslessStringConvertible {
    /// 主版號（>= 0）。
    public let major: Int
    /// 次版號（>= 0）。
    public let minor: Int
    /// 修訂號（>= 0）。
    public let patch: Int
    /// 預發行版識別段（無則為空陣列）。
    public let prerelease: [PrereleaseIdentifier]
    /// 建構資訊（不參與比較，僅保留顯示用）。
    public let build: String?

    /// 預發行版的單一段識別字。
    public enum PrereleaseIdentifier: Sendable, Hashable, Codable, CustomStringConvertible {
        /// 純數字段（不可有前導零，已在解析時檢查）。
        case numeric(Int, raw: String)
        /// 含字母或連字號的段。
        case alphanumeric(String)

        public var description: String {
            switch self {
            case .numeric(_, let raw): return raw
            case .alphanumeric(let s): return s
            }
        }

        /// 是否為純數字段。
        var isNumeric: Bool {
            if case .numeric = self { return true }
            return false
        }

        /// 數字段的數值（字母段回 nil）。
        var numericValue: Int? {
            if case .numeric(let v, _) = self { return v }
            return nil
        }
    }

    /// 以數字建立版本。
    /// - Parameters:
    ///   - major: 主版號。
    ///   - minor: 次版號。
    ///   - patch: 修訂號。
    ///   - prerelease: 預發行版識別段。
    ///   - build: 建構資訊。
    public init(major: Int, minor: Int, patch: Int, prerelease: [PrereleaseIdentifier] = [], build: String? = nil) {
        precondition(major >= 0 && minor >= 0 && patch >= 0, "版號不可為負數")
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.build = build
    }

    /// 以字串解析版本，壞字串回 `nil`（同時滿足 `LosslessStringConvertible`）。
    public init?(_ description: String) {
        guard let parsed = Self.parse(description) else { return nil }
        self = parsed
    }

    /// 標準字串表示（會保留預發行版與建構資訊）。
    public var description: String {
        var s = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty {
            s += "-" + prerelease.map(\.description).joined(separator: ".")
        }
        if let build, !build.isEmpty {
            s += "+" + build
        }
        return s
    }

    // MARK: - 解析

    /// 解析字串，失敗回 `nil`。
    private static func parse(_ string: String) -> SemanticVersion? {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // 先拆建構資訊（第一個 `+` 之後）。
        let buildSplit = s.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard buildSplit.count <= 2 else { return nil }
        let withoutBuild = String(buildSplit[0])
        let build: String? = buildSplit.count == 2 ? String(buildSplit[1]) : nil
        if let build {
            // 建構資訊：至少一段、每段僅允許 [0-9A-Za-z-] 且不可為空。
            guard isValidBuild(build) else { return nil }
        }

        // 再拆預發行版（第一個 `-` 之後）。
        let preSplit = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard preSplit.count <= 2 else { return nil }
        let core = String(preSplit[0])
        let prereleaseRaw: String? = preSplit.count == 2 ? String(preSplit[1]) : nil
        // `1.2.3-`（橫線後空白）視為壞字串。
        if preSplit.count == 2, prereleaseRaw?.isEmpty ?? true { return nil }

        // 核心版號：必須恰好三段數字。
        let coreParts = core.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard coreParts.count == 3 else { return nil }
        guard let major = parseCoreNumber(coreParts[0]),
              let minor = parseCoreNumber(coreParts[1]),
              let patch = parseCoreNumber(coreParts[2]) else { return nil }

        // 預發行版：以 `.` 分段，每段 [0-9A-Za-z-]+；純數字段不可有前導零。
        var prerelease: [PrereleaseIdentifier] = []
        if let prereleaseRaw {
            let ids = prereleaseRaw.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !ids.isEmpty else { return nil }
            for id in ids {
                guard !id.isEmpty, isValidIdentifierChars(id) else { return nil }
                if isAllDigits(id) {
                    // 數字段：前導零檢查（`0` 本身合法，`01` 不合法）。
                    if id.count > 1, id.hasPrefix("0") { return nil }
                    guard let v = Int(id) else { return nil }
                    prerelease.append(.numeric(v, raw: id))
                } else {
                    prerelease.append(.alphanumeric(id))
                }
            }
        }

        return SemanticVersion(major: major, minor: minor, patch: patch, prerelease: prerelease, build: build)
    }

    /// 核心版號數字：非負整數，不可有前導零（`0` 本身合法）。
    private static func parseCoreNumber(_ s: String) -> Int? {
        guard !s.isEmpty, isAllDigits(s) else { return nil }
        if s.count > 1, s.hasPrefix("0") { return nil }
        return Int(s)
    }

    /// 是否全為 ASCII 數字。
    private static func isAllDigits(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// 識別字合法字元：`[0-9A-Za-z-]`。
    private static func isValidIdentifierChars(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// 建構資訊合法性：以 `.` 分段，每段不可為空、字元同上。
    private static func isValidBuild(_ s: String) -> Bool {
        let ids = s.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !ids.isEmpty else { return false }
        return ids.allSatisfy { isValidIdentifierChars($0) }
    }

    // MARK: - Codable（以單一字串編解碼）

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let parsed = Self.parse(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "無效的語意化版本：\(raw)")
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    // MARK: - Comparable（建構資訊不參與比較）

    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch
            && lhs.prerelease == rhs.prerelease
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(major)
        hasher.combine(minor)
        hasher.combine(patch)
        hasher.combine(prerelease)
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // 無預發行版 > 有預發行版。
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return false
        case (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        // 逐段比較預發行版。
        let count = min(lhs.prerelease.count, rhs.prerelease.count)
        for i in 0..<count {
            let l = lhs.prerelease[i]
            let r = rhs.prerelease[i]
            if l == r { continue }
            // 純數字 < 字母數字。
            switch (l.isNumeric, r.isNumeric) {
            case (true, true):
                return l.numericValue! < r.numericValue!
            case (true, false):
                return true
            case (false, true):
                return false
            case (false, false):
                return l.description < r.description
            }
        }
        // 前綴相同時段數少者較小。
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
