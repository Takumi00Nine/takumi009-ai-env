---
date: 2026-06-21
updated: 2026-08-13
tags: [preference, meta, external-brain, routing]
project: external-brain
aliases:
  - "外部脳運用チートシート"
  - "public執筆の掟"
---
# 外部脳 運用チートシート（起動必読・ルーティング表）
詳細・実例＝[[Knowledge/external-brain-guide]]。public 公開＝リンク先が読めなくても単体でルールとして完結するよう書く。
## どのフォルダに何を書くか
- **Fragments/**＝未確定・副産物の入口（append-only・日次 `Fragments/YYYY-MM/YYYY-MM-DD.md`）。断片は応答前にその場で短く追記・確定したら昇格。
- **Knowledge/**＝技術知見・背景／**Decisions/**＝選んだ判断と理由（`YYYY-MM-DD-topic.md`）／**Projects/**＝進行状態と next_action／**Preferences/**＝運用ルール（⚠️public）／**Personal/**＝個人情報。**Blogs/**・**Explorations/**＝外部脳の対象外（人間向け）。6フォルダはAI向け＝トークン効率優先。
## public 執筆の掟（public＝Preferences/ のみ・他は private）
1. 個人情報・経緯・エピソードを書かない（理由・経緯は Decisions へ、個人の事実は Personal へ）。
2. ユーザーの呼び名を書かない。「ユーザー」「本人」等の中立表現を使う（ID「takumi009」は可）。
3. Personal 配下への wiki link・Personal ノート名を書かない（他フォルダへのリンクは可）。
4. ホーム配下の絶対パスを書かない（`~/` 表記＝Vault 全域の掟）。
- Preferences 編集セッションの締めに `~/work/takumi009-ai-env/scripts/export-public-vault.sh` を実行（commit 自動・push は別途明示）。
## SSOT の役割分担（ドリフト防止）
- **Preferences＝今どう動くか／Decisions＝なぜ／Knowledge＝背景。** 判断は Preferences と Decisions を**ペアで**書く。現行値（設定値・状態）は Projects のみ。
- 体制を変える Decision を書いたら影響語を grep して現在形ノート（Preferences/Projects/Knowledge）を同時修正し、grep 語と修正ファイルを Decision の「適用」欄に記録（該当ノートは**通し読み**）。
- 同じルールは SSOT 1つ＋他はリンクのみ。旧方針は `deprecated YYYY-MM-DD` で現行より下に隔離。
- **Projects の frontmatter**: `status:` は4値のみ＝`active`/`paused`/`completed`/`closed`。**状態が動いたら `next:`（15文字以内の次アクション）も更新**（cmux Next ペイン表示元。「Nextの N 番」解決＝`cmux-next-watch.sh --list`）。
## 書き方の鉄則
- 該当が出たら**その場で書く**。書き込みの**決定者**はリーダーの Claude のみ。**執筆は必ず `vault-scribe`（常駐チームメイト）へ委任**＝リーダーが内容を確定して渡し、scribe が掟に従い執筆（[[Decisions/2026-08-10-vault-scribe]]）。**リーダー直筆は禁止**＝旧例外「scribe 不在時・軽い1件は直筆可」は本人指示で撤廃（[[Decisions/2026-08-12-vault-scribe-mandatory]]・delegation-gate フックが deny・scribe 不在なら起動してから振る）。**scribe 専任の対象は AI向け6フォルダ（Fragments/Knowledge/Decisions/Projects/Preferences/Personal）に限定**＝人間向け領域（Blogs/・Explorations/ ほか6フォルダ以外すべて）はリーダー・ワーカー・スクリプトが直接書き込み可（[[Decisions/2026-08-13-vault-scribe-scope-ai-folders]]・旧例外「Codex のみ Blogs/・Explorations/ 直書き可」は人間向け領域全体の直書き可に一般化され不要に）。他ワーカーは AI向け6フォルダへの記録候補があれば「Vault記録候補:」で申告。
- 長くなったら分割（目安8,000字・Decisions は対象外）＝詳細を別ノートへ分離し相互リンク。
- フロントマター必須（date/tags/project）・本文編集で `updated` 更新。wiki link はフォルダ付き `[[Folder/note]]`・関連ノートは**相互に**リンク。
- aliases 必須（README 除く）＝想起フックの検索キー。実際に打ちそうな語1〜5個・汎用語禁止・迷ったら付けない。外部情報系は `review_by:`（任意）。
- Read/Write/Edit/Grep で直接操作（obsidian-mcp 不使用）。Vault 読み書きはユーザーへ明示報告（例外＝定常メンテ＝Fragments 昇格・棚卸し対処は自律・個別報告不要。本人へは実世界の事実・金銭・公開・破壊的操作のみ）。
## AI主導の想起（キーワード1本化）
- 検索仕様は**フック1つだけ**（aliases・ファイル名照合。ベクトル検索撤去済み・別ツール/別閾値/別モード禁止）。候補不足なら同じフックをクエリ言い換えで手動再実行（コマンド＝[[Knowledge/external-brain-guide]] §必読ノートの詳細）。工夫は「聞き方」のみ。
## 起動時ヘルス警告・綻びの扱い
- SessionStart 注入のヘルス行の ⚠️ は**最初の応答で報告し対処を提案**（黙って本題に入らない）。
- **綻びは読み時（気づいた時点）で直す**: 鮮度（`review_by` 超過・古い外部可変情報＝一次情報で再確認→`updated` 引き直し。内部の決定ノートは対象外）／リンク切れ（張り直す or 除去）／alias（欠落・汎用/短すぎ＝想起に効く語へ）。
- **撤回・白紙化バナー**: 失効ノート（Decisions 含む）は冒頭に「⚠️白紙化済み/撤回済み（日付＋出典）」バナー（本文は書き換えない・単体で失効が分かる）。**バナー付きノートを新文脈の材料に使わない**（再採用は本人の明示指示のみ）。
- **撤去済みシステムの退役**: システム・ツールを撤去したら、関連 Knowledge ノートを想起から退役させる＝aliases・review_by を除去し frontmatter `retired: true`＋冒頭に退役バナー（本文は温存・削除/移動しない）。判定は読み時・棚卸し時に個別（ルールの根拠ノートは対象外）。詳細＝[[Decisions/2026-08-10-round6-rulings]]。
- **停滞は本人の領域**: project の status は本人が棚卸しで判断＝**AI は勝手に書き換えない**（気づいたら一言添える）。最終防衛線はリーダーの読み時判断（棚卸しレポートは検出のみ）＝**読んだノートの綻びは読むたびに直す**。
