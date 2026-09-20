#!/usr/bin/env bash
# scripts/claude-exec.sh — Claude ワーカー（`claude -p --agent <職種名>`）の
# 唯一の呼び出し口（別プロセス化）。設計: docs/design-v1.1.1.md §2（D-1）。
#
# 使い方:
#   scripts/claude-exec.sh --role <職種名> --prompt-file <絶対パス> \
#     --out <絶対パス> --task-id <id> --model-def <定義名> \
#     [--resume <session_id>] [--force] [--dry-run]
#
# 標準出力は4行だけ（dry-runを除く。子の起動を試みた呼び出しでのみ出す）:
#   SESSION_ID:<子のsession_idか空>
#   OUT:<--outのパス>
#   REASON:<失敗分類 か ->
#   EXIT:<終了コード>
# dry-run はこの4行契約の外（FR-17＝選ばれた候補の定義名・--modelの値・
# effortの値と渡し口・注入する環境変数の名前・組み立てた引数列を印字。
# 値・依頼文の本文は出さない）。
#
# 子を起動した呼び出しでは --out の確定と同時に <out>.stderr（子の標準
# エラー全文。分類には使わない＝設計§2.8のまま）も隣に残す（DR1-M2）。
# dry-runでは作らない。
#
# Spawn contract (moved from README "Roles" 2026-09-19, verbatim):
# Worker models are selected per spawn from profile candidates. Run `resolve-candidate` with the deployed `--agents-dir`; for subagent execution, pass the returned `AGENT_MODEL` value explicitly as `Agent.model`. Do not spawn on a nonzero exit or malformed output. The Agent guard rejects missing or invalid model arguments for the managed roles (= the definitions under `claude/agents/`). Legacy Claude IDs and non-anthropic-api subagent providers are rejected; external-cli retains `CODEX_ARGS`.
# A role that has candidates in the local profile is not launched in-process via the `Agent` tool (a `PreToolUse` hook rejects that) — it's launched as a separate `claude -p` process through `scripts/claude-exec.sh` (a Bash wrapper mirroring `scripts/codex-exec.sh`'s contract; see "claude-exec.sh" below for the invocation form, how to read the worker's report, and how to recover from a stale lock).
#
# Reading the worker's report / recovering from a leftover lock / `effort:` (moved from README "claude-exec.sh" 2026-09-19, verbatim):
# **Reading the worker's report**: the worker's actual final report is the `result` field inside the JSON written to `--out` once the call has completed — read it with `jq -r '.result' <out>`, not the wrapper's own stdout. Any deliverable files the worker produces are written by the worker itself into its own working directory (the parent directory of `--out`, under a name the request text specifies) — the worker never writes to `--out` itself, since the wrapper only creates that file once, atomically, at the end of the run.
# **Recovering from a leftover lock**: while a call is in flight it reserves `--out` with a `<out>.lock` file; if a previous run was killed before it could release that reservation, the next call to the same `--out` fails until the stale lock is cleared — remove it manually (`rm <out>.lock`) before retrying.
# **`effort:`**: the wrapper resolves `--effort` fresh on every call from the local profile's candidate (via `resolve-candidate`) and passes it straight to `claude -p` — role definitions under `~/.claude/agents/<role>.md` never carry an `effort:` frontmatter line (that per-role generation scheme was retired once the wrapper started resolving effort itself).
#
# 終了コード表（設計§2.9・要件requirements-v1.4.3.md §12に転記済み）:
#   0成功/1想定外(予約)/2引数不正/3候補外の定義名/4配役表・定義の解決失敗/
#   5モデル明示の強制違反/6依頼文が読めない・absolute-rules参照無し/
#   7成果物置き場の上書き拒否・並行呼び出し/8前提不備/9子cwdの前提不備/
#   10上限到達/11認証失敗/12タイムアウト/13権限不足/14その他/15確定失敗
#
# 環境変数（既定は設計§2.2）:
#   CLAUDE_CODE_WRAPPER_BIN（既定 claude・FR-8の固定1キー）
#   AIENV_LOCAL_PROFILE_PATH（既定 ~/.config/takumi009-ai-env/profile.md）
#   AIENV_AGENT_SOURCE_DIR（既定 <repo>/claude/agents）
#   AIENV_CHILD_SETTINGS_SRC（既定 $HOME/.claude/settings.json）
#   AIENV_CLAUDE_EXEC_LOG（既定 $HOME/.claude/logs/claude-exec.jsonl）
#   AIENV_CLAUDE_EXEC_TIMEOUT_SECS（既定 1800）
#   GATE_MARKER_DIR（既定 /tmp）
#
# 絶対厳守④の機械強制: 依頼文に "absolute-rules" の参照が無ければ子を
# 起動せず exit 6（codex-exec.shと同じ型だが、AC-7④の引数不正=2と区別する
# ため本ラッパーは6を使う＝DR1-m7）。
#
# 依存: python3・claude（CLAUDE_CODE_WRAPPER_BINで差し替え可）・
# claude/hooks/lib/{claude_exec.py,agent_def.py,profile_resolve.py,
# guard_common.sh}（後3者は担当外＝設計§3・§7・§8の契約にのみ依存する）。
#
# macOS 同梱 /bin/bash 3.2 で動作する想定（連想配列不使用。`[[ =~ ]]`は
# bash 3.0以降で利用可）。

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$REPO_ROOT/claude/hooks/lib"

