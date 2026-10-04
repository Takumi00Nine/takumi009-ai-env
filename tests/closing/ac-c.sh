# v1.2 束 C の締め AC（AC-7①②④〔束 B の ac_7 をそのまま流用＝run-closing-c.sh が ac-b.sh を source するだけで足りる・
#   ここでは再定義しない〕・AC-8②④・AC-10・AC-11③④・AC-12①②③④）。
# run-closing-c.sh が lib-closing.sh・ac-suites.sh・ac-12.sh・ac-live.sh・ac-b.sh の後に source する
# （同名の関数 ac_8・ac_10・ac_11・ac_12 はここの定義で上書きする＝ac_7 だけ ac-b.sh のまま）。
# shellcheck shell=bash
#
# ■ 試験設計の要点（報告に残す・リーダー裁定＝束 C 着手ゲート C4 の実名に従う）
# - AC-8②の「入口の全数」＝確定直前に台帳と repo を grep して取り直した（鍵を照会する部品＝ledger-tool.sh lookup を
#   直接呼ぶか core/executor/notice.sh 経由で呼ぶもの）のうち AI Brain・Core に属するもの＝3 件：
#     ai-brain/executor/maintenance.sh（ab-maint）・core/connect/claude-code/session-start-compose.sh（ab-bootstrap）・
#     core/connect/claude-code/prompt-answer.sh（hk-ups-pos）。3 件とも既存の v1.1 FX-26 入力がある（無い入口を
#     1 件ずつ決める必要は無かった）。Team・Usage・Dock に属する lookup 呼び手（claude_exec.py・codex-direct-call-gate.sh・
#     role_candidates.py・usage-fetch.sh・usage_snapshot.py・cmux-next-model.sh）は対象外（選んだ機能に属さない）。
# - FX-8 の注入＝$HOME/.codex を読取専用（束 C 着手ゲート C4・実装計画 §5）。AI Brain の link を置いた後、
#   Team の Codex の gen 行で rename が失敗して止まる想定＝「配置を 1 件以上変えた後・登録の前」。
# - 台帳から導いた配置の集合＝`ledger-tool.sh placement [--all]`（未実装の間は赤＝そのための試験）。
#   選択を直接 CLI で渡す引数は無い（plan §1）ので、AIENV_COMPONENTS_FILE で一時ファイルを渡して解決する。
# - AC-11④＝dotfiles の FR-19 commit（implementer C-3 が後で作る）。closing.conf の CLOSING_DOTFILES_REPO・
#   CLOSING_DOTFILES_COMMIT が空（または commit が無い）間は `AC-11④ skip <理由>` を出して NG に数えない。

# ---------------------------------------------------------------- 共有ヘルパ
# clc_strip_features <wt> <fn...> — v1.1 FX-8／FX-9 の取り外し方（機能フォルダ・そのスイート・台帳の
#   その機能の行〔part/suite/notify〕を除く。移動表は触らない＝束 C は転送が無いので対象外）。
clc_strip_features() {
  local wt="$1" fn f p
  shift
  [ -f "$wt/$CLOSING_LEDGER_REL" ] || { echo "台帳が無い"; return 1; }
  for fn in "$@"; do
    while IFS="$(printf '\t')" read -r f p; do
      [ "$f" = "$fn" ] && [ -n "$p" ] && rm -f "$wt/$p"
    done <<EOF
$(cl_ledger_suites "$wt")
EOF
    rm -rf "${wt:?}/$fn"
    awk -F'\t' -v fn="$fn" -v k1="$CLOSING_LEDGER_PART_KIND" -v k2="$CLOSING_LEDGER_SUITE_KIND" -v k3="$CLOSING_LEDGER_NOTIFY_KIND" \
      '!($0 !~ /^#/ && ($1==k1||$1==k2||$1==k3) && $3==fn)' "$wt/$CLOSING_LEDGER_REL" > "$wt/$CLOSING_LEDGER_REL.tmp" \
      && mv "$wt/$CLOSING_LEDGER_REL.tmp" "$wt/$CLOSING_LEDGER_REL"
  done
}

