"""Automated tests for check_lexicon.py (standard library only).

Run from the lexcheck folder with either:
  python3 -m pytest -q
  python3 -m unittest discover -v -s tests
"""

import contextlib
import io
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(
    0, os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)

import check_lexicon as lex

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def run_main(args):
    out = io.StringIO()
    err = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = lex.main(args)
    return code, out.getvalue(), err.getvalue()


class TempWorkDir(unittest.TestCase):
    def setUp(self):
        # Keep every temp file inside lexcheck/ (task constraint).
        self.tmp = tempfile.mkdtemp(prefix="lextest_", dir=REPO_ROOT)
        self.seen = {}

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def make_text(self, name, text):
        path = os.path.join(self.tmp, name)
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        return path

    def make_bytes(self, name, data):
        path = os.path.join(self.tmp, name)
        with open(path, "wb") as f:
            f.write(data)
        return path

    def check_text(self, name, text, seen=None):
        path = self.make_text(name, text)
        if seen is None:
            seen = {}
        return path, lex.check_file(path, seen)


class TestSyllableValidity(unittest.TestCase):
    def test_first_tone_unmarked_ok(self):
        self.assertTrue(lex.is_valid_syllable("ㄊㄞ"))

    def test_second_tone_ok(self):
        self.assertTrue(lex.is_valid_syllable("ㄊㄞˊ"))

    def test_third_tone_ok(self):
        self.assertTrue(lex.is_valid_syllable("ㄋㄧˇ"))

    def test_fourth_tone_ok(self):
        self.assertTrue(lex.is_valid_syllable("ㄨㄢˋ"))

    def test_neutral_front_ok(self):
        self.assertTrue(lex.is_valid_syllable("˙ㄇㄚ"))

    # R2-10：資料與引擎用後置輕聲（ㄉㄜ˙），舊版只收前置並把後置報 E004，
    # 等於拒收所有真實資料。現在前置、後置都收，內部統一成後置。
    def test_neutral_back_ok(self):
        self.assertTrue(lex.is_valid_syllable("ㄇㄚ˙"))

    def test_neutral_both_sides_rejected(self):
        self.assertFalse(lex.is_valid_syllable("˙ㄇㄚ˙"))

    def test_neutral_alone_rejected(self):
        self.assertFalse(lex.is_valid_syllable("˙"))

    def test_neutral_with_another_tone_rejected(self):
        self.assertFalse(lex.is_valid_syllable("ㄇㄚˊ˙"))
        self.assertFalse(lex.is_valid_syllable("˙ㄇㄚˊ"))

    def test_normalize_syllable_moves_neutral_to_the_back(self):
        self.assertEqual(lex.normalize_syllable("˙ㄉㄜ"), "ㄉㄜ˙")
        self.assertEqual(lex.normalize_syllable("ㄉㄜ˙"), "ㄉㄜ˙")
        self.assertEqual(lex.normalize_syllable("ㄉㄜˊ"), "ㄉㄜˊ")
        self.assertEqual(lex.normalize_syllable("˙ㄉㄜ˙"), "˙ㄉㄜ˙")  # 壞輸入原樣留給檢查器報錯

    def test_normalize_reading_per_syllable(self):
        self.assertEqual(lex.normalize_reading("ㄇㄚ˙"), "ㄇㄚ˙")
        self.assertEqual(lex.normalize_reading("ㄔㄜ-˙ㄗ"), "ㄔㄜ-ㄗ˙")
        self.assertEqual(lex.normalize_reading("˙ㄇㄚ-ㄊㄞˊ"), "ㄇㄚ˙-ㄊㄞˊ")

    def test_lone_empty_rhyme_initial_ok(self):
        for s in ["ㄓ", "ㄔ", "ㄕ", "ㄖ", "ㄗ", "ㄘ", "ㄙ"]:
            self.assertTrue(lex.is_valid_syllable(s), s)

    def test_lone_nonempty_initial_rejected(self):
        self.assertFalse(lex.is_valid_syllable("ㄅ"))

    def test_bare_rhyme_zero_initial_ok(self):
        self.assertTrue(lex.is_valid_syllable("ㄚ"))

    def test_standalone_medial_ok(self):
        self.assertTrue(lex.is_valid_syllable("ㄧ"))

    def test_er_alone_ok(self):
        self.assertTrue(lex.is_valid_syllable("ㄦ"))

    def test_initial_plus_er_rejected(self):
        self.assertFalse(lex.is_valid_syllable("ㄅㄦ"))

    def test_kongyun_omitted_rejected(self):
        self.assertFalse(lex.is_valid_syllable("ㄭ"))
        self.assertFalse(lex.is_valid_syllable("ㄓㄭ"))

    def test_first_tone_mark_rejected(self):
        self.assertFalse(lex.is_valid_syllable("ㄅㄚˉ"))

    def test_double_tone_rejected(self):
        self.assertFalse(lex.is_valid_syllable("ㄅㄚˊˋ"))

    def test_tone_in_middle_rejected(self):
        self.assertFalse(lex.is_valid_syllable("ㄅˊㄚ"))

    def test_j_with_i_ok(self):
        self.assertTrue(lex.is_valid_syllable("ㄐㄧㄚ"))

    def test_j_without_i_or_u_rejected(self):
        self.assertFalse(lex.is_valid_syllable("ㄐㄚ"))

    def test_z_with_i_rejected(self):
        self.assertFalse(lex.is_valid_syllable("ㄗㄧㄚ"))

    def test_z_with_u_ok(self):
        self.assertTrue(lex.is_valid_syllable("ㄗㄨㄛ"))

    def test_sh_with_i_rejected(self):
        self.assertFalse(lex.is_valid_syllable("ㄕㄧ"))

    def test_empty_rejected(self):
        self.assertFalse(lex.is_valid_syllable(""))

    def test_latin_rejected(self):
        self.assertFalse(lex.is_valid_syllable("a"))

    def test_reading_join_ok(self):
        self.assertTrue(lex.is_valid_reading("ㄊㄞˊ-ㄨㄢ"))

    def test_reading_edge_dash_rejected(self):
        self.assertFalse(lex.is_valid_reading("-ㄊㄞˊ"))
        self.assertFalse(lex.is_valid_reading("ㄊㄞˊ-"))
        self.assertFalse(lex.is_valid_reading("ㄊㄞˊ--ㄨㄢ"))

    def test_simplified_table_has_100_entries(self):
        self.assertEqual(len(lex.SIMPLIFIED_TO_TRADITIONAL), 100)

    def test_is_url_accepts_https(self):
        self.assertTrue(lex.is_url("https://example.com/x"))

    def test_is_url_rejects_plain_word(self):
        self.assertFalse(lex.is_url("not-a-url"))


