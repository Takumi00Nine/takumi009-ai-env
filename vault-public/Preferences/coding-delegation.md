---
date: 2026-06-14
updated: 2026-07-08
tags: [preference, delegation, codex, reviewer, orchestrator, agent-teams]
project: meta
related:
  - "[[Preferences/absolute-rules]]"
  - "[[Preferences/codex-review-protocol]]"
  - "[[Preferences/worker-role-prompts]]"
  - "[[Decisions/2026-07-05-codex-reviewer-only]]"
  - "[[Decisions/2026-07-03-sonnet5-worker-delegation]]"
---

# 開発の役割分担（Claude中心＋Codex一次レビュアー）

## 基本構図
- **Claude 本体（リーダー・オーケストレーター）**: ①最終意思決定 ②外部脳記録 ③ユーザー対話 ④実環境が要る結合検証 ＋ 各工程の采配。
- **Claude ワーカー（Agent Teams / Agent ツール・既定 Sonnet 5）**: 実装・調査・テスト等の「作る工程」。`cmux claude-teams` でペイン可視化。委任は**7工程ロール**（`~/.claude/agents/`）を名指し＝[[Preferences/worker-role-prompts]]。
- **Codex ＝ 一次レビュアー専任**（実装・調査は委任しない）。

## 工程フロー（各工程で二段レビュー）
要件定義/設計/開発/テストの各工程で：**ワーカーが成果物作成＋Codex一次レビューを自分で回して修正（worker-driven）→ リーダーが却下希望の採否と全体確認 → ユーザー最終レビュー。** 手順の正本＝[[Preferences/codex-review-protocol]]。

## ユーザーへの提示（cmux ペイン表示）
見せるものは cmux ペインに表示してから依頼（`~/work/dotfiles/cmux/show-review.sh <path-or-url>`）。**対象外＝Vault 内の全ノート**（本人が Obsidian で見る→テキスト報告のみ）。詳細＝[[Decisions/2026-07-05-show-in-cmux-pane]]・[[Preferences/cmux-layout]]。

## オーケストレーター強制（delegation-gate v2）
PreToolUse(`Edit|Write|NotebookEdit`) がリーダーの許可パス外（Vault・~/.claude・tmp・takumi009-web 以外）への直接編集を deny。通過条件・軌道修正法＝[[Decisions/2026-07-05-delegation-gate-v2]]。

## ワーカー/チームメイトの起動時ルール
SessionStart が**軽量版**を注入（absolute-rules のみ必読・Vault 書込禁止＝申告制・obsidian-mcp 不使用）。フル版5ファイルはリーダーのみ。**Vault 書込はリーダーのみ**（[[Preferences/vault-operation]]）。

## 合議
後戻りコスト高の設計・技術選定のみ: リーダーが論点定義→ワーカー＋Codex が案+根拠+リスク→リーダー統合・決定。

## 例外
なし（全プロジェクト共通で通常のワーカー委任体制。委任除外は設けない）。
