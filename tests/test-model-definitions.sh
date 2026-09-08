#!/usr/bin/env bash
# tests/test-model-definitions.sh — モデル定義ファイルと候補指定-要件-2026-09-08.md
# （v1.7）§6のfixture27件＋実装回帰RG-1・版境界・cwd不変性・列ずれ回帰を
# claude/hooks/lib/profile_resolve.py に対して直接検証する。
#
# 正本: ~/work/takumi009-ai-env-private/docs/core-split/
#   モデル定義ファイルと候補指定-要件-2026-09-08.md（fixture・AC定義）
#   モデル定義ファイルと候補指定-設計-2026-09-08.md（§11 テスト戦略）
#
# tests/test-bootstrap-vault.sh等の既存8スイート（役割行fixtureが旧記法
# だった計247箇所）は別コミット群で新記法（model=<定義名>）へ変換済み
# （実装記録参照）。本ファイルは新機能（モデル定義ファイル・候補指定）の
# 受入条件を独立に検証する専用スイートとして新設した。
#
# 実行方法: bash tests/test-model-definitions.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
LIB="$REPO_ROOT/claude/hooks/lib/profile_resolve.py"
BOOTSTRAP="$REPO_ROOT/claude/hooks/bootstrap-vault.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$desc"; else
    fail_case "$desc (expected=[$expected] actual=[$actual])"
  fi
}
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$desc"; else
    fail_case "$desc (含まれない: \"$needle\" / 実際: $haystack)"
  fi
}
assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$desc"; else
    fail_case "$desc (含まれてはいけないのに含まれる: \"$needle\")"
  fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ============================================================
# §6.1 共通ベース FX-B1（要件v1.7・literal）
# ============================================================
BASE="$WORK/base"
mkdir -p "$BASE/agents"

cat > "$BASE/profile.md" <<'EOF'
---
schema_version: 6
profile_slug: fixture
team_mode:        configured value=full
no_read_paths:    unavailable
machine_role:     configured value=main
excluded_models:  configured value=none
role.leader:      configured model=opus-main
role.implementer: configured model=sonnet-main,codex-high
role.verifier:    configured model=codex-high
---
EOF

cat > "$BASE/models.conf" <<'EOF'
# モデル定義（このマシン専用・非配布）
[opus-main]
provider=anthropic-api
model=claude-opus-5
effort=high

[sonnet-main]
provider=anthropic-api
model=claude-sonnet-5

[codex-high]
provider=external
execution=external-cli
model=default
effort=high

# 以下2つはFX-B1の配役表からは参照しない（4 providerすべてを定義できる
# ことを陽性で固定するために置く＝AC-3）
[bedrock-opus]
provider=bedrock
model=opus

[mantle-sonnet]
provider=bedrock-mantle
model=anthropic.claude-sonnet-5
EOF

cat > "$BASE/agents/implementer.md" <<'EOF'
---
name: implementer
model: claude-sonnet-5
---
EOF
cat > "$BASE/agents/verifier.md" <<'EOF'
---
name: verifier
model: claude-opus-5
---
EOF
cat > "$BASE/agents/ja-doc.md" <<'EOF'
---
name: ja-doc
model: claude-sonnet-5
---
EOF

# fixture variant helper: FX-B1のprofile.mdを1行だけ置換/追記した版を作る。
# 使い方: variant_profile <出力先> <sed置換式...>
variant_profile() {
  local out="$1"; shift
  local expr
  cp "$BASE/profile.md" "$out"
  for expr in "$@"; do
    sed -i '' "$expr" "$out"
  done
}

R() { # R <profile> <agents_dir> — resolve
  python3 "$LIB" resolve "$1" --agents-dir "$2"
}
L() { # L <profile> — list-roles
  python3 "$LIB" list-roles "$1"
}
LD() { # LD <profile> <agents_dir> — resolve-leader
  python3 "$LIB" resolve-leader "$1" --agents-dir "$2"
}
C() { # C <profile> <role> [<model-def>] <agents_dir>
  local profile="$1" role="$2" def="$3" agents="$4"
  if [ -n "$def" ]; then
    python3 "$LIB" resolve-candidate "$profile" --role "$role" --model-def "$def" --agents-dir "$agents"
  else
    python3 "$LIB" resolve-candidate "$profile" --role "$role" --agents-dir "$agents"
  fi
}

export AIENV_MODEL_DEFS_FILE="$BASE/models.conf"

