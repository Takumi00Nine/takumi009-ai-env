---
date: 2026-07-05
updated: 2026-11-01
tags: [preference, delegation, agent-teams, subagent, roles]
project: meta
related:
  - "[[Decisions/2026-11-01-agents-md-no-rules]]"
  - "[[Decisions/2026-09-10-leader-free-model-choice]]"
  - "[[Decisions/2026-09-16-rules-bind-to-roles-not-models]]"
  - "[[Decisions/2026-09-10-verifier-lineage-recommended]]"
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
  - "[[Decisions/2026-09-03-worker-write-tools-for-deliverable-roles]]"
  - "[[Preferences/core-worker]]"
  - "[[Decisions/2026-09-06-worker-common-norms-and-delivery]]"
  - "[[Decisions/2026-09-07-three-team-mode-rollout]]"
  - "[[Preferences/model-definitions-sample]]"
  - "[[Decisions/2026-09-08-model-definitions-file]]"
  - "[[Preferences/model-catalog]]"
  - "[[Decisions/2026-09-17-effort-per-role-v2]]"
  - "[[Decisions/2026-09-17-verifier-review-before-tests]]"
  - "[[Decisions/2026-09-17-worker-wrapper-b1]]"
  - "[[Decisions/2026-09-20-roles-config-only]]"
  - "[[Decisions/2026-09-21-test-three-roles]]"
aliases:
  - "9ロール運用"
  - "requirements-analyst"
  - "adoption-critic"
---

# ワーカー工程ロール運用（9職種）

ワーカーへの委任は職種を名指しで行う。職種固有の本文・権限は各職種ノート、本ノートはリーダー側の運用を持つ。モデルは起動時に指定する。Claude の `agents/<職種名>.md` は識別情報・ツール宣言と正本への参照だけを持つ。

> **2026-08-07 改定（in-process 恒久化＝[[Decisions/2026-08-07-teammate-in-process-permanent]]）**: チームメイトはペインを持たない（エージェントパネル内で動作）。本ノートの「ペイン実査」（`cmux read-screen`・`list-panes`・ペイン消滅確認）は **`TaskOutput`／エージェントパネル（↑↓選択・Enter でトランスクリプト）での実査に読み替える**。名前付き起動は 2026-09-17 に例外へ縮小（下の起動形態の節）。ペイン運用に戻した場合（`cct --teammate-mode auto`）のみ原文の手順を使う。

## 9職種の用途と正本

ワーカーモデルは配役表の候補からリーダーが起動ごとに選ぶ。判断目安は [[Preferences/coding-delegation]]・[[Preferences/model-catalog]] を参照する。各ノートの「権限」節が権限の正本。

- [[Preferences/worker-role-requirements-analyst]]：検証可能な要件・制約・スコープ外を定める。
- [[Preferences/worker-role-system-designer]]：要件から方式・構成・テスト戦略を設計する。
- [[Preferences/worker-role-implementer]]：承認済み設計に沿ってコード・文書を実装する。
- [[Preferences/worker-role-test-writer]]：実装者とは別個体で、実装より先に受入テストを書く。
- [[Preferences/worker-role-test-runner]]：指定スイートを実行し、結果を報告する。
- [[Preferences/worker-role-verifier]]：成果物を読んで指摘し、実走結果を受入条件と突合する。
- [[Preferences/worker-role-researcher]]：裏取り・先行実装・作者意図・デバッグ・振り返りを調査する。
- [[Preferences/worker-role-operator]]：稼働状況を診断し、対処案を報告する。
- [[Preferences/worker-role-adoption-critic]]：着手・採用・継続の価値を判定する案を出す。

共通規範は [[Preferences/core-worker]]、Codex の既定sandboxは [[Decisions/2026-10-10-codex-sandbox-full-access]] を参照する。

