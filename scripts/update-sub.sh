#!/usr/bin/env bash
# サブ環境の定期更新: このリポジトリを git pull し、変化があれば
# codex/config.toml の再生成・Vaultの Preferences 再同期・新しい骨格フォルダの
# 補充を行う（2026-07-08 本人発案・サブ専用）。
#
# launchagents/com.takumi009.sub-update.plist から1日2回（09:00/13:00）無人実行
# される前提のスクリプト（install-sub.sh が配置する。**サブ専用**＝メインでは
# 設置しない。メインは編集側なので自動pullは多地点編集事故のもと）。
#
# 処理順序:
#   1. スクリプト自身の多重起動防止ロック（backup-vault.shと同方式・原子的）
#   2. git pull --ff-only（衝突可能性を排除。ff不可ならWARNで終了。サブは
#      編集しない運用のため通常は起きないはずだが、念のため force しない）
#   3. pull で HEAD が変化していなければ何もせず終了（静か・冪等）
#   4. 変化があれば:
#      a. codex/config.toml をテンプレから再生成する
#         （install-main.sh の generate_config_toml() と同等処理。
#          既存の .pre-aienv.bak は上書きしない）
#      b. vault-public/Preferences/ を $HOME/Data/obsidian/Preferences/ へ
#         rsync -a --delete で再同期する（**Preferences 以外には絶対に触らない**＝
#         サブ機ローカルの Fragments 等の断片を消さないため）
#      c. vault-public/ 配下に新しい骨格フォルダ（Preferences以外）があり、
#         $VAULT にまだ存在しなければ mkdir + README.md を補充する
#         （既存フォルダの中身・READMEには触らない）
#
# パスは $HOME 相対（DIR・VAULT・LOCK_FILE は環境変数で上書き可＝ユニットテスト用。
# 本番実行時は既定値のまま呼べば良い）。

set -euo pipefail

: "${DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${VAULT:=$HOME/Data/obsidian}"
: "${LOCK_FILE:=${TMPDIR:-/tmp}/aienv-update-sub.lock}"
STALE_LOCK_SECONDS="${STALE_LOCK_SECONDS:-3600}"

log() { echo "[update-sub] $*"; }
warn() { echo "[update-sub] WARN: $*" >&2; }
fail() { echo "[update-sub] FAIL: $*" >&2; exit 1; }

[ -d "$DIR/.git" ] || fail "DIR が git リポジトリではありません: $DIR"
command -v git >/dev/null 2>&1 || fail "git が見つかりません"
command -v rsync >/dev/null 2>&1 || fail "rsync が見つかりません"

# --- 1. 多重起動防止ロック（backup-vault.shと同方式・原子的） ---
try_create_lock() {
  ( set -C; echo "$$" > "$LOCK_FILE" ) 2>/dev/null
}
acquire_lock() {
  if try_create_lock; then
    trap 'rm -f "$LOCK_FILE"' EXIT
    return
  fi
  local old_pid
  old_pid="$(cat "$LOCK_FILE" 2>/dev/null || true)"
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    log "既に実行中です（pid=${old_pid}）。今回はskipします。"
    exit 0
  fi
  warn "stale なロックファイルを検出しました（pid=${old_pid:-unknown} は生存していません）。解除して続行します: $LOCK_FILE"
  rm -f "$LOCK_FILE"
  if try_create_lock; then
    trap 'rm -f "$LOCK_FILE"' EXIT
    return
  fi
  old_pid="$(cat "$LOCK_FILE" 2>/dev/null || true)"
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    log "ロック再取得中に別プロセスが先に取得しました（pid=${old_pid}）。今回はskipします。"
    exit 0
  fi
  fail "ロック取得に失敗しました（原因不明。再試行してください）: $LOCK_FILE"
}
acquire_lock

# --- 2. git pull --ff-only ---
if ! git -C "$DIR" remote get-url origin >/dev/null 2>&1; then
  warn "remote 'origin' が設定されていません。git pull をスキップします: $DIR"
  exit 0
fi

