# 配置と外部参照の AC（AC-8・AC-9・AC-10）。run-closing.sh が source する。
# shellcheck shell=bash
#
# ■ 試験設計（AC-10）
# - origin＝$WORK/origin.git（使い捨ての bare）。基準を main に push してから clone（FX-15・16）し、
#   「origin を FX-1 へ進める」＝FX-1 のコミットを同じ main へ push（fast-forward）。実 repo の main・remote には触れない。
# - FX-15＝clone＋README のサブ機手順（profile.md.sample の machine_role を sub に書き換え）。入力ごとに作り直す。
# - FX-23 の途中失敗のさせ方＝PATH 先頭に偽 `ln`（FX-6 に足す 1 本）を置き、$CLOSING_IFAIL_LN_OK_CALLS 回までは /bin/ln へ
#   渡し、それを超えた呼び出しから非 0 を返す＝インストーラの配置（symlink 張り替え）の途中で止まる（設計 §8.2 F1）。
#   注入が起きなかった（偽 ln の呼び出しが上限以下）ときは試験として成立しないので NG にする。
# - メイン機の取込み手順（FX-16 → FX-1）＝設計 §8.1-4: pull → 全部入りインストーラ → LaunchAgent 系 3 本 → 配置の健全性検査。
#   各パスは移動表で引く（lib-closing.sh 契約 3）。各段の終了コード 0（配置の健全性検査を含む）＋要件の 3 点＋起動対象で判定する。
# - 手順の定数は、起動時に README（英日）の印の手順と突合し、不一致なら NG（lib-closing.sh cl_readme_check・印は closing.conf）。