## 職種定義を新設・改訂するとき
- 全職種共通の決まりは [[Preferences/core-worker]]、文書の分割は [[Preferences/coding-doc-style]] に置き、職種ノートへ複製しない。職種ノートには固有の仕事・入力・権限・出力形式だけを置く。
- Claude の `agents/<職種名>.md` の本文は、`~/Data/obsidian/Preferences/absolute-rules.md`・`core-worker.md`・`worker-role-<職種名>.md` を着手前に全文読む参照だけにする。識別情報・短い用途説明・既存のツール宣言は維持する。
- 成果物を保存する職種には書込手段を与える。Claude のときは `tools:` に `Edit, Write` を含める。
- Claude の定義は installer が `~/.claude/agents/` へ配る。effort は配役表の候補からラッパーが `--effort` で渡す。素材を commit・push し、サブ機は `update-sub.sh` で再生成する。反映はリーダーの新しいターン開始時。
- Codex は `--role <職種名>` を初回・継続とも指定する。ラッパーが上記3ノートの全文読込指示を自動で付ける。継続は同じ職種を指定し、改役は新規起動する。職種本文を `--developer-instructions` に複写して渡さない。

## リーダーが spawn 時に必ず渡すもの（定義には書けないタスク固有分）
1. 背景と目的（会話履歴は引き継がれない前提で書く）
2. 対象パス・**担当ファイル範囲**（ワーカー間のファイル競合防止）。**置き場も指定する**＝成果物そのもの（画像・動画・公開物）は最初から `output/`、途中の資料は `work/<作業名>/`（指定しないと生成物が `work/` にたまる＝2026-11-01 実測・[[Decisions/2026-11-01-doc-management]]）
3. 受入条件・完了定義
4. 参照すべき Vault ノート（パスで指定）
5. 報告の上限行数（既定30行）と報告先。Claude Code のとき：**ラッパー経路の最終報告は `--out` の JSON `result`（リーダーは `jq -r .result` で読む）。SendMessage は子からリーダーへ届かない。名前無し subagent（配役表外）は最終応答で返る**
6. ツール境界を明示する。Claude Code のとき：Web調査だけで足りるタスクは**「Bash/gh 不使用・WebFetch で読む」を明示**（ワーカーの許可リスト外コマンドは承認プロンプトがユーザーへ飛び、作業も止まるため）

Claude Code のとき：呼び方: チームメイト＝「Spawn a teammate using the implementer agent type…」／サブエージェント＝Agent ツールの subagent_type。
7. **配役の指定＝正本は配役表**。配役表の候補からリーダーが選ぶ。選択・起動条件は [[Preferences/core-workflow]] §1 spawn条文に従う。属性の正本はモデル定義ファイル（[[Preferences/model-definitions-sample]]）。名前だけを実効モデルの証拠にしない。判断材料は [[Preferences/model-catalog]] と【使用率】ブロック。Claude Code のとき：ラッパーには選んだ候補の定義名を `--model-def` で渡す。`resolve-candidate` の手動実行は配役表外を名前無しで起動するときだけ。名前は付けない（名前付きの例外時のみ上の命名規則）。Codex のとき：external-cli の既存 `CODEX_ARGS` を所定のラッパーへ渡し、選んだ候補のモデルと effort を `--model`・`--effort` で指定する。
8. Claude Code のとき：**起動と依頼を分ける（常駐基準・2026-09-16 本人決定）**: すべてのワーカーは常駐前提で起動する。起動プロンプトに書くのは「職種の確認・全依頼に共通する制約（上記 5〜7＝報告書式と報告先・ツール境界・配役）・待機指示」だけで、**個別の依頼（上記 1〜4＝背景・対象パス・担当範囲・受入条件・参照ノート）は起動後に SendMessage で渡す**。起動プロンプトに最初の依頼を混ぜない（個体の文脈に最後まで残り、後の依頼まで引きずる）。「単発」の区分は設けない＝要件・設計も検証巡の差し戻しで同じ個体に戻るため常駐と同じ扱い。起動1往復分のコストは許容する。理由＝[[Decisions/2026-09-16-spawn-then-assign]]（**ラッパー経路では不要になった**）。**ラッパー経路では1回の呼び出しに統合＝職種定義（`--agent` が読む）＋依頼文ファイル（`--prompt-file`。必読ノートへの参照は職種定義とラッパーが付ける）。起動プロンプトを別に書かない。1回の呼び出し＝1依頼**。
9. **個体は巡ごとに入れ替える（文脈上限・2026-09-16 本人決定）**: 既定は新規起動（継続はリーダーが明示したときだけ）。状態メモは毎回の成果物（検討経緯）に書く（旧個体へ書かせる手順は不要）。①検証の巡の区切りで、指摘の反映は**同じ職種の新個体**に「成果物＋指摘リスト」を渡して始める（差し戻し先は「同じロール」であって「同じ個体」ではない） ②巡の途中でも文脈が目安 20〜30 万トークンを超えたら同じ手順で切る ④残りが数回で終わる作業は切らない ⑤会話履歴は引き継がない（成果物が状態の正本）。理由と実測＝[[Decisions/2026-09-16-worker-context-recycle]]・[[Knowledge/usage-cost-drivers-2026-09]]。Codex・Claude Code のラッパー経路のとき：継続は `--resume`。

