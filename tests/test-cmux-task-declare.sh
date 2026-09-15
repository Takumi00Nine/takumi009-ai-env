#!/bin/bash
# cmux-task-declare.sh のユニットテスト（cmux-session-todo 設計 §11.1 D層）。
# 実 Vault・実ワークスペース・実 cmux には一切触れない。cmux 呼び出しは
# $WORKDIR/stubbin/cmux（スタブ）へ差し替える（§11.2 の契約）。
#
# 実行方法: bash tests/test-cmux-task-declare.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../cmux/cmux-task-declare.sh"
WATCH_TARGET="$SCRIPT_DIR/../cmux/cmux-task-model.sh"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-task-declare-test.XXXXXX")" || {
  echo "FATAL: mktemp -d に失敗しました" >&2
  exit 1
}
trap 'rm -rf "$WORKDIR"' EXIT

STUB_STATE="$WORKDIR/stubstate"
STUBBIN="$WORKDIR/stubbin"
VAULT="$WORKDIR/vault"
# テスト計測用ログはSTATE_FILE（$WORKDIR/decl.json）と同じ階層に置かない
# （AC-40が「記録ディレクトリに記録ファイル以外の生成物が無い」を
# $WORKDIR直下のfind -maxdepth 1で見るため。専用サブディレクトリへ隔離）。
TESTMETA_DIR="$WORKDIR/testmeta"
mkdir -p "$STUB_STATE" "$STUBBIN" "$VAULT/Projects" "$TESTMETA_DIR"

# AC-34用: reset_stub_state（mk_declare_base経由でも呼ばれる）で消える
# $STUB_STATE/calls.log とは別に、ファイル全体の実行を通して1本の集約ログ
# を残す（verifierレビュー1巡目 #4対応）。
AGGREGATE_CALLS_LOG="$TESTMETA_DIR/aggregate_calls.log"
: > "$AGGREGATE_CALLS_LOG"
export AGGREGATE_CALLS_LOG

# AC-33用: $VAULT の全ファイルの内容とmtimeのスナップショット。名前・mtime・
# サイズだけでは内容の書換えを検知できない（verifier実装レビュー2巡目
# #10・MAJOR）ため、内容ハッシュ（shasum -a 256）を各行へ追加する。
vault_snapshot() {
  find "$VAULT" -type f -print 2>/dev/null | sort | while IFS= read -r f; do
    printf '%s %s\n' \
      "$(stat -f '%N %m %z' "$f" 2>/dev/null)" \
      "$(shasum -a 256 "$f" 2>/dev/null | awk '{print $1}')"
  done
}

# AC-33の違反をファイルへ集約する（bash3.2の罠: run_declare は
# `lst="$(declare_list)"` のように $(...) 経由で呼ばれることがあり、その
# ときは関数全体がサブシェルで走ってグローバル変数への書込みが呼び出し元
# に伝わらない＝Knowledge/bash32-strict-mode-pitfalls.md #5。ファイルへの
# 追記ならサブシェル境界を跨いでも失われない）。
VAULT_MUTATION_LOG_FILE="$TESTMETA_DIR/vault_mutations.log"
: > "$VAULT_MUTATION_LOG_FILE"
check_vault_unchanged() {
  local label="$1" before="$2" after="$3"
  if [ "$before" != "$after" ]; then
    echo "$label" >> "$VAULT_MUTATION_LOG_FILE"
  fi
}

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

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    PASS=$(( PASS + 1 ))
  else
    FAIL=$(( FAIL + 1 ))
    echo "FAIL: $desc"
    echo "  期待した文字列が見つかりません: $needle"
  fi
}

# ==========================================================================
# cmux スタブ（test-cmux-task-watch.sh と同一契約＝設計 §11.2）
# ==========================================================================
cat > "$STUBBIN/cmux" <<'STUB'
#!/bin/bash
STATE="$STUB_STATE"
echo "cmux $*" >> "$STATE/calls.log"
[ -n "${AGGREGATE_CALLS_LOG:-}" ] && echo "cmux $*" >> "$AGGREGATE_CALLS_LOG"

sub2=""
[ "$1" = "--json" ] && sub2="$2"

