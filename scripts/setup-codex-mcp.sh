#!/usr/bin/env bash
# Claude Code に codex MCP サーバーを登録する（mcp__codex__codex / codex-reply の実体。
# レビュー体制の中核）。install-main.sh の末尾から呼ばれる（install-sub.sh は
# install-main.sh に委譲しているので自動的に恩恵を受ける）。
#
# 冪等: 既に登録済みなら何もしない（`claude mcp get codex` の終了コードで判定。
# `claude mcp list` は全サーバーのヘルスチェックを伴い遅い場合があるため使わない）。
#
# codex バイナリの解決順序:
#   1. command -v codex （PATHに直接あれば最優先）
#   2. nodenv/anyenv の shim（$HOME/.anyenv/envs/nodenv/shims/codex）
#   3. どちらでも見つからなければ手動登録手順を表示して exit 1
#      （呼び出し元のinstall-main.shはこれをWARN扱いにして続行する設計＝
#      Claude Code未導入環境でinstaller全体を落とさないため）
#
# 過去の教訓（bare command はPATH問題で壊れる）に従い、**必ず絶対パスで登録する**
# （bare "codex" のような相対/PATH依存コマンドでは登録しない）。
#
# 登録コマンドの形式は実機の `claude mcp get codex` 出力
# （Command=<絶対パス>, Args=mcp-server, Scope=user）に基づいて確定した:
#   claude mcp add codex -s user -- <絶対パス> mcp-server
#
# 使い方: scripts/setup-codex-mcp.sh
# 注意: 本スクリプトは install-main.sh から自動的に呼び出される（単体で直接実行することも可能）。

set -euo pipefail

log() { echo "[setup-codex-mcp] $*"; }
fail() { echo "[setup-codex-mcp] FAIL: $*" >&2; exit 1; }

# `command -v` の結果が絶対パスであることを確認する。bare command 禁止の原則
# （過去の教訓＝PATH依存のMCP登録は壊れる）を徹底するため、`command -v` が
# シェル関数・エイリアス名・相対パス等（絶対パスでないもの）を返した場合は
# 「見つからなかった」扱いにして次の解決手段へフォールバックする
# （Codexレビュー指摘・Major）。
is_absolute_path() {
  case "$1" in
    /*) return 0 ;;
    *) return 1 ;;
  esac
}

# claude コマンドの解決（command -v が最優先。テストは PATH 前置でモックする）。
resolve_claude() {
  local p
  if p="$(command -v claude 2>/dev/null)" && is_absolute_path "$p"; then
    printf '%s' "$p"
    return 0
  fi
  if [ -x "$HOME/.anyenv/envs/nodenv/shims/claude" ]; then
    printf '%s' "$HOME/.anyenv/envs/nodenv/shims/claude"
    return 0
  fi
  return 1
}

# codex コマンドの解決（同上）。
resolve_codex() {
  local p
  if p="$(command -v codex 2>/dev/null)" && is_absolute_path "$p"; then
    printf '%s' "$p"
    return 0
  fi
  if [ -x "$HOME/.anyenv/envs/nodenv/shims/codex" ]; then
    printf '%s' "$HOME/.anyenv/envs/nodenv/shims/codex"
    return 0
  fi
  return 1
}

CLAUDE_BIN="$(resolve_claude)" || fail "claude コマンドが見つかりません（Claude Code が未導入の可能性）。導入後に再実行してください: scripts/setup-codex-mcp.sh"

if "$CLAUDE_BIN" mcp get codex >/dev/null 2>&1; then
  log "codex MCP は既に登録済みです（skip）"
  exit 0
fi

CODEX_BIN="$(resolve_codex)" || {
  # 手動案内は "$(command -v codex)" を使わない（Codexレビュー指摘・Major：
  # command -v がシェル関数名・相対パス等を返す環境だと、この案内文をそのまま
  # 実行するとbare/非絶対パス登録を誘導してしまい、スクリプト本体の
  # 「必ず絶対パスで登録する」原則と矛盾する）。プレースホルダを明示し、
  # 絶対パスであることの確認を促す。
  cat >&2 <<'EOF'
[setup-codex-mcp] FAIL: codex コマンドが見つかりません。
  以下のいずれかで導入してから再実行してください:
    - PATH に codex を通す（npm install -g 等でのグローバル導入）
    - anyenv/nodenv 経由で導入する
  導入後、次のいずれかを実行してください:
    scripts/setup-codex-mcp.sh
    claude mcp add codex -s user -- /absolute/path/to/codex mcp-server
      （/absolute/path/to/codex は実際の codex の絶対パスに置き換えること。
       "/" で始まらないパスやシェル関数名を渡さないよう注意）
EOF
  exit 1
}

log "codex MCP を登録します（bare command は使わず絶対パスで登録）: $CODEX_BIN"
"$CLAUDE_BIN" mcp add codex -s user -- "$CODEX_BIN" mcp-server
log "登録しました（確認: claude mcp get codex）"
