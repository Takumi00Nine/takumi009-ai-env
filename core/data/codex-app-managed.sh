# Codex TOML のアプリ管理分類。install-main.sh と check-drift.sh の共通定義。
KNOWN_APP_MANAGED_TOML_TABLE_PREFIXES=(
  "marketplaces"            # プラグインのキャッシュパス・last_updated。次回起動時にCodexが再スキャンする
  "hooks.state"              # 機固有の有効・無効と信頼状態（installer が保持する）
  "projects"                 # フォルダごとのtrust_level履歴
  "tui"                      # オンボーディング通知の既読カウンタ等（実質的な設定ではない）
  "shell_environment_policy" # Codex.appがファイル末尾の機械管理領域に自動追記するセクション。ビルド毎に変わるNODE_REPL_TRUSTED_BROWSER_CLIENT_SHA256S等を含む。2026-08-03のアプリ書換で出現・2026-08-05実測確認
  # 2026-09-19 着手順3（設計 §4.1・本人裁定）: Codex Desktopが起動時に書き直す
  # 3テーブル。監視対象はテンプレのうち本人が決めたキー（service_tier・
  # approval_policy・model・model_reasoning_effort・sandbox_workspace_write.
  # network_access・features.hooks・features.js_repl）だけになる。
  "plugins"                  # バンドルプラグインの目録（版ごとに増減・enabledの本人設定はアプリ側が保持）
  "mcp_servers"              # 同梱MCP（node_repl・computer-use）の起動設定とenv＝アプリが版ごとに書き直す
  "desktop"                  # デスクトップ設定（アプリのUIから変わる）
)
KNOWN_APP_MANAGED_TOML_LEAF_KEYS=(
  "notify"                                    # Codexアプリがインストール時のパスで自動再設定する。ユーザーがテンプレ上でコメントアウトして無効化していても実ファイルには復活しうる
  "NODE_REPL_TRUSTED_BROWSER_CLIENT_SHA256S"  # Codex.appの内部ビルドに紐づくハッシュ（アップデートのたび変わる）
  "BROWSER_USE_CODEX_APP_VERSION"             # Codex.appのバージョン文字列（アップデートのたび変わる）
  "NODE_REPL_TRUSTED_CODE_PATHS"              # ChatGPT.appが自パス(cua_node/lib/node_modules)を追記する実績あり（2026-08-14実測・本人裁定）。テンプレにも記載があるが下記のとおりアプリ管理判定を優先するため、install時の基底値提供とdrift監視除外を両立できる
)