if [ -n "$sub2" ] && [ -e "$STATE/hang_$sub2" ]; then
  echo "$$" >> "$STATE/hang_pids"
  sleep 60 & child=$!
  echo "$child" >> "$STATE/hang_pids"
  wait "$child"
  exit 1
fi

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

# ==========================================================================
# 宣言基底（W-0・M-1・S-1・F-1）: UUID-AAA未宣言。slug-a・slug-bのノートあり。
# ==========================================================================
mk_declare_base() {
  reset_stub_state
  rm -f "$STATE_FILE"
  cat > "$VAULT/Projects/slug-a.md" <<'EOF'
---
date: 2026-01-01
---
## Tasks

### v1
- [ ] task
EOF
  cat > "$VAULT/Projects/slug-b.md" <<'EOF'
---
date: 2026-01-01
---
## Tasks

### v1
- [ ] task
EOF
}

STATE_FILE="$WORKDIR/decl.json"
# 呼び出しのたびに $VAULT の前後差分を取る（verifierレビュー1巡目 #4対応。
# AC-33を「最後の1回」ではなくこのファイルが実行する全fixtureへ広げる）。
run_declare() {
  run_declare_with_state "$STATE_FILE" "$@"
}

# 汎用版: stateパスを明示指定してsnapshot付きで実行する（verifier実装
# レビュー3巡目 #13対応。AC-40/42/43がRODIR等の別stateパスを直接実行して
# おり、その経路だけ$VAULTスナップショット比較を通っていなかったため、
# 対象スクリプトの全実行をこの経路へ統一する。$1=stateパス、以降は実行
# コマンド）。
run_declare_with_state() {
  local state="$1"; shift
  local before after rc
  before="$(vault_snapshot)"
  CMUX_TASK_VAULT="$VAULT" CMUX_TASK_STATE="$state" "$@"
  rc=$?
  after="$(vault_snapshot)"
  check_vault_unchanged "run_declare_with_state($state): $*" "$before" "$after"
  return "$rc"
}

# AC-41/AC-43/DT-5 が供給側（cmux-task-model.sh）を直接呼ぶ箇所も同じ前後
# 差分検査の対象にする（D+U複合ACなので、こちらのファイルでも$VAULTの
# 不変を見る）。v3では常駐（--plain --once）が無いため --frame を使う。
# フレームが理由フレーム（R行を持つ）なら理由文字列だけを返し（v1/v2の
# 「理由行1行がそのまま出る」契約と同じ形で比較できるようにする）、通常
# フレームならフレーム全文を返す（"slug-a" 等の contains 検査はヘッダー
# 行の中の値に対して行える）。
run_watch_plain() {
  local before after out reason
  before="$(vault_snapshot)"
  out="$(CMUX_TASK_VAULT="$VAULT" CMUX_TASK_STATE="$STATE_FILE" \
    bash "$WATCH_TARGET" --frame)"
  after="$(vault_snapshot)"
  check_vault_unchanged "run_watch_plain" "$before" "$after"
  reason="$(printf '%s\n' "$out" | awk -F '\t' '$1=="R"{print $2}')"
  if [ -n "$reason" ]; then
    printf '%s' "$reason"
  else
    printf '%s' "$out"
  fi
}

declare_list() {
  run_declare bash "$TARGET" list
}

# ==========================================================================
# AC-19〜22: 宣言基底
# ==========================================================================
echo "=== AC-19: 未宣言からslug-aを宣言 ==="
mk_declare_base
run_declare bash "$TARGET" set slug-a
rc=$?
assert_eq "AC-19: setが成功する" "0" "$rc"
assert_true "AC-19: 記録ファイルが新規に作られる" "$([ -f "$STATE_FILE" ] && echo 1 || echo 0)"
lst="$(declare_list)"
assert_eq "AC-19: 一覧にUUIDとslug-aの対が1つだけ" "UUID-AAA	slug-a" "$lst"

echo "=== AC-20: 続けてslug-bを宣言すると入れ替わる ==="
mk_declare_base
run_declare bash "$TARGET" set slug-a
run_declare bash "$TARGET" set slug-b
lst="$(declare_list)"
assert_eq "AC-20: slug-bに入れ替わり対は1つのまま" "UUID-AAA	slug-b" "$lst"