# clc_home_select <home> <wt> <stubdir> <log> <selection> — 空 HOME へ install-main.sh --select <selection>
clc_home_select() {
  local h="$1" wt="$2" s="$3" log="$4" sel="$5" cfg p
  rm -rf "$h"; cfg="$h/$CLOSING_CONFIG_DIR_REL"; mkdir -p "$cfg"
  p="$(cl_side_path new "$CLOSING_PROFILE_SAMPLE_OLD")" || { echo "引けない: $CLOSING_PROFILE_SAMPLE_OLD" >>"$log"; return 1; }
  cp "$wt/$p" "$cfg/profile.md"
  p="$(cl_side_path new "$CLOSING_MODELS_SAMPLE_OLD")" || { echo "引けない: $CLOSING_MODELS_SAMPLE_OLD" >>"$log"; return 1; }
  cp "$wt/$p" "$cfg/models.conf"
  p="$(cl_side_path new "$CLOSING_INSTALL_MAIN_OLD")" || { echo "引けない: $CLOSING_INSTALL_MAIN_OLD" >>"$log"; return 1; }
  cl_run "$h" "$s" "$wt" "$wt/$p" "$CLOSING_SELECT_ARG" "$sel" </dev/null >>"$log" 2>&1
}

# clc_placement_set <wt> <home> <all|SELECTION> — 台帳から導いた配置の集合（$HOME 展開ずみ）＝
#   "<仕方>:<置き場>" を 1 行 1 件（sorted・unique）。SELECTION は AIENV_COMPONENTS_FILE の一時ファイルで渡す
#   （plan §1＝placement 自身は --select を取らず、保存された選択〔既定＝全部入り〕を読む）。
clc_placement_set() {
  local wt="$1" h="$2" sel="$3" tmp out
  if [ "$sel" = "$CLOSING_SELECT_ALL" ]; then
    out="$(cd "$wt" && HOME="$h" bash "$CLOSING_LEDGER_TOOL_REL" "$CLOSING_PLACEMENT_SUBCMD" --all 2>/dev/null)"
  else
    tmp="$(mktemp "${TMPDIR:-/tmp}/components.XXXXXX")"
    printf '%s=%s\n' "$CLOSING_COMPONENTS_KEY" "$sel" > "$tmp"
    out="$(cd "$wt" && HOME="$h" AIENV_COMPONENTS_FILE="$tmp" bash "$CLOSING_LEDGER_TOOL_REL" "$CLOSING_PLACEMENT_SUBCMD" 2>/dev/null)"
    rm -f "$tmp"
  fi
  printf '%s\n' "$out" | awk -F'\t' -v home="$h" '{g=$2; gsub(/\$HOME/, home, g); print $1":"g}' | sort -u
}

# clc_names_match <home> <wt> <all|SEL> <out_prefix> — <out_prefix>.diff を書く。名前集合が一致すれば 0。
clc_names_match() {
  local h="$1" wt="$2" sel="$3" outp="$4"
  clc_placement_set "$wt" "$h" "$sel" \
    | sed -E 's/^[a-z]+://' \
    | awk -v home="$h" '{ if (index($0, home "/") == 1) print substr($0, length(home) + 2); else print $0 }' \
    | sort -u > "$outp.expect"
  ac8_live "$h" "$wt" | awk -F'\t' '$2!="-"{print $1}' | sort -u > "$outp.actual"
  diff -u "$outp.expect" "$outp.actual" > "$outp.diff" 2>&1
}

# clc_ac8_entry_run <lbl:A|B> <wt> <home> <stub> <od> <id:ab-maint|ab-bootstrap|hk-ups-pos>
clc_ac8_entry_run() {
  local lbl="$1" wt="$2" h="$3" s="$4" od="$5" id="$6" rc=0 st="$od/$lbl.stdin" e f
  mkdir -p "$od"; : > "$st"
  case "$id" in
    ab-maint) cl_mk_vault_fx5 "$h/$CLOSING_VAULT_REL" ;;
    *) cl_mk_vault_fx4 "$h/$CLOSING_VAULT_REL" ;;
  esac
  case "$id" in
    ab-bootstrap) printf '{}' > "$st" ;;
    hk-ups-pos) printf '{"session_id":"s1","prompt":"%s"}' "$CLOSING_FX9_UPS_POS" > "$st" ;;
  esac
  cl_py snap "$h" "$od/$lbl.before.json" --exclude Library/Caches/
  {
    case "$id" in
      ab-maint)
        e="$(cl_side_path new "$CLOSING_MAINT_OLD")" && cl_run "$h" "$s" "$wt" AIENV_REPO="$wt" "$wt/$e" </dev/null || rc=$? ;;
      ab-bootstrap)
        ac12_hooks "$h" "$s" "$wt" SessionStart "" "$st" || rc=$? ;;
      hk-ups-pos)
        ac12_hooks "$h" "$s" "$wt" UserPromptSubmit "" "$st" "CODE27_CALL_BIN=$s/c27/bin/code27-call-clear" || rc=$? ;;
    esac
  } >"$od/$lbl.stdout" 2>"$od/$lbl.stderr" || rc=$?
  printf '%s\n' "$rc" > "$od/$lbl.rc"
  case "$id" in hk-ups-pos) cl_wait_lines "$s/c27/calls.log" 1 ;; esac
  cl_py snap "$h" "$od/$lbl.after.json" --exclude Library/Caches/
  cl_py snapdiff "$od/$lbl.before.json" "$od/$lbl.after.json" "$h" > "$od/$lbl.state"
  for f in rc stdout state; do CL_SIDE_WT="$wt" cl_norm new "$s" < "$od/$lbl.$f" > "$od/$lbl.$f.n"; done
}

