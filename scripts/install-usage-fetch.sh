#!/usr/bin/env bash
# 使用率取得器 LaunchAgent（com.takumi009.usage-fetch）のインストーラ／
# 旧ジョブ（com.claude-codex-usage.refresh）からの移行・巻き戻し・復旧
# （B1-b・使用率取得器移設）。
#
# 要件＝ローカルLLM段階経路-要件-2026-09-03.md v20 FR-77b・AC-98。
# 設計＝docs/core-split/使用率取得器移設B1b-設計-2026-09-08.md §2.4・§3。
#
# ⚠️ 安全の判断は毎回の「観測」だけで行う（state.jsonは判断に使わない）。
# 観測する4つの事実＝OLD_LOADED（旧が launchd にロード済みか）・
# NEW_ACTIVE（新がロード済みかつ非disabledか）・OLD_PLIST_AT（旧plistが
# 元の場所／退避先のどちらにあるか、独立に見る）・OLD_CODE（旧repoの
# 取得コードが残っているか）。
#
# ⚠️ 守る不変条件（INV-1〜INV-4。設計書§2.4）＝
#   INV-1 OLD_LOADEDとNEW_ACTIVEが同時に真になる瞬間が無い（二重取得ゼロ）。
#         --healを除くすべての口で入口検査＋ジョブを有効化する操作の直前に
#         もう一度検査する（2段構え）。
#   INV-2 旧を止める操作は新を起動する操作より厳密に先。
#   INV-3 巻き戻せる期間中は、旧を復元する手段（退避plist または
#         旧repoのinstall.sh）が完全な形で残っている。
#   INV-4 launchdへの照会が機能しない（unknown）ときは破壊的操作へ進まない
#         （fail-closed）。
#
# state.json（$STATE_DIR/state.json）が持つのは「観測できないこと」だけ＝
# had_old_job（この機がもともと旧ジョブを持っていたか）・old_plist_dest
# （退避先）・phase（何をしようとしていたか＝中断からの再開のためだけに
# 使う。安全の判断には一切使わない）・test_mode（SKIP_LAUNCHCTL=1で
# 作った状態の印）。
#
# 使い方:
#   scripts/install-usage-fetch.sh                # 実行（経路を自動判定し a→b→c→d）
#   scripts/install-usage-fetch.sh --dry-run       # 計画だけ表示（何もしない）
#   scripts/install-usage-fetch.sh --capture-display  # 移行前に表示を記録
#   scripts/install-usage-fetch.sh --verify        # (c)の再確認＋表示比較＋本人確認 -> verified
#   scripts/install-usage-fetch.sh --confirm       # 本人確認のうえ退避物を削除 -> confirmed
#   scripts/install-usage-fetch.sh --rollback      # 観測した局面に応じて安全に戻す
#   scripts/install-usage-fetch.sh --heal          # 二重取得（INV-1違反）から復旧する唯一の口
#
# テスト専用: SKIP_LAUNCHCTL=1 は AIENV_USAGE_FETCH_TEST=1 と併用したときだけ
# 受け付ける（単独指定は拒否＝D-17・本番での誤用防止）。受け付けた場合は
# 実launchdへ一切問い合わせず、plistの配置・退避などファイル操作だけを行う。
# AIENV_USAGE_FETCH_TEST=1 のときは --verify・--confirm の対話質問を
# AIENV_USAGE_FETCH_VERIFY_ANSWER／AIENV_USAGE_FETCH_CONFIRM_ANSWER で
# 非対話に答えられる。AIENV_USAGE_MIGRATION_STATE_DIR・
# AIENV_USAGE_FETCH_LAUNCHAGENTS_DIR・AIENV_USAGE_OLD_REPO_DIR・
# XDG_CACHE_HOME はいずれもテスト用の差し替え口。

set -uo pipefail

: "${SKIP_LAUNCHCTL:=0}"
: "${AIENV_USAGE_FETCH_TEST:=0}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST_NAME="com.takumi009.usage-fetch.plist"
SRC="$DIR/launchagents/$PLIST_NAME"
LAUNCH_AGENTS_DIR="${AIENV_USAGE_FETCH_LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}"
DEST="$LAUNCH_AGENTS_DIR/$PLIST_NAME"
LABEL="com.takumi009.usage-fetch"
OLD_LABEL="com.claude-codex-usage.refresh"
OLD_PLIST_NAME="${OLD_LABEL}.plist"
OLD_PLIST_SRC="$LAUNCH_AGENTS_DIR/$OLD_PLIST_NAME"
DOMAIN="gui/$(id -u)"

STATE_DIR="${AIENV_USAGE_MIGRATION_STATE_DIR:-$HOME/.local/state/takumi009-ai-env/usage-migration}"
STATE_FILE="$STATE_DIR/state.json"
OLD_REPO_DIR="${AIENV_USAGE_OLD_REPO_DIR:-$HOME/work/claude-codex-usage}"
OLD_REPO_REFRESH="$OLD_REPO_DIR/refresh.sh"
OLD_REPO_INSTALLER="$OLD_REPO_DIR/install.sh"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-codex-usage"
CLAUDE_CACHE="$CACHE_DIR/claude-cache.json"
CODEX_CACHE="$CACHE_DIR/codex-cache.json"
DISPLAY_CAPTURE_FILE="$STATE_DIR/display-before.txt"

log() { echo "[install-usage-fetch] $*"; }
warn() { echo "[install-usage-fetch] WARN: $*" >&2; }
fail() { echo "[install-usage-fetch] FAIL: $*" >&2; exit 1; }

# ⚠️ D-17・T-16: SKIP_LAUNCHCTL=1 の本番での誤用を規定で塞ぐ。
if [ "$SKIP_LAUNCHCTL" = "1" ] && [ "$AIENV_USAGE_FETCH_TEST" != "1" ]; then
  fail "SKIP_LAUNCHCTL=1 は AIENV_USAGE_FETCH_TEST=1 と併用したときだけ受け付けます（本番での誤用防止）。単独指定は拒否します。"
fi

command -v jq >/dev/null 2>&1 || fail "jq が見つかりません。"

test_mode_json() { [ "$SKIP_LAUNCHCTL" = "1" ] && echo true || echo false; }

# ============================================================
# 観測（label_status・disabled_status は4値: loaded/not_loaded/unknown/skip）
# ============================================================

label_status() {
  local label="$1"
  if [ "$SKIP_LAUNCHCTL" = "1" ]; then echo skip; return; fi
  if ! launchctl print "$DOMAIN" >/dev/null 2>&1; then echo unknown; return; fi
  if launchctl print "$DOMAIN/$label" >/dev/null 2>&1; then echo loaded; else echo not_loaded; fi
}

