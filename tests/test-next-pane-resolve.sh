#!/usr/bin/env bash
# claude/hooks/next-pane-resolve.sh のユニットテスト。
#
# 実 ~/.claude・実Vault・実cmuxには一切依存しない。フックへ渡すJSON入力
# （UserPromptSubmitフックの実際の呼び出し形式＝`{"prompt":"..."}`）をjqで
# 組み立てて標準入力から渡し、標準出力の additionalContext JSON の有無で
# 判定する。`--list` を叩く先は NEXT_RESOLVE_LIST_CMD で自前のスタブへ
# 差し替える（実 cmux-next-watch.sh を呼ばない）。
#
# FR-45（cmux-session-todo/docs/requirements.md）・design.md §8＝
# 「Next Task」への言及（表記ゆれ含む）ではNext Projectの番号表を注入しない。
# 従来の3通りの言い方（Next Project の N 番／Next ペインの N 番／
# 素の Next の N 番）は今までどおり注入する（後方互換）。
#
# 実行方法: bash tests/test-next-pane-resolve.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
HOOK="$REPO_ROOT/claude/hooks/next-pane-resolve.sh"

# mktemp -d の失敗・異常な返り値を即検査する（差分レビュー指摘#6 MAJOR対応）。
# `set -e` を使っていないため、失敗しても代入自体は続行してしまい、
# 空文字列や `/` を掴んだままtrapの `rm -rf "$WORK_DIR"` がルート直下等の
# 意図しない場所へ向かう危険がある。空・`/`・既存の非空ディレクトリを
# 拒否してからtrapとfixture作成へ進む。
WORK_DIR="$(mktemp -d)" || { echo "FATAL: mktemp -d に失敗しました" >&2; exit 1; }
case "$WORK_DIR" in
  "" | "/")
    echo "FATAL: mktemp -d の返り値が不正です: [$WORK_DIR]" >&2
    exit 1
    ;;
esac
if [ ! -d "$WORK_DIR" ]; then
  echo "FATAL: mktemp -d がディレクトリを作成しませんでした: [$WORK_DIR]" >&2
  exit 1
fi
if [ -n "$(ls -A "$WORK_DIR" 2>/dev/null)" ]; then
  echo "FATAL: mktemp -d が空でない既存ディレクトリを返しました: [$WORK_DIR]" >&2
  exit 1
fi
trap 'rm -rf "$WORK_DIR"' EXIT

# --list スタブ。呼ばれたら固定のTSV（4列）を返す。
STUB_LIST_CMD="$WORK_DIR/cmux-next-watch-stub.sh"
cat >"$STUB_LIST_CMD" <<'EOF'
#!/bin/bash
if [ "$1" = "--list" ]; then
  printf '1\tcmux-session-todo\tv2 1/3\t稼働中\n'
  printf '2\tother-project\t(next未設定)\t保留\n'
fi
EOF
chmod +x "$STUB_LIST_CMD"

# 存在するが実行権限の無いスタブ（[ -x ] チェックの回帰確認用）。
NONEXEC_LIST_CMD="$WORK_DIR/cmux-next-watch-noexec.sh"
cat >"$NONEXEC_LIST_CMD" <<'EOF'
#!/bin/bash
printf '1\tcmux-session-todo\tv2 1/3\t稼働中\n'
EOF
chmod -x "$NONEXEC_LIST_CMD"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

# フックへJSON入力を渡して標準出力を返す。
run_hook() {
  local prompt="$1"
  jq -n --arg p "$prompt" '{prompt:$p}' | NEXT_RESOLVE_LIST_CMD="$STUB_LIST_CMD" bash "$HOOK"
}

assert_no_injection() {
  local desc="$1" prompt="$2" out
  out="$(run_hook "$prompt")"
  if [ -z "$out" ]; then
    pass "$desc"
  else
    fail_case "$desc (注入されてしまった。prompt=[$prompt] out=[$out])"
  fi
}

