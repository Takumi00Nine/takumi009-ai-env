# S-10 — S-2（理由 X）の後、別理由 Y で再失敗

- 種別: 書き手注入
- 期待: WARNING・items=1・理由 Y のみ（X が残らない）
- 判定時刻 `now`: 2026-09-15T09:01:01Z

- V-17 取り込み 2026-09-20（commit `816bd49`）・生成元＝`tests/test-maintenance.sh` H-17 `S-10`（`writer_ack_kept_on_refail` ブロック内・別理由 Y での再失敗の続き）・時刻フィールドのみ B 規則へ正規化（impl-integrate-notes.md §1）
