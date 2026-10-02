#!/usr/bin/env bash
# 統合試験（Core＝全部入りを前提に 2 機能以上の部品を同時に動かす。AC-5 の取り外し試験の対象外）。
# Dock の Project 供給（dock/executor/cmux-next-model.sh）の B 行が、AI Brain のヘルス判定機
# （台帳の鍵 ai-brain.health-judge）を写すことと、AI Brain の読込（注入のヘルス節）と同じ段階を出すことを見る。
# 移し替えた節（由来＝分割元。v1.1 設計 v1.2 §4.4・§5.2・実装計画 §8）:
#   tests/test-cmux-next-model.sh の B 行の節（frame_b_row_ok〜判定機の入力が壊れていても B 行は出る。
#   判定機なしで B 行を省く節は Dock に残す）、tests/test-bootstrap-vault.sh の旧 6（注入の stage＝B 行）。
#
# 実行方法: bash tests/test-integration.sh
#
# 契約: 新パス＝実装計画 §2（dock/executor/cmux-next-model.sh・ai-brain/executor/bootstrap-vault.sh）。
#   B 行の判定機は Dock 供給が台帳の鍵で引く（設計 §5.2 方式③）＝本ファイルは全部入りの台帳のまま動かす。
#   読込（AI Brain の寄与）は引数なしで hook 形の additionalContext を返す（設計 §5.5）。上書き口は現行名のまま。
# 実 Vault・実ログには触れない（既定が実ファイルの env は全て fixture／存在しないパスへ向ける＝設計 §10.1）。

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT_DIR="$TESTS_DIR"
TARGET="$REPO_ROOT/dock/executor/cmux-next-model.sh"
SCRIPT="$REPO_ROOT/ai-brain/executor/bootstrap-vault.sh"
unset VAULT_AGENT_LOG_STALE_DAYS

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/aienv-integration-test.XXXXXX")" || { echo "FATAL: mktemp -d に失敗しました" >&2; exit 1; }
trap 'chmod -R u+rwx "$WORKDIR" 2>/dev/null; rm -rf "$WORKDIR"' EXIT
mkdir -p "$WORKDIR/cmux-stub"
printf '#!/bin/bash\nexit 9\n' > "$WORKDIR/cmux-stub/cmux"; chmod +x "$WORKDIR/cmux-stub/cmux"
export PATH="$WORKDIR/cmux-stub:$PATH" HOME="$WORKDIR/home"
mkdir -p "$HOME"

# shellcheck source=./lib-cmux-fixtures.sh
. "$SCRIPT_DIR/lib-cmux-fixtures.sh"

VAULT="$WORKDIR/vault"
reset_vault() { rm -rf "$VAULT"; mkdir -p "$VAULT/Projects"; }

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail_case "$1 (expected=[$2] actual=[$3])"; fi; }
assert_true() { if [ "$2" = "1" ]; then pass "$1"; else fail_case "$1"; fi; }

make_full_vault() {
  local vault="$1" f
  mkdir -p "$vault/Knowledge" "$vault/Preferences" "$vault/Personal"
  for f in "Preferences/absolute-rules.md" "Preferences/core-conduct.md" "Preferences/core-workflow.md" \
           "Personal/profile-personal.md" "Preferences/vault-operation.md"; do
    echo "dummy" > "$vault/$f"
  done
}

# run_bootstrap <vault> <reads> <recall> <inv_dir> <last_run> <plist> <obs> <session_json> — AI Brain の読込を
# 引数なし（hook 形）で起動し additionalContext を返す（旧 test-bootstrap-vault.sh の同名ヘルパと同じ入力）。
run_bootstrap() {
  printf '%s\n' "$8" \
    | BOOTSTRAP_VAULT="$1" BOOTSTRAP_TEAMS_DIR="/nonexistent-teams-dir" \
      VAULT_READS_LOG="$2" VAULT_RECALL_LOG="$3" VAULT_INVENTORY_LOG_DIR="$4" \
      MAINTENANCE_LAST_RUN_FILE="$5" MAINTENANCE_PLIST_FILE="$6" HEALTH_OBSERVATION_FILE="$7" \
      HEALTH_JUDGE_NOW="${HEALTH_JUDGE_NOW:-}" BOOTSTRAP_ENABLE_LOCAL_PROFILE=0 bash "$SCRIPT" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null
  return 0
}