CLAUDE_EXEC_PY="$LIB_DIR/claude_exec.py"
PROFILE_RESOLVE_PY="$LIB_DIR/profile_resolve.py"
AGENT_DEF_PY="$LIB_DIR/agent_def.py"
GUARD_COMMON_SH="$LIB_DIR/guard_common.sh"

ROLE=""
PROMPT_FILE=""
OUT=""
TASK_ID=""
MODEL_DEF=""
RESUME_ID=""
FORCE=0
DRY_RUN=0

usage() {
  cat >&2 <<EOF
使い方: $SCRIPT_NAME --role <職種名> --prompt-file <絶対パス> \\
  --out <絶対パス> --task-id <id> --model-def <定義名> \\
  [--resume <session_id>] [--force] [--dry-run]
EOF
}

fail_usage() {
  echo "[$SCRIPT_NAME] FAIL: $*" >&2
  usage
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --role)
      [ $# -ge 2 ] || fail_usage "--role には値が必要です"
      ROLE="$2"; shift 2 ;;
    --prompt-file)
      [ $# -ge 2 ] || fail_usage "--prompt-file には値が必要です"
      PROMPT_FILE="$2"; shift 2 ;;
    --out)
      [ $# -ge 2 ] || fail_usage "--out には値が必要です"
      OUT="$2"; shift 2 ;;
    --task-id)
      [ $# -ge 2 ] || fail_usage "--task-id には値が必要です"
      TASK_ID="$2"; shift 2 ;;
    --model-def)
      [ $# -ge 2 ] || fail_usage "--model-def には値が必要です"
      MODEL_DEF="$2"; shift 2 ;;
    --resume)
      [ $# -ge 2 ] || fail_usage "--resume には値が必要です"
      RESUME_ID="$2"; shift 2 ;;
    --force)
      FORCE=1; shift ;;
    --dry-run)
      DRY_RUN=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      fail_usage "不明な引数: $1" ;;
  esac
done

# --- 手順1（設計§2.3）: 引数の形だけを検査。ここで失敗したら invocation_id
# を発行せず、記録も残さない（§2.3の境界＝DR1-M6）。 ------------------------
[ -n "$ROLE" ] || fail_usage "--role は必須です"
[ -n "$PROMPT_FILE" ] || fail_usage "--prompt-file は必須です"
[ -n "$OUT" ] || fail_usage "--out は必須です"
[ -n "$TASK_ID" ] || fail_usage "--task-id は必須です"
[ -n "$MODEL_DEF" ] || fail_usage "--model-def は必須です"

