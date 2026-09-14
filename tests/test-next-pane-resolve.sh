#!/usr/bin/env bash
# claude/hooks/next-pane-resolve.sh のユニットテスト。
#
# 実 ~/.claude・実Vault・実cmuxには一切依存しない。フックへ渡すJSON入力
# （UserPromptSubmitフックの実際の呼び出し形式＝`{"prompt":"..."}`）をjqで
# 組み立てて標準入力から渡し、標準出力・標準エラー・終了コードの3点で
# 判定する（検証1巡目 MAJOR #6・stdoutだけの確認は不十分）。`--list` を
# 叩く先は NEXT_RESOLVE_LIST_CMD で自前のスタブへ差し替える（実
# cmux-next-watch.sh を呼ばない）。ファイル名（next-pane-resolve.sh）は
# 旧仕様の名残でそのまま（本人指示 2026-09-14 19:45）。
#
# run_hookの標準fixtureは本番のUserPromptSubmit envelope（session_id等を
# 含む）を渡す。prompt-only入力だと`.prompt`以外のキーの有無で分岐する
# ような変異を検出できないため（検証3巡目 MAJOR #3）。時間予算は判定用
# jq=1秒＋emit_context=2秒（それぞれTERMは公称秒数の地点で送り、正常な
# 処理はその秒数いっぱい使える。deadline到達（TERM）で終了した場合は
# watchdog自身の0.3秒後KILLをそのまま待ち、後始末する子孫にも猶予0.3秒
# を与える。deadline前に自然終了した場合だけ残存子孫へ即座にKILLする。
# 検証4巡目 MAJOR #1＝旧実装はTERMをN-1秒で送っており正常終了までに
# 時間のかかる処理を打ち切っていた。検証5巡目 MAJOR #2＝cmd_pidの生死に
# 関わらず無条件で即座にKILLしていたため、TERMハンドラで後始末する
# 子孫の猶予が実質0秒になっていた）。5秒のフック枠に対する実質の余裕は
# 1.4秒（②設計の「2秒の余裕」からは縮む。②設計 docs/design.md §22.4・
# 検証3巡目 BLOCKING #1）。
#
# 発火条件（本人の要件変更 2026-09-14 19:45＝Dock枠名からNextを外し
# Project/Taskにした）＝「Project」（大小文字非依存）または「プロジェクト」
# を含み、かつ「番」を含むこと。旧仕様にあった「Next」の要求は撤廃した。
# 「Next Project の 3 番」はProject＋番を含むので変更後も自然に発火する
# （後方互換）。前後をASCII英数字・アンダースコアで挟まれた語の一部
# （例: Projects/Projector/NextProject〈packed〉）は対象外。この境界は
# 英語側だけでなく日本語側（プロジェクト）にも同じASCII英数字・
# アンダースコアの境界を課す（検証5巡目 MAJOR #1＝Aプロジェクト／
# プロジェクトA／_プロジェクト／プロジェクト_はいずれも対象外）。
# 日本語側は直後に漢字が続く複合語の一部（例: プロジェクト化）も対象外。
# 「の」等の平仮名の助詞は漢字ではないため対象内のまま（検証1巡目
# MAJOR #2・検証2巡目 MAJOR #2）。「プロジェクター」は「プロジェクト」を
# 部分文字列として含まない別語なのでそもそも一致しない。「番」は数字が
# 隣接しなくても文字自体の有無だけで判定する（検証5巡目 MINOR #4）。
# .promptに不正なUTF-8バイト由来の置換文字（U+FFFD）が含まれる場合は
# 判定に使わず非発火にする（検証5巡目 MINOR #3＝jqは不正バイトをJSON
# 解析エラーにはせずU+FFFDへ変換して読み進めるため、そのままだと過剰
# 発火する）。
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

STDERR_TMP="$WORK_DIR/stderr.tmp"

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

# 6秒 sleep してから出力するスタブ（TERMは無視しない。時間予算の実測用。
# 検証1巡目 BLOCKING #1・検証3〜4巡目で予算の意味を改訂）。
SLOW_LIST_CMD="$WORK_DIR/cmux-next-watch-slow.sh"
cat >"$SLOW_LIST_CMD" <<'EOF'
#!/bin/bash
if [ "$1" = "--list" ]; then
  sleep 6
  printf '1\tcmux-session-todo\tv2 1/3\t稼働中\n'
