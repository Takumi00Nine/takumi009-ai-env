#!/bin/bash
# SessionStart hook: サブ機のみで動作し、外部脳(takumi009-ai-env)リポジトリに
# 未反映の更新（origin/mainより遅れているコミット）が無いかを毎セッション実測し、
# あれば手動実行を案内する。
#
# 背景（2026-07-23 本人決定）: 従来はLaunchAgent（com.takumi009.update-sub、
# 1日2回・09:00/13:00）で無人自動pullしていたが、これを廃止し、セッション起動時に
# 確認→本人が能動的に scripts/update-sub.sh を手動実行する方式へ置き換えた
# （間引きなし＝毎セッション必ず確認する）。scripts/update-sub.sh 自体（pull後の
# config.toml再生成・Preferences再同期処理）は変更なしで温存し、本フックは
# 「実行すべきか」を案内するだけに徹する。
#
# メイン/サブの判定は配役表（ローカル実体プロファイル）の能力軸`machine_role`
# で行う（配役表-能力軸整理-設計-2026-09-07.md §2。2026-07-24リーダー裁定の
# 「否定証明を根拠にしない・積極的な証明が要る」という設計方針は維持し、
# 判定式の正本を`claude/hooks/lib/profile_resolve.py`の1箇所に置く＝D-1）。
# 本フックは`machine_role`が「sub」と解決できた場合だけ動作し、それ以外
# （解決失敗・unknown・unavailable・欠落等）はメイン機とみなして即座に
# 何も出力せず exit 0 する（fail-closed＝積極的な証明が無ければ動かない）。
# install-main.sh（サブへの委譲経路である --sub-delegate 経由も含む）は
# 実体プロファイルを書き換えないため、メイン機で誤って`machine_role: sub`が
# 立つ経路は設計上存在しない。scripts/update-sub.sh 側にも同じ判定を設けている
# （誤って手動実行された場合の最後の砦）。
#
# ワーカー/サブエージェント起動時もスキップする（bootstrap-vault.shと同様に
# stdin JSON の agent_type の有無で判定。チーム設定ファイルとの突合までは
# 行わない＝このフックの案内はセッション開始時に1回出せば足りる軽量な通知であり、
# bootstrap-vault.shほど厳密な判定は要求されていないため意図的に簡略化）。
# 既知の限界（Codex一次レビュー指摘・Minor）: agent_typeを持たないAgent Teamsの
# チームメイト（teams/配下のconfig.jsonでのみリーダーと紐付くケース）はこの
# 簡略判定では捕捉できず、リーダー扱いのままフックが実行される。fail-open設計
# のため多重fetch程度に留まり致命的ではないが、bootstrap-vault.shほど厳密な
# 捕捉ではない点は意図的な簡略化として記録しておく。
#
# fail-open（Knowledge/fail-open-and-observable-guards）: オフライン・fetch失敗・
# タイムアウト等、何が起きてもセッション開始をブロックしない（必ずexit 0）。
# ただし「無言のfail-open」は禁止のため、失敗はログファイルに残す。
#
# パスは全て $HOME 相対（絶対パスのハードコード禁止＝リポジトリの掟）。
# 環境変数はすべてテスト用に上書き可（本番は既定値のまま呼べばよい）。
#   AIENV_LOCAL_PROFILE_PATH … ローカル実体プロファイル（既定
#                                $HOME/.config/takumi009-ai-env/profile.md。
#                                4つの読み手が共有する既定値＝配役表-能力軸
#                                整理-設計-2026-09-07.md §2.2）
#   AIENV_BEDROCK_ENV_FILE    … Bedrockピン留め実値ファイル（既定
#                                $HOME/.config/takumi009-ai-env/bedrock.env）
#   AIENV_AGENTS_DIR           … コア職種マニフェストの実体側入力（既定
#                                $SELF_DIR/../agents）
#   CHECK_SUB_UPDATE_DIR      … リポジトリのルート（既定 $HOME/work/takumi009-ai-env。
#                                ⚠️ lib解決には使わない＝テストではスタブrepoを指すため）
#   CHECK_SUB_UPDATE_LOG      … 失敗ログの出力先（既定 /tmp/check-sub-update.log）
#   CHECK_SUB_UPDATE_TIMEOUT  … git fetch のタイムアウト秒数（既定 5）
#
# bash 3.2（macOSシステムbash）前提: 連想配列・mapfileは使わない。
# set -e は使わない（bootstrap-vault.sh・vault-recall.shと同方針＝fail-openを
# 徹底するため、途中の失敗は各所で個別にexit 0へ倒す）。

