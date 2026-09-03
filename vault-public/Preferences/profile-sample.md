---
date: 2026-08-30
updated: 2026-09-03
tags: [preference, core, profile, sample, role-cast]
project: takumi009-ai-env
related:
  - "[[Preferences/core-conduct]]"
  - "[[Preferences/core-workflow]]"
  - "[[Decisions/2026-09-01-role-cast-table-unfreeze]]"
aliases:
  - "配役表サンプル"
  - "プロファイルサンプル"
---
# プロファイルサンプル（v2・職種ファースト配役表）

## この案の要点
- **v2 schema**（配役表解凍-設計-2026-09-01.md §3.2 が正本）。旧版の能力軸7キーだけの形式（`schema_version`が無い/`1`の実体）は現行実装（`resolve_local_profile()`）へ委譲され続ける（§3.5）。
- 配役は**職種を第一階層にしたインライン形式**（`role.<職種>: <状態> provider=... model=... [execution=...] [effort=...]`）。`fallback.<職種>`は同じ書式で本命が使えないときの代替。
- **本サンプルに「どのマシンの値か」というラベルは付けない**（2026-08-29 本人裁定）。コピーした本人が、自分のマシンで実際に採用する職種・provider・modelへ書き換えて使う前提の雛形であり、特定機の実運用値ではない。
- 各キー・各状態のとりうる値は**コメントに書く**（2026-08-30 本人フィードバック＝日本語長文値は手編集困難・指定可能な値がコメントで分かるようにする）。本文中で説明しない値は書かない。
- `role.leader`は雛形では`unknown`のまま配布する。**installerの対話（U-1・設計§3.9）が実体側で確定させる**ため、サンプル側に既定値を発明しない。
- 能力軸7キー（`inventory_source`／`reviewer`／`vault_write`／`vault_scope`／`ui.user_call`／`git_role`／`web_verification`）はA-1からキー名・書式（`configured value=...`）を変更していない（§3.2 の④）。

## サンプル本文（コピーしてこのまま編集する）

