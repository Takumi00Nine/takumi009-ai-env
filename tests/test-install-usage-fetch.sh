#!/usr/bin/env bash
# scripts/install-usage-fetch.sh のユニットテスト（B1-b・使用率取得器移設。
# AC-98＝移行の検査。§6.2b の状態機械・drift 検査＝T-1〜T-18 のうち、安全に
# 直結する不変条件（INV-1〜INV-4）と主要な再開・巻き戻し経路を実測で検証する。
#
# ⚠️ 実 launchd には一切触れない。PATH スタブの偽 launchctl が状態
# （$LCTL_STATE/loaded/<label>・$LCTL_STATE/disabled/<label>）をファイルで
# 保持し、bootout/bootstrap/enable/disable/print/print-disabled に応答する
# （2026-06-30 の実launchd誤操作事故の再発防止＝test-install-maintenance.sh
# と同じ考え方をさらに状態遷移可能な形へ拡張）。各テストの後、実launchctlが
# 一度も呼ばれていないことを個別に確認はしないが、SKIP_LAUNCHCTL=1 の代わりに
# PATH スタブそのものを常に先頭に置くことで実launchdに触れない構造にしている
# （install-usage-fetch.sh 自体は SKIP_LAUNCHCTL を使わない通常経路のまま
# 検査できる＝本番同様の分岐を検査する）。
#
# 実行方法: bash tests/test-install-usage-fetch.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/install-usage-fetch.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }
assert_true() {
  local desc="$1" cond="$2"
  if [ "$cond" = "1" ]; then pass "$desc"; else fail_case "$desc"; fi
}
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then pass "$desc"; else fail_case "$desc (expected=$expected actual=$actual)"; fi
}

FAKE_BIN="$(mktemp -d)"
trap 'rm -rf "$FAKE_BIN"' EXIT

# --- 疑似launchctl（状態を持つ。bootout/bootstrap/enable/disable/print/print-disabled） ---
cat > "$FAKE_BIN/launchctl" <<'STUB'
#!/usr/bin/env bash
# 状態は $LCTL_STATE/loaded/<label>（存在=ロード済み）・
# $LCTL_STATE/disabled/<label>（存在=disabled）で表す。
: "${LCTL_STATE:?LCTL_STATE not set}"
mkdir -p "$LCTL_STATE/loaded" "$LCTL_STATE/disabled" "$LCTL_STATE/enabled" 2>/dev/null

label_of_plist() {
  plutil -extract Label raw -o - "$1" 2>/dev/null
}

case "$1" in
  print)
    target="$2"
    if [ "${LCTL_DOMAIN_UNKNOWN:-0}" = "1" ]; then exit 1; fi
    # "gui/<uid>/<label>"（ラベル指定）と"gui/<uid>"（ドメインのみ）を区別する。
    # 両方とも"/"を含むため、より具体的なパターンを先に評価する。
    case "$target" in
      gui/*/*)
        label="${target#gui/*/}"
        # ⚠️ 検証職2巡目BLOCKING-1回帰試験専用フック: 指定ラベルへの
        # print照会が「N回目」（既定2・LCTL_REVIVE_AFTER_QUERY_Nで変更可）に
        # なった時点で、それ以降loadedを返すように切り替える（実時間の待機
        # ではなく呼び出し回数で時系列を決定的に再現する）。
        # ⚠️ 検証職3巡目MAJOR対応: cmd_confirmはold_loaded()を計3回呼ぶ
        # （①入口のinv1_entry_check_or_die ②対話前 ③対話後・削除直前）。
        # 既定の2回目で復活させると②の対話前検査で先に拒否されてしまい、
        # ③の削除直前再観測（TOCTOU対策の本体）を一度も通らないまま
        # テストが「たまたま」成功していた（偽陽性）。LCTL_REVIVE_AFTER_QUERY_N
        # で3回目に変更し、②までは復活していない状態を維持したうえで③だけを
        # 狙い撃ちできるようにする。
        if [ "${LCTL_REVIVE_AFTER_SECOND_QUERY_FOR:-}" = "$label" ]; then
          count_file="$LCTL_STATE/.query_count_$label"
          count=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
          echo "$count" > "$count_file"
          threshold="${LCTL_REVIVE_AFTER_QUERY_N:-2}"
          if [ "$count" -ge "$threshold" ]; then
            : > "$LCTL_STATE/loaded/$label"
          fi
        fi
        [ -f "$LCTL_STATE/loaded/$label" ] && exit 0 || exit 1
        ;;
      gui/*)
        exit 0
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  print-disabled)
    if [ "${LCTL_PRINTDISABLED_FAIL:-0}" = "1" ]; then exit 1; fi
    # ⚠️ 検証職1巡目MAJOR-3対応: 実launchctlの封筒（`disabled services = {
    # ... }`）を模す（install-usage-fetch.sh側のdisabled_status()が
    # この封筒の有無で「解析できた」かどうかを判定するようになったため）。
    # LCTL_PRINTDISABLED_MALFORMED=1 のときは封筒を壊した出力を返す
    # （fail-closed=unknownになることを検査するテスト専用）。
    # LCTL_PRINTDISABLED_TRUNCATED=1 のときは終端の`}`を欠いた出力を返す
    # （検証職2巡目MAJOR-1対応の回帰試験専用）。
    # ⚠️ 検証職4巡目MAJOR対応: LCTL_PRINTDISABLED_MALFORMED_CLOSE=1 のとき
    # は、閉じ括弧が単独行ではなく（対象ラベルの後に他の文字と同じ行に
    # あり）末尾に非空のtrailerが続く「壊れた終端」を返す（reviewerの
    # 再現ケース＝開始行はあるが真の終端が無いまま出力が続く）。
    # LCTL_PRINTDISABLED_DUPLICATE_FOR=<label> のときは、対象ラベルを
    # enabled/disabledで重複させた封筒を返す（e2eでの重複競合fixture用）。
    if [ "${LCTL_PRINTDISABLED_MALFORMED:-0}" = "1" ]; then
      echo "not a valid launchctl output at all"
      exit 0
    fi
    if [ "${LCTL_PRINTDISABLED_MALFORMED_CLOSE:-0}" = "1" ]; then
      echo "disabled services = {"
      for f in "$LCTL_STATE/enabled"/*; do
        [ -e "$f" ] || continue
        printf '\t"%s" => enabled\n' "$(basename "$f")"
      done
      echo "malformed }"
      echo "trailer"
      exit 0
    fi
    if [ -n "${LCTL_PRINTDISABLED_DUPLICATE_FOR:-}" ]; then
      echo "disabled services = {"
      printf '\t"%s" => enabled\n' "$LCTL_PRINTDISABLED_DUPLICATE_FOR"
      printf '\t"%s" => disabled\n' "$LCTL_PRINTDISABLED_DUPLICATE_FOR"
      echo "}"
      exit 0
    fi
    # ⚠️ 検証職5巡目MAJOR対応: LCTL_PRINTDISABLED_LEADING_BRACE=1 のときは、
    # 正規の封筒の<u>前</u>に単独の'}'行を置いた出力を返す（reviewerの
    # 再現ケース＝開始行より前の単独'}'を無視して正常な封筒と誤認しない
    # ことを確認する回帰試験専用）。
    if [ "${LCTL_PRINTDISABLED_LEADING_BRACE:-0}" = "1" ]; then
      echo "}"
      echo "disabled services = {"
      for f in "$LCTL_STATE/enabled"/*; do
        [ -e "$f" ] || continue
        printf '\t"%s" => enabled\n' "$(basename "$f")"
      done
      echo "}"
      exit 0
    fi
    echo "disabled services = {"
    for f in "$LCTL_STATE/disabled"/*; do
      [ -e "$f" ] || continue
      printf '\t"%s" => disabled\n' "$(basename "$f")"
    done
    # ⚠️ 検証職2巡目MAJOR-1対応: 実launchdは一度でも`enable`が明示的に
    # 呼ばれたラベルを`=> enabled`として封筒に載せ続ける（一度も
    # enable/disableされていないラベルは封筒に一切現れない＝実機
    # launchctl print-disabledで実測確認済み。22件程度しか載らない一方、
    # ロード済みラベルは1000件超）。この区別を模すため、明示的にenableが
    # 呼ばれたラベルだけ`enabled/`ディレクトリへ記録し、封筒へ含める。
    for f in "$LCTL_STATE/enabled"/*; do
      [ -e "$f" ] || continue
      printf '\t"%s" => enabled\n' "$(basename "$f")"
    done
    if [ "${LCTL_PRINTDISABLED_TRUNCATED:-0}" != "1" ]; then
      echo "}"
    fi
    exit 0
    ;;
  bootout)
    target="$2"
    label="${target##*/}"
    if [ -f "$LCTL_STATE/fail_bootout_$label" ]; then
      exit 1
    fi
    rm -f "$LCTL_STATE/loaded/$label"
    exit 0
    ;;
  bootstrap)
    plistfile="$3"
    label="$(label_of_plist "$plistfile")"
    [ -n "$label" ] || exit 1
    if [ -f "$LCTL_STATE/fail_bootstrap_$label" ]; then
      exit 1
    fi
    : > "$LCTL_STATE/loaded/$label"
    # ⚠️ 検証職1巡目BLOCKING対応の回帰試験専用フック: 新ジョブのbootstrapが
    # 成功した直後に、外部要因（再ログイン・旧installerの再実行等）で旧が
    # 復活したのと同じ状況を1回だけ作る（「有効化する操作の直前に毎回検査
    # する」INV-1(b)の実装が、この直後の操作〈enable等〉を正しく拒否する
    # ことを検証するため）。
    if [ "${LCTL_REVIVE_OLD_ON_NEW_BOOTSTRAP:-0}" = "1" ] && [ "$label" = "$NEW_LABEL_FOR_REVIVE_HOOK" ] && [ ! -f "$LCTL_STATE/.revived_once" ]; then
      : > "$LCTL_STATE/.revived_once"
      : > "$LCTL_STATE/loaded/$OLD_LABEL_FOR_REVIVE_HOOK"
      # 復活＝再ロードなので、以前にenable済みだった扱いにする
      # （検証職2巡目MAJOR-1対応後の disabled_status() は「封筒に載って
      # いない」ことを enabled とはみなさなくなったため、実際に外部要因で
      # 復活したラベルが過去に一度でも明示enableされていたことを模す
      # 必要がある＝実機のcom.claude-codex-usage.refreshが
      # `=> enabled`として封筒に載り続けていた実測と同じ状況）。
      rm -f "$LCTL_STATE/disabled/$OLD_LABEL_FOR_REVIVE_HOOK"
      : > "$LCTL_STATE/enabled/$OLD_LABEL_FOR_REVIVE_HOOK"
    fi
    exit 0
    ;;
  enable)
    target="$2"
    label="${target##*/}"
    if [ -f "$LCTL_STATE/fail_enable_$label" ]; then
      exit 1
    fi
    rm -f "$LCTL_STATE/disabled/$label"
    : > "$LCTL_STATE/enabled/$label"
    exit 0
    ;;
  disable)
    target="$2"
    label="${target##*/}"
    rm -f "$LCTL_STATE/enabled/$label"
    : > "$LCTL_STATE/disabled/$label"
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
STUB
chmod +x "$FAKE_BIN/launchctl"
PATH="$FAKE_BIN:$PATH"
hash -r

