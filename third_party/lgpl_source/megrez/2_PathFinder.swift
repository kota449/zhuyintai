// (c) 2022 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.
// ====================
// MODIFIED VERSION: this file differs from the upstream vChewing/Megrez file
// Sources/Megrez/2_PathFinder.swift at commit 5d41861779a3a3b87e962a2c82505f6e40972a44.
// Modified by the twkeyboard project (changes dated between 2026-08-07 and 2026-10-04).
// The list of changes and the unified diff against upstream are in MODIFICATIONS.md and
// megrez_upstream.patch at the root of the accompanying LGPL source package.

// MARK: - Megrez.PathFinder

extension Megrez {
  /// **path-level LM rescoring 掛勾（twkeyboard 專用，非上游 vChewing）**
  ///
  /// **為什麼需要**：原本的路徑分數是 `Σ log P(詞)`，**詞與詞之間零關係**。
  /// KenLM 雖然有接，但 `LMInstantiator.rerankByKenLM` 是**節點內**正規化
  /// （映射回該節點自己的 `[best-spread, best]`）⇒ 只能決定節點內誰排第一，
  /// **對路徑分數零影響、對斷詞零發言權**。
  /// 實測：`P(夜|花園)=-1.61` vs `P(業|花園)=-3.87`，KenLM 差 2.27 分偏好「夜市」，
  /// 引擎仍選「業/是」。離線探針（300 句、正對照 300/300）顯示把 LM 放進路徑分數後
  /// λ=0.3 得 **+6.7pp**（修 22 壞 2、McNemar p<0.0001）。
  ///
  /// ⚠️ **`pathLM == nil` 時走完全原本的 DP，逐行未動 ⇒ 預設零行為改變。**
  public struct PathLMHook {
    /// (左文, 候選字串) -> log10 條件機率；回 nil 表示該候選查不到
    public let score: (String, String) -> Double?
    /// λ：LM 與詞庫分數的插值權重（離線甜蜜點 0.3；W>1 會崩壞）
    public let weight: Double
    /// beam 寬度。DP 狀態必須帶「已產生的字串」（LM 需要左文）⇒ 狀態會爆炸，靠 beam 壓。
    public let beamWidth: Int
    /// 左文取尾端幾個字（與出貨 `kenLMContextWindowChars` 對齊）
    public let contextChars: Int
    /// 句首的外部左文（上一次上屏的尾巴）
    public let initialContext: String
    /// 讀音與使用者輸入**不符**的候選，λ 要乘上的倍率。
    ///
    /// - `1.0` ＝ **現行行為**（LM 對讀音不符的候選一樣有全額發言權）。**預設值。**
    /// - `0.0` ＝ 最嚴：讀音不符者拿不到任何 LM 加分，而且它的讀音罰**不再被 `(1−λ)` 稀釋**
    ///   （`(1−0)=1`，全額計入）。
    /// - 中間值 ＝ 旋鈕。階段二要放寬模糊音時**調這個值就好，不必改 code**。
    ///
    /// 🔴 **為什麼需要它**：讀音罰是候選生成時就寫進 `Unigram.score` 的
    /// （`LMInstantiator.rerankByReadingDistance`）⇒ 在 `(1−λ)·gram.score + λ·lm` 裡
    /// **被 `(1−λ)` 稀釋，而 LM 那一項沒有對應縮小**。λ=0.3 時讀音罰只剩 70%。
    ///
    /// 實測簽名（T2，2×2，n=1914）：λ 0.3→0.8 時，有 fuzzy 掉 **−10.71pp**（p=2e-30）、
    /// 無 fuzzy 只掉 −0.68pp（p=0.367）⇒ **交互作用 −10.03pp，崩壞的 93.7% 來自模糊音**。
    public let mismatchWeightScale: Double