echo "=== AC-21: 宣言→確認→解除 ==="
mk_declare_base
before_vault="$(find "$VAULT" -type f -exec stat -f '%N %m %z' {} \; | sort)"
run_declare bash "$TARGET" set slug-a
lst="$(declare_list)"
assert_eq "AC-21: 解除前に一覧が1件" "UUID-AAA	slug-a" "$lst"
run_declare bash "$TARGET" unset
unset_rc=$?
lst_after="$(declare_list)"
assert_eq "AC-21: unsetが成功する" "0" "$unset_rc"
assert_eq "AC-21: 解除後に一覧が空" "" "$lst_after"
after_vault="$(find "$VAULT" -type f -exec stat -f '%N %m %z' {} \; | sort)"
assert_eq "AC-21: fixture Vaultが不変" "$before_vault" "$after_vault"
write_cmds="$(grep -E 'todo|set-status|clear-status|set-progress|workspace status set|new-pane|new-surface' "$STUB_STATE/calls.log" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "AC-21: cmuxスタブに書込系の記録が無い" "0" "$write_cmds"

echo "=== AC-22: W-4（無効slug×2）がrc=4（setの拒否）・記録バイト一致 ==="
mk_declare_base
run_declare bash "$TARGET" set slug-a
before="$(cat "$STATE_FILE")"
run_declare bash "$TARGET" set "../evil-slug"
rc1=$?
run_declare bash "$TARGET" set "no-such-note-slug"
rc2=$?
after="$(cat "$STATE_FILE")"
assert_eq "AC-22: 無効slug操作①がrc=4（拒否・D-17）" "4" "$rc1"
assert_eq "AC-22: 無効slug操作②がrc=4（拒否・D-17）" "4" "$rc2"
assert_eq "AC-22: 記録ファイルが操作前後でバイト一致" "$before" "$after"

echo "=== AC-23(D側): refが振り直っても --workspace 解決は同一UUIDに落ちる ==="
mk_declare_base
cat > "$STUB_STATE/workspaces.json" <<'JSON'
{"workspaces":[{"id":"UUID-AAA","ref":"workspace:7"}]}
JSON
echo "workspace:7" > "$STUB_STATE/caller_ref"
run_declare bash "$TARGET" set slug-a
lst="$(declare_list)"
assert_eq "AC-23(D側): 振り直り後もUUID-AAAへ解決される" "UUID-AAA	slug-a" "$lst"
reset_stub_state

echo "=== §3.3(D側)回帰: --workspace <index> は配列位置ではなく.indexで解決（verifier実装レビュー2巡目 #9） ==="
mk_declare_base
# 配列順とindex値をわざとずらす（配列位置0=index2, 位置1=index0, 位置2=index1）。
# 旧実装（配列位置を1始まりのindexとみなす）だと --workspace 0 は
# jqの負インデックス（配列末尾）に化けてUUID-BBBへ誤解決していた。
cat > "$STUB_STATE/workspaces.json" <<'JSON'
{"workspaces":[
  {"id":"UUID-CCC","ref":"workspace:3","index":2},
  {"id":"UUID-AAA","ref":"workspace:1","index":0},
  {"id":"UUID-BBB","ref":"workspace:2","index":1}
]}
JSON
run_declare bash "$TARGET" set slug-a --workspace 0
run_declare bash "$TARGET" set slug-b --workspace 1
lst="$(declare_list)"
assert_eq "回帰#9: --workspace 0 はindex=0のUUID-AAAへ・--workspace 1 はindex=1のUUID-BBBへ" \
  "UUID-AAA	slug-a
UUID-BBB	slug-b" "$lst"
reset_stub_state

# ==========================================================================
# AC-40〜44
# ==========================================================================
echo "=== AC-40: 成功時に残骸なし・途中失敗時に旧内容が残る ==="
mk_declare_base
run_declare bash "$TARGET" set slug-a
extra="$(find "$(dirname "$STATE_FILE")" -maxdepth 1 -type f ! -name "$(basename "$STATE_FILE")" | wc -l | tr -d ' ')"
assert_eq "AC-40: 成功後に記録ディレクトリへ余分な生成物が無い" "0" "$extra"