case "$OUT" in
  /*) ;;
  *) fail_usage "--out は絶対パスで指定してください: $OUT" ;;
esac
case "$PROMPT_FILE" in
  /*) ;;
  *) fail_usage "--prompt-file は絶対パスで指定してください: $PROMPT_FILE" ;;
esac

if ! [[ "$TASK_ID" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  fail_usage "--task-id は ^[a-z0-9][a-z0-9-]*\$ に一致しません: $TASK_ID"
fi

# --- 手順2: 親のCLAUDE_CODE_SESSION_IDを読む（FR-9の除去より前＝FR-24）。 ---
PARENT_SID="${CLAUDE_CODE_SESSION_ID:-}"

# --- 手順3: invocation_idを発行する。以後はどの経路で終わっても invocation
# 行を1行書く（dry-runを除く＝AC-17）。 --------------------------------------
INVOCATION_ID="$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n')"
if [ -z "$INVOCATION_ID" ] || [ "${#INVOCATION_ID}" -lt 16 ]; then
  # /dev/urandom が使えない異常系のフォールバック（時刻+PIDから作る）。
  INVOCATION_ID="$(printf '%016x%08x' "$(date +%s)" "$$")"
fi

BIN="${CLAUDE_CODE_WRAPPER_BIN:-claude}"
PROFILE="${AIENV_LOCAL_PROFILE_PATH:-$HOME/.config/takumi009-ai-env/profile.md}"
AGENTS_DIR="${AIENV_AGENT_SOURCE_DIR:-$REPO_ROOT/claude/agents}"
CHILD_SETTINGS_SRC="${AIENV_CHILD_SETTINGS_SRC:-$HOME/.claude/settings.json}"
EXEC_LOG="${AIENV_CLAUDE_EXEC_LOG:-$HOME/.claude/logs/claude-exec.jsonl}"
TIMEOUT_SECS="${AIENV_CLAUDE_EXEC_TIMEOUT_SECS:-1800}"
MARKER_DIR="${GATE_MARKER_DIR:-/tmp}"
export GATE_MARKER_DIR="$MARKER_DIR"

# invocation行の追記（best-effort。失敗しても呼び出し側の終了コードは
# 変えない＝NFR-2）。python3が無いときは書けない（F13＝このときだけログを
# 残せない。呼び出し元でpython3の有無を先に見ている前提だが、念のため
# ここでも二重に防御する）。
write_log() {
  # $1=exit_code $2=reason_code(空/-可) $3=child_session_id(空/-可)
  # $4=child_cwd(空/-可)
  command -v python3 >/dev/null 2>&1 || return 0
  if ! python3 "$CLAUDE_EXEC_PY" log-append \
      --log "$EXEC_LOG" \
      --invocation-id "$INVOCATION_ID" \
      --task-id "$TASK_ID" \
      --role "$ROLE" \
      --candidate-def "$MODEL_DEF" \
      --exit-code "$1" \
      --reason-code "${2:--}" \
      --artifact-path "$OUT" \
      --child-session-id "${3:--}" \
      --child-cwd "${4:--}" \
      >/dev/null 2>&1; then
    echo "[$SCRIPT_NAME] WARN: invocationログの追記に失敗しました（$EXEC_LOG）" >&2
  fi
}

# 起動前（子を1度も起動していない）失敗の共通終了処理。
fail_exit() {
  # $1=exit_code $2=reason_code(省略可)
  write_log "$1" "${2:--}" - -
  exit "$1"
}

# --- 手順4a/4b: 依頼文ファイルを読み、absolute-rules参照を検査する。 --------
if [ ! -r "$PROMPT_FILE" ]; then
  echo "[$SCRIPT_NAME] FAIL: --prompt-file のファイルが読めません: $PROMPT_FILE" >&2
  fail_exit 6 prompt_unreadable
fi
if ! grep -q "absolute-rules" "$PROMPT_FILE" 2>/dev/null; then
  echo "[$SCRIPT_NAME] FAIL: 依頼文に absolute-rules への参照がありません。Preferences/absolute-rules.md（[[Preferences/absolute-rules]]）を読む指示を依頼文に含めてください。" >&2
  fail_exit 6 absolute_rules_missing
fi

# --- 手順5: python3とclaude実行体の存在確認。 -------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  echo "[$SCRIPT_NAME] FAIL: python3 が見つかりません（PATHを確認してください）" >&2
  # F13: python3が無いのでログを残せない（write_logもpython3依存のため）。
  exit 8
fi
case "$BIN" in
  */*)
    if [ ! -x "$BIN" ]; then
      echo "[$SCRIPT_NAME] FAIL: claude 実行体が見つかりません: $BIN" >&2
      fail_exit 8 claude_binary_missing
    fi
    ;;
  *)
    if ! command -v "$BIN" >/dev/null 2>&1; then
      echo "[$SCRIPT_NAME] FAIL: claude 実行体が見つかりません（PATHを確認してください）: $BIN" >&2
      fail_exit 8 claude_binary_missing
    fi
    ;;
esac