# clc_ac8_entry_same <od> — A.*.n と B.*.n を比較。<od>/diff.txt に差分。一致で 0。
clc_ac8_entry_same() {
  local od="$1" f bad=0
  : > "$od/diff.txt"
  for f in rc stdout state; do diff -u "$od/A.$f.n" "$od/B.$f.n" >> "$od/diff.txt" 2>&1 || bad=1; done
  return "$bad"
}

# ---------------------------------------------------------------- AC-8 選択（②④ だけ＝①③⑤⑥ は常設）
ac_8() {
  local od="$OUT/ac8" why bad2="" n=0 same=0 id tg4=0 ok4=1 msg4=""
  mkdir -p "$od"
  if ! cl_fx1_ready; then cl_result AC-8 NG "② $CL_FX1_WHY"; return; fi

  # ④ 指定なしの組立 vs 基準（v1.1 AC-8 ①〜④・比較本体は ac-live.sh の cl_ac8_cmp を共有）
  why="$(cl_readme_check base main "$WT0/README.md")" || { cl_result AC-8 NG "④ README 不一致(基準): $why"; return; }
  ac8_side base "$WT0" || { cl_result AC-8 NG "④ 基準側の導入が失敗（ac8/base/install.log）"; return; }
  why="$(cl_readme_check new main "$WT1/README.md")" || { cl_result AC-8 NG "④ README 不一致(FX-1): $why"; return; }
  ac8_side new "$WT1" || { cl_result AC-8 NG "④ FX-1 側の導入が失敗（ac8/new/install.log）"; return; }
  cl_ac8_cmp "$od"
  tg4="$(grep -c . "$od/new/la-targets.txt")"
  if [ -n "$CL_AC8_E1" ] || [ "$CL_AC8_E2" != 0 ] || [ -n "$CL_AC8_E3" ] || [ "$CL_AC8_E4" != 0 ] || [ "$tg4" -le 0 ]; then
    ok4=0; msg4="①${CL_AC8_E1:- ok} ②リンク切れ $CL_AC8_E2 ③${CL_AC8_E3:- ok} ④不在 $CL_AC8_E4/${tg4}"
  else
    msg4="v1.1 AC-8 ①〜④ 成立（起動対象 $tg4 件）"
  fi

  # ② 選択（FX-13＝{Core, AI Brain}）vs v1.1 FX-8 の作り方で AI Brain・Core だけにした木を全部入りで組み立てた HOME
  local wtA="$WORK/wt-ac8c-a" wtB="$WORK/wt-ac8c-b" hA="$WORK/home-ac8c-a" hB="$WORK/home-ac8c-b" sA="$WORK/s-ac8c-a" sB="$WORK/s-ac8c-b"
  cl_new_wt "$wtA" "$FX1_COMMIT" || { cl_result AC-8 NG "②④ worktree(A) を作れない"; return; }
  cl_new_wt "$wtB" "$FX1_COMMIT" || { cl_result AC-8 NG "②④ worktree(B) を作れない"; return; }
  why="$(clc_strip_features "$wtB" team usage notify dock)"
  [ -f "$wtB/$CLOSING_LEDGER_REL" ] || { cl_result AC-8 NG "② v1.1 FX-8 の木を作れない: $why"; return; }
  cl_stubs "$sA"; mkdir -p "$sA/c27/bin"; cp -R "$CL_DIR/../fixtures/code27-call/bin/." "$sA/c27/bin/"
  clc_home_select "$hA" "$wtA" "$sA" "$od/c2-a-install.log" "$CLOSING_SELECT_AB_CORE" \
    || { cl_result AC-8 NG "② HOME-A（--select ${CLOSING_SELECT_AB_CORE}）の組立が失敗（ac8/c2-a-install.log）"; return; }
  cl_stubs "$sB"; mkdir -p "$sB/c27/bin"; cp -R "$CL_DIR/../fixtures/code27-call/bin/." "$sB/c27/bin/"
  cl_fresh_main_home new "$hB" "$wtB" "$sB" "$od/c2-b-install.log" \
    || { cl_result AC-8 NG "② HOME-B（取り外した木・全部入り組立）の組立が失敗（ac8/c2-b-install.log）"; return; }

  # 入口の全数（確定直前に台帳・repo で取り直した＝ファイル冒頭コメント）＝3 件
  for id in ab-maint ab-bootstrap hk-ups-pos; do
    n=$((n + 1))
    clc_ac8_entry_run A "$wtA" "$hA" "$sA" "$od/$id" "$id"
    clc_ac8_entry_run B "$wtB" "$hB" "$sB" "$od/$id" "$id"
    if clc_ac8_entry_same "$od/$id"; then same=$((same + 1)); else bad2="$bad2 $id"; fi
  done

  if [ "$ok4" -eq 1 ] && [ -z "$bad2" ]; then
    cl_result AC-8 ok "② 入口 3 件（maintenance.sh／session-start-compose.sh／prompt-answer.sh）$same/$n 一致 ④ $msg4"
  else
    cl_result AC-8 NG "②一致 $same/${n}（不一致:${bad2:- なし}・ac8/<id>/diff.txt） ④${msg4}（ac8/）"
  fi
}

