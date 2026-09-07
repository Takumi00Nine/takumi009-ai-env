#!/usr/bin/env bash
# scripts/codex-exec.sh のユニットテスト。
#
# 実 codex コマンドには依存しない。モックの `codex`（PATH前置）を使って、
# 引数の組み立て（--search のグローバル位置・resume の `--` 区切り・-c の値の
# 組み立て方）・absolute-rules 欠落時の exit 2（codex を起動しないこと含む）・
# stdout 3行契約・events/stderr の保存先・依頼文の受け渡し方式（argvではなく
# stdin経由・positionalは常に`-`）を検証する
# （2026-09-06 codex exec 一本化・[[Preferences/codex-exec-worker]]。
# 2026-09-06 Codex一次レビュー指摘対応＝argv経由のプロンプト受け渡しの
# ハイフン誤解釈・ARG_MAX対策、developer_instructionsのTOML誤解釈対策）。
#
# 実行方法: bash tests/test-codex-exec.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/codex-exec.sh"

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

# jqを含まない最小PATHディレクトリを作る（--developer-instructionsの
# python3フォールバック経路を強制的に通すため。Codex一次レビュー指摘・
# 2巡目Minor＝jqが常在する開発機ではpython3経路が一度も実行されず、
# ensure_ascii関連の不具合を検出できなかった対策）。macOS標準の絶対パス
# （/usr/bin, /bin）を直接指定する＝`command -v` 経由の解決は使わない
# （このリポジトリの開発機ではgrep等がClaude Code独自のシェル関数で
# シャドーされることがあり、`command -v grep`が絶対パスを返さない場合が
# ある。またpython3はpyenv経由のshimであることが多く、shim自体を
# symlinkしても内部でpyenvコマンド解決に失敗するため、実体の
# インタプリタパスを`sys.executable`で解決してからsymlinkする）。
build_path_without_jq() {
  local dir="$1"
  mkdir -p "$dir"
  local sys_tool
  for sys_tool in /bin/bash /bin/sh /usr/bin/grep /usr/bin/sed /bin/cat /bin/mkdir \
                  /usr/bin/dirname /usr/bin/basename /usr/bin/mktemp /bin/chmod \
                  /usr/bin/wc /usr/bin/cut /bin/rm /usr/bin/tr /usr/bin/head /usr/bin/uname; do
    [ -x "$sys_tool" ] && ln -sf "$sys_tool" "$dir/$(basename "$sys_tool")" 2>/dev/null
  done
  local real_python3
  real_python3="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)"
  if [ -n "$real_python3" ] && [ -x "$real_python3" ]; then
    ln -sf "$real_python3" "$dir/python3" 2>/dev/null
  fi
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

  stdout_out="$(PATH="$BINDIR:$PATH" bash "$SCRIPT" --cwd "$WORK" --sandbox read-only --out "$OUT" --prompt-file - <<< "absolute-rules を読んでhello" 2>"$WORK/stderr-of-script.log")"
  rc=$?
  assert_eq "exit code 0" "0" "$rc"
  assert_true "stdoutがちょうど3行" \
    "$([ "$(printf '%s\n' "$stdout_out" | wc -l | tr -d ' ')" = "3" ] && echo 1 || echo 0)"
  assert_true "THREAD_ID行がある" \
    "$(printf '%s\n' "$stdout_out" | grep -qx 'THREAD_ID:thread-abc' && echo 1 || echo 0)"
  assert_true "OUT行がある" \
    "$(printf '%s\n' "$stdout_out" | grep -qx "OUT:$OUT" && echo 1 || echo 0)"
  assert_true "EXIT行がある" \
    "$(printf '%s\n' "$stdout_out" | grep -qx 'EXIT:0' && echo 1 || echo 0)"

  assert_true "--skip-git-repo-check が渡る" \
    "$(grep -qx -- '--skip-git-repo-check' "$LOG" && echo 1 || echo 0)"
  assert_true "-s read-only が渡る" \
    "$(grep -A1 -- '^-s$' "$LOG" | grep -qx 'read-only' && echo 1 || echo 0)"
  assert_true "-C <cwd> が渡る" \
    "$(grep -A1 -- '^-C$' "$LOG" | grep -qx "$WORK" && echo 1 || echo 0)"
  assert_true "--json が渡る" \
    "$(grep -qx -- '--json' "$LOG" && echo 1 || echo 0)"
  assert_true "-o <out> が渡る" \
    "$(grep -A1 -- '^-o$' "$LOG" | grep -qx "$OUT" && echo 1 || echo 0)"
  assert_true "最後の引数は依頼文そのものではなく '-'（stdinから読む指示）" \
    "$(args=$(sed -n '1,/ARGS-END/p' "$LOG" | grep -v 'ARGS-END'); n=$(printf '%s\n' "$args" | wc -l | tr -d ' '); [ "$(printf '%s\n' "$args" | sed -n "${n}p")" = "-" ] && echo 1 || echo 0)"
  assert_true "依頼文はargvではなくstdin経由でcodexへ渡る" \
    "$([ "$(cat "$STDIN_LOG")" = "absolute-rules を読んでhello" ] && echo 1 || echo 0)"
  assert_true "依頼文の文字列自体はargvのどこにも出現しない（ARG_MAX/誤解釈対策の確認）" \
    "$(grep -qx 'absolute-rules を読んでhello' "$LOG" && echo 0 || echo 1)"

  assert_true "events.jsonl が <out>.events.jsonl に保存される" \
    "$([ -f "$OUT.events.jsonl" ] && grep -q 'thread.started' "$OUT.events.jsonl" && echo 1 || echo 0)"
  assert_true "stderr が <out>.stderr.log に保存される（空ファイルでも存在すればよい）" \
    "$([ -f "$OUT.stderr.log" ] && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 2. absolute-rules への参照が無い依頼文 → exit 2・codexを起動しない ==="
{
  WORK="$(mktemp -d)"
  BINDIR="$WORK/bin"
  LOG="$WORK/calls.log"
  : > "$LOG"
  make_mock_codex "$BINDIR" "$LOG"
  OUT="$WORK/out.md"

  rc=0
  out=$(PATH="$BINDIR:$PATH" bash "$SCRIPT" --cwd "$WORK" --sandbox read-only --out "$OUT" --prompt-file - <<< "こんにちは、何かして" 2>&1) || rc=$?
  assert_eq "exit code 2" "2" "$rc"
  assert_true "codexは一度も呼ばれていない（ログが空）" \
    "$([ ! -s "$LOG" ] && echo 1 || echo 0)"
  assert_true "absolute-rulesという語を含むエラーメッセージが出る" \
    "$(echo "$out" | grep -q 'absolute-rules' && echo 1 || echo 0)"

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
  PATH="$BINDIR:$PATH" bash "$SCRIPT" --cwd "$WORK" --sandbox workspace-write --out "$OUT" \
    --prompt-file - --resume "thread-xyz-123" <<< "absolute-rules を読んで続きをやって" >/dev/null 2>"$WORK/stderr.log" || rc=$?
  assert_eq "exit code 0" "0" "$rc"

  # ARGS-END の手前が末尾のpositional（依頼文の代わりの'-'）、その手前が
  # resumeのthread_id、さらに手前が"--"区切り、さらに手前が"resume"サブ
  # コマンドであること（共通オプションより後ろに置かれていること）を、
  # 行番号の相対関係で確認する。
  args_before_end=$(sed -n '1,/ARGS-END/p' "$LOG" | grep -v 'ARGS-END')
  n=$(printf '%s\n' "$args_before_end" | wc -l | tr -d ' ')
  last_line=$(printf '%s\n' "$args_before_end" | sed -n "${n}p")
  resume_id_line=$(printf '%s\n' "$args_before_end" | sed -n "$((n-1))p")
  dashdash_line=$(printf '%s\n' "$args_before_end" | sed -n "$((n-2))p")
  resume_kw_line=$(printf '%s\n' "$args_before_end" | sed -n "$((n-3))p")

  assert_eq "最後のpositionalは '-'（stdinから読む指示）" "-" "$last_line"
  assert_eq "その直前がresumeのthread_id" "thread-xyz-123" "$resume_id_line"
  assert_eq "さらにその直前が '--' 区切り" "--" "$dashdash_line"
  assert_eq "さらにその直前が resume というサブコマンド" "resume" "$resume_kw_line"
  assert_true "続きの依頼文はargvではなくstdin経由でcodexへ渡る" \
    "$([ "$(cat "$STDIN_LOG")" = "absolute-rules を読んで続きをやって" ] && echo 1 || echo 0)"
  cline=$(grep -n -- '^-C$' "$LOG" | head -1 | cut -d: -f1)
  rline=$(grep -n -- '^resume$' "$LOG" | head -1 | cut -d: -f1)
  assert_true "-C は resume より前に渡っている（共通オプションが前）" \
    "$([ -n "$cline" ] && [ -n "$rline" ] && [ "$cline" -lt "$rline" ] && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 4. --resume でも absolute-rules 検査は省略されない ==="
{
  WORK="$(mktemp -d)"
  BINDIR="$WORK/bin"
  LOG="$WORK/calls.log"
  : > "$LOG"
  make_mock_codex "$BINDIR" "$LOG"
  OUT="$WORK/out3.md"

  rc=0
  PATH="$BINDIR:$PATH" bash "$SCRIPT" --cwd "$WORK" --sandbox read-only --out "$OUT" \
    --prompt-file - --resume "thread-xyz" <<< "続きをやってください、よろしく" >/dev/null 2>&1 || rc=$?
  assert_eq "exit code 2（resumeでも検査が効く）" "2" "$rc"
  assert_true "codexは呼ばれていない" \
    "$([ ! -s "$LOG" ] && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 5. --search はグローバル位置（exec より前）に渡る ==="
{
  WORK="$(mktemp -d)"
  BINDIR="$WORK/bin"
  LOG="$WORK/calls.log"
  : > "$LOG"
  make_mock_codex "$BINDIR" "$LOG"
  OUT="$WORK/out4.md"

  PATH="$BINDIR:$PATH" bash "$SCRIPT" --cwd "$WORK" --sandbox read-only --out "$OUT" \
    --prompt-file - --search <<< "absolute-rules を読んで調べて" >/dev/null 2>&1

  search_line=$(grep -n -- '^--search$' "$LOG" | head -1 | cut -d: -f1)
  exec_line=$(grep -n -- '^exec$' "$LOG" | head -1 | cut -d: -f1)
  assert_true "--search が渡っている" "$([ -n "$search_line" ] && echo 1 || echo 0)"
  # このmock codexは "exec" 自体を引数として受け取らない（`codex ... exec ...`の
  # "exec" はmockスクリプト自身の起動名ではなく$@の1要素として渡る）ため、
  # --search が exec より前に来ていることを確認する。
  assert_true "--search が exec より前（グローバル位置）" \
    "$([ -n "$search_line" ] && [ -n "$exec_line" ] && [ "$search_line" -lt "$exec_line" ] && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 6. --developer-instructions（jq経路）: -c developer_instructions=<TOML文字列エンコード済み> が渡る ==="
{
  if ! command -v jq >/dev/null 2>&1; then
    echo "  skip - jqがこの環境に無いため、jq経路のテストをスキップ"
  else
  WORK="$(mktemp -d)"
  BINDIR="$WORK/bin"
  LOG="$WORK/calls.log"
  : > "$LOG"
  make_mock_codex "$BINDIR" "$LOG"
  OUT="$WORK/out5.md"
  DEV="$WORK/dev-instr.txt"
  printf 'これは職種定義の本文（1行目）' > "$DEV"

  PATH="$BINDIR:$PATH" bash "$SCRIPT" --cwd "$WORK" --sandbox read-only --out "$OUT" \
    --prompt-file - --developer-instructions "$DEV" <<< "absolute-rules を読んで実装して" >/dev/null 2>&1

  # 生の "developer_instructions=これは..." ではなく、TOML基本文字列として
  # ダブルクォートで囲まれた（jq -Rs でエンコードされた）値になっている
  # ことを確認する（Codex一次レビュー指摘・Major対応）。
  raw_line=$(grep -x 'developer_instructions=これは職種定義の本文（1行目）' "$LOG" || true)
  assert_true "生の未エンコード文字列としては渡らない" \
    "$([ -z "$raw_line" ] && echo 1 || echo 0)"
  encoded_line=$(grep '^developer_instructions=' "$LOG" || true)
  assert_true "developer_instructions= の値がダブルクォートで囲まれたTOML/JSON文字列になっている" \
    "$(printf '%s' "$encoded_line" | grep -qE '^developer_instructions="' && echo 1 || echo 0)"
  decoded=$(printf '%s' "$encoded_line" | sed -e 's/^developer_instructions=//' | jq -r .)
  assert_eq "エンコードされた値をjqでデコードすると元の内容に戻る" \
    "これは職種定義の本文（1行目）" "$decoded"

  rm -rf "$WORK"
  fi
}

echo "=== 6b. --developer-instructions（jq経路）: 内容がTOML配列に見えるテキストでも文字列として渡る ==="
{
  if ! command -v jq >/dev/null 2>&1; then
    echo "  skip - jqがこの環境に無いため、jq経路のテストをスキップ"
  else
  WORK="$(mktemp -d)"
  BINDIR="$WORK/bin"
  LOG="$WORK/calls.log"
  : > "$LOG"
  make_mock_codex "$BINDIR" "$LOG"
  OUT="$WORK/out5b.md"
  DEV="$WORK/dev-instr-arraylike.txt"
  printf '["これはTOML配列に見えるテキストです", "実際は文字列として扱われるべき"]' > "$DEV"

  rc=0
  PATH="$BINDIR:$PATH" bash "$SCRIPT" --cwd "$WORK" --sandbox read-only --out "$OUT" \
    --prompt-file - --developer-instructions "$DEV" <<< "absolute-rules を読んで実装して" >/dev/null 2>&1 || rc=$?
  assert_eq "スクリプト自体は正常終了する" "0" "$rc"

  encoded_line=$(grep '^developer_instructions=' "$LOG" || true)
  assert_true "TOML配列の生の丸括弧ではなく、二重にエンコードされたJSON文字列になっている" \
    "$(printf '%s' "$encoded_line" | grep -qE '^developer_instructions="\[' && echo 1 || echo 0)"
  decoded=$(printf '%s' "$encoded_line" | sed -e 's/^developer_instructions=//' | python3 -c 'import json,sys; print(json.load(sys.stdin))')
  assert_eq "デコードすると元のテキストがそのまま復元できる（配列としては解釈されない）" \
    '["これはTOML配列に見えるテキストです", "実際は文字列として扱われるべき"]' "$decoded"

  rm -rf "$WORK"
  fi
}

echo "=== 6c. --developer-instructions（python3フォールバック経路）: jq不在でも絵文字・改行・引用符が壊れず復元できる ==="
{
  if ! command -v python3 >/dev/null 2>&1; then
    echo "  skip - python3がこの環境に無いため、python3経路のテストをスキップ"
  else
  WORK="$(mktemp -d)"
  BINDIR="$WORK/bin"
  LOG="$WORK/calls.log"
  : > "$LOG"
  make_mock_codex "$BINDIR" "$LOG"
  OUT="$WORK/out5c.md"
  DEV="$WORK/dev-instr-emoji.txt"
  # 絵文字（BMP外文字）・改行・ダブルクォート・バックスラッシュを含む内容。
  # Codex一次レビュー指摘・2巡目Major＝python3側でensure_ascii=Falseに
  # していないと、絵文字がUTF-16サロゲートペアへエスケープされ、TOMLの
  # Unicodeエスケープはサロゲート単体を許さないため解析に失敗しうる。
  printf '1行目 😀 絵文字\n2行目 "引用符" と \\バックスラッシュ' > "$DEV"

  # jqを含まない最小PATHを作り、python3フォールバック経路を強制する。
  NOJQDIR="$WORK/nojq"
  build_path_without_jq "$NOJQDIR"
  PATH="$BINDIR:$NOJQDIR" command -v jq >/dev/null 2>&1 && fail_case "テスト前提が崩れている: 制限PATH下でjqが見つかってしまう"

  rc=0
  PATH="$BINDIR:$NOJQDIR" bash "$SCRIPT" --cwd "$WORK" --sandbox read-only --out "$OUT" \
    --prompt-file - --developer-instructions "$DEV" <<< "absolute-rules を読んで実装して" >/dev/null 2>&1 || rc=$?
  assert_eq "python3経路でも正常終了する" "0" "$rc"

  encoded_line=$(grep '^developer_instructions=' "$LOG" || true)
  decoded=$(printf '%s' "$encoded_line" | sed -e 's/^developer_instructions=//' | python3 -c 'import json,sys; print(json.load(sys.stdin), end="")')
  expected="$(cat "$DEV")"
  assert_eq "絵文字・改行・引用符・バックスラッシュを含む内容がそのまま復元できる" \
    "$expected" "$decoded"

  rm -rf "$WORK"
  fi
}

echo "=== 7. --model / --effort: -m と -c model_reasoning_effort= に変換される ==="
{
  WORK="$(mktemp -d)"
  BINDIR="$WORK/bin"
  LOG="$WORK/calls.log"
  : > "$LOG"
  make_mock_codex "$BINDIR" "$LOG"
  OUT="$WORK/out6.md"

  PATH="$BINDIR:$PATH" bash "$SCRIPT" --cwd "$WORK" --sandbox read-only --out "$OUT" \
    --prompt-file - --model gpt-5.6-sol --effort high <<< "absolute-rules を読んでやって" >/dev/null 2>&1

  assert_true "-m gpt-5.6-sol が渡る" \
    "$(grep -A1 -- '^-m$' "$LOG" | grep -qx 'gpt-5.6-sol' && echo 1 || echo 0)"
  assert_true "-c model_reasoning_effort=high が渡る" \
    "$(grep -qx 'model_reasoning_effort=high' "$LOG" && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 8. 必須引数の欠落 → exit 1（使い方が表示される） ==="
{
  WORK="$(mktemp -d)"
  rc=0
  out=$(bash "$SCRIPT" --sandbox read-only --out "$WORK/o.md" --prompt-file - <<< "absolute-rules" 2>&1) || rc=$?
  assert_eq "--cwd 欠落は exit 1" "1" "$rc"
  assert_true "使い方が表示される" "$(echo "$out" | grep -q '使い方' && echo 1 || echo 0)"
  rm -rf "$WORK"
}

echo "=== 9. --sandbox に read-only/workspace-write 以外を渡すと拒否される ==="
{
  WORK="$(mktemp -d)"
  rc=0
  bash "$SCRIPT" --cwd "$WORK" --sandbox danger-full-access --out "$WORK/o.md" --prompt-file - <<< "absolute-rules" >/dev/null 2>&1 || rc=$?
  assert_eq "danger-full-accessはexit 1で拒否" "1" "$rc"
  rm -rf "$WORK"
}

echo "=== 10. --cwd / --out に相対パスを渡すと拒否される ==="
{
  WORK="$(mktemp -d)"
  rc=0
  bash "$SCRIPT" --cwd "relative/dir" --sandbox read-only --out "$WORK/o.md" --prompt-file - <<< "absolute-rules" >/dev/null 2>&1 || rc=$?
  assert_eq "--cwdの相対パスはexit 1" "1" "$rc"

  rc=0
  bash "$SCRIPT" --cwd "$WORK" --sandbox read-only --out "relative/o.md" --prompt-file - <<< "absolute-rules" >/dev/null 2>&1 || rc=$?
  assert_eq "--outの相対パスはexit 1" "1" "$rc"
  rm -rf "$WORK"
}

echo "=== 11. codex コマンド自体が見つからない → exit 1 ==="
{
  WORK="$(mktemp -d)"
  rc=0
  out=$(PATH="/usr/bin:/bin" bash "$SCRIPT" --cwd "$WORK" --sandbox read-only --out "$WORK/o.md" --prompt-file - <<< "absolute-rules test" 2>&1) || rc=$?
  assert_eq "exit code 1" "1" "$rc"
  assert_true "codexが見つからない旨のメッセージが出る" \
    "$(echo "$out" | grep -q 'codex コマンドが見つかりません' && echo 1 || echo 0)"
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
  stdout_out=$(PATH="$BINDIR:$PATH" bash "$SCRIPT" --cwd "$WORK" --sandbox read-only --out "$OUT" --prompt-file - <<< "absolute-rules テスト" 2>"$WORK/stderr.log") || rc=$?
  assert_eq "codexのexit codeがそのまま返る" "7" "$rc"
  assert_true "EXIT:7 がstdoutに出る" \
    "$(printf '%s\n' "$stdout_out" | grep -qx 'EXIT:7' && echo 1 || echo 0)"
  assert_true "stderrがout.stderr.logに保存される" \
    "$(grep -q 'something failed' "$OUT.stderr.log" && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 13. 依頼文がハイフンから始まっても正しく渡る（argvオプションとして誤解釈されない） ==="
{
  WORK="$(mktemp -d)"
  BINDIR="$WORK/bin"
  LOG="$WORK/calls.log"
  STDIN_LOG="$WORK/stdin.log"
  : > "$LOG"
  make_mock_codex "$BINDIR" "$LOG" "thread-hyphen" "$STDIN_LOG"
  OUT="$WORK/out8.md"

  rc=0
  PATH="$BINDIR:$PATH" bash "$SCRIPT" --cwd "$WORK" --sandbox read-only --out "$OUT" --prompt-file - \
    <<< "--evil-flag absolute-rules を読んでhello" >/dev/null 2>&1 || rc=$?
  assert_eq "exit code 0（オプションとして誤解釈されず正常終了）" "0" "$rc"
  assert_true "依頼文の全文がstdin経由でそのまま渡る" \
    "$([ "$(cat "$STDIN_LOG")" = "--evil-flag absolute-rules を読んでhello" ] && echo 1 || echo 0)"
  assert_true "'--evil-flag' はargvには出現しない（positionalは常に'-'）" \
    "$(grep -qx -- '--evil-flag' "$LOG" && echo 0 || echo 1)"

  rm -rf "$WORK"
}

echo "=== 14. --resume のIDがハイフンから始まっても '--' 区切りでオプションと誤解釈されない ==="
{
  WORK="$(mktemp -d)"
  BINDIR="$WORK/bin"
  LOG="$WORK/calls.log"
  : > "$LOG"
  make_mock_codex "$BINDIR" "$LOG"
  OUT="$WORK/out9.md"

  rc=0
  PATH="$BINDIR:$PATH" bash "$SCRIPT" --cwd "$WORK" --sandbox read-only --out "$OUT" \
    --prompt-file - --resume "--last" <<< "absolute-rules を読んで続きをやって" >/dev/null 2>&1 || rc=$?
  assert_eq "exit code 0" "0" "$rc"

  args_before_end=$(sed -n '1,/ARGS-END/p' "$LOG" | grep -v 'ARGS-END')
  dashdash_line=$(printf '%s\n' "$args_before_end" | grep -n -- '^--$' | head -1 | cut -d: -f1)
  id_lineno=$((dashdash_line + 1))
  id_value=$(printf '%s\n' "$args_before_end" | sed -n "${id_lineno}p")
  assert_true "'--' 区切りが resume の直後に存在する" \
    "$([ -n "$dashdash_line" ] && echo 1 || echo 0)"
  assert_eq "'--' の直後がリテラルな '--last'（オプションではなくpositional値として渡る）" \
    "--last" "$id_value"

  rm -rf "$WORK"
}

echo "=== 15. --out の親ディレクトリが作成できない場合は exit 1 で失敗する（無視しない） ==="
{
  WORK="$(mktemp -d)"
  BINDIR="$WORK/bin"
  LOG="$WORK/calls.log"
  : > "$LOG"
  make_mock_codex "$BINDIR" "$LOG"
  # 通常ファイルをパスの途中に置く（ENOTDIR）。chmod 000によるEACCES方式
  # だとrootで実行するとバイパスされ環境依存になる（Codex一次レビュー
  # 指摘・2巡目Minor）ため、権限に依存せず確実に失敗するこの方式にした。
  BLOCKER="$WORK/not-a-directory"
  : > "$BLOCKER"

  rc=0
  out=$(PATH="$BINDIR:$PATH" bash "$SCRIPT" --cwd "$WORK" --sandbox read-only --out "$BLOCKER/sub/out.md" \
    --prompt-file - <<< "absolute-rules test" 2>&1) || rc=$?
  assert_eq "exit code 1（mkdir失敗を無視しない）" "1" "$rc"
  assert_true "codexは呼ばれていない" \
    "$([ ! -s "$LOG" ] && echo 1 || echo 0)"
  assert_true "作成できない旨のメッセージが出る" \
    "$(echo "$out" | grep -q '作成できません' && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 16. --out の親ディレクトリが既存だが書き込み不能な場合も exit 1 で失敗する ==="
{
  WORK="$(mktemp -d)"
  BINDIR="$WORK/bin"
  LOG="$WORK/calls.log"
  : > "$LOG"
  make_mock_codex "$BINDIR" "$LOG"
  # mkdir -p は既存ディレクトリに対しては何もせず成功するため、書き込み
  # 可否は別途 `-w` で確認する必要がある（Codex一次レビュー指摘・2巡目
  # Minor）。注: root実行環境ではchmod 000でも書き込めてしまいこの
  # テストは成立しない（既知の制約。通常のユーザー権限での実行を前提）。
  LOCKED="$WORK/locked-existing"
  mkdir -p "$LOCKED"
  chmod 000 "$LOCKED"

  rc=0
  out=$(PATH="$BINDIR:$PATH" bash "$SCRIPT" --cwd "$WORK" --sandbox read-only --out "$LOCKED/out.md" \
    --prompt-file - <<< "absolute-rules test" 2>&1) || rc=$?
  chmod 755 "$LOCKED"
  if [ "$(id -u)" = "0" ]; then
    echo "  skip - root実行のためchmod 000が書き込み制限として機能しない"
  else
    assert_eq "exit code 1（既存だが書き込み不能なディレクトリを検出）" "1" "$rc"
    assert_true "codexは呼ばれていない" \
      "$([ ! -s "$LOG" ] && echo 1 || echo 0)"
    assert_true "書き込めない旨のメッセージが出る" \
      "$(echo "$out" | grep -q '書き込めません' && echo 1 || echo 0)"
  fi

  rm -rf "$WORK"
}

# --- 前提修正 P-5 の結合2ケース（2026-09-07・設計§4a）: scripts/codex-exec.sh
#     本体は変更しない。3モード体制の設計が「補助ファイルが存在するか」で
#     失敗の切り分けをする前提（<out>.wrapper.log／<out>.events.jsonl／
#     <out>.stderr.log）が守られていることを、呼び出し側の手順（親を作る・
#     基底名を変える）を守れば診断が成立する形で固定する。どちらも
#     codex の起動を伴わない（事前検査で失敗させる）。 ---

echo "=== 17. PA-23: --out の親を先に mkdir -p してから起動し、事前検査で失敗させる（absolute-rules無し=exit 2／引数不備=exit 1） ==="
{
  # (a) absolute-rules への参照が無い依頼文 → exit 2
  WORK="$(mktemp -d)"
  BINDIR="$WORK/bin"
  LOG="$WORK/calls.log"
  : > "$LOG"
  make_mock_codex "$BINDIR" "$LOG"
  OUT="$WORK/reviews/review-r1-a1.md"
  mkdir -p "$(dirname "$OUT")"

  rc=0
  stdout_out="$(PATH="$BINDIR:$PATH" bash "$SCRIPT" --cwd "$WORK" --sandbox read-only --out "$OUT" --prompt-file - \
    <<< "こんにちは、何かして" 2>"$OUT.wrapper.log")" || rc=$?
  assert_eq "(a) absolute-rules無しはexit 2" "2" "$rc"
  assert_true "(a) stdoutに3行出ない（空）" "$([ -z "$stdout_out" ] && echo 1 || echo 0)"
  assert_true "(a) <out>.wrapper.logに理由が残る" \
    "$(grep -q 'absolute-rules' "$OUT.wrapper.log" && echo 1 || echo 0)"
  assert_true "(a) <out>.stderr.logは作られていない" \
    "$([ ! -e "$OUT.stderr.log" ] && echo 1 || echo 0)"
  assert_true "(a) codexは一度も呼ばれていない" "$([ ! -s "$LOG" ] && echo 1 || echo 0)"

  rm -rf "$WORK"

  # (b) 引数不備（--sandbox に無効な値）→ exit 1
  WORK="$(mktemp -d)"
  BINDIR="$WORK/bin"
  LOG="$WORK/calls.log"
  : > "$LOG"
  make_mock_codex "$BINDIR" "$LOG"
  OUT="$WORK/reviews/review-r1-a2.md"
  mkdir -p "$(dirname "$OUT")"

  rc=0
  stdout_out="$(PATH="$BINDIR:$PATH" bash "$SCRIPT" --cwd "$WORK" --sandbox danger-full-access --out "$OUT" --prompt-file - \
    <<< "absolute-rules を読んでやって" 2>"$OUT.wrapper.log")" || rc=$?
  assert_eq "(b) 引数不備はexit 1" "1" "$rc"
  assert_true "(b) stdoutに3行出ない（空）" "$([ -z "$stdout_out" ] && echo 1 || echo 0)"
  assert_true "(b) <out>.wrapper.logに理由（使い方）が残る" \
    "$(grep -q '使い方' "$OUT.wrapper.log" && echo 1 || echo 0)"
  assert_true "(b) <out>.stderr.logは作られていない" \
    "$([ ! -e "$OUT.stderr.log" ] && echo 1 || echo 0)"
  assert_true "(b) codexは一度も呼ばれていない" "$([ ! -s "$LOG" ] && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo "=== 18. PA-24: 前の試行の残骸（別の基底名の<out>.events.jsonl/.stderr.log）があっても、新しい基底名では補助ファイルが無く『未起動』と正しく判定できる ==="
{
  WORK="$(mktemp -d)"
  BINDIR="$WORK/bin"
  LOG="$WORK/calls.log"
  : > "$LOG"
  make_mock_codex "$BINDIR" "$LOG"
  REVIEWS="$WORK/reviews"
  mkdir -p "$REVIEWS"

  # 前の試行の残骸を用意する（別の基底名 review-r1-a1.md 側）。
  OLD_OUT="$REVIEWS/review-r1-a1.md"
  echo '{"type":"thread.started","thread_id":"old-thread"}' > "$OLD_OUT.events.jsonl"
  echo "古い試行のstderr" > "$OLD_OUT.stderr.log"

  # 新しい基底名（-a2）で、事前検査に失敗させる（absolute-rules無し）。
  NEW_OUT="$REVIEWS/review-r1-a2.md"

  rc=0
  stdout_out="$(PATH="$BINDIR:$PATH" bash "$SCRIPT" --cwd "$WORK" --sandbox read-only --out "$NEW_OUT" --prompt-file - \
    <<< "こんにちは、何かして" 2>"$NEW_OUT.wrapper.log")" || rc=$?
  assert_eq "exit code 2" "2" "$rc"
  assert_true "stdoutに3行出ない（空）" "$([ -z "$stdout_out" ] && echo 1 || echo 0)"
  assert_true "新しい基底名側に .events.jsonl が無い（未起動と正しく判定できる）" \
    "$([ ! -e "$NEW_OUT.events.jsonl" ] && echo 1 || echo 0)"
  assert_true "新しい基底名側に .stderr.log が無い（未起動と正しく判定できる）" \
    "$([ ! -e "$NEW_OUT.stderr.log" ] && echo 1 || echo 0)"
  assert_true "古い試行の残骸（別の基底名）は影響を受けず残ったまま（前の試行に引きずられないことの確認）" \
    "$([ -f "$OLD_OUT.events.jsonl" ] && [ -f "$OLD_OUT.stderr.log" ] && echo 1 || echo 0)"
  assert_true "codexは一度も呼ばれていない" "$([ ! -s "$LOG" ] && echo 1 || echo 0)"

  rm -rf "$WORK"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
