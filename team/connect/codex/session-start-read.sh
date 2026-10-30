#!/usr/bin/env bash
# リーダーの SessionStart に必読5ファイルの全文を渡す。ワーカーは対象外。
# 本体・Python の起動失敗は hooks.json の登録コマンドが不足JSONに変換する。
python3 - <<'PY'
import json
import os
from pathlib import Path

NOTES = (
    "Preferences/absolute-rules.md",
    "Preferences/core-conduct.md",
    "Preferences/core-workflow.md",
    "Personal/profile-personal.md",
    "Preferences/vault-operation.md",
)

context = ""
if os.environ.get("AIENV_CODEX_WORKER") != "1":
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

print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "SessionStart", "additionalContext": context,
}}, ensure_ascii=False))
PY
