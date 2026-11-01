#!/bin/bash
# context-size-warn.sh — UserPromptSubmit フック
# transcript から長さを推定し、要約前に案件ノートの未記録分を書く合図を出す。
#
# 環境変数（値の正本は core/assembly/settings.json の env）:
#   CLAUDE_CODE_AUTO_COMPACT_WINDOW  共通の要約開始値
#   CTX_REWARN_STEP  再警告の増分。警告長＝要約開始値−この幅
#   CTX_WARN_MODELS  対象モデルの grep 正規表現（既定 . ＝全モデル）
# リーダー判定はモデルでなく transcript の agentName で行う（2026-08-10 実測:
# ワーカー/チームメイトのセッションは全行に agentName が付き、リーダーには付かない。
# UserPromptSubmit はワーカー側でも発火しうるため、これが唯一確実な判別子。
# モデル不問なのでサブ機の Opus 5 リーダーでも警告が届く）。
# 失敗時は常に無言で exit 0（フェイルセーフ・本体動作を妨げない）。

set -u
INPUT=$(cat) || exit 0

COMPACT_WINDOW="${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}"
REWARN_STEP="${CTX_REWARN_STEP:-}"
WARN_MODELS="${CTX_WARN_MODELS:-.}"
STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/context-size-warn"

CTX_HOOK_INPUT="$INPUT" python3 - "$COMPACT_WINDOW" "$REWARN_STEP" "$WARN_MODELS" "$STATE_DIR" <<'PYEOF' 2>/dev/null || exit 0
import json, os, re, subprocess, sys

window, step = int(sys.argv[1]), int(sys.argv[2])
if not 0 < step < window:
    sys.exit(0)
warn_at = window - step
model_re, state_dir = sys.argv[3], sys.argv[4]

try:
    hook = json.loads(os.environ.get("CTX_HOOK_INPUT", ""))
except Exception:
    sys.exit(0)

tp = hook.get("transcript_path") or ""
sid = hook.get("session_id") or "unknown"
if not tp or not os.path.isfile(tp):
    sys.exit(0)

# 末尾 2MB だけ読み、最後の assistant usage を拾う（巨大 transcript の全走査を避ける）
size = os.path.getsize(tp)
with open(tp, "rb") as f:
    if size > 2_000_000:
        f.seek(size - 2_000_000)
        f.readline()  # 途中行を捨てる
    tail_start = f.tell()
    tail = f.read()

ctx = 0
model = ""
agent_name = None
boundary = 0
decrease = 0
position = tail_start
for line in tail.splitlines(keepends=True):
    position += len(line)
    try:
        o = json.loads(line)
    except Exception:
        continue
    if o.get("type") == "system" and o.get("subtype") == "compact_boundary":
        boundary = position
        ctx = 0
        continue
    if o.get("type") != "assistant":
        continue
    u = (o.get("message") or {}).get("usage") or {}
    c = (u.get("input_tokens", 0) or 0) \
        + (u.get("cache_read_input_tokens", 0) or 0) \
        + (u.get("cache_creation_input_tokens", 0) or 0)
    if c > 0:
        if c < ctx:
            decrease = position
        ctx = c
        model = (o.get("message") or {}).get("model") or model
        agent_name = o.get("agentName")

# agentName があればワーカー/チームメイトのセッション＝リーダーではないので無言
if agent_name:
    sys.exit(0)

if not ctx or not re.search(model_re, model, re.I):
    sys.exit(0)

# 再警告制御: 前回警告時のコンテキストから step 以上増えるまで沈黙
os.makedirs(state_dir, exist_ok=True)
state_file = os.path.join(state_dir, sid)
last = 0
cycle = [boundary, decrease]
try:
    with open(state_file) as f:
        state = json.load(f)
    if state.get("cycle") == cycle and ctx >= state.get("ctx", 0):
        last = state.get("last", 0)
except Exception:
    pass
notify = ctx >= warn_at and (not last or ctx >= last + step)
with open(state_file, "w") as f:
    json.dump(dict(cycle=cycle, ctx=ctx, last=ctx if notify else last), f)
if not notify:
    sys.exit(0)

# ターン数（参考表示・grep は高速）
try:
    turns = subprocess.run(
        ["grep", "-c", '"type":"assistant"', tp],
        capture_output=True, text=True, timeout=3,
    ).stdout.strip() or "?"
except Exception:
    turns = "?"

print(
    f"⚠️【要約前の記録確認】現在のコンテキスト推定 ~{ctx//1000}k トークン"
    f"（しきい値 {warn_at//1000}k 超・model={model}・assistant応答 {turns} 回）。"
    "正本: ~/Data/obsidian/Preferences/session-handoff.md・~/Data/obsidian/Preferences/core-conduct.md（記録）"
)
PYEOF
exit 0
