---
date: 2026-09-03
updated: 2026-11-01
tags: [preference, codex, delegation, worker, exec]
project: meta
related:
  - "[[Decisions/2026-11-01-agents-md-no-rules]]"
  - "[[Decisions/2026-11-01-rule-relaxation]]"
  - "[[Preferences/coding-delegation]]"
  - "[[Preferences/codex-review-protocol]]"
  - "[[Preferences/absolute-rules]]"
  - "[[Decisions/2026-07-23-codex-delegation-reopened]]"
  - "[[Decisions/2026-09-06-codex-mcp-retire]]"
aliases:
  - "Codex実装ワーカー起動手順"
  - "codex execで直接起動"
  - "ラッパーワーカー不要"
---
# Codex を実装ワーカーとして直接起動する手順（`codex exec` 背景実行）

**Codex 子の起動は `~/Workspace/Tools/takumi009-ai-env/team/connect/codex/codex-exec.sh` 経由のみ**（MCP 廃止＝[[Decisions/2026-09-06-codex-mcp-retire]]）。呼び出し経路は規則として守る。一次レビューの割り当ては [[Preferences/codex-review-protocol]]。

用途＝リーダーが Codex を implementer 等の職種ワーカーとして起動する手順。担当・起動条件は [[Preferences/coding-delegation]] に従う。

親の種類による非同期起動・完了の受け取りは [[Preferences/worker-role-prompts]]「起動形態の既定」を参照する。

本ノートは委任のたびに Codex に読ませるため**最小サイズを維持**する（起動手順のみ。背景・経緯・他経路の説明は書かない）。レビューの割り当ては正本＝[[Preferences/codex-review-protocol]]。

実測環境＝codex-cli 0.144.6・2026-09-03・メイン機。

> **消す作業は任せない（2026-11-01 実測）**＝Codex の実行環境からはゴミ箱（`/usr/bin/trash`）が権限エラー（NSCocoaErrorDomain 513）になる。ワーカーには「消す一覧（絶対パス）」を作らせ、ゴミ箱への移動はリーダーが行う。

## 起動の型
`--role` は初回・継続とも必須。以下のラッパー呼び出しを、上記の非同期起動手順で実行する。

```bash
~/Workspace/Tools/takumi009-ai-env/team/connect/codex/codex-exec.sh \
  --role <職種名> \
  --sandbox danger-full-access \
  --cwd /abs/path/to/target \
  --prompt-file /abs/path/request.md \
  --out /abs/path/report.md \
  --model <選んだモデル> --effort <選んだeffort> \
  2> /abs/path/report.wrapper.log
```

- 完了後は `--out` を読む。events の全文は読まない。
- `--cwd` は担当範囲の絶対パスに最小化し、ホーム全体は渡さない。出力先の親ディレクトリを用意する。
- 初回・`--resume <thread_id>` の継続とも `--role <職種名>` を指定する。継続は同じ職種、改役は新規起動にする。thread_id と終了値はラッパーの出力で確認する。
- ラッパーは新規起動・継続とも、`~/Data/obsidian/Preferences/absolute-rules.md`・`core-worker.md`・`worker-role-<職種名>.md` を全文読む指示を自動で付ける。依頼文へ absolute-rules の参照を手で書く必要はない。
- 職種の本文・権限・出力形式は各 [[Preferences/worker-role-prompts|職種ノート]] を参照する。`--developer-instructions` へ職種本文を切り出して渡す運用は終了する。このオプションは個別案件の入力用に残す。
- 依頼文には承認済み設計・担当ファイル範囲・受入条件・Vault 書込禁止を示す。新しいファイルを追加するときは、その repo の登録表（ai-env なら `core/data/ledger.tsv`）の更新も担当範囲に含める。報告の固有指定があれば添える。
- 大きい作業は工程や成果物の区切りで分ける。継続するときはリーダーが `--resume` を明示する。
- `--sandbox` は必須なので、`--sandbox danger-full-access` を明示する。既定方針は `danger-full-access`（[[Decisions/2026-10-10-codex-sandbox-full-access]]）。担当範囲は依頼文で指定する。
- 画像は `--image <path>`（繰り返し可・`--resume` 併用可）で渡す。Web裏取りが要るときは `--search` を付ける。
- モデル・effort は配役表から選んだ候補を `--model`・`--effort` で渡す。
- 依頼文の stdin 送信、開発指示の文字列符号化、ログ保存はラッパーが行う。
