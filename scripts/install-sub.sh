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
#   4. サブ専用の定期更新LaunchAgent（旧com.takumi009.update-sub・1日2回=09:00/13:00の
#      無人自動pull）は2026-07-23 本人決定で廃止した。代わりにSessionStartフック
#      （claude/hooks/check-sub-update.sh）がセッション起動のたびに未反映コミットの
#      有無を実測し、あれば `scripts/update-sub.sh` の手動実行を案内する運用へ
#      置き換えた（本人が能動的に実行する）。よって本スクリプトは**LaunchAgentを
#      一切設置しない**（旧ラベルの移行/撤去処理も無い＝本人指示: 実機のサブ機は
#      本スクリプトを一度も適用したことが無く、既設のLaunchAgentが存在しないため
#      移行処理自体が不要）。
#   5. machine-role マーカーファイル（既定 $HOME/.config/takumi009-ai-env/machine-role、
#      中身は「sub」）を設置する（2026-07-24 リーダー裁定・Codex一次レビュー指摘
#      Major対応）。claude/hooks/check-sub-update.sh・scripts/update-sub.sh は
#      このマーカーの中身が「sub」であることを積極的な証明として要求する
#      fail-closed方式に変更した（旧方式＝Vaultのprivate層専用ファイルの
#      「不在」による判定は、メイン機で私的パッチが未適用/復旧中等の理由で
#      一時的にファイルが欠けていると誤ってサブ扱いされ、案内どおり
#      update-sub.shを実行するとメインVaultの`Preferences/`が
#      `rsync --delete`で上書き削除される事故になり得た）。本スクリプト（サブ専用
#      インストーラ）だけがこのマーカーを書き込み、install-main.sh
#      （--sub-delegate経由含む）は一切書かない＝メイン機で誤ってマーカーが立つ
#      経路は設計上存在しない。
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
# 注意: 本スクリプト自身はLaunchAgentを一切設置しないためlaunchctlを直接
# 呼び出さない（2026-07-23廃止のサブ専用定期更新LaunchAgentの設置処理を撤去済み）。
# 呼び出し側が既存テストとの互換のため SKIP_LAUNCHCTL=1 を渡すことがあるが、
# 本スクリプトはこれを参照しない（委譲先の install-main.sh は同名の環境変数を
# 別目的＝週次drift通知LaunchAgent向けに宣言だけしているが未使用。実launchdへは
# 触れない）。

DRY_RUN=0
WITH_DOTFILES=0
RECONFIGURE_LEADER=0
NON_INTERACTIVE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --with-dotfiles) WITH_DOTFILES=1 ;;
    # 2026-09-01 配役表解凍 §3.9: リーダー配役の対話は共通関数1箇所
    # （install-main.sh側）に置き、install-sub.shはそのままinstall-main.sh
    # へ委譲する（フラグが落ちると挙動が変わるため必ず転送する）。
    --reconfigure-leader) RECONFIGURE_LEADER=1 ;;
    --non-interactive) NON_INTERACTIVE=1 ;;
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
[ "$RECONFIGURE_LEADER" = "1" ] && main_args+=(--reconfigure-leader)
[ "$NON_INTERACTIVE" = "1" ] && main_args+=(--non-interactive)
# ⚠️ 裸の呼び出しで`set -e`に任せると、install-main.sh側が設計書S4等の
# 「他の処理は完走させたうえで最終的に非0」を意図した終了コードを返した
# 場合でも、install-sub.shはここで即座に終了してしまい、後続のstep3〜5
# （machine-roleマーカー設置を含む）が一切実行されない（2026-09-01 Codex
# 差分レビュー指摘・MAJOR対応）。マーカー未設置はcheck-sub-update.sh・
# update-sub.shのfail-closed判定に影響するため、install-main.shの終了
# コードもinstall-sub.sh自身の"AIENV_DEFERRED_EXIT_CODE"として引き継ぎ、
# 後続処理を完走させてからスクリプト末尾で反映する。
AIENV_MAIN_DELEGATE_RC=0
"$DIR/scripts/install-main.sh" "${main_args[@]+"${main_args[@]}"}" || AIENV_MAIN_DELEGATE_RC=$?

# --- 3. メイン専用のLaunchAgent類は意図的にインストールしない ---
log "（メイン専用機能＝backup-vault・maintenance等のLaunchAgentはインストールしていません）"

# --- 4. サブ専用の定期更新LaunchAgentも意図的にインストールしない ---
# 2026-07-23 本人決定でサブの定期自動pull運用（旧com.takumi009.update-sub）を
# 廃止した（詳細は本ファイル冒頭のコメント参照）。実機のサブ機は本スクリプトを
# 一度も適用したことが無く、既設のLaunchAgentが存在しないため、旧ラベルの
# bootout/plist削除といった移行処理は不要（本人指示・2026-07-23）。単に設置しない
# だけでよい。
log "（サブ専用の定期更新LaunchAgentも廃止済みのためインストールしていません＝claude/hooks/check-sub-update.shのSessionStartフックに置き換え済み）"

# --- 5. machine-roleマーカーの設置（サブ機であることの積極的な証明） ---
# check-sub-update.sh・update-sub.shはこのマーカーの中身が「sub」であることを
# 要求するfail-closed方式（詳細は本ファイル冒頭のコメント参照）。原子的書込
# （mktemp+mv）はcodex/config.toml生成・plist生成と同じ既存様式を踏襲。
: "${AIENV_MACHINE_ROLE_MARKER:=$HOME/.config/takumi009-ai-env/machine-role}"
if [ "$DRY_RUN" = "1" ]; then
  log "[dry-run] would write: $AIENV_MACHINE_ROLE_MARKER (content: sub)"
else
  mkdir -p "$(dirname "$AIENV_MACHINE_ROLE_MARKER")"
  marker_tmp="$(mktemp "$(dirname "$AIENV_MACHINE_ROLE_MARKER")/.$(basename "$AIENV_MACHINE_ROLE_MARKER").aienv-tmp.XXXXXX")"
  printf 'sub\n' > "$marker_tmp"
  mv "$marker_tmp" "$AIENV_MACHINE_ROLE_MARKER"
  log "machine-role マーカーを設置しました（sub）: $AIENV_MACHINE_ROLE_MARKER"
fi

if [ "$DRY_RUN" = "1" ]; then
  log "[dry-run] 完了。実際の変更は一切行っていません。"
else
  if [ "$AIENV_MAIN_DELEGATE_RC" != "0" ]; then
    warn "install-main.sh への委譲が非0終了しました（詳細は上記のinstall-mainログを参照）。machine-roleマーカー等の他の処理は完了しましたが、全体としては非0終了します。"
  else
    log "done."
  fi
fi
if [ "$AIENV_MAIN_DELEGATE_RC" != "0" ]; then
  exit "$AIENV_MAIN_DELEGATE_RC"
fi
