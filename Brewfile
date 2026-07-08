# takumi009-ai-env の実行に必要な Homebrew formula。
# `brew bundle` で一括インストールできる（README.md「導入手順」参照）。
#
# 本体アプリ（Claude Code / Codex）は brew 管理外（各公式サイトから導入する。
# 言語ランタイムを brew で直接入れない方針＝anyenv-runtime運用と同様、
# アプリ本体もbrewの管轄外として扱う）。

brew "ripgrep"   # export-public-vault.sh・check-drift.sh 等の private link / NGワード検出（rg コマンド）
brew "gitleaks"  # export-public-vault.sh 等のシークレット検出
brew "jq"        # Claude Code hooks（claude/hooks/*.sh）・settings.json の hook コマンドが使用
brew "gh"        # GitHub CLI。private repo 作成・operateの運用（Preferences/git-workflow）で使用。
                 # check-drift.sh の private repo可視性検証（gh repo view）でも使用（未導入でも
                 # driftにはせずWARN表示のみで動作する＝必須ではないが導入を推奨）。
