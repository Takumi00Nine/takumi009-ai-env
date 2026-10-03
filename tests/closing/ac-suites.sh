# スイートを流す AC（AC-2 ③④・AC-5 ①・AC-7）。run-closing.sh が source する。
# shellcheck shell=bash

# cl_plain_path — 子スイート用の PATH＝ハーネスを起動した PATH から、claude・codex の実行体を含むディレクトリだけ除いたもの
#   （FX-6 の「claude・codex が PATH に無い」は保つ。偽 launchctl・osascript・cmux は置かない＝スイート自身の偽物が効く）
cl_plain_path() {
  local d out="" IFS=:
  for d in $PATH; do
    [ -n "$d" ] || continue
    { [ -x "$d/claude" ] || [ -x "$d/codex" ]; } && continue
    out="${out:+$out:}$d"
  done
  printf '%s' "$out"
}

# cl_run_suites <wt> <outdir> <suite...>（repo 相対）— 1 本ごとに新しい HOME（FX-3）で、素の環境から起動する
#   （cl_run の env -i・SKIP_LAUNCHCTL・LAUNCHCTL_TIMEOUT_SECS・偽 launchctl 等を継がない＝スイートの「enable 失敗は exit 1」等を
#   ハーネスの設定が握り潰さない。外から持ち込まれた SKIP_LAUNCHCTL・LAUNCHCTL_TIMEOUT_SECS も外す）。
# <outdir>/results.tsv（rc<TAB>スイート）と各ログを残し、非 0 の本数を CL_SUITES_FAILED に入れる。
cl_run_suites() {
  local wt="$1" od="$2" t rc n
  shift 2
  mkdir -p "$od"
  : > "$od/results.tsv"
  CL_SUITES_FAILED=0
  CL_SUITES_FAILED_NAMES=""
  for t in "$@"; do
    n="$(basename "$t" .sh)"
    rm -rf "$od/h" "$od/t"; mkdir -p "$od/h" "$od/t"
    rc=0
    # SIGINT・SIGQUIT は既定に戻してから起動する（nohup・& で起動されたハーネスでは無視が子へ継がれ、bash は入口で無視された
    # シグナルを戻せない＝SIGINT を前提にするスイートが落ちる。実測＝test-maintenance-run-step の 2 件）
    ( cd "$wt" && env -u SKIP_LAUNCHCTL -u LAUNCHCTL_TIMEOUT_SECS HOME="$od/h" TMPDIR="$od/t/" PATH="$(cl_plain_path)" \
        python3 -c 'import os,signal,sys; [signal.signal(x, signal.SIG_DFL) for x in (signal.SIGINT, signal.SIGQUIT)]; os.execvp("bash", ["bash", sys.argv[1]])' "$t" \
    ) </dev/null >"$od/$n.log" 2>&1 || rc=$?
    printf '%s\t%s\n' "$rc" "$t" >> "$od/results.tsv"
    if [ "$rc" -ne 0 ]; then
      CL_SUITES_FAILED=$((CL_SUITES_FAILED + 1))
      CL_SUITES_FAILED_NAMES="$CL_SUITES_FAILED_NAMES $n"
    fi
  done
  rm -rf "$od/h" "$od/t"
}

# README の一括テスト実行の対象（tests/test-*.sh）
cl_all_suites() { ( cd "$1" && ls tests/test-*.sh ); }

# 台帳の列（実装計画 §3＝種類 パス 機能 層 提供元 鍵 備考）からスイート行を「機能<TAB>パス」で出す
cl_ledger_suites() {
  awk -F'\t' -v k="$CLOSING_LEDGER_SUITE_KIND" '$0 !~ /^#/ && $1 == k { print $3 "\t" $2 }' "$1/$CLOSING_LEDGER_REL"
}

