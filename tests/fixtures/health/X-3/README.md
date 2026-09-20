# X-3 — last-run.json が JSON として解析不能（`{` だけ）＝破損であって不在ではない

- 種別: 設計追加（V-21）
- 期待: WARNING・items=1（破損・AI）・state=broken（absent でない）
- 判定時刻 `now`: 2026-09-15T06:01:01Z
- 欠く入力: `last-run.json` の中身（意図的に `{` だけ）。
- 初稿: 実装 B の手書き（設計 v1.2 §3.1／§3.3 の形・schema 2）。A の `test-maintenance.sh` 完成後に B が再生成して差し替える（V-17）。生成元ケース名: （未取り込み・手書き）
