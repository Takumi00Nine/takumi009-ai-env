---
date: 2026-06-15
updated: 2026-07-10
tags: [preference, permissions, commands, security, claude-code]
project: meta
related:
  - "[[Preferences/file-placement]]"
  - "[[Preferences/mcp-global-install]]"
  - "[[Preferences/review-open-vscode]]"
aliases:
  - "Auto mode許可方針"
  - "3ティア構成"
  - "additionalDirectories"
---

# コマンド許可の方針（Claude Code）

**原則：リード（読み取り）系コマンドは自動許可してよい。ライト（書き込み・変更・外部通信）系コマンドは必ずユーザーの承認を得る。**

**Why:** 読み取りは実害がなく、毎回の承認が作業のストレスになる。一方で書き込み・破壊・外部送信は取り返しがつかない/影響が大きいので、ユーザーが都度判断したい。

**How to apply:**
- 自動許可してよい例：`ls` `pwd` `cd` `cat` `which` `file` `stat`、git の参照系（`git status` `git diff` `git log` `git branch` `git show` `git fetch` `git rev-list`）、`log show`、`system_profiler` など状態確認系。
- **read-only 組込みは allow 不要**：Claude Code は `ls cat echo pwd head tail grep find wc which diff stat du cd` と git 参照系を「read-only 組込み」として全モードで無確認実行する。よって settings.json の `Bash(cat *)` 等の allow は実質冗長（あっても無害）。出典: [Configure permissions](https://code.claude.com/docs/en/permissions)。

## 承認モデル — Auto mode、OSサンドボックスは無効

- **`permissions.defaultMode: "auto"`**：新規セッションは Claude Code の **Auto mode** が既定。ツール実行ごとに分類モデルが「安全＝自動承認／危険＝ブロック」を判定する。判定順は `deny → ask → allow → 分類器`。
- **OSサンドボックス無効**：Bash 経由の Codex/cloud 別モデル起動などで摩擦が出るため、`sandbox` 設定は使わない（Auto mode の分類判定に一本化）。
- **`allow` は最小9件**：`mcp__codex__codex` / `codex-reply`（Codex 一次レビュー委任=定常 workflow）、`WebSearch` / `WebFetch(domain:*)`（Claude 直取得=定常操作）、`Write(~/Data/**)` / `Edit(~/Data/**)`（Vault 書込=最高頻度の中核操作を決定的に無プロンプト化）、`Skill(schedule/update-config/claude-api)`。それ以外（読取系 Bash・読取/書込 MCP・git 系・launchctl/plutil・workdir 編集・`Read(~/**)`）は Auto mode 分類器が判定（読取/作業ディレクトリ編集は自動承認、書込/外部・git push 等は確認が出る方が安全）。bare `Bash` allow も置かない（無境界の全 Bash 自動許可は穴になるため）。
- **残すもの（Auto mode は肩代わりしない）**：`permissions.deny`（機密 Read/Edit・外部投稿系＝最優先ハードガード）、`ask`（個人ディレクトリ）、全 hooks（gh public 禁止・pip venv・brew runtime・codex absolute-rules・bootstrap・delegation-gate-v2＝直接実装ゲート）、`WebFetch(domain:*)`。
- **残留リスクを承知の上で Auto mode に一本化している**。リスクの分析・限界・再検討トリガーは private の運用ノートで管理する（公開しない）。
- **注意（実挙動）**：settings.json の **allow（権限付与部分）の自己改変は Auto mode 分類器がブロック**する。allow 変更はユーザー手動か明示承認が要る。

## フォルダ読み書きの権限モデル

**Bash 読取が無確認になる条件＝パスが `additionalDirectories`（または作業ディレクトリ）内にあること。** `Read(/Users/...**)` の allow は **Bash 読取には効かない**（Read/Glob/Grep ツール専用）。作業ディレクトリ外を Bash で読むと「allow reading from X?」の承認プロンプトが出る。

**deny / ask の効き方は Read/Glob/Grep ツールと Bash とで非対称**（`ask` は Read ツール専用で Bash には効かない、等）。「Bash でも承認付きで読ませたい」フォルダは ask ではなく **additionalDirectories から外す**ことで実現する。評価順は deny → ask → allow で、`Edit(...)` deny は allow より優先（`.claude` 書込許可下でも `.credentials.json` を守れる）。詳細な効き方の表と限界は private の運用ノートで管理する。

**採用した3ティア構成（`~/.claude/settings.json`）：**
- `additionalDirectories` = 作業6フォルダのみ（`Data`(Vault含む)/`.claude`/`Claude`/`work`/`.codex`/`Codex`）＝Bash無確認読取＋書込allow。
- それ以外のホーム配下＝additionalDirectories外なので **Bash読取は承認プロンプト**、Readツールは `ask` でプロンプト（＝承認すれば読める）。
- secrets（`~/.ssh .aws .gnupg .config .kube .docker Library .zsh_sessions`、`.netrc .npmrc .pypirc .claude/.credentials.json`、`**/.env`）は **Read+Edit を deny**（読み書き遮断）。

**その他の承認要因**：複合コマンドは `&& || ; | |& & 改行` で分割され各サブコマンドが独立にマッチ要（cd+git は常に承認）。`for`/`while`ループや多文は分解しきれず承認。
- 承認を得るべき例（自動許可しない）：`rm`、`mv`（既存の上書き）、`chmod`、`curl`/`wget` など外部通信、`pip install` などインストール系、その他ファイルを変更・生成・削除するコマンド。
  - 例外：git の `add`/`commit`/`push` は本人が CLI で Git を回す方針のため個別に許可済み（[[Preferences/file-placement]] とは別管理）。
- `find` は `-exec`/`-delete` で破壊的になり得るため自動許可に含めない（読み取り用途でも都度承認）。
- 広すぎる指定（`bash *` `python3 *` 等）は禁止。必要な範囲だけを具体的に許可する。

## パスパターンの落とし穴：単一スラッシュ＝プロジェクトルート相対

`Read()/Edit()/Write()` のパス指定は gitignore 準拠で、**先頭スラッシュ1つ（`/Users/...`）は「絶対パス」ではなく「プロジェクトルートからの相対パス」**と解釈される。出典: [Configure permissions](https://code.claude.com/docs/en/permissions)（"A pattern like `/Users/alice/file` is NOT an absolute path. It's relative to the project root. Use `//Users/alice/file` for absolute paths."）。
- 正しくは **`~/`（ホーム）アンカー**か **`//`（絶対）**を使う。採用：`Edit(~/Data/**)` `Write(~/Data/**)` … `Read(~/**)`。
- 注意：`additionalDirectories` は gitignore パターンではなく実ディレクトリパスなので、`/Users/...` の絶対指定で正しく動く（別仕様）。

## settings.json 編集は常に承認プロンプトが出る（仕様・正しい挙動）
`settings.json` / `settings.local.json` への編集は、`Edit(~/.claude/**)` を allow に入れていても**必ず承認プロンプトが出る**。これは Claude Code の**ハードコードされた保護**で、エージェントが自分の権限設定を黙って書き換えられないようにする安全装置（allow より優先）。＝設定ミスではなく、むしろ望ましい。
- `Edit(~/.claude/**)` allow は `.claude` 配下の非 settings ファイルには有効。
- 既知バグ [Issue #41359](https://github.com/anthropics/claude-code/issues/41359)：保護が settings ファイルだけのはずが `.claude/` フォルダ全体を巻き込みプロンプトを出すことがある（害はない）。
- 回避は `"defaultMode": "acceptEdits"` だが編集を広く自動承認するため、この用途では非推奨。

許可設定の置き場所：`~/.claude/settings.json`（ユーザー設定＝全プロジェクト共通）。プロジェクト限定の `settings.local.json` には置かない。

## MCP の書込・外部作用系 allow について（再指摘しない）
書込・外部作用系の MCP 操作（外部サービスへの書込・投稿・機器操作など）は **allow に入れない**。「クラウドルーティンの無人実行に local allow が要る」という理由づけは**誤り**で、クラウドルーティンは MCP コネクタ経由で動作しローカルの `permissions.allow` を参照しない（[[Knowledge/cloud-routines-use-connectors-not-local-allow]]）。対話時の書込/外部操作は Auto mode 分類器が判定する（＝確認が出た方が安全）。**レビュー時に「自動化のため auto-allow が必須」と誤って再提案しない。**
