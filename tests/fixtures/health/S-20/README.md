# S-20 — 想起＝直接観測なし・現行の線（7 日）を超える期間の記録なし（疑い）

- 種別: 読み手側
- 期待: WARNING・items=1（想起・AI）
- 判定時刻 `now`: 2026-09-15T06:01:01Z
- 最終有効行 2026-08-30 06:10 → `now` から 15 日（切り捨て）＞7 日。
- `observation.json.recall_prev`＝直接観測なしの型（`session_id: null`・`reads_rows: 0`・`recall_valid_rows: 0`・`injected: null`）＝要件 S-20 の字義「直接観測の記録が無い」を陽性で表す（検証 B-3）。`observation-prev.json.session_id` も `null`（bootstrap 経由でも「前セッション」を特定できない＝reads_rows/recall_valid_rows とも 0 になる）にして bootstrap 経由の検査（AC-12）とも整合させた。`vault-recall.tsv`（sess-prev-0001 の行）は疑い判定の最終有効行の材料としてそのまま残す（sid に依存せず全体の末尾行を見るため 15 日超の判定は不変）。期待値（WARNING・`recall_stale` 1 件）は不変。
- 初稿: 実装 B の手書き（設計 v1.2 §3.1／§3.3 の形・schema 2）。A の `test-maintenance.sh` 完成後に B が再生成して差し替える（V-17）。生成元ケース名: （未取り込み・手書き）
