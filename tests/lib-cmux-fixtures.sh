# cmux 供給側テストの共通 fixture 生成部品（cmux-session-todo 設計
# §28.3・§33.1・§36 担当J）。V群（Task 側 Vault ノート）・W群（宣言記録）・
# N群（Project 側 Vault ノート）・S群（cmux スタブ）・F群（外部脳ログ）・
# T群（タイミング）・K群（機の構成）を提供する。`test-*.sh` に一致しない
# 名前にしてある（テストランナーがこのファイル自体を実行しないため）。
#
# ゲート（~/Claude/cmux-session-todo/gates/gate-stage1.sh）はこのファイルを
# source して 55 fixture の同値検査に使う（設計 §33.1）。両 repo の外の
# ツールなので、どちらの repo の lib を source しても FR-87 に抵触しない。
#
# 使い方:
#   . "$SCRIPT_DIR/lib-cmux-fixtures.sh"
#   mk_note_V1 "$VAULT"

# ==========================================================================
# V群: Task 側 Vault ノート fixture（V-1〜V-18・v1/v2 と同一内容／
# V-19a〜c・V-20＝v4新設・design.md §39.7.2）
# ==========================================================================
mk_note_V1() {
  cat > "$1/Projects/v1proj.md" <<'EOF'
---
date: 2026-01-01
---
## Tasks

### v1
- [x] task a
- [x] task b
- [x] task c

### v2
- [x] 要件定義
- [/] 設計
- [ ] 実装

### v3
- [ ] t1
- [ ] t2
- [ ] t3
- [ ] t4
EOF
}

mk_note_V2() {
  cat > "$1/Projects/v2proj.md" <<'EOF'
---
date: 2026-01-01
---
# no tasks section at all
EOF
}

mk_note_V3() {
  cat > "$1/Projects/v3proj.md" <<'EOF'
---
date: 2026-01-01
---
## Tasks
- [ ] task without a version heading
EOF
}

mk_note_V4() {
  cat > "$1/Projects/v4proj.md" <<'EOF'
---
date: 2026-01-01
---
## Tasks

### v1

### v2
EOF
}

mk_note_V5() {
  cat > "$1/Projects/v5proj.md" <<'EOF'
---
date: 2026-01-01
---
## Tasks

### v1
- [x] a

### v2

### v3
- [ ] b
EOF
}

# タスク本文に U+0000（NUL）・ESC・CSI（ESC[…）・TAB・U+007F（DEL）・
# U+0080・U+009F を含む。bash 変数は NUL を保持できないため、printf から
# ファイルへ直接リダイレクトして書く（変数へは一切経由しない）。
mk_note_V6() {
  printf -- '---\ndate: 2026-01-01\n---\n## Tasks\n\n### v1\n- [ ] a\x00b\x1bc\x1b[31md\x09e\x7ff\xc2\x80g\xc2\x9fh\n' > "$1/Projects/v6proj.md"
}

mk_note_V7() {
  local body
  body="$(python3 -c 'print("A"*520)')"
  {
    printf -- '---\ndate: 2026-01-01\n---\n## Tasks\n\n### v1\n- [ ] '
    printf '%s\n' "$body"
  } > "$1/Projects/v7proj.md"
}

mk_note_V8() {
  cat > "$1/Projects/v8proj.md" <<'EOF'
---
date: 2026-01-01
---
## Tasks

### v1
- [ ]
EOF
}

mk_note_V9() {
  local body
  body="$(python3 -c 'print("あ"*25)')"
  {
    printf -- '---\ndate: 2026-01-01\n---\n## Tasks\n\n### v1\n- [ ] '
    printf '%s\n' "$body"
  } > "$1/Projects/v9proj.md"
}

mk_note_V10() {
  cat > "$1/Projects/v10proj.md" <<'EOF'
---
date: 2026-01-01
---
## Tasks

### v1
- [x] a
- [x] b

### v2
- [x] a

### v3
- [x] a
- [x] b
- [x] c
EOF
}