NEW_LABEL="com.takumi009.usage-fetch"
OLD_LABEL="com.claude-codex-usage.refresh"

# --- fixture環境 ---
new_env() {
  local d
  d="$(mktemp -d)"
  mkdir -p "$d/home/Library/LaunchAgents" "$d/state" "$d/oldrepo" "$d/cache" "$d/lctl"
  # 旧repoの最小構成（refresh.sh・install.sh・表示2本）
  cat > "$d/oldrepo/refresh.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$d/oldrepo/refresh.sh"
  cat > "$d/oldrepo/install.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$d/oldrepo/install.sh"
  cat > "$d/oldrepo/tmux-usage.sh" <<'EOF'
#!/bin/sh
echo "tmux-usage stub"
EOF
  chmod +x "$d/oldrepo/tmux-usage.sh"
  cat > "$d/oldrepo/cmux-usage-watch.sh" <<'EOF'
#!/bin/sh
echo "cmux-usage-watch stub"
EOF
  chmod +x "$d/oldrepo/cmux-usage-watch.sh"
  echo "$d"
}

run_install() {
  local d="$1"; shift
  HOME="$d/home" \
    AIENV_USAGE_MIGRATION_STATE_DIR="$d/state" \
    AIENV_USAGE_OLD_REPO_DIR="$d/oldrepo" \
    XDG_CACHE_HOME="$d/cache" \
    LCTL_STATE="$d/lctl" \
    bash "$SCRIPT" "$@"
}

state_field() {
  local d="$1" f="$2"
  [ -f "$d/state/state.json" ] && \
    jq -r --arg f "$f" 'if (has($f) and (.[$f] != null)) then (.[$f] | tostring) else empty end' "$d/state/state.json" 2>/dev/null || echo ""
}

old_plist_path() { echo "$1/home/Library/LaunchAgents/${OLD_LABEL}.plist"; }
new_plist_path() { echo "$1/home/Library/LaunchAgents/${NEW_LABEL}.plist"; }

loaded() { [ -f "$1/lctl/loaded/$2" ] && echo 1 || echo 0; }
disabled() { [ -f "$1/lctl/disabled/$2" ] && echo 1 || echo 0; }

# ⚠️ 検証職1巡目MAJOR-2対応: step_c_verify_cache がClaude・Codex両方の
# updated_atを要求するようになったため、fixtureヘルパーも両方を書く／
# 両方を進める（名前は既存呼び出し箇所との互換のためclaude_*のまま維持）。
write_claude_cache_fresh() {
  local d="$1"
  mkdir -p "$d/cache/claude-codex-usage"
  jq -n --argjson t "$(date +%s)" '{schema_version:1,service:"claude",fetched_at:$t,updated_at:$t,five_hour:{used_percent:1},seven_day:{used_percent:1},last_error:null}' \
    > "$d/cache/claude-codex-usage/claude-cache.json"
  jq -n --argjson t "$(date +%s)" '{schema_version:1,service:"codex",fetched_at:$t,updated_at:$t,five_hour:{used_percent:1},seven_day:{used_percent:1},last_error:null}' \
    > "$d/cache/claude-codex-usage/codex-cache.json"
}
advance_claude_cache() {
  local d="$1" t
  t="$(( $(date +%s) + 1000 ))"
  jq --argjson t "$t" '.fetched_at=$t | .updated_at=$t' \
    "$d/cache/claude-codex-usage/claude-cache.json" > "$d/cache/claude-codex-usage/claude-cache.json.tmp"
  mv "$d/cache/claude-codex-usage/claude-cache.json.tmp" "$d/cache/claude-codex-usage/claude-cache.json"
  jq --argjson t "$t" '.fetched_at=$t | .updated_at=$t' \
    "$d/cache/claude-codex-usage/codex-cache.json" > "$d/cache/claude-codex-usage/codex-cache.json.tmp"
  mv "$d/cache/claude-codex-usage/codex-cache.json.tmp" "$d/cache/claude-codex-usage/codex-cache.json"
}

echo "=== T-1: 新規機（経路2）。aを飛ばし had_old_job:false・phase:migrated ==="
{
  E="$(new_env)"
  write_claude_cache_fresh "$E"
  ( sleep 2; advance_claude_cache "$E" ) &
  bgpid=$!
  out="$(run_install "$E")"
  rc=$?
  wait "$bgpid" 2>/dev/null
  assert_eq "T-1: exit=0" "0" "$rc"
  assert_eq "T-1: had_old_job=false" "false" "$(state_field "$E" had_old_job)"
  assert_eq "T-1: phase=migrated" "migrated" "$(state_field "$E" phase)"
  assert_eq "T-1: 新ジョブがロード済み" "1" "$(loaded "$E" "$NEW_LABEL")"
  assert_true "T-1: mvを試みない（旧plistが元から存在しない）" \
    "$([ ! -e "$(old_plist_path "$E")" ] && echo 1 || echo 0)"
  # --rollback は「新を止める」だけで取得0件へ戻る旨を出す
  rb_out="$(run_install "$E" --rollback)"
  assert_true "T-1 rollback: 新ジョブを停止" "$([ "$(loaded "$E" "$NEW_LABEL")" = "0" ] && echo 1 || echo 0)"
  assert_true "T-1 rollback: state.jsonを削除" "$([ ! -f "$E/state/state.json" ] && echo 1 || echo 0)"
  assert_true "T-1 rollback: 取得0件へ戻る旨のメッセージ" "$(printf '%s' "$rb_out" | grep -q "0件" && echo 1 || echo 0)"
  rm -rf "$E"
}

echo "=== T-2: 退避に失敗（旧は停止・plistは元の場所）。非0でbへ進まない・phaseはstartingのまま ==="
{
  E="$(new_env)"
  : > "$(old_plist_path "$E")"
  mkdir -p "$E/lctl/loaded"; : > "$E/lctl/loaded/$OLD_LABEL"
  chmod 555 "$E/home/Library/LaunchAgents"
  out="$(run_install "$E" 2>&1)"
  rc=$?
  chmod 755 "$E/home/Library/LaunchAgents"
  assert_true "T-2: 非0で終わる" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  assert_eq "T-2: phaseはstartingのまま" "starting" "$(state_field "$E" phase)"
  rm -rf "$E"
}

echo "=== T-3: bootstrapに失敗。phase=new-placed・非0。再実行でmigratedへ・plistを再mvしない ==="
{
  E="$(new_env)"
  write_claude_cache_fresh "$E"
  : > "$E/lctl/fail_bootstrap_${NEW_LABEL}"
  out1="$(run_install "$E" 2>&1)"; rc1=$?
  assert_true "T-3: 1回目は非0" "$([ "$rc1" -ne 0 ] && echo 1 || echo 0)"
  assert_eq "T-3: phase=new-placed" "new-placed" "$(state_field "$E" phase)"
  placed_mtime1="$(stat -f %m "$(new_plist_path "$E")" 2>/dev/null)"
  rm -f "$E/lctl/fail_bootstrap_${NEW_LABEL}"
  ( sleep 2; advance_claude_cache "$E" ) &
  bgpid=$!
  out2="$(run_install "$E" 2>&1)"; rc2=$?
  wait "$bgpid" 2>/dev/null
  placed_mtime2="$(stat -f %m "$(new_plist_path "$E")" 2>/dev/null)"
  assert_eq "T-3: 再実行でexit=0" "0" "$rc2"
  assert_eq "T-3: phase=migrated" "migrated" "$(state_field "$E" phase)"
  assert_eq "T-3: plistを再mvしない(mtime不変)" "$placed_mtime1" "$placed_mtime2"
  rm -rf "$E"
}

