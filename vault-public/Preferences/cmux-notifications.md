---
date: 2026-07-05
updated: 2026-08-05
tags: [preference, cmux, notifications]
project: meta
related:
  - "[[Decisions/2026-08-05-cmux-notify-leader-call-only]]"
  - "[[Decisions/2026-07-05-cmux-notifications-actionable-only]]"
  - "[[Knowledge/cmux-cli]]"
  - "[[Knowledge/cmux-cli-reference]]"
aliases:
  - "agentIdleReminder"
  - "📣で呼ぶ"
  - "通知はリーダー呼び出しのみ"
---

# cmux 通知の運用（SSOT）

**方針: 通知の効果（音・バナー・未読リング・ペインフラッシュ）は「リーダーが本人を呼ぶとき」だけ**（2026-08-05 更新。理由＝[[Decisions/2026-08-05-cmux-notify-leader-call-only]]）。それ以外の通知はサイドバー履歴に記録されるのみで、画面・音には一切出ない。

## リーダーの呼び出し運用（必須）
- 本人の判断・レビュー・応答が必要になったら、リーダーは **`cmux notify --title "📣 <用件>" --body "<補足>"` を明示発行**する（タイトル先頭の📣がフィルタの通行証）。
- AI 側の自動通知は鳴らない前提なので、**📣を出さない限り本人には届かない**。呼び忘れはリーダーの失点。

## 現在の設定（実行時に `~/.config/cmux/cmux.json` として展開・ファイル管理）
- `notifications.hooks[0]` id=`sound-only-leader-call` — jq で「タイトルが📣始まり以外」の通知の `sound/desktop/markUnread/paneFlash` を false 化（record は残す）。hook 失敗時は既定挙動にフォールバック。
- `automation.claudeCodeIntegration: true` — Claude 統合通知 ON
- `automation.suppressSubagentNotifications: true` — ワーカー（子エージェント）の通知は抑制
- `notifications.agentTurnComplete: "never"` — 毎ターンの完了通知はオフ
- `notifications.agentPermissionPrompt: true` / `agentIdleReminder: true` — 発生はする（履歴用）が、上記 hook により無音・非表示。

## Codex の通知
- **Codex 自前のターン終了通知は無効化済み**: `~/.codex/config.toml` の `notify` 設定をコメントアウトしてある（cmux とは別経路で毎ターン鳴る挙動を止めるため）。戻す場合は該当行頭の `#` を外す。

## 運用上の前提・注意
- **表示中ワークスペースの通知バナーは自動取り下げ**（default のレガシー挙動）。通知の発火テストはフォーカスを外して行う。
- リーダーにフックイベントが届くには **claude-teams 起動時の `--settings` 注入が必須**（`cct` か entry.sh 経由で起動する。手打ち `cmux claude-teams` 素起動は通知が出ない）＝[[Knowledge/cmux-cli]] ⑦。
- 設定変更は cmux.json 編集＋`cmux reload-config`。
