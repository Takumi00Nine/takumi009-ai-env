---
date: 2026-07-05
updated: 2026-09-21
tags: [preference, delegation, agent-teams, subagent, roles]
project: meta
related:
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

# ワーカー工程ロール運用（9ロール・agents定義＋本ノートSSOT）

ワーカー/チームメイトへの委任は**工程ロール定義**（`~/.claude/agents/*.md`）を名指しで使う。定義本文＝ロールの行動規範（機械的にシステムプロンプトへ付加し、toolsを適用）、本ノート＝リーダー側の運用ルール。モデルはspawn時に指定する。

> **2026-08-07 改定（in-process 恒久化＝[[Decisions/2026-08-07-teammate-in-process-permanent]]）**: チームメイトはペインを持たない（エージェントパネル内で動作）。本ノートの「ペイン実査」（`cmux read-screen`・`list-panes`・ペイン消滅確認）は **`TaskOutput`／エージェントパネル（↑↓選択・Enter でトランスクリプト）での実査に読み替える**。名前付き起動は 2026-09-17 に例外へ縮小（下の起動形態の節）。ペイン運用に戻した場合（`cct --teammate-mode auto`）のみ原文の手順を使う。

## 9ロール一覧（職種と職務）

ワーカーモデルは配役表の候補からリーダーがspawnごとに選ぶ。上流工程向けの判断目安は [[Preferences/coding-delegation]] と [[Preferences/model-catalog]] を参照する。命名は実際に選んだ配役に合わせる。
| ロール名 | 工程 | 要旨 |
|---|---|---|
| `requirements-analyst` | 要件定義 | 検証可能な受入条件・スコープ外・OSS先行調査（「作らない」提案含む）。**要件定義の成果物は「要件定義書（確定事項のみ）」と「検討経緯（論点・代替案比較・レビュー録）」の2ファイル構成を既定とする**（正本＝[[Preferences/coding-doc-style]] §3・[[Decisions/2026-08-30-doc-body-archive-split]]） |
| `system-designer` | 設計 | 代替案比較（A vs B＋根拠＋リスク）・構成・テスト戦略。合議参加もこれ。**リスク部分（永続状態・人間承認/却下・複数部品連携）は詳細設計まで＝状態遷移(失敗/却下/滞留/復活含む)・source of truth・失敗モードを必ず落とす**（2026-07-18・手戻り前倒し）。**設計成果物は「設計書（確定事項のみ）」と「検討経緯（論点・代替案比較・レビュー録）」の2ファイル構成を既定とする**（正本＝[[Preferences/coding-doc-style]] §3・[[Decisions/2026-08-30-doc-body-archive-split]]。委任プロンプト頼みにせずロール規範側で担保＝2026-09-01 本人指示）。**要件の許可表（使ってよい外部コマンド等）に無い道具が要るとき、道具を諦めて要件の粒度を曲げる前に「許可表へ 1 語足せば済まないか」を先に見て、読み替えとしてリーダー承認を求める**（2026-09-15 設計 3 巡の自己反省＝[[Decisions/2026-09-15-cmux-dock-two-repo-split]]） |
| `implementer` | 実装 | 担当ファイル範囲限定・既存様式遵守・**test-writer のテストを緑にする**（追加テスト可・置換/弱体化不可・test-writer 不在時のみ併作）。**文書改修も対象** |
| `test-writer` | テスト作成 | 確定した受入条件から**実装より先に**テストを書く（実装者とは別個体・実装本体は書かない・未実装で赤／仕様どおりで緑・条件 ID と 1 対 1）。曖昧な受入条件は差し戻す（[[Decisions/2026-09-21-test-three-roles]]） |
| `test-runner` | テスト実行 | 指定スイートを**そのまま**実行し集計行・失敗行だけ報告。判断・指摘・修正なし。固定スイートはリーダー直叩きで代替可 |
| `verifier` | 検証 | 読んで指摘する**だけ**（本体・テストコード・文書）・成果物には書かない・不足テストは指摘まで（受入条件のテストは test-writer が書く）・**テストは実行しない**（test-runner の結果を渡されたら受入条件と突合）。**順序＝レビュー先行**（BLOCKING が1件でもあれば test-runner を回さず即報告＝[[Decisions/2026-09-17-verifier-review-before-tests]]・[[Decisions/2026-09-21-test-three-roles]]） |
| `researcher` | 調査（横断） | 裏取り/OSS/作者意図/デバッグ/振り返り分析の5モード。出典URL・確度必須 |
| `operator` | 運用 | ヘルスチェック・障害一次調査・メンテ点検。**診断のみ・破壊的操作は提案止まり** |
| `adoption-critic` | 採用判定（ゲート） | 敵対的レビューで「採用する価値があるか」の判定案。3モード＝着手判定（アイデア・要件定義より前）／採用判定（成果物・外部ツール）／継続判定（運用結果）。**品質レビュー（Codex）とは別軸**・最終決定はリーダー→ユーザー |

