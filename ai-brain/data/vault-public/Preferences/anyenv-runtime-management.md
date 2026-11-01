---
date: 2026-06-16
updated: 2026-11-01
tags: [preference, runtime, anyenv]
project: meta
related:
  - "[[Preferences/python-venv]]"
  - "[[Knowledge/venv-breaks-on-folder-rename]]"
aliases:
  - "jenv"
  - "rbenv"
  - "goenv"
  - "anyenv経由"
---

# 言語ランタイムは anyenv で管理する

**新しい言語ランタイム（Java など）を入れるときは、必ず anyenv 経由でその言語のバージョン管理ツール（*env）を入れてから、それを使ってランタイムを導入する。システムや brew でランタイムを直接入れない。**

- 現状の管理：anyenv 配下に **pyenv（Python）** と **nodenv（Node）** がある（`~/.anyenv/envs/`）。Python/Node はこの仕組みで管理済み。
- 新言語を追加する手順（例）：
  1. `anyenv install <言語env>` で管理ツールを入れる
     - Java → `jenv`、Ruby → `rbenv`、Go → `goenv`、PHP → `phpenv` など
  2. シェルを再読み込み（`exec $SHELL -l` 等）
  3. その *env を使ってバージョンを入れる（例：`jenv add ...` / `rbenv install <ver>` / `goenv install <ver>`）
  4. プロジェクト/グローバルで使うバージョンを `*env local|global <ver>` で設定
- **やらないこと：** `brew install openjdk` や `brew install go` 等で**ランタイム本体を直接**入れる、システムにグローバル導入する、といった anyenv を経由しない入れ方。

**Why:** バージョン切り替え・プロジェクトごとの固定・再現性を anyenv に一元化したい。直接入れると管理が分散し、バージョン衝突や環境破壊の原因になる。Python の venv 方針（[[Preferences/python-venv]]）と同じ「隔離して再現性を保つ」思想。

**How to apply:** 言語ランタイムを足す要望が来たら、まず「anyenv にその言語の *env はあるか」を確認 → 無ければ `anyenv install <env>` → その *env でバージョン導入、の順で進める。anyenv 自体や *env のインストール手順は実施前にユーザーへ確認してもよい。