echo "=== T-4: enableに失敗。phase=new-bootstrapped・非0。再実行でenableだけ行う ==="
{
  E="$(new_env)"
  write_claude_cache_fresh "$E"
  : > "$E/lctl/fail_enable_${NEW_LABEL}"
  out1="$(run_install "$E" 2>&1)"; rc1=$?
  assert_true "T-4: 1回目は非0" "$([ "$rc1" -ne 0 ] && echo 1 || echo 0)"
  assert_eq "T-4: phase=new-bootstrapped" "new-bootstrapped" "$(state_field "$E" phase)"
  assert_eq "T-4: 新ジョブはロード済み(bootstrapは成功している)" "1" "$(loaded "$E" "$NEW_LABEL")"
  rm -f "$E/lctl/fail_enable_${NEW_LABEL}"
  # ⚠️ 検証職2巡目MAJOR-1対応後: enableが一度も成功していないラベルは
  # print-disabledの封筒に一切現れず、disabled_status()はunknownを返す
  # （fail-closed）。1回目のFAILメッセージが案内する「手動で確認のうえ
  # enableしてください」を本人が実行した状況を模す（実機のリカバリ手順の
  # 忠実な再現＝自動での握り潰しではない）。
  : > "$E/lctl/enabled/${NEW_LABEL}"
  ( sleep 2; advance_claude_cache "$E" ) &
  bgpid=$!
  out2="$(run_install "$E" 2>&1)"; rc2=$?
  wait "$bgpid" 2>/dev/null
  assert_eq "T-4: 再実行でexit=0" "0" "$rc2"
  assert_eq "T-4: phase=migrated" "migrated" "$(state_field "$E" phase)"
  rm -rf "$E"
}

echo "=== T-6: 冪等な再実行。新が1件だけ有効な状態でaを実行しない・old_plist_destが変わらない ==="
{
  E="$(new_env)"
  write_claude_cache_fresh "$E"
  ( sleep 2; advance_claude_cache "$E" ) &
  bgpid=$!
  run_install "$E" >/dev/null 2>&1
  wait "$bgpid" 2>/dev/null
  dest_before="$(state_field "$E" old_plist_dest)"
  ( sleep 2; advance_claude_cache "$E" ) &
  bgpid=$!
  out="$(run_install "$E" 2>&1)"; rc=$?
  wait "$bgpid" 2>/dev/null
  dest_after="$(state_field "$E" old_plist_dest)"
  assert_eq "T-6: 再実行もexit=0" "0" "$rc"
  assert_eq "T-6: old_plist_destが変わらない" "$dest_before" "$dest_after"
  assert_true "T-6: aを実行しない（--confirmを自動で行わない=phaseはmigratedのまま）" \
    "$([ "$(state_field "$E" phase)" = "migrated" ] && echo 1 || echo 0)"
  rm -rf "$E"
}

echo "=== T-7: --rollback の拒否（state.json欠如） ==="
{
  E="$(new_env)"
  : > "$(new_plist_path "$E")"
  mkdir -p "$E/lctl/loaded"; : > "$E/lctl/loaded/$NEW_LABEL"
  out="$(run_install "$E" --rollback 2>&1)"; rc=$?
  assert_true "T-7: state.json欠如は自動で戻さず非0" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  rm -rf "$E"
}

echo "=== T-8: had_old_job:falseの巻き戻し。r2を行わずstate.jsonが削除される ==="
{
  E="$(new_env)"
  write_claude_cache_fresh "$E"
  ( sleep 2; advance_claude_cache "$E" ) &
  bgpid=$!
  run_install "$E" >/dev/null 2>&1
  wait "$bgpid" 2>/dev/null
  assert_eq "T-8前提: had_old_job=false" "false" "$(state_field "$E" had_old_job)"
  out="$(run_install "$E" --rollback 2>&1)"
  assert_true "T-8: r2を行わない（旧plistが作られない）" "$([ ! -e "$(old_plist_path "$E")" ] && echo 1 || echo 0)"
  assert_true "T-8: state.jsonが削除される" "$([ ! -f "$E/state/state.json" ] && echo 1 || echo 0)"
  assert_true "T-8: 取得0件になる旨を出す" "$(printf '%s' "$out" | grep -q "0件" && echo 1 || echo 0)"
  rm -rf "$E"
}

echo "=== T-9(部分): drift検知の材料になる基本状態（DUPLICATE=INV-1違反）を作れること ==="
{
  E="$(new_env)"
  mkdir -p "$E/lctl/loaded" "$E/lctl/enabled"
  : > "$E/lctl/loaded/$OLD_LABEL"
  : > "$E/lctl/loaded/$NEW_LABEL"
  # ⚠️ 実機の二重取得は両方が真に有効（enable済み）なので、その状態を
  # 忠実に模す（検証職2巡目MAJOR-1対応後、loadedだけではNEW_ACTIVEが
  # unknownに倒れfail-closedしてしまう）。
  : > "$E/lctl/enabled/$NEW_LABEL"
  out="$(run_install "$E" 2>&1)"; rc=$?
  assert_true "T-9: 両方loadedのときは非0で中止しhealを案内" \
    "$([ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q -- "--heal" && echo 1 || echo 0)"
  rm -rf "$E"
}

echo "=== T-12(a): INV-1入口検査。両方loadした状態でa・b・--verify・--confirm・--rollback・再実行はすべて非0でheal案内、--healだけが解消する ==="
for flag in "" "--verify" "--confirm" "--rollback"; do
  E="$(new_env)"
  mkdir -p "$E/lctl/loaded" "$E/lctl/enabled"
  : > "$E/lctl/loaded/$OLD_LABEL"
  : > "$E/lctl/loaded/$NEW_LABEL"
  : > "$E/lctl/enabled/$NEW_LABEL"
  if [ -n "$flag" ]; then
    out="$(run_install "$E" "$flag" 2>&1)"
  else
    out="$(run_install "$E" 2>&1)"
  fi
  rc=$?
  label="${flag:-run}"
  assert_true "T-12a ${label}: 非0でheal案内・何もしない" \
    "$([ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q -- "--heal" && [ "$(loaded "$E" "$OLD_LABEL")" = "1" ] && [ "$(loaded "$E" "$NEW_LABEL")" = "1" ] && echo 1 || echo 0)"
  rm -rf "$E"
done
{
  E="$(new_env)"
  mkdir -p "$E/lctl/loaded" "$E/lctl/enabled"
  : > "$E/lctl/loaded/$OLD_LABEL"
  : > "$E/lctl/loaded/$NEW_LABEL"
  : > "$E/lctl/enabled/$NEW_LABEL"
  out="$(run_install "$E" --heal 2>&1)"; rc=$?
  assert_eq "T-12a --heal: exit=0" "0" "$rc"
  assert_true "T-12a --heal: 旧を停止" "$([ "$(loaded "$E" "$OLD_LABEL")" = "0" ] && echo 1 || echo 0)"
  assert_true "T-12a --heal: 新は残る" "$([ "$(loaded "$E" "$NEW_LABEL")" = "1" ] && echo 1 || echo 0)"
  assert_true "T-12a --heal: 復活元候補を表示（撤去はしない）" "$(printf '%s' "$out" | grep -q "install.sh" && echo 1 || echo 0)"
  rm -rf "$E"
}

echo "=== T-12b: --heal は二重でなければ何もせず終了する ==="
{
  E="$(new_env)"
  mkdir -p "$E/lctl/loaded" "$E/lctl/enabled"
  : > "$E/lctl/loaded/$NEW_LABEL"
  : > "$E/lctl/enabled/$NEW_LABEL"
  out="$(run_install "$E" --heal 2>&1)"; rc=$?
  assert_eq "T-12b: exit=0" "0" "$rc"
  assert_true "T-12b: 「二重取得ではありません」と出す" "$(printf '%s' "$out" | grep -q "二重取得ではありません" && echo 1 || echo 0)"
  rm -rf "$E"
}

echo "=== T-12c: P4の巻き戻し案内は「新を止める」が先頭 ==="
{
  E="$(new_env)"
  mkdir -p "$E/lctl/loaded" "$E/lctl/enabled"
  : > "$E/lctl/loaded/$NEW_LABEL"
  : > "$E/lctl/enabled/$NEW_LABEL"
  cat > "$E/state/state.json" <<EOF
{"had_old_job":true,"phase":"confirmed"}
EOF
  out="$(run_install "$E" --rollback 2>&1)"; rc=$?
  assert_true "T-12c: 拒否（非0）" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  first_step_line="$(printf '%s' "$out" | grep -o "①[^②]*" | head -1)"
  assert_true "T-12c: 案内の①が bootout（新を止める）" "$(printf '%s' "$first_step_line" | grep -q "bootout ${NEW_LABEL}\|bootout .*usage-fetch" && echo 1 || echo 0)"
  rm -rf "$E"
}

echo "=== T-15(部分): --rollback可否表＝P5拒否（退避物なし・OLD_CODEなし） ==="
{
  E="$(new_env)"
  rm -f "$E/oldrepo/refresh.sh"
  mkdir -p "$E/lctl/loaded" "$E/lctl/enabled"
  : > "$E/lctl/loaded/$NEW_LABEL"
  : > "$E/lctl/enabled/$NEW_LABEL"
  cat > "$E/state/state.json" <<EOF
{"had_old_job":true,"phase":"confirmed"}
EOF
  out="$(run_install "$E" --rollback 2>&1)"; rc=$?
  assert_true "T-15 P5: 拒否＋戻せない旨" "$([ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "戻す手段がありません\|新しい取得器を直す" && echo 1 || echo 0)"
  rm -rf "$E"
}

echo "=== T-16: SKIP_LAUNCHCTL=1単独指定は拒否 ==="
{
  E="$(new_env)"
  out="$(HOME="$E/home" AIENV_USAGE_MIGRATION_STATE_DIR="$E/state" AIENV_USAGE_OLD_REPO_DIR="$E/oldrepo" XDG_CACHE_HOME="$E/cache" LCTL_STATE="$E/lctl" SKIP_LAUNCHCTL=1 bash "$SCRIPT" 2>&1)"
  rc=$?
  assert_true "T-16: 非0で拒否" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  assert_true "T-16: AIENV_USAGE_FETCH_TESTと併用しないと拒否する旨のメッセージ" \
    "$(printf '%s' "$out" | grep -q "AIENV_USAGE_FETCH_TEST" && echo 1 || echo 0)"
  rm -rf "$E"
}