mk_note_V11() {
  cat > "$1/Projects/v11proj.md" <<'EOF'
---
date: 2026-01-01
---
## Tasks

### v1
- [ ] a

### v2
- [ ] b
EOF
}

mk_note_V12() {
  cat > "$1/Projects/v12proj.md" <<'EOF'
---
date: 2026-01-01
## Tasks

### v1
- [ ] a
EOF
}

mk_note_V13() {
  cat > "$1/Projects/v13proj.md" <<'EOF'
---
date: 2026-01-01
---
## Tasks

### dup
- [x] a

### dup
- [ ] b
EOF
}

mk_note_V14() {
  python3 -c "
lines=['---','date: 2026-01-01','---','## Tasks','','### v1']
for i in range(60): lines.append(f'- [ ] t{i}')
open('$1/Projects/v14proj.md','w').write('\n'.join(lines)+'\n')
"
}

mk_note_V15() {
  python3 -c "
lines=['---','date: 2026-01-01','---','## Tasks','','### v1','- [x] a','- [x] b','','### v2']
for i in range(1,6): lines.append(f'- [x] t{i}')
for i in range(6,11): lines.append(f'- [ ] t{i}')
lines.append('- [/] t11')
lines.append('- [ ] t12')
lines += ['','### v3','- [x] a','','### v4','- [x] a','','### v5','- [x] a']
open('$1/Projects/v15proj.md','w').write('\n'.join(lines)+'\n')
"
}

V16_SLUG="$(python3 -c 'print("a"*45)')"
mk_note_V16() {
  cat > "$1/Projects/${V16_SLUG}.md" <<'EOF'
---
date: 2026-01-01
---
## Tasks

### v1
- [ ] t1
- [ ] t2
EOF
}

V18_SLUG="v18proj"
mk_note_V18() {
  cat > "$1/Projects/${V18_SLUG}.md" <<'EOF'
---
date: 2026-01-01
---
## Tasks

### v1
- [x] a
- [/] b
- [ ] c

### v2
- [/] d
- [ ] e
EOF
}

V19A_SLUG="v19aproj"
mk_note_V19a() {
  cat > "$1/Projects/${V19A_SLUG}.md" <<'EOF'
---
date: 2026-01-01
next: "v2"
---
## Tasks

### v1
- [ ] a

### v2
- [ ] b
EOF
}

V19B_SLUG="v19bproj"
mk_note_V19b() {
  cat > "$1/Projects/${V19B_SLUG}.md" <<'EOF'
---
date: 2026-01-01
next: "v"
---
## Tasks

### v1
- [ ] a

### v2
- [ ] b
EOF
}

V19C_SLUG="v19cproj"
mk_note_V19c() {
  cat > "$1/Projects/${V19C_SLUG}.md" <<'EOF'
---
date: 2026-01-01
next: "v1"
---
## Tasks

### v1
- [x] a

### v2
- [ ] b
EOF
}

V20_SLUG="v20proj"
mk_note_V20() {
  cat > "$1/Projects/${V20_SLUG}.md" <<'EOF'
---
date: 2026-01-01
---
## Tasks

### v1
- [/] a
- [ ] b

### v2
- [x] c
- [ ] d

### v3
- [ ] e
EOF
}

V17_SLUG="v17projectname"
mk_note_V17() {
  local longver
  longver="$(python3 -c 'print("v"*45)')"
  cat > "$1/Projects/${V17_SLUG}.md" <<EOF
---
date: 2026-01-01
---
## Tasks

### ${longver}
- [ ] t1
- [ ] t2
EOF
}

# ==========================================================================
# W群: 宣言記録 fixture（W-1〜W-11）
# ==========================================================================

# W-1: UUID-AAA -> $1(slug) の1件。
mk_decl_single() {
  local slug="$1" state_file="$2"
  cat > "$state_file" <<JSON
{"version":1,"workspaces":{"UUID-AAA":"$slug"}}
JSON
}