echo "=== AC-1: FX-B1・FX-B3（陽性）／FX-B2a・FX-B2b・FX-B2c（陰性） ==="
{
  out="$(R "$BASE/profile.md" "$BASE/agents")"; rc=$?
  assert_eq "FX-B1: exit0" "0" "$rc"
  case "$out" in
    "OK	schema_version=6"*) pass "FX-B1: OK\\tschema_version=6で始まる" ;;
    *) fail_case "FX-B1: OK\\tschema_version=6で始まる (実際=$out)" ;;
  esac

  variant_profile "$WORK/b3.md" '/role.verifier:/a\
role.ja-doc:      unavailable model=sonnet-main'
  out="$(R "$WORK/b3.md" "$BASE/agents")"; rc=$?
  assert_eq "FX-B3: exit0" "0" "$rc"
  lroles="$(L "$WORK/b3.md")"
  assert_contains "FX-B3: list-rolesにja-doc/unavailable/sonnet-mainの行" "$lroles" "$(printf 'role\tja-doc\tunavailable\tsonnet-main\tanthropic-api\tclaude-sonnet-5\tsubagent\t')"

  # 2026-09-08 Codexレビュー指摘・BLOCKING-1対応（1巡目）: 旧記法の断片
  # （"provider="）を変数へ分けてから展開する（AC-14のrepo検索＝完成
  # 文字列の直書き禁止に一致させないため。意図的な旧記法拒否fixtureで
  # あり、本物の旧記法の取りこぼしではない）。
  legacy_attr_frag="provider="
  variant_profile "$WORK/b2a.md" "s/role.implementer: configured model=sonnet-main,codex-high/role.implementer: configured ${legacy_attr_frag}anthropic-api model=sonnet-main,codex-high/"
  out="$(R "$WORK/b2a.md" "$BASE/agents")"; rc=$?
  assert_eq "FX-B2a: exit1" "1" "$rc"
  case "$out" in MINIMAL*) pass "FX-B2a: MINIMALで始まる" ;; *) fail_case "FX-B2a: MINIMALで始まる (実際=$out)" ;; esac

  variant_profile "$WORK/b2b.md" 's/role.implementer: configured model=sonnet-main,codex-high/role.implementer: unavailable/'
  out="$(R "$WORK/b2b.md" "$BASE/agents")"; rc=$?
  assert_eq "FX-B2b: exit1" "1" "$rc"
  case "$out" in MINIMAL*) pass "FX-B2b: MINIMALで始まる" ;; *) fail_case "FX-B2b: MINIMALで始まる (実際=$out)" ;; esac

  variant_profile "$WORK/b2c.md" '/role.verifier:/a\
role.ja-doc:      not_adopted model=sonnet-main'
  out="$(R "$WORK/b2c.md" "$BASE/agents")"; rc=$?
  assert_eq "FX-B2c: exit1" "1" "$rc"
  case "$out" in MINIMAL*) pass "FX-B2c: MINIMALで始まる" ;; *) fail_case "FX-B2c: MINIMALで始まる (実際=$out)" ;; esac
}

echo "=== AC-2: FX-B1のlist-rolesが4行に行単位完全一致 ==="
{
  actual="$(L "$BASE/profile.md")"
  expected="$(printf 'role\timplementer\tconfigured\tsonnet-main\tanthropic-api\tclaude-sonnet-5\tsubagent\t\nrole\timplementer\tconfigured\tcodex-high\texternal\tdefault\texternal-cli\thigh\nrole\tleader\tconfigured\topus-main\tanthropic-api\tclaude-opus-5\tsubagent\thigh\nrole\tverifier\tconfigured\tcodex-high\texternal\tdefault\texternal-cli\thigh')"
  assert_eq "AC-2: list-roles 4行完全一致" "$expected" "$actual"
}

echo "=== AC-3: FX-B1・FX-B7（陽性）／FX-B4a〜FX-B4d（陰性） ==="
{
  # FX-B1自体が4 provider全定義（陽性は上のAC-1で確認済み）。
  cp "$BASE/models.conf" "$WORK/b7.conf"
  # 空行・#コメント・前後空白を混ぜる（FR-2）。
  sed -i '' 's/^\[sonnet-main\]$/  [sonnet-main]  /' "$WORK/b7.conf"
  out="$(AIENV_MODEL_DEFS_FILE="$WORK/b7.conf" R "$BASE/profile.md" "$BASE/agents")"; rc=$?
  assert_eq "FX-B7: exit0" "0" "$rc"

  cp "$BASE/models.conf" "$WORK/b4a.conf"
  printf '\n[sonnet-main]\nprovider=anthropic-api\nmodel=claude-sonnet-5\n' >> "$WORK/b4a.conf"
  out="$(AIENV_MODEL_DEFS_FILE="$WORK/b4a.conf" R "$BASE/profile.md" "$BASE/agents")"; rc=$?
  assert_eq "FX-B4a: exit1（定義名重複）" "1" "$rc"

  cp "$BASE/models.conf" "$WORK/b4b.conf"
  sed -i '' '/^\[opus-main\]$/,/^$/{/^model=/d;}' "$WORK/b4b.conf"
  out="$(AIENV_MODEL_DEFS_FILE="$WORK/b4b.conf" R "$BASE/profile.md" "$BASE/agents")"; rc=$?
  assert_eq "FX-B4b: exit1（model欠落）" "1" "$rc"

  cp "$BASE/models.conf" "$WORK/b4c.conf"
  sed -i '' 's/^\[opus-main\]$/[Opus-Main]/' "$WORK/b4c.conf"
  out="$(AIENV_MODEL_DEFS_FILE="$WORK/b4c.conf" R "$BASE/profile.md" "$BASE/agents")"; rc=$?
  assert_eq "FX-B4c: exit1（定義名が大文字を含む）" "1" "$rc"

  out="$(AIENV_MODEL_DEFS_FILE="$WORK/does-not-exist.conf" R "$BASE/profile.md" "$BASE/agents")"; rc=$?
  assert_eq "FX-B4d: exit1（定義ファイル不在）" "1" "$rc"
}

