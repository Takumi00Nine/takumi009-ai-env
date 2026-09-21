---
date: 2026-06-21
updated: 2026-09-21
tags: [preference, meta, external-brain, routing]
project: external-brain
related:
  - "[[Knowledge/core-rules-compression-archive]]"
  - "[[Decisions/2026-08-10-vault-scribe]]"
  - "[[Decisions/2026-09-07-profile-axes-consolidation]]"
  - "[[Decisions/2026-09-17-effort-per-role-v2]]"
  - "[[Decisions/2026-09-18-task-pane-format-v4]]"
  - "[[Decisions/2026-09-20-health-self-explain-error-only-autofix]]"
  - "[[Decisions/2026-09-20-fragments-reviewed-close-command]]"
  - "[[Decisions/2026-09-20-project-frame-wait-status-v5]]"
  - "[[Decisions/2026-09-21-project-wait-by-version-v6]]"
  - "[[Decisions/2026-09-20-roles-config-only]]"
  - "[[Preferences/external-brain-maintenance-close-loop]]"
  - "[[Decisions/2026-09-21-maintenance-close-loop]]"
aliases:
  - "外部脳運用チートシート"
  - "public執筆の掟"
---
# 外部脳 運用チートシート（起動必読・ルーティング表）
詳細・実例＝[[Knowledge/external-brain-guide]]。public 公開＝リンク先が読めなくても単体でルールとして完結するよう書く。
## どのフォルダに何を書くか
- **Fragments/**＝未確定・副産物の入口（append-only・日次 `Fragments/YYYY-MM/YYYY-MM-DD.md`）。断片は応答前にその場で短く追記・確定したら昇格。昇格の締め（印・締めコマンド・Dock 確認）＝[[Preferences/fragments-workflow]] §4。
- **Knowledge/**＝技術知見・背景／**Decisions/**＝選んだ判断と理由（`YYYY-MM-DD-topic.md`）／**Projects/**＝進行状態と next_action／**Preferences/**＝運用ルール（⚠️public）／**Personal/**＝個人情報。**Blogs/**・**Explorations/**＝外部脳の対象外（人間向け）。6フォルダはAI向け＝トークン効率優先。
## public 執筆の掟（public＝Preferences/ のみ・他は private）
1. 個人情報・経緯・エピソードを書かない（理由・経緯は Decisions へ、個人の事実は Personal へ）。
2. ユーザーの呼び名を書かない。「ユーザー」「本人」等の中立表現を使う（ID「takumi009」は可）。
3. Personal 配下への wiki link・Personal ノート名を書かない（他フォルダへのリンクは可）。
4. ホーム配下の絶対パスを書かない（`~/` 表記＝Vault 全域の掟）。
- Preferences 編集セッションの締めに `~/work/takumi009-ai-env/scripts/export-public-vault.sh` を実行（commit 自動・push は別途明示）。⚠️ Preferences の編集も公開スナップショットの生成・commit も machine_role: main の機だけ（sub は pull のみ）。
## SSOT の役割分担（ドリフト防止）
- **Preferences＝今どう動くか／Decisions＝なぜ／Knowledge＝背景。** 判断は Preferences と Decisions を**ペアで**書く。現行値（設定値・状態）は Projects のみ。
- 体制を変える Decision を書いたら影響語を grep して現在形ノート（Preferences/Projects/Knowledge）を同時修正し、grep 語と修正ファイルを Decision の「適用」欄に記録（該当ノートは**通し読み**）。
- 同じルールは SSOT 1つ＋他はリンクのみ。旧方針は `deprecated YYYY-MM-DD` で現行より下に隔離。
- **部品追加の掟**: 実行部品（スクリプト・フック・LaunchAgent）を追加するときは、対応する Decision に**分類（A=常時/B=定期/C=手動）・テスト増分・廃止条件**を書く。
- **Projects の frontmatter**: `status:` は4値のみ＝`active`/`paused`/`completed`/`closed`。**状態が動いたら `next:`（15文字以内）も更新**（cmux Dock「Project」枠の表示元。「Project の N 番」解決＝`~/work/takumi009-ai-env/cmux/cmux-next-model.sh --list`＝5 列 TSV＝番号・正式プロジェクト名・next 値・区分（稼働中／待ち／保留）・待ち日時）。
- **待ち（wait_until）**: 日時まで待つ案件は、Tasks 節の**待つ版（Dock の ▶ の版）の直下**に行頭から `- wait_until: YYYY-MM-DDTHH:MM`（ローカル時刻・`YYYY-MM-DD` 可＝その日の 00:00）を 1 行書く（`status: active` のまま。Dock は描かず・数えない。▶ の版が待ちのときだけ Project 枠が「待ち」になり、次の版に着手すれば自動で稼働中へ＝書き戻し不要。過ぎた値は次にその版を触るとき消す）。**▶ の版が無い案件（Tasks 節なし・全版完了・全版タスク 0 件）だけ** frontmatter `wait_until:` が効く。▶ の版がある案件では frontmatter の値は効かない（供給側が診断 1 行）。字下げした行・版の範囲の外・秒／タイムゾーン付き・暦に無い日は無効＝稼働中のまま。詳細＝[[Decisions/2026-09-20-project-frame-wait-status-v5]]・[[Decisions/2026-09-21-project-wait-by-version-v6]]。
- **Tasks 節**（任意）: `## Tasks` → `### <版名>` → `- [ ]`/`- [/]`（進行中）/`- [x]`。cmux Dock「Task」枠の表示元。工程の節目にリーダーが記録職へ更新を依頼する。依頼をまとめて出すときは、その依頼の直後に始める子行を着手後の状態 `[/]` で書く（▶ は `[/]` の版に付く＝未着手のまま出すと矢印が別の版に残る）。Tasks を触った依頼の後はリーダーが Dock の出力（`~/work/takumi009-ai-env/cmux/cmux-task-model.sh --frame` の `cur` 行）を 1 回見る。`next:` が無いノートは先頭未完タスクを Project 枠が導出表示する（書き戻しなし）。「Task の N 番」解決・Dock の展開規則は下の「Tasks の書き方」節参照。
- **Tasks の書き方**: Dock は `###` 版名と `- [ ]` 子行をそのまま描くので短く書く＝**版名は目的だけ・20文字以内**／**子行は「動詞句」・番号なし・25文字以内**（例: `- [x] 実装`・`- [ ] 検証→merge`。番号は Dock が版に振るので子行に書かない）。経緯・承認日時・モード・巡数・枠消費・コミット番号・締めの1行（モード・検証職・巡数）は見出しや子行に書かず、その版の直下に `- 記録:`（版全体）か `- 記録 <子行の動詞句>:`（子行個別・子行の文言をそのまま）の行へ書く（Dock は描かない）。詳細は Decision／Fragments へ。理由＝長い版名・子行が Dock の右端で切れて読めない。「Task の N 番」解決＝`~/work/takumi009-ai-env/cmux/cmux-task-model.sh --list`（番号は版。未完の版だけに記載順で 1 から。5 列＝番号・版名・分数・状態・本文）。Dock の ▶ は `[/]` を含む最初の版 → 無ければ frontmatter `next:` と版名が完全一致する版 → 無ければ 1 番。展開されるのは done≥1 か `[/]` を含む版。完了版は「── 完了 n 件 ✅」の 1 行に畳む。
## 書き方の鉄則
- 該当が出たら**その場で書く**。書き込みの**決定者**はリーダーの Claude のみ。**執筆は必ず Vault 書込を宣言した記録職（定義の frontmatter `aienv-vault-write: allowed`・既定＝`vault-scribe`・起動形態は問わない＝既定は名前無し subagent）へ委任**＝リーダーが内容を確定して渡し、vault-scribe が掟に従い執筆。**リーダー直筆は禁止**。⚠️ **単独モードだけは例外**＝リーダーが案件の締めに直筆する（Vault 専用の直接作業宣言マーカーで gate を通す）。**記録職専任の対象は AI向け6フォルダ（Fragments/Knowledge/Decisions/Projects/Preferences/Personal）のみ**＝人間向け領域（Blogs/・Explorations/ ほか）はリーダー・ワーカー・スクリプトが直接書き込み可。他ワーカーは6フォルダへの記録候補を「Vault記録候補:」で申告。
- **記録職の選び方**（2026-09-21）: 既定＝`vault-scribe-light`（既存ノートへの数行追記・状態記号・frontmatter の数行・指定文字列の置換 1〜2 箇所）。標準 `vault-scribe` は新規ノート・Preferences の編集・本文の書き換え・複数ノートの整合のときだけ。担当分けの正本＝各定義ファイルの「担当範囲」・経緯＝[[Decisions/2026-08-10-vault-scribe]] 追補。
- 長くなったら分割（目安8,000字・Decisions は対象外）＝詳細を別ノートへ分離し相互リンク。
- フロントマター必須（date/tags/project）・本文編集で `updated` 更新。wiki link はフォルダ付き `[[Folder/note]]`・関連ノートは**相互に**リンク。
- aliases 必須（README 除く）＝想起フックの検索キー。実際に打ちそうな語1〜5個・汎用語禁止・迷ったら付けない。外部情報系は `review_by:`（任意）。
- Read/Write/Edit/Grep で直接操作（obsidian-mcp 不使用）。Vault 読み書きは本人へ明示報告（定常メンテ＝Fragments 昇格・棚卸し対処は個別報告不要）。
## AI主導の想起（キーワード1本化）
- 検索仕様は**フック1つだけ**（aliases・ファイル名照合。別ツール/別閾値/別モード禁止）。候補不足なら同じフックをクエリ言い換えで再実行（コマンド＝[[Knowledge/external-brain-guide]]）。工夫は「聞き方」のみ。
## 起動時ヘルス警告・綻びの扱い
- SessionStart 注入の【外部脳ヘルス】は `stage=ERROR` のときだけ最初の応答で「直しましょう」と述べ、ERROR を生んだ源の主体 `AI` の項目を対処して本番経路（読込・想起＝同セッション内の読み直し）を 1 回だけ再実行し、失敗したら診断結果と対処案の提示に切り替える。`WARNING` は本人が対処を求めるまで言及しない（放置防止は Dock の `外部脳 WARNING` 表示＝本人が引き受ける）。詳細＝[[Decisions/2026-09-20-health-self-explain-error-only-autofix]]。対処の締め手順と終了条件（`OK 候補0件` まで回す）＝[[Preferences/external-brain-maintenance-close-loop]]。
- **綻びは読み時（気づいた時点）で直す**: 鮮度（`review_by` 超過・古い外部可変情報＝一次情報で再確認→`updated` 引き直し。内部の決定ノートは対象外）／リンク切れ（張り直す or 除去）／alias（欠落・汎用/短すぎ＝想起に効く語へ）。⚠️ サブ機で Preferences 内のリンク先が無いのは常態＝リンク切れに数えない（[[Preferences/core-workflow]] §4）。
- **撤回・白紙化バナー**: 失効ノート（Decisions 含む）は冒頭に「⚠️白紙化済み/撤回済み（日付＋出典）」バナー（本文は書き換えない・単体で失効が分かる）。**バナー付きノートを新文脈の材料に使わない**（再採用は本人の明示指示のみ）。
- **撤去済みシステムの退役**: 撤去したら関連 Knowledge ノートを想起から退役させる＝aliases・review_by を除去し `retired: true`＋冒頭に退役バナー（本文は温存）。判定は読み時・棚卸し時に個別（ルールの根拠ノートは対象外）。
- **停滞は本人の領域**: project の status は本人が棚卸しで判断＝**AI は書き換えない**（気づいたら一言添える）。棚卸しレポートは検出のみ＝**読んだノートの綻びは読むたびに直す**。
