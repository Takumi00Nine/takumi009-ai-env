#!/usr/bin/env bash
# claude/agents/*.md と Vault ノートの「内容契約」を見る静的テスト
# （3モード体制-設計-2026-09-06.md §10.3・新設）。
#
# AC-11・AC-12・AC-25 は claude/agents/*.md と Vault ノートの内容契約を
# 見るもので、既存のどのスイートも収容先を持たなかったため新設する
# （test-core-docs-placeholder-schema.sh はコア文書のプレースホルダ検査が
# 主題で、こちらとは主題が異なる）。
#
# ⚠️ 要件書 v1.4〜v1.5.1（FR-4・FR-6）により、このスイートは repo の外を
# 読まない（Vault・本人のローカル実体・private repo のいずれにも依存しない）。
# サンプルへの検査は tests/test-config-samples.sh へ一本化した（FR-8・
# 詳細＝セクション5のコメント）。
#
# 実行方法: bash tests/test-agent-definitions.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
AGENTS_DIR="$REPO_ROOT/claude/agents"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    fail_case "$desc (expected=$expected actual=$actual)"
  fi
}

assert_true() {
  local desc="$1" cond="$2"
  if [[ "$cond" == "1" ]]; then
    pass "$desc"
  else
    fail_case "$desc"
  fi
}

assert_contains_file() {
  local desc="$1" file="$2" needle="$3"
  if [ -f "$file" ] && grep -qF "$needle" "$file"; then
    pass "$desc"
  else
    fail_case "$desc (file=$file needle=[$needle])"
  fi
}

echo "=== model廃止 AC-1: 8職種集合・frontmatter model不在 ==="
if python3 - "$REPO_ROOT" <<'PYMODEL'
from pathlib import Path
import re, sys
r=Path(sys.argv[1])
roles=set('adoption-critic implementer operator requirements-analyst researcher system-designer vault-scribe verifier'.split())
assert {p.stem for p in (r/'claude/agents').glob('*.md')} == roles
for role in sorted(roles):
    rel=f'claude/agents/{role}.md'
    new=(r/rel).read_bytes()
    assert not re.search(rb'^[ \t]*model[ \t]*:',new.split(b'---',2)[1],re.M)
PYMODEL
then
  pass "8職種集合・frontmatter model不在"
else
  fail_case "8職種集合・frontmatter model不在"
fi

echo "=== 1. AC-12①: claude/agents/verifier.md が在り、tester.md が無い ==="
{
  assert_true "verifier.md が実在する" "$([ -f "$AGENTS_DIR/verifier.md" ] && echo 1 || echo 0)"
  assert_true "tester.md が存在しない（退役済み）" "$([ ! -f "$AGENTS_DIR/tester.md" ] && echo 1 || echo 0)"
}

echo "=== 2. AC-12②: verifier.md の tools: に SendMessage・Edit・Write・Bash を含む（カンマ区切りトークンの完全一致で判定・部分一致にしない） ==="
{
  # ⚠️ 部分文字列一致だと、例えば将来tools:にNotebookEditが加わったときに
  # "Edit"が誤って含まれる扱いになる（並列worktreeのCodexレビュー指摘の
  # 反映・点検対応）。tools:の値をカンマ区切りで分割し、トレリムした
  # トークンとの完全一致で判定する。
  tools_line="$(grep '^tools:' "$AGENTS_DIR/verifier.md" 2>/dev/null || true)"
  tools_value="${tools_line#tools:}"
  for t in SendMessage Edit Write Bash; do
    found=0
    IFS=',' read -ra _tool_tokens <<< "$tools_value"
    for tok in "${_tool_tokens[@]}"; do
      tok="$(printf '%s' "$tok" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      [ "$tok" = "$t" ] && { found=1; break; }
    done
    assert_true "tools: に ${t} をカンマ区切りトークンとして完全一致で含む" "$found"
  done
}

