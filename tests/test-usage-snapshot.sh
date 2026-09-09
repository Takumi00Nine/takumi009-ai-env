#!/usr/bin/env bash
# tests/test-usage-snapshot.sh — claude/hooks/lib/usage_snapshot.py の
# ユニットテスト（B1a「使用率の見える化」-実装-2026-09-08.md §2.3）。
#
# 2026-09-08 worker-driven一次レビュー（Codex・2巡）BLOCKING/MAJOR/MINOR
# 対応で拡充。
#
# fixture総数=15（陽性15件・陰性0件。FX-13/FX-14は検証職1巡目MINOR-5/6対応で追加）:
#   FX-1  正常（claude=model_weekly付き・codex=通常。両方usage_state=ok）
#   FX-2  stale（claudeのfetched_atが--stale-secondsより古い。codexは新鮮。
#         599/600/601秒の境界も検査）
#   FX-3  claudeのみ欠落（claude-cache.json無し・codexは正常）
#   FX-4  両方欠落（キャッシュディレクトリが空）
#   FX-5  壊れたJSON（claude-cache.jsonが構文エラー・codexは正常）
#   FX-6  last_errorが実際の取得器の形（オブジェクト{type,status,...}）→
#         type/statusだけの要約に置換され（自由文のmessageは再掲しない）、
#         usage_state=okのままでも人可読行に⚠️取得エラーとして表示される
#   FX-6b last_error.typeが取得器の閉じた6値語彙の外（識別子形式には一致
#         するが未知の値）→ 汎用の伏せ字文言に丸められる（2巡目BLOCKING
#         再発防止・正規表現方式から6値の完全一致方式への変更を固定）
#   FX-7  used_percent境界（150% → remaining_percentは0で止まり負にならない）
#   FX-8  last_errorのJSON内にNaNが混入 → ファイル全体がusage_state=error
#         （NaN/Infinityは書き手側の契約違反として一部だけでなく丸ごと疑う）
#   FX-9  last_errorオブジェクトのtypeが不正形式で秘密っぽい文字列を含む →
#         汎用の伏せ字文言に丸められ、生の秘密値が一切出力に現れない
#         （絶対厳守③の直接検証）
#   FX-10 model_weekly.labelに改行混入 → その窓は「無いもの」として扱われ、
#         人可読出力は3行のまま（複数行に分断されない。isprintable()による
#         Unicode行/段落区切り文字の拒否・長さ上限も同時に検証）
#   FX-11 --cache-dirがAIENV_USAGE_CACHE_DIRより優先される（引数→環境変数→
#         既定の優先順位を固定）
#   FX-12 巨大なresets_at_epoch → _format_reset()のtry/exceptでクラッシュ
#         せず「リセット不明」へ静かに倒れる
#   FX-13 five_hour/seven_dayのresets_at_epoch欠落 → usage_state=error
#         （検証職1巡目MINOR-5: 必須窓のリセット時刻欠落をokにしない）
#   FX-14 last_error.type=curl → 許可リストで要約される
#         （検証職1巡目MINOR-6: 取得器のD-3拡張と許可リストの不一致を解消）
# 横断検査（全fixtureに適用）: exit 0（AC-91①）・pools配列が常に3件
#   （AC-91②）・claude-subscription/codex-subscription/unlimitedの順序固定。
# 構造検査（FX-1限定）: AC-95①（--jsonの最上位・pool・window各階層の
#   フィールド名集合が実装記録の固定表と完全一致）・差分/順位/偏りを示す
#   フィールドが0件（フィールド名ベースの構造検査）。
# AST検査（許可リスト方式の簡易版・coding-doc-style §4「陽性fixtureを必ず
#   置く」対応）: usage_snapshot.py全体で減算(Sub)・不等号比較(Lt/LtE/Gt/GtE)
#   演算が発生する(演算種別,関数名)ごとの**個数**を、既知の安全な関数
#   （_extract_window・build_subscription_pool・_scrub_error＝いずれも
#   単一poolの内部値だけを扱う）の期待個数と完全一致させる（2巡目MAJOR
#   対応で集合比較から個数比較へ強化＝既に許可された関数内へ演算を追加
#   しても検出できる）。陽性fixtureは①新しい関数を追加する場合②既に
#   許可された関数の中へ演算を追加する場合の両方を置く。⚠️ それでも
#   関数名単位・個数ベースの粗い検査であり、AC-95③が本来求める行単位・
#   データフロー追跡までの完全なAST到達可能性検査（v19要件書全体の
#   スコープ）ではない（実装記録「残件」に明記）。
#
# 正本: ~/work/takumi009-ai-env-private/docs/core-split/
#   使用率提示B1a-実装-2026-09-08.md
#
# 実行方法: bash tests/test-usage-snapshot.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
LIB="$REPO_ROOT/claude/hooks/lib/usage_snapshot.py"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$desc"; else
    fail_case "$desc (expected=[$expected] actual=[$actual])"
  fi
}
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$desc"; else
    fail_case "$desc (含まれない: \"$needle\" / 実際: $haystack)"
  fi
}
assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$desc"; else
    fail_case "$desc (含まれてはいけないのに含まれる: \"$needle\")"
  fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

NOW=1788858365  # 固定epoch（JST表示・年齢計算を決定的にするための固定値）

write_json() { # write_json <path> <python式(dictリテラル)>
  python3 -c "import json,sys; open(sys.argv[1],'w').write(json.dumps(eval(sys.argv[2])))" "$1" "$2"
}
run_json() { # run_json <cache_dir> [追加引数...]
  local dir="$1"; shift
  AIENV_USAGE_CACHE_DIR="$dir" python3 "$LIB" --json --now "$NOW" "$@"
}
run_human() { # run_human <cache_dir> [追加引数...]
  local dir="$1"; shift
  AIENV_USAGE_CACHE_DIR="$dir" python3 "$LIB" --now "$NOW" "$@"
}
pool_field() { # pool_field <json> <pool_ref> <key>
  python3 -c "
import json,sys
d = json.loads(sys.argv[1])
p = [p for p in d['pools'] if p['pool_ref'] == sys.argv[2]][0]
v = p[sys.argv[3]]
print('null' if v is None else v)
" "$1" "$2" "$3"
}
pools_meta() { # pools_meta <json> — 3件固定・順序・exit有無の横断検査に使う共通値
  python3 -c "
import json,sys
d = json.loads(sys.argv[1])
print(len(d['pools']))
print(','.join(p['pool_ref'] for p in d['pools']))
" "$1"
}

