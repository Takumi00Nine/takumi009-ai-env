---
date: 2026-06-14
updated: 2026-07-18
tags: [preference, delegation, codex, reviewer, orchestrator, agent-teams]
project: meta
aliases:
  - "Claudeに残す4つ"
  - "オーケストレーター強制"
---

# 開発の役割分担（Claude中心＋Codex一次レビュアー）

## 基本構図
- **Claude 本体（リーダー・オーケストレーター）**: ①最終意思決定 ②外部脳記録 ③ユーザー対話 ④実環境が要る結合検証、＋各工程の采配。実装・調査・テスト等の「作る工程」は自分でやらず、着手前にワーカーへ委任する。
- **Claude ワーカー（Agent Teams / Agent ツール・既定 Sonnet 5）**: 作る工程の実働。`~/.claude/agents/` の7工程ロール（要件定義/設計/実装/テスト/調査/運用/採用判定）を名指しで委任する（運用の正本＝[[Preferences/worker-role-prompts]]）。`cmux claude-teams` でペイン可視化。
- **Codex＝一次レビュアー専任**（実装・調査は委任しない＝[[Decisions/2026-07-05-codex-reviewer-only]]）。

## 工程フロー（各工程で二段レビュー）
要件定義/設計/開発/テストの各工程で：**ワーカーが成果物作成＋Codex一次レビューを自分で回して修正（worker-driven）→ リーダーが却下希望の採否と全体確認 → ユーザー最終レビュー**（手順の正本＝[[Preferences/codex-review-protocol]]）。**加えてプロジェクトの締め（全工程完了・tester 検証後・本人レビュー前）に、工程横断の「全体構成（アーキテクチャ）レビュー」を Codex で必須実施**（行レベルとは別レイヤ＝境界/正本整合/状態機械の穴を見る。大規模は別モデルでも2者クロス。手順＝[[Preferences/codex-review-protocol]]「工程横断・全体構成の最終レビュー」）。

## 運用ルール
- 見せる成果物は cmux ペインに表示してから依頼（`~/work/dotfiles/cmux/show-review.sh <path-or-url>`）。例外＝Vault 内の全ノートと Explorations/ の HTML レポート（本人が Obsidian で見る→テキスト報告のみ。HTML は HTML Reader プラグインで表示＝[[Decisions/2026-07-16-obsidian-html-reader-plugin]]）。ペイン表示は Vault 外ファイル・URL 用。
- リーダーの直接編集は PreToolUse フック（delegation-gate v2）が制限：許可パス＝Vault・`~/.claude`・tmp のみ。それ以外は委任するか、理由をユーザーへ明示してマーカー touch（[[Decisions/2026-07-05-delegation-gate-v2]]）。
- ワーカー/チームメイトの起動時は軽量版ブートストラップ（absolute-rules のみ必読・Vault 書込禁止＝申告制・obsidian-mcp 不使用）。フル版はリーダーのみ。Vault 書込はリーダーのみ。
- 合議＝後戻りコスト高の設計・技術選定のみ：リーダーが論点定義→ワーカー＋Codex が案+根拠+リスク→リーダー統合・決定。例外なし（全プロジェクト共通で通常のワーカー委任体制。委任除外は設けない）。