## 職種ごとの権限表（リーダー向け一覧）
**正本＝各職種定義（`agents/<職種名>.md`）の「## 権限」行。本表はその転記＝改版は定義→本表の順。**

| 職種 | 成果物への書込 | テスト | 実行 | Codex が演じるときの `sandbox` |
|---|---|---|---|---|
| `implementer` | **担当ファイル範囲**に書ける | 書ける（追加のみ・test-writer のテスト・fixture の置換/弱体化は不可） | 担当範囲のみ | `workspace-write`（`cwd`＝担当範囲へ最小化）|
| `test-writer` | **担当テストファイル範囲**に書ける（テスト本体と受入条件用の fixture。実装本体は書かない） | 書ける | 担当範囲のみ | `workspace-write`（`cwd`＝担当テスト範囲へ最小化）|
| `test-runner` | **書かない**（結果ファイルのみ） | **書かない** | できる（指定コマンドのみ） | `workspace-write`（`cwd`＝使い捨て worktree・書けるのは結果の出力先だけ）|
| `verifier` | **書かない**（指摘のみ）| **書かない**（指摘まで）| **しない**（Bash は読取に限る・実行は test-runner）| **`read-only`** 一律（文書・コードとも。指摘リストは最終メッセージで返す）|
| `requirements-analyst` | 自分の成果物に書ける | — | — | `workspace-write`（`cwd`＝成果物の置き場）|
| `system-designer` | 自分の成果物に書ける | — | — | 同上 |
| `adoption-critic` | 自分の成果物に書ける | — | — | 同上 |
| `researcher` | **自分の調査報告には書ける／他職種の成果物には書かない**（**本人裁定 2026-09-07**） | — | 調査に要する読取・実行のみ | 同上 |
| `operator` | **自分の巡回・障害報告には書ける／診断の対象（設定・成果物・常駐）は変更しない**。破壊的操作は提案止まり | — | 読取・診断系のみ | `workspace-write`（`cwd`＝報告の置き場） |
| `vault-scribe` | **Vault へ書ける（宣言あり・既定の記録職）** | — | — | **該当なし**（Codex はこの職種を演じない＝Vault 書込は Claude のみ） |

**全職種に共通**＝①Vault の AI 向け6フォルダへは `vault-scribe` 以外書かない ②**`cwd` に `$HOME` 全体を渡すときは職種を問わず `read-only`**（広い `cwd` と `workspace-write` を組み合わせない）。

補助ロール（9工程外）: **`vault-scribe`**（執筆代行）＝リーダーが確定した内容の Vault 書き込み専任。内容の新規判断はしない・Codex 一次レビュー対象外（リーダーが diff 実査）。記録職＝Vault 書込を宣言した職種（既定 `subagent_type: vault-scribe`）・既定は名前無し subagent（起動形態に依存しない）。同一個体への続行は Agent ID 宛の SendMessage で可。**停止条件＝工程の区切りか、依頼なしで 30 分**（名前無し subagent は常駐コストを持たないが、依頼なしの放置は続行しない・[[Decisions/2026-09-16-worker-context-recycle]]）。運用の詳細＝[[Preferences/vault-operation]]・[[Decisions/2026-08-10-vault-scribe]]。

