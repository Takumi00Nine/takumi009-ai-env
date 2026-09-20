# S-4 — 中断（開始の記録のみ・完了記録なし）

- 種別: 書き手注入
- 期待: WARNING・items=1（中断・AI）。前回の完了記録（fail 1 件）は表示しない
- 判定時刻 `now`: 2026-09-15T08:00:01Z
- `now` ＝ `run.started_at` + `stale_after_seconds`（7200 秒）。X-5 と同じ記録で `now` だけが違う対。
- V-17 取り込み 2026-09-20（commit `816bd49`）・生成元＝`tests/test-maintenance.sh` H-8 `writer_interrupted_S4_run_only`・時刻フィールドのみ B 規則へ正規化（impl-integrate-notes.md §1）
