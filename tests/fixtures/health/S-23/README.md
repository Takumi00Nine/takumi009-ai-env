# S-23 — 状態記録が不在＝ファイルはあるが実行実績のキーが無い（判定時刻は予定超過）

- 種別: 読み手側
- 期待: OK・items=0
- 判定時刻 `now`: 2026-09-22T06:01:01Z
- `last-run.json`＝`fragments_*` だけ（run／completed／started_at／last_success_at の 4 キーすべて無し）。
- 初稿: 実装 B の手書き（設計 v1.2 §3.1／§3.3 の形・schema 2）。A の `test-maintenance.sh` 完成後に B が再生成して差し替える（V-17）。生成元ケース名: （未取り込み・手書き）