RODIR="$WORKDIR/ro-state"
rm -rf "$RODIR"; mkdir -p "$RODIR"
cat > "$RODIR/workspaces.json" <<'JSON'
{"version":1,"workspaces":{"UUID-AAA":"slug-a"}}
JSON
cp "$RODIR/workspaces.json" "$RODIR/before.json"
chmod 0500 "$RODIR"
run_declare_with_state "$RODIR/workspaces.json" bash "$TARGET" set slug-b
fail_rc=$?
chmod 0700 "$RODIR"
assert_eq "AC-40: 書込不可ディレクトリではrc=3（内部エラー・D-17）" "3" "$fail_rc"
assert_eq "AC-40: 記録が旧内容のまま読める" "$(cat "$RODIR/before.json")" "$(cat "$RODIR/workspaces.json")"
leftover="$(find "$RODIR" -maxdepth 1 -name '.workspaces.json.*' | wc -l | tr -d ' ')"
assert_eq "AC-40: 途中失敗でも一時ファイルの残骸が無い" "0" "$leftover"

echo "--- AC-40補強: unset/pruneでも書込不可でrc=3・記録が旧内容のまま ---"
RODIR2="$WORKDIR/ro-state-unset"
rm -rf "$RODIR2"; mkdir -p "$RODIR2"
cat > "$RODIR2/workspaces.json" <<'JSON'
{"version":1,"workspaces":{"UUID-AAA":"slug-a"}}
JSON
cp "$RODIR2/workspaces.json" "$RODIR2/before.json"
chmod 0500 "$RODIR2"
run_declare_with_state "$RODIR2/workspaces.json" bash "$TARGET" unset
unset_fail_rc=$?
chmod 0700 "$RODIR2"
assert_eq "AC-40補強: unsetも書込不可でrc=3" "3" "$unset_fail_rc"
assert_eq "AC-40補強: unset失敗時も記録が旧内容のまま" "$(cat "$RODIR2/before.json")" "$(cat "$RODIR2/workspaces.json")"

RODIR3="$WORKDIR/ro-state-prune"
rm -rf "$RODIR3"; mkdir -p "$RODIR3"
cat > "$RODIR3/workspaces.json" <<'JSON'
{"version":1,"workspaces":{"UUID-DEAD":"slug-dead"}}
JSON
cp "$RODIR3/workspaces.json" "$RODIR3/before.json"
cat > "$STUB_STATE/windows.json" <<'JSON'
[{"id":"win:1","index":0}]
JSON
cat > "$STUB_STATE/workspaces.win:1.json" <<'JSON'
{"workspaces":[{"id":"UUID-AAA","ref":"workspace:1"}]}
JSON
chmod 0500 "$RODIR3"
run_declare_with_state "$RODIR3/workspaces.json" bash "$TARGET" prune
prune_fail_rc=$?
chmod 0700 "$RODIR3"
assert_eq "AC-40補強: pruneも書込不可でrc=3" "3" "$prune_fail_rc"
assert_eq "AC-40補強: prune失敗時も記録が旧内容のまま" "$(cat "$RODIR3/before.json")" "$(cat "$RODIR3/workspaces.json")"

echo "=== AC-41: 記録破損時は理由行1行＋記録が前後でバイト一致（D+U） ==="
mk_declare_base
run_declare bash "$TARGET" set slug-a
printf 'not json' > "$STATE_FILE"
before_corrupt="$(cat "$STATE_FILE")"
watch_out="$(run_watch_plain)"
assert_eq "AC-41: cmux-task-watch.shが理由行1行を出す" "宣言記録破損" "$watch_out"
after_corrupt="$(cat "$STATE_FILE")"
assert_eq "AC-41: 記録ファイルが実行前後でバイト一致" "$before_corrupt" "$after_corrupt"
run_declare bash "$TARGET" list >/dev/null 2>&1
list_rc=$?
assert_eq "AC-41: listはrc=2（記録破損）で拒否する" "2" "$list_rc"

