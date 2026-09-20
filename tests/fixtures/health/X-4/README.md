# X-4 — latest.json 無し × 週次の状態ごとの加算有無（⑥ の評価位置）

- 種別: 設計追加（V-6）
- 期待: completed(steps 空)→ phase1-inventory 1 件／absent・interrupted・broken・completed(steps に phase1-inventory あり)→ 加算なし
- 判定時刻 `now`: 2026-09-15T06:01:01Z
- 欠く入力: `latest.json`（意図的に置かない）。
- `last-run.json`＝completed(steps 空)。`variants/` に他の状態の last-run.json を置く（absent＝存在しないパスを渡す）。
- 初稿: 実装 B の手書き（設計 v1.2 §3.1／§3.3 の形・schema 2）。A の `test-maintenance.sh` 完成後に B が再生成して差し替える（V-17）。生成元ケース名: （未取り込み・手書き）