# ---------------------------------------------------------------- FX-10（AC-2）
# cl_mk_fx10 <wt> — FX-1 の worktree に偽 zz-cli の AI Brain 用接続フォルダと、台帳の行・移動表の新規行を足す
cl_mk_fx10() {
  local wt="$1" zz recall rel
  zz="$wt/$CLOSING_ZZ_DIR_REL"
  recall="$(cl_side_path new "$CLOSING_RECALL_OLD")" || { echo "想起の入口が移動表で引けない"; return 1; }
  [ -f "$wt/$CLOSING_LEDGER_REL" ] || { echo "台帳 $CLOSING_LEDGER_REL が無い"; return 1; }
  mkdir -p "$zz"
  cp "$CL_ZZ_FIX/connect/"* "$zz/"
  rel="$(python3 -c 'import os,sys;print(os.path.relpath(sys.argv[1],sys.argv[2]))' "$wt/$recall" "$zz")"
  sed "s#__RECALL_REL__#$rel#" "$CL_ZZ_FIX/connect/recall-shim.sh" > "$zz/recall-shim.sh"
  chmod +x "$zz/recall-shim.sh" "$zz/install.sh"
  printf '%s\t%s/\t%s\t%s\t%s\t-\t%s\n' "$CLOSING_LEDGER_PART_KIND" "$CLOSING_ZZ_DIR_REL" "$CLOSING_ZZ_FN" \
    "$CLOSING_ZZ_LAYER" "$CLOSING_ZZ_PROVIDER" "AC-2 試験の第 3 提供元（締めの実走が足す）" >> "$wt/$CLOSING_LEDGER_REL"
  # 移動表にも由来の行（FR-13＝新規の部品にも由来が要る・列＝旧パス 新パス 種別 転送印）
  [ -f "$wt/$CLOSING_MOVES_REL" ] || { echo "移動表 $CLOSING_MOVES_REL が無い"; return 1; }
  printf -- '-\t%s/\t新規\t-\n' "$CLOSING_ZZ_DIR_REL" >> "$wt/$CLOSING_MOVES_REL"
}

# AC-2 ③ FX-10 で一括テスト全スイート exit 0 ／ ④ zz-cli の配置手順＋偽 zz-cli に FX-17 → Knowledge/zz-probe.md
ac_2() {
  local od="$OUT/ac2" wt="$WORK/wt-fx10" why h s out rc3="NG" rc4="NG" m3 m4
  mkdir -p "$od"
  if ! cl_fx1_ready; then cl_result AC-2 NG "③④ $CL_FX1_WHY"; return; fi
  cl_new_wt "$wt" "$FX1_COMMIT" || { cl_result AC-2 NG "FX-10 の worktree を作れない"; return; }
  why="$(cl_mk_fx10 "$wt")" || { cl_result AC-2 NG "FX-10 を作れない: $why"; return; }
  # ③
  # shellcheck disable=SC2046
  cl_run_suites "$wt" "$od/suites" $(cl_all_suites "$wt")
  [ "$CL_SUITES_FAILED" -eq 0 ] && rc3="ok"
  m3="③ 非0 ${CL_SUITES_FAILED} 本${CL_SUITES_FAILED_NAMES:+（$CL_SUITES_FAILED_NAMES ）}"
  # ④
  h="$od/home"; s="$od/stub"; rm -rf "$h"; mkdir -p "$h"; cl_stubs "$s"
  cl_mk_vault_fx4 "$h/$CLOSING_VAULT_REL"
  mkdir -p "$od/zzbin"; cp "$CL_ZZ_FIX/zz-cli" "$od/zzbin/zz-cli"
  if cl_run "$h" "$s" "$wt" bash "$wt/$CLOSING_ZZ_DIR_REL/install.sh" </dev/null >"$od/zz-install.log" 2>&1; then
    rc=0
    out="$(cl_run "$h" "$s" "$wt" "$(cl_path "$s" "$od/zzbin")" zz-cli "$CL_PROBE_Q" </dev/null 2>"$od/zz-stderr.log")" || rc=$?
    printf '%s\n' "$out" > "$od/zz-stdout.log"
    if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF 'Knowledge/zz-probe.md'; then rc4="ok"; fi
    m4="④ exit ${rc}・zz-probe $(printf '%s' "$out" | grep -qF 'Knowledge/zz-probe.md' && echo あり || echo なし)"
  else
    m4="④ 配置手順が非 0（$od/zz-install.log）"
  fi
  if [ "$rc3" = ok ] && [ "$rc4" = ok ]; then cl_result AC-2 ok "$m3 / $m4"; else cl_result AC-2 NG "$m3 / $m4"; fi
}

