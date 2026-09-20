# X-5 — 実行中（表示状態）＝前回の完了記録だけを「前回」と明示して見せる

- 種別: 設計追加（W-3・§14-6）
- 期待: WARNING・state=running・items=1（前回 completed の fail 1 件のみ）・未起動 0・中断 0・破損 0
- 判定時刻 `now`: 2026-09-15T06:01:01Z
- 欠く入力: なし（S-* と同じ 5 入力＋bootstrap 経由の 2 入力を全部持つ）。
- 検査: `sources.maintenance.state=running`・bootstrap ヘッダの `maintenance=running(開始 …・以下の週次メンテ項目は前回 <completed.run_id> の完了記録)`。
- 手書きのまま（生成元なし＝S-4 とは独立の fixture・リーダー裁定 2026-09-20）