# ---------------------------------------------------------------- AC-8
# ac8_live <home> <wt> > tsv — ライブ位置の各名前: 名前<TAB>種類(L/F/-)<TAB>実体（repo 内は R:<相対>・無ければ MISSING:）
ac8_live() {
  local h="$1" wtr d n f t
  wtr="$(cl_realpath "$2")"
  for d in $CLOSING_LIVE_DIRS; do
    [ -d "$h/$d" ] || continue
    for n in $(ls -A "$h/$d"); do ac8_entry "$h" "$d/$n" "$wtr"; done
  done
  for f in $CLOSING_LIVE_FILES; do ac8_entry "$h" "$f" "$wtr"; done
  for f in $CLOSING_LA_PLISTS; do ac8_entry "$h" "$CLOSING_LA_DIR_REL/$f" "$wtr"; done
}
ac8_entry() {
  local h="$1" n="$2" wtr="$3" t
  if [ -L "$h/$n" ]; then
    t="$(cl_realpath "$h/$n")"
    [ -e "$t" ] || { printf '%s\tL\tMISSING:%s\n' "$n" "$t"; return; }
    case "$t" in "$wtr"/*) t="R:${t#"$wtr"/}" ;; esac
    printf '%s\tL\t%s\n' "$n" "$t"
  elif [ -e "$h/$n" ]; then printf '%s\tF\t-\n' "$n"
  else printf '%s\t-\t-\n' "$n"; fi
}

# ac8_side <side> <wt> — 新しい HOME に導入手順を実行し、ライブ位置の一覧と生成ファイルを $OUT/ac8/<side>/ へ
ac8_side() {
  local side="$1" wt="$2" od="$OUT/ac8/$1" h="$WORK/home" f
  rm -rf "$od"; mkdir -p "$od"
  cl_stubs "$WORK/ac8-$side"
  cl_fresh_main_home "$side" "$h" "$wt" "$WORK/ac8-$side" "$od/install.log" || return 1
  ac8_live "$h" "$wt" > "$od/live.tsv"
  cp "$h/.claude/settings.json" "$od/settings.json" 2>/dev/null
  cp "$h/.codex/config.toml" "$od/config.toml" 2>/dev/null
  for f in $CLOSING_LA_PLISTS; do cp "$h/$CLOSING_LA_DIR_REL/$f" "$od/$f" 2>/dev/null; done
  # ④ の材料（その側の plist の起動対象＝ProgramArguments の絶対パス）が実在するか
  : > "$od/la-targets.txt"
  for f in $CLOSING_LA_PLISTS; do
    plutil -extract ProgramArguments json -o - "$h/$CLOSING_LA_DIR_REL/$f" 2>/dev/null | jq -r '.[] | select(startswith("/"))' |
      while IFS= read -r t; do if [ -e "$t" ]; then echo "ok $f $t"; else echo "MISSING $f $t"; fi; done >> "$od/la-targets.txt"
  done
}

ac_8() {
  local od="$OUT/ac8" moves="$WT1/$CLOSING_MOVES_REL" n k t nk nt succ e1="" e2="" e3="" e4="" c p f
  mkdir -p "$od"
  local why
  why="$(cl_readme_check base main "$WT0/README.md")" || { cl_result AC-8 NG "README の手順と定数が不一致: 基準 ${why}"; return; }
  ac8_side base "$WT0" || { cl_result AC-8 NG "基準側の導入手順が失敗（ac8/base/install.log）"; return; }
  if ! cl_fx1_ready; then cl_result AC-8 NG "${CL_FX1_WHY}（基準側の配置は済み＝ac8/base/）"; return; fi
  why="$(cl_readme_check new main "$WT1/README.md")" || { cl_result AC-8 NG "README の手順と定数が不一致: FX-1 ${why}"; return; }
  ac8_side new "$WT1" || { cl_result AC-8 NG "FX-1 側の導入手順が失敗（ac8/new/install.log）"; return; }
  # ① 名前の包含と実体の後継
  while IFS="$(printf '\t')" read -r n k t; do
    [ -n "$n" ] && [ "$k" != "-" ] || continue
    nk="$(awk -F'\t' -v n="$n" '$1==n{print $2}' "$od/new/live.tsv")"
    nt="$(awk -F'\t' -v n="$n" '$1==n{print $3}' "$od/new/live.tsv")"
    if [ -z "$nk" ] || [ "$nk" = "-" ]; then e1="$e1 欠:$n"; continue; fi
    if [ "$k" = L ] && [ "${t#R:}" != "$t" ]; then
      succ="$(cl_py moves-succ "$moves" "${t#R:}")" || succ="${t#R:}"
      printf '%s\n' "$succ" | grep -qxF "${nt#R:}" || e1="$e1 実体:$n(${t#R:}→${nt#R:})"
    fi
  done < "$od/base/live.tsv"
  while IFS="$(printf '\t')" read -r n k t; do
    [ -n "$n" ] && [ "$k" != "-" ] || continue
    awk -F'\t' -v n="$n" '$1==n && $2!="-"{f=1} END{exit !f}' "$od/base/live.tsv" && continue
    if [ "${t#R:}" != "$t" ] && cl_py moves-split-new "$moves" "${t#R:}"; then :; else e1="$e1 新のみ:$n"; fi
  done < "$od/new/live.tsv"
  # ②
  e2="$(grep -c 'MISSING:' "$od/new/live.tsv")"
  # ③ 生成ファイル
  cl_py canon "$od/base/settings.json" json | cl_norm base "$od" > "$od/base.settings.n.json"
  cl_py canon "$od/new/settings.json" json | cl_norm new "$od" > "$od/new.settings.n.json"
  cl_py settings-cmp "$od/base.settings.n.json" "$od/new.settings.n.json" > "$od/settings-cmp.txt" || e3="$e3 settings.json"
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    # FX-1 にだけある登録は、許容する追加のライブ名（closing.conf CLOSING_AC8_ALLOWED_EXTRA）だけ ok
    p="${c#EXTRA }"; p="${p%% *}"; p="${p##*/}"
    case " $CLOSING_AC8_ALLOWED_EXTRA " in *" $p "*) ;; *) e3="$e3 登録:${c#EXTRA }" ;; esac
  done <<EOF
$(grep '^EXTRA ' "$od/settings-cmp.txt")
EOF
  for f in config.toml $CLOSING_LA_PLISTS; do
    case "$f" in *.toml) k=toml ;; *) k=plist ;; esac
    cl_py canon "$od/base/$f" "$k" 2>/dev/null | cl_norm base "$od" > "$od/base.$f.n"
    cl_py canon "$od/new/$f" "$k" 2>/dev/null | cl_norm new "$od" > "$od/new.$f.n"
    diff -u "$od/base.$f.n" "$od/new.$f.n" > "$od/$f.diff" || e3="$e3 $f"
  done
  # ④
  e4="$(grep -c '^MISSING' "$od/new/la-targets.txt")"
  local tg; tg="$(grep -c . "$od/new/la-targets.txt")"
  if [ -z "$e1" ] && [ "$e2" = 0 ] && [ -z "$e3" ] && [ "$e4" = 0 ] && [ "$tg" -gt 0 ]; then
    cl_result AC-8 ok "①名前・実体 一致 ②リンク切れ 0 ③生成ファイル 一致 ④起動対象 $tg 件 実在"
  else
    cl_result AC-8 NG "①${e1:- ok} ②リンク切れ $e2 ③${e3:- ok} ④不在 $e4/${tg}（ac8/）"
  fi
}