# ============================================================
# FX-1: 正常（陽性）
# ============================================================
FX1="$WORK/fx1"; mkdir -p "$FX1"
write_json "$FX1/claude-cache.json" "{'schema_version':1,'service':'claude','fetched_at':$NOW-180,'updated_at':$NOW-180,'five_hour':{'used_percent':25.0,'resets_at_epoch':$NOW+1000},'seven_day':{'used_percent':46.0,'resets_at_epoch':$NOW+90000},'model_weekly':{'used_percent':34,'resets_at_epoch':$NOW+90000,'label':'Fable'},'last_error':None}"
write_json "$FX1/codex-cache.json" "{'schema_version':1,'service':'codex','fetched_at':$NOW-60,'updated_at':$NOW-60,'five_hour':{'used_percent':66,'resets_at_epoch':$NOW+2000},'seven_day':{'used_percent':10,'resets_at_epoch':$NOW+90000},'last_error':None}"

echo "=== FX-1: 正常（陽性） ==="
{
  json1="$(run_json "$FX1")"; rc1=$?
  assert_eq "FX-1 exit 0（AC-91①）" "0" "$rc1"
  read -r npools1 order1 <<< "$(pools_meta "$json1" | tr '\n' ' ')"
  assert_eq "FX-1 pools常に3件（AC-91②）" "3" "$npools1"
  assert_eq "FX-1 枠の順序＝claude-subscription,codex-subscription,unlimited" "claude-subscription,codex-subscription,unlimited" "$order1"
  assert_eq "FX-1 claude-subscription usage_state=ok" "ok" "$(pool_field "$json1" claude-subscription usage_state)"
  assert_eq "FX-1 codex-subscription usage_state=ok" "ok" "$(pool_field "$json1" codex-subscription usage_state)"
  assert_eq "FX-1 unlimited usage_state=not_applicable" "not_applicable" "$(pool_field "$json1" unlimited usage_state)"
  assert_eq "FX-1 unlimited kind=unlimited" "unlimited" "$(pool_field "$json1" unlimited kind)"

  fieldcheck1="$(printf '%s' "$json1" | python3 -c "
import json,sys
d = json.load(sys.stdin)
top_ok = frozenset(d.keys()) == frozenset({'generated_at','pools'})
pool_ok = all(frozenset(p.keys()) == frozenset({'pool_ref','kind','usage_state','fetched_at','age_seconds','windows','error'}) for p in d['pools'])
win_ok = all(frozenset(w.keys()) == frozenset({'window','used_percent','remaining_percent','resets_at_epoch','label'}) for p in d['pools'] for w in p['windows'])
unlimited_windows_empty = [p for p in d['pools'] if p['pool_ref']=='unlimited'][0]['windows'] == []
print('OK' if (top_ok and pool_ok and win_ok and unlimited_windows_empty) else 'NG')
")"
  assert_eq "FX-1 AC-95①: 最上位・pool・windowのフィールド集合が実装記録の固定表と完全一致（unlimited windows=[]含む）" "OK" "$fieldcheck1"

  no_bias1="$(printf '%s' "$json1" | python3 -c "
import json,sys
d = json.load(sys.stdin)
banned = ('diff','delta','gap','rank','bias','偏')
names = set(d.keys())
for p in d['pools']:
    names |= set(p.keys())
    for w in p['windows']:
        names |= set(w.keys())
names = {n.lower() for n in names}
hit = [n for n in names if any(b in n for b in banned)]
print('OK' if not hit else ','.join(hit))
")"
  assert_eq "FX-1 差分・順位・偏りを示すフィールドが0件" "OK" "$no_bias1"

  weekly_label1="$(printf '%s' "$json1" | python3 -c "
import json,sys
d = json.load(sys.stdin)
ws = [w for p in d['pools'] if p['pool_ref']=='claude-subscription' for w in p['windows'] if w['window']=='model_weekly']
print(ws[0]['label'] if ws else 'MISSING')
")"
  assert_eq "FX-1 model_weeklyのlabel=Fable" "Fable" "$weekly_label1"

  # 決定性（要件書AC-91⑦相当）: 同じ入力を10回呼んでバイト単位で一致する。
  det_ok=1
  for _i in 1 2 3 4 5 6 7 8 9 10; do
    d_iter="$(run_json "$FX1")"
    [ "$d_iter" != "$json1" ] && det_ok=0
  done
  assert_eq "FX-1 決定性: 同じ入力を10回呼んでバイト単位で一致" "1" "$det_ok"

  human1="$(run_human "$FX1")"
  n_lines1="$(printf '%s\n' "$human1" | wc -l | tr -d ' ')"
  assert_eq "FX-1 人可読は3行（枠あたり1行）" "3" "$n_lines1"
  assert_contains "FX-1 人可読にClaude枠行" "$human1" "Claude枠:"
  assert_contains "FX-1 人可読にunlimited固定文" "$human1" "unlimited（Bedrock・ローカル）: 使用率なし"

  # 2026-09-08 worker-driven一次レビューMAJOR-4対応: 同日／翌日リセットの
  # 書式分岐（_format_reset）を、実際の描画済み文字列で直接検査する
  # （NOW=1788858365=2026-09-08 18:06:05 JST。five_hourのresets_at_epoch=
  # NOW+1000（18:22 JST）は同日なのでHH:MM＋「リセット」の語を前置。
  # seven_dayのresets_at_epoch=NOW+90000（09-09 19:06 JST）は翌日なので
  # MM-DD HH:MMのみ・語は前置しない。実測値はpython3のdatetimeで裏取り済み）。
  claude_line1="$(printf '%s\n' "$human1" | grep '^Claude枠:')"
  assert_contains "FX-1 同日リセット(5h)は「リセット HH:MM」形式" "$claude_line1" "5h 残75%（リセット 18:22）"
  assert_contains "FX-1 翌日以降のリセット(7d)は「MM-DD HH:MM」のみ（語を前置しない）" "$claude_line1" "7d 残54%（09-09 19:06）"
  assert_not_contains "FX-1 7d側には「リセット」の語を前置しない" "$claude_line1" "7d 残54%（リセット"
}

