---
date: 2026-07-12
updated: 2026-07-15
tags: [preference, external-brain, merge, procedure]
project: vault-hybrid-search
aliases:
  - "マージ手順書"
  - "自律マージの手順"
  - "knowledge_merge.py"
  - "knowledge_merge_candidates.py"
---

# Knowledge 自律マージの実行手順（AI 向け・正本）

週次検出レポート（`~/.claude/logs/knowledge-merge-candidates/`）の「レビュー待ち候補」を、AI（リーダー）がセッション内で自律処理する手順。ツール＝リポジトリ `takumi009-ai-env` の `scripts/vault-agents/knowledge_merge.py`（10サブコマンド）。運用は段階導入（Stage 2a=検出のみ → 故障注入 → 2b=週1件上限 → 実績後に緩和）。

## preflight チェックリスト（毎回・スキップ禁止）

1. `knowledge_merge.py preflight --json` が PASS（未解決 ALERT ラッチ＋候補パスの独立検証）。
2. 敵対的レビュー役（Codex）には**証拠パックの読取と verdict 返答のみ**をさせる（Vault 編集・コマンド実行はさせない）。
3. Vault への書込は AI リーダーのみ。public 化操作はしない。
4. 統合ノート本文に再配布不可アセット・シークレットが混入していないか目視確認。

## 手順A: 週次候補の処理（1件ずつ・週上限1件）

⚠️ **着手順序（2026-07-13 改定・head_moved 予防）**: 候補選定と統合ノート執筆（下記2）を**先に**終わらせてから、`worktree-setup` 以降（1→3→4→5→6）を**一気に連続実行**する。worktree を先に作って執筆に時間をかけると、その間に毎時バックアップが main を進めて commit の ff-only が失敗し（head_moved ALERT）、Codex 再審査まで丸ごと1周やり直しになる（2026-07-13 実例）。窓を数分に抑えれば構造的に防げる。

