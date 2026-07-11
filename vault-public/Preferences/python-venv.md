---
date: 2026-06-16
updated: 2026-07-10
tags: [preference, python, venv]
project: meta
related:
  - "[[Knowledge/venv-breaks-on-folder-rename]]"
  - "[[Preferences/mcp-global-install]]"
aliases:
  - "venv未有効ブロック"
  - "グローバルpip禁止"
  - "Python"
---

# Python は必ず仮想環境で実行する

**Python を実行・パッケージ導入するときは、必ず先に仮想環境（venv）を作ってその中で行う。グローバル環境への直接 `pip install` はしない。**

- 新しい Python 作業を始めるときは、まず `python -m venv .venv` で仮想環境を作成し、`source .venv/bin/activate` してから作業する。
- 依存パッケージは **venv を有効化した状態で** `pip install`（または `pip install -r requirements.txt`）する。**システム/グローバルの pip に直接入れない。**
- スクリプト実行も venv の python（`.venv/bin/python` など）を使う。`run.sh` のように `source .venv/bin/activate` してから実行する形にしてもよい。
- `.venv/` は `.gitignore` に入れてコミットしない。

**Why:** グローバルに直接入れると、プロジェクト間で依存が衝突したり、システムPythonを汚染して壊す原因になる。仮想環境ごとに隔離すれば再現性・安全性が保てる。

**How to apply:** Python タスクの最初に venv を用意 → activate → その中で pip / 実行。requirements.txt があるものは venv 内で `pip install -r`。フォルダ名変更で venv が壊れる点は [[Knowledge/venv-breaks-on-folder-rename]] 参照。

**機械的な強制:** `~/.claude/settings.json` の PreToolUse(Bash) フックで、**venv未有効状態でのグローバル `pip install`（`pip`/`pip3`/`python -m pip`）を deny でブロック**する設定済み。許可される例外：venv有効時（`VIRTUAL_ENV`/`CONDA_PREFIX`）、同一コマンド内で `source .../activate` 済み、`.venv/bin/pip`等の明示パス、`uv pip`。`pip list` 等の非installや `python -m venv` 作成は対象外。フックの確認・無効化は `/hooks` から。同ファイルには git公開ガードのフックも併設（[[Preferences/git-workflow]]）。
