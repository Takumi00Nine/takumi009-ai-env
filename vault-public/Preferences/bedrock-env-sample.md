---
date: 2026-09-07
updated: 2026-09-08
tags: [preference, core, profile, sample, bedrock]
project: takumi009-ai-env
related:
  - "[[Preferences/profile-sample]]"
  - "[[Knowledge/bedrock-claude-code-pitfalls]]"
  - "[[Decisions/2026-08-21-machine-role-model-assignment]]"
  - "[[Decisions/2026-09-01-role-cast-table-unfreeze]]"
  - "[[Decisions/2026-09-08-model-definitions-file]]"
aliases:
  - "bedrock.env サンプル"
  - "Bedrockピン留めファイル"
  - "ピン留めenvの書き方"
  - "bedrock.env案内"
---
# bedrock.env サンプル（Bedrock 機のピン留め値）

## 要点
- **正本は repo の設定サンプル**（2026-09-08 本人決定）: `takumi009-ai-env` の `config/profile.md.sample`／`config/models.conf.sample`／`config/bedrock.env.sample`（実ファイル・値はメイン機の実値）が正本。本人が `~/.config/takumi009-ai-env/` へコピーして使う（`mkdir -p ~/.config/takumi009-ai-env && cp config/profile.md.sample ~/.config/takumi009-ai-env/profile.md` の要領。models.conf も同様・bedrock.env は Bedrock 機だけ）。サブ機はコピー後に `machine_role`（と必要なら `role.leader`）だけ書き換える。installer は実体が無いときだけ `config/profile.md.sample` を雛形としてコピーする（既存は壊さない）。symlink・同期処理は無い。
- コピー後の置き場＝`~/.config/takumi009-ai-env/bedrock.env`（パーミッション 0600・このマシン専用の実体・git 管理外のまま）。**メイン／サブを問わず、Bedrock を使う機にだけ置く**（読む仕組みは `install-main.sh`・`install-sub.sh`・`bootstrap-vault.sh` で共通＝メイン機でも置けば同じように効く）。ファイルが存在するだけで installer が `settings.json` の `env` ブロックへ値を書き出すので、サブスク本命の機には置かない（置くと env が出る＝[[Decisions/2026-09-05-cast-table-unfreeze-completion]] の残余4）。
- 書けるのは**認証情報ではないモデルのピン留め値**だけ（絶対厳守③）。`AWS_ACCESS_KEY_ID`・`AWS_SECRET_ACCESS_KEY`・`AWS_SESSION_TOKEN`・`AWS_BEARER_TOKEN_BEDROCK`・`ANTHROPIC_API_KEY`・`ANTHROPIC_AUTH_TOKEN` 等は**書かない**（認証は AWS CLI／SSO 等の資格情報機構へ）。installer は許可リスト外のキーを取り込まない。
- 取り込まれるキー＝固定2つ（`CLAUDE_CODE_USE_BEDROCK`・`AWS_REGION`）＋動的（配役表の `role.*`／`fallback.*` に `provider=bedrock model=<別名>` の行があるときだけ、その別名に対応する `ANTHROPIC_DEFAULT_<別名大文字>_MODEL`）。使っていない別名のピン留め行は無視される。
- 書式＝1行1つの `KEY=VALUE`。空行と行頭 `#` の行は無視。⚠️ **値の後ろに `# コメント` を付けない**（`=` 以降がそのまま値になる）。コメントは行の上に書く。
- ピン留め値は推論プロファイル ID か ARN（`us.`／`eu.`／`global.`／`arn:` 始まり）。⚠️ これらは配役表 `profile.md` の `model=` には書けない（別名だけ）＝ピン留めはこのファイルにだけ置く。エイリアス（`opus` 等）はピンとして働かない（[[Knowledge/bedrock-claude-code-pitfalls]] §2）。
- ⚠️ 現在のメイン機はサブスク本命でこのファイルを置いていない。`config/bedrock.env.sample` の値は Bedrock を使う機（実運用値）から起こす（本ノートの雛形の考え方は installer／resolver の契約＝`install-main.sh` の許可リスト・`profile_resolve.py` の読取規則から導いたもの）。

## サンプル本文

本文は repo の `config/bedrock.env.sample` を見る（正本・実ファイル）。

## 確認手順（コピー後）

| キー | 確認手順 |
|---|---|
| `CLAUDE_CODE_USE_BEDROCK` | Bedrock 機なら `1`。サブスク本命機ならファイルごと置かない |
| `AWS_REGION` | 推論プロファイルのリージョンを AWS コンソールで確認して書く |
| `ANTHROPIC_DEFAULT_*_MODEL` | 配役表で使う別名の分だけ残し、ID を Bedrock コンソール（Cross-region inference）で確認する。使わない別名の行は削除する |
| 確認コマンド | `scripts/install-main.sh --print-bedrock-env-json`（許可されたキーだけが JSON に出る。認証情報らしいキーが出たら書式違反） |
