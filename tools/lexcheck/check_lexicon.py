#!/usr/bin/env python3
"""Lexicon contribution checker (lexcheck).

Only Python 3 standard library.
See README.md for usage and the list of known limits.
"""

import argparse
import json
import os
import re
import sys

PROG = "check_lexicon.py"

# --- Bopomofo sets ---

INITIALS = frozenset(list("ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙ"))
MEDIALS = frozenset(list("ㄧㄨㄩ"))
SINGLE_FINALS = frozenset(list("ㄚㄛㄜㄝㄞㄟㄠㄡㄢㄣㄤㄥㄦ"))
COMBINED_FINALS = frozenset([
    "ㄧㄚ", "ㄧㄛ", "ㄧㄝ", "ㄧㄞ", "ㄧㄠ", "ㄧㄡ", "ㄧㄢ", "ㄧㄣ", "ㄧㄤ", "ㄧㄥ",
    "ㄨㄚ", "ㄨㄛ", "ㄨㄞ", "ㄨㄟ", "ㄨㄢ", "ㄨㄣ", "ㄨㄤ", "ㄨㄥ",
    "ㄩㄝ", "ㄩㄢ", "ㄩㄣ", "ㄩㄥ",
])
# Standalone medials can act as rhymes with zero initial (e.g. ㄧ衣, ㄨ污, ㄩ淤).
STANDALONE_MEDIAL_RHYMES = frozenset(["ㄧ", "ㄨ", "ㄩ"])
ALLOWED_RHYMES = frozenset(
    set(SINGLE_FINALS) | set(STANDALONE_MEDIAL_RHYMES) | set(COMBINED_FINALS)
)
ALL_BOPOMOFO = frozenset(
    set(INITIALS) | set(MEDIALS) | set(SINGLE_FINALS) | set(["ㄭ"])
)

TONE_AFTER = frozenset(list("ˊˇˋ"))
NEUTRAL_MARK = "˙"
# Seven initials that may stand alone as a syllable (empty rhyme, ㄭ omitted).
EMPTY_RHYME_INITIALS = frozenset(list("ㄓㄔㄕㄖㄗㄘㄙ"))
# Initials that require a fine (齊齒/撮口) rhyme containing ㄧ or ㄩ.
JI_QI_XI = frozenset(list("ㄐㄑㄒ"))
# Initials that must not combine with ㄧ/ㄩ rhymes (open or ㄨ-only).
NO_I_U_INITIALS = frozenset(list("ㄓㄔㄕㄖㄗㄘㄙ"))

ASCII_ALNUM_RE = re.compile(r"[A-Za-z0-9]")
WHITESPACE_RE = re.compile(r"\s")

# --- Simplified -> Traditional table (100 common pairs; warning only) ---
# Keys are simplified characters that trigger W002; values are the
# corresponding traditional forms for the warning message.
SIMPLIFIED_TO_TRADITIONAL = {
    "万": "萬", "与": "與", "专": "專", "业": "業", "丛": "叢",
    "东": "東", "丝": "絲", "丢": "丟", "两": "兩", "严": "嚴",
    "丧": "喪", "个": "個", "丰": "豐", "临": "臨", "丽": "麗",
    "举": "舉", "义": "義", "习": "習", "乡": "鄉", "书": "書",
    "买": "買", "乱": "亂", "争": "爭", "亚": "亞", "产": "產",
    "亲": "親", "亿": "億", "仅": "僅", "从": "從", "仓": "倉",
    "仪": "儀", "们": "們", "优": "優", "会": "會", "传": "傳",
    "伤": "傷", "体": "體", "余": "餘", "补": "補", "蚕": "蠶",
    "层": "層", "厂": "廠", "彻": "徹", "尘": "塵", "迟": "遲",
    "冲": "衝", "丑": "醜", "处": "處", "触": "觸", "辞": "辭",
    "聪": "聰", "达": "達", "带": "帶", "单": "單", "当": "當",
    "党": "黨", "导": "導", "灯": "燈", "邓": "鄧", "敌": "敵",
    "递": "遞", "点": "點", "电": "電", "读": "讀", "对": "對",
    "队": "隊", "吨": "噸", "夺": "奪", "儿": "兒", "发": "發",
    "罚": "罰", "饭": "飯", "范": "範", "飞": "飛", "奋": "奮",
    "粪": "糞", "凤": "鳳", "肤": "膚", "妇": "婦", "复": "復",
    "盖": "蓋", "赶": "趕", "巩": "鞏", "沟": "溝", "构": "構",
    "购": "購", "谷": "穀", "顾": "顧", "关": "關", "观": "觀",
    "柜": "櫃", "汉": "漢", "号": "號", "后": "後", "护": "護",
    "华": "華", "画": "畫", "汇": "匯", "获": "獲", "饥": "飢",
}


