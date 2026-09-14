#!/usr/bin/env bash
# scripts/lib/managed-symlink.sh
#
# install-main.sh の link() と update-sub.sh の claude/agents/*.md 直接配置
# （2c.）が共有する「destが既存の通常ファイルなら安全に退避してからsymlink化
# する」処理を1箇所に集約する（検証4巡目 BLOCKING-1対応・2026-09-14）。
#
# 経緯: 検証3巡目 BLOCKING-1で、install-main.sh の backup_once() に
# --additional-on-diff というオプトイン引数を追加し、link() だけがこれを
# 渡すよう限定した（既存の.pre-aienv.bakと内容が異なる通常ファイルへ
# symlink化しようとした場合、そのままln -sfnすると内容が消えるため）。
# しかし update-sub.sh は install-main.sh を呼ばず、claude/agents/*.md の
# symlink化を自前で（同じ規則のつもりで）複製実装しており、この対応の
# 適用漏れが検証4巡目 BLOCKING-1として再発した。同じ規則を2箇所に
# コピペで持ち込むと再び分岐する（実際に再発した）ため、共有関数へ
# 抽出し、install-main.sh・update-sub.sh の両方がこれを呼ぶ。
#
# sync_managed_symlink <src> <dest> <log_prefix>
#   destが既存の通常ファイル（symlinkではない）の場合:
#     - .pre-aienv.bakがまだ無ければ作る（インストール前オリジナルを
#       保持する）。
#     - .pre-aienv.bakが既にあり、かつ現在のdestの内容がそれと異なる
#       場合は、衝突しない追加backup（<dest>.pre-aienv.bak.<UTCタイム
#       スタンプ>。同一秒内の衝突は連番.1・.2…を付与）へ保存してから
#       symlink化する。内容が既存backupと同じ場合は何もしない。
#   その後 `ln -sfn <src> <dest>` でsymlink化し、標準出力へ
#   `[<log_prefix>] backed up: ...` / `[<log_prefix>] linked: ...` を
#   出す（scripts/lib/pid-lock.sh の log_prefix引数と同じ流儀。呼び出し元
#   スクリプトのlog()に依存せず、この関数単体で完結させるため）。
#
#   cp失敗はreturn 1で伝える。呼び出し元のset -eに委ねる方針
#   （install-main.sh backup_once()の既存方針＝2026-09-01工程横断レビュー
#   指摘・MAJOR対応の踏襲。「cmd || fail ...」の左辺で呼ぶとbash仕様上
#   set -eが関数本体全体で無効化されるため、あえて`||`で包まず素の
#   呼び出しのままにする）。
sync_managed_symlink() {
  local src="$1" dest="$2" log_prefix="$3"
  mkdir -p "$(dirname "$dest")"
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    if [ ! -e "$dest.pre-aienv.bak" ]; then
      if ! cp "$dest" "$dest.pre-aienv.bak"; then
        return 1
      fi
      echo "[$log_prefix] backed up: $dest -> $dest.pre-aienv.bak"
    elif ! cmp -s "$dest" "$dest.pre-aienv.bak"; then
      local ts extra_bak suffix
      ts="$(TZ=UTC date -u +%Y%m%dT%H%M%SZ)"
      extra_bak="$dest.pre-aienv.bak.$ts"
      suffix=0
      while [ -e "$extra_bak" ]; do
        suffix=$((suffix + 1))
        extra_bak="$dest.pre-aienv.bak.$ts.$suffix"
      done
      if ! cp "$dest" "$extra_bak"; then
        return 1
      fi
      echo "[$log_prefix] backed up (既存の.pre-aienv.bakと内容が異なる通常ファイルのため追加保存): $dest -> $extra_bak"
    fi
  fi
  ln -sfn "$src" "$dest"
  echo "[$log_prefix] linked: $dest -> $src"
}
