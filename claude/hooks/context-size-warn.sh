#!/bin/bash
# context-size-warn.sh — UserPromptSubmit フック
# 現セッションのコンテキストサイズを transcript から推定し、しきい値超過で
# リーダーに「セッション分割 / compact を提案せよ」という警告をコンテキスト注入する。
# 背景: Fable 週次枠の主消費源は「長大セッション×多ターンの cache 読み」
# （実測 2026-08-10・Fragments/2026-08/2026-08-10.md「Fable 週次枠の消費実測」）。
#
# 環境変数（settings.json の env か plist で上書き可）:
#   CTX_WARN_AT      初回警告しきい値（トークン。既定 200000＝2026-08-10 本人決定。
#                    120k 起点だと直近14日の62%が警告対象＝過剰。200k は怪物セッション
#                    狙い撃ち（38%）で、累積コストの二乗特性上、検知価値はほぼ落ちない）
#   CTX_REWARN_STEP  再警告の増分（既定 50000）
#   CTX_WARN_MODELS  対象モデルの grep 正規表現（既定 . ＝全モデル）
# リーダー判定はモデルでなく transcript の agentName で行う（2026-08-10 実測:
# ワーカー/チームメイトのセッションは全行に agentName が付き、リーダーには付かない。
# UserPromptSubmit はワーカー側でも発火しうるため、これが唯一確実な判別子。
# モデル不問なのでサブ機の Opus 5 リーダーでも警告が届く）。
# 失敗時は常に無言で exit 0（フェイルセーフ・本体動作を妨げない）。

set -u
INPUT=$(cat) || exit 0

WARN_AT="${CTX_WARN_AT:-200000}"
REWARN_STEP="${CTX_REWARN_STEP:-50000}"
WARN_MODELS="${CTX_WARN_MODELS:-.}"
STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/context-size-warn"

CTX_HOOK_INPUT="$INPUT" python3 - "$WARN_AT" "$REWARN_STEP" "$WARN_MODELS" "$STATE_DIR" <<'PYEOF' 2>/dev/null || exit 0
import json, os, re, subprocess, sys

warn_at, step = int(sys.argv[1]), int(sys.argv[2])
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
    tail = f.read().decode("utf-8", "replace")

ctx = 0
model = ""
agent_name = None
for line in tail.splitlines():
    if '"usage"' not in line:
        continue
    try:
        o = json.loads(line)
    except Exception:
        continue
    if o.get("type") != "assistant":
        continue
    u = (o.get("message") or {}).get("usage") or {}
    c = (u.get("input_tokens", 0) or 0) \
        + (u.get("cache_read_input_tokens", 0) or 0) \
        + (u.get("cache_creation_input_tokens", 0) or 0)
    if c > 0:
        ctx = c
        model = (o.get("message") or {}).get("model") or model
        agent_name = o.get("agentName")

# agentName があればワーカー/チームメイトのセッション＝リーダーではないので無言
if agent_name:
    sys.exit(0)

if ctx < warn_at or not re.search(model_re, model, re.I):
    sys.exit(0)

# 再警告制御: 前回警告時のコンテキストから step 以上増えるまで沈黙
os.makedirs(state_dir, exist_ok=True)
state_file = os.path.join(state_dir, sid)
last = 0
try:
    with open(state_file) as f:
        last = int(f.read().strip() or 0)
except Exception:
    pass
if last and ctx < last + step:
    sys.exit(0)
with open(state_file, "w") as f:
    f.write(str(ctx))

# ターン数（参考表示・grep は高速）
try:
    turns = subprocess.run(
        ["grep", "-c", '"type":"assistant"', tp],
        capture_output=True, text=True, timeout=3,
    ).stdout.strip() or "?"
except Exception:
    turns = "?"

print(
    f"⚠️【セッション肥大化警告】現在のコンテキスト推定 ~{ctx//1000}k トークン"
    f"（しきい値 {warn_at//1000}k 超・model={model}・assistant応答 {turns} 回）。"
    "cache読み消費はターン数×コンテキスト長に比例して膨らむ（Fable週次枠の主消費源・実測 2026-08-10）。"
    "今のタスクの区切りが来たら、ユーザーに『新セッションへの分割』または『/compact』を明示的に提案すること。"
    "作業の中断はしない。この警告への言及は提案時のみでよい。"
)
PYEOF
exit 0
