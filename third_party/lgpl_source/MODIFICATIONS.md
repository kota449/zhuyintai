# 對上游 Megrez 的修改 / Modifications to upstream Megrez

上游：https://github.com/vChewing/Megrez，比對基準 commit `5d41861779a3a3b87e962a2c82505f6e40972a44`（`Sources/Megrez/*.swift`）。
`megrez_upstream.patch`（unified diff，`patch -R -p1` 還原）在 10 個檔案中**只涉及下列 4 個**；其餘 6 個與上游位元組相同。
還原後的 sha256 與上游相符，可用 `tools/test_package_lgpl_source.sh`（在 TWKeyboard 的原始碼樹內）驗證，或自行 `shasum -a 256` 對下表。

| 檔案 | 與上游 | 修改摘要 |
|---|---|---|
| `0_Megrez.swift` | 相同 | — |
| `1_Compositor.swift` | **已修改** | ① 惰性組裝：新增 `assembledSentenceDirty` 標記與 `ensureAssembled()`，`assembledSentence` 的 getter 先確保已組裝；新增 `assemble()` 對外入口。② `dropKey()` 無條件標記 dirty（修復刪鍵後畫面殘留）。③ `assignNodes` 把索引鍵切片延後到真正要用才計算（效能）。④ `assembledSentenceDirty` 為 `public`（2026-10-03，為了編成獨立框架）。檔頭加「MODIFIED VERSION」註記 |
| `2_PathFinder.swift` | **已修改** | ① 路徑層語言模型重排：`Megrez.pathLMHook`（`PathLMHook`）、beam search、K-best 收集、`NBestCandidate`／`NBestRescoreOutcome` 與 n-best 重排回呼。預設關閉（hook 為 nil 時走原本的 DP）。② `NBestCandidate` 新增 `public init(pathScore:text:)`（2026-10-03，為了編成獨立框架）。③ 路徑層重排新增可選行為（2026-10-04，預設關閉）：對「讀音與查詢讀音不符」的候選，限制其語言模型加分不得高於節點內讀音相符者的最高值。④ 路徑層重排再新增可選行為（2026-10-07，預設關閉）：節點內讀音相符的候選，語言模型項改成同一個常數（使相符者這一側的最高總分不變），同音字之間不看語言模型、只看詞庫分數。檔頭加註記 |
| `3_KeyValuePaired.swift` | 相同 | — |
| `4_Segment.swift` | **已修改** | `insert` 的邊界處理：迴圈範圍 `0 ..< count` 改 `0 ... count`，並對空容器加防護。檔頭加註記 |
| `5_Node.swift` … `6_LangModel.swift` | 相同 | — |
| `7_Unigram.swift` | **已修改** | 單元圖新增一個可選欄位，保存候選「自己的讀音」（被改寫成查詢讀音前的原值）；不參與相等比較、雜湊與編碼。供上列路徑層重排判斷讀音是否相符（2026-10-04）。檔頭加註記 |
| `8_GramInPath.swift` … `9_SwiftImpl_Internals.swift` | 相同 | — |

## sha256（完整）

| 檔案 | 上游（5d418617） | 本包 |
|---|---|---|
| 0_Megrez.swift | `0c19cec4e370a9f76db495a6b1bf73034293ad1ebf011adc0d69dab8fcad9fe1` | `0c19cec4e370a9f76db495a6b1bf73034293ad1ebf011adc0d69dab8fcad9fe1` (相同) |
| 1_Compositor.swift | `f6a936d239ea4ff5333e954d6b8a72560fbe59cbfaf890e81670207e0f19c024` | `47983df00ed662022f35b6ee5345c64b2377125df432ed4bce8505b9c79a201b` |
| 2_PathFinder.swift | `92997e972458a2651603c113857c308c9084898c92f3ff4898762c6ced13bb8f` | `b2d33f8ea98e49294bbc5af715b3177d5f360f5d7aaaa1820c49f320196bc823` |
| 3_KeyValuePaired.swift | `71bf310709fa37d0c19b5cd635f6c7d69ee9a2c206adfcc5c7047d704743a5b7` | `71bf310709fa37d0c19b5cd635f6c7d69ee9a2c206adfcc5c7047d704743a5b7` (相同) |
| 4_Segment.swift | `c07f3f61a76edc7018e326c0a68f2b67b3683fc20f920455c97510846dceecb8` | `da9d5eb1417919e6c563681c9b0cdc696b7e6e9b26a26bf03beb620ebd36109b` |
| 5_Node.swift | `0b9725caed8611cf39008ec386abc7302a9ee7858424cf6f4997671d24eb2090` | `0b9725caed8611cf39008ec386abc7302a9ee7858424cf6f4997671d24eb2090` (相同) |
| 6_LangModel.swift | `713f9b8c8dbb1e8e2b7ec11ae70905e83ffeb82cd0fd4c9c691e1d73112c2c6d` | `713f9b8c8dbb1e8e2b7ec11ae70905e83ffeb82cd0fd4c9c691e1d73112c2c6d` (相同) |
| 7_Unigram.swift | `62c99b1975466b1421adb4366a2d6ebf46397f6174af734bf432583860d210f3` | `fc2807b74a85061d66af3c207efb16390fbcf8fc9fb11f30fe38117d57bd0e04` |
| 8_GramInPath.swift | `39ced69def01c59f27151d150025de25928f8b69ea557036338f93541dba2b9e` | `39ced69def01c59f27151d150025de25928f8b69ea557036338f93541dba2b9e` (相同) |
| 9_SwiftImpl_Internals.swift | `c437fa4c6cb46e8f69d72d15f5c609fd2374e545128bcf4e3c3111080d3beb3c` | `c437fa4c6cb46e8f69d72d15f5c609fd2374e545128bcf4e3c3111080d3beb3c` (相同) |

## KenLM

本包的 `Vendor/KenLMQuerySource/` 對上游 kpu/kenlm `4cb443e60b7bf2c0ddf3c745378f76cb59e254e5`：
**沒有修改任何上游檔案**；多出兩個我方檔案：`README.kenlm.md`（說明）、`util/usage_ios_stub.cc`（取代 `util/usage.cc`，把 `WallTime`／`CPUTime`／`RSSMax` 等回傳 0 的 stub）。
`Shared/KenLMQueryBridge.{h,mm}` 是我方寫的 ObjC 介面層。
