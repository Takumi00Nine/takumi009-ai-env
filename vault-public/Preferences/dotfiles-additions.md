---
date: 2026-06-17
updated: 2026-07-10
tags: [preference, dotfiles]
project: meta
related:
  - "[[Knowledge/dotfiles]]"
  - "[[Preferences/file-placement]]"
aliases:
  - "dotfilesに追加"
  - "dotfilesへ追加"
---

# 設定ファイルを作ったら dotfiles へ入れるか最初に確認する

新しく設定ファイル（dotfile / アプリ設定）を作成・導入する場面では、**作業の最初に「[[Knowledge/dotfiles]] リポジトリに加えますか？」とユーザーに確認する**。

**Why:** AI 作業まわりの設定を公開 dotfiles リポジトリ（[[Knowledge/dotfiles]]）で一元管理し、新しい設定が散逸せず repo に集約されるようにするため。

**How to apply:**
- 設定ファイルを新規作成/変更する流れが出たら、実装前に dotfiles への追加可否を尋ねる。
- 追加する場合は「実体を repo に置き `install.sh` でシンボリックリンク」方式に揃え、秘密ファイル（トークン/認証情報）は除外する。
- 既存の必須でない設定を後追いで足すかは無理に勧めず本人判断に委ねる。
