#!/usr/bin/env bash
# tests/test-usage-snapshot.sh — claude/hooks/lib/usage_snapshot.py の
# ユニットテスト（B1a「使用率の見える化」-実装-2026-09-08.md §2.3）。
#
# 2026-09-08 worker-driven一次レビュー（Codex・2巡）BLOCKING/MAJOR/MINOR
# 対応で拡充。
#
# fixture一覧（固定の総数は持たない＝検証職3巡目MINOR-2対応。数え方
# （区分単位／`$WORK/fx*`ディレクトリ単位等）によって合計値が割れやすく、
# 過去2巡で数字だけがドリフトして実体と食い違う指摘を繰り返し受けたため、
# 総数の明記はやめて下記の列挙そのものを正とする。再集計したい場合は
# `grep -o '\$WORK/fx[0-9a-z]*' tests/test-usage-snapshot.sh | sort -u | wc -l`
# でユニークなfixtureディレクトリ数を機械的に数え直せる。FX-13/FX-14は
# 検証職1巡目MINOR-5/6対応・FX-15〈3ディレクトリa-c・4観点a-d〉/FX-16
# 〈8ディレクトリ=観点a-h〉はB1-c「Codexチケット」対応で追加）:
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
#   FX-15 Codexの「チケット」(reset credit)の提示（4区分a-d）: 0枚／
#         reset_credits欠落(拡張前キャッシュ)は取得不可／複数枚・status混在
#         時の日付選択／Claude行への非影響（B1-c）
#   FX-16 チケットの正常形の網羅＋型不正の除外（8区分a-h・検証職2巡目対応）:
#         負値available_countはmissing(a)／count-only(credits空)は正常形で
#         state=ok(b)／expires_at_epoch=0(c)・失効済み(d)・型不正(e)は当該
#         フィールドだけNoneへ倒しエントリは残す／reset_scope汚染値は無視
#         して固定値(f)／id欠落creditは丸ごと除外(g)／全項目nullのcreditは
#         有効な別creditがあっても残らない(h)
# 横断検査（全fixtureに適用）: exit 0（AC-91①）・pools配列が常に3件
#   （AC-91②）・claude-subscription/codex-subscription/unlimitedの順序固定。
# 構造検査（FX-1限定）: AC-95①（--jsonの最上位・pool・window各階層の
#   フィールド名集合が実装記録の固定表と完全一致）・差分/順位/偏りを示す
#   フィールドが0件（フィールド名ベースの構造検査）。
# AST検査（許可リスト方式の簡易版・coding-doc-style §4「陽性fixtureを必ず
#   置く」対応）: usage_snapshot.py全体で減算(Sub)・不等号比較(Lt/LtE/Gt/GtE)
#   演算が発生する(演算種別,関数名)ごとの**個数**を、既知の安全な関数
#   （_extract_window・build_subscription_pool・_scrub_error・_valid_epoch・
#   _build_codex_reset_credits・_format_ticket_text＝いずれも単一pool・
#   単一チケットの内部値だけを扱う。後半3つはB1-c「Codexチケット」対応で
#   追加）の期待個数と完全一致させる（2巡目MAJOR対応で集合比較から個数
#   比較へ強化＝既に許可された関数内へ演算を追加しても検出できる）。
#   陽性fixtureは①新しい関数を追加する場合②既に許可された関数の中へ
#   演算を追加する場合の両方を置く。⚠️ それでも関数名単位・個数ベースの
#   粗い検査であり、AC-95③が本来求める行単位・データフロー追跡までの
#   完全なAST到達可能性検査（v19要件書全体のスコープ）ではない
#   （実装記録「残件」に明記）。
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
write_json "$FX1/codex-cache.json" "{'schema_version':1,'service':'codex','fetched_at':$NOW-60,'updated_at':$NOW-60,'five_hour':{'used_percent':66,'resets_at_epoch':$NOW+2000},'seven_day':{'used_percent':10,'resets_at_epoch':$NOW+90000},'reset_credits':{'available_count':1,'reset_scope':['five_hour','seven_day'],'credits':[{'id':'RateLimitResetCredit_abc123','status':'available','granted_at_epoch':1788539594,'expires_at_epoch':1791131594,'title':'Full reset (Weekly + 5 hr)'}]},'last_error':None}"

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
pool_ok = all(frozenset(p.keys()) == frozenset({'pool_ref','kind','usage_state','fetched_at','age_seconds','windows','error','reset_credits'}) for p in d['pools'])
win_ok = all(frozenset(w.keys()) == frozenset({'window','used_percent','remaining_percent','resets_at_epoch','label'}) for p in d['pools'] for w in p['windows'])
unlimited_windows_empty = [p for p in d['pools'] if p['pool_ref']=='unlimited'][0]['windows'] == []
unlimited_rc_null = [p for p in d['pools'] if p['pool_ref']=='unlimited'][0]['reset_credits'] is None
claude_rc = [p for p in d['pools'] if p['pool_ref']=='claude-subscription'][0]['reset_credits']
claude_rc_ok = frozenset(claude_rc.keys()) == frozenset({'available_count','reset_scope','credits','note'})
codex_rc = [p for p in d['pools'] if p['pool_ref']=='codex-subscription'][0]['reset_credits']
codex_rc_ok = frozenset(codex_rc.keys()) == frozenset({'available_count','reset_scope','credits','state'})
credit_ok = all(frozenset(c.keys()) == frozenset({'id','status','granted_at_epoch','expires_at_epoch','title'}) for c in codex_rc['credits'])
print('OK' if (top_ok and pool_ok and win_ok and unlimited_windows_empty and unlimited_rc_null and claude_rc_ok and codex_rc_ok and credit_ok) else 'NG')
")"
  assert_eq "FX-1 AC-95①: 最上位・pool・window・reset_credits・credit各階層のフィールド集合が実装記録の固定表と完全一致（B1-c反映）" "OK" "$fieldcheck1"

  codex_rc_state1="$(printf '%s' "$json1" | python3 -c "import json,sys; d=json.load(sys.stdin); print([p['reset_credits']['state'] for p in d['pools'] if p['pool_ref']=='codex-subscription'][0])")"
  assert_eq "FX-1 codex-subscription.reset_credits.state=ok" "ok" "$codex_rc_state1"

  # ⚠️ 検証職1巡目MINOR-1対応（記述訂正）: 当初「日本語を含む同一コマンド
  # 内でbrace展開が誤発火する」と説明していたが、検証職の再現実験（日本語
  # 無しでも失敗しないとの報告）を受けて再調査した結果、日本語の有無は
  # 無関係で、GNU Bashの仕様（ダブルクォート内の`{`・`,`はbrace展開の対象
  # 外）と矛盾しない現象であることが分かった。**最小再現**（本機の
  # `/bin/bash 3.2.57(1)-release`で確定的に再現・日本語無し）:
  #   f() { echo "argc=$#"; }
  #   f "x" "$(python3 -c "print({'a': 1, 'b': 2})")"   # → argc=3 に化ける
  #   v="$(python3 -c "print({'a': 1, 'b': 2})")"; f "x" "$v"  # → argc=2（安全）
  # 「コマンド置換の結果をコマンドの引数として直接使う」場合にだけ再現し、
  # 「変数へ一度代入してから参照する」場合は再現しない（`frozenset({...})`
  # のように直前に`(`が付く形も、直接引数に使えば同様に再現する＝当初の
  # 「直前の(で回避できる」という説明も誤りだった）。原因（bashのどの内部
  # 処理がこれを起こすか）は未特定のまま。対処は再現しない側の書き方
  # （dict(...)呼び出し構文で波括弧そのものを避け、かつ計算とassert_eqを
  # 別文＝変数へ一度代入してから渡す。fieldcheck1と同じパターンに揃える）
  # の両方を採用し、原因不明のまま安全側に倒した。
  claude_rc_check1="$(printf '%s' "$json1" | python3 -c "
