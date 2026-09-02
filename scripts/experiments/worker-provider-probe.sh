#!/usr/bin/env bash
#
# 使い捨て実験スクリプト（2026-09-02）検証後に削除すること。
# Throwaway experiment script (2026-09-02) — delete after verification is done.
#
# 目的（JA）:
#   Bedrock 経由で起動しているリーダーセッション（環境に
#   CLAUDE_CODE_USE_BEDROCK=1 / AWS_REGION / AWS_PROFILE /
#   ANTHROPIC_DEFAULT_*_MODEL が入っている）の Bash から `claude -p` を
#   別プロセスとして起動したとき、サブスク（Anthropic ログイン）側の
#   provider で動かせるかを、5つのバリアントで実測して1行ずつ比較する。
#   何も書き換えない読み取り専用の確認用スクリプト。
#
# Purpose (EN):
#   Probe whether `claude -p` (spawned as a separate process from Bash while
#   the parent leader session is running via Bedrock, i.e. with
#   CLAUDE_CODE_USE_BEDROCK=1 / AWS_REGION / AWS_PROFILE /
#   ANTHROPIC_DEFAULT_*_MODEL set in the environment) can be made to run
#   against the subscription (Claude.ai OAuth login) provider instead, by
#   trying 5 variants of env/settings overrides and comparing one summary
#   line per variant. Read-only — this script does not modify anything.
#
# 使い方（JA） / Usage (EN):
#   git pull 後に、このリポジトリのルートから実行する:
#     bash scripts/experiments/worker-provider-probe.sh
#   （実行属性が付いているので ./scripts/experiments/worker-provider-probe.sh でも可）
#   Run from the repo root after `git pull`:
#     bash scripts/experiments/worker-provider-probe.sh
#   (executable bit is set, so ./scripts/experiments/worker-provider-probe.sh also works)
#
# バリアント（JA）:
#   A) 素の継承        : そのまま `claude -p ...`
#   B) env除去          : `env -u CLAUDE_CODE_USE_BEDROCK -u AWS_PROFILE -u AWS_REGION claude -p ...`
#   C) --settings "0"   : `--settings '{"env":{"CLAUDE_CODE_USE_BEDROCK":"0"}}'`
#   D) --settings ""    : `--settings '{"env":{"CLAUDE_CODE_USE_BEDROCK":""}}'`
#   E) B + C 併用       : env除去と --settings "0" の両方
#
# 安全のための制約（JA）:
#   - 各バリアントに 90 秒のタイムアウト（macOS 標準 bash には timeout/gtimeout が
#     無い前提で、プロセスグループごと kill する実装。参考:
#     Knowledge/macos-bash-timeout-process-group.md）。
#   - ツール実行はさせない（--allowedTools "" と --permission-mode plan の併用）。
#   - API キー等の値は一切表示しない。環境変数は「名前と set/unset の有無」のみ表示する。
#   - 何もファイルを書き換えない（一時ディレクトリのみ使用、終了時に削除）。
#
# Safety constraints (EN):
#   - 90s timeout per variant, implemented via process-group kill (macOS stock
#     bash has no timeout/gtimeout). See Knowledge/macos-bash-timeout-process-group.md.
#   - Tool use is disabled for the probed `claude -p` calls (--allowedTools ""
#     plus --permission-mode plan).
#   - Never prints secret values — only env var names and set/unset status.
#   - Read-only: writes only to a temp dir that is removed on exit.

set -euo pipefail

TIMEOUT_SECS=90
PROMPT="Reply with exactly: OK"

if ! command -v claude >/dev/null 2>&1; then
  echo "ERROR: claude コマンドが見つかりません（PATH を確認してください） / claude command not found in PATH" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq コマンドが見つかりません / jq command not found in PATH" >&2
  exit 1
fi

OUTDIR=$(mktemp -d "${TMPDIR:-/tmp}/worker-provider-probe.XXXXXX")

# 実行中の子プロセス(グループ)のPID。SIGINT/TERM/HUP受信時にここを見て
# プロセスグループごと kill する。run_with_timeout 実行中のみ非空。
# PID of the currently-running child (process group). Signal handler below
# uses this to kill the whole group on SIGINT/TERM/HUP. Non-empty only while
# run_with_timeout is running.
CURRENT_PID=""
LAST_RC=0
LAST_TIMED_OUT=0

