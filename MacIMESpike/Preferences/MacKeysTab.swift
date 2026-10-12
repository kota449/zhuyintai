// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// 「按鍵」分頁：刪除鍵設定與快捷鍵說明。說明會隨刪除鍵設定即時改變，所以放同一頁。
struct MacKeysTab: View {
    @AppStorage(MacTypingPreferences.backspaceRoleDefaultsKey)
    private var backspaceRoleRaw = MacBackspaceRole.wholeCharacter.rawValue
    @AppStorage(MacTypingPreferences.deleteForwardDoesTheOtherDefaultsKey)
    private var deleteForwardDoesTheOther = true

    private var shortcutRows: [(key: String, detail: String)] {
        MacShortcutHelp.rows(
            role: MacBackspaceRole.from(raw: backspaceRoleRaw),
            forwardDoesTheOther: deleteForwardDoesTheOther
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("⌫ 的作用", selection: $backspaceRoleRaw) {
                    ForEach(MacBackspaceRole.allCases) { role in
                        Text(role.label).tag(role.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                Toggle("fn＋⌫ 做另一種刪法", isOn: $deleteForwardDoesTheOther)
            } header: {
                Label("刪除鍵", systemImage: "delete.left")
            } footer: {
                Text("組字區是空的時候，fn＋⌫ 仍交給 App 往後刪。")
            }

            Section {
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 12) {
                    ForEach(shortcutRows, id: \.key) { row in
                        GridRow {
                            MacKeycaps(keys: row.key)
                            Text(row.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Label("快捷鍵", systemImage: "command")
            }
        }
        .formStyle(.grouped)
    }
}

/// 左欄的鍵帽。「fn＋⌫」拆成兩顆中間放 +；其他一個鍵一顆。
private struct MacKeycaps: View {
    let keys: String

    private var parts: [String] {
        keys.components(separatedBy: "＋")
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Text("+").foregroundStyle(.secondary)
                }
                Text(part)
                    .font(.system(.callout, design: .rounded).weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.replacingOccurrences(of: "＋", with: " 加 "))
    }
}