echo "=== T-18: --confirmの前提（phase=migratedでは拒否・退避物が消えない） ==="
{
  E="$(new_env)"
  write_claude_cache_fresh "$E"
  ( sleep 2; advance_claude_cache "$E" ) &
  bgpid=$!
  run_install "$E" >/dev/null 2>&1
  wait "$bgpid" 2>/dev/null
  assert_eq "T-18前提: phase=migrated" "migrated" "$(state_field "$E" phase)"
  dest="$(state_field "$E" old_plist_dest)"
  out="$(AIENV_USAGE_FETCH_TEST=1 AIENV_USAGE_FETCH_CONFIRM_ANSWER=yes \
    HOME="$E/home" AIENV_USAGE_MIGRATION_STATE_DIR="$E/state" AIENV_USAGE_OLD_REPO_DIR="$E/oldrepo" \
    XDG_CACHE_HOME="$E/cache" LCTL_STATE="$E/lctl" bash "$SCRIPT" --confirm 2>&1)"
  rc=$?
  assert_true "T-18: phase=migratedでの--confirmは拒否" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  rm -rf "$E"
}

echo "=== --verify -> --confirm の正常経路（対話はAIENV_USAGE_FETCH_TESTで代替） ==="
{
  E="$(new_env)"
  write_claude_cache_fresh "$E"
  ( sleep 2; advance_claude_cache "$E" ) &
  bgpid=$!
  run_install "$E" >/dev/null 2>&1
  wait "$bgpid" 2>/dev/null
  ( sleep 2; advance_claude_cache "$E" ) &
  bgpid=$!
  out_verify="$(AIENV_USAGE_FETCH_TEST=1 AIENV_USAGE_FETCH_VERIFY_ANSWER=yes \
    HOME="$E/home" AIENV_USAGE_MIGRATION_STATE_DIR="$E/state" AIENV_USAGE_OLD_REPO_DIR="$E/oldrepo" \
    XDG_CACHE_HOME="$E/cache" LCTL_STATE="$E/lctl" bash "$SCRIPT" --verify 2>&1)"
  rc_verify=$?
  wait "$bgpid" 2>/dev/null
  assert_eq "verify: exit=0" "0" "$rc_verify"
  assert_eq "verify: phase=verified" "verified" "$(state_field "$E" phase)"
  dest="$(state_field "$E" old_plist_dest)"
  out_confirm="$(AIENV_USAGE_FETCH_TEST=1 AIENV_USAGE_FETCH_CONFIRM_ANSWER=yes \
    HOME="$E/home" AIENV_USAGE_MIGRATION_STATE_DIR="$E/state" AIENV_USAGE_OLD_REPO_DIR="$E/oldrepo" \
    XDG_CACHE_HOME="$E/cache" LCTL_STATE="$E/lctl" bash "$SCRIPT" --confirm 2>&1)"
  rc_confirm=$?
  assert_eq "confirm: exit=0" "0" "$rc_confirm"
  assert_eq "confirm: phase=confirmed" "confirmed" "$(state_field "$E" phase)"
  if [ -n "$dest" ]; then
    assert_true "confirm: 退避物が削除される" "$([ ! -e "$dest" ] && echo 1 || echo 0)"
  fi
  rm -rf "$E"
}

echo "=== 検証職1巡目 BLOCKING: INV-1(b)の有効化直前検査が各操作(bootstrap後のenable)を覆う ==="
{
  # 経路2（新規機）でstep_bのbootstrap成功「直後」に外部要因で旧が復活した
  # のと同じ状況を作る（疑似launchctlのフック）。最終enableは
  # guard_activate_new経由なので、この復活を検出して拒否するはず。
  E="$(new_env)"
  write_claude_cache_fresh "$E"
  out="$(HOME="$E/home" AIENV_USAGE_MIGRATION_STATE_DIR="$E/state" AIENV_USAGE_OLD_REPO_DIR="$E/oldrepo" \
    XDG_CACHE_HOME="$E/cache" LCTL_STATE="$E/lctl" \
    LCTL_REVIVE_OLD_ON_NEW_BOOTSTRAP=1 NEW_LABEL_FOR_REVIVE_HOOK="$NEW_LABEL" OLD_LABEL_FOR_REVIVE_HOOK="$OLD_LABEL" \
    bash "$SCRIPT" 2>&1)"
  rc=$?
  assert_true "BLOCKING回帰: bootstrap直後の旧復活で非0終了する" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  assert_true "BLOCKING回帰: heal案内が出る（最終enableが復活を検出して中断）" \
    "$(printf '%s' "$out" | grep -q -- "--heal" && echo 1 || echo 0)"
  assert_true "BLOCKING回帰: phase=migratedへは進まない（enable未完了のまま止まる）" \
    "$([ "$(state_field "$E" phase)" != "migrated" ] && echo 1 || echo 0)"
  assert_true "BLOCKING回帰: 旧・新とも実際にロードされた状態になっている（外部要因による復活自体は模擬どおり）" \
    "$([ "$(loaded "$E" "$OLD_LABEL")" = "1" ] && [ "$(loaded "$E" "$NEW_LABEL")" = "1" ] && echo 1 || echo 0)"
  # ⚠️ 検証職2巡目MAJOR-1対応後: 復活検出でenableが中断されたため新ラベルは
  # まだ一度もenableされておらずprint-disabledの封筒に現れない
  # （disabled_status()はunknown＝fail-closed）。--heal自身も①観測で
  # unknownなら中止するのが設計どおりなので、本人がFAILメッセージの案内
  # （手動確認）に従いenableを済ませた状況を模してから--healを呼ぶ。
  : > "$E/lctl/enabled/${NEW_LABEL}"
  # --heal で正しく解消できることも確認する（復旧経路が機能する証拠）。
  heal_out="$(HOME="$E/home" AIENV_USAGE_MIGRATION_STATE_DIR="$E/state" AIENV_USAGE_OLD_REPO_DIR="$E/oldrepo" \
    XDG_CACHE_HOME="$E/cache" LCTL_STATE="$E/lctl" bash "$SCRIPT" --heal 2>&1)"
  heal_rc=$?
  assert_eq "BLOCKING回帰: --healで解消(exit=0)" "0" "$heal_rc"
  assert_true "BLOCKING回帰: --heal後は旧が停止し新だけ残る" \
    "$([ "$(loaded "$E" "$OLD_LABEL")" = "0" ] && [ "$(loaded "$E" "$NEW_LABEL")" = "1" ] && echo 1 || echo 0)"
  rm -rf "$E"
}

echo "=== 検証職1巡目 BLOCKING: 巻き戻し側(rollback_r2_restore_old)でも同型の再観測が効く ==="
{
  # 経路1・had_old_job=trueでconfirmed一歩手前まで進め、旧を退避済みにする。
  # rollbackで旧を復元する最終enable直前に、新側が復活したのと同じ状況を
  # 作れることを確かめる（対称の保護）。
  E="$(new_env)"
  mkdir -p "$E/lctl/loaded" "$E/state/stash"
  # ⚠️ bootstrapスタブはplistからLabelを抽出するため、空ファイルではなく
  # 有効な最小plistでなければならない（label_of_plist()がLabelを取れないと
  # 別の理由〈exit 1〉で失敗し、本来検証したいINV-1(b)ガードの分岐に
  # 到達しない＝実測で判明）。
  cat > "$E/state/stash/${OLD_LABEL}.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${OLD_LABEL}</string>
</dict>
</plist>
PLIST
  cat > "$E/state/state.json" <<EOF
{"had_old_job":true,"old_plist_dest":"$E/state/stash/${OLD_LABEL}.plist","phase":"confirmed"}
EOF
  # 新は当初ロード無し（rollback対象）。旧のbootstrap直後に新が復活したのと
  # 同じ状況を作る（フックの対象ラベルを旧側へ切り替える）。
  out="$(HOME="$E/home" AIENV_USAGE_MIGRATION_STATE_DIR="$E/state" AIENV_USAGE_OLD_REPO_DIR="$E/oldrepo" \
    XDG_CACHE_HOME="$E/cache" LCTL_STATE="$E/lctl" \
    LCTL_REVIVE_OLD_ON_NEW_BOOTSTRAP=1 NEW_LABEL_FOR_REVIVE_HOOK="$OLD_LABEL" OLD_LABEL_FOR_REVIVE_HOOK="$NEW_LABEL" \
    bash "$SCRIPT" --rollback 2>&1)"
  rc=$?
  assert_true "rollback側BLOCKING回帰: 新復活で非0終了する" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  assert_true "rollback側BLOCKING回帰: heal案内が出る" \
    "$(printf '%s' "$out" | grep -q -- "--heal" && echo 1 || echo 0)"
  rm -rf "$E"
}