# ---------------------------------------------------------------- AC-9
ac_9() {
  local od="$OUT/ac9" p bad="" info="" n=0 id rel same=0
  mkdir -p "$od"
  if ! cl_fx1_ready; then cl_result AC-9 NG "$CL_FX1_WHY"; return; fi
  # 実在・実行可能（旧パスのまま＝repo の外の参照はこの名前で来る）
  for p in $CLOSING_DOCK_OLD $CLOSING_LA_TARGETS_OLD $CLOSING_UPDATE_SUB_CALLS; do
    n=$((n + 1))
    if [ ! -e "$WT1/$p" ]; then bad="$bad 不在:$p"
    elif [ "${p%.sh}" != "$p" ] && [ ! -x "$WT1/$p" ]; then bad="$bad 実行不可:$p"; fi
  done
  # Vault Preferences が名指す repo パス（読み取りだけ）
  # shellcheck disable=SC2086
  # （`~/.config/takumi009-ai-env/` は設定置き場＝repo パスでないので除く）
  grep -rhoE '(\.config/)?takumi009-ai-env/[A-Za-z0-9_./-]+' $CLOSING_PREFS_GLOB 2>/dev/null | grep -v '^\.config/' \
    | sed -E 's#^takumi009-ai-env/##; s#[.]+$##; s#/$##' | sort -u > "$od/vault-prefs-paths.txt"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ ! -e "$WT0/$p" ]; then info="$info $p"; continue; fi   # 基準にも無い＝相当パスが無い（対象外・一覧に残す）
    n=$((n + 1)); rel="$p"
    if [ ! -e "$WT1/$p" ]; then rel="$(cl_py moves-main "$WT1/$CLOSING_MOVES_REL" "$p")" || rel=""; fi
    if [ -z "$rel" ] || [ ! -e "$WT1/$rel" ]; then bad="$bad 不在:$p"
    elif [ "${rel%.sh}" != "$rel" ] && [ ! -x "$WT1/$rel" ]; then bad="$bad 実行不可:$p"; fi
  done < "$od/vault-prefs-paths.txt"
  printf '%s\n' $info > "$od/vault-prefs-not-in-base.txt"
  # dotfiles の既定供給パス 2 本＝FX-2 と同じ入力で同じ出力（FX-1 側は旧パスのまま起動）
  ac12_prep base && ac12_prep new || { cl_result AC-9 NG "導入手順が失敗（ac12/install-*.log）"; return; }
  for id in dock-next-list dock-next-frame dock-task-list dock-task-frame; do
    CL_AC12_OD="$od" ac12_run base "$id"
    CL_AC12_OD="$od" ac12_run new "$id" literal
    if CL_AC12_OD="$od" ac12_same "$id"; then same=$((same + 1)); else bad="$bad 出力差:$id"; fi
  done
  if [ -z "$bad" ]; then cl_result AC-9 ok "参照 $n 件 実在・実行可能 / 供給 2 本 4 入力 一致（基準にも無い Vault 参照は ac9/vault-prefs-not-in-base.txt）"
  else cl_result AC-9 NG "${bad}（ac9/）"; fi
}

