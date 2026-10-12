#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""tools/oss 四份清單的一致性檢查：把清單展開成「實際會匯出的檔案集合」並驗證。

不匯出、不寫檔，只讀。glob 語意＝Python `glob(recursive=True)`（`**` 跨目錄）；
Muse TASK_16 工具的 glob 實作搬回後，要用同一份清單交叉比對兩邊展開結果一致。
"""
import glob
import os
from pathlib import Path

TEXT_EXT = ('.swift', '.h', '.m', '.mm', '.c', '.cc', '.cpp', '.hh', '.hpp', '.md', '.txt', '.sh',
            '.py', '.json', '.plist', '.strings', '.xcconfig', '.entitlements', '.yml', '.yaml',
            '.cmake', '.in', '.inc', '.pbxproj', '.occ', '.list')
TEXT_NAMES = ('LICENSE', 'NOTICE', 'COPYING', 'COPYING.LESSER.3')
LGPL_PREFIXES = ('Shared/Megrez/', 'Vendor/', 'third_party/')
NOTICE_NAMES = ('ThirdPartyNotices.txt', 'THIRD_PARTY_NOTICE.md')


def read_list(path):
    return [ln.strip() for ln in Path(path).read_text(encoding='utf-8').splitlines()
            if ln.strip() and not ln.lstrip().startswith('#')]


def expand(src, patterns):
    out = set()
    for pat in patterns:
        for m in glob.glob(pat, recursive=True, root_dir=src, include_hidden=True):
            full = os.path.join(src, m)
            if os.path.isdir(full):
                for dp, _, fs in os.walk(full):
                    for f in fs:
                        out.add(os.path.relpath(os.path.join(dp, f), src))
            else:
                out.add(m)
    return out


def export_set(src, lists_dir):
    """allowlist 展開 − denylist 展開；排除符號連結與非檔案。"""
    allow = expand(src, read_list(os.path.join(lists_dir, 'allowlist.txt')))
    deny = expand(src, read_list(os.path.join(lists_dir, 'denylist.txt')))
    return sorted(f for f in allow - deny
                  if os.path.isfile(os.path.join(src, f)) and not os.path.islink(os.path.join(src, f)))


def symbol_hits(src, files, symbols):
    """回傳 {symbol: [命中的檔（內容或檔名）]}；只掃文字檔內容，檔名一律掃。"""
    hits = {}
    for f in files:
        text = ''
        if f.endswith(TEXT_EXT) or os.path.basename(f) in TEXT_NAMES:
            text = Path(src, f).read_text(encoding='utf-8', errors='ignore')
        for s in symbols:
            if s in text or s in f:
                hits.setdefault(s, []).append(f)
    return hits


def classify(path):
    """'lgpl'＝已因 LGPL 義務公開；'notice'＝第三方聲明檔；'src'＝我們改得動的原始碼。"""
    if path.startswith(LGPL_PREFIXES):
        return 'lgpl'
    if path.endswith(NOTICE_NAMES):
        return 'notice'
    return 'src'
