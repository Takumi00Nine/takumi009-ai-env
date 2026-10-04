#!/usr/bin/env bash
# Notify（口・送り手・台帳の「知らせ」列）のユニットテスト（v1.2 束 B・新設）。
#
# 正本＝docs/v1.2-notify-install の要件 v1.3 §2・§5〜§7（AC-1③④・AC-3・AC-4・AC-5②③・AC-6）、
# 設計 v1.3 §2.1〜§2.4、実装計画 §1・§2・§4。
#
# 実 $HOME・実 cmux・実 osascript・実 CODE27 取次には一切触れない。HOME は一時ディレクトリに
# 固定し、PATH 先頭へ偽 launchctl／osascript／cmux（lib-ledger-fixtures.sh の lf_mk_fx6＝v1.1 FX-6
# 相当）を置き、CODE27_CALL_BIN／CODE27_CALL_LOG で偽 CODE27 取次（tests/fixtures/code27-call/・
# test-writer B 作成の共有 fixture）へ差し替える。FX-11（zz-dest・第 4 の届け先）は使い捨ての
# git worktree（lib-ledger-fixtures.sh の lf_copy_repo）の上に、共有 fixture
# tests/fixtures/zz-dest/connect/deliver.sh を足して作る。
#
# 契約（テストが決めた口。実装計画 §1 に無い分だけここで決める＝test-ledger.sh 冒頭と同じ流儀）:
#   ledger-tool.sh route <知らせ>  … <届け先><TAB><絶対パス> を台帳の行順に。終了コードは
#     lookup と同じ語彙＝0 あり／1 該当なし／2 台帳異常／3 全件が実体異常（実体の無い行は
#     1 行ずつ `LEDGER: part …` を stderr に出して結果から除く＝設計 §2.1）。
#
# 実行方法: bash tests/test-notify.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=./lib-ledger-fixtures.sh
. "$TESTS_DIR/lib-ledger-fixtures.sh"

NOTIFY="$REPO_ROOT/notify/executor/notify.sh"
DELIVER_MACOS="$REPO_ROOT/notify/connect/macos/deliver.sh"
DELIVER_CMUX="$REPO_ROOT/notify/connect/cmux/deliver.sh"
DELIVER_CODE27="$REPO_ROOT/notify/connect/code27/deliver.sh"
LEDGER_TOOL="$REPO_ROOT/core/assembly/ledger-tool.sh"
LEDGER_REAL="$REPO_ROOT/core/data/ledger.tsv"
ZZDEST_FIXTURE="$TESTS_DIR/fixtures/zz-dest/connect/deliver.sh"
CODE27_FAKE_BIN="$TESTS_DIR/fixtures/code27-call/bin/code27-call-clear"
CODE27_FAKE_SAY="$TESTS_DIR/fixtures/code27-call/bin/code27-call-say"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail_case "$1 (expected=[$2] actual=[$3])"; fi; }
assert_true() { if [ "$2" = "1" ]; then pass "$1"; else fail_case "$1"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail_case "$1 (含まれない: [$3] 実際: [$2])"; fi; }

# verifier 1巡目 VM-04＝`date +%s` の整数差は量子化誤差で「2秒未満」が約3秒でも合格しうる。
# 単調時計を小数秒で計る（macOS の date に %N は無いので python3 time.monotonic を使う）。
mono_now() { python3 -c 'import time; print(time.monotonic())'; }
# mono_lt <t0> <t1> <上限（秒・小数可）>  … (t1 - t0) < 上限 なら 1、他 0（厳密な未満）。
mono_lt() { python3 -c "print(1 if ($2 - $1) < $3 else 0)"; }
# mono_le <t0> <t1> <上限（秒・小数可）>  … (t1 - t0) <= 上限 なら 1、他 0。
mono_le() { python3 -c "print(1 if ($2 - $1) <= $3 else 0)"; }

WORK="$(mktemp -d)" || exit 1
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
STUB="$WORK/stub"
lf_mk_fx6 "$STUB"                      # 偽 launchctl・osascript・cmux（calls.log へ記録）
export HOME="$WORK/home" PATH="$STUB:$PATH"
mkdir -p "$HOME"
NOTIFY_LOG="$HOME/.claude/logs/notify.tsv"

echo "=== 0. 置き場: 口・送り手 3・台帳ツールが実在して実行可能 ==="
for f in "$NOTIFY" "$DELIVER_MACOS" "$DELIVER_CMUX" "$DELIVER_CODE27" "$LEDGER_TOOL"; do
  assert_true "$f が実行可能" "$([ -x "$f" ] && echo 1 || echo 0)"
done

