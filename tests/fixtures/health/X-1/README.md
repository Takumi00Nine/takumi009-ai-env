# X-1 — 定期起動の busy-skip＝当該予定の実行なし（未起動 (B)）

- 種別: 設計追加（V-2）
- 期待: WARNING・items=1（未起動・AI）・state=skipped
- 判定時刻 `now`: 2026-09-15T06:01:01Z
- 欠く入力: なし。
- 検査: `run.status=skipped`・`trigger=scheduled`・前回 completed は OK → 未起動 1 件だけ。
- 初稿: 実装 B の手書き（設計 v1.2 §3.1／§3.3 の形・schema 2）。A の `test-maintenance.sh` 完成後に B が再生成して差し替える（V-17）。生成元ケース名: （未取り込み・手書き）
