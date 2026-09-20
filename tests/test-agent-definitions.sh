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
# 検査対象の定義ディレクトリ。既定は repo の実定義。ラッパーと同じ変数名で
# 差し替えられる（職種の追加・削除を設定だけで完結させる設計 2026-09-20
# §4.3・§6.2＝`AIENV_AGENT_SOURCE_DIR=<dir> bash tests/test-agent-definitions.sh`。
# 固定職種の内容検査（1・2・4・7・9）も同じディレクトリに掛かるので、<dir> は
# 実定義の複製に fixture を足したものにする）。
AGENTS_DIR="${AIENV_AGENT_SOURCE_DIR:-$REPO_ROOT/claude/agents}"
AGENT_DEF_LIB="$REPO_ROOT/claude/hooks/lib"

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

# ------------------------------------------------------------------
# 定義ファイル契約 (a)〜(g) の検査（職種の追加・削除を設定だけで完結させる
# 設計 2026-09-20 §4.3・§6.1・FR-12）。<dir>/*.md のうち Path.is_file()
# （symlink を辿る＝ガードの `-f` と同じ集合）の各ファイルについて契約を
# **全部**評価し、違反を `<ファイル名>: <CODE>` で 1 行ずつ出力する（短絡
# しない）。0 ファイルは `NO_DEFINITIONS` を出力して非 0（空虚な真の禁止）。
# 違反 0 件なら無出力・exit 0。
#   (a)(b)(d) … agent_def.load_agent_def の例外コードで判定
#               （ROLE_INVALID→NAME_FORMAT_INVALID・ROLE_NAME_MISMATCH→
#               NAME_FILENAME_MISMATCH・FRONTMATTER_FIELD_*／BODY_EMPTY はそのまま）
#   (g)       … agent_def.vault_declared_writable の例外コードをそのまま
#               （VAULT_WRITE_DECLARATION_INVALID／VAULT_WRITE_DECLARATION_DUPLICATE
#               ／AIENV_KEY_UNKNOWN）。宣言の解析ロジックはテスト側に持たない
#   (c)(e)(f) … このヘルパ内で直接見る（BUILTIN_NAME_COLLISION・
#               MODEL_KEY_FORBIDDEN・EFFORT_KEY_FORBIDDEN・
#               PERMISSION_HEADING_COUNT・LEGACY_REFERENCE_PRESENT）
# ⚠️ 定義集合の等値・件数はここでは見ない（AC-6＝集合の閉列挙なし）。
# ------------------------------------------------------------------
contract_check() {
  PYTHONPATH="$AGENT_DEF_LIB" python3 - "$1" <<'PYCONTRACT'
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
    if len(re.findall(r"^## 権限", text, re.M)) != 1:
        add("PERMISSION_HEADING_COUNT")
    if "worker-role-prompts" in text:
        add("LEGACY_REFERENCE_PRESENT")

    # (g)
    try:
        agent_def.vault_declared_writable(agents_dir, stem)
    except agent_def.AgentDefError as exc:
        c = code_of(exc)
        add(CODE_MAP.get(c, c))

    for c in codes:
        violations.append(f"{path.name}: {c}")

for v in violations:
    print(v)
sys.exit(1 if violations else 0)
PYCONTRACT
}

# 要件 §7 の probe 定義（契約 (a)〜(g) だけを満たす最小形・宣言なし）を書く。
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
    echo "probe body"
    echo
    echo "## 権限"
    echo "成果物への書込＝なし／テスト＝なし／実行＝なし"
  } > "$out"
}

echo "=== AD-C1. 定義ファイル契約 (a)〜(g): 検査対象ディレクトリの全定義が違反 0 件（AC-9①・FR-12） ==="
{
  adc1_out="$(contract_check "$AGENTS_DIR")"
  adc1_rc=$?
  assert_eq "contract_check(AGENTS_DIR): exit 0" "0" "$adc1_rc"
  assert_eq "contract_check(AGENTS_DIR): 違反の出力が無い" "" "$adc1_out"
}

