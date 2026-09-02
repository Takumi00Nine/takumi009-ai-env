---
date: 2026-07-05
updated: 2026-09-02
tags: [preference, delegation, agent-teams, subagent, roles]
project: meta
related:
  - "[[Preferences/coding-delegation]]"
  - "[[Decisions/2026-07-05-worker-stage-roles]]"
  - "[[Decisions/2026-07-05-delegation-gate-v2]]"
  - "[[Preferences/absolute-rules]]"
  - "[[Knowledge/model-param-accepted-vs-resolved]]"
  - "[[Preferences/coding-doc-style]]"
  - "[[Decisions/2026-08-30-doc-body-archive-split]]"
  - "[[Knowledge/claude-effort-delivery-paths]]"
  - "[[Decisions/2026-09-01-doc-rule-bake-into-roles]]"
  - "[[Decisions/2026-09-01-role-cast-table-unfreeze]]"
  - "[[Preferences/core-workflow]]"
aliases:
  - "7ロール運用"
  - "requirements-analyst"
  - "adoption-critic"
---

# ワーカー工程ロール運用（7ロール・agents定義＋本ノートSSOT）

ワーカー/チームメイトへの委任は**工程ロール定義**（`~/.claude/agents/*.md`）を名指しで使う。定義本文＝ロールの行動規範（機械的にシステムプロンプトへ付加・tools/model も適用）、本ノート＝リーダー側の運用ルール。

> **2026-08-07 改定（in-process 恒久化＝[[Decisions/2026-08-07-teammate-in-process-permanent]]）**: チームメイトはペインを持たない（エージェントパネル内で動作）。本ノートの「ペイン実査」（`cmux read-screen`・`list-panes`・ペイン消滅確認）は **`TaskOutput`／エージェントパネル（↑↓選択・Enter でトランスクリプト）での実査に読み替える**。名前付き起動・命名規則（パネル・通知・Feed での判別に引き続き有効）・終了の後始末（停止条件④の実査・終了要求レース注意）は従来通り。ペイン運用に戻した場合（`cct --teammate-mode auto`）のみ原文の手順を使う。

## 7ロール一覧（既定 model: sonnet・**上流3ロール＝claude-opus-5**）

モデル割り当て（2026-07-25 本人決定＝[[Decisions/2026-07-25-opus5-upstream-roles]]）: **requirements-analyst / system-designer / adoption-critic ＝ Opus 5**（判断の質が下流全体に効く上流工程・実行回数少）、他4ロール＝Sonnet 5 のまま。命名規則に従い上流3ロールは `opus-` プレフィックス（例: `opus-system-designer`）。これらは職種定義の既定値であり、実際の配役の正本は配役表（[[Preferences/core-workflow]] §1・[[Preferences/coding-delegation]]）。
| ロール名 | 工程 | 要旨 |
|---|---|---|
| `requirements-analyst` | 要件定義 | 検証可能な受入条件・スコープ外・OSS先行調査（「作らない」提案含む）。**要件定義の成果物は「要件定義書（確定事項のみ）」と「検討経緯（論点・代替案比較・レビュー録）」の2ファイル構成を既定とする**（正本＝[[Preferences/coding-doc-style]] §3・[[Decisions/2026-08-30-doc-body-archive-split]]） |
| `system-designer` | 設計 | 代替案比較（A vs B＋根拠＋リスク）・構成・テスト戦略。合議参加もこれ。**リスク部分（永続状態・人間承認/却下・複数部品連携）は詳細設計まで＝状態遷移(失敗/却下/滞留/復活含む)・source of truth・失敗モードを必ず落とす**（2026-07-18・手戻り前倒し）。**設計成果物は「設計書（確定事項のみ）」と「検討経緯（論点・代替案比較・レビュー録）」の2ファイル構成を既定とする**（正本＝[[Preferences/coding-doc-style]] §3・[[Decisions/2026-08-30-doc-body-archive-split]]。委任プロンプト頼みにせずロール規範側で担保＝2026-09-01 本人指示） |
| `implementer` | 実装 | 担当ファイル範囲限定・既存様式遵守・ユニットテスト併作。**文書改修も対象** |
| `tester` | テスト | 受入条件と1対1突合・追試（自己申告を信用しない）・実行前の破壊的操作チェック |
| `researcher` | 調査（横断） | 裏取り/OSS/作者意図/デバッグ/振り返り分析の5モード。出典URL・確度必須 |
| `operator` | 運用 | ヘルスチェック・障害一次調査・メンテ点検。**診断のみ・破壊的操作は提案止まり** |
| `adoption-critic` | 採用判定（ゲート） | 敵対的レビューで「採用する価値があるか」の判定案。3モード＝着手判定（アイデア・要件定義より前）／採用判定（成果物・外部ツール）／継続判定（運用結果）。**品質レビュー（Codex）とは別軸**・最終決定はリーダー→ユーザー |

