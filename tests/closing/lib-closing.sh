# 締めの実走ハーネスの共通部品（tests/closing/run-closing.sh が source する）。
# shellcheck shell=bash
#
# ■ 契約（実装と合わせる点。食い違えばハーネスでなく実装側か本ファイルの契約をリーダー判断で直す）
# 1. 移動表＝FX-1 の ${CLOSING_MOVES_REL}（既定 core/data/moves.tsv）。TSV・`#` 始まりと空行は読まない。
#    列＝①旧パス ②新パス ③種別（移動／分割／新規） ④転送印（空か `-` 以外＝旧パスに転送 symlink がある）。
#    新規の旧パスは `-`。末尾 `/` の行はフォルダ単位（配下のパスへ前方一致）。
#    主後継＝同じ旧パスを持つ行のうち**先頭行**（実装計画 §2 の並び＝主後継が先）。
# 2. 入口の引き方＝基準（FX-2）は基準での名前そのまま。FX-1 は移動表の主後継。
#    登録フック（FX-26 の SessionStart〜Agent）は各側の導入手順が生成した $HOME/.claude/settings.json から
#    イベント・マッチャーで引き、当たる全フックへ同じ stdin を与える。合併＝stdout を登録順に連結・
#    終了コードは最大値・FX-6 の記録と状態差分は和集合（設計 §10.4。SessionStart は旧ライブ名＝合成器 1 本が
#    元と同じ位置に登録されるので、連結しても文字列等値の比較になる）。
# 3. 導入手順（HOME＝FX-3 へ）＝README の手順を基準での名前で持ち、FX-1 側は各パスを移動表で引く:
#    メイン機＝mkdir 設定置き場 → cp profile.md.sample・models.conf.sample → install-main → LaunchAgent 系 3 本。
#    サブ機＝同じ cp（machine_role を sub に書き換え）→ install-sub。
#    repo は README の clone 先（$HOME/${CLOSING_REPO_HOME_REL}）に置く＝worktree への symlink（FX-15・16 は実 clone）。
#    定数は README の再実装なので、AC-8・AC-10 の冒頭で README（英日）の印の手順と突合する（cl_readme_check）。
# 4. 実行環境（FX-6）＝env -i で HOME・PATH・TMPDIR・LANG・git の名乗り・SKIP_LAUNCHCTL=1・LAUNCHCTL_TIMEOUT_SECS=1 だけ渡す。
#    PATH＝偽 launchctl・osascript・cmux（受けた引数を calls.log へ 1 行ずつ・exit 0）＋${CLOSING_BASE_PATH}。

CL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=closing.conf
. "$CL_DIR/closing.conf"
CL_PY="$CL_DIR/closing_util.py"
CL_RULES="$CL_DIR/normalize-rules.tsv"
CL_FIX="$CL_DIR/fixtures"
CL_ZZ_FIX="$CL_DIR/../fixtures/zz-cli"   # FX-10 の雛形（常設スイートと共有・使い方は同ディレクトリの README.md）
CL_PROBE_Q='想起プローブ甲 について'   # FX-17
CL_NEG_Q='今日の天気'                  # FX-18
CL_MUSTREAD_LINE='> 必読＝`~/Data/obsidian/Preferences/absolute-rules.md`（[[Preferences/absolute-rules]]）を着手前に全文読み、全項目を守る。'   # FX-26 Team の依頼文の 2 行目

CL_WTS=""        # 作った worktree（空白区切り）＝終了時に remove
CL_OK=0
CL_NG=0

cl_py() { python3 "$CL_PY" "$@"; }
cl_realpath() { python3 "$CL_PY" realpath "$1"; }

# AC の結果 1 行（契約＝`AC-n <ok|NG> <要点>`）
cl_result() {
  local id="$1" st="$2"; shift 2
  if [ "$st" = "ok" ]; then CL_OK=$((CL_OK + 1)); else CL_NG=$((CL_NG + 1)); st="NG"; fi
  printf '%s %s %s\n' "$id" "$st" "$*"
}

cl_note() { printf '%s\n' "$*" >> "$OUT/detail.log"; }

# ---------------------------------------------------------------- worktree
cl_new_wt() {  # cl_new_wt <dir> <commit>
  git -C "$CL_SRC" worktree add -q --detach "$1" "$2" >>"$OUT/detail.log" 2>&1 || return 1
  CL_WTS="$CL_WTS $1"
}