# コマンドをタイムアウトつきで実行する（timeoutコマンドに依存しない＝FR-16
# の注記。resolverのハング検知＝F12にも使う）。RWT_TIMED_OUTに結果を返す。
RWT_TIMED_OUT=0
run_with_timeout() {
  local secs="$1"; shift
  local marker
  marker="$(mktemp)"
  rm -f "$marker"
  "$@" &
  local cmd_pid=$!
  (
    sleep "$secs"
    if kill -0 "$cmd_pid" 2>/dev/null; then
      : > "$marker"
      kill -TERM "$cmd_pid" 2>/dev/null
    fi
  ) >/dev/null 2>&1 &
  local watcher_pid=$!
  local rc=0
  wait "$cmd_pid" 2>/dev/null
  rc=$?
  # ⚠️ 順序が重要（実測で検出）＝先にwatcher本体を殺すと、`sleep`の子は
  # その時点で孤児化しPPIDが再割当てされるため、後から`pkill -P watcher_pid`
  # をかけても何も見つからず「孤児のsleepプロセスが残り続ける」（本番では
  # プロセスの無駄な蓄積・恒久テストでは呼び出し元スクリプトの標準出力
  # パイプ〈コマンド置換 `$(...)`〉を握ったままEOFが来ずハングする）。
  # 先に子（sleep）を殺し、その後に親（watcher）を殺す。
  pkill -TERM -P "$watcher_pid" 2>/dev/null
  kill "$watcher_pid" 2>/dev/null
  wait "$watcher_pid" 2>/dev/null
  if [ -f "$marker" ]; then
    RWT_TIMED_OUT=1
    rm -f "$marker" 2>/dev/null
  else
    RWT_TIMED_OUT=0
  fi
  return "$rc"
}

# --- 手順6: resolve-candidateでAGENT_MODEL/AGENT_EFFORTを得る（§2.4）。 -----
RESOLVE_OUT_FILE="$(mktemp)"
RESOLVE_ERR_FILE="$(mktemp)"
run_with_timeout 30 python3 "$PROFILE_RESOLVE_PY" resolve-candidate "$PROFILE" \
  --role "$ROLE" --model-def "$MODEL_DEF" --agents-dir "$AGENTS_DIR" \
  >"$RESOLVE_OUT_FILE" 2>"$RESOLVE_ERR_FILE"
RESOLVE_RC=$?

if [ "$RWT_TIMED_OUT" = "1" ]; then
  rm -f "$RESOLVE_OUT_FILE" "$RESOLVE_ERR_FILE"
  echo "[$SCRIPT_NAME] FAIL: resolve-candidate が期限内に応答しませんでした（30秒）" >&2
  fail_exit 4 resolver_hang
fi

if [ "$RESOLVE_RC" -ne 0 ]; then
  ERR_LINE="$(head -n1 "$RESOLVE_ERR_FILE" 2>/dev/null || true)"
  ERR_CODE="${ERR_LINE%%$'\t'*}"
  rm -f "$RESOLVE_OUT_FILE" "$RESOLVE_ERR_FILE"
  case "$ERR_CODE" in
    AGENT_MODEL_UNSUPPORTED|SUBAGENT_PROVIDER_UNSUPPORTED)
      fail_exit 5 "$ERR_CODE"
      ;;
    CANDIDATE_NOT_IN_LIST)
      # 二次判定（設計§2.4）: list-candidatesを1回呼び、①非0→4
      # ②その職種の行のdef列が空（候補0件）→4 ③check-candidateが
      # FAIL\tV17→4 ④それ以外→3。
      SECOND_CODE=4
      LIST_OUT_FILE="$(mktemp)"
      if python3 "$PROFILE_RESOLVE_PY" list-candidates "$PROFILE" >"$LIST_OUT_FILE" 2>/dev/null; then
        ROLE_ROWS="$(awk -F'\t' -v r="$ROLE" '$1==r' "$LIST_OUT_FILE")"
        HAS_DEF="$(printf '%s\n' "$ROLE_ROWS" | awk -F'\t' '$3!=""{print; exit}')"
        if [ -n "$HAS_DEF" ]; then
          CHECK_OUT="$(python3 "$PROFILE_RESOLVE_PY" check-candidate --model-def "$MODEL_DEF" 2>/dev/null)"
          case "$CHECK_OUT" in
            "FAIL"$'\t'"V17"*) SECOND_CODE=4 ;;
            *) SECOND_CODE=3 ;;
          esac
        else
          SECOND_CODE=4
        fi
      else
        SECOND_CODE=4
      fi
      rm -f "$LIST_OUT_FILE"
      fail_exit "$SECOND_CODE" CANDIDATE_NOT_IN_LIST
      ;;
    *)
      fail_exit 4 "${ERR_CODE:-CANDIDATE_RESOLUTION_FAILED}"
      ;;
  esac
