# S-22 — 単一の異常工程で、主体を判定できない（actor が未知値）

- 種別: 書き手注入
- 期待: WARNING・items=1・actor=本人
- 判定時刻 `now`: 2026-09-15T06:01:01Z
- 書き手の `actor` に未知値 `unknown-actor` を置く→読み手が `本人` に正規化（§3.4）。
- 派生元＝新 S-2（`tests/test-maintenance.sh` H-16 `writer_S2_then_S9_clears`。派生の規則＝上記の既存記述を維持）・取り込み 2026-09-20（commit `816bd49`）
