#!/usr/bin/env bash
# Vault バックアップ用 LaunchAgent (launchagents/com.takumi009.backup-vault.plist) を
# $HOME/Library/LaunchAgents へ配置し、launchctl へ (re)load する
# （dotfiles/install.sh の install_launchagent() と同方式＝実ファイルコピー。
# launchdのログイン時自動読込がsymlinked plistでは不安定なため実ファイルを配る）。
#
# plist は __AIENV_HOME__ プレースホルダを実ホームパスへ置換してから配置する
# （codex/config.toml と同じ理由＝plistはシェル変数展開されないプレーンなXML）。
#
# ラベル改名（2026-07-16簡素化・設計書§5「命名規則統一」: LAラベル=対象スクリプトの
# basenameと同語順。改名実施は com.takumi009.vault-backup → com.takumi009.backup-vault
# の1件のみ＝対象スクリプトscripts/backup-vault.shのbasenameと語順を一致させる）。
# 新ラベルを設置したうえで、旧ラベル(com.takumi009.vault-backup)が残っていれば
# bootout+plist削除する（設計書§4「install-backup.sh は新ラベル設置後に旧ラベルを
# bootout+削除」）。
#
# dotfiles/install.sh の install_launchagent() との違い（意図的）: あちらは
# bootstrap直後に `launchctl kickstart -k` で即時1回実行するが、本スクリプトは
# **bootstrap+enableのみ**で即時実行はしない（plist側もRunAtLoad=false）。
# Vaultの初回git化は「Vault分割・呼称の中立化等が完了してから」という
# 段階的ロールアウトが前提（設計§4-3）のため、インストール＝即バックアップ実行
# にしてしまうと、その前提確認より先にVaultがgit管理下に入ってしまう恐れがある。
# 初回実行は次のStartInterval（最大1時間後）を待つか、準備が整ってから
# `launchctl kickstart -k gui/$(id -u)/com.takumi009.backup-vault` を手動実行する。
#
# 使い方:
#   scripts/install-backup.sh            # 実行（配置 + launchctl (re)load。即時実行はしない）
#   scripts/install-backup.sh --dry-run  # 計画だけ表示（何もしない）
#
# 注意: インストール系スクリプトはユーザーが内容を確認したうえで実行する（自動実行しない）。
#
# テスト専用: SKIP_LAUNCHCTL=1 にすると launchctl への実操作（bootout/bootstrap/
# enable）だけをskipする（plist配置・旧ラベルのplist削除は行う。実LaunchAgent状態
# を書き換えずにファイル配置・移行ロジックだけを検証したいテスト向け。
# scripts/install-sub.sh の SKIP_LAUNCHCTL と同じ考え方・同じ変数名）。

set -euo pipefail

: "${SKIP_LAUNCHCTL:=0}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST_NAME="com.takumi009.backup-vault.plist"
SRC="$DIR/launchagents/$PLIST_NAME"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"
LABEL="${PLIST_NAME%.plist}"
DOMAIN="gui/$(id -u)"

# 旧ラベル（改名前・2026-07-16簡素化以前）。新ラベル設置後にこちらをbootout+削除する。
OLD_PLIST_NAME="com.takumi009.vault-backup.plist"
OLD_DEST="$HOME/Library/LaunchAgents/$OLD_PLIST_NAME"
OLD_LABEL="${OLD_PLIST_NAME%.plist}"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

log() { echo "[install-backup] $*"; }
warn() { echo "[install-backup] WARN: $*" >&2; }
fail() { echo "[install-backup] FAIL: $*" >&2; exit 1; }

# 旧ラベルがlaunchd上に「ロード済み」かどうかをplistファイルの有無とは独立に
# 確認する（2026-07-16 Codexレビュー指摘Major対応: plistファイルの有無だけで
# 移行要否を判定すると、「plistは既に無いが旧ジョブはlaunchd上に残っている」
# ケースを取り逃がす）。
#
# 戻り値は3値（2026-07-16 Codexレビュー3巡目指摘Major対応: 当初「ロード済み/
# 未ロード」の2値だけだったため、「旧plistファイルは存在するが旧ジョブは
# そもそも一度もロードされたことが無い」ケースで、未ロードサービスへの
# bootoutが（多くの場合）非0で終わることをもって毎回『bootout失敗』と誤判定
# し、削除して問題ない孤立plistを永久に温存し続けてしまっていた）:
#   loaded     : 旧ラベルがlaunchd上にロード済み（bootoutを試みる必要がある）
#   not_loaded : launchdへの照会自体は機能しており、旧ラベルは確実に未ロード
#                （plistが残っているだけなら安全に削除してよい）
#   unknown    : launchdへの照会そのものが機能していない（domain自体への
#                print照会が失敗）。この場合は「未ロード」と誤判定して安全な
#                plistを消してしまうリスクを避け、fail-closed（保守側）に倒す。
# SKIP_LAUNCHCTL=1の場合は実launchdへ一切問い合わせず"skip"を返す（テストが
# 実launchdセッションへread-onlyであっても絶対に触れないようにするため）。
old_label_status() {
  if [ "$SKIP_LAUNCHCTL" = "1" ]; then
    echo "skip"
    return
  fi
  if ! launchctl print "$DOMAIN" >/dev/null 2>&1; then
    echo "unknown"
    return
  fi
  if launchctl print "$DOMAIN/$OLD_LABEL" >/dev/null 2>&1; then
    echo "loaded"
  else
    echo "not_loaded"
  fi
}

