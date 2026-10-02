---
date: 2026-06-21
updated: 2026-09-23
tags: [preference, meta, external-brain, routing]
project: external-brain
aliases:
  - "外部脳運用チートシート"
  - "public執筆の掟"
---
# 外部脳 運用チートシート（起動必読・ルーティング表）
詳細・実例＝[[Knowledge/external-brain-guide]]。public 公開＝リンク先が読めなくても単体でルールとして完結するよう書く。
## どのフォルダに何を書くか
- **Fragments/**＝未確定・副産物の入口（append-only・日次 `Fragments/YYYY-MM/YYYY-MM-DD.md`）。断片は応答前にその場で短く追記・確定したら昇格（締め＝[[Preferences/fragments-workflow]] §4）。
- **Knowledge/**＝技術知見・背景／**Decisions/**＝選んだ判断と理由（`YYYY-MM-DD-topic.md`）／**Projects/**＝進行状態と next_action／**Preferences/**＝運用ルール（⚠️public）／**Personal/**＝個人情報。**Blogs/**・**Explorations/**＝外部脳の対象外（人間向け）。6フォルダはAI向け＝トークン効率優先。
## public 執筆の掟（public＝Preferences/ のみ・他は private）
1. 個人情報・経緯・エピソードを書かない（理由・経緯は Decisions へ、個人の事実は Personal へ）。
2. ユーザーの呼び名を書かない。「ユーザー」「本人」等の中立表現を使う（ID「takumi009」は可）。
3. Personal 配下への wiki link・Personal ノート名を書かない（他フォルダへのリンクは可）。
4. ホーム配下の絶対パスを書かない（`~/` 表記＝Vault 全域の掟）。
- Preferences 編集セッションの締めに `~/work/takumi009-ai-env/scripts/export-public-vault.sh` を実行（commit 自動・push は別途明示）。⚠️ 編集も export・commit もメイン機だけ（[[Preferences/core-workflow]] §5）。
## SSOT の役割分担（ドリフト防止）
- **Preferences＝今どう動くか／Decisions＝なぜ／Knowledge＝背景。** 判断は Preferences と Decisions を**ペアで**書く。現行値（設定値・状態）は Projects のみ。
- 体制を変える Decision を書いたら影響語を grep して現在形ノート（Preferences/Projects/Knowledge）を**通し読み**して同時修正し、grep 語と修正ファイルを Decision の「適用」欄に記録。
- 同じルールは SSOT 1つ＋他はリンクのみ。旧方針は `deprecated YYYY-MM-DD` で現行より下に隔離。
- **部品追加の掟**: 実行部品（スクリプト・フック・LaunchAgent）を追加するときは、対応する Decision に**分類（A=常時/B=定期/C=手動）・テスト増分・廃止条件**を書く。
- **Projects の frontmatter と Tasks 節**: `status:` 4 値（active/paused/completed/closed）・状態が動いたら `next:`（15 文字以内）も更新・Tasks 節と待ち（wait_until）の書式＝[[Preferences/project-tasks-format]]（Dock の表示元）。
## 書き方の鉄則
- 該当が出たら**その場で書く**。書き込みの**決定者**はリーダーの Claude のみ。**執筆は必ず Vault 書込を宣言した記録職（定義の frontmatter `aienv-vault-write: allowed`・既定＝`vault-scribe`）へ委任**＝リーダーが内容を確定して渡す。**リーダー直筆は禁止**。⚠️ **単独モードだけは例外**＝リーダーが案件の締めに直筆する（Vault 専用の直接作業宣言マーカーで gate を通す）。**記録職専任の対象は AI向け6フォルダのみ**＝人間向け領域（Blogs/・Explorations/ ほか）は直接書き込み可。他ワーカーは6フォルダへの記録候補を「Vault記録候補:」で申告。
- **記録職の選び方**: 既定＝`vault-scribe-light`（既存ノートへの数行追記・状態記号・frontmatter の数行・文字列置換 1〜2 箇所）。標準 `vault-scribe` は新規ノート・Preferences の編集・本文の書き換え・複数ノートの整合のときだけ。正本＝各定義ファイルの「担当範囲」。
- 長くなったら分割（目安8,000字・Decisions は対象外）＝詳細を別ノートへ分離し相互リンク。
- フロントマター必須（date/tags/project）・本文編集で `updated` 更新。wiki link はフォルダ付き `[[Folder/note]]`・関連ノートは**相互に**リンク。
- aliases 必須（README 除く）＝想起フックの検索キー。実際に打ちそうな語（目安5個・他ノートと重ならない固有語・汎用語禁止・迷ったら付けない）で、**うち1個以上は「その知識を使う場面で口にする語」**（技法名・カタログ名だけにしない＝[[Decisions/2026-09-23-situational-aliases-and-milestone-recall]]）。外部情報系は `review_by:`（任意）。
- Read/Write/Edit/Grep で直接操作（obsidian-mcp 不使用）。Vault 読み書きは本人へ明示報告（定常メンテ＝Fragments 昇格・棚卸し対処は個別報告不要）。
## AI主導の想起（キーワード1本化）
- 検索仕様は**フック1つだけ**（aliases・ファイル名照合。別ツール/別閾値/別モード禁止）。候補不足なら同じフックをクエリ言い換えで再実行（コマンド＝[[Knowledge/external-brain-guide]]）。工夫は「聞き方」のみ。**工程の節目（要件定義・設計・企画書・レビューの着手前）にリーダーが場面語で同じフックを1回回し、出た棚を読んでから始める**（同 Decision）。
## 起動時ヘルス警告・綻びの扱い
- SessionStart 注入の【外部脳ヘルス】は `stage=ERROR` のときだけ最初の応答で「直しましょう」と述べ、主体 `AI` の項目を対処して本番経路（読込・想起）を 1 回だけ再実行し、失敗したら診断結果と対処案の提示に切り替える。`WARNING` は本人が対処を求めるまで言及しない。対処の締め手順と終了条件（`OK 候補0件` まで回す）＝[[Preferences/external-brain-maintenance-close-loop]]。
- **綻びは読み時に直す**: 鮮度（`review_by` 超過・古い外部可変情報＝一次情報で再確認→`updated` 引き直し。内部の決定ノートは対象外）／リンク切れ（張り直す or 除去）／alias（欠落・汎用/短すぎ＝想起に効く語へ）。⚠️ サブ機で Preferences 内のリンク先が無いのは常態＝リンク切れに数えない（[[Preferences/core-workflow]] §4）。
- **撤回・白紙化バナー**: 失効ノート（Decisions 含む）は冒頭に「⚠️白紙化済み/撤回済み（日付＋出典）」バナー（本文は書き換えない）。**バナー付きノートを新文脈の材料に使わない**（再採用は本人の明示指示のみ）。
- **撤去済みシステムの退役**: 撤去したら関連 Knowledge ノートを想起から退役させる＝aliases・review_by を除去し `retired: true`＋冒頭に退役バナー（本文は温存）。判定は読み時・棚卸し時に個別（ルールの根拠ノートは対象外）。
- **停滞は本人の領域**: project の status は本人が棚卸しで判断＝**AI は書き換えない**（気づいたら一言添える）。棚卸しレポートは検出のみ＝**読んだノートの綻びは読むたびに直す**。