fi
EOF
chmod +x "$SLOW_LIST_CMD"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

# フックへ生JSON入力を渡し、標準出力/標準エラー/終了コードをグローバル
# 変数（HOOK_STDOUT/HOOK_STDERR/HOOK_EXIT）へ格納する。
run_hook_raw() {
  local json_input="$1" list_cmd="${2:-$STUB_LIST_CMD}"
  HOOK_STDOUT="$(printf '%s' "$json_input" | NEXT_RESOLVE_LIST_CMD="$list_cmd" bash "$HOOK" 2>"$STDERR_TMP")"
  HOOK_EXIT=$?
  HOOK_STDERR="$(cat "$STDERR_TMP" 2>/dev/null)"
}

# フックへプレーンテキストのpromptを渡す（内部で本番のUserPromptSubmit
# envelope＝session_id・transcript_path・cwd・permission_mode・
# hook_event_name・prompt_id・scratchpad_dir を含む形に組み立てる。公式
# リファレンス https://code.claude.com/docs/en/hooks・2026-09-14取得。
# promptだけのfixtureだと`.prompt`以外のキーの有無を見て条件分岐する
# ような変異を検出できない＝検証3巡目 MAJOR #3。prompt欠落・型検査など
# 個別のエッジケースだけpromptだけの最小JSONをrun_hook_rawで直接渡す）。
run_hook() {
  local prompt="$1" list_cmd="${2:-$STUB_LIST_CMD}"
  local json_input
  json_input="$(jq -n --arg p "$prompt" '{
    session_id: "test-session-id",
    transcript_path: "/tmp/test-transcript.jsonl",
    cwd: "/tmp",
    permission_mode: "default",
    hook_event_name: "UserPromptSubmit",
    prompt_id: "test-prompt-id",
    scratchpad_dir: "/tmp/test-scratchpad",
    prompt: $p
  }')"
  run_hook_raw "$json_input" "$list_cmd"
}

# stdout・stderr・終了コードの3点をまとめて検査する内部ヘルパー。
assert_fail_silent() {
  local desc="$1"
  if [ -n "$HOOK_STDOUT" ]; then
    fail_case "$desc (stdoutに出力があった。out=[$HOOK_STDOUT])"
    return
  fi
  if [ -n "$HOOK_STDERR" ]; then
    fail_case "$desc (stderrに出力があった。err=[$HOOK_STDERR])"
    return
  fi
  if [ "$HOOK_EXIT" -ne 0 ]; then
    fail_case "$desc (終了コードが0でない。exit=$HOOK_EXIT)"
    return
  fi
  pass "$desc"
}

assert_no_injection() {
  local desc="$1" prompt="$2"
  run_hook "$prompt"
  assert_fail_silent "$desc"
}

EXPECTED_HEADING='Project番号対応表（この瞬間の表示順。ユーザーの「Project の N 番」はこの表で解決する）:'

assert_injected() {
  local desc="$1" prompt="$2"
  run_hook "$prompt"
  if [ -n "$HOOK_STDERR" ]; then
    fail_case "$desc (stderrに出力があった。err=[$HOOK_STDERR])"
    return
  fi
  if [ "$HOOK_EXIT" -ne 0 ]; then
    fail_case "$desc (終了コードが0でない。exit=$HOOK_EXIT)"
    return
  fi
  if [ -z "$HOOK_STDOUT" ]; then
    fail_case "$desc (注入されなかった。prompt=[$prompt])"
    return
  fi
  if ! printf '%s' "$HOOK_STDOUT" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null 2>&1; then
    fail_case "$desc (JSON形式が想定と違う。out=[$HOOK_STDOUT])"
    return
  fi
  local ctx firstline
  ctx="$(printf '%s' "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.additionalContext')"
  firstline="$(printf '%s' "$ctx" | head -1)"
  # 見出し文は完全一致で検査する（検証1巡目 MAJOR #5）。
  if [ "$firstline" != "$EXPECTED_HEADING" ]; then
    fail_case "$desc (見出し文が完全一致しない。firstline=[$firstline])"
    return
  fi
  if ! printf '%s' "$ctx" | grep -qF "cmux-session-todo"; then
    fail_case "$desc (--listの出力が含まれていない。ctx=[$ctx])"
    return
  fi
  pass "$desc"
}

