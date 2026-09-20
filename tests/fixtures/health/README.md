# tests/fixtures/health — 外部脳ヘルス判定機の fixture（要件 v1.3.2 §4 S-1〜S-23＋設計 v1.2 §10.2 X-1〜X-5）

所有＝実装 B（設計 §10.1・V-17）。判定機 `claude/hooks/lib/health_judge.py` の入力 4 本＋判定時刻を
1 ディレクトリに置く。`tests/test-health-judge.sh`（判定機 1 本で 23 本を閉じる）・
`tests/test-bootstrap-vault.sh`・`tests/test-cmux-next-model.sh`（判定機の写しであることを検査）が読む。

## 構成規則（設計 §10.1）

| ファイル | 必須 | 用途 |
|---|---|---|
| `last-run.json` | 必須（不在を検査する S-14 だけ置かない。X-3 は `{` だけ） | 判定機の入力（週次メンテ・schema 2＝設計 §3.1） |
| `latest.json` | 必須（X-4 だけ意図的に欠く） | 判定機の入力（棚卸し・`items` つき＝設計 §3.5） |
| `observation.json` | 必須 | 判定機の入力（読込・想起の観測記録）。bootstrap 経由の検査では期待値 |
| `vault-recall.tsv` | 必須（空可） | 判定機の入力（疑い判定）・bootstrap の観測材料 |
| `vault-reads.tsv` | bootstrap 経由で必須 | 観測材料（`reads_rows`） |
| `observation-prev.json` | bootstrap 経由で必須 | 「前セッション」の解決（最後に観測記録を書いたセッション） |
| `now` | 必須（1 行・RFC3339 UTC） | `--now`／`HEALTH_JUDGE_NOW` |
| `plist` | 任意（S-2・S-13・S-14・S-21・S-23） | `--plist`／`MAINTENANCE_PLIST_FILE`／`CMUX_NEXT_MAINT_PLIST` |
| `vault/` | 読込の fixture（S-15・S-16）だけ | 「本来存在するはず」の必読集合と欠落。**無い fixture は** bootstrap 経由の検査で共有の完全な Vault を使う。S-18 は `observation.json` の `load.vault_root_readable=false` を印に存在しないパスを Vault にする |
| `README.md` | 必須 | 各 fixture の意図・期待値・生成元ケース名 |

- 判定時刻の既定＝`run.started_at` + 60 秒（直近の予定時刻を過ぎていない時刻）。基準日を**火曜**にしてあるので、
  どの時刻帯（`--tz` 省略＝OS ローカル）で判定しても月曜 06:00 の予定を跨がない。予定超過の fixture（S-13・S-14・S-21・S-23）は
  `now`＝翌週火曜＝どの時刻帯でも月曜 06:00 を跨ぐ。
- 書き手注入 fixture（S-2・S-3・S-4・S-6・S-7・S-9・S-10・S-13・S-17・S-22）の初稿は実装 B の手書き。
  実装 A の `tests/test-maintenance.sh` 完成後に B が再生成して差し替える（各 README に生成元ケース名と取り込み日を記す）。
- X-n（設計追加ケース）は要件 fixture の総数 23 に数えない。全件走査のテスト（`truth_table_23`・
  `all_fixtures_one_b_row_three_values`・`stage_unique_and_equal_to_dock`）は `S-*` だけを対象にする。
  X-n は検査対象の入力を意図的に欠いてよい（X-3・X-4）。欠いた入力と検査内容は各 README に 1 行ずつ。

## 段階の期待値（AC-11＝OK 5／WARNING 14／ERROR 4）

- OK: S-1・S-6・S-9・S-14・S-23
- WARNING: S-2・S-3・S-4・S-5・S-7・S-8・S-10・S-11・S-12・S-13・S-17・S-20・S-21・S-22
- ERROR: S-15・S-16・S-18・S-19