# W-1相当・複数対（AC-102・K-1/K-3の期待JSON用）。
mk_decl_pair() {
  local uuid1="$1" slug1="$2" uuid2="$3" slug2="$4" state_file="$5"
  cat > "$state_file" <<JSON
{"version":1,"workspaces":{"$uuid1":"$slug1","$uuid2":"$slug2"}}
JSON
}

# W-3: 空の宣言（version 1・workspaces 空）。
mk_decl_empty() {
  cat > "$1" <<'JSON'
{"version":1,"workspaces":{}}
JSON
}

# W-7: 記録が壊れている（JSON として無効）。
mk_decl_corrupt() {
  printf 'not json' > "$1"
}

# ==========================================================================
# N群: Project 側 Vault ノート fixture（N-0〜N-8・FR-31 の導出検査用）
# ==========================================================================

mk_note_N0() {
  cat > "$1/Projects/proj-n0-base.md" <<'EOF'
---
date: 2026-08-01
updated: 2026-09-08
status: active
next: N0基準next値
---
## Tasks
### v1
- [ ] N0のタスク
EOF
}

mk_note_N1() {
  cat > "$1/Projects/proj-n1-handwritten.md" <<'EOF'
---
date: 2026-08-01
updated: 2026-09-05
status: active
next: 手書きのnext値
---
## Tasks
### v1
- [ ] Tasksの別タスク本文（next:優先時はここに出ないはず）
EOF
}

mk_note_N2() {
  cat > "$1/Projects/proj-n2-short.md" <<'EOF'
---
date: 2026-08-01
updated: 2026-09-04
status: active
---
## Tasks
### v1
- [x] 完了済みタスク
- [ ] 短いタスク
EOF
}

mk_note_N3() {
  cat > "$1/Projects/proj-n3-long.md" <<'EOF'
---
date: 2026-08-01
updated: 2026-09-03
status: active
---
## Tasks
### v1
- [ ] これは十五コードポイントを確実に超える長さの未完タスク本文
EOF
}

mk_note_N4() {
  cat > "$1/Projects/proj-n4-none.md" <<'EOF'
---
date: 2026-08-01
updated: 2026-09-02
status: active
---
# next も Tasks 節も無いノート
EOF
}

mk_note_N5() {
  cat > "$1/Projects/proj-n5-emptynext.md" <<'EOF'
---
date: 2026-08-01
updated: 2026-09-06
status: active
next: ""
---
## Tasks
### v1
- [/] 進行中のタスク
EOF
}

mk_note_N6() {
  python3 - "$1/Projects/proj-n6-control.md" <<'PYEOF'
import sys
esc = chr(27)
cr = chr(13)
tab = chr(9)
body = "タスク" + tab + "本文" + cr + "続き" + esc + "[31m"
content = (
    "---\n"
    "date: 2026-08-01\n"
    "updated: 2026-08-25\n"
    "status: active\n"
    "---\n"
    "## Tasks\n"
    "### v1\n"
    "- [ ] " + body + "\n"
)
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    fh.write(content)
PYEOF
}

mk_note_N7() {
  cat > "$1/Projects/proj-n7-completed.md" <<'EOF'
---
date: 2026-08-01
updated: 2026-09-07
status: completed
---
## Tasks
### v1
- [ ] completedなので出ないはず
EOF
}

mk_note_N8() {
  cat > "$1/Projects/proj-n8-older.md" <<'EOF'
---
date: 2026-08-01
updated: 2026-08-10
status: active
next: N8のnext値
---
## Tasks
### v1
- [ ] N8のタスク
EOF
}

# 全N群を1度に配置する（表示基底の Next Project 版として使う）。
mk_notes_N_all() {
  mk_note_N0 "$1"; mk_note_N1 "$1"; mk_note_N2 "$1"; mk_note_N3 "$1"
  mk_note_N4 "$1"; mk_note_N5 "$1"; mk_note_N6 "$1"; mk_note_N7 "$1"
  mk_note_N8 "$1"
}

# ==========================================================================
# S群: cmux スタブ（設計 §11.2 の契約・v1/v2 と同一挙動）
# ==========================================================================

