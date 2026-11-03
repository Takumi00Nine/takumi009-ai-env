#!/bin/bash
# fixture Vault と偽 cmux で、宣言・解除・prune の非破壊性を確認する。

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../dock/executor/cmux-task-declare.sh"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-task-declare-test.XXXXXX")" || {
  echo "FATAL: mktemp -d に失敗しました" >&2
  exit 1
}
trap 'rm -rf "$WORKDIR"' EXIT

STUB_STATE="$WORKDIR/stubstate"
STUBBIN="$WORKDIR/stubbin"
VAULT="$WORKDIR/vault"
mkdir -p "$STUB_STATE" "$STUBBIN" "$VAULT/Projects"

PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$(( PASS + 1 ))
  else
    FAIL=$(( FAIL + 1 ))
    echo "FAIL: $desc"
    echo "  expected: [$expected]"
    echo "  actual:   [$actual]"
  fi
}

assert_true() {
  local desc="$1" cond="$2"
  if [ "$cond" = "1" ]; then
    PASS=$(( PASS + 1 ))
  else
    FAIL=$(( FAIL + 1 ))
    echo "FAIL: $desc"
  fi
}

cat > "$STUBBIN/cmux" <<'STUB'
#!/bin/bash
STATE="$STUB_STATE"
echo "cmux $*" >> "$STATE/calls.log"

if [ "$1" = "--json" ] && [ "$2" = "identify" ]; then
  [ -e "$STATE/fail_identify" ] && exit 9
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

case "$*" in
  *todo*|*set-status*|*clear-status*|*set-progress*|*"workspace status set"*|*new-pane*|*new-surface*)
    exit 9 ;;
esac

echo "unhandled: $*" >&2
exit 9
STUB
chmod +x "$STUBBIN/cmux"

export CMUX_TASK_CMUX_BIN="$STUBBIN/cmux"
export STUB_STATE

reset_stub_state() {
  rm -rf "$STUB_STATE"
  mkdir -p "$STUB_STATE"
  echo "workspace:1" > "$STUB_STATE/focused_ref"
  echo "workspace:1" > "$STUB_STATE/caller_ref"
  cat > "$STUB_STATE/workspaces.json" <<'JSON'
{"workspaces":[{"id":"UUID-AAA","ref":"workspace:1"}]}
JSON
}
STATE_FILE="$WORKDIR/decl.json"

run_declare() {
  CMUX_TASK_VAULT="$VAULT" CMUX_TASK_STATE="$STATE_FILE" bash "$TARGET" "$@"
}

# A15（段階1・設計 §2/§10）: ノートを先に用意し、Tasks が見出しだけの
# 初期ノートでも案件画面へ宣言できる。親の起動自体はこの CLI の責務外。
echo "=== A15: 初期ノートの存在確認から案件宣言へ ==="
reset_stub_state
rc=0
run_declare set stage1-example >/dev/null 2>&1 || rc=$?
assert_true "A15: ノート不在なら宣言せず、cmux の照会にも進まない" \
  "$([ "$rc" -ne 0 ] && [ ! -e "$STATE_FILE" ] && [ ! -s "$STUB_STATE/calls.log" ] && echo 1 || echo 0)"
cat > "$VAULT/Projects/stage1-example.md" <<'EOF'
---
date: 2026-01-01
status: active
next: 親の作業一覧作成待ち
---
## 目的
試験用の成果物を作る。
## 守ること
試験用の案件フォルダを使う。
## 今どこ・次に何を
目的とゴールが決まり、親の作業一覧作成を待っている。
## 正本の所在
案件フォルダ: ./stage1-example/
## Tasks
EOF
before="$(shasum -a 256 "$VAULT/Projects/stage1-example.md")"
rc=0
run_declare set stage1-example >/dev/null 2>&1 || rc=$?
assert_true "A15: Tasks が見出しだけでも宣言でき、ノートへ一覧を作り足さない" \
  "$([ "$rc" -eq 0 ] && [ "$(run_declare list)" = "$(printf 'UUID-AAA\tstage1-example')" ] \
     && [ "$before" = "$(shasum -a 256 "$VAULT/Projects/stage1-example.md")" ] && echo 1 || echo 0)"

echo "=== 宣言・解除 ==="
cat > "$VAULT/Projects/slug-a.md" <<'EOF'
---
date: 2026-01-01
---
- [ ] task
EOF
reset_stub_state
before="$(shasum -a 256 "$VAULT/Projects/slug-a.md")"
run_declare set slug-a
rc=$?
assert_true "set した UUID と slug が一覧に出る" "$([ "$rc" -eq 0 ] && [ "$(run_declare list)" = "$(printf 'UUID-AAA\tslug-a')" ] && echo 1 || echo 0)"
run_declare unset
rc=$?
assert_true "unset で宣言を解除する" "$([ "$rc" -eq 0 ] && [ -z "$(run_declare list)" ] && echo 1 || echo 0)"
assert_eq "Vault のノートは変更しない" "$before" "$(shasum -a 256 "$VAULT/Projects/slug-a.md")"

echo "=== 破損した記録は書き換えない ==="
printf 'not json' > "$STATE_FILE"
cp "$STATE_FILE" "$WORKDIR/before.json"
run_declare set slug-a >/dev/null 2>&1
rc=$?
assert_true "破損は拒否し元のバイトを保持" "$([ "$rc" -ne 0 ] && cmp -s "$STATE_FILE" "$WORKDIR/before.json" && echo 1 || echo 0)"

echo "=== prune は生存 workspace を残す ==="
printf '{"version":1,"workspaces":{"UUID-AAA":"slug-a","UUID-DEAD":"slug-dead"}}' > "$STATE_FILE"
printf '[{"id":"win:1","index":0}]' > "$STUB_STATE/windows.json"
cp "$STUB_STATE/workspaces.json" "$STUB_STATE/workspaces.win:1.json"
run_declare prune >/dev/null
rc=$?
assert_true "prune は消滅した workspace だけ削除" "$([ "$rc" -eq 0 ] && [ "$(run_declare list)" = "$(printf 'UUID-AAA\tslug-a')" ] && echo 1 || echo 0)"
touch "$STUB_STATE/fail_workspace_list"
cp "$STATE_FILE" "$WORKDIR/before.json"
run_declare prune >/dev/null 2>&1
rc=$?
assert_true "cmux 取得失敗なら prune は非破壊" "$([ "$rc" -ne 0 ] && cmp -s "$STATE_FILE" "$WORKDIR/before.json" && echo 1 || echo 0)"

echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
exit $?
