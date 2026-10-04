#!/bin/bash
# 送り手（CODE27）: deliver.sh <種別> <区分|-> <題> <本文> [<音>]
# 応答だけを受ける（台帳の「知らせ」列＝answer）。📣 通知取次（code27-call）の未応答の呼び出しを全消去する
# 入口を 1 回呼ぶ（本人が応答した＝繰り返し発話を止める）。題・本文は使わない。
# 終了コード＝0 届けた／2 取次が無い／1 失敗。秘密は扱わない。
#
# 環境変数（省略可・テスト用）: CODE27_CALL_BIN … 呼ぶ実行ファイル（既定は下の 1 か所）

BIN="${CODE27_CALL_BIN:-$HOME/work/navi-orchestrator/code27-call/bin/code27-call-clear}"
[ -x "$BIN" ] || exit 2
"$BIN" </dev/null >/dev/null 2>&1 && exit 0
exit 1
