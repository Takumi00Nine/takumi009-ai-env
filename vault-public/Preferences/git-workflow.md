---
date: 2026-06-14
tags: [preference, git, github, security]
project: meta
updated: 2026-07-28
related:
  - "[[Preferences/readme-bilingual]]"
aliases:
  - "privateから作成"
  - "GitHub Release提案"
  - "リポジトリをpublic"
---

# git push運用と権限分担

GitHub への commit/push の運用ルールと権限モデル。

## 役割分担

| 作業 | 担当 |
|---|---|
| リポジトリ作成（private） | **AI**（`gh repo create --private`） |
| ローカル git init・リモート設定・add・commit・push | **AI** |
| README・.gitignore・**LICENSE**・その他ドキュメント | **AI**（[[Preferences/readme-bilingual]]） |
| **public化**（private→public への可視性変更） | **ユーザー**（GitHub UI または `gh repo edit --visibility public`） |

## 🚩 ルール：公開リポジトリには LICENSE を必ず含める

**public化するリポジトリには、必ず LICENSE ファイルを含めてからプッシュする。**

- ライセンスはユーザーが指定しなければ **MIT** をデフォルトとする。
- 著作権者は GitHub アカウント名（`Takumi00Nine`）、年は作成年を記載。
- README の英語版にライセンスセクション（`## License`）も併記する。
- `.gitignore` と同様に初回コミットに含める。

**Why:** AIにリポジトリ作成〜pushまで一気通貫で任せ、外部公開の最終ゲートだけユーザーが握る。

**How to apply:**
- AIはリポジトリを必ず `--private` で作成し、コードをpushするところまでを完結させる。
- public化はAIから指示しない。ユーザーが自分のタイミングでGitHub UI（Settings → Danger Zone → Change visibility）または `gh repo edit --visibility public` を実行する。
- AIはpublic化を促す案内を出してよいが、コマンドは実行しない。

**認証の注意点:** `gh` CLI と `git push` は別の認証を使う。新規リポジトリへ push できない場合は認証側の対象リポジトリ設定を確認する（実運用の詳細＝[[Knowledge/github-auth-ops]]・private）。

## 🚩 ルール：リポジトリ作成は必ずprivateから

**新規リポジトリは必ず最初に private で作成する。`gh repo create --public` は使わない。**

- 作成は常に `gh repo create <name> --private`（明示private必須）。
- public化は別ステップとして行い、ユーザーが担当する（上記役割分担参照）。
- 結果の流れ：**①AI が private 作成 → ②AI がコミット・プッシュ → ③ユーザーが public 化**。

**Why:** 作成と同時にpublicだと、確認・監査の前に中身が露出するリスクがある。

## 🚩 最重要ルール：public化はユーザーが実行する

**`gh repo edit --visibility public` 等のpublic化操作はAIが実行しない。ユーザーが自分で行う。**

- AIはこの操作を代行しない（明示許可があっても実行しない）。
- 案内・手順の説明はしてよい。
- フックで機械的にもブロック済み（下記参照）。

**Why:** 公開は取り消しにくく外部露出が伴う重大操作。ユーザーが最終の門番。

## フックによる機械的な強制

`~/.claude/settings.json` の PreToolUse(Bash) フックで public 化系を **deny でブロック**:
- `gh repo create --public` / `gh repo edit --visibility public`（`=public` 含む）
- `gh repo create` で `--private` が無いもの（private既定に依存させない）
- `gh api` ＋ `visibility` ＋ `public`（REST/GraphQL 経由の公開化）
- `curl`/`wget` ＋ `api.github.com` ＋ `visibility` ＋ `public`（API直叩き）

commit/push/private作成/force-push・`visibility=private`・visibilityの読み取りは許可。フックの確認・変更は `/hooks`。

## 権限モデル

- git push の認証は **OS の資格情報ストア**を使う（トークンをファイルに書かない。設定・スコープの実運用詳細＝[[Knowledge/github-auth-ops]]・private）。
- commit/push はローカル git で行う（MCP の push_files は履歴が分かれるので使わない。MCP は Issue/PR/検索/読み取り用）。

## 🚩 ルール：push 前に未push コミットを整理する（push済みは書き換えない）

**push する前に、未push のローカルコミット（`origin/main..HEAD`）を少数の論理的コミットに集約してから push する。** wip/fixup/export snapshot 等のノイズを潰し、意味の区切りでまとめる。

