---
date: 2026-07-07
updated: 2026-07-10
tags: [preference, ai-build-loop, orchestration, human-gate]
project: ai-driven-workflow
related:
  - "[[Decisions/2026-07-06-ai-build-loop-v1]]"
  - "[[Knowledge/three-layer-orchestration]]"
  - "[[Projects/ai-driven-workflow]]"
aliases:
  - "以上です方式"
  - "request.md代筆"
---

# ai-build-loop 進行役の運用ルール

進行役（リーダー Claude）が人間ゲートを中継する際の取り決め。スキル本体（SKILL.md）は実行者向けの手順であり、人間↔進行役の会話プロトコルはここが正本。

## 「以上です」方式（代筆資料の確定合図）
- **対象＝人間の意向を進行役が代筆する資料**: 依頼資料（`request.md`）・成果物評価資料（`revisions/evaluation-<CYCLE>.md`）。
- 人間は会話で内容を複数回に分けて出してよい。進行役は逐次代筆・蓄積し、**人間が「以上です」（相当の完了宣言）を言うまで実行者へ渡さない**（起動・再開・評価送付をしない）。
