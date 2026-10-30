---
date: 2026-06-28
updated: 2026-10-30
tags: [preference, tools, workflow, scripts]
project: meta
related:
  - "[[Preferences/coding-delegation]]"
aliases:
  - "~/Workspace/Tools集約"
---

# ツール格納ルール

汎用スクリプト・ユーティリティツールは `~/Workspace/Tools/` に集約する。

## ルール（2026-10-30 改定・共通環境の一本化）
- **汎用ツール（2つ以上の案件で使う）**：`~/Workspace/Tools/<tool-name>/`（ツールごとにフォルダ・README付き・[[Knowledge/tools-inventory]] 登録）。例: pixel-finisher
- **案件固有のツール・成果物**：その案件の `~/Workspace/Projects/<project>/output/` 配下。道具は最初は生まれた案件の中に置き、2つ目の案件で使い始めたら `Tools/<名前>/` へ移す。専用ツールの新設は原則しない（2026-07-21 本人方針＝最初から「汎用エンジン（Tools）＋案件固有の設定・データ（Projects）」に分解して作る。[[Preferences/coding-delegation]]「共通化ファースト分解」の発展）
- **候補級（もしかしたら使えるかも）**：生まれた案件の `work` に置く。汎用に化けたら Tools へ移す。
- **Tools/ 配下は自由に育ててよい（2026-07-21 本人方針）**: 既存の汎用ツールへの機能追加（プロジェクトのニーズ由来の機能も含む）を柔軟に**許可・推奨**する。専用スクリプトを新設するより、汎用ツール側にオプションとして取り込む（成功例＝pixel-finisher への `--key auto` 追加）。守るのは2点だけ: ①既存機能の後方互換（回帰テスト・既存成果物の再現一致で担保）②変更したら [[Knowledge/tools-inventory]] を更新。
- **例外**: AI 環境の一部として再現すべきツールは takumi009-ai-env（基本パッケージ）へ、メイン専用の個人ツールは私的パッチへ置く（判定則＝[[Preferences/coding-delegation]]「AI本体／部品」）。
- **例外**: cmux の Dock 常駐（Project／Task 枠）は ai-env（供給側）と dotfiles（描画側）が配る構成部品であり `~/Workspace/Tools/` 集約の対象外（2026-09-15 本人裁定）。
- 再編の経緯＝[[Decisions/2026-07-21-work-projects-tools-restructure]] → 2026-10-30 に ~/Workspace へ一本化（[[Preferences/file-placement]]）

## 適用
- 新しいツール・スクリプトを作るとき、使い捨てでなければ `~/Workspace/Tools/` 下にフォルダを切って配置する
- 一時的な検証用スクリプト（1回だけ使うもの）は、その案件の `work` に置く（/tmp・scratchpad には置かない）
- 同じスクリプトを2箇所に置かない（正本を1つに決める。二重化すると「編集した方と実行される方が食い違う」事故が起きる）

**Why:** ツールが散在すると再利用時に探せない。定位置を決めて管理を集約する。
