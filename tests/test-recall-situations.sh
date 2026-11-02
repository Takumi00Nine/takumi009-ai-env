#!/usr/bin/env bash
# S1: 共通書式・場面だけの照合・設定と直接編集の不変条件。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/recall-s1.XXXXXX")"
export HOME="$TEST_ROOT/home"
export PYTHONDONTWRITEBYTECODE=1
unset VAULT_RECALL_CONFIG VAULT_RECALL_MAX_ITEMS VAULT_RECALL_THRESHOLD VAULT_RECALL_KEYWORD_BUDGET_MS
mkdir -p "$HOME"

trap 'rm -rf "$TEST_ROOT"' EXIT
python3 - "$REPO_ROOT/ai-brain/executor" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, sys.argv[1])
import keyword_recall_helper as recall
from vault_lib import read_recall_records

LESSON_SCENE = "安全柵のテストを減らす"
LESSON_PROMPT = "安全柵のテストを減らしたい"
DECISION_SCENE = "直すのは別のタスクに回す"
DECISION_PROMPT = "設定は写しから戻して、直すのは別のタスクに回そう"


def lesson(identifier="safety-tests", text="安全柵が守る振る舞いを確認する。", scene=LESSON_SCENE):
    return f"""## 教訓: {identifier}
- 教訓1行: {text}
- 効く場面:
  - {scene}
- 起きたこと: 安全柵まで削る案になった。
- 発生記録:
  - 2026-11-01 [[Fragments/2026-11/2026-11-01#初回]] [[Knowledge/検証]]
  - 2026-11-02 [[Fragments/2026-11/2026-11-02#再発]]
"""


def decision(scene=DECISION_SCENE):
    return f"""# 応急処置で終わらせない
- 判断1行: 応急処置で終わらせない
- 効く場面:
  - {scene}
- 判断の日付: 2026-11-01

## 理由
旧案を撤回した経緯を説明する本文。本文全体は注入しない。
"""