補助ロール（7工程外）: **`vault-scribe`**（Sonnet 5・執筆代行）＝リーダーが確定した内容の Vault 書き込み専任。内容の新規判断はしない・Codex 一次レビュー対象外（リーダーが diff 実査）。命名＝`sonnet-vault-scribe`。**常駐可**（セッション中は残置してよい＝その旨本人に明示・セッション終了時に停止）。運用の詳細＝[[Preferences/vault-operation]]・[[Decisions/2026-08-10-vault-scribe]]。

## 職種定義を新設・改訂するときの掟（2026-09-01 本人指示）
職種定義（`~/.claude/agents/*.md`）を新設・改訂するときは、その職種の**成果物種別を確認**し、長寿命文書（設計書・要件書級）を作る職種には出力形式の節へ**「本文（確定事項のみ）＋検討経緯（論点・代替案比較・レビュー録）の2ファイル構成」の1行を必ず含める**（正本＝[[Preferences/coding-doc-style]] §3）。横断ルールは委任プロンプト頼みにせず職種定義側へ焼き込む（実例＝2026-09-01 設計差分書の分割差し戻し＝[[Decisions/2026-09-01-doc-rule-bake-into-roles]]）。

## リーダーが spawn 時に必ず渡すもの（定義には書けないタスク固有分）
1. 背景と目的（会話履歴は引き継がれない前提で書く）
2. 対象パス・**担当ファイル範囲**（ワーカー間のファイル競合防止）
3. 受入条件・完了定義
4. 参照すべき Vault ノート（パスで指定）
5. 報告の上限行数（既定30行）と報告先。**最終報告は SendMessage 必須と毎回明記**（テキスト出力だけだとリーダーに届かずペイン書き置きになる・実績2件 2026-07-12）
6. ツール境界: Web調査だけで足りるタスクは**「Bash/gh 不使用・WebFetch で読む」を明示**（ワーカーの許可リスト外コマンドは承認プロンプトがユーザーへ飛び、作業も止まるため）

呼び方: チームメイト＝「Spawn a teammate using the implementer agent type…」／サブエージェント＝Agent ツールの subagent_type。
7. **配役の指定＝正本は配役表**（コア＝[[Preferences/core-workflow]] §1 spawn 条文・[[Decisions/2026-09-01-role-cast-table-unfreeze]]）。配役表はセッション開始時に読んだ値を使う。`agents/*.md` の `model:` は「指定しなかった場合の既定値」であり、配役表の派生物ではない（二重管理にしない）。
   - 配役表の `model` と職種定義の既定値が一致する職種（現状のメイン機は全職種が一致）では、Agent ツールの `model` パラメータを**渡さない**＝定義側の具体 ID がそのまま効く。渡すと別名（sonnet/opus/haiku/fable の4種しか受理されない）へ置き換えることになり、別名は具体 ID に固定されない（実例 2026-07-27: `model: opus` を明示→定義の claude-opus-5 が当時の既定 Opus へ落ちた）。
   - 配役表が定義の既定値と**異なる**値を要求する場合: `provider=bedrock` の別名（opus/sonnet/haiku/fable）はピン留めが効いている確認が取れていればその別名をそのまま渡す（未確認なら渡さず本人へ上げる＝コア §1 条文④）。`provider=anthropic-api` の具体 ID は Agent ツールの `model` パラメータでは渡せない（別名 enum のみ受理）ため、勝手に別名へ読み替えず「職種定義の `model:` 改訂」か「本人裁定」へ上げる。エイリアスを発明しない。
   - 指定漏れ・別名の誤解決は機構では塞げない（設計書 F-4）。実効モデルの確認＝ワーカー別トランスクリプト（`~/.claude/projects/<プロジェクト>/<セッション>/subagents/agent-*.jsonl`）の `model` フィールドを見る（in-process ワーカーも可・[[Knowledge/model-param-accepted-vs-resolved]]）。ペイン先頭のモデル表記はペイン運用時のみ存在し、in-process（既定）では無い（2026-09-02 実測）。正本はトランスクリプト。命名規則 `<配役>-<職種名>` は判別の補助。
   - 例外＝本人がその場でモデルを明示指定した場合はその指示に従う（従来どおり）。