    /// **「刪符號」類讀音不符候選的 LM 項上限**：`true` 時，節點內只要有讀音符合的候選，
    /// 「打的音節比候選原讀音多一個符號」的候選（例：打 ㄕㄥˋ 得到 ㄕˋ 的「是」），其 LM 項（`logP(字|左文)`）
    /// 不得高於符合者當中最高的那一個。其他種類的不符（換鍵、只差聲調、漏打符號＝候選比打的多一個符號）
    /// 是打錯音救回的主力（單音節 typo 語料 1511＋1257＋206 題），不受影響。
    /// 目的：LM 仍可在符合讀音的候選之間排序（同音字），但不能憑「左文裡的高頻字」把
    /// 打錯讀音的候選抬過打對的字（例：打 ㄕㄥˋ 變 ㄕˋ 的「是」）。
    /// `false` ＝ 現行行為（預設，出貨零改變）。
    /// 為何不用 `mismatchWeightScale`：LM 項是負的對數機率，縮小不符者的 λ 會讓它少吃扣分、
    /// 相對於仍吃滿 λ 的符合者反而占便宜（見 `PathLMMismatchLMCapTests`）。
    public let capMismatchedLM: Bool

    /// **同音字之間不看 LM**：`true` 時，節點內「讀音與打的讀音完全相同（含聲調）」的候選，
    /// LM 項改成同一個常數（選法使「符合者這一側的最高總分」與拉平前相同）⇒ 精確讀音的同音字彼此之間
    /// 由詞庫分數（＝候選窗的排序）決定，LM 不再能把其中一個翻到另一個上面。讀音不符的候選照舊用自己的
    /// LM 項，且它面對的符合者最高總分不變（打錯音救回與否不受影響）。
    /// 呼叫端（`ZhuyinEngine`）只在「組字剛好一個 key 且左文空」時打開：那時 LM 只剩 `logP(字 | <s>)`
    /// 句首先驗，對「使用者想要哪個同音字」沒有資訊，卻會把「嗎」（語助詞，幾乎不開句）壓到「媽」之下，
    /// 使組字顯示與候選窗第一名分岔（例：打單字「嗎」會出現「媽」）。
    /// `false` ＝ 現行行為（預設，出貨零改變）。
    public let flattenExactReadingLM: Bool

    /// 整句 N-mid 重排 closure，可選。`nil` ＝ 完全不掛
    /// （K-best 收集仍會做，但一律取第 0 條＝純 KenLM path score 排序，跟
    /// 單一 `best` 路徑選擇等價）。非 nil 時，呼叫端（`ZhuyinEngine`）
    /// 對 `kBest(...)` 產生的 K-best 候選做整句重打分並回傳勝者索引；
    /// `.skipped` 表示這次沒有真的重排（模型未載入／候選不足／推論失敗，
    /// 原因判斷與紀錄是呼叫端 C5 的責任，這裡只管「有沒有換」）。
    public var nbestRescorer: ((_ candidates: [NBestCandidate]) -> NBestRescoreOutcome)?

    public init(
      score: @escaping (String, String) -> Double?,
      weight: Double, beamWidth: Int = 8, contextChars: Int = 24, initialContext: String = "",
      mismatchWeightScale: Double = 1.0,
      capMismatchedLM: Bool = false,
      flattenExactReadingLM: Bool = false,
      nbestRescorer: ((_ candidates: [NBestCandidate]) -> NBestRescoreOutcome)? = nil
    ) {
      self.score = score
      self.weight = weight
      self.beamWidth = beamWidth
      self.contextChars = contextChars
      self.initialContext = initialContext
      self.mismatchWeightScale = mismatchWeightScale
      self.capMismatchedLM = capMismatchedLM
      self.flattenExactReadingLM = flattenExactReadingLM
      self.nbestRescorer = nbestRescorer
    }
  }

