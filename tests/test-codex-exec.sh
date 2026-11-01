#!/usr/bin/env bash
# team/connect/codex/codex-exec.sh のユニットテスト。
#
# 実 codex コマンドには依存しない。モックの `codex`（PATH前置）を使って、
# 引数の組み立て（--search のグローバル位置・resume の `--` 区切り・-c の値の
# 組み立て方）・職種と必読指示・起動前の拒否・
# stdout 3行契約・events/stderr の保存先・依頼文の受け渡し方式（argvではなく
# stdin経由・positionalは常に`-`）を検証する
# （2026-09-06 codex exec 一本化・[[Preferences/codex-exec-worker]]。
# 2026-09-06 Codex一次レビュー指摘対応＝argv経由のプロンプト受け渡しの
# ハイフン誤解釈・ARG_MAX対策、developer_instructionsのTOML誤解釈対策）。
#
# 画像受け渡し（--image）の公式根拠: https://developers.openai.com/codex/cli/reference の `codex exec` と
# `codex exec resume` の両表に `--image, -i  path[,path...]`（繰り返し可）があり、resume でも -i を受け付ける（2026-10-10 確認）。
#
# 実行方法: bash tests/test-codex-exec.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/team/connect/codex/codex-exec.sh"

PASS=0
FAIL=0
PREFS_WORK="$(mktemp -d)"
export AIENV_PREFERENCES_DIR="$PREFS_WORK"
printf '%s\n' '試験用職種ノート' > "$PREFS_WORK/worker-role-implementer.md"
PREFIX="着手前に $PREFS_WORK/absolute-rules.md・$PREFS_WORK/core-worker.md・$PREFS_WORK/worker-role-implementer.md を全文読み、従う。"

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

# モックの codex コマンドを作る。呼ばれた引数を1行ずつ（改行区切りで各引数）
# $2 のログファイルへ記録し、標準入力（本スクリプトが依頼文をパイプする経路）
# を $4（省略時 /dev/null）へそのまま保存したうえで、--json の最小イベント
# （thread.started）を標準出力へ吐いて exit 0 する。$3 に thread_id を指定
# できる（省略時 mock-thread-1）。
make_mock_codex() {
  local bindir="$1" log="$2" thread_id="${3:-mock-thread-1}" stdin_log="${4:-/dev/null}"
  mkdir -p "$bindir"
  cat > "$bindir/codex" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do printf '%s\n' "\$a" >> "$log"; done
printf '%s\n' '===ARGS-END===' >> "$log"
cat > "$stdin_log"
echo '{"type":"thread.started","thread_id":"$thread_id"}'
echo '{"type":"turn.completed"}'
exit 0
EOF
  chmod +x "$bindir/codex"
}