[ -e "$SRC" ] || fail "リポジトリのファイルが見つかりません（checkout破損の可能性）: $SRC"

if [ "$DRY_RUN" = "1" ]; then
  log "[dry-run] would generate: $DEST <- $SRC （__AIENV_HOME__ を $HOME へ置換）"
  log "[dry-run] would run: launchctl bootout $DOMAIN/$LABEL （既存があれば一旦アンロード。無ければ無視）"
  log "[dry-run] would run: launchctl bootstrap $DOMAIN $DEST"
  log "[dry-run] would run: launchctl enable $DOMAIN/$LABEL"
  log "[dry-run] （kickstartは行わない＝即時実行しない設計。次のStartIntervalか手動kickstart待ち）"
  if [ -e "$OLD_DEST" ]; then
    log "[dry-run] would run: launchctl bootout $DOMAIN/$OLD_LABEL （旧ラベルの移行・plist削除の対象を検出）"
    log "[dry-run] would run: rm -f $OLD_DEST"
  fi
  log "[dry-run] 完了。実際の変更は一切行っていません。"
  exit 0
fi

mkdir -p "$(dirname "$DEST")"

# plistは symlink ではなく実ファイルとして配置する（dotfiles/install.shの
# install_launchagent()と同じ理由＝launchdのログイン時自動読込がsymlinked plist
# では不安定なため）。__AIENV_HOME__ を実ホームパスへ置換しつつ、mktemp書き込み
# →mvで原子的に生成する（scripts/install-main.shのgenerate_config_toml()と同方式）。
escaped_home=$(printf '%s' "$HOME" | sed -e 's/[&\]/\\&/g' -e 's/#/\\#/g')
tmp="$(mktemp "$(dirname "$DEST")/.$(basename "$DEST").aienv-tmp.XXXXXX")"
trap 'rm -f "$tmp"' RETURN
sed "s#__AIENV_HOME__#${escaped_home}#g" "$SRC" > "$tmp"
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
    # （macOS launchdの既知の挙動。scripts/install-maintenance.shで確立した
    # 方式の横展開・2026-07-16 リーダー裁定対応）。enableを試みてから
    # bootstrapを1回だけ再試行する。
    warn "launchd: bootstrap failed for ${LABEL}（disabled状態の可能性があるため、enable後に1回だけ再試行します）"
    launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
    if launchctl bootstrap "$DOMAIN" "$DEST" 2>/dev/null; then
      bootstrap_ok=1
    fi
  fi

  if [ "$bootstrap_ok" = "1" ]; then
    if launchctl enable "$DOMAIN/$LABEL" 2>/dev/null; then
      log "launchd: (re)loaded ${LABEL}（即時実行はしていません。初回は次のStartInterval、または準備が整い次第 'launchctl kickstart -k ${DOMAIN}/${LABEL}' を手動実行してください）"
    else
      # enableの失敗を無視するとラベルがdisabledのまま静かに残り、launchdは
      # 次回起動後も再enableされるまでロードしない（scripts/install-maintenance.sh
      # で確立した方式の横展開・2026-07-16 リーダー裁定対応。以前は`|| true`で
      # 握り潰していた）。
      fail "launchd: enable failed for ${LABEL}（手動でenableしてください: launchctl enable $DOMAIN/${LABEL}）"
    fi
  else
    # $DESTを${DEST}と明示的に波括弧で囲む（2026-07-16 テスト実装中に発見:
    # bash 3.2(macOS既定)+ja_JP.UTF-8ロケール環境で、裸の$VARの直後に全角記号
    # （）等）が続くと変数名の境界を誤認識し「unbound variable」で本来の
    # エラーメッセージを握りつぶしてしまう実バグがある。scripts/install-sub.sh・
    # scripts/install-vault-agents.shの同型fail()メッセージにも同じパターンが
    # あったため合わせて修正した）。
    fail "launchd: bootstrap failed for ${LABEL}（disabled状態のenable経由リトライも失敗。手動でロードしてください: launchctl enable $DOMAIN/${LABEL} && launchctl bootstrap $DOMAIN ${DEST}）"
  fi