# Dock 供給の fixture 実行（旧 test-cmux-next-model.sh の run_frame_fixture・b_rows を写した）。
FX_ROOT="$SCRIPT_DIR/fixtures/health"
run_frame_fixture() {
  local d="$FX_ROOT/$1" plist="/nonexistent-dir/com.takumi009.maintenance.plist"
  [ -f "$d/plist" ] && plist="$d/plist"
  CMUX_NEXT_VAULT="$VAULT" CMUX_NEXT_MAINT_STATE="$d/last-run.json" \
    CMUX_NEXT_INVENTORY_LATEST="$d/latest.json" CMUX_NEXT_HEALTH_OBSERVATION="$d/observation.json" \
    CMUX_NEXT_RECALL_LOG="$d/vault-recall.tsv" CMUX_NEXT_MAINT_PLIST="$plist" \
    HEALTH_JUDGE_NOW="$(cat "$d/now")" \
    bash "$TARGET" --frame > "$WORKDIR/frame_stdout" 2>"$WORKDIR/frame_stderr"
  printf '%s' "$?" > "$WORKDIR/frame_rc"
}
b_rows() { awk -F '\t' '$1=="B"' "$WORKDIR/frame_stdout"; }

# 旧 test-bootstrap-vault.sh 6 の土台（ヘルス fixture を読込と Dock 供給の両方へ向ける）。
HEALTH_FX_ROOT="$TESTS_DIR/fixtures/health"
CMUX_NEXT_MODEL="$TARGET"
HEALTH_SHARED_VAULT="$(mktemp -d)"
make_full_vault "$HEALTH_SHARED_VAULT"
HEALTH_EMPTY_PROJECTS="$(mktemp -d)"
mkdir -p "$HEALTH_EMPTY_PROJECTS/Projects"

# fixture_vault_dir <fixture dir> — fixture の vault/ があればそれ、observation.json が「ルート不在」なら存在しないパス、
# それ以外は共有の完全な Vault（fixtures/health/README.md の規則）。
fixture_vault_dir() {
  local d="$1"
  if [ -d "$d/vault" ]; then
    printf '%s' "$d/vault"
  elif [ "$(jq -r '.load.vault_root_readable' "$d/observation.json" 2>/dev/null)" = "false" ]; then
    printf '%s' "/nonexistent-dir/vault"
  else
    printf '%s' "$HEALTH_SHARED_VAULT"
  fi
}

# run_bootstrap_fixture <fixture名> [session_json] — fixture の入力を全部向けて bootstrap を回し additionalContext を返す。
# 観測記録＝fixture の observation-prev.json を一時ファイルへ写して HEALTH_OBSERVATION_FILE に渡す（bootstrap が上書きする）。
# 書かれた観測記録は $BOOT_OBS_FILE に残す（呼び出し側が検査してから消す）。HEALTH_JUDGE_NOW＝fixture の now。
HEALTH_FIXTURE_SESSION_JSON='{"session_id":"sess-cur-0002","source":"startup"}'
HEALTH_OBS_WORK="$(mktemp -d)"
BOOT_OBS_FILE="$HEALTH_OBS_WORK/session-observation.json"
run_bootstrap_fixture() {
  local fx="$1" session_json="${2:-$HEALTH_FIXTURE_SESSION_JSON}"
  local d="$HEALTH_FX_ROOT/$fx" plist="/nonexistent-dir/com.takumi009.maintenance.plist"
  [ -f "$d/plist" ] && plist="$d/plist"
  rm -f "$BOOT_OBS_FILE"
  [ -f "$d/observation-prev.json" ] && cp "$d/observation-prev.json" "$BOOT_OBS_FILE"
  HEALTH_JUDGE_NOW="$(cat "$d/now")" \
    run_bootstrap "$(fixture_vault_dir "$d")" "$d/vault-reads.tsv" "$d/vault-recall.tsv" "$d" "$d/last-run.json" \
      "$plist" "$BOOT_OBS_FILE" "$session_json"
}