echo "=== AC-1: 発火（Project／プロジェクト＋番。本人の要件変更 2026-09-14 19:45） ==="
assert_injected "「Project の 3 番」は発火" "Project の 3 番"
assert_injected "「プロジェクトの3番」は発火" "プロジェクトの3番"
assert_injected "後方互換「Next Project の 3 番」は発火" "Next Project の 3 番"
assert_injected "「ネクストプロジェクト 3番」は発火" "ネクストプロジェクト 3番"
assert_injected "「Project ペインの 3 番」は「番」を含むので発火" "Project ペインの 3 番"
assert_injected "小文字「project 3番」は発火" "project 3番"
assert_injected "ハイフン前置「Next-Project 3 番」は発火（ハイフンは語構成文字でない）" "Next-Project 3 番"
assert_injected "日本語の詰め表記「ネクストプロジェクトの3番」は発火（日本語側に前方境界は課さない）" "ネクストプロジェクトの3番"
assert_injected "全角スペース「ネクスト　プロジェクト　3番」は発火" "ネクスト　プロジェクト　3番"
run_hook_raw '{"prompt":"Next\nProject 3番"}'
if [ -n "$HOOK_STDOUT" ] && [ -z "$HOOK_STDERR" ] && [ "$HOOK_EXIT" -eq 0 ]; then
  pass "改行を挟む「Next\\nProject 3番」は発火（Project自体は分断されていない）"
else
  fail_case "改行を挟む「Next\\nProject 3番」は発火 (out=[$HOOK_STDOUT] err=[$HOOK_STDERR] exit=$HOOK_EXIT)"
fi
assert_injected "「番」は数字が隣接しなくても発火する「Project は何番？」" "Project は何番？"
assert_injected "全角数字「Project ３番」は発火する（番という文字自体は変わらない）" "Project ３番"
assert_injected "全角数字と空白「プロジェクト ３ 番」は発火する" "プロジェクト ３ 番"

echo "=== AC-2続き: 検証5巡目 MAJOR #1（日本語側にもASCII英数字/アンダースコアの境界を課す） ==="
assert_no_injection "「Aプロジェクト 3番」は発火しない（直前にASCII英字）" "Aプロジェクト 3番"
assert_no_injection "「プロジェクトA 3番」は発火しない（直後にASCII英字）" "プロジェクトA 3番"
assert_no_injection "「_プロジェクト 3番」は発火しない（直前にアンダースコア）" "_プロジェクト 3番"
assert_no_injection "「プロジェクト_ 3番」は発火しない（直後にアンダースコア）" "プロジェクト_ 3番"

echo "=== AC-1続き: 不正バイトがProjectという語自体を分断すれば発火しない ==="
# jqは不正なUTF-8バイトをJSON解析エラーにはせず、置換文字（U+FFFD）へ
# 変換して読み進める（実測で確認。従来「JSON解析が失敗してfail-silentに
# なる」という前提で書かれていたテストだったが、実際には解析は成功し、
# 語の外側にある不正バイトは単なる非英数字の区切りとして扱われ発火する。
# 語の内側を分断する場合だけ意味のある陰性fixtureになる）。
BADUTF_JSON1="$WORK_DIR/bad-utf8-1.json"
printf '{"prompt":"pro\x80ject 3\xe7\x95\xaa"}' >"$BADUTF_JSON1"
HOOK_STDOUT="$(NEXT_RESOLVE_LIST_CMD="$STUB_LIST_CMD" bash "$HOOK" <"$BADUTF_JSON1" 2>"$STDERR_TMP")"
HOOK_EXIT=$?
HOOK_STDERR="$(cat "$STDERR_TMP" 2>/dev/null)"
assert_fail_silent "不正な単独継続バイトがProjectを分断する（pro\\x80ject）と発火しない"

BADUTF_JSON2="$WORK_DIR/bad-utf8-2.json"
printf '{"prompt":"pro\xe3\x80ject 3\xe7\x95\xaa"}' >"$BADUTF_JSON2"
HOOK_STDOUT="$(NEXT_RESOLVE_LIST_CMD="$STUB_LIST_CMD" bash "$HOOK" <"$BADUTF_JSON2" 2>"$STDERR_TMP")"
HOOK_EXIT=$?
HOOK_STDERR="$(cat "$STDERR_TMP" 2>/dev/null)"
assert_fail_silent "U+3000の断片バイトがProjectを分断する（pro\\xe3\\x80ject）と発火しない"

