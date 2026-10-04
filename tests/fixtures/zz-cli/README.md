# FX-10 雛形（偽 zz-cli 接続・設計 §10.3）— 常設スイートと締めの実走（tests/closing/）で共有

- `zz-cli`＝偽の実行体（repo の外＝PATH 上に置く）。`zz-cli <問い合わせ文>` で `$HOME/.zz-cli/hooks` の各行（**1 行 1 本の絶対パス**・`#` と空行は読まない）を stdin `{"query":<問い合わせ文>}` で順に起動し、stdout をそのまま出す。終了コード＝最後のフックのもの（登録が無ければ 3）。
- `connect/`＝AI Brain の zz-cli 接続フォルダの中身（`<AI Brain>/<接続>/zz-cli/` へ丸ごとコピーする）:
  - `recall-shim.sh`＝変換シム。stdin `{"query":q}` → `{"session_id":"s1","prompt":q}` にして想起の入口を起動。コピー時に `__RECALL_REL__` を「接続フォルダから想起の入口への相対パス」に置き換える（例＝`sed "s#__RECALL_REL__#../../executor/vault-recall.sh#"`）。
  - `register.tmpl`＝登録の雛形（`__SHIM__` を配置手順が埋める）。
  - `install.sh`＝配置手順。**引数なし**・`$HOME/.zz-cli/hooks` にシムの絶対パスを書くだけ（全部入りの組立は触らない）。
- 台帳に足す行（v1.2 束 C・実装計画 §2＝9 列。X-06＝ゲート①レビューで移動表の由来行の追加を外した＝
  v1.2 FR-20「v1.1 の後の新規部品は台帳の行だけでよい」と矛盾していたため）＝**ファイルごと 3 行**（フォルダ
  単位の 1 行にはしない＝フォルダは実行可能でなく `run` を持てない）:
  - `part<TAB>…/recall-shim.sh<TAB>ai-brain<TAB>connect<TAB>zz-cli<TAB>-<TAB><備考><TAB>-<TAB>-`
  - `part<TAB>…/register.tmpl<TAB>ai-brain<TAB>connect<TAB>zz-cli<TAB>-<TAB><備考><TAB>-<TAB>-`
  - `part<TAB>…/install.sh<TAB>ai-brain<TAB>connect<TAB>zz-cli<TAB>-<TAB><備考><TAB>-<TAB>run:$HOME/.zz-cli/`
  （9 列目「配置」＝`run:$HOME/.zz-cli/` は install.sh の行だけに持たせる＝AC-9 で全部入りの組立がこの行を
  拾って install.sh を自動で実行する）。移動表（`core/data/moves.tsv`）には行を足さない。式 A の除外は
  台帳ファイルと接続フォルダ全体（`ai-brain/connect/zz-cli/`）の 2 つ。
- 使用例＝`tests/test-decoupling.sh` の `mk_zz_connect`（常設・AC-2・AC-9）・`tests/closing/ac-suites.sh` の
  `cl_mk_fx10`・`ac_2`（締め）。所有＝test-writer B（直すときは B へ。本改訂＝test-writer A・v1.2 束 C 着手ゲート
  C4 の X-06 指示による＝tests/closing/ 側の `cl_mk_fx10` の同期は B への申し送り）。
