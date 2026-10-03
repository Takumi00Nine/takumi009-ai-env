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
"$NOTIFY" call ask "📣 テスト呼出" "本文" >/dev/null 2>&1 || rc=$?
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
"$NOTIFY" call ask "呼出タイトル" "呼出本文" >/dev/null 2>&1 || rc=$?
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
  printf 'part\tnotify/connect/zz-missing/deliver.sh\tnotify\tconnect\tzz-missing\t-\t試験\tcall.ask\n'
} > "$BADROUTE_LEDGER"
rc=0
ROUTE_OUT3="$(AIENV_LEDGER="$BADROUTE_LEDGER" "$LEDGER_TOOL" route call.ask 2>"$WORK/route3.err")"; rc=$?
assert_eq "route 一部実体異常: 実在する cmux の行は残るので exit 0" "0" "$rc"
assert_eq "route 一部実体異常: 存在しない送り手は除かれる" "0" "$(printf '%s' "$ROUTE_OUT3" | grep -c 'zz-missing' || true)"
assert_true "route 一部実体異常: stderr に固定文 LEDGER: part" "$(grep -q 'LEDGER: part' "$WORK/route3.err" 2>/dev/null && echo 1 || echo 0)"
ALLBAD_LEDGER="$WORK/allbad-ledger.tsv"
printf 'part\tnotify/connect/zz-missing/deliver.sh\tnotify\tconnect\tzz-missing\t-\t試験\tcall.ask\n' > "$ALLBAD_LEDGER"
rc=0
AIENV_LEDGER="$ALLBAD_LEDGER" "$LEDGER_TOOL" route call.ask >/dev/null 2>"$WORK/route4.err" || rc=$?
assert_eq "route 全件実体異常: exit 3" "3" "$rc"

echo "=== FX-11 ZZD（第 4 の届け先・移動表なし）: 式 A・zz-dest への到達・台帳検査 ==="
WT="$WORK/wt-fx11"
lf_copy_repo "$REPO_ROOT" "$WT"
mkdir -p "$WT/notify/connect/zz-dest"
cp "$ZZDEST_FIXTURE" "$WT/notify/connect/zz-dest/deliver.sh"
chmod +x "$WT/notify/connect/zz-dest/deliver.sh"
printf 'part\tnotify/connect/zz-dest/deliver.sh\tnotify\tconnect\tzz-dest\t-\t第4の届け先（試験）\tcall\n' >> "$WT/core/data/ledger.tsv"

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
mkdir -p "$WT17/notify/connect/zz-dest"
cp "$ZZDEST_FIXTURE" "$WT17/notify/connect/zz-dest/deliver.sh"
printf 'part\tnotify/connect/zz-dest/deliver.sh\tnotify\tconnect\tzz-dest\t-\t第4の届け先（試験）\tcall\n' >> "$WT17/core/data/ledger.tsv"
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
WT24="$WORK/wt-fx24"
lf_copy_repo "$REPO_ROOT" "$WT24"
mkdir -p "$WT24/notify/connect/zz-dest"
cp "$ZZDEST_FIXTURE" "$WT24/notify/connect/zz-dest/deliver.sh"
chmod +x "$WT24/notify/connect/zz-dest/deliver.sh"
printf 'part\tnotify/connect/zz-dest/deliver.sh\tnotify\tconnect\tzz-dest\t-\t第4の届け先（試験）\tcall\n' >> "$WT24/core/data/ledger.tsv"

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
start="$(date +%s)"
PATH="$FX24_PATH" \
  AIENV_LEDGER="$WT24/core/data/ledger.tsv" AIENV_NOTIFY_WAIT_SECS="$T" ZZ_DEST_LOG="$ZZ24" \
  bash "$WT24/notify/executor/notify.sh" call ask "📣 テスト呼出" "本文" >/dev/null 2>&1 || rc=$?
end="$(date +%s)"
dur=$((end - start))
assert_true "FX-24: 所要が T+1 秒以内（T=${T}・実測 ${dur}s）" "$([ "$dur" -le $((T + 1)) ] && echo 1 || echo 0)"
assert_eq "FX-24: zz-dest の記録に1行（応答しない cmux をよそに届く）" "1" "$(grep -c . "$ZZ24" 2>/dev/null || true)"
assert_true "FX-24: 記録に cmux の応答なし（timeout）が1行" "$(grep -q 'cmux' "$NOTIFY_LOG" 2>/dev/null && grep -q 'timeout' "$NOTIFY_LOG" 2>/dev/null && echo 1 || echo 0)"

echo "--- FX-24 続き: CODE27 の実行体欠落（UserPromptSubmit 入口経由） ---"
PROMPT_ANSWER="$REPO_ROOT/core/connect/claude-code/prompt-answer.sh"
if [ -x "$PROMPT_ANSWER" ]; then
  rm -f "$NOTIFY_LOG"
  json='{"session_id":"s1","prompt":"了解","hook_event_name":"UserPromptSubmit"}'
  rc=0
  start="$(date +%s)"
  out="$(printf '%s' "$json" | CODE27_CALL_BIN="$WORK/no-such-code27" AIENV_LEDGER="$LEDGER_REAL" AIENV_NOTIFY_WAIT_SECS="$T" \
    bash "$PROMPT_ANSWER" 2>"$WORK/prompt.err")" || rc=$?
  end="$(date +%s)"
  assert_eq "入口: 終了コード0" "0" "$rc"
  assert_eq "入口: 標準出力は空" "" "$out"
  assert_true "入口: 2秒未満で終了" "$([ $((end - start)) -le 2 ] && echo 1 || echo 0)"
  sleep 1
  assert_true "記録に CODE27（実行体なし）が1行" "$(grep -q 'code27' "$NOTIFY_LOG" 2>/dev/null && grep -q 'no-exe' "$NOTIFY_LOG" 2>/dev/null && echo 1 || echo 0)"
else
  fail_case "core/connect/claude-code/prompt-answer.sh が実在（v1.2 束 B・未実装）"
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
