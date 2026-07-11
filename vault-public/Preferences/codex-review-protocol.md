---
date: 2026-07-05
updated: 2026-07-10
tags: [preference, codex, review, delegation, protocol]
project: meta
related:
  - "[[Preferences/coding-delegation]]"
  - "[[Preferences/absolute-rules]]"
  - "[[Knowledge/codex-mcp]]"
  - "[[Knowledge/cmux-cli]]"
  - "[[Decisions/2026-07-05-worker-driven-codex-review]]"
  - "[[Decisions/2026-07-05-codex-reviewer-only]]"
aliases:
  - "レビュー委任プロトコル"
  - "worker-driven呼び出し方"
---

# Codex 一次レビュー委任プロトコル（SSOT）

役割分担の全体像は [[Preferences/coding-delegation]]。本ノートはレビュー実行手順の正本。

## 呼び出し方（worker-driven）
- **呼び出すのは成果物を作ったワーカー自身**（[[Decisions/2026-07-05-worker-driven-codex-review]]。リーダー中継はコンテキスト浪費・直列化のため廃止。リーダー自身の成果物や工程横断の総括レビューはリーダーが呼ぶ）。
- `mcp__codex__codex`。**`sandbox: "read-only"`**（指摘はテキストで受領し反映は作成者。書込不要）。`cwd` はレビュー対象に合わせる。
- プロンプト＝レビュー対象（**ファイルパスで読ませる**。検索させない）＋レビュー観点＋出力形式（指摘リスト：重大度・根拠・修正案）。
- **[[Preferences/absolute-rules]] を必ず読ませる**（`mcp__codex__codex`/`codex-reply` の PreToolUse フックで強制＝呼び出し元を問わず参照なしは拒否）。

## レビュー対象範囲
開発4工程（要件定義/設計/開発/テスト）＝必須。researcher の調査報告・adoption-critic の判定案＝原則乗せる。operator の巡回報告＝対象外。

## 自己レビューバイアスのガードレール
ワーカーは最終報告に指摘の**全リストを省略せず**載せ、各指摘に「修正済み／却下希望＋理由」を付ける。自明な指摘の修正はワーカーが実施してよいが、**却下の最終採否はリーダー**。

## 失敗時・スレッド運用
- 失敗時: 1回目=情報補完して `codex-reply` 継続／2回目=再分割。**Ctrl-C しない**（ワーカーは詰まったら中断せずリーダーへ報告。rollout ログ回収はリーダー＝[[Knowledge/codex-mcp-cancel-desync]]）。
- 継続 vs 新規: 同一成果物の再レビュー=継続、別成果物・最新ルール反映時=新規（ワーカーは自分の成果物1本＝1スレッドで完結）。

## 環境と実行可否
- **ペイン型でも worker-driven 可能**: 接続には `~/.claude.json` の codex 定義を bare コマンドでなく nodenv shim の絶対パスにしておく必要がある（bare command は起動シェルによって PATH に anyenv が乗らず接続に失敗し得るため）。worker-driven は環境を問わず全ワーカーの正規ルート。詳細＝[[Knowledge/cmux-cli]]。MCP 定義の bare command は今後全面禁止が安全。
- **注意**: `~/.claude/agents/*.md` のツール変更は**既存セッションのチームメイトに反映されない**（spawn 時点で固定）。ルール改定直後はフォールバックが要ることがある。
- **フォールバック**: ワーカーが Codex を使えない場合（旧定義個体・接続一時障害等）は、最終報告に「Codex レビュー未実施（ツール不可）」と明記→**リーダーが代行レビュー**→反映はワーカーへ差し戻し（軽微ならリーダー実施）。

## その他
- Vault 書込は**リーダーの Claude のみ**（Codex・ワーカーは申告→リーダー代筆＝[[Preferences/vault-operation]]）。Codex はクラウド routines 不可。
