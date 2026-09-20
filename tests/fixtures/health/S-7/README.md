# S-7 — S-2 に申告を加えた後、次の本番実行が再失敗

- 種別: 書き手注入
- 期待: WARNING・items=1・ack=申告後に再失敗（refailed）
- 判定時刻 `now`: 2026-09-15T09:01:01Z

- V-17 取り込み 2026-09-20（commit `816bd49`）・生成元＝`tests/test-maintenance.sh` H-17 `writer_ack_kept_on_refail`・時刻フィールドのみ B 規則へ正規化（impl-integrate-notes.md §1）
