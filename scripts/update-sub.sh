#!/usr/bin/env bash
# サブ機の手動更新コマンド（**サブ専用**・本人が能動的に実行する。SessionStart
# フック claude/hooks/check-sub-update.sh が未反映コミットを検知すると本コマンドの
# 実行を案内する）。
#
# 処理は直列 1 本＝毎回すべて行う（状態ファイルを持たない・冪等。どこで失敗しても
# 同じコマンドの再実行で前へ進む）:
#   0. 配役表の machine_role が「sub」と解決できなければ拒否（メイン機での誤実行を
#      防ぐ最後の砦。メイン機で走ると 4. の rsync --delete がメイン Vault の
#      Preferences/ を消す。判定式の正本＝claude/hooks/lib/profile_resolve.py）
#   1. 多重起動防止ロック（scripts/lib/pid-lock.sh＝backup-vault.sh・maintenance.sh
#      と共通の実装）
#   2. git pull --ff-only（失敗＝WARN・exit 1・何も変えない。force しない）
#   3. scripts/install-sub.sh（symlink・settings.json・config.toml・agents symlink・
#      Vault 骨格＝配置の正本はこの 1 経路だけ。HEAD が不変でも毎回走る。
#      非0＝FAIL＋復旧コマンドを出し、同じ rc で exit）
#   4. vault-public/Preferences/ → $VAULT/Preferences/ を rsync -a --delete
#      （**Preferences 以外には絶対に触らない**＝サブ機ローカルの Fragments 等は消えない。
#      install-sub.sh には machine_role ガードが無いので、この処理は本スクリプトに残す）
#   5. vault-public/ 配下の新しい骨格フォルダ（Preferences 以外）を $VAULT へ補充
#      （既存フォルダの中身・README には触らない）
#
# 全体を main() に包み末尾で呼ぶ＝2. の pull で本ファイル自身が書き換わっても、実行中の
# 本文は解析済みで影響を受けない（次回 run から新版）。3. 以降の実作業は別プロセス
# install-sub.sh＝pull 後の新版が走る。自己再 exec・HEAD 比較による早期終了・
# install-main.sh の複製処理（settings.json 再生成・agents symlink・drift 自動修復）は
# 2026-09-19 に撤去した（ai-env 全体最適化 着手順 3・design-step3.md §2・§5）。
#
# 引数は受け付けない（旧 resync フラグは廃止＝毎回 Preferences を同期するので不要。
# 計画だけ見たいときは scripts/install-sub.sh --dry-run）。
# 復旧（本人が現地で打つ）:
#   cd ~/work/takumi009-ai-env && git pull --ff-only && scripts/install-sub.sh
#   scripts/update-sub.sh
#
# パスは $HOME 相対（DIR・VAULT・LOCK_FILE は環境変数で上書き可＝ユニットテスト用。
# 本番実行時は既定値のまま呼べば良い）。

set -euo pipefail

: "${DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${VAULT:=$HOME/Data/obsidian}"
: "${LOCK_FILE:=${TMPDIR:-/tmp}/aienv-update-sub.lock}"
# machine_role の共通レシピが使う入力（claude/hooks/check-sub-update.sh と同じ
# 既定値・同じ環境変数名）。
: "${PROFILE_RESOLVE_LIB:=$DIR/claude/hooks/lib/profile_resolve.py}"
: "${AIENV_LOCAL_PROFILE_PATH:=$HOME/.config/takumi009-ai-env/profile.md}"
: "${AIENV_AGENTS_DIR:=$DIR/claude/agents}"
: "${AIENV_BEDROCK_ENV_FILE:=$HOME/.config/takumi009-ai-env/bedrock.env}"
STALE_LOCK_SECONDS="${STALE_LOCK_SECONDS:-3600}"
# 3. の install-sub.sh（Vault 骨格配置）と 4.・5. が同じ Vault を見るようにする。
export VAULT

log() { echo "[update-sub] $*"; }
warn() { echo "[update-sub] WARN: $*" >&2; }
fail() { echo "[update-sub] FAIL: $*" >&2; exit 1; }

# pid-lock.sh は main() の外で source する（ライブラリが declare -a で作る
# グローバル配列を EXIT trap の _pid_lock_cleanup が読むため。関数内で source すると
# bash はその配列を関数ローカルにしてしまい、ロックの後始末が空振りする）。
[ -f "$DIR/scripts/lib/pid-lock.sh" ] || {
  echo "[update-sub] FAIL: scripts/lib/pid-lock.sh が見つかりません（checkout破損の可能性）: $DIR/scripts/lib/pid-lock.sh" >&2
  exit 1
}
. "$DIR/scripts/lib/pid-lock.sh"

# resolve_machine_role — 配役表の machine_role を main|sub|unknown の 1 語で標準出力へ。
# 解決失敗・欠落・unavailable はすべて unknown（積極的な証明が無ければ動かない
# fail-closed）。`|| _out=""` は set -e/pipefail 対策（resolve が非0のとき、コマンド
# 置換がそのまま script 全体を落として fail() の分かりやすいメッセージが出ないまま
# 黙って落ちる事故を防ぐ）。
resolve_machine_role() {
  local _out _tab _rest _role
  _out="$(python3 "$PROFILE_RESOLVE_LIB" resolve "$AIENV_LOCAL_PROFILE_PATH" \
    --bedrock-env "$AIENV_BEDROCK_ENV_FILE" --agents-dir "$AIENV_AGENTS_DIR" 2>/dev/null)" || _out=""
  _tab=$'\t'
  _rest="${_out#*"${_tab}MACHINE_ROLE:"}"
  _role=""
  [ "$_rest" != "$_out" ] && _role="${_rest%%"${_tab}"*}"
  case "$_role" in main|sub) printf '%s\n' "$_role" ;; *) printf 'unknown\n' ;; esac
}

