// SPDX-License-Identifier: Apache-2.0
/// 注音符號列舉與分類
public enum BopomofoSymbol: String, CaseIterable, Equatable {
    // 聲母 (Initials) — 21 個
    case b = "ㄅ", p = "ㄆ", m = "ㄇ", f = "ㄈ"
    case d = "ㄉ", t = "ㄊ", n = "ㄋ", l = "ㄌ"
    case g = "ㄍ", k = "ㄎ", h = "ㄏ"
    case j = "ㄐ", q = "ㄑ", x = "ㄒ"
    case zh = "ㄓ", ch = "ㄔ", sh = "ㄕ", r = "ㄖ"
    case z = "ㄗ", c = "ㄘ", s = "ㄙ"

    // 介音 (Medials) — 3 個
    case i = "ㄧ", u = "ㄨ", yu = "ㄩ"

    // 韻母 (Finals) — 13 個
    case a = "ㄚ", o = "ㄛ", e = "ㄜ", eh = "ㄝ"
    case ai = "ㄞ", ei = "ㄟ", ao = "ㄠ", ou = "ㄡ"
    case an = "ㄢ", en = "ㄣ", ang = "ㄤ", eng = "ㄥ", er = "ㄦ"

    // 聲調 (Tones) — 5 個
    case tone1 = "ˉ"  // 一聲（有時省略）
    case tone2 = "ˊ"  // 二聲
    case tone3 = "ˇ"  // 三聲
    case tone4 = "ˋ"  // 四聲
    case tone5 = "˙"  // 輕聲

    public var isInitial: Bool {
        switch self {
        case .b, .p, .m, .f, .d, .t, .n, .l,
             .g, .k, .h, .j, .q, .x,
             .zh, .ch, .sh, .r, .z, .c, .s:
            return true
        default:
            return false
        }
    }

    public var isMedial: Bool {
        switch self {
        case .i, .u, .yu: return true
        default: return false
        }
    }

    public var isFinal: Bool {
        switch self {
        case .a, .o, .e, .eh, .ai, .ei, .ao, .ou,
             .an, .en, .ang, .eng, .er:
            return true
        default:
            return false
        }
    }

    public var isTone: Bool {
        switch self {
        case .tone1, .tone2, .tone3, .tone4, .tone5: return true
        default: return false
        }
    }

    /// 從 Character 轉換，找不到返回 nil
    public static func from(_ char: Character) -> BopomofoSymbol? {
        return BopomofoSymbol(rawValue: String(char))
    }

    /// 將字串轉換為符號序列（忽略無法識別的字元）
    public static func parse(_ input: String) -> [BopomofoSymbol] {
        return input.compactMap { BopomofoSymbol.from($0) }
    }
}
