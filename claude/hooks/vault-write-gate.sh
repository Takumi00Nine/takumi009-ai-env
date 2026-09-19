#!/bin/bash
# PreToolUse(Edit|Write|NotebookEdit): 子（ラッパー起動のワーカー）向けの
# Vault 保護の柵（設計-v1.1.1.md §2.5・§3・裁定A）。
#
# 背景: `scripts/claude-exec.sh` が子を起動するとき、子の `--setting-sources`
# は `local` だけ（FR-9）なので、親の `~/.claude/settings.json` に登録された
# `delegation-gate-v2.sh`（リーダー専用の委任ゲート）は子に載らない。しかし
# `delegation-gate-v2.sh` を丸ごと子へ渡すと rule 2.5 以外（委任実績の有無等）
# が誤って効き、ワーカーの正当な編集まで拒否される（設計 notes §2.1）。
# そこで「Vault の AI 向け6フォルダへの書き込みを拒否する」判定だけを、この
# 専用フックへ切り出し、ラッパーが職種ごとの `--settings` に足す
# （`vault-scribe` の子には載せない＝記録職の正規の書き込み経路）。
#
# 判定式は `guard_common.sh` の `guard_is_vault_ai_path` を使う（6フォルダの
# literal はそこにしか書かない＝NFR-7・AC-10②。親側の `delegation-gate-v2.sh`
# rule 2.5 も同じ関数を使う）。
#
# ⚠️ 逃げ道のマーカー（親専用の `claude-vault-direct-ok-<sid>`）はここでは
# 見ない（子に逃げ道を持たせない＝設計 notes §2.1）。
# ⚠️ 判定材料が取れないとき（jq 不在・入力が空・パスが取れない等）は素通し
# （親の rule 2.5 と同じ向き＝このゲートは防御ではなく再発防止＝
# delegation-gate-v2.sh:24 の方針）。ただし共有部品 guard_common.sh 自体が
# 読めないときは別扱い（下記）＝この柵が持つ唯一の判定式なので、読めない
# まま素通しにはしない。
#
# 検証1巡目 I1-B1 対応: installer は本フックを `$HOME/.claude/hooks/
# vault-write-gate.sh`（repoへのsymlink）として配置する
# （`$HOME/.claude/hooks/lib/`は作らない）ため、`BASH_SOURCE[0]%/*`だけでは
# 実運用経路でguard_common.shを解決できない。claude/hooks/inprocess-gate.sh
# の resolve_inprocess_gate_self_dir() と同じ方式（自身のsymlinkを解決した
# 実体ディレクトリ直下のlib/を見る）に揃える。source失敗時は fail-close
# （denyしてexit 0＝子に載せた唯一のVault保護柵が無言で無効化される再発を
# 防ぐ。他の「判定材料が取れないときは素通し」箇所とは異なり、ここは
# 柵そのものが機能しない場合なので通さない）。
resolve_vault_gate_self_dir() {
  local src="${BASH_SOURCE[0]}"
  while [ -L "$src" ]; do
    local dir
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    case "$src" in
      /*) ;;
      *) src="$dir/$src" ;;
    esac
  done
  cd -P "$(dirname "$src")" && pwd
}
guard_common_load_error() {
  reason="vault-write-gate: 共有部品（guard_common.sh・cause=$1）を読み込めず、Vault保護を判定できません。フックの配置を確認してください。成果物は依頼文が指定した作業ディレクトリへ書いてください。"
  jq -n --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}' 2>/dev/null \
    || printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
  exit 0
}
SELF_DIR="$(resolve_vault_gate_self_dir 2>/dev/null)" || guard_common_load_error SELF_DIR_UNRESOLVABLE
[ -n "$SELF_DIR" ] || guard_common_load_error SELF_DIR_UNRESOLVABLE
# 検証2巡目 I2-M2 対応: env上書き口（GUARD_COMMON_LIB）は置かない（子が
# 持てない逃げ道になる＝裁定A「子に逃げ道を持たせない」に反するため撤去。
# 本フックは子に載る唯一のVault保護柵そのもの＝逃げ道を持たせてはならない。
# テスト用の差し替えは、実体ディレクトリごとsymlinkする既存の方式で足りる）。
# shellcheck source=lib/guard_common.sh
source "$SELF_DIR/lib/guard_common.sh" 2>/dev/null || guard_common_load_error GUARD_COMMON_UNREADABLE

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat 2>/dev/null || true)
[ -n "$input" ] || exit 0

fpath=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null) || exit 0
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null) || exit 0

[ -n "$fpath" ] || exit 0

# 相対パスは cwd で絶対化（delegation-gate-v2.sh と同じ扱い）
case "$fpath" in
  /*) : ;;
  *) fpath="${cwd%/}/$fpath" ;;
esac

if guard_is_vault_ai_path "$fpath"; then
  reason="vault-write-gate: Vault の AI 向け6フォルダへの書き込みは不可です。成果物は依頼文の作業ディレクトリへ書き、Vault への記録はリーダーへ報告してください。"
  jq -n --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
fi
exit 0
