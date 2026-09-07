#!/usr/bin/env bash
# Codex 呼び出しの唯一の口（`codex exec` をラップする）。
#
# 背景: Claude CodeからCodexを呼ぶ経路をMCPサーバー経由からこのexecラッパー
# （CLI・背景実行）へ一本化した（2026-09-06 本人決定）。理由＝公式でCodexの
# MCPサーバー起動サブコマンドが非推奨／MCP経由はweb_search不可（2026-09-06
# 実測）／長時間タスクでabort・接続死の実績／戻り値が呼び出し元の文脈に必ず
# 入る。詳細は docs/core-split/codex-exec-only-検討経緯-2026-09-06.md。
#
# 実測済みの起動の型は Preferences/codex-exec-worker.md
# （[[Preferences/codex-exec-worker]]）。本スクリプトはその型をコマンド化した
# ものであり、呼び出し側（ワーカー・職種定義）は本スクリプトだけを叩けばよい。
#
# 使い方:
#   scripts/codex-exec.sh --cwd <絶対パス> --sandbox read-only|workspace-write \
#     --out <絶対パス> --prompt-file <file>|- \
#     [--search] [--resume <thread_id>] [--developer-instructions <file>] \
#     [--model <model>] [--effort <effort>]
#
# 絶対厳守④の機械強制（[[Preferences/absolute-rules]]）: 依頼文（プロンプト）に
# "absolute-rules" の文字列が含まれていなければ、codex を起動せず exit 2 で
# 終了する。`codex exec` は Claude Code の PreToolUse フックの対象外（MCP経路の
# ように自動で検査されない）ため、ここで肩代わりする。継続（--resume）でも
# 同じ検査を行う（省略不可）。
#
# stdout は次の3行のみを出す（それ以外は書かない。呼び出し元の文脈を汚さない
# ため）:
#   THREAD_ID:<id>
#   OUT:<path>
#   EXIT:<code>
# `--json` のイベントストリームは <out>.events.jsonl、標準エラーは
# <out>.stderr.log に保存するだけで、本スクリプト自身は読み上げない
# （調査が要るときだけ呼び出し側がファイルを直接読む）。
#
# 本体は前景で終了まで待つ（`codex exec` 自体を背景実行させたい場合は、
# 呼び出し側が本スクリプトごと Bash の run_in_background で包むこと）。
#
# 依存: codex（PATH上にあること）。thread_id 抽出には jq か python3 の
# どちらかがあればよい（両方無ければ簡易sedへフォールバック）。
# `--developer-instructions` を使う場合は jq か python3 のどちらかが必須
# （TOML文字列として安全にエンコードするため。無ければ exit 1 で拒否する）。
# macOS 同梱 /bin/bash 3.2 で動作する（連想配列不使用・`read -N`不使用）。

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"

CWD=""
SANDBOX=""
OUT=""
PROMPT_FILE=""
SEARCH=0
RESUME_ID=""
DEV_INSTR_FILE=""
MODEL=""
EFFORT=""

usage() {
  cat >&2 <<EOF
使い方: $SCRIPT_NAME --cwd <絶対パス> --sandbox read-only|workspace-write \\
  --out <絶対パス> --prompt-file <file>|- \\
  [--search] [--resume <thread_id>] [--developer-instructions <file>] \\
  [--model <model>] [--effort <effort>]
EOF
}