# ============================================================
# FX-2: stale（陽性。claudeだけ古い・codexは新鮮＝混在で検証）
# ============================================================
FX2="$WORK/fx2"; mkdir -p "$FX2"
write_json "$FX2/claude-cache.json" "{'fetched_at':$NOW-700,'five_hour':{'used_percent':10.0,'resets_at_epoch':$NOW+1000},'seven_day':{'used_percent':20.0,'resets_at_epoch':$NOW+90000},'last_error':None}"
write_json "$FX2/codex-cache.json" "{'fetched_at':$NOW-30,'five_hour':{'used_percent':40,'resets_at_epoch':$NOW+2000},'seven_day':{'used_percent':50,'resets_at_epoch':$NOW+90000},'last_error':None}"

echo "=== FX-2: stale（陽性） ==="
{
  json2="$(run_json "$FX2")"; rc2=$?
  assert_eq "FX-2 exit 0" "0" "$rc2"
  read -r npools2 order2 <<< "$(pools_meta "$json2" | tr '\n' ' ')"
  assert_eq "FX-2 pools常に3件" "3" "$npools2"
  assert_eq "FX-2 claude-subscription usage_state=stale（既定stale-seconds=600超）" "stale" "$(pool_field "$json2" claude-subscription usage_state)"
  assert_eq "FX-2 codex-subscription usage_state=ok（30秒しか経っていない）" "ok" "$(pool_field "$json2" codex-subscription usage_state)"

  human2="$(run_human "$FX2")"
  assert_contains "FX-2 人可読にstale marker ⚠️古い" "$human2" "⚠️古い"
  claude_line2="$(printf '%s' "$human2" | grep '^Claude枠:')"
  assert_contains "FX-2 stale markerはClaude枠の行に付く" "$claude_line2" "⚠️古い"
  codex_line2="$(printf '%s' "$human2" | grep '^Codex枠:')"
  assert_not_contains "FX-2 stale markerはCodex枠の行には付かない" "$codex_line2" "⚠️古い"

  # --stale-secondsを広げるとok扱いになる（CLI引数の有効性確認）。
  json2b="$(run_json "$FX2" --stale-seconds 1000)"
  assert_eq "FX-2 --stale-seconds 1000ならclaudeもok（CLI引数が効く）" "ok" "$(pool_field "$json2b" claude-subscription usage_state)"

  # 2026-09-08 worker-driven一次レビューMAJOR-4対応: stale境界（600秒）を
  # 599/600/601秒で個別に検査する（判定は`age_seconds > stale_seconds`の
  # 厳密不等号＝ちょうど600秒はまだokという評価順を固定する）。
  FX2B="$WORK/fx2b"; mkdir -p "$FX2B"
  write_json "$FX2B/codex-cache.json" "{'fetched_at':$NOW-30,'five_hour':{'used_percent':1,'resets_at_epoch':$NOW+2000},'seven_day':{'used_percent':1,'resets_at_epoch':$NOW+90000},'last_error':None}"
  for offset_state in "599:ok" "600:ok" "601:stale"; do
    off="${offset_state%%:*}"; expect="${offset_state##*:}"
    write_json "$FX2B/claude-cache.json" "{'fetched_at':$NOW-$off,'five_hour':{'used_percent':1,'resets_at_epoch':$NOW+1000},'seven_day':{'used_percent':1,'resets_at_epoch':$NOW+90000},'last_error':None}"
    json2c="$(run_json "$FX2B")"
    assert_eq "FX-2 stale境界: fetched_atが${off}秒前（既定stale-seconds=600）→${expect}" "$expect" "$(pool_field "$json2c" claude-subscription usage_state)"
  done
}

# ============================================================
# FX-3: claudeのみ欠落（陽性）
# ============================================================
FX3="$WORK/fx3"; mkdir -p "$FX3"
write_json "$FX3/codex-cache.json" "{'fetched_at':$NOW-30,'five_hour':{'used_percent':5,'resets_at_epoch':$NOW+2000},'seven_day':{'used_percent':5,'resets_at_epoch':$NOW+90000},'last_error':None}"

echo "=== FX-3: claudeのみ欠落（陽性） ==="
{
  json3="$(run_json "$FX3")"; rc3=$?
  assert_eq "FX-3 exit 0" "0" "$rc3"
  read -r npools3 _ <<< "$(pools_meta "$json3" | tr '\n' ' ')"
  assert_eq "FX-3 pools常に3件（claude欠落でも3件のまま）" "3" "$npools3"
  assert_eq "FX-3 claude-subscription usage_state=missing" "missing" "$(pool_field "$json3" claude-subscription usage_state)"
  assert_eq "FX-3 codex-subscription usage_state=ok" "ok" "$(pool_field "$json3" codex-subscription usage_state)"

  human3="$(run_human "$FX3")"
  n_lines3="$(printf '%s\n' "$human3" | wc -l | tr -d ' ')"
  assert_eq "FX-3 欠落時も人可読は3行のまま（行数を変えない）" "3" "$n_lines3"
  assert_contains "FX-3 Claude枠が導入手順つきの固定文" "$human3" "Claude枠: 取得できません（キャッシュ無し＝claude-codex-usage 未導入。導入手順: README §使用率）"
}

# ============================================================
# FX-4: 両方欠落（陽性。キャッシュディレクトリが空）
# ============================================================
FX4="$WORK/fx4"; mkdir -p "$FX4"

