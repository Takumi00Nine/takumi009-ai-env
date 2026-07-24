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
# メイン/サブの判定は明示的な「machine-role マーカーファイル」で行う
# （2026-07-24 リーダー裁定＝Codex一次レビュー指摘Major対応で設計変更。旧方式は
# Vaultのprivate層専用ファイル(Personal/profile-personal.md・Knowledge/mistakes.md)
# の「不在」を根拠にしていたが、これは否定証明であり、メイン機で私的パッチが
# 未適用・復旧中等の理由で一時的にファイルが欠けていると誤ってサブ扱いされ、
# 案内どおり `scripts/update-sub.sh` を実行するとメインVaultの`Preferences/`が
# `rsync --delete`で上書き削除される事故になり得た）。
# scripts/install-sub.sh が実行された時だけ machine-role マーカーファイル
# （既定 $HOME/.config/takumi009-ai-env/machine-role・中身は "sub"）を書き込む。
# 本フックはこのマーカーの中身が「sub」の場合だけ動作し、それ以外（マーカーが
# 無い・中身が違う・読めない等）はメイン機とみなして即座に何も出力せず exit 0
# する（fail-closed＝積極的な証明が無ければ動かない）。install-main.sh（サブへの
# 委譲経路である --sub-delegate 経由も含む）はこのマーカーを一切書かないため、
# メイン機で誤ってマーカーが立つ経路は設計上存在しない。scripts/update-sub.sh
# 側にも同じマーカーチェックを設けている（誤って手動実行された場合の最後の砦）。
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
#   AIENV_MACHINE_ROLE_MARKER … machine-roleマーカーファイル
#                                （既定 $HOME/.config/takumi009-ai-env/machine-role。
#                                 scripts/install-sub.sh・scripts/update-sub.sh と
#                                 同じ環境変数名・既定値を共有する）
#   CHECK_SUB_UPDATE_DIR      … リポジトリのルート（既定 $HOME/work/takumi009-ai-env）
#   CHECK_SUB_UPDATE_LOG      … 失敗ログの出力先（既定 /tmp/check-sub-update.log）
#   CHECK_SUB_UPDATE_TIMEOUT  … git fetch のタイムアウト秒数（既定 5）
#
# bash 3.2（macOSシステムbash）前提: 連想配列・mapfileは使わない。
# set -e は使わない（bootstrap-vault.sh・vault-recall.shと同方針＝fail-openを
# 徹底するため、途中の失敗は各所で個別にexit 0へ倒す）。

: "${AIENV_MACHINE_ROLE_MARKER:=$HOME/.config/takumi009-ai-env/machine-role}"
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

# --- 1. machine-roleマーカーが「sub」でなければ何もしない（無出力・fail-closed） ---
# マーカーが無い・読めない・中身が"sub"以外（前後の空白等はtrimして許容）の
# いずれでもメイン機とみなす。積極的な証明（マーカー）が無ければ動かない設計。
# 前後の空白だけを取り除く（Codex再レビュー指摘・Minor: `tr -d '[:space:]'`は
# 内部の空白まで削除してしまうため、"s u b"のような中身まで誤って"sub"として
# 通してしまう穴があった。bash 3.2互換のパラメータ展開のみで前後trimする）。
MACHINE_ROLE_RAW="$(cat "$AIENV_MACHINE_ROLE_MARKER" 2>/dev/null)"
MACHINE_ROLE="${MACHINE_ROLE_RAW#"${MACHINE_ROLE_RAW%%[![:space:]]*}"}"
MACHINE_ROLE="${MACHINE_ROLE%"${MACHINE_ROLE##*[![:space:]]}"}"
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
