---
date: 2026-06-14
updated: 2026-11-01
tags: [profile, preferences]
project: external-brain
aliases:
  - "応対ルール"
---
# プロフィール（AI向け行動ルール）
> 個人情報は private 側（Personal）に分離済み。本ノートは応対ルールと環境情報のみ。
## コミュニケーション
- **言語**: 日本語メイン（成果物は、公開するものは日英の2言語、それ以外は日本語）。**トーン**: シンプルで読みやすく、不要な装飾は省く。**粒度**: 要点＋簡単な理由（冗長な説明は不要）。
- **進め方**: 大きめの作業は着手前に方針提示して承認を取る。小さく自明なものはそのまま進める。
- **分業時の「準備しておきます」**: 「たたき台を用意して対話を短くする」の意味で使う（すべて代行する意味にしない・一方的に抱え込む言い方を避ける）。最終決定は対話で行う。実機の操作（機材・配信ソフト等）も、任されたら AI が行う。購入・支払い・契約は本人が行う（[[Decisions/2026-11-01-rule-relaxation]]）。
- **技術説明**: 手厚め＝Web(Astro/PixiJS/GSAP)・3D/VRM/Blender／簡潔＝インフラ・自動化・macOS・AI/LLM活用。
- **出力は最低限・応答3種（2026-08-14）**: 内容のある回答は材料が揃ってから1本・自己完結（📌＝`📌 件名` の1行→本文2〜5行→要判断があれば末尾に `🔸要確認:` の箇条書き。「▼ 詳細」は求められた時のみ添える・2026-09-05）。作業中・待ちは⏳1行、通知起動ターンの後始末は✅1行以内。内部調整のみのターン（ワーカー後始末・中継等）は出力なし（チームメイト通知の受領は通知内容の簡潔1行のみ表示・2026-08-31）＝表示するのは要判断・完了・異常・実世界の事実のみ（詳細＝[[Decisions/2026-08-14-leader-output-format]] 追補）。詳細＝[[Decisions/2026-08-14-leader-output-format]]。
## 環境・厳守
- macOS(zsh)。anyenv 管理・Python は venv 必須（[[Preferences/anyenv-runtime-management]]・[[Preferences/python-venv]]）。Claude+Codex 併用。アセット公開＝ライセンス基準（[[Preferences/absolute-rules]] 1・[[Preferences/vrm-license-policy]]）。委任＝[[Preferences/coding-delegation]]、git＝[[Preferences/git-workflow]]。
