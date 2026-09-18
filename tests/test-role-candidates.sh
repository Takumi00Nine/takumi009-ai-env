#!/usr/bin/env bash
# tests/test-role-candidates.sh — claude/hooks/lib/role_candidates.py の
# 受入条件テスト（設計-v1.2.md §4「D-3 候補一覧コマンド」・
# 要件v1.2.1 §3.3 FR-14〜24・AC-6・AC-7・AC-8）。
#
# fixture一覧:
#   BASE   … role.leader(subagent/OK)・role.implementer(subagent/OK と
#            external-cli/OKの2候補)・role.verifier(external-cli/OKのみ)・
#            role.researcher(unavailable)・role.navi(unknown)・
#            role.ja-doc(not_adopted)・role.system-designer(subagentだが
#            provider=bedrock＝resolverが拒否する候補＝AC-8の「resolver
#            fixture」を兼ねる）。models.confに未参照の定義を1件含む
#            （AC-7）。
#   欠損キャッシュ … AIENV_USAGE_CACHE_DIRが空ディレクトリ（h5/d7が常に`-`）。
#   健全キャッシュ … claude-subscription/codex-subscriptionとも両窓とも
#            残率>0（resolver判定だけが効くことを確認する土台）。
#   枠0キャッシュ … claude-subscriptionのfive_hourだけ残率0（AC-8「枠
#            fixture」）。
#
# 正本: ~/Claude/effort-per-role/docs/design-v1.2.md §4
#       ~/Claude/effort-per-role/docs/requirements-v1.2.1.md §3.3・§4
#
# 実行方法: bash tests/test-role-candidates.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
RC="$REPO_ROOT/claude/hooks/lib/role_candidates.py"

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
# BASE fixture
# ============================================================
BASE="$WORK/base"
mkdir -p "$BASE/agents"

cat > "$BASE/profile.md" <<'EOF'
---
schema_version: 7
profile_slug: fixture
team_mode:            configured value=full
no_read_paths:        unavailable
machine_role:         configured value=main
role.leader:          configured model=opus-high
role.implementer:     configured model=sonnet-noeffort,codex-high
role.verifier:        configured model=codex-high
role.researcher:      unavailable model=sonnet-noeffort
role.navi:            unknown
role.ja-doc:          not_adopted
role.system-designer: configured model=bedrock-opus
---
EOF

cat > "$BASE/models.conf" <<'EOF'
[opus-high]
provider=anthropic-api
model=claude-opus-5
effort=high

[sonnet-noeffort]
provider=anthropic-api
model=claude-sonnet-5

[codex-high]
provider=external
execution=external-cli
model=default
effort=high

[bedrock-opus]
provider=bedrock
model=opus

# AC-7: role.*のどの候補列からも参照されない定義（構造的に出ないことの確認用）。
[unused-def]
provider=anthropic-api
model=claude-haiku-4-5-20251001
EOF

cat > "$BASE/agents/implementer.md" <<'EOF'
---
name: implementer
---
EOF

export AIENV_MODEL_DEFS_FILE="$BASE/models.conf"

# usage_snapshot.py --json 用のキャッシュを組み立てる。
# write_cache <dir> <claude_h5_used> <claude_d7_used> <codex_h5_used> <codex_d7_used>
write_cache() {
  local dir="$1" c5="$2" c7="$3" k5="$4" k7="$5"
  mkdir -p "$dir"
  local now; now="$(date +%s)"
  python3 -c "
import json, sys
now = int(sys.argv[1])
c5, c7, k5, k7 = (float(x) for x in sys.argv[2:6])
claude = {
    'schema_version': 1, 'service': 'claude', 'fetched_at': now - 60, 'updated_at': now - 60,
    'five_hour': {'used_percent': c5, 'resets_at_epoch': now + 1000},
    'seven_day': {'used_percent': c7, 'resets_at_epoch': now + 90000},
    'last_error': None,
}
codex = {
    'schema_version': 1, 'service': 'codex', 'fetched_at': now - 60, 'updated_at': now - 60,
    'five_hour': {'used_percent': k5, 'resets_at_epoch': now + 1000},
    'seven_day': {'used_percent': k7, 'resets_at_epoch': now + 90000},
    'last_error': None,
}
open(sys.argv[6] + '/claude-cache.json', 'w').write(json.dumps(claude))
open(sys.argv[6] + '/codex-cache.json', 'w').write(json.dumps(codex))
" "$now" "$c5" "$c7" "$k5" "$k7" "$dir"
}