# launchctl print-disabled の出力を解析する。解析できなければ unknown
# （fail-closed）。
# ⚠️ 検証職1巡目MAJOR-3対応: 出力全体が既知の封筒（`disabled services = {`
# を含む）であることをまず確認する。
# ⚠️ 検証職2巡目MAJOR-1対応（強化）: 封筒は開始`{`だけでなく終端`}`も
# 含むことを要求する。対象ラベルの行が封筒内に見つからない場合も無条件に
# `enabled` とみなさず `unknown` にする（設計書の観測表「print-disabledが
# 非0・解析不能・ラベル欠落ならunknown」に従う）＝print-disabledは
# 「override（明示的にenable/disableされた記録）」だけを列挙し、override
# が無いラベルの実効値はそのplist自身のDisabledキーに従うため、override
# 一覧に無いことだけでは「enabled」と断定できない（実測: `launchctl
# print-disabled gui/<uid>` の実出力は全体のロード済みラベル数より
# はるかに少ない22件程度で、一度もenable/disableを明示呼び出しして
# いないラベルは掲載されない）。値トークンは既知の語彙（macOS Ventura
# 以降="disabled"/"enabled"・それ以前="true"/"false"＝実測: launchctl(1)
# の表記はOS版で変わる）とだけ照合し、それ以外の未知トークンも unknown。
# ⚠️ 検証職3巡目MAJOR対応: 解析範囲を封筒本体（開始行〜単独`}`行の
# あいだ）だけに限定し、対象ラベル行が<u>厳密に1件</u>のときだけ判定する
# （0件・2件以上はどちらもunknown）。
# ⚠️ 検証職4巡目MAJOR対応（さらに強化）: (a) 従来のsed範囲指定は「単独の
# 終了行」が最後まで見つからない場合にEOFまで含めてしまい、`sed '$d'`が
# 末尾行（`malformed }`のような、閉じ括弧を含むが単独行ではない行）を
# 誤って閉じ括弧とみなしていた。開始行・単独終了行がそれぞれ<u>厳密に
# 1件</u>・正しい順序（開始→終了→その後は空行のみ）で揃っていることを、
# 単一のawk状態機械で検証する形へ作り直した。(b) `diagnose_new_active_
# unknown()`が独自の緩い封筒判定を再実装しており、重複・未知値・壊れた
# 封筒のいずれも「ラベル欠落」と誤診していた（reviewer実測）。状態判定と
# 診断理由を同じ`parse_disabled_envelope()`から返す形に一本化した。
# 出力: "<status> <reason>"。status ∈ {disabled,enabled,unknown}。
# reason ∈ {ok,no-communication,malformed,label-absent,label-duplicate,
# unknown-value}（statusがdisabled/enabledのときはreason=ok）。
# ⚠️ 検証職5巡目MAJOR対応: 従来は単独`}`行を「開始行を読んだ後（state==1）
# のときだけ」数えていたため、開始行より<u>前</u>に現れる単独`}`行が
# 完全に無視され、その後に続く正規の封筒（開始→本体→終了）がそのまま
# 正常と判定されてしまっていた（実運用で踏む見込みは低いが、INV-4の
# 「解析不能ならunknown」という契約には違反する）。単独`}`行は状態に
# 関わらず<u>常に</u>数え、想定した順序（開始の前に現れる／開始後の本体
# 中に2件目が現れる等）以外で現れたら即座にmalformedとする。開始行の
# 正規表現も行頭を固定し（`^[[:space:]]*disabled services = \{...$`）、
# 他の文字列の一部として出現した場合を開始行と誤認しないようにした。
parse_disabled_envelope() {
  local label="$1" out rc
  out="$(launchctl print-disabled "$DOMAIN" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then printf 'unknown no-communication'; return; fi
  printf '%s\n' "$out" | awk -v label="$label" '
    BEGIN { state = 0; opens = 0; closes = 0; matches = 0; value = ""; malformed = 0 }
    /^[[:space:]]*disabled services = \{[[:space:]]*$/ {
      opens++
      if (state != 0) { malformed = 1 }
      state = 1
      next
    }
    /^[[:space:]]*\}[[:space:]]*$/ {
      closes++
      if (state != 1) { malformed = 1 }
      state = 2
      next
    }
    state == 1 {
      key = "\"" label "\" =>"
      if (index($0, key) == 0) { next }
      matches++
      v = $0
      sub(/.*=>[[:space:]]*/, "", v)
      gsub(/[[:space:]]/, "", v)
      value = v
      next
    }
    state == 2 && NF > 0 { malformed = 1 }
    END {
      if (malformed || opens != 1 || closes != 1) { print "unknown malformed"; exit }
      if (matches == 0) { print "unknown label-absent"; exit }
      if (matches > 1) { print "unknown label-duplicate"; exit }
      if (value == "disabled" || value == "true") { print "disabled ok"; exit }
      if (value == "enabled" || value == "false") { print "enabled ok"; exit }
      print "unknown unknown-value"
    }
  '
}

disabled_status() {
  local label="$1" result
  if [ "$SKIP_LAUNCHCTL" = "1" ]; then echo skip; return; fi
  result="$(parse_disabled_envelope "$label")"
  printf '%s' "${result%% *}"
}

# NEW_ACTIVE = 新ラベルが loaded かつ非disabled。
new_active() {
  local ls ds
  ls="$(label_status "$LABEL")"
  case "$ls" in
    unknown) echo unknown; return ;;
    skip) echo skip; return ;;
    not_loaded) echo false; return ;;
  esac
  ds="$(disabled_status "$LABEL")"
  case "$ds" in
    unknown) echo unknown ;;
    skip) echo skip ;;
    disabled) echo false ;;
    enabled) echo true ;;
  esac
}

# OLD_LOADED = 旧ラベルが launchd にロード済みか。
old_loaded() {
  local ls
  ls="$(label_status "$OLD_LABEL")"
  case "$ls" in
    unknown) echo unknown ;;
    skip) echo skip ;;
    loaded) echo true ;;
    not_loaded) echo false ;;
  esac
}

old_plist_at_original() { [ -e "$OLD_PLIST_SRC" ] && echo true || echo false; }
old_plist_at_stash() {
  local dest
  dest="$(state_get old_plist_dest)"
  [ -n "$dest" ] && [ -e "$dest" ] && echo true || echo false
}
old_code_present() { [ -f "$OLD_REPO_REFRESH" ] && echo true || echo false; }

