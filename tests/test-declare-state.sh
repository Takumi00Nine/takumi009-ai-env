#!/usr/bin/env bash
# 宣言状態の寄与（Dock 実行器）のテスト（Dock）。SessionStart の注入文の ⑥ の 1 行を出す。
# tests/test-bootstrap-vault.sh から移し替えた（由来＝分割元。v1.1 設計 v1.2 §4.3・実装計画 §8）:
#   旧 84（⑥ の部分）・85・86・87。番号は旧のまま。①〜⑤ との並び（ブロック全体）は tests/test-session-start-compose.sh。
#
# 実行方法: bash tests/test-declare-state.sh
#
# 契約（テストが決めた口。設計 §5.5・§11、実装計画 §7・§9）:
#   寄与     dock/executor/declare-state.sh。stdin＝hook JSON。
#     --slots   {"slots":{"declare6":"<⑥ の 1 行>"}}（この 1 枠ちょうど・末尾に改行を付けない）。
#     引数なし  {"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"<⑥ の 1 行>"}}。
#   ⑥ の宣言コマンドの文＝`~/work/takumi009-ai-env/dock/executor/cmux-task-declare.sh set <slug>`（新パス）。
# v6（cmux-session-todo requirements-v6.md FR-112・AC-153・design.md §41.6）＝実装への契約（旧 bootstrap の口を引き継ぐ）:
#   BOOTSTRAP_CMUX_LIB_DIR ＝ 寄与が宣言状態の判定のために source する共有部品（Dock の lib＝呼び出し元
#   ワークスペースの解決・宣言記録の読み手）の置き場ディレクトリ。既定＝寄与の実体位置からの相対（同じ機能）。
#   存在しないパスを与えると段 0 が失敗し ⑥ は「宣言状態 不明」に倒れる（DT-29）。
#   cmux 実体＝PATH 上の `cmux`（上書き口 CMUX_TASK_CMUX_BIN は宣言 CLI と同じ）・
#   宣言記録＝`$HOME/.config/cmux-task-watch/workspaces.json`（上書き口 CMUX_TASK_STATE は
#   宣言 CLI と同じ）・呼び出し上限＝既定 5 秒（CMUX_TASK_CALL_TIMEOUT・取得全体で 1 つ）。
# A-v6-4: 寄与が cmux を呼ぶので、本ファイルの全ケースで PATH 先頭に「応答しない cmux スタブ」を置き、
# 実 cmux（実ソケット）に触れないよう固定する。HOME も一時ディレクトリにする。

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
DECL="$REPO_ROOT/dock/executor/declare-state.sh"
DECL_SESSION_JSON='{"session_id":"test-session-0000"}'

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail_case "$1 (expected=$2 actual=$3)"; fi; }
assert_true() { if [ "$2" = "1" ]; then pass "$1"; else fail_case "$1"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail_case "$1 (含まれない: \"$3\")"; fi; }
assert_not_contains() { if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail_case "$1 (含まれてはいけないのに含まれる: \"$3\")"; fi; }

# safe_mktemp_d — mktemp -d のラッパー（旧 test-bootstrap-vault.sh から写した＝rm -rf の巻き込み防止）。
safe_mktemp_d() {
  local d
  d="$(mktemp -d)" || { echo "FATAL: mktemp -d に失敗しました" >&2; return 1; }
  case "$d" in "" | "/") echo "FATAL: mktemp -d の返り値が不正です: [$d]" >&2; return 1 ;; esac
  [ -d "$d" ] || { echo "FATAL: mktemp -d がディレクトリを作成しませんでした: [$d]" >&2; return 1; }
  [ -z "$(ls -A "$d" 2>/dev/null)" ] || { echo "FATAL: mktemp -d が空でない既存ディレクトリを返しました: [$d]" >&2; return 1; }
  printf '%s' "$d"
}

CMUX_FIXED_STUB_DIR="$(safe_mktemp_d)" || exit 1
printf '#!/bin/bash\nexit 9\n' > "$CMUX_FIXED_STUB_DIR/cmux"
chmod +x "$CMUX_FIXED_STUB_DIR/cmux"
export PATH="$CMUX_FIXED_STUB_DIR:$PATH"
DECL_HOME="$(safe_mktemp_d)" || exit 1
export HOME="$DECL_HOME"
unset CMUX_TASK_STATE CMUX_TASK_CMUX_BIN CMUX_TASK_CALL_TIMEOUT BOOTSTRAP_CMUX_LIB_DIR

