---
date: 2026-08-30
updated: 2026-08-30
tags: [preference, core, profile, sample]
project: takumi009-ai-env
related:
  - "[[Preferences/core-conduct]]"
  - "[[Preferences/core-workflow]]"
aliases:
  - "最小能力表"
  - "プロファイルサンプル"
---
# プロファイルサンプル（最小能力表・7キー）

## この案の要点
- キーは§3.3.0が定義する7つだけ（`inventory_source`／`reviewer`／`vault_write`／`vault_scope`／`ui.user_call`／`git_role`／`web_verification`）。validator・版管理・配役表は持たない（凍結側）。
- **本サンプルの値はメイン機の実運用値である**（2026-08-30本人裁定＝「メイン機の実値を既定値に戻す」）。コピーすれば即動く。
- ⚠️ **サブ機・Bedrock機ではこの値のままでは成立しない項目がある**（特に`vault_scope`はマシンによって正しい値が真逆に近いほど異なる＝§6.2破綻④、`web_verification`はBedrock機では組み込み検索WebSearchが使えないことが公式確定済み＝F7）。**コピー後、機体ごとに下表「確認手順」に従って値を見直すこと**（サブ機での運用は「コピー後に自分で調整する」前提）。
- `git_role`は最低契約③どおりrepoスコープ付きで書く（無限定に「pull専用」と書くと社内リポジトリへのcommitまで禁じてしまう事故を避けるため）。

## frontmatter案（メイン機の実値。コピー直後からそのまま動く。サブ/Bedrock機では要見直し）

```yaml
---
inventory_source: Vault(Preferences/Knowledge直下)＋work配下のtools/（プロジェクト一覧。専用の棚卸し資料は無い）
reviewer: configured(Codex一次レビュー・mcp__codex__codex経由)
vault_write: configured(vault-scribe teammateへ委任)
vault_scope: Vault全体(Data/obsidian配下)
ui.user_call: configured(SendMessage to: main／本人への確認質問)
git_role: takumi009-ai-env repo=commit可(feature branch経由・push可否は運用ルールに従う)。それ以外のrepoは都度本人に確認
web_verification: configured(WebSearch/WebFetch)
---
```

## 各キーの根拠・確認手順（コピー後、機体ごとに見直す）

| キー | 値（メイン機） | 根拠 | 確認手順（1行。サブ/Bedrock機で見直す際に使う） |
|---|---|---|---|
| `inventory_source` | `Vault(Preferences/Knowledge直下)＋work配下のtools/（プロジェクト一覧。専用の棚卸し資料は無い）` | work配下のtools/の実在を確認済み（複数プロジェクトディレクトリが存在。専用のtools-inventory文書は無い） | このマシンでwork配下の`tools/`の実在を`ls`で確認し、実在すればそのパスを維持、無ければ`Vault(Preferences/Knowledge直下)`のみに削る |
| `reviewer` | `configured(Codex一次レビュー・mcp__codex__codex経由)` | `mcp__codex__codex`が実際に呼び出せることを確認済み | `claude mcp list`（またはCodex MCPサーバー登録確認コマンド）で`mcp__codex__codex`が使える状態か確認する。使えなければ値を書き換える |
| `vault_write` | `configured(vault-scribe teammateへ委任)` | bootstrap-vault.shのDIRECTIVE文言「執筆担当は常駐チームメイトvault-scribeのみ（リーダー直筆は禁止）」と一致する設計上の既定経路 | チーム構成にvault-scribeロールが実際に起動できるか確認する。委任先が無ければ`unavailable`にする |
| `vault_scope` | `Vault全体(Data/obsidian配下)` | Data/obsidian直下にprivate層込みの全フォルダ（Blogs/Decisions/Explorations/Fragments/Knowledge/Personal/Preferences/Projects）が揃っていることを確認済み | このマシンのData/obsidian配下がVault全体（private含む）かPreferences配下のみのpublicスナップショットかを確認し、後者（サブ機）なら`Preferences配下のみ`へ書き換える |
| `ui.user_call` | `configured(SendMessage to: main／本人への確認質問)` | `SendMessage`で実際にリーダーへ送信できることを確認済み | このマシンでSendMessage以外の呼び出し手段（cmux notify等）が必要か確認し、必要なら`configured(...)`の形で書き換える |
| `git_role` | `takumi009-ai-env repo=commit可(feature branch経由・push可否は運用ルールに従う)。それ以外のrepoは都度本人に確認` | `takumi009-ai-env`リポジトリのfeature branchへの実際のcommitで確認済み。他repoの立場は本人裁定が無い（H5未決）ため値を発明しない | 社内・第三者リポジトリでの立場（pull専用かpush可か）が決まったら本人に確認のうえ、repoスコープ付きで追記する |
| `web_verification` | `configured(WebSearch/WebFetch)` | `WebFetch`で実際に外部ドキュメントを取得できることを確認済み | このマシンで実際にWebSearch/WebFetchツールを実行して使えるか確認する。Bedrock機では組み込み検索（WebSearch）が使えないことが公式確定済み（F7）なので`unavailable`または個別の代替手段へ書き換える |

## サンプルの位置づけ（unknown・sentinelを使わない理由）
本サンプルは全キーをメイン機の実値で埋めている（2026-08-30本人裁定）。ワーカー側実装（`bootstrap-vault.sh` `resolve_local_profile`関数）が持つfail-soft機構（値が空文字列のキーをunknownへ正規化する・sentinel`<fill-in>`を検出するとT2で最小能力へ倒す等）はコードとして維持されるが、**本サンプルはこれらの機構を意図的に発火させない**（コピー直後から通常のprofileとして機能する）。**サブ機・Bedrock機で値がそのまま成立しない項目（特に`vault_scope`・`web_verification`）は、コピー後に本人が確認手順に従って書き換える運用**とする（「コピーすれば動く」を優先し、機体差異の吸収は運用側の責務とする）。
