// SPDX-License-Identifier: Apache-2.0
// 引擎全域旋鈕的窄介面（分數快取容量、單鍵同音字排序旗標）。公開版 no-op。

import Foundation

protocol MacEngineTuningProviding {
    /// 兩個分數快取的容量（每代筆數）。要在第一次使用前設定（呼叫時機維持 `MacIMEPerfTuning.apply()` 原位）。
    func setScoreCacheCapacities(kenLM: Int, neural: Int)
    /// 單鍵＋左文空時同音字改看詞庫排序：終端機宿主／全部宿主。
    var loneKeyHomophoneOrderTerminalHosts: Bool { get nonmutating set }
    var loneKeyHomophoneOrderAllHosts: Bool { get nonmutating set }
}

struct MacNoEngineTuning: MacEngineTuningProviding {
    func setScoreCacheCapacities(kenLM: Int, neural: Int) {}
    var loneKeyHomophoneOrderTerminalHosts: Bool { get { false } nonmutating set {} }
    var loneKeyHomophoneOrderAllHosts: Bool { get { false } nonmutating set {} }
}

enum MacEngineTuning {
    static var provider: any MacEngineTuningProviding = {
        #if TWK_CLOSED_CORE
        return TWKClosedCore.makeEngineTuning()
        #else
        return MacNoEngineTuning()
        #endif
    }()

    static func setScoreCacheCapacities(kenLM: Int, neural: Int) {
        provider.setScoreCacheCapacities(kenLM: kenLM, neural: neural)
    }

    static var loneKeyHomophoneOrderTerminalHosts: Bool {
        get { provider.loneKeyHomophoneOrderTerminalHosts }
        set { provider.loneKeyHomophoneOrderTerminalHosts = newValue }
    }

    static var loneKeyHomophoneOrderAllHosts: Bool {
        get { provider.loneKeyHomophoneOrderAllHosts }
        set { provider.loneKeyHomophoneOrderAllHosts = newValue }
    }
}