import json,sys
d = json.load(sys.stdin)
rc = [p for p in d['pools'] if p['pool_ref']=='claude-subscription'][0]['reset_credits']
print('OK' if rc == dict(available_count=None, reset_scope=['five_hour'], credits=[], note='not_machine_readable') else 'NG:'+json.dumps(rc))
")"
  assert_eq "FX-1 claude-subscription.reset_credits は範囲差の固定値（5h窓のみ・not_machine_readable）" "OK" "$claude_rc_check1"

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

  # B1-c（2026-09-09）: Codex行の末尾にチケット句が付き、Claude行には
  # 何も足されない（本人指示2026-09-09＝範囲差の説明を提示に載せない）。
  codex_line1="$(printf '%s\n' "$human1" | grep '^Codex枠:')"
  assert_contains "FX-1 Codex行の末尾にチケット句（1枚・失効日MM/DD）が付く" "$codex_line1" "／チケット 1枚（10/05）"
  assert_not_contains "FX-1 Claude行にはチケット句を足さない" "$claude_line1" "チケット"
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

# 許可リスト（実測: 2026-09-09時点のusage_snapshot.pyを手で確認して転記。
# 個数まで固定する＝関数の中で件数が増えても検出できるようにする）。
# いずれも単一poolの内部値・単一チケットの内部値だけを扱う（枠間比較・
# チケット間比較ではない）:
#   _extract_window: SUB1(remaining=100-used)・CMP2(remaining<0／
#     len(label)>40)
#   build_subscription_pool: SUB1(age=now-fetched_at)・
#     CMP2(age<0／age>stale_seconds)
#   _scrub_error: CMP1(100<=status<=999のHTTPステータス形式検査)
#   _valid_epoch: CMP1(value>0＝1件のチケットが持つ1つのepoch値の健全性
#     検査。検証職1巡目MAJOR-2対応)
#   _build_codex_reset_credits: CMP1(available_count<0＝1件のpoolが持つ
#     枚数の非負性検査。検証職1巡目MAJOR-2対応。⚠️検証職2巡目MAJOR-2対応で
#     「available_count>0なら未失効の裏付けが必須」というCMPをもう1つ
#     持っていたが、正常な「枚数だけ取得(count-only)」を誤ってmissingへ
#     倒す過剰なfail-closed化だったため撤回＝CMP2→CMP1)
#   _format_ticket_text: CMP1(expires_at_epoch>now＝表示候補の未失効判定。
#     単一チケット内の判定で枠間比較ではない。検証職1巡目MAJOR-2対応)
ALLOWED = {
    ("SUB", "_extract_window"): 1,
    ("CMP", "_extract_window"): 2,
    ("SUB", "build_subscription_pool"): 1,
    ("CMP", "build_subscription_pool"): 2,
    ("CMP", "_scrub_error"): 1,
    ("CMP", "_valid_epoch"): 1,
    ("CMP", "_build_codex_reset_credits"): 1,
    ("CMP", "_format_ticket_text"): 1,
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

# ============================================================
# FX-15: 「チケット」（Codex rate-limit reset credit）の人可読・JSON表現
# （B1-c・2026-09-09。指示書§2.3＝JSONのキー集合更新・人可読行の固定文言・
# 0枚／取得不可／期限のJST表示・行数3のまま）
# ============================================================
echo "=== FX-15: チケット（reset credit）の提示（陽性・B1-c） ==="
{
  # (a) 0枚: available_countが0（credits空でもcreditsに0件あってもよい）。
  FX15A="$WORK/fx15a"; mkdir -p "$FX15A"
  write_json "$FX15A/claude-cache.json" "{'fetched_at':$NOW-60,'five_hour':{'used_percent':1,'resets_at_epoch':$NOW+1000},'seven_day':{'used_percent':1,'resets_at_epoch':$NOW+90000},'last_error':None}"
  write_json "$FX15A/codex-cache.json" "{'fetched_at':$NOW-30,'five_hour':{'used_percent':1,'resets_at_epoch':$NOW+2000},'seven_day':{'used_percent':1,'resets_at_epoch':$NOW+90000},'reset_credits':{'available_count':0,'reset_scope':['five_hour','seven_day'],'credits':[]},'last_error':None}"
  human15a="$(run_human "$FX15A")"
  n_lines15a="$(printf '%s\n' "$human15a" | wc -l | tr -d ' ')"
  assert_eq "FX-15a 人可読は3行のまま" "3" "$n_lines15a"
  assert_contains "FX-15a Codex行は「チケット 0枚」（枚数のみ・期限なし）" "$human15a" "Codex枠: 5h 残99%（リセット 18:39）／7d 残99%（09-09 19:06）・取得 0分前／チケット 0枚"
  json15a="$(run_json "$FX15A")"
  assert_eq "FX-15a JSON: reset_credits.state=ok（0枚を機械可読には'取れなかった'扱いにしない＝available_count=0はそれ自体正常値・検証職1巡目MINOR-2で説明文の誤記を訂正）" \
    "ok" "$(printf '%s' "$json15a" | python3 -c "import json,sys; d=json.load(sys.stdin); print([p['reset_credits']['state'] for p in d['pools'] if p['pool_ref']=='codex-subscription'][0])")"
  assert_eq "FX-15a JSON: reset_credits.available_count=0" "0" \
    "$(printf '%s' "$json15a" | python3 -c "import json,sys; d=json.load(sys.stdin); print([p['reset_credits']['available_count'] for p in d['pools'] if p['pool_ref']=='codex-subscription'][0])")"

  # (b) 取得不可: codex-cache.jsonにreset_creditsキー自体が無い（拡張前の
  # 実キャッシュ相当）。usage_state（five_hour/seven_day）はokのまま。
  FX15B="$WORK/fx15b"; mkdir -p "$FX15B"
  write_json "$FX15B/claude-cache.json" "{'fetched_at':$NOW-60,'five_hour':{'used_percent':1,'resets_at_epoch':$NOW+1000},'seven_day':{'used_percent':1,'resets_at_epoch':$NOW+90000},'last_error':None}"
  write_json "$FX15B/codex-cache.json" "{'fetched_at':$NOW-30,'five_hour':{'used_percent':1,'resets_at_epoch':$NOW+2000},'seven_day':{'used_percent':1,'resets_at_epoch':$NOW+90000},'last_error':None}"
  human15b="$(run_human "$FX15B")"
  assert_contains "FX-15b 拡張前キャッシュ(reset_credits欠落)は「チケット 取得不可」" "$human15b" "／チケット 取得不可"
  json15b="$(run_json "$FX15B")"
  assert_eq "FX-15b JSON: codex-subscription usage_stateはok（窓データは無傷）" "ok" "$(pool_field "$json15b" codex-subscription usage_state)"
  assert_eq "FX-15b JSON: reset_credits.state=missing" "missing" \
    "$(printf '%s' "$json15b" | python3 -c "import json,sys; d=json.load(sys.stdin); print([p['reset_credits']['state'] for p in d['pools'] if p['pool_ref']=='codex-subscription'][0])")"
  assert_eq "FX-15b JSON: reset_credits.available_count=null" "None" \
    "$(printf '%s' "$json15b" | python3 -c "import json,sys; d=json.load(sys.stdin); print([p['reset_credits']['available_count'] for p in d['pools'] if p['pool_ref']=='codex-subscription'][0])")"

  # (c) 複数枚・statusが混在: available 2枚（失効日が異なる）＋expired 1枚。
  # 表示は「available」だけを対象に最も早く失効する日付を添える。
  FX15C="$WORK/fx15c"; mkdir -p "$FX15C"
  write_json "$FX15C/claude-cache.json" "{'fetched_at':$NOW-60,'five_hour':{'used_percent':1,'resets_at_epoch':$NOW+1000},'seven_day':{'used_percent':1,'resets_at_epoch':$NOW+90000},'last_error':None}"
  write_json "$FX15C/codex-cache.json" "{'fetched_at':$NOW-30,'five_hour':{'used_percent':1,'resets_at_epoch':$NOW+2000},'seven_day':{'used_percent':1,'resets_at_epoch':$NOW+90000},'reset_credits':{'available_count':2,'reset_scope':['five_hour','seven_day'],'credits':[{'id':'RateLimitResetCredit_later','status':'available','granted_at_epoch':$NOW,'expires_at_epoch':1793550794,'title':'t'},{'id':'RateLimitResetCredit_sooner','status':'available','granted_at_epoch':$NOW,'expires_at_epoch':1791131594,'title':'t'},{'id':'RateLimitResetCredit_old','status':'expired','granted_at_epoch':$NOW,'expires_at_epoch':1700000000,'title':'t'}]},'last_error':None}"
  human15c="$(run_human "$FX15C")"
  assert_contains "FX-15c 複数枚: 枚数はavailable_countをそのまま表示（2枚）" "$human15c" "チケット 2枚"
  assert_contains "FX-15c 複数枚: 添える日付はavailableのうち最も早い失効日(10/05)。expiredの古い日付や、availableでも遅い方(11/02)は使わない" "$human15c" "チケット 2枚（10/05）"
  assert_not_contains "FX-15c availableでも遅い方の失効日(11/02)が誤って使われていない" "$human15c" "11/02"
  assert_not_contains "FX-15c expiredの失効日(11/15)が誤って使われていない" "$human15c" "11/15"

  # (d) FX-1のClaude行と同じfixtureで、Claude行にはreset_creditsの内容が
  # 一切影響しないことを別のcodex reset_credits値で再確認する（回帰防止）。
  claude_line15c="$(printf '%s\n' "$human15c" | grep '^Claude枠:')"
  assert_not_contains "FX-15d Claude行はcodexのreset_credits値に一切影響されない" "$claude_line15c" "チケット"
}

# ============================================================
# FX-16: 「チケット」の正常形の網羅＋壊れた値の除外（検証職2巡目MAJOR-1/
# MAJOR-2対応で全面書き換え）。
# ⚠️ 1巡目対応は「available_count>0なら未失効の裏付けが必須」という
# fail-closed化を入れたが、これは公式app-server応答の正常形である
# 「count-only」応答（`credits:null`・detail行が無い。availableCountが
# 権威値）を誤ってmissingへ倒す過剰な拒否だった（検証職2巡目MAJOR-2）。
# 本節は「正常形の網羅表（count-only／詳細あり／0枚／欠落／型不正）→
# 各形の期待JSON・人可読」を先に固定してから実装した結果を検証する
# （検証職2巡目の指摘どおりの順）。
# 各fixtureは five_hour/seven_day は完全に正常（usage_state=ok）に保ち、
# reset_credits側の1点だけを変えることで、結果の原因が意図した検査
# （`_build_codex_reset_credits`・`_extract_credit_entry`）以外にないことを
# 保証する（coding-doc-style §4「陽性fixtureが実際に拒否経路を通っていない」
# 再発防止）。
# ============================================================
echo "=== FX-16: チケットの正常形・型不正の除外（B1-c・検証職2巡目対応） ==="
{
  fx16_base_pools() { # $1=codex-cache.jsonのreset_credits部分（jqのdictリテラル文字列そのまま）
    local dir="$1" rc_literal="$2"
    write_json "$dir/claude-cache.json" "{'fetched_at':$NOW-60,'five_hour':{'used_percent':1,'resets_at_epoch':$NOW+1000},'seven_day':{'used_percent':1,'resets_at_epoch':$NOW+90000},'last_error':None}"
    write_json "$dir/codex-cache.json" "{'fetched_at':$NOW-30,'five_hour':{'used_percent':1,'resets_at_epoch':$NOW+2000},'seven_day':{'used_percent':1,'resets_at_epoch':$NOW+90000},'reset_credits':$rc_literal,'last_error':None}"
  }
  rc_state_of() { # $1=cache_dir
    printf '%s' "$(run_json "$1")" | python3 -c "import json,sys; d=json.load(sys.stdin); print([p['reset_credits']['state'] for p in d['pools'] if p['pool_ref']=='codex-subscription'][0])"
  }
  rc_credits_of() { # $1=cache_dir
    printf '%s' "$(run_json "$1")" | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps([p['reset_credits']['credits'] for p in d['pools'] if p['pool_ref']=='codex-subscription'][0]))"
  }

  # (a) 型不正な枚数（負値）→ 権威値そのものが壊れているのでmissing／
  # 取得不可へ倒す（検証職1巡目MAJOR-2で改善済み・2巡目でもここは維持）。
  FX16A="$WORK/fx16a"; mkdir -p "$FX16A"
  fx16_base_pools "$FX16A" "{'available_count':-1,'reset_scope':['five_hour','seven_day'],'credits':[{'id':'x','status':'available','granted_at_epoch':$NOW,'expires_at_epoch':1791131594,'title':'t'}]}"
  assert_eq "FX-16a available_count=-1はstate=missingへ倒す" "missing" "$(rc_state_of "$FX16A")"
  human16a="$(run_human "$FX16A")"
  assert_contains "FX-16a 人可読は「チケット -1枚」ではなく「取得不可」" "$human16a" "／チケット 取得不可"
  assert_not_contains "FX-16a 人可読に負の枚数を出さない" "$human16a" "-1枚"

  # (b) 【正常形＝count-only】available_count=1・creditsは空（公式
  # app-server応答の`credits:null`相当。詳細行を返さないのは異常ではない
  # ＝検証職2巡目MAJOR-2で反転）。available_countが権威値として
  # そのまま信頼され、state=ok・期限なしの「チケット 1枚」になる。
  FX16B="$WORK/fx16b"; mkdir -p "$FX16B"
  fx16_base_pools "$FX16B" "{'available_count':1,'reset_scope':['five_hour','seven_day'],'credits':[]}"
  assert_eq "FX-16b【正常形】count-onlyはstate=ok（missingへ倒さない）" "ok" "$(rc_state_of "$FX16B")"
  human16b="$(run_human "$FX16B")"
  assert_contains "FX-16b【正常形】人可読は期限なしの「チケット 1枚」" "$human16b" "／チケット 1枚"
  assert_not_contains "FX-16b【正常形】「取得不可」にはならない" "$human16b" "取得不可"
  assert_not_contains "FX-16b【正常形】無い期限を捏造して括弧を出さない" "$human16b" "チケット 1枚（"

  # (c) expires_at_epoch=0（1970年付近の壊れた値）→ その値だけをNoneへ
  # 倒す（id/status/granted_at_epochが正しい限りエントリ自体は残す）。
  # 枚数はcount-only同様に信頼され、日付だけ出さない。
  FX16C="$WORK/fx16c"; mkdir -p "$FX16C"
  fx16_base_pools "$FX16C" "{'available_count':1,'reset_scope':['five_hour','seven_day'],'credits':[{'id':'x','status':'available','granted_at_epoch':$NOW,'expires_at_epoch':0,'title':'t'}]}"
  assert_eq "FX-16c expires_at_epoch=0でもstate=ok（枚数は信頼する）" "ok" "$(rc_state_of "$FX16C")"
  assert_eq "FX-16c expires_at_epoch=0はJSON上nullへ正規化される（エントリは残す）" "null" \
    "$(printf '%s' "$(rc_credits_of "$FX16C")" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)[0]["expires_at_epoch"]))')"
  human16c="$(run_human "$FX16C")"
  assert_contains "FX-16c 人可読は期限なしの「チケット 1枚」" "$human16c" "／チケット 1枚"
  assert_not_contains "FX-16c 1970年付近の日付(01/01)を出さない" "$human16c" "01/01"

  # (d) status=availableだが失効日が過去（既に失効済みなのにavailableを
  # 名乗る矛盾）→ エントリはそのまま残す（型としては正しいepochのため。
  # 過去かどうかの判定は表示側`_format_ticket_text`の責務）が、表示の
  # 日付候補からは除外される。
  FX16D="$WORK/fx16d"; mkdir -p "$FX16D"
  fx16_base_pools "$FX16D" "{'available_count':1,'reset_scope':['five_hour','seven_day'],'credits':[{'id':'x','status':'available','granted_at_epoch':1700000000,'expires_at_epoch':1700000001,'title':'t'}]}"
  assert_eq "FX-16d 失効済みでもstate=ok（枚数は信頼する）" "ok" "$(rc_state_of "$FX16D")"
  human16d="$(run_human "$FX16D")"
  assert_contains "FX-16d 人可読は期限なしの「チケット 1枚」（過去の失効日を出さない）" "$human16d" "／チケット 1枚"
  assert_not_contains "FX-16d 失効済みの過去日付(11/15)を出さない" "$human16d" "11/15"

  # (e) expires_at_epochが文字列（型不正）→ (c)と同じくその値だけNoneへ
  # 倒し、エントリ自体（id/status/granted_at_epoch）は残す。
  FX16E="$WORK/fx16e"; mkdir -p "$FX16E"
  fx16_base_pools "$FX16E" "{'available_count':1,'reset_scope':['five_hour','seven_day'],'credits':[{'id':'x','status':'available','granted_at_epoch':$NOW,'expires_at_epoch':'1791131594','title':'t'}]}"
  credits16e="$(rc_credits_of "$FX16E")"
  assert_eq "FX-16e 型不正なexpires_at_epochだけNoneへ正規化し、id等は残す" "OK" \
    "$(printf '%s' "$credits16e" | python3 -c "
import json,sys
c = json.load(sys.stdin)
print('OK' if len(c) == 1 and c[0]['id'] == 'x' and c[0]['expires_at_epoch'] is None else 'NG:'+json.dumps(c))
")"
  human16e="$(run_human "$FX16E")"
  assert_contains "FX-16e 人可読は期限なしの「チケット 1枚」" "$human16e" "／チケット 1枚"

  # (f) reset_scopeがキャッシュ内で汚染されていても出力は常に固定値。
  FX16F="$WORK/fx16f"; mkdir -p "$FX16F"
  fx16_base_pools "$FX16F" "{'available_count':1,'reset_scope':['secret_scope'],'credits':[{'id':'x','status':'available','granted_at_epoch':$NOW,'expires_at_epoch':1791131594,'title':'t'}]}"
  json16f="$(run_json "$FX16F")"
  scope16f="$(printf '%s' "$json16f" | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps([p['reset_credits']['reset_scope'] for p in d['pools'] if p['pool_ref']=='codex-subscription'][0]))")"
  assert_eq "FX-16f reset_scopeは汚染値を無視し常に固定値" '["five_hour", "seven_day"]' "$scope16f"
  assert_not_contains "FX-16f 汚染値がJSONに漏れていない" "$json16f" "secret_scope"

  # (g) 【検証職2巡目MAJOR-1】id欠落のcredit（他フィールドは正常）は丸ごと
  # 除外する。available_countは影響を受けず信頼される（枚数と詳細行は
  # 独立に検証する設計＝指摘3と同じ考え方をcredit単位にも適用）。
  FX16G="$WORK/fx16g"; mkdir -p "$FX16G"
  fx16_base_pools "$FX16G" "{'available_count':1,'reset_scope':['five_hour','seven_day'],'credits':[{'status':'available','granted_at_epoch':$NOW,'expires_at_epoch':1791131594,'title':'t'}]}"
  assert_eq "FX-16g idが無いcreditは丸ごと除外される" "[]" "$(rc_credits_of "$FX16G")"
  assert_eq "FX-16g それでもavailable_countは信頼されstate=ok" "ok" "$(rc_state_of "$FX16G")"
  human16g="$(run_human "$FX16G")"
  assert_contains "FX-16g 人可読は期限なしの「チケット 1枚」" "$human16g" "／チケット 1枚"

  # (h) 【検証職2巡目MAJOR-1の直接repro】有効な1件＋全項目nullの1件が
  # 混在＝有効な方の存在によって、全項目nullの方まで`state:ok`の
  # credits[]へ残ってしまわないことを確認する。
  FX16H="$WORK/fx16h"; mkdir -p "$FX16H"
  fx16_base_pools "$FX16H" "{'available_count':2,'reset_scope':['five_hour','seven_day'],'credits':[{'id':'RateLimitResetCredit_ok','status':'available','granted_at_epoch':$NOW,'expires_at_epoch':1791131594,'title':'t'},{'id':None,'status':None,'granted_at_epoch':None,'expires_at_epoch':None,'title':None}]}"
  credits16h="$(rc_credits_of "$FX16H")"
  assert_eq "FX-16h 全項目nullのcreditは有効な別creditがあっても残らない（1件だけになる）" "OK" \
    "$(printf '%s' "$credits16h" | python3 -c "
