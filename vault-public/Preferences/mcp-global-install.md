---
date: 2026-06-14
updated: 2026-07-08
tags: [preference, mcp, install]
project: meta
related:
  - "[[Knowledge/codex-mcp]]"
---

# MCPサーバーは必ずグローバル導入する

今後、MCPサーバーを導入するときは **必ずグローバル導入する**（`npx -y <pkg>` の都度解決方式は使わない）。

- npm パッケージなら `npm install -g <pkg>` し、`~/.claude.json` の MCP 定義は **node を実体スクリプトに直接向ける**：
  - 例: `"command": ".../bin/node"`, `"args": [".../lib/node_modules/<pkg>/build/main.js", <その他引数>]`
- Python なら専用 venv を作り、その `python` を直接指定する。

**Why:**
- `npx`/`npm exec` は「ラッパー → 実体」の二段構造になり、Claude Code の急終了（強制終了/窓を閉じる等）で実体プロセスが切り離されて**オーファン化・多重起動**する。グローバル導入＋直接起動なら MCP サーバーが Claude Code の直接の子になり終了シグナルが届く。
- 都度ダウンロード/解決が消えて**起動も速くなる**。

**How to apply:** 新しい MCP サーバーを追加する依頼が来たら、`npx` 起動で済ませず、まずグローバル（またはvenv）に導入し、設定では実体バイナリ/スクリプトを直接起動する形にする。既存の `npx` 起動の MCP も同方式へ移行（または不要なら削除）する。MCP を削除するときは、認証情報が設定ファイルに残置されていないか必ず確認する（残っていればプロバイダ側で失効も行う）。
