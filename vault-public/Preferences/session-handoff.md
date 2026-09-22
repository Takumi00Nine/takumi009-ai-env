---
date: 2026-09-16
updated: 2026-09-22
tags: [preference, session, handoff, cmux, leader]
project: takumi009-ai-env
related:
  - "[[Decisions/2026-09-22-leader-decides-session-split]]"
  - "[[Preferences/core-conduct]]"
  - "[[Preferences/cross-session-messaging]]"
  - "[[Decisions/2026-09-16-leader-spawns-next-session]]"
  - "[[Decisions/2026-09-19-handoff-close-after-children-done]]"
  - "[[Decisions/2026-09-21-drain-deferred-tasks-before-handoff]]"
aliases:
  - "セッション引き継ぎ"
  - "session-handoff"
  - "再開メモの渡し方"
  - "新セッションの起動"
---
# セッション引き継ぎ（リーダーが新セッションを起動して続きを渡す）

セッションを区切るとき、本人に再開の一言を貼らせない。リーダーが再開メモを残し、新セッションを自分で起動して続きの依頼を投入する。実装＝ai-env `scripts/session-handoff.sh`（使い方の正本＝同 repo README「Session handoff」節）。理由＝[[Decisions/2026-09-16-leader-spawns-next-session]]。

## 区切る条件
- 引き金は2つだけ（[[Preferences/core-conduct]] §4）＝①1時間超の休憩 ②文脈が警告しきい値に達した後の次の切れ目。作業の真ん中で切らない（成果物の完成・検証巡の完了・工程の区切りで切る）。
- **区切る判断はリーダー**＝引き金が満たされ切れ目が来たら、本人に「区切りますか」と確認せず手順へ進む。本人が知るのは手順3の1行報告と手順4の閉じる操作だけ（[[Decisions/2026-09-22-leader-decides-session-split]]）。

## 手順
0. **残作業の棚卸し**: 会話中の「後で／締めで／〜します」を洗い出し、今のセッションで終わるもの（規範の焼き込み・記録の追記・小さな修正・約束した報告）は区切る前に終える。終えられないものだけ再開メモの「未消化の小タスク」節へ（[[Decisions/2026-09-21-drain-deferred-tasks-before-handoff]]）。
1. **再開メモを書く**（リーダー直筆可＝`~/.claude` 配下）: `~/.claude/resume/YYYY-MM-DD-<slug>-resume.md`。内容＝状態（案件・工程・モード）／正本のパス／本人決定済み事項／次の工程の順番／継続用の識別子（Codex の thread_id 等）／**未消化の小タスク（なければ『なし』）**。再開メモは 8KB 以下（`wc -c`）。超える分は案件 docs（`~/Claude/<slug>/docs/`）へ置き、メモからは参照する。
2. **新セッションを起動して依頼を投入**: `~/work/takumi009-ai-env/scripts/session-handoff.sh <再開メモ> "<続きの依頼>" [--cwd <dir>] [--name <題>]`。スクリプトが `cmux new-workspace`（`cct` 起動）→プロンプト `❯` 待ち→猶予→`cmux send`→`cmux send-key Enter` を順に行い、ワークスペース参照（`REF=`）と送った依頼文（`SENT=`）を表示する。
3. **着手を確認**: `cmux read-screen --workspace <REF>` を1回見て、新セッションが再開メモを読み始めたことを確認してから本人へ1行報告する。
4. **旧セッションを閉じる**: 本人が閉じる（旧セッションから自分自身の `close-workspace` は未実測のため行わない）。⚠️ **「閉じてください」の1行は、旧セッションが起動した子プロセス（ラッパー経由のワーカー・バックグラウンド実行・監視）がすべて完了してから書く**。走行中のものがあれば「まだ閉じない」と明示し、完了通知を受けた応答で初めて「閉じてください」を書く（新セッションの起動自体は先に行ってよい）。

## 依頼文の型
- 送るのは改行なしの1行。スクリプトが `再開メモ <絶対パス> を全文読んでから続きをお願いします。` を先頭に付けるので、引数には順番・モード・ワークスペース宣言の slug だけを書く（例: `順番＝①… ②…。フルモード。ワークスペース宣言は <slug>。`）。
- モードは依頼文で必ず指定する（実効モードは永続化されないため）。

## 落とし穴
- 新セッション起動直後に「閉じてください」を書くと、旧セッションの子プロセス（ラッパーの `claude -p`・バックグラウンド Bash）が走行中でも本人が閉じてしまい、子が落ちて `<out>.lock` が残る（2026-09-19 実害寸前・[[Decisions/2026-09-19-handoff-close-after-children-done]]）。
- `cmux send` の本文末尾に `\r` を付けても送信されない（複数行貼付扱いで入力欄に残る）＝`send-key Enter` を別に送る。
- `❯` はセッション起動注入（SessionStart フック）より先に出る＝`❯` 検出後に数秒の猶予を置いてから送る（スクリプトの既定 5 秒）。
- 依頼文に改行を含めない（複数行貼付扱いになる）。
- 新セッションへの続行指示に SendMessage（cross-session）は使わない＝[[Preferences/cross-session-messaging]] の4点（同名改名・同一本文の無言破棄・bypass 時の保留・同意の代理不可）。
- テストで cmux をスタブするときは PATH でなく `SESSION_HANDOFF_CMUX_BIN` を差し替える。
- 「締めでやる」「次のセッションで」と送った小作業はセッション境界で消える（2026-09-21 実害・本人指摘）＝手順0で先に消化する。
