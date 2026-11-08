---
date: 2026-09-22
updated: 2026-11-03
tags: [preference, project, tasks, cmux, dock]
project: takumi009-ai-env
related:
  - "[[Decisions/2026-11-01-agents-md-no-rules]]"
  - "[[Preferences/vault-operation]]"
  - "[[Decisions/2026-09-18-task-pane-format-v4]]"
  - "[[Decisions/2026-09-21-project-wait-by-version-v6]]"
  - "[[Decisions/2026-09-22-project-frame-focus-arrow-v7]]"
  - "[[Preferences/project-note-sample]]"
  - "[[Decisions/2026-09-23-project-note-standard]]"
  - "[[Decisions/2026-10-04-project-note-tasks-docs-split]]"
aliases:
  - "Tasks 節の書き方"
  - "wait_until の書き方"
  - "Project 枠"
  - "Projects の frontmatter"
  - "Projects ノートの型"
  - "Projects の起票"
---
# Projects ノートの型（frontmatter・本文5節・Tasks 節＝cmux Dock の表示元）
[[Preferences/vault-operation]] の下位規則。Projects ノートの `status:`／`next:`・待ち（wait_until）・Tasks 節の書式＝cmux Dock「Project」枠・「Task」枠が読む正本。

## 本文の型（2026-09-23 本人決定）
- **用途**＝リーダーが案件のセッション開始時に最初に読む最低限の申し送り。詳細は要件書・設計書に置き、ノートは全体 2,000 字を目安に保つ（超えたら正本へ逃がす）。
- **frontmatter の固定キー**＝date／updated／tags／project／status／next／aliases／related（待ちがある案件だけ wait_until）。`project` はノート名＝案件宣言の slug と同じ値。`next_action` は廃止（新規では書かない）。
- **本文は5節・この順・見出し固定**＝①目的（2〜3行）②守ること（確定した前提・本人裁定・やらないこと＝1行1件・日付・理由は Decision へリンク。前提／裁定／不採用を分けず1本のリストにする）③今どこ・次に何を（段階・モード・委任の有無・決める人・次の一手＝書き換えて更新し追記しない）④正本の所在（要件書・設計書・作業ディレクトリ・調査へのリンク）⑤Tasks（下記）。空の節も見出しは残す。
- **書かないもの**＝経緯・対話ログ・工程の出来事（Fragments）／判断の理由（Decisions）／ゴール像・受入条件（要件書）／アイデア台帳（Knowledge か Fragments に置いて④からリンク）／日付見出しの積み上げ。
- **起票の手順**＝新規案件はリーダーが内容を確定し、自分で [[Preferences/project-note-sample]] を複製して埋める（[[Preferences/core-workflow]] §1「Projects ノートは宣言の前」）。既存ノートは一斉移行せず、触ったときに型へ直す。
- **三段の体制の起票**＝初期ノートは目的・ゴールを本人と決めた後、マックリーダーが作る。固定キーと5節を保ち、①目的＝目的・ゴールの要約 ②守ること＝確定した本人の前提 ③今どこ・次に何を＝親の作業一覧作成待ち ④正本の所在＝本人発言と案件の所在を書く。Tasks は見出しだけとし、仮の工程・枠・体制をマックリーダーが埋めない。存在確認と案件宣言は親の起動前に済ませる。親は初回にノートを読み、作業一覧と見積り・停止点・体制を作り、マックリーダーの取り次ぎで本人承認を得てから Tasks と次の一手へ反映する。以後の更新・記号・next は親。締めで体制節の要点（範囲・次工程・人数と相談の結論）と担当表・状態記録の保存先を既存の節へ短く残す（[[Decisions/2026-11-03-three-tier-team-stage1]]）。
  - **全案件の一覧への接続**＝案件宣言の案件名と、案件の所在・担当表と状態記録の保存先を④正本の所在から辿れるようにする。立ち上げ時はマックリーダーが予定先と親未起動を書き、親の登録後は実際の保存先との対応を確かめる。以後の変更と締めの参照確認は親が行い、一覧に効く対応の変更はマックリーダーへ報告する。新しい frontmatter キーや第6節は増やさない。
  - 一覧は宣言中の画面だけに限らず、画面との対応が外れても案件の参照と保存記録を失わない。参照が欠ける案件を親未起動・0人と推測せず未接続・未確認とする。status・next・Tasks は本人判断と工程の節目の記録のまま。ワーカーの実行・相談状態は状態記録を読み、一覧の取得や経過時間だけで status・Tasks・待ち日時を更新せず、子の逐次状態を案件ノートへ複写しない（[[Decisions/2026-11-03-three-tier-team-stage4]]）。