echo "=== 検証職1巡目 MAJOR-2: キャッシュ確認はClaude・Codex両方の更新を要求する ==="
{
  E="$(new_env)"
  write_claude_cache_fresh "$E"
  # Claudeだけ進め、Codexは固定したままにする（実装のcache_field/is_advanced
  # は updated_at 基準）。短いタイムアウトでテストを高速化する。
  ( sleep 1; jq --argjson t "$(( $(date +%s) + 1000 ))" '.fetched_at=$t | .updated_at=$t' \
      "$E/cache/claude-codex-usage/claude-cache.json" > "$E/cache/claude-codex-usage/claude-cache.json.tmp"
    mv "$E/cache/claude-codex-usage/claude-cache.json.tmp" "$E/cache/claude-codex-usage/claude-cache.json" ) &
  bgpid=$!
  out="$(HOME="$E/home" AIENV_USAGE_MIGRATION_STATE_DIR="$E/state" AIENV_USAGE_OLD_REPO_DIR="$E/oldrepo" \
    XDG_CACHE_HOME="$E/cache" LCTL_STATE="$E/lctl" AIENV_USAGE_VERIFY_CACHE_TIMEOUT_SECONDS=3 \
    bash "$SCRIPT" 2>&1)"
  rc=$?
  wait "$bgpid" 2>/dev/null
  assert_true "MAJOR-2回帰: Codexが進まなければ非0で終わる（Claudeだけの進行では成功にしない）" \
    "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  assert_true "MAJOR-2回帰: Codex側が更新されなかった旨のWARNが出る" \
    "$(printf '%s' "$out" | grep -q "Codex側のキャッシュが更新されません" && echo 1 || echo 0)"
  rm -rf "$E"
}
{
  # 陽性: 両方進めば成功する（既存ヘルパー write_claude_cache_fresh/
  # advance_claude_cache は両キャッシュを扱うよう既に改修済み）。
  E="$(new_env)"
  write_claude_cache_fresh "$E"
  ( sleep 1; advance_claude_cache "$E" ) &
  bgpid=$!
  out="$(HOME="$E/home" AIENV_USAGE_MIGRATION_STATE_DIR="$E/state" AIENV_USAGE_OLD_REPO_DIR="$E/oldrepo" \
    XDG_CACHE_HOME="$E/cache" LCTL_STATE="$E/lctl" AIENV_USAGE_VERIFY_CACHE_TIMEOUT_SECONDS=10 \
    bash "$SCRIPT" 2>&1)"
  rc=$?
  wait "$bgpid" 2>/dev/null
  assert_eq "MAJOR-2陽性: 両方進めばexit=0" "0" "$rc"
  rm -rf "$E"
}

echo "=== 検証職1巡目 MAJOR-3: INV-4のprint-disabled解析はfail-closed（封筒が壊れていればunknown） ==="
{
  # 新ジョブがloadedな状態でprint-disabledの出力自体が既知の封筒でない
  # 場合、disabled_status()はunknownを返し、new_active()もunknownになる
  # べき＝新規の破壊的操作（bootout/bootstrap/enable/mv等のファイル操作）
  # が一切起きないことを確認する。
  E="$(new_env)"
  mkdir -p "$E/lctl/loaded"
  : > "$E/lctl/loaded/$NEW_LABEL"
  : > "$(new_plist_path "$E")"
  before_lctl_files="$(find "$E/lctl" -type f | sort)"
  out="$(HOME="$E/home" AIENV_USAGE_MIGRATION_STATE_DIR="$E/state" AIENV_USAGE_OLD_REPO_DIR="$E/oldrepo" \
    XDG_CACHE_HOME="$E/cache" LCTL_STATE="$E/lctl" LCTL_PRINTDISABLED_MALFORMED=1 \
    bash "$SCRIPT" --rollback 2>&1)"
  rc=$?
  after_lctl_files="$(find "$E/lctl" -type f | sort)"
  assert_true "MAJOR-3回帰: 封筒が壊れたprint-disabledはfail-closedで非0終了" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  assert_true "MAJOR-3回帰: INV-4(照会不能)の拒否メッセージが出る" \
    "$(printf '%s' "$out" | grep -q "確認できません" && echo 1 || echo 0)"
  assert_eq "MAJOR-3回帰: launchctl状態ファイルは1件も変化しない（破壊的操作ゼロ）" "$before_lctl_files" "$after_lctl_files"
  rm -rf "$E"
}
{
  # 対比: 対象ラベルの値トークンが未知（"maybe"等）の場合もunknown扱い
  # （実装のcase文が既知トークン以外はunknownへ倒すことを直接検査）。
  E="$(new_env)"
  mkdir -p "$E/lctl/loaded" "$E/lctl/disabled"
  : > "$E/lctl/loaded/$NEW_LABEL"
  cat > "$E/lctl/print_disabled_override.txt" <<EOF
disabled services = {
	"$NEW_LABEL" => maybe
}
EOF
  # 既定スタブは固定封筒しか返さないため、この観点は disabled_status() の
  # 単体呼び出しで直接検査する（インストーラ本体をsourceして関数を叩く）。
  out="$(HOME="$E/home" AIENV_USAGE_MIGRATION_STATE_DIR="$E/state" AIENV_USAGE_OLD_REPO_DIR="$E/oldrepo" \
    XDG_CACHE_HOME="$E/cache" LCTL_STATE="$E/lctl" bash -c '
      launchctl() {
        if [ "$1" = "print-disabled" ]; then
          cat "$LCTL_STATE/print_disabled_override.txt"
          return 0
        fi
        if [ "$1" = "print" ]; then return 0; fi
        return 1
      }
      export -f launchctl
      DOMAIN="gui/0"
      LABEL="'"$NEW_LABEL"'"
      SKIP_LAUNCHCTL=0
      set -uo pipefail
      # install-usage-fetch.sh を直接execせず関数だけ使う簡易ハック:
      # 同名関数を再定義して直接呼ぶ。
      '"$(sed -n '/^parse_disabled_envelope()/,/^}/p' "$SCRIPT")"'
      '"$(sed -n '/^disabled_status()/,/^}/p' "$SCRIPT")"'
      disabled_status "$LABEL"
    ' 2>&1)"
  assert_eq "MAJOR-3回帰: 未知トークン(maybe)はunknownへ倒す" "unknown" "$out"
  rm -rf "$E"
}

echo "=== 検証職2巡目 MAJOR-1: ラベル欠落・封筒の閉じ括弧欠落もunknownへ倒す ==="
{
  # 対象ラベルが封筒内に一切現れない場合（＝一度もenable/disableを明示
  # 呼び出ししていないラベル。実機のprint-disabledでは最も一般的な状態）
  # を無条件にenabledとみなさない（設計書の観測表「ラベル欠落なら
  # unknown」）。
  E="$(new_env)"
  mkdir -p "$E/lctl/loaded" "$E/lctl/disabled"
  cat > "$E/lctl/print_disabled_override.txt" <<EOF
disabled services = {
	"com.other.unrelated-label" => disabled
}
EOF
  out="$(HOME="$E/home" AIENV_USAGE_MIGRATION_STATE_DIR="$E/state" AIENV_USAGE_OLD_REPO_DIR="$E/oldrepo" \
    XDG_CACHE_HOME="$E/cache" LCTL_STATE="$E/lctl" bash -c '
      launchctl() {
        if [ "$1" = "print-disabled" ]; then cat "$LCTL_STATE/print_disabled_override.txt"; return 0; fi
        if [ "$1" = "print" ]; then return 0; fi
        return 1
      }
      export -f launchctl
      DOMAIN="gui/0"
      LABEL="'"$NEW_LABEL"'"
      SKIP_LAUNCHCTL=0
      set -uo pipefail
      '"$(sed -n '/^parse_disabled_envelope()/,/^}/p' "$SCRIPT")"'
      '"$(sed -n '/^disabled_status()/,/^}/p' "$SCRIPT")"'
      disabled_status "$LABEL"
    ' 2>&1)"
  assert_eq "MAJOR-1回帰: 対象ラベルが封筒に無ければunknown（enabledと断定しない）" "unknown" "$out"
  rm -rf "$E"
}
{
  # 封筒の終端`}`が欠けている（出力が途中で切れている）場合もunknown。
  E="$(new_env)"
  mkdir -p "$E/lctl/loaded"
  cat > "$E/lctl/print_disabled_override.txt" <<EOF
disabled services = {
	"$NEW_LABEL" => enabled
EOF
  out="$(HOME="$E/home" AIENV_USAGE_MIGRATION_STATE_DIR="$E/state" AIENV_USAGE_OLD_REPO_DIR="$E/oldrepo" \
    XDG_CACHE_HOME="$E/cache" LCTL_STATE="$E/lctl" bash -c '
      launchctl() {
        if [ "$1" = "print-disabled" ]; then cat "$LCTL_STATE/print_disabled_override.txt"; return 0; fi
        if [ "$1" = "print" ]; then return 0; fi
        return 1
      }
      export -f launchctl
      DOMAIN="gui/0"
      LABEL="'"$NEW_LABEL"'"
      SKIP_LAUNCHCTL=0
      set -uo pipefail
      '"$(sed -n '/^parse_disabled_envelope()/,/^}/p' "$SCRIPT")"'
      '"$(sed -n '/^disabled_status()/,/^}/p' "$SCRIPT")"'
      disabled_status "$LABEL"
    ' 2>&1)"
  assert_eq "MAJOR-1回帰: 封筒の閉じ括弧が欠けていればunknown（先頭一致だけで解析済みとみなさない）" "unknown" "$out"
  rm -rf "$E"
}
{
  # end-to-endでも、疑似launchctlのLCTL_PRINTDISABLED_TRUNCATED=1経由で
  # 同じ状況（閉じ括弧欠落）を作り、破壊的操作ゼロのまま拒否されることを
  # 確認する。
  E="$(new_env)"
  mkdir -p "$E/lctl/loaded"
  : > "$E/lctl/loaded/$NEW_LABEL"
  : > "$(new_plist_path "$E")"
  before_lctl_files="$(find "$E/lctl" -type f | sort)"
  out="$(HOME="$E/home" AIENV_USAGE_MIGRATION_STATE_DIR="$E/state" AIENV_USAGE_OLD_REPO_DIR="$E/oldrepo" \
    XDG_CACHE_HOME="$E/cache" LCTL_STATE="$E/lctl" LCTL_PRINTDISABLED_TRUNCATED=1 \
    bash "$SCRIPT" --rollback 2>&1)"
  rc=$?
  after_lctl_files="$(find "$E/lctl" -type f | sort)"
  assert_true "MAJOR-1回帰(e2e): 封筒が途中で切れたprint-disabledは非0終了" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  assert_eq "MAJOR-1回帰(e2e): launchctl状態ファイルは1件も変化しない（破壊的操作ゼロ）" "$before_lctl_files" "$after_lctl_files"
  rm -rf "$E"
}