echo "=== AC-1続き: 検証5巡目 MINOR #3（不正バイトが置換文字化して新たな語境界を作っても発火しない） ==="
# jqは不正バイトをU+FFFDへ変換して読み進めるため、Projectの外側に
# 不正バイトがあると、それが本来無関係な位置に非英数字の境界を作って
# しまい過剰発火する（実測確認）。.promptにU+FFFDが含まれる場合は
# 判定に使わず非発火にすることで対処した。
BADUTF_JSON3="$WORK_DIR/bad-utf8-3.json"
printf '{"prompt":"A\x80Project 3\xe7\x95\xaa"}' >"$BADUTF_JSON3"
HOOK_STDOUT="$(NEXT_RESOLVE_LIST_CMD="$STUB_LIST_CMD" bash "$HOOK" <"$BADUTF_JSON3" 2>"$STDERR_TMP")"
HOOK_EXIT=$?
HOOK_STDERR="$(cat "$STDERR_TMP" 2>/dev/null)"
assert_fail_silent "「A\\x80Project 3番」は不正バイトが境界を作っても発火しない"

BADUTF_JSON4="$WORK_DIR/bad-utf8-4.json"
printf '{"prompt":"Project\x80s 3\xe7\x95\xaa"}' >"$BADUTF_JSON4"
HOOK_STDOUT="$(NEXT_RESOLVE_LIST_CMD="$STUB_LIST_CMD" bash "$HOOK" <"$BADUTF_JSON4" 2>"$STDERR_TMP")"
HOOK_EXIT=$?
HOOK_STDERR="$(cat "$STDERR_TMP" 2>/dev/null)"
assert_fail_silent "「Project\\x80s 3番」は不正バイトが境界を作っても発火しない"

BADUTF_JSON5="$WORK_DIR/bad-utf8-5.json"
printf '{"prompt":"\x80Project 3\xe7\x95\xaa"}' >"$BADUTF_JSON5"
HOOK_STDOUT="$(NEXT_RESOLVE_LIST_CMD="$STUB_LIST_CMD" bash "$HOOK" <"$BADUTF_JSON5" 2>"$STDERR_TMP")"
HOOK_EXIT=$?
HOOK_STDERR="$(cat "$STDERR_TMP" 2>/dev/null)"
assert_fail_silent "先頭が不正バイトの「\\x80Project 3番」は発火しない"

echo "=== AC-2: 非発火（Project／プロジェクトを伴わない・番が無い・キーワードが無い等） ==="
assert_no_injection "素の「Next の 3 番」は発火しない（Project 無し）" "Next の 3 番"
assert_no_injection "「Task の 3 番」は発火しない（Project 無し）" "Task の 3 番"
assert_no_injection "「タスクの3番」は発火しない（プロジェクト無し）" "タスクの3番"
assert_no_injection "「プロジェクトを確認して」は発火しない（番が無い）" "プロジェクトを確認して"
assert_no_injection "空プロンプトは発火しない" ""

echo "=== AC-2続き: 語境界（前後がASCII英数字/アンダースコアで連続する語の一部は対象外） ==="
assert_no_injection "「Projects の 3 番」は発火しない（複数形の一部）" "Projects の 3 番"
assert_no_injection "「3 番のプロジェクター」は発火しない（プロジェクトを部分文字列として含まない別語）" "3 番のプロジェクター"
assert_no_injection "「abcnext-projectxyz 3番」は発火しない（より大きな語に埋め込み）" "abcnext-projectxyz 3番"
assert_no_injection "「myNextProjector 3番」は発火しない（Projectorの一部）" "myNextProjector 3番"
assert_no_injection "「Project_suffix 3番」は発火しない（末尾がアンダースコアに連続）" "Project_suffix 3番"
assert_no_injection "反転: 詰め表記「NextProjectの3番」は発火しない（Projectが大きな語Nextprojectに埋め込み。旧仕様は発火・要件変更でNext前置の特別扱いを廃止したため反転）" "NextProjectの3番"
assert_no_injection "反転: アンダースコア接続「Next_Project の 3 番」は発火しない（旧仕様はNextとの接続子として許容していたが、要件変更でNext前置の特別扱いを廃止したため反転）" "Next_Project の 3 番"
assert_injected "反転: 混在区切り「Next_- Project 3番」は発火する（Projectの直前は半角空白なので境界を満たす。旧仕様はNext-Project専用の接続子規則で非発火だったが、その規則自体が無くなったため反転）" "Next_- Project 3番"