- **起動時**＝案件宣言した slug の Projects ノートをリーダーが最初に読む（運用ルール。フック化は再発時に判断）。
- **書く時機**＝工程の節目に加え、本人の意図・決定・留意事項がまだ書かれていない状態で大きな読み込み・長い処理へ進む前と、要約が近いとき。続きの正本はこのノート＝要約・本人による新しいセッションの開始のどちらからでも続けられるようにする（中身の対応表＝[[Preferences/session-handoff]]「先に書く」）。

- **Projects の frontmatter**: `status:` は4値のみ＝`active`/`paused`/`completed`/`closed`。**本人が決めた状態をリーダーが `status:` に反映し、`next:`（15文字以内）も更新**。停滞による状態判断は [[Preferences/vault-operation]]、工程完了時の記号・`next` 更新は下の Tasks 節の規定に従う（cmux Dock「Project」枠の表示元。「Project の N 番」解決＝`~/Workspace/Tools/takumi009-ai-env/dock/executor/cmux-next-model.sh --list`。描画規則＝[[Decisions/2026-09-22-project-frame-focus-arrow-v7]]）。
- **待ち（wait_until）**: 日時まで待つ案件は、Tasks 節の**待つ版（Dock の ▶ の版）の直下**に行頭から `- wait_until: YYYY-MM-DDTHH:MM`（ローカル時刻・`YYYY-MM-DD` 可＝その日の 00:00）を 1 行書く（`status: active` のまま。過ぎた値は次にその版を触るとき消す）。**▶ の版が無い案件（Tasks 節なし・全版完了・全版タスク 0 件）だけ** frontmatter `wait_until:` が効く。字下げ・版の範囲外・秒／タイムゾーン付き・暦に無い日は無効。描画規則＝[[Decisions/2026-09-21-project-wait-by-version-v6]]。
- **Tasks 節**（任意）: `## Tasks` → `### <版名>` → `- [ ]`/`- [/]`（進行中）/`- [x]`。cmux Dock「Task」枠の表示元。子行は**工程単位**（1 ワーカーの起動〜完了、または 1 ゲート＝リーダーの作業単位）。工程が終わるごとにリーダーが記号（と next）を即時に直筆する（締めまで後回しにしない＝[[Decisions/2026-10-04-leader-vault-light-writes-no-gate]]）。版の直下に `- 正本: <案件の docs/ の裁定録・要件書・設計書へのパス>` を 1 行置く（Dock は描かない）。経緯・巡数・commit・裁定は Projects に書かず案件の docs/（裁定録）へ＝二重管理をしない（[[Decisions/2026-10-04-project-note-tasks-docs-split]]）。
- **版が終わったら見出しごと消す**：版の子行が全部 `[x]` になったら、その `###` 版を子行ごと消す。「完了（日付）＝…」のまとめ行に置き換えて残さない（Dock に 0/0 で残るため）。結果は Decision か案件の docs（requirements-notes 等）に残す（本人決定 2026-11-01）。
- **Task 番号**：案件ノートの Tasks 節にある版（作業の区切り）を指す。子行の工程番号ではない。
- **Tasks の書き方**: Dock は `###` 版名と `- [ ]` 子行をそのまま描くので短く書く＝**版名は目的だけ・20 文字以内・番号（v1.2 等）を付けない**／**子行は「動詞句」・番号なし・25 文字以内**（例: `- [ ] 検証→merge`）。`- 記録:` 行は廃止（2026-10-04）＝既存ノートの記録行は、そのノートを触ったときに案件の docs/ へ移して外す。
- **Tasks 節と `next:` は言葉だけで書く**＝記号・番号・版記号・文書の内部名（例 O5・M-1・AP01・⑤）を持ち込まない。本人がタスク一覧を読んで内容が分かる語で書く（[[Decisions/2026-10-11-plain-words-for-the-user]]）。