# ⚠️ 検証職2巡目BLOCKING-2対応: state.jsonのold_plist_destを`rm -rf`する前に、
# それが許可ルート（$STATE_DIR配下の1階層下＝タイムスタンプディレクトリ）に
# 実在して収まっていることを検証する。state_valid()はJSON構文しか検証せず、
# basename・所属・symlinkは見ていなかった＝壊れたstateに任意パスが入ると
# 退避領域外を再帰削除しうる穴があった（claude-codex-usage側の
# `uninstall.sh --purge-cache` と同じ「削除対象を許可ルート配下に限定して
# からcanonicalizeで確認する」型を踏襲）。成功時は削除してよい実ファイルの
# canonicalパスを1行で返す。
# ⚠️ 検証職3巡目MAJOR対応: `[ -f "$dest" ]`はsymlinkを追跡してしまい
# （symlink先が通常ファイルなら真になる）、symlinkそのものを拒否できて
# いなかった。`[ ! -L "$dest" ]`を`-e`/`-f`より先に必須化する。さらに、
# 入力パス文字列に`..`コンポーネントが含まれる場合は多重防御としてその場で
# 拒否する（cd+pwd -Pによるcanonicalize自体は正しく解決するが、`..`を含む
# 入力を一切信用しない方針を徹底する）。
validate_stash_path() {
  local dest="$1" canon_state canon_dir canon_full
  [ -n "$dest" ] || return 1
  case "$dest" in
    */../*|*/..|../*|..) return 1 ;;
  esac
  [ ! -L "$dest" ] || return 1  # symlinkは受理しない（-e/-fより先に検査）
  [ -e "$dest" ] || return 1
  [ -f "$dest" ] || return 1  # 通常ファイルであること
  [ "$(basename "$dest")" = "$OLD_PLIST_NAME" ] || return 1
  canon_state="$(cd "$STATE_DIR" 2>/dev/null && pwd -P)" || return 1
  canon_dir="$(cd "$(dirname "$dest")" 2>/dev/null && pwd -P)" || return 1
  case "$canon_dir" in
    "$canon_state"/*) : ;;
    *) return 1 ;;
  esac
  local rel="${canon_dir#"$canon_state"/}"
  # STATE_DIR直下の1階層（タイムスタンプディレクトリ）に限定する（それより
  # 浅い＝STATE_DIR自体・深い＝想定外のネストはいずれも拒否）。
  case "$rel" in
    ""|*/*) return 1 ;;
  esac
  canon_full="$canon_dir/$OLD_PLIST_NAME"
  # 入力パス自身の実体（symlinkチェーン込みの解決先）が、算出した
  # canonical pathと厳密一致することも確認する（basename文字列の一致だけに
  # 頼らない二重検査）。
  [ "$(cd "$(dirname "$dest")" 2>/dev/null && pwd -P)/$(basename "$dest")" = "$canon_full" ] || return 1
  printf '%s' "$canon_full"
  return 0
}

# ============================================================
# 有効化操作（bootstrap/enable）の直前ガード（INV-1(b)）
# ⚠️ 検証職1巡目BLOCKING対応: 「有効化する操作の直前に、その都度もう一度
# 検査する」を、シーケンス全体の入口で1回だけ検査するのではなく、
# bootstrap/enable のそれぞれの呼び出し **1回ごと** に直前で検査する形へ
# 徹底する（再試行経路の enable・2回目の bootstrap・最終 enable も含む
# 全操作を共通関数経由に限定し、素の launchctl 呼び出しを個別箇所に
# 残さない）。
# ============================================================

# 新ジョブを有効化する直前に、OLD_LOADED が真でないことを確認する。
# true/unknown ならこの呼び出し自体を実行せず非0を返す（fail-closed）。
guard_activate_new() {
  local ol
  ol="$(old_loaded)"
  if [ "$ol" = "unknown" ]; then
    warn "有効化直前にOLD_LOADEDが確認できませんでした（INV-4）。この操作は実行しません。"
    return 1
  fi
  if [ "$ol" = "true" ]; then
    warn "有効化直前に旧ジョブ（${OLD_LABEL}）の復活を検出しました。この操作は実行しません（INV-1）。復旧: $0 --heal"
    return 1
  fi
  return 0
}
launchctl_bootstrap_new() {
  guard_activate_new || return 1
  launchctl bootstrap "$DOMAIN" "$DEST" 2>/dev/null
}
launchctl_enable_new() {
  guard_activate_new || return 1
  launchctl enable "$DOMAIN/$LABEL" 2>/dev/null
}

# 旧ジョブを有効化する直前に、NEW_ACTIVE が真でないことを確認する。
guard_activate_old() {
  local na
  na="$(new_active)"
  if [ "$na" = "unknown" ]; then
    warn "有効化直前にNEW_ACTIVEが確認できませんでした（INV-4）。この操作は実行しません。"
    return 1
  fi
  if [ "$na" = "true" ]; then
    warn "有効化直前に新ジョブがまだ有効であることを検出しました。この操作は実行しません（INV-1）。復旧: $0 --heal"
    return 1
  fi
  return 0
}
launchctl_bootstrap_old() {
  guard_activate_old || return 1
  launchctl bootstrap "$DOMAIN" "$OLD_PLIST_SRC" 2>/dev/null
}
launchctl_enable_old() {
  guard_activate_old || return 1
  launchctl enable "$DOMAIN/$OLD_LABEL" 2>/dev/null
}

# ============================================================
# state.json（観測できないことだけを持つ。安全の判断には使わない）
# ============================================================

state_valid() { [ -f "$STATE_FILE" ] && jq -e . "$STATE_FILE" >/dev/null 2>&1; }
state_get() {
  state_valid || { echo ""; return; }
  # ⚠️ jqの`//`は`false`も"無い"扱いにする（`false // empty`はemptyを返す）。
  # had_old_job=falseを正しく読むため、has()判定+tostringで真偽値を保つ。
  jq -r --arg f "$1" 'if (has($f) and (.[$f] != null)) then (.[$f] | tostring) else empty end' "$STATE_FILE" 2>/dev/null
}
state_delete() { rm -f "$STATE_FILE" 2>/dev/null; }

