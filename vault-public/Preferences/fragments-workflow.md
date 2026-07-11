---
date: 2026-06-23
updated: 2026-07-11
tags: [preference, fragments, blog, workflow, capture]
project: external-brain
related:
  - "[[Decisions/2026-06-23-fragments-fleeting-layer]]"
  - "[[Preferences/vault-operation]]"
  - "[[Preferences/note-canvas-workflow]]"
  - "[[Preferences/blog-writing-nudge]]"
  - "[[Knowledge/external-brain-guide]]"
aliases:
  - "即時capture"
  - "Fragments昇格レビュー"
  - "Fragments"
---

# Fragments：未確定の断片を溜める入口層の運用

`Fragments/` は **AI（Claude）向けの append-only な時系列入口層**。雑多な作業の副産物・気づき・出来事・未確定の断片を漠然と溜める。Vault の3層構造の入口：**Fragments（未確定）→ 確定したら Knowledge/Decisions/Projects/Preferences へ昇格／記事の種は Blog へ**。基本削除しない。

## 1. 何を記録するか（基準）
「全部」ではなく「**後で Claude が使う可能性がある作業上の断片**」に絞る（over-capture は情報過多で逆に使えなくなる）。該当例：
- バグ/トラブルの原因・決定の理由・ユーザーの嗜好/気づき・作業上の発見・失敗/つまずき・未確定アイデア・Blog の種・既存4フォルダへ昇格しそうな断片。

## 2. いつ・誰が（Claude主導・2段構え）
- **①即時 capture**：作業の区切りごとに、その場で短く記録（timestamp＋1〜3行＋関連リンク）。**「最後にまとめて」は避ける**（後でまとめると記憶減衰・文脈喪失・後知恵混入で、細部/迷った理由/失敗経路が落ちる）。
- **②後で整形・昇格判断**：日末や次の機会に表記補正・リンク追加・昇格候補マーク。最初から綺麗に書こうとしない。
- 書込は **Claude のみ**（既存ルール踏襲）。

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
- 状態マーク：`生` / `promoted`（昇格済）/ `published`（記事化済）。

## 4. 昇格・記事化
- **週1昇格（完全自律・2026-07-11〜）**: 毎週月曜 03:30 に昇格候補リストが自動生成される（LaunchAgent `com.takumi009.fragments-log` → `~/.claude/logs/fragments-log/YYYY-MM-DD.md`・**Vault 外**。読まれない人間向け資料を Vault に置かないため）。**生成後の最初のセッションで、AI（リーダー）が昇格判断〜実行（昇格先作成＋`status: promoted`＋相互リンク）まで自律で行う。ユーザーの指示・確認・個別報告は不要**。Vault に残すのは Fragments 日次ファイルへの実施1行（例:「週次昇格: 3件昇格・12件見送り」）のみ。判断基準＝確定した知見のみ昇格・SSOT 矛盾チェック・フォルダ別ルール準拠。昇格しないエントリが多数派で正常。誤昇格は git で可逆。**処理完了の印＝レポートの frontmatter に `processed: YYYY-MM-DD` を1行追記**（frontmatter ブロック内のみ判定・未追記のレポートはセッション開始ヘルス行に「未処理」として表示される）。
- 確定したら4フォルダへ昇格、記事の種は Blog へ（記事化は [[Preferences/note-canvas-workflow]]：Fragments を素材に Canvas → 下書き → ユーザー手直し）。
- **append-only：元エントリは消さない**。昇格先と Fragments を相互リンクし、Fragments 側に `status: promoted`（＋昇格先リンク）を足すだけ。
- 二重管理しない：**Fragments＝履歴/発生文脈／4フォルダ＝現在の確定版／Blog＝人間向け素材**、と役割を分ける。

## 5. 報告
セッション中の capture・作業に伴う読み書きはユーザーに明示報告（サイレント禁止＝[[Preferences/vault-operation]]）。**例外＝定常メンテナンス（週次昇格・棚卸し対処）は個別報告不要**（監査はレポート・git 履歴・Fragments の実施記録で担保）。

**Why:** 種を都度の声かけで消さず、未確定の断片を時系列で残し、確定したものだけ昇格させる。記事構想は AI が Fragments を素材に組み立てる（[[Preferences/note-canvas-workflow]]）。即時 capture は後追いの記憶劣化・文脈喪失を防ぐため。
**How to apply:** 作業の区切りで該当する断片をその場で日次ファイルに短く追記。整形・昇格は後で。記事化依頼時は Fragments を読んで種を束ねる。
