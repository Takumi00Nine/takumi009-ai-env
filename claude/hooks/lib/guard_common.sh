#!/bin/bash
# guard_common.sh — ガードの共有部品（設計-v1.1.1.md §3・D-2・裁定A）。
#
# 目的: `scripts/claude-exec.sh`（ラッパー）と `claude/hooks/agent-model-guard.sh`・
# `claude/hooks/delegation-gate-v2.sh`（rule 2.5）・`claude/hooks/vault-write-gate.sh`
# の4箇所が同じ判定（許容モデル別名の集合・委任実績マーカーの置き方・
# Vault の AI 向け6フォルダの判定）を持たないよう、正本をここ1箇所に集約する
# （FR-24・FR-25・NFR-7）。Bash 3.2 互換（連想配列を使わない）。
#
# `source` して使う（実行可能属性は付けるが、直接実行する用途は想定しない）。
# 何度 source しても安全（副作用は関数定義のみ）。

# --- 許容モデル別名（source of truth＝ここだけ。派生＝profile_resolve.py の
#     AGENT_MODEL_ALIASES の値集合。両者の一致はテストで突合する） -----------

# guard_allowed_model_aliases: 許容別名を空白区切りで標準出力する。
guard_allowed_model_aliases() {
  printf '%s\n' "fable opus sonnet haiku"
}

# guard_is_allowed_model_alias <値>: 属せば0・属さなければ1。
guard_is_allowed_model_alias() {
  local value="$1" alias
  for alias in $(guard_allowed_model_aliases); do
    [ "$alias" = "$value" ] && return 0
  done
  return 1
}

# --- 委任実績マーカー（source of truth＝ここだけ。名前の規則はここだけが持つ） -

# guard_marker_path <sid>: マーカーファイルの絶対パスを標準出力する。
guard_marker_path() {
  local sid="$1"
  printf '%s\n' "${GATE_MARKER_DIR:-/tmp}/claude-delegated-ok-$sid"
}

# guard_mark_delegation <sid>: マーカーを touch する。sid が空なら何もしない。
# 書き込み失敗は握り潰して0を返す（呼び出し側のspawn/起動を止めない＝既存
# agent-model-guard.sh と同じ流儀）。
guard_mark_delegation() {
  local sid="$1"
  [ -n "$sid" ] || return 0
  : > "$(guard_marker_path "$sid")" 2>/dev/null || true
  return 0
}

# --- Vault の AI 向け6フォルダ（source of truth＝ここだけ。裁定A） -----------
# `delegation-gate-v2.sh` rule 2.5 と `vault-write-gate.sh` の両方がこの2関数を
# 呼ぶ（6フォルダの literal はここにしか書かない＝NFR-7・AC-10②）。

# guard_vault_ai_prefixes: $HOME/Data/obsidian 配下のAI向け6フォルダの
# プレフィックス（末尾に /* を付けない絶対パス）を1行ずつ標準出力する。
guard_vault_ai_prefixes() {
  local base="${HOME:-}/Data/obsidian"
  printf '%s\n' \
    "$base/Fragments" \
    "$base/Knowledge" \
    "$base/Decisions" \
    "$base/Projects" \
    "$base/Preferences" \
    "$base/Personal"
}

# guard_is_vault_ai_path <絶対パス>: 6フォルダ配下（フォルダ自身は含まず、
# 配下のファイル/ディレクトリだけ）なら0・それ以外は1。
guard_is_vault_ai_path() {
  local path="$1" prefix
  while IFS= read -r prefix; do
    case "$path" in
      "$prefix"/*) return 0 ;;
    esac
  done <<EOF
$(guard_vault_ai_prefixes)
EOF
  return 1
}