echo "=== AC-4: FX-B5（未定義の定義名を参照） ==="
{
  variant_profile "$WORK/b5.md" 's/role.implementer: configured model=sonnet-main,codex-high/role.implementer: configured model=sonnet-main,does-not-exist/'
  out="$(R "$WORK/b5.md" "$BASE/agents")"; rc=$?
  assert_eq "FX-B5: exit1" "1" "$rc"
  assert_contains "FX-B5: 理由にimplementerを含む" "$out" "implementer"
  assert_contains "FX-B5: 理由にdoes-not-existを含む" "$out" "does-not-exist"
  lineno="$(grep -n '^role.implementer:' "$WORK/b5.md" | head -1 | cut -d: -f1)"
  assert_contains "FX-B5: 理由に行番号($lineno)を含む" "$out" "${lineno}行目"
}

echo "=== AC-5: FX-B6a・FX-B6e・FX-B6f（旧版拒否・T4-LEGACY） ==="
{
  # 2026-09-08 Codexレビュー指摘・BLOCKING-1対応（1巡目）: 旧記法の断片
  # （"provider="）を変数へ分けてから展開する（AC-14のrepo検索＝完成
  # 文字列の直書き禁止に一致させないため。意図的な旧版拒否fixtureであり、
  # 本物の旧記法の取りこぼしではない）。
  legacy_attr_frag="provider="
  cat > "$WORK/b6a.md" <<EOF
---
schema_version: 1
profile_slug: fixture
team_mode:        configured value=full
no_read_paths:    unavailable
machine_role:     configured value=main
excluded_models:  configured value=none
role.leader:      configured ${legacy_attr_frag}anthropic-api model=claude-opus-5 effort=high
role.implementer: configured ${legacy_attr_frag}anthropic-api model=claude-sonnet-5
role.verifier:    configured ${legacy_attr_frag}external execution=external-cli model=default effort=high
---
EOF
  out="$(R "$WORK/b6a.md" "$BASE/agents")"; rc=$?
  assert_eq "FX-B6a: exit1" "1" "$rc"
  case "$out" in OK*) fail_case "FX-B6a: OKで始まってはいけない" ;; *) pass "FX-B6a: OKで始まらない" ;; esac
  assert_contains "FX-B6a: 理由に「旧版」" "$out" "旧版"

  sed 's/schema_version: 1/schema_version: 5/' "$WORK/b6a.md" > "$WORK/b6e.md"
  out="$(R "$WORK/b6e.md" "$BASE/agents")"; rc=$?
  assert_eq "FX-B6e: exit1" "1" "$rc"
  case "$out" in OK*) fail_case "FX-B6e: OKで始まってはいけない" ;; *) pass "FX-B6e: OKで始まらない" ;; esac
  assert_contains "FX-B6e: 理由に「旧版」" "$out" "旧版"

  sed '/^schema_version:/d' "$BASE/profile.md" > "$WORK/b6f.md"
  out="$(R "$WORK/b6f.md" "$BASE/agents")"; rc=$?
  assert_eq "FX-B6f: exit1" "1" "$rc"
  assert_contains "FX-B6f: 理由に「旧版」" "$out" "旧版"

  # ⚠️ 5口すべて（R・L・LD・C）が同じT4-LEGACYへ落ちることも固定する。
  lout="$(L "$WORK/b6a.md" 2>&1)"; lrc=$?
  assert_eq "FX-B6a: list-rolesもexit1" "1" "$lrc"
  assert_contains "FX-B6a: list-rolesの理由にT4-LEGACY" "$lout" "T4-LEGACY"
  ldout="$(LD "$WORK/b6a.md" "$BASE/agents" 2>&1)"; ldrc=$?
  assert_eq "FX-B6a: resolve-leaderもexit1" "1" "$ldrc"
  assert_contains "FX-B6a: resolve-leaderの理由にT4-LEGACY" "$ldout" "T4-LEGACY"
  cout="$(C "$WORK/b6a.md" implementer sonnet-main "$BASE/agents" 2>&1)"; crc=$?
  assert_eq "FX-B6a: resolve-candidateもexit1" "1" "$crc"
  assert_contains "FX-B6a: resolve-candidateの理由にT4-LEGACY" "$cout" "T4-LEGACY"
}

echo "=== AC-6: FX-B1（陽性）／FX-B8（除外モデル・陰性） ==="
{
  variant_profile "$WORK/b8.md" 's/excluded_models:  configured value=none/excluded_models:  configured value=anthropic-api\/claude-sonnet-5/'
  out="$(R "$WORK/b8.md" "$BASE/agents")"; rc=$?
  assert_eq "FX-B8: exit1" "1" "$rc"
  assert_contains "FX-B8: 理由にrole.implementer" "$out" "role.implementer"
  lineno="$(grep -n '^role.implementer:' "$WORK/b8.md" | head -1 | cut -d: -f1)"
  assert_contains "FX-B8: 理由に行番号($lineno)" "$out" "${lineno}行目"
}

