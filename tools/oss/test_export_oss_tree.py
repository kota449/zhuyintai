# SPDX-License-Identifier: Apache-2.0
import hashlib
import json
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

import unittest

TOOL = Path(__file__).resolve().parent / "export_oss_tree.py"
PYTHON = sys.executable
AUTHOR = "ZhuyinTai Contributors <noreply@example.invalid>"
DATE = "2026-10-11T00:00:00+08:00"


def write(path, content=b"", mode=None):
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(content, str):
        p.write_text(content, encoding="utf-8")
    else:
        p.write_bytes(content)
    if mode is not None:
        os.chmod(p, mode)


def write_list(path, lines):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")


def run_tool(*args, env=None):
    return subprocess.run(
        [PYTHON, str(TOOL), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )


def manifest_for(out):
    mp = Path(str(out) + ".manifest.json")
    return mp


def git_env_extra():
    # 不繼承呼叫端的 GIT_*（hook 環境會帶 GIT_DIR）；見 conftest.py 與 TestGitHookEnvIsolation
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    return env


def git_rev_parse(out):
    r = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=str(out),
        env=git_env_extra(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return r.stdout.strip()


class Base(unittest.TestCase):
    def make_src(self, tmp, files):
        src = Path(tmp) / "src"
        src.mkdir(parents=True, exist_ok=True)
        for rel, content in files.items():
            write(src / rel, content)
        return src

    def base_lists(self, tmp, allow, deny=None, symbols=None, keep=None):
        d = Path(tmp)
        ap = d / "allowlist.txt"
        dp = d / "denylist.txt"
        sp = d / "deny_symbols.txt"
        kp = d / "license_keep.txt"
        write_list(ap, allow)
        write_list(dp, deny if deny is not None else ["# none"])
        write_list(sp, symbols if symbols is not None else ["# none"])
        write_list(kp, keep if keep is not None else ["# none"])
        return ap, dp, sp, kp


class TestPriorityAndGlob(Base):
    def test_01_denylist_priority_over_allowlist(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self.make_src(tmp, {"a.txt": "hello", "secret.txt": "hello"})
            ap, dp, sp, kp = self.base_lists(
                tmp, allow=["*.txt"], deny=["secret.txt"], symbols=[], keep=[]
            )
            out = Path(tmp) / "out"
            r = run_tool("--src", str(src), "--out", str(out),
                         "--allowlist", str(ap), "--denylist", str(dp),
                         "--deny-symbols", str(sp), "--license-keep", str(kp),
                         "--author", AUTHOR, "--date", DATE)
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            self.assertTrue((out / "a.txt").exists())
            self.assertFalse((out / "secret.txt").exists())
            m = json.loads(manifest_for(out).read_text(encoding="utf-8"))
            self.assertIn("secret.txt", m["excluded_by_denylist"])

    def test_02_double_star_glob_recursive(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self.make_src(tmp, {
                "top.swift": "let a = 1\n",
                "nested/deep/file.swift": "let b = 2\n",
                "other.txt": "x",
            })
            ap, dp, sp, kp = self.base_lists(
                tmp, allow=["**/*.swift"], deny=[], symbols=[], keep=[]
            )
            out = Path(tmp) / "out"
            r = run_tool("--src", str(src), "--out", str(out),
                         "--allowlist", str(ap), "--denylist", str(dp),
                         "--deny-symbols", str(sp), "--license-keep", str(kp),
                         "--author", AUTHOR, "--date", DATE)
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            self.assertTrue((out / "top.swift").exists())
            self.assertTrue((out / "nested/deep/file.swift").exists())
            self.assertFalse((out / "other.txt").exists())

    def test_03_symlink_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "src"
            src.mkdir()
            write(src / "real.txt", "real")
            os.symlink("real.txt", src / "link.txt")
            ap, dp, sp, kp = self.base_lists(
                tmp, allow=["*.txt", "**/*.txt"], deny=[], symbols=[], keep=[]
            )
            out = Path(tmp) / "out"
            r = run_tool("--src", str(src), "--out", str(out),
                         "--allowlist", str(ap), "--denylist", str(dp),
                         "--deny-symbols", str(sp), "--license-keep", str(kp),
                         "--author", AUTHOR, "--date", DATE)
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            self.assertTrue((out / "real.txt").exists())
            self.assertFalse((out / "link.txt").exists())
            m = json.loads(manifest_for(out).read_text(encoding="utf-8"))
            self.assertIn("link.txt", m["skipped_symlinks"])

    def test_04_out_nonempty_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self.make_src(tmp, {"a.txt": "hi"})
            ap, dp, sp, kp = self.base_lists(tmp, allow=["*.txt"], deny=[], symbols=[], keep=[])
            out = Path(tmp) / "out"
            out.mkdir()
            write(out / "existing.txt", "do not overwrite")
            r = run_tool("--src", str(src), "--out", str(out),
                         "--allowlist", str(ap), "--denylist", str(dp),
                         "--deny-symbols", str(sp), "--license-keep", str(kp),
                         "--author", AUTHOR, "--date", DATE)
            self.assertEqual(r.returncode, 2)
            # Must not overwrite.
            self.assertTrue((out / "existing.txt").exists())
            self.assertFalse((out / "a.txt").exists())

    def test_05_git_dir_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self.make_src(tmp, {"a.txt": "hi", ".git/config": "secret-config"})
            ap, dp, sp, kp = self.base_lists(tmp, allow=["**/*"], deny=[], symbols=[], keep=[])
            out = Path(tmp) / "out"
            r = run_tool("--src", str(src), "--out", str(out),
                         "--allowlist", str(ap), "--denylist", str(dp),
                         "--deny-symbols", str(sp), "--license-keep", str(kp),
                         "--author", AUTHOR, "--date", DATE)
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            self.assertTrue((out / "a.txt").exists())
            m = json.loads(manifest_for(out).read_text(encoding="utf-8"))
            paths = [e["path"] for e in m["exported"]]
            self.assertNotIn(".git/config", paths)
            ls = subprocess.run(["git", "ls-files"], cwd=str(out),
                                env=git_env_extra(), stdout=subprocess.PIPE, text=True)
            self.assertNotIn(".git/config", ls.stdout.splitlines())
            self.assertIn("a.txt", ls.stdout)


class TestHeaders(Base):
    def run_one(self, tmp, filename, content):
        src = self.make_src(tmp, {filename: content})
        ap, dp, sp, kp = self.base_lists(tmp, allow=["**/*"], deny=[], symbols=[], keep=[])
        out = Path(tmp) / "out"
        r = run_tool("--src", str(src), "--out", str(out),
                     "--allowlist", str(ap), "--denylist", str(dp),
                     "--deny-symbols", str(sp), "--license-keep", str(kp),
                     "--author", AUTHOR, "--date", DATE)
        self.assertEqual(r.returncode, 0, msg=r.stderr)
        return out

    def test_06_swift_header(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = self.run_one(tmp, "a.swift", "let x = 1\n")
            text = (out / "a.swift").read_text(encoding="utf-8")
            self.assertTrue(text.startswith("// SPDX-License-Identifier: Apache-2.0"))

    def test_07_h_header(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = self.run_one(tmp, "a.h", "int x;\n")
            text = (out / "a.h").read_text(encoding="utf-8")
            self.assertTrue(text.startswith("// SPDX-License-Identifier: Apache-2.0"))

    def test_08_m_header(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = self.run_one(tmp, "a.m", "@implementation A\n@end\n")
            text = (out / "a.m").read_text(encoding="utf-8")
            self.assertTrue(text.startswith("// SPDX-License-Identifier: Apache-2.0"))

    def test_09_mm_header(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = self.run_one(tmp, "a.mm", "int y;\n")
            text = (out / "a.mm").read_text(encoding="utf-8")
            self.assertTrue(text.startswith("// SPDX-License-Identifier: Apache-2.0"))

    def test_10_c_header(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = self.run_one(tmp, "a.c", "int main(){}\n")
            text = (out / "a.c").read_text(encoding="utf-8")
            self.assertTrue(text.startswith("// SPDX-License-Identifier: Apache-2.0"))

    def test_11_cpp_header(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = self.run_one(tmp, "a.cpp", "int main(){}\n")
            text = (out / "a.cpp").read_text(encoding="utf-8")
            self.assertTrue(text.startswith("// SPDX-License-Identifier: Apache-2.0"))

    def test_12_py_header(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = self.run_one(tmp, "a.py", "x = 1\n")
            text = (out / "a.py").read_text(encoding="utf-8")
            self.assertTrue(text.startswith("# SPDX-License-Identifier: Apache-2.0"))

    def test_13_sh_header(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = self.run_one(tmp, "a.sh", "echo hi\n")
            text = (out / "a.sh").read_text(encoding="utf-8")
            self.assertTrue(text.startswith("# SPDX-License-Identifier: Apache-2.0"))

    def test_14_other_ext_no_header(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = self.run_one(tmp, "a.txt", "hello\n")
            text = (out / "a.txt").read_text(encoding="utf-8")
            self.assertNotIn("SPDX-License-Identifier", text)
            self.assertEqual(text, "hello\n")

    def test_15_existing_spdx_not_added(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self.make_src(tmp, {"a.swift": "// SPDX-License-Identifier: MIT\nlet x = 1\n"})
            ap, dp, sp, kp = self.base_lists(tmp, allow=["**/*"], deny=[], symbols=[], keep=[])
            out = Path(tmp) / "out"
            r = run_tool("--src", str(src), "--out", str(out),
                         "--allowlist", str(ap), "--denylist", str(dp),
                         "--deny-symbols", str(sp), "--license-keep", str(kp),
                         "--author", AUTHOR, "--date", DATE)
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            text = (out / "a.swift").read_text(encoding="utf-8")
            self.assertEqual(text.count("SPDX-License-Identifier"), 1)

    def test_16_shebang_second_line_py(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = self.run_one(tmp, "a.py", "#!/usr/bin/env python3\nx = 1\n")
            lines = (out / "a.py").read_text(encoding="utf-8").splitlines()
            self.assertEqual(lines[0], "#!/usr/bin/env python3")
            self.assertEqual(lines[1], "# SPDX-License-Identifier: Apache-2.0")

    def test_17_shebang_second_line_sh(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = self.run_one(tmp, "a.sh", "#!/bin/sh\necho hi\n")
            lines = (out / "a.sh").read_text(encoding="utf-8").splitlines()
            self.assertEqual(lines[0], "#!/bin/sh")
            self.assertEqual(lines[1], "# SPDX-License-Identifier: Apache-2.0")

    def test_18_license_keep_untouched(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self.make_src(tmp, {"keep/me.swift": "let x = 1\n", "other.swift": "let y = 2\n"})
            ap, dp, sp, kp = self.base_lists(
                tmp, allow=["**/*.swift"], deny=[], symbols=[], keep=["keep/*"]
            )
            out = Path(tmp) / "out"
            r = run_tool("--src", str(src), "--out", str(out),
                         "--allowlist", str(ap), "--denylist", str(dp),
                         "--deny-symbols", str(sp), "--license-keep", str(kp),
                         "--author", AUTHOR, "--date", DATE)
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            kept = (out / "keep" / "me.swift").read_text(encoding="utf-8")
            other = (out / "other.swift").read_text(encoding="utf-8")
            self.assertNotIn("SPDX", kept)
            self.assertIn("SPDX", other)


class TestDenySymbols(Base):
    def test_19_deny_symbol_in_content(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self.make_src(tmp, {"a.txt": "hello InternalSecret123 world"})
            ap, dp, sp, kp = self.base_lists(
                tmp, allow=["**/*"], deny=[], symbols=["InternalSecret123"], keep=[]
            )
            out = Path(tmp) / "out"
            r = run_tool("--src", str(src), "--out", str(out),
                         "--allowlist", str(ap), "--denylist", str(dp),
                         "--deny-symbols", str(sp), "--license-keep", str(kp),
                         "--author", AUTHOR, "--date", DATE)
            self.assertEqual(r.returncode, 3)
            self.assertIn("InternalSecret123", r.stderr)

    def test_20_deny_symbol_in_filename(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self.make_src(tmp, {"mySecretFile.txt": "clean content"})
            ap, dp, sp, kp = self.base_lists(
                tmp, allow=["**/*"], deny=[], symbols=["Secret"], keep=[]
            )
            out = Path(tmp) / "out"
            r = run_tool("--src", str(src), "--out", str(out),
                         "--allowlist", str(ap), "--denylist", str(dp),
                         "--deny-symbols", str(sp), "--license-keep", str(kp),
                         "--author", AUTHOR, "--date", DATE)
            self.assertEqual(r.returncode, 3)
            self.assertIn("Secret", r.stderr)

    def test_21_output_deleted_on_deny_hit(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self.make_src(tmp, {"a.txt": "has BADTOKEN inside"})
            ap, dp, sp, kp = self.base_lists(
                tmp, allow=["**/*"], deny=[], symbols=["BADTOKEN"], keep=[]
            )
            out = Path(tmp) / "out"
            r = run_tool("--src", str(src), "--out", str(out),
                         "--allowlist", str(ap), "--denylist", str(dp),
                         "--deny-symbols", str(sp), "--license-keep", str(kp),
                         "--author", AUTHOR, "--date", DATE)
            self.assertEqual(r.returncode, 3)
            self.assertFalse(out.exists(), msg="output dir must be deleted on deny hit")

    def test_22_deny_case_sensitive(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self.make_src(tmp, {"a.txt": "has secret lowercase"})
            ap, dp, sp, kp = self.base_lists(
                tmp, allow=["**/*"], deny=[], symbols=["Secret"], keep=[]
            )
            out = Path(tmp) / "out"
            r = run_tool("--src", str(src), "--out", str(out),
                         "--allowlist", str(ap), "--denylist", str(dp),
                         "--deny-symbols", str(sp), "--license-keep", str(kp),
                         "--author", AUTHOR, "--date", DATE)
            # "Secret" != "secret", so no hit -> success.
            self.assertEqual(r.returncode, 0, msg=r.stderr)


class TestReproAndManifest(Base):
    def test_23_twice_same_commit_hash(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self.make_src(tmp, {"a.swift": "let x = 1\n", "b.py": "y = 2\n"})
            ap, dp, sp, kp = self.base_lists(tmp, allow=["**/*"], deny=[], symbols=[], keep=[])
            out1 = Path(tmp) / "out1"
            out2 = Path(tmp) / "out2"
            r1 = run_tool("--src", str(src), "--out", str(out1),
                          "--allowlist", str(ap), "--denylist", str(dp),
                          "--deny-symbols", str(sp), "--license-keep", str(kp),
                          "--author", AUTHOR, "--date", DATE)
            self.assertEqual(r1.returncode, 0, msg=r1.stderr)
            r2 = run_tool("--src", str(src), "--out", str(out2),
                          "--allowlist", str(ap), "--denylist", str(dp),
                          "--deny-symbols", str(sp), "--license-keep", str(kp),
                          "--author", AUTHOR, "--date", DATE)
            self.assertEqual(r2.returncode, 0, msg=r2.stderr)
            h1 = git_rev_parse(out1)
            h2 = git_rev_parse(out2)
            self.assertTrue(len(h1) == 40)
            self.assertEqual(h1, h2)

    def test_24_single_commit(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self.make_src(tmp, {"a.txt": "hi", "b.txt": "yo"})
            ap, dp, sp, kp = self.base_lists(tmp, allow=["**/*"], deny=[], symbols=[], keep=[])
            out = Path(tmp) / "out"
            r = run_tool("--src", str(src), "--out", str(out),
                         "--allowlist", str(ap), "--denylist", str(dp),
                         "--deny-symbols", str(sp), "--license-keep", str(kp),
                         "--author", AUTHOR, "--date", DATE)
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            c = subprocess.run(["git", "rev-list", "--count", "HEAD"], cwd=str(out),
                               env=git_env_extra(), stdout=subprocess.PIPE, text=True)
            self.assertEqual(c.stdout.strip(), "1")

    def test_25_manifest_outside_repo(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self.make_src(tmp, {"a.txt": "hi"})
            ap, dp, sp, kp = self.base_lists(tmp, allow=["**/*"], deny=[], symbols=[], keep=[])
            out = Path(tmp) / "out"
            r = run_tool("--src", str(src), "--out", str(out),
                         "--allowlist", str(ap), "--denylist", str(dp),
                         "--deny-symbols", str(sp), "--license-keep", str(kp),
                         "--author", AUTHOR, "--date", DATE)
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            mp = manifest_for(out)
            self.assertTrue(mp.exists())
            # Manifest must be outside out.
            self.assertFalse((out / mp.name).exists())
            self.assertEqual(mp.parent, out.parent)
            # Must not be tracked by git.
            ls = subprocess.run(["git", "ls-files"], cwd=str(out),
                                env=git_env_extra(), stdout=subprocess.PIPE, text=True)
            self.assertNotIn("manifest", ls.stdout)

    def test_26_manifest_contents(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self.make_src(tmp, {
                "keep.swift": "let a = 1\n",
                "skip.txt": "skip me",
                "other.txt": "other",
            })
            # allow only swift + other.txt; skip.txt excluded via denylist.
            ap, dp, sp, kp = self.base_lists(
                tmp, allow=["**/*.swift", "other.txt"], deny=["skip*"], symbols=[], keep=[]
            )
            # Add a file that is not in allowlist: extra.md
            write(src / "extra.md", "extra")
            out = Path(tmp) / "out"
            r = run_tool("--src", str(src), "--out", str(out),
                         "--allowlist", str(ap), "--denylist", str(dp),
                         "--deny-symbols", str(sp), "--license-keep", str(kp),
                         "--author", AUTHOR, "--date", DATE)
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            m = json.loads(manifest_for(out).read_text(encoding="utf-8"))
            by_path = {e["path"]: e for e in m["exported"]}
            self.assertIn("keep.swift", by_path)
            self.assertIn("other.txt", by_path)
            # sha256 matches output file.
            for rel, rec in by_path.items():
                data = (out / rel).read_bytes()
                self.assertEqual(rec["sha256"], hashlib.sha256(data).hexdigest())
                self.assertIn("header_added", rec)
                self.assertIn("license", rec)
            self.assertIn("skip.txt", m["excluded_by_denylist"])
            self.assertIn("extra.md", m["not_in_allowlist"])
            self.assertIn("skipped_symlinks", m)
            # header_added true for swift, false for txt.
            self.assertTrue(by_path["keep.swift"]["header_added"])
            self.assertEqual(by_path["keep.swift"]["license"], "Apache-2.0")
            self.assertFalse(by_path["other.txt"]["header_added"])

    def test_27_dry_run_writes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self.make_src(tmp, {"a.swift": "let x = 1\n"})
            ap, dp, sp, kp = self.base_lists(tmp, allow=["**/*"], deny=[], symbols=[], keep=[])
            out = Path(tmp) / "out"
            r = run_tool("--src", str(src), "--out", str(out),
                         "--allowlist", str(ap), "--denylist", str(dp),
                         "--deny-symbols", str(sp), "--license-keep", str(kp),
                         "--author", AUTHOR, "--date", DATE, "--dry-run")
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            self.assertFalse(out.exists())
            self.assertFalse(manifest_for(out).exists())
            self.assertIn("a.swift", r.stdout)

    def test_28_empty_allowlist_exit_2(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self.make_src(tmp, {"a.txt": "hi"})
            ap, dp, sp, kp = self.base_lists(tmp, allow=["# only comment", ""], deny=[], symbols=[], keep=[])
            out = Path(tmp) / "out"
            r = run_tool("--src", str(src), "--out", str(out),
                         "--allowlist", str(ap), "--denylist", str(dp),
                         "--deny-symbols", str(sp), "--license-keep", str(kp),
                         "--author", AUTHOR, "--date", DATE)
            self.assertEqual(r.returncode, 2)

    def test_29_exec_bit_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "src"
            src.mkdir()
            p = src / "run.sh"
            p.write_text("echo hi\n", encoding="utf-8")
            os.chmod(p, 0o755)
            ap, dp, sp, kp = self.base_lists(tmp, allow=["**/*"], deny=[], symbols=[], keep=[])
            out = Path(tmp) / "out"
            r = run_tool("--src", str(src), "--out", str(out),
                         "--allowlist", str(ap), "--denylist", str(dp),
                         "--deny-symbols", str(sp), "--license-keep", str(kp),
                         "--author", AUTHOR, "--date", DATE)
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            mode = stat.S_IMODE(os.stat(out / "run.sh").st_mode)
            self.assertTrue(mode & stat.S_IXUSR, msg=f"mode {oct(mode)} missing exec")

    def test_30_empty_selection_exit_2(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self.make_src(tmp, {"a.txt": "hi"})
            ap, dp, sp, kp = self.base_lists(tmp, allow=["nomatch/**/*.xyz"], deny=[], symbols=[], keep=[])
            out = Path(tmp) / "out"
            r = run_tool("--src", str(src), "--out", str(out),
                         "--allowlist", str(ap), "--denylist", str(dp),
                         "--deny-symbols", str(sp), "--license-keep", str(kp),
                         "--author", AUTHOR, "--date", DATE)
            self.assertEqual(r.returncode, 2)

    def test_31_src_missing_exit_2(self):
        with tempfile.TemporaryDirectory() as tmp:
            ap, dp, sp, kp = self.base_lists(tmp, allow=["**/*"], deny=[], symbols=[], keep=[])
            out = Path(tmp) / "out"
            r = run_tool("--src", str(Path(tmp) / "nope"), "--out", str(out),
                         "--allowlist", str(ap), "--denylist", str(dp),
                         "--deny-symbols", str(sp), "--license-keep", str(kp),
                         "--author", AUTHOR, "--date", DATE)
            self.assertEqual(r.returncode, 2)


class TestStrictAnchoring(Base):
    """glob 一律從 --src 根錨定（loop J 新增）。

    Muse 版原本有「無斜線樣式比對任何深度的 basename」與右側錨定的 fallback，
    讓 `release/**` 同時擋掉 `tools/release/*`、allowlist 也可能多放行。
    allowlist 多放行＝外洩方向，所以改成嚴格錨定。
    """

    def _export(self, tmp, files, allow, deny=None):
        src = self.make_src(tmp, files)
        ap, dp, sp, kp = self.base_lists(tmp, allow=allow, deny=deny, symbols=[], keep=[])
        out = Path(tmp) / "out"
        r = run_tool("--src", str(src), "--out", str(out),
                     "--allowlist", str(ap), "--denylist", str(dp),
                     "--deny-symbols", str(sp), "--license-keep", str(kp),
                     "--author", AUTHOR, "--date", DATE)
        self.assertEqual(r.returncode, 0, msg=r.stderr)
        m = json.loads(manifest_for(out).read_text(encoding="utf-8"))
        return {e["path"] for e in m["exported"]}

    def test_32_path_pattern_not_right_anchored(self):
        with tempfile.TemporaryDirectory() as tmp:
            got = self._export(tmp, {"Shared/Foo.swift": "a", "x/Shared/Foo.swift": "b"},
                               allow=["Shared/Foo.swift"])
            self.assertEqual(got, {"Shared/Foo.swift"})

    def test_33_deny_dir_glob_is_rooted(self):
        with tempfile.TemporaryDirectory() as tmp:
            got = self._export(tmp, {"release/a.txt": "a", "tools/release/b.txt": "b"},
                               allow=["**/*.txt"], deny=["release/**"])
            self.assertEqual(got, {"tools/release/b.txt"})

    def test_34_single_star_does_not_cross_slash(self):
        with tempfile.TemporaryDirectory() as tmp:
            got = self._export(tmp, {"tools/a.sh": "a", "tools/sub/b.sh": "b"}, allow=["tools/*.sh"])
            self.assertEqual(got, {"tools/a.sh"})

    def test_35_slashless_pattern_does_not_match_nested_basename(self):
        with tempfile.TemporaryDirectory() as tmp:
            got = self._export(tmp, {"a.txt": "a", "nested/b.txt": "b"}, allow=["*.txt"])
            self.assertEqual(got, {"a.txt"})

    def test_36_double_star_prefix_matches_any_depth_including_root(self):
        with tempfile.TemporaryDirectory() as tmp:
            got = self._export(tmp, {"a.sqlite": "a", "x/y/b.sqlite": "b", "c.txt": "c"},
                               allow=["**/*"], deny=["**/*.sqlite"])
            self.assertEqual(got, {"c.txt"})


class TestGitHookEnvIsolation(Base):
    """git hook 環境（GIT_DIR 等）下，工具只能寫 --out，不得碰呼叫端 repo。

    2026-10-11 事故：pre-push gate 跑本工具測試，`git init`／`commit` 繼承 hook 的 GIT_DIR，
    往工作分支寫了 56 個 fixture commit，並把主 repo 的 `core.bare` 改成 true。
    """

    @staticmethod
    def _clean_env():
        return {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}

    def _make_decoy(self, tmp):
        decoy = Path(tmp) / "decoy"
        decoy.mkdir()
        env = self._clean_env()
        env.update({"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"})
        subprocess.run(["git", "init", "-q"], cwd=decoy, env=env, check=True)
        (decoy / "keep.txt").write_text("keep\n", encoding="utf-8")
        subprocess.run(["git", "add", "-A"], cwd=decoy, env=env, check=True)
        subprocess.run(["git", "-c", "user.name=d", "-c", "user.email=d@example.invalid",
                        "commit", "-q", "-m", "decoy base"], cwd=decoy, env=env, check=True)
        return decoy, env

    def _snapshot(self, decoy, env):
        head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=decoy, env=env,
                              stdout=subprocess.PIPE, text=True, check=True).stdout.strip()
        count = subprocess.run(["git", "rev-list", "--count", "--all"], cwd=decoy, env=env,
                               stdout=subprocess.PIPE, text=True, check=True).stdout.strip()
        cfg = (decoy / ".git" / "config").read_text(encoding="utf-8")
        index = (decoy / ".git" / "index").read_bytes()
        return head, count, cfg, index

    def test_37_inherited_git_dir_does_not_touch_caller_repo(self):
        with tempfile.TemporaryDirectory() as tmp:
            decoy, cenv = self._make_decoy(tmp)
            before = self._snapshot(decoy, cenv)
            src = self.make_src(tmp, {"a.txt": "hello", "b.txt": "world"})
            ap, dp, sp, kp = self.base_lists(tmp, allow=["*.txt"], deny=[], symbols=[], keep=[])
            out = Path(tmp) / "out"
            env = dict(os.environ)  # 故意帶 hook 式變數
            env.update({
                "GIT_DIR": str(decoy / ".git"),
                "GIT_WORK_TREE": str(decoy),
                "GIT_INDEX_FILE": str(decoy / ".git" / "index"),
            })
            r = run_tool("--src", str(src), "--out", str(out),
                         "--allowlist", str(ap), "--denylist", str(dp),
                         "--deny-symbols", str(sp), "--license-keep", str(kp),
                         "--author", AUTHOR, "--date", DATE, env=env)
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            # 呼叫端 repo 完全沒變
            self.assertEqual(self._snapshot(decoy, cenv), before)
            self.assertNotIn("bare = true", (decoy / ".git" / "config").read_text(encoding="utf-8"))
            self.assertFalse((decoy / "a.txt").exists())
            # 輸出自己是獨立 repo，剛好一個 commit
            self.assertTrue((out / ".git").is_dir())
            count = subprocess.run(["git", "rev-list", "--count", "HEAD"], cwd=out,
                                   env=git_env_extra(), stdout=subprocess.PIPE, text=True).stdout.strip()
            self.assertEqual(count, "1")

    def test_38_tool_commit_hash_same_with_and_without_inherited_git_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            decoy, _ = self._make_decoy(tmp)
            src = self.make_src(tmp, {"a.txt": "hello"})
            ap, dp, sp, kp = self.base_lists(tmp, allow=["*.txt"], deny=[], symbols=[], keep=[])
            hashes = []
            for name, extra in (("o1", {}), ("o2", {"GIT_DIR": str(decoy / ".git")})):
                out = Path(tmp) / name
                env = dict(os.environ)
                env.update(extra)
                r = run_tool("--src", str(src), "--out", str(out),
                             "--allowlist", str(ap), "--denylist", str(dp),
                             "--deny-symbols", str(sp), "--license-keep", str(kp),
                             "--author", AUTHOR, "--date", DATE, env=env)
                self.assertEqual(r.returncode, 0, msg=r.stderr)
                hashes.append(git_rev_parse(out))
            self.assertEqual(hashes[0], hashes[1])


class TestOverlay(Base):
    def test_39_overlay_file_copied_as_is_and_in_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self.make_src(tmp, {"a.txt": "from-src"})
            overlay = Path(tmp) / "overlay"
            write(overlay / "extra" / "note.swift", "let overlayOnly = 1\n")
            ap, dp, sp, kp = self.base_lists(tmp, allow=["*.txt"], deny=[], symbols=[], keep=[])
            out = Path(tmp) / "out"
            r = run_tool("--src", str(src), "--out", str(out),
                         "--allowlist", str(ap), "--denylist", str(dp),
                         "--deny-symbols", str(sp), "--license-keep", str(kp),
                         "--overlay", str(overlay),
                         "--author", AUTHOR, "--date", DATE)
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            body = (out / "extra" / "note.swift").read_text(encoding="utf-8")
            self.assertEqual(body, "let overlayOnly = 1\n")
            self.assertNotIn("SPDX-License-Identifier", body)
            m = json.loads(manifest_for(out).read_text(encoding="utf-8"))
            self.assertEqual(m["overlay"], ["extra/note.swift"])
            by_path = {e["path"]: e for e in m["exported"]}
            self.assertTrue(by_path["extra/note.swift"]["from_overlay"])
            self.assertFalse(by_path["extra/note.swift"]["header_added"])
            self.assertIsNone(by_path["extra/note.swift"]["license"])
            self.assertFalse(by_path["a.txt"]["from_overlay"])
            ls = subprocess.run(["git", "ls-files"], cwd=str(out), env=git_env_extra(),
                                stdout=subprocess.PIPE, text=True)
            self.assertIn("extra/note.swift", ls.stdout)

    def test_40_overlay_overwrites_same_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self.make_src(tmp, {"a.swift": "let fromSrc = 1\n"})
            overlay = Path(tmp) / "overlay"
            write(overlay / "a.swift", "let fromOverlay = 2\n")
            ap, dp, sp, kp = self.base_lists(tmp, allow=["**/*.swift"], deny=[], symbols=[], keep=[])
            out = Path(tmp) / "out"
            r = run_tool("--src", str(src), "--out", str(out),
                         "--allowlist", str(ap), "--denylist", str(dp),
                         "--deny-symbols", str(sp), "--license-keep", str(kp),
                         "--overlay", str(overlay),
                         "--author", AUTHOR, "--date", DATE)
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            self.assertEqual((out / "a.swift").read_text(encoding="utf-8"), "let fromOverlay = 2\n")
            m = json.loads(manifest_for(out).read_text(encoding="utf-8"))
            rec = {e["path"]: e for e in m["exported"]}["a.swift"]
            self.assertTrue(rec["from_overlay"])
            self.assertFalse(rec["header_added"])
            self.assertEqual(rec["sha256"], hashlib.sha256(b"let fromOverlay = 2\n").hexdigest())

    def test_41_overlay_content_deny_deletes_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self.make_src(tmp, {"a.txt": "ok"})
            overlay = Path(tmp) / "overlay"
            write(overlay / "bad.txt", "contains SecretToken here")
            ap, dp, sp, kp = self.base_lists(
                tmp, allow=["*.txt"], deny=[], symbols=["SecretToken"], keep=[]
            )
            out = Path(tmp) / "out"
            r = run_tool("--src", str(src), "--out", str(out),
                         "--allowlist", str(ap), "--denylist", str(dp),
                         "--deny-symbols", str(sp), "--license-keep", str(kp),
                         "--overlay", str(overlay),
                         "--author", AUTHOR, "--date", DATE)
            self.assertEqual(r.returncode, 3, msg=r.stderr)
            self.assertIn("bad.txt", r.stderr)
            self.assertIn("SecretToken", r.stderr)
            self.assertFalse(out.exists())

    def test_42_overlay_filename_deny(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self.make_src(tmp, {"a.txt": "ok"})
            overlay = Path(tmp) / "overlay"
            write(overlay / "SecretToken.txt", "plain")
            ap, dp, sp, kp = self.base_lists(
                tmp, allow=["*.txt"], deny=[], symbols=["SecretToken"], keep=[]
            )
            out = Path(tmp) / "out"
            r = run_tool("--src", str(src), "--out", str(out),
                         "--allowlist", str(ap), "--denylist", str(dp),
                         "--deny-symbols", str(sp), "--license-keep", str(kp),
                         "--overlay", str(overlay),
                         "--author", AUTHOR, "--date", DATE)
            self.assertEqual(r.returncode, 3, msg=r.stderr)
            self.assertIn("filename", r.stderr)
            self.assertFalse(out.exists())

    def test_43_overlay_dry_run_writes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self.make_src(tmp, {"a.txt": "ok"})
            overlay = Path(tmp) / "overlay"
            write(overlay / "b.txt", "bee")
            ap, dp, sp, kp = self.base_lists(tmp, allow=["*.txt"], deny=[], symbols=[], keep=[])
            out = Path(tmp) / "out"
            r = run_tool("--src", str(src), "--out", str(out),
                         "--allowlist", str(ap), "--denylist", str(dp),
                         "--deny-symbols", str(sp), "--license-keep", str(kp),
                         "--overlay", str(overlay),
                         "--author", AUTHOR, "--date", DATE, "--dry-run")
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            self.assertFalse(out.exists())
            self.assertFalse(manifest_for(out).exists())
            self.assertIn("b.txt", r.stdout)
            self.assertIn("overlay:", r.stdout)

    def test_44_overlay_missing_exit_2(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self.make_src(tmp, {"a.txt": "ok"})
            ap, dp, sp, kp = self.base_lists(tmp, allow=["*.txt"], deny=[], symbols=[], keep=[])
            out = Path(tmp) / "out"
            r = run_tool("--src", str(src), "--out", str(out),
                         "--allowlist", str(ap), "--denylist", str(dp),
                         "--deny-symbols", str(sp), "--license-keep", str(kp),
                         "--overlay", str(Path(tmp) / "no-such-overlay"),
                         "--author", AUTHOR, "--date", DATE)
            self.assertEqual(r.returncode, 2, msg=r.stderr)
            self.assertFalse(out.exists())

    def test_45_overlay_exec_bit_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self.make_src(tmp, {"a.txt": "ok"})
            overlay = Path(tmp) / "overlay"
            write(overlay / "run.sh", "#!/bin/sh\necho hi\n", mode=0o755)
            ap, dp, sp, kp = self.base_lists(tmp, allow=["*.txt"], deny=[], symbols=[], keep=[])
            out = Path(tmp) / "out"
            r = run_tool("--src", str(src), "--out", str(out),
                         "--allowlist", str(ap), "--denylist", str(dp),
                         "--deny-symbols", str(sp), "--license-keep", str(kp),
                         "--overlay", str(overlay),
                         "--author", AUTHOR, "--date", DATE)
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            mode = stat.S_IMODE((out / "run.sh").stat().st_mode)
            self.assertTrue(mode & stat.S_IXUSR)
            text = (out / "run.sh").read_text(encoding="utf-8")
            self.assertTrue(text.startswith("#!/bin/sh\n"))
            self.assertNotIn("SPDX-License-Identifier", text)

    def test_46_overlay_symlink_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self.make_src(tmp, {"a.txt": "ok"})
            overlay = Path(tmp) / "overlay"
            overlay.mkdir()
            write(overlay / "real.txt", "real")
            os.symlink("real.txt", overlay / "link.txt")
            ap, dp, sp, kp = self.base_lists(tmp, allow=["*.txt"], deny=[], symbols=[], keep=[])
            out = Path(tmp) / "out"
            r = run_tool("--src", str(src), "--out", str(out),
                         "--allowlist", str(ap), "--denylist", str(dp),
                         "--deny-symbols", str(sp), "--license-keep", str(kp),
                         "--overlay", str(overlay),
                         "--author", AUTHOR, "--date", DATE)
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            self.assertTrue((out / "real.txt").exists())
            self.assertFalse((out / "link.txt").exists())
            m = json.loads(manifest_for(out).read_text(encoding="utf-8"))
            self.assertIn("link.txt", m["skipped_symlinks"])

    def test_47_no_overlay_manifest_has_empty_overlay_list(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self.make_src(tmp, {"a.txt": "ok"})
            ap, dp, sp, kp = self.base_lists(tmp, allow=["*.txt"], deny=[], symbols=[], keep=[])
            out = Path(tmp) / "out"
            r = run_tool("--src", str(src), "--out", str(out),
                         "--allowlist", str(ap), "--denylist", str(dp),
                         "--deny-symbols", str(sp), "--license-keep", str(kp),
                         "--author", AUTHOR, "--date", DATE)
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            m = json.loads(manifest_for(out).read_text(encoding="utf-8"))
            self.assertEqual(m["overlay"], [])
            self.assertFalse(m["exported"][0]["from_overlay"])


class TestOverlayDenylistAndDryRunScan(Base):
    """code-review high 的兩條：overlay 不能繞過 denylist（.pyc 帶著本機路徑進了匯出樹）、
    dry-run 要跟真跑一樣掃禁字（否則「先 dry-run 預檢」會誤導）。"""

    def _run(self, tmp, src, overlay, deny, symbols, extra=()):
        ap, dp, sp, kp = self.base_lists(tmp, allow=["*.txt"], deny=deny, symbols=symbols, keep=[])
        out = Path(tmp) / "out"
        args = ["--src", str(src), "--out", str(out),
                "--allowlist", str(ap), "--denylist", str(dp),
                "--deny-symbols", str(sp), "--license-keep", str(kp),
                "--author", AUTHOR, "--date", DATE]
        if overlay is not None:
            args += ["--overlay", str(overlay)]
        return out, run_tool(*args, *extra)

    def test_48_overlay_files_matching_denylist_are_not_exported(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self.make_src(tmp, {"a.txt": "ok"})
            overlay = Path(tmp) / "overlay"
            write(overlay / "tools" / "x" / "keep.txt", "keep")
            write(overlay / "tools" / "x" / "__pycache__" / "m.cpython-312.pyc", "binary-ish")
            write(overlay / ".DS_Store", "junk")
            out, r = self._run(
                tmp, src, overlay,
                deny=["**/__pycache__/**", "**/*.pyc", "**/.DS_Store"], symbols=[])
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            self.assertTrue((out / "tools" / "x" / "keep.txt").is_file())
            self.assertFalse((out / "tools" / "x" / "__pycache__").exists())
            self.assertFalse((out / ".DS_Store").exists())
            m = json.loads(manifest_for(out).read_text(encoding="utf-8"))
            self.assertEqual(m["overlay"], ["tools/x/keep.txt"])
            self.assertEqual(
                sorted(m["overlay_excluded_by_denylist"]),
                [".DS_Store", "tools/x/__pycache__/m.cpython-312.pyc"])

    def test_49_dry_run_reports_deny_symbol_hits_and_exits_3(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self.make_src(tmp, {"a.txt": "hello InternalSecret123 world"})
            out, r = self._run(tmp, src, None, deny=[], symbols=["InternalSecret123"],
                               extra=("--dry-run",))
            self.assertEqual(r.returncode, 3, msg=r.stdout + r.stderr)
            self.assertIn("InternalSecret123", r.stderr)
            self.assertFalse(out.exists())
            self.assertFalse(manifest_for(out).exists())

    def test_50_dry_run_overlay_filename_hit_exits_3(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self.make_src(tmp, {"a.txt": "ok"})
            overlay = Path(tmp) / "overlay"
            write(overlay / "SecretToken.txt", "plain")
            out, r = self._run(tmp, src, overlay, deny=[], symbols=["SecretToken"],
                               extra=("--dry-run",))
            self.assertEqual(r.returncode, 3, msg=r.stdout + r.stderr)
            self.assertIn("filename", r.stderr)
            self.assertFalse(out.exists())


class TestPathMap(Base):
    """--path-map：匯出層把來源路徑對應成公開樹路徑（目錄改名、單檔改名、文字內容的路徑字樣）。

    規則：allow／deny／license_keep 一律用「來源路徑」判斷（先判後改名，否則
    denylist 擋不到改名後的檔）；overlay 已是公開樹佈局，不改名、不改內容，且蓋掉同一公開路徑的來源檔。
    本檔會被匯出，所以這裡只用假名字（OldDir／NewDir）；真名字的測試在 test_check_lists.py。"""

    MAP = [
        "# 測試用對應表",
        "path OldDir/OldDir.entitlements => NewDir/NewDir.entitlements",
        "path OldDir/ => NewDir/",
        "text OldDir.entitlements => NewDir.entitlements",
        "text OldDir/ => NewDir/",
        "skip-text Vendor/**",
    ]

    def _run(self, tmp, files, allow, deny=None, symbols=None, overlay_files=None,
             map_lines=None, extra=(), keep=None):
        src = self.make_src(tmp, files)
        ap, dp, sp, kp = self.base_lists(tmp, allow=allow, deny=deny if deny is not None else [],
                                         symbols=symbols if symbols is not None else [],
                                         keep=keep if keep is not None else [])
        mp = Path(tmp) / "pathmap.txt"
        write_list(mp, map_lines if map_lines is not None else self.MAP)
        out = Path(tmp) / "out"
        args = ["--src", str(src), "--out", str(out),
                "--allowlist", str(ap), "--denylist", str(dp),
                "--deny-symbols", str(sp), "--license-keep", str(kp),
                "--path-map", str(mp),
                "--author", AUTHOR, "--date", DATE]
        if overlay_files is not None:
            ov = Path(tmp) / "overlay"
            for rel, content in overlay_files.items():
                write(ov / rel, content)
            args += ["--overlay", str(ov)]
        return out, run_tool(*args, *extra)

    def _tracked(self, out):
        r = subprocess.run(["git", "ls-files"], cwd=str(out), env=git_env_extra(),
                           stdout=subprocess.PIPE, text=True)
        return sorted(r.stdout.split())

    def test_51_directory_prefix_is_renamed(self):
        with tempfile.TemporaryDirectory() as tmp:
            out, r = self._run(tmp, {"OldDir/sub/a.txt": "x", "top.txt": "y"}, allow=["**/*.txt"])
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            self.assertEqual(self._tracked(out), ["NewDir/sub/a.txt", "top.txt"])
            self.assertFalse((out / "OldDir").exists())

    def test_52_allow_and_deny_are_judged_on_source_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            files = {"OldDir/a.txt": "x", "OldDir/closed/c.txt": "secret"}
            out, r = self._run(tmp, files, allow=["OldDir/**"], deny=["OldDir/closed/**"])
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            self.assertEqual(self._tracked(out), ["NewDir/a.txt"])
            m = json.loads(manifest_for(out).read_text(encoding="utf-8"))
            self.assertEqual(m["excluded_by_denylist"], ["OldDir/closed/c.txt"])
        with tempfile.TemporaryDirectory() as tmp:
            # 公開名字寫進 allowlist 不算數：來源裡沒有這個路徑，等於沒選到任何檔。
            out, r = self._run(tmp, {"OldDir/a.txt": "x"}, allow=["NewDir/**"])
            self.assertEqual(r.returncode, 2, msg=r.stderr)
            self.assertFalse(out.exists())

    def test_53_single_file_rule_beats_directory_rule(self):
        with tempfile.TemporaryDirectory() as tmp:
            out, r = self._run(tmp, {"OldDir/OldDir.entitlements": "e", "OldDir/b.txt": "b"},
                               allow=["OldDir/**"])
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            self.assertEqual(self._tracked(out), ["NewDir/NewDir.entitlements", "NewDir/b.txt"])

    def test_54_overlay_replaces_mapped_source_and_is_not_rewritten(self):
        with tempfile.TemporaryDirectory() as tmp:
            files = {"OldDir/NewDir.plist": "official id=A OldDir/x", "OldDir/OldDir.entitlements": "official"}
            overlay = {"NewDir/NewDir.plist": "oss id=B OldDir/literal",
                       "NewDir/NewDir.entitlements": "oss"}
            out, r = self._run(tmp, files, allow=["OldDir/**"], overlay_files=overlay)
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            self.assertEqual((out / "NewDir/NewDir.plist").read_text(encoding="utf-8"), "oss id=B OldDir/literal")
            self.assertEqual((out / "NewDir/NewDir.entitlements").read_text(encoding="utf-8"), "oss")
            self.assertEqual(self._tracked(out), ["NewDir/NewDir.entitlements", "NewDir/NewDir.plist"])
            m = json.loads(manifest_for(out).read_text(encoding="utf-8"))
            by_path = {e["path"]: e for e in m["exported"]}
            self.assertTrue(by_path["NewDir/NewDir.entitlements"]["from_overlay"])
            self.assertEqual(m["overlay"], ["NewDir/NewDir.entitlements", "NewDir/NewDir.plist"])
            self.assertEqual(m["text_rewritten"], [])   # 被 overlay 蓋掉的檔不算「改過內容」

    def test_55_text_rule_rewrites_first_party_text_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            files = {
                "OldDir/a.swift": "// see OldDir/b.swift and OldDir.entitlements\nlet x = 1\n",
                "Vendor/up.txt": "upstream mentions OldDir/ verbatim\n",
                "OldDir/blob.bin": b"\xff\xfeOldDir/\x00",
            }
            out, r = self._run(tmp, files, allow=["**/*"])
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            body = (out / "NewDir/a.swift").read_text(encoding="utf-8")
            self.assertEqual(
                body,
                "// SPDX-License-Identifier: Apache-2.0\n"
                "// see NewDir/b.swift and NewDir.entitlements\nlet x = 1\n")
            self.assertEqual((out / "Vendor/up.txt").read_text(encoding="utf-8"),
                             "upstream mentions OldDir/ verbatim\n")
            self.assertEqual((out / "NewDir/blob.bin").read_bytes(), b"\xff\xfeOldDir/\x00")
            m = json.loads(manifest_for(out).read_text(encoding="utf-8"))
            self.assertEqual(m["text_rewritten"], ["NewDir/a.swift"])
            rec = {e["path"]: e for e in m["exported"]}["NewDir/a.swift"]
            self.assertEqual(rec["sha256"], hashlib.sha256(body.encode("utf-8")).hexdigest())

    def test_56_two_sources_mapping_to_one_path_is_an_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            files = {"OldDir/a.txt": "one", "NewDir/a.txt": "two"}
            out, r = self._run(tmp, files, allow=["**/*.txt"])
            self.assertEqual(r.returncode, 2, msg=r.stderr)
            self.assertIn("NewDir/a.txt", r.stderr)
            self.assertFalse(out.exists())

    def test_57_manifest_records_the_mapping(self):
        with tempfile.TemporaryDirectory() as tmp:
            out, r = self._run(tmp, {"OldDir/a.txt": "x", "top.txt": "y"}, allow=["**/*.txt"])
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            m = json.loads(manifest_for(out).read_text(encoding="utf-8"))
            self.assertEqual(m["path_map"], {"OldDir/a.txt": "NewDir/a.txt"})
            self.assertEqual(m["text_rewritten"], [])

    def test_58_deny_symbols_scan_the_mapped_output_in_dry_run_too(self):
        with tempfile.TemporaryDirectory() as tmp:
            # 禁字是公開名字：只存在於改名後的輸出，乾跑也要抓到（乾跑綠＝真跑綠）。
            out, r = self._run(tmp, {"OldDir/a.txt": "x"}, allow=["**/*.txt"],
                               symbols=["NewDir"], extra=("--dry-run",))
            self.assertEqual(r.returncode, 3, msg=r.stdout + r.stderr)
            self.assertIn("NewDir/a.txt", r.stderr)
            self.assertFalse(out.exists())
        with tempfile.TemporaryDirectory() as tmp:
            # 禁字是舊名字：改名＋改內容之後輸出裡一個都沒有，所以通過（用來鎖「舊名字＝0」）。
            out, r = self._run(tmp, {"OldDir/a.txt": "see OldDir/a.txt"}, allow=["**/*.txt"],
                               symbols=["OldDir"])
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            self.assertEqual((out / "NewDir/a.txt").read_text(encoding="utf-8"), "see NewDir/a.txt")

    def test_59_dry_run_lists_mapped_paths_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            out, r = self._run(tmp, {"OldDir/a.txt": "x"}, allow=["**/*.txt"], extra=("--dry-run",))
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            self.assertIn("NewDir/a.txt", r.stdout)
            self.assertNotIn("\nOldDir/a.txt\n", r.stdout)
            self.assertFalse(out.exists())
            self.assertFalse(manifest_for(out).exists())

    def test_60_bad_map_file_exits_2(self):
        with tempfile.TemporaryDirectory() as tmp:
            out, r = self._run(tmp, {"a.txt": "x"}, allow=["*.txt"], map_lines=["path only-one-side"])
            self.assertEqual(r.returncode, 2, msg=r.stderr)
            self.assertFalse(out.exists())
        with tempfile.TemporaryDirectory() as tmp:
            out, r = self._run(tmp, {"a.txt": "x"}, allow=["*.txt"], map_lines=["path a/ => b"])
            self.assertEqual(r.returncode, 2, msg=r.stderr)    # 目錄規則兩邊都要以 / 結尾
        with tempfile.TemporaryDirectory() as tmp:
            out, r = self._run(tmp, {"a.txt": "x"}, allow=["*.txt"], map_lines=["bogus a => b"])
            self.assertEqual(r.returncode, 2, msg=r.stderr)
        with tempfile.TemporaryDirectory() as tmp:
            src = self.make_src(tmp, {"a.txt": "x"})
            ap, dp, sp, kp = self.base_lists(tmp, allow=["*.txt"], deny=[], symbols=[], keep=[])
            r = run_tool("--src", str(src), "--out", str(Path(tmp) / "out"),
                         "--allowlist", str(ap), "--denylist", str(dp),
                         "--deny-symbols", str(sp), "--license-keep", str(kp),
                         "--path-map", str(Path(tmp) / "missing.txt"))
            self.assertEqual(r.returncode, 2, msg=r.stderr)

    def test_62_overlay_keep_exempts_only_the_listed_files_from_the_denylist(self):
        """denylist 的規則錨定在「來源」根目錄（來源的 docs/** 是內部文件），而 overlay 已是公開樹佈局，
        公開樹的 docs/BUILDING.md 會被誤擋。overlay-keep 只豁免列出的那個檔；同目錄其他 overlay 檔、
        垃圾檔照擋（不是整個 overlay 不檢查）。"""
        with tempfile.TemporaryDirectory() as tmp:
            overlay = {"docs/KEEP.md": "public", "docs/OTHER.md": "still blocked",
                       "docs/__pycache__/x.pyc": "junk"}
            out, r = self._run(
                tmp, {"top.txt": "x"}, allow=["*.txt"],
                deny=["docs/**", "**/__pycache__/**"],
                overlay_files=overlay,
                map_lines=self.MAP + ["overlay-keep docs/KEEP.md"])
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            self.assertEqual(self._tracked(out), ["docs/KEEP.md", "top.txt"])
            m = json.loads(manifest_for(out).read_text(encoding="utf-8"))
            self.assertEqual(sorted(m["overlay_excluded_by_denylist"]),
                             ["docs/OTHER.md", "docs/__pycache__/x.pyc"])

    def test_63_overlay_keep_takes_exact_paths_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            out, r = self._run(
                tmp, {"top.txt": "x"}, allow=["*.txt"], deny=["docs/**"],
                overlay_files={"docs/A.md": "a"}, map_lines=self.MAP + ["overlay-keep docs/**"])
            self.assertEqual(r.returncode, 2, msg=r.stderr)    # 萬用字元會讓豁免範圍失控，不接受
            self.assertFalse(out.exists())

    def test_61_without_path_map_nothing_is_renamed(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = self.make_src(tmp, {"OldDir/a.txt": "see OldDir/b"})
            ap, dp, sp, kp = self.base_lists(tmp, allow=["**/*.txt"], deny=[], symbols=[], keep=[])
            out = Path(tmp) / "out"
            r = run_tool("--src", str(src), "--out", str(out),
                         "--allowlist", str(ap), "--denylist", str(dp),
                         "--deny-symbols", str(sp), "--license-keep", str(kp),
                         "--author", AUTHOR, "--date", DATE)
            self.assertEqual(r.returncode, 0, msg=r.stderr)
            self.assertEqual((out / "OldDir/a.txt").read_text(encoding="utf-8"), "see OldDir/b")
            m = json.loads(manifest_for(out).read_text(encoding="utf-8"))
            self.assertEqual(m["path_map"], {})
            self.assertEqual(m["text_rewritten"], [])


if __name__ == "__main__":
    unittest.main()
