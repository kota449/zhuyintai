# Third-party notice — candidate window (`MacIMESpike/CandidateUI/`)

The candidate-window user interface in `Upstream/` is derived from the
**vChewing** macOS input method (`https://github.com/vChewing/vChewing-macOS`),
upstream commit `55e1d70d7bd9db4beab414d3e93f0ec333ade6a6`,
© 2021 and onwards The vChewing Project, licensed under **Mulan PSL v2 (MulanPSL-2.0)**.

The license text is shipped alongside this file:

- `LICENSE-MulanPSL-2.0.txt` — verbatim copy of the upstream `LICENSE.txt`
- `LICENSE-MulanPSL-2.0-zh-Hant.txt` — verbatim copy of the upstream `LICENSE-CHT.txt`

Every file under `Upstream/` keeps its original three-line copyright / SPDX header unchanged.

## Trademarks

"vChewing", "威注音" and "唯音" are names of the upstream project. **No trademark license is granted**
(Mulan PSL v2 §3). This app is not affiliated with or endorsed by the vChewing Project; the names
appear in this notice, and in the unchanged copyright headers, only to identify where code came from.
No module name, type prefix or user-visible string in this app uses them.

## What came from where

| Our file (`Upstream/…`) | Upstream file | Changes |
|---|---|---|
| `UI/CtlCandidateGSI4AppKit.swift` | `Packages/vChewing_CandidateWindow/Sources/TDK4AppKit/` (same name) | imports removed |
| `UI/VwrCandidateGSI4AppKit.swift` | same dir | imports removed |
| `UI/CandidatePool4AppKit.swift` | same dir | imports removed |
| `UI/CandidateCellData4AppKit.swift` | same dir | imports removed; a doc-comment block that named the upstream product was rewritten |
| `UI/_TDK4AppKit.swift` | same dir | imports removed |
| `Support/SwiftExtension/*.swift` (3) | `Packages/vChewing_OSNeutral_LibVanguard/Deps/VanguardSwiftExtension/Sources/SwiftExtension/` | `os.Logger` subsystem renamed to this app's bundle id; two comments naming the upstream legacy repo reworded |
| `Support/AppKitImpl_Misc.swift` | `Packages/vChewing_OSFrameworkImpl/Sources/OSFrameworkImpl/AppKitImpl/` | import removed; `DispatchQueue` label renamed; one comment reworded |
| `Support/AppKitImpl_NSView_Extract.swift` | same dir, `AppKitImpl_NSView.swift` | **extract**: only `NSView.pinEdges(to:)` and the `NSMenu` / `NSMenuItem` builder helpers, byte-for-byte; the rest of that file is not included |
| `Support/Broadcaster.swift` | `Packages/vChewing_Shared_DarwinImpl/Sources/Shared_DarwinImpl/` | none |

Every edit inside an upstream file is marked with a `[TWKeyboard]` comment.

## What was deliberately NOT taken

- **`Shared`** (`Packages/vChewing_OSNeutral_LibVanguard/Sources/Shared/`, 17 files) — each file is
  `LGPL-3.0-or-later`, not Mulan PSL. The candidate window needs five symbols from it
  (`CandidateInState`, `CtlCandidateDelegate`, `CtlCandidateProtocol`, `CandidateContextMenuAction`,
  `PrefMgr`). Those are re-written in `Shim/CandidateUIShim.swift` from the call sites in `Upstream/UI/`.
- **`AppKitImpl_NSWindowPositioner.swift`** (in `OSFrameworkImpl`) — its header is only
  "Free to use / Written by Alexis Bridoux", which is not a license we can rely on. Only the legacy
  controller used it; we did not port that controller.
- The legacy `TDK4AppKit` controller and view (`CtlCandidateTDK4AppKit`, `VwrCandidateTDK4AppKit`).

## Files that are ours

`Shim/` — `CandidateUIShim.swift`, `NSMenuActionTrampoline.swift`. Not derived from upstream text.

Full audit: (internal audit record, not shipped).