echo "=== AC-5 ②: 台帳で Notify の実行器の部品がちょうど 1 件（口）。実体が実在・実行可能・呼ぶと exit 0 ==="
MOUTH_ROWS="$(awk -F'\t' '!/^#/ && $1=="part" && $3=="notify" && $4=="executor" {print}' "$LEDGER_REAL" 2>/dev/null)"
assert_eq "notify/executor の part 行はちょうど1" "1" "$(printf '%s\n' "$MOUTH_ROWS" | grep -c . || true)"
MOUTH_KEY="$(printf '%s' "$MOUTH_ROWS" | cut -f6)"
assert_eq "その鍵は notify.send" "notify.send" "$MOUTH_KEY"
rc=0
rm -f "$NOTIFY_LOG"
# ZZ_DEST_LOG＝実木に zz-dest が既にあっても既定の記録先（connect の親＝notify/connect/calls.log）へ
# 書かせず捨てる（このテストは3届け先の組立だけを見る・FX-11 の zz-dest 検証ではない）。
ZZ_DEST_LOG="$WORK/unused-ambient.log" "$NOTIFY" call ask "📣 テスト呼出" "本文" >/dev/null 2>&1 || rc=$?
assert_eq "口を shell から呼ぶと exit 0（3 届け先が全部入りで揃っている前提）" "0" "$rc"

echo "=== 3 届け先の充足（送り手の行で数える）・CODE27 は応答だけを受ける（対応表の誤り検査） ==="
for prov_knows in "macos:call" "cmux:call" "code27:answer"; do
  prov="${prov_knows%%:*}"; want="${prov_knows##*:}"
  row="$(awk -F'\t' -v p="$prov" '!/^#/ && $1=="part" && $3=="notify" && $4=="connect" && $5==p {print $8}' "$LEDGER_REAL" 2>/dev/null | head -1)"
  assert_true "届け先 $prov の送り手に「知らせ」列の値がある（空でない・- でない）" \
    "$([ -n "$row" ] && [ "$row" != "-" ] && echo 1 || echo 0)"
done
CODE27_KNOWS="$(awk -F'\t' '!/^#/ && $1=="part" && $3=="notify" && $4=="connect" && $5=="code27" {print $8}' "$LEDGER_REAL" 2>/dev/null | head -1)"
assert_true "CODE27 の送り手は呼出(call)の対応を持たない（二重発話防止・設計§2.3）" \
  "$(printf '%s' "$CODE27_KNOWS" | grep -qE '(^|,)call(\.|,|$)' && echo 0 || echo 1)"
assert_true "CODE27 の送り手は応答(answer)を受ける" "$(printf '%s' "$CODE27_KNOWS" | grep -qE '(^|,)answer(,|$)' && echo 1 || echo 0)"
DOCK_IN_NOTIFY="$(awk -F'\t' '!/^#/ && $1=="part" && $3=="dock" {d[$2]=1} !/^#/ && $1=="notify" {n[$2]=1}
  END {c=0; for (p in n) for (q in d) if (p==q) c++; print c}' "$LEDGER_REAL" 2>/dev/null)"
assert_eq "Dock の部品が Notify 所在に 0 件" "0" "${DOCK_IN_NOTIFY:-ledger-missing}"

echo "=== 台帳の「知らせ」列の形式（値を持つのは Notify の接続の実行可能な部品だけ） ==="
BAD_KNOWS="$(awk -F'\t' '!/^#/ && $1=="part" && $8!="-" && $8!="" && !($3=="notify" && $4=="connect") {print $2}' "$LEDGER_REAL" 2>/dev/null)"
assert_eq "Notify の接続以外に「知らせ」列の値を持つ行が無い" "0" "$(printf '%s\n' "$BAD_KNOWS" | grep -c . || true)"

echo "=== 口の呼び方と終了コード（0／1／64） ==="
rc=0; rm -f "$NOTIFY_LOG"
ZZ_DEST_LOG="$WORK/unused-ambient.log" "$NOTIFY" call ask "呼出タイトル" "呼出本文" >/dev/null 2>&1 || rc=$?
assert_eq "正常な呼出で exit 0" "0" "$rc"
rc=0
"$NOTIFY" >/dev/null 2>"$WORK/usage.err" || rc=$?
assert_eq "引数無し（使い方の誤り）は exit 64" "64" "$rc"
rc=0
"$NOTIFY" call >/dev/null 2>"$WORK/usage2.err" || rc=$?
assert_eq "call に区分・題・本文が無いのは exit 64" "64" "$rc"
: > "$WORK/no-dest-ledger.tsv"
rc=0
rm -f "$NOTIFY_LOG"
AIENV_LEDGER="$WORK/no-dest-ledger.tsv" "$NOTIFY" call ask "題" "本文" >/dev/null 2>&1 || rc=$?
assert_eq "届け先が無い台帳で呼ぶと exit 1（FX-19 相当）" "1" "$rc"
assert_true "記録に「届け先なし」（語 no-dest）が1行" "$(grep -q '	no-dest	' "$NOTIFY_LOG" 2>/dev/null && echo 1 || echo 0)"

