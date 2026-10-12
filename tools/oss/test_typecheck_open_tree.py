# SPDX-License-Identifier: Apache-2.0
"""typecheck_open_tree.py 的測試：用合成的小樹驗證「只編開放集合、列出未解析符號、容許名單」。

不碰真實 repo 內容。需要 swiftc；沒有就整支跳過。
"""
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
TOOL = HERE / "typecheck_open_tree.py"

HAVE_SWIFTC = shutil.which("swiftc") is not None


def make_tree(root: Path, files: dict, allow: list, deny: list = ()):
    for rel, text in files.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")
    lists = root / "tools" / "oss"
    lists.mkdir(parents=True, exist_ok=True)
    (lists / "allowlist.txt").write_text("\n".join(allow) + "\n", encoding="utf-8")
    (lists / "denylist.txt").write_text("\n".join(deny) + "\n", encoding="utf-8")


def run_tool(root: Path, *extra):
    return subprocess.run(
        [sys.executable, "-I", str(TOOL), "--src", str(root), "--work", str(root / "_work"), *extra],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )


@unittest.skipUnless(HAVE_SWIFTC, "需要 swiftc")
class TypecheckOpenTree(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_clean_open_tree_passes(self):
        make_tree(self.root, {"Shell/A.swift": "struct A { var x = 1 }\n"}, ["Shell/**"])
        r = run_tool(self.root)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("unexpected=0", r.stdout)

    def test_unresolved_symbol_is_reported_and_fails(self):
        make_tree(self.root, {"Shell/A.swift": "struct A { var e = SecretCoreEngine() }\n"}, ["Shell/**"])
        r = run_tool(self.root)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("SecretCoreEngine", r.stdout)
        self.assertIn("unexpected=1", r.stdout)

    def test_allow_missing_tolerates_named_gap_only(self):
        make_tree(self.root, {"Shell/A.swift": "struct A { var e = BasicEngine(); var f = OtherCore() }\n"},
                  ["Shell/**"])
        r = run_tool(self.root, "--allow-missing", "BasicEngine")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("OtherCore", r.stdout)
        self.assertIn("tolerated=1", r.stdout)
        self.assertIn("unexpected=1", r.stdout)

    def test_denied_file_is_not_compiled(self):
        # denylist 內的檔不進開放樹，所以引用它的符號就是未解析（真實情況＝外殼還依賴被排除的檔）。
        make_tree(
            self.root,
            {"Shell/A.swift": "struct A { var c = Core() }\n", "Shell/Closed/C.swift": "struct Core {}\n"},
            ["Shell/**"], ["Shell/Closed/**"],
        )
        r = run_tool(self.root)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("Core", r.stdout)

    def test_does_not_modify_source_tree(self):
        make_tree(self.root, {"Shell/A.swift": "struct A {}\n"}, ["Shell/**"])
        before = sorted(p.relative_to(self.root).as_posix() for p in self.root.rglob("*") if "_work" not in p.parts)
        run_tool(self.root)
        after = sorted(p.relative_to(self.root).as_posix() for p in self.root.rglob("*") if "_work" not in p.parts)
        self.assertEqual(before, after)


if __name__ == "__main__":
    unittest.main()
