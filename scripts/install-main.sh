#!/usr/bin/env bash
# メイン環境用インストーラ: このリポジトリの claude/・codex/ 配下を
# ライブ位置（~/.claude/・~/.codex/）へ symlink する（dotfiles/install.sh と同方式）。
#
# 冪等（再実行安全）: 既存の「実ファイル」（symlinkでないもの）は初回だけ
# "<dest>.pre-aienv.bak" へ退避してから symlink に置き換える。バックアップは
# 既に存在すれば上書きしない（2回目以降の実行や、symlinkでなく実ファイルを
# 生成し続ける config.toml でも、初回のオリジナルだけを守り続ける。
# Codexレビュー指摘・Major＝旧実装は generate_config_toml() が毎回 backup を
# 上書きし、2回目実行でオリジナルが失われる不具合があった）。
#
# 例外: codex/config.toml は symlink しない。plain TOML は（hooks.json の
# "command" 文字列と違い）シェル変数展開が行われないため、__AIENV_HOME__
# プレースホルダを実ホームパスへ置換した実ファイルとして生成する
# （詳細は codex/config.toml 冒頭のコメント参照）。
#
# 使い方:
#   scripts/install-main.sh                   # 実行（symlink化 / config.toml生成）
#   scripts/install-main.sh --dry-run         # 置換計画だけ表示（何もしない）
#   scripts/install-main.sh --with-dotfiles   # 上記に加え、dotfiles（部品・下請け）も導入する
#
# --with-dotfiles（既定OFF・明示オプション時のみ）: $HOME/work/dotfiles が無ければ
# `git clone` し、その後 dotfiles/install.sh を呼ぶ（既に存在する場合は clone を
# skipして install.sh だけ呼ぶ＝dotfiles側のinstall.shは再実行しても安全な設計のため。
# 相談資料§3-5「dotfilesは独立のまま部品として下請け」の実装）。
#
# --sub-delegate（内部専用・install-sub.sh がこのスクリプトへ委譲する際に常に付ける
# フラグ。手動指定は想定しない）: symlink化・config.toml生成・codex MCP登録は
# メイン/サブ共通で行うが、週次drift通知LaunchAgent（com.takumi009.drift-check.plist）
# の設置は**メイン専用機能**のためskipする（2026-07-08 設計決定H-2「メイン専用」の
# 実装。install-backup.sh・install-vault-agents.sh を別スクリプトに分離しているのと
# 同じ意図だが、drift-check はinstall-main.sh本体に統合する指示だったため、
# install-sub.shからの委譲経路だけをこのフラグで区別する）。
#
# 注意: インストール系スクリプトはユーザーが内容を確認したうえで実行する（自動実行しない）。
#       本スクリプトは既存の実ファイルをsymlinkへ置き換えるため、ユーザー本人が
#       立ち会って実行すること。

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${DOTFILES_DIR:=$HOME/work/dotfiles}"
: "${DOTFILES_REPO_URL:=https://github.com/Takumi00Nine/dotfiles}"
# テスト専用: "1" にすると scripts/setup-codex-mcp.sh の呼び出し自体をskipする
# （既定0）。setup-codex-mcp.sh は実 claude/codex CLI を呼びうるため、それらが
# 実際にPATH上にある開発機でテストを走らせると、HOMEをfixtureへ差し替えていても
# 実システムのMCP登録に触れてしまう恐れがある（Codexレビュー指摘・Major。
# scripts/install-sub.sh の SKIP_LAUNCHCTL と同じ考え方の対策）。
: "${SKIP_CODEX_MCP:=0}"
# テスト専用: "1" にすると launchctl への実操作（bootout/bootstrap/enable）だけを
# skipし、plist生成（プレースホルダ置換）はそのまま行う（週次drift通知LaunchAgentの
# 設置に使用。scripts/install-sub.sh の SKIP_LAUNCHCTL と同じ考え方・同じ変数名。
# 実launchd＝gui/$(id -u) はHOMEを差し替えても隔離できないため、テストで誤って
# 実システムのlaunchdへ登録してしまう事故を防ぐ。本番運用では常に既定値=0のまま）。
: "${SKIP_LAUNCHCTL:=0}"

DRY_RUN=0
WITH_DOTFILES=0
IS_SUB_DELEGATE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --with-dotfiles) WITH_DOTFILES=1 ;;
    --sub-delegate) IS_SUB_DELEGATE=1 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

