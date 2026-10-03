#!/bin/bash
# 送り手（cmux）: deliver.sh <種別> <区分|-> <題> <本文> [<音>]
# `cmux notify --title <題> --body <本文>` を 1 回発行する（CODE27 の発話は cmux 設定の連鎖が受け持つ）。
# 終了コード＝0 届けた／2 cmux が無い／1 失敗。音は使わない。

command -v cmux >/dev/null 2>&1 || exit 2
cmux notify --title "${3:-}" --body "${4:-}" && exit 0
exit 1
