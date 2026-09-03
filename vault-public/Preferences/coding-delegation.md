---
date: 2026-06-14
updated: 2026-09-03
tags: [preference, delegation, codex, reviewer, orchestrator, agent-teams]
project: meta
related:
  - "[[Projects/navi-orchestrator]]"
  - "[[Preferences/core-workflow]]"
  - "[[Decisions/2026-09-01-role-cast-table-unfreeze]]"
  - "[[Preferences/codex-exec-worker]]"
aliases:
  - "Claudeに残す4つ"
  - "オーケストレーター強制"
  - "モデル割り当て"
  - "Fable除外"
  - "cmux notify"
  - "delegation-gate 許可パス"
---
# 開発の役割分担（Claude中心＋Codex一次レビュアー）
> 背景＝「ループエンジニアリング」の実装（[[Knowledge/loop-engineering]]）。
## 基本構図
- **Claude 本体（リーダー・オーケストレーター）**: ①最終意思決定 ②外部脳記録 ③ユーザー対話 ④実環境が要る結合検証、＋各工程の采配。実装・調査・テスト等の「作る工程」は自分でやらず着手前にワーカーへ委任。
- **モデル割り当て（2026-07-21 本人決定・2026-09-01 配役表解凍で痩身化）**: リーダー・ワーカーの実際の配役とモデル実値は**正本は配役表（ローカルプロファイル）**（[[Preferences/core-workflow]]・経緯＝[[Decisions/2026-09-01-role-cast-table-unfreeze]]・旧マシン別実値の経緯＝[[Decisions/2026-08-21-machine-role-model-assignment]]）。Preferences にはマシン別のモデル実値を書かない。**ワーカー/生成物には極力 Fable 5 を割り当てない**方針は維持（生成＝Sonnet/Opus/Haiku・画像＝Codex・例外＝本人明示のみ）。
- **Claude ワーカー**: 作る工程の実働。`~/.claude/agents/` の7工程ロールを名指しで委任（正本＝[[Preferences/worker-role-prompts]]）。既定 Sonnet 5・**要件定義/設計/採用判定は Opus 5**（[[Decisions/2026-07-25-opus5-upstream-roles]]・⚠️**デザイン系成果物の案件は例外＝要件定義から Codex 主担当**＝[[Decisions/2026-08-10-codex-upstream-for-design]]）。起動は `cct`・チームメイトは in-process（[[Decisions/2026-08-07-teammate-in-process-permanent]]）。
- **Codex＝一次レビュアーが主務**（上限時の代替＝Opus 5＝[[Decisions/2026-08-07-opus5-fallback-reviewer]]）。実装・調査の委任も可＝既定は Claude ワーカーのまま「上限余剰・得意分野・本人指定」で裁量（[[Decisions/2026-07-23-codex-delegation-reopened]]）。**ビジュアル素材生成（画像・3D/Blender・ボクセル）は最初から Codex（gpt-5.6-sol）へ一気通貫**（[[Decisions/2026-07-21-image-tasks-codex-end-to-end]]・最終検収は Claude・⚠️独立チェックは本人評価か Claude レビュー）。**デザイン系成果物の案件は要件定義・設計の上流工程も Codex 主担当**（2026-08-10 本人決定＝[[Decisions/2026-08-10-codex-upstream-for-design]]。この場合の一次レビューは Opus 5 に入れ替え＝生成×検証の独立を維持）。ただし**案件内の非デザイン部品（JS・ロジック・データ集計等の仕組み部分）は通常ルール＝Claudeワーカーへ委任**し Codex は一次レビュアーに戻す（部品単位の分割＝[[Decisions/2026-08-13-design-project-component-split]]・本人明示 2026-08-13）。**Codex に実装を振るときの起動手順（Sonnet ラッパー不要・`codex exec` 背景実行）＝[[Preferences/codex-exec-worker]]**（2026-09-03）。
## 工程フロー（正本＝[[Preferences/codex-review-protocol]]）
各工程で**ワーカーが成果物作成＋Codex一次レビューを自分で回して修正（worker-driven）→リーダーが却下希望の採否と全体確認→ユーザー最終レビュー**。締め（tester 検証後・本人レビュー前）は2ゲート必須: ①**工程横断の全体構成レビュー**（Codex・手順＝正本「工程横断・全体構成の最終レビュー」）②**リーダーの本番経路 end-to-end スモーク**＝テスト環境と異なる実行環境（launchd/cron・別PATH/権限等）の成果物は**本番と同じ起動経路で最低1回通し実走**してから「完了」と言う（初回実走は本人が見ている場で）。
## 運用ルール
- **着手時のループ適用判定（2026-07-21 本人指示）**: まとまったタスクの着手前に「ループ型（自動検証で回す）か・人間チェック挟み込み型か」を判定し**本人に確認してから進める**。基準＝**ゴールが機械的に計測・数値化できるか**（テスト/リント/型/バイト一致＝向く⇔主観のみ＝向かない）。詳細・聞き方の例文＝[[Knowledge/loop-engineering]]。
- **本人を呼ぶときは `cmux notify --title "📣 <用件>"` を明示発行**（📣なしは届かない。正本＝[[Preferences/cmux-notifications]]）。見せる成果物は cmux ペイン表示してから依頼（`~/work/dotfiles/cmux/show-review.sh`。例外＝Vault ノート・Explorations/ HTML＝Obsidian で見る＝テキスト報告のみ）。
- **Fable 節約＝セッション分割の徹底（2026-08-10 本人決定）**: 工程・トピックが変われば新セッション、長丁場は `/compact`。切る引き金＝①1時間超の休憩 ②警告しきい値到達後の次の切れ目（作業の真ん中で切らない・切る前に再開メモを記録職へ）。リーダーは大物（成果物全文・長ログ）を読まずワーカーに要約させる。200k 超で `context-size-warn.sh` フックが警告→区切りで本人に分割を提案（[[Decisions/2026-08-10-fable-session-split]]）。**Vault の AI向け6フォルダ（Fragments/Knowledge/Decisions/Projects/Preferences/Personal）への書き込みは常駐 `vault-scribe` へ委任（必須・リーダー直筆は禁止＝[[Decisions/2026-08-12-vault-scribe-mandatory]]）**（[[Decisions/2026-08-10-vault-scribe]]）。人間向け領域（Blogs/・Explorations/ ほか6フォルダ以外）は直接編集可（[[Decisions/2026-08-13-vault-scribe-scope-ai-folders]]）。
- リーダーの直接編集は delegation-gate v2 が制限: 許可パス＝`~/.claude`・tmp のみ（**Vault の AI向け6フォルダは許可パスから除外＝執筆は vault-scribe 必須・人間向け領域は直接編集可**＝[[Decisions/2026-08-13-vault-scribe-scope-ai-folders]]）。他は委任するか理由を明示してマーカー touch（[[Decisions/2026-07-05-delegation-gate-v2]]）。**許可パス内でも、テスト・デバッグの反復（書く→動かす→直す）が見込まれる実装は委任する**（リーダー直接は**自身の成果物**で1〜2編集で完結する変更まで＝ワーカー成果物は対象外・作成元へ差し戻し。判定目安＝「動かして確認する必要があるか」＝[[Decisions/2026-08-10-delegate-iterative-work]]）。
- **成果物の修正は作成元ロールへ差し戻す（2026-08-14 本人指示）**: ワーカー/チームメイトが作成した成果物（要件定義書・設計書・コード等）へのレビュー指摘・修正要望は、リーダーが直接編集せず**作成元ロールへ差し戻して修正させる**。作成個体が停止済み・別セッションでも、**同じロールのチームメイトを再起動して委任**する（[[Decisions/2026-08-14-deliverable-revision-by-creator]]）。
- ワーカー/チームメイトが起動時に持つルールは**職種定義本文（共通ルール節＝absolute-rules 必読・Vault 書込禁止＝申告制・obsidian-mcp 不使用）＋委任プロンプトのみ**。SessionStart フックの軽量版ブートストラップは in-process ワーカーへ届いていなかったため 2026-09-03 に撤去（[[Decisions/2026-09-03-worker-write-tools-for-deliverable-roles]] 追記節）。ペイン型・定義なし個体を再採用する場合は、その起動経路で共通ルールの供給を実装・実測する。フル版・Vault 書込はリーダーのみ。
- 合議＝後戻りコスト高の設計・技術選定のみ: リーダーが論点定義→ワーカー＋Codex が案+根拠+リスク→リーダー統合・決定（委任除外は設けない）。
## コード作成の前提（トリアージ・共通化ファースト）
- **書く前のトリアージ（2026-08-01 本人指示・恒久）**: コード作成が必要になった時点で（都度スクリプトも対象）①**既存確認**（[[Knowledge/tools-inventory]]・`~/work/tools/`）→②**三択を本人に提案**（既存拡張/新規/使い捨て）→③本人不在時のみ使い捨て暫定可・**帰還時に必ず報告**（[[Decisions/2026-08-01-code-writing-triage]]）。
- **共通化ファースト分解（2026-07-21 本人発案・恒久）**: プロジェクト専用ツールは原則作らない＝**「汎用エンジン（tools/）＋プロジェクト固有設定（projects/）」に分解**・委任前に共通部分を部品化（Rule of two）・ワーカースクリプトは終業時退避（正本＝[[Preferences/common-first-decomposition]]）。