echo "=== FX-4: 両方欠落（陽性） ==="
{
  json4="$(run_json "$FX4")"; rc4=$?
  assert_eq "FX-4 exit 0（キャッシュ皆無でも落ちない）" "0" "$rc4"
  read -r npools4 order4 <<< "$(pools_meta "$json4" | tr '\n' ' ')"
  assert_eq "FX-4 pools常に3件（両方欠落でも3件）" "3" "$npools4"
  assert_eq "FX-4 枠の順序は変わらない" "claude-subscription,codex-subscription,unlimited" "$order4"
  assert_eq "FX-4 claude-subscription usage_state=missing" "missing" "$(pool_field "$json4" claude-subscription usage_state)"
  assert_eq "FX-4 codex-subscription usage_state=missing" "missing" "$(pool_field "$json4" codex-subscription usage_state)"
  assert_eq "FX-4 unlimited usage_state=not_applicable" "not_applicable" "$(pool_field "$json4" unlimited usage_state)"

  human4="$(run_human "$FX4")"
  n_lines4="$(printf '%s\n' "$human4" | wc -l | tr -d ' ')"
  assert_eq "FX-4 全欠落でも人可読は3行のまま" "3" "$n_lines4"
}

# ============================================================
# FX-5: 壊れたJSON（陽性。claude-cache.jsonが構文エラー・codexは正常）
# ============================================================
FX5="$WORK/fx5"; mkdir -p "$FX5"
printf '{not valid json' > "$FX5/claude-cache.json"
write_json "$FX5/codex-cache.json" "{'fetched_at':$NOW-30,'five_hour':{'used_percent':5,'resets_at_epoch':$NOW+2000},'seven_day':{'used_percent':5,'resets_at_epoch':$NOW+90000},'last_error':None}"

echo "=== FX-5: 壊れたJSON（陽性） ==="
{
  json5="$(run_json "$FX5")"; rc5=$?
  assert_eq "FX-5 exit 0（壊れたJSONでも落ちない）" "0" "$rc5"
  read -r npools5 _ <<< "$(pools_meta "$json5" | tr '\n' ' ')"
  assert_eq "FX-5 pools常に3件" "3" "$npools5"
  assert_eq "FX-5 claude-subscription usage_state=error" "error" "$(pool_field "$json5" claude-subscription usage_state)"
  assert_eq "FX-5 codex-subscription usage_state=ok（隣が壊れていても道連れにしない）" "ok" "$(pool_field "$json5" codex-subscription usage_state)"

  human5="$(run_human "$FX5")"
  n_lines5="$(printf '%s\n' "$human5" | wc -l | tr -d ' ')"
  assert_eq "FX-5 壊れたJSONでも人可読は3行のまま" "3" "$n_lines5"
  assert_contains "FX-5 Claude枠が「壊れています」の固定文" "$human5" "Claude枠: 取得できません（キャッシュが壊れています。導入手順: README §使用率）"
}

# ============================================================
# FX-6: last_errorが実際の取得器の形（オブジェクト・陽性）
# ============================================================
# ⚠️ 2026-09-08 worker-driven一次レビューBLOCKING-2対応で全面差し替え。
# 実際の取得器（~/work/claude-codex-usage/refresh.sh 253〜297行目・
# write_failure_cache/empty_error_cache）は last_error を文字列ではなく
# オブジェクト {at,type,message,status,attempts} として書く（実測確認済み）。
# 旧FX-6（文字列形式）はこの実在フォーマットを一切検出できていなかった。
FX6="$WORK/fx6"; mkdir -p "$FX6"
write_json "$FX6/claude-cache.json" "{'fetched_at':$NOW-30,'five_hour':{'used_percent':10.0,'resets_at_epoch':$NOW+1000},'seven_day':{'used_percent':20.0,'resets_at_epoch':$NOW+90000},'last_error':{'at':$NOW-30,'type':'auth_expired','message':'access token expired; open Claude Code to refresh it','status':None,'attempts':0}}"
write_json "$FX6/codex-cache.json" "{'fetched_at':$NOW-30,'five_hour':{'used_percent':5,'resets_at_epoch':$NOW+2000},'seven_day':{'used_percent':5,'resets_at_epoch':$NOW+90000},'last_error':{'at':$NOW-30,'type':'http','message':'rate limited','status':429,'attempts':3}}"

echo "=== FX-6: last_errorが実際の取得器の形（オブジェクト・陽性） ==="
{
  json6="$(run_json "$FX6")"; rc6=$?
  assert_eq "FX-6 exit 0" "0" "$rc6"
  # データ自体は新鮮・完全なのでusage_stateはok（last_errorの有無で
  # usage_stateを変えない設計＝検討経緯論点1参照。error欄で別途表現する）。
  assert_eq "FX-6 claude-subscription usage_state=ok（データ自体は新鮮）" "ok" "$(pool_field "$json6" claude-subscription usage_state)"
  err6_claude="$(pool_field "$json6" claude-subscription error)"
  assert_eq "FX-6 claude側errorはtype=auth_expiredのみ（statusはnullなので含めない）" "type=auth_expired" "$err6_claude"
  err6_codex="$(pool_field "$json6" codex-subscription error)"
  assert_eq "FX-6 codex側errorはtype=http status=429" "type=http status=429" "$err6_codex"
  assert_not_contains "FX-6 自由文のmessage(rate limited等)は一切再掲されない" "$json6" "rate limited"
  assert_not_contains "FX-6 自由文のmessage(access token expired等)は一切再掲されない" "$json6" "access token expired"

  human6="$(run_human "$FX6")"
  assert_not_contains "FX-6 人可読出力にも自由文messageが含まれない" "$human6" "rate limited"
  # 2026-09-08 worker-driven一次レビュー2巡目BLOCKING対応: usage_state=ok
  # でも取得エラーがあれば人可読行にも⚠️で出す（JSONだけに留めない・
  # データは新鮮でも取得試行自体が壊れかけていることを隠さない）。
  claude_line6="$(printf '%s\n' "$human6" | grep '^Claude枠:')"
  codex_line6="$(printf '%s\n' "$human6" | grep '^Codex枠:')"
  assert_contains "FX-6 usage_state=okでもclaude側の人可読行に⚠️取得エラーが出る" "$claude_line6" "⚠️取得エラー（type=auth_expired）"
  assert_contains "FX-6 usage_state=okでもcodex側の人可読行に⚠️取得エラーが出る" "$codex_line6" "⚠️取得エラー（type=http status=429）"
  n_lines6="$(printf '%s\n' "$human6" | wc -l | tr -d ' ')"
  assert_eq "FX-6 取得エラー表示があっても人可読は3行のまま（行数を変えない）" "3" "$n_lines6"
}

