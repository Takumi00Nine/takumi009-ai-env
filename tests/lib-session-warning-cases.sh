# 要望8 AC-1/2/3・設計「Claudeの既存の警告」「受入条件の確かめ方」。
# 実フックを偽HOME・キャッシュ・transcriptで実行。実設定は読まない。
# test-install-main.sh からsource。ハーネスと隔離fixtureを共用する。
sf_init

# settings.json.env は Claude がフックへ渡す経路を再現する。
warn() {
  sf_env python3 - "$SF_REPO" "$SF_WORK/transcript.jsonl" "$1" <<'PY'
import json, os, pathlib, subprocess, sys
repo, transcript, sid = sys.argv[1:]
env = dict(os.environ)
env.update(json.loads((pathlib.Path(repo)/'core/assembly/settings.json').read_text()).get('env', {}))
r = subprocess.run(['bash', repo+'/core/connect/claude-code/context-size-warn.sh'],
    input=json.dumps(dict(session_id=sid, transcript_path=transcript)),
    text=True, capture_output=True, env=env)
print(r.stdout, end='')
sys.exit(r.returncode)
PY
}
usage() {
  python3 - "$SF_WORK/transcript.jsonl" "$1" <<'PY'
import json, sys
with open(sys.argv[1], 'a') as f:
    f.write(json.dumps(dict(type='assistant', message=dict(model='test-model',
        usage=dict(input_tokens=int(sys.argv[2]), cache_read_input_tokens=0,
                   cache_creation_input_tokens=0))))+'\n')
PY
}
quiet() { [ -z "$OUT" ]; }
loud() { [ -n "$OUT" ]; }
step="$(python3 - "$SF_REPO/core/assembly/settings.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get('env', {}).get('CTX_REWARN_STEP', ''))
PY
)"
sf_check 'S8-W01: 再警告幅の正本はひな形の50000' test "$step" = 50000
usage 249999; OUT="$(warn cycle)"; sf_check 'S8-W02: 250k直前は無警告' quiet
usage 250000; OUT="$(warn cycle)"; sf_check 'S8-W03: 250k到達で記録を促す' loud
sf_check 'S8-W04: 警告文は案件ノート・進捗・次の作業・留意事項・検討経緯・同じ画面を含む' \
  python3 -c 'import sys; s=sys.argv[1]; assert all(w in s for w in ["案件ノート","進捗","次の作業","留意事項","検討経緯","同じ画面"]); assert "250" in s' "$OUT"
sf_check 'S8-W05: 警告文に旧起動・強制上限・区切りの指示がない' \
  python3 -c 'import re,sys; assert not re.search(r"session-handoff|新.{0,8}セッション|強制上限|区切|切れ目|3条件|800k|800000", sys.argv[1])' "$OUT"
usage 299999; OUT="$(warn cycle)"; sf_check 'S8-W06: 同周期50k増の直前は再警告しない' quiet
usage 300000; OUT="$(warn cycle)"; sf_check 'S8-W07: 同周期50k増で再警告' loud
usage 349999; OUT="$(warn cycle)"; sf_check 'S8-W08: 次の50k直前も無警告' quiet
usage 350000; OUT="$(warn cycle)"; sf_check 'S8-W09: 次の50k到達でも再警告' loud
usage 100000; OUT="$(warn cycle)"; sf_check 'S8-W10: 要約で長さが減った時は無警告' quiet
usage 250000; OUT="$(warn cycle)"; sf_check 'S8-W11: 要約後の再到達で再警告' loud
# 境界直前の警告状態は、新しい周期の同じ長さへ持ち越さない。
printf '%s\n' '{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"auto","preTokens":350000}}' >> "$SF_WORK/transcript.jsonl"
usage 250000; OUT="$(warn cycle)"; sf_check 'S8-W12: 明示の要約境界後も再警告' loud
sf_set_env CLAUDE_CODE_AUTO_COMPACT_WINDOW 400000
sf_set_env CTX_WARN_AT 1
usage 349999; OUT="$(warn changed)"; sf_check 'S8-W13: 共通値変更で350k直前は無警告' quiet
usage 350000; OUT="$(warn changed)"; sf_check 'S8-W14: 共通値だけ変えると警告長も追随' loud
sf_set_env CTX_REWARN_STEP 25000
usage 374999; OUT="$(warn step)"; sf_check 'S8-W15: 幅だけ変えると375k直前は無警告' quiet
usage 375000; OUT="$(warn step)"; sf_check 'S8-W16: 幅だけ変えると警告長も追随' loud
rm "$SF_WORK/transcript.jsonl"
rc=0; OUT="$(warn missing)" || rc=$?
sf_check 'S8-W17: transcript読取失敗でも本体を止めない' test "$rc" = 0
sf_check 'S8-W18: transcript読取失敗は無警告' quiet
printf 'not json\n' > "$SF_WORK/transcript.jsonl"
rc=0; OUT="$(warn broken)" || rc=$?
sf_check 'S8-W19: 長さを解釈できなくても本体を止めない' test "$rc" = 0
rm -rf "$SF_WORK"