echo "=== AC-2続き: 日本語側の複合語（直後に漢字が続く場合は対象外） ==="
assert_no_injection "「プロジェクト化 3番」は発火しない（直後が漢字＝複合語の一部）" "プロジェクト化 3番"
assert_injected "「プロジェクトの3番」は発火する（直後が平仮名の助詞は複合語扱いしない）" "プロジェクトの3番"

echo "=== AC-2続き: .promptの型検査 ==="
run_hook_raw '{"prompt":{"text":"Project 3番"}}'
assert_fail_silent "prompt がobject型のときは発火しない"
run_hook_raw '{"prompt":["Project 3番"]}'
assert_fail_silent "prompt がarray型のときは発火しない"
run_hook_raw '{"prompt":null}'
assert_fail_silent "prompt がnullのときは発火しない"

echo "=== AC-2続き: NULバイトはProjectという語を分断すれば発火しない ==="
run_hook_raw '{"prompt":"Pro\\u0000ject 3番"}'
assert_fail_silent "「Pro\\u0000jectを3番」はNULで語が分断され発火しない"
# 「Next\\u0000Project」（run_hook_rawはbashの単一引用符でエスケープを
# 一切解決しないため、ここは実際のNULバイトではなく、リテラルな6文字
# 「\u0000」がプロンプト文字列に残る＝jq側では「Project」の直前が数字の
# 「0」に隣接している扱いになり、語境界を満たさず非発火のまま。旧仕様の
# NUL安全性テスト（検証1巡目 MINOR #8）の意図を維持する）。
run_hook_raw '{"prompt":"Next\\u0000Project 3番"}'
assert_fail_silent "「Next\\u0000Project 3番」は「u0000」の0がProjectに隣接し境界を満たさず発火しない"

echo "=== AC-2続き: prompt キー欠落 ==="
run_hook_raw '{}'
assert_fail_silent "prompt キー欠落は発火しない"

echo "=== AC-3: 複合（Project 側と Task 側の両方を含む） ==="
assert_injected "「Project の 2 番と Task の 3 番」は発火" "Project の 2 番と Task の 3 番"
assert_injected "後方互換「Next Project の 2 番と Next Task の 3 番」は発火" "Next Project の 2 番と Next Task の 3 番"

echo "=== AC-4: 既存のfail-silent系（LIST_CMD不在・実行権限なし・空出力・不正JSON入力）は維持 ==="
run_hook "Project の2番" "$WORK_DIR/does-not-exist.sh"
assert_fail_silent "LIST_CMDが存在しないときは発火しない"

run_hook "Project の2番" "$NONEXEC_LIST_CMD"
assert_fail_silent "LIST_CMDに実行権限が無いときは発火しない"

EMPTY_LIST_CMD="$WORK_DIR/cmux-next-watch-empty.sh"
cat >"$EMPTY_LIST_CMD" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$EMPTY_LIST_CMD"
run_hook "Project の2番" "$EMPTY_LIST_CMD"
assert_fail_silent "LIST_CMDの出力が空のときは発火しない"

run_hook_raw 'not-json'
assert_fail_silent "不正JSON入力のときは発火しない"

echo "=== AC-4続き: 検証4巡目 MAJOR #1（正常だが遅い処理は公称予算いっぱいまで許される） ==="
# run_with_deadline <N> のTERM時刻は「正常処理に許す時間」を意味する
# （リーダー裁定・②設計 §22.4の予算表の意図に合わせた。検証4巡目
# MAJOR #1＝旧実装はTERMをN-1秒で送っており、正常終了までに時間の
# かかる処理を打ち切っていた）。判定用jq（budget=1）は0.3秒、
# emit_context（budget=2）のLIST_CMDは0.6秒まで正常に完了できることを
# 確認する（deadlineに対して30%の負荷時間に抑え、並列実行下でも十分な
# 余裕を持たせた。検証5巡目 MINOR #5＝0.6秒/1.2秒（60%）は3変異suiteの
# 並列実行で無関係な2suiteが追加失敗する程度に余裕が小さかった）。
SLOWJQ_BIN="$WORK_DIR/slowjq-bin"
mkdir -p "$SLOWJQ_BIN"
REAL_JQ="$(command -v jq)"
cat >"$SLOWJQ_BIN/jq" <<EOF
#!/bin/bash
sleep 0.3
exec "$REAL_JQ" "\$@"
EOF
chmod +x "$SLOWJQ_BIN/jq"
json_input="$(jq -n --arg p "Project 3番" '{prompt:$p}')"
start_ts=$(date +%s)
HOOK_STDOUT="$(printf '%s' "$json_input" | PATH="$SLOWJQ_BIN:$PATH" NEXT_RESOLVE_LIST_CMD="$STUB_LIST_CMD" bash "$HOOK" 2>"$STDERR_TMP")"
HOOK_EXIT=$?
end_ts=$(date +%s)
HOOK_STDERR="$(cat "$STDERR_TMP" 2>/dev/null)"
elapsed=$((end_ts - start_ts))
if [ "$elapsed" -le 3 ] && [ -n "$HOOK_STDOUT" ] && [ -z "$HOOK_STDERR" ] && [ "$HOOK_EXIT" -eq 0 ]; then
  pass "0.3秒で正常終了するjq（判定用・budget=1）は打ち切られず発火する（実測 ${elapsed}s）"
