---
date: 2026-06-28
updated: 2026-07-21
tags: [preference, tools, workflow, scripts]
project: meta
related:
  - "[[Preferences/coding-delegation]]"
aliases:
  - "~/work/tools集約"
---

# ツール格納ルール

汎用スクリプト・ユーティリティツールは `~/work/tools/` に集約する。

## ルール（2026-07-21 本人確定・work 再編後）
**分類軸は「汎用か／プロジェクト固有か」の一つだけ**（公開・git 管理の有無は分類の垣根にしない＝どちらの場所でも git 化してよい）:
- **汎用ツール（複数プロジェクトで使う）**: `~/work/tools/<tool-name>/`（ツールごとにサブフォルダ・README付き・[[Knowledge/tools-inventory]] 登録）。例: pixel-finisher
- **プロジェクト固有のツール・成果物**: `~/work/projects/<project>/` 配下（プロジェクトの一部として同居）。例: op-loop-composer → projects/dot-animation/op/composer/。**ただし専用ツールの新設は原則しない**（2026-07-21 本人方針＝最初から「汎用エンジン（tools/）＋プロジェクト固有の設定・データ（projects/）」に分解して作る。[[Preferences/coding-delegation]]「共通化ファースト分解」の発展）
- **候補級（もしかしたら使えるかも）**: `~/work/tools/worker-scripts/<YYYY-MM-DD>/`（日付フォルダ・ワーカー終業時退避＝[[Preferences/coding-delegation]]。汎用に化けたら tools/ へ、特定プロジェクト専用と判明したらそのプロジェクトへ昇格）
- **tools/ 配下は自由に育ててよい（2026-07-21 本人方針）**: 既存の汎用ツールへの機能追加（プロジェクトのニーズ由来の機能も含む）を柔軟に**許可・推奨**する。専用スクリプトを新設するより、汎用ツール側にオプションとして取り込む（成功例＝pixel-finisher への `--key auto` 追加）。守るのは2点だけ: ①既存機能の後方互換（回帰テスト・既存成果物の再現一致で担保）②変更したら [[Knowledge/tools-inventory]] を更新。
- **例外**: AI 環境の一部として再現すべきツールは takumi009-ai-env（基本パッケージ）へ、メイン専用の個人ツールは私的パッチへ置く（判定則＝[[Preferences/coding-delegation]]「AI本体／部品」）。
- 再編の経緯＝[[Decisions/2026-07-21-work-projects-tools-restructure]]

## 適用
- 新しいツール・スクリプトを作るとき、使い捨てでなければ `~/work/tools/` 下にフォルダを切って配置する
- 一時的な検証用スクリプト（1回だけ使うもの）は scratchpad でよい
- 同じスクリプトを2箇所に置かない（正本を1つに決める。二重化すると「編集した方と実行される方が食い違う」事故が起きる）

**Why:** ツールが散在すると再利用時に探せない。定位置を決めて管理を集約する。
