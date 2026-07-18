#!/usr/bin/env bash
# サブ環境用インストーラ: install-main.sh と同じ symlink 方式だが、
# 「私的パッチが無い（Vault実体・秘匿設定が無い）」サブ機前提の差分を追加する。
#
# サブ前提の差分:
#   1. Vault骨格の配置: $HOME/Data/obsidian が無ければ、このリポジトリの
#      vault-public/ の中身をそのままコピーして作る（サブのVault＝publicスナップショット
#      ＋空骨格。既に存在する場合は上書きしない＝private層を壊さないため）。
#   2. claude/・codex/ の symlink化は install-main.sh をそのまま呼び出して再利用する
#      （DRY。ロジックの二重管理を避ける）。bootstrap-vault.sh 側は「存在するファイルだけ
#      必読リストに載せる」よう既に改修済みのため、Personal/profile-personal.md 等が
#      無いサブ機でも「見つかりません」を連発しない（2026-07-08 設計判断）。
#   3. 週次メンテナンスランナー（maintenance.sh）・バックアップLaunchAgentは
#      インストールしない（メイン専用機能）。install-backup.sh・install-maintenance.sh
#      は本スクリプトから一切呼び出さない。install-main.sh へ委譲する際に
#      `--sub-delegate` を付けてskipさせる。
#   4. サブ専用の定期更新LaunchAgent（com.takumi009.update-sub.plist・
#      scripts/update-sub.sh を1日2回起動）を設置する（**サブ専用**。メインでは設置しない
#      ＝メインは編集側なので自動pullは多地点編集事故のもと。2026-07-08 本人発案）。
#      ラベル改名（2026-07-16簡素化・設計書§5「命名規則統一＝LAラベルは対象
#      スクリプトのbasenameと同語順」対応。設計書に明記の唯一の改名対象
#      （vault-backup→backup-vault）以外にも語順不一致が残っていた見落としを
#      PR3残確認で発見・リーダー裁定2026-07-16で改名確定）:
#      com.takumi009.sub-update → com.takumi009.update-sub
#      （対象スクリプトscripts/update-sub.shのbasenameと語順を一致させる）。
#      新ラベル設置後に旧ラベルをbootout+削除する（scripts/install-backup.shと
#      同じ1対1改名パターン＝新旧どちらのラベルも存在しない空白期間を作らない）。
#
# 使い方:
#   scripts/install-sub.sh                   # 実行（Vault骨格配置 + claude/codex symlink化）
#   scripts/install-sub.sh --dry-run         # 計画だけ表示（何もしない）
#   scripts/install-sub.sh --with-dotfiles   # 上記に加え、dotfiles（部品・下請け）も導入する
#
# --with-dotfiles は install-main.sh へそのまま委譲する（実装の二重管理を避ける。
# install-main.sh側の挙動＝相談資料§3-5「dotfilesは独立のまま部品として下請け」）。
#
# 注意: インストール系スクリプトはユーザーが内容を確認したうえで実行する（自動実行しない）。

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${VAULT:=$HOME/Data/obsidian}"
# テスト専用: "1" にすると launchctl への実操作（bootout/bootstrap/enable）だけを
# skipし、plist生成（プレースホルダ置換）はそのまま行う。--dry-runは生成すら
# しないため、生成物の中身（RunAtLoad等）を検査するテストにはこちらを使う
# （実launchd＝gui/$(id -u) はHOMEを差し替えても隔離できないため、テストで誤って
# 実システムのlaunchdへ登録してしまう事故を防ぐ。本番運用では常に既定値=0のまま）。
: "${SKIP_LAUNCHCTL:=0}"

DRY_RUN=0
WITH_DOTFILES=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --with-dotfiles) WITH_DOTFILES=1 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

log() { echo "[install-sub] $*"; }
warn() { echo "[install-sub] WARN: $*" >&2; }
fail() { echo "[install-sub] FAIL: $*" >&2; exit 1; }

[ -d "$DIR/vault-public" ] || fail "リポジトリに vault-public/ が見つかりません（checkout破損の可能性）: $DIR/vault-public"
[ -x "$DIR/scripts/install-main.sh" ] || fail "install-main.sh が見つかりません（checkout破損の可能性）: $DIR/scripts/install-main.sh"

