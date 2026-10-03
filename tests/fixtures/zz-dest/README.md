# FX-11 ZZD 雛形（第 4 の届け先 zz-dest）— 常設スイートと締めの実走（tests/closing/）で共有

> 所有＝test-writer B（締め）。試験設計の共有雛形として test-writer A と使う（無ければ最小を作り報告に書く＝委任文の指示）。

- `connect/deliver.sh`＝zz-dest の送り手。送り手の契約（実装計画 §1＝`deliver.sh <種別> <区分|-> <題> <本文> [<音>]`）で
  呼ばれ、受けた知らせを 1 行（TAB 区切り＝種別・区分・題・本文・音）`calls.log` へ記録して常に exit 0（届けた）。
- 使い方＝FX-1 の worktree に `<Notify の接続>/zz-dest/` としてコピーし、台帳へ「全ての呼出を zz-dest にも届ける」
  対応の行を 1 行足す（要件 FX-11・移動表は変えない＝検証 1 巡目 V-02 の反映）。
- 使用例＝`tests/closing/ac-b.sh`（AC-3 ①②④）・`tests/test-notify.sh`（test-writer A・AC-3①②・AC-5③・FX-17・FX-24。
  `ZZ_DEST_LOG` を明示して記録先を指定して使う）・`tests/test-ledger.sh`（FR-20・移動表に行の無い新規部品を不合格にしない）。
