# X-1b — 手動起動の busy-skip＝未起動に数えない（表示状態 skipped）

- 種別: 設計追加（V-2）
- 期待: OK・items=0・sources.maintenance.state=skipped
- 判定時刻 `now`: 2026-09-15T06:01:01Z
- 欠く入力: なし。
- 検査: bootstrap ヘッダが `maintenance=skipped(busy:lock・前回 <completed.run_id> の完了記録)`＝「前回」明示（W-3）。
- 初稿: 実装 B の手書き（設計 v1.2 §3.1／§3.3 の形・schema 2）。A の `test-maintenance.sh` 完成後に B が再生成して差し替える（V-17）。生成元ケース名: （未取り込み・手書き）
