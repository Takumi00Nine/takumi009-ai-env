---
date: 2026-06-14
updated: 2026-07-08
tags: [preference, scheduling, cron]
project: meta
related:
  - "[[Projects/news-report-automation]]"
---

# スケジュール実行ルール

時間指定タスクの使い分け：
- **繰り返し処理 → スケジュール（クラウドルーティン：`/schedule`・RemoteTrigger）**
- **1回だけの実行 → CronCreate**
- **例外：ローカルファイルへのアクセスが必要な繰り返し処理**（Vault 棚卸し・使用率取得等）はクラウドから到達不可のため **LaunchAgent**（[[Knowledge/launchagent-vs-cron-keychain]]。実例＝[[Decisions/2026-07-05-vault-inventory-automation]]・[[Knowledge/claude-codex-usage]]）

※ ただし要件が「セッションを閉じても/PCを切っても動かす」なら、1回だけでもクラウド側（`run_once_at`）を使う。手元起動が前提でよい単発タスクは CronCreate（recurring:false）。

## 1. ローカル実行でよい（端末＋Claude Codeが起動している前提）→ CronCreate
- 一回限り・繰り返し問わずCronCreateを使う。`durable: true`でセッションをまたいで保持。
- ただし **CronCreateはこのClaude Codeセッション/REPLに紐づく**：セッションを閉じる・PCが落ちると発火しない。繰り返しは7日で自動失効。

## 2. セッションを閉じても・PCが落ちていても動かしたい → クラウドルーティン
- `/schedule` スキル、または `RemoteTrigger` ツール（`action: create/list/get/update/run`）で登録。Anthropicのクラウドで実行される。
- cronは**UTC**指定・最小間隔1時間。管理/削除は https://claude.ai/code/routines （削除はAPI不可、Web UIから）。
- **既知の落とし穴**：自動発火したルーティンではMCPコネクタ（Notion等）がメインセッションに読み込まれない。回避策＝プロンプト冒頭で**全タスクをサブエージェント(Task)に委任**する。
- ローカルMCP（例：Codex）はクラウドから到達不可。使うならリモートMCP(OAuth)化してカスタムコネクタ登録が必要。

**How to apply:** 「セッションを閉じても」「PCを切っても」動かす要件ならクラウドルーティン。手元起動中のみでよければCronCreate。事前にToolSearchでスキーマ読み込み。