echo "=== 送り手 3 の呼び方と終了コード（0／2／他） ==="
rm -f "$STUB/calls.log"
rc=0
"$DELIVER_MACOS" call alert "タイトル" "本文" >/dev/null 2>&1 || rc=$?
assert_eq "macOS 送り手: osascript があれば exit 0" "0" "$rc"
assert_true "macOS 送り手: osascript が呼ばれタイトル・本文を含む" \
  "$(grep -q "タイトル" "$STUB/calls.log" 2>/dev/null && grep -q "本文" "$STUB/calls.log" 2>/dev/null && echo 1 || echo 0)"
rc=0
PATH="$(lf_path_without osascript)" "$DELIVER_MACOS" call alert "タイトル" "本文" >/dev/null 2>&1 || rc=$?
assert_eq "macOS 送り手: osascript が無ければ exit 2（実行体なし）" "2" "$rc"
NOEXEC_OSA="$WORK/noexec-osa"
mkdir -p "$NOEXEC_OSA"
printf '#!/bin/bash\nexit 1\n' > "$NOEXEC_OSA/osascript"; chmod +x "$NOEXEC_OSA/osascript"
rc=0
PATH="$NOEXEC_OSA:$(lf_path_without osascript)" "$DELIVER_MACOS" call alert "タイトル" "本文" >/dev/null 2>&1 || rc=$?
assert_true "macOS 送り手: osascript が失敗すると 0/2 以外の非0" "$([ "$rc" != "0" ] && [ "$rc" != "2" ] && echo 1 || echo 0)"

rm -f "$STUB/calls.log"
rc=0
"$DELIVER_CMUX" call ask "📣 テスト呼出" "本文" >/dev/null 2>&1 || rc=$?
assert_eq "cmux 送り手: cmux があれば exit 0" "0" "$rc"
assert_eq "cmux 送り手: 発行が cmux notify --title <題> --body <本文> と同一" \
  "cmux notify --title 📣 テスト呼出 --body 本文" "$(cat "$STUB/calls.log" 2>/dev/null)"
rc=0
PATH="$(lf_path_without cmux)" "$DELIVER_CMUX" call ask "題" "本文" >/dev/null 2>&1 || rc=$?
assert_eq "cmux 送り手: cmux が無ければ exit 2" "2" "$rc"

CODE27_LOG="$WORK/code27-fake.log"
rm -f "$CODE27_LOG"
rc=0
CODE27_CALL_BIN="$CODE27_FAKE_BIN" CODE27_CALL_LOG="$CODE27_LOG" "$DELIVER_CODE27" answer - - - >/dev/null 2>&1 || rc=$?
assert_eq "CODE27 送り手: 取次があれば exit 0" "0" "$rc"
assert_true "CODE27 送り手: 消去の入口が呼ばれる" "$([ -s "$CODE27_LOG" ] && grep -q 'code27-call-clear' "$CODE27_LOG" && echo 1 || echo 0)"
rc=0
CODE27_CALL_BIN="$WORK/does-not-exist" "$DELIVER_CODE27" answer - - - >/dev/null 2>&1 || rc=$?
assert_eq "CODE27 送り手: 取次が無ければ exit 2" "2" "$rc"

echo "=== 台帳の「知らせ」列 + ledger-tool.sh route（行順・該当なし1・実体異常の除外と stderr 固定文） ==="
rc=0
ROUTE_OUT="$("$LEDGER_TOOL" route call.ask 2>"$WORK/route.err")"; rc=$?
assert_eq "route call.ask: exit 0" "0" "$rc"
assert_contains "route call.ask: cmux の行を含む" "$ROUTE_OUT" "cmux"
rc=0
ROUTE_OUT2="$("$LEDGER_TOOL" route call.nope-nothing-matches-this 2>"$WORK/route2.err")"; rc=$?
assert_eq "route 該当なし: exit 1" "1" "$rc"
assert_eq "route 該当なし: 出力なし" "" "$ROUTE_OUT2"
BADROUTE_LEDGER="$WORK/badroute-ledger.tsv"
{ cat "$LEDGER_REAL"
  printf 'part\tnotify/connect/zz-missing/deliver.sh\tnotify\tconnect\tzz-missing\t-\t試験\tcall.ask\t-\n'
} > "$BADROUTE_LEDGER"
rc=0
ROUTE_OUT3="$(AIENV_LEDGER="$BADROUTE_LEDGER" "$LEDGER_TOOL" route call.ask 2>"$WORK/route3.err")"; rc=$?
assert_eq "route 一部実体異常: 実在する cmux の行は残るので exit 0" "0" "$rc"
assert_eq "route 一部実体異常: 存在しない送り手は除かれる" "0" "$(printf '%s' "$ROUTE_OUT3" | grep -c 'zz-missing' || true)"
assert_true "route 一部実体異常: stderr に固定文 LEDGER: part" "$(grep -q 'LEDGER: part' "$WORK/route3.err" 2>/dev/null && echo 1 || echo 0)"
ALLBAD_LEDGER="$WORK/allbad-ledger.tsv"
printf 'part\tnotify/connect/zz-missing/deliver.sh\tnotify\tconnect\tzz-missing\t-\t試験\tcall.ask\t-\n' > "$ALLBAD_LEDGER"
rc=0
AIENV_LEDGER="$ALLBAD_LEDGER" "$LEDGER_TOOL" route call.ask >/dev/null 2>"$WORK/route4.err" || rc=$?
assert_eq "route 全件実体異常: exit 3" "3" "$rc"

