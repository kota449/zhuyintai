#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""White-list export tool: export a source tree into a clean-history open source repo."""
import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys

DEFAULT_AUTHOR = "ZhuyinTai Contributors <noreply@example.invalid>"
DEFAULT_DATE = "2026-10-11T00:00:00+08:00"
COMMIT_MESSAGE = "Import clean history"

HEADER_SLASH = "// SPDX-License-Identifier: Apache-2.0"
HEADER_HASH = "# SPDX-License-Identifier: Apache-2.0"

SLASH_EXTS = {".swift", ".h", ".m", ".mm", ".c", ".cpp"}
HASH_EXTS = {".py", ".sh"}

AUTHOR_RE = re.compile(r"^(.*)\s+<([^<>]+)>\s*$")


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def load_list_file(path, what):
    """Read a UTF-8 list file, ignore empty lines and lines starting with #."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            raw = f.read().splitlines()
    except FileNotFoundError:
        eprint(f"error: {what} file not found: {path}")
        raise
    except OSError as exc:
        eprint(f"error: cannot read {what} file {path}: {exc}")
        raise
    items = []
    for line in raw:
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("#"):
            continue
        items.append(stripped)
    return items


def _glob_to_regex(pat):
    """Translate glob with ** support to regex string (without ^$)."""
    i = 0
    n = len(pat)
    out = []
    while i < n:
        c = pat[i]
        if c == "*":
            # Check for **.
            if i + 1 < n and pat[i + 1] == "*":
                # Consume all consecutive *.
                j = i + 2
                while j < n and pat[j] == "*":
                    j += 1
                # If ** followed by /, treat as (.*/)? (zero or more dirs).
                if j < n and pat[j] == "/":
                    out.append("(.*/)?")
                    i = j + 1
                else:
                    out.append(".*")
                    i = j
            else:
                out.append("[^/]*")
                i += 1
        elif c == "?":
            out.append("[^/]")
            i += 1
        elif c == "[":
            # Pass through character class.
            j = i + 1
            if j < n and pat[j] == "!":
                j += 1
            if j < n and pat[j] == "]":
                j += 1
            while j < n and pat[j] != "]":
                j += 1
            if j >= n:
                out.append("\\[")
                i += 1
            else:
                stuff = pat[i:j + 1]
                # Convert [!...] to [^...] for regex.
                if stuff.startswith("[!"):
                    stuff = "[^" + stuff[2:]
                out.append(stuff)
                i = j + 1
        else:
            if c in ".()+|^${}\\&":
                out.append("\\" + c)
            else:
                out.append(c)
            i += 1
    return "".join(out)


def glob_match(rel_posix, pattern):
    """Match a relative posix path against a glob pattern, anchored at the --src root.

    Supports **, *, ?, [...]. Uses stdlib only.
    - `*` and `?` do not cross `/`; `**` crosses `/`; `**/` matches zero or more
      directories (so `**/*.swift` matches top-level `a.swift` too).
    - Always anchored at the root: `release/**` does NOT match `tools/release/x`,
      `*.txt` does NOT match `sub/a.txt` (use `**/*.txt`). An over-matching allowlist
      is a leak, so there is no basename or right-anchored fallback.
    """
    pat = pattern.strip()
    if not pat:
        return False
    while pat.startswith("./"):
        pat = pat[2:]
    pat = pat.lstrip("/")
    rel = rel_posix.strip()
    while rel.startswith("./"):
        rel = rel[2:]
    if not rel or not pat:
        return False
    try:
        return re.match("^" + _glob_to_regex(pat) + "$", rel) is not None
    except re.error:
        return False


def matches_any(rel_posix, patterns):
    for pat in patterns:
        if glob_match(rel_posix, pat):
            return True
    return False


def parse_author(author_str):
    m = AUTHOR_RE.match(author_str.strip())
    if not m:
        return None
    name = m.group(1).strip()
    email = m.group(2).strip()
    if not name or not email:
        return None
    return (name, email)


def header_style_for(rel_posix):
    _, ext = os.path.splitext(rel_posix)
    ext = ext.lower()
    if ext in SLASH_EXTS:
        return "slash"
    if ext in HASH_EXTS:
        return "hash"
    return None


def should_add_header(content_text, license_keep_hit):
    if license_keep_hit:
        return False
    # First 10 lines already have SPDX -> skip.
    lines = content_text.splitlines()[:10]
    for ln in lines:
        if "SPDX-License-Identifier" in ln:
            return False
    return True


def apply_header_to_text(text, style, has_shebang):
    header = HEADER_SLASH if style == "slash" else HEADER_HASH
    # Preserve trailing newline behaviour: ensure header ends with \n.
    if style == "hash" and has_shebang:
        lines = text.splitlines(keepends=True)
        if not lines:
            return header + "\n"
        first = lines[0]
        rest = "".join(lines[1:])
        # Ensure first line ends with newline.
        if not first.endswith("\n"):
            first = first + "\n"
        return first + header + "\n" + rest
    else:
        return header + "\n" + text


def is_text_bytes(data):
    try:
        data.decode("utf-8")
        return True
    except UnicodeDecodeError:
        return False


def collect_files(src_abs):
    """Walk src, skip .git, collect regular files and symlinks.

    Returns (regular_files_rel, skipped_symlinks_rel).
    regular_files_rel: list of posix rel paths for regular files.
    skipped_symlinks_rel: list of posix rel paths for symlinks encountered.
    """
    regular = []
    skipped = []
    for root, dirnames, filenames in os.walk(src_abs, topdown=True, followlinks=False):
        # Compute rel dir for .git check.
        # Filter dirnames in-place: skip .git dirs, record symlink dirs.
        # Need to iterate over a copy.
        for d in list(dirnames):
            full = os.path.join(root, d)
            # rel of this dir
            try:
                rel = os.path.relpath(full, src_abs)
            except ValueError:
                dirnames.remove(d)
                continue
            rel_posix = rel.replace(os.sep, "/")
            parts = rel_posix.split("/")
            if ".git" in parts:
                dirnames.remove(d)
                continue
            # Symlinked dir: do not follow, record as skipped.
            if os.path.islink(full):
                skipped.append(rel_posix)
                dirnames.remove(d)
                continue
            # Also skip any dir literally named .git (already handled).
        # Handle files.
        for fn in filenames:
            full = os.path.join(root, fn)
            try:
                rel = os.path.relpath(full, src_abs)
            except ValueError:
                continue
            rel_posix = rel.replace(os.sep, "/")
            parts = rel_posix.split("/")
            if ".git" in parts:
                continue
            # Symlink (including broken): record and skip.
            if os.path.islink(full):
                skipped.append(rel_posix)
                continue
            # Only regular files; skip other special types.
            try:
                st = os.lstat(full)
            except OSError:
                continue
            if not stat.S_ISREG(st.st_mode):
                skipped.append(rel_posix)
                continue
            regular.append(rel_posix)
    return sorted(regular), sorted(skipped)


def git_env(author_name, author_email, date_str, ceiling=None):
    """Environment for the git subprocesses.

    🔴 Never inherit GIT_* from the caller. Under a git hook (pre-push etc.) the
    caller's environment has GIT_DIR / GIT_INDEX_FILE / GIT_WORK_TREE pointing at the
    *calling* repository; `git init`/`git add`/`git commit` would then write into it
    (2026-10-11 incident: 56 fixture commits on the host branch, core.bare flipped).
    """
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    if ceiling:
        # Stop upward repo discovery at the parent of --out.
        env["GIT_CEILING_DIRECTORIES"] = ceiling
    env["GIT_AUTHOR_NAME"] = author_name
    env["GIT_AUTHOR_EMAIL"] = author_email
    env["GIT_AUTHOR_DATE"] = date_str
    env["GIT_COMMITTER_NAME"] = author_name
    env["GIT_COMMITTER_EMAIL"] = author_email
    env["GIT_COMMITTER_DATE"] = date_str
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    return env


def run_git(args, cwd, env):
    return subprocess.run(
        ["git"] + args,
        cwd=cwd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


class PathMapError(ValueError):
    """The --path-map file is unreadable or malformed."""


class PathMap:
    """Source path -> public path mapping, plus literal text rewrites for first-party text.

    File format, one rule per line, `#` starts a comment:

        path <src> => <dst>      src and dst both end with `/`: directory prefix; neither does: one file.
                                 A single-file rule wins over a directory rule.
        text <old> => <new>      literal replacement in the content of exported (non-overlay) text
                                 files, applied in file order before the SPDX header is decided.
        skip-text <glob>         source paths (same glob syntax as the allowlist) whose content is
                                 never rewritten (upstream files must stay byte for byte).
        overlay-keep <path>      one exact public path of an overlay file that the denylist must not
                                 drop. The denylist is written against the *source* tree (its `docs/**`
                                 is the internal docs), the overlay is already in public layout.
                                 No wildcards: the exemption must stay as narrow as the file it is for.
    """

    def __init__(self, files=(), dirs=(), texts=(), skip_text=(), overlay_keep=()):
        self.files = dict(files)
        self.dirs = sorted(dirs, key=lambda kv: -len(kv[0]))
        self.texts = list(texts)
        self.skip_text = list(skip_text)
        self.overlay_keep = set(overlay_keep)

    @classmethod
    def empty(cls):
        return cls()

    @classmethod
    def load(cls, path):
        try:
            raw = load_list_file(path, "path-map")
        except (FileNotFoundError, OSError) as exc:
            raise PathMapError(f"cannot read path-map file {path}: {exc}") from exc
        files, dirs, texts, skip_text, overlay_keep = {}, [], [], [], []
        for line in raw:
            kind, _, rest = line.partition(" ")
            rest = rest.strip()
            if kind == "skip-text":
                if not rest:
                    raise PathMapError(f"path-map: skip-text needs a glob: {line!r}")
                skip_text.append(rest)
                continue
            if kind == "overlay-keep":
                if not rest or any(ch in rest for ch in "*?[") or rest.endswith("/"):
                    raise PathMapError(f"path-map: overlay-keep needs one exact file path: {line!r}")
                overlay_keep.append(rest)
                continue
            if kind not in ("path", "text"):
                raise PathMapError(f"path-map: unknown rule {line!r}")
            old, sep, new = rest.partition(" => ")
            old, new = old.strip(), new.strip()
            if not sep or not old or not new:
                raise PathMapError(f"path-map: expected '{kind} <from> => <to>': {line!r}")
            if kind == "text":
                texts.append((old, new))
            elif old.endswith("/") and new.endswith("/"):
                dirs.append((old, new))
            elif not old.endswith("/") and not new.endswith("/"):
                files[old] = new
            else:
                raise PathMapError(f"path-map: both sides must be a directory (end with /) or a file: {line!r}")
        return cls(files, dirs, texts, skip_text, overlay_keep)

    def map_path(self, rel):
        if rel in self.files:
            return self.files[rel]
        for old, new in self.dirs:
            if rel.startswith(old):
                return new + rel[len(old):]
        return rel

    def unmap_path(self, rel):
        """Inverse of map_path for one public path (for tests and link checks)."""
        for old, new in self.files.items():
            if rel == new:
                return old
        for old, new in self.dirs:
            if rel.startswith(new):
                return old + rel[len(new):]
        return rel

    def rewrite_text(self, src_rel, text):
        if not self.texts or matches_any(src_rel, self.skip_text):
            return text
        for old, new in self.texts:
            text = text.replace(old, new)
        return text


def read_overlay(overlay_abs):
    """Read an overlay tree as-is. No SPDX header is applied.

    Returns (ok, records, skipped_symlinks, error_message).
    records is a list of (rel_posix, bytes, mode_path).
    Symlinks are not followed and not copied.
    """
    if os.path.islink(overlay_abs) or not os.path.isdir(overlay_abs):
        return False, [], [], (
            f"error: --overlay does not exist or is not a directory: {overlay_abs}"
        )
    rels, skipped = collect_files(overlay_abs)
    records = []
    for rel in rels:
        src_file = os.path.join(overlay_abs, *rel.split("/"))
        try:
            with open(src_file, "rb") as f:
                data = f.read()
        except OSError as exc:
            return False, [], [], f"error: cannot read overlay file {rel}: {exc}"
        records.append((rel, data, src_file))
    return True, records, skipped, ""


def record_to_json(rec):
    return {
        "path": rec["rel"],
        "sha256": hashlib.sha256(rec["bytes"]).hexdigest(),
        "header_added": rec["header_added"],
        "license": rec["license"],
        "from_overlay": rec["from_overlay"],
    }


def build_parser():
    p = argparse.ArgumentParser(description="Export allowlisted files into a clean-history repo.")
    p.add_argument("--src", required=True, help="source root directory")
    p.add_argument("--out", required=True, help="output directory (must not exist or be empty)")
    p.add_argument("--allowlist", required=True, help="allowlist file")
    p.add_argument("--denylist", required=True, help="denylist file")
    p.add_argument("--deny-symbols", required=True, help="deny symbols file")
    p.add_argument("--license-keep", required=True, help="license-keep file")
    p.add_argument("--author", default=DEFAULT_AUTHOR, help="author 'Name <email>'")
    p.add_argument("--date", default=DEFAULT_DATE, help="commit date")
    p.add_argument("--dry-run", action="store_true", help="only print list and manifest, write nothing")
    p.add_argument(
        "--overlay",
        default=None,
        help="directory copied as-is onto the output root after export (same path overwrites)",
    )
    p.add_argument(
        "--path-map",
        default=None,
        help="rename rules applied to source paths after allow/deny (see PathMap docstring)",
    )
    return p


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)

    src_abs = os.path.abspath(args.src)
    out_abs = os.path.abspath(args.out)

    # --src must exist and be a dir.
    if not os.path.isdir(src_abs):
        eprint(f"error: --src does not exist or is not a directory: {args.src}")
        return 2

    # Load list files.
    try:
        allowlist = load_list_file(args.allowlist, "allowlist")
    except (FileNotFoundError, OSError):
        return 2
    try:
        denylist = load_list_file(args.denylist, "denylist")
    except (FileNotFoundError, OSError):
        return 2
    try:
        deny_symbols = load_list_file(args.deny_symbols, "deny-symbols")
    except (FileNotFoundError, OSError):
        return 2
    try:
        license_keep = load_list_file(args.license_keep, "license-keep")
    except (FileNotFoundError, OSError):
        return 2

    path_map = PathMap.empty()
    if args.path_map:
        try:
            path_map = PathMap.load(args.path_map)
        except PathMapError as exc:
            eprint(f"error: {exc}")
            return 2

    # Allowlist empty -> error 2.
    if len(allowlist) == 0:
        eprint("error: allowlist is empty")
        return 2

    # Parse author.
    parsed = parse_author(args.author)
    if parsed is None:
        eprint(f"error: --author must look like 'Name <email>', got: {args.author}")
        return 2
    author_name, author_email = parsed
    date_str = args.date.strip()
    if not date_str:
        eprint("error: --date is empty")
        return 2

    # Collect files.
    regular_files, skipped_symlinks = collect_files(src_abs)

    exported = []
    excluded_by_denylist = []
    not_in_allowlist = []
    for rel in regular_files:
        if matches_any(rel, denylist):
            excluded_by_denylist.append(rel)
        elif matches_any(rel, allowlist):
            exported.append(rel)
        else:
            not_in_allowlist.append(rel)

    exported.sort()
    excluded_by_denylist.sort()
    not_in_allowlist.sort()
    skipped_symlinks.sort()

    # Empty export -> error 2 ("input empty is always error").
    if len(exported) == 0:
        eprint("error: nothing to export (empty selection)")
        return 2

    # --out must not exist or be an empty directory.
    out_existed = os.path.lexists(out_abs)
    if out_existed:
        if not os.path.isdir(out_abs) or os.path.islink(out_abs):
            eprint(f"error: --out exists and is not a directory: {args.out}")
            return 2
        try:
            entries = os.listdir(out_abs)
        except OSError as exc:
            eprint(f"error: cannot list --out: {exc}")
            return 2
        if len(entries) != 0:
            eprint(f"error: --out is not empty: {args.out}")
            return 2
    # Dry-run: print list and manifest, write nothing.
    manifest_path = os.path.join(
        os.path.dirname(out_abs), os.path.basename(out_abs) + ".manifest.json"
    )

    # Pre-compute header decisions and output bytes (in memory) for manifest/dry-run.
    # For each exported file, read src bytes, decide header.
    file_records = []  # (rel, header_added, license, out_bytes)
    text_rewritten = []
    path_map_applied = {}
    for rel in exported:
        src_file = os.path.join(src_abs, *rel.split("/"))
        try:
            with open(src_file, "rb") as f:
                src_bytes = f.read()
        except OSError as exc:
            eprint(f"error: cannot read source file {rel}: {exc}")
            return 2
        style = header_style_for(rel)
        keep = matches_any(rel, license_keep)
        header_added = False
        out_bytes = src_bytes
        # Path-map text rules run first, so the SPDX header decision sees the final text.
        if path_map.texts:
            try:
                original_text = src_bytes.decode("utf-8")
            except UnicodeDecodeError:
                original_text = None
            if original_text is not None:
                rewritten = path_map.rewrite_text(rel, original_text)
                if rewritten != original_text:
                    out_bytes = rewritten.encode("utf-8")
                    text_rewritten.append(path_map.map_path(rel))
        if style is not None and not keep:
            # Try utf-8 decode; binary files skip header.
            try:
                text = out_bytes.decode("utf-8")
            except UnicodeDecodeError:
                text = None
            if text is not None:
                if should_add_header(text, False):
                    has_shebang = False
                    if style == "hash":
                        if text.startswith("#!"):
                            has_shebang = True
                    new_text = apply_header_to_text(text, style, has_shebang)
                    out_bytes = new_text.encode("utf-8")
                    header_added = True
        lic = "Apache-2.0" if header_added else None
        dst_rel = path_map.map_path(rel)
        if dst_rel != rel:
            path_map_applied[rel] = dst_rel
        file_records.append({
            "rel": dst_rel,
            "header_added": header_added,
            "license": lic,
            "bytes": out_bytes,
            "from_overlay": False,
            "mode_path": os.path.join(src_abs, *rel.split("/")),
        })

    seen_dst = {}
    for rec in file_records:
        if rec["rel"] in seen_dst:
            eprint(f"error: two source files map to the same output path: {rec['rel']}")
            return 2
        seen_dst[rec["rel"]] = True

    overlay_rels = []
    overlay_excluded = []
    if args.overlay:
        ok, orecs, oskipped, err = read_overlay(os.path.abspath(args.overlay))
        if not ok:
            eprint(err)
            return 2
        by_rel = {rec["rel"]: rec for rec in file_records}
        for rel, data, mode_path in orecs:
            # overlay 不能繞過 denylist：本機跑 pytest 留在 overlay 目錄裡的 __pycache__／.pyc
            # 帶著本機絕對路徑，曾因此進了匯出樹（code-review high）。路徑是匯出樹內的相對路徑。
            if matches_any(rel, denylist) and rel not in path_map.overlay_keep:
                overlay_excluded.append(rel)
                continue
            # Overlay wins on the same relative path. Bytes are copied as-is (no SPDX header).
            by_rel[rel] = {
                "rel": rel,
                "header_added": False,
                "license": None,
                "bytes": data,
                "from_overlay": True,
                "mode_path": mode_path,
            }
            overlay_rels.append(rel)
        file_records = [by_rel[k] for k in sorted(by_rel)]
        skipped_symlinks = sorted(set(skipped_symlinks) | set(oskipped))
        overlay_rels = sorted(set(overlay_rels))
        overlay_excluded = sorted(set(overlay_excluded))
        # An overlay file replaces the rewritten source file, so it is not "rewritten" any more.
        text_rewritten = [r for r in text_rewritten if r not in set(overlay_rels)]

    # deny_symbols 掃描（內容＋檔名）在 dry-run 與真跑之間共用：dry-run 是預檢，
    # 不能「預檢綠、真跑 exit 3」。掃的是記憶體裡的輸出位元組，不需要先寫檔。
    hits = []
    if len(deny_symbols) > 0:
        for rec in file_records:
            rel = rec["rel"]
            # Filename check: substring in rel posix path (includes overlay paths).
            for sym in deny_symbols:
                if sym and sym in rel:
                    hits.append({"file": rel, "symbol": sym, "where": "filename"})
        # Content check: output bytes, including overlay overwrites, as utf-8 if possible.
        for rec in file_records:
            rel = rec["rel"]
            try:
                text = rec["bytes"].decode("utf-8")
            except UnicodeDecodeError:
                continue
            for sym in deny_symbols:
                if sym and sym in text:
                    hits.append({"file": rel, "symbol": sym, "where": "content"})
    if hits:
        for h in hits:
            eprint(f"deny-symbol hit: file={h['file']} symbol={h['symbol']} where={h['where']}")
        # Whole failure: nothing is left behind (an empty pre-existing --out is removed as before).
        if out_existed and not args.dry_run:
            shutil.rmtree(out_abs, ignore_errors=True)
        return 3

    if args.dry_run:
        # Print export list and manifest JSON to stdout, write nothing.
        # Compute sha256 from in-memory bytes.
        exported_json = [record_to_json(rec) for rec in file_records]
        manifest = {
            "src": src_abs,
            "out": out_abs,
            "author": args.author,
            "date": date_str,
            "commit": None,
            "exported": exported_json,
            "excluded_by_denylist": excluded_by_denylist,
            "not_in_allowlist": not_in_allowlist,
            "skipped_symlinks": skipped_symlinks,
            "overlay": overlay_rels,
            "overlay_excluded_by_denylist": overlay_excluded,
            "path_map": dict(sorted(path_map_applied.items())),
            "text_rewritten": sorted(text_rewritten),
        }
        print("would export:")
        for rec in file_records:
            print(rec["rel"])
        if args.overlay:
            print("overlay:")
            for rel in overlay_rels:
                print(rel)
        print("manifest:")
        print(json.dumps(manifest, indent=2, sort_keys=True, ensure_ascii=False))
        return 0

    # Real run: create out dir if needed.
    if not out_existed:
        try:
            os.makedirs(out_abs, exist_ok=False)
        except OSError as exc:
            eprint(f"error: cannot create --out: {exc}")
            return 2

    # Copy files, preserve relative path and exec bits.
    try:
        for rec in file_records:
            rel = rec["rel"]
            dst_file = os.path.join(out_abs, *rel.split("/"))
            parent = os.path.dirname(dst_file)
            if parent and not os.path.isdir(parent):
                os.makedirs(parent, exist_ok=True)
            with open(dst_file, "wb") as f:
                f.write(rec["bytes"])
            # Preserve mode (at least exec bits) from the file we actually copied.
            try:
                src_mode = stat.S_IMODE(os.stat(rec["mode_path"]).st_mode)
                os.chmod(dst_file, src_mode)
            except OSError as exc:
                eprint(f"error: cannot preserve mode for {rel}: {exc}")
                shutil.rmtree(out_abs, ignore_errors=True)
                return 2
    except OSError as exc:
        eprint(f"error: copy failed: {exc}")
        shutil.rmtree(out_abs, ignore_errors=True)
        return 2

    # git init + single commit with fixed author/date, isolated config.
    env = git_env(author_name, author_email, date_str, ceiling=os.path.dirname(out_abs))
    r = run_git(["init", "-q"], cwd=out_abs, env=env)
    if r.returncode != 0:
        eprint(f"error: git init failed: {r.stderr.strip()}")
        shutil.rmtree(out_abs, ignore_errors=True)
        return 2
    # Belt and braces: the repo must really live inside --out (never redirected elsewhere).
    if not os.path.isdir(os.path.join(out_abs, ".git")):
        eprint("error: git init did not create <out>/.git; refusing to continue")
        shutil.rmtree(out_abs, ignore_errors=True)
        return 2
    r = run_git(["add", "-A"], cwd=out_abs, env=env)
    if r.returncode != 0:
        eprint(f"error: git add failed: {r.stderr.strip()}")
        shutil.rmtree(out_abs, ignore_errors=True)
        return 2
    r = run_git(
        [
            "-c",
            "commit.gpgsign=false",
            "-c",
            f"user.name={author_name}",
            "-c",
            f"user.email={author_email}",
            "commit",
            "-q",
            "-m",
            COMMIT_MESSAGE,
            f"--author={author_name} <{author_email}>",
            f"--date={date_str}",
        ],
        cwd=out_abs,
        env=env,
    )
    if r.returncode != 0:
        eprint(f"error: git commit failed: {r.stderr.strip()}")
        shutil.rmtree(out_abs, ignore_errors=True)
        return 2
    r = run_git(["rev-parse", "HEAD"], cwd=out_abs, env=env)
    if r.returncode != 0:
        eprint(f"error: git rev-parse failed: {r.stderr.strip()}")
        shutil.rmtree(out_abs, ignore_errors=True)
        return 2
    commit_hash = r.stdout.strip()

    # Manifest (outside out, not in repo).
    exported_json = [record_to_json(rec) for rec in file_records]
    manifest = {
        "src": src_abs,
        "out": out_abs,
        "author": args.author,
        "date": date_str,
        "commit": commit_hash,
        "exported": exported_json,
        "excluded_by_denylist": excluded_by_denylist,
        "not_in_allowlist": not_in_allowlist,
        "skipped_symlinks": skipped_symlinks,
        "overlay": overlay_rels,
        "overlay_excluded_by_denylist": overlay_excluded,
        "path_map": dict(sorted(path_map_applied.items())),
        "text_rewritten": sorted(text_rewritten),
    }
    try:
        with open(manifest_path, "w", encoding="utf-8") as f:
            json.dump(manifest, f, indent=2, sort_keys=True, ensure_ascii=False)
            f.write("\n")
    except OSError as exc:
        eprint(f"error: cannot write manifest: {exc}")
        shutil.rmtree(out_abs, ignore_errors=True)
        return 2

    print(f"exported {len(file_records)} files to {out_abs}")
    if args.overlay:
        print(f"overlay {len(overlay_rels)} files")
    print(f"commit {commit_hash}")
    print(f"manifest {manifest_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