**モデル指定は「受理された」ことと「意図どおり解決された」ことは別**（詳細＝[[Knowledge/model-param-accepted-vs-resolved]]）。ピン留め効果が未検証の指定経路（例: settings.json 単体経由）ではエイリアス指定を避け、疑わしければ本人へ確認する。Claude Code のとき：実効モデルの確認手段: リーダー行＝`/status`・ワーカー行（named/cmux・in-process とも）＝ワーカー別トランスクリプトの `model` フィールドが正本。ペイン先頭のモデル表記はペイン運用時のみ存在し、in-process（既定）では無い（2026-09-02 実測）。

**個別指示と標準手順が食い違うとき**：扱いは [[Preferences/core-worker]] §7 に従い、確認事項は最終報告で返す。

**途中投入の仕様変更は最終レビューで反映確認必須（2026-07-23 本人指摘）**: 作業中のワーカーへ仕様変更を送っても、反映が最後回しになる・取りこぼされる傾向がある。リーダーは最終レビュー時に**変更点が成果物に実際に反映されているかを個別に実査**する（変更で「不要」にした実装・テストの残存も含めて grep で確認）。実例2件（2026-07-23 同一タスク）: ①削除指示した移行コードが残存 ②**差し戻し2点中1点のみ対応し、裁定済みの残り1点を「要リーダー判断」と報告**。対策＝差し戻しは可能なら1メッセージ1論点に絞り、報告には**各点の実装箇所（ファイル:行）の明記を義務付け**て突合する。Claude Code のとき：送信は SendMessage。

## 起動形態の既定（2026-09-17 B-1）
Claude Code のとき：起動形態は2段に分かれる。(1) **配役表に職種行がある職種**＝ラッパー `team/connect/claude-code/claude-exec.sh`（別プロセス・1回の呼び出し＝1依頼・報告は `result`）。(2) **配役表外の組み込み subagent**＝名前無し subagent（`subagent_type`＝職種名・`model`＝`resolve-candidate` が返す `AGENT_MODEL`）。理由＝名前を付けるとチームメイト経路になり、職種定義 frontmatter の `effort:` が無視される（公式・実測 2026-09-17＝[[Knowledge/claude-effort-delivery-paths]]）。本人はペインを見ないため、名前無し化に伴うペイン消滅は許容する。同ロールを並行させるときの識別は名前でなく委任文の担当名（例: 担当A／担当B）で行う。

Claude Code のとき：**ラッパーの呼び出しは必ずバックグラウンドで起動する（本人指示 2026-09-18）**: `team/connect/claude-code/claude-exec.sh` は Bash ツールの `run_in_background: true` で呼び、完了は通知で受けて `--out` の `result` を読む。前面（同期待ち）で呼ばない＝子が終わるまでリーダーの応答が塞がり本人が話しかけられなくなる上、Bash の上限（10分）で子ごと強制終了され成果物が失われる。短い依頼も例外にしない（[[Decisions/2026-09-18-wrapper-launch-background-only]]）。