# ---------------------------------------------------------------- AC-10 部分成功（束 C）
ac_10() {
  local od="$OUT/ac10c" h="$WORK/home-ac10c" repo s why rc=0 bad="" p x
  mkdir -p "$od"
  why="$(cl_readme_check base sub "$WT0/README.md" && cl_readme_check base main "$WT0/README.md")" \
    || { cl_result AC-10 NG "README の手順と定数が不一致: 基準 ${why}"; return; }
  if ! cl_fx1_ready; then cl_result AC-10 NG "$CL_FX1_WHY"; return; fi
  why="$(cl_readme_check new import "$WT1/README.md")" || { cl_result AC-10 NG "README の手順と定数が不一致: FX-1 ${why}"; return; }

  # FX-6（基準でメイン機導入）→ origin を FX-1 へ進め、$HOME/.codex を読取専用にして
  #   README のメイン機の取込み手順（pull→install-main→LA→check-drift）を実行＝FX-8（計画§5・束C着手ゲートC4）
  s="$WORK/s-ac10c"; cl_stubs "$s"
  ac10_clone "$h" "$s" && cl_install_main base "$h" "$h/$CLOSING_REPO_HOME_REL" "$s" "$od/fx6.log" \
    || { cl_result AC-10 NG "FX-6（基準のメイン機導入）が失敗（ac10c/fx6.log）"; return; }
  repo="$h/$CLOSING_REPO_HOME_REL"
  ac10_origin_advance
  chmod -w "$h/.codex" 2>/dev/null

  : > "$od/fx8.log"
  cl_run "$h" "$s" "$repo" git pull -q --ff-only </dev/null >>"$od/fx8.log" 2>&1
  rc=0
  for x in $CLOSING_INSTALL_MAIN_OLD $CLOSING_INSTALL_LA_OLD $CLOSING_CHECK_DRIFT_OLD; do
    p="$(cl_side_path new "$x")" || continue
    cl_run "$h" "$s" "$repo" "$repo/$p" </dev/null >>"$od/fx8.log" 2>&1 || { rc=$?; echo "rc=$rc $p" >>"$od/fx8.log"; break; }
    echo "rc=0 $p" >> "$od/fx8.log"
  done
  if [ "$rc" -eq 0 ]; then
    chmod +w "$h/.codex" 2>/dev/null
    cl_result AC-10 NG "FX-8 の注入（.codex 読取専用）で失敗にならなかった（ac10c/fx8.log）"; return
  fi
  cl_hooks_exist "$h" "$h/.claude/settings.json" > "$od/fx8-hooks.txt" 2>&1 \
    || bad="$bad 再実行前:全フック実在しない($(grep -c . "$od/fx8-hooks.txt")件)"
  grep -qE '[./][A-Za-z0-9_./-]+\.(sh|toml)' "$od/fx8.log" || bad="$bad 再実行前:失敗報告に終わらなかった項目が見えない"

  # 同じ取込み手順を再実行（.codex を書込み可に戻す）＝exit 0・名前集合＝全部入り・配置の健全性検査 exit0
  chmod +w "$h/.codex" 2>/dev/null
  : > "$od/redo1.log"
  cl_run "$h" "$s" "$repo" git pull -q --ff-only </dev/null >>"$od/redo1.log" 2>&1
  rc=0
  for x in $CLOSING_INSTALL_MAIN_OLD $CLOSING_INSTALL_LA_OLD; do
    p="$(cl_side_path new "$x")" || { bad="$bad 再実行:引けない:$x"; continue; }
    cl_run "$h" "$s" "$repo" "$repo/$p" </dev/null >>"$od/redo1.log" 2>&1 || { rc=$?; bad="$bad 再実行:$p=rc$rc"; }
  done
  p="$(cl_side_path new "$CLOSING_CHECK_DRIFT_OLD")" && {
    cl_run "$h" "$s" "$repo" "$repo/$p" "$CLOSING_CHECK_DRIFT_HEALTH_ARG" </dev/null >>"$od/redo1.log" 2>&1 \
      || bad="$bad 再実行:配置の健全性検査=$?"
  }
  [ "$rc" -eq 0 ] || bad="$bad 再実行:exit=$rc"
  clc_names_match "$h" "$repo" "$CLOSING_SELECT_ALL" "$od/redo1-names" || bad="$bad 再実行後:名前集合≠全部入り(ac10c/redo1-names.diff)"
  cp "$h/.claude/settings.json" "$od/redo1-settings.json" 2>/dev/null

  # FX-13 の選択で組立 → 全部入りの選択を明示して組立をもう一度
  p="$(cl_side_path new "$CLOSING_INSTALL_MAIN_OLD")"
  cl_run "$h" "$s" "$repo" "$repo/$p" "$CLOSING_SELECT_ARG" "$CLOSING_SELECT_AB_CORE" </dev/null >"$od/sel13.log" 2>&1 \
    || bad="$bad FX-13選択:rc$?"
  cl_run "$h" "$s" "$repo" "$repo/$p" "$CLOSING_SELECT_ARG" "$CLOSING_SELECT_ALL" </dev/null >"$od/sel-all.log" 2>&1 \
    || bad="$bad 全部入り明示:rc$?"
  clc_names_match "$h" "$repo" "$CLOSING_SELECT_ALL" "$od/back-names" || bad="$bad 戻した後:名前集合≠全部入り(ac10c/back-names.diff)"
  diff -u <(cl_py canon "$od/redo1-settings.json" json 2>/dev/null) <(cl_py canon "$h/.claude/settings.json" json 2>/dev/null) \
    > "$od/back-settings.diff" 2>&1 || bad="$bad 戻した後:settings≠再実行後(ac10c/back-settings.diff)"

  if [ -z "$bad" ]; then
    cl_result AC-10 ok "再実行前=柵含む全フック実在・終わらなかった項目の報告あり / 再実行後=exit0・名前集合=全部入り / 戻した後=名前集合・settings が再実行後と一致"
  else
    cl_result AC-10 NG "${bad}（ac10c/）"
  fi
}