echo "=== 検証職1巡目 MAJOR-4: state.json書込み失敗は非0＋WARNで可視化される ==="
{
  E="$(new_env)"
  write_claude_cache_fresh "$E"
  mkdir -p "$E/state"
  # had_old_jobを事前に確定させ、ensure_started自体は書き込みなしで
  # 早期returnさせる（そちらは元から`|| fail`で握りつぶしていない・別経路）。
  # 本テストが狙うのはstep_b_install_new側の最初の書込み（phase=new-placed）
  # が失敗するケース＝旧実装が`|| true`で握りつぶしていた6箇所のうちの1つ。
  echo '{"had_old_job":false,"phase":"starting","test_mode":false}' > "$E/state/state.json"
  # state.jsonの書込み先を読み取り専用にして、mv（state_apply内部）を失敗
  # させる（ディレクトリ書込み不可＝mvのunlink/rename相当が失敗する）。
  chmod 555 "$E/state"
  out="$(HOME="$E/home" AIENV_USAGE_MIGRATION_STATE_DIR="$E/state" AIENV_USAGE_OLD_REPO_DIR="$E/oldrepo" \
    XDG_CACHE_HOME="$E/cache" LCTL_STATE="$E/lctl" AIENV_USAGE_VERIFY_CACHE_TIMEOUT_SECONDS=2 \
    bash "$SCRIPT" 2>&1)"
  rc=$?
  chmod 755 "$E/state"
  assert_true "MAJOR-4回帰: state.json書込み失敗時は非0で終わる（黙って成功にしない）" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  assert_true "MAJOR-4回帰: WARNに実際の操作が完了済みである旨と再実行の案内が出る" \
    "$(printf '%s' "$out" | grep -q "の記録に失敗しました。.*もう一度実行" && echo 1 || echo 0)"
  rm -rf "$E"
}

echo "=== 検証職2巡目 BLOCKING-1: --confirmの対話待ちTOCTOU（回答後・削除直前に再観測する） ==="
{
  # phase=verified・old_plist_destが有効な退避物を指す状態を直接構成する。
  # cmd_confirmはold_loaded()を計3回呼ぶ（①入口のinv1_entry_check_or_die
  # ②対話前 ③対話後・削除直前）。「①②では旧は未ロード」→「③で初めて
  # 旧がロードされている」という時系列を、疑似launchctlの呼び出し回数
  # ベースのフックで決定的に再現する（wall-clockの待機に依存しない）。
  # ⚠️ 検証職3巡目MAJOR対応: 2回目（②対話前）で復活させると②自身が
  # 先に拒否してしまい、本来検証したい③（削除直前の再観測）を一度も
  # 通らないまま「たまたま」成功する偽陽性になっていた
  # （②の拒否メッセージにも"--heal"の文言が含まれるため見分けが付かな
  # かった）。3回目（LCTL_REVIVE_AFTER_QUERY_N=3）に変更し、③到達を
  # 照会回数とphase=confirming（②の対話受理後にしか書かれない）の両方で
  # 直接検査する。
  E="$(new_env)"
  mkdir -p "$E/lctl/loaded" "$E/lctl/enabled" "$E/state/stash"
  : > "$E/lctl/loaded/$NEW_LABEL"
  : > "$E/lctl/enabled/$NEW_LABEL"
  cat > "$E/state/stash/${OLD_LABEL}.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict><key>Label</key><string>${OLD_LABEL}</string></dict>
</plist>
PLIST
  cat > "$E/state/state.json" <<EOF
{"had_old_job":true,"old_plist_dest":"$E/state/stash/${OLD_LABEL}.plist","phase":"verified"}
EOF
  before_stash_exists=1
  [ -e "$E/state/stash/${OLD_LABEL}.plist" ] || before_stash_exists=0
  out="$(AIENV_USAGE_FETCH_TEST=1 AIENV_USAGE_FETCH_CONFIRM_ANSWER=yes \
    HOME="$E/home" AIENV_USAGE_MIGRATION_STATE_DIR="$E/state" AIENV_USAGE_OLD_REPO_DIR="$E/oldrepo" \
    XDG_CACHE_HOME="$E/cache" LCTL_STATE="$E/lctl" \
    LCTL_REVIVE_AFTER_SECOND_QUERY_FOR="$OLD_LABEL" LCTL_REVIVE_AFTER_QUERY_N=3 \
    bash "$SCRIPT" --confirm 2>&1)"
  rc=$?
  assert_true "BLOCKING-1回帰: 対話後・削除直前の再観測で旧の復活を検出し非0終了する" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  assert_true "BLOCKING-1回帰: heal案内が出る" "$(printf '%s' "$out" | grep -q -- "--heal" && echo 1 || echo 0)"
  assert_true "BLOCKING-1回帰: 退避物は削除されない（拒否時点で完全に残る）" \
    "$([ -e "$E/state/stash/${OLD_LABEL}.plist" ] && echo 1 || echo 0)"
  assert_true "BLOCKING-1回帰: phaseはconfirmedへ進まない" \
    "$([ "$(state_field "$E" phase)" != "confirmed" ] && echo 1 || echo 0)"
  # ⚠️ 検証職3巡目対応（偽陽性の是正）: ③（削除直前の再観測）まで実際に
  # 到達したことを、対話受理後にしか書かれないphase=confirmingと、旧ラベル
  # への照会回数が3以上であることの両方で直接確認する。
  assert_eq "BLOCKING-1回帰: 対話を受理しconfirming到達後に拒否された（②では未検出）" \
    "confirming" "$(state_field "$E" phase)"
  assert_true "BLOCKING-1回帰: 旧ラベルへの照会が3回以上行われた（③まで到達した証拠）" \
    "$([ "$(cat "$E/lctl/.query_count_${OLD_LABEL}" 2>/dev/null || echo 0)" -ge 3 ] && echo 1 || echo 0)"
  rm -rf "$E"
}
{
  # 陰性: 復活が起きなければ通常どおり確定できる（回帰試験が過剰検知に
  # なっていないことの確認）。
  E="$(new_env)"
  mkdir -p "$E/lctl/loaded" "$E/lctl/enabled" "$E/state/stash"
  : > "$E/lctl/loaded/$NEW_LABEL"
  : > "$E/lctl/enabled/$NEW_LABEL"
  : > "$E/state/stash/${OLD_LABEL}.plist"
  cat > "$E/state/state.json" <<EOF
{"had_old_job":true,"old_plist_dest":"$E/state/stash/${OLD_LABEL}.plist","phase":"verified"}
EOF
  out="$(AIENV_USAGE_FETCH_TEST=1 AIENV_USAGE_FETCH_CONFIRM_ANSWER=yes \
    HOME="$E/home" AIENV_USAGE_MIGRATION_STATE_DIR="$E/state" AIENV_USAGE_OLD_REPO_DIR="$E/oldrepo" \
    XDG_CACHE_HOME="$E/cache" LCTL_STATE="$E/lctl" \
    bash "$SCRIPT" --confirm 2>&1)"
  rc=$?
  assert_eq "BLOCKING-1陰性: 復活が無ければexit=0" "0" "$rc"
  assert_eq "BLOCKING-1陰性: phase=confirmed" "confirmed" "$(state_field "$E" phase)"
  assert_true "BLOCKING-1陰性: 退避物は削除される" "$([ ! -e "$E/state/stash/${OLD_LABEL}.plist" ] && echo 1 || echo 0)"
  rm -rf "$E"
}

