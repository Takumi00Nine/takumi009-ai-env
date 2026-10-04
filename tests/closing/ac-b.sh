# v1.2 束 B の締め AC（AC-2・AC-3④・AC-4①・AC-5①・AC-7①②④・AC-12①②）。
# run-closing-b.sh が lib-closing.sh・ac-suites.sh・ac-12.sh・ac-live.sh の後に source する。
# 同名の関数（ac_2・ac_5・ac_7・ac_12）は束 B の定義で上書きする（v1.1 の定義は run-closing.sh 側に残す＝
# 束 C の test-writer が AC-8〜11 を同じ形で拡張するときの参考に残す）。
#
# 前提＝ac-12.sh に v1.2 FX-9 (a)(b) 用の入力 id を 2 つ足した（fx9-maint・fx9-usage）。
# shellcheck shell=bash

# ---------------------------------------------------------------- FX-9 (c)(d)（ac12_run の単発モデルに乗らない複合入力）
# clb_fx9_ups <side> → $OUT/ac2/fx9-ups/<side>.{c1,c2}.{rc,calls}（偽 CODE27 消去の記録＝1 件目だけ増える）
clb_fx9_ups() {
  local side="$1" wt h s od="$OUT/ac2/fx9-ups" commit rc=0
  wt="$WORK/wtb-$side"; h="$WORK/home-fx9ups"; s="$WORK/s-fx9ups-$side"
  mkdir -p "$od"
  [ "$side" = base ] && commit="$BASE_COMMIT" || commit="$FX1_COMMIT"
  rm -rf "$wt"; cl_new_wt "$wt" "$commit" || return 1
  rm -rf "$h" "$s"; mkdir -p "$s/c27/bin"
  cp -R "$CL_DIR/../fixtures/code27-call/bin/." "$s/c27/bin/"
  cl_stubs "$s"
  cl_fresh_main_home "$side" "$h" "$wt" "$s" "$od/$side-install.log" || { echo "install失敗" > "$od/$side.err"; return 1; }
  : > "$s/c27/calls.log"
  printf '{"session_id":"s1","prompt":"%s"}' "$CLOSING_FX9_UPS_POS" \
    | cl_run "$h" "$s" "$wt" CODE27_CALL_BIN="$s/c27/bin/code27-call-clear" \
      "$h/.claude/hooks/code27-call-clear.sh" >"$od/$side.c1.stdout" 2>"$od/$side.c1.stderr" || rc=$?
  printf '%s\n' "$rc" > "$od/$side.c1.rc"
  # 口は応答を切り離して起動する（設計 R2-01）＝入口の終了は配送の完了を意味しない。記録が現れるまで
  # T+1 秒待ってから写す（基準側は同期なので実質即・新側は非同期の配送を待つ）。
  cl_wait_lines "$s/c27/calls.log" 1
  cp "$s/c27/calls.log" "$od/$side.c1.calls"
  rc=0
  printf '{"session_id":"s1","prompt":"%s"}' "$CLOSING_FX9_UPS_EXCLUDED" \
    | cl_run "$h" "$s" "$wt" CODE27_CALL_BIN="$s/c27/bin/code27-call-clear" \
      "$h/.claude/hooks/code27-call-clear.sh" >"$od/$side.c2.stdout" 2>"$od/$side.c2.stderr" || rc=$?
  printf '%s\n' "$rc" > "$od/$side.c2.rc"
  # 除外入力＝増えないことを確かめる側。上限まで待って「それでも増えていない」ことを写す。
  cl_wait_lines "$s/c27/calls.log" 2
  cp "$s/c27/calls.log" "$od/$side.c2.calls"
}

# clb_fx9_announce <side> → $OUT/ac2/fx9-announce/<side>.{rc,cmux.calls,code27.calls}
#   基準側＝`cmux notify` を直接。新側＝口（notify.sh call ask）経由（要件 v1.2 FX-9 (d) の定義どおり）。
clb_fx9_announce() {
  local side="$1" wt h s od="$OUT/ac2/fx9-announce" commit rc=0 e
  wt="$WORK/wtb-ann-$side"; h="$WORK/home-ann-$side"; s="$WORK/s-ann-$side"
  mkdir -p "$od"
  [ "$side" = base ] && commit="$BASE_COMMIT" || commit="$FX1_COMMIT"
  rm -rf "$wt"; cl_new_wt "$wt" "$commit" || return 1
  rm -rf "$h" "$s"; mkdir -p "$h" "$s/c27/bin"
  cp -R "$CL_DIR/../fixtures/code27-call/bin/." "$s/c27/bin/"
  cl_stubs "$s"
  if [ "$side" = base ]; then
    cl_run "$h" "$s" "$wt" cmux notify --title "$CLOSING_FX9_ANNOUNCE_TITLE" --body "$CLOSING_FX9_ANNOUNCE_BODY" \
      >"$od/$side.stdout" 2>"$od/$side.stderr" || rc=$?
  else
    e="$(cl_side_path new "$CLOSING_NOTIFY_SH_REL")" || { printf '入口が引けない: %s\n' "$CLOSING_NOTIFY_SH_REL" > "$od/$side.err"; rc=127; }
    if [ -n "${e:-}" ]; then
      cl_run "$h" "$s" "$wt" CODE27_CALL_BIN="$s/c27/bin/code27-call-clear" \
        "$wt/$e" call ask "$CLOSING_FX9_ANNOUNCE_TITLE" "$CLOSING_FX9_ANNOUNCE_BODY" \
        >"$od/$side.stdout" 2>"$od/$side.stderr" || rc=$?
    fi
  fi
  printf '%s\n' "$rc" > "$od/$side.rc"
  cp "$s/calls.log" "$od/$side.cmux.calls" 2>/dev/null || : > "$od/$side.cmux.calls"
  cp "$s/c27/calls.log" "$od/$side.code27.calls" 2>/dev/null || : > "$od/$side.code27.calls"
}