else
  fail_case "0.3秒で正常終了するjqは打ち切られず発火する (実測 ${elapsed}s, out=[$HOOK_STDOUT] err=[$HOOK_STDERR] exit=$HOOK_EXIT)"
fi

SLOW_OK_LIST_CMD="$WORK_DIR/cmux-next-watch-slow-ok.sh"
cat >"$SLOW_OK_LIST_CMD" <<'EOF'
#!/bin/bash
if [ "$1" = "--list" ]; then
  sleep 0.6
  printf '1\tcmux-session-todo\tv2 1/3\t稼働中\n'
fi
EOF
chmod +x "$SLOW_OK_LIST_CMD"
start_ts=$(date +%s)
run_hook "Project 3番" "$SLOW_OK_LIST_CMD"
end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))
if [ "$elapsed" -le 3 ] && [ -n "$HOOK_STDOUT" ] && [ -z "$HOOK_STDERR" ] && [ "$HOOK_EXIT" -eq 0 ]; then
  pass "0.6秒で正常終了するLIST_CMD（emit_context・budget=2）は打ち切られず発火する（実測 ${elapsed}s）"
else
  fail_case "0.6秒で正常終了するLIST_CMDは打ち切られず発火する (実測 ${elapsed}s, out=[$HOOK_STDOUT] err=[$HOOK_STDERR] exit=$HOOK_EXIT)"
fi

echo "=== AC-4続き: 検証1・3・4巡目 BLOCKING #1（TERMに応答するLIST_CMDは予算のN秒地点で打ち切る） ==="
# 6秒かかるが、TERMを無視しないLIST_CMD。budget=2なのでTERMはN=2秒地点で
# 送られそこで終了する。run_with_deadlineはシグナルで終了した場合、
# watchdog自身の0.3秒後KILLをそのまま待つため、実測はN+0.3秒程度になる。
start_ts=$(date +%s)
run_hook "Project 3番" "$SLOW_LIST_CMD"
end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))
if [ "$elapsed" -le 4 ] && [ -z "$HOOK_STDOUT" ] && [ -z "$HOOK_STDERR" ] && [ "$HOOK_EXIT" -eq 0 ]; then
  pass "6秒かかるLIST_CMDはTERMに応答し予算のN秒地点で打ち切られる（実測 ${elapsed}s）"
else
  fail_case "6秒かかるLIST_CMDはTERMに応答し予算のN秒地点で打ち切られる (実測 ${elapsed}s, out=[$HOOK_STDOUT] err=[$HOOK_STDERR] exit=$HOOK_EXIT)"
fi

echo "=== AC-4続き: 検証2〜3巡目 BLOCKING #1（正常経路は時間を引きずらず即完了する） ==="
# watchdogサブシェルの標準入出力を継承したままだと、呼び出し元が
# command substitutionでフックの出力を受け取っている場合、LIST_CMDが
# すぐ終わってもwatchdogのsleepがpipeの書き込み端を握ったままになり、
# sleepが終わるまで呼び出し元の`$(...)`が完了しない回帰を防ぐ。
start_ts=$(date +%s)
run_hook "Project 3番" "$STUB_LIST_CMD"
end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))
if [ "$elapsed" -le 1 ] && [ -n "$HOOK_STDOUT" ] && [ -z "$HOOK_STDERR" ] && [ "$HOOK_EXIT" -eq 0 ]; then
  pass "即時応答のLIST_CMDは0秒程度で即完了する（実測 ${elapsed}s）"
