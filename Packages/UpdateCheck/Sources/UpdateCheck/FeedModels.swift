// SPDX-License-Identifier: Apache-2.0
import Foundation

/// 版本資訊 feed 的根物件（Codable）。
///
/// 對應 `Examples/feed.json` 的 JSON 結構。
public struct UpdateFeed: Sendable, Hashable, Codable {
    /// 結構描述版本（目前為 1）。
    public var schemaVersion: Int
    /// 所有已發布版本（未排序；由 `UpdateChecker` 挑選）。
    public var releases: [Release]

    /// 建立 feed。
    public init(schemaVersion: Int, releases: [Release]) {
        self.schemaVersion = schemaVersion
        self.releases = releases
    }
}

/// 單一發布版本。
public struct Release: Sendable, Hashable, Codable, Identifiable {
    /// 以版本字串作為識別（例如 `0.1.0-beta.2`）。
    public var id: String { version }

    /// 版本字串（SemVer 2.0）。
    public var version: String
    /// 組建編號（僅供顯示參考，不參與新舊比較）。
    public var build: Int?
    /// 可安裝的最低 macOS 版本（例如 `14.0`），缺省表示無限制。
    public var minimumMacOS: String?
    /// 發布時間。
    public var publishedAt: Date?
    /// 下載連結（只接受 `https`，其餘會被 `UpdateChecker` 拒絕）。
    public var downloadURL: URL
    /// 更新說明（顯示於提示視窗）。
    public var notes: String?
    /// 是否為重大更新（無視「略過這個版本」）。
    public var critical: Bool

    enum CodingKeys: String, CodingKey {
        case version, build, minimumMacOS, publishedAt, downloadURL, notes, critical
    }

    /// 建立單一發布版本。
    public init(
        version: String,
        build: Int? = nil,
        minimumMacOS: String? = nil,
        publishedAt: Date? = nil,
        downloadURL: URL,
        notes: String? = nil,
        critical: Bool = false
    ) {
        self.version = version
        self.build = build
        self.minimumMacOS = minimumMacOS
        self.publishedAt = publishedAt
        self.downloadURL = downloadURL
        self.notes = notes
        self.critical = critical
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        build = try c.decodeIfPresent(Int.self, forKey: .build)
        minimumMacOS = try c.decodeIfPresent(String.self, forKey: .minimumMacOS)
        // 發布時間接受 ISO 8601（例如 `2026-10-20T10:00:00+08:00`）。
        if let raw = try c.decodeIfPresent(String.self, forKey: .publishedAt) {
            publishedAt = Self.parseISO8601(raw)
        } else {
            publishedAt = nil
        }
        downloadURL = try c.decode(URL.self, forKey: .downloadURL)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        critical = try c.decodeIfPresent(Bool.self, forKey: .critical) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encodeIfPresent(build, forKey: .build)
        try c.encodeIfPresent(minimumMacOS, forKey: .minimumMacOS)
        if let publishedAt {
            try c.encode(Self.formatISO8601(publishedAt), forKey: .publishedAt)
        }
        try c.encode(downloadURL, forKey: .downloadURL)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encode(critical, forKey: .critical)
    }

    /// 解析 ISO 8601 時間（含時區，每次新建 formatter 以避開共享可變狀態）。
    private static func parseISO8601(_ raw: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: raw)
    }

    /// 格式化為 ISO 8601 字串。
    private static func formatISO8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// 解析後的語意化版本（壞字串回 `nil`，呼叫方應跳過該筆）。
    public var semanticVersion: SemanticVersion? {
        SemanticVersion(version)
    }
}
