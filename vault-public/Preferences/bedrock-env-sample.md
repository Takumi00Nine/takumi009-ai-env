---
date: 2026-09-07
updated: 2026-09-07
tags: [preference, core, profile, sample, bedrock]
project: takumi009-ai-env
related:
  - "[[Preferences/profile-sample]]"
  - "[[Knowledge/bedrock-claude-code-pitfalls]]"
  - "[[Decisions/2026-08-21-machine-role-model-assignment]]"
  - "[[Decisions/2026-09-01-role-cast-table-unfreeze]]"
aliases:
  - "bedrock.env サンプル"
  - "Bedrockピン留めファイル"
  - "ピン留めenvの書き方"
---
# bedrock.env サンプル（Bedrock 機のピン留め値・非配布）

## 要点
- 置き場＝`~/.config/takumi009-ai-env/bedrock.env`（パーミッション 0600・repo 管理外・このマシン専用）。**メイン／サブを問わず、Bedrock を使う機にだけ置く**（読む仕組みは `install-main.sh`・`install-sub.sh`・`bootstrap-vault.sh` で共通＝メイン機でも置けば同じように効く）。ファイルが存在するだけで installer が `settings.json` の `env` ブロックへ値を書き出すので、サブスク本命の機には置かない（置くと env が出る＝[[Decisions/2026-09-05-cast-table-unfreeze-completion]] の残余4）。
- 書けるのは**認証情報ではないモデルのピン留め値**だけ（絶対厳守③）。`AWS_ACCESS_KEY_ID`・`AWS_SECRET_ACCESS_KEY`・`AWS_SESSION_TOKEN`・`AWS_BEARER_TOKEN_BEDROCK`・`ANTHROPIC_API_KEY`・`ANTHROPIC_AUTH_TOKEN` 等は**書かない**（認証は AWS CLI／SSO 等の資格情報機構へ）。installer は許可リスト外のキーを取り込まない。
- 取り込まれるキー＝固定2つ（`CLAUDE_CODE_USE_BEDROCK`・`AWS_REGION`）＋動的（配役表の `role.*`／`fallback.*` に `provider=bedrock model=<別名>` の行があるときだけ、その別名に対応する `ANTHROPIC_DEFAULT_<別名大文字>_MODEL`）。使っていない別名のピン留め行は無視される。
- 書式＝1行1つの `KEY=VALUE`。空行と行頭 `#` の行は無視。⚠️ **値の後ろに `# コメント` を付けない**（`=` 以降がそのまま値になる）。コメントは行の上に書く。
- ピン留め値は推論プロファイル ID か ARN（`us.`／`eu.`／`global.`／`arn:` 始まり）。⚠️ これらは配役表 `profile.md` の `model=` には書けない（別名だけ）＝ピン留めはこのファイルにだけ置く。エイリアス（`opus` 等）はピンとして働かない（[[Knowledge/bedrock-claude-code-pitfalls]] §2）。
- 本サンプルは特定機の実値ではなく雛形（値は `XXXX`）。コピーした本人が自分の機の値へ書き換える。⚠️ 現在のメイン機はサブスク本命でこのファイルを置いていないため、本サンプルは実体からの写しではなく installer／resolver の契約（`install-main.sh` の許可リスト・`profile_resolve.py` の読取規則）から起こした。

## サンプル本文（コピーしてこのまま編集する）

```bash
# =====================================================================
# bedrock.env（このマシン専用・非配布・repo管理外・0600）
#  書式: KEY=VALUE を1行1つ。空行と行頭 # は無視。値の後ろにコメントを書かない
#  ⚠️ 認証情報（AWSアクセスキー・セッショントークン・Bearerトークン・APIキー）は
#     書かない。書けるのは「どのモデルを指すか」のピン留め値だけ
# =====================================================================

# Bedrock 経路を有効にする（1 か true）。この行が無い／0 なら経路は無効
CLAUDE_CODE_USE_BEDROCK=1

# 推論プロファイルが存在するリージョン
AWS_REGION=XXXX

# ピン留め（配役表で provider=bedrock model=<別名> を使っている別名の分だけ書く）
# 値＝推論プロファイルID または ARN（例: us.anthropic.… / arn:aws:bedrock:…）
ANTHROPIC_DEFAULT_OPUS_MODEL=XXXX
ANTHROPIC_DEFAULT_SONNET_MODEL=XXXX
ANTHROPIC_DEFAULT_HAIKU_MODEL=XXXX
ANTHROPIC_DEFAULT_FABLE_MODEL=XXXX
```

## 確認手順（コピー後）

| キー | 確認手順 |
|---|---|
| `CLAUDE_CODE_USE_BEDROCK` | Bedrock 機なら `1`。サブスク本命機ならファイルごと置かない |
| `AWS_REGION` | 推論プロファイルのリージョンを AWS コンソールで確認して書く |
| `ANTHROPIC_DEFAULT_*_MODEL` | 配役表で使う別名の分だけ残し、ID を Bedrock コンソール（Cross-region inference）で確認する。使わない別名の行は削除する |
| 確認コマンド | `scripts/install-main.sh --print-bedrock-env-json`（許可されたキーだけが JSON に出る。認証情報らしいキーが出たら書式違反） |