echo "=== FX-11 ZZD（第 4 の届け先・移動表なし）: 式 A・zz-dest への到達・台帳検査 ==="
WT="$WORK/wt-fx11"
lf_copy_repo "$REPO_ROOT" "$WT"
lf_mk_fx11 "$WT" "$ZZDEST_FIXTURE"
chmod +x "$WT/notify/connect/zz-dest/deliver.sh"

formula_a() {  # formula_a <WT> <足した接続フォルダ相対パス>
  git -C "$1" status --porcelain --untracked-files=all \
    | cut -c4- \
    | grep -vE "^${2}/" \
    | grep -vxF 'core/data/ledger.tsv'
}
assert_eq "FX-11: 式A が 0 行（接続フォルダ＋台帳行だけの差分）" "0" "$(formula_a "$WT" 'notify/connect/zz-dest' | grep -c . || true)"

ZZLOG="$WORK/zz-dest-calls.log"; rm -f "$ZZLOG"
rc=0
ZZ_DEST_LOG="$ZZLOG" AIENV_LEDGER="$WT/core/data/ledger.tsv" bash "$WT/notify/executor/notify.sh" call ask "📣 テスト呼出" "本文" >/dev/null 2>&1 || rc=$?
assert_eq "FX-11: zz-dest を足した口を呼ぶと exit 0" "0" "$rc"
assert_eq "FX-11: zz-dest の記録に1行（題と本文を含む）" "1" "$(grep -c . "$ZZLOG" 2>/dev/null || true)"
assert_true "FX-11: zz-dest の記録に題と本文を含む" "$(grep -q 'テスト呼出' "$ZZLOG" 2>/dev/null && grep -q '本文' "$ZZLOG" 2>/dev/null && echo 1 || echo 0)"
assert_true "FX-11: 同じ呼出で cmux にも届く（偽 cmux の記録）" "$(grep -q 'cmux notify' "$STUB/calls.log" 2>/dev/null && echo 1 || echo 0)"

rc=0
AIENV_LEDGER="$WT/core/data/ledger.tsv" bash "$WT/core/assembly/ledger-tool.sh" check >"$WORK/fx11-check.out" 2>&1 || rc=$?
assert_eq "FX-11: 台帳の検査 exit 0（移動表に行の無い zz-dest を不合格にしない）" "0" "$rc"

echo "=== FX-17 ZZDN（陰性）: 接続フォルダの外の追跡ファイルに 1 行の変更＝式 A が 1 行 ==="
WT17="$WORK/wt-fx17"
lf_copy_repo "$REPO_ROOT" "$WT17"
lf_mk_fx11 "$WT17" "$ZZDEST_FIXTURE"
printf '# FX-17: 接続外の1行変更\n' >> "$WT17/README.md"
assert_eq "FX-17: 式A が 1 行（変更した接続外のパス）" "1" "$(formula_a "$WT17" 'notify/connect/zz-dest' | grep -c . || true)"
assert_contains "FX-17: その1行は README.md" "$(formula_a "$WT17" 'notify/connect/zz-dest')" "README.md"

echo "=== FX-19 NODEST（陰性）: 台帳から届け先の接続の行を全て除く＝終了1・記録 no-dest ==="
NODEST_LEDGER="$WORK/fx19-ledger.tsv"
awk -F'\t' '!/^#/ { if ($1=="part" && $4=="connect" && $3=="notify") next } { print }' "$LEDGER_REAL" > "$NODEST_LEDGER"
rc=0
rm -f "$NOTIFY_LOG"
AIENV_LEDGER="$NODEST_LEDGER" "$NOTIFY" call ask "📣 テスト呼出" "本文" >/dev/null 2>&1 || rc=$?
assert_eq "FX-19: 口の終了コードが 0 でない" "1" "$rc"
assert_true "FX-19: 記録に「届け先なし」が1行" "$(grep -q '	no-dest	' "$NOTIFY_LOG" 2>/dev/null && echo 1 || echo 0)"