1. `preflight` → `worktree-setup --candidate-id <id>`
2. 両ノートを読み、**統合ノート本文をリーダーが執筆**→ 一時ファイルへ。執筆時の鉄則（ゲートの構造検査に対応）: **原ノートの見出しは文字列を一字も変えず残す**（階層変更・見出し追加は可）／両ノートの `updated` 日付を本文に明記／aliases は和集合／コードブロック・出典URL 無改変／統合後も約8,000字以内に収まるペアを選ぶ。
3. `draft`（統合ノート配置＋原ノート2件の非破壊スタブ化＋流入リンク張替を worktree に適用）。
4. `evidence` → evidence.json を Codex へ。**証拠パックには原ノート本文が含まれないため、原ノート2件（実 Vault 側）と worktree の統合ノートのパスも読取対象として渡す**（2026-07-12 初回運用で確立）。→ verdict.json は **worktrees ディレクトリ直下**＝`<worktrees-dir>/<candidate-id>.verdict.json`（evidence.json と同じ階層・**worktree フォルダの中ではない**。これが commit の既定参照パス＝2026-07-13 明確化）として保存。**スキーマ厳守（1つでも違うと commit が BLOCK）**:
   - 必須キー: `candidate_id`・`content_fingerprint`（evidence の値を echo）・`verdict`（"approve"/"reject"）・`reason_code`・`rubric_version`（現行 **"1"**）・`model`・`rubric`
   - `rubric` は6項目（`contradiction`/`negation_diff`/`date_diff`/`proper_noun_diff`/`code_block_diff`/**`claim_preservation`**）で、値は **"PASS" か "FAIL" の文字列**（オブジェクト不可）。approve なのに FAIL 混在は拒否される。
   - 編集ミス由来の再ドラフト時は fingerprint が変わる＝**Codex 再審査から**やり直す（古い verdict の使い回しは fingerprint 照合で構造的に不可）。head_moved 復旧の worktree 再作成でも（本文が同一でも）fingerprint は変わる＝同じく再審査。
   - **`codex-reply`（継続スレッド）にも absolute-rules 参照が毎回必須**（PreToolUse フックが拒否する。初回プロンプトだけでは不足＝2026-07-13 実測）。
5. `gate --bench-tsv <検収ベンチ>`（品質ゲート＋ベンチ改ざん検知＋回帰採点）。**検収ベンチの正本＝リポジトリ `takumi009-ai-env-private` の `docs/vault-recall-benchmark.tsv`（27問）**。同フォルダの holdout/negative 系 TSV は別用途（採点者検証・偽陽性測定）でありゲートには使わない（2026-07-13 明確化）。
6. 全 PASS のときのみ `commit --report-id <週次レポートID>`（レポートIDは週次レポートのファイル名の日付部分。例: `~/.claude/logs/knowledge-merge-candidates/2026-07-12.md` → `2026-07-12`）。FAIL 時は原因を読んで修正→再ドラフト→再審査してよいが、**再試行は2回まで**。それでも通らなければ worktree 破棄（コミット無し）→ `skip` で終端化（無限リトライ禁止。skipped は relpath ペア基準の**恒久** tombstone＝内容が変わっても自動では再提案されない。再評価は `unskip` で明示的に行う＝6b）。ツール側の不具合が疑われる場合は当該候補を blocked にし、修正は軽微ならリーダー・大きければ implementer 委任。
6b. **マージしない判断の記録（2026-07-14 追加・skip サブコマンド）**: 候補を「マージ不適」と判断したら `python3 scripts/vault-agents/knowledge_merge.py skip --candidate-id <id> --reason "<理由>"` で終端状態 skipped にする（state.json 直書き・検出側とロック共有。merged/blocked への skip は FAIL・二重 skip は冪等で reason 不変。skipped は relpath ペア基準の**恒久** tombstone＝候補IDに content_hash を含まないため、内容が大きく書き換わっても自動では再提案されない（2026-07-14 実装確認・candidates.py の merge_candidate_state docstring 参照）。**再評価したくなったら `unskip --candidate-id <id> --reason "<理由>"`**（2026-07-15 追加・本人裁定）: skipped→pending へ戻し次回週次検出から再評価対象になる。ガード＝skipped 以外・HEAD 到達可能なマージコミットあり・未解決 ALERT ありは FAIL。skip_reason/skipped_at は消えず unskip_reason/unskipped_at が追記される（監査履歴の温存）。**「今週は週上限で枠が無いだけ」の候補は skip しない**＝pending のまま残して翌週へ持ち越す（この場合その週のレポートに processed は付かず、bootstrap の未処理表示が続くのは残作業ありの正しいシグナル）。
7. `reconcile` は **commit 成功時に自動実行される**（2026-07-12〜。出力 JSON の `reconcile_ok` を確認し、false のときのみ手動で `reconcile` を再実行）。その上で **commit と同一セッション内で必ず**レポートの候補状態欄の更新まで完了させる（commit で終わらない。放置すると次セッションが不整合調査から始まる）。全候補終端（merged/skipped）でレポート frontmatter に `processed: YYYY-MM-DD`（見送り候補は 6b の skip で終端化してから。skip 手段が無かった時期の経緯＝Fragments 2026-07-14）。Fragments 日次に実施1行（例:「Knowledge自律整理(週次): 候補5→マージ1・見送り4」）。個別報告はしない。

## 手順B: 異常時

- gate/verdict の FAIL＝そのまま見送り（正常動作）。git 競合・HEAD 移動・未追跡変更＝ツールが自動で ALERT を生成し**全マージ停止（ラッチ）**。解除は「原因の機械的解消確認＋ALERT に `resolved:` 付与」の両方。head_moved の解消＝worktree 再作成で base_head を更新した上で resolved 付与（2026-07-12 リーダー確認済みの解釈・2026-07-13 実運用で復旧実証）。
- **`resolved:` の値は `YYYY-MM-DD` の日付のみ**（説明文を続けると形式不正で commit がブロックされ続ける＝2026-07-13 実測）。解消の経緯は frontmatter でなく本文に書く。
- 3回/14日を超えて未解決の ALERT は、プッシュ通知ではなく本人との自然な会話の文脈で言及する。

## 手順C: revert（人間判断専用・自動フロー外）

コミット後に欠陥が発覚した場合のみ、リーダーが判断して `revert --candidate-id <id>`（1リバート=1コミット・競合検出時は停止＋ALERT）。

## 制約（変更しない）

対象＝Knowledge/ 同フォルダのみ／原ノートは削除せずスタブ化（`deprecated: true`＋`superseded_by:`）／履歴ノート（Decisions）は対象外／週上限1件（初回のみ実装直後のテスト実施が例外）。