echo "=== 4. AC-12④: Codexが演じうる職種（vault-scribe以外の7本）のagents/*.mdにsandboxの値が書かれ、§5.2の権限表の値と一致する ==="
{
  # 3モード体制-設計-2026-09-06.md §5.2の権限表を正本値としてハードコードする
  # （Vaultのworker-role-prompts.mdへの依存を避け、この段階でも緑にできる）。
  # ⚠️ macOS既定bash 3.2は連想配列(declare -A)を持たないため、
  # "職種:期待値"のスペース区切りリストで表現する（repo全体で徹底している
  # bash 3.2互換の既存作法）。
  # ⚠️ 値の文字列を含むかだけを見ると、無関係な地の文に値が現れても合格
  # してしまう（境界が無い＝並列worktreeのCodexレビュー指摘の反映・点検
  # 対応）。実際の記述形式`sandbox: <値>`（バッククォート囲み）で境界を
  # 持たせて一致を見る。
  for pair in "implementer:workspace-write" "requirements-analyst:workspace-write" \
              "system-designer:workspace-write" "adoption-critic:workspace-write" \
              "researcher:workspace-write" "operator:workspace-write"; do
    role="${pair%%:*}"; expected="${pair#*:}"
    f="$AGENTS_DIR/${role}.md"
    assert_contains_file "${role}.md にsandbox: ${expected}が境界つきで書かれている" "$f" "\`sandbox: $expected\`"
  done
  # verifierは成果物の種別で2経路（read-only／workspace-write の両方）。
  # verifier.mdはCLIフラグ形式（--sandbox <値>）で記述している。
  assert_contains_file "verifier.md にread-only経路が境界つきで書かれている" "$AGENTS_DIR/verifier.md" "\`--sandbox read-only\`"
  assert_contains_file "verifier.md にworkspace-write経路が境界つきで書かれている" "$AGENTS_DIR/verifier.md" "\`--sandbox workspace-write\`"
  # vault-scribeはCodexが演じない＝「対象外」の1行があればよい。
  assert_contains_file "vault-scribe.md は「Codexは演じない/対象外」と書かれている" "$AGENTS_DIR/vault-scribe.md" "Codex はこの職種を演じない"
}

# 廃止したMCP経路のexecution値を検査するための共有パターン。⚠️ このファイル
# 自身（tests/配下）も検査対象に含める都合上（項目6）、ソース上に完成した
# 文字列そのものを書くと自己参照ヒットしてしまうため、2つに分割して連結する
# （Codex二次レビュー指摘・MINOR対応。定義をここ1箇所にまとめ、以降の項目
# 5・6はこの変数を使い回すことで「別の場所にまた書いてしまう」再発も防ぐ）。
MCP_EXEC_PAT="execution=external-"
MCP_EXEC_PAT="${MCP_EXEC_PAT}mcp"

echo "=== 5. AC-11: 退役キーrole.(primary-reviewer|tester): がclaude/hooks/・claude/agents/で0件。CORE_ROLES_WITHOUT_REPO_AGENT_FILEにprimary-reviewerを含まない ==="
{
  hits="$(grep -rEn '^role\.(primary-reviewer|tester):' "$REPO_ROOT/claude/hooks" "$REPO_ROOT/claude/agents" 2>/dev/null || true)"
  assert_eq "claude/hooks・claude/agentsに退役キーが0件" "" "$hits"

  hits_mcp="$(grep -rn "$MCP_EXEC_PAT" "$REPO_ROOT/claude/hooks" "$REPO_ROOT/claude/agents" 2>/dev/null || true)"
  assert_eq "claude/hooks・claude/agentsに廃止したMCP経路のexecution値が0件" "" "$hits_mcp"

  core_manifest="$(PYTHONPATH="$REPO_ROOT/claude/hooks/lib" python3 -c 'import profile_resolve as pr; print("primary-reviewer" in pr.CORE_ROLES_WITHOUT_REPO_AGENT_FILE)')"
  assert_eq "CORE_ROLES_WITHOUT_REPO_AGENT_FILEにprimary-reviewerを含まない" "False" "$core_manifest"

  # ⚠️ 2026-09-08 本人裁定A案: Vault正本・公開スナップショットは案内ノート化
  # され機械契約の対象外（schema本体を持たない）。要件書 FR-8 により、
  # サンプルへの退役キー・MCP値検査は tests/test-config-samples.sh
  # （AC-1c・AC-1）へ一本化し、ここでの重複検査は撤去した。要件書 FR-4 に
  # より、ローカル実体（`~/.config/takumi009-ai-env/*`）はテストから一切
  # 読まない（値の一致・形だけの検査・skip の分岐のいずれも置かない）。
  # 実体の健全性はセッション起動時の resolve（SessionStart）が担う。
}

echo "=== 6. 廃止したMCP経路のexecution値がtests/内に1件も無い ==="
{

  # 廃止したMCP経路のexecution値がtests/内に1件も無いこと（意図的な陰性
  # fixtureが無い＝要件AC-11の走査対象。Codex一次レビュー指摘・MAJOR対応）。
  # MCP_EXEC_PAT（ファイル冒頭で定義・分割連結済み）を再利用する。⚠️ パスで
  # 自己ファイルを除外すると、将来このファイル自身に廃止値のfixtureが
  # 混入しても検出できなくなるため、tests/全体を除外なしで走査する
  # （Codex二次レビュー指摘・MINOR対応）。
  tests_mcp_hits="$(grep -rn "$MCP_EXEC_PAT" "$REPO_ROOT/tests" 2>/dev/null || true)"
  assert_eq "tests/内に廃止したMCP経路のexecution値が0件（意図的な陰性fixtureは現状無い・自己ファイルも除外なしで走査）" "" "$tests_mcp_hits"
}