  /// K-best 候選給 `PathLMHook.nbestRescorer` 看的最小資訊——只給整句重排
  /// 決策需要的東西（路徑分數、組出的文字），不外洩內部 `Beam`/`GramInPath` 結構。
  public struct NBestCandidate {
    public let pathScore: Double
    public let text: String

    public init(pathScore: Double, text: String) {
      self.pathScore = pathScore
      self.text = text
    }
  }

  /// `nbestRescorer` 的回傳型別。
  public enum NBestRescoreOutcome {
    /// 選中 `candidates[winningIndex]`。`winningIndex` 超出範圍時，呼叫端一律
    /// 退回 `.skipped` 的行為（K-best 第 0 條）。
    case rescored(winningIndex: Int)
    /// 這次沒有重排（原因由呼叫端自行記錄），退回純 KenLM path score 排序。
    case skipped
  }

  /// nil ＝ 停用（出貨預設）。由 `ZhuyinEngine` 在 warmUp 時依 performance_config 決定是否掛上。
  public nonisolated(unsafe) static var pathLMHook: PathLMHook?

  final class PathFinder {
    /// 組句工具，會以 DAG 動態規劃演算法更新當前組字器的 assembledSentence。
    ///
    /// 該演算法使用動態規劃在有向無環圖中尋找具有最高分數的路徑，即最可能的字詞組合。
    /// DAG 演算法相對簡潔，記憶體使用量較少。
    @discardableResult
    init(config: CompositorConfig, assembledSentence: inout [Megrez.GramInPath]) {
      var newAssembledSentence = [Megrez.GramInPath]()
      defer { assembledSentence = newAssembledSentence }
      guard !config.segments.isEmpty else { return }

      // 掛勾存在 ⇒ 走 K-best 收集＋（可選）整句重排；否則走下面原本的純和 DP，逐行未動。
      if let hook = Megrez.pathLMHook {
        let candidates = Self.kBest(config: config, hook: hook)
        guard !candidates.isEmpty else { return }
        if let rescorer = hook.nbestRescorer {
          // 給 rescorer 看的文字只取組出的候選本身（不含 initialContext 上次上屏
          // 尾巴前綴）——語意對齊 Python `kenlm_beam_nbest`／C3 `SentenceScoreCoreMLScorer`
          // 的 R5 v1 慣例：context 固定空字串，重排器把每條 K-best 當獨立句子打分。
          let nbestCandidates = candidates.map {
            Megrez.NBestCandidate(pathScore: $0.score, text: $0.path.map(\.value).joined())
          }
          let outcome = rescorer(nbestCandidates)
          switch outcome {
          case .rescored(let idx) where candidates.indices.contains(idx):
            newAssembledSentence = candidates[idx].path
          default:
            newAssembledSentence = candidates[0].path
          }
        } else {
          newAssembledSentence = candidates[0].path
        }
        return
      }

      let keyCount = config.keys.count

      // 動態規劃陣列：dp[i] 表示到位置 i 的最佳分數
      var dp = [Double](repeating: Double(Int32.min), count: keyCount + 1)
      // 回溯陣列：parent[i] 記錄到達位置 i 的最佳前驅節點
      var parent = [Megrez.Node?](repeating: nil, count: keyCount + 1)

      // 起始狀態
      dp[0] = 0

      // DAG 動態規劃主循環
      for i in 0 ..< keyCount {
        guard dp[i] > Double(Int32.min) else { continue } // 只處理可達的位置

        // 遍歷從位置 i 開始的所有可能節點
        for (length, node) in config.segments[i] {
          guard !node.unigrams.isEmpty else { continue }

          let nextPos = i + length
          guard nextPos <= keyCount else { continue }

          let newScore = dp[i] + node.score

          // 如果找到更好的路徑，更新 dp 和 parent
          if newScore > dp[nextPos] {
            dp[nextPos] = newScore
            parent[nextPos] = node
          }
        }
      }

      // 回溯構建最佳路徑
      var currentPos = keyCount
      var reversedSentence = [Megrez.GramInPath]()

      // 從終點開始回溯
      while currentPos > 0 {
        guard let node = parent[currentPos] else { break }
        let insertable = Megrez.GramInPath(
          gram: node.currentUnigram,
          isExplicit: node.isExplicitlyOverridden
        )
        reversedSentence.append(insertable)
        currentPos -= node.keyArray.count
      }

      if !reversedSentence.isEmpty {
        newAssembledSentence = reversedSentence.reversed()
      }
    }