# ---------------------------------------------------------------- AC-10
ac10_origin_reset() {  # origin の main を基準へ戻す（無ければ作る）
  [ -d "$WORK/origin.git" ] || git init -q --bare -b main "$WORK/origin.git"
  git -C "$CL_SRC" push -q -f "$WORK/origin.git" "$BASE_COMMIT:refs/heads/main" >>"$OUT/detail.log" 2>&1
}
ac10_origin_advance() {
  git -C "$CL_SRC" push -q "$WORK/origin.git" "$FX1_COMMIT:refs/heads/main" >>"$OUT/detail.log" 2>&1
}
# ac10_clone <home> <stubdir> — 新しい HOME に origin（基準）を clone
ac10_clone() {
  rm -rf "$1"; mkdir -p "$1/$(dirname "$CLOSING_REPO_HOME_REL")"
  ac10_origin_reset || return 1
  cl_run "$1" "$2" "$1" git clone -q "$WORK/origin.git" "$1/$CLOSING_REPO_HOME_REL" >>"$OUT/detail.log" 2>&1
}
# ac10_fx15 <home> <stubdir> <log> — FX-15（clone＋現行のサブ機導入手順）
ac10_fx15() {
  ac10_clone "$1" "$2" || return 1
  cl_install_sub base "$1" "$1/$CLOSING_REPO_HOME_REL" "$2" "$3"
}
# ac10_three <home> <label> — 要件の 3 点（HEAD・リンク切れ・登録フック）を見て、欠けを 1 行で返す
ac10_three() {
  local h="$1" repo="$1/$CLOSING_REPO_HOME_REL" m="" head
  head="$(git -C "$repo" rev-parse HEAD 2>/dev/null)"
  [ "$head" = "$FX1_COMMIT" ] || m="$m HEAD≠FX-1"
  cl_dangling "$h/.claude" "$h/.codex" > "$OUT/ac10/$2-dangling.txt" || m="$m リンク切れ$(grep -c . "$OUT/ac10/$2-dangling.txt")"
  cl_hooks_exist "$h" "$h/.claude/settings.json" > "$OUT/ac10/$2-hooks.txt" || m="$m フック欠$(grep -c . "$OUT/ac10/$2-hooks.txt")"
  printf '%s' "$m"
}