## 職種定義を新設・改訂するときの掟（2026-09-01 本人指示）
**共通部と固有部の分離（2026-09-06 本人決定）**: 全職種に共通の型（着手前の Read・事実の扱い・成果物の2ファイル構成とシンプルさ・Vault の扱い・安全則・一次レビュー・報告形式・指示の優先）は [[Preferences/core-worker]] に1本で持ち、職種定義（`agents/*.md`）には「absolute-rules と core-worker を Read する」の2行と、その職種固有の手順・出力形式だけを書く。共通部を職種定義へ複製しない。職種定義には日付・決定ノート参照・理由を書かず（ルールだけ）、なぜ・いつは Decisions 側に置く。

職種定義（`~/.claude/agents/*.md`）を新設・改訂するときは、その職種の**成果物種別を確認**し、長寿命文書（設計書・要件書級）を作る職種には出力形式の節へ**「本文（確定事項のみ）＋検討経緯（論点・代替案比較・レビュー録）の2ファイル構成」の1行を必ず含める**（2026-09-06 以降は共通規範 [[Preferences/core-worker]] §3 がこれを担うため、職種定義側には書かない）（正本＝[[Preferences/coding-doc-style]] §3）。横断ルールは委任プロンプト頼みにせず職種定義側へ焼き込む（実例＝2026-09-01 設計差分書の分割差し戻し＝[[Decisions/2026-09-01-doc-rule-bake-into-roles]]）。

成果物（設計書・要件書・報告書・判定書など、ファイルとして残す文書）を作る職種には **`tools:` に `Edit, Write` を必ず含める**（本文が「保存する」と言うのに書けない定義にしない。実例＝2026-09-03 設計者が書き込めない問題＝[[Decisions/2026-09-03-worker-write-tools-for-deliverable-roles]]）。

配置先 `~/.claude/agents/*.md` は installer が配る（配り方は README）。effort の実行値は配役表の候補からラッパーが `--effort` で渡す＝職種定義の `effort:` 行は実行値ではない（B-1 の AC-1 後に生成を退役）。改訂は素材を commit・push→サブ機は `update-sub.sh` で再生成。反映はリーダーの新しいターン開始時（再起動不要）。

## リーダーが spawn 時に必ず渡すもの（定義には書けないタスク固有分）
1. 背景と目的（会話履歴は引き継がれない前提で書く）
2. 対象パス・**担当ファイル範囲**（ワーカー間のファイル競合防止）
3. 受入条件・完了定義
4. 参照すべき Vault ノート（パスで指定）
5. 報告の上限行数（既定30行）と報告先。**ラッパー経路の最終報告は `--out` の JSON `result`（リーダーは `jq -r .result` で読む）。SendMessage は子からリーダーへ届かない。名前無し subagent（配役表外）は最終応答で返る**
6. ツール境界: Web調査だけで足りるタスクは**「Bash/gh 不使用・WebFetch で読む」を明示**（ワーカーの許可リスト外コマンドは承認プロンプトがユーザーへ飛び、作業も止まるため）