# run_dock_fixture <fixture名> — cmux-next-model.sh --frame を fixture の入力（判定機の入力 4 本＋plist）で回す。
# 既定が実ファイルの env 5 本をすべて fixture／存在しないパスへ向ける（設計 §10.1）。
run_dock_fixture() {
  local fx="$1" d="$HEALTH_FX_ROOT/$fx" plist="/nonexistent-dir/com.takumi009.maintenance.plist"
  [ -f "$d/plist" ] && plist="$d/plist"
  CMUX_NEXT_VAULT="$HEALTH_EMPTY_PROJECTS" CMUX_NEXT_MAINT_STATE="$d/last-run.json" \
    CMUX_NEXT_INVENTORY_LATEST="$d/latest.json" CMUX_NEXT_HEALTH_OBSERVATION="$d/observation.json" \
    CMUX_NEXT_RECALL_LOG="$d/vault-recall.tsv" CMUX_NEXT_MAINT_PLIST="$plist" \
    HEALTH_JUDGE_NOW="$(cat "$d/now")" bash "$CMUX_NEXT_MODEL" --frame 2>/dev/null
}

# health_section <ctx> — ヘルス節（【外部脳ヘルス】の行から、続く「- [」項目行・⚠️ 行まで）だけを取り出す。
health_section() {
  printf '%s\n' "$1" | awk '/^【外部脳ヘルス】/{flag=1; print; next} flag && (/^- \[/ || /^⚠️ 観測記録/){print; next} flag{exit}'
}
health_header() { printf '%s\n' "$1" | grep '^【外部脳ヘルス】' | head -1; }

echo "=== 6. stage_unique_and_equal_to_dock（AC-12）: S-1〜S-23 全件で stage= がヘッダに 1 回・Dock の B 行と一致 ==="
{
  n_fx=0
  for d in "$HEALTH_FX_ROOT"/S-*; do
    fx="$(basename "$d")"
    n_fx=$((n_fx + 1))
    ctx="$(run_bootstrap_fixture "$fx")"
    frame="$(run_dock_fixture "$fx")"
    assert_eq "AC-12 $fx: stage= がちょうど 1 回" "1" "$(grep -c 'stage=' <<<"$ctx")"
    assert_eq "AC-12 $fx: 注入の stage と B 行の段階が一致" \
      "$(grep -o 'stage=[A-Z]*' <<<"$ctx" | cut -d= -f2)" \
      "$(awk -F'\t' '$1=="B"{print $4}' <<<"$frame" | sed 's/ 候補[0-9]*件$//')"
    assert_eq "AC-12 $fx: ヘッダの items= と項目行数が一致" \
      "$(grep -o 'items=[0-9]*' <<<"$ctx" | head -1 | cut -d= -f2)" \
      "$(health_section "$ctx" | grep -c '^- \[')"
    # bootstrap が書いた観測記録の load・recall_prev が fixture の observation.json（期待値）と一致（設計 §10.1）
    assert_eq "AC-12 $fx: 観測記録の load が期待値と一致" \
      "$(jq -c '.load' "$d/observation.json")" "$(jq -c '.load' "$BOOT_OBS_FILE" 2>/dev/null)"
    assert_eq "AC-12 $fx: 観測記録の recall_prev が期待値と一致" \
      "$(jq -c '.recall_prev' "$d/observation.json")" "$(jq -c '.recall_prev' "$BOOT_OBS_FILE" 2>/dev/null)"
  done
  assert_eq "AC-12: S-* は 23 本" "23" "$n_fx"
}