ac_10() {
  local od="$OUT/ac10" h="$WORK/home" s rc m1 m2 m3a m3b x p lim cnt bad=0 why
  mkdir -p "$od"
  why="$(cl_readme_check base sub "$WT0/README.md" && cl_readme_check base main "$WT0/README.md")" \
    || { cl_result AC-10 NG "README の手順と定数が不一致: 基準 ${why}"; return; }
  # 基準側だけで動く部分（FX-15・FX-16 の配置）を先に確かめる
  s="$WORK/ac10-s0"; cl_stubs "$s"
  ac10_fx15 "$h" "$s" "$od/fx15-probe.log" || { cl_result AC-10 NG "FX-15（基準のサブ機導入）が失敗（ac10/fx15-probe.log）"; return; }
  s="$WORK/ac10-s1"; cl_stubs "$s"
  ac10_clone "$h" "$s" && cl_install_main base "$h" "$h/$CLOSING_REPO_HOME_REL" "$s" "$od/fx16-probe.log" \
    || { cl_result AC-10 NG "FX-16（基準のメイン機導入）が失敗（ac10/fx16-probe.log）"; return; }
  if ! cl_fx1_ready; then cl_result AC-10 NG "${CL_FX1_WHY}（基準側 FX-15・FX-16 の配置は成功）"; return; fi
  why="$(cl_readme_check new import "$WT1/README.md")" || { cl_result AC-10 NG "README の手順と定数が不一致: FX-1 ${why}"; return; }
  # ① FX-15 → 現行のサブ機更新コマンド 1 回
  s="$WORK/ac10-a"; cl_stubs "$s"
  ac10_fx15 "$h" "$s" "$od/fx15-a.log" && ac10_origin_advance || { cl_result AC-10 NG "① FX-15 を作れない"; return; }
  rc=0; cl_run "$h" "$s" "$h/$CLOSING_REPO_HOME_REL" "$h/$CLOSING_REPO_HOME_REL/$CLOSING_UPDATE_SUB_OLD" </dev/null >"$od/1-update-sub.log" 2>&1 || rc=$?
  m1="$(ac10_three "$h" 1)"; [ "$rc" -eq 0 ] || m1="$m1 exit=$rc"
  [ -z "$m1" ] || bad=1
  # ② FX-16 → README のメイン機の取込み手順
  s="$WORK/ac10-b"; cl_stubs "$s"
  ac10_clone "$h" "$s" && cl_install_main base "$h" "$h/$CLOSING_REPO_HOME_REL" "$s" "$od/fx16.log" && ac10_origin_advance \
    || { cl_result AC-10 NG "② FX-16 を作れない"; return; }
  m2=""
  # shellcheck disable=SC2086
  { rc=0; cl_run "$h" "$s" "$h/$CLOSING_REPO_HOME_REL" $CLOSING_IMPORT_PULL </dev/null || rc=$?; echo "rc=$rc pull"; } >"$od/2-import.log" 2>&1
  [ "$rc" -eq 0 ] || m2="$m2 pull=$rc"
  for x in $CLOSING_INSTALL_MAIN_OLD $CLOSING_INSTALL_LA_OLD $CLOSING_CHECK_DRIFT_OLD; do
    p="$(cl_side_path new "$x")" || { m2="$m2 引けない:$x"; continue; }
    rc=0; cl_run "$h" "$s" "$h/$CLOSING_REPO_HOME_REL" "$h/$CLOSING_REPO_HOME_REL/$p" </dev/null >>"$od/2-import.log" 2>&1 || rc=$?
    echo "rc=$rc $p" >> "$od/2-import.log"
    [ "$rc" -eq 0 ] || m2="$m2 $p=$rc"   # 配置の健全性検査（check-drift）も rc 0 を必須（C-2）
  done
  m2="$m2$(ac10_three "$h" 2)"
  for x in $CLOSING_LA_PLISTS; do
    plutil -extract ProgramArguments json -o - "$h/$CLOSING_LA_DIR_REL/$x" 2>/dev/null | jq -r '.[] | select(startswith("/"))' |
      while IFS= read -r p; do [ -e "$p" ] || echo "不在 $x $p"; done
  done > "$od/2-la-targets.txt"
  [ -s "$od/2-la-targets.txt" ] && m2="$m2 起動対象欠$(grep -c . "$od/2-la-targets.txt")"
  [ -z "$m2" ] || bad=1
  # ③ FX-22（pull だけ）
  s="$WORK/ac10-c"; cl_stubs "$s"
  ac10_fx15 "$h" "$s" "$od/fx15-c.log" && ac10_origin_advance || { cl_result AC-10 NG "③ FX-22 を作れない"; return; }
  cl_run "$h" "$s" "$h/$CLOSING_REPO_HOME_REL" git pull -q --ff-only </dev/null >"$od/3-fx22-pull.log" 2>&1
  m3a=""; cl_hooks_exist "$h" "$h/.claude/settings.json" > "$od/3-fx22-hooks.txt" || m3a=" FX-22 フック欠$(grep -c . "$od/3-fx22-hooks.txt")"
  # ③ FX-23（インストーラの途中失敗＝偽 ln）
  s="$WORK/ac10-d"; cl_stubs "$s"
  ac10_fx15 "$h" "$s" "$od/fx15-d.log" && ac10_origin_advance || { cl_result AC-10 NG "③ FX-23 を作れない"; return; }
  lim="$CLOSING_IFAIL_LN_OK_CALLS"
  printf '#!/bin/bash\nc="%s/ln.count"; n=$(( $(cat "$c" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$c"\nif [ "$n" -gt %s ]; then echo "closing: 偽 ln が失敗を注入（$n 回目）" >&2; exit 1; fi\nexec /bin/ln "$@"\n' "$s" "$lim" > "$s/bin/ln"
  chmod +x "$s/bin/ln"
  rc=0; cl_run "$h" "$s" "$h/$CLOSING_REPO_HOME_REL" "$h/$CLOSING_REPO_HOME_REL/$CLOSING_UPDATE_SUB_OLD" </dev/null >"$od/3-fx23-update-sub.log" 2>&1 || rc=$?
  cnt="$(cat "$s/ln.count" 2>/dev/null || echo 0)"
  m3b=""
  if [ "$cnt" -le "$lim" ]; then m3b=" FX-23 失敗を注入できず（ln ${cnt} 回・試験設計の見直しが要る）"
  else
    [ "$rc" -ne 0 ] || m3b=" FX-23 更新コマンドが exit 0（途中失敗にならず）"
    cl_hooks_exist "$h" "$h/.claude/settings.json" > "$od/3-fx23-hooks.txt" || m3b="$m3b FX-23 フック欠$(grep -c . "$od/3-fx23-hooks.txt")"
  fi
  [ -z "$m3a$m3b" ] || bad=1
  if [ "$bad" -eq 0 ]; then cl_result AC-10 ok "① ok ② ok ③ FX-22・FX-23（exit=${rc}・ln ${cnt} 回目で失敗）フック実在"
  else cl_result AC-10 NG "①${m1:- ok} ②${m2:- ok} ③${m3a}${m3b}（ac10/）"; fi
}
