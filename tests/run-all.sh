#!/usr/bin/env bash
# 全スイート一括実行＝README の `for t in tests/test-*.sh; do bash "$t"; done` は最後のスイートが
# 成功すると全体が exit 0 で終わり途中の失敗が静かに消える（ゲート①レビュー C-1）ので、ここで
# tests/test-*.sh を名前順に全件続けて実行し、失敗を集約する。
#
# 出力はこの2形だけ（各スイート自身の本文はそのまま流す）:
#   <スイート名> exit=<終了コード>   … スイート1本ごとに1行
#   suites=<総数> green=<成功数> red=<失敗数>   … 最後に1行
# red が1以上なら exit 1。引数・環境変数は取らない。
#
# 実行方法: bash tests/run-all.sh

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

suites=0
green=0
red=0

for t in "$DIR"/test-*.sh; do
  [ -e "$t" ] || continue
  name="$(basename "$t")"
  bash "$t"
  rc=$?
  suites=$((suites + 1))
  if [ "$rc" -eq 0 ]; then
    green=$((green + 1))
  else
    red=$((red + 1))
  fi
  echo "$name exit=$rc"
done

echo "suites=$suites green=$green red=$red"
[ "$red" -eq 0 ]
