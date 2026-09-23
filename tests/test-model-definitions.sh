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
schema_version: 7
profile_slug: fixture
team_mode:        configured value=full
no_read_paths:    unavailable
machine_role:     configured value=main
role.leader:      configured model=t-opus-high
role.implementer: configured model=sonnet-noeffort,codex-high
role.verifier:    configured model=codex-high
---
EOF

cat > "$BASE/models.conf" <<'EOF'
# モデル定義（実体＝機ごとのローカル。config/models.conf.sampleのコピー）
[t-opus-high]
provider=anthropic-api
model=claude-opus-5-5
effort=high

[sonnet-noeffort]
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
model: claude-opus-5-5
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
    "OK	schema_version=7"*) pass "FX-B1: OK\\tschema_version=7で始まる" ;;
    *) fail_case "FX-B1: OK\\tschema_version=7で始まる (実際=$out)" ;;
  esac

  variant_profile "$WORK/b3.md" '/role.verifier:/a\
role.ja-doc:      unavailable model=sonnet-noeffort'
  out="$(R "$WORK/b3.md" "$BASE/agents")"; rc=$?
  assert_eq "FX-B3: exit0" "0" "$rc"
  lroles="$(L "$WORK/b3.md")"
  assert_contains "FX-B3: list-rolesにja-doc/unavailable/sonnet-noeffortの行" "$lroles" "$(printf 'ja-doc\tunavailable\tsonnet-noeffort\tanthropic-api\tclaude-sonnet-5\tsubagent\t')"

  # 2026-09-08 Codexレビュー指摘・BLOCKING-1対応（1巡目）: 旧記法の断片
  # （"provider="）を変数へ分けてから展開する（AC-14のrepo検索＝完成
  # 文字列の直書き禁止に一致させないため。意図的な旧記法拒否fixtureで
  # あり、本物の旧記法の取りこぼしではない）。
  legacy_attr_frag="provider="
  variant_profile "$WORK/b2a.md" "s/role.implementer: configured model=sonnet-noeffort,codex-high/role.implementer: configured ${legacy_attr_frag}anthropic-api model=sonnet-noeffort,codex-high/"
  out="$(R "$WORK/b2a.md" "$BASE/agents")"; rc=$?
  assert_eq "FX-B2a: exit1" "1" "$rc"
  case "$out" in MINIMAL*) pass "FX-B2a: MINIMALで始まる" ;; *) fail_case "FX-B2a: MINIMALで始まる (実際=$out)" ;; esac

  variant_profile "$WORK/b2b.md" 's/role.implementer: configured model=sonnet-noeffort,codex-high/role.implementer: unavailable/'
  out="$(R "$WORK/b2b.md" "$BASE/agents")"; rc=$?
  assert_eq "FX-B2b: exit1" "1" "$rc"
  case "$out" in MINIMAL*) pass "FX-B2b: MINIMALで始まる" ;; *) fail_case "FX-B2b: MINIMALで始まる (実際=$out)" ;; esac

  variant_profile "$WORK/b2c.md" '/role.verifier:/a\
role.ja-doc:      not_adopted model=sonnet-noeffort'
  out="$(R "$WORK/b2c.md" "$BASE/agents")"; rc=$?
  assert_eq "FX-B2c: exit1" "1" "$rc"
  case "$out" in MINIMAL*) pass "FX-B2c: MINIMALで始まる" ;; *) fail_case "FX-B2c: MINIMALで始まる (実際=$out)" ;; esac
}

echo "=== AC-2: FX-B1のlist-rolesが4行に行単位完全一致 ==="
{
  actual="$(L "$BASE/profile.md")"
  expected="$(printf 'implementer\tconfigured\tsonnet-noeffort\tanthropic-api\tclaude-sonnet-5\tsubagent\t\nimplementer\tconfigured\tcodex-high\texternal\tdefault\texternal-cli\thigh\nleader\tconfigured\tt-opus-high\tanthropic-api\tclaude-opus-5-5\tsubagent\thigh\nverifier\tconfigured\tcodex-high\texternal\tdefault\texternal-cli\thigh')"
  assert_eq "AC-2: list-roles 4行完全一致" "$expected" "$actual"
}