# claude/hooks/bootstrap-vault.sh の resolve_bootstrap_self_dir() と同じ方式を
# 複製する（配役表-能力軸整理-設計-2026-09-07.md §2.3）。installerはフックを
# 1本ずつsymlinkしており（~/.claude/hooks/lib/ は存在しない）、lib専用の
# リンクは持たないため、本フック自身のsymlinkを解決した実体ディレクトリ
# 直下のlib/を見る（判定式を2箇所に増やさない＝A-0-3と同型）。
resolve_check_sub_update_self_dir() {
  local src="${BASH_SOURCE[0]}"
  while [ -L "$src" ]; do
    local dir
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    case "$src" in
      /*) ;;
      *) src="$dir/$src" ;;
    esac
  done
  cd -P "$(dirname "$src")" && pwd
}
SELF_DIR="$(resolve_check_sub_update_self_dir)"
: "${PROFILE_RESOLVE_LIB:=$SELF_DIR/lib/profile_resolve.py}"
: "${AIENV_LOCAL_PROFILE_PATH:=$HOME/.config/takumi009-ai-env/profile.md}"
: "${AIENV_BEDROCK_ENV_FILE:=$HOME/.config/takumi009-ai-env/bedrock.env}"
: "${AIENV_AGENTS_DIR:=$SELF_DIR/../agents}"
DIR="${CHECK_SUB_UPDATE_DIR:-$HOME/work/takumi009-ai-env}"
LOG_FILE="${CHECK_SUB_UPDATE_LOG:-/tmp/check-sub-update.log}"
FETCH_TIMEOUT_SECONDS="${CHECK_SUB_UPDATE_TIMEOUT:-5}"

log_fail() {
  # ログ書込自体もベストエフォート（書けなくても本処理は継続する＝fail-open）。
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$1" >> "$LOG_FILE" 2>/dev/null
  return 0
}

# --- 0. ワーカー/サブエージェント起動時はスキップ ---
INPUT=$(cat 2>/dev/null)
AGENT_TYPE=$(printf '%s' "$INPUT" | jq -r '.agent_type // ""' 2>/dev/null)
[ -n "$AGENT_TYPE" ] && exit 0

# --- 1. machine_roleが「sub」でなければ何もしない（無出力・fail-closed） ---
# 配役表の`machine_role`が解決失敗・unknown・unavailable・欠落等のいずれでも
# メイン機とみなす。積極的な証明（`sub`と読めること）が無ければ動かない設計
# （配役表-能力軸整理-設計-2026-09-07.md §2.2の共通レシピ）。
_mr_out="$(python3 "$PROFILE_RESOLVE_LIB" resolve "$AIENV_LOCAL_PROFILE_PATH" \
  --bedrock-env "$AIENV_BEDROCK_ENV_FILE" --agents-dir "$AIENV_AGENTS_DIR" 2>/dev/null)" || _mr_out=""
# 失敗を静かにしない（Knowledge/fail-open-and-observable-guards）＝空、または
# OKで始まらない出力はログへ1行残してからexit 0する。標準出力へは出さない
# （メイン機で毎セッション出力が増えるのを避ける＝§2.4②）。
case "$_mr_out" in
  OK*) : ;;
  *)
    log_fail "profile_resolve.py resolveが失敗またはOKで始まらない出力を返しました（machine_roleを解決できません）: '${_mr_out}'"
    exit 0
    ;;
esac
_mr_tab=$'\t'
_mr_rest="${_mr_out#*"${_mr_tab}MACHINE_ROLE:"}"
MACHINE_ROLE=""
[ "$_mr_rest" != "$_mr_out" ] && MACHINE_ROLE="${_mr_rest%%"${_mr_tab}"*}"
case "$MACHINE_ROLE" in main|sub) : ;; *) MACHINE_ROLE="unknown" ;; esac
[ "$MACHINE_ROLE" = "sub" ] || exit 0

# --- 2. リポジトリが無い/gitが無いなら何もしない ---
[ -d "$DIR/.git" ] || exit 0
command -v git >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# --- 3. git fetch を時間上限つきで実行する ---
# macOSの標準bashには`timeout`コマンドが無い（GNU coreutils由来。
# brew install coreutilsでも`gtimeout`という別名でしか入らない＝Web裏取り済み・
# 2026-07-23）。bash 3.2でも動く移植可能な方法として「バックグラウンド実行＋
# 監視サブシェルによるkill」を使う。
#
# Codex一次レビュー指摘・Major対応: 当初 `kill "$cmd_pid"` だけを送っていたが、
# これは`git fetch`本体のPIDにしか届かず、gitが内部で起動する
# `git-remote-https`・SSH・credentialヘルパー等の子孫プロセスは同じ
# プロセスグループの別PIDのため生き残る可能性があった（親が終了/killされても
# 子孫を道連れにする保証が無い＝野良プロセスが残るリスク）。
# 対策: `set -m`（monitor mode）を一時的に有効にしてから背景ジョブを起動すると、
# そのジョブは自分自身のPIDと同じプロセスグループIDを持つ新しいプロセスグループの
# リーダーになる（bashの標準的な挙動）。以降 `kill <負のPID>` でグループ全体
# （本体+すべての子孫）へシグナルを送れる。TERMで終了しない場合に備え、1秒後に
# KILLで強制終了する保険も付ける。
run_with_timeout() {
  local secs="$1"
  shift
  local had_monitor=0
  case "$-" in *m*) had_monitor=1 ;; esac
  set -m
  "$@" &
  local cmd_pid=$!
  [ "$had_monitor" = "1" ] || set +m
  ( sleep "$secs"; kill -TERM "-$cmd_pid" 2>/dev/null; sleep 1; kill -KILL "-$cmd_pid" 2>/dev/null ) &
  local watcher_pid=$!
  local rc=0
  wait "$cmd_pid" 2>/dev/null
  rc=$?
  kill "$watcher_pid" 2>/dev/null
  wait "$watcher_pid" 2>/dev/null
  return "$rc"
}

# GIT_TERMINAL_PROMPT=0でHTTP認証プロンプト待ちの無限ハングを防ぐ
# （git 2.3+の標準機能＝Web裏取り済み。`env`経由で明示的に子プロセスへ渡す＝
# 関数呼び出し越しの環境変数エクスポートの曖昧さに頼らないため）。
# http.lowSpeedLimit/lowSpeedTimeは「低速だが生きている接続」に対する追加の
# 保険（https remote前提）。
FETCH_OUT_FILE="$(mktemp 2>/dev/null)"
[ -n "$FETCH_OUT_FILE" ] || FETCH_OUT_FILE="/tmp/check-sub-update-fetch.$$"

if ! run_with_timeout "$FETCH_TIMEOUT_SECONDS" \
     env GIT_TERMINAL_PROMPT=0 \
     git -C "$DIR" -c "http.lowSpeedLimit=1000" -c "http.lowSpeedTime=${FETCH_TIMEOUT_SECONDS}" \
     fetch origin >"$FETCH_OUT_FILE" 2>&1; then
  log_fail "git fetch failed or timed out (dir=$DIR, timeout=${FETCH_TIMEOUT_SECONDS}s): $(tr '\n' ' ' < "$FETCH_OUT_FILE" 2>/dev/null)"
  rm -f "$FETCH_OUT_FILE"
  exit 0
fi
rm -f "$FETCH_OUT_FILE"

# --- 4. 未反映コミット数を判定する ---
AHEAD_COUNT="$(git -C "$DIR" rev-list --count HEAD..origin/main 2>>"$LOG_FILE")"
case "$AHEAD_COUNT" in
  ''|*[!0-9]*)
    log_fail "rev-list --count の結果が数値ではありません（origin/mainが無い等の可能性）: '${AHEAD_COUNT}'"
    exit 0
    ;;
esac

[ "$AHEAD_COUNT" -ge 1 ] || exit 0

# --- 5. 未反映があれば手動実行を案内する ---
MSG="⚠️ 外部脳（takumi009-ai-env）の更新が未反映です（origin/main より ${AHEAD_COUNT} コミット遅れ）。プロンプトに次を入力すると、このセッション内でそのまま実行して反映できます（\`!\` プレフィックス＝セッション内シェル実行）: \`! $DIR/scripts/update-sub.sh\`"

# jq自体の異常（実行時障害・SIGPIPE等）でスクリプト全体の終了コードが非0に
# ならないよう、出力生成を変数に一旦収めてから明示的にexit 0する（Codex一次
# レビュー指摘・Minor: 「必ずexit 0」というfail-open契約に最後の穴が残っていた）。
# jqの終了コード自体も確認する（Codex再レビュー指摘・Minor: 出力が空かどうか
# だけを見ていると、jqが非0終了しつつ何らかの出力を残したケースを失敗として
# 扱えない）。
if ! OUT_JSON="$(jq -n --arg ctx "$MSG" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}' 2>>"$LOG_FILE")"; then
  log_fail "jqでの出力JSON生成に失敗しました（終了コード異常。案内メッセージの提示をskipします）"
  exit 0
fi
if [ -z "$OUT_JSON" ]; then
  log_fail "jqでの出力JSON生成に失敗しました（出力が空。案内メッセージの提示をskipします）"
  exit 0
fi

printf '%s\n' "$OUT_JSON"
exit 0