log() { echo "[install-main] $*"; }
warn() { echo "[install-main] WARN: $*" >&2; }
fail() { echo "[install-main] FAIL: $*" >&2; exit 1; }

# バックアップは「.pre-aienv.bak がまだ無いときだけ」作る（何度実行しても
# 常にインストール前オリジナルを保持する。symlink化後は dest が symlink に
# なるため自然と対象外になるが、generate_config_toml() のように毎回実ファイルを
# 書く経路ではこのガードが無いと2回目の実行でオリジナルが消える）。
backup_once() {
  local dest="$1"
  if [ -e "$dest" ] && [ ! -L "$dest" ] && [ ! -e "$dest.pre-aienv.bak" ]; then
    cp "$dest" "$dest.pre-aienv.bak"
    log "backed up: $dest -> $dest.pre-aienv.bak"
  fi
}

# would_backup <dest> — dry-run表示用（backup_once相当の判定のみ、書き込みしない）
would_backup() {
  local dest="$1"
  [ -e "$dest" ] && [ ! -L "$dest" ] && [ ! -e "$dest.pre-aienv.bak" ]
}

# link <repo-relative-source> <destination>
# dotfiles/install.sh の link() と同方式（バックアップは backup_once() 経由）。
# source が無い場合は「このリポジトリの必須構成が壊れている」ことを意味するため
# skip扱いにせず fail する（Codexレビュー指摘・Minor：黙って進むと壊れた
# checkoutでも "done" と表示されてしまう）。
link() {
  local src="$DIR/$1" dest="$2"
  [ -e "$src" ] || fail "リポジトリのファイルが見つかりません（checkout破損の可能性）: $src"
  if [ "$DRY_RUN" = "1" ]; then
    would_backup "$dest" && log "[dry-run] would back up: $dest -> $dest.pre-aienv.bak"
    log "[dry-run] would link: $dest -> $src"
    return
  fi
  mkdir -p "$(dirname "$dest")"
  backup_once "$dest"
  ln -sfn "$src" "$dest"
  log "linked: $dest -> $src"
}

# generate_config_toml <repo-relative-source> <destination>
# symlink ではなく「プレースホルダ置換した実ファイル」を配置する
# （config.toml は plain TOML でシェル変数展開されないため）。
# 置換は sed のメタ文字（& \ その他区切り文字）を $HOME 側でエスケープしてから行い、
# 生成は mktemp への書き込み→mv で原子的に行う（Codexレビュー指摘・Minor：
# $HOME に & や \ が含まれる環境での置換破損、書き込み中断時の破損を防ぐ）。
generate_config_toml() {
  local src="$DIR/$1" dest="$2" escaped_home tmp
  [ -e "$src" ] || fail "リポジトリのファイルが見つかりません（checkout破損の可能性）: $src"
  if [ "$DRY_RUN" = "1" ]; then
    would_backup "$dest" && log "[dry-run] would back up: $dest -> $dest.pre-aienv.bak"
    log "[dry-run] would generate (not symlink): $dest <- $src （__AIENV_HOME__ を $HOME へ置換）"
    return
  fi
  mkdir -p "$(dirname "$dest")"
  backup_once "$dest"
  escaped_home=$(printf '%s' "$HOME" | sed -e 's/[&\]/\\&/g' -e 's/#/\\#/g')
  # dest と同じディレクトリに一時ファイルを作る（mv が同一ファイルシステム内の
  # atomic rename になることを保証するため。$TMPDIR が別ボリュームだと
  # atomicにならない可能性があるとのCodexレビュー指摘・Nit）。異常終了時は
  # trap で後始末する。
  tmp="$(mktemp "$(dirname "$dest")/.$(basename "$dest").aienv-tmp.XXXXXX")"
  trap 'rm -f "$tmp"' RETURN
  sed "s#__AIENV_HOME__#${escaped_home}#g" "$src" > "$tmp"
  mv "$tmp" "$dest"
  log "generated: $dest <- $src （__AIENV_HOME__ を $HOME へ置換）"
}

# --- claude/ ---
link claude/settings.json               "$HOME/.claude/settings.json"
link claude/hooks/bootstrap-vault.sh    "$HOME/.claude/hooks/bootstrap-vault.sh"
link claude/hooks/delegation-gate-v2.sh "$HOME/.claude/hooks/delegation-gate-v2.sh"