class TestLineChecks(TempWorkDir):
    def test_valid_line_passes(self):
        _p, issues = self.check_text("a.tsv", "台灣\tㄊㄞˊ-ㄨㄢ\t常用\n")
        self.assertEqual(issues, [])

    def test_e001_two_columns(self):
        _p, issues = self.check_text("a.tsv", "台灣\tㄊㄞˊ-ㄨㄢ\n")
        self.assertTrue(any(i.code == "E001" for i in issues))

    def test_e001_fourth_column_rejected(self):
        _p, issues = self.check_text("a.tsv", "台灣\tㄊㄞˊ-ㄨㄢ\t常用\t0.9\n")
        self.assertTrue(any(i.code == "E001" for i in issues))

    def test_e002_empty_word(self):
        _p, issues = self.check_text("a.tsv", "\tㄊㄞˊ\t常用\n")
        self.assertTrue(any(i.code == "E002" for i in issues))

    def test_e002_word_with_space(self):
        _p, issues = self.check_text("a.tsv", "台 灣\tㄊㄞˊ-ㄨㄢ\t常用\n")
        self.assertTrue(any(i.code == "E002" for i in issues))

    def test_e002_ascii_letters(self):
        _p, issues = self.check_text("a.tsv", "台灣ABC\tㄊㄞˊ-ㄨㄢ-ㄚ-ㄅ-ㄘ\t常用\n")
        codes = [i.code for i in issues]
        self.assertIn("E002", codes)
        msg = [i.message for i in issues if i.code == "E002"][0]
        self.assertIn("Issue", msg)

    def test_e002_ascii_digits(self):
        _p, issues = self.check_text("a.tsv", "台灣123\tㄊㄞˊ-ㄨㄢ-ㄚ-ㄅ-ㄘ\t常用\n")
        self.assertTrue(any(i.code == "E002" for i in issues))

    def test_e003_count_mismatch(self):
        _p, issues = self.check_text("a.tsv", "台灣\tㄊㄞˊ\t常用\n")
        self.assertTrue(any(i.code == "E003" for i in issues))

    def test_e004_bad_syllable(self):
        _p, issues = self.check_text("a.tsv", "台灣\tㄊㄞˊ-XYZ\t常用\n")
        self.assertTrue(any(i.code == "E004" for i in issues))

    def test_neutral_back_is_not_an_error(self):
        # 行為修正（R2-10）：舊版把後置輕聲報 E004；資料與引擎實際就是後置
        _p, issues = self.check_text("a.tsv", "嗎\tㄇㄚ˙\t常用\n")
        self.assertEqual(issues, [])

    def test_neutral_front_is_not_an_error(self):
        _p, issues = self.check_text("a.tsv", "嗎\t˙ㄇㄚ\t常用\n")
        self.assertEqual(issues, [])

    def test_e004_neutral_on_both_sides(self):
        _p, issues = self.check_text("a.tsv", "嗎\t˙ㄇㄚ˙\t常用\n")
        self.assertTrue(any(i.code == "E004" for i in issues))

    def test_e005_front_and_back_neutral_are_the_same_reading(self):
        # 兩種寫法正規化後是同一個讀音，算重複
        _p, issues = self.check_text("a.tsv", "車子\tㄔㄜ-˙ㄗ\t常用\n車子\tㄔㄜ-ㄗ˙\t常用\n")
        self.assertEqual([i.code for i in issues], ["E005"])

    def test_e005_duplicate_same_file(self):
        _p, issues = self.check_text(
            "a.tsv", "台灣\tㄊㄞˊ-ㄨㄢ\t常用\n台灣\tㄊㄞˊ-ㄨㄢ\t常用\n"
        )
        self.assertTrue(any(i.code == "E005" for i in issues))

    def test_same_word_different_reading_not_duplicate(self):
        _p, issues = self.check_text(
            "a.tsv", "台灣\tㄊㄞˊ-ㄨㄢ\t常用\n台灣\tㄊㄞ-ㄨㄢ\t常用\n"
        )
        self.assertFalse(any(i.code == "E005" for i in issues))

    def test_e006_bom(self):
        data = b"\xef\xbb\xbf" + "台灣\tㄊㄞˊ-ㄨㄢ\t常用\n".encode("utf-8")
        path = self.make_bytes("a.tsv", data)
        issues = lex.check_file(path, {})
        self.assertTrue(any(i.code == "E006" for i in issues))

    def test_e006_crlf(self):
        data = "台灣\tㄊㄞˊ-ㄨㄢ\t常用\r\n".encode("utf-8")
        path = self.make_bytes("a.tsv", data)
        issues = lex.check_file(path, {})
        self.assertTrue(any(i.code == "E006" for i in issues))

    def test_e006_not_utf8(self):
        path = self.make_bytes("a.tsv", b"\xff\xfe\x00bad\x01\x02")
        issues = lex.check_file(path, {})
        self.assertTrue(any(i.code == "E006" for i in issues))

    def test_w001_bad_source_warns(self):
        _p, issues = self.check_text("a.tsv", "台灣\tㄊㄞˊ-ㄨㄢ\t隨便寫\n")
        w = [i for i in issues if i.code == "W001"]
        self.assertEqual(len(w), 1)
        self.assertEqual(w[0].severity, "warning")

    def test_w001_url_ok(self):
        _p, issues = self.check_text(
            "a.tsv", "台灣\tㄊㄞˊ-ㄨㄢ\thttps://example.com\n"
        )
        self.assertFalse(any(i.code == "W001" for i in issues))

    def test_w002_simplified_warns(self):
        _p, issues = self.check_text("a.tsv", "华\tㄏㄨㄚˊ\t常用\n")
        self.assertTrue(any(i.code == "W002" for i in issues))

    def test_w002_traditional_no_warn(self):
        _p, issues = self.check_text("a.tsv", "台灣\tㄊㄞˊ-ㄨㄢ\t常用\n")
        self.assertFalse(any(i.code == "W002" for i in issues))

    def test_comments_and_blank_lines_ignored(self):
        _p, issues = self.check_text(
            "a.tsv", "# 註解\n\n台灣\tㄊㄞˊ-ㄨㄢ\t常用\n\n# 尾\n"
        )
        self.assertEqual(issues, [])

    def test_output_text_format(self):
        path, issues = self.check_text("a.tsv", "台灣\tㄊㄞˊ\n")
        self.assertTrue(issues)
        for i in issues:
            self.assertRegex(i.text(), r"\.tsv:\d+: (E\d{3}|W\d{3}) ")