# $1=jqフィルタ、残りはjqへそのまま渡す（--arg/--argjson等）。原子的書き出し。
state_apply() {
  local filter="$1"; shift
  local current tmp
  mkdir -p "$STATE_DIR" 2>/dev/null || return 1
  if state_valid; then current="$(cat "$STATE_FILE")"; else current='{}'; fi
  tmp="$STATE_DIR/.tmp.state.json.$$"
  if ! printf '%s' "$current" | jq -c "$@" "$filter" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"; return 1
  fi
  mv -f "$tmp" "$STATE_FILE" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

# ⚠️ 検証職3巡目MAJOR対応: NEW_ACTIVEがunknownになる理由を診断する。
# 「print-disabledそのものへの照会が機能しない（非0・封筒不明）」場合と
# 「照会は健全だが対象ラベルの記録が封筒に無い（一度もenable/disableを
# 呼んでいないだけ＝自プロセス自身がbootstrapした直後でenable未完了、
# という無害な中間状態でも起こりうる）」場合とでは、本人に案内すべき
# 復旧手順が異なる（前者は原因不明なので汎用の手動確認、後者は
# `launchctl enable`を実行すれば解決する具体的な手順を示せる）。
# fail-closedの判定自体（unknownなら常に中止）は変えない＝案内文の
# 出し分けだけを行う。
# ⚠️ 検証職4巡目MAJOR対応: 独自の緩い封筒判定（`{`と`}`が任意位置に
# あるかだけを見る）を再実装しており、重複競合・未知値・壊れた封筒の
# いずれも「ラベル欠落」と誤診していた（reviewer実測）。disabled_status()
# と同じ`parse_disabled_envelope()`から理由を直接受け取る形に一本化し、
# 状態判定と診断理由の解釈がずれないようにする。
diagnose_new_active_unknown() {
  local result
  result="$(parse_disabled_envelope "$LABEL")"
  printf '%s' "${result#* }"
}

# 上記の診断結果から、NEW_ACTIVEがunknownである理由が「新ラベルは
# loaded済みだがenableがまだ封筒に記録されていない」という限定局面
# （OLD_LOADEDは確定してfalse）に当てはまるときだけ真を返す。
new_active_unknown_is_enable_pending() {
  [ "$(old_loaded)" = "false" ] || return 1
  [ "$(label_status "$LABEL")" = "loaded" ] || return 1
  [ "$(new_active)" = "unknown" ] || return 1
  [ "$(diagnose_new_active_unknown)" = "label-absent" ] || return 1
  return 0
}

inv4_unknown_message() {
  local generic="launchd への照会状態が確認できません（INV-4・fail-closed）。手動確認: launchctl print ${DOMAIN}"
  if new_active_unknown_is_enable_pending; then
    printf '%s' "新ジョブ（${LABEL}）は launchd にロード済みですが、enable が完了したか launchd へ照会できません（print-disabled にこのラベルの記録が無いため。INV-4・fail-closed）。手動で確認のうえ次を実行してください: launchctl enable ${DOMAIN}/${LABEL} 。完了後、もう一度 $0 を実行してください。"
    return
  fi
  printf '%s' "$generic"
}

# ============================================================
# INV-1 入口検査（--heal を除くすべての口が最初に呼ぶ）
# ============================================================

inv1_entry_check_or_die() {
  local ol na
  ol="$(old_loaded)"
  na="$(new_active)"
  if [ "$ol" = "unknown" ] || [ "$na" = "unknown" ]; then
    fail "$(inv4_unknown_message)"
  fi
  if [ "$ol" = "true" ] && [ "$na" = "true" ]; then
    fail "旧（${OLD_LABEL}）と新（${LABEL}）が両方 launchd にロードされています（二重取得＝INV-1違反）。復旧: $0 --heal"
  fi
}

# ============================================================
# 経路の決定（had_old_job が正本。未記録なら観測から決める）
# ============================================================

determine_route() {
  local had
  had="$(state_get had_old_job)"
  if [ "$had" = "true" ]; then echo 1; return; fi
  if [ "$had" = "false" ]; then echo 2; return; fi
  local at_orig at_stash ol
  at_orig="$(old_plist_at_original)"
  at_stash="$(old_plist_at_stash)"
  ol="$(old_loaded)"
  if [ "$at_orig" = "false" ] && [ "$at_stash" = "false" ] && [ "$ol" = "false" ]; then
    echo 2
  else
    echo 1
  fi
}

ensure_started() {
  local had
  had="$(state_get had_old_job)"
  [ -n "$had" ] && return 0
  local route
  route="$(determine_route)"
  if [ "$route" = "2" ]; then
    state_apply '.had_old_job=false | .phase="starting" | .test_mode=$tm' --argjson tm "$(test_mode_json)" \
      || fail "state.json への記録に失敗しました（ディスク容量・権限を確認してください）。"
  else
    state_apply '.had_old_job=true | .phase="starting" | .test_mode=$tm' --argjson tm "$(test_mode_json)" \
      || fail "state.json への記録に失敗しました（ディスク容量・権限を確認してください）。"
  fi
}

# ============================================================
# render_plist（__AIENV_HOME__ 置換）
# ============================================================

render_plist() {
  local escaped_home
  escaped_home=$(printf '%s' "$HOME" | sed -e 's/[&\]/\\&/g' -e 's/#/\\#/g')
  sed "s#__AIENV_HOME__#${escaped_home}#g" "$SRC"
}

# ============================================================
# a: stop-old（経路1のときだけ呼ばれる）
# ============================================================

step_a_stop_old() {
  inv1_entry_check_or_die
  local dest
  dest="$STATE_DIR/$(date -u +%Y%m%dT%H%M%SZ)/$OLD_PLIST_NAME"
  # 記録が先（mv の後に記録すると、mv 直後に落ちたときに退避先を誰も
  # 知らない状態が残る）。⚠️ phase はまだ old-stopped にしない
  # （まだ何も止めていない）。
  state_apply '.old_plist_src=$s' --arg s "$OLD_PLIST_SRC" || fail "state.json記録に失敗しました。まだ何も操作していません。"

  if [ "$SKIP_LAUNCHCTL" != "1" ]; then
    launchctl bootout "$DOMAIN/$OLD_LABEL" 2>/dev/null || true
  fi
  local after
  after="$(label_status "$OLD_LABEL")"
  case "$after" in
    loaded)
      fail "旧ジョブ（${OLD_LABEL}）のbootoutを実行しましたが、まだ launchd にロードされたままです。手動確認: launchctl print ${DOMAIN}/${OLD_LABEL}"
      ;;
    unknown)
      fail "旧ジョブ（${OLD_LABEL}）の事後状態を launchd 照会で確認できませんでした（INV-4・fail-closed）。手動確認: launchctl print ${DOMAIN}"
      ;;
  esac

  # 旧plistが元の場所に実在するときだけ退避する（実在しない＝「plistは無いが
  # loadedだった」経路。この機は退避物を持たないため、巻き戻しはINV-3の
  # 「旧repoのinstall.sh」経路に依る）。
  if [ -e "$OLD_PLIST_SRC" ]; then
    mkdir -p "$(dirname "$dest")" 2>/dev/null || fail "退避先ディレクトリを作成できませんでした: $(dirname "$dest")"
    if mv -f "$OLD_PLIST_SRC" "$dest" 2>/dev/null; then
      state_apply '.old_plist_dest=$d | .phase="old-stopped"' --arg d "$dest" \
        || fail "phase更新に失敗しました。旧plistは退避済みです: $dest"
    else
      fail "旧plistの退避（mv）に失敗しました。旧は停止済み・plistは元の場所（${OLD_PLIST_SRC}）にあります＝再ログインで復活しうるので、手動で退避してください: mv ${OLD_PLIST_SRC} ${dest}"
    fi
  else
    state_apply '.old_plist_dest=null | .phase="old-stopped"' \
      || fail "旧ジョブは停止しましたが、state.json（phase=old-stopped）の記録に失敗しました。$0 をもう一度実行すると記録を追いつかせられます。"
  fi
  log "旧ジョブ（${OLD_LABEL}）を停止しました。"
}

# ============================================================
# b: install-new（両経路共通・冪等）
# ============================================================