# ============================================================
# FX-6b: last_error.typeが実装器の閉じた語彙6値の外（陽性・BLOCKING再発防止）
# ============================================================
# 2026-09-08 worker-driven一次レビュー2巡目BLOCKING対応。1巡目で追加した
# ERROR_TYPE_RE（正規表現による「識別子っぽい形」判定）は、未知だが
# 識別子形式に一致する値（例: secret_material_encoded_here）をそのまま
# 通してしまっていた。ALLOWED_ERROR_TYPES（閉じた6値との完全一致）へ
# 変更した効果をFX-9とは別に単独で固定する。
FX6B="$WORK/fx6b"; mkdir -p "$FX6B"
write_json "$FX6B/claude-cache.json" "{'fetched_at':$NOW-30,'five_hour':{'used_percent':10.0,'resets_at_epoch':$NOW+1000},'seven_day':{'used_percent':20.0,'resets_at_epoch':$NOW+90000},'last_error':{'type':'secret_material_encoded_here','status':None}}"
write_json "$FX6B/codex-cache.json" "{'fetched_at':$NOW-30,'five_hour':{'used_percent':5,'resets_at_epoch':$NOW+2000},'seven_day':{'used_percent':5,'resets_at_epoch':$NOW+90000},'last_error':None}"

echo "=== FX-6b: last_error.typeが6値の許可リスト外（陽性・BLOCKING再発防止） ==="
{
  json6b="$(run_json "$FX6B")"; rc6b=$?
  assert_eq "FX-6b exit 0" "0" "$rc6b"
  err6b="$(pool_field "$json6b" claude-subscription error)"
  assert_eq "FX-6b 未知のtype(identifier形式に一致するが6値の外)は汎用の伏せ字文言に丸められる" "取得エラーがありますが詳細は伏せています（絶対厳守③・自由文は再掲しない）" "$err6b"
  assert_not_contains "FX-6b typeの生値(secret_material_encoded_here)が出力に一切含まれない" "$json6b" "secret_material_encoded_here"
}

# ============================================================
# FX-8: last_error内にNaNが混入（陽性。ファイル全体をparse_error扱いにする）
# ============================================================
FX8="$WORK/fx8"; mkdir -p "$FX8"
printf '{"fetched_at":%s,"five_hour":{"used_percent":NaN,"resets_at_epoch":%s},"seven_day":{"used_percent":20.0,"resets_at_epoch":%s},"last_error":null}' \
  "$((NOW - 30))" "$((NOW + 1000))" "$((NOW + 90000))" > "$FX8/claude-cache.json"
write_json "$FX8/codex-cache.json" "{'fetched_at':$NOW-30,'five_hour':{'used_percent':5,'resets_at_epoch':$NOW+2000},'seven_day':{'used_percent':5,'resets_at_epoch':$NOW+90000},'last_error':None}"

echo "=== FX-8: NaN混入（陽性・worker-driven一次レビューMAJOR-1対応） ==="
{
  json8="$(run_json "$FX8")"; rc8=$?
  assert_eq "FX-8 exit 0（NaN混入でも落ちない）" "0" "$rc8"
  assert_eq "FX-8 claude-subscription usage_state=error（NaNを含むファイル全体を疑う）" "error" "$(pool_field "$json8" claude-subscription usage_state)"
  assert_eq "FX-8 codex-subscription usage_state=ok（隣は道連れにしない）" "ok" "$(pool_field "$json8" codex-subscription usage_state)"
  assert_not_contains "FX-8 出力中に生のNaNトークンが残らない（非標準JSON拡張を出力しない）" "$json8" "NaN"

  human8="$(run_human "$FX8")"
  n_lines8="$(printf '%s\n' "$human8" | wc -l | tr -d ' ')"
  assert_eq "FX-8 NaN混入でも人可読は3行のまま" "3" "$n_lines8"
}

# ============================================================
# FX-9: last_errorオブジェクトのtypeが不正形式で秘密っぽい文字列を含む
# （陽性・絶対厳守③の直接検証）
# ============================================================
FX9="$WORK/fx9"; mkdir -p "$FX9"
write_json "$FX9/claude-cache.json" "{'fetched_at':$NOW-30,'five_hour':{'used_percent':10.0,'resets_at_epoch':$NOW+1000},'seven_day':{'used_percent':20.0,'resets_at_epoch':$NOW+90000},'last_error':{'type':'Bearer sk-abc123XYZsecret leaked!!','message':'whatever secret token=xyz AKIAABCDEFGHIJKLMNOP'}}"
write_json "$FX9/codex-cache.json" "{'fetched_at':$NOW-30,'five_hour':{'used_percent':5,'resets_at_epoch':$NOW+2000},'seven_day':{'used_percent':5,'resets_at_epoch':$NOW+90000},'last_error':None}"

echo "=== FX-9: last_error.typeが不正形式・秘密っぽい文字列混入（陽性・絶対厳守③） ==="
{
  json9="$(run_json "$FX9")"; rc9=$?
  assert_eq "FX-9 exit 0" "0" "$rc9"
  err9="$(pool_field "$json9" claude-subscription error)"
  assert_eq "FX-9 errorは汎用の伏せ字文言に丸められる（typeが識別子形式に一致しないため）" "取得エラーがありますが詳細は伏せています（絶対厳守③・自由文は再掲しない）" "$err9"
  assert_not_contains "FX-9 生の秘密値(sk-abc123XYZsecret)が出力に一切含まれない" "$json9" "sk-abc123XYZsecret"
  assert_not_contains "FX-9 生の秘密値(AKIAABCDEFGHIJKLMNOP)が出力に一切含まれない" "$json9" "AKIAABCDEFGHIJKLMNOP"
  assert_not_contains "FX-9 token=xyzという断片も出力に含まれない" "$json9" "token=xyz"

  human9="$(run_human "$FX9")"
  assert_not_contains "FX-9 人可読出力にも秘密値が含まれない" "$human9" "sk-abc123XYZsecret"
}

