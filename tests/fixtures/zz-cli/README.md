# FX-10 雛形（偽 zz-cli 接続・設計 §10.3）— 常設スイートと締めの実走（tests/closing/）で共有

- `zz-cli`＝偽の実行体（repo の外＝PATH 上に置く）。`zz-cli <問い合わせ文>` で `$HOME/.zz-cli/hooks` の各行（**1 行 1 本の絶対パス**・`#` と空行は読まない）を stdin `{"query":<問い合わせ文>}` で順に起動し、stdout をそのまま出す。終了コード＝最後のフックのもの（登録が無ければ 3）。
- `connect/`＝AI Brain の zz-cli 接続フォルダの中身（`<AI Brain>/<接続>/zz-cli/` へ丸ごとコピーする）:
  - `recall-shim.sh`＝変換シム。stdin `{"query":q}` → `{"session_id":"s1","prompt":q}` にして想起の入口を起動。コピー時に `__RECALL_REL__` を「接続フォルダから想起の入口への相対パス」に置き換える（例＝`sed "s#__RECALL_REL__#../../executor/vault-recall.sh#"`）。
  - `register.tmpl`＝登録の雛形（`__SHIM__` を配置手順が埋める）。
  - `install.sh`＝配置手順。**引数なし**・`$HOME/.zz-cli/hooks` にシムの絶対パスを書くだけ（全部入りの組立は触らない）。
- 台帳に足す行（実装計画 §3 の列）＝`part<TAB><接続フォルダ>/<TAB>ai-brain<TAB>connect<TAB>zz-cli<TAB>-<TAB><備考>`。移動表（`core/data/moves.tsv`）にも由来の行＝`-<TAB><接続フォルダ>/<TAB>新規<TAB>-`（FR-13）。式 A の除外は台帳と移動表の 2 ファイル。
- 使用例＝`tests/closing/ac-suites.sh` の `cl_mk_fx10`・`ac_2`。所有＝test-writer B（直すときは B へ）。