fi

# --- 旧ラベル(com.takumi009.vault-backup)の移行: bootout + plist削除 ---
# 新ラベルの設置・(re)loadが成功した後にのみ行う（設計書§4「新ラベル設置後に旧
# ラベルをbootout+削除」＝新旧どちらのラベルも存在しない空白期間を作らない
# ため）。
# old_label_status()の4値（skip/loaded/not_loaded/unknown）で判定する。
# **plistファイルの有無で外側を先にゲートしない**（2026-07-16 Codexレビュー4巡目
# 指摘Major対応: 当初`if [ -e "$OLD_DEST" ] || [ status = loaded ]`という外側の
# 条件で先に絞ってから内側でcase分岐していたが、「旧plistファイルは既に無いが
# unknown（launchd照会不能）」の組み合わせだと外側の条件自体がfalseになり、
# unknown分岐へ一切入らずサイレントにexit 0で完了扱いになってしまっていた。
# statusをまずcaseで分岐し、plist削除の要否は各分岐の内側で
# `[ -e "$OLD_DEST" ]` を個別に見る構造に変更した）。
MIGRATION_FAILED=0
OLD_STATUS_ONCE="$(old_label_status)"
case "$OLD_STATUS_ONCE" in
  unknown)
    # launchdへの照会そのものが機能していない状態。plistファイルの有無に
    # 関わらず「旧ジョブが本当に存在しないか」を確認できていないため、
    # 「未ロード」と誤判定して安全なplistを消してしまうより、fail-closedで
    # 温存する（plistが元々無い場合でも、launchd上に旧ジョブだけが残っている
    # 可能性を否定できないため同様に扱う）。
    warn "旧ラベル（${OLD_LABEL}）のロード状態をlaunchd照会で確認できませんでした。plistは削除せず次回実行時に再試行します。手動確認: launchctl print ${DOMAIN}"
    MIGRATION_FAILED=1
    ;;
  skip)
    if [ -e "$OLD_DEST" ]; then
      log "旧ラベル（${OLD_LABEL}）を検出したため移行します（bootout + plist削除）"
      log "SKIP_LAUNCHCTL=1 のため旧ラベルのlaunchctl bootoutはskipします（テスト用。plist削除は行います）"
      rm -f "$OLD_DEST"
      log "旧ラベル（${OLD_LABEL}）を削除しました。"
    fi
    ;;
  not_loaded)
    # launchdへの照会自体は機能しており、旧ラベルは確実に未ロード。
    # plistファイルが孤立して残っている場合のみ、安全に削除する
    # （plistも無ければ何もする必要が無い＝既に移行済み）。
    if [ -e "$OLD_DEST" ]; then
      log "旧ラベル（${OLD_LABEL}）を検出したため移行します（bootout + plist削除）"
      rm -f "$OLD_DEST"
      log "旧ラベル（${OLD_LABEL}）を削除しました（launchd上には元々ロードされていませんでした）。"
    fi
    ;;
  loaded)
    log "旧ラベル（${OLD_LABEL}）を検出したため移行します（bootout + plist削除）"
    if launchctl bootout "$DOMAIN/$OLD_LABEL" 2>/dev/null; then
      rm -f "$OLD_DEST"
      log "旧ラベル（${OLD_LABEL}）を削除しました。"
    else
      warn "旧ラベル（${OLD_LABEL}）のbootoutに失敗しました。plistは削除せず次回実行時に再試行します。手動確認: launchctl print ${DOMAIN}/${OLD_LABEL} ／ 手動解除: launchctl bootout ${DOMAIN}/${OLD_LABEL}"
      MIGRATION_FAILED=1
    fi
    ;;
esac

log "done."

# 新ラベルの設置自体は成功しているため"done."までは出すが、旧ラベルの後片付けが
# 未完了の場合は最終的な終了コードを非0にする（インストール全体が黙って成功扱い
# にならないようにする＝2026-07-16 Codexレビュー2巡目指摘Major対応）。
if [ "$MIGRATION_FAILED" = "1" ]; then
  exit 1
fi