```yaml
---
# =====================================================================
# プロファイル実体（このマシン専用・非配布・repo管理外）
#  書式 : <キー>: <状態> [属性=値 ...]
#         - 状態は必ず先頭に1語。とりうる値は各ブロックのコメントにある
#         - 属性は 名前=値 をスペース区切り。値にスペース・日本語は使わない
#           （長い説明は行の上の # コメントへ書く）
#         - 行頭 # の行と、値の後ろの「スペース+#」以降は無視される
#  ⚠️ 認証情報（AWSのアクセスキー・トークン等）は書かない。このファイルは
#     毎セッションAIが読む。Bedrockのピン留め値は bedrock.env（0600）へ。
# =====================================================================

# --- メタ -----------------------------------------------------------
# この実体が追随しているスキーマ版。コードが期待する版より小さいと「追随待ち」
# （欠けた固定キーは unknown 扱い・警告のみ）、同じなのに欠けていたら「壊れて
# いる」（最小能力へ倒す）。⚠️ 職種の行を足しても版は上げない。版を上げるのは
# 固定キー・文法・必須属性・enum が変わったときだけ。
schema_version: 2
# 能力クラスの表示ラベル。^[a-z0-9][a-z0-9-]*$ ／判定には使わない
profile_slug: authoring

# --- ① 配役表：職種ごとに「使うか・誰が演じるか」を1行で書く --------
# 書式: role.<職種>: <状態> [provider=<経路>] [model=<渡す値>] [execution=<起動方法>]
#  状態: configured    この職種を使う。下の model で起動する
#      | unavailable   使いたいが今は動かせない（上限・認証失敗・定義ファイル不在）
#                      ⚠️ 何を使いたかったかを残すため provider/model は書く
#      | not_adopted   この職種はこのマシンでは使わない（属性は書かない）
#      | unknown       未確定。⚠️ 保留して本人に確認する（属性は書かない）
#  provider: anthropic-api    サブスク／ネイティブAPI経由
#          | bedrock          Amazon Bedrock の Invoke API 経由
#          | bedrock-mantle   Bedrock の Mantle エンドポイント経由
#          | external         このツールの外にあるモデル
#  model   : **リーダーが起動時にそのまま渡す値**。エイリアスを発明しない
#            anthropic-api  = 具体ID（claude-opus-5 等。aliasは書かない）
#            bedrock        = 別名だけ（opus/sonnet/haiku/fable）
#                             ⚠️ 推論プロファイルID・ARN はここに書かない
#                             （それは bedrock.env のピン留め側にだけ置く）
#            bedrock-mantle = anthropic. で始まるID
#            external       = 呼び出し先の識別子
#            1M文脈が要るなら [1m] を付ける
#            ⚠️ Sonnet 5 は常に1Mで [1m] 変種が無いので付けない
#  execution: 書かなければ subagent（チームメイトとして起動する）。
#             provider=external のときだけ external-mcp / external-api を必ず書く
#  effort  : 推論エフォート（任意）。書かなければ**セッション既定を継承**する
#            Claude 系＝low|medium|high|xhigh|max ／ Codex＝minimal|low|medium|high|xhigh
#            ⚠️ **実際に効くのはリーダー行だけ**（settings.json へ反映される）。
#               ワーカー行の effort は「意図の記録＝参考値」で実行値ではない（§3.8）
#  ⚠️ Bedrockのピン留めは書かない（provider=bedrock なら model の別名から
#     bedrock_pin_<別名> を機械が導出する）
#  ⚠️ 職種を増やすときは、この表に1行足す（コード改修は不要。ただし自分の
#     セッションで起動する職種は、コア側の職種定義 agents/<職種>.md も要る）
#  ⚠️ 行を書かなかった職種は unknown 扱い＝保留して本人に確認する
#     （「使わない」つもりなら not_adopted と明示的に書くこと）
role.leader:               unknown        # ← このマシンのリーダー配役を記入（U-1）
role.navi:                 unknown        # 未実装（Projects/navi-orchestrator 設計中）
role.requirements-analyst: configured provider=anthropic-api model=claude-opus-5
role.system-designer:      configured provider=anthropic-api model=claude-opus-5 effort=high
role.adoption-critic:      configured provider=anthropic-api model=claude-opus-5
role.implementer:          configured provider=anthropic-api model=claude-sonnet-5
role.tester:               configured provider=anthropic-api model=claude-sonnet-5
role.researcher:           configured provider=anthropic-api model=claude-sonnet-5
role.operator:             configured provider=anthropic-api model=claude-sonnet-5
role.vault-scribe:         configured provider=anthropic-api model=claude-sonnet-5
role.primary-reviewer:     configured provider=external execution=external-mcp model=codex-review-default
role.ja-doc:               unknown        # 候補=Qwen（H17 実測評価待ち・経路未実装）
# Bedrock機ではこう書く（例）:
# role.leader:             configured provider=bedrock model=opus
# role.researcher:         configured provider=bedrock model=haiku

# --- ② 代替配役：本命が使えないときに使う（無い職種は書かなくてよい）--
# 書式は ① と同じ。⚠️ 状態が configured のものだけが代替として採用される
fallback.primary-reviewer: configured provider=anthropic-api model=claude-opus-5

# --- ③ このマシンで配役してはいけないモデル -------------------------
# 書式: excluded_models: <状態> [value=<値>]
#  状態: configured    禁止リストを持つ。value= に中身を書く
#      | unavailable   禁止リストを判定できない（属性は書かない）
#      | unknown       未確定（属性は書かない）
#      ⚠️ 能力軸と同じ3値の enum（§3.3）。未記載・空も unknown 扱い
#  value : <provider>/<model> のカンマ区切り。禁止したいモデルが無ければ none
#          （[1m] は判定で無視する）
# ⚠️ モデル族を全経路で禁止したいときは経路ごとに列挙する
#    （例 anthropic-api/claude-fable-5,bedrock/fable）
excluded_models: configured value=none

# --- ④ 能力軸（7キー・A-1 から**キー名は変更なし**）-----------------
# 共通のとりうる値: configured value=<短い英語トークン> | unavailable | unknown
# 既存確認の参照先。値: work-tools-dir | vault-preferences | vault-knowledge
inventory_source: configured value=work-tools-dir,vault-preferences,vault-knowledge
# 一次レビュアーの実体。値: codex-mcp | peer-claude ／ 居なければ unavailable
reviewer:         configured value=codex-mcp
# Vaultへの書込み。値: via-scribe | direct ／ 書けなければ unavailable
vault_write:      configured value=via-scribe
# このマシンに実在するVault蔵書範囲。値: full | フォルダ名のカンマ区切り
vault_scope:      configured value=full
# 本人を呼ぶ手段。値: send-message | cmux-notify | stdout-only
ui.user_call:     configured value=send-message,cmux-notify
# git上の立場。**必ずrepoスコープ付き**。値: <repoスコープ>:<立場> のカンマ区切り
#   立場: push | commit | pull-only | ask（＝その都度本人に確認）
git_role:         configured value=aienv-repo:commit,other-repo:ask
# 裏取りの手段。値: websearch | webfetch ／ 無ければ unavailable
# ⚠️ Bedrock機では公式ドキュメントは「WebSearch不可」だが実測で「使えた」と
#    いう報告がある。**このマシンで実際に1回試して書くこと**
web_verification: configured value=websearch,webfetch
---
```