# ---------------------------------------------------------------- AC-2 働き不変
ac_2() {
  local od="$OUT/ac2" n=0 same=0 differ="" id m2="" bad_extra=""
  mkdir -p "$od"
  if ! cl_fx1_ready; then cl_result AC-2 NG "① $CL_FX1_WHY"; return; fi

  # ① v1.1 AC-12 の FX-26 全入力 ＋ v1.2 FX-9 (a)(b)（fx9-maint・fx9-usage＝ac-12.sh へ足した入力 id）
  if ! ac12_prep base; then cl_result AC-2 NG "① 基準側の導入手順が失敗（ac12/install-base.log）"; return; fi
  if ! ac12_prep new; then cl_result AC-2 NG "① FX-1 側の導入手順が失敗（ac12/install-new.log）"; return; fi
  for id in $CL_AC12_INPUTS fx9-maint fx9-usage; do
    n=$((n + 1))
    CL_AC12_OD="$od" ac12_run base "$id"
    CL_AC12_OD="$od" ac12_run new "$id"
    if CL_AC12_OD="$od" ac12_same "$id"; then same=$((same + 1)); else differ="$differ $id"; fi
  done

  # ① FX-9 (c)（同じ入口へ 2 件・CODE27 消去の記録は 1 件目だけ）
  clb_fx9_ups base; clb_fx9_ups new
  local ups_bad="" side c1 c2
  for side in base new; do
    c1="$({ [ -f "$od/fx9-ups/$side.c1.calls" ] && grep -c . "$od/fx9-ups/$side.c1.calls" 2>/dev/null; } || true)"
    c2="$({ [ -f "$od/fx9-ups/$side.c2.calls" ] && grep -c . "$od/fx9-ups/$side.c2.calls" 2>/dev/null; } || true)"
    [ "$c1" = 1 ] && [ "$c2" = 1 ] || ups_bad="$ups_bad $side(1件目=$c1,2件目=$c2)"
  done

  # ① FX-9 (d)（偽 cmux 1 件・題が 📣 で始まる／偽 CODE27 発話 0 件、両側）
  clb_fx9_announce base; clb_fx9_announce new
  local ann_bad=""
  for side in base new; do
    local cmux_n title_ok say_n
    cmux_n="$({ [ -f "$od/fx9-announce/$side.cmux.calls" ] && grep -c . "$od/fx9-announce/$side.cmux.calls" 2>/dev/null; } || true)"
    title_ok="$(grep -qF -- "--title $CLOSING_FX9_ANNOUNCE_TITLE" "$od/fx9-announce/$side.cmux.calls" 2>/dev/null && echo 1 || echo 0)"
    say_n="$({ [ -f "$od/fx9-announce/$side.code27.calls" ] && grep -c . "$od/fx9-announce/$side.code27.calls" 2>/dev/null; } || true)"
    { [ "$cmux_n" = 1 ] && [ "$title_ok" = 1 ] && [ "$say_n" = 0 ]; } || ann_bad="$ann_bad $side(cmux=$cmux_n,題=$title_ok,発話=$say_n)"
  done

  # ② v1.1 AC-8 の比較（FX-3 に FX-2・FX-1 それぞれの導入手順を実行＝ac8_side は締め層 ac-live.sh の既存機）。
  #    許容差分＝口のための 1 名以内（v1.2 は口をライブ位置に置かない設計＝期待は 0 だが要件の上限どおり 1 まで許容）。
  local e1="" e2="" e3="" e4="" extra_n=0
  if ! ac8_side base "$WT0"; then cl_result AC-2 NG "② 基準側の導入手順が失敗（ac8/base/install.log）"; return; fi
  if ! ac8_side new "$WT1"; then cl_result AC-2 NG "② FX-1 側の導入手順が失敗（ac8/new/install.log）"; return; fi
  while IFS="$(printf '\t')" read -r nm k t; do
    [ -n "$nm" ] && [ "$k" != "-" ] || continue
    awk -F'\t' -v n="$nm" '$1==n && $2!="-"{f=1} END{exit !f}' "$OUT/ac8/new/live.tsv" && continue
    extra_n=$((extra_n + 1))
  done < "$OUT/ac8/base/live.tsv"
  while IFS="$(printf '\t')" read -r nm k t; do
    [ -n "$nm" ] && [ "$k" != "-" ] || continue
    awk -F'\t' -v n="$nm" '$1==n && $2!="-"{f=1} END{exit !f}' "$OUT/ac8/base/live.tsv" && continue
    extra_n=$((extra_n + 1))
  done < "$OUT/ac8/new/live.tsv"
  e2="$(grep -c 'MISSING:' "$OUT/ac8/new/live.tsv")"
  if [ "$extra_n" -gt 1 ]; then e1="FX-1 にだけある名前・登録 ${extra_n} 件（1 名以内のはず）"; fi
  [ "$e2" = 0 ] || e1="${e1:+$e1 / }リンク切れ $e2"

  if [ -z "$differ" ] && [ -z "$ups_bad" ] && [ -z "$ann_bad" ] && [ -z "$e1" ]; then
    cl_result AC-2 ok "① $same/$n 入力で一致・FX-9(c)(d) 形が合う ② 名前・登録の差分 ${extra_n} 件（1 以内）"
  else
    cl_result AC-2 NG "①一致 $same/${n}（不一致:${differ:- なし}）・FX-9(c):${ups_bad:- ok}・FX-9(d):${ann_bad:- ok} ②${e1:- ok}（ac2/）"
  fi
}