# ---------------------------------------------------------------- AC-11 撤去（③ の締め側＝FX-5・④ だけ）
ac_11() {
  local od="$OUT/ac11c" h s why e3="" rc=0 p
  mkdir -p "$od"
  if ! cl_fx1_ready; then cl_result AC-11 NG "③ $CL_FX1_WHY"; return; fi

  # ③ FX-5（サブ機）の HOME へ check-drift --forward-refs（dotfiles は none・Vault は FX-5 の複製）
  h="$WORK/home-ac11c"; s="$WORK/s-ac11c"; cl_stubs "$s"
  ac10_fx15 "$h" "$s" "$od/fx5.log" || { cl_result AC-11 NG "③ FX-5（サブ機導入）が失敗（ac11c/fx5.log）"; return; }
  cl_mk_vault_fx5 "$h/$CLOSING_VAULT_REL"
  p="$(cl_side_path new "$CLOSING_CHECK_DRIFT_OLD")"
  rc=0; cl_run "$h" "$s" "$h/$CLOSING_REPO_HOME_REL" "$h/$CLOSING_REPO_HOME_REL/$p" \
    "$CLOSING_CHECK_DRIFT_FORWARD_ARG" --dotfiles "$CLOSING_DOTFILES_NONE_VALUE" \
    >"$od/forward-refs.log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || e3="exit=${rc}（ac11c/forward-refs.log）"

  # ④ FX-16（dotfiles の 1 commit）＝値が無ければ skip（NG に数えない）
  if [ -z "${CLOSING_DOTFILES_REPO:-}" ] || [ -z "${CLOSING_DOTFILES_COMMIT:-}" ] \
     || ! git -C "$CLOSING_DOTFILES_REPO" rev-parse --verify "${CLOSING_DOTFILES_COMMIT}^{commit}" >/dev/null 2>&1; then
    echo "AC-11④ skip dotfiles の commit が未指定・未作成（closing.conf の CLOSING_DOTFILES_REPO・CLOSING_DOTFILES_COMMIT で与える＝implementer C-3 の成果を指す）"
    if [ -z "$e3" ]; then cl_result AC-11 ok "③ check-drift --forward-refs（dotfiles=none）exit 0"
    else cl_result AC-11 NG "③ $e3"; fi
    return
  fi

  local dw="$WORK/dotfiles-fx16" e4=""
  cl_new_wt_at "$CLOSING_DOTFILES_REPO" "$dw" "$CLOSING_DOTFILES_COMMIT" \
    || { cl_result AC-11 NG "③${e3:- ok} ④ dotfiles の worktree を作れない"; return; }

  # ④-a 追跡ファイルを転送の旧パス（移動表の撤去印）で grep＝0 件
  local old_paths op hit
  old_paths="$(awk -F'\t' -v mk="$CLOSING_RETIRE_MARK" '$0!~/^#/ && NF>=4 && $4==mk{print $1}' "$WT1/$CLOSING_MOVES_REL")"
  : > "$od/fx16-grep.txt"
  for op in $old_paths; do
    [ -n "$op" ] || continue
    git -C "$dw" grep -I -n -F -- "$op" >> "$od/fx16-grep.txt" 2>/dev/null
  done
  hit="$(grep -c . "$od/fx16-grep.txt" 2>/dev/null || true)"
  [ "${hit:-0}" = 0 ] || e4="$e4 旧パスの参照 ${hit} 件（ac11c/fx16-grep.txt）"

  # ④-b commit の差分が旧パス→新パスの置換行だけ（追加・削除が 1 対 1）
  local pairs x swap_args
  pairs="$(awk -F'\t' -v mk="$CLOSING_RETIRE_MARK" '$0!~/^#/ && NF>=4 && $4==mk{print $1"="$2}' "$WT1/$CLOSING_MOVES_REL")"
  swap_args=()
  while IFS= read -r x; do [ -n "$x" ] && swap_args+=("$x"); done <<EOF
$pairs
EOF
  if ! cl_py pathswap-diff "$CLOSING_DOTFILES_REPO" "$CLOSING_DOTFILES_COMMIT" "${swap_args[@]}" > "$od/fx16-diff.txt" 2>&1; then
    e4="$e4 commit の差分が置換行だけでない（ac11c/fx16-diff.txt）"
  fi

  # ④-c 描画常駐 2 本（cmux-next-watch・cmux-task-watch）の README に示すテストを実行
  #   （dotfiles 側のテストの正確な置き場は implementer C-3 の成果待ち＝暫定で test-*.sh を glob。要調整＝報告）
  local wd t_fail=0 t_ran=0 f
  for wd in $CLOSING_DOTFILES_RETIRE_WATCH_DIRS; do
    [ -d "$dw/$wd" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      t_ran=$((t_ran + 1))
      /bin/bash "$f" >"$od/$(basename "$f").log" 2>&1 || t_fail=$((t_fail + 1))
    done <<EOF
$(find "$dw/$wd" -type f -name 'test-*.sh' 2>/dev/null)
EOF
  done
  if [ "$t_ran" -eq 0 ]; then e4="$e4 描画常駐のテストが見つからない（$CLOSING_DOTFILES_RETIRE_WATCH_DIRS 配下 test-*.sh）"
  elif [ "$t_fail" -gt 0 ]; then e4="$e4 描画常駐のテスト ${t_fail}/${t_ran} 本が非 0"
  fi

  # ④-d 既定供給パス 2 本を v1.1 AC-9 と同じ入力で起動し、FX-2 の供給と同じ出力（既存の ac12_run/ac12_same を共有）
  local id same=0 dn=0
  if ac12_prep base && ac12_prep new; then
    for id in dock-next-list dock-next-frame dock-task-list dock-task-frame; do
      dn=$((dn + 1))
      CL_AC12_OD="$od/dock" ac12_run base "$id"
      CL_AC12_OD="$od/dock" ac12_run new "$id" literal
      if CL_AC12_OD="$od/dock" ac12_same "$id"; then same=$((same + 1)); else e4="$e4 供給差:$id"; fi
    done
  else
    e4="$e4 導入手順が失敗（ac12/install-*.log）"
  fi

  if [ -z "$e3" ] && [ -z "$e4" ]; then
    cl_result AC-11 ok "③ check-drift --forward-refs exit 0 ④ grep 0 件・置換のみ・描画常駐 ${t_ran} 本合格・供給 $same/$dn 一致"
  else
    cl_result AC-11 NG "③${e3:- ok} ④${e4:- ok}（ac11c/）"
  fi
}

# ---------------------------------------------------------------- AC-12 取込み（①②③④＝束 C）
ac_12() {
  local od="$OUT/ac12c" h1="$WORK/home-ac12c-1" s1 rc=0 m1="" m2="" m3="" m4="" why
  mkdir -p "$od" "$OUT/ac10"
  if ! cl_fx1_ready; then cl_result AC-12 NG "① $CL_FX1_WHY"; return; fi

  # ① FX-5 で更新コマンドを 1 回（origin を FX-1 へ進めた状態）
  s1="$WORK/s-ac12c-1"; cl_stubs "$s1"
  ac10_fx15 "$h1" "$s1" "$od/fx15-1.log" || { cl_result AC-12 NG "① FX-5 を作れない（ac12c/fx15-1.log）"; return; }
  ac10_origin_advance
  rc=0; cl_run "$h1" "$s1" "$h1/$CLOSING_REPO_HOME_REL" "$h1/$CLOSING_REPO_HOME_REL/$CLOSING_UPDATE_SUB_OLD" </dev/null \
    >"$od/1-update-sub.log" 2>&1 || rc=$?
  m1="$(ac10_three "$h1" "ac12c-1")"; [ "$rc" -eq 0 ] || m1="$m1 exit=$rc"

  # ② FX-7（origin だけ進め pull のみ）＝柵の登録フックが全て実在
  local h2="$WORK/home-ac12c-2" s2
  s2="$WORK/s-ac12c-2"; cl_stubs "$s2"
  ac10_fx15 "$h2" "$s2" "$od/fx15-2.log" || { cl_result AC-12 NG "② FX-5 を作れない（ac12c/fx15-2.log）"; return; }
  ac10_origin_advance
  cl_run "$h2" "$s2" "$h2/$CLOSING_REPO_HOME_REL" git pull -q --ff-only </dev/null >"$od/2-pull.log" 2>&1
  cl_hooks_exist "$h2" "$h2/.claude/settings.json" > "$od/2-hooks.txt" 2>&1
  if [ $? -ne 0 ]; then
    local fence; fence="$(grep -E "$CLOSING_FENCE_GREP_RE" "$od/2-hooks.txt" || true)"
    [ -z "$fence" ] || m2="柵フック欠落: $(printf '%s' "$fence" | tr '\n' ';')"
  fi

  # ③ FX-6 で clone を FX-1 へ進め、README に示すメイン機の取込み手順を実行（印付きコマンドの照合は v1.1 ハーネスのまま）
  why="$(cl_readme_check new import "$WT1/README.md")" || { cl_result AC-12 NG "③ README の手順と定数が不一致(FX-1): ${why}"; return; }
  local h3="$WORK/home-ac12c-3" s3 repo3 p x rc3=0
  s3="$WORK/s-ac12c-3"; cl_stubs "$s3"
  ac10_clone "$h3" "$s3" && cl_install_main base "$h3" "$h3/$CLOSING_REPO_HOME_REL" "$s3" "$od/fx6-3.log" \
    || { cl_result AC-12 NG "③ FX-6（基準のメイン機導入）が失敗（ac12c/fx6-3.log）"; return; }
  ac10_origin_advance
  repo3="$h3/$CLOSING_REPO_HOME_REL"
  { rc3=0; cl_run "$h3" "$s3" "$repo3" git pull -q --ff-only </dev/null || rc3=$?; echo "rc=$rc3 pull"; } >"$od/3-import.log" 2>&1
  [ "$rc3" -eq 0 ] || m3="pull=$rc3"
  for x in $CLOSING_INSTALL_MAIN_OLD $CLOSING_INSTALL_LA_OLD; do
    p="$(cl_side_path new "$x")" || { m3="$m3 引けない:$x"; continue; }
    rc3=0; cl_run "$h3" "$s3" "$repo3" "$repo3/$p" </dev/null >>"$od/3-import.log" 2>&1 || rc3=$?
    echo "rc=$rc3 $p" >> "$od/3-import.log"
    [ "$rc3" -eq 0 ] || m3="$m3 $p=$rc3"
  done
  m3="$m3$(ac10_three "$h3" "ac12c-3")"
  : > "$od/3-la-targets.txt"
  for x in $CLOSING_LA_PLISTS; do
    plutil -extract ProgramArguments json -o - "$h3/$CLOSING_LA_DIR_REL/$x" 2>/dev/null | jq -r '.[] | select(startswith("/"))' |
      while IFS= read -r p; do [ -e "$p" ] || echo "不在 $x $p"; done
  done >> "$od/3-la-targets.txt"
  [ -s "$od/3-la-targets.txt" ] && m3="$m3 起動対象欠$(grep -c . "$od/3-la-targets.txt")"
  p="$(cl_side_path new "$CLOSING_CHECK_DRIFT_OLD")" && {
    rc3=0; cl_run "$h3" "$s3" "$repo3" "$repo3/$p" "$CLOSING_CHECK_DRIFT_HEALTH_ARG" </dev/null >>"$od/3-import.log" 2>&1 || rc3=$?
    [ "$rc3" -eq 0 ] || m3="$m3 配置の健全性検査=$rc3"
  }

  # ④ ① の後の FX-5（h1）で、FX-14 の選択→更新コマンド1回→失敗注入（.codex 読取専用）→更新コマンド
  local repo1="$h1/$CLOSING_REPO_HOME_REL"
  p="$(cl_side_path new "$CLOSING_INSTALL_SUB_OLD")"
  rc=0; cl_run "$h1" "$s1" "$repo1" "$repo1/$p" "$CLOSING_SELECT_ARG" "$CLOSING_SELECT_CORE" </dev/null >"$od/4-sel.log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || m4="選択(install-sub --select core)=$rc"
  rc=0; cl_run "$h1" "$s1" "$repo1" "$repo1/$CLOSING_UPDATE_SUB_OLD" </dev/null >"$od/4-update1.log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || m4="$m4 更新1回目=$rc"
  clc_names_match "$h1" "$repo1" "$CLOSING_SELECT_CORE" "$od/4-names" || m4="$m4 名前集合≠Core(ac12c/4-names.diff)"
  chmod -w "$h1/.codex" 2>/dev/null
  rc=0; cl_run "$h1" "$s1" "$repo1" "$repo1/$CLOSING_UPDATE_SUB_OLD" </dev/null >"$od/4-update2-fail.log" 2>&1 || rc=$?
  chmod +w "$h1/.codex" 2>/dev/null
  [ "$rc" -ne 0 ] || m4="$m4 失敗注入(.codex読取専用)で失敗にならなかった"
  cl_hooks_exist "$h1" "$h1/.claude/settings.json" > "$od/4-hooks-after-fail.txt" 2>&1
  if [ $? -ne 0 ]; then
    local fence4; fence4="$(grep -E "$CLOSING_FENCE_GREP_RE" "$od/4-hooks-after-fail.txt" || true)"
    [ -z "$fence4" ] || m4="$m4 柵フック欠落(失敗後): $(printf '%s' "$fence4" | tr '\n' ';')"
  fi

  if [ -z "$m1$m2$m3$m4" ]; then
    cl_result AC-12 ok "① ok ② 柵実在 ③ README取込み手順・LA対象実在・配置健全性検査 ok ④ Core選択保持・失敗後も柵実在"
  else
    cl_result AC-12 NG "①${m1:- ok}（ac12c/1-update-sub.log） ②${m2:- ok} ③${m3:- ok}（ac12c/3-import.log） ④${m4:- ok}（ac12c/4-*）"
  fi
}
