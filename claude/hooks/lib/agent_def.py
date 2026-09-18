#!/usr/bin/env python3
"""agent_def.py — 職種定義の素材（`claude/agents/<職種>.md`）から、Claude Code
起動時の `--agents` JSON と `--allowedTools` の値を毎回生成する共有部品
（設計-v1.1.1.md §7・D-6）。

正本は素材ファイル1つ（`claude/agents/<職種>.md`）——複製ファイルは作らず
毎回ここで生成する（FR-11a①）。`effort`・`color` は frontmatter に在っても
落とす（渡し口はラッパーの `--effort` だけ＝FR-6・AC-6）。

外部ライブラリに依存しない（標準ライブラリのみ）。

使い方:
  agent_def.py agents-json --dir <素材ディレクトリ> --role <職種名>
      → {"<職種>":{"description":"…","tools":["Read",…],"prompt":"<本文>"}} を1行で
  agent_def.py allowed-tools --dir <素材ディレクトリ> --role <職種名>
      → "Read,Grep,Glob,…"（カンマ区切り1行）

失敗（素材が無い／frontmatter が壊れている／必須フィールドが無い）は標準
エラーへ理由を書いて非0で終わる。「子を起動しない」判断そのものは呼び出し側
（ラッパー）が行う——本スクリプトは失敗を伝えるだけ。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


class AgentDefError(Exception):
    """素材の読み込み・解析に失敗したときに送出する。"""


# 検証1巡目 I1-m6 対応（検証2巡目 I2-m1 でコメント訂正）: --role をそのまま
# ファイル名へ連結すると `../` 等の走査を弾けない。ファイル名として使う前に
# 形式を検査する（`../`・絶対パス・空文字・空白等をすべて弾く程度の緩さ）。
# 職種名は先頭英字＝`^[a-z][a-z0-9-]*$`（scripts/claude-exec.sh の
# task-id 規則 `^[a-z0-9][a-z0-9-]*$` より厳しくしている＝先頭に数字を許さない）。
_ROLE_PATTERN = re.compile(r"^[a-z][a-z0-9-]*$")


def _validate_role(role: str) -> None:
    if not _ROLE_PATTERN.match(role):
        raise AgentDefError(
            f"ROLE_INVALID: --role の形式が不正です（^[a-z][a-z0-9-]*$ に一致しない）: {role!r}"
        )


def _read_source(agents_dir: str, role: str) -> bytes:
    path = Path(agents_dir) / f"{role}.md"
    try:
        return path.read_bytes()
    except OSError as exc:
        raise AgentDefError(f"SOURCE_UNREADABLE: {path} ({exc})") from exc


def _split_frontmatter(raw: bytes) -> tuple[str, str]:
    """先頭の `---\\n...\\n---\\n` ブロックと、それ以降の本文を返す。

    test-agent-definitions.sh の frontmatter_block() と同じ境界規則
    （先頭が `---\\n` で始まり、閉じの `---` 単独行を探す）。
    """
    if not raw.startswith(b"---\n"):
        raise AgentDefError("FRONTMATTER_MISSING: 先頭が '---' ブロックではない")
    idx = 4
    while True:
        nl = raw.find(b"\n", idx)
        if nl == -1:
            raise AgentDefError("FRONTMATTER_UNTERMINATED: 閉じの '---' が無い")
        if raw[idx:nl] == b"---":
            fm = raw[4:idx].decode("utf-8")
            body = raw[nl + 1 :].decode("utf-8")
            if body.startswith("\n"):
                body = body[1:]
            return fm, body
        idx = nl + 1


def _parse_frontmatter_fields(fm_text: str) -> dict[str, str]:
    """frontmatter ブロックのトップレベル `key: value` 行だけを拾う
    （インデントされた行は多行値の続きとみなし読み飛ばす）。"""
    fields: dict[str, str] = {}
    for line in fm_text.split("\n"):
        if not line or line[0] in (" ", "\t"):
            continue
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        key = key.strip()
        if not key:
            continue
        fields[key] = value.strip()
    return fields


def _tools_list(raw_value: str) -> list[str]:
    return [t.strip() for t in raw_value.split(",") if t.strip()]


def load_agent_def(agents_dir: str, role: str) -> dict:
    """役割1件ぶんの {"description":…, "tools":[…], "prompt":…} を返す。"""
    _validate_role(role)
    raw = _read_source(agents_dir, role)
    fm_text, body = _split_frontmatter(raw)
    fields = _parse_frontmatter_fields(fm_text)

    # 検証1巡目 I1-m6 対応: 素材の frontmatter `name` を読み、`--role`
    # （＝`--agents` JSON のキー）と一致することを確かめる（AC-11b②の
    # 「名前が素材と一致」が実質ファイル名との一致にしかなっていなかった
    # 抜け穴を塞ぐ）。
    name = fields.get("name")
    if name != role:
        raise AgentDefError(
            f"ROLE_NAME_MISMATCH: frontmatter の name={name!r} が --role={role!r} と一致しません ({role}.md)"
        )

    description = fields.get("description")
    if not description:
        raise AgentDefError(f"FRONTMATTER_FIELD_MISSING: description ({role}.md)")

    tools_raw = fields.get("tools")
    if not tools_raw:
        raise AgentDefError(f"FRONTMATTER_FIELD_MISSING: tools ({role}.md)")
    tools = _tools_list(tools_raw)
    if not tools:
        raise AgentDefError(f"FRONTMATTER_FIELD_EMPTY: tools ({role}.md)")

    prompt = body.rstrip("\n")
    if not prompt:
        raise AgentDefError(f"BODY_EMPTY: {role}.md")

    return {"description": description, "tools": tools, "prompt": prompt}


def cmd_agents_json(agents_dir: str, role: str) -> str:
    definition = load_agent_def(agents_dir, role)
    return json.dumps({role: definition}, ensure_ascii=False)


def cmd_allowed_tools(agents_dir: str, role: str) -> str:
    definition = load_agent_def(agents_dir, role)
    return ",".join(definition["tools"])


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="agent_def.py")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_json = sub.add_parser("agents-json")
    p_json.add_argument("--dir", required=True)
    p_json.add_argument("--role", required=True)

    p_tools = sub.add_parser("allowed-tools")
    p_tools.add_argument("--dir", required=True)
    p_tools.add_argument("--role", required=True)

    args = parser.parse_args(argv)

    try:
        if args.cmd == "agents-json":
            sys.stdout.write(cmd_agents_json(args.dir, args.role) + "\n")
            return 0
        if args.cmd == "allowed-tools":
            sys.stdout.write(cmd_allowed_tools(args.dir, args.role) + "\n")
            return 0
    except AgentDefError as exc:
        sys.stderr.write(f"{exc}\n")
        return 1

    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