echo "=== AD-C2. probe を足した複製で契約 0 件・agents-json／allowed-tools が probe を出す・消せば SOURCE_UNREADABLE（AC-1③④・AC-2b③） ==="
{
  AGENT_DEF="$AGENT_DEF_LIB/agent_def.py"
  ADC2_WORK="$(mktemp -d)"
  ADC2_DIR="$ADC2_WORK/agents"
  mkdir -p "$ADC2_DIR"
  cp "$AGENTS_DIR"/*.md "$ADC2_DIR"/
  write_probe_def "$ADC2_DIR/zz-probe.md" zz-probe

  adc2_out="$(contract_check "$ADC2_DIR")"
  adc2_rc=$?
  assert_eq "複製+probe: contract_check exit 0" "0" "$adc2_rc"
  assert_eq "複製+probe: 違反の出力が無い" "" "$adc2_out"

  adc2_json="$(python3 "$AGENT_DEF" agents-json --dir "$ADC2_DIR" --role zz-probe 2>/dev/null)"
  adc2_keys="$(printf '%s' "$adc2_json" | python3 -c '
import json, sys
obj = json.load(sys.stdin)
top = sorted(obj.keys())
inner = sorted(obj[top[0]].keys()) if len(top) == 1 else []
print(",".join(top) + "|" + ",".join(inner))
' 2>/dev/null)"
  assert_eq "複製+probe: agents-json のトップキー={zz-probe}・値キー={description,tools,prompt}" "zz-probe|description,prompt,tools" "$adc2_keys"
  adc2_tools="$(python3 "$AGENT_DEF" allowed-tools --dir "$ADC2_DIR" --role zz-probe 2>/dev/null)"
  assert_eq "複製+probe: allowed-tools=Read" "Read" "$adc2_tools"

  rm -f "$ADC2_DIR/zz-probe.md"
  if python3 "$AGENT_DEF" agents-json --dir "$ADC2_DIR" --role zz-probe >/dev/null 2>"$ADC2_WORK/removed.err"; then
    fail_case "probe を消した複製: agents-json --role zz-probe は非 0 のはずが成功した"
  else
    grep -q 'SOURCE_UNREADABLE' "$ADC2_WORK/removed.err" \
      && pass "probe を消した複製: agents-json --role zz-probe は非 0・SOURCE_UNREADABLE" \
      || fail_case "probe を消した複製: 失敗はしたが理由が SOURCE_UNREADABLE でない (stderr=[$(cat "$ADC2_WORK/removed.err")])"
  fi
  rm -rf "$ADC2_WORK"
}

echo "=== AD-C3. 陰性 fixture（各 1 ファイルの一時ディレクトリ）で契約テストが非 0・理由が当該違反を指す（AC-9②） ==="
{
  ADC3_WORK="$(mktemp -d)"
  adc3_n=0

  # fixture ディレクトリを 1 つ作り、パスをグローバル ADC3_DIR に置く。
  adc3_new_dir() {
    adc3_n=$((adc3_n + 1))
    ADC3_DIR="$ADC3_WORK/case-$adc3_n"
    mkdir -p "$ADC3_DIR"
  }
  # contract_check が非 0 で、出力に <期待行> を含む。
  adc3_assert_violation() {
    local desc="$1" dir="$2" needle="$3" out rc
    out="$(contract_check "$dir")"
    rc=$?
    # `-e` … needle が `-zz.md: …` のように `-` で始まっても option と誤解させない。
    if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF -e "$needle"; then
      pass "$desc: 非 0・[$needle]"
    else
      fail_case "$desc (rc=$rc out=[$(printf '%s' "$out" | tr '\n' ' ')] want=[$needle])"
    fi
  }

  # (b) name ≠ ファイル名
  adc3_new_dir
  write_probe_def "$ADC3_DIR/zz-probe.md" zz-other
  adc3_assert_violation "name≠ファイル名" "$ADC3_DIR" "zz-probe.md: NAME_FILENAME_MISMATCH"

  # (a) 大文字・数字・`:`・先頭ハイフン
  for bad_name in 'Zz-Probe' 'zz-probe1' 'zz:probe' '-zz'; do
    adc3_new_dir
    write_probe_def "$ADC3_DIR/${bad_name}.md" "$bad_name"
    adc3_assert_violation "名前形式 [$bad_name]" "$ADC3_DIR" "${bad_name}.md: NAME_FORMAT_INVALID"
  done

  # (c) 組込み種別名との衝突（名前形式は有効＝出力が衝突の 1 行だけ）
  for builtin in general-purpose claude statusline-setup; do
    adc3_new_dir
    write_probe_def "$ADC3_DIR/${builtin}.md" "$builtin"
    adc3_out="$(contract_check "$ADC3_DIR")"
    adc3_rc=$?
    if [ "$adc3_rc" -ne 0 ] && [ "$adc3_out" = "${builtin}.md: BUILTIN_NAME_COLLISION" ]; then
      pass "組込み種別 [$builtin]: 非 0・出力が BUILTIN_NAME_COLLISION の 1 行だけ"
    else
      fail_case "組込み種別 [$builtin] (rc=$adc3_rc out=[$(printf '%s' "$adc3_out" | tr '\n' ' ')])"
    fi
  done

  # (f) `## 権限` 見出し 0 件
  adc3_new_dir
  cat > "$ADC3_DIR/zz-probe.md" <<'EOF'
---
name: zz-probe
description: probe without permission heading
tools: Read
---
probe body without the heading
EOF
  adc3_assert_violation "## 権限 が 0 件" "$ADC3_DIR" "zz-probe.md: PERMISSION_HEADING_COUNT"

  # (g) 値が不正
  adc3_new_dir
  write_probe_def "$ADC3_DIR/zz-probe.md" zz-probe "aienv-vault-write: yes"
  adc3_assert_violation "宣言の値が yes" "$ADC3_DIR" "zz-probe.md: VAULT_WRITE_DECLARATION_INVALID"

  # (g) 重複（不正値の後に allowed＝後勝ちで有効にならない・INVALID を出さない）
  adc3_new_dir
  write_probe_def "$ADC3_DIR/zz-probe.md" zz-probe "aienv-vault-write: yes" "aienv-vault-write: allowed"
  adc3_assert_violation "宣言が 2 行" "$ADC3_DIR" "zz-probe.md: VAULT_WRITE_DECLARATION_DUPLICATE"
  adc3_dup_out="$(contract_check "$ADC3_DIR")"
  assert_true "宣言が 2 行: VAULT_WRITE_DECLARATION_INVALID は出さない" "$(printf '%s\n' "$adc3_dup_out" | grep -qF 'VAULT_WRITE_DECLARATION_INVALID' && echo 0 || echo 1)"

  # (g) 未知の aienv- キー
  adc3_new_dir
  write_probe_def "$ADC3_DIR/zz-probe.md" zz-probe "aienv-vault-writ: allowed"
  adc3_assert_violation "aienv-vault-writ（打ち間違い）" "$ADC3_DIR" "zz-probe.md: AIENV_KEY_UNKNOWN"

  # (b) 生きた symlink `zz-alias.md → implementer.md`（ファイルを作らず symlink
  # だけで違反になる＝ガードの `-f` と同じく辿って数える）
  adc3_new_dir
  cp "$AGENTS_DIR/implementer.md" "$ADC3_DIR/implementer.md"
  ln -s implementer.md "$ADC3_DIR/zz-alias.md"
  adc3_assert_violation "symlink zz-alias.md→implementer.md" "$ADC3_DIR" "zz-alias.md: NAME_FILENAME_MISMATCH"

  # 0 ファイル＝空虚な真の禁止
  adc3_new_dir
  adc3_assert_violation "定義 0 件" "$ADC3_DIR" "NO_DEFINITIONS"

  rm -rf "$ADC3_WORK"
}

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
  # 期待値をハードコードする（正本＝agents の権限行（2026-09-19 段3-4）。
  # Vault の worker-role-prompts.md の表はリーダー向け一覧＝テストは読まない）。
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
  # verifierは指摘のみ（テスト実行は test-runner・2026-09-21 テスト3職分割）
  # ＝Codex 経路は read-only 一律。verifier.mdはCLIフラグ形式（--sandbox <値>）で記述している。
  assert_contains_file "verifier.md にread-only経路が境界つきで書かれている" "$AGENTS_DIR/verifier.md" "\`--sandbox read-only\`"
  # vault-scribeはCodexが演じない＝「対象外」の1行があればよい。
  assert_contains_file "vault-scribe.md は「Codexは演じない/対象外」と書かれている" "$AGENTS_DIR/vault-scribe.md" "Codex はこの職種を演じない"
}

# （旧 4b「## 権限 見出し 1 件・worker-role-prompts 参照 0 件」と旧 10「effort:
# 行 0 件」・旧 AC-1「集合の等値・model 不在」は契約 (e)(f) として AD-C1 の
# contract_check に吸収した＝設計 2026-09-20 §4.3。）

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

echo "=== 11. 新設②(設計-v1.1.1.md §7・D-6・要件AC-11b②): agents_json_matches_source_and_has_no_effort（検査対象ディレクトリの全定義） ==="
{
  AGENT_DEF="$REPO_ROOT/claude/hooks/lib/agent_def.py"
  result="$(python3 - "$AGENT_DEF" "$AGENTS_DIR" <<'PYCHECK'
import json
import subprocess
import sys
from pathlib import Path

agent_def, agents_dir = sys.argv[1], sys.argv[2]
# 定義集合は閉じた列挙で持たない（ディレクトリの中身そのもの＝設計 2026-09-20 §4.3）。
roles = [p.stem for p in sorted(Path(agents_dir).glob("*.md")) if p.is_file()]
assert roles, "no definitions found"


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
    pass "agents_json_matches_source_and_has_no_effort: 全定義で一致・effort/color/name無し"
  else
    fail_case "agents_json_matches_source_and_has_no_effort ($(printf '%s' "$result" | tr '\n' ' '))"
  fi
}

echo "=== 12. 検証1巡目 I1-m6 対応: agent_def.py の --role 検査（陰性ケース） ==="
{
  AGENT_DEF="$REPO_ROOT/claude/hooks/lib/agent_def.py"
  I1M6_WORK="$(mktemp -d)"

  # --role が ^[a-z][a-z-]*$ に一致しない（`../`混入・大文字・空文字・
  # 空白混入・数字＝契約 (a)・設計 2026-09-20 §6.3）ときは非0で失敗する
  # （実在のディレクトリ・実在の素材に対して検査する＝ファイル名連結より前に
  # 弾かれることを見る）。
  for bad_role in '../implementer' 'Implementer' '' 'imple menter' 'implementer/../x' 'implementer2' 'zz-probe-1'; do
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
  # ではなく、実素材が全てnameを持つ前提（契約 (b)）＝欠落も不一致として扱う）。
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