def is_url(text):
    """Return True if text looks like an http(s) URL."""
    s = text.strip()
    if WHITESPACE_RE.search(s):
        return False
    if s.startswith("http://") or s.startswith("https://"):
        rest = s.split("://", 1)[1]
        if not rest:
            return False
        host = rest.split("/", 1)[0]
        # Host must contain a dot and no spaces; allow port.
        if "." not in host:
            return False
        if len(host) < 3:
            return False
        return True
    return False


def normalize_syllable(syllable):
    """Move a leading neutral mark to the back: ˙ㄉㄜ -> ㄉㄜ˙.

    Data and engine write the neutral tone after the syllable (ㄉㄜ˙); the
    leading form (˙ㄉㄜ) is accepted as input and normalized to it. Anything
    that is not exactly "one leading ˙ and no other ˙" is returned unchanged so
    the validator can report it.
    """
    if (len(syllable) > 1 and syllable[0] == NEUTRAL_MARK
            and NEUTRAL_MARK not in syllable[1:]):
        return syllable[1:] + NEUTRAL_MARK
    return syllable


def normalize_reading(reading):
    """Normalize every syllable of a '-'-joined reading."""
    return "-".join(normalize_syllable(p) for p in reading.split("-"))


def is_valid_syllable(syllable):
    """Return True if a single bopomofo syllable is legal.

    Rules:
    - neutral tone ˙ may be written before or after the syllable (˙ㄉㄜ or
      ㄉㄜ˙); only one ˙, and no other tone mark with it
    - otherwise optional single trailing ˊ/ˇ/ˋ (must be last)
    - first tone unmarked; ˉ is not accepted
    - body must be initial(+rhyme), bare rhyme, or lone ㄓㄔㄕㄖㄗㄘㄙ
    - rhyme must be one of the 13 singles, ㄧ/ㄨ/ㄩ alone, or 22 combos
    - ㄐㄑㄒ must pair with a rhyme containing ㄧ/ㄩ
    - ㄓㄔㄕㄖㄗㄘㄙ must not pair with a rhyme containing ㄧ/ㄩ
    - initial + ㄦ is rejected (ㄦ is zero-initial only)
    - ㄭ is never accepted (the empty rhyme is left unwritten)
    """
    if not syllable:
        return False
    # Internally the neutral tone is always trailing.
    syllable = normalize_syllable(syllable)
    if NEUTRAL_MARK in syllable:
        # Exactly one ˙, at the end, and no other tone mark.
        if syllable.count(NEUTRAL_MARK) != 1 or syllable[-1] != NEUTRAL_MARK:
            return False
        body = syllable[:-1]
        for ch in body:
            if ch in TONE_AFTER:
                return False
        if not body:
            return False
    else:
        tones = [ch for ch in syllable if ch in TONE_AFTER]
        if len(tones) > 1:
            return False
        if tones:
            if syllable[-1] not in TONE_AFTER:
                return False
            body = syllable[:-1]
        else:
            body = syllable
        if not body:
            return False
    # ˉ (first-tone mark sometimes seen) is not accepted: first tone unmarked.
    if "ˉ" in body or "¯" in body:
        return False
    # Body must consist solely of bopomofo letters (ㄭ excluded -> invalid).
    for ch in body:
        if ch == "ㄭ":
            return False
        if ch not in ALL_BOPOMOFO:
            return False
    # Lone empty-rhyme syllable.
    if body in EMPTY_RHYME_INITIALS:
        return True
    initial = None
    rhyme = body
    if body and body[0] in INITIALS:
        # If body is a single initial not in the empty-rhyme set, invalid.
        if len(body) == 1:
            return False
        initial = body[0]
        rhyme = body[1:]
        if not rhyme:
            return False
    # Rhyme must be in the allowlist.
    if rhyme not in ALLOWED_RHYMES:
        return False
    # ㄦ only stands alone (zero initial).
    if rhyme == "ㄦ" and initial is not None:
        return False
    # ㄐㄑㄒ must go with a rhyme containing ㄧ or ㄩ.
    if initial in JI_QI_XI:
        if "ㄧ" not in rhyme and "ㄩ" not in rhyme:
            return False
    # ㄓㄔㄕㄖㄗㄘㄙ must not go with ㄧ/ㄩ rhymes.
    if initial in NO_I_U_INITIALS:
        if "ㄧ" in rhyme or "ㄩ" in rhyme:
            return False
    return True