**モデル指定は「受理された」ことと「意図どおり解決された」ことは別**（詳細＝[[Knowledge/model-param-accepted-vs-resolved]]）。実効モデルの確認手段: リーダー行＝`/status`・ワーカー行（named/cmux・in-process とも）＝ワーカー別トランスクリプトの `model` フィールドが正本。ペイン先頭のモデル表記はペイン運用時のみ存在し、in-process（既定）では無い（2026-09-02 実測）。ピン留め効果が未検証の指定経路（例: settings.json 単体経由）ではエイリアス指定を避け、疑わしければ本人へ確認する。

**リーダーの個別指示と標準プロトコルが矛盾したら着手前に確認（2026-08-01 追加）**: ワーカーは、リーダーからのその場の個別指示（例:「Codex 指摘は転送のみ・反映しない」）が本ノートやロール定義の標準手順（例: worker-driven で自分が反映）と食い違う場合、**どちらに従うか着手前に1行確認**する。個別指示が原則優先。実例＝2026-08-01 W4 が「転送のみ」指示を標準プロトコルで上書き解釈し自分で修正まで実施（結果は良かったが監査の穴になり得る）。

**途中投入の仕様変更は最終レビューで反映確認必須（2026-07-23 本人指摘）**: 作業中のワーカーへ SendMessage で仕様変更を送っても、反映が最後回しになる・取りこぼされる傾向がある。リーダーは最終レビュー時に**変更点が成果物に実際に反映されているかを個別に実査**する（変更で「不要」にした実装・テストの残存も含めて grep で確認）。実例2件（2026-07-23 同一タスク）: ①削除指示した移行コードが残存 ②**差し戻し2点中1点のみ対応し、裁定済みの残り1点を「要リーダー判断」と報告**。対策＝差し戻しは可能なら1メッセージ1論点に絞り、報告には**各点の実装箇所（ファイル:行）の明記を義務付け**て突合する。

## 起動形態の既定＝名前付きチームメイト（2026-07-12 本人指示）
ワーカーは**原則、名前付きチームメイト**（Agent ツールに `name` を付与）で起動する。**命名規則（2026-07-20 本人指示）＝`<モデル名>-<ロール名>`**：名前の先頭に実行モデル、ハイフンの後に**工程ロール名**（7ロール: requirements-analyst/system-designer/implementer/tester/researcher/operator/adoption-critic）。例: `sonnet-implementer`・`sonnet-researcher`・`fable-system-designer`。一覧・通知・ペインで「どのモデルがどの工程か」を一目で判別するため。モデル未指定（既定 Sonnet）でも省略せず `sonnet-` を付ける。末尾に**タスク識別子を任意で付けてよい（リーダー裁量・2026-07-20 本人確認）**: 例 `sonnet-implementer-op-keyframes`。同ロール並行時は衝突回避のため必須。cmux では名前付きだけが分割ペインに表示され、本人が進行を目視できるため。名前なしサブエージェント（in-process・ペインなし）は裏で走って見えない＝既定にしない。例外＝ごく軽い内部検索・数分で終わる単発タスクでリーダーが不要と判断した場合のみ。

**終了の後始末も必須**: チームメイトは使い終わったら必ず停止・消去する（放置しない）。停止条件＝**①作業完了 ②最終報告の受領 ③リーダーのレビューOK（差し戻しなし）④作業していないこと**。④は通知だけで判断せず `cmux read-screen` のペイン実査で「処理中でない」ことを確認する（完了報告を送った後も作業を続けている個体が実在するため。報告≠停止可）。差し戻す可能性がある間は停止しない（コンテキスト保持のまま再指示）。継続対話の予定がある場合は残してよいが、その旨をユーザーに明示する。