class RecallTest(unittest.TestCase):
    def setUp(self):
        self.vault = Path.home() / self._testMethodName
        self.vault.mkdir()

    def note(self, source, text):
        path = self.vault / source
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def run_recall(self, prompt, **overrides):
        return recall.recall_situations(self.vault, prompt, recall.load_recall_config(**overrides))

    def test_shared_records_and_exclusions(self):
        self.note("Knowledge/traps.md", "# 罠集\n" + lesson()
                  + "- 状態: 規則化見送り（2026-11-02）\n"
                  + "## 補足\n- 教訓1行: 別の節は取り込まない\n"
                  + lesson("second") + "- 状態: 規則化済み → [[Preferences/安全#確認]]\n"
                  + lesson("missing").replace("- 効く場面:\n  - " + LESSON_SCENE + "\n", "")
                  + "```markdown\n" + lesson("example") + "```\n")
        # 現役ノートの本文にある退役への言及は、日付・警告付きでも失効バナーではない。
        self.note("Decisions/current.md",
                  "> ⚠️ 2026-09-17 B-1 により、installer の effort 生成は AC-1 通過後に退役。白紙化バナーではない。\n"
                  + decision())
        self.note("Knowledge/retired.md", "---\nretired: true\n---\n" + lesson())
        self.note("Decisions/withdrawn.md", "> ⚠️撤回済み（2026-10-31）：本文は当時の記録。\n" + decision())
        self.note("Decisions/blank.md", "# 履歴\n> ⚠️ **白紙化済み（2026-07-20）**: 履歴として保全。\n" + decision())
        # Knowledge/streaming-ai-work.md:27 の現物表記。
        self.note("Knowledge/streaming-ai-work.md",
                  "> ⚠️ **撤回済み企画の資料（2026-08-05 バナー付与）**: 本ノートの実行計画は現役でない。\n"
                  + lesson())
        self.note("Decisions/README.md", decision())
        self.note("Decisions/example.md", "# 判断の書式例\n~~~markdown\n" + decision() + "~~~\n")
        self.note("Preferences/rule.md", decision())
        records, issues = read_recall_records(self.vault)
        self.assertEqual([r["id"] for r in records],
                         ["Knowledge/traps.md#safety-tests", "Knowledge/traps.md#second", "Decisions/current.md"])
        first, second, current = records
        self.assertEqual(set(first), {"kind", "id", "source", "text", "situations", "occurrences", "state"})
        self.assertEqual(first["situations"], [LESSON_SCENE])
        self.assertEqual(first["state"], "規則化見送り（2026-11-02）")
        self.assertTrue(second["state"].startswith("規則化済み"))
        self.assertEqual(len(first["occurrences"]), 2)  # 複数出典でも1行は1発生。
        self.assertEqual(first["occurrences"][0], {
            "date": "2026-11-01", "source": "[[Fragments/2026-11/2026-11-01#初回]] [[Knowledge/検証]]"})
        self.assertEqual(set(current), {"kind", "id", "source", "text", "situations", "date"})
        self.assertEqual(current["date"], "2026-11-01")
        self.assertIn({"id": "Knowledge/traps.md#missing", "source": "Knowledge/traps.md", "fields": ["効く場面"]}, issues)
        # 日付・経緯の欠けも、text/場面があるレコードとは別に報告する。
        self.note("Knowledge/incomplete.md", lesson().replace("- 起きたこと: 安全柵まで削る案になった。\n", ""))
        self.assertIn("起きたこと", read_recall_records(self.vault)[1][0]["fields"])

    def test_only_situations_match_and_render(self):
        # AC-FL-8 の陽性①②、陰性①②。文面・ファイル名・aliases は検索キーにならない。
        self.note("Knowledge/lesson.md", lesson())
        self.note("Decisions/2026-11-01-no-stopgap-only.md", decision())
        self.note("Preferences/only-alias.md", "---\naliases: [専用別名]\n---\n" + decision())
        self.note("Decisions/withdrawn.md", "> ⚠️ **撤回済み（2026-10-31）**: 履歴\n" + decision("撤回判断専用の場面"))
        positive = self.run_recall(LESSON_PROMPT)
        self.assertEqual(positive["text"], "教訓：安全柵が守る振る舞いを確認する。 — [[Knowledge/lesson#教訓: safety-tests]]")
        self.assertGreaterEqual(positive["candidates"][0]["score"], recall.load_recall_config()["threshold"])
        self.assertEqual(self.run_recall(DECISION_PROMPT)["text"],
                         "本人の判断：応急処置で終わらせない（2026-11-01） — [[Decisions/2026-11-01-no-stopgap-only]]")
        for prompt in ("テストを実行して", "only-alias 専用別名", "撤回判断専用の場面",
                       "安全柵が守る振る舞いを確認する。", "no-stopgap-only"):
            self.assertEqual(self.run_recall(prompt)["text"], "", prompt)
        self.assertEqual(self.run_recall("テストを実行して", threshold=0)["text"], "")
        self.assertEqual(recall.normalize_situation(" ＡＢＣ、 テスト。"), "abcテスト")
        # 場面を複数足しても加点しない。
        grams = recall.situation_grams(recall.normalize_situation(LESSON_PROMPT))
        self.assertEqual(recall.score_situations([LESSON_SCENE], grams),
                         recall.score_situations([LESSON_SCENE, LESSON_SCENE], grams))

    def test_config_limits_budget_and_next_read(self):
        # AC-FL-8 陰性③と AC-FL-15 の S1 部分。3候補を種類で優先しない。
        path = self.note("Knowledge/lesson.md", lesson("x") + lesson("y"))
        self.note("Decisions/decision.md", decision(LESSON_SCENE))
        result = self.run_recall(LESSON_PROMPT)
        self.assertEqual(len(result["candidates"]), 2)
        self.assertEqual([r["id"] for r in result["candidates"]],
                         ["Decisions/decision.md", "Knowledge/lesson.md#x"])
        config = recall.load_recall_config()
        config["max_items"] = 1
        config_path = Path.home() / "recall.json"
        config_path.write_text(json.dumps(config), encoding="utf-8")
        with patch.dict(os.environ, {"VAULT_RECALL_CONFIG": str(config_path)}):
            self.assertEqual(len(self.run_recall(LESSON_PROMPT)["candidates"]), 1)
        threshold = (result["candidates"][0]["score"] + 1) / 2
        with patch.dict(os.environ, {"VAULT_RECALL_THRESHOLD": str(threshold)}):
            self.assertEqual(self.run_recall(LESSON_PROMPT)["text"], "")
        read_text = Path.read_text

        def read_past_deadline(note, *args, **kwargs):
            text = read_text(note, *args, **kwargs)
            if note == path:
                self.assertEqual(clock.return_value, 10.0)  # 読取開始時は期限内。
                clock.return_value = 10.002  # 本文を読む間に1msの予算を超える。
            return text

        with patch.dict(os.environ, {"VAULT_RECALL_KEYWORD_BUDGET_MS": "1"}), \
                patch.object(recall.time, "monotonic", return_value=10.0) as clock, \
                patch.object(Path, "read_text", read_past_deadline):
            with self.assertRaises(recall.BudgetExceeded):
                self.run_recall(LESSON_PROMPT)
            self.assertEqual(clock.return_value, 10.002)  # 開始前に打ち切られていない。
        path.write_text(path.read_text(encoding="utf-8").replace("安全柵が守る振る舞いを確認する。", "安全柵を確認してから減らす。"), encoding="utf-8")
        next_result = self.run_recall(LESSON_PROMPT)
        self.assertIn("教訓：安全柵を確認してから減らす。", next_result["text"])
        self.assertEqual(next_result["candidates"][1]["id"], result["candidates"][1]["id"])
        # S1 では既存 CLI の契約を保つ（hook の切替は S3）。
        self.note("Knowledge/legacy-key.md", "---\naliases: [legacyword]\n---\n本文\n")
        legacy = subprocess.run([sys.executable, recall.__file__, "--vault", str(self.vault),
                                 "--query", "legacyword"], capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(legacy.stdout)["candidates"][0]["relpath"], "Knowledge/legacy-key.md")


unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