呼び方: チームメイト＝「Spawn a teammate using the implementer agent type…」／サブエージェント＝Agent ツールの subagent_type。
7. **配役の指定＝正本は配役表**。選択・起動条件は [[Preferences/core-workflow]] §1 spawn条文に従う。属性の正本はモデル定義ファイル（[[Preferences/model-definitions-sample]]）。選んだ候補の定義名を `--model-def` で渡す。`resolve-candidate` の手動実行は配役表外を名前無しで起動するときだけ。external-cliでは既存 `CODEX_ARGS` を所定のwrapperへ渡す。名前は付けない（名前付きの例外時のみ上の命名規則）。名前だけを実効モデルの証拠にしない。判断材料は [[Preferences/model-catalog]] と【使用率】ブロック。
8. **起動と依頼を分ける（常駐基準・2026-09-16 本人決定）**: すべてのワーカーは常駐前提で起動する。起動プロンプトに書くのは「職種の確認・全依頼に共通する制約（上記 5〜7＝報告書式と報告先・ツール境界・配役）・待機指示」だけで、**個別の依頼（上記 1〜4＝背景・対象パス・担当範囲・受入条件・参照ノート）は起動後に SendMessage で渡す**。起動プロンプトに最初の依頼を混ぜない（個体の文脈に最後まで残り、後の依頼まで引きずる）。「単発」の区分は設けない＝要件・設計も検証巡の差し戻しで同じ個体に戻るため常駐と同じ扱い。起動1往復分のコストは許容する。理由＝[[Decisions/2026-09-16-spawn-then-assign]]（**ラッパー経路では不要になった**）。**ラッパー経路では1回の呼び出しに統合＝職種定義（`--agent` が読む）＋依頼文ファイル（`--prompt-file`・absolute-rules への参照必須＝無いと拒否）。起動プロンプトを別に書かない。1回の呼び出し＝1依頼**。
9. **個体は巡ごとに入れ替える（文脈上限・2026-09-16 本人決定）**: 既定は新規起動（`--resume` はリーダーが明示したときだけ）。状態メモは毎回の成果物（検討経緯）に書く（旧個体へ書かせる手順は不要）。①検証の巡の区切りで、指摘の反映は**同じ職種の新個体**に「成果物＋指摘リスト」を渡して始める（差し戻し先は「同じロール」であって「同じ個体」ではない） ②巡の途中でも文脈が目安 20〜30 万トークンを超えたら同じ手順で切る ④残りが数回で終わる作業は切らない ⑤会話履歴は引き継がない（成果物が状態の正本）。理由と実測＝[[Decisions/2026-09-16-worker-context-recycle]]・[[Knowledge/usage-cost-drivers-2026-09]]。

**モデル指定は「受理された」ことと「意図どおり解決された」ことは別**（詳細＝[[Knowledge/model-param-accepted-vs-resolved]]）。実効モデルの確認手段: リーダー行＝`/status`・ワーカー行（named/cmux・in-process とも）＝ワーカー別トランスクリプトの `model` フィールドが正本。ペイン先頭のモデル表記はペイン運用時のみ存在し、in-process（既定）では無い（2026-09-02 実測）。ピン留め効果が未検証の指定経路（例: settings.json 単体経由）ではエイリアス指定を避け、疑わしければ本人へ確認する。

**リーダーの個別指示と標準プロトコルが矛盾したら着手前に確認（2026-08-01 追加）**: ワーカーは、リーダーからのその場の個別指示（例:「Codex 指摘は転送のみ・反映しない」）が本ノートやロール定義の標準手順（例: 検証職の指摘をリーダー経由で反映）と食い違う場合、**どちらに従うか着手前に1行確認**する。個別指示が原則優先。実例＝2026-08-01 W4 が「転送のみ」指示を標準プロトコルで上書き解釈し自分で修正まで実施（結果は良かったが監査の穴になり得る）。

**途中投入の仕様変更は最終レビューで反映確認必須（2026-07-23 本人指摘）**: 作業中のワーカーへ SendMessage で仕様変更を送っても、反映が最後回しになる・取りこぼされる傾向がある。リーダーは最終レビュー時に**変更点が成果物に実際に反映されているかを個別に実査**する（変更で「不要」にした実装・テストの残存も含めて grep で確認）。実例2件（2026-07-23 同一タスク）: ①削除指示した移行コードが残存 ②**差し戻し2点中1点のみ対応し、裁定済みの残り1点を「要リーダー判断」と報告**。対策＝差し戻しは可能なら1メッセージ1論点に絞り、報告には**各点の実装箇所（ファイル:行）の明記を義務付け**て突合する。