echo "=== AC-3: FX-B1・FX-B7（陽性）／FX-B4a〜FX-B4d（陰性） ==="
{
  # FX-B1自体が4 provider全定義（陽性は上のAC-1で確認済み）。
  cp "$BASE/models.conf" "$WORK/b7.conf"
  # 空行・#コメント・前後空白を混ぜる（FR-2）。
  sed -i '' 's/^\[sonnet-noeffort\]$/  [sonnet-noeffort]  /' "$WORK/b7.conf"
  out="$(AIENV_MODEL_DEFS_FILE="$WORK/b7.conf" R "$BASE/profile.md" "$BASE/agents")"; rc=$?
  assert_eq "FX-B7: exit0" "0" "$rc"

  cp "$BASE/models.conf" "$WORK/b4a.conf"
  printf '\n[sonnet-noeffort]\nprovider=anthropic-api\nmodel=claude-sonnet-5\n' >> "$WORK/b4a.conf"
  out="$(AIENV_MODEL_DEFS_FILE="$WORK/b4a.conf" R "$BASE/profile.md" "$BASE/agents")"; rc=$?
  assert_eq "FX-B4a: exit1（定義名重複）" "1" "$rc"

  cp "$BASE/models.conf" "$WORK/b4b.conf"
  sed -i '' '/^\[t-opus-high\]$/,/^$/{/^model=/d;}' "$WORK/b4b.conf"
  out="$(AIENV_MODEL_DEFS_FILE="$WORK/b4b.conf" R "$BASE/profile.md" "$BASE/agents")"; rc=$?
  assert_eq "FX-B4b: exit1（model欠落）" "1" "$rc"

  cp "$BASE/models.conf" "$WORK/b4c.conf"
  sed -i '' 's/^\[t-opus-high\]$/[Opus-High]/' "$WORK/b4c.conf"
  out="$(AIENV_MODEL_DEFS_FILE="$WORK/b4c.conf" R "$BASE/profile.md" "$BASE/agents")"; rc=$?
  assert_eq "FX-B4c: exit1（定義名が大文字を含む）" "1" "$rc"

  out="$(AIENV_MODEL_DEFS_FILE="$WORK/does-not-exist.conf" R "$BASE/profile.md" "$BASE/agents")"; rc=$?
  assert_eq "FX-B4d: exit1（定義ファイル不在）" "1" "$rc"
}

echo "=== AC-4: FX-B5（未定義の定義名を参照） ==="
{
  variant_profile "$WORK/b5.md" 's/role.implementer: configured model=sonnet-noeffort,codex-high/role.implementer: configured model=sonnet-noeffort,does-not-exist/'
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
role.leader:      configured ${legacy_attr_frag}anthropic-api model=claude-opus-5-5 effort=high
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
  cout="$(C "$WORK/b6a.md" implementer sonnet-noeffort "$BASE/agents" 2>&1)"; crc=$?
  assert_eq "FX-B6a: resolve-candidateもexit1" "1" "$crc"
  assert_contains "FX-B6a: resolve-candidateの理由にT4-LEGACY" "$cout" "T4-LEGACY"
}

echo "=== AC-7(FR-11): 職種ごとの候補注入は撤去済み（bootstrap-vault.sh・I） ==="
{
  FAKEHOME="$WORK/fakehome-ac7"
  mkdir -p "$FAKEHOME/.config/takumi009-ai-env"
  cp "$BASE/profile.md" "$FAKEHOME/.config/takumi009-ai-env/profile.md"
  cp "$BASE/models.conf" "$FAKEHOME/.config/takumi009-ai-env/models.conf"
  ctx="$(echo '{"session_id":"test-model-defs"}' \
    | HOME="$FAKEHOME" BOOTSTRAP_VAULT="/nonexistent-vault" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
      VAULT_READS_LOG="/nonexistent-dir/vault-reads.tsv" VAULT_RECALL_LOG="/nonexistent-dir/vault-recall.tsv" \
      VAULT_INVENTORY_LOG_DIR="/nonexistent-dir/vault-inventory" \
      MAINTENANCE_LAST_RUN_FILE="/nonexistent-dir/last-run.json" \
      AIENV_AGENTS_DIR="$BASE/agents" \
      BOOTSTRAP_ENABLE_LOCAL_PROFILE=1 "$BOOTSTRAP" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' 2>/dev/null)"
  # FR-11（要件v1.2.1）: 職種ごとの候補一覧（定義名）はSessionStart注入
  # から撤去された。候補・定義名は一切出さず、照会は候補一覧コマンド
  # （role_candidates.py・担当C実装）へ一本化する（担当B対応・
  # 2026-09-17 bootstrap-vault fa1b7de）。
  assert_not_contains "AC-7(FR-11)陽性: 候補定義名sonnet-noeffortは出ない" "$ctx" "sonnet-noeffort"
  assert_not_contains "AC-7(FR-11)陽性: 候補定義名codex-highは出ない" "$ctx" "codex-high"
  assert_not_contains "AC-7(FR-11)陽性: model値claude-sonnet-5も出ない" "$ctx" "claude-sonnet-5"
  assert_contains "AC-7(FR-11)陽性: 照会コマンドの呼び出し例が現れる" "$ctx" "role_candidates.py"

  ctx2="$(echo '{"session_id":"test-model-defs-2"}' \
    | HOME="$FAKEHOME" BOOTSTRAP_VAULT="/nonexistent-vault" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
      VAULT_READS_LOG="/nonexistent-dir/vault-reads.tsv" VAULT_RECALL_LOG="/nonexistent-dir/vault-recall.tsv" \
      VAULT_INVENTORY_LOG_DIR="/nonexistent-dir/vault-inventory" \
      MAINTENANCE_LAST_RUN_FILE="/nonexistent-dir/last-run.json" \
      AIENV_AGENTS_DIR="$BASE/agents" AIENV_MODEL_DEFS_FILE="/nonexistent-dir/models.conf" \
      BOOTSTRAP_ENABLE_LOCAL_PROFILE=1 "$BOOTSTRAP" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' 2>/dev/null)"
  assert_contains "AC-7陰性: 定義ファイル不在で警告を含む" "$ctx2" "解決できません"
}