# --- 1. Vault骨格の配置（$VAULT が無い時だけ。既存Vaultは上書きしない） ---
if [ -e "$VAULT" ]; then
  log "VAULT は既に存在するため骨格配置はskipします（既存を壊さない）: $VAULT"
else
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] would copy: $DIR/vault-public/ -> $VAULT/"
  else
    mkdir -p "$(dirname "$VAULT")"
    cp -R "$DIR/vault-public/" "$VAULT/"
    log "copied: $DIR/vault-public/ -> $VAULT/ （publicスナップショット＋空骨格）"
  fi
fi

# --- 2. claude/・codex/ の symlink化・config.toml生成（＋--with-dotfiles）は
#        install-main.sh に委譲 ---
# 注意: bash 3.2（macOSシステムbash）は「空配列を "${arr[@]}" 展開」すると
# set -u 下で unbound variable になる既知の制限がある（bash 4.4で修正済みだが
# macOSは3.2のまま）。"${arr[@]+"${arr[@]}"}" の形で回避する（実測確認済み）。
log "claude/・codex/ の配置は install-main.sh に委譲します"
main_args=(--sub-delegate)
[ "$DRY_RUN" = "1" ] && main_args+=(--dry-run)
[ "$WITH_DOTFILES" = "1" ] && main_args+=(--with-dotfiles)
"$DIR/scripts/install-main.sh" "${main_args[@]+"${main_args[@]}"}"

# --- 3. メイン専用のLaunchAgent類は意図的にインストールしない ---
log "（メイン専用機能＝backup-vault・maintenance等のLaunchAgentはインストールしていません）"

# --- 4. サブ専用の定期更新LaunchAgent（com.takumi009.update-sub.plist）を設置する ---
# install-backup.shと同方式＝実ファイルコピー＋__AIENV_HOME__プレースホルダ
# 置換＋bootstrap+enableのみ（即時kickstartはしない。初回実行は次回発火＝
# 当日09:00/13:00のいずれか、または手動kickstart待ち）。disabled override時の
# 1回リトライ・enable失敗の即fail()も含めinstall-backup.shで確立した方式を
# 踏襲する（2026-07-16 リーダー裁定「同型パターンの横展開」）。
SUB_UPDATE_PLIST="com.takumi009.update-sub.plist"
SUB_UPDATE_SRC="$DIR/launchagents/$SUB_UPDATE_PLIST"
SUB_UPDATE_DEST="$HOME/Library/LaunchAgents/$SUB_UPDATE_PLIST"
SUB_UPDATE_LABEL="${SUB_UPDATE_PLIST%.plist}"
SUB_UPDATE_DOMAIN="gui/$(id -u)"

# 旧ラベル（改名前・2026-07-16簡素化以前）。新ラベル設置後にこちらをbootout+
# 削除する（scripts/install-backup.shと同じ1対1改名パターン）。
OLD_SUB_UPDATE_PLIST="com.takumi009.sub-update.plist"
OLD_SUB_UPDATE_DEST="$HOME/Library/LaunchAgents/$OLD_SUB_UPDATE_PLIST"
OLD_SUB_UPDATE_LABEL="${OLD_SUB_UPDATE_PLIST%.plist}"

# 旧ラベルがlaunchd上に「ロード済み」かどうかをplistファイルの有無とは独立に
# 確認する（scripts/install-backup.shのold_label_status()と同じ設計・同じ
# Codexレビュー対応をそのまま踏襲）。
old_sub_update_label_status() {
  if [ "$SKIP_LAUNCHCTL" = "1" ]; then
    echo "skip"
    return
  fi
  if ! launchctl print "$SUB_UPDATE_DOMAIN" >/dev/null 2>&1; then
    echo "unknown"
    return
  fi
  if launchctl print "$SUB_UPDATE_DOMAIN/$OLD_SUB_UPDATE_LABEL" >/dev/null 2>&1; then
    echo "loaded"
  else
    echo "not_loaded"
  fi
}

[ -e "$SUB_UPDATE_SRC" ] || fail "リポジトリのファイルが見つかりません（checkout破損の可能性）: $SUB_UPDATE_SRC"