echo "=== AC-7: 定義ファイルの候補注入（bootstrap-vault.sh・I） ==="
{
  FAKEHOME="$WORK/fakehome-ac7"
  mkdir -p "$FAKEHOME/.config/takumi009-ai-env"
  cp "$BASE/profile.md" "$FAKEHOME/.config/takumi009-ai-env/profile.md"
  cp "$BASE/models.conf" "$FAKEHOME/.config/takumi009-ai-env/models.conf"
  ctx="$(echo '{"session_id":"test-model-defs"}' \
    | HOME="$FAKEHOME" BOOTSTRAP_VAULT="/nonexistent-vault" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
      VAULT_READS_LOG="/nonexistent-dir/vault-reads.tsv" VAULT_RECALL_LOG="/nonexistent-dir/vault-recall.tsv" \
      VAULT_INVENTORY_LOG_DIR="/nonexistent-dir/vault-inventory" \
      PREFERENCES_PROPOSALS_DIR="/nonexistent-dir/preferences-proposals" \
      MAINTENANCE_LAST_RUN_FILE="/nonexistent-dir/last-run.json" \
      AIENV_AGENTS_DIR="$BASE/agents" \
      BOOTSTRAP_ENABLE_LOCAL_PROFILE=1 "$BOOTSTRAP" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' 2>/dev/null)"
  assert_contains "AC-7陽性: sonnet-mainが現れる" "$ctx" "sonnet-main"
  assert_contains "AC-7陽性: codex-highが現れる" "$ctx" "codex-high"
  assert_not_contains "AC-7陽性: claude-sonnet-5は現れない" "$ctx" "claude-sonnet-5"

  ctx2="$(echo '{"session_id":"test-model-defs-2"}' \
    | HOME="$FAKEHOME" BOOTSTRAP_VAULT="/nonexistent-vault" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
      VAULT_READS_LOG="/nonexistent-dir/vault-reads.tsv" VAULT_RECALL_LOG="/nonexistent-dir/vault-recall.tsv" \
      VAULT_INVENTORY_LOG_DIR="/nonexistent-dir/vault-inventory" \
      PREFERENCES_PROPOSALS_DIR="/nonexistent-dir/preferences-proposals" \
      MAINTENANCE_LAST_RUN_FILE="/nonexistent-dir/last-run.json" \
      AIENV_AGENTS_DIR="$BASE/agents" AIENV_MODEL_DEFS_FILE="/nonexistent-dir/models.conf" \
      BOOTSTRAP_ENABLE_LOCAL_PROFILE=1 "$BOOTSTRAP" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' 2>/dev/null)"
  assert_contains "AC-7陰性: 定義ファイル不在で警告を含む" "$ctx2" "解決できません"
}

echo "=== AC-8: known-keysの3行目がSCHEMA_VERSION:6 ==="
{
  kk="$(python3 "$LIB" known-keys)"; rc=$?
  assert_eq "AC-8: exit0" "0" "$rc"
  third="$(printf '%s\n' "$kk" | sed -n '3p')"
  assert_eq "AC-8: 3行目完全一致" "SCHEMA_VERSION:6" "$third"
}

echo "=== AC-9: FX-B9（リーダーは先頭候補のみ解決） ==="
{
  variant_profile "$WORK/b9.md" 's/role.leader:      configured model=opus-main/role.leader:      configured model=opus-main,sonnet-main/'
  out="$(LD "$WORK/b9.md" "$BASE/agents")"; rc=$?
  assert_eq "FX-B9: exit0" "0" "$rc"
  keys="$(printf '%s' "$out" | python3 -c 'import json,sys; print(",".join(sorted(json.load(sys.stdin).keys())))')"
  assert_eq "FX-B9: キー集合" "effort,model" "$keys"
  model_val="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["model"])')"
  assert_eq "FX-B9: model==claude-opus-5（先頭候補）" "claude-opus-5" "$model_val"
}

echo "=== AC-10: FX-B1（MODEL_MISMATCH無し）／FX-B10・FX-B11（陰性） ==="
{
  out="$(R "$BASE/profile.md" "$BASE/agents")"
  assert_not_contains "FX-B1: MODEL_MISMATCHを含まない" "$out" "MODEL_MISMATCH"

  variant_profile "$WORK/b10.md" 's/role.implementer: configured model=sonnet-main,codex-high/role.implementer: configured model=sonnet-main,opus-main/'
  out="$(R "$WORK/b10.md" "$BASE/agents")"; rc=$?
  assert_eq "FX-B10: exit0" "0" "$rc"
  cnt="$(printf '%s' "$out" | grep -o 'MODEL_MISMATCH:implementer:opus-main' | wc -l | tr -d ' ')"
  assert_eq "FX-B10: MODEL_MISMATCH:implementer:opus-mainがちょうど1件" "1" "$cnt"
  assert_not_contains "FX-B10: sonnet-main分は現れない" "$out" "MODEL_MISMATCH:implementer:sonnet-main"

  mkdir -p "$WORK/agents-b11"
  cat > "$WORK/agents-b11/implementer.md" <<'EOF'
---
name: implementer
model: sonnet
---
EOF
  cp "$BASE/agents/verifier.md" "$BASE/agents/ja-doc.md" "$WORK/agents-b11/"
  variant_profile "$WORK/b11.md" 's/role.implementer: configured model=sonnet-main,codex-high/role.implementer: configured model=sonnet-main/'
  out="$(R "$WORK/b11.md" "$WORK/agents-b11")"; rc=$?
  assert_eq "FX-B11: exit0" "0" "$rc"
  assert_contains "FX-B11: MODEL_MISMATCH:implementer:sonnet-main" "$out" "MODEL_MISMATCH:implementer:sonnet-main"
}