# S-1: 正常応答するスタブを $1（実行可能ファイルのパス）へ書く。制御は
# $STUB_STATE（呼び出し元が export した環境変数）配下のファイルで行う。
# S-2〜S-5 はこのスタブが $STUB_STATE 配下のマーカーファイルで切り替える
# （fail_identify・fail_workspace_list・broken_identify・
# broken_workspace_list・hang_<sub>・term_ignoring_hang_<sub>〈副産物
# term_ignoring_grandchild_pid にTERM無視の子孫PIDを記録〉）。
write_cmux_stub() {
  local bin="$1"
  cat > "$bin" <<'STUB'
#!/bin/bash
STATE="$STUB_STATE"
echo "cmux $*" >> "$STATE/calls.log"
[ -n "${AGGREGATE_CALLS_LOG:-}" ] && echo "cmux $*" >> "$AGGREGATE_CALLS_LOG"

sub2=""
[ "$1" = "--json" ] && sub2="$2"

if [ -n "$sub2" ] && [ -e "$STATE/term_ignoring_hang_$sub2" ]; then
  # TERMを無視する子孫（本体は無視しない）を先に作ってからハングする
  # （run_with_timeout の回帰用・scripts/session-handoff.sh 側の同型fixture
  # に合わせる。本体はTERMで通常どおり終了するが、子孫はTERM無視のため
  # 生き残りうる＝wait後にKILLを送らないと孤児化する）。
  ( trap '' TERM; sleep 60 ) &
  echo "$!" > "$STATE/term_ignoring_grandchild_pid"
  sleep 60
  exit 1
fi

if [ -n "$sub2" ] && [ -e "$STATE/hang_$sub2" ]; then
  echo "$$" >> "$STATE/hang_pids"
  sleep 60 & child=$!
  echo "$child" >> "$STATE/hang_pids"
  wait "$child"
  exit 1
fi

if [ "$1" = "--json" ] && [ "$2" = "identify" ]; then
  [ -e "$STATE/fail_identify" ] && exit 9
  if [ -e "$STATE/broken_identify" ]; then
    printf '{"focused":{"workspace_ref":"workspace:1"'
    exit 0
  fi
  focused_ref="$(cat "$STATE/focused_ref" 2>/dev/null)"
  caller_ref="$(cat "$STATE/caller_ref" 2>/dev/null)"
  printf '{"focused":{"workspace_ref":"%s"},"caller":{"workspace_ref":"%s"}}\n' "$focused_ref" "$caller_ref"
  exit 0
fi

if [ "$1" = "--json" ] && [ "$2" = "workspace" ] && [ "$3" = "list" ]; then
  win=""
  shift 3
  while [ $# -gt 0 ]; do
    case "$1" in --window) win="$2"; shift 2 ;; *) shift ;; esac
  done
  [ -e "$STATE/fail_workspace_list" ] && exit 9
  if [ -e "$STATE/broken_workspace_list" ]; then
    printf '{"workspaces":"not-an-array"}'
    exit 0
  fi
  if [ -n "$win" ]; then
    [ -e "$STATE/fail_workspace_list.$win" ] && exit 9
    f="$STATE/workspaces.$win.json"
    [ -f "$f" ] || exit 9
    cat "$f"
    exit 0
  fi
  [ -f "$STATE/workspaces.json" ] || exit 9
  cat "$STATE/workspaces.json"
  exit 0
fi

if [ "$1" = "--json" ] && [ "$2" = "list-windows" ]; then
  [ -e "$STATE/fail_list_windows" ] && exit 9
  [ -f "$STATE/windows.json" ] || exit 9
  cat "$STATE/windows.json"
  exit 0
fi

if [ "$1" = "list-windows" ]; then
  exit 9
fi

case "$1 $2" in
  "todo "*|"--json todo"*) exit 9 ;;
esac
case "$*" in
  *set-status*|*clear-status*|*set-progress*|*"workspace status set"*|*new-pane*|*new-surface*)
    exit 9 ;;
esac

echo "unhandled: $*" >&2
exit 9
STUB
  chmod +x "$bin"
}