# run_decl — 寄与を引数なしで起動し additionalContext を返す（失敗しても空を返して続ける）。
run_decl() {
  printf '%s\n' "$DECL_SESSION_JSON" | "$DECL" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null || true
}

echo "=== S1. --slots 全枠モード（実装計画 §9）: 枠名 declare6 ちょうど・引数なし＝同じ 1 行 ==="
{
  slots_json="$(printf '%s\n' "$DECL_SESSION_JSON" | "$DECL" --slots 2>/dev/null || true)"
  assert_eq "S1: 枠名＝declare6 だけ" "declare6" "$(printf '%s' "$slots_json" | jq -r '.slots | keys | join(",")' 2>/dev/null || true)"
  line6="$(printf '%s' "$slots_json" | jq -r '.slots.declare6' 2>/dev/null || true)"
  assert_eq "S1: declare6 は ⑥ で始まる 1 行" "1" "$(printf '%s\n' "$line6" | grep -c '^⑥ ' || true)"
  assert_eq "S1: 引数なしの additionalContext＝declare6 の 1 行" "$line6" "$(run_decl)"
}

echo "=== 84. 注入本文の ⑥: 宣言コマンドを含む1行・cmux 不在＝宣言状態 不明・実行はリーダー ==="
{
  ctx84="$(run_decl)"
  n_line84="$(printf '%s\n' "$ctx84" | grep -cE '^⑥ .*cmux-task-declare\.sh set <slug>' || true)"
  assert_eq "84: ⑥は宣言コマンド(set <slug>)を含むちょうど1行" "1" "$n_line84"
  line6_84="$(printf '%s\n' "$ctx84" | grep '^⑥ ' || true)"
  assert_not_contains "84(v6): ⑥ の行に「宣言済み」は無い（cmux 不在＝不明。旧文面の括弧書きは流用しない）" "$line6_84" "宣言済み"
  assert_contains "84(v6): ⑥ の行は「宣言状態 不明」（cmux 不在）" "$line6_84" "宣言状態 不明"
  assert_contains "84: ⑥は「実行はリーダー」を残す" "$ctx84" "実行はリーダーであってフックではない"
  assert_contains "84: ⑥の宣言コマンドは新パス（dock/executor/cmux-task-declare.sh）" "$line6_84" "~/work/takumi009-ai-env/dock/executor/cmux-task-declare.sh set <slug>"
}

echo "=== 85. FR-48/AC-59: 寄与は宣言コマンド(set)を実行せず、宣言記録も作らない ==="
{
  SPY_DIR85="$(safe_mktemp_d)" || exit 1
  MARKER_DIR85="$(safe_mktemp_d)" || exit 1
  MARKER85="$MARKER_DIR85/declare-was-called.marker"
  printf '#!/bin/bash\ntouch "%s"\n' "$MARKER85" > "$SPY_DIR85/cmux-task-declare.sh"
  chmod +x "$SPY_DIR85/cmux-task-declare.sh"
  # 注入文に書かれている固定パス（$HOME/work/takumi009-ai-env/dock/executor/）にもスパイを置く（隔離 HOME）。
  FAKE_HOME85="$(safe_mktemp_d)" || exit 1
  mkdir -p "$FAKE_HOME85/work/takumi009-ai-env/dock/executor"
  MARKER_DIR85B="$(safe_mktemp_d)" || exit 1
  MARKER85B="$MARKER_DIR85B/declare-was-called-fixedpath.marker"
  printf '#!/bin/bash\ntouch "%s"\n' "$MARKER85B" > "$FAKE_HOME85/work/takumi009-ai-env/dock/executor/cmux-task-declare.sh"
  chmod +x "$FAKE_HOME85/work/takumi009-ai-env/dock/executor/cmux-task-declare.sh"
  STATE_DIR85="$(safe_mktemp_d)" || exit 1
  STATE85="$STATE_DIR85/workspaces.json"

  ctx85="$(HOME="$FAKE_HOME85" PATH="$SPY_DIR85:$PATH" CMUX_TASK_STATE="$STATE85" run_decl)"

  assert_eq "85: ⑥ の行は出る（寄与は壊れない）" "1" "$(printf '%s\n' "$ctx85" | grep -c '^⑥ ' || true)"
  assert_eq "85: 偽cmux-task-declare.sh(PATH経由)は呼ばれない（マーカー未生成）" "0" "$([ -e "$MARKER85" ] && echo 1 || echo 0)"
  assert_eq "85: 偽cmux-task-declare.sh(固定パス経由)も呼ばれない" "0" "$([ -e "$MARKER85B" ] && echo 1 || echo 0)"
  assert_eq "85: 宣言記録ファイルも作られない" "0" "$([ -e "$STATE85" ] && echo 1 || echo 0)"

  rm -rf "$SPY_DIR85" "$MARKER_DIR85" "$FAKE_HOME85" "$MARKER_DIR85B" "$STATE_DIR85"
}