echo "=== FX-24 PART（陰性・複合）: 1 届け先の実行体欠落・1 届け先の無応答・残りは届く ==="
PROMPT_ANSWER="$REPO_ROOT/core/connect/claude-code/prompt-answer.sh"
WT24="$WORK/wt-fx24"
lf_copy_repo "$REPO_ROOT" "$WT24"
lf_mk_fx11 "$WT24" "$ZZDEST_FIXTURE"
chmod +x "$WT24/notify/connect/zz-dest/deliver.sh"

HANG_STUB="$WORK/hang-stub"
mkdir -p "$HANG_STUB"
printf '#!/bin/bash\nsleep 30\n' > "$HANG_STUB/cmux"; chmod +x "$HANG_STUB/cmux"
printf '#!/bin/bash\nexit 0\n' > "$HANG_STUB/osascript"; chmod +x "$HANG_STUB/osascript"
printf '#!/bin/bash\nexit 0\n' > "$HANG_STUB/launchctl"; chmod +x "$HANG_STUB/launchctl"

ZZ24="$WORK/zz24.log"; rm -f "$ZZ24"
rm -f "$NOTIFY_LOG"
T=2
# v1.2 T6（リーダー裁定）＝計測の窓（start〜end）には口の起動〜終了だけを入れる。
# lf_path_without（約2秒かかる fixture 準備）は窓の外で先に済ませておく。
FX24_PATH="$HANG_STUB:$(lf_path_without cmux osascript launchctl)"
rc=0
# verifier 1巡目 VM-04＝date +%s の整数差でなく単調時計の小数秒で計る。
t0="$(mono_now)"
PATH="$FX24_PATH" \
  AIENV_LEDGER="$WT24/core/data/ledger.tsv" AIENV_NOTIFY_WAIT_SECS="$T" ZZ_DEST_LOG="$ZZ24" \
  bash "$WT24/notify/executor/notify.sh" call ask "📣 テスト呼出" "本文" >/dev/null 2>&1 || rc=$?
t1="$(mono_now)"
assert_true "FX-24: 所要が T+1 秒以内（T=${T}・厳密な単調時計）" "$(mono_le "$t0" "$t1" "$((T + 1))")"
assert_eq "FX-24: zz-dest の記録に1行（応答しない cmux をよそに届く）" "1" "$(grep -c . "$ZZ24" 2>/dev/null || true)"
assert_true "FX-24: 記録に cmux の応答なし（timeout）が1行" "$(grep -q 'cmux' "$NOTIFY_LOG" 2>/dev/null && grep -q 'timeout' "$NOTIFY_LOG" 2>/dev/null && echo 1 || echo 0)"

echo "--- FX-24 続き: CODE27 の実行体欠落（UserPromptSubmit 入口経由） ---"
if [ -x "$PROMPT_ANSWER" ]; then
  rm -f "$NOTIFY_LOG"
  json='{"session_id":"s1","prompt":"了解","hook_event_name":"UserPromptSubmit"}'
  rc=0
  t0="$(mono_now)"
  out="$(printf '%s' "$json" | CODE27_CALL_BIN="$WORK/no-such-code27" AIENV_LEDGER="$LEDGER_REAL" AIENV_NOTIFY_WAIT_SECS="$T" \
    bash "$PROMPT_ANSWER" 2>"$WORK/prompt.err")" || rc=$?
  t1="$(mono_now)"
  assert_eq "入口: 終了コード0" "0" "$rc"
  assert_eq "入口: 標準出力は空" "" "$out"
  assert_true "入口: 2秒未満で終了（厳密な単調時計・VM-04）" "$(mono_lt "$t0" "$t1" 2.0)"
  sleep 1
  assert_true "記録に CODE27（実行体なし）が1行" "$(grep -q 'code27' "$NOTIFY_LOG" 2>/dev/null && grep -q 'no-exe' "$NOTIFY_LOG" 2>/dev/null && echo 1 || echo 0)"
else
  fail_case "core/connect/claude-code/prompt-answer.sh が実在（v1.2 束 B・未実装）"
fi

# verifier 1巡目 VB-03＝設計 §6（design-v1.md:349・plan-v1-impl.md §4）が FX-24 に必須指定した
# 5 ケース。fixture は増やさず（裁定 D-05・R2-04・R3-01）、この FX-24 のセットアップ
# （WT24＝zz-dest を足した worktree・HANG_STUB・T=2）をそのまま使い回す。

