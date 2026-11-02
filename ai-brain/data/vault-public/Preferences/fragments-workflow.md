---
date: 2026-06-23
updated: 2026-11-02
tags: [preference, fragments, blog, workflow, capture]
project: external-brain
related:
  - "[[Decisions/2026-06-23-fragments-fleeting-layer]]"
  - "[[Preferences/vault-operation]]"
  - "[[Preferences/note-canvas-workflow]]"
  - "[[Preferences/blog-writing-nudge]]"
  - "[[Knowledge/external-brain-guide]]"
  - "[[Decisions/2026-09-20-fragments-reviewed-close-command]]"
  - "[[Preferences/external-brain-maintenance-close-loop]]"
  - "[[Decisions/2026-09-21-maintenance-close-loop]]"
aliases:
  - "即時capture"
  - "Fragments昇格レビュー"
  - "Fragments"
---

# Fragments：未確定の断片を溜める入口層の運用

`Fragments/` は **AI向けの append-only な時系列入口層**。雑多な作業の副産物・気づき・出来事・未確定の断片を溜める。教訓の3段の流れと書き分け＝[[Preferences/vault-operation]]。記事の種は Blog へ。元の断片は削除しない。

## 1. 何を記録するか（基準）
「全部」ではなく「**後でリーダー・ワーカーが使う可能性がある作業上の断片**」に絞る（over-capture は情報過多で逆に使えなくなる）。該当例：
- バグ/トラブルの原因・決定の理由・ユーザーの嗜好/気づき・作業上の発見・失敗/つまずき・未確定アイデア・Blog の種・後で知識や判断として残せそうな断片。

## 2. いつ・誰が
- **即時 capture**：作業の区切りごと、その場で短く記録（timestamp＋1〜3行＋関連リンク）。**「最後にまとめて」は避ける**。案件ノートを更新する節目では同じ節目で断片を1件以上書き、案件ノートへリンクする。
- 最初から綺麗に書こうとしない。教訓が分かったら §4 に従ってすぐ上げる。
- 書込は **リーダー自身**が行う。ワーカーは書かず、記録候補を最終報告で申告する（[[Preferences/vault-operation]]）。理由＝[[Decisions/2026-06-23-fragments-fleeting-layer]]・[[Decisions/2026-11-02-external-brain-three-stage-ladder]]。

## 3. 置き場所・粒度・フォーマット
- **日次ファイル** `Fragments/YYYY-MM/YYYY-MM-DD.md`（`YYYY-MM` フォルダで分割）。1枚は肥大、月次は当日が探しにくい、1エントリ1ファイルは細かすぎ。
- AI向け構造化。ファイル先頭にフロントマター。エントリは次の**2形式のどちらでも可**:
  - **見出し型**: `## HH:MM タイトル`＋本文（時刻を残したい・長めの塊に向く）
  - **箇条書き型**: `- **タイトル**：本文1〜数行`（1日分を素早く積める）
  - どちらも関連 `[[link]]` を添える。`status` は昇格/記事化したときに付ければよい（全エントリ必須ではない・無印は `生` とみなす）。
- 例：
```
---
date: YYYY-MM-DD
tags: [fragments]
---

## HH:MM 見出し（トピックを短く）
- 後で使う可能性がある作業上の断片を1〜3行で記録。
- 関連 [[Folder/note]]
- status: 生
```
- 状態マーク：`promoted`（昇格済）/ `published`（記事化済）の**2つだけを、該当時に付ける**。未確定は無印がデフォルト＝**「status: 生」とは書かない**（2026-07-12 本人指摘で明文化）。

## 4. 昇格・記事化
- 教訓が分かった時点で、リーダーは本人の指示を待たず Knowledge に書く。同じ型の教訓があれば新規作成せず、その教訓の発生記録へ足す。書式＝[[Preferences/note-templates#型1: 罠集（技術的な落とし穴の記録）]]（[[Decisions/2026-11-02-external-brain-three-stage-ladder]]）。
- 教訓を保存してから、元エントリの末尾へ `status: promoted → [[Knowledge/教訓のノート]]` を付け、教訓側の発生記録から元の断片へリンクする。元エントリは消さない。⑤で拾うときも同じ出来事を二重に足さない。
- 教訓を含まない断片（出来事・実施記録だけ）は上げず、昇格の印も付けない。本人の判断・案件の状態・規則の書き先と作成順は [[Preferences/vault-operation]] に従う。
- 記事の種は Blog へ（記事化は [[Preferences/note-canvas-workflow]]：Fragments を素材に Canvas → 下書き → ユーザー手直し）。記事化したときだけ `published` の印を付ける。
- 元の断片と昇格先はリンクで結び、同じ中身を二重に持たない。書き分けは [[Preferences/vault-operation#どのフォルダに何を書くか]] を参照する。

## 5. 報告
セッション中の capture・作業に伴う読み書きはユーザーに明示報告（サイレント禁止＝[[Preferences/vault-operation]]）。**例外＝定常メンテナンス（Fragments 昇格・棚卸し対処）は個別報告不要**（監査はレポート・git 履歴・Fragments の実施記録で担保）。

**Why:** 種を都度の声かけで消さず、未確定の断片を時系列で残し、確定したものだけ昇格させる。記事構想は AI が Fragments を素材に組み立てる（[[Preferences/note-canvas-workflow]]）。即時 capture は後追いの記憶劣化・文脈喪失を防ぐため。
**How to apply:** 作業の区切りで該当する断片をその場で日次ファイルに短く追記し、教訓が分かったら §4 に従って上げる。記事化依頼時は Fragments を読んで種を束ねる。