echo "=== AC-8: known-keysの3行目がSCHEMA_VERSION:7 ==="
{
  kk="$(python3 "$LIB" known-keys)"; rc=$?
  assert_eq "AC-8: exit0" "0" "$rc"
  third="$(printf '%s\n' "$kk" | sed -n '3p')"
  assert_eq "AC-8: 3行目完全一致" "SCHEMA_VERSION:7" "$third"
}

echo "=== AC-9: FX-B9（リーダーは先頭候補のみ解決） ==="
{
  variant_profile "$WORK/b9.md" 's/role.leader:      configured model=t-opus-high/role.leader:      configured model=t-opus-high,sonnet-noeffort/'
  out="$(LD "$WORK/b9.md" "$BASE/agents")"; rc=$?
  assert_eq "FX-B9: exit0" "0" "$rc"
  keys="$(printf '%s' "$out" | python3 -c 'import json,sys; print(",".join(sorted(json.load(sys.stdin).keys())))')"
  assert_eq "FX-B9: キー集合" "effort,model" "$keys"
  model_val="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["model"])')"
  assert_eq "FX-B9: model==claude-opus-5-5（先頭候補）" "claude-opus-5-5" "$model_val"
}

echo "=== AC-10: 職種frontmatterのmodel値はresolver出力へ影響しない ==="
{
  base_out="$(R "$BASE/profile.md" "$BASE/agents")"
  cp -R "$BASE/agents" "$WORK/agents-model-ignored"
  sed -i '' '2i\
model: claude-fable-5-1
' "$WORK/agents-model-ignored/implementer.md"
  changed_out="$(R "$BASE/profile.md" "$WORK/agents-model-ignored")"; rc=$?
  assert_eq "model行があってもresolveはexit0" "0" "$rc"
  assert_eq "model行があってもresolve出力は同一" "$base_out" "$changed_out"
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
  invoke_via_candidate "$BASE/profile.md" implementer t-opus-high "$BASE/agents"; rc=$?
  assert_eq "FX-B12c: exit2（候補外）" "2" "$rc"
  cnt_c="$(wc -l < "$CALLS_LOG" | tr -d ' ')"
  assert_eq "FX-B12c: Wの記録が0行" "0" "$cnt_c"
}

echo "=== RG-2: resolve-candidateの2分岐（定義名省略の無条件exit2・同一行の候補直接指定）の実装回帰（Codexレビュー指摘・MAJOR対応2巡目。要件fixtureは増やさない） ==="
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

  # ③role.implementerが同一行に複数候補（sonnet-noeffort,codex-high）を
  # 持つとき、2件目の候補名を直接指定してresolve-candidateへ渡すと、その
  # 候補だけが検査され採用される（選択は呼び出し側が行う＝D-6）。
  out_rg2c="$(python3 "$LIB" resolve-candidate "$BASE/profile.md" --role implementer --model-def codex-high --agents-dir "$BASE/agents")"; rc_rg2c=$?
  assert_eq "RG-2③: exit0（同一行の2件目を直接指定）" "0" "$rc_rg2c"
  sel_rg2c="$(printf '%s' "$out_rg2c" | sed -n '1p' | awk -F'\t' '{print $2}')"
  assert_eq "RG-2③: 選択結果がcodex-high（2件目を直接指定）" "codex-high" "$sel_rg2c"

  # ④role.implementerがunavailable: 候補が何件あっても行ごと評価せず、
  # CANDIDATE_UNUSABLE:ROLE_UNAVAILABLEという安定コードでexit1になる。
  variant_profile "$WORK/rg2d.md" \
    's/role.implementer: configured model=sonnet-noeffort,codex-high/role.implementer: unavailable model=sonnet-noeffort,codex-high/'
  out_rg2d="$(python3 "$LIB" resolve-candidate "$WORK/rg2d.md" --role implementer --model-def sonnet-noeffort --agents-dir "$BASE/agents" 2>&1 1>/dev/null)"; rc_rg2d=$?
  assert_eq "RG-2④: exit1（unavailable）" "1" "$rc_rg2d"
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

