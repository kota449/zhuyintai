# TWKeyboard — LGPL 對應原始碼包 / LGPL Corresponding Source

這個資料夾是 TWKeyboard（macOS 輸入法 app）內兩個 LGPL 程式庫的**對應原始碼**，附在 app 的 `Contents/Resources/lgpl_source/`。
你可以用它重新編出這兩個程式庫、換進 app，並讓 app 實際載入你換進去的版本。

This folder is the Corresponding Source of the two LGPL libraries inside the TWKeyboard macOS app
(`Contents/Resources/lgpl_source/`). You can rebuild them, replace them in the app, and have the app load your build.

## 內容 / Contents

| 路徑 | 是什麼 | 授權 |
|---|---|---|
| `megrez/` | **Megrez 組字引擎，修改版**（10 個 Swift 檔）。app 內是 `Contents/Frameworks/Megrez.framework` | LGPL-3.0-or-later ＋ 作者附加許可 |
| `Vendor/KenLMQuerySource/` | **KenLM 查詢碼**（上游 kpu/kenlm `4cb443e6` 的子集，除一個 stub 外與上游逐位元組相同）。app 內是 `Contents/Frameworks/libKenLMQuery.dylib` | LGPL-2.1-or-later（個別檔案例外見其 `LICENSE`） |
| `Shared/KenLMQueryBridge.{h,mm}` | ObjC 介面層，與 KenLM 一起編進 `libKenLMQuery.dylib` | 與 KenLM 一起提供 |
| `licenses/` | `LGPL-2.1.txt`、`LGPL-3.0.txt`、`GPL-3.0.txt`、`Megrez-CUSTOM_LGPLv3_EXCEPTION.md` | — |
| `MODIFICATIONS.md`、`megrez_upstream.patch` | 對上游 Megrez 的逐項修改與 unified diff | — |
| `build/` | 重建與替換腳本（見下） | — |

app 的其餘部分（引擎、重排器、詞庫處理、模型檔、候選窗等）不是 LGPL 程式庫，不在這個包裡。
主程式只透過兩個程式庫的公開介面呼叫它們：Megrez 的 Swift `public` API，與 `KenLMQueryBridge.h` 的兩個 ObjC 方法。

## 需求 / Requirements

- Apple silicon Mac（arm64），macOS 14 以上，Xcode 命令列工具。
- **Swift 編譯器大版本必須與出貨版相同：Swift 6.4（Xcode 內建，`swift-driver 1.168.6`）。**
  Swift 沒有穩定的模組介面：換大版本編出來的 Megrez 可能與主程式的記憶體配置不符而無法使用。
  The shipped Megrez was built with Swift 6.4; other major versions may produce a library the app cannot use.
- 旗標已寫在腳本裡，**不要改**：
  - Megrez：`-swift-version 5 -O -wmo -Xfrontend -disable-cmo`，目標 `arm64-apple-macosx14.0`，install_name `@rpath/Megrez.framework/Versions/A/Megrez`
  - KenLM：`-std=c++14 -stdlib=libc++ -O2 -DNDEBUG=1 -DKENLM_MAX_ORDER=6 -fno-common -fvisibility-inlines-hidden -fpascal-strings`（取自出貨的 Xcode Release 建置的實際 clang 指令），install_name `@rpath/libKenLMQuery.dylib`。
    `KENLM_MAX_ORDER` 與 bridge 不一致會**無聲地算出錯誤分數**。

## 重建並替換 / Rebuild and replace

```bash
cd lgpl_source                       # 本資料夾
bash build/build_megrez.sh out       # → out/Megrez
bash build/build_kenlm.sh  out       # → out/libKenLMQuery.dylib

# 對「你自己的 app 複本」替換並重簽（不要直接改 /Applications 裡的 app；腳本會拒絕）
cp -R /path/to/TWKeyboard.app ~/Desktop/TWKeyboard.app
bash build/replace_in_app.sh ~/Desktop/TWKeyboard.app out/Megrez out/libKenLMQuery.dylib
```

`build/test_build_megrez.sh`、`build/test_build_kenlm.sh` 是這兩個腳本的測試（驗 install_name 與符號）。

### 為什麼要重簽，以及指令為什麼長這樣（實測）

出貨的 app 以 Developer ID 簽章並開 hardened runtime（含 library validation）：**簽署者不同的程式庫會被 dyld 拒載**。
下面四種情況都在 macOS 實機上跑過（把重編的庫換進 app 複本後直接啟動主程式，看 dyld 與 `lsof`）：

| 做法 | 結果 |
|---|---|
| 只換程式庫、不重簽（或只重簽主程式、程式庫不是同一簽署者） | ❌ **拒載**：`dyld: Library not loaded … code signature … not valid for use in process: mapping process and mapped file (non-platform) have different Team IDs` |
| **ad-hoc 重簽整個 app，不加 `--options runtime`**（`replace_in_app.sh` 預設） | ✅ 載入你換進去的版本 |
| ad-hoc 重簽、**加** `--options runtime` | ❌ 拒載，同樣是 `different Team IDs`（ad-hoc 沒有 Team ID，過不了 library validation） |
| 用**你自己的簽署身分**（`SIGN_IDENTITY="Developer ID Application: …" RUNTIME=1 bash build/replace_in_app.sh …`），app 與兩個程式庫同一身分、可加 runtime | ✅ 載入你換進去的版本 |

所以：**ad-hoc → 不要加 runtime；要 hardened runtime → 必須用自己的身分簽整個 app。**
`replace_in_app.sh` 一律帶 `--preserve-metadata=entitlements`：不帶的話 `codesign --force` 會丟掉 app 的 sandbox 等 entitlements。

重簽後這份 app **不再是原作者簽章的版本**，要不要把它當輸入法安裝由你決定（本包不涵蓋安裝）。

### 重簽後原沙箱容器的資料還讀得到嗎

app 在 App Sandbox 內（容器 `~/Library/Containers/com.kota.xrich.inputmethod.TWKeyboard/`，自訂詞、log 等在裡面）。
macOS 的容器記錄「擁有者」的簽署資訊。我們用一個**同樣 sandbox、同 bundle id 的測試用小 app**（不是 TWKeyboard 本身，以免動到使用者的資料）量測：
Developer ID 簽章下寫入容器 → ad-hoc 重簽（保留 entitlements）→ **仍讀得到**原本寫入的檔案，容器的擁有者清單多了一筆 ad-hoc 項目。
這個結果在 macOS（Darwin 27）上量得，未來 macOS 版本可能改變；若你的系統跳出「想存取其他 App 的資料」之類的提示，那是 macOS 的容器保護，與本包無關。

## 對應原始碼的取得 / Source availability

這個資料夾就是對應原始碼，隨 app 一起發送。上游：
Megrez — https://github.com/vChewing/Megrez（基準 commit `5d41861779a3a3b87e962a2c82505f6e40972a44`）；
KenLM — https://github.com/kpu/kenlm（commit `4cb443e60b7bf2c0ddf3c745378f76cb59e254e5`）。