step_b_install_new() {
  inv1_entry_check_or_die
  mkdir -p "$LAUNCH_AGENTS_DIR" 2>/dev/null || fail "LaunchAgentsディレクトリを作成できませんでした: $LAUNCH_AGENTS_DIR"

  # ⚠️ 検証職1巡目MAJOR-4対応: state.jsonの記録失敗を握りつぶさない。
  # 実際のlaunchctl操作（プレースホルダ以下参照）自体は継続するが
  # （記録の失敗だけを理由にジョブを止めない＝ジョブが動いていること自体は
  # 安全側）、最後にまとめて非0で返し、完了済みの外部操作と再開手順を示す。
  local state_write_failed=0

  local content_matches=0
  if [ -f "$DEST" ]; then
    local tmp_check
    tmp_check="$(mktemp)"
    render_plist > "$tmp_check"
    cmp -s "$tmp_check" "$DEST" && content_matches=1
    rm -f "$tmp_check"
  fi

  if [ "$content_matches" != "1" ]; then
    local tmp
    tmp="$(mktemp "$LAUNCH_AGENTS_DIR/.$(basename "$DEST").aienv-tmp.XXXXXX")" || fail "一時ファイルを作成できませんでした。"
    render_plist > "$tmp" || { rm -f "$tmp"; fail "plistの生成に失敗しました。"; }
    mv -f "$tmp" "$DEST" || { rm -f "$tmp"; fail "plistの配置（mv）に失敗しました。"; }
    log "新plistを配置しました: $DEST"
  else
    log "新plistは既に配置済みで内容も一致しているため、再配置はスキップします: $DEST"
  fi
  if ! state_apply '.phase="new-placed"'; then
    warn "新plistの配置は完了しましたが、state.json（phase=new-placed）の記録に失敗しました。$0 をもう一度実行すると記録を追いつかせられます。"
    state_write_failed=1
  fi

  if [ "$SKIP_LAUNCHCTL" = "1" ]; then
    log "SKIP_LAUNCHCTL=1 のため launchctl 操作はskipします（テスト用）。"
    state_apply '.phase="migrated"' \
      || { warn "state.json（phase=migrated）の記録に失敗しました。$0 をもう一度実行すると記録を追いつかせられます。"; state_write_failed=1; }
    [ "$state_write_failed" = "0" ] || return 1
    return 0
  fi

  local ls
  ls="$(label_status "$LABEL")"
  if [ "$content_matches" = "1" ] && [ "$ls" = "loaded" ]; then
    log "新ジョブは既にロード済みで内容も一致しているため、bootstrapのやり直しはしません。"
    state_apply '.phase="new-bootstrapped"' \
      || { warn "state.json（phase=new-bootstrapped）の記録に失敗しました。$0 をもう一度実行すると記録を追いつかせられます。"; state_write_failed=1; }
  elif [ "$ls" = "unknown" ]; then
    fail "新ジョブ（${LABEL}）のロード状態を確認できませんでした（INV-4・fail-closed）。手動確認: launchctl print ${DOMAIN}"
  else
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    # ⚠️ INV-1(b)（検証職1巡目BLOCKING対応）: bootstrap・その再試行・
    # 再試行前のenableのすべてを、直前にOLD_LOADEDを検査するラッパー
    # （launchctl_bootstrap_new/launchctl_enable_new）経由に限定する。
    # 素のlaunchctl呼び出しをここに残さない＝各操作の直前に毎回検査する。
    local bootstrap_ok=0
    if launchctl_bootstrap_new; then
      bootstrap_ok=1
    else
      warn "bootstrap に失敗しました（disabled状態、またはOLD_LOADEDの再検査で中断した可能性）。enable後に1回だけ再試行します。"
      launchctl_enable_new || true
      launchctl_bootstrap_new && bootstrap_ok=1
    fi
    [ "$bootstrap_ok" = "1" ] || fail "bootstrap に失敗しました（旧ジョブの復活を検出して中断した場合を含みます）。手動で確認のうえロードしてください: launchctl bootstrap ${DOMAIN} ${DEST}"
    state_apply '.phase="new-bootstrapped"' \
      || { warn "新ジョブのbootstrapは完了しましたが、state.json（phase=new-bootstrapped）の記録に失敗しました。$0 をもう一度実行すると記録を追いつかせられます。"; state_write_failed=1; }
  fi

  # ⚠️ INV-1(b): 最終enableもラッパー経由（直前にOLD_LOADEDを再検査）。
  launchctl_enable_new \
    || fail "enable に失敗しました（旧ジョブの復活を検出して中断した場合を含みます）。手動で確認のうえenableしてください: launchctl enable ${DOMAIN}/${LABEL}"
  state_apply '.phase="migrated"' \
    || { warn "新ジョブの配置・ロードは完了しましたが、state.json（phase=migrated）の記録に失敗しました。$0 をもう一度実行すると記録を追いつかせられます。"; state_write_failed=1; }
  log "新ジョブ（${LABEL}）を配置・ロードしました。"
  [ "$state_write_failed" = "0" ] || return 1
  return 0
}

# ============================================================
# c: verify-cache（両キャッシュとも新ジョブが触れたことを最大90秒ポーリング）
# ============================================================

cache_field() { [ -f "$1" ] && jq -r --arg f "$2" '.[$f] // empty' "$1" 2>/dev/null || echo ""; }
is_advanced() {
  local before="$1" now="$2"
  [ -z "$now" ] && return 1
  [ -z "$before" ] && return 0
  [ "$now" -gt "$before" ] 2>/dev/null
}

# ⚠️ 検証職1巡目MAJOR-2対応: `fetched_at`（成功時だけ進む）ではなく
# `updated_at`（usage-fetch.shの成功・失敗どちらの書き出しでも必ず更新
# される＝write_failure_cache／成功時の変換関数のどちらもupdated_atを
# 書く）で両キャッシュを見る。`||`（どちらか一方）ではなく両方が進んだ
# ときだけ成功とする＝Codex側が永久に失敗していてもClaudeだけ進めば
# 移行成功になっていた穴を塞ぐ。⚠️ ただしcodexコマンドが本当に存在しない
# 機（F-3）でも、新ジョブは毎回write_failure_cacheでcodex-cache.jsonの
# updated_atを更新する契約のため、この機でもc)は正しく成功する（fetched_at
# ベースだと永久にタイムアウトしていた）。
: "${AIENV_USAGE_VERIFY_CACHE_TIMEOUT_SECONDS:=90}"

step_c_verify_cache() {
  local before_claude_u before_codex_u t=0
  before_claude_u="$(cache_field "$CLAUDE_CACHE" updated_at)"
  before_codex_u="$(cache_field "$CODEX_CACHE" updated_at)"
  while [ "$t" -lt "$AIENV_USAGE_VERIFY_CACHE_TIMEOUT_SECONDS" ]; do
    local now_claude_u now_codex_u
    now_claude_u="$(cache_field "$CLAUDE_CACHE" updated_at)"
    now_codex_u="$(cache_field "$CODEX_CACHE" updated_at)"
    if is_advanced "$before_claude_u" "$now_claude_u" && is_advanced "$before_codex_u" "$now_codex_u"; then
      log "キャッシュの更新を確認しました（Claude・Codexとも新ジョブが取得を試みました）。"
      return 0
    fi
    sleep 1
    t=$((t + 1))
  done
  if ! is_advanced "$before_claude_u" "$(cache_field "$CLAUDE_CACHE" updated_at)"; then
    warn "${AIENV_USAGE_VERIFY_CACHE_TIMEOUT_SECONDS}秒待ってもClaude側のキャッシュが更新されませんでした。"
  fi
  if ! is_advanced "$before_codex_u" "$(cache_field "$CODEX_CACHE" updated_at)"; then
    warn "${AIENV_USAGE_VERIFY_CACHE_TIMEOUT_SECONDS}秒待ってもCodex側のキャッシュが更新されませんでした。"
  fi
  warn "$0 --rollback で戻せます。ログを確認してください: ${HOME}/Library/Logs/takumi009-ai-env/usage-fetch.log"
  return 1
}