MISSING_CACHE="$WORK/cache-missing"   # 欠損fixture（ディレクトリごと無い）
HEALTHY_CACHE="$WORK/cache-healthy"   # 両pool・両窓とも残率>0
ZERO_H5_CACHE="$WORK/cache-zero-h5"   # claude-subscriptionのfive_hourだけ残率0
write_cache "$HEALTHY_CACHE" 20 30 15 25
write_cache "$ZERO_H5_CACHE" 100 30 15 25

RCALL() { # RCALL <cache_dir> [追加引数...]
  local cache="$1"; shift
  AIENV_USAGE_CACHE_DIR="$cache" python3 "$RC" --profile "$BASE/profile.md" --agents-dir "$BASE/agents" "$@"
}

echo "=== AC-6: 候補一覧の形と解決不能時の出口 ==="
{
  out="$(RCALL "$MISSING_CACHE")"; rc=$?
  assert_eq "AC-6: exit0" "0" "$rc"
  header="$(printf '%s\n' "$out" | sed -n '1p')"
  assert_eq "AC-6: 1行目のヘッダ" "$(printf 'role\tdef\troute\tpass\tok\th5\td7')" "$header"

  bad_lines="$(printf '%s\n' "$out" | tail -n +2 | awk -F'\t' 'NF!=7 && NF!=2{c++} END{print c+0}')"
  assert_eq "AC-6: 本体の全行がフィールド数7または2" "0" "$bad_lines"

  body_count="$(printf '%s\n' "$out" | tail -n +2 | grep -c .)"
  assert_eq "AC-6: 本体は少なくとも1行以上ある（fixtureの健全性確認）" "1" "$([ "$body_count" -ge 1 ] && echo 1 || echo 0)"

  # 配役表が解決できないfixture（実体不在）。
  unresolved_stdout="$(RCALL "$MISSING_CACHE" --profile "$WORK/does-not-exist.md" 2>/dev/null)"
  unresolved_stderr="$(RCALL "$MISSING_CACHE" --profile "$WORK/does-not-exist.md" 2>&1 1>/dev/null)"
  unresolved_rc=0
  RCALL "$MISSING_CACHE" --profile "$WORK/does-not-exist.md" >/dev/null 2>&1 || unresolved_rc=$?
  assert_eq "AC-6(UNRESOLVED): stdoutはヘッダ1行だけ" "$(printf 'role\tdef\troute\tpass\tok\th5\td7')" "$unresolved_stdout"
  first_stderr_line="$(printf '%s\n' "$unresolved_stderr" | sed -n '1p')"
  case "$first_stderr_line" in
    UNRESOLVED*) pass "AC-6(UNRESOLVED): stderrの1行目がUNRESOLVEDで始まる" ;;
    *) fail_case "AC-6(UNRESOLVED): stderrの1行目がUNRESOLVEDで始まる (実際=$first_stderr_line)" ;;
  esac
  assert_eq "AC-6(UNRESOLVED): exit0（提示専用・FR-23）" "0" "$unresolved_rc"
}

echo "=== AC-7: 未参照の定義を出さない ==="
{
  out="$(RCALL "$MISSING_CACHE")"
  assert_not_contains "AC-7: 未参照定義unused-defが出ない" "$out" "unused-def"
}

