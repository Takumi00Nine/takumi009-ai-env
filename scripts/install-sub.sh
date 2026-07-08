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
#   3. Vault育成系LaunchAgents（vault-inventory等）・バックアップLaunchAgentは
#      インストールしない（メイン専用機能）。install-backup.sh・install-vault-agents.sh
#      は本スクリプトから一切呼び出さない。週次drift通知LaunchAgent
#      （com.takumi009.drift-check.plist）も同様にインストールしない（メイン専用機能。
#      install-main.sh へ委譲する際に `--sub-delegate` を付けてskipさせる）。
#   4. サブ専用の定期更新LaunchAgent（com.takumi009.sub-update.plist・
#      scripts/update-sub.sh を1日2回起動）を設置する（**サブ専用**。メインでは設置しない
#      ＝メインは編集側なので自動pullは多地点編集事故のもと。2026-07-08 本人発案）。
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
log "（メイン専用機能＝backup-vault・vault-inventory等のLaunchAgentはインストールしていません）"

# --- 4. サブ専用の定期更新LaunchAgent（com.takumi009.sub-update.plist）を設置する ---
# install-backup.sh/install-vault-agents.sh と同方式＝実ファイルコピー＋
# __AIENV_HOME__プレースホルダ置換＋bootstrap+enableのみ（即時kickstartはしない。
# 初回実行は次回発火＝当日09:00/13:00のいずれか、または手動kickstart待ち）。
SUB_UPDATE_PLIST="com.takumi009.sub-update.plist"
SUB_UPDATE_SRC="$DIR/launchagents/$SUB_UPDATE_PLIST"
SUB_UPDATE_DEST="$HOME/Library/LaunchAgents/$SUB_UPDATE_PLIST"
SUB_UPDATE_LABEL="${SUB_UPDATE_PLIST%.plist}"
SUB_UPDATE_DOMAIN="gui/$(id -u)"

[ -e "$SUB_UPDATE_SRC" ] || fail "リポジトリのファイルが見つかりません（checkout破損の可能性）: $SUB_UPDATE_SRC"

if [ "$DRY_RUN" = "1" ]; then
  log "[dry-run] would generate: $SUB_UPDATE_DEST <- $SUB_UPDATE_SRC （__AIENV_HOME__ を $HOME へ置換）"
  log "[dry-run] would run: launchctl bootout ${SUB_UPDATE_DOMAIN}/${SUB_UPDATE_LABEL} （既存があれば一旦アンロード。無ければ無視）"
  log "[dry-run] would run: launchctl bootstrap $SUB_UPDATE_DOMAIN $SUB_UPDATE_DEST"
  log "[dry-run] would run: launchctl enable ${SUB_UPDATE_DOMAIN}/${SUB_UPDATE_LABEL}"
  log "[dry-run] （kickstartは行わない＝即時実行しない設計。次回発火か手動kickstart待ち）"
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
    if launchctl bootstrap "$SUB_UPDATE_DOMAIN" "$SUB_UPDATE_DEST" 2>/dev/null; then
      launchctl enable "$SUB_UPDATE_DOMAIN/$SUB_UPDATE_LABEL" 2>/dev/null || true
      log "launchd: (re)loaded ${SUB_UPDATE_LABEL}（即時実行はしていません。1日2回＝09:00/13:00に自動更新されます）"
    else
      fail "launchd: bootstrap failed for ${SUB_UPDATE_LABEL}（手動でロードしてください: launchctl bootstrap $SUB_UPDATE_DOMAIN $SUB_UPDATE_DEST）"
    fi
  fi
fi

if [ "$DRY_RUN" = "1" ]; then
  log "[dry-run] 完了。実際の変更は一切行っていません。"
else
  log "done."
fi