echo "=== 検証職2巡目 BLOCKING-2: state.jsonの未検証パスをrm -rfしない ==="
{
  # old_plist_destが許可ルート（STATE_DIR配下）の外を指す壊れたstate.json
  # を用意し、削除されず拒否されることを確認する（対象=STATE_DIR外の
  # ディレクトリ全体を巻き添えにしない）。
  E="$(new_env)"
  mkdir -p "$E/lctl/loaded" "$E/lctl/enabled" "$E/canary_dir"
  : > "$E/lctl/loaded/$NEW_LABEL"
  : > "$E/lctl/enabled/$NEW_LABEL"
  echo "canary" > "$E/canary_dir/precious-file.txt"
  cat > "$E/state/state.json" <<EOF
{"had_old_job":true,"old_plist_dest":"$E/canary_dir/precious-file.txt","phase":"verified"}
EOF
  out="$(AIENV_USAGE_FETCH_TEST=1 AIENV_USAGE_FETCH_CONFIRM_ANSWER=yes \
    HOME="$E/home" AIENV_USAGE_MIGRATION_STATE_DIR="$E/state" AIENV_USAGE_OLD_REPO_DIR="$E/oldrepo" \
    XDG_CACHE_HOME="$E/cache" LCTL_STATE="$E/lctl" \
    bash "$SCRIPT" --confirm 2>&1)"
  rc=$?
  assert_true "BLOCKING-2回帰: 許可ルート外のold_plist_destは非0で拒否される" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  assert_true "BLOCKING-2回帰: 許可ルート外のファイルは削除されない" \
    "$([ -e "$E/canary_dir/precious-file.txt" ] && echo 1 || echo 0)"
  assert_true "BLOCKING-2回帰: state.jsonが壊れている旨のメッセージが出る" \
    "$(printf '%s' "$out" | grep -q "許可された範囲" && echo 1 || echo 0)"
  rm -rf "$E"
}
{
  # 陰性: STATE_DIR配下の正規の1階層下（タイムスタンプディレクトリ）を
  # 指す場合は削除される（過剰検知になっていないことの確認。既存の
  # 「--verify -> --confirm の正常経路」テストでも間接的に確認済みだが、
  # ここではvalidate_stash_pathの境界（basename一致・1階層限定）を
  # 直接ねらう）。
  E="$(new_env)"
  mkdir -p "$E/lctl/loaded" "$E/lctl/enabled" "$E/state/20260909T000000Z"
  : > "$E/lctl/loaded/$NEW_LABEL"
  : > "$E/lctl/enabled/$NEW_LABEL"
  : > "$E/state/20260909T000000Z/${OLD_LABEL}.plist"
  cat > "$E/state/state.json" <<EOF
{"had_old_job":true,"old_plist_dest":"$E/state/20260909T000000Z/${OLD_LABEL}.plist","phase":"verified"}
EOF
  out="$(AIENV_USAGE_FETCH_TEST=1 AIENV_USAGE_FETCH_CONFIRM_ANSWER=yes \
    HOME="$E/home" AIENV_USAGE_MIGRATION_STATE_DIR="$E/state" AIENV_USAGE_OLD_REPO_DIR="$E/oldrepo" \
    XDG_CACHE_HOME="$E/cache" LCTL_STATE="$E/lctl" \
    bash "$SCRIPT" --confirm 2>&1)"
  rc=$?
  assert_eq "BLOCKING-2陰性: 正規の1階層下パスはexit=0で確定できる" "0" "$rc"
  assert_true "BLOCKING-2陰性: 対象plistは削除される" "$([ ! -e "$E/state/20260909T000000Z/${OLD_LABEL}.plist" ] && echo 1 || echo 0)"
  assert_true "BLOCKING-2陰性: 空になった専用ディレクトリもrmdirされる" "$([ ! -d "$E/state/20260909T000000Z" ] && echo 1 || echo 0)"
  rm -rf "$E"
}

echo "=== 検証職3巡目 MAJOR: validate_stash_path()はsymlinkと'..'を拒否する ==="
{
  # old_plist_destが「STATE_DIR配下の正規の1階層下パス」の形をしていても
  # 実体がsymlinkなら削除しない（symlink先の外部実体を巻き添えにしない）。
  E="$(new_env)"
  mkdir -p "$E/lctl/loaded" "$E/lctl/enabled" "$E/state/20260909T000000Z" "$E/outside"
  : > "$E/lctl/loaded/$NEW_LABEL"
  : > "$E/lctl/enabled/$NEW_LABEL"
  : > "$E/outside/precious-file.txt"
  ln -s "$E/outside/precious-file.txt" "$E/state/20260909T000000Z/${OLD_LABEL}.plist"
  cat > "$E/state/state.json" <<EOF
{"had_old_job":true,"old_plist_dest":"$E/state/20260909T000000Z/${OLD_LABEL}.plist","phase":"verified"}
EOF
  out="$(AIENV_USAGE_FETCH_TEST=1 AIENV_USAGE_FETCH_CONFIRM_ANSWER=yes \
    HOME="$E/home" AIENV_USAGE_MIGRATION_STATE_DIR="$E/state" AIENV_USAGE_OLD_REPO_DIR="$E/oldrepo" \
    XDG_CACHE_HOME="$E/cache" LCTL_STATE="$E/lctl" \
    bash "$SCRIPT" --confirm 2>&1)"
  rc=$?
  assert_true "3巡目MAJOR: symlinkのold_plist_destは非0で拒否される" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  assert_true "3巡目MAJOR: symlink先の外部実体は削除されない" "$([ -e "$E/outside/precious-file.txt" ] && echo 1 || echo 0)"
  assert_true "3巡目MAJOR: symlink自体も削除されない" "$([ -L "$E/state/20260909T000000Z/${OLD_LABEL}.plist" ] && echo 1 || echo 0)"
  rm -rf "$E"
}
{
  # old_plist_destが'..'を含み、文字列上は許可ルート外の実ディレクトリを
  # 指す（STATE_DIRの兄弟ディレクトリへ抜ける）場合を拒否する。
  E="$(new_env)"
  mkdir -p "$E/lctl/loaded" "$E/lctl/enabled" "$E/evil"
  : > "$E/lctl/loaded/$NEW_LABEL"
  : > "$E/lctl/enabled/$NEW_LABEL"
  : > "$E/evil/${OLD_LABEL}.plist"
  cat > "$E/state/state.json" <<EOF
{"had_old_job":true,"old_plist_dest":"$E/state/../evil/${OLD_LABEL}.plist","phase":"verified"}
EOF
  out="$(AIENV_USAGE_FETCH_TEST=1 AIENV_USAGE_FETCH_CONFIRM_ANSWER=yes \
    HOME="$E/home" AIENV_USAGE_MIGRATION_STATE_DIR="$E/state" AIENV_USAGE_OLD_REPO_DIR="$E/oldrepo" \
    XDG_CACHE_HOME="$E/cache" LCTL_STATE="$E/lctl" \
    bash "$SCRIPT" --confirm 2>&1)"
  rc=$?
  assert_true "3巡目MAJOR: '..'を含むold_plist_destは非0で拒否される" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  assert_true "3巡目MAJOR: '..'の指す先は削除されない" "$([ -e "$E/evil/${OLD_LABEL}.plist" ] && echo 1 || echo 0)"
  rm -rf "$E"
}

echo "=== 検証職3巡目 MAJOR: disabled_status()は封筒外・重複ラベルもunknownへ倒す ==="
{
  # 対象ラベルが閉じ括弧`}`の<u>後ろ</u>にある場合（封筒の外）は解析対象に
  # 含めない。
  E="$(new_env)"
  mkdir -p "$E/lctl/loaded"
  cat > "$E/lctl/print_disabled_override.txt" <<EOF
disabled services = {
	"com.other.unrelated-label" => disabled
}
	"$NEW_LABEL" => enabled
EOF
  out="$(HOME="$E/home" AIENV_USAGE_MIGRATION_STATE_DIR="$E/state" AIENV_USAGE_OLD_REPO_DIR="$E/oldrepo" \
    XDG_CACHE_HOME="$E/cache" LCTL_STATE="$E/lctl" bash -c '
      launchctl() {
        if [ "$1" = "print-disabled" ]; then cat "$LCTL_STATE/print_disabled_override.txt"; return 0; fi
        if [ "$1" = "print" ]; then return 0; fi
        return 1
      }
      export -f launchctl
      DOMAIN="gui/0"
      LABEL="'"$NEW_LABEL"'"
      SKIP_LAUNCHCTL=0
      set -uo pipefail
      '"$(sed -n '/^parse_disabled_envelope()/,/^}/p' "$SCRIPT")"'
      '"$(sed -n '/^disabled_status()/,/^}/p' "$SCRIPT")"'
      disabled_status "$LABEL"
    ' 2>&1)"
  assert_eq "3巡目MAJOR: 閉じ括弧の後ろの対象ラベル行は無視されunknown" "unknown" "$out"
  rm -rf "$E"
}
{
  # 対象ラベルがenabledとdisabledで重複して出現する場合もunknown
  # （先頭一致を無条件採用しない）。
  E="$(new_env)"
  mkdir -p "$E/lctl/loaded"
  cat > "$E/lctl/print_disabled_override.txt" <<EOF
disabled services = {
	"$NEW_LABEL" => enabled
	"$NEW_LABEL" => disabled
}
EOF
  out="$(HOME="$E/home" AIENV_USAGE_MIGRATION_STATE_DIR="$E/state" AIENV_USAGE_OLD_REPO_DIR="$E/oldrepo" \
    XDG_CACHE_HOME="$E/cache" LCTL_STATE="$E/lctl" bash -c '
      launchctl() {
        if [ "$1" = "print-disabled" ]; then cat "$LCTL_STATE/print_disabled_override.txt"; return 0; fi
        if [ "$1" = "print" ]; then return 0; fi
        return 1
      }
      export -f launchctl
      DOMAIN="gui/0"
      LABEL="'"$NEW_LABEL"'"
      SKIP_LAUNCHCTL=0
      set -uo pipefail
      '"$(sed -n '/^parse_disabled_envelope()/,/^}/p' "$SCRIPT")"'
      '"$(sed -n '/^disabled_status()/,/^}/p' "$SCRIPT")"'
      disabled_status "$LABEL"
    ' 2>&1)"
  assert_eq "3巡目MAJOR: 対象ラベルの重複出現はunknown" "unknown" "$out"
  rm -rf "$E"
}

echo "=== 検証職3巡目 MAJOR: bootstrap成功・enable未完了の限定局面で手動enableを案内する ==="
{
  # OLD_LOADED=false・新ラベルはloaded・print-disabledは健全だが対象ラベル
  # の記録が無い（＝一度もenableが成功していない）という限定局面で、
  # 汎用の「手動確認: launchctl print」ではなく具体的なenableコマンドを
  # 案内することを確認する（fail-closedの判定自体は変えない）。
  E="$(new_env)"
  mkdir -p "$E/lctl/loaded"
  : > "$E/lctl/loaded/$NEW_LABEL"
  out="$(run_install "$E" --dry-run 2>&1)"
  # --dry-runでも入口検査(inv1_entry_check_or_die)はcmd_dry_run実行前に
  # 通るため、この局面ではdry-runも同じ理由でunknown拒否される。
  rc=$?
  assert_true "3巡目MAJOR: enable未完了の限定局面は非0で拒否される" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  assert_true "3巡目MAJOR: 具体的なlaunchctl enableコマンドを案内する" \
    "$(printf '%s' "$out" | grep -q "launchctl enable gui/.*/${NEW_LABEL}" && echo 1 || echo 0)"
  assert_true "3巡目MAJOR: 再実行の案内も出る" "$(printf '%s' "$out" | grep -q "もう一度" && echo 1 || echo 0)"
  rm -rf "$E"
}