before_head="$(git -C "$DIR" rev-parse HEAD 2>/dev/null || echo '')"
pull_rc=0
git -C "$DIR" pull --ff-only >/dev/null 2>&1 || pull_rc=$?
if [ "$pull_rc" -ne 0 ]; then
  warn "git pull --ff-only に失敗しました（ローカル変更との衝突等の可能性。サブは編集しない運用のため通常は起きないはずです）: $DIR"
  exit 0
fi
after_head="$(git -C "$DIR" rev-parse HEAD 2>/dev/null || echo '')"

# --- 3. 変化が無ければ静かに終了 ---
if [ "$before_head" = "$after_head" ]; then
  log "変更なし（${after_head}）。何もしません。"
  exit 0
fi

log "更新を検知しました: ${before_head} -> ${after_head}"

# --- 4a. codex/config.toml をテンプレから再生成する ---
# install-main.sh の generate_config_toml() と同等の処理（意図的な複製。
# ロジックを変える場合はinstall-main.sh側も合わせて見直すこと）。
CONFIG_SRC="$DIR/codex/config.toml"
CONFIG_DEST="$HOME/.codex/config.toml"
if [ -f "$CONFIG_SRC" ]; then
  if [ -e "$CONFIG_DEST" ] && [ ! -L "$CONFIG_DEST" ] && [ ! -e "$CONFIG_DEST.pre-aienv.bak" ]; then
    cp "$CONFIG_DEST" "$CONFIG_DEST.pre-aienv.bak"
    log "backed up: $CONFIG_DEST -> $CONFIG_DEST.pre-aienv.bak"
  fi
  mkdir -p "$(dirname "$CONFIG_DEST")"
  # $HOME はここでは sed の「置換値」側（s#PATTERN#REPLACEMENT#）として使うため、
  # エスケープが必要なのは置換値の特殊文字（& \）と区切り文字（#）だけでよい
  # （install-main.sh の generate_config_toml() と全く同じ用途・同じエスケープ）。
  # 検索パターン側で使う check-drift.sh とは必要なエスケープの種類が異なる点に注意
  # （Codexレビュー指摘・Minor：正規表現メタ文字まで一律エスケープすると、
  # $HOME に "." 等が含まれる環境で生成される config.toml に余計な "\" が混入する）。
  escaped_home=$(printf '%s' "$HOME" | sed -e 's/[&\]/\\&/g' -e 's/#/\\#/g')
  config_tmp="$(mktemp "$(dirname "$CONFIG_DEST")/.$(basename "$CONFIG_DEST").aienv-tmp.XXXXXX")"
  sed "s#__AIENV_HOME__#${escaped_home}#g" "$CONFIG_SRC" > "$config_tmp"
  mv "$config_tmp" "$CONFIG_DEST"
  log "config.toml を再生成しました: $CONFIG_DEST"
else
  warn "codex/config.toml のテンプレが見つかりません（checkout破損の可能性）: $CONFIG_SRC"
fi

# --- 4b. Preferences をrsyncで再同期する（Preferences以外は絶対に触らない） ---
VP_PREFS="$DIR/vault-public/Preferences"
VAULT_PREFS="$VAULT/Preferences"
if [ -d "$VP_PREFS" ]; then
  mkdir -p "$VAULT_PREFS"
  rsync -a --delete "$VP_PREFS/" "$VAULT_PREFS/"
  log "Preferences を再同期しました: $VP_PREFS -> $VAULT_PREFS"
else
  warn "vault-public/Preferences が見つかりません（checkout破損の可能性）: $VP_PREFS"
fi

# --- 4c. 新しい骨格フォルダがあれば補充する（既存フォルダには一切触らない） ---
if [ -d "$DIR/vault-public" ]; then
  for d in "$DIR"/vault-public/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    [ "$name" = "Preferences" ] && continue
    dest="$VAULT/$name"
    if [ ! -e "$dest" ]; then
      mkdir -p "$dest"
      if [ -f "$d/README.md" ]; then
        cp "$d/README.md" "$dest/README.md"
      fi
      log "新しい骨格フォルダを補充しました: $dest"
    fi
  done
fi

log "done."