cl_cleanup() {
  local w
  for w in $CL_WTS; do
    chmod -R u+w "$w" 2>/dev/null
    git -C "$CL_SRC" worktree remove --force "$w" >/dev/null 2>&1 || true
  done
  git -C "$CL_SRC" worktree prune >/dev/null 2>&1 || true
  [ -n "${WORK:-}" ] && { chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"; }
}

# FX-1 側の入口が引けるか（移動表の有無）。引けなければ理由を CL_FX1_WHY に入れて 1。
cl_fx1_ready() {
  CL_FX1_WHY=""
  if [ "$FX1_COMMIT" = "$BASE_COMMIT" ]; then
    CL_FX1_WHY="FX-1 が基準と同じコミット（v1.1 未適用）・FX-1 側の入口が引けない"
    return 1
  fi
  if [ ! -f "$WT1/$CLOSING_MOVES_REL" ]; then
    CL_FX1_WHY="FX-1 側の入口が引けない（移動表 $CLOSING_MOVES_REL が無い）"
    return 1
  fi
  return 0
}

# cl_side_path <base|new> <基準での repo 相対パス> → その側の repo 相対パス
cl_side_path() {
  if [ "$1" = "base" ]; then printf '%s\n' "$2"; return 0; fi
  cl_py moves-main "$WT1/$CLOSING_MOVES_REL" "$2"
}

# ---------------------------------------------------------------- FX-6・実行環境
cl_stubs() {  # cl_stubs <dir> → <dir>/bin に偽 3 本・記録＝<dir>/calls.log
  local d="$1" c
  mkdir -p "$d/bin" "$d/tmp"
  : > "$d/calls.log"
  for c in launchctl osascript cmux; do
    printf '#!/bin/bash\nprintf "%%s\\n" "%s $*" >> "%s/calls.log"\nexit 0\n' "$c" "$d" > "$d/bin/$c"
    chmod +x "$d/bin/$c"
  done
}

# cl_run <home> <stubdir> <cwd> [VAR=val ...] cmd args... （stdin はそのまま渡る）
cl_run() {
  local h="$1" s="$2" cwd="$3"; shift 3
  ( cd "$cwd" && env -i HOME="$h" PATH="$s/bin:$CLOSING_BASE_PATH" TMPDIR="$s/tmp/" \
      LANG="$CLOSING_LANG" USER="$(id -un)" LOGNAME="$(id -un)" SHELL=/bin/bash \
      SKIP_LAUNCHCTL=1 LAUNCHCTL_TIMEOUT_SECS=1 \
      GIT_AUTHOR_NAME="$CLOSING_GIT_NAME" GIT_AUTHOR_EMAIL="$CLOSING_GIT_EMAIL" \
      GIT_COMMITTER_NAME="$CLOSING_GIT_NAME" GIT_COMMITTER_EMAIL="$CLOSING_GIT_EMAIL" \
      "$@" )
}

# PATH を前置きして使う形（cl_run の引数に置く）: "$(cl_path <stubdir> <dir>...)"
cl_path() {
  local s="$1" p=""; shift
  local d; for d in "$@"; do p="$p$d:"; done
  printf 'PATH=%s%s/bin:%s' "$p" "$s" "$CLOSING_BASE_PATH"
}

# 起動時の環境検査（FX-6 の前提＝claude・codex が無く、道具が揃う）
cl_check_env() {
  local miss="" c
  for c in claude codex; do
    if PATH="$CLOSING_BASE_PATH" command -v "$c" >/dev/null 2>&1; then miss="$miss $c が PATH にある;"; fi
  done
  for c in git jq python3 rsync plutil; do
    PATH="$CLOSING_BASE_PATH" command -v "$c" >/dev/null 2>&1 || miss="$miss $c が無い;"
  done
  [ -z "$miss" ] && return 0
  printf '%s\n' "$miss"; return 1
}

# ---------------------------------------------------------------- Vault（FX-4・FX-5）
cl_mk_vault_fx4() {  # cl_mk_vault_fx4 <dest>（中身は基準の vault-public＝両側で同じ入力）
  mkdir -p "$(dirname "$1")"
  cp -R "$WT0/vault-public" "$1"
  cat > "$1/Knowledge/zz-probe.md" <<'EOF'
---
aliases: ["想起プローブ甲"]
---
想起プローブ甲の本文（締めの実走用の 1 行）。
EOF
}

cl_mk_vault_fx5() {  # FX-4＋git（初期コミット 1・remote 無し・未コミットの変更 1 件）
  cl_mk_vault_fx4 "$1"
  ( cd "$1" && git init -q -b main && git add -A \
    && GIT_AUTHOR_NAME="$CLOSING_GIT_NAME" GIT_AUTHOR_EMAIL="$CLOSING_GIT_EMAIL" \
       GIT_COMMITTER_NAME="$CLOSING_GIT_NAME" GIT_COMMITTER_EMAIL="$CLOSING_GIT_EMAIL" \
       git commit -q -m "FX-5 初期コミット" ) || return 1
  printf '未コミットの変更 1 件（FX-5）。\n' >> "$1/Knowledge/zz-probe.md"
}

# ---------------------------------------------------------------- 導入手順（契約 3）
# cl_install_main <side> <home> <repo> <stubdir> <log> — README のメイン機手順。repo＝$HOME/<clone 先>（実体か symlink）
cl_install_main() {
  local side="$1" h="$2" repo="$3" s="$4" log="$5" p cfg rc=0 x
  cfg="$h/$CLOSING_CONFIG_DIR_REL"
  mkdir -p "$cfg"
  p="$(cl_side_path "$side" "$CLOSING_PROFILE_SAMPLE_OLD")" && cp "$repo/$p" "$cfg/profile.md" || { echo "引けない: $CLOSING_PROFILE_SAMPLE_OLD" >>"$log"; return 1; }
  p="$(cl_side_path "$side" "$CLOSING_MODELS_SAMPLE_OLD")" && cp "$repo/$p" "$cfg/models.conf" || { echo "引けない: $CLOSING_MODELS_SAMPLE_OLD" >>"$log"; return 1; }
  for x in $CLOSING_INSTALL_MAIN_OLD $CLOSING_INSTALL_LA_OLD; do
    p="$(cl_side_path "$side" "$x")" || { echo "引けない: $x" >>"$log"; return 1; }
    echo "--- $p" >>"$log"
    cl_run "$h" "$s" "$repo" "$repo/$p" </dev/null >>"$log" 2>&1 || { rc=$?; echo "rc=$rc: $p" >>"$log"; return "$rc"; }
  done
  return 0
}

# cl_install_sub <side> <home> <repo> <stubdir> <log> — README のサブ機手順（machine_role を sub に）
cl_install_sub() {
  local side="$1" h="$2" repo="$3" s="$4" log="$5" p cfg rc=0
  cfg="$h/$CLOSING_CONFIG_DIR_REL"
  mkdir -p "$cfg"
  p="$(cl_side_path "$side" "$CLOSING_PROFILE_SAMPLE_OLD")" || return 1
  sed -E 's/^(machine_role:[[:space:]]*configured value=)[a-z]+/\1sub/' "$repo/$p" > "$cfg/profile.md"
  grep -q '^machine_role:.*value=sub' "$cfg/profile.md" || { echo "machine_role を sub にできない" >>"$log"; return 1; }
  p="$(cl_side_path "$side" "$CLOSING_MODELS_SAMPLE_OLD")" && cp "$repo/$p" "$cfg/models.conf" || return 1
  p="$(cl_side_path "$side" "$CLOSING_INSTALL_SUB_OLD")" || return 1
  echo "--- $p" >>"$log"
  cl_run "$h" "$s" "$repo" "$repo/$p" </dev/null >>"$log" 2>&1 || { rc=$?; echo "rc=$rc: $p" >>"$log"; return "$rc"; }
}

# ---------------------------------------------------------------- README との照合（C-2）
# cl_proc_cmds <side> <main|sub|import> — ハーネスが実行する手順を README のコマンド行の形で出す（各パスはその側の名前）
cl_proc_cmds() {
  local side="$1" x p list=""
  case "$2" in
    main)   list="cp:$CLOSING_PROFILE_SAMPLE_OLD cp:$CLOSING_MODELS_SAMPLE_OLD $CLOSING_INSTALL_MAIN_OLD $CLOSING_INSTALL_LA_OLD" ;;
    sub)    list="cp:$CLOSING_PROFILE_SAMPLE_OLD cp:$CLOSING_MODELS_SAMPLE_OLD $CLOSING_INSTALL_SUB_OLD" ;;
    import) printf '%s\n' "$CLOSING_IMPORT_PULL"; list="$CLOSING_INSTALL_MAIN_OLD $CLOSING_INSTALL_LA_OLD $CLOSING_CHECK_DRIFT_OLD" ;;
  esac
  for x in $list; do
    p="$(cl_side_path "$side" "${x#cp:}")" || p="<引けない:${x#cp:}>"
    case "$x" in cp:*) printf 'cp %s\n' "$p" ;; *) printf '%s\n' "$p" ;; esac
  done
}

