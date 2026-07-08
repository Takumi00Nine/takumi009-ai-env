---
date: 2026-06-22
updated: 2026-07-08
tags: [preference, blog, note, canvas, workflow]
project: blog-platform
related:
  - "[[Projects/blog-platform]]"
  - "[[Knowledge/obsidian-canvas-to-note]]"
  - "[[Preferences/coding-delegation]]"
---

# note記事を Canvas 経由で作るワークフロー

note 記事を書くとき、いきなり本文を書かず **JSON Canvas で構成を組んでから下書き化**する。

## 3ステップ（この順で進める）
1. **マインドマップ Canvas を作る**（発想を広げる）。中心テーマ → 枝(章候補) → サブノード(要点)、edge で接続。素材は外部脳の知見ノートを `file` ノードで参照。
2. **章構成 Canvas に直す**（記事の流れにする）。枝＝章候補を「読む順」に並べ替え・束ね、各章に**狙い(1行)**を添える。導入と結論で挟む。note は章を欲張らない（5〜6ブロック目安）。
3. **Markdown 下書きにする**。確定した章構成 Canvas を設計図に note 下書き `.md` を生成 → 以降は既存の執筆ワークフロー（[[Projects/blog-platform]]：drafts → `save_draft` → 公開 → published/移動）へ。

## 進め方の決め事
- **マインドマップと章構成は別ファイルで残す**（`<slug>-mindmap.canvas` と `<slug>-outline.canvas`）。発想用と設計図用を両方残すと次回の編集がしやすい。
- **Claude × Codex の合議で作ってよい**：Claude が論点設定、Codex は対案・レビュー参加のみ（レビュアー専任＝[[Decisions/2026-07-05-codex-reviewer-only]]）。**Vault への書込は Claude**。※`Blogs/` への Codex 書込許可（[[Decisions/2026-06-28-codex-blogs-explorations-write]]）は権限として残るが、実装委任をしない現行運用では使わない。
- **「下書きは見ない」で作る指定があり得る**：既存下書きに引っ張られずテーマから起こしたい時は、Codexにも下書きパスを読ませない指示を明示する。
- 使う skill は **`kepano/obsidian-skills` の `json-canvas`**（導入済み。詳細 [[Knowledge/obsidian-canvas-to-note]]）。

## 実装上の注意（ハマりどころ）
- **`.canvas` の text に straight double quote (`"`) を入れない**（JSONが壊れる）。強調は `「」` を使う。改行は `\n`。
- 作成後は必ず検証：JSON妥当・node/edgeのID重複なし・dangling edgeなし・`file` 参照先が実在するか（`jq` でチェック）。
- ノードIDは16桁hex。`file` パスは Vault ルートからの相対。

**Why:** いきなり本文だと構成がぶれる。Canvas で「広げる→流れに直す→書く」と段階を踏むと、切り口が固まり手戻りが減る。設計図(Canvas)が残るので次回の改稿も速い。
**How to apply:** note記事の依頼が来たら、まずマインドマップCanvas→章構成Canvas→md下書き の順で進める。各Canvasは別ファイルで残し、合議を使ってよいが書込はClaude。
