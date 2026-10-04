#!/usr/bin/env bash
# NG 語ファイルの既定の解決（Core 実行器・共有 lib・実行入口なし）。
# 公開前監査（core/executor/audit.sh）と公開出力（ai-brain/executor/export-public-vault.sh）が source する。
# 正本＝docs/v1.2-notify-install 設計 §2.5（D-7）。
#
# 状態（NGWORDS_FILE を与えないとき）:
#   N1 新既定だけ／N2 両方 → 新既定を使う
#   N- どちらも無い        → 新既定のパスを入れて返す（呼び手が現行どおり「見つかりません」で止める）
#   N0 旧既定だけ          → 非 0。stderr に説明 1 行と「移す 1 コマンド」1 行（そのまま貼って実行できる形）
# 移す 1 コマンド＝旧既定が相対リンクなら、同じ実体を指す相対リンクを新既定に張って旧を消す
#   （例＝../../x → ../../../x。新既定は旧既定より 1 段深い）。実ファイル・絶対リンクなら mv。

# ---- 既定値（変えるときはここだけ） ----
NGWORDS_NEW_REL="core/data/ngwords.txt"   # 新既定（Core のデータ層・git 管理外）
NGWORDS_OLD_REL="scripts/ngwords.txt"     # 旧既定（検出して移す 1 コマンドを示すだけ）

# ngwords_resolve <repo ルート> — NGWORDS_FILE が空なら既定を解決して NGWORDS_FILE に入れる。
#   返り値 0＝使えるパスが入った（N1・N2・N-・NGWORDS_FILE 指定）／1＝N0（移す 1 コマンドを stderr へ）。
ngwords_resolve() {
  local root new old target dir up cmd d
  [ -n "${NGWORDS_FILE:-}" ] && return 0
  root="$(cd "$1" && pwd)" || return 1
  new="$root/${NGWORDS_NEW_REL}"
  old="$root/${NGWORDS_OLD_REL}"
  NGWORDS_FILE="$new"
  if [ -e "$new" ] || [ -L "$new" ] || { [ ! -e "$old" ] && [ ! -L "$old" ]; }; then
    return 0
  fi
  target="$(readlink "$old" 2>/dev/null)"
  if [ -n "$target" ] && [ "${target#/}" = "$target" ]; then
    # 旧既定のフォルダから見た相対の字面を、新既定のフォルダから見た字面へ書き換える。
    dir="$(dirname "${NGWORDS_OLD_REL}")"
    while [ "${target#../}" != "$target" ] && [ "$dir" != "." ]; do
      target="${target#../}"; dir="$(dirname "$dir")"
    done
    [ "$dir" = "." ] && dir="" || dir="$dir/"
    up=""; d="$(dirname "${NGWORDS_NEW_REL}")"
    while [ "$d" != "." ]; do up="../$up"; d="$(dirname "$d")"; done
    cmd="ln -s $(printf '%q' "$up$dir$target") ${NGWORDS_NEW_REL} && rm ${NGWORDS_OLD_REL}"
  else
    cmd="mv ${NGWORDS_OLD_REL} ${NGWORDS_NEW_REL}"
  fi
  echo "NG 語ファイルが旧既定 ${NGWORDS_OLD_REL} にだけあります（新既定＝${NGWORDS_NEW_REL}）。次の 1 コマンドで移してから再実行してください:" >&2
  echo "cd $(printf '%q' "$root") && mkdir -p $(dirname "${NGWORDS_NEW_REL}") && $cmd" >&2
  return 1
}