# 直接の子(リーダー)PIDではなく、プロセスグループ(-PGID)宛てに送る。
# リーダーが先に終了していても、同じグループの孫プロセスが残っていれば
# グループIDは有効なままなので、存在確認なしで送っても無害
# (該当なしなら kill は失敗するだけ = || true で握りつぶす)。
# Send to the process group (-PGID), not just the direct child PID: even
# if the leader already exited, a stray grandchild in the same group keeps
# the pgid alive. Sending unconditionally is harmless when there is
# nothing left (kill just fails, suppressed by || true).
sweep_group() {
  local pgid="$1" grace_secs="${2:-1}"
  [ -z "$pgid" ] && return 0
  # TERM が実際に何かへ届いた場合のみ猶予をおいて KILL する
  # (何も残っていなければ kill は失敗するだけで、余計な sleep もしない)。
  # Only wait-and-KILL if TERM actually reached something (if nothing is
  # left, kill just fails and we skip the extra sleep).
  if kill -TERM -- -"$pgid" 2>/dev/null; then
    sleep "$grace_secs"
    kill -KILL -- -"$pgid" 2>/dev/null || true
  fi
}

cleanup() {
  sweep_group "$CURRENT_PID"
  rm -rf "$OUTDIR"
}
trap cleanup EXIT
on_term_signal() {
  local exit_code="$1"
  cleanup
  trap - EXIT
  exit "$exit_code"
}
# シグナルごとに慣例の終了コードを使う (128+シグナル番号: INT=130, HUP=129, TERM=143)。
# Use the conventional exit code per signal (128+signum: INT=130, HUP=129, TERM=143).
trap 'on_term_signal 130' INT
trap 'on_term_signal 143' TERM
trap 'on_term_signal 129' HUP

# --- 90秒タイムアウト付きでコマンドを実行し、標準出力/エラーを $1 に書く ---
# --- Run a command with a 90s timeout, writing stdout/stderr to $1 ---
# macOS 標準 bash に timeout/gtimeout が無いため、ジョブ制御で新しい
# プロセスグループを作らせ、タイムアウト時はグループごと kill する。
# 結果は LAST_RC / LAST_TIMED_OUT (グローバル) に入れる。タイムアウト時は
# 対象プロセスの実際の終了コードに関わらず LAST_RC=124 に固定する
# （TERM を自前ハンドラで正常終了扱いする対象があっても誤って exit=0 と
# 表示しないため）。
# Results go into the globals LAST_RC / LAST_TIMED_OUT. On timeout, LAST_RC
# is forced to 124 regardless of the target's actual wait status (so a
# process that traps TERM and exits 0 is not misreported as success).
run_with_timeout() {
  local outfile="$1"
  shift
  local waited=0 timed_out=0 rc

  set -m
  ( "$@" >"$outfile" 2>&1 ) &
  CURRENT_PID=$!
  set +m

  while kill -0 "$CURRENT_PID" 2>/dev/null; do
    if [ "$waited" -ge "$TIMEOUT_SECS" ]; then
      timed_out=1
      sweep_group "$CURRENT_PID" 2
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done

  if wait "$CURRENT_PID" 2>/dev/null; then
    rc=0
  else
    rc=$?
  fi

  # リーダー(直接の子)は終了していても、同じプロセスグループの孫が
  # 残っている場合がある。CURRENT_PID を空にする前にグループを掃除する
  # (タイムアウト経路で既にKILL済みでも、対象が無ければ sweep_group は無害)。
  # The leader (direct child) may have exited while a grandchild in the same
  # process group is still running. Sweep the group before clearing
  # CURRENT_PID (harmless no-op if nothing is left, e.g. already killed
  # above on the timeout path).
  sweep_group "$CURRENT_PID"
  CURRENT_PID=""

  if [ "$timed_out" -eq 1 ]; then
    LAST_RC=124
    LAST_TIMED_OUT=1
  else
    LAST_RC=$rc
    LAST_TIMED_OUT=0
  fi
}

