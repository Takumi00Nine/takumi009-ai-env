#!/usr/bin/env bash
# scripts/lib/managed-symlink.sh
#
# install-main.sh・update-sub.shが共有する「管理配置先のsymlink同期」を
# 1箇所に集約する（検証4巡目 BLOCKING-1対応・2026-09-14）。
#
# ⚠️ 2026-09-17〜 effort-per-role v2（設計-v1.2.md §2）は本ファイルへ職種
# 定義の生成実ファイル方式（frontmatterへeffort値を都度書き込む生成・判定
# 関数群）を追加したが、案件③ B-1 D-4（設計-v1.1.3.md §5 手順2）で退役し、
# symlink方式（本ファイルの sync_managed_symlink）へ戻した。B-1のラッパーが
# effortの実行値を--effortで子へ渡すため、職種定義ファイル側にeffort:行を
# 持たせる必要が無くなったため。
#
# --- sync_managed_symlink ---
#
# install-main.sh の link() と update-sub.sh の claude/agents/*.md直接
# 配置（2c.）が共有していた「destが既存の通常ファイルなら安全に退避してから
# symlink化する」処理。
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
#   cp失敗はreturn 1で伝える。呼び出し元は`if ! _backup_managed_dest ...; then
#   return 1; fi`のように明示的に非0を検査する（2026-09-17検証1巡目差し戻し
#   MINOR-10対応: 「cmd || fail ...」の左辺で呼ぶとbash仕様上set -eが関数
#   本体全体で無効化される、という一般的な注意は正しいが、
#   _backup_managed_dest()自身の内部（cp・cmp）はすべて明示的にreturn 1する
#   実装であり、呼び出し元を`||`で包んでも実害は無い。ただし規約として
#   紛らわしいため呼び出し側は素の`||`を避け、if文で明示する）。

# _backup_managed_dest <dest> <log_prefix>
# destが既存の通常ファイル（symlinkではない）の場合、.pre-aienv.bakへ退避
# する（無ければ新規作成／既存と内容が違えばタイムスタンプ付き追加保存）。
# sync_managed_symlink() が使う退避規則の実体。
_backup_managed_dest() {
  local dest="$1" log_prefix="$2"
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
}

sync_managed_symlink() {
  local src="$1" dest="$2" log_prefix="$3"
  mkdir -p "$(dirname "$dest")"
  if ! _backup_managed_dest "$dest" "$log_prefix"; then
    return 1
  fi
  ln -sfn "$src" "$dest"
  echo "[$log_prefix] linked: $dest -> $src"
}