## 起動形態の既定（2026-09-17 B-1）
起動形態は2段に分かれる。(1) **配役表に職種行がある職種**＝ラッパー `scripts/claude-exec.sh`（別プロセス・1回の呼び出し＝1依頼・報告は `result`）。(2) **配役表外の組み込み subagent**＝名前無し subagent（`subagent_type`＝職種名・`model`＝`resolve-candidate` が返す `AGENT_MODEL`）。理由＝名前を付けるとチームメイト経路になり、職種定義 frontmatter の `effort:` が無視される（公式・実測 2026-09-17＝[[Knowledge/claude-effort-delivery-paths]]）。本人はペインを見ないため、名前無し化に伴うペイン消滅は許容する。同ロールを並行させるときの識別は名前でなく委任文の担当名（例: 担当A／担当B）で行う。

**ラッパーの呼び出しは必ずバックグラウンドで起動する（本人指示 2026-09-18）**: `scripts/claude-exec.sh` は Bash ツールの `run_in_background: true` で呼び、完了は通知で受けて `--out` の `result` を読む。前面（同期待ち）で呼ばない＝子が終わるまでリーダーの応答が塞がり本人が話しかけられなくなる上、Bash の上限（10分）で子ごと強制終了され成果物が失われる。記録職の短い依頼も例外にしない（[[Decisions/2026-09-18-wrapper-launch-background-only]]）。

**例外（名前付きチームメイト）**: 本人指示があるとき・delegation-gate-v2 rule 4 の例外運用に限り、名前付きチームメイトを使ってよい。そのときの**命名規則（2026-07-20 本人指示・2026-09-16 定義名へ統一）＝`<職種名>-<配役（定義名）>[-識別子]`**：名前の先頭に職種名、ハイフンの後に配役表の定義名（9ロール: requirements-analyst/system-designer/implementer/test-writer/test-runner/verifier/researcher/operator/adoption-critic）。例: `implementer-sonnet-high`・`researcher-sonnet-high`・`system-designer-opus-high`・並行時 `implementer-sonnet-high-op-keyframes`。一覧・通知・ペインで「どの配役がどの職種か」を一目で判別するため。名前の配役部分は、明示して起動した配役に合わせる。末尾に**タスク識別子を任意で付けてよい（リーダー裁量・2026-07-20 本人確認）**: 例 `sonnet-implementer-op-keyframes`。同ロール並行時は衝突回避のため必須。cmux では名前付きだけが分割ペインに表示され、本人が進行を目視できる。

**ラッパー経路の終了**: ラッパーの終了コード（0＝成功）と `--out` の受領で終わる。

**名前無し subagent の終了**: 最終応答（完了報告）の受領で終わり（停止操作は不要）。

**例外時（名前付き）の終了の後始末**: チームメイトは使い終わったら必ず停止・消去する（放置しない）。停止条件＝**①作業完了 ②最終報告の受領 ③リーダーのレビューOK（差し戻しなし）④作業していないこと**。④は通知だけで判断せず `cmux read-screen` のペイン実査で「処理中でない」ことを確認する（完了報告を送った後も作業を続けている個体が実在するため。報告≠停止可）。差し戻す可能性がある間は停止しない（コンテキスト保持のまま再指示）。継続対話の予定がある場合は残してよいが、その旨をユーザーに明示する。

停止手順（例外時（名前付き）・①〜④が全て揃ってから実行）:
- **ペイン実査の ref の調べ方**: `cmux list-panes` → `cmux list-pane-surfaces --pane pane:<n>` でチームメイト名の surface を特定 → `cmux read-screen --surface surface:<n> --lines <行数>`。**チームメイト名の直接指定は不可**（ref/UUID/index のみ受理＝2026-07-13 実測）。
- **基本**: `idle_notification`（手が空いた通知）を受信→④をペイン実査で確認→shutdown_request を送る（通知前・作業中に送らない＝終了要求レースを避ける）。送信後はポーリングせず `shutdown_approved`/`teammate_terminated` 通知の受信を待ち、受信後にペイン消滅を1回だけ実査して完了。
- **保留からの再開**: 通知受信時点で①〜④が揃わず残置した場合（差し戻しの可能性・レビュー未完・継続対話の予定）は、**その保留理由が消えた時点（差し戻し無し確定・レビューOK・対話終了）を新たな停止トリガー**として、速やかに④の実査→shutdown_request を実行する。`idle_notification` は再送されないため、通知の再受信を待たない。
- **フォールバック**: 通知が一定期間（目安2〜3分）届かない場合、および SendMessage 非搭載ロール（claude-code-guide 等＝通知が構造的に届かない）も、④の実査で作業終了を確認してから `TaskStop`（task_id にチームメイト名）で手動停止→ペイン1回確認。作業中なら待って再実査（間隔1〜2分＝[[Knowledge/mistakes]]のレース注意と同じ）。
- ペイン消滅の確認前に「消えた」と報告しない。