停止手順（①〜④が全て揃ってから実行）:
- **ペイン実査の ref の調べ方**: `cmux list-panes` → `cmux list-pane-surfaces --pane pane:<n>` でチームメイト名の surface を特定 → `cmux read-screen --surface surface:<n> --lines <行数>`。**チームメイト名の直接指定は不可**（ref/UUID/index のみ受理＝2026-07-13 実測）。
- **基本**: `idle_notification`（手が空いた通知）を受信→④をペイン実査で確認→shutdown_request を送る（通知前・作業中に送らない＝終了要求レースを避ける）。送信後はポーリングせず `shutdown_approved`/`teammate_terminated` 通知の受信を待ち、受信後にペイン消滅を1回だけ実査して完了。
- **保留からの再開**: 通知受信時点で①〜④が揃わず残置した場合（差し戻しの可能性・レビュー未完・継続対話の予定）は、**その保留理由が消えた時点（差し戻し無し確定・レビューOK・対話終了）を新たな停止トリガー**として、速やかに④の実査→shutdown_request を実行する。`idle_notification` は再送されないため、通知の再受信を待たない。
- **停止後の修正**: 停止・消去済みの個体が作った成果物に修正が必要になったら、**同じロールのチームメイトを再起動して委任**する（リーダーの直接修正は不可＝[[Decisions/2026-08-14-deliverable-revision-by-creator]]）。
- **フォールバック**: 通知が一定期間（目安2〜3分）届かない場合、および SendMessage 非搭載ロール（claude-code-guide 等＝通知が構造的に届かない）も、④の実査で作業終了を確認してから `TaskStop`（task_id にチームメイト名）で手動停止→ペイン1回確認。作業中なら待って再実査（間隔1〜2分＝[[Knowledge/mistakes]]のレース注意と同じ）。
- ペイン消滅の確認前に「消えた」と報告しない。

## 工程フロー接続（coding-delegation の二段レビューに乗せる）
各ロールの成果物 → **ワーカー自身が Codex 一次レビューを回して自明な指摘を修正** → リーダーが却下希望の採否と全体確認 → ユーザー最終レビュー。**品質**レビューロールは作らない（Codex 専任＝[[Decisions/2026-07-05-codex-reviewer-only]]。Codex 使用上限時のみ Opus 5 代替＝[[Decisions/2026-08-07-opus5-fallback-reviewer]]）。`adoption-critic` は品質でなく**価値**（作るべきか・採用すべきか・続けるべきか）を見る別軸のゲートで、Codex 専任と衝突しない。使いどころ: ①着手前（要件定義の前段。requirements-analyst の OSS 調査結果も入力にできる）②成果物完成後・導入候補ツールの採用前 ③運用棚卸し（operator の巡回報告を入力に継続/廃止の判定案）。実環境が要る結合検証はリーダー担当（ロール化しない）。

**Codex の呼び出しは worker-driven**（成果物を作ったワーカー自身が報告前にレビューを回す。指摘全リストの省略なし報告義務・却下の最終採否はリーダー。operator を除く6ロールの定義に手順を埋込済み＝[[Decisions/2026-07-05-worker-driven-codex-review]]。リーダー自身の成果物・工程横断の総括レビューはリーダーが呼ぶ）。

**Codex 一次レビューの対象範囲**: 開発4工程（要件定義/設計/実装/テスト）の成果物＝従来通り必須。加えて **researcher の調査報告と adoption-critic の判定案も原則レビューに乗せる**（軽い単発はリーダー判断で省略可）。**operator の巡回報告は対象外**（リーダー確認のみ。定常巡回に毎回 Codex を挟まない）。

## ユーザー最終レビューの提示
成果物をユーザーに見せるときは cmux ペイン表示（md=プレビュー/HTML・URL=ブラウザ・タブ再利用）。本文＝[[Preferences/coding-delegation]]「ユーザーへの提示」節（SSOT）。

## メンテ
- **`tools:` 許可リストには `SendMessage` を必ず含める**（許可リストを明示すると、書かなかったツールは剥がれる仕様のため。省略すると SendMessage も落ち、チームメイトが最終報告を送れなくなる）。⚠️**組み込みロール `claude-code-guide` は SendMessage 非搭載**（Bash/Read/WebFetch/WebSearch のみ・実測 2026-07-12＝報告は必ずペイン書き置きになり graceful 終了も不可）。チームメイト起動するなら報告はペイン実査前提と割り切るか、SendMessage 持ちの自作ロール（researcher 等）を使う。**shutdown_request への承認応答も SendMessage 経由**のため、欠落個体は graceful 終了もできない→ `TaskStop`（task_id にチームメイト名）で直接停止する。
- ロールの行動規範を変えるとき＝`~/.claude/agents/*.md` を編集。運用（spawn時に渡すもの・フロー）を変えるとき＝本ノートを編集。両方に跨る変更は同時に。
- `~/.claude/agents/` はセッション開始時に読み込まれる。**新規作成・変更は既存セッションに反映されない**（要再起動）。