# AC-5 ① FX-9a〜d（1 機能のフォルダ・そのスイート・台帳のその機能の行を除く）で残りの Core 以外のスイート全件 exit 0
ac_5() {
  local od="$OUT/ac5" fn wt letter=a list bad="" tot=0 failed=0 f p
  mkdir -p "$od"
  if ! cl_fx1_ready; then cl_result AC-5 NG "① $CL_FX1_WHY"; return; fi
  if [ ! -f "$WT1/$CLOSING_LEDGER_REL" ]; then cl_result AC-5 NG "① 台帳 $CLOSING_LEDGER_REL が無い"; return; fi
  for fn in $CLOSING_RM_FNS; do
    wt="$WORK/wt-fx9$letter"
    cl_new_wt "$wt" "$FX1_COMMIT" || { bad="$bad FX-9$letter(worktree)"; continue; }
    list=""
    while IFS="$(printf '\t')" read -r f p; do
      [ -n "$p" ] || continue
      if [ "$f" = "$fn" ]; then rm -f "$wt/$p"; continue; fi   # その機能のスイートを除く
      [ "$f" = "$CLOSING_CORE_FN" ] && continue
      list="$list $p"
    done <<EOF
$(cl_ledger_suites "$wt")
EOF
    rm -rf "${wt:?}/$fn"
    # 台帳からその機能の行（部品・スイート・Notify 所在）を除く（移動表は触らない）
    awk -F'\t' -v fn="$fn" -v k1="$CLOSING_LEDGER_PART_KIND" -v k2="$CLOSING_LEDGER_SUITE_KIND" -v k3="$CLOSING_LEDGER_NOTIFY_KIND" \
      '!($0 !~ /^#/ && ($1 == k1 || $1 == k2 || $1 == k3) && $3 == fn)' "$wt/$CLOSING_LEDGER_REL" > "$wt/$CLOSING_LEDGER_REL.tmp" \
      && mv "$wt/$CLOSING_LEDGER_REL.tmp" "$wt/$CLOSING_LEDGER_REL"
    # shellcheck disable=SC2086
    cl_run_suites "$wt" "$od/fx9$letter" $list
    tot=$((tot + $(printf '%s\n' $list | grep -c .)))
    if [ "$CL_SUITES_FAILED" -ne 0 ]; then
      failed=$((failed + CL_SUITES_FAILED)); bad="$bad FX-9$letter($fn):$CL_SUITES_FAILED_NAMES"
    fi
    letter="$(printf '%s' "$letter" | tr 'abc' 'bcd')"
  done
  if [ -z "$bad" ]; then cl_result AC-5 ok "① FX-9a〜d 計 $tot 本 全 exit 0"
  else cl_result AC-5 NG "① 非0 $failed 本／計 $tot 本:$bad"; fi
}

# AC-7 ① FX-1 で一括テスト実行 全 exit 0 ／ ② 基準..FX-1 の tests/ の差分一覧と差分統計を出す（分類は verifier）
ac_7() {
  local od="$OUT/ac7" wt="$WORK/wt-ac7" n
  mkdir -p "$od"
  git -C "$CL_SRC" diff --name-status "$BASE_COMMIT" "$FX1_COMMIT" -- tests/ > "$od/tests-diff-name-status.txt"
  git -C "$CL_SRC" diff --numstat "$BASE_COMMIT" "$FX1_COMMIT" -- tests/ > "$od/tests-diff-numstat.txt"
  git -C "$CL_SRC" diff "$BASE_COMMIT" "$FX1_COMMIT" -- tests/ > "$od/tests-diff.patch"
  n="$(grep -c . "$od/tests-diff-name-status.txt")"
  cl_new_wt "$wt" "$FX1_COMMIT" || { cl_result AC-7 NG "FX-1 の worktree を作れない"; return; }
  # shellcheck disable=SC2046
  cl_run_suites "$wt" "$od/suites" $(cl_all_suites "$wt")
  local tot; tot="$(grep -c . "$od/suites/results.tsv")"
  if ! cl_fx1_ready; then
    cl_result AC-7 NG "${CL_FX1_WHY}（参考: ① 非0 $CL_SUITES_FAILED 本／$tot 本${CL_SUITES_FAILED_NAMES:+:$CL_SUITES_FAILED_NAMES}）"
  elif [ "$CL_SUITES_FAILED" -eq 0 ]; then
    cl_result AC-7 ok "① $tot 本 全 exit 0 / ② tests/ の変更 $n ファイル（分類は verifier・ac7/tests-diff-*.txt）"
  else
    cl_result AC-7 NG "① 非0 $CL_SUITES_FAILED 本／$tot 本（$CL_SUITES_FAILED_NAMES ）/ ② tests/ の変更 $n ファイル（ac7/tests-diff-*.txt）"
  fi
}
