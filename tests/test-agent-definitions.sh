#!/usr/bin/env bash
# 職種定義の契約・起動JSON・拒否の代表。

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
# 検査対象の定義ディレクトリ。既定は repo の実定義。ラッパーと同じ変数名で
# 差し替えられる（職種の追加・削除を設定だけで完結させる設計 2026-09-20
# §4.3・§6.2＝`AIENV_AGENT_SOURCE_DIR=<dir> bash tests/test-agent-definitions.sh`。
# 固定職種の内容検査（1・2・4・7・9）も同じディレクトリに掛かるので、<dir> は
# 実定義の複製に fixture を足したものにする）。
AGENTS_DIR="${AIENV_AGENT_SOURCE_DIR:-$REPO_ROOT/team/rules/agents}"
AGENT_DEF_LIB="$REPO_ROOT/team/connect/claude-code"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

assert_true() {
  local desc="$1" cond="$2"
  if [[ "$cond" == "1" ]]; then
    pass "$desc"
  else
    fail_case "$desc"
  fi
}

# ------------------------------------------------------------------
# 定義ファイル契約 (a)〜(f) の検査（職種の追加・削除を設定だけで完結させる
# 設計 2026-09-20 §4.3・§6.1・FR-12）。<dir>/*.md のうち Path.is_file()
# （symlink を辿る＝ガードの `-f` と同じ集合）の各ファイルについて契約を
# **全部**評価し、違反を `<ファイル名>: <CODE>` で 1 行ずつ出力する（短絡
# しない）。0 ファイルは `NO_DEFINITIONS` を出力して非 0（空虚な真の禁止）。
# 違反 0 件なら無出力・exit 0。
#   (a)(b)(d) … agent_def.load_agent_def の例外コードで判定
#               （ROLE_INVALID→NAME_FORMAT_INVALID・ROLE_NAME_MISMATCH→
#               NAME_FILENAME_MISMATCH・FRONTMATTER_FIELD_*／BODY_EMPTY はそのまま）
#   (c)(e)(f) … このヘルパ内で直接見る（BUILTIN_NAME_COLLISION・
#               MODEL_KEY_FORBIDDEN・EFFORT_KEY_FORBIDDEN・
#               REFERENCE_BODY_INVALID）
# ⚠️ 定義集合の等値・件数はここでは見ない（AC-6＝集合の閉列挙なし）。
# ------------------------------------------------------------------
contract_check() {
  PYTHONPATH="$AGENT_DEF_LIB" python3 - "$1" "$2" <<'PYCONTRACT'
import re
import sys
from pathlib import Path

import agent_def

# (c) 組込み種別名（このテストにだけ置く。出典＝
# https://code.claude.com/docs/en/sub-agents 2026-09-20 取得）。
BUILTIN_NAMES = {
    "Explore",
    "Plan",
    "general-purpose",
    "claude",
    "statusline-setup",
    "claude-code-guide",
}
# 契約 (a)〜(d) について agent_def の例外コードを契約の語へ読み替える。
CODE_MAP = {
    "ROLE_INVALID": "NAME_FORMAT_INVALID",
    "ROLE_NAME_MISMATCH": "NAME_FILENAME_MISMATCH",
}


def code_of(exc: Exception) -> str:
    return str(exc).split(":", 1)[0]


def frontmatter_text(raw: bytes):
    """先頭の '---' ブロックの中身。壊れていれば None（構造の違反は
    load_agent_def の例外として別途出る）。"""
    if not raw.startswith(b"---\n"):
        return None
    idx = 4
    while True:
        nl = raw.find(b"\n", idx)
        if nl == -1:
            return None
        if raw[idx:nl] == b"---":
            return raw[4:idx].decode("utf-8", errors="replace")
        idx = nl + 1


agents_dir = sys.argv[1]
preferences_dir = Path(sys.argv[2])
files = sorted(p for p in Path(agents_dir).glob("*.md") if p.is_file())
if not files:
    print("NO_DEFINITIONS")
    sys.exit(1)

violations = []
for path in files:
    stem = path.name[: -len(".md")]
    codes = []

    def add(code: str) -> None:
        if code not in codes:
            codes.append(code)

    # (a)(b)(d)
    try:
        agent_def.load_agent_def(agents_dir, stem)
    except agent_def.AgentDefError as exc:
        c = code_of(exc)
        add(CODE_MAP.get(c, c))

    # (c)
    if stem in BUILTIN_NAMES:
        add("BUILTIN_NAME_COLLISION")

    # (e)(f)
    raw = path.read_bytes()
    fm = frontmatter_text(raw)
    if fm is not None:
        if re.search(r"^[ \t]*model[ \t]*:", fm, re.M):
            add("MODEL_KEY_FORBIDDEN")
        if re.search(r"^[ \t]*effort[ \t]*:", fm, re.M):
            add("EFFORT_KEY_FORBIDDEN")
    text = raw.decode("utf-8", errors="replace")
    body = text.split("---", 2)[-1].strip()
    expected = ("着手前に ~/Data/obsidian/Preferences/absolute-rules.md → "
                f"core-worker.md → worker-role-{stem}.md を全文 Read し、従う。")
    if body != expected:
        add("REFERENCE_BODY_INVALID")

    note = preferences_dir / f"worker-role-{stem}.md"
    try:
        note_body = note.read_text()
    except OSError:
        add("ROLE_NOTE_UNREADABLE")
    else:
        if len(re.findall(r"^## 権限\s*$", note_body, re.M)) != 1:
            add("ROLE_NOTE_PERMISSION_HEADING_COUNT")

    for c in codes:
        violations.append(f"{path.name}: {c}")

for v in violations:
    print(v)
sys.exit(1 if violations else 0)
PYCONTRACT
}