    // MARK: - path-level LM beam search／K-best 收集

    /// 路徑分數 ＝ `Σ [ (1-λ)·詞庫分數 + λ·logP(候選字串 | 左文) ]`（單一最佳路徑）。
    /// 向後相容封裝：等於 `kBest(config:hook:).first?.path ?? []`。既有呼叫點
    /// （`PathLMReadingMismatchTests`／`PathLMDegradedFallbackTests`）不需要改。
    static func beamSearch(
      config: Megrez.CompositorConfig, hook: Megrez.PathLMHook
    ) -> [Megrez.GramInPath] {
      kBest(config: config, hook: hook).first?.path ?? []
    }

    /// K-best 候選容器。
    struct Beam {
      var score: Double
      var text: String
      var path: [Megrez.GramInPath]
    }

    /// K-best 候選，語意對齊 Python `nbest_rescore.kenlm_beam_nbest`
    /// （`tools/neural_rescore/nbest_rescore.py:20-81`）：
    ///   - 同一個位置、組出的文字完全相同的路徑視為同一條，只留分數最高者
    ///     （不同切分產生相同字串不各算一條）。
    ///   - 每個位置（含最終位置 `keyCount`）先去重、再剪枝到 `hook.beamWidth` 條。
    ///   - 最終排序：分數降冪；同分時以組出的文字降冪排序（對齊 Python
    ///     `sorted(beams[n], reverse=True)` 對 `(score, text)` tuple 的預設比較）。
    ///
    /// override 鎖定：使用者覆寫過的節點，
    /// 字典分項改用 `node.score`（覆寫時＝ `overridingScore` 野獸常數 114514，
    /// 見 `5_Node.swift:74`／`115-122`）而不是 `gram.score`（候選自己的詞庫分）。
    /// 純 DP（本檔 `init`）本來就是靠 `node.score` 的野獸常數讓覆寫節點主宰整條
    /// 路徑；beam search 先前用 `gram.score`，繞過了這個機制，導致「繞過覆寫節點的
    /// 另一種切分」可能贏過覆寫路徑——**這個修法會改變已出貨的 `beamSearch` 單一
    /// 路徑選擇結果，跟重排開關無關**，需要回歸量測。
    ///
    /// ⚠️ **只改字典分項只保證 top-1 贏**：K-best 其餘條目仍可能是「繞過 override
    /// 節點的另一種切分」（規格必測①要求全部 K 條都含 override，見
    /// `PathFinderKBestTests.testOverrideSurvivesInEveryKBestCandidateEvenWithBypassSegmentation`——
    /// 只靠 `node.score` 過不了這條）。
    /// 因此額外加一層過濾：任何**非 override** 節點，若其 span `[pos, pos+length)`
    /// 與某個 override 節點的 span 重疊，直接排除、不展開。這不影響 top-1（野獸常數
    /// 已保證 top-1 走 override），只清掉 K-best 後段會繞過使用者手選的路徑——否則
    /// `nbestRescorer` 若選中那種候選，等於把同一個 bug 搬到重排層再犯一次。沒有任何
    /// override 時 `overriddenSpans` 為空，這層過濾完全 no-op（不影響現有行為，
    /// 既有測試與整句重播的 no-op 結論都靠這點成立）。
    static func kBest(
      config: Megrez.CompositorConfig, hook: Megrez.PathLMHook
    ) -> [Beam] {
      let keyCount = config.keys.count
      guard keyCount > 0 else { return [] }
      let lambda = min(max(hook.weight, 0), 1)
      // 讀音不符的候選要用的 λ 倍率。與 lambda 同樣夾在 [0,1]。
      // 1.0 ＝ 現行行為（預設）⇒ `lambdaEff == lambda` ⇒ 逐行等同改動前。
      let mismatchScale = min(max(hook.mismatchWeightScale, 0), 1)

      var overriddenSpans: [(start: Int, end: Int)] = []
      for pos in config.segments.indices {
        for (length, node) in config.segments[pos] where node.isOverridden {
          overriddenSpans.append((pos, pos + length))
        }
      }

      var frontier: [Int: [Beam]] = [
        0: [Beam(score: 0, text: hook.initialContext, path: [])],
      ]

      for pos in 0 ..< keyCount {
        guard let beams = frontier[pos], !beams.isEmpty else { continue }
        guard config.segments.indices.contains(pos) else { continue }
        for beam in beams {
          for (length, node) in config.segments[pos] {
            guard !node.unigrams.isEmpty else { continue }
            let nextPos = pos + length
            guard nextPos <= keyCount else { continue }
            if !node.isOverridden {
              let bypassesOverride = overriddenSpans.contains { span in
                pos < span.end && span.start < nextPos
              }
              guard !bypassesOverride else { continue }
            }
            // override 的節點不重選；其餘取節點內前 beamWidth 個候選
            let candidates: [Megrez.Unigram] = node.isOverridden
              ? [node.currentUnigram]
              : Array(node.unigrams.prefix(hook.beamWidth))
            // 先把這個節點每個候選的 LM 項算好（每個候選仍只查一次 KenLM，次數與改動前相同）。
            // 查不到給保守低分。**必須與字數成正比**：路徑分數是逐節點
            // 相加，固定 -8.0 會讓節點少（詞長）的路徑系統性少扣分 ⇒ 偏好長詞。
            // 乘上字數之後，任一條完整路徑的字數相同 ⇒ 這一項變成常數 ⇒ 不影響排序。
            // （主要防線是上游不掛 hook，見 `ZhuyinEngine.applyPathLevelLMHook`；
            //   這裡防的是 scorer 活著但個別候選查不到的殘餘情形。）
            let ctx = String(beam.text.suffix(hook.contextChars))
            var lmTerms: [Double] = candidates.map { hook.score(ctx, $0.value) ?? (-8.0 * Double($0.value.count)) }
            // `capMismatchedLM`：節點內讀音符合者的 LM 項最高值，當作讀音不符者的 LM 項上限。
            // override 節點不套（手選的字一律視為符合）；節點內沒有任何符合者時沒有東西可保護 ⇒ nil。
            // 讀音是否符合：與下面的 `readingMatches` 共用同一份判定（用候選的**原讀音**，見 `isReadingCompatible`）。
            let matchFlags: [Bool] = candidates.map {
              node.isOverridden
                || Self.isReadingCompatible(typed: node.keyArray, native: $0.nativeKeyArray ?? $0.keyArray)
            }
            // 上限只對「刪符號」類候選生效（打的音節比候選的原讀音多一個符號）：
            // 使用者得多按一個符號才會變成它，而打的音節本身就是完整合法音節。
            // 換鍵、只差聲調、漏打符號（候選比打的多一個符號）是打錯音救回的主力，不在此限。
            let capTargets: [Bool] = candidates.enumerated().map { i, g in
              hook.capMismatchedLM && !matchFlags[i]
                && Self.isSymbolDeletionVariant(typed: node.keyArray, native: g.nativeKeyArray ?? g.keyArray)
            }
            var exactBestLM: Double?
            if capTargets.contains(true) {
              for i in candidates.indices where matchFlags[i] {
                exactBestLM = max(exactBestLM ?? -.infinity, lmTerms[i])
              }
            }
            // 同音字之間不看 LM（見 `PathLMHook.flattenExactReadingLM`）。放在 `exactBestLM` 之後：
            // 刪符號上限讀的是拉平**之前**的符合者最高 LM 項，語意不變。
            // 做法：讀音完全相符者的 LM 項改成同一個常數 L*，選 L* 使「符合者這一側的最高總分」與拉平前相同、
            // 而符合者之間只剩詞庫分數的先後：
            //   T = max_i∈符合 [(1-λ)·d_i + λ·lm_i]（拉平前）；d* = max_i∈符合 d_i；L* = (T - (1-λ)·d*) / λ。
            // 於是詞庫分數最高的符合者總分＝T，其餘依詞庫分數差往下；讀音不符者（打錯音救回）面對的
            // 「符合者最高總分」不變 ⇒ 救回與否的判斷與拉平前一樣，不會被反壓回精確讀音。
            // （只拉到「最高 LM 值」會把符合者最高總分抬高，普查實測 38 組原本由 LM 救回的字被壓回精確讀音，已改掉。）
            // override 節點只有一個候選，T＝它自己的總分、L*＝它自己的 LM 項，是 no-op。
            if hook.flattenExactReadingLM, lambda > 0 {
              // 「完全相符」＝候選原讀音與打的讀音陣列逐位相同。**不能用 `matchFlags`**：沒打聲調的音節，
              // 只差聲調的候選也算「符合」（漏打聲調會展開成各聲調），用它會把 ㄨㄛ 的「我」（ㄨㄛˇ）
              // 跟「窩」（ㄨㄛ）併成同一組、改由詞庫分數決定 ⇒ 我→窩（普查實測，字頻 3417 vs 60）。
              let exactIdx = candidates.indices.filter {
                node.isOverridden || (candidates[$0].nativeKeyArray ?? candidates[$0].keyArray) == node.keyArray
              }
              if exactIdx.count > 1 {
                func dict(_ i: Int) -> Double { node.isOverridden ? node.score : candidates[i].score }
                let tMax = exactIdx.map { (1 - lambda) * dict($0) + lambda * lmTerms[$0] }.max() ?? 0
                let dBest = exactIdx.map(dict).max() ?? 0
                let flat = (tMax - (1 - lambda) * dBest) / lambda
                // 詞庫分數同分時，順序交給候選順序（`candidates` 就是候選窗的順序）：每往後一個差 1e-9，
                // 遠小於任何真實分差（分數只有 6 位小數），只用來讓同分者的先後與候選窗一致，
                // 而不是落到 K-best 的「同分取文字降冪」（普查：ㄗㄨㄢˋ 賺 vs 鑽 同分，原本由 LM 決定）。
                for i in exactIdx { lmTerms[i] = flat - 1e-9 * Double(i) }
              }
            }
            for (gramIndex, gram) in candidates.enumerated() {
              // 讀音符不符 —— `node.keyArray` 是**使用者實際打的鍵**，
              // `gram.keyArray` 是**候選自己的讀音**（模糊候選帶的是它自己的音）。
              //
              // ⚠️ **override 的節點一律視為符合**：使用者手選過的字，讀音本來就可能與
              // 輸入不同（那正是他的意思）；因為讀音不符就砍它的 LM 分數，
              // 等於懲罰使用者自己的選擇。
              let readingMatches = matchFlags[gramIndex]
              let lambdaEff = readingMatches ? lambda : lambda * mismatchScale
              var lm = lmTerms[gramIndex]
              if let exactBestLM, capTargets[gramIndex] { lm = min(lm, exactBestLM) }
              let dictScore = node.isOverridden ? node.score : gram.score
              let newScore = beam.score + (1 - lambdaEff) * dictScore + lambdaEff * lm
              var nextPath = beam.path
              nextPath.append(.init(gram: gram, isExplicit: node.isExplicitlyOverridden))
              let nb = Beam(score: newScore, text: beam.text + gram.value, path: nextPath)
              frontier[nextPos, default: []].append(nb)
            }
          }
        }
        for key in frontier.keys where key > pos {
          frontier[key] = Self.dedupAndCap(frontier[key]!, beamWidth: hook.beamWidth)
        }
      }

      let finalBeams = frontier[keyCount] ?? []
      return finalBeams.sorted { lhs, rhs in
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.text > rhs.text
      }
    }