fi

AGENT_MODEL_ALIAS="$(awk -F'\t' '$1=="AGENT_MODEL"{print $2; exit}' "$RESOLVE_OUT_FILE")"
AGENT_EFFORT="$(awk -F'\t' '$1=="AGENT_EFFORT"{print $2; exit}' "$RESOLVE_OUT_FILE")"
rm -f "$RESOLVE_OUT_FILE" "$RESOLVE_ERR_FILE"

if [ -z "$AGENT_MODEL_ALIAS" ]; then
  # execution=external-cli（CODEX_ARGS行）等、Claudeワーカーとして起動でき
  # ない候補が選ばれた場合はモデル明示の強制違反として扱う。
  fail_exit 5 AGENT_MODEL_LINE_MISSING
fi

# --- 手順7: モデル明示の強制＝許容別名の集合に属するか（共有部品）。 -------
if [ ! -r "$GUARD_COMMON_SH" ]; then
  echo "[$SCRIPT_NAME] FAIL: guard_common.sh が見つかりません: $GUARD_COMMON_SH" >&2
  fail_exit 8 guard_common_missing
fi
# shellcheck disable=SC1090
source "$GUARD_COMMON_SH"

if ! guard_is_allowed_model_alias "$AGENT_MODEL_ALIAS"; then
  fail_exit 5 MODEL_ALIAS_NOT_ALLOWED
fi

# --- 手順8: 子のcwd（--outの親）を正規化し、settings.local.json/.mcp.json
# の不在をcwdからgit管理の根（無ければ$HOME）まで遡って確認する。本番・
# dry-runで同じ1本の判定を使い、判定結果（受理／拒否・終了コード）を
# 一致させる（I2-m2）。判定は**作らずに**行う＝実在する最初の祖先まで登り、
# それがディレクトリで書込可かを見る（mkdir -p が成功する条件と同値）。
# 実際のmkdir -pは本番のときだけ、判定が通った後に行う（dry-runは行わない
# ＝I1-m7。作ってから消す経路は持たない）。 -------------------------------
OUT_DIR_RAW="$(dirname "$OUT")"
FIRST_EXISTING_ANCESTOR="$OUT_DIR_RAW"
OUT_DIR_SUFFIX=""
while [ ! -e "$FIRST_EXISTING_ANCESTOR" ]; do
  OUT_DIR_SUFFIX="$(basename "$FIRST_EXISTING_ANCESTOR")${OUT_DIR_SUFFIX:+/$OUT_DIR_SUFFIX}"
  FIRST_EXISTING_ANCESTOR="$(dirname "$FIRST_EXISTING_ANCESTOR")"
done

if [ ! -d "$FIRST_EXISTING_ANCESTOR" ] || [ ! -w "$FIRST_EXISTING_ANCESTOR" ]; then
  echo "[$SCRIPT_NAME] FAIL: --out の親ディレクトリを作成できません: $OUT_DIR_RAW" >&2
  fail_exit 8 out_dir_uncreatable
fi

FIRST_EXISTING_ANCESTOR="$(cd "$FIRST_EXISTING_ANCESTOR" && pwd)"
if [ -n "$OUT_DIR_SUFFIX" ]; then
  OUT_DIR="$FIRST_EXISTING_ANCESTOR/$OUT_DIR_SUFFIX"
else
  OUT_DIR="$FIRST_EXISTING_ANCESTOR"
fi

if [ "$DRY_RUN" != "1" ]; then
  if ! mkdir -p "$OUT_DIR" 2>/dev/null; then
    echo "[$SCRIPT_NAME] FAIL: --out の親ディレクトリを作成できません: $OUT_DIR" >&2
    fail_exit 8 out_dir_uncreatable
  fi
fi

ROOT_DIR="${HOME:-/}"
d="$OUT_DIR"
while [ "$d" != "/" ]; do
  if [ -e "$d/.git" ]; then
    ROOT_DIR="$d"
    break
  fi
  d="$(dirname "$d")"
done

