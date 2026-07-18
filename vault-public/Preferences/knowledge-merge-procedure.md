---
date: 2026-07-12
updated: 2026-07-18
tags: [preference, external-brain, merge, procedure]
project: external-brain
aliases:
  - "マージ手順書"
  - "自律マージの手順"
  - "knowledge_merge_candidates.py"
---

# Knowledge 自律マージの現行フロー（AI 向け・簡素化後）

Knowledge の重複ノートの統合は、**夜間メンテ（maintenance.sh）の Phase 2 で夜間 Claude が自律実行**する。2026-07-16 簡素化で**旧 `knowledge_merge.py` CLI・worktree・evidence/verdict・手動リーダー手順は全廃**した（正本＝[[Decisions/2026-07-16-simplification-item-cleanups]] #8 ＋ [[Decisions/2026-07-16-nightly-batch-direct-write]]）。責任分担の位置づけ＝[[Knowledge/external-brain-maintenance-split]]（A＝夜間自律）。

## 現行フロー（無人・週次）
1. **検出（Phase 1）**: `knowledge_merge_candidates.py`（**キーワード系類似**＝alias・タイトルトークン・タグ・outbound link の重なり）が Knowledge 同フォルダの重複候補を出す。
2. **マージ（Phase 2）**: 夜間 Claude が**明白な重複だけ**を非破壊マージ。
   - 統合ノートを新規執筆・**原ノート2件は `superseded_by` 付きスタブ化**（削除しない）。
   - **週上限2件**。少しでも論点が違う／矛盾する／片方の主張が消えると感じたら**見送り**（見送っても候補は state.json 上で **pending のまま残り**、明示的にマージされるまで消えない＝**翌週以降も再提示され得る**。※PROMOTE の Fragments 昇格＝one-shot とは異なり、MERGE 候補は**永続**）。
   - **機械ゲート（`merge_checks.py`）が構造保存を検査**＝見出し文字列の不変・コード/URL/日付の不変・aliases 和集合・frontmatter 必須キー・リンク切れ無し。1つでも満たさなければ統合ノート不採用（原ノートは変更されない）。
3. 実施は週次サマリに1行（Fragments）。個別報告なし。

## 規約の正本と人間の関与
- **マージ規約の正本**＝夜間 Claude への指示文（`maintenance_apply.py` の `build_system_prompt` の merge 節）＋ `merge_checks.py`（構造ゲート）。本ノートはその人間向け概観。
- ルーチンのマージは**無人**＝リーダー/本人は原則ノータッチ。
- **revert は人間判断**（コミット後に欠陥発覚時のみ・git 履歴から）。原ノートは非破壊スタブ化なので復元可能。

## ⚠️ 旧方式は使わない（deprecated 2026-07-16）
`knowledge_merge.py`（preflight/worktree-setup/draft/evidence/gate/commit/skip/unskip/reconcile/revert 等のサブコマンド・週上限1件・敵対的 Codex verdict）は**削除済み**。過去の手順書はこの CLI を前提にしていたが撤去した。**この CLI・手順・週次レポートの `processed` マーカー運用は現行では存在しない**（旧レポート文言に残っていたら順次是正）。
