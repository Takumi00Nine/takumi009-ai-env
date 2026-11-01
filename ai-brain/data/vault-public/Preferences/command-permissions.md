---
date: 2026-06-15
updated: 2026-11-01
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

# コマンド許可の方針（共通の本人ゲートと Claude 固有設定）

**共通の本人ゲート**：[[Preferences/core-conduct]] §3 と [[Preferences/absolute-rules]] に従う。git の commit・push は [[Preferences/git-workflow]]。ツールが自動許可しても、規則上必要な本人同意を省略しない。Codex の `approval_policy=never` も本人同意を省略してよい意味ではない。

以下の権限設定とプロンプトの説明は Claude 固有。許可設定の正本は `~/.claude/settings.json` で確認し（適用先の `settings.local.json` に上書きがあれば併せて確認する）。現行の列挙や件数を本ノートへ複写しない。

**How to apply:**
- 自動許可してよい例：`ls` `pwd` `cd` `cat` `which` `file` `stat`、git の参照系（`git status` `git diff` `git log` `git branch` `git show` `git fetch` `git rev-list`）、`log show`、`system_profiler` など状態確認系。
- **read-only 組込みは allow 不要**：Claude Code は `ls cat echo pwd head tail grep find wc which diff stat du cd` と git 参照系を「read-only 組込み」として全モードで無確認実行する。よって settings.json の `Bash(cat *)` 等の allow は実質冗長（あっても無害）。出典: [Configure permissions](https://code.claude.com/docs/en/permissions)。

## Claude の承認モデル

- Claude の承認モード・`deny`／`ask`／`allow`・sandbox の現行値は上記設定ファイルで確認する。Auto mode の自動判定は共通の本人ゲートの代わりにしない。
- `allow` は定常操作の必要な範囲に絞り、bare `Bash` のような無境界の許可を置かない。Vault の書き手は [[Preferences/vault-operation]] に従う。
- **Auto mode に肩代わりさせないもの**：機密・外部投稿の `deny`、個人ディレクトリの `ask`、公開化禁止・危険コマンドの安全ゲート、必読供給・委任経路のフック。公開化は [[Preferences/git-workflow]]、pip・ランタイムは [[Preferences/python-venv]]・[[Preferences/anyenv-runtime-management]] の規則として守る。
- Claude の `bash-danger-gate` はリモートパイプと HOME／ルートの一括削除を止める。保護パス（Vault・`.claude`・`.codex`・`.cmuxterm`）は、コマンドに再帰 `rm`（`-r` 等）と保護パス名が両方あれば止める（同じコマンドの別の箇所に名前が出ただけでも止まる＝そのときはコマンドを分ける）。`cat` がファイルへ書くだけの heredoc の本文は照合から除く。
- Claude の Agent 起動・委任マーカーは [[Preferences/worker-role-prompts]]「起動形態の既定」を参照する。
- Auto mode のリスク分析・限界・再検討トリガーは private の運用ノートで管理する。
- **注意（実挙動）**：settings.json の **allow（権限付与部分）の自己改変は Auto mode 分類器がブロック**する。allow 変更はユーザー手動か明示承認が要る。

## Claude のフォルダ読み書きの権限モデル

**Bash 読取が無確認になる条件＝パスが `additionalDirectories`（または作業ディレクトリ）内にあること。** `Read(/Users/...**)` の allow は **Bash 読取には効かない**（Read/Glob/Grep ツール専用）。作業ディレクトリ外を Bash で読むと「allow reading from X?」の承認プロンプトが出る。

**deny / ask の効き方は Read/Glob/Grep ツールと Bash とで非対称**（`ask` は Read ツール専用で Bash には効かない、等）。「Bash でも承認付きで読ませたい」フォルダは ask ではなく **additionalDirectories から外す**ことで実現する。評価順は deny → ask → allow で、`Edit(...)` deny は allow より優先（`.claude` 書込許可下でも `.credentials.json` を守れる）。詳細な効き方の表と限界は private の運用ノートで管理する。

**採用した3ティア構成（`~/.claude/settings.json`）：**
- `additionalDirectories` の対象は設定ファイルを正本とする。作業場所の規則は [[Preferences/file-placement]] を参照し、許可対象の一覧と混同しない。
- それ以外のホーム配下＝additionalDirectories外なので **Bash読取は承認プロンプト**、Readツールは `ask` でプロンプト（＝承認すれば読める）。
- 機密の Read/Edit 拒否は設定ファイルの `permissions.deny` を正本とする。allow や additionalDirectories に含まれていても拒否を優先する。

**その他の承認要因**：複合コマンドは `&& || ; | |& & 改行` で分割され各サブコマンドが独立にマッチ要（cd+git は常に承認）。`for`/`while`ループや多文は分解しきれず承認。
- 破壊的操作・公開・金銭・契約・認証の本人同意は冒頭の共通規則に従う。それ以外の承認プロンプトの有無は Claude の権限設定と承認モードによる。
- `find` は `-exec`/`-delete` で破壊的になり得るため自動許可に含めない（読み取り用途でも都度承認）。
- 広すぎる指定（`bash *` `python3 *` 等）は禁止。必要な範囲だけを具体的に許可する。

## パスパターンの落とし穴：単一スラッシュ＝プロジェクトルート相対

`Read()/Edit()/Write()` のパス指定は gitignore 準拠で、**先頭スラッシュ1つ（`/Users/...`）は「絶対パス」ではなく「プロジェクトルートからの相対パス」**と解釈される。出典: [Configure permissions](https://code.claude.com/docs/en/permissions)（"A pattern like `/Users/alice/file` is NOT an absolute path. It's relative to the project root. Use `//Users/alice/file` for absolute paths."）。
- 正しくは **`~/`（ホーム）アンカー**か **`//`（絶対）**を使う。採用：`Edit(~/Data/**)` … `Read(~/**)`。

## `Write()`/`NotebookEdit()`/`Glob()` のパス付きルールは無効（v2.1.210 で起動時警告）

ファイル権限チェックがマッチするのは **`Edit(path)` と `Read(path)` の2形式だけ**。`Write(path)`・`NotebookEdit(path)`・`Glob(path)` のルールは受理はされるが**一度もマッチしない死にルール**で、Claude Code v2.1.210 以降は起動時に1件ずつ警告が出る。出典: [Configure permissions](https://code.claude.com/docs/en/permissions)。
- 書き換え：`Write(docs/**)`/`NotebookEdit(docs/**)` → `Edit(docs/**)`、`Glob(docs/**)` → `Read(docs/**)`（Edit ルールは Write/NotebookEdit 含む全ファイル編集ツール、Read ルールは Glob/Grep もカバー）。
- パス無しのツール名単独ルール（例: deny `Write`）は対象外＝警告なし。
- 本環境では旧 `Write(~/Data/**)` allow がこれに該当（`Edit(~/Data/**)` が既にあるため実挙動は元から同一＝削除しても何も変わらない）。2026-07-20 に削除。
- 注意：`additionalDirectories` は gitignore パターンではなく実ディレクトリパスなので、`/Users/...` の絶対指定で正しく動く（別仕様）。

## settings.json 編集は常に承認プロンプトが出る（仕様・正しい挙動）
`settings.json` / `settings.local.json` への編集は、`Edit(~/.claude/**)` を allow に入れていても**必ず承認プロンプトが出る**。これは Claude Code の**ハードコードされた保護**で、エージェントが自分の権限設定を黙って書き換えられないようにする安全装置（allow より優先）。＝設定ミスではなく、むしろ望ましい。
- `Edit(~/.claude/**)` allow は `.claude` 配下の非 settings ファイルには有効。
- 既知バグ [Issue #41359](https://github.com/anthropics/claude-code/issues/41359)：保護が settings ファイルだけのはずが `.claude/` フォルダ全体を巻き込みプロンプトを出すことがある（害はない）。
- 回避は `"defaultMode": "acceptEdits"` だが編集を広く自動承認するため、この用途では非推奨。

許可設定の置き場所：`~/.claude/settings.json`（ユーザー設定＝全プロジェクト共通）。プロジェクト限定の `settings.local.json` には置かない。

## Auto mode 分類器の観測事実（日付付き・仕様は更新で変わりうる）

- **一度ユーザーが却下したコマンドは、後から口頭 GO があっても分類器が止め続ける**（2026-07-08 実測・例: `gh repo create`）。却下後にやはり実行したくなったら、AI に再試行させず**ユーザーが `!` プレフィックスで直接実行**する。
- **LaunchAgent 設置（plist 配置・load）は「永続化」として明示レビュー要求と判定される**（2026-07-08 実測）。外部公開・永続化系はユーザー実行に回すのが正解。
- **認証情報の実体化はブロックされる**（2026-07-07 実測・正当）: `cmux browser cookies get` → curl への受け渡しは、teammate 依頼経由の無人運転では「user intent 不成立」としてブロック。**無人運転での資産調達は認証不要の公開資産が基本線**・認証つき調達（BOOTH 等）は人間同席時に行う。完全無人化にはユーザーによる限定許可の付与が必要。

## MCP の書込・外部作用系 allow について（再指摘しない）
書込・外部作用系の MCP 操作（外部サービスへの書込・投稿・機器操作など）は **allow に入れない**。「クラウドルーティンの無人実行に local allow が要る」という理由づけは**誤り**で、クラウドルーティンは MCP コネクタ経由で動作しローカルの `permissions.allow` を参照しない（[[Knowledge/cloud-routines-use-connectors-not-local-allow]]）。対話時の書込/外部操作は Auto mode 分類器が判定する（＝確認が出た方が安全）。**レビュー時に「自動化のため auto-allow が必須」と誤って再提案しない。**
