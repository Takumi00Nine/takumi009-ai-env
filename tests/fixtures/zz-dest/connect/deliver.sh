#!/bin/bash
# 第 4 の届け先 zz-dest の送り手（要件 v1.2 FX-11 ZZD）＝受けた知らせを一時ファイルへ 1 行ずつ記録するだけ。
# 呼び方＝送り手の契約（実装計画 §1）＝deliver.sh <種別> <区分|-> <題> <本文> [<音>]。常に届けた（exit 0）。
# 記録先＝ZZ_DEST_LOG（既定＝このファイルの親の親の calls.log）。
log="${ZZ_DEST_LOG:-$(cd "$(dirname "$0")/.." && pwd)/calls.log}"
printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-}" >> "$log"
exit 0
