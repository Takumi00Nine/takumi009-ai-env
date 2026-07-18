---
date: 2026-06-21
updated: 2026-07-18
tags: [preference, meta, external-brain, routing]
project: external-brain
aliases:
  - "外部脳運用チートシート"
  - "public執筆の掟"
---

# 外部脳 運用チートシート（起動必読・ルーティング表）

詳細・背景・実例は [[Knowledge/external-brain-guide]]。本ノートは public 公開されるため、リンク先が読めなくても単体でルールとして完結するよう書く。

## どのフォルダに何を書くか
- **Fragments/**＝未確定・副産物の入口（append-only・日次 `Fragments/YYYY-MM/YYYY-MM-DD.md`）。作業・判断が一段落したら、後で使える断片を応答前にその場で短く追記し、確定したら下記フォルダへ昇格。
- **Knowledge/**＝技術知見・調査結果・背景／**Decisions/**＝複数案から選んだ判断とその理由（`YYYY-MM-DD-topic.md`）／**Projects/**＝進行中の状態と next_action／**Preferences/**＝今どう動くかの運用ルール（⚠️public）／**Personal/**＝ユーザーの個人情報。**Blogs/**・**Explorations/**＝**外部脳の対象外**（人間向け成果物。Obsidian で扱うため Vault に同居しているだけ＝[[Decisions/2026-07-15-blogs-explorations-out-of-external-brain]]）。読みやすさ優先で書き、外部脳6フォルダ（Fragments/Knowledge/Decisions/Projects/Preferences/Personal）はAI向け＝トークン効率優先。

## public 執筆の掟（public＝Preferences/ のみ。他フォルダはすべて private）
1. 個人情報・経緯・エピソードを書かない（ルールは「今どう動くか」だけに削ぐ。理由・経緯は Decisions へ、個人の事実は Personal へ）。
2. ユーザーの呼び名（ハンドルネーム）を書かない。「ユーザー」「本人」等の中立表現を使う（ID「takumi009」は可）。
3. Personal 配下への wiki link・Personal ノート名を書かない（ファイル名自体が私事のヒントになるため。他フォルダへのリンクは可＝public 側で切れるだけ）。
4. ホーム配下の絶対パスを書かない（`~/` 表記。これは Vault 全域の掟でもある。`~` が展開されない設定値は「実行時に展開」等の書き方で名前を残さない）。
- Preferences を編集したセッションの締めに `~/work/takumi009-ai-env/scripts/export-public-vault.sh` を実行して public スナップショットを同期する（commit まで自動・push は別途明示）。

## SSOT の役割分担（ドリフト防止）
- **Preferences＝今どう動くか／Decisions＝なぜ／Knowledge＝背景。** 判断が出たら Preferences と Decisions を**ペアで**書く。現行値（設定値・間隔・状態）は Projects のみに書き、Knowledge は背景＋「正本＝Projects」のポインタに留める。
- 体制を変える Decision を書いたら影響語を grep して現在形ノート（Preferences/Projects/Knowledge）を同時修正し、grep 語と修正ファイルを Decision の「適用」欄に記録する（波及チェック。履歴ノートは直さない）。
- 同じルールは SSOT 1つ＋他はリンクのみ。旧方針は `deprecated YYYY-MM-DD` で現行より下に隔離。

## 書き方の鉄則
- 該当が出たら**その場で書く**（「後で書く」はしない）。書き手はリーダーの Claude のみ＝ワーカー/Codex は「Vault記録候補:」で申告しリーダーが代筆（例外＝Codex のみ Blogs/・Explorations/ 直書き可）。
- **ノートが長くなりすぎたら分割を検討する（目安8,000字前後・厳密な字数管理はしない）**。分割は詳細を別ノートへ分離して相互リンク（アーカイブ分離方式）。理由は Read 時のトークン効率と読みやすさ（履歴ノート＝Decisions は分割対象外。2026-07-16 に厳密ルールから目安へ格下げ＝[[Decisions/2026-07-16-remove-vector-search-embedding-infra]] の派生）。本文の推奨スケルトン＝[[Preferences/note-templates]]（強制しない）。
- フロントマター必須（date/tags/project）。本文を編集したら `updated` も必ず更新。wiki link はフォルダ付き `[[Folder/note]]`。同一主題の関連ノート同士は**相互に**リンクを張る（片方向の放置は、片側だけ読んで関連知見に辿り着けない再発見漏れの元）。
- aliases 必須（Knowledge/Decisions/Projects/Preferences/**Personal**・README 除く）＝想起フックの検索キー（Personal は 2026-07-11 追加＝デバイス台帳等の台帳型ノートも想起対象にするため）。ユーザーが実際に打ちそうな語 1〜5 個・汎用語禁止・迷ったら付けない。外部情報系ノートは `review_by: YYYY-MM-DD`（任意）。
- ファイルは Read/Write/Edit/Grep で直接操作（obsidian-mcp は使わない）。Vault を読み書きしたらユーザーへ明示報告（サイレント禁止）。**例外＝定常メンテナンス（Fragments 週次昇格・棚卸し対処）は AI が自律実行し個別報告も不要**（監査はレポートファイル・git 履歴で担保。本人へ持ち込むのは実世界の事実・金銭・公開操作・破壊的操作のみ）。

## AI主導のハイブリッド想起（2026-07-12 本人決定・仕様一本化）
- 想起の検索仕様は**フック1つだけ**（キーワード照合＋ベクトル検索の並列マージ・閾値も設定も本番と同一。手動用の別ツール・別閾値・別モードは作らない＝本人決定）。
- 「Vault にありそう」な質問（〜なんだっけ・私の◯◯は・以前どうしたっけ 等）でフックの自動候補が不十分なら、リーダーは**同じフックを手動で実行**して追加検索する: `jq -n --arg p "<聞き方を変えたクエリ>" '{prompt:$p}' | bash ~/.claude/hooks/vault-recall.sh`（テスト・実験時は `VAULT_RECALL_LOG` を退避先へ）。手動時の工夫は「聞き方（クエリの文面）」のみ＝主題を短く言い直して再質問する。ツール側の設定は一切変えない（全文埋め込みは支配的話題に引っ張られ主題一語の発話は閾値を割る実測・意味を汲んだ言い直しはリーダーにしかできない。検証記録＝Fragments 2026-07-12）。

## ノートの綻びは読み時（気づいた時点）で直す（2026-07-18 本人決定）
リーダーが作業中にノートを読んで「綻び」に気づいたら、**その場で対応する**（別途の棚卸し相談を待たない）。鮮度も整合性も同じ「気づきベース」で扱う。
- **鮮度（内容が古い）**: `review_by` が過ぎている、または `date`/`updated` が数ヶ月前で内容が外部の可変情報（モデル・料金・外部ツール仕様など）なら、**鵜呑みにせず一次情報（Web 等）で再確認してから使う・答える**。再確認したら `updated`（＋必要なら `review_by`）を引き直す。内部の決定・原則ノートは対象外。
- **整合性の綻び（気づいたら直す）**: **リンク切れ**（解決しない `[[wiki link]]`＝張り直す or 除去）・**alias 系**（欠落・汎用/短すぎる alias＝想起に効く語へ直す）。
- **停滞は対象外＝本人の領域**: `status: active/in_progress/pending` の project が止まっているかどうかは**本人が棚卸しで判断する**（実作業の進行状態のため）。**AI は project の status を勝手に書き換えない**（気づいても本人に一言添えるまで・本人が「棚卸しする」と言ったら一緒に見る）。
- **なぜ読み時に一本化するか**: これらは棚卸し（vault_inventory）が今も検出するが、簡素化で「レポート→承認処理」ループを廃止したため、綻び（鮮度・リンク切れ・alias）の最終防衛線を**リーダーの読み時判断**に置く（自動サーフェシングは見送り＝[[Decisions/2026-07-16-nightly-batch-direct-write]]）。＝**読んだノートに綻びがあれば直す責任はリーダーが読むたびに負う**（一度も読まれないノートは放置されるが、読まれない＝重要度が低いとみなす受容）。
