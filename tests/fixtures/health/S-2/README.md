# S-2 — 単一の異常工程（失敗・理由 X・主体 AI）

- 種別: 書き手注入
- 期待: WARNING・items=1（失敗・AI・ack 該当なし）
- 判定時刻 `now`: 2026-09-15T06:01:01Z
- plist を同梱＝予定（月曜 06:00）を跨いでいないことを陽性で確かめる（未起動 0）。
- V-17 取り込み 2026-09-20（commit `816bd49`）・生成元＝`tests/test-maintenance.sh` H-16 `writer_S2_then_S9_clears`・時刻フィールドのみ B 規則へ正規化（impl-integrate-notes.md §1）
