#!/bin/bash
# 配役表の状態（Team の SessionStart 寄与）: 開幕1行（🧭 モード行＋配役表セグメント）・行動則⑤・machine_role 保留行・
# ローカル実体プロファイルの警告を出す。
# 使い方: stdin＝hook JSON（読み捨てる）。
#   --slots   自分の全枠を 1 回で返す＝{"slots":{"opening":…,"directive5":…,"role-hold":…,"profile-warning":…}}
#             （空の枠は ""・文の末尾に改行を付けない。SessionStart の合成器が起動する形）
#   引数なし  空でない枠を枠順（opening・directive5・role-hold・profile-warning）に空行 1 つで連結し hook 形で返す
# 解決器の起動は preflight＋resolve の 1 組（python3 2 回）。
# 経緯＝[[Decisions/2026-09-19-ai-env-optimization-rulings]]

# ローカル実体プロファイル（正本＝各マシンの $HOME/.config/takumi009-ai-env/profile.md・repo 管理外）。
: "${BOOTSTRAP_ENABLE_LOCAL_PROFILE:=1}"
: "${AIENV_LOCAL_PROFILE_PATH:=$HOME/.config/takumi009-ai-env/profile.md}"
# 判定式の正本は解決器 profile_resolve.py の1箇所（同じ機能の実行器＝本寄与の実体位置からの相対）。
STATUS_SELF_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${PROFILE_RESOLVE_LIB:=$STATUS_SELF_DIR/../../executor/profile_resolve.py}"
# Bedrock のピン留め実値ファイル（全部入りの組立と同じ既定値。特定キーの有無だけ見る＝値は読まない）。
: "${AIENV_BEDROCK_ENV_FILE:=$HOME/.config/takumi009-ai-env/bedrock.env}"
# コア職種マニフェストの実体側入力。team/rules/agents。
: "${AIENV_AGENTS_DIR:=${STATUS_SELF_DIR%/*/*/*}/team/rules/agents}"

# 開幕1行（team_mode＝solo|lean|full|unknown）。builtin だけで書く（外部プロセスを起こさない）。
# 文面の正本＝Preferences/core-conduct.md §1（両者の一致は静的テストが検証する）。
compose_team_mode_line() {   # $1 = solo|lean|full|unknown
  case "$1" in
    solo) TEAM_MODE_LINE='🧭 現在＝単独モード（リーダーが全工程を自分で行います。第三者検証はありません）。他のモード＝軽量／フル。切り替えたいときは言ってください' ;;
    lean) TEAM_MODE_LINE='🧭 現在＝軽量モード（実装者と検証職を置き、適用工程ごとに1巡で回します）。他のモード＝単独／フル。切り替えたいときは言ってください' ;;
    full) TEAM_MODE_LINE='🧭 現在＝フルモード（職種ごとに担当を立て、指摘が収まるまで検証を回します）。他のモード＝単独／軽量。切り替えたいときは言ってください' ;;
    *)    TEAM_MODE_LINE='🧭 現在＝モード未確定（配役表の team_mode が読めません）。委任の前に本人へ確認します。' ;;
  esac
}

# DIRECTIVE ⑤（オーケストレーター行動則）をモード別に組み立てる（先頭に「⑤ 」を含む）。
compose_team_mode_directive5() {   # $1 = solo|lean|full|unknown
  local base5='⑤ オーケストレーター行動則（詳細＝Preferences/core-workflow.md §1・§2）: 「作る工程」は自分でやらず委任し、成果物の修正はリーダーが直接行わず作成元ロールへ差し戻す。⚠️ リーダー自身の Edit/Write が正当なのは、~/.claude・scratchpad・リーダー自身の成果物への軽微な修正・ユーザーの直接作業指示のみ（Vault は含まない）。許可パス外への直接編集は delegation-gate-v2 フックが deny する（委任するか、理由をユーザーに明示してマーカー touch）。'
  case "$1" in
    solo)
      TEAM_MODE_DIRECTIVE5='⑤ ⚠️ 単独モードでは全工程をリーダー自身が行い、他の職種を1つも立てない（検証職も立てない）。工程は飛ばさず『専任なし』を明記する。許可パス外の直接編集は、単独モードであることを理由として本人への応答で明示してから touch $MARKER_DIR/claude-direct-edit-ok-<session_id> して再試行する。⚠️ Vault の AI 向け6フォルダも同じ扱い——solo ではリーダーが案件の締めにまとめて直筆する（理由を応答で明示してから touch $MARKER_DIR/claude-vault-direct-ok-<session_id>）。'
      ;;
    lean)
      TEAM_MODE_DIRECTIVE5="${base5} ⚠️ 軽量モードでは要件定義と設計はリーダー自身が行う。実装は implementer へ委任し、適用工程ごとに検証職を1巡だけ回す。requirements-analyst・system-designer・researcher・adoption-critic・operator は立てず『専任なし』を明記する。"
      ;;
    full)
      TEAM_MODE_DIRECTIVE5="$base5"
      ;;
    *)
      TEAM_MODE_DIRECTIVE5="${base5} ⚠️ モードが未確定なので、委任の前に本人へ確認する。"
      ;;
  esac
}