assert_injected() {
  local desc="$1" prompt="$2" out
  out="$(run_hook "$prompt")"
  if [ -z "$out" ]; then
    fail_case "$desc (注入されなかった。prompt=[$prompt])"
    return
  fi
  if ! printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null 2>&1; then
    fail_case "$desc (JSON形式が想定と違う。out=[$out])"
    return
  fi
  local ctx
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
  if ! printf '%s' "$ctx" | grep -qF "NextProjectペイン番号対応表"; then
    fail_case "$desc (見出しがNextProjectペイン番号対応表になっていない。ctx=[$ctx])"
    return
  fi
  if ! printf '%s' "$ctx" | grep -qF "cmux-session-todo"; then
    fail_case "$desc (--listの出力が含まれていない。ctx=[$ctx])"
    return
  fi
  pass "$desc"
}

echo "=== 1. FR-45: Next Task への言及（表記ゆれ）は注入しない ==="
assert_no_injection "素の「Next Task の2番」は注入しない" "Next Task の2番"
assert_no_injection "ハイフン区切り「Next-Task の2番」は注入しない" "Next-Task の2番"
assert_no_injection "アンダースコア区切り「Next_Task の2番」は注入しない" "Next_Task の2番"
assert_no_injection "詰め表記「NextTaskの2番」は注入しない" "NextTaskの2番"
assert_no_injection "全角カナ「ネクストタスクの2番」は注入しない" "ネクストタスクの2番"
assert_no_injection "カナに空白「ネクスト タスク の2番」は注入しない" "ネクスト タスク の2番"
assert_no_injection "大文字小文字混在「nextTASKの2番」は注入しない" "nextTASKの2番"
assert_no_injection "「Next Task」＋「ペイン」表記でも注入しない" "Next Task のペインを見て"

echo "=== 2. 回帰: 従来の3通りの言い方は今までどおり注入する ==="
assert_injected "「Next Project の2番」は従来どおり注入" "Next Project の2番"
assert_injected "「Nextペインの2番」は従来どおり注入" "Nextペインの2番"
assert_injected "素の「Nextの2番」は従来どおり注入" "Nextの2番"
assert_injected "「ネクストの2番」は従来どおり注入" "ネクストの2番"
assert_injected "「Next の3番目のペイン」は従来どおり注入" "Next の3番目のペインを見て"

echo "=== 3. 混在プロンプト: Next Task を含んでもNext側の言及が残れば注入する（design.md §8） ==="
assert_injected "「Next Task の2番と Next の3番」はNext側が残るので注入" "Next Task の2番と Next の3番を教えて"
assert_injected "「NextTaskの状況とNext Projectの1番」は注入" "NextTaskの状況とNext Projectの1番を教えて"

echo "=== 4. 回帰: 既存の非該当条件はfail-silentのまま ==="
assert_no_injection "「next」も「番/ペイン」も無いプロンプトは注入しない" "こんにちは、調子はどう？"
assert_no_injection "「next」はあるが「番/ペイン」が無いプロンプトは注入しない" "next taskを片付けよう"
assert_no_injection "「番」はあるが「next/ネクスト」が無いプロンプトは注入しない" "3番目の作業をお願い"
assert_no_injection "空プロンプトは注入しない" ""

echo "=== 5. 回帰: LIST_CMDが実行不可・空出力のときはfail-silent ==="
out5a="$(jq -n --arg p "Nextの2番" '{prompt:$p}' | NEXT_RESOLVE_LIST_CMD="$NONEXEC_LIST_CMD" bash "$HOOK")"
if [ -z "$out5a" ]; then
  pass "LIST_CMDに実行権限が無いときは注入しない"
else
  fail_case "LIST_CMDに実行権限が無いときは注入しない (out=[$out5a])"
fi

EMPTY_LIST_CMD="$WORK_DIR/cmux-next-watch-empty.sh"
cat >"$EMPTY_LIST_CMD" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$EMPTY_LIST_CMD"
out5b="$(jq -n --arg p "Nextの2番" '{prompt:$p}' | NEXT_RESOLVE_LIST_CMD="$EMPTY_LIST_CMD" bash "$HOOK")"
if [ -z "$out5b" ]; then
  pass "LIST_CMDの出力が空のときは注入しない"
else
  fail_case "LIST_CMDの出力が空のときは注入しない (out=[$out5b])"
fi

echo "=== 6. bash 3.2 互換の静的検査 ==="
if /bin/bash -n "$HOOK"; then
  pass "/bin/bash -n が通る（macOS bash 3.2 互換）"
else
  fail_case "/bin/bash -n が通る（macOS bash 3.2 互換）"
fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
