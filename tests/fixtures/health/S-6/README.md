# S-6 — S-2 に申告を加えた後、次の本番実行（手動）が完全正常終了

- 種別: 書き手注入
- 期待: OK・items=0・ack が消えている
- 判定時刻 `now`: 2026-09-15T09:01:01Z

- V-17 取り込み 2026-09-20（commit `816bd49`）・生成元＝`tests/test-maintenance.sh` H-17 `writer_ack_cleared_on_fully_ok`・時刻フィールドのみ B 規則へ正規化（impl-integrate-notes.md §1）
