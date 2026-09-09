---
date: 2026-08-30
updated: 2026-09-08
tags: [preference, core, profile, sample, role-cast]
project: takumi009-ai-env
related:
  - "[[Preferences/core-conduct]]"
  - "[[Preferences/core-workflow]]"
  - "[[Preferences/bedrock-env-sample]]"
  - "[[Preferences/model-definitions-sample]]"
  - "[[Decisions/2026-09-01-role-cast-table-unfreeze]]"
  - "[[Decisions/2026-09-06-codex-mcp-retire]]"
  - "[[Decisions/2026-09-07-three-team-mode-rollout]]"
  - "[[Decisions/2026-09-07-profile-axes-consolidation]]"
  - "[[Decisions/2026-09-08-model-definitions-file]]"
aliases:
  - "配役表サンプル"
  - "プロファイルサンプル"
  - "profile.md案内"
---
# プロファイルサンプル（v6・職種ファースト配役表）

## この案の要点
- **v6 schema**は role 行から `provider`／`execution`／`effort` の属性を撤去し、モデル定義ファイル（[[Preferences/model-definitions-sample]]）の定義名を `model=<定義名>[,<定義名>…]` で参照する形へ変えた（[[Decisions/2026-09-08-model-definitions-file]]）。
- **v4 schema**（基本形＝配役表解凍-設計-2026-09-01.md §3.2 が正本。v3 は P3 段階4 で `no_read_paths` を追加、v4 は 3モード体制で `team_mode` を追加・能力軸 `reviewer` を廃止・`execution` の enum を `external-cli`／`external-api` に改めた＝[[Decisions/2026-09-07-three-team-mode-rollout]]）。旧版の能力軸7キーだけの形式（`schema_version`が無い/`1`の実体）は現行実装（`resolve_local_profile()`）へ委譲され続ける（§3.5）。v5 は能力軸を `team_mode`・`no_read_paths`・`machine_role` の3キーへ整理し、`machine_role` を新設した（[[Decisions/2026-09-07-profile-axes-consolidation]]）。
- 配役は**職種を第一階層にしたインライン形式**（`role.<職種>: <状態> model=<定義名>[,<定義名>…]`）。`fallback.<職種>`は同じ書式で本命が使えないときの代替（候補は1件だけ）。
- **正本は repo の設定サンプル**（2026-09-08 本人決定）: `takumi009-ai-env` の `config/profile.md.sample`／`config/models.conf.sample`／`config/bedrock.env.sample`（実ファイル・値はメイン機の実値）が正本。本人が `~/.config/takumi009-ai-env/` へコピーして使う（`mkdir -p ~/.config/takumi009-ai-env && cp config/profile.md.sample ~/.config/takumi009-ai-env/profile.md` の要領。models.conf も同様・bedrock.env は Bedrock 機だけ）。サブ機はコピー後に `machine_role`（と必要なら `role.leader`）だけ書き換える。installer は実体が無いときだけ `config/profile.md.sample` を雛形としてコピーする（既存は壊さない）。symlink・同期処理は無い。
- 各キー・各状態のとりうる値は**コメントに書く**（2026-08-30 本人フィードバック＝日本語長文値は手編集困難・指定可能な値がコメントで分かるようにする）。本文中で説明しない値は書かない。
- `role.leader`はサンプル（メイン機の実値）では確定値のまま配布する。未確定・サブ機で変える場合は**installerの対話（U-1・設計§3.9）が実体側で確定させる**（2026-09-08 本人決定でサンプル＝雛形の unknown 前提は解消）。
- 能力軸3キー（`team_mode`／`no_read_paths`／`machine_role`）。キー名・書式（`configured value=...`）は A-1 から変更していない（§3.2 の④）。`no_read_paths` は P3 段階4（schema_version 3）で追加。`vault_scope` は 2026-09-07 に撤去（[[Decisions/2026-09-07-retire-vault-scope-axis]]・schema は 4 のまま）。`inventory_source`／`vault_write`／`ui.user_call`／`git_role`／`web_verification` は 2026-09-07 に撤去・`machine_role` を新設（[[Decisions/2026-09-07-profile-axes-consolidation]]・schema 5）。
- `effort` は各モデル定義（[[Preferences/model-definitions-sample]]）に明示する（2026-09-02 本人指示＝セッション既定の継承は使わない・全マシン共通）。定義ファイルのサンプルにある `effort=high` は一例で、機体ごとに選び直してよい。

## サンプル本文

本文は repo の `config/profile.md.sample` を見る（正本・実ファイル）。

## 確認手順（コピー後、機体ごとに見直す）

サンプルの値は**メイン機の実値**である（2026-09-08 本人決定）。メイン機はそのまま使ってよい。それ以外の機で使う場合は、以下の手順で自分のマシンの実値へ書き換える。

| キー | サンプルの値（例） | 確認手順（1行） |
|---|---|---|
| `role.leader` | メイン機の実値（サンプルはメイン機の実運用値） | メイン機はそのまま使う。未確定・サブ機で変える場合は `scripts/install-main.sh`／`scripts/install-sub.sh`実行時の対話（設計§3.9）で確定させる |
| `role.*`（leader以外） | `configured model=<定義名>[,<定義名>…]` | 自分のセッションで実際に起動する職種だけ`configured`にし、モデル定義ファイル（[[Preferences/model-definitions-sample]]）の定義名をカンマ区切りで1つ以上書く。使わない職種は`not_adopted`、判断保留は`unknown`のまま残す |
| `fallback.*` | `configured model=<定義名>` | 本命(`role.*`)が使えないときに使う職種にだけ、定義名を**1件だけ**書く。不要なら行ごと削ってよい |
| `excluded_models` | `value=none` | このマシンで使ってはいけないモデル族があれば`<provider>/<model>`のカンマ区切りへ書き換える。無ければ`none`のまま |
| `team_mode` | `value=full` | このマシンの枠に合う既定体制を選ぶ（メイン機＝`full`・サブ機＝`lean` が目安）。迷ったら本人に確認する |
| `no_read_paths` | `value=~/work/old` | 読まない・検索しないパスが実在するかを確認し、無ければ`unavailable`にする |
| `machine_role` | `configured value=main`（サンプルはメイン機の実値） | サンプルはメイン機の値のまま。**サブ機はコピー後に `configured value=sub` へ書き換える**（機構は推測しない） |

未記載の職種は`unknown`（保留・本人確認待ち）として扱われる。「このマシンでは使わない」と決めている職種は、行を省略せず`not_adopted`と明示的に書くこと（§3.2）。
