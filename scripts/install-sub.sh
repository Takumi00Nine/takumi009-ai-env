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
#   5. 機役割の宣言は本人が行う（2026-07-24 リーダー裁定・Codex一次レビュー指摘
#      Major対応の設計を2026-09-07に配役表-能力軸整理-設計へ引き継いだ）。
#      claude/hooks/check-sub-update.sh・scripts/update-sub.sh は配役表の能力軸
#      `machine_role`が「sub」と解決できることを積極的な証明として要求する
#      fail-closed方式（旧方式＝Vaultのprivate層専用ファイルの「不在」による
#      判定は、メイン機で私的パッチが未適用/復旧中等の理由で一時的にファイルが
#      欠けていると誤ってサブ扱いされ、案内どおりupdate-sub.shを実行すると
#      メインVaultの`Preferences/`が`rsync --delete`で上書き削除される事故に
#      なり得た）。本スクリプトは実体プロファイルの中身を編集しない（FR-15＝
#      実体を編集するのは本人だけ。⚠️ 実体が無ければ内部で呼ぶinstall-main.sh
#      のP1機構がconfig/profile.md.sampleから新規作成することはあるが、
#      既にある実体を書き換えることは無い）。代わりに`machine_role`を書く
#      案内を1行出す。
#
# 使い方:
#   scripts/install-sub.sh                   # 実行（Vault骨格配置 + claude/codex symlink化）
#   scripts/install-sub.sh --dry-run         # 計画だけ表示（何もしない）
#   scripts/install-sub.sh --with-dotfiles   # 上記に加え、dotfiles（部品・下請け）も導入する
#   scripts/install-sub.sh --check-profile   # 副作用ゼロの検査（実行せずプロファイル状態だけ見る）
#
# --with-dotfiles は install-main.sh へそのまま委譲する（実装の二重管理を避ける。
# install-main.sh側の挙動＝相談資料§3-5「dotfilesは独立のまま部品として下請け」）。
#
# --check-profile（install-main.sh 4.2-e の検査口をサブ機からも直接叩けるようにする
# 転送・2026-09-02追加）: install-main.sh 側が副作用ゼロで自身exitする契約
# （check_profile_cmd()）のため、本スクリプト側でも検査モードのときはstep1
# （Vault骨格配置）を行わず、委譲呼び出しの直後にinstall-main.shの終了コードを
# そのまま返して即終了する＝step3〜5（機役割の案内ログ等）へは一切進まない。
# `--check-profile --print-schema-version` を付けた場合は install-main.sh が
# schema_versionの値だけを1行返す契約（§6）を壊さないよう、本スクリプト自身の
# ログ（"claude/・codex/ の配置は…委譲します"等）もこのモードでは出さない。
#
# 注意: インストール系スクリプトはユーザーが内容を確認したうえで実行する（自動実行しない）。

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${VAULT:=$HOME/Data/obsidian}"
# 配役表-能力軸整理-設計-2026-09-07.md §5.1: 案内ログ（step 5）が参照する
# だけの既定値。install-main.sh も同じ既定値を自分で宣言しており両者は
# 同じパスへ解決するため、export はしない（本人が環境変数で上書きした
# 場合も両者が等しく見る）。
: "${AIENV_LOCAL_PROFILE_PATH:=$HOME/.config/takumi009-ai-env/profile.md}"
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
CHECK_PROFILE=0
PRINT_SCHEMA_VERSION=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --with-dotfiles) WITH_DOTFILES=1 ;;
    # 2026-09-01 配役表解凍 §3.9: リーダー配役の対話は共通関数1箇所
    # （install-main.sh側）に置き、install-sub.shはそのままinstall-main.sh
    # へ委譲する（フラグが落ちると挙動が変わるため必ず転送する）。
    --reconfigure-leader) RECONFIGURE_LEADER=1 ;;
    --non-interactive) NON_INTERACTIVE=1 ;;
    # 2026-09-02追加: install-main.sh 4.2-eの検査口（副作用ゼロ）をサブ機からも
    # 直接叩けるようにする転送。--print-schema-versionは--check-profileの
    # サブモード（単独では意味を持たない・install-main.sh側の既存契約）。
    --check-profile) CHECK_PROFILE=1 ;;
    --print-schema-version) PRINT_SCHEMA_VERSION=1 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

log() { echo "[install-sub] $*"; }
warn() { echo "[install-sub] WARN: $*" >&2; }
fail() { echo "[install-sub] FAIL: $*" >&2; exit 1; }

[ -d "$DIR/vault-public" ] || fail "リポジトリに vault-public/ が見つかりません（checkout破損の可能性）: $DIR/vault-public"
[ -x "$DIR/scripts/install-main.sh" ] || fail "install-main.sh が見つかりません（checkout破損の可能性）: $DIR/scripts/install-main.sh"