import json,sys
c = json.load(sys.stdin)
print('OK' if len(c) == 1 and c[0]['id'] == 'RateLimitResetCredit_ok' else 'NG:'+json.dumps(c))
")"
  human16h="$(run_human "$FX16H")"
  assert_contains "FX-16h 有効な方の失効日(10/05)は表示される" "$human16h" "チケット 2枚（10/05）"

  # --- 変異確認（coding-doc-style §4「陽性fixtureが実際に拒否経路／正常
  # 経路を通っているか」の直接検証） ---
  # (i) FX-16aが検出する不具合（負のavailable_countをそのまま信用する）を
  # 意図的に再現した壊れコピーへ差し戻すと、同じfixtureが確実に失敗側へ
  # 転じることを確認する。
  MUT_LIB_NOGUARD="$WORK/usage_snapshot_mutant_noguard.py"
  python3 -c "
src = open('$LIB', encoding='utf-8').read()
marker = '    if available_count is not None and available_count < 0:\n        available_count = None\n'
assert marker in src, '対象コードが見つからない（実装が変更された場合はこのテストも更新すること）'
mutated = src.replace(marker, '')
open('$MUT_LIB_NOGUARD', 'w', encoding='utf-8').write(mutated)
"
  human16a_mut="$(AIENV_USAGE_CACHE_DIR="$FX16A" python3 "$MUT_LIB_NOGUARD" --now "$NOW")"
  assert_contains "陽性fixture(FX-16a向け): 負値ガードを外した変異コピーは-1枚をそのまま出す（fixtureが実際にこの分岐を通っている証拠）" "$human16a_mut" "-1枚"

  # (j) 検証職2巡目MAJOR-2で撤回した「available_count>0なら未失効の
  # 裏付けが必須」というfail-closed化を意図的に復元した壊れコピーへ戻すと、
  # FX-16b（count-only・正常形）が「取得不可」へ誤って転じることを確認する
  # （撤回が正しく効いていることの直接証拠）。
  MUT_LIB_OVERCLOSED="$WORK/usage_snapshot_mutant_overclosed.py"
  python3 -c "
