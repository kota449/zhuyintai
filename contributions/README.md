# 詞庫投稿

補詞、改讀音的投稿檔放在這個資料夾，一個主題一個 `.tsv` 檔。
格式與送 PR 的規矩見 [CONTRIBUTING.md](../CONTRIBUTING.md)；
送之前用 [lexcheck](../tools/lexcheck/README.md) 檢查一次：

```sh
python3 tools/lexcheck/check_lexicon.py contributions/
```

## 授權

這個資料夾裡的詞庫檔（詞＋讀音，不含分數）以 Mozilla Public License 2.0（MPL-2.0）釋出。
授權全文在 [LICENSES/MPL-2.0.txt](../LICENSES/MPL-2.0.txt)。

`.tsv` 檔裡沒有地方放授權聲明（`#` 註解行也可能被工具略過），
所以把 MPL-2.0 附件 A 的聲明放在這裡，適用這個資料夾裡的每一個檔：

```text
This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
If a copy of the MPL was not distributed with this file, You can obtain one at
http://mozilla.org/MPL/2.0/.
```

送 PR 要用 `git commit -s` 簽署（DCO），說明見 CONTRIBUTING.md。