echo "=== AC-42: prune（W-8×S-1・W-8×S-3） ==="
mk_declare_base
cat > "$STATE_FILE" <<'JSON'
{"version":1,"workspaces":{"UUID-AAA":"slug-a","UUID-DEAD":"slug-dead"}}
JSON
cat > "$STUB_STATE/windows.json" <<'JSON'
[{"id":"win:1","index":0}]
JSON
cat > "$STUB_STATE/workspaces.win:1.json" <<'JSON'
{"workspaces":[{"id":"UUID-AAA","ref":"workspace:1"}]}
JSON
run_declare bash "$TARGET" prune
prune_rc=$?
lst="$(declare_list)"
assert_eq "AC-42: W-8×S-1 成功時にrc=0" "0" "$prune_rc"
assert_eq "AC-42: 生存1件のみ残る" "UUID-AAA	slug-a" "$lst"

mk_declare_base
cat > "$STATE_FILE" <<'JSON'
{"version":1,"workspaces":{"UUID-AAA":"slug-a","UUID-DEAD":"slug-dead"}}
JSON
cat > "$STUB_STATE/windows.json" <<'JSON'
[{"id":"win:1","index":0}]
JSON
touch "$STUB_STATE/fail_workspace_list"
before_s3="$(cat "$STATE_FILE")"
run_declare bash "$TARGET" prune
prune_rc2=$?
after_s3="$(cat "$STATE_FILE")"
assert_eq "AC-42: W-8×S-3 失敗時にrc=1（接続不可）" "1" "$prune_rc2"
assert_eq "AC-42: W-8×S-3 で2件とも残る（バイト一致）" "$before_s3" "$after_s3"
rm -f "$STUB_STATE/fail_workspace_list"

echo "=== AC-43: 別プロセスとして起動し直しても解決される（D+U） ==="
mk_declare_base
run_declare bash "$TARGET" set slug-a
lst1="$(run_declare bash "$TARGET" list)"
lst2="$(run_declare bash "$TARGET" list)"
assert_eq "AC-43: 別プロセスでも同じ宣言が解決される" "$lst1" "$lst2"
watch_out1="$(run_watch_plain)"
assert_contains "AC-43: cmux-task-watch.shの表示にslug-aが現れる" "$watch_out1" "slug-a"

# ==========================================================================
# DT-3: prune の全ウィンドウ列挙と取得失敗（4ケース）
# ==========================================================================
echo "=== DT-3: prune の全ウィンドウ列挙と取得失敗 ==="
setup_dt3_record() {
  cat > "$STATE_FILE" <<'JSON'
{"version":1,"workspaces":{"UUID-W1":"slug-a","UUID-W2":"slug-b","UUID-DEAD":"slug-dead"}}
JSON
}
setup_dt3_windows() {
  rm -f "$STUB_STATE/fail_list_windows" "$STUB_STATE/fail_workspace_list"
  rm -f "$STUB_STATE/fail_workspace_list.win:1" "$STUB_STATE/fail_workspace_list.win:2"
  cat > "$STUB_STATE/windows.json" <<'JSON'
[{"id":"win:1","index":0},{"id":"win:2","index":1}]
JSON
  cat > "$STUB_STATE/workspaces.win:1.json" <<'JSON'
{"workspaces":[{"id":"UUID-W1","ref":"workspace:1"}]}
JSON
  cat > "$STUB_STATE/workspaces.win:2.json" <<'JSON'
{"workspaces":[{"id":"UUID-W2","ref":"workspace:1"}]}
JSON
}

echo "--- ① 正常: 2件残り1件だけ消える ---"
mk_declare_base
setup_dt3_record
setup_dt3_windows
rm -f "$STUB_STATE/calls.log"
out1="$(run_declare bash "$TARGET" prune)"
lst="$(declare_list)"
assert_eq "DT-3①: 記録が2件残る" "UUID-W1	slug-a
UUID-W2	slug-b" "$lst"
assert_eq "DT-3①: 消えた対がstdoutに出る" "UUID-DEAD	slug-dead" "$out1"

echo "--- ② 2窓目だけ失敗: 3件とも残る・部分成功の痕跡がある ---"
mk_declare_base
setup_dt3_record
setup_dt3_windows
touch "$STUB_STATE/fail_workspace_list.win:2"
rm -f "$STUB_STATE/calls.log"
before2="$(cat "$STATE_FILE")"
run_declare bash "$TARGET" prune
rc2=$?
after2="$(cat "$STATE_FILE")"
assert_eq "DT-3②: rc=1（接続不可）" "1" "$rc2"
assert_eq "DT-3②: 3件とも残る（バイト一致）" "$before2" "$after2"
assert_true "DT-3②: win:1のworkspace list成功呼び出しがログに残る" \
  "$(grep -qF 'workspace list --window win:1' "$STUB_STATE/calls.log" && echo 1 || echo 0)"
