---
date: 2026-09-23
updated: 2026-09-23
tags: [preference, project, sample, template]
project: external-brain
related:
  - "[[Preferences/project-tasks-format]]"
  - "[[Preferences/vault-operation]]"
  - "[[Preferences/core-workflow]]"
  - "[[Decisions/2026-09-23-project-note-standard]]"
aliases:
  - "Projects起票テンプレ"
  - "プロジェクトノートのサンプル"
  - "案件ノートの型"
  - "起票サンプル"
---
# Projects ノートのサンプル（起票時にこれを複製して埋める）
> 用途＝リーダーが案件のセッションを始めるときに最初に読む「最低限の申し送り」。詳しいことは要件書・設計書（正本の所在からたどる）に置き、ここには書かない。規則の正本＝[[Preferences/project-tasks-format]]。全体の目安 2,000 字・超えたら正本へ逃がす。
> 複製したら `<…>` を埋め、この引用ブロックは消す。空の節も見出しは残す（「無い」と読めるように）。

```markdown
---
date: <YYYY-MM-DD>
updated: <YYYY-MM-DD>
tags: [project, <領域タグ>]
project: <案件宣言と同じ slug（ノート名も同じ）>
status: active
next: "<15字以内・次の一手>"
related:
  - "[[Decisions/<関連する判断>]]"
aliases:
  - "<実際に打ちそうな語 1〜5 個・汎用語は不可>"
---
# <案件名>

## 目的
<なぜやるか・完成したら何が起きてほしいか。本人の言葉で 2〜3 行。手段と経緯は書かない>

## 守ること（確定した前提・本人裁定・やらないこと）
- <YYYY-MM-DD> <1 行 1 件。理由は Decision へリンク>
- <YYYY-MM-DD> やらない: <スコープ外・不採用案＝[[Decisions/…]]>

## 今どこ・次に何を
- 段階: <発散／要件定義／設計／実装／検証／締め>
- モード: <単独／軽量／フル>・委任: <する／しない（誰に）>・決める人: <本人／リーダー>
- 次の一手: <1 行。書き換えて更新する（追記しない）>

## 正本の所在
- 要件書: <パス（`~/` 表記）または「未作成」>
- 設計書: <パス または「未作成」>
- 作業ディレクトリ: <パス>
- 調査・素材: <[[Knowledge/…]]・[[Fragments/…]]>

## Tasks
### <版名＝目的だけ・20 字以内>
- [ ] <動詞句・25 字以内>
- [ ] <動詞句>
```

## 書かないもの（Projects ノートに入れない）
- 経緯・対話ログ・工程の出来事→ Fragments。判断の理由→ Decisions。ゴール像・受入条件→ 要件書。発散のアイデア台帳→ Knowledge か Fragments（正本の所在からリンク）。
- frontmatter の `next_action`（廃止。Dock は `next:` だけを読む）。日付見出し（`## YYYY-MM-DD 更新`）の積み上げ。