BAD_CHILD_CONFIG=0
d="$OUT_DIR"
while :; do
  if [ -e "$d/.claude/settings.local.json" ] || [ -e "$d/.mcp.json" ]; then
    BAD_CHILD_CONFIG=1
  fi
  [ "$d" = "$ROOT_DIR" ] && break
  [ "$d" = "/" ] && break
  d="$(dirname "$d")"
done

if [ "$BAD_CHILD_CONFIG" = "1" ]; then
  echo "[$SCRIPT_NAME] FAIL: 子のcwd付近に .claude/settings.local.json または .mcp.json があります（FR-9の保証が破れます）" >&2
  fail_exit 9 child_cwd_config_present
fi

# --- 手順9: --outを予約する（set -Cで<out>.lockを排他作成）。dry-runでは
# ロックファイルを作らない（DR1-m7）。 --------------------------------------
if [ -e "$OUT" ] && [ "$FORCE" != "1" ]; then
  echo "[$SCRIPT_NAME] FAIL: --out が既に存在します（--forceで上書きを許可できます）: $OUT" >&2
  fail_exit 7 out_exists_no_force
fi

LOCK_FILE="$OUT.lock"
LOCK_CREATED=0
cleanup() {
  if [ "$LOCK_CREATED" = "1" ] && [ -e "$LOCK_FILE" ]; then
    rm -f "$LOCK_FILE" 2>/dev/null
  fi
}
trap cleanup EXIT INT TERM

if [ "$DRY_RUN" != "1" ]; then
  if (set -C; : > "$LOCK_FILE") 2>/dev/null; then
    LOCK_CREATED=1
  else
    echo "[$SCRIPT_NAME] FAIL: 同じ --out への並行呼び出しを検出しました（ロック残り）: $LOCK_FILE" >&2
    fail_exit 7 out_locked
  fi
fi

# --- 手順10: --agents JSONと--allowedToolsの値を生成する（D-6）。 ----------
AGENTS_JSON="$(python3 "$AGENT_DEF_PY" agents-json --dir "$AGENTS_DIR" --role "$ROLE" 2>/dev/null)"
if [ -z "$AGENTS_JSON" ]; then
  echo "[$SCRIPT_NAME] FAIL: 職種定義の素材が読めません（agents-json）: $AGENTS_DIR/$ROLE.md" >&2
  fail_exit 4 agent_def_unavailable
fi
ALLOWED_TOOLS="$(python3 "$AGENT_DEF_PY" allowed-tools --dir "$AGENTS_DIR" --role "$ROLE" 2>/dev/null)"
if [ -z "$ALLOWED_TOOLS" ]; then
  echo "[$SCRIPT_NAME] FAIL: 職種定義の素材が読めません（allowed-tools）: $AGENTS_DIR/$ROLE.md" >&2
  fail_exit 4 agent_def_unavailable
fi

# --- 手順11: 職種ごとの子の設定（--settingsのインラインJSON）を生成する
# （§2.5）。 -------------------------------------------------------------
CHILD_SETTINGS_JSON="$(python3 "$CLAUDE_EXEC_PY" child-settings --src "$CHILD_SETTINGS_SRC" --role "$ROLE" --child-cwd "$OUT_DIR" --agents-dir "$AGENTS_DIR")"
if [ -z "$CHILD_SETTINGS_JSON" ]; then
  echo "[$SCRIPT_NAME] FAIL: 子へ届ける柵を組み立てられません（抽出元が読めない、柵が0本、または Vault 書込宣言が不正です）: $CHILD_SETTINGS_SRC" >&2
  fail_exit 8 child_settings_unavailable
fi