# ============================================================
# d: verify-display（合否の判断は本人。移行前後の表示を並べて出すだけ）
# ============================================================

capture_display_now() {
  if [ -x "$OLD_REPO_DIR/tmux-usage.sh" ]; then
    "$OLD_REPO_DIR/tmux-usage.sh" 120 2>&1 || true
  fi
  if [ -x "$OLD_REPO_DIR/cmux-usage-watch.sh" ]; then
    "$OLD_REPO_DIR/cmux-usage-watch.sh" --once 2>&1 || true
  fi
}

step_d_verify_display() {
  if [ ! -f "$DISPLAY_CAPTURE_FILE" ]; then
    log "移行前の表示キャプチャが無いため (d) の比較はスキップします（事前に $0 --capture-display を実行しておくと比較できます）。"
    return 0
  fi
  log "--- 移行前の表示（$0 --capture-display で記録） ---"
  cat "$DISPLAY_CAPTURE_FILE"
  log "--- 現在の表示 ---"
  capture_display_now
  log "上記を見比べてください（時刻依存トークンは変わって当然です。合否の判断は本人）。"
}

cmd_capture_display() {
  mkdir -p "$STATE_DIR" 2>/dev/null || fail "状態ディレクトリを作成できませんでした: $STATE_DIR"
  capture_display_now > "$DISPLAY_CAPTURE_FILE" 2>&1
  log "表示を記録しました: $DISPLAY_CAPTURE_FILE"
}

# ============================================================
# --dry-run（副作用ゼロ）
# ============================================================

cmd_dry_run() {
  local ol na had route
  ol="$(old_loaded)"; na="$(new_active)"
  had="$(state_get had_old_job)"
  if [ -z "$had" ]; then
    local at_orig at_stash
    at_orig="$(old_plist_at_original)"; at_stash="$(old_plist_at_stash)"
    if [ "$at_orig" = "false" ] && [ "$at_stash" = "false" ] && [ "$ol" = "false" ]; then
      route=2
    else
      route=1
    fi
  else
    [ "$had" = "true" ] && route=1 || route=2
  fi
  log "[dry-run] 観測: OLD_LOADED=$ol NEW_ACTIVE=$na had_old_job=${had:-(未記録)}"
  if [ "$route" = "1" ]; then
    log "[dry-run] 経路1（旧ジョブがある機）＝ a(旧を止める) -> b(新を入れる) -> c(キャッシュ確認) -> d(表示を並べて出力)"
  else
    log "[dry-run] 経路2（旧ジョブが無い機・新規導入）＝ b(新を入れる) -> c(キャッシュ確認)（aとdは無い）"
  fi
  log "[dry-run] 完了。実際の変更は一切行っていません。"
}

# ============================================================
# 既定の実行（a→b→c→d を1コマンドで。順序は本スクリプトが固定する）
# ============================================================

cmd_run() {
  inv1_entry_check_or_die
  ensure_started
  local had phase
  had="$(state_get had_old_job)"
  phase="$(state_get phase)"
  if [ "$had" = "true" ]; then
    case "$phase" in
      starting) step_a_stop_old || return 1; step_b_install_new || return 1 ;;
      *) step_b_install_new || return 1 ;;
    esac
  else
    step_b_install_new || return 1
  fi
  step_c_verify_cache
  local c_status=$?
  step_d_verify_display
  if [ "$c_status" -ne 0 ]; then
    return 1
  fi
  # ⚠️ 検証職2巡目MINOR-6対応: had_old_job=false（旧ジョブが無かった新規機）
  # では退避物も旧の配布元も存在しないため、--verify/--confirmは必須では
  # ない（README「新規導入」節のとおり）。完了案内を経路ごとに分岐する。
  if [ "$had" = "true" ]; then
    log "完了。次は本人が $0 --verify で(c)の再確認と表示比較を行い、問題無ければ数日運用してから $0 --confirm してください。"
  else
    log "完了。この機には旧ジョブが無かったため、--verify・--confirmは不要です（退避物も旧の配布元も存在しません）。取りやめる場合は $0 --rollback で新ジョブを止めるだけで済みます。"
  fi
  return 0
}

# ============================================================
# --verify（(c)再確認＋表示比較＋本人確認 -> phase=verified）
# ============================================================

cmd_verify() {
  local phase
  phase="$(state_get phase)"
  if [ "$phase" != "migrated" ] && [ "$phase" != "verified" ]; then
    fail "--verify は移行完了直後（phase=migrated）でのみ実行できます（現在: ${phase:-未開始}）。まず $0 を実行してください。"
  fi
  step_c_verify_cache || fail "(c)キャッシュ更新の再確認に失敗しました。$0 --rollback で戻せます。"
  step_d_verify_display
  local ans
  if [ "$AIENV_USAGE_FETCH_TEST" = "1" ]; then
    ans="${AIENV_USAGE_FETCH_VERIFY_ANSWER:-no}"
  else
    printf '上記の表示は移行前と同じですか？ [y/N]: ' >&2
    read -r ans < /dev/tty 2>/dev/null || ans="no"
  fi
  case "$ans" in
    y|yes|Y|YES)
      state_apply '.phase="verified"' || fail "phase更新に失敗しました。"
      log "verified。数日そのまま運用してから $0 --confirm してください。"
      ;;
    *)
      log "verifiedにはしませんでした。表示を確認のうえ、もう一度 $0 --verify を実行してください。必要なら $0 --rollback で戻せます。"
      return 1
      ;;
  esac
}

# ============================================================
# --confirm（本人確認のうえ退避物を削除 -> confirming -> confirmed）
# ============================================================

