# SPDX-License-Identifier: Apache-2.0
"""conftest.py 的回歸測試：收集階段必須已把繼承來的 GIT_* 從 os.environ 清掉。

驗法（git hook 環境）：`GIT_DIR=/some/repo/.git pytest tools/oss/test_oss_git_env_scrub.py` 要全綠。
"""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


class ConftestScrubsGitEnv(unittest.TestCase):
    def test_no_git_variables_in_environ_during_tests(self):
        leaked = sorted(k for k in os.environ if k.startswith("GIT_"))
        self.assertEqual(leaked, [])

    def test_pytest_with_decoy_git_dir_sees_clean_environ(self):
        """誘餌 GIT_DIR 丟進 pytest 子行程：收集後 environ 不得再有 GIT_*，且誘餌 repo 不被動到。"""
        with tempfile.TemporaryDirectory() as tmp:
            decoy = Path(tmp) / "decoy.git"
            subprocess.run(["git", "init", "-q", "--bare", str(decoy)], check=True,
                           env={k: v for k, v in os.environ.items() if not k.startswith("GIT_")})
            before = sorted(p.name for p in decoy.iterdir())
            cfg_before = (decoy / "config").read_text()
            env = dict(os.environ)
            env["GIT_DIR"] = str(decoy)
            env["GIT_INDEX_FILE"] = str(Path(tmp) / "decoy.index")
            env["GIT_WORK_TREE"] = tmp
            r = subprocess.run(
                [sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider",
                 str(HERE / "test_oss_git_env_scrub.py") + "::ConftestScrubsGitEnv::test_no_git_variables_in_environ_during_tests"],
                cwd=str(HERE), env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            )
            self.assertEqual(r.returncode, 0, msg=r.stdout + r.stderr)
            self.assertEqual(sorted(p.name for p in decoy.iterdir()), before)
            self.assertEqual((decoy / "config").read_text(), cfg_before)


if __name__ == "__main__":
    unittest.main()