# cl_readme_check <side> <main|sub|import> <README> — 英日の印の手順と定数を突合。一致で 0、不一致は差分 1 行を出して 1
cl_readme_check() {
  local side="$1" proc="$2" readme="$3" marks m got exp a x first
  case "$proc" in main) marks="$CLOSING_README_MARK_MAIN" ;; sub) marks="$CLOSING_README_MARK_SUB" ;; *) marks="$CLOSING_README_MARK_IMPORT" ;; esac
  a=()
  for x in $CLOSING_README_SKIP_LINE_ARGS; do a+=(--skip-line-arg "$x"); done
  for x in $CLOSING_README_DROP_ARGS; do a+=(--drop-arg "$x"); done
  exp="$(cl_proc_cmds "$side" "$proc")"
  while [ -n "$marks" ]; do
    m="${marks%%|*}"; [ "$m" = "$marks" ] && marks="" || marks="${marks#*|}"
    if ! got="$(cl_py readme-cmds "$readme" "$m" "${a[@]}")"; then
      echo "印が無い（${m}・$(basename "$readme")）"; return 1
    fi
    if [ "$got" != "$exp" ]; then
      first="$(diff <(printf '%s\n' "$exp") <(printf '%s\n' "$got") | grep '^[<>]' | head -2 | tr '\n' ' ')"
      echo "${m}: ${first}（< 定数・> README）"; return 1
    fi
  done
  return 0
}

