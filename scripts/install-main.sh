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
# 同フラグはmachine-roleマーカー（後述）の扱いにも使う: --sub-delegate経由の
# 場合は委譲元のinstall-sub.shが既に"sub"を書き込む/書き込む予定のため、本
# スクリプト側では一切マーカーに触れない。
#
# machine-roleマーカー（$HOME/.config/takumi009-ai-env/machine-role）:
# 本スクリプトを --sub-delegate 無しで直接実行した場合（＝実際にメイン機として
# セットアップする場合）は明示的に"main"を書き込む（2026-07-24 Codex一次レビュー
# 指摘Major対応: かつてinstall-sub.shを実行しサブ機だった機体を、後から
# install-main.shを直接実行してメイン機へ移行する運用で、旧"sub"マーカーが
# 残ったままだとclaude/hooks/check-sub-update.sh・scripts/update-sub.shが
# サブ機と誤認し続け、update-sub.shの`rsync --delete`でメインVaultの
# `Preferences/`が上書き削除される事故になり得た）。
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

# --- machine-roleマーカー: --sub-delegate無し（＝メイン機としての直接実行）の
#     場合だけ明示的に"main"を書く。--sub-delegate経由では一切触れない
#     （委譲元のinstall-sub.shが"sub"を書き込む/書き込む予定のため。詳細は
#     本ファイル冒頭のコメント参照）。
#
# Codex再レビュー指摘・Major対応: 他の全処理より前（symlink化・config.toml生成
# 等の実処理が始まる前）に真っ先に書く。末尾に置いていた旧実装だと、直接実行の
# 途中でchecked-out破損等によりfail()して停止した場合、旧"sub"マーカーが
# 上書きされないまま残ってしまい、Main Vault上でscripts/update-sub.shが
# 引き続き許可されてしまう欠陥があった（本人が直接install-main.shを実行した
# 時点で「メイン機として使うつもりだ」という意思は既に確定しているため、
# 後続処理の成否に関わらず真っ先にマーカーを確定させるのが安全側）。
# 書込自体（mkdir/mktemp/mv）が失敗した場合はset -eによりここで即座に
# スクリプト全体が停止する（他のfail-fast処理と同じ扱い＝黙って続行しない）。
if [ "$IS_SUB_DELEGATE" != "1" ]; then
  : "${AIENV_MACHINE_ROLE_MARKER:=$HOME/.config/takumi009-ai-env/machine-role}"
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] would write: $AIENV_MACHINE_ROLE_MARKER (content: main)"
  else
    mkdir -p "$(dirname "$AIENV_MACHINE_ROLE_MARKER")"
    marker_tmp="$(mktemp "$(dirname "$AIENV_MACHINE_ROLE_MARKER")/.$(basename "$AIENV_MACHINE_ROLE_MARKER").aienv-tmp.XXXXXX")"
    printf 'main\n' > "$marker_tmp"
    mv "$marker_tmp" "$AIENV_MACHINE_ROLE_MARKER"
    log "machine-role マーカーを設置しました（main）: $AIENV_MACHINE_ROLE_MARKER"
  fi
fi

# --- claude/ ---
link claude/settings.json               "$HOME/.claude/settings.json"
link claude/hooks/bootstrap-vault.sh    "$HOME/.claude/hooks/bootstrap-vault.sh"
link claude/hooks/delegation-gate-v2.sh "$HOME/.claude/hooks/delegation-gate-v2.sh"
# 外部脳 想起支援(UserPromptSubmit)・利用ログ(PostToolUse Read) の2フック
# （2026-07-10 追加。settings.json への hooks 登録はリーダーが別途行う＝
# このスクリプトはsymlink配置のみを担当）。
link claude/hooks/vault-recall.sh    "$HOME/.claude/hooks/vault-recall.sh"
link claude/hooks/vault-read-log.sh  "$HOME/.claude/hooks/vault-read-log.sh"
# サブ機更新チェック(SessionStart)。settings.json は main/sub 共通でこのフックを
# 登録するため、リンクも main/sub 共通で配置する（スクリプト側が machine-role
# マーカーで判定し、メイン機では無出力で即 exit 0＝fail-closed）。
# 2026-07-28 追加: 2026-07-23 実装時にリンク配置が漏れており、両機で
# SessionStart に「No such file or directory」の非ブロッキングエラーが出ていた。
link claude/hooks/check-sub-update.sh "$HOME/.claude/hooks/check-sub-update.sh"

[ -d "$DIR/claude/agents" ] || fail "リポジトリのディレクトリが見つかりません（checkout破損の可能性）: $DIR/claude/agents"
for f in "$DIR"/claude/agents/*.md; do
  [ -e "$f" ] || fail "claude/agents/ 配下に .md が1つもありません（checkout破損の可能性）"
  name="$(basename "$f")"
  link "claude/agents/$name" "$HOME/.claude/agents/$name"
done

if [ "$DRY_RUN" != "1" ]; then
  chmod +x "$DIR/claude/hooks/bootstrap-vault.sh" "$DIR/claude/hooks/delegation-gate-v2.sh" \
           "$DIR/claude/hooks/vault-recall.sh" "$DIR/claude/hooks/vault-read-log.sh" \
           "$DIR/claude/hooks/check-sub-update.sh"
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

# 週次drift通知LaunchAgent（com.takumi009.drift-check.plist・scripts/drift-notify.sh）は
# 2026-07-16簡素化（[[Decisions/2026-07-16-nightly-batch-direct-write]]）で撤去した。
# 週次無人実行の経路は新設 maintenance.sh（PR2・install-maintenance.shが設置）へ移す。
# 既存マシンで稼働中の旧LAは install-maintenance.sh の移行処理（旧ラベルのbootout）で
# 片付ける（本スクリプトでは何もしない）。

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