cmd_confirm() {
  local phase
  phase="$(state_get phase)"
  if [ "$phase" != "verified" ] && [ "$phase" != "confirming" ]; then
    fail "--confirm は $0 --verify 済み（phase=verified）のときだけ実行できます（現在: ${phase:-未開始}）。"
  fi
  local ol na
  ol="$(old_loaded)"; na="$(new_active)"
  if [ "$ol" = "unknown" ] || [ "$na" = "unknown" ]; then
    fail "launchd への照会状態が確認できません（INV-4）。--confirm を拒否します。"
  fi
  if [ "$ol" = "true" ] && [ "$na" = "true" ]; then
    fail "旧と新が両方ロードされています（INV-1違反）。まず $0 --heal を実行してください。"
  fi
  if [ "$phase" = "verified" ]; then
    local ans
    if [ "$AIENV_USAGE_FETCH_TEST" = "1" ]; then
      ans="${AIENV_USAGE_FETCH_CONFIRM_ANSWER:-no}"
    else
      printf '退避した旧plistを削除し、移行を確定します。よろしいですか？ [y/N]: ' >&2
      read -r ans < /dev/tty 2>/dev/null || ans="no"
    fi
    case "$ans" in
      y|yes|Y|YES) : ;;
      *) log "確定しませんでした。"; return 1 ;;
    esac
    state_apply '.phase="confirming"' || fail "phase更新に失敗しました。"
  fi
  # ⚠️ 検証職2巡目BLOCKING-1対応（TOCTOU）: 本人が回答するまでの待ち時間・
  # phase=confirmingから再開するまでの待ち時間のあいだに状態が変わりうる。
  # 上でobserveした値（ol/na）は待機前の古い値なので使わない。不可逆操作
  # （退避物削除）の直前に、必ずもう一度INV-1を再観測する。ここが「削除
  # してよいか」の唯一の正本判断であり、待機中に旧が復活していれば
  # 退避物を残したまま拒否する（設計書「二重取得の最中に確定を進めない」）。
  local ol2 na2
  ol2="$(old_loaded)"; na2="$(new_active)"
  if [ "$ol2" = "unknown" ] || [ "$na2" = "unknown" ]; then
    fail "退避物を削除する直前にlaunchdへの照会状態が確認できなくなりました（INV-4）。退避物は削除していません。状態を確認のうえ、もう一度 $0 --confirm を実行してください。"
  fi
  if [ "$ol2" = "true" ] && [ "$na2" = "true" ]; then
    fail "退避物を削除する直前に旧ジョブの復活を検出しました（INV-1違反）。退避物は削除していません。まず $0 --heal を実行してください。"
  fi
  # ⚠️ confirming は「削除するつもりだった」意図の記録。中断したら削除を
  # 冪等にやり直して confirmed を書く（削除は何度でも同じ結果）。
  local dest safe_dest
  dest="$(state_get old_plist_dest)"
  if [ -n "$dest" ] && [ -e "$dest" ]; then
    safe_dest="$(validate_stash_path "$dest")" \
      || fail "退避先パス（${dest}）が許可された範囲（${STATE_DIR}配下）に収まっていません。state.jsonが壊れている可能性があります。削除は行いません。手動で確認してください: cat ${STATE_FILE}"
    rm -f "$safe_dest" 2>/dev/null \
      || fail "退避物の削除に失敗しました（${safe_dest}）。もう一度 $0 --confirm を実行してください（冪等です）。"
    rmdir "$(dirname "$safe_dest")" 2>/dev/null || true
  fi
  state_apply '.phase="confirmed"' || fail "phase更新に失敗しました（退避物の削除自体は完了しています）。"
  log "確定しました。⚠️ 旧repo（${OLD_REPO_DIR}）の取得コードはまだ残っています（本人が別PRで表示専用化するまでは ${OLD_REPO_INSTALLER} の再実行で復元できます）。"
}

# ============================================================
# --heal（二重取得＝INV-1違反から復旧する唯一の道）
# ============================================================

cmd_heal() {
  local ol na
  ol="$(old_loaded)"; na="$(new_active)"
  if [ "$ol" = "unknown" ] || [ "$na" = "unknown" ]; then
    if new_active_unknown_is_enable_pending; then
      fail "新ジョブ（${LABEL}）は launchd にロード済みですが、enable が完了したか launchd へ照会できません（print-disabled にこのラベルの記録が無いため。INV-4）。--heal を拒否します。手動で確認のうえ次を実行してください: launchctl enable ${DOMAIN}/${LABEL} 。完了後、もう一度 $0 --heal を実行してください。"
    fi
    fail "launchd への照会状態が確認できません（INV-4）。--heal を拒否します。"
  fi
  if [ "$ol" != "true" ] || [ "$na" != "true" ]; then
    log "二重取得ではありません（OLD_LOADED=${ol} NEW_ACTIVE=${na}）。何もせず終了します。"
    return 0
  fi
  if [ "$SKIP_LAUNCHCTL" != "1" ]; then
    launchctl bootout "$DOMAIN/$OLD_LABEL" 2>/dev/null || true
  fi
  local after
  after="$(label_status "$OLD_LABEL")"
  if [ "$after" = "loaded" ] || [ "$after" = "unknown" ]; then
    fail "旧ジョブのbootoutを試みましたが、まだ確認できません（${after}）。中止します。新ジョブは動き続けているため取得は継続します。手動確認: launchctl print ${DOMAIN}/${OLD_LABEL}"
  fi
  local dest
  dest="$(state_get old_plist_dest)"
  if [ -z "$dest" ] || [ -e "$dest" ]; then
    dest="$STATE_DIR/$(date -u +%Y%m%dT%H%M%SZ)/${OLD_PLIST_NAME}.revived"
  fi
  if [ -e "$OLD_PLIST_SRC" ]; then
    mkdir -p "$(dirname "$dest")" 2>/dev/null
    mv -f "$OLD_PLIST_SRC" "$dest" 2>/dev/null || warn "旧plistの退避に失敗しました。手動で確認してください: $OLD_PLIST_SRC"
  fi
  if [ "$(label_status "$LABEL")" != "loaded" ]; then
    warn "再観測で新ジョブが1件だけロードされていることを確認できませんでした。手動確認: launchctl print ${DOMAIN}"
  else
    log "新ジョブ（${LABEL}）が1件だけ有効であることを確認しました。"
  fi
  log "復活元の候補（自動では撤去しません。確定前に配布元を消すと INV-3 を破って戻れなくなるため）:"
  log "  - 旧repoのインストーラ: ${OLD_REPO_INSTALLER}"
  log "  - dotfiles の install.sh（導入していれば）"
  log "  - 手で置かれたplist"
  log "heal完了。復活元を確認し、確定後であれば旧repoの表示専用化（retire-old-repo）で配布元を撤去してください。"
}

# ============================================================
# --rollback（観測した局面ごとに§2.4の可否表どおり動く）
# ============================================================

rollback_r1_stop_new() {
  if [ "$SKIP_LAUNCHCTL" != "1" ]; then
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    launchctl disable "$DOMAIN/$LABEL" 2>/dev/null || true
  fi
  local after
  after="$(label_status "$LABEL")"
  case "$after" in
    loaded) fail "新ジョブのbootoutを実行しましたが、まだロードされたままです。手動確認: launchctl print ${DOMAIN}/${LABEL}" ;;
    unknown) fail "新ジョブの事後状態を確認できませんでした（INV-4）。手動確認: launchctl print ${DOMAIN}" ;;
  esac
  if [ -e "$DEST" ]; then
    local retire_dest
    retire_dest="$STATE_DIR/$(date -u +%Y%m%dT%H%M%SZ)/${PLIST_NAME}"
    mkdir -p "$(dirname "$retire_dest")" 2>/dev/null
    mv -f "$DEST" "$retire_dest" 2>/dev/null || warn "新plistの退避に失敗しました（${DEST}）。手動で確認してください。"
  fi
  log "新ジョブ（${LABEL}）を停止しました。"
}

