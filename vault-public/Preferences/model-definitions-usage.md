---
date: 2026-09-18
updated: 2026-09-21
tags: [preference, model, catalog, quick-reference]
project: meta
related:
  - "[[Preferences/model-catalog]]"
  - "[[Preferences/model-definitions-sample]]"
  - "[[Preferences/core-workflow]]"
  - "[[Decisions/2026-09-18-cast-candidates-revision]]"
  - "[[Decisions/2026-09-19-ai-env-optimization-rulings]]"
  - "[[Decisions/2026-09-21-fable-max-explicit-only]]"
aliases:
  - "定義名の早見表"
  - "どのモデル定義を選ぶか"
  - "モデル定義 用途"
---
# モデル定義の用途早見表
定義の正本は repo の `config/models.conf.sample`（コピー先 `~/.config/takumi009-ai-env/models.conf`）。
特性・経路の詳しい比較は [[Preferences/model-catalog]]。
本ノートは「候補列からどれを選ぶか」を1行で引くための早見表＝機械は読まない（機械可読の属性拡張は 2026-09-18 に不採用）。候補列に優先度は無く、軽い依頼では軽い候補を選び、崩れたら重い候補へ戻す。
- fable-max は本人の明示指示があるときだけ（[[Decisions/2026-09-21-fable-max-explicit-only]]）。fable-high は上流工程の候補として現状どおり。

| 定義名 | モデル／effort | 消費する枠 | 配役表で参照する職種（2026-09-18時点） | 向く場面 |
|---|---|---|---|---|
| fable-high | Fable 5.1 / high | Claude サブスク | leader・adoption-critic・researcher | リーダー既定。高度な採用判定 |
| fable-max | Fable 5.1 / max | Claude サブスク | （未参照） | 上流工程で判断の質を最優先するとき。**本人が明示したときだけ使う（リーダーは自動で選ばない・配役表に載せない）**＝[[Decisions/2026-09-21-fable-max-explicit-only]] |
| opus-high | Opus 5 / high | Claude サブスク | requirements-analyst・system-designer・adoption-critic・verifier・implementer | 要件・設計・検証の主力候補。実装では Sonnet との実測比較用 |
| opus-medium | Opus 5 / medium | Claude サブスク | implementer | 標準的な実装・設計の下読み |
| opus-low | Opus 5 / low | Claude サブスク | （未参照） | 並列の軽作業・枠温存 |
| sonnet-high | Sonnet 5 / high | Claude サブスク | implementer・researcher・operator | 実装・調査の主力 |
| sonnet-medium | Sonnet 5 / medium | Claude サブスク | implementer・researcher・operator | 通常の実装・調査（主力候補の入口） |
| sonnet-low | Sonnet 5 / low | Claude サブスク | operator・vault-scribe | 探索的調査・定型の巡回・記録 |
| haiku | Haiku 4.5（effort非対応） | Claude サブスク | researcher・operator・vault-scribe | 分類・抽出・定型変換・短い執筆（初回は軽い案件で試す） |
| codex-astra-high／medium／low | GPT-6 Astra | Codex サブスク | astra-low＝requirements-analyst・system-designer | デザイン系案件の上流工程限定（2026-09-05） |
| codex-sol-high／medium／low | GPT-5.6 Sol | Codex サブスク | sol-high＝verifier・sol-medium＝implementer | 一次レビューの本命・bounded task の実装 |
| codex-terra-high／medium／low | GPT-5.6 Terra | Codex サブスク | terra-medium＝verifier | 文書・軽量1巡の検証（Sol はコード検証に温存） |
| codex-luna-high／medium／low | GPT-5.6 Luna | Codex サブスク | （未参照） | 抽出・分類・構造化要約の高頻度タスク |

legacy／bedrock-*／mantle-* 定義は 2026-09-19 に models.conf から削除（Bedrock・mantle のコードは休眠・将来サブ機で復活＝[[Decisions/2026-09-19-ai-env-optimization-rulings]]）。

候補列の現行値は配役表（`config/profile.md.sample`）が正本。見直しの経緯＝[[Decisions/2026-09-18-cast-candidates-revision]]
更新の掟＝配役表か models.conf を変えたら本ノートの該当行も同じ案件で直す。
Codex 定義の effort は `max` まで通る（2026-09-18 実測・gpt-5.6-sol・受理と解決の両方を確認）。