# ---------------------------------------------------------------- FX-10 RMN／FX-11 ZZD（共有ビルダー）
# cl_mk_fx10_rmn <wt>｜FX-1 から Notify を除く（機能フォルダ・スイート・台帳の Notify の行・移動表で Notify を
# 新側とする行・Notify を指す転送を除く＝v1.1 FX-9 の作り方に移動表と転送を足したもの＝検証 1 巡目 V-01 の反映）。
cl_mk_fx10_rmn() {
  local wt="$1" fn="$CLOSING_NOTIFY_FN" f p old newp mark
  [ -f "$wt/$CLOSING_LEDGER_REL" ] || { echo "台帳が無い"; return 1; }
  [ -f "$wt/$CLOSING_MOVES_REL" ] || { echo "移動表が無い"; return 1; }
  # git rm で消す（ledger-tool.sh の存在チェックは git ls-files を見るため・単なる rm だと
  # 索引に残って「台帳の行が 0 件」の誤検知になる＝実測）。
  while IFS="$(printf '\t')" read -r f p; do
    [ "$f" = "$fn" ] && [ -n "$p" ] && git -C "$wt" rm -q -f --ignore-unmatch -- "$p" >/dev/null
  done <<EOF
$(cl_ledger_suites "$wt")
EOF
  while IFS="$(printf '\t')" read -r old newp _kind mark; do
    [ -n "$old" ] && [ "$old" != "-" ] || continue
    case "$newp" in "$fn"/*) [ -n "$mark" ] && [ "$mark" != "-" ] && git -C "$wt" rm -q -f --ignore-unmatch -- "$old" >/dev/null ;; esac
  done < <(awk -F'\t' '$0 !~ /^#/ && NF>=4' "$wt/$CLOSING_MOVES_REL")
  [ -d "$wt/$fn" ] && git -C "$wt" rm -q -rf --ignore-unmatch -- "$fn" >/dev/null
  rm -rf "${wt:?}/$fn"
  awk -F'\t' -v fn="$fn" -v k1="$CLOSING_LEDGER_PART_KIND" -v k2="$CLOSING_LEDGER_SUITE_KIND" -v k3="$CLOSING_LEDGER_NOTIFY_KIND" \
    '!($0 !~ /^#/ && ($1==k1||$1==k2||$1==k3) && $3==fn)' "$wt/$CLOSING_LEDGER_REL" > "$wt/$CLOSING_LEDGER_REL.tmp" \
    && mv "$wt/$CLOSING_LEDGER_REL.tmp" "$wt/$CLOSING_LEDGER_REL"
  awk -F'\t' -v fn="$fn" '$0 ~ /^#/ || index($2, fn "/") != 1' "$wt/$CLOSING_MOVES_REL" > "$wt/$CLOSING_MOVES_REL.tmp" \
    && mv "$wt/$CLOSING_MOVES_REL.tmp" "$wt/$CLOSING_MOVES_REL"
}

# cl_mk_fx11_zzd <wt>｜第 4 の届け先 zz-dest（共有雛形 tests/fixtures/zz-dest/）＋台帳の行（移動表は変えない＝FR-20）。
cl_mk_fx11_zzd() {
  local wt="$1" dest
  dest="$wt/$CLOSING_ZZD_DIR_REL"
  [ -f "$wt/$CLOSING_LEDGER_REL" ] || { echo "台帳が無い"; return 1; }
  mkdir -p "$dest"
  cp "$CL_DIR/../../$CLOSING_ZZD_FIX_REL/connect/deliver.sh" "$dest/deliver.sh"
  chmod +x "$dest/deliver.sh"
  # VB-02（verify-impl-r1）＝知らせを持つ行は実行可能ファイル＝ディレクトリでなく deliver.sh そのものを指す
  # （常設 fixture tests/test-notify.sh:169-172 と同じ字面）。
  printf 'part\t%s/deliver.sh\t%s\tconnect\t%s\t-\t%s\tcall\n' \
    "$CLOSING_ZZD_DIR_REL" "$CLOSING_NOTIFY_FN" "$CLOSING_ZZD_PROVIDER" \
    "AC-3 試験の第 4 届け先（締めの実走が足す・移動表は変えない）" >> "$wt/$CLOSING_LEDGER_REL"
}

# ---------------------------------------------------------------- AC-3 届け先の追加（④ だけ＝①②③ は常設）
ac_3() {
  local od="$OUT/ac3" wt="$WORK/wt-fx11-b" why
  mkdir -p "$od"
  if ! cl_fx1_ready; then cl_result AC-3 NG "④ $CL_FX1_WHY"; return; fi
  cl_new_wt "$wt" "$FX1_COMMIT" || { cl_result AC-3 NG "FX-11 の worktree を作れない"; return; }
  why="$(cl_mk_fx11_zzd "$wt")" || { cl_result AC-3 NG "FX-11 を作れない: $why"; return; }
  local rc=0
  cl_run_all "$wt" "$od/run-all" || rc=$?
  if [ "$rc" -eq 0 ]; then cl_result AC-3 ok "④ FX-11 で一括実行 exit 0（red>0 なし・ac3/run-all/）"
  else cl_result AC-3 NG "④ FX-11 で一括実行 exit=${rc}（ac3/run-all/run-all.log）"; fi
}

# ---------------------------------------------------------------- AC-4 無いとき（① だけ＝②③④ は常設）
# VB-04-R2＝状態（メンテの last-run.json 等）・取得結果（Usage のキャッシュ・通知状態 JSON）は
# 個別フィールドでなく $HOME 全体の前後スナップショット差分（AC-2/ac12_run と同じ snap＋snapdiff＋cl_norm）
# で比較する（取りこぼしの温床にしない）。FX-1・FX-10 とも $HOME は同名（$WORK/home-ac4）を使い回すことで、
# home 名そのものの違いが差分に紛れ込まないようにする（repo の実パスは cl_norm の CL_SIDE_WT で正規化）。
ac_4() {
  local od="$OUT/ac4" wt10="$WORK/wt-fx10-ac4" bad=""
  mkdir -p "$od"
  if ! cl_fx1_ready; then cl_result AC-4 NG "① $CL_FX1_WHY"; return; fi
  cl_new_wt "$wt10" "$FX1_COMMIT" || { cl_result AC-4 NG "① FX-10 の worktree を作れない"; return; }
  local why; why="$(cl_mk_fx10_rmn "$wt10")" || { cl_result AC-4 NG "① FX-10 を作れない: $why"; return; }

  local h s e rc
  # --- FX-1（Notify あり）側の基準出力
  h="$WORK/home-ac4"; s="$WORK/s-ac4-fx1"; rm -rf "$h" "$s"; mkdir -p "$h"; cl_stubs "$s"
  cl_fresh_main_home new "$h" "$WT1" "$s" "$od/fx1-install.log" || { cl_result AC-4 NG "① FX-1 の導入が失敗（ac4/fx1-install.log）"; return; }
  cl_mk_vault_fx5 "$h/$CLOSING_VAULT_REL"; git -C "$h/$CLOSING_VAULT_REL" checkout -q -b other-branch
  e="$(cl_side_path new "$CLOSING_MAINT_OLD")" || e=""
  cl_py snap "$h" "$od/fx1-maint-before.json" --exclude Library/Caches/
  rc=0; [ -n "$e" ] && { cl_run "$h" "$s" "$WT1" AIENV_REPO="$WT1" "$WT1/$e" </dev/null >"$od/fx1-maint.stdout" 2>"$od/fx1-maint.stderr" || rc=$?; }
  printf '%s\n' "$rc" > "$od/fx1-maint.rc"
  cl_py snap "$h" "$od/fx1-maint-after.json" --exclude Library/Caches/
  cl_py snapdiff "$od/fx1-maint-before.json" "$od/fx1-maint-after.json" "$h" > "$od/fx1-maint.state"
  CL_SIDE_WT="$WT1" cl_norm new "$s" < "$od/fx1-maint.state" > "$od/fx1-maint.state.n"
  local fx1_osascript_maint; fx1_osascript_maint="$(grep -c '異常終了' "$s/calls.log" 2>/dev/null || true)"
  e="$(cl_side_path new "$CLOSING_USAGE_FETCH_OLD")" || e=""
  : > "$s/calls.log"
  cl_py snap "$h" "$od/fx1-usage-before.json" --exclude Library/Caches/
  rc=0; [ -n "$e" ] && { cl_run "$h" "$s" "$WT1" "$(cl_path "$s" "$CL_FIX/usage-bin")" \
    STUB_CURL_STATUS=200 STUB_CURL_BODY="$CLOSING_USAGE_WARN_BODY" \
    STUB_SECURITY_JSON='{"claudeAiOauth":{"accessToken":"tok-abc","expiresAt":99999999999999}}' \
    STUB_CODEX_RESULT_LINE="$(cat "$CL_FIX/usage-bin/codex_success_result_line.json")" \
    "$WT1/$e" </dev/null >"$od/fx1-usage.stdout" 2>"$od/fx1-usage.stderr" || rc=$?; }
  printf '%s\n' "$rc" > "$od/fx1-usage.rc"
  cl_py snap "$h" "$od/fx1-usage-after.json" --exclude Library/Caches/
  cl_py snapdiff "$od/fx1-usage-before.json" "$od/fx1-usage-after.json" "$h" > "$od/fx1-usage.state"
  CL_SIDE_WT="$WT1" cl_norm new "$s" < "$od/fx1-usage.state" > "$od/fx1-usage.state.n"
  local fx1_osascript_usage; fx1_osascript_usage="$(grep -c '警告' "$s/calls.log" 2>/dev/null || true)"

  # --- FX-10（Notify を除いた）側（$h は FX-1 側と同名を使い回す＝上で rm -rf 済みの前提）
  h="$WORK/home-ac4"; s="$WORK/s-ac4-fx10"; rm -rf "$h" "$s"; mkdir -p "$h"; cl_stubs "$s"
  cl_fresh_main_home new "$h" "$wt10" "$s" "$od/fx10-install.log" || { cl_result AC-4 NG "① FX-10 の導入が失敗（ac4/fx10-install.log）"; return; }
  cl_mk_vault_fx5 "$h/$CLOSING_VAULT_REL"; git -C "$h/$CLOSING_VAULT_REL" checkout -q -b other-branch
  e="$(cl_side_path new "$CLOSING_MAINT_OLD")" || e=""
  cl_py snap "$h" "$od/fx10-maint-before.json" --exclude Library/Caches/
  rc=0; [ -n "$e" ] && { cl_run "$h" "$s" "$wt10" AIENV_REPO="$wt10" "$wt10/$e" </dev/null >"$od/fx10-maint.stdout" 2>"$od/fx10-maint.stderr" || rc=$?; }
  printf '%s\n' "$rc" > "$od/fx10-maint.rc"
  cl_py snap "$h" "$od/fx10-maint-after.json" --exclude Library/Caches/
  cl_py snapdiff "$od/fx10-maint-before.json" "$od/fx10-maint-after.json" "$h" > "$od/fx10-maint.state"
  CL_SIDE_WT="$wt10" cl_norm new "$s" < "$od/fx10-maint.state" > "$od/fx10-maint.state.n"
  local fx10_osascript_maint; fx10_osascript_maint="$({ [ -f "$s/calls.log" ] && grep -c . "$s/calls.log" 2>/dev/null; } || true)"
  # VB-04-R3＝各自のログに「送らなかった」旨が題を含む行数＝FX-1側が同じ入力で送った知らせの数（知らせ1件につき1行）。
  local maint_log_n; maint_log_n="$(grep -cF '口が無いため知らせを送りません: maintenance.sh 異常終了' "$od/fx10-maint.stdout" "$od/fx10-maint.stderr" 2>/dev/null | awk -F: '{s+=$NF} END{print s+0}')"
  e="$(cl_side_path new "$CLOSING_USAGE_FETCH_OLD")" || e=""
  : > "$s/calls.log"
  cl_py snap "$h" "$od/fx10-usage-before.json" --exclude Library/Caches/
  rc=0; [ -n "$e" ] && { cl_run "$h" "$s" "$wt10" "$(cl_path "$s" "$CL_FIX/usage-bin")" \
    STUB_CURL_STATUS=200 STUB_CURL_BODY="$CLOSING_USAGE_WARN_BODY" \
    STUB_SECURITY_JSON='{"claudeAiOauth":{"accessToken":"tok-abc","expiresAt":99999999999999}}' \
    STUB_CODEX_RESULT_LINE="$(cat "$CL_FIX/usage-bin/codex_success_result_line.json")" \
    "$wt10/$e" </dev/null >"$od/fx10-usage.stdout" 2>"$od/fx10-usage.stderr" || rc=$?; }
  printf '%s\n' "$rc" > "$od/fx10-usage.rc"
  cl_py snap "$h" "$od/fx10-usage-after.json" --exclude Library/Caches/
  cl_py snapdiff "$od/fx10-usage-before.json" "$od/fx10-usage-after.json" "$h" > "$od/fx10-usage.state"
  CL_SIDE_WT="$wt10" cl_norm new "$s" < "$od/fx10-usage.state" > "$od/fx10-usage.state.n"
  local fx10_osascript_usage; fx10_osascript_usage="$({ [ -f "$s/calls.log" ] && grep -c . "$s/calls.log" 2>/dev/null; } || true)"
  local usage_log_n; usage_log_n="$(grep -cF '口が無いため知らせを送りません: claude-codex-usage' "$od/fx10-usage.stdout" "$od/fx10-usage.stderr" 2>/dev/null | awk -F: '{s+=$NF} END{print s+0}')"

  [ "$(cat "$od/fx1-maint.rc")" = "$(cat "$od/fx10-maint.rc")" ] || bad="$bad maint:rc不一致"
  [ "$fx1_osascript_maint" -ge 1 ] || bad="$bad maint:FX-1側でosascript記録が無い"
  [ "$fx10_osascript_maint" = 0 ] || bad="$bad maint:FX-10側でosascript記録が${fx10_osascript_maint}件（0のはず）"
  [ "$maint_log_n" = "$fx1_osascript_maint" ] || bad="$bad maint:口が無い旨の記録が${maint_log_n}件（FX-1側が送った知らせ${fx1_osascript_maint}件と一致するはず）"
  diff -u "$od/fx1-maint.state.n" "$od/fx10-maint.state.n" > "$od/maint-state.diff" 2>&1 || bad="$bad maint:状態記録(全体)不一致（ac4/maint-state.diff）"
  [ "$(cat "$od/fx1-usage.rc")" = "$(cat "$od/fx10-usage.rc")" ] || bad="$bad usage:rc不一致"
  [ "$fx1_osascript_usage" -ge 1 ] || bad="$bad usage:FX-1側でosascript記録が無い"
  [ "$fx10_osascript_usage" = 0 ] || bad="$bad usage:FX-10側でosascript記録が${fx10_osascript_usage}件（0のはず）"
  [ "$usage_log_n" = "$fx1_osascript_usage" ] || bad="$bad usage:口が無い旨の記録が${usage_log_n}件（FX-1側が送った知らせ${fx1_osascript_usage}件と一致するはず）"
  diff -u "$od/fx1-usage.state.n" "$od/fx10-usage.state.n" > "$od/usage-state.diff" 2>&1 || bad="$bad usage:取得結果(全体)不一致（ac4/usage-state.diff）"

  if [ -z "$bad" ]; then cl_result AC-4 ok "① メンテ・Usage とも rc・状態記録・取得結果（全体スナップショット比較）一致・FX-10 は osascript 0 件＋口なしの記録1行ずつ"
  else cl_result AC-4 NG "①${bad}（ac4/）"; fi
}

# ---------------------------------------------------------------- AC-5 取り外しと台帳（① だけ＝②③ は常設）
ac_5() {
  local od="$OUT/ac5" wt="$WORK/wt-fx10-ac5" why list f p tot rc_ledger=0
  mkdir -p "$od"
  if ! cl_fx1_ready; then cl_result AC-5 NG "① $CL_FX1_WHY"; return; fi
  cl_new_wt "$wt" "$FX1_COMMIT" || { cl_result AC-5 NG "FX-10 の worktree を作れない"; return; }
  why="$(cl_mk_fx10_rmn "$wt")" || { cl_result AC-5 NG "FX-10 を作れない: $why"; return; }
  list=""
  while IFS="$(printf '\t')" read -r f p; do
    [ -n "$p" ] || continue
    [ "$f" = "$CLOSING_LEDGER_CORE_FN" ] && continue
    list="$list $p"
  done <<EOF
$(cl_ledger_suites "$wt")
EOF
  CL_SUITES_FAILED=0; CL_SUITES_FAILED_NAMES=""
  # shellcheck disable=SC2086
  cl_run_suites "$wt" "$od/suites" $list
  tot="$(printf '%s\n' $list | grep -c .)"
  ( cd "$wt" && bash "$CLOSING_LEDGER_TOOL_REL" check ) >"$od/ledger-check.log" 2>&1 || rc_ledger=$?
  if [ "$CL_SUITES_FAILED" -eq 0 ] && [ "$rc_ledger" -eq 0 ]; then
    cl_result AC-5 ok "① FX-10 でスイート $tot 本 全 exit 0・台帳の検査 exit 0"
  else
    cl_result AC-5 NG "① 非0 ${CL_SUITES_FAILED}/${tot} 本（内訳＝ac5/suites/results.tsv）・台帳の検査 exit=${rc_ledger}（ac5/ledger-check.log）"
  fi
}

# ---------------------------------------------------------------- AC-7 スイートと実装の範囲（①②④。③ は常設）
ac_7() {
  local od="$OUT/ac7" wt="$WORK/wt-ac7-b" n rc=0 e4=""
  mkdir -p "$od"
  git -C "$CL_SRC" diff --name-status "$BASE_COMMIT" "$FX1_COMMIT" -- tests/ > "$od/tests-diff-name-status.txt"
  git -C "$CL_SRC" diff --numstat "$BASE_COMMIT" "$FX1_COMMIT" -- tests/ > "$od/tests-diff-numstat.txt"
  n="$(grep -c . "$od/tests-diff-name-status.txt")"
  if ! cl_fx1_ready; then cl_result AC-7 NG "① $CL_FX1_WHY"; return; fi
  cl_new_wt "$wt" "$FX1_COMMIT" || { cl_result AC-7 NG "① FX-1 の worktree を作れない"; return; }
  cl_run_all "$wt" "$od/run-all" || rc=$?

  # ④ (a) Brewfile・plist 本数・schema_version・台帳の列見出し
  diff -q <(git -C "$CL_SRC" show "$BASE_COMMIT:Brewfile" 2>/dev/null) <(git -C "$CL_SRC" show "$FX1_COMMIT:Brewfile" 2>/dev/null) \
    >/dev/null 2>&1 || e4="$e4 Brewfile"
  local pb pn; pb="$(git -C "$CL_SRC" ls-tree -r --name-only "$BASE_COMMIT" | grep -c '\.plist$')"
  pn="$(git -C "$CL_SRC" ls-tree -r --name-only "$FX1_COMMIT" | grep -c '\.plist$')"
  [ "$pb" = "$pn" ] || e4="$e4 plist本数(${pb}→${pn})"
  local svb svn
  svb="$(git -C "$CL_SRC" show "$BASE_COMMIT:team/data/profile.md.sample" 2>/dev/null | grep -m1 '^schema_version:')"
  svn="$(git -C "$CL_SRC" show "$FX1_COMMIT:team/data/profile.md.sample" 2>/dev/null | grep -m1 '^schema_version:')"
  [ "$svb" = "$svn" ] || e4="$e4 配役表schema_version(${svb}→${svn})"
  # VM-03＝実物の見出しは全角「列＝」・列名は <TAB> という文字列で区切られる（半角 `=` の grep は空振りしていた）。
  local colb coln addb addn
  colb="$(git -C "$CL_SRC" show "$BASE_COMMIT:$CLOSING_LEDGER_REL" 2>/dev/null | grep -m1 '^# 列＝')"
  coln="$(git -C "$CL_SRC" show "$FX1_COMMIT:$CLOSING_LEDGER_REL" 2>/dev/null | grep -m1 '^# 列＝')"
  if [ -z "$colb" ] || [ -z "$coln" ]; then
    e4="$e4 台帳列見出しが取れない（基準=${colb:-空}／FX-1=${coln:-空}）"
  else
    addb="$(printf '%s' "$colb" | grep -o '<TAB>' | wc -l | tr -d ' ')"
    addn="$(printf '%s' "$coln" | grep -o '<TAB>' | wc -l | tr -d ' ')"
    [ "$((addn - addb))" -le 2 ] || e4="$e4 台帳列見出しの増分$((addn - addb))件(上限2)"
  fi

  # ④ (b) bash 3.2 構文・実行時非互換
  local f syntax_bad=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    /bin/bash -n "$wt/$f" 2>>"$od/syntax.log" || syntax_bad="$syntax_bad $f"
  done < <(git -C "$CL_SRC" diff --name-only --diff-filter=AM "$BASE_COMMIT".."$FX1_COMMIT" -- '*.sh' ':!tests/closing')
  [ -z "$syntax_bad" ] || e4="$e4 bash構文:$syntax_bad"
  # リーダー実査＝tests/closing/（検査する側・メイン機でしか動かない）は実装対象から除く。
  # |&・&>> は演算子としての出現だけに当てる（[[:space:]] 境界）＝test-ledger.sh のブラケット式
  # リテラル（FORMULA_C='…|&…'）を偽陽性にしない。
  git -C "$CL_SRC" diff -U0 "$BASE_COMMIT".."$FX1_COMMIT" -- '*.sh' ':!tests/closing' 2>/dev/null | grep -E '^\+' \
    | grep -E 'wait -n|declare -[a-zA-Z]*[gnA]|local -[a-zA-Z]*[nA]|mapfile|readarray|coproc|\$\{[A-Za-z_]+(,,|\^\^)\}|(^|[[:space:]])&>>([[:space:]]|$)|(^|[[:space:]])\|&([[:space:]]|$)' \
    > "$od/bash32-incompat.txt"
  local incompat; incompat="$(grep -c . "$od/bash32-incompat.txt" 2>/dev/null || true)"
  [ "${incompat:-0}" = 0 ] || e4="$e4 bash3.2非互換${incompat}件（ac7/bash32-incompat.txt）"

  # ④ (c) python の import が標準ライブラリだけ
  local nonstd
  nonstd="$(git -C "$CL_SRC" diff --name-only --diff-filter=AM "$BASE_COMMIT".."$FX1_COMMIT" -- '*.py' 2>/dev/null \
    | while read -r f; do python3 - "$wt/$f" <<'PY'
import ast, sys
try:
    t = ast.parse(open(sys.argv[1]).read())
except Exception:
    sys.exit(0)
for n in ast.walk(t):
    names = [a.name for a in n.names] if isinstance(n, ast.Import) else ([n.module] if isinstance(n, ast.ImportFrom) and n.module and n.level == 0 else [])
    for m in names:
        if m.split(".")[0] not in sys.stdlib_module_names: print("nonstd", sys.argv[1], m)
PY
    done)"
  [ -z "$nonstd" ] || e4="$e4 python非標準import:$(printf '%s' "$nonstd" | tr '\n' ';')"

  # ④ (d) 新しい設定拡張子・ビルド定義・外部 API
  local newext
  newext="$(git -C "$CL_SRC" diff --name-only --diff-filter=A "$BASE_COMMIT".."$FX1_COMMIT" 2>/dev/null \
    | sed -n 's/.*\.\([A-Za-z0-9]*\)$/\1/p' | sort -u \
    | grep -vxF -f <(git -C "$CL_SRC" ls-tree -r --name-only "$BASE_COMMIT" | sed -n 's/.*\.\([A-Za-z0-9]*\)$/\1/p' | sort -u) || true)"
  [ -z "$newext" ] || e4="$e4 新拡張子:$(printf '%s' "$newext" | tr '\n' ',')"
  local builddef
  builddef="$(git -C "$CL_SRC" diff --name-only --diff-filter=A "$BASE_COMMIT".."$FX1_COMMIT" 2>/dev/null \
    | grep -E '(^|/)(Makefile|package\.json|pyproject\.toml|setup\.py|requirements[^/]*\.txt|Gemfile|go\.mod|Cargo\.toml|CMakeLists\.txt)$' || true)"
  [ -z "$builddef" ] || e4="$e4 ビルド定義:$(printf '%s' "$builddef" | tr '\n' ',')"
  local api
  api="$(git -C "$CL_SRC" diff -U0 "$BASE_COMMIT".."$FX1_COMMIT" -- . ':!tests' ':!*.md' 2>/dev/null | grep -E '^\+' \
    | grep -E 'api\.anthropic\.com|api\.openai\.com|(curl|wget)[^#]*https?://' | wc -l | tr -d ' ')"
  [ "$api" = 0 ] || e4="$e4 外部API呼出${api}件"

  if [ "$rc" -eq 0 ] && [ -z "$e4" ]; then
    cl_result AC-7 ok "① FX-1 一括実行 exit 0（ac7/run-all/） ② tests/ 変更 $n ファイル（分類は verifier） ④ 静的検査すべて適合"
  else
    cl_result AC-7 NG "① exit=${rc}（ac7/run-all/run-all.log） ② tests/ 変更 $n ファイル ④${e4:- ok}"
  fi
}

# ---------------------------------------------------------------- AC-12 取込み（①② だけ＝③④ は束 C）
ac_12() {
  local od="$OUT/ac12-b" h="$WORK/home" s m1="" m2=""
  mkdir -p "$od" "$OUT/ac10"   # ac10_three（ac-live.sh の共有部品）は $OUT/ac10/ に固定で書く
  if ! cl_fx1_ready; then cl_result AC-12 NG "① $CL_FX1_WHY"; return; fi

  # ① FX-5（sub clone・origin=FX-1 へ進めた状態）で更新コマンドを 1 回
  s="$WORK/s-ac12b-1"; cl_stubs "$s"
  ac10_fx15 "$h" "$s" "$od/fx15.log" || { cl_result AC-12 NG "① FX-5 を作れない（ac12-b/fx15.log）"; return; }
  ac10_origin_advance
  local rc=0
  cl_run "$h" "$s" "$h/$CLOSING_REPO_HOME_REL" "$h/$CLOSING_REPO_HOME_REL/$CLOSING_UPDATE_SUB_OLD" </dev/null \
    >"$od/1-update-sub.log" 2>&1 || rc=$?
  m1="$(ac10_three "$h" "ac12b-1")"; [ "$rc" -eq 0 ] || m1="$m1 exit=$rc"
  [ -z "$m1" ] || m1="$m1"

  # ② FX-7（① と同じ FX-5 を作り直し、origin だけ進めて pull のみ＝更新コマンドは実行しない）
  s="$WORK/s-ac12b-2"; cl_stubs "$s"
  ac10_fx15 "$h" "$s" "$od/fx15-2.log" || { cl_result AC-12 NG "② FX-5 を作れない（ac12-b/fx15-2.log）"; return; }
  ac10_origin_advance
  cl_run "$h" "$s" "$h/$CLOSING_REPO_HOME_REL" git pull -q --ff-only </dev/null >"$od/2-pull.log" 2>&1
  cl_hooks_exist "$h" "$h/.claude/settings.json" > "$od/2-hooks.txt" 2>&1
  local hook_rc=$?
  if [ "$hook_rc" -ne 0 ]; then
    # 柵（安全フェンス）フックだけが対象（NFR-4）＝*-gate.sh・*-guard.sh・inprocess-gate.sh を名指す行だけを見る。
    local fence; fence="$(grep -E '(-gate|-guard)\.sh' "$od/2-hooks.txt" || true)"
    [ -z "$fence" ] || m2="$m2 柵フック欠落: $(printf '%s' "$fence" | tr '\n' ';')"
  fi

  if [ -z "$m1" ] && [ -z "$m2" ]; then
    cl_result AC-12 ok "① FX-5→更新コマンド1回 exit=${rc}・HEAD/リンク/フック OK ② FX-7 で柵フック全実在"
  else
    cl_result AC-12 NG "①${m1:- ok}（ac12-b/1-update-sub.log） ②${m2:- ok}（ac12-b/2-hooks.txt）"
  fi
}
