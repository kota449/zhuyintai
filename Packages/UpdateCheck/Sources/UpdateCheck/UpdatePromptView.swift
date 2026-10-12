// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import AppKit

/// 開啟瀏覽器的抽象層（正式用 `NSWorkspace`，測試用假 opener）。
public protocol URLOpener: Sendable {
    /// 開啟指定網址（例如「前往下載」按鈕）。
    @MainActor func open(_ url: URL)
}

/// 以 `NSWorkspace.open` 開啟瀏覽器的正式實作。
public struct NSWorkspaceURLOpener: URLOpener, Sendable {
    /// 建立 opener。
    public init() {}
    @MainActor public func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

/// 更新提示視窗（SwiftUI）。
///
/// 顯示新版版本號、發布日期、更新說明，並提供三個按鈕：
/// 「前往下載」「略過這個版本」「稍後提醒」。
/// 支援深淺色（系統色彩）與系統材質（`.regularMaterial` 背景）。
///
/// - 執行緒假設：必須在 MainActor 使用（SwiftUI View）。
@MainActor
public struct UpdatePromptView: View {
    private let release: Release
    private let opener: any URLOpener
    private let onSkip: () -> Void
    private let onLater: () -> Void

    /// 建立提示視窗。
    /// - Parameters:
    ///   - release: `UpdateChecker` 回傳的可用更新。
    ///   - opener: 開啟瀏覽器的抽象（預設 `NSWorkspaceURLOpener`）。
    ///   - onSkip: 按下「略過這個版本」時的回呼（呼叫方應呼叫 `checker.skip(version:)`）。
    ///   - onLater: 按下「稍後提醒」時的回呼（僅關閉視窗）。
    public init(
        release: Release,
        opener: any URLOpener = NSWorkspaceURLOpener(),
        onSkip: @escaping () -> Void = {},
        onLater: @escaping () -> Void = {}
    ) {
        self.release = release
        self.opener = opener
        self.onSkip = onSkip
        self.onLater = onLater
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 標題列：圖示＋版本號（含重大更新標籤）。
            HStack(spacing: 10) {
                Image(systemName: release.critical ? "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90" : "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(release.critical ? .red : .accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("發現新版本 \(release.version)")
                        .font(.headline)
                    if let date = release.publishedAt {
                        Text("發布於 \(date, format: .dateTime.year().month().day())")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if release.critical {
                    Text("重大更新")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.red.opacity(0.15), in: Capsule())
                        .foregroundStyle(.red)
                }
            }

            // 更新說明（可捲動，避免過長說明撐爆版面）。
            if let notes = release.notes, !notes.isEmpty {
                ScrollView {
                    Text(notes)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            } else {
                Text("建議前往下載頁查看更新內容。")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            // 三個按鈕。
            HStack(spacing: 8) {
                Button("前往下載") {
                    opener.open(release.downloadURL)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                Button("略過這個版本") {
                    onSkip()
                }
                .buttonStyle(.bordered)

                Button("稍後提醒") {
                    onLater()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 360, maxWidth: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

#Preview {
    UpdatePromptView(
        release: Release(
            version: "0.1.0-beta.2",
            build: 12,
            minimumMacOS: "14.0",
            publishedAt: Date(),
            downloadURL: URL(string: "https://example.com/ZhuyinTai-0.1.0-beta.2.pkg")!,
            notes: "修正注音輸入問題並提升穩定性。",
            critical: false
        )
    )
    .padding()
}