echo "=== 7. AC-25: FR-40の1行が対象5職種の各1件に現れ、verifier・operator・vault-scribeには0件 ==="
{
  FR40_LINE='自分ではレビューを起動しない。リーダーが起動する検証に応じ、指摘の反映は自分が行う。'
  # ⚠️ `grep -c`は0件一致のとき"0"を出力しつつ非0終了するため、
  # `|| echo 0`を足すと出力が二重化する（0\n0）。フォールバックは付けず、
  # ファイル不在時だけ空文字にする。
  for role in implementer requirements-analyst system-designer researcher adoption-critic; do
    f="$AGENTS_DIR/${role}.md"
    if [ -f "$f" ]; then n="$(grep -cF "$FR40_LINE" "$f")"; else n="(file missing)"; fi
    assert_eq "${role}.md: FR-40の1行がちょうど1件" "1" "$n"
  done
  for role in verifier operator vault-scribe; do
    f="$AGENTS_DIR/${role}.md"
    if [ -f "$f" ]; then n="$(grep -cF "$FR40_LINE" "$f")"; else n="(file missing)"; fi
    assert_eq "${role}.md: FR-40の1行は0件（対象外）" "0" "$n"
  done
}

echo "=== 8(意味の検査・機械化しない): core-worker.md §6に職種の義務(自分では起動しない等)が書かれていないこと ==="
{
  echo "  skip - RV-4と同じ枠でレビュー観点として見る（本テストでは機械化しない）"
}

echo "=== 9. agents/verifier.md の出力形式に、出力先ファイルの先頭3行の固定形が連続3行・この順序で書かれている ==="
{
  # ⚠️ 部分文字列一致だけでは「3行の連続性・順序・先頭3行であること」を
  # 検証できない（Codex一次レビュー指摘・MINOR対応）。3行連続のブロックを
  # 実際に探す。
  # ⚠️ 1・2行目のパターンに`^`/`$`が無いと、行頭に接頭辞・行末に不正な
  # 末尾を付けても部分一致で「見つかった」扱いになる。また2行目は
  # ` — <1行の理由>` の必須サフィックスまで見ないと、理由部分が欠けた
  # 行でも合格してしまう（検証職・第3巡MAJOR指摘2の反映）。3行とも
  # インデントを含めて`^...$`で行全体を固定し、2行目は
  # `打ち切り可否: <可|不可> — <1行の理由>` 全体を照合する。
  VERIFIER_MD="$AGENTS_DIR/verifier.md"
  three_line_block="$(awk '
    /^[ \t]*件数: BLOCKING <n> \/ MAJOR <n> \/ MINOR <n>[ \t]*$/ { l1=NR }
    l1 && NR==l1+1 && /^[ \t]*打ち切り可否: <可\|不可> — <1行の理由>[ \t]*$/ { l2=NR }
    l2 && NR==l2+1 && /^[ \t]*---[ \t]*$/ { print "FOUND"; exit }
  ' "$VERIFIER_MD" 2>/dev/null)"
  assert_eq "verifier.md: 件数:/打ち切り可否:/--- の3行が連続してこの順序で存在する" "FOUND" "$three_line_block"
}

echo "=== 10. FM-G3(設計v1.1.3 §5・§7): 素材claude/agents/*.mdにeffort:行が0件 ==="
{
  # D-4でinstallerのeffort:生成を退役し、配置先職種定義はsymlinkで素材を
  # そのまま指す（素材と配置先が同一実体・sync_managed_symlink直呼び）。
  # ラッパー経路ではfrontmatterのeffort:は実行時の値にならない（設計§7）ため、
  # 素材へ書くと配置先でもそのまま出て誤解を招く。素材は「effort行を持たない」
  # ことを恒久条件として固定する（frontmatterブロック内の`^effort:`行だけを
  # 見る。本文中に偶然`effort:`という文字列が出てもfrontmatter外なら対象外）。
  effort_hits="$(python3 - "$AGENTS_DIR" <<'PYEFFORT'
import sys
from pathlib import Path

def frontmatter_block(b: bytes):
    if not b.startswith(b"---\n"):
        return None
    idx = 4
    while True:
        nl = b.find(b"\n", idx)
        if nl == -1:
            return None
        if b[idx:nl] == b"---":
            return b[4:idx]
        idx = nl + 1

d = Path(sys.argv[1])
hits = []
for f in sorted(d.glob("*.md")):
    block = frontmatter_block(f.read_bytes())
    if block is None:
        continue
    for line in block.split(b"\n"):
        if line.startswith(b"effort:"):
            hits.append(f.name)
for name in hits:
    print(name)
PYEFFORT
)"
  assert_eq "claude/agents/*.md のfrontmatterにeffort:行が0件" "" "$effort_hits"
}