# --- 手順12: dry-runならここで印字してexit 0（記録も残さない＝AC-17）。 ----
if [ "$DRY_RUN" = "1" ]; then
  echo "candidate_def=$MODEL_DEF"
  echo "model=$AGENT_MODEL_ALIAS"
  if [ -n "$AGENT_EFFORT" ]; then
    echo "effort=$AGENT_EFFORT (via --effort)"
  else
    echo "effort=(none; child uses settings.json effortLevel)"
  fi
  echo "env_removed_key_names:"
  # ⚠️ NUL区切りの出力をbash変数へ代入すると`$(...)`がNULを黙って除去する
  # （bash文字列はNUL終端のC文字列のため）。変数を経由させずパイプで直接
  # 変換する。
  python3 "$CLAUDE_EXEC_PY" env-keys | tr '\0' '\n' | sed '/^$/d' | sed 's/^/  /'
  echo "argv:"
  {
    printf '  %s\n' "-p" "--agent" "$ROLE" "--model" "$AGENT_MODEL_ALIAS"
    [ -n "$AGENT_EFFORT" ] && printf '  %s\n  %s\n' "--effort" "$AGENT_EFFORT"
    printf '  %s\n' "--output-format" "json" "--permission-mode" "dontAsk" \
      "--allowedTools" "$ALLOWED_TOOLS" "--setting-sources" "local" \
      "--settings" "<inline JSON, omitted>" "--agents" "<inline JSON, omitted>"
    [ -n "$RESUME_ID" ] && printf '  %s\n  %s\n' "--resume" "$RESUME_ID"
  }
  echo "prompt_file=$PROMPT_FILE"
  echo "child_cwd=$OUT_DIR"
  exit 0
fi

# --- 手順13: 子の環境を組み立てて起動する（§2.6）。起動に成功した直後に
# 委任実績マーカーを置く（FR-24）。 ------------------------------------------
# ⚠️ NUL区切りの出力をbash変数へ代入すると`$(...)`がNULを黙って除去する
# （bash文字列はNUL終端のC文字列のため。実測で検出＝除去したはずの
# CLAUDE_CODE_*キーが子環境に残ってしまう不具合になる）。変数を経由させず
# プロセス置換で直接読む。
ENV_UNSET_ARGS=()
while IFS= read -r -d '' key; do
  ENV_UNSET_ARGS+=(-u "$key")
done < <(python3 "$CLAUDE_EXEC_PY" env-keys)

CLAUDE_ARGS=(-p --agent "$ROLE" --model "$AGENT_MODEL_ALIAS")
[ -n "$AGENT_EFFORT" ] && CLAUDE_ARGS+=(--effort "$AGENT_EFFORT")
CLAUDE_ARGS+=(
  --output-format json --permission-mode dontAsk
  --allowedTools "$ALLOWED_TOOLS"
  --setting-sources local
  --settings "$CHILD_SETTINGS_JSON"
  --agents "$AGENTS_JSON"
)
[ -n "$RESUME_ID" ] && CLAUDE_ARGS+=(--resume "$RESUME_ID")

TMP_PREFIX="${OUT}.tmp.${INVOCATION_ID}"
OUT_TMP="${TMP_PREFIX}.stdout"
ERR_TMP="${TMP_PREFIX}.stderr"
TIMEDOUT_MARKER="${TMP_PREFIX}.timedout"
rm -f "$TIMEDOUT_MARKER" 2>/dev/null

(
  cd "$OUT_DIR" && \
  env "${ENV_UNSET_ARGS[@]+"${ENV_UNSET_ARGS[@]}"}" CLAUDE_CODE_WRAPPER_BIN="$BIN" \
    "$BIN" "${CLAUDE_ARGS[@]}" < "$PROMPT_FILE" > "$OUT_TMP" 2> "$ERR_TMP"
) >/dev/null 2>&1 &
CHILD_PID=$!

if [ -n "$PARENT_SID" ]; then
  guard_mark_delegation "$PARENT_SID"
  MARKER_PATH="$(guard_marker_path "$PARENT_SID")"
  if [ ! -e "$MARKER_PATH" ]; then
    # F2: マーカーの書き込みに失敗（子は止めない＝既存agent-model-guard.sh
    # と同じ流儀）。
    echo "[$SCRIPT_NAME] WARN: 委任実績マーカーの書き込みに失敗しました: $MARKER_PATH" >&2
  fi
else
  # F1: 親sidが空（マーカーを置かず継続）。
  echo "[$SCRIPT_NAME] WARN: 親セッションIDが空のため委任実績マーカーを置けません（起動は続行します）" >&2
fi

# --- 手順14: タイムアウト監視つきで待つ（§2.7）。 --------------------------
# ⚠️ watcherは標準出力/標準エラーを明示的に/dev/nullへ逃がす（コマンド
# 置換で本スクリプトを呼んでいる場合、無指定だと呼び出し元のパイプを
# 継承し、途中で殺してもsleepの子が孤児として残ってパイプを握ったまま
# 呼び出し元がハングする＝実測で検出）。
(
  sleep "$TIMEOUT_SECS"
  if kill -0 "$CHILD_PID" 2>/dev/null; then
    : > "$TIMEDOUT_MARKER" 2>/dev/null
    kill -TERM "$CHILD_PID" 2>/dev/null
    sleep 5
    kill -0 "$CHILD_PID" 2>/dev/null && kill -KILL "$CHILD_PID" 2>/dev/null
  fi
) >/dev/null 2>&1 &
WATCHER_PID=$!