# HOME を新しく作り、clone 先に worktree への symlink を置いてメイン機手順を実行する
cl_fresh_main_home() {  # <side> <home> <wt> <stubdir> <log>
  rm -rf "$2"; mkdir -p "$2/$(dirname "$CLOSING_REPO_HOME_REL")"
  ln -s "$3" "$2/$CLOSING_REPO_HOME_REL"
  cl_install_main "$1" "$2" "$2/$CLOSING_REPO_HOME_REL" "$4" "$5"
}

# ---------------------------------------------------------------- 検査の部品
# settings.json に登録された全フックのコマンドが実在して実行可能か。欠けを 1 行ずつ出し、欠けがあれば 1。
cl_hooks_exist() {  # <home> <settings.json>
  local h="$1" f="$2" c path bad=0
  [ -f "$f" ] || { echo "settings.json が無い: $f"; return 1; }
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    path="${c%% *}"; path="${path//\$HOME/$h}"; path="${path/#\~/$h}"
    if [ ! -e "$path" ]; then echo "不在: $c"; bad=1
    elif [ ! -x "$path" ]; then echo "実行不可: $c"; bad=1; fi
  done <<EOF
$(cl_py hook-cmds "$f")
EOF
  return "$bad"
}

# 配下のリンク切れ（最後まで辿った先が無い）を 1 行ずつ出し、あれば 1。
cl_dangling() {  # <dir>...
  local d l bad=0
  for d in "$@"; do
    [ -d "$d" ] || continue
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      [ -e "$l" ] || { echo "リンク切れ: $l -> $(readlink "$l")"; bad=1; }
    done <<EOF
$(find "$d" -type l 2>/dev/null)
EOF
  done
  return "$bad"
}

# 正規化（比較から除く値）。<side> が base のときだけ旧パス→新パスの置換をする。
cl_norm() {  # cl_norm <side> <run_dir> < in > out
  local side="$1" rd="$2" a=()
  local sub
  for sub in "${CL_SUBS[@]}"; do a+=(--sub "$sub"); done
  a+=(--sub "$rd/tmp=<TMP>" --sub "$(cl_realpath "$rd")/tmp=<TMP>" --sub "$rd=<RUN>" --sub "$(cl_realpath "$rd")=<RUN>")
  if [ "$side" = "base" ]; then
    a+=(--sub "$WT0=<WT>" --sub "$(cl_realpath "$WT0")=<WT>")
    [ -f "$WT1/$CLOSING_MOVES_REL" ] && a+=(--moves "$WT1/$CLOSING_MOVES_REL")
    for sub in $CLOSING_BASE_MOVES_EXTRA; do a+=(--extra-move "$sub"); done
  else
    a+=(--sub "$WT1=<WT>" --sub "$(cl_realpath "$WT1")=<WT>")
  fi
  [ -n "${CL_SIDE_WT:-}" ] && a+=(--sub "$CL_SIDE_WT=<WT>" --sub "$(cl_realpath "$CL_SIDE_WT")=<WT>")
  a+=(--repo-dirname "$(basename "$CLOSING_REPO_HOME_REL")")
  cl_py norm "$CL_RULES" "${a[@]}"
}
