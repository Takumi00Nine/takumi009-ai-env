#!/bin/bash
# bash-danger-gate.sh — PreToolUse(Bash) の危険コマンド deny ゲート
# 目的: プロンプトインジェクション等で騙されても、ツール境界で破壊的コマンドを実行不能にする最終防衛線。
#   ①リモートスクリプトのパイプ実行（curl/wget → shell）を無条件 deny
#   ②保護パス（Vault・~/.claude・~/.codex・~/.cmuxterm・HOME直下・/）への再帰 rm を deny
#   ③codex exec/codex resume（execの別名eを含む）の直接実行を deny（scripts/codex-exec.sh 経由のみ許可。単純コマンド単位で判定）
# 導入経緯: 2026-07-19 偽 system_warning 注入インシデント（Fragments/2026-07/2026-07-19）
# ③の導入経緯: 2026-09-06 codex exec 一本化（Claude CodeからのMCPサーバー
# 経由呼び出しを廃止し scripts/codex-exec.sh に一本化）。absolute-rules参照の
# 機械強制はラッパー内部に移した（execはPreToolUseフックの対象外のため）ため、
# ラッパーを経由しない直叩きが機械強制のバイパス経路にならないようここで塞ぐ。

cmd=$(jq -r '.tool_input.command // ""')

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' "$1"
  exit 0
}

# ① リモート取得内容をシェルへ流す実行（curl/wget ... | [sudo] bash/sh/zsh、bash <(curl ...)）
if printf '%s' "$cmd" | grep -Eqi '(^|[^[:alnum:]_])(curl|wget)[^|;&]*\|[[:space:]]*(sudo[[:space:]]+)?(bash|sh|zsh|source)([[:space:]]|$)'; then
  deny 'リモートスクリプトのパイプ実行（curl/wget | shell）はブロックされています。スクリプトは一旦ファイルに保存し、内容を確認してから実行してください（bash-danger-gate）。'
fi
if printf '%s' "$cmd" | grep -Eqi '(^|[^[:alnum:]_])(bash|sh|zsh)[[:space:]]+<\([[:space:]]*(curl|wget)'; then
  deny 'リモートスクリプトのプロセス置換実行（bash <(curl ...)）はブロックされています。スクリプトは一旦ファイルに保存し、内容を確認してから実行してください（bash-danger-gate）。'
fi

# ② 再帰 rm（rm -r/-R/--recursive）× 保護パス
if printf '%s' "$cmd" | grep -Eq '(^|[;&|[:space:]])(sudo[[:space:]]+)?rm[[:space:]]+(-[[:alnum:]]*[rR][[:alnum:]]*|--recursive)'; then
  # 保護パス: Vault / ~/.claude / ~/.codex / ~/.cmuxterm
  if printf '%s' "$cmd" | grep -Eq '(Data/obsidian|\.claude|\.codex|\.cmuxterm)'; then
    deny '保護パス（Vault・.claude・.codex・.cmuxterm）への再帰 rm はブロックされています。本当に必要な削除は本人が自分の手で実行してください（bash-danger-gate）。'
  fi
  # HOME 直下・ルートへの再帰 rm（rm -rf ~ / rm -rf /）
  if printf '%s' "$cmd" | grep -Eq 'rm[[:space:]]+-[[:alnum:]]*[rR][[:alnum:]]*[[:space:]]+("?\$HOME"?|~)?/?([[:space:]]|$)'; then
    deny 'ホーム直下またはルートへの再帰 rm はブロックされています（bash-danger-gate）。'
  fi
fi

# ③ codex exec / codex resume（execの別名eを含む）の直接実行
#    （scripts/codex-exec.sh を経由しないもの）。
#    ⚠️ 目的の明記（2026-09-06 リーダー裁定）: 本ルールの目的は
#    「ラッパー（absolute-rules機械強制を持つ）を経由し忘れる事故の防止」
#    であり、シェル構文を完全に解析してあらゆる回避策を防ぎ切ることでは
#    ない。悪意を持って正規表現の弱点を突く高度な難読化までは対象外
#    （残存限界はcodex_direct_call_check.pyのdocstring・本実装記録参照）。
#    判定は claude/hooks/lib/codex_direct_call_check.py（Python標準の
#    shlexモジュールでPOSIXシェルの引用符・エスケープ・コメントを正しく
#    解釈するトークナイザ）に委譲する。当初は正規表現だけで単純コマンド
#    分割・引用符除去・コメント除去・`--`終端の認識を自前実装していたが、
#    dogfoodレビュー（5巡）でエスケープされた引用符による対応ずれ
#    （`codex -c "x=a\"b" exec ...`で"exec"まで誤って消える等）を含む
#    複数のCriticalなバイパスが繰り返し見つかったため、車輪の再発明を
#    やめて委譲する方針に転換した（判定ロジックの詳細・既知の残存限界
#    ＝`sudo`/`env`/`command`前置・`codex review`/`queue`/`fork`等の
#    exec/resume以外の起動経路への非対応・は同ファイルのdocstring参照）。
#    python3が使えない場合・トークナイズ自体が失敗する場合（引用符の
#    閉じ忘れ等）は、位置関係を見ない簡易な語境界ベースの正規表現へ
#    fail-closedでフォールバックする（このフォールバック経路は
#    `codex --version`のような読み取り系も含め`codex`と`exec`/`e`/`resume`
#    が両方出現すれば単純にdenyする粗いものであり、通常経路（python3
#    経由）よりも過剰検知しやすいことを許容したうえでの安全側の設計）。
# installerはhookを個別symlinkしており（install-main.sh・bootstrap-vault.sh
# の resolve_bootstrap_self_dir と同じ事情）lib専用のsymlinkは持たないため、
# 本スクリプト自身のsymlinkを解決した実体ディレクトリ直下のlib/を見る。
_bdg_resolve_self_dir() {
  local src="${BASH_SOURCE[0]:-$0}"
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
_bdg_lib="$(_bdg_resolve_self_dir)/lib/codex_direct_call_check.py"
codex_direct_call=0
_bdg_fallback_check() {
  printf '%s' "$cmd" | grep -Eqi '(^|[^[:alnum:]_])codex([^[:alnum:]_]|$)' || return 1
  printf '%s' "$cmd" | grep -Eqi '(^|[^[:alnum:]_])(exec|e|resume)([^[:alnum:]_]|$)'
}
if command -v python3 >/dev/null 2>&1 && [ -f "$_bdg_lib" ]; then
  _bdg_result="$(printf '%s' "$cmd" | python3 "$_bdg_lib" 2>/dev/null)"
  case "$_bdg_result" in
    DENY) codex_direct_call=1 ;;
    ALLOW) codex_direct_call=0 ;;
    *) _bdg_fallback_check && codex_direct_call=1 ;;
  esac
else
  _bdg_fallback_check && codex_direct_call=1
fi
if [ "$codex_direct_call" = "1" ]; then
  deny 'Codex の起動は scripts/codex-exec.sh 経由のみです（absolute-rules の機械強制はラッパー内部にあります）。直接の codex exec / codex resume 呼び出しはブロックされています（bash-danger-gate）。'
fi

exit 0