else
  fail_case "即時応答のLIST_CMDは0秒程度で即完了する (実測 ${elapsed}s, out=[$HOOK_STDOUT] err=[$HOOK_STDERR] exit=$HOOK_EXIT)"
fi

echo "=== AC-4続き: 検証3・4巡目 BLOCKING #1・MAJOR #2（SIGTERMを無視するLIST_CMDも打ち切り、子孫を孤児化させない） ==="
# TERMをtrapで無視する設定はfork/execを越えて子プロセス（sleep）へ
# 継承されるため、group TERMだけを送って早期にwatchdogを止めると、
# 生き残ったsleepが孤児化して走り続ける不具合が実測で確認された
# （検証3巡目 MAJOR #2の追加検証）。孤児検査は`pgrep`のコマンド名一致に
# 頼らず、スタブ自身に子（sleep）のPIDをファイルへ書かせて`kill -0`で
# 直接生死を確認する（`pgrep`自体が失敗して0件を返すと空振りのまま全緑
# になっていた検証4巡目 MAJOR #2対応。「一致なし」と「pgrep実行不能」を
# 区別する）。
IGNORE_TERM_LIST_CMD="$WORK_DIR/cmux-next-watch-ignore-term.sh"
IGNORE_TERM_PIDFILE="$WORK_DIR/ignore-term-child.pid"
rm -f "$IGNORE_TERM_PIDFILE"
cat >"$IGNORE_TERM_LIST_CMD" <<EOF
#!/bin/bash
trap '' TERM
if [ "\$1" = "--list" ]; then
  sleep 8 &
  echo \$! >"$IGNORE_TERM_PIDFILE"
  wait
  printf '1\tcmux-session-todo\tv2 1/3\t稼働中\n'
fi
EOF
chmod +x "$IGNORE_TERM_LIST_CMD"
start_ts=$(date +%s)
run_hook "Project 3番" "$IGNORE_TERM_LIST_CMD"
end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))
sleep 0.3
if [ ! -f "$IGNORE_TERM_PIDFILE" ]; then
  fail_case "SIGTERMを無視するLIST_CMDの子孫検査 (PIDファイルが作られなかった＝スタブが起動できていない可能性)"
else
  child_pid="$(cat "$IGNORE_TERM_PIDFILE")"
  if kill -0 "$child_pid" 2>/dev/null; then
    fail_case "SIGTERMを無視するLIST_CMDも打ち切られ子孫も残らない (子プロセス pid=$child_pid がまだ生きている＝孤児化)"
    kill -KILL "$child_pid" 2>/dev/null
  elif [ "$elapsed" -le 4 ] && [ -z "$HOOK_STDOUT" ] && [ -z "$HOOK_STDERR" ] && [ "$HOOK_EXIT" -eq 0 ]; then
    pass "SIGTERMを無視するLIST_CMDも打ち切られ、子孫(pid=$child_pid)も残らない（実測 ${elapsed}s）"
  else
    fail_case "SIGTERMを無視するLIST_CMDも打ち切られる (実測 ${elapsed}s, out=[$HOOK_STDOUT] err=[$HOOK_STDERR] exit=$HOOK_EXIT)"
  fi
fi

echo "=== AC-4続き: 検証5巡目 MAJOR #2（deadline到達時、TERMハンドラで後始末する子孫に0.3秒の猶予が渡る） ==="
# LIST_CMDがTERMを捕まえて0.2秒の後始末をしてから終了する場合、猶予
# 0.3秒より短いのでhandler-start・handler-doneの両方のマーカーが揃う
# はず。旧実装はcmd_pidの生死に関わらず無条件で即座にgroup KILLしていた
# ため、猶予が実質0秒になりhandler-doneが記録されなかった（検証5巡目
# MAJOR #2）。
TERM_CLEANUP_LIST_CMD="$WORK_DIR/cmux-next-watch-term-cleanup.sh"
TERM_CLEANUP_MARKER="$WORK_DIR/term-cleanup-marker.log"
rm -f "$TERM_CLEANUP_MARKER"
cat >"$TERM_CLEANUP_LIST_CMD" <<EOF
#!/bin/bash
MARKER="$TERM_CLEANUP_MARKER"
cleanup() {
  echo "handler-start" >>"\$MARKER"
  sleep 0.2
  echo "handler-done" >>"\$MARKER"
  exit 0
}
trap cleanup TERM
if [ "\$1" = "--list" ]; then
  sleep 10
