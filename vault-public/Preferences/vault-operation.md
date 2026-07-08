---
date: 2026-06-21
updated: 2026-07-08
tags: [preference, meta, external-brain, routing]
project: external-brain
related:
  - "[[Knowledge/external-brain-guide]]"
  - "[[Knowledge/mistakes]]"
---

# 外部脳 運用チートシート（起動必読・ルーティング表）

詳細・背景は [[Knowledge/external-brain-guide]]（§2 書込・§8 SSOT/メンテ）。

## どのフォルダに何を書くか
- **Fragments/** = 未確定・副産物の入口（append-only・日次）。確定で下記4フォルダへ昇格、記事の種は Blog へ（[[Preferences/fragments-workflow]]）。**即時capture**：作業・判断が一段落し応答前に、後で使える断片を `Fragments/YYYY-MM/YYYY-MM-DD.md` へ短く追記（瑣末な一問一答・作業途中は対象外）。
- **Explorations/** = AI整理のキャンバス・情報ダンプ（探索済み・未確定）。
- **Knowledge/** = 技術知見・バグ解決（原因と対策）・調査結果・背景。
- **Decisions/** = 複数案から選んだ判断（**なぜ A か**）。`YYYY-MM-DD-topic.md`。
- **Projects/** = 進行中の状態・next_action（frontmatter に status/updated）。
- **Preferences/** = 好み・作業スタイル・**今どう動くか**（運用ルール）。**⚠️public フォルダ＝下記の掟に従う**。
- **Personal/** = ユーザーの個人情報（プロフィール・経歴・好み・価値観・生活リズム・契約等）。
- Blogs/・Explorations/＝**人間向け**（読みやすさ優先）、他＝**AI向け**（トークン効率。未確定な種は Fragments へ）。

## public / private フォルダ区分（takumi009-ai-env）
- **public ＝ Preferences/ のみ**（takumi009-ai-env の public repo へ丸ごとエクスポートされ世界公開される）。**それ以外（Personal/Knowledge/Decisions/Projects/Fragments/Explorations/Blogs）＝ private**（public repo には空フォルダ＋README の骨格だけ配布）。
- **public フォルダ執筆の掟**（フォルダ単位で判定を省くための書き込み時規律）:
  1. **個人情報・経緯・エピソードを書かない**（ルールは「今どう動くか」だけに削ぐ。なぜ・経緯は Decisions へ、個人の事実は Personal へ）
  2. **ユーザーの呼び名（ハンドルネーム）を書かない**（「ユーザー」「本人」等の中立表現を使う。ID「takumi009」は可。NG 語の定義はエクスポートスクリプトの ngwords.txt が正本＝このノートには書かない）
  3. **Personal 配下への wiki link・Personal ノート名の記載を書かない**（ファイル名自体が私事のヒントになるため禁止。エクスポート時に機械検出＝fail-fast で止まる）。Knowledge/Decisions/Projects/Fragments/Explorations へのリンクは**許容**（public 側ではリンク切れになるだけ。エクスポート時に切れるリンク一覧がレポートされる）
  4. 絶対パス（`/Users/…`）を書かない（`~/` 表記にする）
- エクスポートは自動同期ではなく**明示実行**（スクリプト＋機械チェック通過時のみ。設計＝`~/work/takumi009-ai-env/docs/takumi009-ai-env-vault-split-design.md`）。普段の書き込み運用は従来どおり。
- **エクスポート運用ルール**: Preferences 配下を編集したセッションでは、作業の締めに `~/work/takumi009-ai-env/scripts/export-public-vault.sh` を実行して public スナップショットを同期する（commit まで自動・**push は別途明示**）。取りこぼしは `scripts/check-drift.sh` で検知できる。Vault 全体のバックアップは LaunchAgent（毎時）が自動実行。

## SSOT の役割分担（ドリフト防止）
- **Preferences＝今どう動くか／Decisions＝なぜ／Knowledge＝背景。** 判断が出たら Preferences と Decisions を**ペアで**書く。
- **波及チェック**：体制を変える Decision を書いたら影響語を grep（Preferences/Projects/Knowledge の現在形のみ。履歴は直さない）→参照側を同時修正→grep 語と修正ファイルを Decision の「適用」欄へ。
- 同じルールは SSOT 1つ＋他はリンクのみ。旧方針は `deprecated YYYY-MM-DD` で隔離。

## 書き方の鉄則
- 該当が出たら**その場で書く**（「後で書く」はしない）。
- **書き手はリーダーの Claude のみ**（[[Decisions/2026-06-14-vault-single-editor]]）。ワーカー/Codex は「Vault記録候補:」で申告→リーダー代筆。例外＝Codex のみ `Blogs/`・`Explorations/` 書込可（[[Decisions/2026-06-28-codex-blogs-explorations-write]]）。
- **フロントマター必須**（date/tags/project）。**編集時は `updated` も必ず更新**。wiki link は**フォルダ付き** `[[Folder/note]]`。
- **ファイル直接操作**（Read/Write/Edit/Grep）。**obsidian-mcp 不使用**（[[Knowledge/obsidian-mcp-write-hang]]）。
- **パスは Vault 全域で `~/` 表記**（ユーザー名はマシンごとに異なる前提のため、ホーム配下の絶対パスは書かない。例外＝`~` が展開されない値の記録（MCP の cwd 等）は「ホームの絶対パスを実行時に展開」等の書き方で名前を残さない）。
- Vault を読み書きしたら**ユーザーに明示報告**（サイレント禁止）。