main() {
  [ "$#" -eq 0 ] || fail "引数は受け付けません（旧 resync フラグは廃止＝毎回 Preferences を同期します。計画だけ見るには scripts/install-sub.sh --dry-run）: $*"

  # --- 0. 配役表 machine_role の確認（メインでの誤実行を防ぐ最後の砦） ---
  local machine_role
  machine_role="$(resolve_machine_role)"
  if [ "$machine_role" != "sub" ]; then
    # ${AIENV_LOCAL_PROFILE_PATH} と明示的に波括弧で囲む（bash 3.2＋ja_JP.UTF-8 で
    # 裸の $VAR 直後に全角記号が続くと変数名の境界を誤認識し unbound variable で
    # 本来の FAIL メッセージを握り潰す実バグの回帰防止）。
    fail "このマシンはサブ機として登録されていません（配役表の machine_role が sub ではありません: ${AIENV_LOCAL_PROFILE_PATH}）。メイン機でこのコマンドを実行すると Vault の Preferences が上書き削除される恐れがあるため拒否します。サブ機であれば実体プロファイルへ machine_role: configured value=sub を書いてください（検査＝scripts/install-sub.sh --check-profile）。"
  fi
  [ -d "$DIR/.git" ] || fail "DIR が git リポジトリではありません: $DIR"
  [ -x "$DIR/scripts/install-sub.sh" ] || fail "scripts/install-sub.sh が見つかりません（checkout破損の可能性）: $DIR/scripts/install-sub.sh"
  command -v git >/dev/null 2>&1 || fail "git が見つかりません"
  command -v rsync >/dev/null 2>&1 || fail "rsync が見つかりません"

  # --- 1. 多重起動防止ロック ---
  # acquire_pid_lock() は「他プロセスが保持中なら exit 0 で skip」の契約（backup-vault
  # 等の定期実行向け）。本コマンドは手動実行なので、先に読み取り専用の
  # is_pid_lock_held() で覗き、保持中なら非0で終える（更新できていないのに成功に
  # 見せない）。stale（PID 死亡）なら acquire_pid_lock() が回収して取得する。
  # 先読みと取得の間に別プロセスが取得した場合は pid-lock の契約どおり exit 0
  # （skip）になる＝手動コマンドの二重起動でしか起きない極小窓として許容
  # （2026-09-19 検証1巡目 θ-1）。
  if is_pid_lock_held "$LOCK_FILE"; then
    fail "既に実行中です（pid=$(sed -n 1p "$LOCK_FILE" 2>/dev/null)）。今回は何もしません: $LOCK_FILE"
  fi
  acquire_pid_lock "$LOCK_FILE" "$STALE_LOCK_SECONDS" "update-sub"

  # --- 2. git pull --ff-only（失敗しても何も変えない） ---
  local pull_out
  if ! pull_out="$(git -C "$DIR" pull --ff-only 2>&1)"; then
    warn "git pull --ff-only に失敗しました（ローカル変更との衝突・remote 未設定・ネットワーク等の可能性。サブは編集しない運用のため通常は起きないはずです）: $DIR"
    [ -n "$pull_out" ] && printf '%s\n' "$pull_out" >&2
    exit 1
  fi
  log "git pull --ff-only 完了（HEAD: $(git -C "$DIR" rev-parse --short HEAD 2>/dev/null || echo '?')）"

  # --- 3. 配置は install-sub.sh に委譲（pull 後の新版が別プロセスで走る） ---
  local rc=0
  "$DIR/scripts/install-sub.sh" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "[update-sub] FAIL: install-sub.sh が非0終了しました（rc=${rc}）。復旧: scripts/install-sub.sh を現地で再実行し、出力の先頭 FAIL 行を直してください" >&2
    exit "$rc"
  fi

  # --- 4. Preferences を rsync で再同期する（Preferences 以外は絶対に触らない） ---
  local vp_prefs="$DIR/vault-public/Preferences" vault_prefs="$VAULT/Preferences"
  [ -d "$vp_prefs" ] || fail "Preferences の rsync に失敗しました: ${vp_prefs} -> ${vault_prefs}（同期元 vault-public/Preferences が見つかりません＝checkout破損の可能性）"
  mkdir -p "$vault_prefs" 2>/dev/null && rsync -a --delete "$vp_prefs/" "$vault_prefs/" \
    || fail "Preferences の rsync に失敗しました: ${vp_prefs} -> ${vault_prefs}"
  log "Preferences を再同期しました: $vp_prefs -> $vault_prefs"

  # --- 5. 新しい骨格フォルダがあれば補充する（既存フォルダには一切触らない） ---
  local d name dest
  for d in "$DIR"/vault-public/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    [ "$name" = "Preferences" ] && continue
    dest="$VAULT/$name"
    [ -e "$dest" ] && continue
    mkdir -p "$dest" 2>/dev/null || fail "骨格フォルダを作成できません: ${dest}"
    if [ -f "$d/README.md" ]; then
      cp "$d/README.md" "$dest/README.md" || fail "骨格フォルダを作成できません: ${dest}"
    fi
    log "新しい骨格フォルダを補充しました: $dest"
  done

  log "done."
}

main "$@"
