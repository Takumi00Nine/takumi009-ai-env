#!/usr/bin/env bash
# scripts/lib/managed-symlink.sh
#
# install-main.sh の link() だけが呼ぶ「管理配置先のsymlink同期」を 1箇所に集約する
# （呼び手は install-main.sh の link() のみ。サブ機・update-sub.sh は
# install-sub.sh→install-main.sh 経由で同じ経路を通る。2026-09-14 導入・2026-09-19
# update-sub.sh は install-sub.sh へ委譲する形に一本化され本ファイルを直接呼ばない）。
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
# 退避規則（README「Setup」から 2026-09-19 に移設・原文）: Symlinked destinations
# (`link()` in `install-main.sh`, built on `scripts/lib/managed-symlink.sh` — sub machines go through the same path via `install-sub.sh`) move any existing real file to `<dest>.pre-aienv.bak` the first time before replacing it with a symlink; if the destination gets replaced again by a real file whose content differs from that existing backup (e.g. external edits between runs), it's preserved to a further non-colliding backup (`<dest>.pre-aienv.bak.<UTC timestamp>`) rather than being deleted, so the original pre-install backup is never overwritten and no version is silently lost.
# Generated/rewritten files instead (`codex/config.toml`, `claude/settings.json`, the local profile's `role.leader` line, etc.) keep the simpler "first run only" backup for a pre-existing real file that differs from what the generator produces — they're regenerated in place every run by design, so there's nothing further to reconcile once that first backup exists. Use `install-main.sh`'s `--dry-run` option to preview its plan only.
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