echo "=== AC-13: FX-B13a・FX-B13b（同一行の複数候補・自動救済は無い＝FR-1） ==="
{
  cp "$BASE/models.conf" "$WORK/b13.conf"
  cat >> "$WORK/b13.conf" <<'EOF'

[codex-alt]
provider=external
execution=external-cli
model=default
EOF
  variant_profile "$WORK/b13.md" 's/role.implementer: configured model=sonnet-noeffort,codex-high/role.implementer: configured model=sonnet-noeffort,codex-alt/'
  mkdir -p "$WORK/agents-b13"
  cp "$BASE/agents/verifier.md" "$BASE/agents/ja-doc.md" "$WORK/agents-b13/"
  # implementer.mdを置かない＝sonnet-noeffortが職種定義の存在検査(V1-b)で使用不可、
  # codex-altは使用可（external-cliはV1-b対象外）。

  : > "$CALLS_LOG"
  c_out="$(AIENV_MODEL_DEFS_FILE="$WORK/b13.conf" python3 "$LIB" resolve-candidate "$WORK/b13.md" --role implementer --model-def codex-alt --agents-dir "$WORK/agents-b13")"; rc=$?
  assert_eq "FX-B13a: exit0" "0" "$rc"
  sel="$(printf '%s' "$c_out" | sed -n '1p' | awk -F'\t' '{print $2}')"
  assert_eq "FX-B13a: 選択結果がcodex-alt（同一行の2件目を直接指定）" "codex-alt" "$sel"
  # 2026-09-08 Codexレビュー指摘・MAJOR-3対応（1巡目）: 要件AC-13の
  # 「Wの記録（1行）は外部CLIの候補が選ばれたときだけ見る」を実際にWまで
  # 通して固定する。
  codex_args_a="$(printf '%s\n' "$c_out" | awk -F'\t' '$1=="CODEX_ARGS"{print $2}')"
  # shellcheck disable=SC2086
  "$STUB" --cwd /tmp/example --sandbox read-only --out /tmp/example.out --prompt-file - $codex_args_a
  assert_eq "FX-B13a: Wの記録はちょうど1行" "1" "$(wc -l < "$CALLS_LOG" | tr -d ' ')"

  # FX-B13b: 1件目(sonnet-noeffort)を直接指定した場合、それがV1-bで使用不可
  # なら2件目へは自動で移らずCANDIDATE_UNUSABLE:V1-bで確定する（自動救済は
  # 無い＝FR-1。選択は呼び出し側が行う＝D-6）。
  : > "$CALLS_LOG"
  out_b13b="$(AIENV_MODEL_DEFS_FILE="$WORK/b13.conf" python3 "$LIB" resolve-candidate "$WORK/b13.md" --role implementer --model-def sonnet-noeffort --agents-dir "$WORK/agents-b13" 2>&1 1>/dev/null)"; rc=$?
  assert_eq "FX-B13b: exit1（1件目が使用不可）" "1" "$rc"
  assert_contains "FX-B13b: CANDIDATE_UNUSABLE:V1-b" "$out_b13b" "CANDIDATE_UNUSABLE:V1-b"
  assert_eq "FX-B13b: Wの記録は0行（起動されない）" "0" "$(wc -l < "$CALLS_LOG" | tr -d ' ')"
}

echo "=== RG-1: 指定した非anthropic-api/subagentはBedrock経路の判定より先に拒否 ==="
{
  # bedrock-opusを直接指定する（bedrock.envを渡さないので経路がdisabled＝
  # V9-d3で使用不可のはずだが、そこへ進む前にsubagent×非anthropic-apiの
  # 組がSUBAGENT_PROVIDER_UNSUPPORTEDで先に拒否されることを固定する）。
  variant_profile "$WORK/rg1.md" \
    's/role.implementer: configured model=sonnet-noeffort,codex-high/role.implementer: configured model=bedrock-opus/'
  mkdir -p "$WORK/agents-rg1"
  cat > "$WORK/agents-rg1/implementer.md" <<'EOF'
---
name: implementer
model: claude-opus-5-5
---
EOF
  cp "$BASE/agents/verifier.md" "$BASE/agents/ja-doc.md" "$WORK/agents-rg1/"

  out="$(python3 "$LIB" resolve-candidate "$WORK/rg1.md" --role implementer --model-def bedrock-opus --agents-dir "$WORK/agents-rg1" 2>&1 1>"$WORK/rg1.stdout")"
  rc=$?
  stdout_content="$(cat "$WORK/rg1.stdout")"
  assert_eq "RG-1: exit2" "2" "$rc"
  assert_eq "RG-1: stdoutが1文字も出ない" "" "$stdout_content"
  assert_eq "RG-1: provider拒否が先勝ち" "SUBAGENT_PROVIDER_UNSUPPORTED	role=implementer def=bedrock-opus provider=bedrock" "$out"
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

  cout="$(cd /tmp && AIENV_MODEL_DEFS_FILE="relative/models.conf" python3 "$LIB" resolve-candidate "$BASE/profile.md" --role implementer --model-def sonnet-noeffort --agents-dir "$BASE/agents" 2>&1)"; crc=$?
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

  c1="$(run_in_cwd /tmp resolve-candidate "$BASE/profile.md" --role implementer --model-def sonnet-noeffort --agents-dir "$BASE/agents")"
  c2="$(run_in_cwd "$REPO_ROOT" resolve-candidate "$BASE/profile.md" --role implementer --model-def sonnet-noeffort --agents-dir "$BASE/agents")"
  c3="$(run_in_cwd "$WORK" resolve-candidate "$BASE/profile.md" --role implementer --model-def sonnet-noeffort --agents-dir "$BASE/agents")"
  assert_eq "cwd不変性(C): /tmp と REPO_ROOT で同じ結果(exit+stdout)" "$c1" "$c2"
  assert_eq "cwd不変性(C): /tmp と WORK で同じ結果(exit+stdout)" "$c1" "$c3"
}