if [ "$DRY_RUN" = "1" ]; then
  log "[dry-run] would generate: $SUB_UPDATE_DEST <- $SUB_UPDATE_SRC （__AIENV_HOME__ を $HOME へ置換）"
  log "[dry-run] would run: launchctl bootout ${SUB_UPDATE_DOMAIN}/${SUB_UPDATE_LABEL} （既存があれば一旦アンロード。無ければ無視）"
  log "[dry-run] would run: launchctl bootstrap $SUB_UPDATE_DOMAIN $SUB_UPDATE_DEST"
  log "[dry-run] would run: launchctl enable ${SUB_UPDATE_DOMAIN}/${SUB_UPDATE_LABEL}"
  log "[dry-run] （kickstartは行わない＝即時実行しない設計。次回発火か手動kickstart待ち）"
  if [ -e "$OLD_SUB_UPDATE_DEST" ]; then
    log "[dry-run] would run: launchctl bootout ${SUB_UPDATE_DOMAIN}/${OLD_SUB_UPDATE_LABEL} （旧ラベルの移行・plist削除の対象を検出）"
    log "[dry-run] would run: rm -f $OLD_SUB_UPDATE_DEST"
  fi
else
  mkdir -p "$(dirname "$SUB_UPDATE_DEST")"
  escaped_home=$(printf '%s' "$HOME" | sed -e 's/[&\]/\\&/g' -e 's/#/\\#/g')
  sub_update_tmp="$(mktemp "$(dirname "$SUB_UPDATE_DEST")/.$(basename "$SUB_UPDATE_DEST").aienv-tmp.XXXXXX")"
  sed "s#__AIENV_HOME__#${escaped_home}#g" "$SUB_UPDATE_SRC" > "$sub_update_tmp"
  mv "$sub_update_tmp" "$SUB_UPDATE_DEST"
  log "generated: $SUB_UPDATE_DEST <- $SUB_UPDATE_SRC （__AIENV_HOME__ を $HOME へ置換）"

  if [ "$SKIP_LAUNCHCTL" = "1" ]; then
    log "SKIP_LAUNCHCTL=1 のため launchctl 操作はskipします（テスト用）"
  else
    launchctl bootout "$SUB_UPDATE_DOMAIN/$SUB_UPDATE_LABEL" 2>/dev/null || true
    sub_update_bootstrap_ok=0
    if launchctl bootstrap "$SUB_UPDATE_DOMAIN" "$SUB_UPDATE_DEST" 2>/dev/null; then
      sub_update_bootstrap_ok=1
    else
      # ラベルがlaunchdのdisabled override（過去の手動`launchctl disable`等）に
      # 残っている場合、bootstrapはenableされるまで失敗し続けることがある
      # （macOS launchdの既知の挙動。scripts/install-backup.shで確立した方式の
      # 横展開・2026-07-16 リーダー裁定対応）。enableを試みてからbootstrapを
      # 1回だけ再試行する。
      warn "launchd: bootstrap failed for ${SUB_UPDATE_LABEL}（disabled状態の可能性があるため、enable後に1回だけ再試行します）"
      launchctl enable "$SUB_UPDATE_DOMAIN/$SUB_UPDATE_LABEL" 2>/dev/null || true
      if launchctl bootstrap "$SUB_UPDATE_DOMAIN" "$SUB_UPDATE_DEST" 2>/dev/null; then
        sub_update_bootstrap_ok=1
      fi
    fi

    if [ "$sub_update_bootstrap_ok" = "1" ]; then
      if launchctl enable "$SUB_UPDATE_DOMAIN/$SUB_UPDATE_LABEL" 2>/dev/null; then
        log "launchd: (re)loaded ${SUB_UPDATE_LABEL}（即時実行はしていません。1日2回＝09:00/13:00に自動更新されます）"
      else
        # enableの失敗を無視するとラベルがdisabledのまま静かに残り、launchdは
        # 次回起動後も再enableされるまでロードしない（scripts/install-backup.sh
        # で確立した方式の横展開・2026-07-16 リーダー裁定対応）。
        fail "launchd: enable failed for ${SUB_UPDATE_LABEL}（手動でenableしてください: launchctl enable $SUB_UPDATE_DOMAIN/${SUB_UPDATE_LABEL}）"
      fi
    else
      # $SUB_UPDATE_DESTを${SUB_UPDATE_DEST}と明示的に波括弧で囲む（2026-07-16
      # scripts/install-backup.shのテスト実装中に発見: bash 3.2(macOS既定)+
      # ja_JP.UTF-8ロケール環境で、裸の$VARの直後に全角記号（）等）が続くと
      # 変数名の境界を誤認識し「unbound variable」で本来のエラーメッセージを
      # 握りつぶしてしまう実バグがある）。
      fail "launchd: bootstrap failed for ${SUB_UPDATE_LABEL}（disabled状態のenable経由リトライも失敗。手動でロードしてください: launchctl enable $SUB_UPDATE_DOMAIN/${SUB_UPDATE_LABEL} && launchctl bootstrap $SUB_UPDATE_DOMAIN ${SUB_UPDATE_DEST}）"
    fi
  fi