echo "=== AC-8: okが2条件だけで決まる（枠 fixture／resolver fixture／欠損 fixture） ==="
{
  # --- 枠 fixture: claude-subscriptionのfive_hourを0にする ---
  zero_out="$(RCALL "$ZERO_H5_CACHE")"
  leader_row="$(printf '%s\n' "$zero_out" | awk -F'\t' '$1=="leader"{print}')"
  impl_subagent_row="$(printf '%s\n' "$zero_out" | awk -F'\t' '$1=="implementer" && $3=="subagent"{print}')"
  impl_cli_row="$(printf '%s\n' "$zero_out" | awk -F'\t' '$1=="implementer" && $3=="external-cli"{print}')"
  verifier_row="$(printf '%s\n' "$zero_out" | awk -F'\t' '$1=="verifier"{print}')"

  assert_eq "AC-8(枠): leader(subagent枠)はh5=0でno" "no" "$(printf '%s' "$leader_row" | awk -F'\t' '{print $5}')"
  assert_eq "AC-8(枠): implementer/sonnet-noeffort(subagent枠)はh5=0でno" "no" "$(printf '%s' "$impl_subagent_row" | awk -F'\t' '{print $5}')"
  assert_eq "AC-8(枠): implementer/codex-high(external-cli枠)は無関係でok" "ok" "$(printf '%s' "$impl_cli_row" | awk -F'\t' '{print $5}')"
  assert_eq "AC-8(枠): verifier(external-cli枠)は無関係でok" "ok" "$(printf '%s' "$verifier_row" | awk -F'\t' '{print $5}')"
  assert_eq "AC-8(枠): leaderのh5列が0" "0" "$(printf '%s' "$leader_row" | awk -F'\t' '{print $6}')"

  # --- resolver fixture: 健全キャッシュ下でBedrock候補(system-designer)だけがno ---
  healthy_out="$(RCALL "$HEALTHY_CACHE")"
  sd_row="$(printf '%s\n' "$healthy_out" | awk -F'\t' '$1=="system-designer"{print}')"
  assert_eq "AC-8(resolver): system-designer(Bedrock経路)はno" "no" "$(printf '%s' "$sd_row" | awk -F'\t' '{print $5}')"
  assert_eq "AC-8(resolver): system-designerのpass列は-（OKでない）" "-" "$(printf '%s' "$sd_row" | awk -F'\t' '{print $4}')"

  # ⚠️ role.researcherはunavailable（CANDIDATE_UNUSABLE:ROLE_UNAVAILABLE）
  # なのでこの土台でも正当にnoになる。「resolverが拒否する」という性質は
  # system-designer（Bedrock経路）と同じだが、AC-8の「resolver fixture」が
  # 固定したいのは「OKな行はhealthyキャッシュでokのまま・拒否された行だけ
  # noになる」ことなので、OK系の職種（leader/implementer/verifier）だけを
  # 数える。
  ok_role_rows="$(printf '%s\n' "$healthy_out" | tail -n +2 | awk -F'\t' 'NF==7 && ($1=="leader" || $1=="implementer" || $1=="verifier")')"
  no_among_ok_roles="$(printf '%s\n' "$ok_role_rows" | grep -c $'\tno\t')"
  assert_eq "AC-8(resolver): OK系職種(leader/implementer/verifier)の行にnoは0件" "0" "$no_among_ok_roles"
  ok_among_ok_roles="$(printf '%s\n' "$ok_role_rows" | grep -c $'\tok\t')"
  ok_role_rows_count="$(printf '%s\n' "$ok_role_rows" | grep -c .)"
  assert_eq "AC-8(resolver): OK系職種の行は全部ok扱い" "$ok_role_rows_count" "$ok_among_ok_roles"

  # --- 欠損 fixture: キャッシュディレクトリが無い ---
  missing_out="$(RCALL "$MISSING_CACHE")"
  m_leader_row="$(printf '%s\n' "$missing_out" | awk -F'\t' '$1=="leader"{print}')"
  m_sd_row="$(printf '%s\n' "$missing_out" | awk -F'\t' '$1=="system-designer"{print}')"
  assert_eq "AC-8(欠損): leaderのh5は-（取得不能）" "-" "$(printf '%s' "$m_leader_row" | awk -F'\t' '{print $6}')"
  assert_eq "AC-8(欠損): leaderのd7は-（取得不能）" "-" "$(printf '%s' "$m_leader_row" | awk -F'\t' '{print $7}')"
  assert_eq "AC-8(欠損): leaderは枠を理由にnoにならずok" "ok" "$(printf '%s' "$m_leader_row" | awk -F'\t' '{print $5}')"
  assert_eq "AC-8(欠損): system-designerはresolverの拒否のままno" "no" "$(printf '%s' "$m_sd_row" | awk -F'\t' '{print $5}')"
}

echo "=== MINOR-5(FR-22): --roleの行絞り ==="
{
  # 該当ありのケース: ヘッダ＋該当行だけ。
  filtered_out="$(RCALL "$MISSING_CACHE" --role leader)"
  filtered_body_count="$(printf '%s\n' "$filtered_out" | tail -n +2 | grep -c .)"
  assert_eq "MINOR-5: --role leaderは本体1行だけ" "1" "$filtered_body_count"
  filtered_role="$(printf '%s\n' "$filtered_out" | tail -n +2 | awk -F'\t' '{print $1}')"
  assert_eq "MINOR-5: --role leaderの本体行はleaderのみ" "leader" "$filtered_role"
  filtered_header="$(printf '%s\n' "$filtered_out" | sed -n '1p')"
  assert_eq "MINOR-5: --role leaderでもヘッダは出る" "$(printf 'role\tdef\troute\tpass\tok\th5\td7')" "$filtered_header"

  # 該当なしのケース: ヘッダのみ・exit0。
  no_match_out="$(RCALL "$MISSING_CACHE" --role no-such-role)"; no_match_rc=$?
  assert_eq "MINOR-5: --role no-such-roleはexit0" "0" "$no_match_rc"
  assert_eq "MINOR-5: --role no-such-roleはヘッダのみ" "$(printf 'role\tdef\troute\tpass\tok\th5\td7')" "$no_match_out"
}