echo "=== frame_b_row_ok（AC-4 供給側）: S-1 → B 行 1 行＝外部脳／ok／OK＋候補12件 ==="
reset_vault
mk_note_N0 "$VAULT"
run_frame_fixture S-1
assert_eq "frame_b_row_ok: rc=0" "0" "$(cat "$WORKDIR/frame_rc")"
assert_eq "frame_b_row_ok: B 行はちょうど 1 行" "1" "$(b_rows | wc -l | tr -d ' ')"
s1_cand="$(jq -r '.fragments_candidates' "$FX_ROOT/S-1/last-run.json")"
assert_eq "frame_b_row_ok: B 行の文法（種別 外部脳・warn 欄 ok・3 値 OK・付記）" "B	外部脳	ok	OK 候補${s1_cand}件" "$(b_rows)"
assert_eq "frame_b_row_ok: 旧種別（棚卸し／週次）の行は出ない" "0" "$(awk -F '\t' '$1=="B" && ($2=="棚卸し" || $2=="週次")' "$WORKDIR/frame_stdout" | wc -l | tr -d ' ')"
p_n="$(awk -F '\t' '$1=="P"' "$WORKDIR/frame_stdout" | wc -l | tr -d ' ')"
assert_eq "frame_b_row_ok: E＝P 行数＋B 行数" "$(( p_n + 1 ))" "$(awk -F '\t' '$1=="E"{print $2}' "$WORKDIR/frame_stdout")"

echo "=== B 行の 3 値: S-2 → warn／WARNING・S-15 → error／ERROR ==="
run_frame_fixture S-2
s2_cand="$(jq -r '.fragments_candidates' "$FX_ROOT/S-2/last-run.json")"
assert_eq "S-2: B 行 warn／WARNING" "B	外部脳	warn	WARNING 候補${s2_cand}件" "$(b_rows)"
run_frame_fixture S-15
assert_eq "S-15: B 行 error／ERROR" "B	外部脳	error	ERROR 候補12件" "$(b_rows)"

echo "=== all_fixtures_one_b_row_three_values（AC-10）: S-1〜S-23 全件で B 行ちょうど 1 行・付記を除いた文言が 3 値・数字/日付/パス/工程名なし ==="
n_fx=0
for d in "$FX_ROOT"/S-*; do
  fx="$(basename "$d")"
  n_fx=$(( n_fx + 1 ))
  run_frame_fixture "$fx"
  assert_eq "AC-10 $fx: rc=0" "0" "$(cat "$WORKDIR/frame_rc")"
  assert_eq "AC-10 $fx: B 行ちょうど 1 行" "1" "$(b_rows | wc -l | tr -d ' ')"
  text="$(b_rows | awk -F '\t' '{print $4}' | sed 's/ 候補[0-9]*件$//')"
  kind="$(b_rows | awk -F '\t' '{print $2}')"
  warn="$(b_rows | awk -F '\t' '{print $3}')"
  assert_eq "AC-10 $fx: 種別＝外部脳" "外部脳" "$kind"
  assert_true "AC-10 $fx: 付記を除いた文言が 3 値のいずれか（実測 ${text}）" \
    "$([ "$text" = "OK" ] || [ "$text" = "WARNING" ] || [ "$text" = "ERROR" ] && echo 1 || echo 0)"
  assert_true "AC-10 $fx: warn 欄と文言の対応（ok/OK・warn/WARNING・error/ERROR）" \
    "$({ [ "$warn/$text" = "ok/OK" ] || [ "$warn/$text" = "warn/WARNING" ] || [ "$warn/$text" = "error/ERROR" ]; } && echo 1 || echo 0)"
  assert_eq "AC-10 $fx: 付記を除いた文言に数字・日付・パス・工程名が無い" "0" "$(printf '%s' "$text" | grep -c '[0-9/.]\|Phase\|要確認\|日前')"
  assert_eq "AC-10 $fx: 4 列ちょうど" "4" "$(b_rows | awk -F '\t' '{print NF}')"
done
assert_eq "AC-10: S-* は 23 本" "23" "$n_fx"

