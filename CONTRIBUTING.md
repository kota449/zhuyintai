# 怎麼參與注音台

歡迎你來幫忙。我們缺這幾種貢獻：補詞與讀音、回報選字問題、候選窗外觀、匯入／匯出工具、app 介面。
先看完這一頁再動手。看不懂就開 Issue 問。

## 回報問題

到這個 repo 的 [Issues](https://github.com/kota449/zhuyintai/issues) 開一則新的。
回報格式沒有另附文件，請直接寫在 [GitHub Issues](https://github.com/kota449/zhuyintai/issues)：哪個詞、預期的字、實際跳出的字。

⚠️ **Issues 是公開的**——任何人都看得到。**請不要貼私人的打字內容**（對話、帳號、密碼、住址、公司資料）。
只貼那一個詞或那一句，用中性的例句就好。
也**不要貼「匯出 log」的檔案**，裡面有你打的字。

## 補詞

缺詞、讀音錯、同音字順序不對，都歡迎補。

格式長這樣，一律照辦：

- UTF-8、LF（換行）、副檔名 `.tsv`。`#` 開頭的那行是註解。
- 每行三欄，用 Tab 分開：①詞 ②注音 ③來源。
- 注音這樣寫：每個字一個音節，音節之間用 `-` 連起來。聲調符號照打，一聲不標。例：`ㄘㄜˋ-ㄕˋ`。
- 輕聲的 `˙` 寫在音節前面或後面都可以（`˙ㄉㄜ` 或 `ㄉㄜ˙`），檢查工具內部統一成後面。
- 來源寫網址（字典、新聞、官方網站），或是寫「常用」。
- **不放分數或詞頻欄。** 有多的欄位我們會退件。

例如（Tab 分隔）：

```text
# 詞<TAB>注音<TAB>來源
測試	ㄘㄜˋ-ㄕˋ	常用
```

送 PR 的規矩：

- 一個 PR 只做一個主題。不要把不相關的詞塞在同一包。
- 每個詞都要附來源。字典、新聞、官方網站的網址，直接貼上來。
- 沒把握的詞先問，不要硬送。

## 改程式

動手前先看：只改你要改的地方，不要動不相關的地方。

## 授權與簽署（DCO）

程式碼用 Apache-2.0 授權（全文見 LICENSE），詞庫檔用 MPL-2.0 授權（全文見 LICENSES/MPL-2.0.txt）。你的貢獻照它所屬檔案的授權釋出。
這兩種授權都允許商業使用，包含我們自己的官方安裝包。

**不用簽任何額外的授權協議。** 我們用 DCO（Developer Certificate of Origin，開發者來源證明）。
你要做的只有一件事：**PR 裡的每一個 commit 都要有一行 `Signed-off-by`**。
這一行表示你確認這份貢獻你有權送出，並同意以本專案的授權釋出。
程式碼和詞庫檔都一樣。DCO 1.1 的原文在 https://developercertificate.org/ ，送之前請看一次。

簽法——commit 時加 `-s`：

```sh
git commit -s -m "補詞：測試"
```

git 會在訊息最後自動加上（姓名與 email 取自你的 `user.name`、`user.email` 設定）：

```text
Signed-off-by: 你的姓名 <you@example.com>
```

忘了簽的話，PR 開了以後也能補：

```sh
# 只有最後一個 commit 沒簽
git commit --amend -s --no-edit

# 整個 PR 的 commit 都沒簽（把 main 換成你的 PR 的目標分支）
git rebase --signoff main
```

補簽會改寫 commit，要用 `git push --force-with-lease` 推回你自己的 PR 分支。
沒有 `Signed-off-by` 的 PR，維護者會請你補上才能合併。

## 建置

建置步驟見 [BUILDING.md](BUILDING.md)。
從原始碼建置的版本，選字結果可能與 Releases 的安裝包不同；要日常使用請下載 Releases 的安裝包。
