---
date: 2026-06-14
tags: [preference, docs, readme]
project: meta
updated: 2026-11-01
related:
  - "[[Decisions/2026-11-01-rule-relaxation]]"
  - "[[Knowledge/claude-codex-usage]]"
aliases:
  - "README日英併記"
  - "言語ナビ"
---

# READMEはバイリンガル

公開する README は英語と日本語の両方で書く。内部向けは日本語でよい。

**Why:** 公開リポジトリ向けに英語が必要だが、ユーザー自身は日本語で読みたいため。

## 構成
- 公開する README は英日で同じ内容を伝える。言語ナビの有無と2言語の順序は既存の構成に合わせてよい。
- ランタイムのバッジは、実行環境の案内が必要なときだけ任意で付ける。付けたバッジは古くなったら更新する。
- 技術記述（フィールド名・コマンド・パス・環境変数・エンドポイント）は英日で変えない。

**How to apply:** 新規作成・更新時は公開範囲と既存の構成に合わせる。
