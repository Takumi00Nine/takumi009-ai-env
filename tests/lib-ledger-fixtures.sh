# v1.1（機能の部品化）の Core スイートが共有する fixture 部品。
# `test-*.sh` に一致しない名前＝一括実行の対象にならない（source して使う）。
#
# 使う側: tests/test-ledger.sh・test-decoupling.sh・test-session-start-compose.sh
#
# 提供するもの（要件 requirements-v1.md §7 の fixture 名で呼ぶ）:
#   LF_LEDGER_REL・LF_MOVES_REL・LF_LEDGER_TOOL_REL … 台帳・移動表・台帳ツールの repo 相対パス（実装計画 §2）
#   lf_copy_repo <src> <dest>      … worktree の複製（git が見る追跡対象＝ls-files -co。symlink はそのまま）を
#                                    git repo として作る（FX-1 の使い捨て複製）
#   lf_commit_all <dir>            … 複製の変更を 1 コミットに（実 git 設定・フックに依らない）
#   lf_ledger_paths <ledger> <awk 条件> … 台帳の行のうち条件に当たる行のパス列（2 列目）を 1 行ずつ
#   lf_mk_fx4 <ai-brain/data/vault-public> <dest> … FX-4（ai-brain/data/vault-public の複製＋Knowledge/zz-probe.md）
#   lf_mk_fx5 <ai-brain/data/vault-public> <dest> … FX-5（FX-4 を git 管理・初期コミット 1・remote なし・未コミット変更 1）
#   lf_mk_fx6 <dir>                … FX-6（偽 launchctl・osascript・cmux＝引数を <dir>/calls.log へ 1 行ずつ記録し exit 0）
#   lf_path_without <cmd>...       … PATH から指定コマンドを除いた PATH（含むディレクトリを影のディレクトリへ置き換える）
#
# ⚠️ 実 HOME・実 Vault・実 launchd・実 cmux には触れない（呼び出し側が HOME を一時ディレクトリにする）。

LF_LEDGER_REL="core/data/ledger.tsv"
LF_MOVES_REL="core/data/moves.tsv"
LF_LEDGER_TOOL_REL="core/assembly/ledger-tool.sh"

lf_git() {
  git -c user.name=aienv-test -c user.email=aienv-test@example.invalid \
      -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}

lf_commit_all() {
  lf_git -C "$1" add -A >/dev/null 2>&1
  lf_git -C "$1" commit -q -m "${2:-fixture}" >/dev/null 2>&1 || true
}

lf_copy_repo() {
  local src="$1" dest="$2" list
  mkdir -p "$dest"
  list="$(mktemp)"
  # 実在するものだけ（git mv 直後の旧パスは除く）。-h 相当＝symlink はリンクのまま写す。
  ( cd "$src" && git ls-files -co --exclude-standard -z \
      | while IFS= read -r -d '' f; do
          { [ -e "$f" ] || [ -L "$f" ]; } && printf '%s\0' "$f"
        done ) > "$list"
  ( cd "$src" && tar -cf - --null -T "$list" ) | ( cd "$dest" && tar -xf - )
  rm -f "$list"
  lf_git -C "$dest" init -q >/dev/null 2>&1
  lf_commit_all "$dest" "FX-1 copy"
}

lf_ledger_paths() {
  awk -F'\t' -v OFS='\t' '!/^#/ && NF>0 && ('"$2"') {print $2}' "$1"
}

lf_mk_fx4() {
  mkdir -p "$2"
  cp -R "$1"/. "$2"/
  mkdir -p "$2/Knowledge"
  printf -- '---\naliases: ["想起プローブ甲"]\n---\n想起の試験用ノート。\n' > "$2/Knowledge/zz-probe.md"
}

lf_mk_fx5() {
  lf_mk_fx4 "$1" "$2"
  lf_git -C "$2" init -q >/dev/null 2>&1
  lf_commit_all "$2" "FX-5 initial"
  printf '未コミットの変更\n' >> "$2/Knowledge/zz-probe.md"
}

lf_mk_fx6() {
  local d="$1" c
  mkdir -p "$d"
  : > "$d/calls.log"
  for c in launchctl osascript cmux; do
    printf '#!/bin/bash\nprintf "%%s\\n" "%s $*" >> "%s/calls.log"\nexit 0\n' "$c" "$d" > "$d/$c"
    chmod +x "$d/$c"
  done
}

lf_path_without() {
  local root out="" d shadow f n=0 hit c
  root="$(mktemp -d)"
  local IFS=':'
  for d in $PATH; do
    [ -n "$d" ] || continue
    hit=0
    for c in "$@"; do [ -x "$d/$c" ] && hit=1; done
    if [ "$hit" = "1" ]; then
      n=$((n + 1)); shadow="$root/$n"; mkdir -p "$shadow"
      for f in "$d"/*; do
        [ -e "$f" ] || continue
        for c in "$@"; do [ "${f##*/}" = "$c" ] && continue 2; done
        ln -s "$f" "$shadow/${f##*/}" 2>/dev/null || true
      done
      d="$shadow"
    fi
    out="${out:+$out:}$d"
  done
  printf '%s' "$out"
}