fi

# --- 旧ラベル(com.takumi009.sub-update)の移行: bootout + plist削除 ---
# 新ラベルの設置・(re)loadが成功した後にのみ行う（scripts/install-backup.shと
# 同じ理由＝新旧どちらのラベルも存在しない空白期間を作らないため）。
SUB_UPDATE_MIGRATION_FAILED=0
if [ "$DRY_RUN" != "1" ]; then
  OLD_SUB_UPDATE_STATUS_ONCE="$(old_sub_update_label_status)"
  case "$OLD_SUB_UPDATE_STATUS_ONCE" in
    unknown)
      warn "旧ラベル（${OLD_SUB_UPDATE_LABEL}）のロード状態をlaunchd照会で確認できませんでした。plistは削除せず次回実行時に再試行します。手動確認: launchctl print ${SUB_UPDATE_DOMAIN}"
      SUB_UPDATE_MIGRATION_FAILED=1
      ;;
    skip)
      if [ -e "$OLD_SUB_UPDATE_DEST" ]; then
        log "旧ラベル（${OLD_SUB_UPDATE_LABEL}）を検出したため移行します（plist削除。SKIP_LAUNCHCTL=1のためbootoutはskip）"
        rm -f "$OLD_SUB_UPDATE_DEST"
        log "旧ラベル（${OLD_SUB_UPDATE_LABEL}）を削除しました。"
      fi
      ;;
    not_loaded)
      if [ -e "$OLD_SUB_UPDATE_DEST" ]; then
        log "旧ラベル（${OLD_SUB_UPDATE_LABEL}）を検出したため移行します（launchd上には元々ロードされていませんでした）"
        rm -f "$OLD_SUB_UPDATE_DEST"
        log "旧ラベル（${OLD_SUB_UPDATE_LABEL}）を削除しました。"
      fi
      ;;
    loaded)
      log "旧ラベル（${OLD_SUB_UPDATE_LABEL}）を検出したため移行します（bootout + plist削除）"
      if launchctl bootout "$SUB_UPDATE_DOMAIN/$OLD_SUB_UPDATE_LABEL" 2>/dev/null; then
        rm -f "$OLD_SUB_UPDATE_DEST"
        log "旧ラベル（${OLD_SUB_UPDATE_LABEL}）を削除しました。"
      else
        warn "旧ラベル（${OLD_SUB_UPDATE_LABEL}）のbootoutに失敗しました。plistは削除せず次回実行時に再試行します。手動確認: launchctl print ${SUB_UPDATE_DOMAIN}/${OLD_SUB_UPDATE_LABEL} ／ 手動解除: launchctl bootout ${SUB_UPDATE_DOMAIN}/${OLD_SUB_UPDATE_LABEL}"
        SUB_UPDATE_MIGRATION_FAILED=1
      fi
      ;;
  esac
fi

if [ "$DRY_RUN" = "1" ]; then
  log "[dry-run] 完了。実際の変更は一切行っていません。"
else
  log "done."
fi

# 新ラベルの設置自体は成功しているため"done."までは出すが、旧ラベルの後片付けが
# 未完了の場合は最終的な終了コードを非0にする（scripts/install-backup.shと
# 同じ方針）。
if [ "$SUB_UPDATE_MIGRATION_FAILED" = "1" ]; then
  exit 1
fi