src = open('$LIB', encoding='utf-8').read()
marker = '''    return {
        \"available_count\": available_count,
        \"reset_scope\": CODEX_RESET_SCOPE,
        \"credits\": credits,
        \"state\": \"ok\",
    }'''
assert marker in src, '対象コードが見つからない（実装が変更された場合はこのテストも更新すること）'
injected = '''    if available_count > 0 and not any(
        c[\"status\"] == \"available\" and c[\"expires_at_epoch\"] is not None and c[\"expires_at_epoch\"] > 0
        for c in credits
    ):
        return missing
''' + marker
mutated = src.replace(marker, injected, 1)
open('$MUT_LIB_OVERCLOSED', 'w', encoding='utf-8').write(mutated)
"
  human16b_mut="$(AIENV_USAGE_CACHE_DIR="$FX16B" python3 "$MUT_LIB_OVERCLOSED" --now "$NOW")"
  assert_contains "陽性fixture(FX-16b向け): 撤回済みのfail-closed化を復元した変異コピーはcount-onlyを誤って取得不可にする（撤回が実際に効いている証拠）" "$human16b_mut" "取得不可"

  # (k) FX-16gが検出する不具合（idが無いcreditを受理する）を意図的に
  # 再現した壊れコピーへ差し戻すと、当該creditがcredits[]へ残ることを
  # 確認する。
  MUT_LIB_NOIDCHECK="$WORK/usage_snapshot_mutant_noidcheck.py"
  python3 -c "
