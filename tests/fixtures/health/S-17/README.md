# S-17 — 09-14 型＝子の失敗を警告として継続し完走したが成功時刻は進まない

- 種別: 書き手注入
- 期待: WARNING・items=1・result=失敗（警告ではない）・子の失敗理由が逐語で読める・AI
- 判定時刻 `now`: 2026-09-15T06:01:01Z
- 旧欄 `last_result` は `warn`（実行体は警告として継続）だが `steps[].result` は `fail`＝読み手は steps を見る。
- V-17 取り込み 2026-09-20（commit `816bd49`）・生成元＝`tests/test-maintenance.sh` H-13 `S17_child_failure_is_fail`（同ブロック内 `writer_scan_error_count_is_fail`）・時刻フィールドのみ B 規則へ正規化（impl-integrate-notes.md §1）