def is_valid_reading(reading):
    """A reading is one or more valid syllables joined by '-'."""
    if not reading:
        return False
    if reading.startswith("-") or reading.endswith("-"):
        return False
    if "--" in reading:
        return False
    parts = reading.split("-")
    for p in parts:
        if not is_valid_syllable(p):
            return False
    return True


class Issue:
    def __init__(self, path, line, code, message, severity):
        self.path = path
        self.line = line
        self.code = code
        self.message = message
        self.severity = severity  # "error" or "warning"

    def text(self):
        return "%s:%d: %s %s" % (self.path, self.line, self.code, self.message)

    def to_dict(self):
        return {
            "file": self.path,
            "line": self.line,
            "code": self.code,
            "message": self.message,
            "severity": self.severity,
        }


def check_file(path, seen):
    """Check one .tsv file. `seen` maps (word, reading) -> (path, line)."""
    issues = []
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError as exc:
        issues.append(Issue(path, 0, "E006", "無法讀取檔案：%s" % exc, "error"))
        return issues
    # E006: BOM
    if raw.startswith(b"\xef\xbb\xbf"):
        issues.append(Issue(path, 0, "E006", "檔案含 BOM，請存成無 BOM 的 UTF-8", "error"))
    # E006: CRLF / CR
    if b"\r\n" in raw or b"\r" in raw:
        issues.append(Issue(path, 0, "E006", "檔案含 CRLF 或 CR，請改用 LF 換行", "error"))
    # E006: must decode as UTF-8
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        issues.append(Issue(path, 0, "E006", "檔案不是合法 UTF-8", "error"))
        return issues
    # Strip a leading BOM char for line parsing (already reported).
    if text.startswith("\ufeff"):
        text = text[1:]
    # Split on \n; strip a single trailing \r left by CRLF for parsing.
    lines = text.split("\n")
    # If file ended with newline, last element is "" -> treated as empty, ignored.
    for idx, raw_line in enumerate(lines, start=1):
        # Remove trailing \r from CRLF so column checks stay meaningful
        # (E006 already reported the line-ending problem).
        if raw_line.endswith("\r"):
            line = raw_line[:-1]
        else:
            line = raw_line
        if line.strip() == "":
            continue
        if line.lstrip().startswith("#"):
            continue
        cols = line.split("\t")
        if len(cols) != 3:
            issues.append(Issue(
                path, idx, "E001",
                "欄數不是 3（應為「詞<TAB>注音<TAB>來源」，不准有第四欄）",
                "error",
            ))
            continue
        word, reading, source = cols
        # E002
        e002_reason = None
        if word == "":
            e002_reason = "詞是空的"
        elif WHITESPACE_RE.search(word):
            e002_reason = "詞含空白字元"
        elif ASCII_ALNUM_RE.search(word):
            e002_reason = "詞含 ASCII 英數字，目前不收，請開 Issue 討論"
        if e002_reason is not None:
            issues.append(Issue(path, idx, "E002", e002_reason, "error"))
        # E003
        syllables = reading.split("-")
        if len(syllables) != len(word):
            issues.append(Issue(
                path, idx, "E003",
                "注音音節數（%d）≠詞的字數（%d）" % (len(syllables), len(word)),
                "error",
            ))
        # E004
        if not is_valid_reading(reading):
            issues.append(Issue(
                path, idx, "E004",
                "音節不是合法注音（聲母＋介音＋韻母組合或聲調位置錯誤）",
                "error",
            ))
        # E005
        # 前置／後置輕聲是同一個讀音，正規化後再比對
        key = (word, normalize_reading(reading))
        if key in seen:
            first_path, first_line = seen[key]
            issues.append(Issue(
                path, idx, "E005",
                "重複的（詞，注音），首次出現在 %s:%d" % (first_path, first_line),
                "error",
            ))
        else:
            seen[key] = (path, idx)
        # W001
        s = source.strip()
        if s != "常用" and not is_url(s):
            issues.append(Issue(
                path, idx, "W001",
                "來源欄不是網址也不是「常用」",
                "warning",
            ))
        # W002
        for ch in word:
            if ch in SIMPLIFIED_TO_TRADITIONAL:
                issues.append(Issue(
                    path, idx, "W002",
                    "詞含疑似簡體字「%s」（對應正體「%s」）" % (
                        ch, SIMPLIFIED_TO_TRADITIONAL[ch]),
                    "warning",
                ))
                break
    return issues


