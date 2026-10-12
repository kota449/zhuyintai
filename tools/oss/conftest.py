# SPDX-License-Identifier: Apache-2.0
"""tools/oss 測試的 pytest 設定。

🔴 在 git hook（pre-push／pre-commit）裡跑測試時，hook 會匯出 GIT_DIR／GIT_INDEX_FILE／
GIT_WORK_TREE 指向「正在 push 的 repo」，子行程繼承後 `git init`／`add`／`commit` 全部寫進
那個 repo（2026-10-11 事故：工作分支被塞 56 個 fixture commit、主 repo `core.bare` 被改成 true）。
子行程預設繼承 os.environ，所以在**收集階段**一次清掉，覆蓋所有測試（含沒帶 env= 的）。
規範出處：parallel-loops SKILL.md「測 git 行為的鐵則」。
"""
import os

for _k in [k for k in os.environ if k.startswith("GIT_")]:
    del os.environ[_k]