## 確認手順（コピー後、機体ごとに見直す）

サンプルの値は**とりうる値の一例**であって、どの機体にも共通の実値ではない。コピーした直後に、以下の手順で自分のマシンの実値へ書き換える。

| キー | サンプルの値（例） | 確認手順（1行） |
|---|---|---|
| `role.leader` | `unknown` | 記入しない。`scripts/install-main.sh`／`scripts/install-sub.sh`実行時の対話（設計§3.9）で確定させる |
| `role.*`（leader以外） | `configured provider=... model=...` など | 自分のセッションで実際に起動する職種だけ`configured`にし、providerとmodelを§3.2の適合表（anthropic-api/bedrock/bedrock-mantle/externalそれぞれのmodel形式）に沿って書く。使わない職種は`not_adopted`、判断保留は`unknown`のまま残す |
| `fallback.*` | `configured provider=... model=...` | 本命(`role.*`)が使えないときに使う職種にだけ書く。不要なら行ごと削ってよい |
| `excluded_models` | `value=none` | このマシンで使ってはいけないモデル族があれば`<provider>/<model>`のカンマ区切りへ書き換える。無ければ`none`のまま |
| `inventory_source` | `value=work-tools-dir,vault-preferences,vault-knowledge` | このマシンで`work`配下の`tools/`やVaultの`Preferences`/`Knowledge`が実在するかを確認し、実在するものだけをカンマ区切りで残す |
| `reviewer` | `value=codex-mcp` | `mcp__codex__codex`（またはpeer-claude）が実際に呼び出せるかを確認し、使えなければ`unavailable`にする |
| `vault_write` | `value=via-scribe` | vault-scribe teammateが実際に起動できるか確認する。委任先が無ければ`unavailable`にする |
| `vault_scope` | `value=full` | このマシンの`Data/obsidian`配下がVault全体（private含む）か、`vault-public`のみのpublicスナップショットかを確認し、後者ならフォルダ名のカンマ区切り（例`Preferences,Knowledge`）へ書き換える |
| `ui.user_call` | `value=send-message,cmux-notify` | このマシンで実際に使える呼び出し手段（SendMessage・cmux notify等）だけを残す |
| `git_role` | `value=aienv-repo:commit,other-repo:ask` | リポジトリごとの実際の立場（push/commit/pull-only/ask）を repoスコープ付きで書く。決まっていないrepoは`ask`にする（絶対厳守②＝public化は本人が行う） |
| `web_verification` | `value=websearch,webfetch` | このマシンで実際にWebSearch/WebFetchを1回実行して使えるかを確認する。⚠️ Bedrock機では公式ドキュメントとの食い違いがありうるので**このマシンで実測してから書く**（§9-6） |

## サンプルの位置づけ（unknown・enum一例を使う理由）

本サンプルは**特定機の実運用値ではなく、書式と各キーのとりうる値を示す雛形**である（2026-08-29 本人裁定「どのマシンの値かラベルを付けない」）。`role.leader`は雛形では常に`unknown`のまま配布し、installerの対話（設計§3.9・U-1裁定）が実体側でリーダー配役を確定させる。それ以外の職種行・能力軸7キーは「書式として妥当な値の一例」であり、コピーした本人が上表の確認手順に従って自分のマシンの実値へ書き換える運用とする。

未記載の職種は`unknown`（保留・本人確認待ち）として扱われる。「このマシンでは使わない」と決めている職種は、行を省略せず`not_adopted`と明示的に書くこと（§3.2）。