echo "=== W（ラッパー用一時スタブ）の準備 ==="
STUB="$WORK/codex-exec-stub.sh"
CALLS_LOG="$WORK/codex_exec_calls.log"
cat > "$STUB" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$CODEX_EXEC_CALLS_LOG"
EOF
chmod +x "$STUB"
export CODEX_EXEC_CALLS_LOG="$CALLS_LOG"

# invoke_via_candidate <profile> <role> <model-def> <agents_dir> —
# 契約書§5.5のリーダー手順①②をテスト側で再現する（resolve-candidateの
# exitが0でなければスタブを呼ばない＝AC-11の「||で受けて落とす」型そのもの
# が検査対象）。
invoke_via_candidate() {
  local profile="$1" role="$2" def="$3" agents="$4"
  local c_out c_rc=0
  c_out="$(python3 "$LIB" resolve-candidate "$profile" --role "$role" --model-def "$def" --agents-dir "$agents" 2>&1)" || c_rc=$?
  [ "$c_rc" -ne 0 ] && return "$c_rc"
  local codex_args
  codex_args="$(printf '%s\n' "$c_out" | awk -F'\t' '$1=="CODEX_ARGS"{print $2}')"
  # shellcheck disable=SC2086
  "$STUB" --cwd /tmp/example --sandbox read-only --out /tmp/example.out --prompt-file - $codex_args
  return 0
}

echo "=== AC-11: FX-B12a（陽性）／FX-B12b・FX-B12c（陰性・exit2かつWの記録0行） ==="
{
  out="$(C "$BASE/profile.md" implementer codex-high "$BASE/agents")"; rc=$?
  assert_eq "FX-B12a: exit0" "0" "$rc"
  assert_eq "FX-B12a: OK行" "$(printf 'OK\tcodex-high\tdefault\texternal-cli\thigh')" "$(printf '%s' "$out" | sed -n '1p')"

  # 2026-09-08 Codexレビュー指摘・MAJOR-3対応（1巡目）: 陰性2件は
  # resolve-candidateの生exitだけでなく、「||で受けて落とす」型
  # （invoke_via_candidate）を実際に通してWの記録が0行のままであることまで
  # 固定する（要件AC-11の「陰性＝2件ともexit2かつWの記録が0行」）。
  : > "$CALLS_LOG"
  invoke_via_candidate "$BASE/profile.md" implementer "" "$BASE/agents"; rc=$?
  assert_eq "FX-B12b: exit2（定義名省略）" "2" "$rc"
  cnt_b="$(wc -l < "$CALLS_LOG" | tr -d ' ')"
  assert_eq "FX-B12b: Wの記録が0行" "0" "$cnt_b"

  : > "$CALLS_LOG"
  invoke_via_candidate "$BASE/profile.md" implementer opus-main "$BASE/agents"; rc=$?
  assert_eq "FX-B12c: exit2（候補外）" "2" "$rc"
  cnt_c="$(wc -l < "$CALLS_LOG" | tr -d ' ')"
  assert_eq "FX-B12c: Wの記録が0行" "0" "$cnt_c"
}

echo "=== RG-2: resolve-candidateの2分岐（定義名省略の無条件exit2・unavailableからのfallback）の実装回帰（Codexレビュー指摘・MAJOR対応2巡目。要件fixtureは増やさない） ==="
{
  # ①配役表が真に不在＋定義名省略: プロファイル読取より前に判定するため
  # 無条件でexit2・CANDIDATE_UNSPECIFIED（プロファイル不在起因の他コードに
  # ならないことを固定する）。
  out_rg2a="$(C "$WORK/does-not-exist-rg2a.md" implementer "" "$BASE/agents" 2>&1)"; rc_rg2a=$?
  assert_eq "RG-2①: exit2（配役表不在＋定義名省略）" "2" "$rc_rg2a"
  assert_contains "RG-2①: CANDIDATE_UNSPECIFIED" "$out_rg2a" "CANDIDATE_UNSPECIFIED"

  # ②モデル定義ファイルが真に不在＋定義名省略: 同じく無条件でexit2・
  # CANDIDATE_UNSPECIFIED（T12等の定義ファイル起因コードにならないことを
  # 固定する）。
  out_rg2b="$(AIENV_MODEL_DEFS_FILE="$WORK/does-not-exist-rg2b.conf" python3 "$LIB" resolve-candidate "$BASE/profile.md" --role implementer --agents-dir "$BASE/agents" 2>&1)"; rc_rg2b=$?
  assert_eq "RG-2②: exit2（定義ファイル不在＋定義名省略）" "2" "$rc_rg2b"
  assert_contains "RG-2②: CANDIDATE_UNSPECIFIED" "$out_rg2b" "CANDIDATE_UNSPECIFIED"

  # ③role.implementerがunavailable＋使用可能なfallback: 本命は§3.6のとおり
  # 評価せず直ちにfallbackへ進み、fallbackの定義（codex-high）を返す
  # （exit0）。
  variant_profile "$WORK/rg2c.md" \
    's/role.implementer: configured model=sonnet-main,codex-high/role.implementer: unavailable model=sonnet-main/' \
    '/role.implementer:/a\
fallback.implementer: configured model=codex-high'
  out_rg2c="$(python3 "$LIB" resolve-candidate "$WORK/rg2c.md" --role implementer --model-def sonnet-main --agents-dir "$BASE/agents")"; rc_rg2c=$?
  assert_eq "RG-2③: exit0（unavailable→fallback発火）" "0" "$rc_rg2c"
  sel_rg2c="$(printf '%s' "$out_rg2c" | sed -n '1p' | awk -F'\t' '{print $2}')"
  assert_eq "RG-2③: 選択結果がcodex-high（fallback経由）" "codex-high" "$sel_rg2c"

  # ④role.implementerがunavailable＋fallback不在: CANDIDATE_UNUSABLE:
  # ROLE_UNAVAILABLEという安定コードでexit1になる。
  variant_profile "$WORK/rg2d.md" \
    's/role.implementer: configured model=sonnet-main,codex-high/role.implementer: unavailable model=sonnet-main/'
  out_rg2d="$(python3 "$LIB" resolve-candidate "$WORK/rg2d.md" --role implementer --model-def sonnet-main --agents-dir "$BASE/agents" 2>&1 1>/dev/null)"; rc_rg2d=$?
  assert_eq "RG-2④: exit1（unavailable・fallback不在）" "1" "$rc_rg2d"
  assert_contains "RG-2④: CANDIDATE_UNUSABLE:ROLE_UNAVAILABLE" "$out_rg2d" "CANDIDATE_UNUSABLE:ROLE_UNAVAILABLE"
}