- **書き換えてよいのは未push 分だけ。push 済みコミット（特に `origin/main`）は書き換えない＝force-push しない。**
  - **Why**: サブ機はセッション開始のたびに（SessionStartフック`claude/hooks/check-sub-update.sh`が）このリポジトリ（takumi009-ai-env）への未反映コミットを確認し、あれば `scripts/update-sub.sh`（`git pull --ff-only`）の手動実行を案内する運用（2026-07-23〜。それ以前は1日2回の無人自動pullだった）。push済み履歴を rewrite すると ff 不可で pull が失敗し、**サブ機の追従が止まる**（復旧に各クローンで手動 `git fetch && git reset --hard origin/main` が必要）。公開履歴の書き換えは取り消しにくい。※自分専用の未共有ブランチの整理に force-push を使うのは可。禁止対象は「他が既に追従している push済み履歴」。
- **やり方（この環境は `git rebase -i` 不可）**:
  - 1コミット化: `git reset --soft origin/main && git commit`。
  - 複数コミット化: フェーズ境界ごとに `git reset --hard <境界commit>` → `git reset --soft <前の新commit>` → `git commit` を繰り返す（各中間ツリーが元と一致＝**内容ロスなし**）。
  - **集約後、元HEADとのツリー差分がゼロであることを検証**（`git diff --quiet <backup> HEAD`）してから本ブランチを移す。**バックアップブランチ**（例 `backup-before-tidy`）を push まで残す。
- **粒度の既定＝「1 push 1 コミット」（2026-07-28 本人決定・都度の確認は不要）**: push は「1つの改修を加えた」という意味の単位なので、未push分は原則1コミットに集約してから push する（例外を作りたい場合のみ本人に確認）。作業中の細かいコミットは自由に積んでよいが、push 直前に必ず畳む。**push 自体は本人専任**（外部脳系リポジトリ＝[[Preferences/coding-delegation]]）。

**Why:** fixup/wip/export の細かいコミットがそのまま公開履歴に残ると、後から「何が入ったか」を追いにくい。push は不可逆な公開操作なので、その直前に一度きれいにする。ただし整理は"まだ誰も見ていない未push分"に限定し、既に共有された履歴には触れない。

## 🚩 ルール：GitHub Release はキリの良いタイミングで提案する

**プロジェクトが区切りを迎えたとき、GitHub Release 作成をユーザーに提案する。**

- **提案トリガー**：プロジェクト `status: completed` への更新時 / 公開リポジトリへの初回 push 完了時 / 「リリースしよう」「公開した」などの発言時。
- **AI が実行する**：`gh release create <tag> --title "..." --notes "..."` で作成まで完結。
- リリースノートは**日英バイリンガル**で書く（[[Preferences/readme-bilingual]] と同じ方針）。
  - 冒頭に言語ナビ：`[English](#english) | [日本語](#japanese)`
  - `## English` セクション（全文英語）→ `---` → `## 日本語` セクション（全文日本語）の2部構成。
- 各セクションにバージョン・主要機能・必要環境・クイックスタートを含める。
- タグは `vX.Y.Z` 形式（初回は `v1.0.0`）。

**Why:** GitHub Release は「この状態が安定版」という意思表示になり、使う人が判断しやすくなる。提案を忘れると作られないまま終わることが多い。

**How to apply:** 作業完了報告とセットで「GitHub Release も作りますか？」と一言添える（強制ではなく提案）。

## 🚩 ルール：Topics は公開リポジトリに必ず設定する

**public リポジトリには必ず Topics（検索タグ）を設定する。**

- **AI が実行する**：`gh repo edit <repo> --add-topic <tag>` で追加（ブラウザ不要）。
- **タイミング**：GitHub Release 作成と同じタイミング（公開・完了時）に合わせて設定。
- Topics 候補は言語・主要ライブラリ・用途から 5〜8件を選ぶ。

**Why:** Topics がないとリポジトリが検索・発見されにくい。CLI で完結するので能動的に行う。

**Note:** `github-manual-ops.md` の「Topics編集はブラウザ」はユーザーが自分で編集する場合の案内。AI は `gh repo edit --add-topic` で代行できる。

関連: [[Preferences/github-manual-ops]] [[Preferences/coding-delegation]] [[Preferences/absolute-rules]]
