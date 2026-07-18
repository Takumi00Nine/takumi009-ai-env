#!/usr/bin/env bash
# 週次メンテナンスランナー（scripts/maintenance.sh・PR2）用 LaunchAgent
# (launchagents/com.takumi009.maintenance.plist) を $HOME/Library/LaunchAgents へ
# 配置し、launchctl へ (re)load する（メイン専用機能）。
# install-backup.sh と同方式＝実ファイルコピー＋__AIENV_HOME__プレースホルダ置換。
#
# 対象スクリプト本体（scripts/maintenance.sh）は symlink 化せず、plist の
# ProgramArguments がリポジトリ内のパスを直接参照する（backup-vault.shと同じ扱い）。
#
# 旧ラベル4本の移行（2026-07-16簡素化・設計書§4「install-maintenance.sh（新設）が
# vault-inventory/fragments-log/knowledge-merge-detect/drift-check の4ラベルを
# migrate_retired_label()で移行しmaintenance.plistを設置」）: これら4本の週次
# LaunchAgentは maintenance.sh のPhase1（検出）へ全て吸収されたため撤去する。
# 個々の検出スクリプト自体（vault_inventory.py・fragments_log.py・
# knowledge_merge_candidates.py・check-drift.sh）は削除しておらず、旧LAが
# 読み込まれたまま残っても「参照先が無くて失敗し続ける」わけではない。実害は
# maintenance.sh Phase1と同じ検出処理が週次で二重実行され続けること（無駄な
# 実行時間・ログ/レポートファイルへの書き込み競合）であり、二重実行の温床を
# 早期に断つために移行する（Codexレビュー指摘対応・2026-07-16）。
# 旧plistが実在する環境でのみ bootout＋削除する一度限りの移行を行う（新規導入
# 環境では該当ファイルが無いため何もしない＝fail-open）。
#
# 移行順序＝**新ラベルの設置・bootstrap・enableが成功したことを確認してから**
# 旧ラベル4本の移行を行う（Codexレビュー指摘Major対応・2026-07-16。当初は
# 旧→新の逆順だったが、新ラベルのbootstrap失敗時に週次経路が空白期間ではなく
# 完全に消失するリスクがあった。install-backup.shの1旧→1新パターンと同じ
# 「新規設置を先に確定してから旧後片付け」の順序に統一する）。新ラベルの設置に
# 失敗した場合は旧ラベルの移行を一切行わずexit 1する（旧ジョブは冗長実行が
# 続くだけで機能自体は失われないため、安全側に倒せる）。
#
# install-backup.sh・install-vault-agents.sh と同じ理由で、bootstrap+enableのみを
# 行い**即時kickstartはしない**（初回実行はStartCalendarIntervalの次回発火を
# 待つか、準備が整ってから手動で `launchctl kickstart -k` する）。
#
# 使い方:
#   scripts/install-maintenance.sh            # 実行（配置 + launchctl (re)load + 旧4ラベルの移行）
#   scripts/install-maintenance.sh --dry-run  # 計画だけ表示（何もしない）
#
# 注意: インストール系スクリプトはユーザーが内容を確認したうえで実行する（自動実行しない）。
#
# テスト専用: SKIP_LAUNCHCTL=1 にすると launchctl への実操作（bootout/bootstrap/
# enable）だけをskipする（plist配置・旧ラベルのplist削除は行う。実LaunchAgent状態
# を書き換えずにファイル配置・移行ロジックだけを検証したいテスト向け。
# scripts/install-backup.sh・scripts/install-sub.sh と同じ考え方・同じ変数名）。

set -euo pipefail

: "${SKIP_LAUNCHCTL:=0}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST_NAME="com.takumi009.maintenance.plist"
SRC="$DIR/launchagents/$PLIST_NAME"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"
LABEL="${PLIST_NAME%.plist}"
DOMAIN="gui/$(id -u)"

# 撤去済みラベル4本（2026-07-16簡素化・設計書§4）。
RETIRED_LABELS=(
  com.takumi009.vault-inventory
  com.takumi009.fragments-log
  com.takumi009.knowledge-merge-detect
  com.takumi009.drift-check
)

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