echo "=== 1. 基本呼び出し: 引数の組み立て・依頼文はstdin経由・positionalは'-'・stdout 3行・events/stderrの保存先 ==="
{
  WORK="$(mktemp -d)"
  BINDIR="$WORK/bin"
  LOG="$WORK/calls.log"
  STDIN_LOG="$WORK/stdin.log"
  : > "$LOG"
  make_mock_codex "$BINDIR" "$LOG" "thread-abc" "$STDIN_LOG"
  OUT="$WORK/out.md"

  stdout_out="$(PATH="$BINDIR:$PATH" bash "$SCRIPT" --role implementer --cwd "$WORK" --sandbox read-only --out "$OUT" --prompt-file - <<< "absolute-rules を読んでhello" 2>"$WORK/stderr-of-script.log")"
  rc=$?
  if [ "$rc" -eq 0 ] && grep -qx -- '--json' "$LOG" \
     && { grep -A1 -- '^-s$' "$LOG" | grep -qx read-only; } \
     && { grep -A1 -- '^-C$' "$LOG" | grep -qx "$WORK"; } \
     && { grep -A1 -- '^-o$' "$LOG" | grep -qx "$OUT"; }; then
    pass "通常起動の引数・sandbox"
  else
    fail_case "通常起動の引数・sandbox"
  fi
  assert_eq "新規起動では必読指示と空行を依頼文の先頭に付ける" \
    "$PREFIX"$'\n\n'"absolute-rules を読んでhello" \
    "$(cat "$STDIN_LOG")"
  assert_true "依頼文はstdin・成果物はevents/stderr" \
    "$(! grep -q 'absolute-rules' "$LOG" \
       && printf '%s\n' "$stdout_out" | grep -q '^THREAD_ID:' \
       && printf '%s\n' "$stdout_out" | grep -q '^OUT:' \
       && printf '%s\n' "$stdout_out" | grep -q '^EXIT:0$' \
       && grep -q 'thread.started' "$OUT.events.jsonl" \
       && [ -f "$OUT.stderr.log" ] && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 2. absolute-rules 参照なし・相対パスでも起動する ==="
{
  WORK="$(mktemp -d)"
  BINDIR="$WORK/bin"
  LOG="$WORK/calls.log"
  : > "$LOG"
  make_mock_codex "$BINDIR" "$LOG"
  OUT="$WORK/out.md"

  rc=0
  out=$(cd "$WORK" && PATH="$BINDIR:$PATH" bash "$SCRIPT" --role implementer --cwd bin --sandbox danger-full-access --out relative/out.md --prompt-file - <<< "こんにちは、何かして" 2>&1) || rc=$?
  assert_eq "参照なしでも成功する" "0" "$rc"
  assert_true "cwd・outを呼出元基準の絶対パスで渡す" \
    "$(grep -A1 -- '^-C$' "$LOG" | grep -qx "$WORK/bin" && grep -A1 -- '^-o$' "$LOG" | grep -qx "$WORK/relative/out.md" && echo 1 || echo 0)"
  rm -rf "$WORK"
}

echo "=== 3. --resume: 引数順（共通オプションの後ろ・resume -- <id> - の順） ==="
{
  WORK="$(mktemp -d)"
  BINDIR="$WORK/bin"
  LOG="$WORK/calls.log"
  STDIN_LOG="$WORK/stdin.log"
  : > "$LOG"
  make_mock_codex "$BINDIR" "$LOG" "resumed-thread" "$STDIN_LOG"
  OUT="$WORK/out2.md"

  rc=0
  PATH="$BINDIR:$PATH" bash "$SCRIPT" --role implementer --cwd "$WORK" --sandbox workspace-write --out "$OUT" \
    --prompt-file - --resume "thread-xyz-123" <<< "続きをやって" >/dev/null 2>"$WORK/stderr.log" || rc=$?
  args_before_end=$(sed -n '1,/ARGS-END/p' "$LOG" | grep -v 'ARGS-END')
  n=$(printf '%s\n' "$args_before_end" | wc -l | tr -d ' ')
  last_line=$(printf '%s\n' "$args_before_end" | sed -n "${n}p")
  resume_id_line=$(printf '%s\n' "$args_before_end" | sed -n "$((n-1))p")
  dashdash_line=$(printf '%s\n' "$args_before_end" | sed -n "$((n-2))p")
  resume_kw_line=$(printf '%s\n' "$args_before_end" | sed -n "$((n-3))p")

  assert_true "resumeはオプション終端後のIDとstdinを渡す" \
    "$([ "$rc" -eq 0 ] && [ "$last_line" = - ] && [ "$resume_id_line" = thread-xyz-123 ] \
       && [ "$dashdash_line" = -- ] && [ "$resume_kw_line" = resume ] && echo 1 || echo 0)"
  assert_eq "--resume でも先頭に3ノートの必読指示を付ける" \
    "$PREFIX"$'\n\n'"続きをやって" "$(cat "$STDIN_LOG")"

  rm -rf "$WORK"
}

echo "=== 4. 職種なし・未知の職種・職種ノート欠落／空は起動しない ==="
{
  WORK="$(mktemp -d)"
  BINDIR="$WORK/bin"
  LOG="$WORK/calls.log"
  : > "$LOG"
  make_mock_codex "$BINDIR" "$LOG"
  for mode in missing-role unknown-role missing-note empty-note; do
    role_args=(--role implementer)
    prefs="$PREFS_WORK"
    case "$mode" in
      missing-role) role_args=() ;;
      unknown-role) role_args=(--role unknown-role) ;;
      missing-note) prefs="$WORK/missing" ;;
      empty-note)
        prefs="$WORK/empty"
        mkdir -p "$prefs"
        : > "$prefs/worker-role-implementer.md" ;;
    esac
    rc=0
    AIENV_PREFERENCES_DIR="$prefs" PATH="$BINDIR:$PATH" bash "$SCRIPT" ${role_args[@]+"${role_args[@]}"} \
      --cwd "$WORK" --sandbox danger-full-access --out "$WORK/out.md" --prompt-file - \
      <<< "依頼" >/dev/null 2>&1 || rc=$?
    assert_true "$mode: CLIを起動しない" \
      "$([ "$rc" -ne 0 ] && [ ! -s "$LOG" ] && echo 1 || echo 0)"
  done
}

echo "=== 7. --model / --effort: -m と -c model_reasoning_effort= に変換される ==="
{
  WORK="$(mktemp -d)"
  BINDIR="$WORK/bin"
  LOG="$WORK/calls.log"
  : > "$LOG"
  make_mock_codex "$BINDIR" "$LOG"
  OUT="$WORK/out6.md"

  PATH="$BINDIR:$PATH" bash "$SCRIPT" --role implementer --cwd "$WORK" --sandbox read-only --out "$OUT" \
    --prompt-file - --model t-model-x --effort high <<< "absolute-rules を読んでやって" >/dev/null 2>&1

  assert_true "-m t-model-x が渡る" \
    "$(grep -A1 -- '^-m$' "$LOG" | grep -qx 't-model-x' && echo 1 || echo 0)"
  assert_true "-c model_reasoning_effort=high が渡る" \
    "$(grep -qx 'model_reasoning_effort=high' "$LOG" && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 12. codex 本体が非0で終了したら、その終了コードをそのまま返す ==="
{
  WORK="$(mktemp -d)"
  BINDIR="$WORK/bin"
  mkdir -p "$BINDIR"
  cat > "$BINDIR/codex" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo "Error: something failed" >&2
exit 7
EOF
  chmod +x "$BINDIR/codex"
  OUT="$WORK/out7.md"

  rc=0
  stdout_out=$(PATH="$BINDIR:$PATH" bash "$SCRIPT" --role implementer --cwd "$WORK" --sandbox read-only --out "$OUT" --prompt-file - <<< "absolute-rules テスト" 2>"$WORK/stderr.log") || rc=$?
  assert_eq "codexのexit codeがそのまま返る" "7" "$rc"
  assert_true "EXIT:7 がstdoutに出る" \
    "$(printf '%s\n' "$stdout_out" | grep -qx 'EXIT:7' && echo 1 || echo 0)"
  assert_true "stderrがout.stderr.logに保存される" \
    "$(grep -q 'something failed' "$OUT.stderr.log" && echo 1 || echo 0)"

  rm -rf "$WORK"
}
echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
