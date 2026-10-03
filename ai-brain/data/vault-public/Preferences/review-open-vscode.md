---
date: 2026-06-14
updated: 2026-07-10
tags: [preference, review]
project: meta
related:
  - "[[Preferences/command-permissions]]"
aliases:
  - "VS Code自動起動しない"
---

# 確認依頼時のVS Code自動オープンはしない

確認・レビューを依頼するときに、対象フォルダを VS Code で**自動オープン（`code <folder>` の実行）はしなくてよい**。ユーザーが必要なら自分で開く。

**Why:** `code`（アプリ起動＝Apple Events）は Auto mode でも確認が必要な操作になり得るため、自動オープンの利点が薄い。

**How to apply:** レビュー依頼時は**対象フォルダの絶対パスを文中で明示する**にとどめ、`code` の自動実行はしない。
