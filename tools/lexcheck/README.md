# 詞庫貢獻檔驗證工具（lexcheck）

給 macOS 注音輸入法「注音台（ZhuyinTai）」開源 repo 用的補詞投稿檢查工具。
投稿者在本機執行，GitHub Actions 也會在 PR 上自動執行。
只用 Python 3 標準函式庫，不需要安裝任何套件。

這個工具只檢查投稿檔的**格式**與音節的結構是否合法，不檢查詞對不對、讀音對不對。
已知限制見下方「合法注音的判定」與「錯誤代碼表」。

## 系統需求

- Python 3.8 以上（只用標準函式庫：`argparse`、`json`、`os`、`re`、`sys`）。
- 作業系統不限；換行與編碼檢查與平台無關。

## 用法

在 repo 根目錄執行：

```sh
python3 tools/lexcheck/check_lexicon.py <檔案或資料夾>... [--json]
```

- `<檔案或資料夾>` 可以給多個；資料夾會遞迴找出底下所有 `.tsv` 檔。
  直接指定副檔名不是 `.tsv` 的檔案會視為參數錯誤。
- `--json`：輸出機器可讀的 JSON（`files`、`issues`、`summary`），
  不加則逐行印出 `檔名:行號: 錯誤代碼 說明`。
- 退出碼：
  - `0`：沒有錯誤（可以有警告）；
  - `1`：有錯誤；
  - `2`：參數錯誤或沒有任何輸入檔（沒有輸入不算成功）。

範例：

```sh
python3 tools/lexcheck/check_lexicon.py contributions/
python3 tools/lexcheck/check_lexicon.py a.tsv b.tsv --json
```

## 貢獻檔格式

- 檔案編碼 UTF-8（不含 BOM）、換行 LF、副檔名 `.tsv`。
- `#` 開頭的行是註解；空行忽略。
- 每行三欄，以 Tab 分隔：①詞 ②注音 ③來源。
  - ① 詞：純中文詞。不可為空、不可含空白、不可含 ASCII 英數字。
    中英混合詞目前不收，會報 `E002`，說明請開 Issue 討論。
  - ② 注音：每個字一個音節，音節之間用半形連字號 `-` 連接。
    聲調符號為 `ˊ`（二聲）、`ˇ`（三聲）、`ˋ`（四聲），標在音節最後；
    一聲不標；輕聲 `˙` 寫在音節前面或後面都收（`˙ㄅㄚ` 或 `ㄅㄚ˙`），
    檢查時內部一律正規化成後置（`ㄅㄚ˙`，與詞庫資料和引擎的寫法一致）。
    同一個詞同一個讀音用兩種寫法各寫一次，算重複（`E005`）。
    `˙` 只能有一個，不能和 `ˊ`、`ˇ`、`ˋ` 同時出現。
  - ③ 來源：網址（`http(s)://`）或「常用」二字；其他文字記警告 `W001`。
- 不准有第四欄（特別是分數、詞頻），有多餘欄位一律報 `E001`。

合法注音的判定只實作下列結構規則：ㄐㄑㄒ只拼含ㄧ／ㄩ的韻；
ㄓㄔㄕㄖㄗㄘㄙ不拼ㄧ／ㄩ韻；ㄦ只限零聲母；空韻ㄭ省略不標；聲母、介音、韻母要在
已知的組合表內；聲調標在音節最後（輕聲前後皆可）。
其餘結構合法就放行——**通過檢查只代表格式與音節結構沒問題，不代表這個詞的讀音正確**。
這個工具沒有逐音節的完整合法音節表，少數結構上合法但實際不存在的音節會被放行。

## 錯誤代碼表

| 代碼 | 層級 | 意義 |
| --- | --- | --- |
| `E001` | 錯誤 | 欄數不是 3（含多出第四欄） |
| `E002` | 錯誤 | 詞是空的、含空白、或含 ASCII 英數（中英混合詞目前不收，請開 Issue 討論） |
| `E003` | 錯誤 | 注音音節數 ≠ 詞的字數 |
| `E004` | 錯誤 | 音節不是合法注音（聲母＋介音＋韻母組合或聲調位置錯誤） |
| `E005` | 錯誤 | 同一檔或跨檔重複的（詞，注音；輕聲前置與後置視為同一個讀音），訊息會註明首次出現的 `檔名:行號` |
| `E006` | 錯誤 | 檔案不是 UTF-8、有 BOM、或用 CRLF／CR（請轉為無 BOM 的 UTF-8＋LF） |
| `W001` | 警告 | 來源欄不是網址也不是「常用」（不影響退出碼） |
| `W002` | 警告 | 詞裡有疑似簡體字（內建 100 組常見簡繁對照；只警告）。有些字在繁體裡本來就是正字，會誤報，例如「皇后」的「后」、「山谷」的「谷」；確認無誤可忽略 |

輸出範例（文字模式）：

```text
contributions/a.tsv:3: E001 欄數不是 3（應為「詞<TAB>注音<TAB>來源」，不准有第四欄）
contributions/a.tsv:7: E005 重複的（詞，注音），首次出現在 contributions/a.tsv:2
contributions/b.tsv:0: E006 檔案含 CRLF 或 CR，請改用 LF 換行
contributions/b.tsv:4: W001 來源欄不是網址也不是「常用」
```

JSON 模式輸出含 `files`、`issues`（每筆有 `file`、`line`、`code`、`message`、
`severity`）與 `summary`（`files`、`errors`、`warnings`）。

## 放進 GitHub Actions

在 repo 新增 `.github/workflows/lexcheck.yml`：

```yaml
name: lexcheck
on:
  pull_request:
    paths:
      - '**/*.tsv'
      - 'tools/lexcheck/**'
  push:
    paths:
      - '**/*.tsv'
      - 'tools/lexcheck/**'

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: actions/setup-python@v5
        with:
          python-version: '3.x'
      - name: Run lexicon checker
        run: python3 tools/lexcheck/check_lexicon.py contributions/
```

- 版號固定寫主版號（`checkout@v6`、`setup-python@v5`），
  兩者皆為官方 repo 上真實存在的主版號
  （`https://github.com/actions/checkout/releases`、
  `https://github.com/actions/setup-python/releases`）。
- 預設用文字輸出即可在 PR 的 log 看到 `檔名:行號: 代碼`；
  需要給其他工具接續處理時再加 `--json`。
- Action 失敗（退出碼 `1`）代表有錯誤；只有警告（退出碼 `0`）不會擋 PR。

## 測試

```sh
cd tools/lexcheck
python3 -m pytest -q        # 有 pytest 時
python3 -m unittest discover -v -s tests   # 只用標準函式庫時
```

測試全用標準函式庫 `unittest` 撰寫，共 66 個，涵蓋 `E001`～`E006`、
`W001`～`W002`、退出碼、`--json` 格式與注音合法性規則（含輕聲前置／後置）。
測試產生的暫存檔都放在 `tools/lexcheck/` 底下，不寫到外面。