# テスト専用: BOOTSTRAP_PRINT_TEAM_MODE_LINES_ONLY=1 なら開幕1行4本を1行1本で出して即終了する（本処理には進まない）。
if [ "${BOOTSTRAP_PRINT_TEAM_MODE_LINES_ONLY:-0}" = "1" ]; then
  for _tm_mode in solo lean full unknown; do
    compose_team_mode_line "$_tm_mode"
    printf '%s\n' "$TEAM_MODE_LINE"
  done
  exit 0
fi
# 未記入のまま残っていると壊れているのと同じ扱いにする印（T2-MINIMAL）。
# sample（team/data/profile.md.sample）は実値入りで配布するのでどのキーにも使わないが、安全弁として検出機構は維持する。
LOCAL_PROFILE_SENTINEL='<fill-in>'

# is_v2_resolve_output_well_formed <line> <exit_code> — resolve の出力が stdout 契約
# （固定順・既知フィールドのみ・単一行）どおりかを検査する。
# ⚠️ この regex は profile_resolve.py の do_resolve() が生成するフィールド集合と1対1。
# resolve() の出力へフィールドを足すときは同じコミットでここも更新すること。
is_v2_resolve_output_well_formed() {
  local s="$1" rc="$2"
  # 複数行（改行混入）は契約違反。
  [ "$(printf '%s' "$s" | wc -l | tr -d ' ')" = "0" ] || return 1
  # name は職種名（role.<name> の <name>）＝parser の KEY_RE と同じ文字集合。
  local name='[A-Za-z0-9_.-]+' code='[A-Za-z0-9_-]+' key='[A-Za-z0-9_.-]+' tab notab
  tab="$(printf '\t')"
  # ⚠️ POSIX ERE はブラケット式内で \t をタブへ解釈しない。実際のタブ文字を埋め込む。
  notab="[^${tab}]+"
  # ADVISORY はコロン区切りの補助情報を持つコードも読めるよう、1要素だけ code より広い。
  local adv_code="${code}(:${name}(:${name})?)?"
  case "$s" in
    OK"$tab"*)
      [ "$rc" = "0" ] || return 1
      # TEAM_MODE: は schema_version の直後・MACHINE_ROLE: はその直後で、どちらも必須（位置を一意にする）。
      local re="^OK${tab}schema_version=[0-9]+${tab}TEAM_MODE:(solo|lean|full|unknown)${tab}MACHINE_ROLE:(main|sub|unknown|unavailable)(${tab}VACANT:${name}(,${name})*)?(${tab}VACANT_REASON:${name}=${code}(,${name}=${code})*)?(${tab}VACANT_UNKNOWN:${name}(,${name})*)?(${tab}ADVISORY:${adv_code}(,${adv_code})*)?(${tab}UNKNOWN_EXTRA:${key}(,${key})*)?\$"
      [[ "$s" =~ $re ]]
      ;;
    MINIMAL"$tab"*)
      [ "$rc" = "1" ] || return 1
      # 理由部分にタブを含めない＝コード・理由の2フィールドだけに限定する。
      local re="^MINIMAL${tab}[A-Za-z0-9_-]+${tab}${notab}\$"
      [[ "$s" =~ $re ]]
      ;;
    *)
      return 1
      ;;
  esac
}

