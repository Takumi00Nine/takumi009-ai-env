---
date: 2026-07-05
updated: 2026-07-10
tags: [preference, delegation, agent-teams, subagent, roles]
project: meta
related:
  - "[[Preferences/coding-delegation]]"
  - "[[Decisions/2026-07-05-worker-stage-roles]]"
  - "[[Decisions/2026-07-05-delegation-gate-v2]]"
  - "[[Preferences/absolute-rules]]"
aliases:
  - "7ロール運用"
  - "requirements-analyst"
  - "adoption-critic"
---

# ワーカー工程ロール運用（7ロール・agents定義＋本ノートSSOT）

ワーカー/チームメイトへの委任は**工程ロール定義**（`~/.claude/agents/*.md`）を名指しで使う。定義本文＝ロールの行動規範（機械的にシステムプロンプトへ付加・tools/model も適用）、本ノート＝リーダー側の運用ルール。

## 7ロール一覧（全て model: sonnet）
| ロール名 | 工程 | 要旨 |
|---|---|---|
| `requirements-analyst` | 要件定義 | 検証可能な受入条件・スコープ外・OSS先行調査（「作らない」提案含む） |
| `system-designer` | 設計 | 代替案比較（A vs B＋根拠＋リスク）・構成・テスト戦略。合議参加もこれ |
| `implementer` | 実装 | 担当ファイル範囲限定・既存様式遵守・ユニットテスト併作。**文書改修も対象** |
| `tester` | テスト | 受入条件と1対1突合・追試（自己申告を信用しない）・実行前の破壊的操作チェック |
| `researcher` | 調査（横断） | 裏取り/OSS/作者意図/デバッグ/振り返り分析の5モード。出典URL・確度必須 |
| `operator` | 運用 | ヘルスチェック・障害一次調査・メンテ点検。**診断のみ・破壊的操作は提案止まり** |
| `adoption-critic` | 採用判定（ゲート） | 敵対的レビューで「採用する価値があるか」の判定案。3モード＝着手判定（アイデア・要件定義より前）／採用判定（成果物・外部ツール）／継続判定（運用結果）。**品質レビュー（Codex）とは別軸**・最終決定はリーダー→ユーザー |

## リーダーが spawn 時に必ず渡すもの（定義には書けないタスク固有分）
1. 背景と目的（会話履歴は引き継がれない前提で書く）
2. 対象パス・**担当ファイル範囲**（ワーカー間のファイル競合防止）
3. 受入条件・完了定義
4. 参照すべき Vault ノート（パスで指定）
5. 報告の上限行数（既定30行）と報告先

呼び方: チームメイト＝「Spawn a teammate using the implementer agent type…」／サブエージェント＝Agent ツールの subagent_type。

## 工程フロー接続（coding-delegation の二段レビューに乗せる）
各ロールの成果物 → **ワーカー自身が Codex 一次レビューを回して自明な指摘を修正** → リーダーが却下希望の採否と全体確認 → ユーザー最終レビュー。**品質**レビューロールは作らない（Codex 専任＝[[Decisions/2026-07-05-codex-reviewer-only]]）。`adoption-critic` は品質でなく**価値**（作るべきか・採用すべきか・続けるべきか）を見る別軸のゲートで、Codex 専任と衝突しない。使いどころ: ①着手前（要件定義の前段。requirements-analyst の OSS 調査結果も入力にできる）②成果物完成後・導入候補ツールの採用前 ③運用棚卸し（operator の巡回報告を入力に継続/廃止の判定案）。実環境が要る結合検証はリーダー担当（ロール化しない）。

**Codex の呼び出しは worker-driven**（成果物を作ったワーカー自身が報告前にレビューを回す。指摘全リストの省略なし報告義務・却下の最終採否はリーダー。operator を除く6ロールの定義に手順を埋込済み＝[[Decisions/2026-07-05-worker-driven-codex-review]]。リーダー自身の成果物・工程横断の総括レビューはリーダーが呼ぶ）。

**Codex 一次レビューの対象範囲**: 開発4工程（要件定義/設計/実装/テスト）の成果物＝従来通り必須。加えて **researcher の調査報告と adoption-critic の判定案も原則レビューに乗せる**（軽い単発はリーダー判断で省略可）。**operator の巡回報告は対象外**（リーダー確認のみ。定常巡回に毎回 Codex を挟まない）。

## ユーザー最終レビューの提示
成果物をユーザーに見せるときは cmux ペイン表示（md=プレビュー/HTML・URL=ブラウザ・タブ再利用）。本文＝[[Preferences/coding-delegation]]「ユーザーへの提示」節（SSOT）。

## メンテ
- **`tools:` 許可リストには `SendMessage` を必ず含める**（許可リストを明示すると、書かなかったツールは剥がれる仕様のため。省略すると SendMessage も落ち、チームメイトが最終報告を送れなくなる）。**shutdown_request への承認応答も SendMessage 経由**のため、欠落個体は graceful 終了もできない→ `TaskStop`（task_id にチームメイト名）で直接停止する。
- ロールの行動規範を変えるとき＝`~/.claude/agents/*.md` を編集。運用（spawn時に渡すもの・フロー）を変えるとき＝本ノートを編集。両方に跨る変更は同時に。
- `~/.claude/agents/` はセッション開始時に読み込まれる。**新規作成・変更は既存セッションに反映されない**（要再起動）。