rm -f "$STUB_STATE/fail_workspace_list.win:2"

echo "--- ③ 全workspace list失敗: 3件とも残る ---"
mk_declare_base
setup_dt3_record
setup_dt3_windows
touch "$STUB_STATE/fail_workspace_list"
before3="$(cat "$STATE_FILE")"
run_declare bash "$TARGET" prune
rc3=$?
after3="$(cat "$STATE_FILE")"
assert_eq "DT-3③: rc=1（接続不可）" "1" "$rc3"
assert_eq "DT-3③: 3件とも残る" "$before3" "$after3"
rm -f "$STUB_STATE/fail_workspace_list"

echo "--- ④ ウィンドウ列挙が失敗: 3件とも残る・workspace list呼び出しが0件 ---"
mk_declare_base
setup_dt3_record
setup_dt3_windows
touch "$STUB_STATE/fail_list_windows"
rm -f "$STUB_STATE/calls.log"
before4="$(cat "$STATE_FILE")"
run_declare bash "$TARGET" prune
rc4=$?
after4="$(cat "$STATE_FILE")"
assert_eq "DT-3④: rc=1（接続不可）" "1" "$rc4"
assert_eq "DT-3④: 3件とも残る" "$before4" "$after4"
wl_calls="$(grep -c 'workspace list' "$STUB_STATE/calls.log" 2>/dev/null)"
[ -n "$wl_calls" ] || wl_calls=0
assert_eq "DT-3④: workspace list呼び出しが0件" "0" "$wl_calls"
rm -f "$STUB_STATE/fail_list_windows"

echo "--- ⑤ list-windowsが有効/不正混在配列（verifierレビュー#1・BLOCKING対応） ---"
mk_declare_base
setup_dt3_record
setup_dt3_windows
# id が null の不正要素を1件混ぜる。select除外方式だと有効なwin:1だけを
# 使って「成功」してしまい、不完全なalive集合で有効な宣言を消しうる
# （verifierレビュー1巡目 #1・BLOCKING）。all(...)検証なら全体が非0になり
# 1件も削除しないはず。
cat > "$STUB_STATE/windows.json" <<'JSON'
[{"id":"win:1","index":0},{"id":null,"index":1}]
JSON
before5="$(cat "$STATE_FILE")"
run_declare bash "$TARGET" prune
rc5=$?
after5="$(cat "$STATE_FILE")"
assert_eq "DT-3⑤: list-windowsに不正要素が混在→rc=1（接続不可）" "1" "$rc5"
assert_eq "DT-3⑤: 3件とも残る（不完全なalive集合で消さない）" "$before5" "$after5"

echo "--- ⑥ workspace listが有効/不正混在配列 ---"
mk_declare_base
setup_dt3_record
setup_dt3_windows
cat > "$STUB_STATE/workspaces.win:1.json" <<'JSON'
{"workspaces":[{"id":"UUID-W1","ref":"workspace:1"},{"id":123}]}
JSON
before6="$(cat "$STATE_FILE")"
run_declare bash "$TARGET" prune
rc6=$?
after6="$(cat "$STATE_FILE")"
assert_eq "DT-3⑥: workspace listに不正要素が混在→rc=1（接続不可）" "1" "$rc6"
assert_eq "DT-3⑥: 3件とも残る（不完全なalive集合で消さない）" "$before6" "$after6"

# ==========================================================================
# DT-5: 記録の複数JSON文
# ==========================================================================
echo "=== DT-5: 記録の複数JSON文（構文不正／2文連結） ==="
mk_declare_base

echo "--- ① 構文として不正 ---"
printf 'not json at all' > "$STATE_FILE"
before_a="$(cat "$STATE_FILE")"
watch_out_a="$(run_watch_plain)"
assert_eq "DT-5①: 常駐が宣言記録破損を出す" "宣言記録破損" "$watch_out_a"
run_declare bash "$TARGET" set slug-a
set_rc_a=$?
run_declare bash "$TARGET" unset
unset_rc_a=$?
after_a="$(cat "$STATE_FILE")"
assert_eq "DT-5①: setはrc=2（記録破損）" "2" "$set_rc_a"
assert_eq "DT-5①: unsetはrc=2（記録破損）" "2" "$unset_rc_a"
assert_eq "DT-5①: 記録がバイト一致のまま" "$before_a" "$after_a"