src = open('$LIB', encoding='utf-8').read()
marker = '    if not (isinstance(id_, str) and id_ != \"\"):\n        return None\n'
assert marker in src, '対象コードが見つからない（実装が変更された場合はこのテストも更新すること）'
mutated = src.replace(marker, '')
open('$MUT_LIB_NOIDCHECK', 'w', encoding='utf-8').write(mutated)
"
  credits16g_mut="$(AIENV_USAGE_CACHE_DIR="$FX16G" python3 "$MUT_LIB_NOIDCHECK" --json --now "$NOW" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len([p for p in d['pools'] if p['pool_ref']=='codex-subscription'][0]['reset_credits']['credits']))")"
  assert_eq "陽性fixture(FX-16g向け): id必須チェックを外した変異コピーはidの無いcreditも残してしまう（fixtureが実際にこの検査を通っている証拠）" "1" "$credits16g_mut"
}

echo "=== AST到達可能性検査（AC-95③・許可リスト方式の簡易版） ==="
{
  ast_result="$(python3 "$AST_HELPER" "$LIB")"
  assert_eq "実装コードの減算・不等号比較は既知の安全な関数・個数と完全一致する(_extract_window/build_subscription_pool/_scrub_error/_valid_epoch/_build_codex_reset_credits/_format_ticket_text)" "OK" "$ast_result"

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
