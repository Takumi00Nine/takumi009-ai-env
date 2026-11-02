---
date: 2026-06-21
updated: 2026-11-02
tags: [preference, meta, external-brain, routing]
project: external-brain
aliases:
  - "外部脳運用チートシート"
  - "public執筆の掟"
---
# 外部脳 運用チートシート（起動必読・ルーティング表）
外部脳は、すべての AI が共通の1つの脳を使い、セッションやツールが替わっても続けられるようにする。目的・意味・仕組みの正本＝[[Knowledge/external-brain-guide]]（理由＝[[Decisions/2026-11-02-external-brain-three-stage-ladder]]）。public 公開＝リンク先が読めなくても単体でルールとして完結するよう書く。
## どのフォルダに何を書くか
- **Fragments/**＝日々の作業の断片（append-only・日次）。応答前にその場で短く追記。時機・昇格の印＝[[Preferences/fragments-workflow]]。
- **Knowledge/**＝情報・知識（事実・起きたこと・調べて分かったこと・教訓・仕組みの説明）を書く。
- **Decisions/**＝本人の判断（本人がなぜそう判断したか。好み・信条・価値観による判断の理由）を書く。
- **Projects/**＝進行状態・現行値・next_action を書く。
- **Preferences/**＝規則を書く（public）。
- **Personal/**＝個人情報・個人の事実を書く。
- **Blogs/**・**Explorations/**＝外部脳の対象外（人間向け）。外部脳の6フォルダは AI 向けで、トークン効率を優先する。
- 規則の理由も上のフォルダの基準で書き分ける。情報・知識と本人の判断の両方を含む理由は各部分をそれぞれに書いて相互にリンクする。発言の形ではなく理由の中身で決める（[[Decisions/2026-11-02-external-brain-three-stage-ladder]]）。
- 理由の置き場を書くときは、上のフォルダの分類基準を必ず添える。同じノート内ではこの節への参照にする（[[Knowledge/rule-reason-placement-criterion]]）。
## 3段で上げる・規則を作る／変える
- **Fragments → Knowledge → Preferences**。教訓が分かったら本人の指示を待たず上げる（[[Preferences/fragments-workflow]]）。ミス由来の規則は必ず Knowledge の教訓を通り、規則化の提案は [[Preferences/core-conduct#4. 判断の型]] に従う（[[Decisions/2026-11-02-external-brain-three-stage-ladder]]）。
- 規則は本人の承認後、**理由のノートを先に作ってから作る**。理由の書き分けは本ノート「どのフォルダに何を書くか」に従う。理由のノート無しの規則は作らない。規則と理由のノートは相互にリンクし、経緯・理由は規則本文に書き写さない。教訓の状態と判断の書式＝[[Preferences/note-templates]]（[[Decisions/2026-11-02-external-brain-three-stage-ladder]]）。
- 規則を変える・消す前は、字句の直し・参照整理を含む**すべての変更**で理由のノート本文を読み、元の理由をもとに変更案を決める。案に「理由のノートへのリンク／元の理由／今回変わったこと」を書く。既存規則に理由のノートが無ければ「元の理由＝理由のノート無し」と書く。本人の承認後に反映する。意味を変えるときは新しい理由の記録を先に保存し、意味を変えない直しのためには理由を新設しない（[[Decisions/2026-11-02-use-decisions-recall-and-rule-change]]）。
## 機ごとに書ける範囲
- サブ機のリーダーが書けるのは Fragments・Knowledge・Decisions。書き分けと両方を含む理由の扱いは本ノート「どのフォルダに何を書くか」に従う。各機の記録は独立で、サブ機の分はメイン機へ反映されない（[[Decisions/2026-09-03-sub-machine-vault-write-policy]]）。
- **Preferences への昇格・編集はメイン機のリーダーだけ**。サブ機は配られた Preferences を使う。サブ機で規則化の提案や規則の変更に当たったら、上の範囲で理由を記録し、規則を作る・変える作業はメイン機での作業として本人の持ち帰りにする。メイン機での続きは本ノート「3段で上げる・規則を作る／変える」に従う。
## public 執筆の掟（public＝Preferences/ のみ・他は private）
1. 個人情報・経緯・エピソードを書かない。書き先と理由の書き分けは本ノート「どのフォルダに何を書くか」に従う。
2. ユーザーの呼び名を書かない。「ユーザー」「本人」等の中立表現を使う（ID「takumi009」は可）。
3. Personal 配下への wiki link・Personal ノート名を書かない（他フォルダへのリンクは可）。
4. ホーム配下の絶対パスを書かない（`~/` 表記＝Vault 全域の掟）。
- 公開スナップショットの export の実行時機・実行者・公開 push の扱いは [[Preferences/core-workflow]] §5 を参照する。
## SSOT の役割分担（ドリフト防止）
- 現行値の書き先は本ノート「どのフォルダに何を書くか」、規則の作成・変更は「3段で上げる・規則を作る／変える」に従う。
- 体制を変える Decision を書いたら影響語を grep して現在形ノート（Preferences/Projects/Knowledge）を**通し読み**して同時修正し、grep 語と修正ファイルを Decision の「適用」欄に記録。
- 同じルールは SSOT 1つ＋他はリンクのみ。旧方針は `deprecated YYYY-MM-DD` で現行より下に隔離。
- **部品追加の掟**: 実行部品（スクリプト・フック・LaunchAgent）を追加するときは、対応する Decision に**分類（A=常時/B=定期/C=手動）・テスト増分・廃止条件**を書く。
- **Projects の frontmatter と Tasks 節**: 書式と工程完了時の更新は [[Preferences/project-tasks-format]]、`status` を決める権限は本ノート「停滞による状態判断は本人の領域」を参照する。
## 初期セットアップ
初回のセットアップは本人の依頼時に行う。通常会話でフォルダを作り直さない。機ごとの構成と配布＝[[Preferences/core-workflow#4. 記録（外部脳）]]、作業場所＝[[Preferences/file-placement]]。
## ファイル命名規則
- Fragments: `YYYY-MM/YYYY-MM-DD.md`（日次・`YYYY-MM` フォルダで分割）
- Knowledge: `topic-subtopic.md`（例: `nextjs-auth-cookie.md`）
- Decisions: `YYYY-MM-DD-topic.md`（例: `2026-05-16-database-choice.md`）
- Preferences: `category.md`（例: `coding-style.md`）
- Projects: `project-name.md`
- **例外**: 各フォルダの `README.md` は索引・役割説明用として許可する（命名規則の対象外）。
- ファイル名は英語kebab-case、ノート見出し（H1）は日本語可（検索性と可読性の両立）。`project:` フィールドはファイル名と揃える。
## 書き方の鉄則
- 該当が出たら**リーダーがその場で自分で書く**。既存ノートへの追記・状態記号・frontmatter・置換から、新規ノート・Preferences の編集・本文の書き換え・複数ノートの整合まで、軽重に関係なくリーダーが内容を決定して直接書く。**ワーカーは Vault（人間向け領域の Blogs/・Explorations/ を含む）へ書かず**、記録候補を最終報告の「Vault記録候補:」で申告する。この役割の決まりはモード・呼び出し経路によらず守り、書き込みを止める仕組みは追加しない。
- **Preferences の編集と公開スナップショットの生成・commit**はメイン機のリーダーだけが行う。実行前に `~/.config/takumi009-ai-env/profile.md` の `machine_role` が `configured value=main` であることを確認する（[[Preferences/core-workflow]] §5）。
- **当てはまる範囲を書き分ける**: どのツールがリーダー・ワーカーになっても同じ決まりは、「リーダー」「ワーカー」「職種名（researcher など）」で書き、Claude・Codex などのツール名やモデル名を書かない。特定のツールにしか当てはまらない手順・事実（起動のしかた・設定・使用枠・不具合など）だけツール名を書き、文頭や節の頭に「Codex のとき：」のように対象を示す。1つの文に両方が混ざるなら、共通の決まりとツール固有の部分の2文に分ける。迷ったら共通の決まりとして書く（[[Decisions/2026-10-31-tool-neutral-rule-wording]]）。
- **続きに必要なことはツールの中にだけ置かない**: 続きの作業に必要な知識・決定・状態は、外部脳か案件のファイルに書く。ツール内蔵の記憶・会話の履歴は残っていてよく使ってもよいが、そこにだけ置かない（リーダーが替わっても、新しいセッションでも続けられるように）。ツールが自動で記憶を書き足す機能は切っておく（[[Decisions/2026-10-31-memory-not-only-in-tools]]）。
- **共有フォルダの書き方**（リーダーが同時に複数いても消さない）: `Fragments/` の日次ファイルは末尾への追記で書き、ファイル全体を読み込んで書き戻さない。既存の行を書き換えるとき（昇格の印など）は書く直前に読み直す。`Preferences/`・`Knowledge/`・`Decisions/`・`Personal/` の既存ノートを書き換えるときは、書く直前に読み直してから書く。`Projects/` は担当リーダーが書く（[[Decisions/2026-10-31-shared-folder-write-rule]]）。
- 長くなったら分割（目安8,000字・Decisions は対象外）＝詳細を別ノートへ分離し相互リンク。
- フロントマター必須（date/tags/project）・本文編集で `updated` 更新。wiki link はフォルダ付き `[[Folder/note]]`・関連ノートは**相互に**リンク。
- aliases は任意。既存の aliases は残す。教訓・本人の判断の「効く場面」は [[Preferences/note-templates]] に従って書く。外部情報系は `review_by:`（任意）（[[Decisions/2026-11-02-external-brain-three-stage-ladder]]・[[Decisions/2026-11-02-use-decisions-recall-and-rule-change]]）。
- Read/Write/Edit/Grep で直接操作（obsidian-mcp 不使用）。Vault 読み書きは本人へ明示報告（定常メンテ＝Fragments 昇格・棚卸し対処は個別報告不要）。
## AI主導の想起
- 想起は Knowledge の教訓と Decisions の本人の判断を同じ部品で扱い、発言が「効く場面」に強く合うときだけ中身1行と出典を出す。規則化済み・規則の理由も対象。退役・撤回・白紙化と「1行／効く場面」の欠けは対象外。別の判定口を作らない（[[Decisions/2026-11-02-use-decisions-recall-and-rule-change]]）。
- 工程の節目（要件定義・設計・企画書・レビューの着手前）にリーダーが場面語で同じ想起を1回回し、出典の本文を読んでから始める。手動の口＝[[Knowledge/external-brain-guide#想起の役目と手動の口]]。合うものが無ければ何も出さず、必要な検索は別途行う（[[Decisions/2026-09-23-situational-aliases-and-milestone-recall]]）。
## 起動時ヘルス警告・綻びの扱い
- SessionStart 注入の【外部脳ヘルス】は `stage=ERROR` のときだけ最初の応答で「直しましょう」と述べ、主体 `AI` の項目を対処して本番経路（読込・想起）を 1 回だけ再実行し、失敗したら診断結果と対処案の提示に切り替える。`WARNING` は本人が対処を求めるまで言及しない。対処の締め手順と終了条件（対処→再実行→読み直し）＝[[Preferences/external-brain-maintenance-close-loop]]。
- **綻びは読み時に直す**: 鮮度（`review_by` 超過・古い外部可変情報＝一次情報で再確認→`updated` 引き直し。内部の決定ノートは対象外）／リンク切れ（張り直す or 除去）。⚠️ サブ機で Preferences 内のリンク先が無いのは常態＝リンク切れに数えない（[[Preferences/core-workflow]] §4）。
- **撤回・白紙化バナー**: 失効ノート（Decisions 含む）は冒頭に「⚠️白紙化済み/撤回済み（日付＋出典）」バナー（本文は書き換えない）。**バナー付きノートを新文脈の材料に使わない**（再採用は本人の明示指示のみ）。
- **撤去済みシステムの退役**: 撤去したら関連 Knowledge ノートを想起から退役させる＝aliases・review_by を除去し `retired: true`＋冒頭に退役バナー（本文は温存）。判定は読み時・棚卸し時に個別（ルールの根拠ノートは対象外）。
- **停滞による状態判断は本人の領域**: AI は停滞を理由に project の `status` を自動で変更しない（気づいたら一言添える）。本人が決めた状態はリーダーが記録へ反映する。工程完了時の Tasks・`next` 更新は [[Preferences/project-tasks-format]] に従う。棚卸しレポートは検出のみ。読んだノートの綻びは読み時に直す。