# --- 1. Vault骨格の配置（$VAULT が無い時だけ。既存Vaultは上書きしない） ---
# ⚠️ --check-profile 検査モードでは一切進まない（2026-09-02追加）。検査は
# 副作用ゼロの契約（install-main.sh 4.2-e）であり、Vault骨格配置はその契約を
# 破る副作用そのものなので、検査モードのときはこのstepごとskipする。
if [ "$CHECK_PROFILE" = "1" ]; then
  :
elif [ -e "$VAULT" ]; then
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
# ⚠️ --check-profile モードでは、この見出しログ自体を出さない
# （`--check-profile --print-schema-version` は install-main.sh 側で
# 「schema_versionの値だけを1行返す」契約＝§6のため、本スクリプト側の
# 前置きログを挟むと出力契約を壊してしまう）。
[ "$CHECK_PROFILE" != "1" ] && log "claude/・codex/ の配置は install-main.sh に委譲します"
main_args=(--sub-delegate)
[ "$DRY_RUN" = "1" ] && main_args+=(--dry-run)
[ "$WITH_DOTFILES" = "1" ] && main_args+=(--with-dotfiles)
[ "$RECONFIGURE_LEADER" = "1" ] && main_args+=(--reconfigure-leader)
[ "$NON_INTERACTIVE" = "1" ] && main_args+=(--non-interactive)
[ "$CHECK_PROFILE" = "1" ] && main_args+=(--check-profile)
[ "$PRINT_SCHEMA_VERSION" = "1" ] && main_args+=(--print-schema-version)
# ⚠️ 裸の呼び出しで`set -e`に任せると、install-main.sh側が設計書S4等の
# 「他の処理は完走させたうえで最終的に非0」を意図した終了コードを返した
# 場合でも、install-sub.shはここで即座に終了してしまい、後続のstep3〜5
# （機役割の案内ログを含む）が一切実行されない（2026-09-01 Codex
# 差分レビュー指摘・MAJOR対応）。案内ログの未出力は本人がmachine_roleの
# 書き方を知る機会を失うことに直結するため、install-main.shの終了
# コードもinstall-sub.sh自身の"AIENV_DEFERRED_EXIT_CODE"として引き継ぎ、
# 後続処理を完走させてからスクリプト末尾で反映する。
AIENV_MAIN_DELEGATE_RC=0
"$DIR/scripts/install-main.sh" "${main_args[@]+"${main_args[@]}"}" || AIENV_MAIN_DELEGATE_RC=$?

# --- --check-profile モードはここで終了する（副作用ゼロの検査口・2026-09-02追加）---
# install-main.sh 側の check_profile_cmd() は自身で完結してexitする契約
# （検査結果をそのまま返す）。install-sub.sh側はstep3〜5（メイン専用機能の
# 案内ログ・機役割の案内ログ等）へは一切進まず、委譲先の終了コードを
# そのまま返す。
if [ "$CHECK_PROFILE" = "1" ]; then
  exit "$AIENV_MAIN_DELEGATE_RC"
fi

# --- 3. メイン専用のLaunchAgent類は意図的にインストールしない ---
log "（メイン専用機能＝backup-vault・maintenance等のLaunchAgentはインストールしていません）"

# --- 4. サブ専用の定期更新LaunchAgentも意図的にインストールしない ---
# 2026-07-23 本人決定でサブの定期自動pull運用（旧com.takumi009.update-sub）を
# 廃止した（詳細は本ファイル冒頭のコメント参照）。実機のサブ機は本スクリプトを
# 一度も適用したことが無く、既設のLaunchAgentが存在しないため、旧ラベルの
# bootout/plist削除といった移行処理は不要（本人指示・2026-07-23）。単に設置しない
# だけでよい。
log "（サブ専用の定期更新LaunchAgentも廃止済みのためインストールしていません＝claude/hooks/check-sub-update.shのSessionStartフックに置き換え済み）"

# --- 5. 機役割（machine_role）の案内（サブ機として使うための本人操作を示す） ---
# 配役表-能力軸整理-設計-2026-09-07.md §5.1: 実体プロファイルへ`machine_role`を
# 書く処理は足さない（FR-15＝実体を編集するのは本人だけ）。案内を1行出す。
log "この機をサブ機として使うには、実体プロファイルへ machine_role: configured value=sub を1行書いてください（本スクリプトは実体を書き換えません。既存の実体が対象で、実体がまだ無い場合はconfig/profile.md.sampleからの新規作成のみ行います）: ${AIENV_LOCAL_PROFILE_PATH}"

if [ "$DRY_RUN" = "1" ]; then
  log "[dry-run] 完了。実際の変更は一切行っていません。"
else
  if [ "$AIENV_MAIN_DELEGATE_RC" != "0" ]; then
    warn "install-main.sh への委譲が非0終了しました（詳細は上記のinstall-mainログを参照）。案内ログの出力は完了しましたが、全体としては非0終了します。"
  else
    log "done."
  fi
fi
if [ "$AIENV_MAIN_DELEGATE_RC" != "0" ]; then
  exit "$AIENV_MAIN_DELEGATE_RC"
fi
