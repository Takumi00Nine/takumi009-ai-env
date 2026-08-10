---
date: 2026-06-14
updated: 2026-08-10
tags: [preference, delegation, codex, reviewer, orchestrator, agent-teams]
project: meta
aliases:
  - "Claudeに残す4つ"
  - "オーケストレーター強制"
---
# 開発の役割分担（Claude中心＋Codex一次レビュアー）
> 背景＝「ループエンジニアリング」の実装（[[Knowledge/loop-engineering]]）。
## 基本構図
- **Claude 本体（リーダー・オーケストレーター）**: ①最終意思決定 ②外部脳記録 ③ユーザー対話 ④実環境が要る結合検証、＋各工程の采配。実装・調査・テスト等の「作る工程」は自分でやらず着手前にワーカーへ委任。
- **モデル割り当て（2026-07-21 本人決定）**: リーダー＝**Fable 5 固定**。**ワーカー/生成物には極力 Fable 5 を割り当てない**（生成＝Sonnet/Opus/Haiku・画像＝Codex・例外＝本人明示のみ）。
- **Claude ワーカー**: 作る工程の実働。`~/.claude/agents/` の7工程ロールを名指しで委任（正本＝[[Preferences/worker-role-prompts]]）。既定 Sonnet 5・**要件定義/設計/採用判定は Opus 5**（[[Decisions/2026-07-25-opus5-upstream-roles]]）。起動は `cct`・チームメイトは in-process（[[Decisions/2026-08-07-teammate-in-process-permanent]]）。
- **Codex＝一次レビュアーが主務**（上限時の代替＝Opus 5＝[[Decisions/2026-08-07-opus5-fallback-reviewer]]）。実装・調査の委任も可＝既定は Claude ワーカーのまま「上限余剰・得意分野・本人指定」で裁量（[[Decisions/2026-07-23-codex-delegation-reopened]]）。**ビジュアル素材生成（画像・3D/Blender・ボクセル）は最初から Codex（gpt-5.6-sol）へ一気通貫**（[[Decisions/2026-07-21-image-tasks-codex-end-to-end]]・最終検収は Claude・⚠️独立チェックは本人評価か Claude レビュー）。
## 工程フロー（正本＝[[Preferences/codex-review-protocol]]）
各工程で**ワーカーが成果物作成＋Codex一次レビューを自分で回して修正（worker-driven）→リーダーが却下希望の採否と全体確認→ユーザー最終レビュー**。締め（tester 検証後・本人レビュー前）は2ゲート必須: ①**工程横断の全体構成レビュー**（Codex・手順＝正本「工程横断・全体構成の最終レビュー」）②**リーダーの本番経路 end-to-end スモーク**＝テスト環境と異なる実行環境（launchd/cron・別PATH/権限等）の成果物は**本番と同じ起動経路で最低1回通し実走**してから「完了」と言う（初回実走は本人が見ている場で）。
## 運用ルール
- **着手時のループ適用判定（2026-07-21 本人指示）**: まとまったタスクの着手前に「ループ型（自動検証で回す）か・人間チェック挟み込み型か」を判定し**本人に確認してから進める**。基準＝**ゴールが機械的に計測・数値化できるか**（テスト/リント/型/バイト一致＝向く⇔主観のみ＝向かない）。詳細・聞き方の例文＝[[Knowledge/loop-engineering]]。
- **本人を呼ぶときは `cmux notify --title "📣 <用件>"` を明示発行**（📣なしは届かない。正本＝[[Preferences/cmux-notifications]]）。見せる成果物は cmux ペイン表示してから依頼（`~/work/dotfiles/cmux/show-review.sh`。例外＝Vault ノート・Explorations/ HTML＝Obsidian で見る＝テキスト報告のみ）。
- **Fable 節約＝セッション分割の徹底（2026-08-10 本人決定）**: 工程・トピックが変われば新セッション、長丁場は `/compact`、リーダーは大物（成果物全文・長ログ）を読まずワーカーに要約させる。200k 超で `context-size-warn.sh` フックが警告→区切りで本人に分割を提案（[[Decisions/2026-08-10-fable-session-split]]）。
- リーダーの直接編集は delegation-gate v2 が制限: 許可パス＝Vault・`~/.claude`・tmp のみ。他は委任するか理由を明示してマーカー touch（[[Decisions/2026-07-05-delegation-gate-v2]]）。**許可パス内でも、テスト・デバッグの反復（書く→動かす→直す）が見込まれる実装は委任する**（リーダー直接は1〜2編集で完結する変更まで。判定目安＝「動かして確認する必要があるか」＝[[Decisions/2026-08-10-delegate-iterative-work]]）。
- ワーカー/チームメイト起動時は軽量版ブートストラップ（absolute-rules のみ必読・Vault 書込禁止＝申告制・obsidian-mcp 不使用）。フル版・Vault 書込はリーダーのみ。
- 合議＝後戻りコスト高の設計・技術選定のみ: リーダーが論点定義→ワーカー＋Codex が案+根拠+リスク→リーダー統合・決定（委任除外は設けない）。
## コード作成の前提（トリアージ・共通化ファースト）
- **書く前のトリアージ（2026-08-01 本人指示・恒久）**: コード作成が必要になった時点で（都度スクリプトも対象）①**既存確認**（[[Knowledge/tools-inventory]]・`~/work/tools/`）→②**三択を本人に提案**（既存拡張/新規/使い捨て）→③本人不在時のみ使い捨て暫定可・**帰還時に必ず報告**（[[Decisions/2026-08-01-code-writing-triage]]）。
- **共通化ファースト分解（2026-07-21 本人発案・恒久）**: プロジェクト専用ツールは原則作らない＝**「汎用エンジン（tools/）＋プロジェクト固有設定（projects/）」に分解**・委任前に共通部分を部品化（Rule of two）・ワーカースクリプトは終業時退避（正本＝[[Preferences/common-first-decomposition]]）。