echo "=== AC-12・AC-16: FX-B1（--model無し）・FX-B15（--model gpt-5-codex） ==="
{
  : > "$CALLS_LOG"
  invoke_via_candidate "$BASE/profile.md" verifier codex-high "$BASE/agents"
  rec="$(cat "$CALLS_LOG")"
  assert_contains "FX-B1: --cwd" "$rec" "--cwd /tmp/example"
  assert_contains "FX-B1: --sandbox" "$rec" "--sandbox read-only"
  assert_contains "FX-B1: --out" "$rec" "--out /tmp/example.out"
  assert_contains "FX-B1: --prompt-file" "$rec" "--prompt-file -"
  assert_contains "FX-B1: --effort high" "$rec" "--effort high"
  assert_not_contains "FX-B1: --modelは現れない（model=default）" "$rec" "--model "
  # 2026-09-08 Codexレビュー指摘・MAJOR-3対応（1巡目）: 部分文字列一致
  # だけでなく、Wの記録がちょうど1行（1起動）で、必須4引数＋--effortが
  # それぞれちょうど1回だけ現れることを固定する（要件AC-12「各1回ずつ」）。
  assert_eq "FX-B1: Wの記録はちょうど1行" "1" "$(wc -l < "$CALLS_LOG" | tr -d ' ')"
  for flag in '\-\-cwd /tmp/example' '\-\-sandbox read-only' '\-\-out /tmp/example.out' '\-\-prompt-file -' '\-\-effort high'; do
    cnt_flag="$(grep -o -- "$flag" "$CALLS_LOG" | wc -l | tr -d ' ')"
    assert_eq "FX-B1: ${flag}はちょうど1回" "1" "$cnt_flag"
  done

  cp "$BASE/models.conf" "$WORK/b15.conf"
  cat >> "$WORK/b15.conf" <<'EOF'

[codex-gpt]
provider=external
execution=external-cli
model=gpt-5-codex
effort=high
EOF
  variant_profile "$WORK/b15.md" 's/role.verifier:    configured model=codex-high/role.verifier:    configured model=codex-gpt/'
  : > "$CALLS_LOG"
  c_out="$(AIENV_MODEL_DEFS_FILE="$WORK/b15.conf" python3 "$LIB" resolve-candidate "$WORK/b15.md" --role verifier --model-def codex-gpt --agents-dir "$BASE/agents")"
  codex_args="$(printf '%s\n' "$c_out" | awk -F'\t' '$1=="CODEX_ARGS"{print $2}')"
  # shellcheck disable=SC2086
  "$STUB" --cwd /tmp/example --sandbox read-only --out /tmp/example.out --prompt-file - $codex_args
  rec="$(cat "$CALLS_LOG")"
  assert_contains "FX-B15: --model gpt-5-codexが1回" "$rec" "--model gpt-5-codex"
  cnt="$(grep -o -- '--model gpt-5-codex' "$CALLS_LOG" | wc -l | tr -d ' ')"
  assert_eq "FX-B15: --model gpt-5-codexはちょうど1回" "1" "$cnt"
  assert_contains "FX-B15: --effort high" "$rec" "--effort high"
  # AC-16: Cが返した値とWが記録した引数が対応している（同一実行内）。
  c_model="$(printf '%s' "$c_out" | sed -n '1p' | awk -F'\t' '{print $3}')"
  c_effort="$(printf '%s' "$c_out" | sed -n '1p' | awk -F'\t' '{print $5}')"
  assert_eq "AC-16: Cのmodelがgpt-5-codex" "gpt-5-codex" "$c_model"
  assert_contains "AC-16: Wの記録にCのmodelが現れる" "$rec" "--model $c_model"
  assert_contains "AC-16: Wの記録にCのeffortが現れる" "$rec" "--effort $c_effort"
}