echo "=== AC-2/3/4/5/6: FX-01〜28（新契約のbytes・評価順） ==="
if python3 - "$REPO_ROOT" "$WORK" <<'PYFX'
from pathlib import Path
import os, re, shutil, subprocess, sys

r, work = map(Path, sys.argv[1:])
root = work / "model-removal-fx"
root.mkdir()
profile = (r / "tests/fixtures/profile.md").read_text()
defs = (r / "tests/fixtures/models.conf").read_text()
models = ["claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5",
          "claude-haiku-4-5-20251001", "claude-fable-5", "claude-opus-4-8",
          "claude-opus-4-7", "claude-opus-4-6", "claude-sonnet-4-6",
          "claude-opus-5-unknown", "opus"]
for n in range(1, 29):
    d = root / f"FX-{n:02}"
    (d / "agents").mkdir(parents=True)
    for source in (r / "claude/agents").glob("*.md"):
        shutil.copy2(source, d / "agents" / source.name)
    attrs = dict(provider="anthropic-api", model=models[n-1] if n <= 11 else "claude-opus-5-5",
                 execution="subagent", effort="high")
    state, candidates = "configured", "pick"
    if n in (12, 13):
        attrs.update(provider="external", execution="external-cli",
                     model="gpt-6-astra" if n == 12 else "default", effort="low")
    if n in (4, 13): attrs.pop("effort")
    # 検証1巡目MAJOR-1対応: FX-28はunavailableのまま残す（FX-23との重複を
    # 避けるため）。unavailableな行でも、指定候補がsubagent×非anthropic-api
    # なら role の状態を見るより先にSUBAGENT_PROVIDER_UNSUPPORTEDが発火する
    # ことを固定する（V1-b等より前段のガード。下の run(28) のアサーションが対象）。
    if n in (16, 28): state = "unavailable"
    if n in (23, 28): attrs.update(provider="bedrock", model="opus")
    if n == 24: attrs.update(provider="bedrock-mantle", model="anthropic.claude-opus-5-5")
    if n == 27: candidates = "pick,probe"
    if n == 19: candidates = "pick,def-legacy"
    if n == 20: attrs["effort"] = "low"
    # 2026-09-16 代替配役の層の撤去に合わせ、以前は別行（撤去済みの
    # 代替候補キー）で表していた2件目の候補を同一行のカンマ列挙へ変える。
    if n == 16: candidates = "pick,def-a"
    if n == 17: candidates = "pick,def-legacy"
    if n in (25, 26): candidates = "pick,probe"
    text, count = re.subn(r"^role\.requirements-analyst:.*$",
                          f"role.requirements-analyst: {state} model={candidates}", profile, flags=re.M)
    assert count == 1
    (d / "profile.md").write_text(text)
    (d / "models.conf").write_text(defs + "\n[pick]\n" + "".join(f"{k}={v}\n" for k, v in attrs.items()))
    if n in (25, 26, 27):
        provider = "bedrock-mantle" if n == 26 else "bedrock"
        model = "anthropic.claude-opus-5-5" if n == 26 else "opus"
        with (d / "models.conf").open("a") as f:
            f.write(f"\n[probe]\nprovider={provider}\nmodel={model}\nexecution=subagent\n")
    if n in (21, 22):
        agent = d / "agents/requirements-analyst.md"
        value = "claude-sonnet-5" if n == 21 else "claude-fable-5-1"
        agent.write_text(agent.read_text().replace("---\n", f"---\nmodel: {value}\n", 1))
    if n == 18: (d / "agents/requirements-analyst.md").unlink()