    private static let toneMarks: Set<Character> = ["ˊ", "ˇ", "ˋ", "˙"]

    /// 候選自己的讀音 `native` 相對於使用者打的 `typed`，算不算「符合」。
    ///
    /// 🔴 **必須用候選的原讀音（`Unigram.nativeKeyArray`），不能比 `gram.keyArray`**：
    /// `Compositor.getSortedUnigrams` 已把所有 keyArray≠查詢 key 的 unigram 改寫成查詢 key，
    /// 比 `gram.keyArray == node.keyArray` 在真引擎上恆為 true（`mismatchWeightScale` 因此是死碼）。
    ///
    /// 省略聲調的例外：使用者打的音節**沒有聲調符號**時，只差聲調的候選與打的讀音同等地位
    /// （漏打聲調本來就會展開成各聲調），不算不符。打了明確聲調卻拿到只差聲調的字（例：打 ㄕㄥˋ 得到 ㄕㄥ 的「生」）才算不符。
    static func isReadingCompatible(typed: [String], native: [String]) -> Bool {
      if typed == native { return true }
      guard typed.count == native.count else { return false }
      for (t, n) in zip(typed, native) {
        if t == n { continue }
        let typedHasTone = t.contains { toneMarks.contains($0) }
        guard !typedHasTone else { return false }
        if n.filter({ !toneMarks.contains($0) }) != t { return false }
      }
      return true
    }