rollback_r2_restore_old() {
  local dest
  dest="$(state_get old_plist_dest)"
  if [ -n "$dest" ] && [ -e "$dest" ]; then
    mkdir -p "$(dirname "$OLD_PLIST_SRC")" 2>/dev/null
    mv -f "$dest" "$OLD_PLIST_SRC" 2>/dev/null || fail "退避した旧plistを元の場所へ戻せませんでした（${dest} -> ${OLD_PLIST_SRC}）。手動で行ってください。"
  fi
  if [ "$SKIP_LAUNCHCTL" = "1" ]; then
    log "SKIP_LAUNCHCTL=1 のため launchctl 操作はskipします（テスト用）。"
    return 0
  fi
  launchctl bootout "$DOMAIN/$OLD_LABEL" 2>/dev/null || true
  # ⚠️ INV-1(b)（検証職1巡目BLOCKING対応）: bootstrap・その再試行・
  # 再試行前のenable・最終enableのすべてを、直前にNEW_ACTIVEを検査する
  # ラッパー（launchctl_bootstrap_old/launchctl_enable_old）経由に限定する。
  local bootstrap_ok=0
  if launchctl_bootstrap_old; then
    bootstrap_ok=1
  else
    launchctl_enable_old || true
    launchctl_bootstrap_old && bootstrap_ok=1
  fi
  [ "$bootstrap_ok" = "1" ] || fail "旧ジョブのbootstrapに失敗しました（新ジョブがまだ有効であることを検出して中断した場合を含みます）。手動で確認のうえロードしてください: launchctl bootstrap ${DOMAIN} ${OLD_PLIST_SRC}"
  launchctl_enable_old \
    || fail "旧ジョブのenableに失敗しました（新ジョブがまだ有効であることを検出して中断した場合を含みます）。手動で確認のうえenableしてください: launchctl enable ${DOMAIN}/${OLD_LABEL}"
  log "旧ジョブ（${OLD_LABEL}）を復元しました。"
}

cmd_rollback() {
  local ol na
  ol="$(old_loaded)"; na="$(new_active)"
  if [ "$ol" = "unknown" ] || [ "$na" = "unknown" ]; then
    fail "launchd への照会状態が確認できません（INV-4・fail-closed）。--rollback を拒否します。"
  fi
  if [ "$ol" = "true" ] && [ "$na" = "true" ]; then
    fail "旧と新が両方ロードされています（INV-1違反）。まず $0 --heal を実行してください。"
  fi

  local had
  had="$(state_get had_old_job)"

  # P0: 新ジョブが動いていない（旧のみ1件の移行前・または新規機の導入前）
  if [ "$na" = "false" ]; then
    local phase
    phase="$(state_get phase)"
    if [ -z "$phase" ] || [ "$phase" = "starting" ]; then
      log "新ジョブは動いていません。戻す必要はありません。"
      state_delete
      return 0
    fi
  fi

  if [ "$had" = "false" ]; then
    # 経路2（新規機）の巻き戻し＝r1だけ。戻す旧が無いので取得は0件へ戻る。
    rollback_r1_stop_new || return 1
    log "新ジョブを停止しました。この機は旧ジョブを持たないため、使用率の取得は0件に戻ります（導入前と同じ状態です。故障ではありません）。"
    state_delete
    return 0
  fi

  # had=true（経路1）
  local at_stash at_orig
  at_stash="$(old_plist_at_stash)"
  at_orig="$(old_plist_at_original)"

  if [ "$at_stash" != "true" ] && [ "$at_orig" != "true" ]; then
    # 退避物が無い（P4／P5）。
    if [ "$(old_code_present)" = "true" ]; then
      fail "退避物がありません。旧repoの取得コード（${OLD_REPO_REFRESH}）はまだ存在するため、旧repoの install.sh を再実行すればplistを作り直せます（P4）。⚠️ 手順の順序を守ってください＝①launchctl bootout ${DOMAIN}/${LABEL} ②launchctl disable ${DOMAIN}/${LABEL} ③新plistを退避 ④NEW_ACTIVEが偽であることを確認 ⑤（そのうえで）${OLD_REPO_INSTALLER} を実行 ⑥キャッシュが更新されることを確認（新を止める前に旧installerを実行すると即座に二重取得になります）。"
    else
      fail "退避物がなく、旧repoの取得コード（${OLD_REPO_REFRESH}）も見つかりません（P5＝戻す手段がありません）。対処は「新しい取得器を直す」ことです。旧へ戻す道はありません。"
    fi
  fi

  rollback_r1_stop_new || return 1
  rollback_r2_restore_old || return 1
  step_c_verify_cache || true
  step_d_verify_display
  state_delete
  log "巻き戻しが完了しました。"
}

# ============================================================
# エントリポイント
# ============================================================

CMD="run"
DRY_RUN=0
# ⚠️ 検証職2巡目MAJOR-2対応: 複数のモード指定（例＝--confirm --rollback）を
# 黙って後勝ちにしない・--dry-runを他モードと併用しても黙って無視しない
# （どちらも副作用のある操作へ進む前に拒否する）。
MODE_FLAG_COUNT=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --rollback) CMD="rollback"; MODE_FLAG_COUNT=$((MODE_FLAG_COUNT + 1)) ;;
    --verify) CMD="verify"; MODE_FLAG_COUNT=$((MODE_FLAG_COUNT + 1)) ;;
    --confirm) CMD="confirm"; MODE_FLAG_COUNT=$((MODE_FLAG_COUNT + 1)) ;;
    --heal) CMD="heal"; MODE_FLAG_COUNT=$((MODE_FLAG_COUNT + 1)) ;;
    --capture-display) CMD="capture-display"; MODE_FLAG_COUNT=$((MODE_FLAG_COUNT + 1)) ;;
    *) fail "unknown option: $arg" ;;
  esac
done
if [ "$MODE_FLAG_COUNT" -gt 1 ]; then
  fail "モードを指定する引数（--rollback/--verify/--confirm/--heal/--capture-display）は同時に1つだけ指定できます。"
fi
if [ "$DRY_RUN" = "1" ] && [ "$CMD" != "run" ]; then
  fail "--dry-run は既定の実行（引数なし）とだけ併用できます（${CMD}系のコマンドとは併用できません）。"
fi

[ -e "$SRC" ] || fail "リポジトリのファイルが見つかりません（checkout破損の可能性）: $SRC"
[ -x "$DIR/scripts/usage-fetch.sh" ] || fail "リポジトリに scripts/usage-fetch.sh が見つかりません（checkout破損の可能性）"

if [ "$CMD" = "heal" ]; then
  cmd_heal
  exit $?
fi

# ⚠️ --heal を除くすべての口で最初に検査する（INV-1 の入口検査）。
inv1_entry_check_or_die

case "$CMD" in
  capture-display) cmd_capture_display; exit $? ;;
  verify) cmd_verify; exit $? ;;
  confirm) cmd_confirm; exit $? ;;
  rollback) cmd_rollback; exit $? ;;
  run)
    if [ "$DRY_RUN" = "1" ]; then
      cmd_dry_run
      exit $?
    fi
    cmd_run
    exit $?
    ;;
esac