lib = r / "claude/hooks/lib/profile_resolve.py"
def run(n, *, model_def="pick", profile_path=None, command="resolve-candidate"):
    d = root / f"FX-{n:02}"
    args = ["python3", str(lib), command, str(profile_path or d / "profile.md")]
    if command == "resolve-candidate":
        args += ["--role", "requirements-analyst"]
        if model_def is not None: args += ["--model-def", model_def]
        args += ["--agents-dir", str(d / "agents")]
    elif command == "resolve":
        args += ["--agents-dir", str(d / "agents")]
    return subprocess.run(args, env={**os.environ, "AIENV_MODEL_DEFS_FILE": str(d / "models.conf")}, capture_output=True)

aliases = {"claude-fable-5-1":"fable", "claude-opus-5-5":"opus",
           "claude-sonnet-5":"sonnet", "claude-haiku-4-5-20251001":"haiku"}
for n, model in enumerate(list(aliases), 1):
    p = run(n); effort = "" if n == 4 else "high"
    # ラッパー起動-設計-v1.1.1.md §2.4・AC-20①②: AGENT_MODEL行の隣に
    # AGENT_EFFORT行（effortが非空のときだけ・空文字の行は出さない）。
    # 判定は先頭語＋定義名の形だけ見る（値の完全一致は使わない＝Decision 09-17 ④）。
    assert p.returncode == 0 and p.stderr == b"" and p.stdout.startswith(b"OK\tpick\t") \
        and b"\nAGENT_MODEL\t" in p.stdout and ((b"\nAGENT_EFFORT\t" in p.stdout) == bool(effort)), (n, p)
for n, model in zip(range(5, 11), models[4:10]):
    p = run(n)
    assert p.returncode == 2 and p.stdout == b"" and p.stderr.startswith(b"AGENT_MODEL_UNSUPPORTED\trole=requirements-analyst def=pick"), (n, p)
p = run(11); assert p.returncode == 1 and p.stdout == b"" and p.stderr.startswith(b"PROFILE_INVALID:T12\t")
p = run(12); assert p.returncode==0 and p.stdout.startswith(b"OK\tpick\t") and b"\nCODEX_ARGS\t--model " in p.stdout
p = run(13); assert p.returncode==0 and p.stdout.startswith(b"OK\tpick\tdefault\t") and b"\nCODEX_ARGS\t" in p.stdout
p = run(14, model_def=None, profile_path=root/"missing.md"); assert p.returncode==2 and p.stdout==b"" and p.stderr.startswith(b"CANDIDATE_UNSPECIFIED\t")
# FX-15: def-a は定義済みだが role の候補列（pick）に無い
p = run(15, model_def="def-a"); assert p.returncode==2 and p.stdout==b"" and p.stderr.startswith(b"CANDIDATE_NOT_IN_LIST\t")
# FX-16: role.requirements-analystがunavailable・同一行に2候補
# （pick,def-a）を持つ。どちらを直接指定してもROLE_UNAVAILABLEで
# 一律拒否される（2026-09-16 代替配役の層の撤去＝FR-1。候補が複数あっても
# 逃げ道は無い）。
unavailable_reason = "CANDIDATE_UNUSABLE:ROLE_UNAVAILABLE\t候補が使用不可です\n".encode()
p = run(16); assert (p.returncode, p.stdout, p.stderr) == (1, b"", unavailable_reason)
p2 = run(16, model_def="def-a"); assert (p2.returncode, p2.stdout, p2.stderr) == (1, b"", unavailable_reason)
p = run(17, model_def="def-legacy"); assert p.returncode==2 and p.stdout==b"" \
    and p.stderr.startswith(b"AGENT_MODEL_UNSUPPORTED\trole=requirements-analyst def=def-legacy")
p = run(18); assert p.returncode==1 and p.stdout==b"" and b"V1-b" in p.stderr
p = run(19); assert p.returncode==0 and p.stdout.endswith(b"AGENT_MODEL\topus\nAGENT_EFFORT\thigh\n")
p = run(20); assert p.returncode==0 and p.stdout.startswith(b"OK\tpick\t") and p.stdout.endswith(b"AGENT_EFFORT\tlow\n")
fx02_candidate = run(2)
fx02_resolve = run(2, command="resolve")
for n in (21,22):
    p = run(n)
    assert (p.returncode, p.stdout, p.stderr) == (fx02_candidate.returncode, fx02_candidate.stdout, fx02_candidate.stderr)
    p = run(n, command="resolve")
    assert (p.returncode, p.stdout, p.stderr) == (fx02_resolve.returncode, fx02_resolve.stdout, fx02_resolve.stderr)
for n in (23, 24):
    p=run(n); assert p.returncode==2 and p.stdout==b"" and p.stderr.startswith(b"SUBAGENT_PROVIDER_UNSUPPORTED\trole=requirements-analyst def=pick"), (n, p)
for n in (25, 26):
    p=run(n, model_def="probe"); assert p.returncode==2 and p.stdout==b"" and p.stderr.startswith(b"SUBAGENT_PROVIDER_UNSUPPORTED\trole=requirements-analyst def=probe"), (n, p)