echo "=== 86. v6 AC-153（FR-112・NFR-19）: ⑥ の宣言状態 WD-1〜WD-9（隔離 HOME・B-1 スパイ・PATH 先頭の cmux スタブ）＋DT-24・DT-29・DT-30 ==="
{
  # --- cmux スタブ（WD ごとに応答を変える）。mode＝ok／fail_identify／no_caller／fail_list／hang／unknown_ref／hang_list。
  # 呼び出し元＝workspace:1（UUID U1）。hang は全サブコマンドで 10 秒 sleep（WD-8）。hang_list は identify 即応答・
  # 一覧だけ 10 秒 sleep（DT-24）。fail_list は workspace list と list-windows の両方が非 0（WD-7）。
  # $3=呼出しログ（1 呼び出し 1 行 append。WD-6「cmux を呼ばずに終える」の観測にだけ使う＝設計 §41.6.2 段 1）。
  mk_wd_cmux_stub() {
    local bin="$1" mode="$2" calls_log="$3"
    printf '#!/bin/bash\nmode="%s"\necho "cmux $*" >> "%s"\n' "$mode" "$calls_log" > "$bin"
    cat >> "$bin" <<'EOF'
[ "$mode" = "hang" ] && { sleep 10; exit 1; }
[ "$1" = "--json" ] || exit 9
sub="$2"
if [ "$sub" = "identify" ]; then
  case "$mode" in
    fail_identify) exit 9 ;;
    no_caller) printf '{"focused":{"workspace_ref":"workspace:1"}}\n'; exit 0 ;;
    unknown_ref) printf '{"focused":{"workspace_ref":"workspace:1"},"caller":{"workspace_ref":"workspace:99"}}\n'; exit 0 ;;
    *) printf '{"focused":{"workspace_ref":"workspace:1"},"caller":{"workspace_ref":"workspace:1"}}\n'; exit 0 ;;
  esac
fi
if [ "$sub" = "workspace" ] && [ "${3:-}" = "list" ]; then
  case "$mode" in
    fail_list) exit 9 ;;
    hang_list) sleep 10; exit 1 ;;
  esac
  printf '{"workspaces":[{"id":"U1","ref":"workspace:1","index":0}]}\n'; exit 0
fi
if [ "$sub" = "list-windows" ]; then
  case "$mode" in
    fail_list) exit 9 ;;
    hang_list) sleep 10; exit 1 ;;
  esac
  printf '[{"id":"win:1","index":0}]\n'; exit 0