    /// 候選的原讀音 `native` 是不是「打的 `typed` 少一個符號」（聲調符號不算符號；只差聲調的音節不算刪除）。
    /// 例：打 ㄕㄥˋ → 候選 ㄕˋ（少 ㄥ）。多音節節點：至少一個音節是刪除，其餘音節相同或只差聲調。
    static func isSymbolDeletionVariant(typed: [String], native: [String]) -> Bool {
      guard typed.count == native.count else { return false }
      var sawDeletion = false
      for (t, n) in zip(typed, native) {
        if t == n { continue }
        let ts = Array(t.filter { !toneMarks.contains($0) })
        let ns = String(n.filter { !toneMarks.contains($0) })
        if String(ts) == ns { continue }  // 只差聲調
        guard ns.count == ts.count - 1,
          ts.indices.contains(where: { i in
            var rest = ts
            rest.remove(at: i)
            return String(rest) == ns
          })
        else { return false }
        sawDeletion = true
      }
      return sawDeletion
    }

    /// 對齊 Python 兩段式剪枝：①同字串只留分數最高者（穩定排序保留第一次出現
    /// 順序，對齊 Python dict 插入序）②依分數排序取前 `beamWidth`。
    private static func dedupAndCap(_ beams: [Beam], beamWidth: Int) -> [Beam] {
      var bestPerText: [String: Beam] = [:]
      var order: [String] = []
      for beam in beams {
        if let existing = bestPerText[beam.text] {
          if beam.score > existing.score { bestPerText[beam.text] = beam }
        } else {
          bestPerText[beam.text] = beam
          order.append(beam.text)
        }
      }
      let deduped = order.map { bestPerText[$0]! }
      let ranked = deduped.enumerated().sorted { lhs, rhs in
        if lhs.element.score != rhs.element.score { return lhs.element.score > rhs.element.score }
        return lhs.offset < rhs.offset
      }.map(\.element)
      return Array(ranked.prefix(beamWidth))
    }
  }
}