echo "--- FX-24 (i): 実在する送り手が非0で終わる＝記録 failed・他は届く ---"
WT24I="$WORK/wt-fx24i"
lf_copy_repo "$REPO_ROOT" "$WT24I"
lf_mk_fx11 "$WT24I" "$ZZDEST_FIXTURE"
chmod +x "$WT24I/notify/connect/zz-dest/deliver.sh"
FAILING_STUB="$WORK/failing-stub"; mkdir -p "$FAILING_STUB"
printf '#!/bin/bash\nexit 7\n' > "$FAILING_STUB/cmux"; chmod +x "$FAILING_STUB/cmux"   # 実在するが非0で終わる
printf '#!/bin/bash\nexit 0\n' > "$FAILING_STUB/osascript"; chmod +x "$FAILING_STUB/osascript"
printf '#!/bin/bash\nexit 0\n' > "$FAILING_STUB/launchctl"; chmod +x "$FAILING_STUB/launchctl"
FAILING_PATH="$FAILING_STUB:$(lf_path_without cmux osascript launchctl)"
ZZ24I="$WORK/zz24i.log"; rm -f "$ZZ24I"
rm -f "$NOTIFY_LOG"
rc=0
t0="$(mono_now)"
PATH="$FAILING_PATH" AIENV_LEDGER="$WT24I/core/data/ledger.tsv" AIENV_NOTIFY_WAIT_SECS="$T" ZZ_DEST_LOG="$ZZ24I" \
  bash "$WT24I/notify/executor/notify.sh" call ask "📣 テスト呼出" "本文" >/dev/null 2>&1 || rc=$?
t1="$(mono_now)"
assert_eq "(i): zz-dest へは届く（1行）" "1" "$(grep -c . "$ZZ24I" 2>/dev/null || true)"
assert_true "(i): 記録に cmux の failed が1行" "$(grep -q 'cmux' "$NOTIFY_LOG" 2>/dev/null && grep -q 'failed' "$NOTIFY_LOG" 2>/dev/null && echo 1 || echo 0)"
assert_eq "(i): 口の終了コードは0（1件以上届いた）" "0" "$rc"
assert_true "(i): 所要が T+1 秒以内（口は上限内で終わる）" "$(mono_le "$t0" "$t1" "$((T + 1))")"

echo "--- FX-24 (ii): 記録先へ追記できない＝入口は0のまま・stderrに1行・それでも配送は届く ---"
if [ -x "$PROMPT_ANSWER" ]; then
  BLOCKED_FILE="$WORK/blocked-notify-log"; : > "$BLOCKED_FILE"   # ディレクトリでなくファイル＝mkdir -p が必ず失敗
  BLOCKED_LOG="$BLOCKED_FILE/notify.tsv"
  II_CLEAR_LOG="$WORK/ii-clear.log"; rm -f "$II_CLEAR_LOG"   # ケース別初期化（応答＝CODE27 の配送の記録）
  json='{"session_id":"s1","prompt":"了解","hook_event_name":"UserPromptSubmit"}'
  rc=0
  t0="$(mono_now)"
  out="$(printf '%s' "$json" | CODE27_CALL_BIN="$CODE27_FAKE_BIN" CODE27_CALL_LOG="$II_CLEAR_LOG" \
    AIENV_LEDGER="$LEDGER_REAL" AIENV_NOTIFY_WAIT_SECS="$T" AIENV_NOTIFY_LOG="$BLOCKED_LOG" \
    bash "$PROMPT_ANSWER" 2>"$WORK/ii-stderr.log")" || rc=$?
  t1="$(mono_now)"
  assert_eq "(ii): 入口の終了コードは0のまま" "0" "$rc"
  assert_eq "(ii): 標準出力は空" "" "$out"
  assert_true "(ii): 2秒未満で終了" "$(mono_lt "$t0" "$t1" 2.0)"
  assert_eq "(ii): 入口の標準エラーに1行" "1" "$(grep -c . "$WORK/ii-stderr.log" 2>/dev/null || true)"
  sleep 1   # 口は切り離して起動される（記録不能でも配送は続く）＝応答先 CODE27 の到達を待つ
  assert_eq "(ii): 記録不能でも配送は届く（応答先 CODE27 が1回呼ばれる）" "1" "$(grep -c . "$II_CLEAR_LOG" 2>/dev/null || true)"
else
  fail_case "(ii): core/connect/claude-code/prompt-answer.sh が実在（v1.2 束 B・未実装）"
fi

