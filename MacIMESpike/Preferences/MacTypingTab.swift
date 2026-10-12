// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// 「輸入」分頁：候選字與選字。只讀寫 `@AppStorage`，key 與預設值與改版前相同。
struct MacTypingTab: View {
    @AppStorage(MacGeneralPreferences.candidateTextSizeKey)
    private var candidateTextSizeRaw = MacGeneralPreferences.CandidateTextSize.medium.rawValue
    @AppStorage(MacReadingPanelPreference.defaultsKey)
    private var showReadingPanel = true
    @AppStorage(MacTypingPreferences.selectionKeysDefaultsKey)
    private var selectionKeysRaw = MacSelectionKeyChoice.digits.rawValue
    @AppStorage(MacTypingPreferences.cursorAfterSelectionDefaultsKey)
    private var cursorAfterSelectionRaw = MacCursorAfterSelection.afterWord.rawValue
    @AppStorage(MacTypingPreferences.unfinishedZhuyinDefaultsKey)
    private var unfinishedZhuyinRaw = MacUnfinishedZhuyinPolicy.keep.rawValue
    @AppStorage(MacTypingPreferences.shiftTapSwitchesToEnglishDefaultsKey)
    private var shiftTapSwitchesToEnglish = true
    @AppStorage(MacChoiceLearning.enabledDefaultsKey)
    private var choiceLearningEnabled = true

    var body: some View {
        Form {
            Section {
                Picker("候選字大小", selection: $candidateTextSizeRaw) {
                    ForEach(MacGeneralPreferences.CandidateTextSize.allCases) { size in
                        Text(size.label).tag(size.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("顯示注音浮窗", isOn: $showReadingPanel)
            } header: {
                Label("候選字", systemImage: "character.cursor.ibeam")
            } footer: {
                Text("打字時在游標下方顯示前三個字的注音，方便看出有沒有拼錯。")
            }

            Section {
                Picker("選字鍵", selection: $selectionKeysRaw) {
                    ForEach(MacSelectionKeyChoice.allCases) { choice in
                        Text(choice.label).tag(choice.rawValue)
                    }
                }
                Picker("選字後游標", selection: $cursorAfterSelectionRaw) {
                    ForEach(MacCursorAfterSelection.allCases) { placement in
                        Text(placement.label).tag(placement.rawValue)
                    }
                }
            } header: {
                Label("選字", systemImage: "list.bullet")
            }

            if MacChoiceLearning.isAvailable {
                Section {
                    Toggle("記住我的選字", isOn: $choiceLearningEnabled)
                } header: {
                    Label("學習", systemImage: "brain")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("你選過的字，下次同樣的前文與讀音會優先給。只存在這台電腦，不會上傳。")
                        Text("變更會在下次切換輸入框時生效。")
                    }
                }
            }

            Section {
                Picker("沒拼完的注音", selection: $unfinishedZhuyinRaw) {
                    ForEach(MacUnfinishedZhuyinPolicy.allCases) { policy in
                        Text(policy.label).tag(policy.rawValue)
                    }
                }
            } header: {
                Label("送出時", systemImage: "paperplane")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("按 Enter、切到英文或切換 App 時，最後一段還沒拼成字的注音（例如只打了ㄒ）要怎麼處理。")
                    Text("拼得成字的音節（例如ㄓ）不受影響；用滑鼠點別處時一律保留。")
                }
            }

            Section {
                Toggle("單押 Shift 切換中／英", isOn: $shiftTapSwitchesToEnglish)
            } header: {
                Label("中英切換", systemImage: "globe")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("只按一下 Shift 就在中文和英文之間切換；按住一段時間再放開也會切換。")
                    Text("切到英文後，所有按鍵都交給 App。Shift 加字母（打大寫）不會切換；Caps Lock 仍由系統設定決定。")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            MacGeneralPreferences.applySavedCandidateTextSize()
        }
        .onChange(of: candidateTextSizeRaw) { _, newValue in
            MacGeneralPreferences.applyCandidateTextSize(
                MacGeneralPreferences.CandidateTextSize.from(raw: newValue),
                reloadIfVisible: true
            )
        }
    }
}