class TestCrossFileAndCli(TempWorkDir):
    def test_e005_duplicate_across_files(self):
        seen = {}
        p1 = self.make_text("a.tsv", "台灣\tㄊㄞˊ-ㄨㄢ\t常用\n")
        p2 = self.make_text("b.tsv", "台灣\tㄊㄞˊ-ㄨㄢ\t常用\n")
        lex.check_file(p1, seen)
        issues = lex.check_file(p2, seen)
        self.assertTrue(any(i.code == "E005" for i in issues))

    def test_exit_zero_with_only_warnings(self):
        path = self.make_text("a.tsv", "台灣\tㄊㄞˊ-ㄨㄢ\t隨便寫\n")
        code, _out, _err = run_main([path])
        self.assertEqual(code, 0)

    def test_exit_one_with_errors(self):
        path = self.make_text("a.tsv", "台灣\tㄊㄞˊ\n")
        code, _out, _err = run_main([path])
        self.assertEqual(code, 1)

    def test_exit_two_no_inputs(self):
        code, _out, _err = run_main([])
        self.assertEqual(code, 2)

    def test_exit_two_missing_path(self):
        code, _out, _err = run_main(
            [os.path.join(self.tmp, "no-such-file.tsv")]
        )
        self.assertEqual(code, 2)

    def test_exit_two_non_tsv_file(self):
        path = self.make_text("a.txt", "x")
        code, _out, _err = run_main([path])
        self.assertEqual(code, 2)

    def test_exit_two_empty_directory(self):
        empty = os.path.join(self.tmp, "empty")
        os.mkdir(empty)
        code, _out, _err = run_main([empty])
        self.assertEqual(code, 2)

    def test_directory_input_collects_tsv(self):
        self.make_text("a.tsv", "台灣\tㄊㄞˊ-ㄨㄢ\t常用\n")
        self.make_text("note.txt", "ignore me\n")
        code, _out, _err = run_main([self.tmp])
        self.assertEqual(code, 0)

    def test_json_output_shape(self):
        path = self.make_text("a.tsv", "台灣\tㄊㄞˊ\n")
        code, out, _err = run_main([path, "--json"])
        self.assertEqual(code, 1)
        payload = json.loads(out)
        self.assertIn("files", payload)
        self.assertIn("issues", payload)
        self.assertIn("summary", payload)
        self.assertGreaterEqual(payload["summary"]["errors"], 1)
        first = payload["issues"][0]
        for key in ("file", "line", "code", "message", "severity"):
            self.assertIn(key, first)


if __name__ == "__main__":
    unittest.main()