echo "=== 検証職4巡目 MAJOR: 閉じ括弧が単独行でない壊れた封筒はunknownへ倒す ==="
{
  # reviewerの再現ケース: 開始行はあるが、閉じ括弧が単独行ではなく
  # （"malformed }"のように他の文字と同じ行にあり）本当の終端が無いまま
  # 末尾に非空のtrailerが続く。従来のsed範囲指定はこの場合にEOFまで含めて
  # しまい、`sed '$d'`が末尾のtrailer行を誤って閉じ括弧とみなし、途中の
  # 対象ラベル行を有効な封筒内の記述として誤判定していた。
  E="$(new_env)"
  mkdir -p "$E/lctl/loaded"
  cat > "$E/lctl/print_disabled_override.txt" <<EOF
disabled services = {
    "$NEW_LABEL" => enabled
malformed }
trailer
EOF
  out="$(HOME="$E/home" AIENV_USAGE_MIGRATION_STATE_DIR="$E/state" AIENV_USAGE_OLD_REPO_DIR="$E/oldrepo" \
    XDG_CACHE_HOME="$E/cache" LCTL_STATE="$E/lctl" bash -c '
      launchctl() {
        if [ "$1" = "print-disabled" ]; then cat "$LCTL_STATE/print_disabled_override.txt"; return 0; fi
        if [ "$1" = "print" ]; then return 0; fi
        return 1
      }
      export -f launchctl
      DOMAIN="gui/0"
      LABEL="'"$NEW_LABEL"'"
      SKIP_LAUNCHCTL=0
      set -uo pipefail
      '"$(sed -n '/^parse_disabled_envelope()/,/^}/p' "$SCRIPT")"'
      '"$(sed -n '/^disabled_status()/,/^}/p' "$SCRIPT")"'
      disabled_status "$LABEL"
    ' 2>&1)"
  assert_eq "4巡目MAJOR: 単独行でない閉じ括弧＋末尾trailerはunknown" "unknown" "$out"
  rm -rf "$E"
}
{
  # 同ケースをe2eでも確認する（新ラベルloaded・旧ラベル不在で
  # --dry-runしてもNEW_ACTIVE=trueにならず、fail-closedで非0のまま
  # 破壊的操作が0件であることを実測する）。
  E="$(new_env)"
  mkdir -p "$E/lctl/loaded"
  : > "$E/lctl/loaded/$NEW_LABEL"
  : > "$(new_plist_path "$E")"
  before_lctl_files="$(find "$E/lctl" -type f | sort)"
  out="$(HOME="$E/home" AIENV_USAGE_MIGRATION_STATE_DIR="$E/state" AIENV_USAGE_OLD_REPO_DIR="$E/oldrepo" \
    XDG_CACHE_HOME="$E/cache" LCTL_STATE="$E/lctl" LCTL_PRINTDISABLED_MALFORMED_CLOSE=1 \
    bash "$SCRIPT" --rollback 2>&1)"
  rc=$?
  after_lctl_files="$(find "$E/lctl" -type f | sort)"
  assert_true "4巡目MAJOR(e2e): 単独行でない閉じ括弧は非0終了" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  assert_eq "4巡目MAJOR(e2e): launchctl状態ファイルは1件も変化しない（破壊的操作ゼロ）" "$before_lctl_files" "$after_lctl_files"
  rm -rf "$E"
}

echo "=== 検証職4巡目 MAJOR: enable未完了診断はラベル欠落以外を誤診しない ==="
{
  # 重複競合（disabled_status()自体はunknownを返す）のとき、
  # diagnose_new_active_unknown()が「ラベル欠落」と誤診して具体的な
  # enable案内を出さないこと（＝汎用の照会不能メッセージへ倒れる）を
  # 確認する。
  E="$(new_env)"
  mkdir -p "$E/lctl/loaded"
  : > "$E/lctl/loaded/$NEW_LABEL"
  : > "$(new_plist_path "$E")"
  out="$(HOME="$E/home" AIENV_USAGE_MIGRATION_STATE_DIR="$E/state" AIENV_USAGE_OLD_REPO_DIR="$E/oldrepo" \
    XDG_CACHE_HOME="$E/cache" LCTL_STATE="$E/lctl" LCTL_PRINTDISABLED_DUPLICATE_FOR="$NEW_LABEL" \
    bash "$SCRIPT" --rollback 2>&1)"
  rc=$?
  assert_true "4巡目MAJOR: 重複競合は非0で拒否される" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  assert_true "4巡目MAJOR: 重複競合では具体的なenable案内を出さない（誤診しない）" \
    "$(printf '%s' "$out" | grep -q "launchctl enable" && echo 0 || echo 1)"
  rm -rf "$E"
}

echo "=== 検証職5巡目 MAJOR: 開始行より前にある単独'}'を無視しない ==="
{
  # reviewerの再現ケース: 正規の封筒の<u>前</u>に単独の'}'行がある。従来は
  # 単独'}'を「開始行を読んだ後（state==1）」のときだけ数えていたため、
  # 開始前の'}'が完全に無視され、その後に続く正規の封筒がそのまま
  # 正常（enabled）と判定されてしまっていた。
  E="$(new_env)"
  mkdir -p "$E/lctl/loaded"
  cat > "$E/lctl/print_disabled_override.txt" <<EOF
}
disabled services = {
    "$NEW_LABEL" => enabled
}
EOF
  out="$(HOME="$E/home" AIENV_USAGE_MIGRATION_STATE_DIR="$E/state" AIENV_USAGE_OLD_REPO_DIR="$E/oldrepo" \
    XDG_CACHE_HOME="$E/cache" LCTL_STATE="$E/lctl" bash -c '
      launchctl() {
        if [ "$1" = "print-disabled" ]; then cat "$LCTL_STATE/print_disabled_override.txt"; return 0; fi
        if [ "$1" = "print" ]; then return 0; fi
        return 1
      }
      export -f launchctl
      DOMAIN="gui/0"
      LABEL="'"$NEW_LABEL"'"
      SKIP_LAUNCHCTL=0
      set -uo pipefail
      '"$(sed -n '/^parse_disabled_envelope()/,/^}/p' "$SCRIPT")"'
      '"$(sed -n '/^disabled_status()/,/^}/p' "$SCRIPT")"'
      disabled_status "$LABEL"
    ' 2>&1)"
  assert_eq "5巡目MAJOR: 開始行より前の単独'}'はmalformedとしてunknown" "unknown" "$out"
  rm -rf "$E"
}
{
  # 同ケースをe2eでも確認する（新ラベルloaded・旧ラベル不在で
  # --rollbackしてもNEW_ACTIVE=trueにならず、fail-closedで非0のまま
  # 破壊的操作が0件であることを実測する）。
  E="$(new_env)"
  mkdir -p "$E/lctl/loaded"
  : > "$E/lctl/loaded/$NEW_LABEL"
  : > "$(new_plist_path "$E")"
  before_lctl_files="$(find "$E/lctl" -type f | sort)"
  out="$(HOME="$E/home" AIENV_USAGE_MIGRATION_STATE_DIR="$E/state" AIENV_USAGE_OLD_REPO_DIR="$E/oldrepo" \
    XDG_CACHE_HOME="$E/cache" LCTL_STATE="$E/lctl" LCTL_PRINTDISABLED_LEADING_BRACE=1 \
    bash "$SCRIPT" --rollback 2>&1)"
  rc=$?
  after_lctl_files="$(find "$E/lctl" -type f | sort)"
  assert_true "5巡目MAJOR(e2e): 開始行より前の単独'}'は非0終了" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  assert_eq "5巡目MAJOR(e2e): launchctl状態ファイルは1件も変化しない（破壊的操作ゼロ）" "$before_lctl_files" "$after_lctl_files"
  rm -rf "$E"
}

echo "=== 検証職2巡目 MAJOR-2: --dry-runと他モードの併用・複数モード指定を拒否する ==="
{
  E="$(new_env)"
  out="$(run_install "$E" --dry-run --confirm 2>&1)"
  rc=$?
  assert_true "MAJOR-2回帰: --dry-run --confirm併用は拒否される" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  rm -rf "$E"
}
{
  E="$(new_env)"
  out="$(run_install "$E" --rollback --confirm 2>&1)"
  rc=$?
  assert_true "MAJOR-2回帰: 複数モード同時指定(--rollback --confirm)は拒否される" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  rm -rf "$E"
}
{
  # 陰性: 単独の--dry-runは従来どおり動く（過剰検知でないことの確認）。
  E="$(new_env)"
  out="$(run_install "$E" --dry-run 2>&1)"
  rc=$?
  assert_eq "MAJOR-2陰性: 単独--dry-runはexit=0のまま" "0" "$rc"
  rm -rf "$E"
}

echo "=== --dry-run: 副作用ゼロ ==="
{
  E="$(new_env)"
  out="$(run_install "$E" --dry-run 2>&1)"
  rc=$?
  assert_eq "dry-run: exit=0" "0" "$rc"
  assert_true "dry-run: state.jsonを作らない" "$([ ! -f "$E/state/state.json" ] && echo 1 || echo 0)"
  assert_true "dry-run: 新plistを作らない" "$([ ! -e "$(new_plist_path "$E")" ] && echo 1 || echo 0)"
  rm -rf "$E"
}

echo
echo "======================================================================"
echo "結果: PASS=$PASS FAIL=$FAIL"
echo "======================================================================"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