echo "=== b_row_suffix_candidates_when_nonneg（R-2）: fragments_candidates が非負整数のときだけ末尾に「 候補N件」（0 件も表示）。キー無し・型違反は付けない ==="
CAND_DIR="$WORKDIR/cand"; mkdir -p "$CAND_DIR"
cp "$FX_ROOT/S-1/latest.json" "$FX_ROOT/S-1/observation.json" "$FX_ROOT/S-1/vault-recall.tsv" "$FX_ROOT/S-1/now" "$CAND_DIR/"
run_cand() {   # $1=fragments_candidates の JSON 値（"del" でキー削除）
  if [ "$1" = "del" ]; then
    jq 'del(.fragments_candidates)' "$FX_ROOT/S-1/last-run.json" > "$CAND_DIR/last-run.json"
  else
    jq --argjson v "$1" '.fragments_candidates = $v' "$FX_ROOT/S-1/last-run.json" > "$CAND_DIR/last-run.json"
  fi
  CMUX_NEXT_VAULT="$VAULT" CMUX_NEXT_MAINT_STATE="$CAND_DIR/last-run.json" \
    CMUX_NEXT_INVENTORY_LATEST="$CAND_DIR/latest.json" CMUX_NEXT_HEALTH_OBSERVATION="$CAND_DIR/observation.json" \
    CMUX_NEXT_RECALL_LOG="$CAND_DIR/vault-recall.tsv" CMUX_NEXT_MAINT_PLIST="/nonexistent-dir/com.takumi009.maintenance.plist" \
    HEALTH_JUDGE_NOW="$(cat "$CAND_DIR/now")" bash "$TARGET" --frame > "$WORKDIR/frame_stdout" 2>/dev/null
}
run_cand 0
assert_eq "候補 0 件も表示" "B	外部脳	ok	OK 候補0件" "$(b_rows)"
run_cand 37
assert_eq "候補 37 件" "B	外部脳	ok	OK 候補37件" "$(b_rows)"
run_cand del
assert_eq "キー無し: 付記なし" "B	外部脳	ok	OK" "$(b_rows)"
run_cand '"12"'
assert_eq "型違反（文字列）: 付記なし" "B	外部脳	ok	OK" "$(b_rows)"
run_cand -1
assert_eq "負数: 付記なし" "B	外部脳	ok	OK" "$(b_rows)"
run_cand 'null'
assert_eq "null: 付記なし" "B	外部脳	ok	OK" "$(b_rows)"

echo "=== health_judge_now_passed_as_now（V-8(a)）: HEALTH_JUDGE_NOW が --now に写る（S-13＝予定超過は now で決まる） ==="
# S-13 は S-2 と同じ記録・plist つき。now を fixture の値（翌週）にすると未起動が加わり WARNING、
# now を S-2 の値（予定を跨がない）にしても WARNING（失敗 1 件）＝段階では見分けられないので、
# 判定機を spy して --now の値そのものを検査する。
SPY_PY="$WORKDIR/spy-py"; mkdir -p "$SPY_PY"
REAL_PY="$(command -v python3)"
cat > "$SPY_PY/python3" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$WORKDIR/py-args.log"
exec "$REAL_PY" "\$@"
EOF
chmod +x "$SPY_PY/python3"
: > "$WORKDIR/py-args.log"
PATH="$SPY_PY:$PATH" run_frame_fixture S-13
assert_eq "HEALTH_JUDGE_NOW あり: --now <fixture の now> が渡る" "1" "$(grep -c -- "--now $(cat "$FX_ROOT/S-13/now")" "$WORKDIR/py-args.log")"
assert_eq "HEALTH_JUDGE_NOW あり: S-13 は WARNING" "warn" "$(b_rows | awk -F '\t' '{print $3}')"
assert_eq "判定機呼び出し: --recall-stale-days 7 が渡る（I-2・bootstrap と同じ既定の渡し方＝設計 §4.1）" "1" "$(grep -c -- '--recall-stale-days 7' "$WORKDIR/py-args.log")"
: > "$WORKDIR/py-args.log"
d="$FX_ROOT/S-1"
PATH="$SPY_PY:$PATH" CMUX_NEXT_VAULT="$VAULT" CMUX_NEXT_MAINT_STATE="$d/last-run.json" \
  CMUX_NEXT_INVENTORY_LATEST="$d/latest.json" CMUX_NEXT_HEALTH_OBSERVATION="$d/observation.json" \
  CMUX_NEXT_RECALL_LOG="$d/vault-recall.tsv" CMUX_NEXT_MAINT_PLIST="/nonexistent-dir/com.takumi009.maintenance.plist" \
  HEALTH_JUDGE_NOW="" bash "$TARGET" --frame > "$WORKDIR/frame_stdout" 2>/dev/null
