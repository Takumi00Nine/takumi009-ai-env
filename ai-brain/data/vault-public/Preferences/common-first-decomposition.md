---
date: 2026-08-08
updated: 2026-11-01
tags: [preference, delegation, tools, decomposition]
project: meta
related:
  - "[[Decisions/2026-11-01-rule-relaxation]]"
  - "[[Preferences/coding-delegation]]"
  - "[[Preferences/tools-folder]]"
  - "[[Knowledge/tools-inventory]]"
aliases:
  - "共通化ファースト分解"
  - "スクリプト退避ルール"
  - "Rule of two"
---

# 共通化ファースト分解（2026-07-21 本人発案・恒久原則）

> 2026-08-08 に [[Preferences/coding-delegation]] から正本を移設（起動注入の減量。運用上の位置づけ・工程フローは元ノート）。

最初はその案件に必要な形で作る。実際に同じ処理が2回目に現れたら、共通部分と個別の設定・データを分ける。将来の再利用だけを理由に、初回から汎用エンジンや先行担当を用意しない。

**Why:** 1回しか使わない処理の部品化を避け、実際の重複が分かってから共通化するため。
**How to apply:** 同じ処理の2回目で共通部分を切り出す。道具は生まれた案件に置き、2つ目の案件で使い始めたら `Tools/` へ移す（[[Preferences/file-placement]]）。

- **実装形態の序列**（省力化が効く順）: ①決定的処理→**AIゼロの常設CLI**（`~/Workspace/Tools/` に配置・[[Knowledge/tools-inventory]] 登録で次回以降の発見可能性を確保）②半定型AIタスク→エージェント定義（frontmatter に model/effort）/スキル ③多体並列の定型→保存ワークフロー（`~/.claude/workflows/`・常設CLIを前提に組む。本人オプトイン済み 2026-07-21・詳細と solo-agent テンプレート=[[Knowledge/claude-workflow-tool]]）。
- **共通部品の受入条件は機械的検証にする**（例: 承認済み成果物をバイト一致で再現）＝実装のブレを構造的に禁止。
- **終業時のスクリプト退避（2026-07-21 本人指示・明示ルール）**: ワーカーが作業中に書いたスクリプトは、タスク完了時に**必ず退避してから完了報告に一覧を含める**。素材フォルダや tmp への置き捨て禁止＝次のワーカーが再利用できない。退避先は2段階（本人指定の運用）:
  - **継続して使うもの** → 生まれた案件の中に用途コメント・README とともに置く。2つ目の案件で使い始めたら `~/Workspace/Tools/` へ移し、[[Knowledge/tools-inventory]] に登録する。
  - **もしかしたら使えるかも級** → **生まれた案件の `~/Workspace/Projects/<案件>/work/`**に置く（各ファイル冒頭に用途コメント）。
  - **配置の基準**：1つの案件で使うものはその案件内、2つ以上の案件で使うものは `Tools/`。環境全体を支える道具の例外は [[Preferences/file-placement]] に従う。公開・git 化の有無は配置の基準にしない。
  - リーダーは報告を見て昇格（候補級→汎用 tools/ or プロジェクト同居）・正式CLI化を判断する（昇格したら退避版は削除可）。
- 初出実例: 2026-07-21 `pixel-finisher`（OP の v2.1 仕上げを同一ワーカーが3回都度 PIL 実装→本人指摘で常設CLI化。生成工程と並行で別 implementer に発注し待ち時間ゼロ）。