[ -d "$DIR/claude/agents" ] || fail "リポジトリのディレクトリが見つかりません（checkout破損の可能性）: $DIR/claude/agents"
for f in "$DIR"/claude/agents/*.md; do
  [ -e "$f" ] || fail "claude/agents/ 配下に .md が1つもありません（checkout破損の可能性）"
  name="$(basename "$f")"
  link "claude/agents/$name" "$HOME/.claude/agents/$name"
done

if [ "$DRY_RUN" != "1" ]; then
  chmod +x "$DIR/claude/hooks/bootstrap-vault.sh" "$DIR/claude/hooks/delegation-gate-v2.sh"
fi

# --- codex/ ---
link codex/AGENTS.md   "$HOME/.codex/AGENTS.md"
link codex/hooks.json  "$HOME/.codex/hooks.json"
generate_config_toml codex/config.toml "$HOME/.codex/config.toml"

# --- codex MCP登録（scripts/setup-codex-mcp.sh）。install-sub.shはこのスクリプトへ
#     委譲しているため自動的に恩恵を受ける。Claude Code未導入環境でも installer 全体を
#     落とさないよう、失敗はWARNに留めて続行する（2026-07-08 設計判断）。 ---
if [ "$SKIP_CODEX_MCP" = "1" ]; then
  log "SKIP_CODEX_MCP=1 のため codex MCP 登録はskipします（テスト用）"
elif [ "$DRY_RUN" = "1" ]; then
  log "[dry-run] would run: $DIR/scripts/setup-codex-mcp.sh"
else
  if [ -x "$DIR/scripts/setup-codex-mcp.sh" ]; then
    if "$DIR/scripts/setup-codex-mcp.sh"; then
      :
    else
      warn "codex MCP の登録に失敗しました（Claude Code未導入等の可能性）。手動で確認してください: scripts/setup-codex-mcp.sh"
    fi
  else
    warn "scripts/setup-codex-mcp.sh が見つかりません（checkout破損の可能性）"
  fi
fi

# --- 週次drift通知LaunchAgent（com.takumi009.drift-check.plist）。**メイン専用**。
#     install-backup.sh・install-vault-agents.sh と同方式＝実ファイルコピー＋
#     __AIENV_HOME__プレースホルダ置換＋bootstrap+enableのみ（即時kickstartはしない）。
#     scripts/check-drift.sh が陳腐化しないよう、週1（月曜09:30）で無人実行して
#     drift>0ならmacOS通知する（scripts/drift-notify.sh 経由）。
#     --sub-delegate（install-sub.shからの委譲）の場合はメイン専用機能としてskipする
#     （2026-07-08 adoption-critic指摘「陳腐化防止の宿題」対応・設計決定H-2）。 ---
if [ "$IS_SUB_DELEGATE" = "1" ]; then
  log "--sub-delegate のため週次drift通知LaunchAgentの設置はskipします（メイン専用機能）"
else
  DRIFT_CHECK_PLIST="com.takumi009.drift-check.plist"
  DRIFT_CHECK_SRC="$DIR/launchagents/$DRIFT_CHECK_PLIST"
  DRIFT_CHECK_DEST="$HOME/Library/LaunchAgents/$DRIFT_CHECK_PLIST"
  DRIFT_CHECK_LABEL="${DRIFT_CHECK_PLIST%.plist}"
  DRIFT_CHECK_DOMAIN="gui/$(id -u)"

  if [ ! -e "$DRIFT_CHECK_SRC" ]; then
    warn "$DRIFT_CHECK_PLIST が見つかりません（checkout破損の可能性）: $DRIFT_CHECK_SRC"
  elif [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] would generate: $DRIFT_CHECK_DEST <- $DRIFT_CHECK_SRC （__AIENV_HOME__ を $HOME へ置換）"
    log "[dry-run] would run: launchctl bootout ${DRIFT_CHECK_DOMAIN}/${DRIFT_CHECK_LABEL} （既存があれば一旦アンロード。無ければ無視）"
    log "[dry-run] would run: launchctl bootstrap $DRIFT_CHECK_DOMAIN $DRIFT_CHECK_DEST"
    log "[dry-run] would run: launchctl enable ${DRIFT_CHECK_DOMAIN}/${DRIFT_CHECK_LABEL}"
    log "[dry-run] （kickstartは行わない＝即時実行しない設計。次回発火（月曜09:30）か手動kickstart待ち）"
  else
    mkdir -p "$(dirname "$DRIFT_CHECK_DEST")"
    drift_escaped_home=$(printf '%s' "$HOME" | sed -e 's/[&\]/\\&/g' -e 's/#/\\#/g')
    drift_tmp="$(mktemp "$(dirname "$DRIFT_CHECK_DEST")/.$(basename "$DRIFT_CHECK_DEST").aienv-tmp.XXXXXX")"
    sed "s#__AIENV_HOME__#${drift_escaped_home}#g" "$DRIFT_CHECK_SRC" > "$drift_tmp"
    mv "$drift_tmp" "$DRIFT_CHECK_DEST"
    log "generated: $DRIFT_CHECK_DEST <- $DRIFT_CHECK_SRC （__AIENV_HOME__ を $HOME へ置換）"

    if [ "$SKIP_LAUNCHCTL" = "1" ]; then
      log "SKIP_LAUNCHCTL=1 のため launchctl 操作はskipします（テスト用）"
    else
      launchctl bootout "$DRIFT_CHECK_DOMAIN/$DRIFT_CHECK_LABEL" 2>/dev/null || true
      if launchctl bootstrap "$DRIFT_CHECK_DOMAIN" "$DRIFT_CHECK_DEST" 2>/dev/null; then
        launchctl enable "$DRIFT_CHECK_DOMAIN/$DRIFT_CHECK_LABEL" 2>/dev/null || true
        log "launchd: (re)loaded ${DRIFT_CHECK_LABEL}（即時実行はしていません。週1＝月曜09:30に自動チェックされます）"
      else
        warn "launchd: bootstrap failed for ${DRIFT_CHECK_LABEL}（手動でロードしてください: launchctl bootstrap $DRIFT_CHECK_DOMAIN $DRIFT_CHECK_DEST）"
      fi
    fi
  fi
fi

# --- dotfiles（部品・下請け）。--with-dotfiles 明示時のみ ---
# git clone・dotfiles/install.sh の実行はどちらも「実システムへの実行」であり
# 失敗しても致命的ではない（ネットワーク不通・後で手動でやり直せる）ため、
# 失敗時は warn に留めて本スクリプト自体は続行する（export-public-vault.sh の
# push失敗時と同方針＝soft-fail）。
if [ "$WITH_DOTFILES" = "1" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    if [ -d "$DOTFILES_DIR" ]; then
      log "[dry-run] dotfiles は既に存在するため clone はskipします: $DOTFILES_DIR"
    else
      log "[dry-run] would run: git clone $DOTFILES_REPO_URL $DOTFILES_DIR"
    fi
    log "[dry-run] would run: (cd $DOTFILES_DIR && ./install.sh)"
  else
    if [ -d "$DOTFILES_DIR" ]; then
      log "dotfiles は既に存在するため clone はskipします: $DOTFILES_DIR"
    else
      log "cloning dotfiles: $DOTFILES_REPO_URL -> $DOTFILES_DIR"
      if ! git clone "$DOTFILES_REPO_URL" "$DOTFILES_DIR"; then
        warn "dotfiles の clone に失敗しました。--with-dotfiles をスキップします（ネットワーク等を確認して手動で再試行してください）: git clone $DOTFILES_REPO_URL $DOTFILES_DIR"
      fi
    fi
    if [ -x "$DOTFILES_DIR/install.sh" ]; then
      log "running: $DOTFILES_DIR/install.sh"
      if ( cd "$DOTFILES_DIR" && ./install.sh ); then
        log "dotfiles install.sh 完了"
      else
        warn "dotfiles/install.sh が失敗しました（exit非0）。dotfiles側を個別に確認してください: $DOTFILES_DIR/install.sh"
      fi
    else
      warn "dotfiles/install.sh が見つからない、または実行権限がありません（clone失敗、または想定外のリポジトリ構成の可能性）: $DOTFILES_DIR/install.sh"
    fi
  fi
fi

if [ "$DRY_RUN" = "1" ]; then
  log "[dry-run] 完了。実際の変更は一切行っていません。"
else
  log "done."
fi
