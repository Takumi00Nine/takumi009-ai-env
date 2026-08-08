---
date: 2026-06-20
updated: 2026-08-08
tags: [preference, rule, strict, absolute]
project: meta
aliases:
  - "絶対厳守"
  - "非交渉ルール"
---
# 絶対厳守ルール一覧
どのアシスタント（委任先 Codex 含む）も例外なく守る、非交渉のルール。**Codex へ委任する全プロンプトでこのノートを必読**（`mcp__codex__codex`/`codex-reply` の PreToolUse フックで強制＝参照が無いと拒否）。詳細は各リンク先。
1. **ライセンス上パブリック公開不可のアセットは公開しない** — 判断基準は**ライセンス**。購入・入手した3Dモデル（VRM/素体含む）・素材・フォント等、再配布・公開が許されないものを外部取得可能な場所（公開リポジトリ/GitHub Pages 出力/公開 Actions 成果物等）に置かない。公開可ライセンスは公開してよい。派生物はライセンスが許す範囲で public 可（現行アバター＝VN3＝本体再配布禁止・2D派生物は二次創作範囲で可＝[[Preferences/vrm-license-policy]]）。不明・迷う場合は公開せず本人に確認。
2. **リポジトリの public 化はユーザーが自分で実行する** — AIは `gh repo edit --visibility public` 等の public 化操作を代行しない。AIはprivate作成〜pushまで。（[[Preferences/git-workflow]]）
3. **認証情報・シークレットを露出しない** — トークン・鍵・パスワード・`.env` などを、出力・コミット・ログに含めない。
4. **必ずWebで裏取りしてから進める** — 実装・回答・設定変更の前に毎回、一次情報をWebで確認してから着手（推測で進めない）。軽い確認は Claude 本体が WebFetch 直、重い・多方面調査は Claude ワーカーか Codex へ。（[[Preferences/web-verify-before-acting]]）
5. **着手前に公開リポジトリで類似OSS・先行実装を検索する** — 要件定義が固まった段階で GitHub 等を検索し、既存ツールで代替できるなら「作らない」判断を優先。担当は Claude ワーカー。調査先＝[[Knowledge/oss-prior-art-search]]。
> 追加・変更は Claude のみが行う（外部脳の編集者は Claude）。毎回読ませる構成上、項目を増やせば Codex へも自動反映される。