fi
exit 9
EOF
    chmod +x "$bin"
  }

  # --- WD-4 用: PATH から cmux を除く（cmux を含むディレクトリは、cmux 以外への symlink だけを持つ影のディレクトリに置き換える）。
  # 影のディレクトリは WD_SHADOW_ROOT 配下に作り、ケース末尾で rm -rf する。
  WD_SHADOW_ROOT="$(safe_mktemp_d)" || exit 1
  path_without_cmux() {
    local out="" d shadow f n=0
    local IFS=':'
    for d in $PATH; do
      [ -n "$d" ] || continue
      if [ -x "$d/cmux" ]; then
        n=$(( n + 1 ))
        shadow="$WD_SHADOW_ROOT/$n"
        mkdir -p "$shadow"
        for f in "$d"/*; do
          [ -e "$f" ] || continue
          [ "${f##*/}" = "cmux" ] && continue
          ln -s "$f" "$shadow/${f##*/}" 2>/dev/null || true
        done
        d="$shadow"
      fi
      out="${out:+$out:}$d"
    done
    printf '%s' "$out"
  }
  PATH_NO_CMUX="$(path_without_cmux)"
  no_cmux_ok=0
  if ! PATH="$PATH_NO_CMUX" command -v cmux >/dev/null 2>&1; then no_cmux_ok=1; fi
  assert_true "86: WD-4 用の PATH に cmux が無い（前提の実測）" "$no_cmux_ok"
  assert_true "86: WD-4 用の PATH でも jq が引ける（前提の実測）" "$(PATH="$PATH_NO_CMUX" command -v jq >/dev/null 2>&1 && echo 1 || echo 0)"

  # --- 隔離 HOME を 1 件組む。$1=記録の形（pair／none／corrupt／multi）。
  # 出力（グローバル）: WD_HOME・WD_SPY（PATH 先頭スパイ）・WD_MARK・WD_MARKB（固定パススパイの呼出しマーカー）・WD_REC（記録の既定パス）。
  wd_setup() {
    local rec_mode="$1"
    WD_HOME="$(safe_mktemp_d)" || exit 1
    WD_SPY="$(safe_mktemp_d)" || exit 1
    mkdir -p "$WD_HOME/markers" "$WD_HOME/work/takumi009-ai-env/dock/executor" "$WD_HOME/.config/cmux-task-watch"
    WD_MARK="$WD_HOME/markers/declare-was-called.marker"
    WD_MARKB="$WD_HOME/markers/declare-was-called-fixedpath.marker"
    printf '#!/bin/bash\ntouch "%s"\n' "$WD_MARK" > "$WD_SPY/cmux-task-declare.sh"
    printf '#!/bin/bash\ntouch "%s"\n' "$WD_MARKB" > "$WD_HOME/work/takumi009-ai-env/dock/executor/cmux-task-declare.sh"
    chmod +x "$WD_SPY/cmux-task-declare.sh" "$WD_HOME/work/takumi009-ai-env/dock/executor/cmux-task-declare.sh"
    WD_REC="$WD_HOME/.config/cmux-task-watch/workspaces.json"
    case "$rec_mode" in
      pair)    printf '{"version":1,"workspaces":{"U1":"slug-a"}}\n' > "$WD_REC" ;;
      none)    : ;;
      corrupt) printf 'not json' > "$WD_REC" ;;
      multi)   printf '{"version":1,"workspaces":{"U9":"slug-z","U1":"slug-a","U2":"slug-a"}}\n' > "$WD_REC" ;;
    esac
  }
  rec_digest() { if [ -e "$1" ]; then shasum -a 256 "$1" | awk '{print $1}'; else printf 'ABSENT'; fi; }
  now_mono() { python3 -c 'import time; print(time.monotonic())'; }

  # --- 1 件走らせる。$1=ID $2=cmux の mode（absent＝PATH に cmux なし）$3=記録の形。
  # 出力（グローバル）: WD_CTX・WD_RC・WD_LINE6・WD_N6・WD_ELAPSED・WD_MARK_HIT・WD_REC_BEFORE／AFTER。
  run_wd() {
    local id="$1" mode="$2" rec_mode="$3" stub_dir path out_json rc t0 t1
    wd_setup "$rec_mode"
    stub_dir="$(safe_mktemp_d)" || exit 1
    WD_CMUX_CALLS="$stub_dir/cmux-calls.log"
    : > "$WD_CMUX_CALLS"
    if [ "$mode" = "absent" ]; then
      path="$WD_SPY:$PATH_NO_CMUX"
    else
      mk_wd_cmux_stub "$stub_dir/cmux" "$mode" "$WD_CMUX_CALLS"
      path="$stub_dir:$WD_SPY:$PATH"
    fi
    WD_REC_BEFORE="$(rec_digest "$WD_REC")"
    out_json="$stub_dir/out.json"
    rc=0
    t0="$(now_mono)"
    printf '%s\n' "$DECL_SESSION_JSON" \
      | HOME="$WD_HOME" PATH="$path" "$DECL" > "$out_json" || rc=$?
    t1="$(now_mono)"
    WD_RC="$rc"
    WD_ELAPSED="$(python3 -c "print($t1 - $t0)")"
    WD_CTX="$(jq -r '.hookSpecificOutput.additionalContext' "$out_json" 2>/dev/null || true)"
    WD_LINE6="$(printf '%s\n' "$WD_CTX" | grep '^⑥ ' || true)"
    WD_N6="$(printf '%s\n' "$WD_CTX" | grep -c '^⑥ ' || true)"
    WD_MARK_HIT=0
    [ -e "$WD_MARK" ] && WD_MARK_HIT=1
    [ -e "$WD_MARKB" ] && WD_MARK_HIT=$(( WD_MARK_HIT + 2 ))
    WD_REC_AFTER="$(rec_digest "$WD_REC")"
    echo "  ($id: mode=$mode rec=$rec_mode rc=$WD_RC elapsed=${WD_ELAPSED}s)"
  }
  # 9 件共通の判定（AC-153 ①②③＋促し＝宣言コマンドの絶対パス・⑥ は 1 行）。
  wd_common_asserts() {
    local id="$1"
    assert_eq "$id: 寄与の終了コードが 0" "0" "$WD_RC"
    assert_eq "$id: ⑥ はちょうど 1 行（AC-59 の促す行が 1 行）" "1" "$WD_N6"
    assert_contains "$id: ⑥ の行に宣言コマンドの絶対パス（dock/executor/cmux-task-declare.sh）" "$WD_LINE6" "/dock/executor/cmux-task-declare.sh"
    assert_eq "$id: B-1 スパイ（PATH・固定パス）の呼出しマーカーが無い" "0" "$WD_MARK_HIT"
    assert_eq "$id: 宣言記録が変化しない（WD-2 は作られない）" "$WD_REC_BEFORE" "$WD_REC_AFTER"
  }
  wd_assert_unknown() {   # 不明（`宣言状態 不明`＋促し・宣言済み／未宣言／宣言記録破損なし）
    local id="$1"
    assert_contains "$id: ⑥ の行に 宣言状態 不明" "$WD_LINE6" "宣言状態 不明"
    assert_not_contains "$id: ⑥ の行に 宣言済み は無い" "$WD_LINE6" "宣言済み"
    assert_not_contains "$id: ⑥ の行に 未宣言 は無い" "$WD_LINE6" "未宣言"
    assert_not_contains "$id: ⑥ の行に 宣言記録破損 は無い" "$WD_LINE6" "宣言記録破損"
  }


  echo "--- WD-1: cmux 正常・呼び出し元 U1・記録 U1→slug-a ＝ 宣言済み slug-a"
  run_wd "WD-1" ok pair
  wd_common_asserts "WD-1"
  assert_contains "WD-1: ⑥ の行に 宣言済み" "$WD_LINE6" "宣言済み"
  assert_contains "WD-1: ⑥ の行に slug-a（同じ行）" "$WD_LINE6" "slug-a"
  assert_not_contains "WD-1: ⑥ の行に 未宣言 は無い" "$WD_LINE6" "未宣言"
  assert_not_contains "WD-1: ⑥ の行に 不明 は無い" "$WD_LINE6" "不明"
  assert_eq "WD-1: 記録は 1 対のまま" "1" "$(jq -r '.workspaces | length' "$WD_REC")"

  echo "--- WD-2: cmux 正常・記録なし ＝ 未宣言＋促し"
  run_wd "WD-2" ok none
  wd_common_asserts "WD-2"
  assert_contains "WD-2: ⑥ の行に 未宣言" "$WD_LINE6" "未宣言"
  assert_not_contains "WD-2: ⑥ の行に 宣言済み は無い" "$WD_LINE6" "宣言済み"
  assert_not_contains "WD-2: ⑥ の行に 不明 は無い" "$WD_LINE6" "不明"
  assert_eq "WD-2: 宣言記録は作られない" "ABSENT" "$WD_REC_AFTER"

  echo "--- WD-3: identify が非 0 ＝ 不明"
  run_wd "WD-3" fail_identify pair
  wd_common_asserts "WD-3"; wd_assert_unknown "WD-3"

  echo "--- WD-4: PATH に cmux が無い ＝ 不明"
  run_wd "WD-4" absent pair
  wd_common_asserts "WD-4"; wd_assert_unknown "WD-4"

  echo "--- WD-5: identify は成功するが caller が無い ＝ 不明"
  run_wd "WD-5" no_caller pair
  wd_common_asserts "WD-5"; wd_assert_unknown "WD-5"

  echo "--- WD-6: 記録が読めない（破損） ＝ 不明＋宣言記録破損"
  run_wd "WD-6" ok corrupt
  wd_common_asserts "WD-6"
  assert_contains "WD-6: ⑥ の行に 宣言状態 不明" "$WD_LINE6" "宣言状態 不明"
  assert_contains "WD-6: ⑥ の行に 宣言記録破損" "$WD_LINE6" "宣言記録破損"
  assert_not_contains "WD-6: ⑥ の行に 宣言済み は無い" "$WD_LINE6" "宣言済み"
  assert_not_contains "WD-6: ⑥ の行に 未宣言 は無い" "$WD_LINE6" "未宣言"
  assert_eq "WD-6: 記録破損では cmux を呼ばずに終える（スタブの呼出しログ 0 行＝設計 §41.6.2 段 1）" "0" "$(wc -l < "$WD_CMUX_CALLS" | tr -d ' ')"

  echo "--- WD-7: identify は成功するが一覧取得が非 0 ＝ 不明"
  run_wd "WD-7" fail_list pair
  wd_common_asserts "WD-7"; wd_assert_unknown "WD-7"

  echo "--- WD-8: cmux が応答せず 10 秒 sleep ＝ 不明・フックは 6 秒以内（NFR-19・取得全体で 1 つの上限 5 秒）"
  run_wd "WD-8" hang pair
  wd_common_asserts "WD-8"; wd_assert_unknown "WD-8"
  assert_true "WD-8: 寄与が 6 秒以内に返る（実測 ${WD_ELAPSED} 秒）" "$(python3 -c "print(1 if $WD_ELAPSED <= 6 else 0)")"

  echo "--- WD-9: caller の ref が一覧に無い（未知 ref） ＝ 不明"
  run_wd "WD-9" unknown_ref pair
  wd_common_asserts "WD-9"; wd_assert_unknown "WD-9"

  echo "--- DT-24: identify は即応答・一覧だけハング ＝ 不明・6 秒以内（段の合計でなく取得全体で 1 つの上限＝F-107）"
  run_wd "DT-24" hang_list pair
  wd_common_asserts "DT-24"; wd_assert_unknown "DT-24"
  assert_true "DT-24: 寄与が 6 秒以内に返る（実測 ${WD_ELAPSED} 秒）" "$(python3 -c "print(1 if $WD_ELAPSED <= 6 else 0)")"

  echo "--- DT-29: 共有部品の所在の上書き口 BOOTSTRAP_CMUX_LIB_DIR を存在しないパスへ ＝ 不明・rc=0・①〜⑤ 不変（WD-1 と同じ入力）"
  export BOOTSTRAP_CMUX_LIB_DIR="/nonexistent-dir/cmux-lib-v6"
  run_wd "DT-29" ok pair
  unset BOOTSTRAP_CMUX_LIB_DIR
  wd_common_asserts "DT-29"; wd_assert_unknown "DT-29"

  echo "--- DT-30: 記録に同じ slug の対が 2 つ（U1・U2→slug-a）と別の対（U9→slug-z・先頭） ＝ 呼び出し元 U1 の対だけ"
  run_wd "DT-30" ok multi
  wd_common_asserts "DT-30"
  assert_contains "DT-30: ⑥ の行に 宣言済み" "$WD_LINE6" "宣言済み"
  assert_contains "DT-30: ⑥ の行に slug-a（呼び出し元 U1 の対）" "$WD_LINE6" "slug-a"
  assert_not_contains "DT-30: ⑥ の行に slug-z（先頭の対）は無い" "$WD_LINE6" "slug-z"
  assert_not_contains "DT-30: ⑥ の行に 不明 は無い" "$WD_LINE6" "不明"
  rm -rf "$WD_SHADOW_ROOT"
}

echo "=== 87. v6 AC-154 (d): README.md の宣言の使い方の案内に「再起動後は同じワークスペースで宣言が生きる・新しいワークスペースは注入文の宣言状態を見て 1 回宣言する」の旨 ==="
{
  readme_v6="$REPO_ROOT/README.md"
  n_decl_cmd="$(grep -c 'cmux-task-declare' "$readme_v6" || true)"
  assert_true "87: README に宣言コマンド（cmux-task-declare）の案内がある（実測 ${n_decl_cmd} 行）" "$([ "$n_decl_cmd" -ge 1 ] && echo 1 || echo 0)"
  n_restart="$(grep -c '再起動.*宣言\|宣言.*再起動' "$readme_v6" || true)"
  assert_true "87: README に「再起動」と「宣言」を同じ文に含む行が 1 つ以上（実測 ${n_restart} 行）" "$([ "$n_restart" -ge 1 ] && echo 1 || echo 0)"
  n_state="$(grep -c '宣言状態' "$readme_v6" || true)"
  assert_true "87: README に「宣言状態」を含む行が 1 つ以上（実測 ${n_state} 行）" "$([ "$n_state" -ge 1 ] && echo 1 || echo 0)"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