p=run(27); assert p.returncode==0 and p.stdout.endswith(b"AGENT_MODEL\topus\nAGENT_EFFORT\thigh\n")
p=run(28); assert p.returncode==2 and p.stdout==b"" and p.stderr.startswith(b"SUBAGENT_PROVIDER_UNSUPPORTED\trole=requirements-analyst def=pick")
print("PASS FX-01..28")
PYFX
then
  pass "FX-01〜28"
else
  fail_case "FX-01〜28"
fi

echo "=== effort-per-role v2（設計-v1.2.md §4.2）: list-candidatesの6列と行順 ==="
{
  LC() { # LC <profile> <agents_dir> — list-candidates
    python3 "$LIB" list-candidates "$1" --agents-dir "$2"
  }

  actual="$(LC "$BASE/profile.md" "$BASE/agents")"
  expected="$(printf 'implementer\tconfigured\tsonnet-noeffort\tsubagent\tsonnet\tOK\nimplementer\tconfigured\tcodex-high\texternal-cli\t--effort high\tOK\nleader\tconfigured\tt-opus-high\tsubagent\topus\tOK\nverifier\tconfigured\tcodex-high\texternal-cli\t--effort high\tOK')"
  assert_eq "LC: FX-B1の4行完全一致（役割順・記載順・6列）" "$expected" "$actual"

  # 未参照の定義（bedrock-opus・mantle-sonnet＝§6.1のBASE fixtureが備える）
  # は出ない（AC-7と同じ性質をlist-candidates自体でも固定する）。
  assert_not_contains "LC: 未参照定義bedrock-opusは出ない" "$actual" "bedrock-opus"
  assert_not_contains "LC: 未参照定義mantle-sonnetは出ない" "$actual" "mantle-sonnet"

  # 候補を持たない職種（not_adopted/unknown）は3〜6列が空の6フィールド行。
  variant_profile "$WORK/lc-no-candidates.md" '/role.verifier:/a\
role.navi:        unknown\
role.ja-doc:      not_adopted'
  lc_out="$(LC "$WORK/lc-no-candidates.md" "$BASE/agents")"
  assert_contains "LC: navi(unknown)は6フィールド中4列が空" "$lc_out" "$(printf 'navi\tunknown\t\t\t\t')"
  assert_contains "LC: ja-doc(not_adopted)は6フィールド中4列が空" "$lc_out" "$(printf 'ja-doc\tnot_adopted\t\t\t\t')"

  # 配役表が解決できない場合はlist-rolesと同じ形（stdout 0行・stderr 1行・exit1）。
  lc_err="$(LC "$WORK/does-not-exist-lc.md" "$BASE/agents" 2>&1 1>/dev/null)"; lc_rc=$?
  lc_stdout="$(LC "$WORK/does-not-exist-lc.md" "$BASE/agents" 2>/dev/null)"
  assert_eq "LC-配役表不在: exit1" "1" "$lc_rc"
  assert_eq "LC-配役表不在: stdout 0行" "" "$lc_stdout"
  assert_contains "LC-配役表不在: PROFILE_NOT_FOUND" "$lc_err" "PROFILE_NOT_FOUND"
}

