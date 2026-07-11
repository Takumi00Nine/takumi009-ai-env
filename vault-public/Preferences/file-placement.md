---
date: 2026-06-14
updated: 2026-07-10
tags: [preference, files, placement]
project: meta
related:
  - "[[Knowledge/codex-mcp]]"
aliases:
  - "成果物の置き場所"
  - "~/work配下"
---

# 成果物の置き場所ルール

ファイルの配置は完成度で分ける：

- **最終的な成果物 → `~/work/` 配下**（ホームフォルダ直下の `work`）。
- **途中段階・作業中のもの → `~/Claude/` 配下**でOK。
- **例外：ブログ（note）記事 → Obsidian Vault の `Blogs/`**。同期・検索・リンクで管理したいため Vault 内に置く。**書きかけ＝`Blogs/drafts/`／公開済み＝`Blogs/published/`**（公開後に Claude が記事md＋見出し画像をdrafts→publishedへ移動）。Vault の既存4フォルダ（Knowledge/Decisions/Preferences/Projects＝Claude単独編集の知識）とは別物の**共作コンテンツ**で、ユーザーも編集する。**資料化はユーザー（人間）向けの形式で作る**（眺めやすさ優先。方向性 [[Preferences/vault-operation]]）。Blog には**完成記事のみ**置き、AI向けの未確定な「ブログの種」は [[Preferences/fragments-workflow|Fragments]] に分離する。秘密情報は置かない（note認証 state file は Vault 外 `~/.claude/note-post-mcp/` のまま）。詳細フロー [[Projects/blog-platform]]。

**Why:** 完成した成果物と作業中ドラフトを置き場で分離し、どれが「確定版」か一目で分かるようにするため。`~/Claude` は作業領域、`~/work` は完成品の置き場、という役割分担。

**How to apply:** 作業中・検討中のファイルは `~/Claude` 配下に作ってよい。完成して確定したら `~/work` 配下へ置く（または移動する）。なお Codex の作業フォルダは `~/Codex`（[[Knowledge/codex-mcp]]）。
