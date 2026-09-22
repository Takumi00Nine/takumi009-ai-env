#!/bin/bash
# UserPromptSubmit hook: 📣 通知取次 v1（code27-call）の未応答の呼び出しを全消去する。
#
# 本人が Claude Code に入力した＝応答した、とみなし、CODE27 での繰り返し発話を止める。
# ツール本体（~/work/navi-orchestrator/code27-call）が無ければ何もしない。常に終了 0（入力を止めない）。
# stdin は読まず、stdout にも何も出さない。秘密は扱わない。
#
# 環境変数（省略可・テスト用）: CODE27_CALL_BIN … 呼ぶ実行ファイル（既定 $HOME/work/navi-orchestrator/code27-call/bin/code27-call-clear）

BIN="${CODE27_CALL_BIN:-$HOME/work/navi-orchestrator/code27-call/bin/code27-call-clear}"
[ -x "$BIN" ] || exit 0
"$BIN" </dev/null >/dev/null 2>&1 || true
exit 0
