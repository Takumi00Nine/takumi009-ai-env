---
date: 2026-06-14
tags: [preference, docs, readme]
project: meta
updated: 2026-07-10
related:
  - "[[Knowledge/claude-codex-usage]]"
aliases:
  - "README日英併記"
  - "言語ナビ"
---

# READMEはバイリンガル

README を書く／更新するときは、**英語と日本語の両方**で記述する（バイリンガル）。

**Why:** 公開リポジトリ向けに英語が必要だが、ユーザー自身は日本語で読みたいため。

## 構成ルール（必須）

1. **言語ナビを最先頭に置く**（タイトル・バッジより前）:
   ```
   **English** | [日本語](#日本語)
   ```
2. **バッジを必ず付ける**（言語ナビの直後、タイトルの直後）。プロジェクトに応じた内容で、最低限ランタイムバージョンを示すバッジを1つ以上含める。例:
   ```markdown
   ![Node.js >=18](https://img.shields.io/badge/node-%3E%3D18-brightgreen)
   ![Dependencies none](https://img.shields.io/badge/dependencies-none-blue)
   ```
3. **英語版を先に全文書く**（タイトル〜最後のセクションまで）。
4. `---` 区切り線のあとに `## 日本語` 見出しを置く。
5. **日本語版を後に全文書く**（英語版と同じ章立て・同じ内容）。
6. 技術記述（フィールド名・コマンド・パス・環境変数・エンドポイント）は英日とも変更しない。

## ファイル先頭の雛形

```markdown
**English** | [日本語](#日本語)

# <プロジェクト名>

![<ランタイム>](https://img.shields.io/badge/...)
![<その他>](https://img.shields.io/badge/...)

## Overview
...

---

## 日本語

# <プロジェクト名>

## 概要
...
```

**How to apply:** 新規作成・大幅更新のどちらでもこの構成を維持する。バッジは内容が古くなったら更新する。