# --- stream-json (NDJSON) の出力から安全にフィールドを取り出す ---
# --- Safely extract a field from stream-json (NDJSON) output ---
# タイムアウトで kill された場合、末尾の行が途中で切れて不正 JSON になりうる。
# 1行ずつ fromjson を試み、パースできない行は捨ててから集計する。
# On timeout-kill the last line may be truncated/invalid JSON; parse line by
# line with fromjson and drop unparseable lines before aggregating.
parse_field() {
  local outfile="$1" jqfilter="$2" val
  val=$(jq -R 'fromjson? // empty' "$outfile" 2>/dev/null | jq -rs "$jqfilter" 2>/dev/null)
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    val="?"
  fi
  # 改行/CR/タブが混じっていても必ず1行に収める（1バリアント1行の表示を保証）。
  # すべての抽出フィールドがここを通るので個別サニタイズは不要。
  # Collapse newlines/CR/tabs so every extracted field is single-line; since
  # all fields go through here, no per-field sanitization is needed elsewhere.
  val=$(printf '%s' "$val" | tr '\n\r\t' '   ')
  printf '%s' "$val"
}

report() {
  local name="$1" outfile="$2" rc="$3" timed_out="$4"
  local model apikey provider result_text timeout_tag

  model=$(parse_field "$outfile" '[.[] | select(.type=="system" and .subtype=="init")][0].model // "?"')
  apikey=$(parse_field "$outfile" '[.[] | select(.type=="system" and .subtype=="init")][0].apiKeySource // "?"')
  provider=$(parse_field "$outfile" '(([.[] | select(.type=="result")][0].modelUsage // {}) | to_entries[0].value.provider) // "?"')
  result_text=$(parse_field "$outfile" '[.[] | select(.type=="result")][0].result // "?"')

  timeout_tag="no"
  [ "$timed_out" -eq 1 ] && timeout_tag="yes(124)"

  printf '%-26s model=%-20s apiKeySource=%-14s provider=%-12s result=%-8s exit=%-5s timeout=%s\n' \
    "$name" "$model" "$apikey" "$provider" "$result_text" "$rc" "$timeout_tag"
}

run_variant() {
  local name="$1"
  shift
  local outfile="$OUTDIR/$(echo "$name" | tr -c 'A-Za-z0-9' '_').json"
  run_with_timeout "$outfile" "$@"
  report "$name" "$outfile" "$LAST_RC" "$LAST_TIMED_OUT"
}

echo "=== 関連env変数の有無（名前のみ・値は非表示） / relevant env vars presence (names only, no values) ==="
for v in CLAUDE_CODE_USE_BEDROCK AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION \
         ANTHROPIC_API_KEY ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL \
         ANTHROPIC_DEFAULT_HAIKU_MODEL; do
  # ${!v+x} は「変数が定義されているか」（空文字での定義も含む）を、値を
  # 展開せずに判定する。${!v:-} だと空文字定義を unset と誤判定するため使わない。
  # ${!v+x} tests whether the var is defined (even if empty) without
  # expanding its value; ${!v:-} would misreport an empty-but-set var as unset.
  if [ "${!v+x}" = "x" ]; then
    echo "  $v: set"
  else
    echo "  $v: unset"
  fi
done

echo
echo "=== claude -p provider probe (5 variants, timeout ${TIMEOUT_SECS}s each) ==="

COMMON_ARGS=(-p "$PROMPT" --output-format stream-json --verbose --allowedTools "" --permission-mode plan)

run_variant "A: plain inheritance" \
  claude "${COMMON_ARGS[@]}"

run_variant "B: env -u removal" \
  env -u CLAUDE_CODE_USE_BEDROCK -u AWS_PROFILE -u AWS_REGION \
  claude "${COMMON_ARGS[@]}"

run_variant "C: --settings \"0\"" \
  claude "${COMMON_ARGS[@]}" --settings '{"env":{"CLAUDE_CODE_USE_BEDROCK":"0"}}'

run_variant "D: --settings \"\"" \
  claude "${COMMON_ARGS[@]}" --settings '{"env":{"CLAUDE_CODE_USE_BEDROCK":""}}'

run_variant "E: B + C combined" \
  env -u CLAUDE_CODE_USE_BEDROCK -u AWS_PROFILE -u AWS_REGION \
  claude "${COMMON_ARGS[@]}" --settings '{"env":{"CLAUDE_CODE_USE_BEDROCK":"0"}}'

echo
echo "=== done ==="