# ============================================================
# FX-10: model_weekly.labelに改行混入（陽性・行分断を防ぐ）
# ============================================================
FX10="$WORK/fx10"; mkdir -p "$FX10"
write_json "$FX10/claude-cache.json" "{'fetched_at':$NOW-30,'five_hour':{'used_percent':10.0,'resets_at_epoch':$NOW+1000},'seven_day':{'used_percent':20.0,'resets_at_epoch':$NOW+90000},'model_weekly':{'used_percent':10,'resets_at_epoch':$NOW+90000,'label':'Fa\\nble'},'last_error':None}"
write_json "$FX10/codex-cache.json" "{'fetched_at':$NOW-30,'five_hour':{'used_percent':5,'resets_at_epoch':$NOW+2000},'seven_day':{'used_percent':5,'resets_at_epoch':$NOW+90000},'last_error':None}"

echo "=== FX-10: model_weekly.labelに改行混入（陽性・worker-driven一次レビューMAJOR-4対応） ==="
{
  json10="$(run_json "$FX10")"; rc10=$?
  assert_eq "FX-10 exit 0" "0" "$rc10"
  n_windows10="$(printf '%s' "$json10" | python3 -c "
import json,sys
d = json.load(sys.stdin)
p = [p for p in d['pools'] if p['pool_ref']=='claude-subscription'][0]
print(len(p['windows']))
")"
  assert_eq "FX-10 改行混入labelのmodel_weekly窓は丸ごと無いものとして扱われる（windowsは5h/7dの2件のみ）" "2" "$n_windows10"

  human10="$(run_human "$FX10")"
  n_lines10="$(printf '%s\n' "$human10" | wc -l | tr -d ' ')"
  assert_eq "FX-10 改行混入labelがあっても人可読は3行のまま（分断されない）" "3" "$n_lines10"
}

# ============================================================
# FX-7: used_percent境界（陽性。150% → remaining_percentは0で止まる）
# ============================================================
FX7="$WORK/fx7"; mkdir -p "$FX7"
write_json "$FX7/claude-cache.json" "{'fetched_at':$NOW-30,'five_hour':{'used_percent':150,'resets_at_epoch':$NOW+1000},'seven_day':{'used_percent':20.0,'resets_at_epoch':$NOW+90000},'last_error':None}"
write_json "$FX7/codex-cache.json" "{'fetched_at':$NOW-30,'five_hour':{'used_percent':5,'resets_at_epoch':$NOW+2000},'seven_day':{'used_percent':5,'resets_at_epoch':$NOW+90000},'last_error':None}"

echo "=== FX-7: used_percent境界150%（陽性・変異確認） ==="
{
  json7="$(run_json "$FX7")"; rc7=$?
  assert_eq "FX-7 exit 0" "0" "$rc7"
  remaining7="$(printf '%s' "$json7" | python3 -c "
import json,sys
d = json.load(sys.stdin)
p = [p for p in d['pools'] if p['pool_ref']=='claude-subscription'][0]
w = [w for w in p['windows'] if w['window']=='five_hour'][0]
print(w['remaining_percent'])
")"
  assert_eq "FX-7 used_percent=150でもremaining_percentは0で止まり負にならない" "0" "$remaining7"
}

# ============================================================
# FX-11: --cache-dirの優先順位（陽性・worker-driven一次レビュー2巡目MINOR対応）
# ============================================================
# AIENV_USAGE_CACHE_DIRとは別のディレクトリを--cache-dirで指定すると、
# 引数側が勝つこと（usage_cache_dir()の優先順位①cli_override②環境変数
# ③既定）を固定する。
FX11_ENV="$WORK/fx11-env"; mkdir -p "$FX11_ENV"  # 環境変数側（欠落のまま）
FX11_CLI="$WORK/fx11-cli"; mkdir -p "$FX11_CLI"  # --cache-dir側（正常データ）
write_json "$FX11_CLI/claude-cache.json" "{'fetched_at':$NOW-30,'five_hour':{'used_percent':10.0,'resets_at_epoch':$NOW+1000},'seven_day':{'used_percent':20.0,'resets_at_epoch':$NOW+90000},'last_error':None}"
write_json "$FX11_CLI/codex-cache.json" "{'fetched_at':$NOW-30,'five_hour':{'used_percent':5,'resets_at_epoch':$NOW+2000},'seven_day':{'used_percent':5,'resets_at_epoch':$NOW+90000},'last_error':None}"

echo "=== FX-11: --cache-dirがAIENV_USAGE_CACHE_DIRより優先される（陽性） ==="
{
  json11="$(AIENV_USAGE_CACHE_DIR="$FX11_ENV" python3 "$LIB" --json --now "$NOW" --cache-dir "$FX11_CLI")"; rc11=$?
  assert_eq "FX-11 exit 0" "0" "$rc11"
  assert_eq "FX-11 --cache-dirが優先されclaude-subscriptionはok（環境変数側は空ディレクトリでmissingのはず）" "ok" "$(pool_field "$json11" claude-subscription usage_state)"

  # 逆方向: --cache-dirを指定しなければ従来どおり環境変数が効く（回帰確認）。
  json11b="$(run_json "$FX11_ENV")"
  assert_eq "FX-11 --cache-dir未指定なら従来どおり環境変数が使われclaude-subscriptionはmissing" "missing" "$(pool_field "$json11b" claude-subscription usage_state)"
}