Claude Code のとき：**例外（名前付きチームメイト）**: 本人指示があるとき・delegation-gate-v2 rule 4 の例外運用に限り、名前付きチームメイトを使ってよい。そのときの**命名規則（2026-07-20 本人指示・2026-09-16 定義名へ統一）＝`<職種名>-<配役（定義名）>[-識別子]`**：名前の先頭に職種名、ハイフンの後に配役表の定義名（9ロール: requirements-analyst/system-designer/implementer/test-writer/test-runner/verifier/researcher/operator/adoption-critic）。例: `implementer-sonnet-high`・`researcher-sonnet-high`・`system-designer-opus-high`・並行時 `implementer-sonnet-high-op-keyframes`。一覧・通知・ペインで「どの配役がどの職種か」を一目で判別するため。名前の配役部分は、明示して起動した配役に合わせる。末尾に**タスク識別子を任意で付けてよい（リーダー裁量・2026-07-20 本人確認）**: 例 `sonnet-implementer-op-keyframes`。同ロール並行時は衝突回避のため必須。cmux では名前付きだけが分割ペインに表示され、本人が進行を目視できる。

Claude Code のとき：**ラッパー経路の終了**: ラッパーの終了コード（0＝成功）と `--out` の受領で終わる。

Claude Code のとき：**名前無し subagent の終了**: 最終応答（完了報告）の受領で終わり（停止操作は不要）。

**例外時（名前付き）の終了の後始末**: チームメイトは使い終わったら必ず停止・消去する（放置しない）。停止条件＝**①作業完了 ②最終報告の受領 ③リーダーのレビューOK（差し戻しなし）④作業していないこと**。④は通知だけで判断せず実査で「処理中でない」ことを確認する（完了報告を送った後も作業を続けている個体が実在するため。報告≠停止可）。差し戻す可能性がある間は停止しない（コンテキスト保持のまま再指示）。継続対話の予定がある場合は残してよいが、その旨をユーザーに明示する。Claude Code のとき：④は `cmux read-screen` のペイン実査で確認する。

Claude Code のとき：停止手順（例外時（名前付き）・①〜④が全て揃ってから実行）:
- Claude Code のとき：**ペイン実査の ref の調べ方**: `cmux list-panes` → `cmux list-pane-surfaces --pane pane:<n>` でチームメイト名の surface を特定 → `cmux read-screen --surface surface:<n> --lines <行数>`。**チームメイト名の直接指定は不可**（ref/UUID/index のみ受理＝2026-07-13 実測）。
- Claude Code のとき：**基本**: `idle_notification`（手が空いた通知）を受信→④をペイン実査で確認→shutdown_request を送る（通知前・作業中に送らない＝終了要求レースを避ける）。送信後はポーリングせず `shutdown_approved`/`teammate_terminated` 通知の受信を待ち、受信後にペイン消滅を1回だけ実査して完了。
- Claude Code のとき：**保留からの再開**: 通知受信時点で①〜④が揃わず残置した場合（差し戻しの可能性・レビュー未完・継続対話の予定）は、**その保留理由が消えた時点（差し戻し無し確定・レビューOK・対話終了）を新たな停止トリガー**として、速やかに④の実査→shutdown_request を実行する。`idle_notification` は再送されないため、通知の再受信を待たない。
- Claude Code のとき：**フォールバック**: 通知が一定期間（目安2〜3分）届かない場合、および SendMessage 非搭載ロール（claude-code-guide 等＝通知が構造的に届かない）も、④の実査で作業終了を確認してから `TaskStop`（task_id にチームメイト名）で手動停止→ペイン1回確認。作業中なら待って再実査（間隔1〜2分＝[[Knowledge/mistakes]]のレース注意と同じ）。
- ペイン消滅の確認前に「消えた」と報告しない。