echo "--- FX-24 (iii): 台帳に偽の第2応答先 zz-answer を足し、CODE27 の偽物（TERM無視・子持ち・応答しない） ---"
HANG_CODE27="$WORK/hang-code27.sh"
cat > "$HANG_CODE27" <<'EOF'
#!/bin/bash
trap '' TERM
( sleep 30 ) &
wait
EOF
chmod +x "$HANG_CODE27"
ZZANSWER_LOG="$WORK/zz-answer.log"; rm -f "$ZZANSWER_LOG"
ZZANSWER_DELIVER="$WORK/zz-answer-deliver.sh"
cat > "$ZZANSWER_DELIVER" <<EOF
#!/bin/bash
printf '%s\t%s\t%s\t%s\t%s\n' "\${1:-}" "\${2:-}" "\${3:-}" "\${4:-}" "\${5:-}" >> "$ZZANSWER_LOG"
exit 0
EOF
chmod +x "$ZZANSWER_DELIVER"
WT24III="$WORK/wt-fx24iii"
lf_copy_repo "$REPO_ROOT" "$WT24III"
mkdir -p "$WT24III/notify/connect/zz-answer"
cp "$ZZANSWER_DELIVER" "$WT24III/notify/connect/zz-answer/deliver.sh"
printf 'part\tnotify/connect/zz-answer/deliver.sh\tnotify\tconnect\tzz-answer\t-\t第2応答先（試験）\tanswer\t-\n' >> "$WT24III/core/data/ledger.tsv"
# ⚠️ AIENV_LEDGER の行の相対パスは、呼んだ ledger-tool.sh 自身の repo ルートから解決される
# （台帳ファイルの置き場からではない）。zz-answer は実体を $REPO_ROOT に持たない新規部品
# なので、この worktree 自身の prompt-answer.sh／notify.sh／ledger-tool.sh を呼ぶ
# （$REPO_ROOT 側の実行体を AIENV_LEDGER だけ差し替えて呼んでも zz-answer は解決できない）。
PROMPT_ANSWER_III="$WT24III/core/connect/claude-code/prompt-answer.sh"
NOTIFY_III="$WT24III/notify/executor/notify.sh"
if [ -x "$PROMPT_ANSWER_III" ]; then
  json='{"session_id":"s1","prompt":"了解","hook_event_name":"UserPromptSubmit"}'
  rc=0
  t0="$(mono_now)"
  out="$(printf '%s' "$json" | CODE27_CALL_BIN="$HANG_CODE27" AIENV_LEDGER="$WT24III/core/data/ledger.tsv" \
    AIENV_NOTIFY_WAIT_SECS="$T" ZZ_DEST_LOG="$WORK/unused-iii.log" \
    bash "$PROMPT_ANSWER_III" 2>"$WORK/iii-stderr.log")" || rc=$?
  t1="$(mono_now)"
  assert_eq "(iii): 入口の終了コードは0" "0" "$rc"
  assert_eq "(iii): 標準出力は空" "" "$out"
  assert_true "(iii): 入口は2秒未満で終了（切り離して即終了）" "$(mono_lt "$t0" "$t1" 2.0)"
  sleep "$((T + 2))"
  assert_true "(iii): T 後に CODE27 の timeout 記録が1行" \
    "$(grep -q 'code27' "$NOTIFY_LOG" 2>/dev/null && grep -q 'timeout' "$NOTIFY_LOG" 2>/dev/null && echo 1 || echo 0)"
  assert_eq "(iii): zz-answer へは配送される（1行）" "1" "$(grep -c . "$ZZANSWER_LOG" 2>/dev/null || true)"
  rc2=0
  AIENV_LEDGER="$WT24III/core/data/ledger.tsv" AIENV_NOTIFY_WAIT_SECS=1 CODE27_CALL_BIN="$HANG_CODE27" \
    "$NOTIFY_III" answer >/dev/null 2>&1 || rc2=$?
  assert_eq "(iii): 同じ台帳で口を直接「応答」で呼ぶと終了0（zz-answer が届くため）" "0" "$rc2"
else
  fail_case "(iii): core/connect/claude-code/prompt-answer.sh が実在（v1.2 束 B・未実装）"
fi

echo "--- FX-24 (iv): 空 HOME（.claude/logs/ 無し）に初回の異常記録＝親フォルダ作成・配送・時間（WT24 のセットアップを使い回す） ---"
FRESH_HOME="$WORK/fresh-home-iv"; mkdir -p "$FRESH_HOME"
assert_eq "(iv): 開始時点で .claude/logs は無い" "0" "$([ -d "$FRESH_HOME/.claude/logs" ] && echo 1 || echo 0)"
ZZ24IV="$WORK/zz24iv.log"; rm -f "$ZZ24IV"   # ケース別初期化
rc=0
t0="$(mono_now)"
HOME="$FRESH_HOME" PATH="$FX24_PATH" AIENV_LEDGER="$WT24/core/data/ledger.tsv" AIENV_NOTIFY_WAIT_SECS="$T" ZZ_DEST_LOG="$ZZ24IV" \
  bash "$WT24/notify/executor/notify.sh" call ask "初回異常" "本文" >/dev/null 2>&1 || rc=$?