# ============================================================
# FX-12: 巨大なresets_at_epoch（陽性・worker-driven一次レビュー2巡目MINOR対応）
# ============================================================
# _format_reset()のtry/except（datetime変換の失敗を静かに「不明」へ倒す）が
# 実際にクラッシュを防ぐことを確認する。NaN以外の「壊れた数値」経路。
FX12="$WORK/fx12"; mkdir -p "$FX12"
write_json "$FX12/claude-cache.json" "{'fetched_at':$NOW-30,'five_hour':{'used_percent':10.0,'resets_at_epoch':99999999999999999999},'seven_day':{'used_percent':20.0,'resets_at_epoch':$NOW+90000},'last_error':None}"
write_json "$FX12/codex-cache.json" "{'fetched_at':$NOW-30,'five_hour':{'used_percent':5,'resets_at_epoch':$NOW+2000},'seven_day':{'used_percent':5,'resets_at_epoch':$NOW+90000},'last_error':None}"

echo "=== FX-12: 巨大なresets_at_epoch（陽性・_format_reset()のクラッシュ防止） ==="
{
  json12="$(run_json "$FX12")"; rc12=$?
  assert_eq "FX-12 exit 0（巨大epochでも落ちない・JSON側はresets_at_epochをそのまま数値で返す）" "0" "$rc12"
  assert_eq "FX-12 claude-subscription usage_state=ok（他のフィールドは正常なので窓自体は生きる）" "ok" "$(pool_field "$json12" claude-subscription usage_state)"

  human12="$(run_human "$FX12")"; rc12h=$?
  assert_eq "FX-12 人可読側もexit 0（datetime変換失敗でクラッシュしない）" "0" "$rc12h"
  n_lines12="$(printf '%s\n' "$human12" | wc -l | tr -d ' ')"
  assert_eq "FX-12 巨大epochでも人可読は3行のまま" "3" "$n_lines12"
  claude_line12="$(printf '%s\n' "$human12" | grep '^Claude枠:')"
  assert_not_contains "FX-12 巨大epochの窓には「リセット」表示を出さない（不明として省略）" "$claude_line12" "リセット"
}

# ============================================================
# FX-13: five_hour/seven_dayのresets_at_epoch欠落（陽性・検証職1巡目MINOR-5対応）
# ============================================================
# used_percentはあるがresets_at_epochが無い必須窓は、黙ってusage_state=okの
# まま（リセット時刻表示だけが静かに消える）にせず、pool全体をerrorにする
# （書き手側の契約＝usage-fetch.shのD-15と対＝coding-doc-style §4）。
FX13="$WORK/fx13"; mkdir -p "$FX13"
write_json "$FX13/claude-cache.json" "{'schema_version':1,'service':'claude','fetched_at':$NOW-30,'updated_at':$NOW-30,'five_hour':{'used_percent':10.0,'resets_at_epoch':None},'seven_day':{'used_percent':20.0,'resets_at_epoch':$NOW+90000},'last_error':None}"
write_json "$FX13/codex-cache.json" "{'schema_version':1,'service':'codex','fetched_at':$NOW-30,'updated_at':$NOW-30,'five_hour':{'used_percent':5,'resets_at_epoch':$NOW+2000},'seven_day':{'used_percent':5,'resets_at_epoch':$NOW+90000},'last_error':None}"

echo "=== FX-13: 必須窓のresets_at_epoch欠落（陽性・検証職1巡目MINOR-5対応） ==="
{
  json13="$(run_json "$FX13")"; rc13=$?
  assert_eq "FX-13 exit 0（提示専用の契約は維持）" "0" "$rc13"
  assert_eq "FX-13 claude-subscription usage_state=error（five_hourのresets_at_epoch欠落を黙ってokにしない）" "error" "$(pool_field "$json13" claude-subscription usage_state)"
  assert_eq "FX-13 claude-subscription windows=[]（errorなので窓は出さない）" "0" "$(python3 -c "
import json,sys
d=json.loads(sys.argv[1])
p=[p for p in d['pools'] if p['pool_ref']=='claude-subscription'][0]
print(len(p['windows']))
" "$json13")"
  assert_eq "FX-13 codex-subscriptionは影響を受けない（正常）" "ok" "$(pool_field "$json13" codex-subscription usage_state)"

  human13="$(run_human "$FX13")"
  n_lines13="$(printf '%s\n' "$human13" | wc -l | tr -d ' ')"
  assert_eq "FX-13 人可読は3行のまま" "3" "$n_lines13"
  assert_contains "FX-13 Claude枠は取得できません表示になる" "$human13" "Claude枠: 取得できません"
}

# ============================================================
# FX-14: last_error.type="curl"（陽性・検証職1巡目MINOR-6対応）
# ============================================================
# scripts/usage-fetch.sh のD-3はcurl系の通信エラー（curl_exit=5/6/7/28/52/
# 55/56）をtype="curl"で記録する。usage_snapshot.pyの許可リストにcurlが
# 無いと、常に汎用の伏せ字文言へ丸められてしまう（取得器とsnapshotの
# 許可リストが不一致だった穴）。
FX14="$WORK/fx14"; mkdir -p "$FX14"
write_json "$FX14/claude-cache.json" "{'schema_version':1,'service':'claude','fetched_at':$NOW-30,'updated_at':$NOW-30,'five_hour':{'used_percent':10.0,'resets_at_epoch':$NOW+1000},'seven_day':{'used_percent':20.0,'resets_at_epoch':$NOW+90000},'last_error':{'at':$NOW-30,'type':'curl','message':'network error (curl_exit=6)','status':None,'attempts':3}}"
write_json "$FX14/codex-cache.json" "{'schema_version':1,'service':'codex','fetched_at':$NOW-30,'updated_at':$NOW-30,'five_hour':{'used_percent':5,'resets_at_epoch':$NOW+2000},'seven_day':{'used_percent':5,'resets_at_epoch':$NOW+90000},'last_error':None}"

echo "=== FX-14: last_error.type=curl（陽性・検証職1巡目MINOR-6対応） ==="
{
  json14="$(run_json "$FX14")"; rc14=$?
  assert_eq "FX-14 exit 0" "0" "$rc14"
  assert_eq "FX-14 error要約にtype=curlが出る（許可リストに追加済み）" "type=curl" "$(pool_field "$json14" claude-subscription error)"
  assert_not_contains "FX-14 自由文のmessageは再掲されない（絶対厳守③）" "$json14" "network error"

  human14="$(run_human "$FX14")"
  assert_contains "FX-14 人可読にも取得エラー（type=curl）が出る" "$human14" "⚠️取得エラー（type=curl）"
}