# resolve_local_profile <path> — 実体を解決する（symlink拒否／存在確認→preflight→resolve）。
# 標準出力へタブ区切り1行:
#   MINIMAL\t<コード>\t<理由>          … 最小能力+⚠️（schema_version 無し・旧版は T4-LEGACY としてここに含まれる）
#   OK\t<解決値>[\tVACANT:...][\tVACANT_REASON:...][\tVACANT_UNKNOWN:...][\tADVISORY:...][\tUNKNOWN_EXTRA:...]
resolve_local_profile() {
  local path="$1"
  [ -L "$path" ] && { printf 'MINIMAL\tSYMLINK\t実体はsymlinkであってはいけません（マシンローカルの通常ファイルとして直接作成してください）: %s\n' "$path"; return; }
  [ -f "$path" ] || { printf 'MINIMAL\tT1\t実体ファイルが存在しません: %s\n' "$path"; return; }

  if [ ! -f "$PROFILE_RESOLVE_LIB" ]; then
    printf 'MINIMAL\tT10\tresolver本体が見つかりません: %s\n' "$PROFILE_RESOLVE_LIB"
    return
  fi

  local preflight_out preflight_rc=0
  preflight_out="$(python3 "$PROFILE_RESOLVE_LIB" preflight "$path" 2>/dev/null)"
  preflight_rc=$?
  if [ "$preflight_rc" != "0" ]; then
    if [ -n "$preflight_out" ]; then
      printf 'MINIMAL\t%s\n' "$preflight_out"
    else
      printf 'MINIMAL\tT10\tresolver本体の実行に失敗しました（preflight）\n'
    fi
    return
  fi

  local v2_out v2_rc=0
  v2_out="$(python3 "$PROFILE_RESOLVE_LIB" resolve "$path" \
    --bedrock-env "$AIENV_BEDROCK_ENV_FILE" --agents-dir "$AIENV_AGENTS_DIR" 2>/dev/null)"
  v2_rc=$?
  if is_v2_resolve_output_well_formed "$v2_out" "$v2_rc"; then
    printf '%s\n' "$v2_out"
  else
    printf 'MINIMAL\tT10\tresolver本体の出力が契約違反です（resolve）\n'
  fi
}

# stdin（hook JSON）は使わないが読み切る（書き手のパイプを先に閉じない）。
cat >/dev/null 2>&1 || true

# ローカル実体プロファイル: 必読リストには載せない。解決の成否・schema_version・machine_role・照会コマンドは
# 🧭モード行の末尾セグメントへ織り込む。失敗時は「利用不可（区分）」を同じセグメントに出す（AI は最小能力として振る舞う）。
LOCAL_PROFILE_WARNING=""
profile_kind=""
machine_role=""
if [ "$BOOTSTRAP_ENABLE_LOCAL_PROFILE" = "1" ]; then
  profile_status="$(resolve_local_profile "$AIENV_LOCAL_PROFILE_PATH")"
  profile_kind="${profile_status%%$'\t'*}"
  profile_rest="${profile_status#*$'\t'}"
  profile_has_unknown_extra=0
  printf '%s' "$profile_status" | grep -q 'UNKNOWN_EXTRA:' && profile_has_unknown_extra=1

  # 警告＝コード＋取るべき行動1つ。
  if [ "$profile_kind" = "MINIMAL" ]; then
    profile_reason_code="${profile_rest%%$'\t'*}"
    profile_reason_msg="${profile_rest#*$'\t'}"
    if [ "$profile_reason_code" = "T11" ]; then
      LOCAL_PROFILE_WARNING="⚠️ ローカル実体プロファイル(${AIENV_LOCAL_PROFILE_PATH})に認証情報らしいキー名があります（T11: ${profile_reason_msg}）→ 該当行を削除して再開。最小能力として扱う。"
    else
      LOCAL_PROFILE_WARNING="⚠️ ローカル実体プロファイル(${AIENV_LOCAL_PROFILE_PATH})を解決できません（${profile_reason_code}: ${profile_reason_msg}）→ 最小能力として扱い、空席の申告（Preferences/core-workflow.md §7）を行う。既定値を発明しない。"
    fi
  elif [ "$profile_has_unknown_extra" = "1" ]; then
    # 未知キーの「値」に秘密が書かれている可能性があるため、機械側の解決は有効でも AI 向けには最小能力として扱う。
    unknown_extra="${profile_status#*UNKNOWN_EXTRA:}"
    LOCAL_PROFILE_WARNING="⚠️ ローカル実体プロファイルに未知のキーがあります（${unknown_extra}）→ プロファイル利用不可＝最小能力として扱い、ワーカー起動は本人確認へ倒してください（Preferences/core-workflow.md §7）。"
  elif printf '%s' "$profile_status" | grep -q -E '(VACANT|VACANT_REASON|VACANT_UNKNOWN|ADVISORY):'; then
    # 配役の値そのものは再掲しないが、縮退・未確定の職種名と条件番号は必ず注入する（静かな失敗を防ぐ）。
    casting_note="$(printf '%s' "$profile_status" | sed -E 's/^OK\t//')"
    LOCAL_PROFILE_WARNING="ℹ️ 配役表の状態（職種名と条件番号のみ・値は含みません）: ${casting_note}。詳細はPreferences/core-workflow.md §7（職種が空席のとき）を参照してください。"
  fi
fi

# TEAM_MODE: の取り出し（パラメータ展開だけ＝外部プロセスなし。$'\t' は command substitution を避けるため）。
tm_tab=$'\t'
tm_pat="${tm_tab}TEAM_MODE:"
team_mode=""
if [ "$profile_kind" = "OK" ] && [ "$profile_has_unknown_extra" = "0" ]; then
  tm_rest="${profile_status#*"$tm_pat"}"
  [ "$tm_rest" != "$profile_status" ] && team_mode="${tm_rest%%"$tm_tab"*}"