echo "=== AC-13: FX-B13a（fallback不発火）・FX-B13b（fallback発火） ==="
{
  cp "$BASE/models.conf" "$WORK/b13.conf"
  cat >> "$WORK/b13.conf" <<'EOF'

[codex-fallback]
provider=external
execution=external-cli
model=default
EOF
  variant_profile "$WORK/b13.md" '/role.implementer:/a\
fallback.implementer: configured model=codex-fallback'
  mkdir -p "$WORK/agents-b13"
  cp "$BASE/agents/verifier.md" "$BASE/agents/ja-doc.md" "$WORK/agents-b13/"
  # implementer.mdを置かない＝sonnet-mainが職種定義の存在検査(V1-b)で使用不可、
  # codex-highは使用可（external-cliはV1-b対象外）。

  : > "$CALLS_LOG"
  c_out="$(AIENV_MODEL_DEFS_FILE="$WORK/b13.conf" python3 "$LIB" resolve-candidate "$WORK/b13.md" --role implementer --model-def codex-high --agents-dir "$WORK/agents-b13")"; rc=$?
  assert_eq "FX-B13a: exit0" "0" "$rc"
  sel="$(printf '%s' "$c_out" | sed -n '1p' | awk -F'\t' '{print $2}')"
  assert_eq "FX-B13a: 選択結果がcodex-high（fallback不発火）" "codex-high" "$sel"
  # 2026-09-08 Codexレビュー指摘・MAJOR-3対応（1巡目）: 要件AC-13の
  # 「Wの記録（1行）は外部CLIの候補が選ばれたときだけ見る」を実際にWまで
  # 通して固定する（両fixtureとも結果は外部CLIなので見られる）。
  codex_args_a="$(printf '%s\n' "$c_out" | awk -F'\t' '$1=="CODEX_ARGS"{print $2}')"
  # shellcheck disable=SC2086
  "$STUB" --cwd /tmp/example --sandbox read-only --out /tmp/example.out --prompt-file - $codex_args_a
  assert_eq "FX-B13a: Wの記録はちょうど1行" "1" "$(wc -l < "$CALLS_LOG" | tr -d ' ')"

  : > "$CALLS_LOG"
  c_out2="$(AIENV_MODEL_DEFS_FILE="$WORK/b13.conf" python3 "$LIB" resolve-candidate "$WORK/b13.md" --role implementer --model-def sonnet-main --agents-dir "$WORK/agents-b13")"; rc=$?
  assert_eq "FX-B13b: exit0" "0" "$rc"
  sel2="$(printf '%s' "$c_out2" | sed -n '1p' | awk -F'\t' '{print $2}')"
  assert_eq "FX-B13b: 選択結果がcodex-fallback（fallback発火）" "codex-fallback" "$sel2"
  codex_args_b="$(printf '%s\n' "$c_out2" | awk -F'\t' '$1=="CODEX_ARGS"{print $2}')"
  # shellcheck disable=SC2086
  "$STUB" --cwd /tmp/example --sandbox read-only --out /tmp/example.out --prompt-file - $codex_args_b
  assert_eq "FX-B13b: Wの記録はちょうど1行" "1" "$(wc -l < "$CALLS_LOG" | tr -d ' ')"
}

echo "=== RG-1: fallback側のMODEL_MISMATCH拒否（D-14。実装回帰・要件fixtureは増やさない） ==="
{
  # bedrock-opusは本命（bedrock.envを渡さないので経路がdisabled＝V9-d3で
  # 使用不可・決定的）。fallback.implementer=sonnet-main（anthropic-api/
  # subagentの1件）。職種定義implementer.mdはmodel: claude-opus-5にして
  # sonnet-main（claude-sonnet-5）と不一致にする。
  variant_profile "$WORK/rg1.md" \
    's/role.implementer: configured model=sonnet-main,codex-high/role.implementer: configured model=bedrock-opus/' \
    '/role.implementer:/a\
fallback.implementer: configured model=sonnet-main'
  mkdir -p "$WORK/agents-rg1"
  cat > "$WORK/agents-rg1/implementer.md" <<'EOF'
---
name: implementer
model: claude-opus-5
---
EOF
  cp "$BASE/agents/verifier.md" "$BASE/agents/ja-doc.md" "$WORK/agents-rg1/"

  out="$(python3 "$LIB" resolve-candidate "$WORK/rg1.md" --role implementer --model-def bedrock-opus --agents-dir "$WORK/agents-rg1" 2>&1 1>"$WORK/rg1.stdout")"
  rc=$?
  stdout_content="$(cat "$WORK/rg1.stdout")"
  assert_eq "RG-1: exit1" "1" "$rc"
  assert_eq "RG-1: stdoutが1文字も出ない" "" "$stdout_content"
  assert_contains "RG-1: stderrがCANDIDATE_UNUSABLE:MODEL_MISMATCHで始まる" "$out" "CANDIDATE_UNUSABLE:MODEL_MISMATCH"
}