log() { echo "[install-maintenance] $*"; }
warn() { echo "[install-maintenance] WARN: $*" >&2; }
fail() { echo "[install-maintenance] FAIL: $*" >&2; exit 1; }

# 旧ラベル4本のうち1本でも移行が未完了（照会不能・bootout失敗）ならスクリプト
# 全体の終了コードを非0にする（scripts/install-backup.shと同じ方針＝新ラベルの
# 設置自体は成功していても、後片付けが未完了ならサイレントに完了扱いにしない）。
MIGRATION_FAILED=0

[ -e "$SRC" ] || fail "リポジトリのファイルが見つかりません（checkout破損の可能性）: $SRC"
[ -f "$DIR/scripts/maintenance.sh" ] || fail "リポジトリに scripts/maintenance.sh が見つかりません（checkout破損の可能性）"

# 指定ラベルがlaunchd上に「ロード済み」かどうかをplistファイルの有無とは独立に
# 確認する（scripts/install-backup.shの old_label_status() と同じ設計・同じ
# 3巡分のCodexレビュー指摘対応をそのまま踏襲）。旧ラベル4本の移行判定だけでなく、
# 新ラベル(com.takumi009.maintenance)自身が「内容に変更が無くロード済みなら
# 再読み込みをスキップしてよいか」の判定にも使う（Codexレビュー指摘Major対応・
# 2026-07-16）ため、汎用名にしている。
#   loaded     : 対象ラベルがlaunchd上にロード済み（bootoutを試みる必要がある）
#   not_loaded : launchdへの照会自体は機能しており、対象ラベルは確実に未ロード
#                （plistが残っているだけなら安全に削除してよい）
#   unknown    : launchdへの照会そのものが機能していない（domain自体への
#                print照会が失敗）。「未ロード」と誤判定して安全なplistを
#                消してしまうリスクを避け、fail-closed（保守側）に倒す。
# SKIP_LAUNCHCTL=1の場合は実launchdへ一切問い合わせず"skip"を返す。
label_status() {
  local label="$1"
  if [ "$SKIP_LAUNCHCTL" = "1" ]; then
    echo "skip"
    return
  fi
  if ! launchctl print "$DOMAIN" >/dev/null 2>&1; then
    echo "unknown"
    return
  fi
  if launchctl print "$DOMAIN/$label" >/dev/null 2>&1; then
    echo "loaded"
  else
    echo "not_loaded"
  fi
}

# 撤去済みラベルの移行（旧LaunchAgentが残っていれば bootout + 削除）。
# plistファイルが既に無い環境（新規導入・移行済み）でも、launchd上にだけ
# ロードされたまま残っている可能性を否定できないため、plistファイルの
# 有無で外側を先にゲートしない（scripts/install-backup.shの4巡目レビュー
# 指摘Major対応をそのまま踏襲）。
migrate_retired_label() {
  local label="$1" dest="$HOME/Library/LaunchAgents/${1}.plist"
  local status
  status="$(label_status "$label")"

  case "$status" in
    unknown)
      warn "旧ラベル（${label}）のロード状態をlaunchd照会で確認できませんでした。plistは削除せず次回実行時に再試行します。手動確認: launchctl print ${DOMAIN}"
      MIGRATION_FAILED=1
      return 0
      ;;
    skip)
      if [ -e "$dest" ]; then
        log "旧ラベル（${label}）を検出したため移行します（plist削除。SKIP_LAUNCHCTL=1のためbootoutはskip）"
        rm -f "$dest"
        log "旧ラベル（${label}）を削除しました。"
      fi
      return 0
      ;;
    not_loaded)
      if [ -e "$dest" ]; then
        log "旧ラベル（${label}）を検出したため移行します（launchd上には元々ロードされていませんでした）"
        rm -f "$dest"
        log "旧ラベル（${label}）を削除しました。"
      fi
      return 0
      ;;
    loaded)
      log "旧ラベル（${label}）を検出したため移行します（bootout + plist削除）"
      if launchctl bootout "$DOMAIN/$label" 2>/dev/null; then
        rm -f "$dest"
        log "旧ラベル（${label}）を削除しました。"
      else
        warn "旧ラベル（${label}）のbootoutに失敗しました。plistは削除せず次回実行時に再試行します。手動確認: launchctl print ${DOMAIN}/${label} ／ 手動解除: launchctl bootout ${DOMAIN}/${label}"
        MIGRATION_FAILED=1
      fi
      return 0
      ;;
  esac
}