fi
case "$team_mode" in solo|lean|full) : ;; *) team_mode="unknown" ;; esac
compose_team_mode_line "$team_mode"
compose_team_mode_directive5 "$team_mode"

# MACHINE_ROLE: も同じ形で取り出す。⚠️ unknown_extra は見ない（機構の分岐は既知キー部分だけを使う。
# 降格させると廃止キーが残る過渡状態のサブ機で④の誤警告が毎セッション出る）。
mr_tab=$'\t'
mr_pat="${mr_tab}MACHINE_ROLE:"
if [ "$profile_kind" = "OK" ]; then
  mr_rest="${profile_status#*"$mr_pat"}"
  [ "$mr_rest" != "$profile_status" ] && machine_role="${mr_rest%%"$mr_tab"*}"
fi
# main|sub|unavailable はそのまま通し、それ以外だけ unknown へ倒す（unavailable では保留行を出さない）。
case "$machine_role" in main|sub|unavailable) : ;; *) machine_role="unknown" ;; esac
MACHINE_ROLE_HOLD_LINE=""
[ "$machine_role" = "unknown" ] && MACHINE_ROLE_HOLD_LINE='⚠️ 配役表の machine_role が未確定です（この機がメイン機かサブ機かを本人が宣言していません）。機役割に依存する判断（Preferences の編集・公開スナップショットの生成・git の立場）は本人へ確認してから行う。既定値を発明しない。'

# 🧭モード行の末尾セグメント（解決の成否・schema_version・machine_role・照会コマンド）。
# BOOTSTRAP_ENABLE_LOCAL_PROFILE=0 では解決を試みていないので付けない。
if [ "$BOOTSTRAP_ENABLE_LOCAL_PROFILE" = "1" ]; then
  if [ "$profile_kind" = "OK" ] && [ "$profile_has_unknown_extra" = "0" ]; then
    sv_tab=$'\t'
    sv_rest="${profile_status#*schema_version=}"
    schema_version_value="${sv_rest%%"$sv_tab"*}"
    TEAM_MODE_LINE="${TEAM_MODE_LINE}｜配役表＝OK schema_version=${schema_version_value} machine_role=${machine_role} 照会＝python3 ~/work/takumi009-ai-env/team/connect/claude-code/role_candidates.py [--role <職種>]"
  else
    # 不在・symlink・validator 違反は区分コード（T1/SYMLINK/T5/…）、UNKNOWN_EXTRA は専用コード名（値は再掲しない）。
    profile_unresolved_code=""
    if [ "$profile_kind" = "MINIMAL" ]; then
      profile_unresolved_code="$profile_reason_code"
    elif [ "$profile_has_unknown_extra" = "1" ]; then
      profile_unresolved_code="UNKNOWN_EXTRA"
    fi
    TEAM_MODE_LINE="${TEAM_MODE_LINE}｜配役表＝利用不可（${profile_unresolved_code}）＝最小能力として振る舞う・ワーカー起動は本人確認へ倒す"
  fi
fi

# 枠（末尾に改行を付けない）。opening＝転記指示＋🧭 行＋⚠️ 行／profile-warning＝見出し＋警告（警告が無ければ空）。
SLOT_OPENING="【開幕1行】最初の応答の冒頭に、次の1行をそのまま転記する（1行だけ・要約しない）:
${TEAM_MODE_LINE}
⚠️ この依頼に本人のモード指定が含まれていたら、上の行ではなく指定後のモードの行を1行だけ出す（2行出さない）。モードを変えられるのは本人だけ。"
SLOT_PROFILE_WARNING="${LOCAL_PROFILE_WARNING:+【ローカル実体プロファイル】
$LOCAL_PROFILE_WARNING}"

if [ "${1:-}" = "--slots" ]; then
  jq -n --arg o "$SLOT_OPENING" --arg d "$TEAM_MODE_DIRECTIVE5" --arg r "$MACHINE_ROLE_HOLD_LINE" --arg p "$SLOT_PROFILE_WARNING" \
    '{slots: {opening: $o, directive5: $d, "role-hold": $r, "profile-warning": $p}}'
else
  jq -n --arg o "$SLOT_OPENING" --arg d "$TEAM_MODE_DIRECTIVE5" --arg r "$MACHINE_ROLE_HOLD_LINE" --arg p "$SLOT_PROFILE_WARNING" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: ([$o, $d, $r, $p] | map(select(. != "")) | join("\n\n"))}}'
fi