echo "--- ② 正しいJSON文が2つ連結 ---"
printf '{"version":1,"workspaces":{}}\n{"version":1,"workspaces":{"X":"y"}}\n' > "$STATE_FILE"
before_b="$(cat "$STATE_FILE")"
watch_out_b="$(run_watch_plain)"
assert_eq "DT-5②: 常駐が宣言記録破損を出す" "宣言記録破損" "$watch_out_b"
run_declare bash "$TARGET" set slug-a
set_rc_b=$?
run_declare bash "$TARGET" unset
unset_rc_b=$?
after_b="$(cat "$STATE_FILE")"
assert_eq "DT-5②: setはrc=2（記録破損）" "2" "$set_rc_b"
assert_eq "DT-5②: unsetはrc=2（記録破損）" "2" "$unset_rc_b"
assert_eq "DT-5②: 記録がバイト一致のまま" "$before_b" "$after_b"

# ==========================================================================
# AC-33/AC-34（D側）
# ==========================================================================
echo "=== AC-33(D側): 全fixture実行を横断してfixture Vaultが不変 ==="
# verifierレビュー1巡目 #4対応: 「最後に作り直した基底の1回」だけでなく、
# run_declare・run_watch_plain がこのファイル冒頭から蓄積してきた前後差分
# （$VAULT_MUTATION_LOG_FILE）を、このファイルが実行した全fixture横断で
# まとめて判定する。
mk_declare_base
run_declare bash "$TARGET" set slug-a
run_declare bash "$TARGET" list >/dev/null
run_declare bash "$TARGET" unset
run_declare bash "$TARGET" prune >/dev/null 2>&1
mutation_count="$(wc -l < "$VAULT_MUTATION_LOG_FILE" | tr -d ' ')"
assert_eq "AC-33(D側): 全fixture実行を通してfixture Vaultへの書込が1件も無い" "0" "$mutation_count"

echo "=== AC-34(D側): 全fixture実行を横断して書込系コマンドが1度も呼ばれない ==="
# verifierレビュー1巡目 #4対応: ファイル冒頭から蓄積した集約ログ
# （$AGGREGATE_CALLS_LOG。reset_stub_stateで消える$STUB_STATE/calls.logとは
# 別）を使い、このファイルが実行した全fixtureを横断して検査する。
mk_declare_base
run_declare bash "$TARGET" set slug-a
run_declare bash "$TARGET" list >/dev/null
run_declare bash "$TARGET" unset
setup_dt3_record; setup_dt3_windows
run_declare bash "$TARGET" prune >/dev/null
write_cmds="$(grep -cE 'todo|set-status|clear-status|set-progress|workspace status set|new-pane|new-surface' "$AGGREGATE_CALLS_LOG" 2>/dev/null)"
[ -n "$write_cmds" ] || write_cmds=0
assert_eq "AC-34(D側): 全fixture実行を通して書込系コマンドが0件" "0" "$write_cmds"
total_calls="$(wc -l < "$AGGREGATE_CALLS_LOG" | tr -d ' ')"
assert_true "AC-34(D側): 集約ログにcmux呼出が記録されている（検査自体が空振りでない）" "$([ "$total_calls" -gt 0 ] && echo 1 || echo 0)"

echo ""
# AC-102（design.md 2614行）: 移設（ファイルの移動とLIB_DIRの書き換えだけ）の
# 完了条件は「本ファイルが全緑のまま」そのものであり、個別のAC-102専用
# assertionは要求していない。ここで判定式を明示的な独立assertへ落とす
# （検証1巡目 MAJOR #14対応: 「全緑だからAC-102も当然満たす」という暗黙の
# 対応付けではなく、PASS/FAILの集計をAC-102の合否として名指しで記録する）。
assert_eq "AC-102: 移設後もtest-cmux-task-declare.shが全緑（宣言CLIのlist/set/unset/pruneの契約がv2と一致）" "0" "$FAIL"
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
exit $?