# S-1 の既定状態（focused=caller=workspace:1、UUID-AAA のみ）へ戻す。
# $1 = STUB_STATE ディレクトリ
reset_stub_state() {
  local state="$1"
  rm -rf "$state"
  mkdir -p "$state"
  echo "workspace:1" > "$state/focused_ref"
  echo "workspace:1" > "$state/caller_ref"
  cat > "$state/workspaces.json" <<'JSON'
{"workspaces":[{"id":"UUID-AAA","ref":"workspace:1"}]}
JSON
}

# ==========================================================================
# F群: 外部脳ログ fixture（棚卸し・週次メンテ）
# ==========================================================================

# 棚卸しの正本 latest.json（design-step2 §3.1/§6.1・書き手=vault_inventory.py）
# を模す。$1=INVENTORY_DIR $2=日付(YYYY-MM-DD) $3=actionable件数。
mk_inventory_report() {
  local dir="$1" date="$2" count="$3"
  mkdir -p "$dir"
  printf '{"date":"%s","actionable":%s}\n' "$date" "$count" > "$dir/latest.json"
}

# latest.json は存在するが actionable キーが無い（形式が変わり抽出できない
# ＝棚卸し n/a・design-step2 §6.3）。
mk_inventory_report_noparse() {
  local dir="$1" date="$2"
  mkdir -p "$dir"
  printf '{"date":"%s"}\n' "$date" > "$dir/latest.json"
}

# 週次メンテの実行記録（last-run.json）。
# $1=出力先ファイル $2=last_success_at（ISO8601 UTC・"Z"付き）
# $3=fragments_candidates（省略可・候補件数。design-step2 §3.2 S9 A-3）。
mk_maintenance_state() {
  local file="$1" ts="$2" cand="${3:-}"
  mkdir -p "$(dirname "$file")"
  if [ -n "$cand" ]; then
    printf '{"last_success_at":"%s","fragments_candidates":%s}\n' "$ts" "$cand" > "$file"
  else
    printf '{"last_success_at":"%s"}\n' "$ts" > "$file"
  fi
}

# ==========================================================================
# T群: タイミング（v2 design §11.2 の足跡方式と同型・ハング検査用）
# ==========================================================================

# $1 のファイルにパターン($2)が現れるまで$3秒ポーリングする（0.1秒間隔）。
wait_for_pattern() {
  local file="$1" pattern="$2" timeout="$3" i
  local n=$(( timeout * 10 ))
  for ((i = 0; i < n; i++)); do
    if [ -f "$file" ] && grep -qF -- "$pattern" "$file" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# ==========================================================================
# K群: 機の構成（FR-85・隔離 HOME）
# ==========================================================================
# 呼び出し側が用意した隔離 HOME（$1）に、ai-env 実体（symlink）・宣言記録
# （W-1）・cmux スタブ（PATH 経由）を配置する（K-1・K-2・K-3 の共通部）。
# AIENV_REPO_ROOT はテストが解決した ai-env 実 repo の絶対パス。
mk_k_common() {
  local fh="$1" aienv_repo="$2"
  mkdir -p "$fh/work" "$fh/.config/cmux-task-watch"
  ln -s "$aienv_repo" "$fh/work/takumi009-ai-env"
  mk_decl_single "cmux-session-todo" "$fh/.config/cmux-task-watch/workspaces.json"
}

# K-3: 上記に加えて dotfiles 実体（symlink）を配置する。
mk_k_add_dotfiles() {
  local fh="$1" dotfiles_repo="$2"
  ln -s "$dotfiles_repo" "$fh/work/dotfiles"
}

# K-4: dotfiles だけを配置する（$fh/work/takumi009-ai-env は 1 バイトも
# 作らない＝AC-107 の前提）。mk_k_common は呼ばないこと。
mk_k_dotfiles_only() {
  local fh="$1" dotfiles_repo="$2"
  mkdir -p "$fh/work"
  ln -s "$dotfiles_repo" "$fh/work/dotfiles"
}