# 要件 §7 の probe 定義（契約 (a)〜(f) だけを満たす最小形）を書く。
# 引数: <出力パス> <name> [<frontmatter に足す行>...]（陰性 fixture 用）
write_probe_def() {
  local out="$1" name="$2" extra
  shift 2
  {
    echo "---"
    echo "name: $name"
    echo "description: probe definition for the role-definition contract test"
    echo "tools: Read"
    for extra in "$@"; do echo "$extra"; done
    echo "---"
    echo "着手前に ~/Data/obsidian/Preferences/absolute-rules.md → core-worker.md → worker-role-$name.md を全文 Read し、従う。"
  } > "$out"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PREFERENCES_DIR="$WORK/preferences"
mkdir -p "$PREFERENCES_DIR"
for definition in "$AGENTS_DIR"/*.md; do
  role="$(basename "$definition" .md)"
  printf '%s\n' '## 権限' '試験用の職種権限' > "$PREFERENCES_DIR/worker-role-$role.md"
done

echo "=== 定義ファイル契約 ==="
out="$(contract_check "$AGENTS_DIR" "$PREFERENCES_DIR")"; rc=$?
assert_true "配布する定義が契約を満たす" "$([ "$rc" -eq 0 ] && [ -z "$out" ] && echo 1 || echo 0)"

write_probe_def "$WORK/zz-probe.md" zz-probe
out="$(contract_check "$WORK" "$PREFERENCES_DIR")"; rc=$?
assert_true "参照先の職種ノートが無ければ契約検査が失敗する" "$([ "$rc" -ne 0 ] && [[ "$out" == *ROLE_NOTE_UNREADABLE* ]] && echo 1 || echo 0)"
json="$(python3 "$AGENT_DEF_LIB/agent_def.py" agents-json --dir "$WORK" --role zz-probe)"
assert_true "職種定義から起動用JSONを生成できる" "$(printf '%s' "$json" | python3 -c '
import json,sys
d=json.load(sys.stdin)["zz-probe"]
assert d["description"] and d["prompt"] and d["tools"]
' && echo 1 || echo 0)"
write_probe_def "$WORK/zz-probe.md" zz-other
out="$(contract_check "$WORK" "$PREFERENCES_DIR")"; rc=$?
assert_true "名前不一致を拒否する" "$([ "$rc" -ne 0 ] && [[ "$out" == *NAME_FILENAME_MISMATCH* ]] && echo 1 || echo 0)"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