**停止後の修正**: 停止・消去済みの個体が作った成果物に修正が必要になったら、**同じロールを再起動して委任**する（リーダーの直接修正は不可＝[[Decisions/2026-08-14-deliverable-revision-by-creator]]）。

## 工程フロー接続
各ロールの成果物 → **リーダーが工程の完了時に検証職を1回起動** → 指摘は作成者が反映 → リーダーが却下希望の採否と全体確認 → ユーザー最終レビュー。**品質**レビューロールは作らない（検証職＝verifier 職・配役は配役表の候補からリーダーが選ぶ＝[[Decisions/2026-09-16-rules-bind-to-roles-not-models]]・[[Decisions/2026-09-10-verifier-lineage-recommended]]）。`adoption-critic` は品質でなく**価値**（作るべきか・採用すべきか・続けるべきか）を見る別軸のゲートで、検証職の品質レビューと衝突しない。使いどころ: ①着手前（要件定義の前段。requirements-analyst の OSS 調査結果も入力にできる）②成果物完成後・導入候補ツールの採用前 ③運用棚卸し（operator の巡回報告を入力に継続/廃止の判定案）。実環境が要る結合検証はリーダー担当（ロール化しない）。

**検証職の一次レビューの対象範囲**: 開発4工程（要件定義/設計/実装/テスト）の成果物＝従来通り必須。加えて **researcher の調査報告と adoption-critic の判定案も原則レビューに乗せる**（軽い単発はリーダー判断で省略可）。**operator の巡回報告は対象外**（リーダー確認のみ。定常巡回に毎回検証職を挟まない）。

## ユーザー最終レビューの提示
成果物をユーザーに見せるときは cmux ペイン表示（md=プレビュー/HTML・URL=ブラウザ・タブ再利用）。本文＝[[Preferences/coding-delegation]]「ユーザーへの提示」節（SSOT）。

## モデルを強制する環境変数の解除
`CLAUDE_CODE_SUBAGENT_MODEL_FORCE` が残っていると、`Agent.model` の指定を上書きする可能性がある。解除してから再実行する。
- 起動元のシェルで設定していた場合は、`unset CLAUDE_CODE_SUBAGENT_MODEL_FORCE` を実行する。
- Claude の設定ファイルの `env` にある場合は、その変数の設定を外す。
- 解除後の環境で Claude を起動し直してから、ワーカーを再実行する。

## メンテ
- Claude のとき：**`tools:` 許可リストには `SendMessage` を必ず含める**（許可リストを明示すると、書かなかったツールは剥がれる仕様のため。省略すると SendMessage も落ち、チームメイトが最終報告を送れなくなる）。⚠️**組み込みロール `claude-code-guide` は SendMessage 非搭載**（Bash/Read/WebFetch/WebSearch のみ・実測 2026-07-12＝報告は必ずペイン書き置きになり graceful 終了も不可）。チームメイト起動するなら報告はペイン実査前提と割り切るか、SendMessage 持ちの自作ロール（researcher 等）を使う。**shutdown_request への承認応答も SendMessage 経由**のため、欠落個体は graceful 終了もできない→ `TaskStop`（task_id にチームメイト名）で直接停止する。
- 職種固有の決まりは `Preferences/worker-role-<職種名>.md`、共通規範は [[Preferences/core-worker]]、起動・再依頼の運用は本ノートを編集する。参照先を変えるときは Claude の定義と Codex の読込処理も同時に揃える。
- Claude Code のとき：`~/.claude/agents/` は公式に hot reload（2026-09-17 取得）。実測では**リーダーの新しいターン開始時**に反映される（再起動不要）。
- Claude Code のとき：repo（`claude/agents/`）に職種定義を足しただけでは `~/.claude/agents/` へ配布されない。`install-main.sh`／`install-sub.sh` は職種定義を1ファイルずつ**生成**するため、新設時はインストーラの配置リストへの追加とセットで完了とする（`resolve` は OK でも spawn だけ失敗する型＝2026-09-03 と同型・2026-09-06 3モード設計レビューで再検出）。