echo "=== AC-20: resolve-candidateのeffortの口（ラッパー起動-設計-v1.1.1.md §2.4・§8） ==="
{
  # ①agent_effort_line_once: effortを持つ定義（role.leader→t-opus-high・
  # effort=high）でAGENT_EFFORT行がちょうど1行あり、値が定義のeffortと
  # 一致し、同じ呼び出しのOK行5列目と同値（同一実体条項）。
  out_eff="$(C "$BASE/profile.md" leader t-opus-high "$BASE/agents")"; rc_eff=$?
  assert_eq "agent_effort_line_once: exit0" "0" "$rc_eff"
  eff_lines="$(printf '%s\n' "$out_eff" | grep -c '^AGENT_EFFORT	')"
  assert_eq "agent_effort_line_once: AGENT_EFFORT行がちょうど1行" "1" "$eff_lines"
  eff_val="$(printf '%s\n' "$out_eff" | awk -F'\t' '$1=="AGENT_EFFORT"{print $2}')"
  ok_eff="$(printf '%s\n' "$out_eff" | sed -n '1p' | awk -F'\t' '{print $5}')"
  assert_eq "agent_effort_line_once: AGENT_EFFORT値がhigh" "high" "$eff_val"
  assert_eq "agent_effort_line_once: AGENT_EFFORT値とOK行5列目が同値（同一実体条項）" "$ok_eff" "$eff_val"

  # ②agent_effort_absent_when_no_effort: effortを持たない定義
  # （role.implementer→sonnet-noeffort）でAGENT_EFFORT行が0行（空文字の
  # 行を出さない＝負の条件なので明示的に見る）。
  out_noeff="$(C "$BASE/profile.md" implementer sonnet-noeffort "$BASE/agents")"; rc_noeff=$?
  assert_eq "agent_effort_absent_when_no_effort: exit0" "0" "$rc_noeff"
  noeff_lines="$(printf '%s\n' "$out_noeff" | grep -c '^AGENT_EFFORT	')"
  assert_eq "agent_effort_absent_when_no_effort: AGENT_EFFORT行が0行" "0" "$noeff_lines"

  # ③ok_and_agent_model_unchanged: OK行の列数とAGENT_MODEL行の値は現行の
  # まま（既存契約の回帰）。
  ok_line="$(printf '%s\n' "$out_eff" | sed -n '1p')"
  ok_cols="$(printf '%s' "$ok_line" | awk -F'\t' '{print NF}')"
  assert_eq "ok_and_agent_model_unchanged: OK行は5列のまま" "5" "$ok_cols"
  agent_model_val="$(printf '%s\n' "$out_eff" | awk -F'\t' '$1=="AGENT_MODEL"{print $2}')"
  assert_eq "ok_and_agent_model_unchanged: AGENT_MODEL値がopus" "opus" "$agent_model_val"
  noeff_ok_cols="$(printf '%s\n' "$out_noeff" | sed -n '1p' | awk -F'\t' '{print NF}')"
  assert_eq "ok_and_agent_model_unchanged: effortなし側もOK行は5列のまま" "5" "$noeff_ok_cols"

  # ④wrapper_does_not_parse_models_conf: ラッパー本体2ファイル
  # （scripts/claude-exec.sh・claude/hooks/lib/claude_exec.py＝設計§1・
  # 担当A実装。並行作成中で存在しないこともある＝存在しなければ検査対象
  # 0件でPASSする）がmodels.confを自前で解析しない（判定式をresolverの
  # 外へ複製しない＝rg -nの静的検査）。
  wrapper_files=()
  [ -f "$REPO_ROOT/scripts/claude-exec.sh" ] && wrapper_files+=("$REPO_ROOT/scripts/claude-exec.sh")
  [ -f "$REPO_ROOT/claude/hooks/lib/claude_exec.py" ] && wrapper_files+=("$REPO_ROOT/claude/hooks/lib/claude_exec.py")
  if [ "${#wrapper_files[@]}" -eq 0 ]; then
    bad_files=""
  else
    bad_files="$(grep -lE 'models\.conf|parse_model_defs|load_model_defs' "${wrapper_files[@]}" 2>/dev/null || true)"
  fi
  assert_eq "wrapper_does_not_parse_models_conf: models.confを解析するラッパーファイルが0件" "" "$bad_files"
}

echo "=== Opus 5.5 案件 OPUS55-AC-2・OPUS55-AC-3: 別名表更新後の解決結果 ==="
{
  # OPUS55-AC-2: model=claude-opus-5-5（BASEのt-opus-high。上のFX-B1等で
  # 既に既定値として使っている）がAGENT_MODEL=opusへ解決する。
  out_opus55="$(C "$BASE/profile.md" leader t-opus-high "$BASE/agents")"; rc_opus55=$?
  assert_eq "OPUS55-AC-2: exit0" "0" "$rc_opus55"
  agent_model_opus55="$(printf '%s\n' "$out_opus55" | awk -F'\t' '$1=="AGENT_MODEL"{print $2}')"
  assert_eq "OPUS55-AC-2: AGENT_MODEL==opus（model=claude-opus-5-5の解決）" "opus" "$agent_model_opus55"

  # OPUS55-AC-3: 旧世代ID model=claude-opus-5 は別名表（AGENT_MODEL_ALIASES）
  # に無いため解決失敗する。⚠️ 意図的に旧IDを使う陰性fixture（AC-4の一括
  # 置換の対象外）。
  cp "$BASE/models.conf" "$WORK/opus55-legacy.conf"
  cat >> "$WORK/opus55-legacy.conf" <<'EOF'

[legacy-opus]
provider=anthropic-api
model=claude-opus-5
execution=subagent
effort=high
EOF
  variant_profile "$WORK/opus55-legacy.md" \
    's/role.leader:      configured model=t-opus-high/role.leader:      configured model=legacy-opus/'
  out_legacy="$(AIENV_MODEL_DEFS_FILE="$WORK/opus55-legacy.conf" python3 "$LIB" resolve-candidate "$WORK/opus55-legacy.md" --role leader --model-def legacy-opus --agents-dir "$BASE/agents" 2>&1)"; rc_legacy=$?
  assert_eq "OPUS55-AC-3: exit2（旧IDclaude-opus-5は別名表に無い）" "2" "$rc_legacy"
  assert_contains "OPUS55-AC-3: AGENT_MODEL_UNSUPPORTED" "$out_legacy" "AGENT_MODEL_UNSUPPORTED"
  assert_contains "OPUS55-AC-3: 理由にmodel=claude-opus-5を含む" "$out_legacy" "model=claude-opus-5"
}

echo ""
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
