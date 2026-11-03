#!/usr/bin/env bash
# リーダーの SessionStart に必読5ファイルの全文を渡す。ワーカーは対象外。
# 本体・Python の起動失敗は hooks.json の登録コマンドが不足JSONに変換する。
AIENV_CODEX_CONNECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" python3 - <<'PY'
import json
import os
import subprocess
from pathlib import Path

NOTES = (
    "Preferences/absolute-rules.md",
    "Preferences/core-conduct.md",
    "Preferences/core-workflow.md",
    "Personal/profile-personal.md",
    "Preferences/vault-operation.md",
)

context = ""
if os.environ.get("AIENV_CODEX_WORKER") != "1" and os.environ.get("AIENV_CODEX_PROJECT_LEADER") == "1":
    context = "親の必読は起動依頼の10文書参照に従い、全文を読む。正本は core-workflow のプロジェクトリーダーの節。"
elif os.environ.get("AIENV_CODEX_WORKER") != "1":
    sections = []
    missing = 0
    for note in NOTES:
        path = Path.home() / "Data/obsidian" / note
        try:
            with path.open(encoding="utf-8", newline="") as stream:
                body = stream.read()
            if not body:
                raise ValueError("空ファイル")
        except (OSError, UnicodeError, ValueError) as error:
            missing += 1
            sections.append(f"⚠️ 不足：{path}（{error}）")
        else:
            sections.append(f"## {path}（{len(body.splitlines())} 行）\n{body}")
    opening = (
        f"必読5ファイルのうち {missing} 件が不足。読了として扱わず、最初の応答で本人に伝える"
        if missing else "必読5ファイル＝全文注入済み（5/5）"
    )
    context = opening + "\n\n" + "\n\n".join(sections)
    try:
        ledger = Path(os.environ["AIENV_CODEX_CONNECT_DIR"]).parents[2] / "core/assembly/ledger-tool.sh"
        judge = subprocess.run([str(ledger), "lookup", "ai-brain.health-judge"],
                               capture_output=True, text=True, check=True).stdout.strip()
        command = ["python3", str(judge), "observe"]
        if os.environ.get("HEALTH_JUDGE_NOW"):
            command += ["--now", os.environ["HEALTH_JUDGE_NOW"]]
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode == 0:
            health = json.loads(result.stdout)
            recall = ", ".join(f"{leader}={state}" for leader, state in health["sources"]["recall"].items())
            health_text = f"【外部脳ヘルス】stage={health['stage']} recall={recall}"
            for item in health["items"]:
                health_text += "\n- " + item.get("result", item.get("detail", ""))
        else:
            raise ValueError("共通観測の失敗")
    except Exception:
        health_text = "【外部脳ヘルス】判定不能（共通観測・保存に失敗）"
    context += "\n\n" + health_text

print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "SessionStart", "additionalContext": context,
}}, ensure_ascii=False))
PY