wait "$CHILD_PID" 2>/dev/null
# 子の終了コードは分類には使わない（設計§2.7。読み捨てる）。

# 子が正常終了したら見張りを先に停止する（PID再利用による誤射を避ける）。
# ⚠️ 順序が重要（実測で検出＝run_with_timeoutと同型の孤児化バグ）。
# 先に子（sleep）を殺し、その後に親（watcher）を殺す。
pkill -TERM -P "$WATCHER_PID" 2>/dev/null
kill "$WATCHER_PID" 2>/dev/null
wait "$WATCHER_PID" 2>/dev/null

# F4: カナリア（SessionEndフック）不在の検出。終了コードは変えない。
CANARY="$OUT_DIR/.claude-exec-hooks-alive"
if [ ! -e "$CANARY" ]; then
  : > "$OUT_DIR/.claude-exec-hooks-missing" 2>/dev/null
  echo "[$SCRIPT_NAME] WARN: 子のカナリア（SessionEndフック）が検出されませんでした: $CANARY" >&2
fi

# --- 手順15: 子の標準出力を分類する（§2.8）。 -------------------------------
TIMEDOUT_FLAG=()
[ -f "$TIMEDOUT_MARKER" ] && TIMEDOUT_FLAG=(--timed-out)

CLASSIFY_ERR_FILE="${TMP_PREFIX}.classify.stderr"
CLASSIFY_OUT="$(python3 "$CLAUDE_EXEC_PY" classify --raw "$OUT_TMP" "${TIMEDOUT_FLAG[@]+"${TIMEDOUT_FLAG[@]}"}" 2>"$CLASSIFY_ERR_FILE")"
REASON_CODE="$(printf '%s\n' "$CLASSIFY_OUT" | awk -F'\t' '$1=="REASON_CODE"{print $2}')"
CLASSIFY_EXIT="$(printf '%s\n' "$CLASSIFY_OUT" | awk -F'\t' '$1=="EXIT_CODE"{print $2}')"
CHILD_SESSION_ID="$(printf '%s\n' "$CLASSIFY_OUT" | awk -F'\t' '$1=="SESSION_ID"{print $2}')"

# ⑤その他のとき、classifyがresultの全文を標準エラーへ書いている
# （AC-19b⑤）。ラッパー自身の標準エラーへそのまま中継する。
if [ -s "$CLASSIFY_ERR_FILE" ]; then
  cat "$CLASSIFY_ERR_FILE" >&2
fi
rm -f "$CLASSIFY_ERR_FILE" 2>/dev/null

# --- 手順16: --outを確定する（一時ファイル→mv）・子の標準エラーも
# <out>.stderr として--outの隣に残す（分類には使わない＝設計§2.8のまま。
# DR1-M2）・ロック解除。 -----------------------------------------------------
if mv "$OUT_TMP" "$OUT" 2>/dev/null; then
  FINAL_EXIT_CODE="$CLASSIFY_EXIT"
else
  echo "[$SCRIPT_NAME] FAIL: --out の確定（rename）に失敗しました。一時ファイルは保持します: $OUT_TMP" >&2
  FINAL_EXIT_CODE=15
  REASON_CODE="rename_failed"
fi
# 移動に失敗しても終了コードは変えない（best-effort＝NFR-2と同じ流儀）。
mv "$ERR_TMP" "${OUT}.stderr" 2>/dev/null || true
# ロックは trap cleanup（EXIT）が削除する。

# --- 手順17: invocation行を1行追記する（書けなくても終了コードは変えない
# ＝NFR-2）。 ------------------------------------------------------------
write_log "$FINAL_EXIT_CODE" "${REASON_CODE:--}" "${CHILD_SESSION_ID:--}" "$OUT_DIR"

echo "SESSION_ID:${CHILD_SESSION_ID}"
echo "OUT:${OUT}"
echo "REASON:${REASON_CODE:--}"
echo "EXIT:${FINAL_EXIT_CODE}"

exit "$FINAL_EXIT_CODE"
