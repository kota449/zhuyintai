// SPDX-License-Identifier: Apache-2.0
// TWKeyboard 自寫（不衍生自上游文字）。授權：本專案自己的。
//
// 這個檔案補的是「候選窗（Upstream/UI，MulanPSL-2.0）需要、但上游放在 LGPL 模組 `Shared`
// 裡」的符號。**刻意自寫而不是複製**：`Shared` 逐檔是 LGPL-3.0-or-later，本專案不引入。
// 每一個宣告都是從 Upstream/UI 的**呼叫點**反推的最小介面，沒有打開上游對應檔案抄。
//
// ⚠️ 這裡的「預設值」（字級、動畫…）是我們自己挑的暫定值，不是上游的預設；
// 哪些值該怎麼定是使用者的設計題，還沒定案。

import AppKit

// MARK: - 資料型別

/// 一個候選：`keyArray`＝該候選對應的讀音（注音）陣列，`value`＝要顯示／上屏的字詞。
/// 形狀由 Upstream/UI 的 `$0.value`／`$0.keyArray` 用法決定。
public typealias CandidateInState = (keyArray: [String], value: String)

/// 右鍵選單的三個動作（提高權重／降低權重／排除）。
/// **本專案目前不提供使用者詞庫調權**，所以 delegate 的 `isCandidateContextMenuEnabled`
/// 一律回 `false`，這三個 case 只是為了讓上游檢視碼能編譯。
public enum CandidateContextMenuAction {
    case toBoost
    case toNerf
    case toFilter
}

// MARK: - 候選窗 → 輸入法 的資料來源／回呼

/// 候選窗向「輸入法那一側」要資料、回報事件用的介面。
///
/// 成員逐一對應 `Upstream/UI/CtlCandidateGSI4AppKit.swift` 與 `VwrCandidateGSI4AppKit.swift`
/// 裡出現的 `delegate.<成員>`（共 20 個）。**哪些成員在 `ZhuyinEngine` 有對應、哪些是缺口**，
/// 見 spec 的「接線盤點」表。
@MainActor
public protocol CtlCandidateDelegate: AnyObject {
    // 顯示組態
    var isCandidateState: Bool { get }
    var isVerticalCandidateWindow: Bool { get }
    var isCandidateWindowSingleLine: Bool { get }
    var shouldAutoExpandCandidates: Bool { get }
    /// 選字鍵標籤，一字一鍵（例："123456"）。**同時決定一行最多幾個候選**（`selectionKeys.count`）。
    var selectionKeys: String { get }
    /// 字型 fallback 用的語系（"zh-Hant" 等）。
    var localeForFontFallbacks: String { get }
    /// 頂部 pane 顯示的「尚未組成的讀音」；nil＝不顯示。
    var unfinishedReading: String? { get }
    var showCodePointForCurrentCandidate: Bool { get }
    var isCandidateContextMenuEnabled: Bool { get }
    /// 目前輸入 app 的強調色；nil＝不跟隨。
    var clientAccentColor: HSBA? { get }

    // 資料
    func candidatePairs(conv: Bool) -> [CandidateInState]
    func getCandidate(at index: Int) -> CandidateInState?
    func candidateToolTip(shortened: Bool) -> String
    func reverseLookup(for text: String) -> [String?]
    func checkIsMacroTokenResult(_ index: Int) -> Bool

    // 定位：候選窗左上角該落在哪（螢幕座標），以及游標行高的修正量。
    func candidateWindowOriginInfo() -> (topLeft: CGPoint, heightDelta: Double)

    // 事件回報
    func candidatePairHighlightChanged(at index: Int?)
    func candidatePairSelectionConfirmed(at index: Int)
    func candidatePairContextMenuActionTriggered(at index: Int, action: CandidateContextMenuAction)
    func callError(_ message: String)
}

// MARK: - 輸入法 → 候選窗 的控制介面

/// 輸入法那一側要操作候選窗時用的介面。成員取自 `CtlCandidateGSI4AppKit` 的 public API。
@MainActor
public protocol CtlCandidateProtocol: AnyObject {
    init(_ layout: UILayoutOrientation)
    var currentLayout: UILayoutOrientation { get set }
    var delegate: CtlCandidateDelegate? { get set }
    var visible: Bool { get set }
    var highlightedIndex: Int { get set }
    func reloadData()
    @discardableResult func showNextPage() -> Bool
    @discardableResult func showPreviousPage() -> Bool
    @discardableResult func showNextLine() -> Bool
    @discardableResult func showPreviousLine() -> Bool
    @discardableResult func highlightNextCandidate() -> Bool
    @discardableResult func highlightPreviousCandidate() -> Bool
    /// 把「按下第 N 個選字鍵」轉成全域候選 index；超出本頁範圍回 nil。
    func candidateIndexAtKeyLabelIndex(_ id: Int) -> Int?
}

// MARK: - 偏好

/// 候選窗讀的偏好（只有它實際讀的 6 個）。
///
/// 上游的 `PrefMgr` 是 LGPL 模組 `Shared` 裡一個 500+ 行、綁 UserDefaults 的大物件；
/// 這裡只留一個純記憶體版。**日後要不要做成使用者可調（走 UserDefaults）是設計題。**
///
/// 刻意**不**標 `@MainActor`：上游 UI 碼（例如 `CandidateCellData4AppKit` 這個 struct）假設
/// 整個 module 預設 MainActor isolation，會在非隔離的 struct 成員裡直接讀這些偏好；
/// 而本 target 的 build settings 沒有 `SWIFT_DEFAULT_ACTOR_ISOLATION`（改它要動 pbxproj）。
/// 約定：**只在主執行緒寫入**（值都是純量／字串，讀取端不會撕裂）。
final class PrefMgr {
    static let sharedSansDidSetOps = PrefMgr()

    /// 候選字級（pt）。16 ＝ 威注音 4.7.4 現行值（`CandidateListTextSize=16`，2026-10-01 使用者
    /// 「選字框太大、比照威注音」；量自 `defaults read org.atelierInmu.inputmethod.vChewing`）。
    /// 09-21 至 09-30 是暫定的 18。
    var candidateListTextSize: Double = 16
    /// 候選字型名稱；空字串＝用系統字型。
    var candidateTextFontName: String = ""
    /// 橫排矩陣的最小格寬；0＝用預設。
    var minCellWidthForHorizontalMatrix: Int = 0
    /// 候選窗移動／出現的動畫。暫定關（先求穩，看手感再決定）。
    var enableCandidateWindowAnimation: Bool = false
    /// 是否跟隨輸入 app 的強調色。暫定關。
    var respectClientAccentColor: Bool = false
    /// 是否允許對「單字」候選做調權／排除。本專案沒有使用者詞庫調權 ⇒ 必須維持 false。
    var allowRescoringSingleKanjiCandidates: Bool = false

    private init() {}
}
