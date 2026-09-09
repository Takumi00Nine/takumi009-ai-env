---
date: 2026-09-08
updated: 2026-09-08
tags: [preference, core, profile, sample, model]
project: takumi009-ai-env
related:
  - "[[Preferences/profile-sample]]"
  - "[[Preferences/bedrock-env-sample]]"
  - "[[Decisions/2026-09-08-model-definitions-file]]"
aliases:
  - "モデル定義ファイルサンプル"
  - "models.conf サンプル"
  - "定義名テンプレ"
  - "models.conf案内"
---
# モデル定義ファイル サンプル（定義名でモデルを参照する）

## 要点
- **正本は repo の設定サンプル**（2026-09-08 本人決定）: `takumi009-ai-env` の `config/profile.md.sample`／`config/models.conf.sample`／`config/bedrock.env.sample`（実ファイル・値はメイン機の実値）が正本。本人が `~/.config/takumi009-ai-env/` へコピーして使う（`mkdir -p ~/.config/takumi009-ai-env && cp config/profile.md.sample ~/.config/takumi009-ai-env/profile.md` の要領。models.conf も同様・bedrock.env は Bedrock 機だけ）。サブ機はコピー後に `machine_role`（と必要なら `role.leader`）だけ書き換える。installer は実体が無いときだけ `config/profile.md.sample` を雛形としてコピーする（既存は壊さない）。symlink・同期処理は無い。
- 置き場＝`~/.config/takumi009-ai-env/models.conf`（コピー後の実体・機ごとに書く）。
- **配役表の役割の行には属性を書かない**＝`role.<職種>: configured model=<定義名>[,<定義名>…]` だけ。provider・model ID・effort 等の属性はすべてこのファイル側に書く（正本＝[[Preferences/profile-sample]] から移設）。
- ⚠️ **候補の並び順に優先度の意味は無い**（どれを使うかはリーダーがそのつど1つ選ぶ）。**例外はリーダー行だけで**、`settings.json` が値を1つしか持てないので**先頭の定義**を書き出す。これは1つに畳むための規則であって「先頭が最良」という意味ではない。
- ⚠️ **`fallback.<職種>` の候補は1件だけにする**（2件以上あると、本命が使えなくなったときに機構が選ばずに止まる）。

## サンプル本文

本文は repo の `config/models.conf.sample` を見る（正本・実ファイル）。

## 確認手順（コピー後、機体ごとに見直す）

| 属性 | サンプルの値（例） | 確認手順（1行） |
|---|---|---|
| `[定義名]` | `[opus-main]` | 自分で決めてよい（`^[a-z0-9][a-z0-9-]*$`）。配役表の `role.*`／`fallback.*` の `model=` からこの名前で参照する |
| `provider` | `anthropic-api` / `bedrock` / `external` | このマシンで実際に使う経路を選ぶ |
| `model` | 実モデルID（サンプルはメイン機の実値） | `anthropic-api`＝具体ID（別名は書かない）／`bedrock`＝別名だけ（実IDは `bedrock.env` のピン留め側）／`external`＝外部CLIが受理する実モデルID、または予約語（CLI側の既定を使う指定） |
| `execution` | `external-cli` | `provider=external` のときだけ必ず書く |
| `effort` | `high` | 任意。書かなければセッション既定を継承する。⚠️ 実際に効くのはリーダー行だけ（`settings.json` へ反映される）。ワーカー行の `effort` は意図の記録＝参考値で実行値ではない |
