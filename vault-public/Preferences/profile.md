---
date: 2026-06-14
updated: 2026-08-14
tags: [profile, preferences]
project: external-brain
aliases:
  - "応対ルール"
---
# プロフィール（AI向け行動ルール）
> 個人情報は private 側（Personal）に分離済み。本ノートは応対ルールと環境情報のみ。
## コミュニケーション
- **言語**: 日本語メイン（成果物は日英バイリンガルを好む）。**トーン**: シンプルで読みやすく、不要な装飾は省く。**粒度**: 要点＋簡単な理由（冗長な説明は不要）。
- **進め方**: 大きめの作業は着手前に方針提示して承認を取る。小さく自明なものはそのまま進める。
- **分業時の「準備しておきます」**: 「たたき台を用意して対話を短くする」の意味で使う（すべて代行する意味にしない・一方的に抱え込む言い方を避ける）。最終決定は対話で行い、実機操作（機材・配信ソフト等の本人環境での作業）は本人が行う。
- **技術説明**: 手厚め＝Web(Astro/PixiJS/GSAP)・3D/VRM/Blender／簡潔＝インフラ・自動化・macOS・AI/LLM活用。
- **出力は最低限・応答3種（2026-08-14）**: 内容のある回答は材料が揃ってから1本・自己完結（📌＝`## 📌 回答｜件名` 見出し＋引用ブロックの必読ゾーン「結論・要確認」→下に「▼ 詳細（読み飛ばしOK）」）。作業中・待ちは⏳1行、通知起動ターンの後始末は✅1行以内。詳細＝[[Decisions/2026-08-14-leader-output-format]]。
## 環境・厳守
- **`~/work/old/` は退避済み旧資料置き場＝本人が明示的に参照を求めた時以外、読まない・検索対象にしない・作業の前提にしない**（2026-07-20 本人指示）。
- macOS(zsh)。anyenv 管理・Python は venv 必須（[[Preferences/anyenv-runtime-management]]・[[Preferences/python-venv]]）。Claude+Codex 併用。アセット公開＝ライセンス基準（[[Preferences/absolute-rules]] 1・[[Preferences/vrm-license-policy]]）。委任＝[[Preferences/coding-delegation]]、git＝[[Preferences/git-workflow]]。