# 2026-09-08 Codexレビュー指摘・MAJOR-3対応（1巡目）: 設計§11.3の
# 「新設2件」は明示的にtest-bootstrap-vault.shへの収容先を指定しているため、
# I（bootstrap-vault.sh経由）の分は同ファイルの77・78番に置いた（本ファイル
# はR/L/LD/Cの4口だけを担当）。
echo "=== T13: AIENV_MODEL_DEFS_FILEが相対パスならR/L/LD/Cの4口がT13で拒否（I口はtest-bootstrap-vault.sh 77番） ==="
{
  out="$(cd /tmp && AIENV_MODEL_DEFS_FILE="relative/models.conf" python3 "$LIB" resolve "$BASE/profile.md" --agents-dir "$BASE/agents" 2>&1)"; rc=$?
  assert_eq "T13(R): exit1" "1" "$rc"
  assert_contains "T13(R): 理由文" "$out" "T13"

  lout="$(cd /tmp && AIENV_MODEL_DEFS_FILE="relative/models.conf" python3 "$LIB" list-roles "$BASE/profile.md" 2>&1)"; lrc=$?
  assert_eq "T13(L): exit1" "1" "$lrc"
  assert_contains "T13(L): 理由文" "$lout" "T13"

  ldout="$(cd /tmp && AIENV_MODEL_DEFS_FILE="relative/models.conf" python3 "$LIB" resolve-leader "$BASE/profile.md" --agents-dir "$BASE/agents" 2>&1)"; ldrc=$?
  assert_eq "T13(LD): exit1" "1" "$ldrc"
  assert_contains "T13(LD): 理由文" "$ldout" "T13"

  cout="$(cd /tmp && AIENV_MODEL_DEFS_FILE="relative/models.conf" python3 "$LIB" resolve-candidate "$BASE/profile.md" --role implementer --model-def sonnet-main --agents-dir "$BASE/agents" 2>&1)"; crc=$?
  assert_eq "T13(C): exit1" "1" "$crc"
  assert_contains "T13(C): 理由文" "$cout" "T13"
}

echo "=== cwd不変性: 同じ絶対パスなら呼び出し元cwdを変えても同じ結果（R・L・LD・Cの4口・I口はtest-bootstrap-vault.sh 78番） ==="
{
  # 2026-09-08 Codexレビュー指摘・MAJOR対応（2巡目）: R口だけでなくL・LD・
  # C口についてもcwd不変性を固定する（設計§9.2⚠️「同じ変数を見る」が
  # 「同じ実体を指す」ことの保証。5口のうちR・L・LD・Cをここで、Iを
  # test-bootstrap-vault.sh 78番で担う）。stdoutだけでなくexit codeの一致
  # も見る。
  run_in_cwd() { # run_in_cwd <cwd> <subcommand...> — 標準出力とexitを1行TSVで返す
    local dir="$1"; shift
    local out rc=0
    out="$(cd "$dir" && AIENV_MODEL_DEFS_FILE="$BASE/models.conf" python3 "$LIB" "$@" 2>&1)" || rc=$?
    printf '%s\t%s' "$rc" "$out"
  }

  r1="$(run_in_cwd /tmp resolve "$BASE/profile.md" --agents-dir "$BASE/agents")"
  r2="$(run_in_cwd "$REPO_ROOT" resolve "$BASE/profile.md" --agents-dir "$BASE/agents")"
  r3="$(run_in_cwd "$WORK" resolve "$BASE/profile.md" --agents-dir "$BASE/agents")"
  assert_eq "cwd不変性(R): /tmp と REPO_ROOT で同じ結果(exit+stdout)" "$r1" "$r2"
  assert_eq "cwd不変性(R): /tmp と WORK で同じ結果(exit+stdout)" "$r1" "$r3"

  l1="$(run_in_cwd /tmp list-roles "$BASE/profile.md")"
  l2="$(run_in_cwd "$REPO_ROOT" list-roles "$BASE/profile.md")"
  l3="$(run_in_cwd "$WORK" list-roles "$BASE/profile.md")"
  assert_eq "cwd不変性(L): /tmp と REPO_ROOT で同じ結果(exit+stdout)" "$l1" "$l2"
  assert_eq "cwd不変性(L): /tmp と WORK で同じ結果(exit+stdout)" "$l1" "$l3"

  ld1="$(run_in_cwd /tmp resolve-leader "$BASE/profile.md" --agents-dir "$BASE/agents")"
  ld2="$(run_in_cwd "$REPO_ROOT" resolve-leader "$BASE/profile.md" --agents-dir "$BASE/agents")"
  ld3="$(run_in_cwd "$WORK" resolve-leader "$BASE/profile.md" --agents-dir "$BASE/agents")"
  assert_eq "cwd不変性(LD): /tmp と REPO_ROOT で同じ結果(exit+stdout)" "$ld1" "$ld2"
  assert_eq "cwd不変性(LD): /tmp と WORK で同じ結果(exit+stdout)" "$ld1" "$ld3"

  c1="$(run_in_cwd /tmp resolve-candidate "$BASE/profile.md" --role implementer --model-def sonnet-main --agents-dir "$BASE/agents")"
  c2="$(run_in_cwd "$REPO_ROOT" resolve-candidate "$BASE/profile.md" --role implementer --model-def sonnet-main --agents-dir "$BASE/agents")"
  c3="$(run_in_cwd "$WORK" resolve-candidate "$BASE/profile.md" --role implementer --model-def sonnet-main --agents-dir "$BASE/agents")"
  assert_eq "cwd不変性(C): /tmp と REPO_ROOT で同じ結果(exit+stdout)" "$c1" "$c2"
  assert_eq "cwd不変性(C): /tmp と WORK で同じ結果(exit+stdout)" "$c1" "$c3"
}

echo ""
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
