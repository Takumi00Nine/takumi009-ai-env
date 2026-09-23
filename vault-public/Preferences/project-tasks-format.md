---
date: 2026-09-22
updated: 2026-09-23
tags: [preference, project, tasks, cmux, dock]
project: takumi009-ai-env
related:
  - "[[Preferences/vault-operation]]"
  - "[[Decisions/2026-09-18-task-pane-format-v4]]"
  - "[[Decisions/2026-09-21-project-wait-by-version-v6]]"
  - "[[Decisions/2026-09-22-project-frame-focus-arrow-v7]]"
  - "[[Preferences/project-note-sample]]"
  - "[[Decisions/2026-09-23-project-note-standard]]"
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
- **起票の手順**＝新規案件はリーダーが内容を確定し、記録職が [[Preferences/project-note-sample]] を複製して埋める（[[Preferences/core-workflow]] §1「Projects ノートは宣言の前」）。既存ノートは一斉移行せず、触ったときに型へ直す。
- **起動時**＝案件宣言した slug の Projects ノートをリーダーが最初に読む（運用ルール。フック化は再発時に判断）。

- **Projects の frontmatter**: `status:` は4値のみ＝`active`/`paused`/`completed`/`closed`。**状態が動いたら `next:`（15文字以内）も更新**（cmux Dock「Project」枠の表示元。「Project の N 番」解決＝`~/work/takumi009-ai-env/cmux/cmux-next-model.sh --list`。描画規則＝[[Decisions/2026-09-22-project-frame-focus-arrow-v7]]）。
- **待ち（wait_until）**: 日時まで待つ案件は、Tasks 節の**待つ版（Dock の ▶ の版）の直下**に行頭から `- wait_until: YYYY-MM-DDTHH:MM`（ローカル時刻・`YYYY-MM-DD` 可＝その日の 00:00）を 1 行書く（`status: active` のまま。過ぎた値は次にその版を触るとき消す）。**▶ の版が無い案件（Tasks 節なし・全版完了・全版タスク 0 件）だけ** frontmatter `wait_until:` が効く。字下げ・版の範囲外・秒／タイムゾーン付き・暦に無い日は無効。描画規則＝[[Decisions/2026-09-21-project-wait-by-version-v6]]。
- **Tasks 節**（任意）: `## Tasks` → `### <版名>` → `- [ ]`/`- [/]`（進行中）/`- [x]`。cmux Dock「Task」枠の表示元。工程の節目にリーダーが記録職へ更新を依頼する。依頼をまとめて出すときは、その直後に始める子行を `[/]` で書く（▶ は `[/]` の版に付く）。Tasks を触った依頼の後はリーダーが Dock の出力（`~/work/takumi009-ai-env/cmux/cmux-task-model.sh --frame` の `cur` 行）を 1 回見る。`next:` が無いノートは先頭未完タスクを Project 枠が導出表示する。
- **Tasks の書き方**: Dock は `###` 版名と `- [ ]` 子行をそのまま描くので短く書く＝**版名は目的だけ・20文字以内**／**子行は「動詞句」・番号なし・25文字以内**（例: `- [ ] 検証→merge`）。経緯・承認日時・モード・巡数・枠消費・コミット番号・締めの1行は見出しや子行に書かず、その版の直下の `- 記録:`（版全体）か `- 記録 <子行の動詞句>:`（子行個別）の行へ書く（Dock は描かない）。詳細は Decision／Fragments へ。「Task の N 番」解決＝`~/work/takumi009-ai-env/cmux/cmux-task-model.sh --list`（番号は未完の版に記載順）。▶ の位置・展開・畳み方＝[[Decisions/2026-09-18-task-pane-format-v4]]。
