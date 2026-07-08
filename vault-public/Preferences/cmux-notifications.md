---
date: 2026-07-05
updated: 2026-07-08
tags: [preference, cmux, notifications]
project: meta
related:
  - "[[Decisions/2026-07-05-cmux-notifications-actionable-only]]"
  - "[[Knowledge/cmux-cli]]"
---

# cmux 通知の運用（SSOT）

**方針: アクション可能なときだけ鳴らす**（毎ターンの完了通知はしない。理由＝[[Decisions/2026-07-05-cmux-notifications-actionable-only]]）。

## 現在の設定（`~/.config/cmux/cmux.json`・ファイル管理）
- `automation.claudeCodeIntegration: true` — Claude 統合通知 ON
- `automation.suppressSubagentNotifications: true` — ワーカー（子エージェント）の通知は抑制
- `notifications.agentTurnComplete: "never"` — 毎ターンの完了通知はオフ
- `notifications.agentPermissionPrompt: true` — 許可・質問でブロック中＝判断が必要なとき即通知
- `notifications.agentIdleReminder: true` — ターン終了後約60秒入力待ちが続いたら1回通知（レビュー待ち検知）

## Codex の通知
- **Codex 自前のターン終了通知は無効化済み**: `~/.codex/config.toml` の `notify` 設定をコメントアウトしてある（cmux とは別経路で毎ターン鳴る挙動を止めるため）。戻す場合は該当行頭の `#` を外す。

## 運用上の前提・注意
- **表示中ワークスペースの通知バナーは自動取り下げ**（default のレガシー挙動）。通知の発火テストはフォーカスを外して行う。
- リーダーにフックイベントが届くには **claude-teams 起動時の `--settings` 注入が必須**（`cct` か entry.sh 経由で起動する。手打ち `cmux claude-teams` 素起動は通知が出ない）＝[[Knowledge/cmux-cli]] ⑦。
- 設定変更は cmux.json 編集＋`cmux reload-config`。