t1="$(mono_now)"
assert_eq "(iv): 口の終了コードは0（応答しない cmux をよそに zz-dest へ届く）" "0" "$rc"
assert_true "(iv): 親フォルダ .claude/logs が作られる" "$([ -d "$FRESH_HOME/.claude/logs" ] && echo 1 || echo 0)"
assert_eq "(iv): 記録はちょうど1行（cmux の timeout）" "1" "$([ -f "$FRESH_HOME/.claude/logs/notify.tsv" ] && grep -c . "$FRESH_HOME/.claude/logs/notify.tsv" || echo 0)"
assert_true "(iv): その1行は cmux の timeout" \
  "$([ -f "$FRESH_HOME/.claude/logs/notify.tsv" ] && grep -q 'cmux' "$FRESH_HOME/.claude/logs/notify.tsv" && grep -q 'timeout' "$FRESH_HOME/.claude/logs/notify.tsv" && echo 1 || echo 0)"
assert_eq "(iv): zz-dest へ配送される（1行）" "1" "$(grep -c . "$ZZ24IV" 2>/dev/null || true)"
assert_true "(iv): 所要が T+1 秒以内" "$(mono_le "$t0" "$t1" "$((T + 1))")"

echo "--- FX-24 (v): (ii)+(iii) の複合＝記録不能と応答先 timeout が重なる→入口0・stderrに1行・それでも配送（zz-answer） ---"
if [ -x "$PROMPT_ANSWER_III" ]; then
  BLOCKED_FILE_V="$WORK/blocked-notify-log-v"; : > "$BLOCKED_FILE_V"
  BLOCKED_LOG_V="$BLOCKED_FILE_V/notify.tsv"
  rm -f "$ZZANSWER_LOG"   # (v) はケース別に初期化（(iii) の記録を引き継がない）
  json='{"session_id":"s1","prompt":"了解","hook_event_name":"UserPromptSubmit"}'
  rc=0
  t0="$(mono_now)"
  out="$(printf '%s' "$json" | CODE27_CALL_BIN="$HANG_CODE27" AIENV_LEDGER="$WT24III/core/data/ledger.tsv" \
    AIENV_NOTIFY_WAIT_SECS="$T" AIENV_NOTIFY_LOG="$BLOCKED_LOG_V" \
    bash "$PROMPT_ANSWER_III" 2>"$WORK/v-stderr.log")" || rc=$?
  t1="$(mono_now)"
  assert_eq "(v): 入口の終了コードは0のまま" "0" "$rc"
  assert_eq "(v): 標準出力は空" "" "$out"
  assert_true "(v): 入口は2秒未満で終了（記録不能は同期確保の段で分かる）" "$(mono_lt "$t0" "$t1" 2.0)"
  assert_eq "(v): 記録不能と応答先timeoutが重なっても無観測にならない（stderrに1行）" "1" \
    "$(grep -c . "$WORK/v-stderr.log" 2>/dev/null || true)"
  sleep "$((T + 2))"
  assert_eq "(v): それでも zz-answer へ配送される（1行・ケース別初期化後の増分）" "1" \
    "$(grep -c . "$ZZANSWER_LOG" 2>/dev/null || true)"
else
  fail_case "(v): core/connect/claude-code/prompt-answer.sh が実在（v1.2 束 B・未実装）"
fi

echo "=== 記録の符号化（改行・TAB・\\ 入りの題が1行で残る） ==="
rm -f "$NOTIFY_LOG"
WEIRD_TITLE=$'題1\n題2\tTAB入り\\バックスラッシュ'   # 実改行・実TAB・リテラル1個のバックスラッシュを含む
NODEST_LEDGER2="$WORK/fx-encode-ledger.tsv"
awk -F'\t' '!/^#/ { if ($1=="part" && $4=="connect" && $3=="notify") next } { print }' "$LEDGER_REAL" > "$NODEST_LEDGER2"
AIENV_LEDGER="$NODEST_LEDGER2" "$NOTIFY" call ask "$WEIRD_TITLE" "本文" >/dev/null 2>&1 || true
assert_eq "記録は1行のまま（実改行を含まない）" "1" "$([ -f "$NOTIFY_LOG" ] && wc -l < "$NOTIFY_LOG" | tr -d ' ' || echo 0)"
EXPECT_ENCODED=$'題1\\n題2\\tTAB入り\\\\バックスラッシュ'   # 符号化の順＝\→\\・改行→\n・TAB→\t（設計§4）
assert_true "符号化後の文字列（\\n・\\t・\\\\）が1行に残る" \
  "$(grep -qF "$EXPECT_ENCODED" "$NOTIFY_LOG" 2>/dev/null && echo 1 || echo 0)"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