if [ "$DRY_RUN" = "1" ]; then
  log "[dry-run] would generate: $DEST <- $SRC （__AIENV_HOME__ を $HOME へ置換）"
  log "[dry-run] would run: launchctl bootout $DOMAIN/$LABEL （既存があれば一旦アンロード。無ければ無視）"
  log "[dry-run] would run: launchctl bootstrap $DOMAIN $DEST"
  log "[dry-run] would run: launchctl enable $DOMAIN/$LABEL"
  log "[dry-run] （kickstartは行わない＝即時実行しない設計。次のStartCalendarIntervalか手動kickstart待ち）"
  for label in "${RETIRED_LABELS[@]}"; do
    dest="$HOME/Library/LaunchAgents/${label}.plist"
    if [ -e "$dest" ]; then
      log "[dry-run] would migrate away retired LaunchAgent: $dest （launchctl bootout ${DOMAIN}/${label} の後、ファイル削除。新ラベルの設置成功が前提）"
    fi
  done
  log "[dry-run] 完了。実際の変更は一切行っていません。"
  exit 0
fi

# --- 新ラベル(com.takumi009.maintenance)の設置を先に行う（Codexレビュー指摘
#     Major対応・2026-07-16。新ラベルのbootstrap/enableが確実に成功したことを
#     確認してから旧ラベル4本の移行に進む。新設置に失敗した場合は旧ラベルの
#     移行を一切行わずexit 1する＝週次経路が完全に消失する事態を避ける） ---
mkdir -p "$(dirname "$DEST")"
escaped_home=$(printf '%s' "$HOME" | sed -e 's/[&\]/\\&/g' -e 's/#/\\#/g')
tmp="$(mktemp "$(dirname "$DEST")/.$(basename "$DEST").aienv-tmp.XXXXXX")"
trap 'rm -f "$tmp"' RETURN
sed "s#__AIENV_HOME__#${escaped_home}#g" "$SRC" > "$tmp"

# 内容に変更が無く、かつ新ラベルが既にlaunchd上にロード済みなら bootout→bootstrap
# による再読み込み自体をスキップする（Codexレビュー指摘Major対応・2026-07-16）。
# 素朴に毎回bootout→bootstrapすると、再インストール（内容が変わっていない
# 冪等な再実行）の直後にbootstrapが失敗した場合、直前まで正常稼働していた
# ジョブまでアンロードされ週次経路が一時的にゼロになる瞬間が生まれる。内容が
# 変わっていなければ再読み込みする必要が無いため、この窓を丸ごと避けられる。
#
# 内容が同一でもlabel_status()が"unknown"（domain照会そのものが機能して
# いない）の場合は、既存ジョブがロード済みかどうか判断できない。この状態で
# 素朴にbootout→bootstrapへ進むと、実際にはロード済みで健全だったジョブを
# 停止したうえでbootstrapが失敗し、週次経路を失う恐れがある（Codexレビュー
# 指摘Major対応・2026-07-16。旧ラベル移行がunknownをfail-closedにしている
# 方針との整合も取る）。よって"unknown"の場合は破壊的操作に一切進まず
# exit 1する。"not_loaded"の場合はロード済みではないと確定しているため、
# 通常のreloadパス（bootout自体は実質no-op）へ進んで問題ない。
SKIP_RELOAD=0
if [ -f "$DEST" ] && cmp -s "$tmp" "$DEST" && [ "$SKIP_LAUNCHCTL" != "1" ]; then
  content_unchanged_status="$(label_status "$LABEL")"
  case "$content_unchanged_status" in
    loaded)
      SKIP_RELOAD=1
      ;;
    unknown)
      rm -f "$tmp"
      fail "launchd: 新ラベル（${LABEL}）のロード状態をlaunchd照会で確認できませんでした。内容は既存のplistと同一のため、既存ジョブへの破壊的なbootout/bootstrapは行わず何もせず終了します。手動確認: launchctl print ${DOMAIN}"
      ;;
    not_loaded)
      : # 未ロードと確定しているため、下の通常reloadパスへ進む（bootoutは無害）。
      ;;
  esac