echo "=== 11. 新設②(設計-v1.1.1.md §7・D-6・要件AC-11b②): agents_json_matches_source_and_has_no_effort（8職種） ==="
{
  AGENT_DEF="$REPO_ROOT/claude/hooks/lib/agent_def.py"
  result="$(python3 - "$AGENT_DEF" "$AGENTS_DIR" <<'PYCHECK'
import json
import subprocess
import sys
from pathlib import Path

agent_def, agents_dir = sys.argv[1], sys.argv[2]
roles = "adoption-critic implementer operator requirements-analyst researcher system-designer vault-scribe verifier".split()


def split_frontmatter(raw: bytes):
    assert raw.startswith(b"---\n")
    idx = 4
    while True:
        nl = raw.find(b"\n", idx)
        assert nl != -1
        if raw[idx:nl] == b"---":
            fm = raw[4:idx].decode("utf-8")
            body = raw[nl + 1:].decode("utf-8")
            if body.startswith("\n"):
                body = body[1:]
            return fm, body
        idx = nl + 1


def fields_of(fm_text: str):
    out = {}
    for line in fm_text.split("\n"):
        if not line or line[0] in (" ", "\t") or ":" not in line:
            continue
        k, _, v = line.partition(":")
        out[k.strip()] = v.strip()
    return out


failures = []
for role in roles:
    src = Path(agents_dir) / f"{role}.md"
    raw = src.read_bytes()
    fm_text, body = split_frontmatter(raw)
    fields = fields_of(fm_text)
    expected_desc = fields["description"]
    expected_tools = [t.strip() for t in fields["tools"].split(",") if t.strip()]
    expected_prompt = body.rstrip("\n")

    out = subprocess.run(
        ["python3", agent_def, "agents-json", "--dir", agents_dir, "--role", role],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    obj = json.loads(out)
    if set(obj.keys()) != {role}:
        failures.append(f"{role}: top-level key != {{role}} (got {sorted(obj.keys())})")
        continue
    val = obj[role]
    if set(val.keys()) != {"description", "tools", "prompt"}:
        failures.append(f"{role}: value keys != description/tools/prompt (got {sorted(val.keys())})")
        continue
    if val["description"] != expected_desc:
        failures.append(f"{role}: description mismatch")
    if val["tools"] != expected_tools:
        failures.append(f"{role}: tools mismatch (got {val['tools']} want {expected_tools})")
    if val["prompt"] != expected_prompt:
        failures.append(f"{role}: prompt mismatch (len got={len(val['prompt'])} want={len(expected_prompt)})")
    if "effort" in val or "color" in val or "name" in val:
        failures.append(f"{role}: effort/color/name leaked into agents-json output")

    tools_out = subprocess.run(
        ["python3", agent_def, "allowed-tools", "--dir", agents_dir, "--role", role],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    if tools_out != ",".join(expected_tools):
        failures.append(f"{role}: allowed-tools mismatch (got [{tools_out}] want [{','.join(expected_tools)}])")

if failures:
    print("FAIL")
    for f in failures:
        print(f"  - {f}")
else:
    print("OK")
PYCHECK
)"
  if [ "$(printf '%s\n' "$result" | head -1)" = "OK" ]; then
    pass "agents_json_matches_source_and_has_no_effort: 8職種すべてで一致・effort/color/name無し"
  else
    fail_case "agents_json_matches_source_and_has_no_effort ($(printf '%s' "$result" | tr '\n' ' '))"
  fi
}

echo "=== 12. 検証1巡目 I1-m6 対応: agent_def.py の --role 検査（陰性ケース） ==="
{
  AGENT_DEF="$REPO_ROOT/claude/hooks/lib/agent_def.py"
  I1M6_WORK="$(mktemp -d)"

  # --role が ^[a-z][a-z0-9-]*$ に一致しない（`../`混入・大文字・空文字・
  # 空白混入）ときは非0で失敗する（実在のディレクトリ・実在の素材に対して
  # 検査する＝ファイル名連結より前に弾かれることを見る）。
  for bad_role in '../implementer' 'Implementer' '' 'imple menter' 'implementer/../x'; do
    if python3 "$AGENT_DEF" agents-json --dir "$AGENTS_DIR" --role "$bad_role" >/dev/null 2>"$I1M6_WORK/role-invalid.err"; then
      fail_case "role_invalid(agents-json,role=[$bad_role]): 不正な--roleは非0で失敗するはずが成功した"
    else
      grep -q 'ROLE_INVALID' "$I1M6_WORK/role-invalid.err" \
        && pass "role_invalid(agents-json,role=[$bad_role]): 不正な--roleは非0・ROLE_INVALIDで失敗" \
        || fail_case "role_invalid(agents-json,role=[$bad_role]): 失敗はしたが理由がROLE_INVALIDでない (stderr=[$(cat "$I1M6_WORK/role-invalid.err")])"
    fi
  done
  if python3 "$AGENT_DEF" allowed-tools --dir "$AGENTS_DIR" --role '../implementer' >/dev/null 2>"$I1M6_WORK/role-invalid-at.err"; then
    fail_case "role_invalid(allowed-tools): 不正な--roleは非0で失敗するはずが成功した"
  else
    grep -q 'ROLE_INVALID' "$I1M6_WORK/role-invalid-at.err" \
      && pass "role_invalid(allowed-tools): 不正な--roleは非0・ROLE_INVALIDで失敗" \
      || fail_case "role_invalid(allowed-tools): 失敗はしたが理由がROLE_INVALIDでない"
  fi

  # frontmatterのnameが--roleと食い違う素材（ファイル名とnameが不一致）は
  # 非0で失敗する（AC-11b②の抜け穴＝ファイル名との一致だけでは検出できな
  # かった食い違いを塞げていることを見る）。
  IMPOSTOR_DIR="$I1M6_WORK/agents-impostor"
  mkdir -p "$IMPOSTOR_DIR"
  cat > "$IMPOSTOR_DIR/impostor.md" <<'EOF'
---
name: someone-else
description: test fixture with mismatched name
tools: Read
---
body text
EOF
  if python3 "$AGENT_DEF" agents-json --dir "$IMPOSTOR_DIR" --role impostor >/dev/null 2>"$I1M6_WORK/name-mismatch.err"; then
    fail_case "role_name_mismatch: frontmatterのnameと--roleが食い違う素材は非0で失敗するはずが成功した"
  else
    grep -q 'ROLE_NAME_MISMATCH' "$I1M6_WORK/name-mismatch.err" \
      && pass "role_name_mismatch: frontmatterのnameと--roleが食い違う素材は非0・ROLE_NAME_MISMATCHで失敗" \
      || fail_case "role_name_mismatch: 失敗はしたが理由がROLE_NAME_MISMATCHでない (stderr=[$(cat "$I1M6_WORK/name-mismatch.err")])"
  fi

  # nameフィールド自体が無い素材も同様に非0で失敗する（"名前が在るなら一致"
  # ではなく、8職種の実素材が全てnameを持つ前提＝欠落も不一致として扱う）。
  NONAME_DIR="$I1M6_WORK/agents-noname"
  mkdir -p "$NONAME_DIR"
  cat > "$NONAME_DIR/noname.md" <<'EOF'
---
description: test fixture without name field
tools: Read
---
body text
EOF
  if python3 "$AGENT_DEF" agents-json --dir "$NONAME_DIR" --role noname >/dev/null 2>"$I1M6_WORK/name-missing.err"; then
    fail_case "role_name_missing: nameフィールドが無い素材は非0で失敗するはずが成功した"
  else
    grep -q 'ROLE_NAME_MISMATCH' "$I1M6_WORK/name-missing.err" \
      && pass "role_name_missing: nameフィールドが無い素材は非0・ROLE_NAME_MISMATCHで失敗" \
      || fail_case "role_name_missing: 失敗はしたが理由がROLE_NAME_MISMATCHでない (stderr=[$(cat "$I1M6_WORK/name-missing.err")])"
  fi

  # 8職種の実素材（正常系）は引き続き成功する（回帰防止＝新設検査が正常系を壊さない）。
  if python3 "$AGENT_DEF" agents-json --dir "$AGENTS_DIR" --role implementer >/dev/null 2>"$I1M6_WORK/normal.err"; then
    pass "role_normal_still_succeeds: 実素材のimplementerは新設検査後も成功する"
  else
    fail_case "role_normal_still_succeeds: 実素材のimplementerが新設検査で失敗した (stderr=[$(cat "$I1M6_WORK/normal.err")])"
  fi

  rm -rf "$I1M6_WORK"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
