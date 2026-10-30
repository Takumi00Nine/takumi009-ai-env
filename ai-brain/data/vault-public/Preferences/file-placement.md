---
date: 2026-06-14
updated: 2026-10-31
tags: [preference, files, placement]
project: meta
related:
  - "[[Knowledge/codex-mcp]]"
  - "[[Projects/takumi009-ai-env]]"
aliases:
  - "成果物の置き場所"
  - "~/Workspace配下"
  - "作業フォルダの決まり"
---

# 作業フォルダと成果物の置き場所ルール

- 作業はすべて `~/Workspace` の下で行う。直下は `Projects` と `Tools` だけにする。Claude（cct）・Codex とも `~/Workspace` で起動する。
- 案件は「目的があり、終わる取り組み」。`Projects/<案件ノート名>/` に1つのフォルダを作る。中は `docs`（現行版だけ）・`work`・`output`。
- 成果物は、生まれた案件の `output` に置き、完成しても動かさない。案件の状態は案件ノート（Vault の Projects）で見分ける。
- プログラムは `output/<名前>/` に一式で置く。git 保管庫なら、そこが保管庫のいちばん上になる。
- 道具は、最初は生まれた案件の中に置く。2つ目の案件で使い始めたら `Tools/<名前>/` へ移す。環境全体を支える道具（takumi009-ai-env・dotfiles など）は、最初から `Tools` に置く。詳細＝[[Preferences/tools-folder]]。
- 作業途中のもの（作業役への依頼文と返事、試作、調べた結果）は `/tmp`（scratchpad を含む）に置かず、案件の `work` に置く。
- 新しい案件は、最初からこの形で作る。
- **例外：ブログ（note）記事 → Obsidian Vault の `Blogs/`**。同期・検索・リンクで管理したいため Vault 内に置く。**書きかけ＝`Blogs/drafts/`／公開済み＝`Blogs/published/`**（公開後にリーダーが記事md＋見出し画像をdrafts→publishedへ移動）。Vault の既存4フォルダ（Knowledge/Decisions/Preferences/Projects＝リーダーが編集する知識）とは別物の**共作コンテンツ**で、ユーザーも編集する。**外部脳（AI記憶）の対象外**（Vault 同居は Obsidian で扱うため＝[[Decisions/2026-07-15-blogs-explorations-out-of-external-brain]]）。**資料化はユーザー（人間）向けの形式で作る**（眺めやすさ優先。方向性 [[Preferences/vault-operation]]）。Blog には**完成記事のみ**置き、AI向けの未確定な「ブログの種」は [[Preferences/fragments-workflow|Fragments]] に分離する。秘密情報は置かない（note認証 state file は Vault 外 `~/.claude/note-post-mcp/` のまま）。詳細フロー [[Projects/blog-platform]]。

**Why:** 置き場を1か所の決まった形にそろえ、Claude と Codex のどちらが作業しても、どこに何があるか（現行の文書・途中のもの・成果物）を迷わないようにするため（2026-10-30 本人裁定・共通環境の一本化）。

**How to apply:** 新しい案件を始めるときは、まず `~/Workspace/Projects/<案件ノート名>/` に docs・work・output を作る。旧 ~/work・~/Claude・~/Codex は存在しない。