# ============================================================
# AST到達可能性検査（AC-95③・許可リスト方式の簡易版）
# ============================================================
# 2026-09-08 worker-driven一次レビュー1巡目MAJOR-4対応で新設。coding-doc-
# style §4「静的検査には陽性fixtureを必ず置く」に従い、変異確認（陽性
# fixture）を併設する。
# ⚠️ 2巡目MAJOR対応: 当初は(演算種別,関数名)の**集合**だけを比較しており、
# 既に許可された関数の中へ新しい減算・比較を追加しても集合が変わらず
# 素通りする穴があった（指摘のとおり）。**個数まで固定した完全一致**へ
# 強化し、陽性fixtureも②「新しい関数を追加する場合」に加えて①「既に
# 許可された関数の中へ枠間演算を追加する場合」の両方を置く。
# ⚠️ それでも行単位・データフロー追跡までは行わない粗い検査であり、
# 要件書AC-95③が本来求める完全なAST到達可能性検査ではない
# （実装記録「残件」参照）。

AST_HELPER="$WORK/ast_check.py"
cat > "$AST_HELPER" <<'PYEOF'
import ast
import sys
from collections import Counter

path = sys.argv[1]
src = open(path, encoding="utf-8").read()
tree = ast.parse(src)

func_ranges = []
for node in ast.walk(tree):
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
        end = getattr(node, "end_lineno", node.lineno)
        func_ranges.append((node.name, node.lineno, end))


def enclosing_func(lineno):
    candidates = [(name, end - start) for name, start, end in func_ranges if start <= lineno <= end]
    if not candidates:
        return None
    return min(candidates, key=lambda c: c[1])[0]


counts = Counter()
for node in ast.walk(tree):
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Sub):
        counts[("SUB", enclosing_func(node.lineno))] += 1
    if isinstance(node, ast.Compare):
        for op in node.ops:
            if isinstance(op, (ast.Lt, ast.LtE, ast.Gt, ast.GtE)):
                counts[("CMP", enclosing_func(node.lineno))] += 1
                break

# 許可リスト（実測: 2026-09-08時点のusage_snapshot.pyを手で確認して転記。
# 個数まで固定する＝関数の中で件数が増えても検出できるようにする）。
# いずれも単一poolの内部値だけを扱う（枠間比較ではない）:
#   _extract_window: SUB1(remaining=100-used)・CMP2(remaining<0／
#     len(label)>40)
#   build_subscription_pool: SUB1(age=now-fetched_at)・
#     CMP2(age<0／age>stale_seconds)
#   _scrub_error: CMP1(100<=status<=999のHTTPステータス形式検査)
ALLOWED = {
    ("SUB", "_extract_window"): 1,
    ("CMP", "_extract_window"): 2,
    ("SUB", "build_subscription_pool"): 1,
    ("CMP", "build_subscription_pool"): 2,
    ("CMP", "_scrub_error"): 1,
}

found = {k: v for k, v in counts.items() if v > 0}
allowed_nonzero = {k: v for k, v in ALLOWED.items() if v > 0}

diffs = []
for k in sorted(set(found) | set(allowed_nonzero), key=lambda x: (x[0], x[1] or "")):
    f_count = found.get(k, 0)
    a_count = allowed_nonzero.get(k, 0)
    if f_count != a_count:
        diffs.append(f"{k[0]}:{k[1]}={f_count}(expected {a_count})")

if diffs:
    print("MISMATCH=" + ",".join(diffs))
else:
    print("OK")
PYEOF

echo "=== AST到達可能性検査（AC-95③・許可リスト方式の簡易版） ==="
{
  ast_result="$(python3 "$AST_HELPER" "$LIB")"
  assert_eq "実装コードの減算・不等号比較は既知の安全な関数・個数と完全一致する(_extract_window/build_subscription_pool/_scrub_error)" "OK" "$ast_result"

  # 陽性fixture①: 「枠間の残量を引き算する」ような新しい関数を一時コピー
  # へ追加すると、この検査が確実に検出することを確認する。
  MUT_LIB_NEWFUNC="$WORK/usage_snapshot_mutant_newfunc.py"
  cp "$LIB" "$MUT_LIB_NEWFUNC"
  printf '\n\ndef _bias_between_pools(pool_a, pool_b):\n    return pool_a["windows"][0]["remaining_percent"] - pool_b["windows"][0]["remaining_percent"]\n' >> "$MUT_LIB_NEWFUNC"
  mut_result_newfunc="$(python3 "$AST_HELPER" "$MUT_LIB_NEWFUNC")"
  assert_contains "陽性fixture①: 枠間の引き算を模した新関数を足すと個数不一致(MISMATCH)として検出される" "$mut_result_newfunc" "SUB:_bias_between_pools=1(expected 0)"

  # 陽性fixture②: 2巡目MAJOR対応の核心。既に許可されているbuild_subscription_
  # pool()の中へ、余分な減算を1つ追加しても検出できることを確認する
  # （「既に許可された関数の中は無条件で信用する」穴を塞いだことの証拠）。
  MUT_LIB_INFUNC="$WORK/usage_snapshot_mutant_infunc.py"
  python3 -c "
import re
src = open('$LIB', encoding='utf-8').read()
marker = 'def build_subscription_pool('
idx = src.index(marker)
body_start = src.index(':\n', idx) + 2
injected = '    _extra_bias_probe = now - stale_seconds  # 陽性fixture②: 許可済み関数内への追加演算\n'
mutated = src[:body_start] + injected + src[body_start:]
open('$MUT_LIB_INFUNC', 'w', encoding='utf-8').write(mutated)
"
  mut_result_infunc="$(python3 "$AST_HELPER" "$MUT_LIB_INFUNC")"
  assert_contains "陽性fixture②: 許可済み関数(build_subscription_pool)内へ演算を1つ追加すると個数不一致として検出される" "$mut_result_infunc" "SUB:build_subscription_pool=2(expected 1)"
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