echo "=== MINOR-6(FR-21): 候補なし職種の2フィールド写像／unavailableは7列でok=no ==="
{
  base_out="$(RCALL "$MISSING_CACHE")"
  navi_line="$(printf '%s\n' "$base_out" | awk -F'\t' '$1=="navi"{print}')"
  ja_doc_line="$(printf '%s\n' "$base_out" | awk -F'\t' '$1=="ja-doc"{print}')"
  researcher_line="$(printf '%s\n' "$base_out" | awk -F'\t' '$1=="researcher"{print}')"

  assert_eq "MINOR-6: naviは<role>TAB unknownの2フィールド" "$(printf 'navi\tunknown')" "$navi_line"
  assert_eq "MINOR-6: naviのフィールド数は2" "2" "$(printf '%s' "$navi_line" | awk -F'\t' '{print NF}')"
  assert_eq "MINOR-6: ja-docは<role>TAB not_adoptedの2フィールド" "$(printf 'ja-doc\tnot_adopted')" "$ja_doc_line"
  assert_eq "MINOR-6: ja-docのフィールド数は2" "2" "$(printf '%s' "$ja_doc_line" | awk -F'\t' '{print NF}')"

  assert_eq "MINOR-6: researcher(unavailable)は7フィールド" "7" "$(printf '%s' "$researcher_line" | awk -F'\t' '{print NF}')"
  assert_eq "MINOR-6: researcher(unavailable)はok=no" "no" "$(printf '%s' "$researcher_line" | awk -F'\t' '{print $5}')"
}

echo "=== MINOR-8(FR-23): list-candidatesの壊れた行を捨てたらstderrへUNRESOLVEDを1行 ==="
{
  # role_candidates.pyのPROFILE_RESOLVE_PYは自身と同じディレクトリを見る
  # ため（__file__基準）、実物のコピー＋壊れた行を返す最小スタブを同じ
  # 一時ディレクトリへ置いて狙い撃ちする（test-update-sub.shのFM-G4と
  # 同じresolverスタブ方式）。
  STUBDIR="$WORK/stublib"
  mkdir -p "$STUBDIR"
  cp "$RC" "$STUBDIR/role_candidates.py"
  cat > "$STUBDIR/profile_resolve.py" <<'PYSTUB'
import sys
cmd = sys.argv[1] if len(sys.argv) > 1 else ""
if cmd == "list-candidates":
    print("leader\tconfigured\topus-high\tsubagent\topus\tOK")
    print("broken\tconfigured\tdef")  # MINOR-8: 6列未満の壊れた行
    sys.exit(0)
sys.exit(1)
PYSTUB

  stub_out="$(python3 "$STUBDIR/role_candidates.py" --profile "$BASE/profile.md" --agents-dir "$BASE/agents" 2>/dev/null)"
  stub_err="$(python3 "$STUBDIR/role_candidates.py" --profile "$BASE/profile.md" --agents-dir "$BASE/agents" 2>&1 1>/dev/null)"
  stub_rc=0
  python3 "$STUBDIR/role_candidates.py" --profile "$BASE/profile.md" --agents-dir "$BASE/agents" >/dev/null 2>&1 || stub_rc=$?

  assert_eq "MINOR-8: 壊れた行があってもexit0" "0" "$stub_rc"
  assert_contains "MINOR-8: 正常行(leader)はstdoutにそのまま残る" "$stub_out" "leader"
  assert_not_contains "MINOR-8: 壊れた行(broken)はstdoutに出ない" "$stub_out" "broken"
  assert_eq "MINOR-8: stderrにUNRESOLVED TAB INTERNAL_ERRORを1行" "$(printf 'UNRESOLVED\tINTERNAL_ERROR')" "$stub_err"
}

echo ""
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
