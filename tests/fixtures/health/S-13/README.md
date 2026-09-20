# S-13 — S-2 と同じ記録を次の予定時刻を跨いだ判定時刻で読む

- 種別: 書き手注入
- 期待: WARNING・items=2（失敗 X＋未起動・AI）
- 判定時刻 `now`: 2026-09-22T06:01:01Z
- plist＝月曜 06:00。`now`＝翌週火曜＝どの時刻帯でも月曜 06:00 を跨ぐ。
- 派生元＝新 S-2（`tests/test-maintenance.sh` H-16 `writer_S2_then_S9_clears`。派生の規則＝上記の既存記述を維持）・取り込み 2026-09-20（commit `816bd49`）