fail_usage() {
  echo "[$SCRIPT_NAME] FAIL: $*" >&2
  usage
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cwd)
      [ $# -ge 2 ] || fail_usage "--cwd には値が必要です"
      CWD="$2"; shift 2 ;;
    --sandbox)
      [ $# -ge 2 ] || fail_usage "--sandbox には値が必要です"
      SANDBOX="$2"; shift 2 ;;
    --out)
      [ $# -ge 2 ] || fail_usage "--out には値が必要です"
      OUT="$2"; shift 2 ;;
    --prompt-file)
      [ $# -ge 2 ] || fail_usage "--prompt-file には値が必要です"
      PROMPT_FILE="$2"; shift 2 ;;
    --search)
      SEARCH=1; shift ;;
    --resume)
      [ $# -ge 2 ] || fail_usage "--resume には値が必要です"
      RESUME_ID="$2"; shift 2 ;;
    --developer-instructions)
      [ $# -ge 2 ] || fail_usage "--developer-instructions には値が必要です"
      DEV_INSTR_FILE="$2"; shift 2 ;;
    --model)
      [ $# -ge 2 ] || fail_usage "--model には値が必要です"
      MODEL="$2"; shift 2 ;;
    --effort)
      [ $# -ge 2 ] || fail_usage "--effort には値が必要です"
      EFFORT="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      fail_usage "不明な引数: $1" ;;
  esac
done

[ -n "$CWD" ] || fail_usage "--cwd は必須です"
[ -n "$SANDBOX" ] || fail_usage "--sandbox は必須です"
[ -n "$OUT" ] || fail_usage "--out は必須です"
[ -n "$PROMPT_FILE" ] || fail_usage "--prompt-file は必須です"

case "$CWD" in
  /*) ;;
  *) fail_usage "--cwd は絶対パスで指定してください: $CWD" ;;
esac
[ -d "$CWD" ] || fail_usage "--cwd のディレクトリが存在しません: $CWD"

case "$OUT" in
  /*) ;;
  *) fail_usage "--out は絶対パスで指定してください: $OUT" ;;
esac

case "$SANDBOX" in
  read-only|workspace-write) ;;
  *) fail_usage "--sandbox は read-only か workspace-write のみ指定できます: $SANDBOX" ;;
esac

if [ -n "$DEV_INSTR_FILE" ]; then
  [ -r "$DEV_INSTR_FILE" ] || fail_usage "--developer-instructions のファイルが読めません: $DEV_INSTR_FILE"
fi

# --- 依頼文（プロンプト）の読み込み ---
if [ "$PROMPT_FILE" = "-" ]; then
  PROMPT="$(cat)"
else
  [ -r "$PROMPT_FILE" ] || fail_usage "--prompt-file のファイルが読めません: $PROMPT_FILE"
  PROMPT="$(cat "$PROMPT_FILE")"
fi

[ -n "$PROMPT" ] || fail_usage "依頼文が空です"

# --- 絶対厳守④の機械強制（--resume でも同じ検査。省略不可） ---
# 注意（仕様として明記＝Codex一次レビュー指摘・2巡目）: この検査は単純な
# 部分一致であり、旧・Claude Code側PreToolUseフック（`grep -q
# 'absolute-rules'`）と意図的に同じ強度に揃えている。悪意ある依頼への
# セキュリティ境界ではなく、「absolute-rulesを読む指示の書き忘れ防止」が
# 目的。大文字小文字や偽装文字列（例: "do-not-read-absolute-rules"）でも
# 通過しうるが、依頼文を書くのは信頼された呼び出し元（Claudeワーカー・
# Codex自身）である前提のため許容している。
case "$PROMPT" in
  *absolute-rules*) ;;
  *)
    echo "[$SCRIPT_NAME] FAIL: 依頼文に absolute-rules への参照がありません。Preferences/absolute-rules.md（[[Preferences/absolute-rules]]）を読む指示を依頼文に含めてください。" >&2
    exit 2
    ;;
esac

command -v codex >/dev/null 2>&1 || fail_usage "codex コマンドが見つかりません（PATHを確認してください）"

EVENTS_FILE="${OUT}.events.jsonl"
STDERR_FILE="${OUT}.stderr.log"
OUT_DIR="$(dirname "$OUT")"
mkdir -p "$OUT_DIR" || fail_usage "--out の出力先ディレクトリを作成できません: $OUT_DIR"
# ディレクトリが既に存在するケースは mkdir -p 自体は成功する（何もせず正常
# 終了する）ため、書き込み可否を別途確認する（Codex一次レビュー指摘・
# 2巡目Minor: 既存だが書き込み不能なディレクトリだと、この時点では検出
# できず、後段のリダイレクト失敗＝codex自体が起動されない状態で気づく
# ことになる）。
[ -w "$OUT_DIR" ] || fail_usage "--out の出力先ディレクトリに書き込めません: $OUT_DIR"

# --search は codex 本体のグローバル位置オプション（`exec` サブコマンドより前）。
GLOBAL_OPTS=()
[ "$SEARCH" = "1" ] && GLOBAL_OPTS+=(--search)

EXEC_OPTS=(--skip-git-repo-check -s "$SANDBOX" -C "$CWD" --json -o "$OUT")
[ -n "$MODEL" ] && EXEC_OPTS+=(-m "$MODEL")
[ -n "$EFFORT" ] && EXEC_OPTS+=(-c "model_reasoning_effort=$EFFORT")
if [ -n "$DEV_INSTR_FILE" ]; then
  # 値は必ずTOML文字列としてエンコードしてから渡す（jq -Rs優先・無ければ
  # python3のjson.dumpsで代替。JSON文字列のエスケープ規則はTOML基本文字列と
  # 互換）。生テキストのままだと、内容がたまたま `["a","b"]` や `true` 等の
  # 有効なTOMLリテラルに見える場合、文字列ではなく配列・真偽値として解釈
  # され `invalid type` エラーで codex 自体が起動に失敗する（実測確認済み・
  # Codex一次レビュー指摘・Major）。
  if command -v jq >/dev/null 2>&1; then
    DEV_INSTR_TOML_VALUE="$(jq -Rs . < "$DEV_INSTR_FILE")" || fail_usage "--developer-instructions のファイルをエンコードできません: $DEV_INSTR_FILE"
  elif command -v python3 >/dev/null 2>&1; then
    # ensure_ascii=False が必須（Codex一次レビュー指摘・2巡目Major）:
    # 既定のensure_ascii=Trueは絵文字等のBMP外文字をUTF-16サロゲート
    # ペア（例: 😀）にエスケープするが、TOMLの仕様は単独の
    # サロゲートコードポイントを許さないためTOML解析に失敗し、生文字列
    # フォールバックでも元の文字へ復元されない実測不具合があった。
    DEV_INSTR_TOML_VALUE="$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read(), ensure_ascii=False))' < "$DEV_INSTR_FILE")" || fail_usage "--developer-instructions のファイルをエンコードできません: $DEV_INSTR_FILE"
  else
    fail_usage "--developer-instructions の安全なエンコードに jq か python3 が必要です（どちらもPATH上にありません）"
  fi
  EXEC_OPTS+=(-c "developer_instructions=$DEV_INSTR_TOML_VALUE")
fi

# resume は共通オプション（-s/-C/-o/--json 等）より後ろに置く（実測済みの型）。
# `--` で以降を全てpositional（session_id・prompt）扱いにする＝session_idが
# 万一ハイフンから始まっても（例: `--last` 相当の文字列）オプションとして
# 誤解釈されない（Codex一次レビュー指摘・Major）。
RESUME_ARGS=()
[ -n "$RESUME_ID" ] && RESUME_ARGS=(resume -- "$RESUME_ID")

# 依頼文（プロンプト）はargvへ直接載せず、標準入力へパイプし、positional
# 引数には常に `-`（stdinから読む指示）だけを渡す（Codex一次レビュー
# 指摘・Major）。理由は2つ: ①依頼文がハイフンから始まる場合にcodexの引数
# パーサーへオプションとして誤解釈されるのを防ぐ ②巨大な依頼文がOSの
# ARG_MAX上限に達するのを避ける。`printf`がパイプを閉じることでEOFが届く
# ため、`</dev/null`は不要（stdinソースが1つだけになり、追加入力待ちは
# 発生しない）。
# 配列展開は `${ARR[@]+"${ARR[@]}"}` 形式にする＝bash 3.2（macOS同梱）は
# `set -u` 下で「要素0個の配列」の `"${ARR[@]}"` 展開を unbound variable
# 扱いにする既知の挙動があり、素の `"${ARR[@]}"` だと GLOBAL_OPTS/RESUME_ARGS
# が空のときに落ちる（実測）。
printf '%s' "$PROMPT" | codex ${GLOBAL_OPTS[@]+"${GLOBAL_OPTS[@]}"} exec "${EXEC_OPTS[@]}" ${RESUME_ARGS[@]+"${RESUME_ARGS[@]}"} - \
  > "$EVENTS_FILE" 2> "$STDERR_FILE"
CODEX_EXIT=$?

# --- thread_id の抽出（events.jsonl の thread.started 行から）。
# jq優先・無ければpython3・それも無ければ簡易sedへフォールバックする
# （sedのみ、キーと値の間の空白揺れを許容する＝Codex一次レビュー指摘・Minor。
# jq/python3経路はJSONパーサーなので元々空白の有無に依存しない）。
THREAD_ID=""
LINE="$(grep -m1 '"type"[[:space:]]*:[[:space:]]*"thread.started"' "$EVENTS_FILE" 2>/dev/null || true)"
if [ -n "$LINE" ]; then
  if command -v jq >/dev/null 2>&1; then
    THREAD_ID="$(printf '%s' "$LINE" | jq -r '.thread_id // empty' 2>/dev/null || true)"
  elif command -v python3 >/dev/null 2>&1; then
    THREAD_ID="$(printf '%s' "$LINE" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("thread_id",""))' 2>/dev/null || true)"
  else
    THREAD_ID="$(printf '%s' "$LINE" | sed -n 's/.*"thread_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  fi
fi

echo "THREAD_ID:${THREAD_ID}"
echo "OUT:${OUT}"
echo "EXIT:${CODEX_EXIT}"

exit "$CODEX_EXIT"