**停止後の修正**: 停止・消去済みの個体が作った成果物に修正が必要になったら、**同じロールを再起動して委任**する（リーダーの直接修正は不可＝[[Decisions/2026-08-14-deliverable-revision-by-creator]]）。

## 工程フロー接続
各ロールの成果物 → **リーダーが工程の完了時に検証職を1回起動** → 指摘は作成者が反映 → リーダーが却下希望の採否と全体確認 → ユーザー最終レビュー。**品質**レビューロールは作らない（検証職＝verifier 職・配役は配役表の候補からリーダーが選ぶ＝[[Decisions/2026-09-16-rules-bind-to-roles-not-models]]・[[Decisions/2026-09-10-verifier-lineage-recommended]]）。`adoption-critic` は品質でなく**価値**（作るべきか・採用すべきか・続けるべきか）を見る別軸のゲートで、Codex 専任と衝突しない。使いどころ: ①着手前（要件定義の前段。requirements-analyst の OSS 調査結果も入力にできる）②成果物完成後・導入候補ツールの採用前 ③運用棚卸し（operator の巡回報告を入力に継続/廃止の判定案）。実環境が要る結合検証はリーダー担当（ロール化しない）。

**Codex 一次レビューの対象範囲**: 開発4工程（要件定義/設計/実装/テスト）の成果物＝従来通り必須。加えて **researcher の調査報告と adoption-critic の判定案も原則レビューに乗せる**（軽い単発はリーダー判断で省略可）。**operator の巡回報告は対象外**（リーダー確認のみ。定常巡回に毎回 Codex を挟まない）。

## ユーザー最終レビューの提示
成果物をユーザーに見せるときは cmux ペイン表示（md=プレビュー/HTML・URL=ブラウザ・タブ再利用）。本文＝[[Preferences/coding-delegation]]「ユーザーへの提示」節（SSOT）。

## メンテ
- **`tools:` 許可リストには `SendMessage` を必ず含める**（許可リストを明示すると、書かなかったツールは剥がれる仕様のため。省略すると SendMessage も落ち、チームメイトが最終報告を送れなくなる）。⚠️**組み込みロール `claude-code-guide` は SendMessage 非搭載**（Bash/Read/WebFetch/WebSearch のみ・実測 2026-07-12＝報告は必ずペイン書き置きになり graceful 終了も不可）。チームメイト起動するなら報告はペイン実査前提と割り切るか、SendMessage 持ちの自作ロール（researcher 等）を使う。**shutdown_request への承認応答も SendMessage 経由**のため、欠落個体は graceful 終了もできない→ `TaskStop`（task_id にチームメイト名）で直接停止する。
- ロールの行動規範を変えるとき＝`~/.claude/agents/*.md` を編集。運用（spawn時に渡すもの・フロー）を変えるとき＝本ノートを編集。両方に跨る変更は同時に。
- `~/.claude/agents/` は公式に hot reload（2026-09-17 取得）。実測では**リーダーの新しいターン開始時**に反映される（再起動不要）。
- repo（`claude/agents/`）に職種定義を足しただけでは `~/.claude/agents/` へ配布されない。`install-main.sh`／`install-sub.sh` は職種定義を1ファイルずつ**生成**するため、新設時はインストーラの配置リストへの追加とセットで完了とする（`resolve` は OK でも spawn だけ失敗する型＝2026-09-03 と同型・2026-09-06 3モード設計レビューで再検出）。
