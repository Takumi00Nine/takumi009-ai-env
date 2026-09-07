---
date: 2026-09-03
updated: 2026-09-06
tags: [preference, codex, delegation, worker, exec]
project: meta
related:
  - "[[Preferences/coding-delegation]]"
  - "[[Preferences/codex-review-protocol]]"
  - "[[Preferences/absolute-rules]]"
  - "[[Decisions/2026-07-23-codex-delegation-reopened]]"
  - "[[Decisions/2026-09-06-codex-mcp-retire]]"
aliases:
  - "Codex実装ワーカー起動手順"
  - "codex execで直接起動"
  - "Sonnetラッパー不要"
---
# Codex を実装ワーカーとして直接起動する手順（`codex exec` 背景実行）

**2026-09-06 以降、Codex 呼び出しの唯一経路**（MCP 廃止＝[[Decisions/2026-09-06-codex-mcp-retire]]）。一次レビュー委任は `~/work/takumi009-ai-env/scripts/codex-exec.sh` ラッパー経由（正本＝[[Preferences/codex-review-protocol]]）、本ノートの生 `codex exec` の型は実装ワーカー起動用に残す。

用途＝実装を Codex に任せるとき、リーダーが**Sonnet 等のラッパーワーカーを挟まず** Codex を直接ワーカーとして起動する手順。既定の実装担当は引き続き Claude の implementer（[[Preferences/coding-delegation]]）。Codex に振るのは implementer が空席・上限、本人指定、Codex 枠の余剰のいずれか（[[Decisions/2026-07-23-codex-delegation-reopened]]）。

経路は **`codex exec` を Bash の `run_in_background: true` で起動**する。終了時にリーダーへ完了通知が届き、チームメイトの idle 通知と同じ受け取り方になる。

本ノートは委任のたびに Codex に読ませるため**最小サイズを維持**する（起動手順のみ。背景・経緯・他経路の説明は書かない）。レビューの割り当ては正本＝[[Preferences/codex-review-protocol]]。

実測環境＝codex-cli 0.144.6・2026-09-03・メイン機。

## 起動の型（実測済み）
```bash
codex exec --skip-git-repo-check -s workspace-write -C /abs/path/to/target \
  --json -o /abs/path/report.md \
  -c 'developer_instructions="<agents/implementer.md の本文をそのまま貼る>"' \
  '<依頼文>' </dev/null > /abs/path/events.jsonl 2> /abs/path/stderr.log
```
- **`</dev/null` は必須**。無いと Codex が stdin の追加入力を待ち続けて止まる（実測＝5分タイムアウト。Bash ツールは stdin が開いたままのため）。
- **`run_in_background: true`** で起動し、完了通知で受け取る。結果は `-o` のファイルだけ読む（events.jsonl は読まない＝リーダーの文脈を小さく保つ）。
- **`-C` は変更対象ディレクトリの絶対パスに最小化**。ホーム全体は渡さない。`--skip-git-repo-check` は git 外の cwd で必須。
- **依頼文は argv でなく stdin 経由で渡し、positional は `-` 固定にする**（先頭がハイフンの依頼文の誤解釈と ARG_MAX を避ける。ラッパー `scripts/codex-exec.sh` はこの型を実装済み）。
- **`-c key=value` は codex がまず TOML として解析し、失敗したときだけ文字列にフォールバックする**。`developer_instructions` のように本文を渡す値は JSON 文字列としてエンコードして渡す（ラッパーが `jq -Rs`／python3 で処理。生で渡すと TOML 型に誤解釈される実バグを 2026-09-06 に実測）。
- ワークスペース外の Vault ノート（例 `absolute-rules.md`）は**exec 経路では読める**（実測）。absolute-rules は貼らずにパス指定で読ませればよい。
- **職種定義の注入＝`-c developer_instructions="..."`**（公式設定キー。実測で報告形式の指示が守られた）。`agents/implementer.md` の本文（frontmatter を除く）をそのまま渡す。
- **`--json` の1行目 `{"type":"thread.started","thread_id":"..."}` に thread_id が出る**。継続は次の形（共通オプションは `resume` より前に置く。`--skip-git-repo-check` も再指定が必要＝無いと "Not inside a trusted directory" で失敗）:
```bash
codex exec --skip-git-repo-check -s workspace-write -C /abs/path -o report2.md \
  resume <thread_id> '<続きの依頼文>' </dev/null
```
- **`--ephemeral` を付けると rollout（セッション記録）が保存されず `resume` できない**。継続の予定がある起動では付けない（公式 CLI リファレンス 2026-09-06 確認）。
- 直近スレッドの継続は `codex exec resume --last '<依頼文>'` でも可（thread_id を控え損ねたときの救済。並列起動中は取り違えるので thread_id 指定を既定にする）。
- **依頼文に必ず入れる内容は Claude ワーカーと同じ**: ①absolute-rules を読む指示（**exec は PreToolUse フックの対象外**なので手動で明記。[[Preferences/absolute-rules]]）②承認済み設計 ③担当ファイル範囲 ④受入条件 ⑤Vault 書込禁止と「Vault記録候補:」での申告 ⑥報告形式（変更ファイル一覧→動作確認手順→受入条件との対応→未解決点）。
- **1呼び出し＝1工程・15分以内で返る粒度に切る**。大きい実装は resume で分割。
- **背景起動した exec は Bash の10分上限に縛られず走り切る**（公式仕様）。止まるのは①前景サブエージェントから起動した場合（その最終応答時）②セッション終了 ③`</dev/null` 忘れ、の3つだけ。
- モデルと effort は `~/.codex/config.toml` の既定（sol・medium）。変えるときは `-m` と `-c model_reasoning_effort=`。xhigh は使わない（[[Decisions/2026-08-07-avoid-xhigh-effort]]）。
- stderr に "Reading additional input from stdin..." が出るのは `</dev/null` の EOF 読みで、正常。
