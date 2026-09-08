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
---
# モデル定義ファイル サンプル（定義名でモデルを参照する・非配布）

## 要点
- 置き場＝`~/.config/takumi009-ai-env/models.conf`（repo 管理外・非配布・機ごとに書く。`bedrock.env` と同じ扱い）。
- **配役表の役割の行には属性を書かない**＝`role.<職種>: configured model=<定義名>[,<定義名>…]` だけ。provider・model ID・effort 等の属性はすべてこのファイル側に書く（正本＝[[Preferences/profile-sample]] から移設）。
- ⚠️ **候補の並び順に優先度の意味は無い**（どれを使うかはリーダーがそのつど1つ選ぶ）。**例外はリーダー行だけで**、`settings.json` が値を1つしか持てないので**先頭の定義**を書き出す。これは1つに畳むための規則であって「先頭が最良」という意味ではない。
- ⚠️ **`fallback.<職種>` の候補は1件だけにする**（2件以上あると、本命が使えなくなったときに機構が選ばずに止まる）。
- **このファイルは配らない**（機ごとに書く。`bedrock.env` と同じ扱い）。

## サンプル本文（コピーしてこのまま編集する）

```conf
# =====================================================================
# models.conf（このマシン専用・非配布・repo管理外）
#  置き場: ~/.config/takumi009-ai-env/models.conf
#  書式:  [定義名] の行で1つの定義が始まり、次の [ ] か行末までが中身
#         属性は key=value を1行1つ。値にスペースは書けない
#  空行と行頭 # は無視。⚠️ 値の後ろにコメントを書かない
#  ⚠️ 認証情報は書かない。ここに書くのは「どのモデルをどの経路で使うか」だけ
#  ⚠️ 定義名は自分で決めてよい（^[a-z0-9][a-z0-9-]*$）。配役表からこの名前で参照する
#  ⚠️ 下の XXXX は雛形。コピーしてから自分の機の値へ書き換える
# =====================================================================

# --- サブスク／ネイティブAPI経由（model は具体ID。別名を書かない）---
[opus-main]
provider=anthropic-api
model=XXXX
effort=high

[sonnet-main]
provider=anthropic-api
model=XXXX

# --- 外部CLI経由（Codex など）------------------------------------
#  model = 外部CLIが受理する実モデルID、または予約語（CLI側の既定を使う指定）。
#          予約語を書いたときはラッパーへ --model を渡さない
#  ⚠️ provider=external のときは execution を必ず書く
[codex-high]
provider=external
execution=external-cli
model=XXXX
effort=high

# --- Bedrock 経由（model は別名だけ。実IDは bedrock.env のピン留め側）---
[bedrock-opus]
provider=bedrock
model=XXXX
```

## 確認手順（コピー後、機体ごとに見直す）

| 属性 | サンプルの値（例） | 確認手順（1行） |
|---|---|---|
| `[定義名]` | `[opus-main]` | 自分で決めてよい（`^[a-z0-9][a-z0-9-]*$`）。配役表の `role.*`／`fallback.*` の `model=` からこの名前で参照する |
| `provider` | `anthropic-api` / `bedrock` / `external` | このマシンで実際に使う経路を選ぶ |
| `model` | `XXXX` | `anthropic-api`＝具体ID（別名は書かない）／`bedrock`＝別名だけ（実IDは `bedrock.env` のピン留め側）／`external`＝外部CLIが受理する実モデルID、または予約語（CLI側の既定を使う指定） |
| `execution` | `external-cli` | `provider=external` のときだけ必ず書く |
| `effort` | `high` | 任意。書かなければセッション既定を継承する。⚠️ 実際に効くのはリーダー行だけ（`settings.json` へ反映される）。ワーカー行の `effort` は意図の記録＝参考値で実行値ではない |