fi
EOF
chmod +x "$TERM_CLEANUP_LIST_CMD"
run_hook "Project 3番" "$TERM_CLEANUP_LIST_CMD"
sleep 0.1
marker_content="$(cat "$TERM_CLEANUP_MARKER" 2>/dev/null)"
if printf '%s' "$marker_content" | grep -qF "handler-start" && printf '%s' "$marker_content" | grep -qF "handler-done"; then
  pass "TERMハンドラの0.2秒の後始末（handler-start/handler-done）が完走する"
else
  fail_case "TERMハンドラの0.2秒の後始末が完走する (marker=[$marker_content])"
fi

echo "=== AC-4続き: 検証4巡目 MINOR #3（hook自身がSIGTERMで終了しても一時ファイルが残らない） ==="
# 判定用jqをハングさせ、hook起動直後にhookプロセス自身へSIGTERMを送る。
# TMPDIRをテスト専用ディレクトリへ切り替え、mktempが作る一時ファイルが
# hook終了後に残っていないかを直接検査する。
HOOK_TMPDIR="$WORK_DIR/hook-tmpdir"
mkdir -p "$HOOK_TMPDIR"
HANGJQ_BIN="$WORK_DIR/hangjq-bin"
mkdir -p "$HANGJQ_BIN"
cat >"$HANGJQ_BIN/jq" <<'EOF'
#!/bin/bash
trap '' TERM
sleep 30
EOF
chmod +x "$HANGJQ_BIN/jq"
json_input="$(jq -n --arg p "Project 3番" '{prompt:$p}')"
printf '%s' "$json_input" | TMPDIR="$HOOK_TMPDIR" PATH="$HANGJQ_BIN:$PATH" NEXT_RESOLVE_LIST_CMD="$STUB_LIST_CMD" bash "$HOOK" >"$WORK_DIR/sigterm-hook.out" 2>"$WORK_DIR/sigterm-hook.err" &
sigterm_hook_pid=$!
sleep 0.2
kill -TERM "$sigterm_hook_pid" 2>/dev/null
wait "$sigterm_hook_pid" 2>/dev/null
sleep 0.3
sigterm_out="$(cat "$WORK_DIR/sigterm-hook.out" 2>/dev/null)"
sigterm_err="$(cat "$WORK_DIR/sigterm-hook.err" 2>/dev/null)"
leftover_count="$(ls -A "$HOOK_TMPDIR" 2>/dev/null | wc -l | tr -d ' ')"
if [ -z "$sigterm_out" ] && [ -z "$sigterm_err" ] && [ "$leftover_count" -eq 0 ]; then
  pass "hook自身がSIGTERMで終了しても一時ファイルが残らない（無出力・stderrなし）"
else
  fail_case "hook自身がSIGTERMで終了しても一時ファイルが残らない (out=[$sigterm_out] err=[$sigterm_err] leftover=$leftover_count)"
fi

echo "=== AC-4続き: 検証2巡目 MAJOR #3（watchdogが追加した外部コマンドの失敗もstderrへ漏らさない） ==="
MKTEMP_FAIL_BIN="$WORK_DIR/mktemp-fail-bin"
mkdir -p "$MKTEMP_FAIL_BIN"
cat >"$MKTEMP_FAIL_BIN/mktemp" <<'EOF'
#!/bin/bash
echo "mktemp: fake failure" >&2
exit 1
EOF
chmod +x "$MKTEMP_FAIL_BIN/mktemp"
json_input="$(jq -n --arg p "Project 3番" '{prompt:$p}')"
HOOK_STDOUT="$(printf '%s' "$json_input" | PATH="$MKTEMP_FAIL_BIN:$PATH" NEXT_RESOLVE_LIST_CMD="$STUB_LIST_CMD" bash "$HOOK" 2>"$STDERR_TMP")"
HOOK_EXIT=$?
HOOK_STDERR="$(cat "$STDERR_TMP" 2>/dev/null)"
assert_fail_silent "mktempが失敗してもstderrへ漏らさずfail-silent"

echo "=== AC-5: bash 3.2 互換の静的検査 ==="
if /bin/bash -n "$HOOK"; then
  pass "/bin/bash -n が通る（macOS bash 3.2 互換）"
else
  fail_case "/bin/bash -n が通る（macOS bash 3.2 互換）"
fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