def collect_inputs(paths):
    """Expand file-or-directory args into a sorted list of .tsv files."""
    found = []
    for p in paths:
        if not os.path.exists(p):
            return None, "路徑不存在：%s" % p
        if os.path.isfile(p):
            if not p.endswith(".tsv"):
                return None, "不是 .tsv 檔：%s" % p
            found.append(p)
        elif os.path.isdir(p):
            for root, _dirs, files in os.walk(p):
                for name in files:
                    if name.endswith(".tsv"):
                        found.append(os.path.join(root, name))
        else:
            return None, "不是檔案或資料夾：%s" % p
    # Deduplicate, keep sorted for deterministic duplicate reporting.
    uniq = sorted(set(found))
    return uniq, None


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="check_lexicon.py",
        description="檢查詞庫貢獻檔（.tsv）格式與注音合法性",
    )
    parser.add_argument("inputs", nargs="*", help="檔案或資料夾路徑")
    parser.add_argument("--json", action="store_true", help="輸出機器可讀結果")
    args = parser.parse_args(argv)
    if not args.inputs:
        parser.print_usage(sys.stderr)
        print("錯誤：沒有任何輸入檔", file=sys.stderr)
        return 2
    files, err = collect_inputs(args.inputs)
    if err is not None:
        print("錯誤：%s" % err, file=sys.stderr)
        return 2
    if not files:
        print("錯誤：沒有任何輸入檔（找不到 .tsv）", file=sys.stderr)
        return 2
    seen = {}
    all_issues = []
    for path in files:
        all_issues.extend(check_file(path, seen))
    errors = [i for i in all_issues if i.severity == "error"]
    warnings = [i for i in all_issues if i.severity == "warning"]
    if args.json:
        payload = {
            "files": files,
            "issues": [i.to_dict() for i in all_issues],
            "summary": {
                "files": len(files),
                "errors": len(errors),
                "warnings": len(warnings),
            },
        }
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        for issue in all_issues:
            print(issue.text())
    if errors:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
