---
date: 2026-06-14
updated: 2026-07-10
tags: [preference, github]
project: meta
related:
  - "[[Knowledge/claude-codex-usage]]"
aliases:
  - "トークン権限更新URL"
---

# GitHub手動操作はURL提示

リポジトリ作成・権限（PATスコープ/トークン）更新・設定変更など、**ユーザー自身がブラウザ等で行う必要がある操作**を案内するときは、その操作を実行できる**具体的なURLを必ず提示**する。

**Why:** 手順の文章だけだと該当ページを探す手間がかかる。直接URLがあれば即操作できる。

**How to apply:** 「クリックすれば操作画面に着くURL」を添える。用途別の指定URL：
- **トークンの権限更新（permission追加）** → **https://github.com/settings/personal-access-tokens** （ユーザー指定。これを使う）
- リポジトリ作成 → https://github.com/new
- リポジトリの説明/Topics編集 → 対象リポジトリのトップページ右上「About」の⚙️

GitHub MCP (`@modelcontextprotocol/server-github`) は repo作成・説明編集ができない等、MCPで不可能な操作はその旨も明示。トークンのenvを変えた場合はMCP再接続/再起動が必要な点も伝える。関連: [[Preferences/git-workflow]]