assert_eq "HEALTH_JUDGE_NOW 無し: --now を渡さない" "0" "$(grep -c -- '--now' "$WORKDIR/py-args.log")"
assert_eq "HEALTH_JUDGE_NOW 無し: 判定機は呼ばれている" "1" "$(grep -c 'health_judge.py judge' "$WORKDIR/py-args.log")"

echo "=== 判定機の入力が壊れていても B 行は出る（NFR-2）: last-run.json 解析不能＝WARNING（破損）・観測記録なし＝OK ==="
d="$FX_ROOT/X-3"
CMUX_NEXT_VAULT="$VAULT" CMUX_NEXT_MAINT_STATE="$d/last-run.json" CMUX_NEXT_INVENTORY_LATEST="$d/latest.json" \
  CMUX_NEXT_HEALTH_OBSERVATION="/nonexistent-dir/session-observation.json" CMUX_NEXT_RECALL_LOG="$d/vault-recall.tsv" \
  CMUX_NEXT_MAINT_PLIST="/nonexistent-dir/com.takumi009.maintenance.plist" HEALTH_JUDGE_NOW="$(cat "$d/now")" \
  bash "$TARGET" --frame > "$WORKDIR/frame_stdout" 2>/dev/null
assert_eq "X-3（解析不能）: B 行 warn／WARNING" "B	外部脳	warn	WARNING" "$(b_rows)"
CMUX_NEXT_VAULT="$VAULT" CMUX_NEXT_MAINT_STATE="/nonexistent-dir/last-run.json" CMUX_NEXT_INVENTORY_LATEST="/nonexistent-dir/latest.json" \
  CMUX_NEXT_HEALTH_OBSERVATION="/nonexistent-dir/session-observation.json" CMUX_NEXT_RECALL_LOG="/nonexistent-dir/vault-recall.tsv" \
  CMUX_NEXT_MAINT_PLIST="/nonexistent-dir/com.takumi009.maintenance.plist" \
  bash "$TARGET" --frame > "$WORKDIR/frame_stdout" 2>/dev/null
assert_eq "データ源が全部無い（サブ機初回・F-7）: 不在＝OK の B 行 1 行" "B	外部脳	ok	OK" "$(b_rows)"

# 旧 test-cmux-next-model.sh の「空 Vault」「v5_ac138」から B 行の有無の検査だけを移した（判定機が要る）。
run_frame_empty_sources() {   # $1＝判定時刻の固定口（空＝実時刻）
  CMUX_NEXT_JUDGE_NOW="$1" CMUX_NEXT_VAULT="$VAULT" CMUX_NEXT_INVENTORY_DIR="/nonexistent-dir/inventory" \
    CMUX_NEXT_MAINT_STATE="/nonexistent-dir/last-run.json" CMUX_NEXT_INVENTORY_LATEST="/nonexistent-dir/latest.json" \
    CMUX_NEXT_HEALTH_OBSERVATION="/nonexistent-dir/session-observation.json" CMUX_NEXT_RECALL_LOG="/nonexistent-dir/vault-recall.tsv" \
    CMUX_NEXT_MAINT_PLIST="/nonexistent-dir/com.takumi009.maintenance.plist" \
    bash "$TARGET" --frame > "$WORKDIR/frame_stdout" 2>/dev/null
}
echo "=== 空Vault(--frame): データ源が無くても判定機は「不在＝OK」＝B 行は 1 行・E は 1（FR-15） ==="
reset_vault
run_frame_empty_sources ""
assert_eq "空Vault(--frame): B行は不在＝OKの1行" "B	外部脳	ok	OK" "$(b_rows)"
assert_eq "空Vault(--frame): E行1（P 0＋B 1）" "1" "$(awk -F '\t' '$1=="E"{print $2}' "$WORKDIR/frame_stdout")"

echo "=== v5_ac138（B 行の部分）: WU-A × T0 の --frame に B 行 1 行 ==="
reset_vault
mk_notes_WU_A "$VAULT"
run_frame_empty_sources "2026-09-20T12:00"
assert_eq "v5_ac138: B 行 1 行" "1" "$(b_rows | wc -l | tr -d ' ')"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