fi

if [ "$SKIP_RELOAD" = "1" ]; then
  rm -f "$tmp"
  log "内容に変更なし・新ラベル（${LABEL}）は既にロード済みのため bootout/bootstrap をスキップします: $DEST"
  # bootout/bootstrapは不要でも、ロード済み＝非disabledとは限らない（`launchctl
  # print`の成功はサービス定義の存在を示すだけで、永続的なdisabled override
  # が解除されている保証にはならない）。ロード済みのまま手動disableされていた
  # 場合を静かに見逃さないよう、enableだけは必ず実行して確認する
  # （Codexレビュー指摘Major対応・2026-07-16）。
  if launchctl enable "$DOMAIN/$LABEL" 2>/dev/null; then
    log "launchd: ${LABEL} は既存ロードのまま enable 状態を確認しました。"
  else
    fail "launchd: enable failed for ${LABEL}（既存ロードのdisabled解除に失敗。手動でenableしてください: launchctl enable $DOMAIN/${LABEL}）"
  fi
else
  mv "$tmp" "$DEST"
  log "generated: $DEST <- $SRC （__AIENV_HOME__ を $HOME へ置換）"

  if [ "$SKIP_LAUNCHCTL" = "1" ]; then
    log "SKIP_LAUNCHCTL=1 のため launchctl 操作はskipします（テスト用）"
  else
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    bootstrap_ok=0
    if launchctl bootstrap "$DOMAIN" "$DEST" 2>/dev/null; then
      bootstrap_ok=1
    else
      # ラベルがlaunchdのdisabled override（過去の手動`launchctl disable`等）に
      # 残っている場合、bootstrapはenableされるまで失敗し続けることがある
      # （macOS launchdの既知の挙動。Codexレビュー指摘Major対応・2026-07-16）。
      # enableを試みてからbootstrapを1回だけ再試行する。
      warn "launchd: bootstrap failed for ${LABEL}（disabled状態の可能性があるため、enable後に1回だけ再試行します）"
      launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
      if launchctl bootstrap "$DOMAIN" "$DEST" 2>/dev/null; then
        bootstrap_ok=1
      fi
    fi

    if [ "$bootstrap_ok" = "1" ]; then
      if launchctl enable "$DOMAIN/$LABEL" 2>/dev/null; then
        log "launchd: (re)loaded ${LABEL}（即時実行はしていません。初回は次のStartCalendarInterval、または準備が整い次第 'launchctl kickstart -k ${DOMAIN}/${LABEL}' を手動実行してください）"
      else
        # enableの失敗を無視するとラベルがdisabledのまま静かに残り、launchdは
        # 次回起動後も再enableされるまでロードしない（Codexレビュー指摘Major
        # 対応・2026-07-16。以前は`|| true`で握り潰していた）。
        fail "launchd: enable failed for ${LABEL}（手動でenableしてください: launchctl enable $DOMAIN/${LABEL}）"
      fi
    else
      fail "launchd: bootstrap failed for ${LABEL}（disabled状態のenable経由リトライも失敗。手動でロードしてください: launchctl enable $DOMAIN/${LABEL} && launchctl bootstrap $DOMAIN ${DEST}）"
    fi
  fi
fi

# --- 新ラベルの設置（上記）が成功した場合のみ、旧ラベル4本の移行へ進む ---
for label in "${RETIRED_LABELS[@]}"; do
  migrate_retired_label "$label"
done

log "done."

# 新ラベルの設置自体は成功しているため"done."までは出すが、旧ラベルの後片付けが
# 未完了の場合は最終的な終了コードを非0にする（scripts/install-backup.shと
# 同じ方針）。
if [ "$MIGRATION_FAILED" = "1" ]; then
  exit 1
fi
