#!/bin/bash
# bash-policy-gate.sh — PreToolUse(Bash) の方針ガード（3 規則・deny ゲート）
# 2026-09-19 段3-5 τ: settings.json の PreToolUse Bash に inline（sh -c・timeout
# 未指定＝既定 600 秒・テスト不能）で並んでいた 3 本を 1 ファイルへ移した。
# 判定式（grep -E の正規表現・語リスト）と deny 文面は inline から verbatim。
#   R1 公開ガード（絶対厳守②・git-workflow）: gh repo create --public／
#      gh repo edit --visibility public／gh repo create の --private 未明示／
#      gh api … visibility … public／curl|wget … api.github.com … visibility … public
#   R2 pip 仮想環境（python-venv）: pip|pip3 install・python -m pip install を
#      仮想環境の根拠（VIRTUAL_ENV／CONDA_PREFIX／activate／venv/bin/pip／
#      VIRTUAL_ENV=）なしで実行するのを deny。uv pip は対象外
#   R3 brew ランタイム（anyenv-runtime）: brew install|reinstall|upgrade の
#      引数に言語ランタイム 21 語（@version 付き・大小無区別）
# 評価順 R1→R2→R3（各規則は deny で終了するため順序は結果に影響しない）。
# 契約は bash-danger-gate.sh と同じ＝deny は標準出力の JSON で表現し、どの経路
# でも exit 0（会話を止めない）。deny JSON は jq --arg で組み立てる（inline 時代
# の brew 規則は `${blocked}` を printf で文字列補間しており `"` を含む token で
# JSON が壊れた＝ファイル化で jq --arg に揃えた。jq 不在は inline も同じく
# 入力を読めず allow）。

cmd=$(jq -r '.tool_input.command // ""' 2>/dev/null)

deny() {
  jq -cn --arg reason "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
  exit 0
}

# R1 公開ガード（5 分岐）
if printf '%s' "$cmd" | grep -Eqi '(^|[[:space:]/])gh[[:space:]]+repo[[:space:]]+create' && printf '%s' "$cmd" | grep -Eq -- '--public([[:space:]]|=|$)'; then
  deny 'リポジトリの公開はブロックされています。publicにするにはユーザーが明示的に「はい、公開してください」と伝える必要があります（git-workflowルール）。'
fi
if printf '%s' "$cmd" | grep -Eqi '(^|[[:space:]/])gh[[:space:]]+repo[[:space:]]+edit' && printf '%s' "$cmd" | grep -Eqi -- '--visibility[[:space:]=]+public'; then
  deny 'private→publicの変更はブロックされています。ユーザーが明示的に「はい、公開してください」と伝える必要があります（git-workflowルール）。'
fi
if printf '%s' "$cmd" | grep -Eqi '(^|[[:space:]/])gh[[:space:]]+repo[[:space:]]+create' && ! printf '%s' "$cmd" | grep -Eq -- '--private([[:space:]]|=|$)'; then
  deny 'gh repo create は必ず --private を明示してください（private既定に依存しない方針）。public化は作成と分離し、ユーザーの明示許可後に行います（git-workflow/absolute-rulesルール）。'
fi
if printf '%s' "$cmd" | grep -Eqi '(^|[[:space:]/])gh[[:space:]]+api' && printf '%s' "$cmd" | grep -Eqi 'visibility' && printf '%s' "$cmd" | grep -Eqi 'public'; then
  deny 'GitHub API(gh api)経由のpublic化はブロックされています。ユーザーが明示的に「はい、公開してください」と伝える必要があります（git-workflow/absolute-rulesルール）。'
fi
if printf '%s' "$cmd" | grep -Eqi '(^|[[:space:]/])(curl|wget)' && printf '%s' "$cmd" | grep -Eqi 'api.github.com' && printf '%s' "$cmd" | grep -Eqi 'visibility' && printf '%s' "$cmd" | grep -Eqi 'public'; then
  deny 'curl/wget 経由のGitHub public化はブロックされています。ユーザーの明示許可が必要です（git-workflow/absolute-rulesルール）。'
fi

# R2 pip 仮想環境
is_pip=0
printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]_])(pip|pip3)[[:space:]]+install' && is_pip=1
printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]_])python[0-9.]*[[:space:]]+-m[[:space:]]+pip[[:space:]]+install' && is_pip=1
printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]_])uv[[:space:]]+pip[[:space:]]' && is_pip=0
if [ "$is_pip" = "1" ]; then
  venv_ok=0
  [ -n "$VIRTUAL_ENV" ] && venv_ok=1
  [ -n "$CONDA_PREFIX" ] && venv_ok=1
  printf '%s' "$cmd" | grep -Eq '(source|\.)[[:space:]]+[^;&|]*activate' && venv_ok=1
  printf '%s' "$cmd" | grep -Eq 'venv[^[:space:]]*/bin/(pip|python)' && venv_ok=1
  printf '%s' "$cmd" | grep -Eq 'VIRTUAL_ENV=' && venv_ok=1
  if [ "$venv_ok" = "0" ]; then
    deny 'グローバルへの直接pip installはブロックされています。先に仮想環境を用意してください：python -m venv .venv && source .venv/bin/activate してから pip install。.venv/bin/pip 等の明示パスや uv pip も可（python-venvルール）。'
  fi
fi

# R3 brew ランタイム（21 語）
if printf '%s' "$cmd" | grep -Eqi '(^|[^[:alnum:]_])brew[[:space:]]+(install|reinstall|upgrade)([[:space:]]|$)'; then
  set -f
  args=$(printf '%s' "$cmd" | sed -E 's/.*brew[[:space:]]+(install|reinstall|upgrade)//; s/[;&|].*$//')
  blocked=""
  for tok in $args; do
    case "$tok" in -*) continue ;; esac
    base=$(printf '%s' "$tok" | sed -E 's/@.*$//' | tr 'A-Z' 'a-z')
    case "$base" in
      openjdk|java|temurin|oracle-jdk|adoptopenjdk|go|golang|ruby|php|python|python3|node|nodejs|deno|perl|lua|erlang|elixir|scala|crystal|kotlin)
        blocked="$tok"; break ;;
    esac
  done
  if [ -n "$blocked" ]; then
    deny "言語ランタイム(${blocked})をbrewで直接入れるのはブロックされています。anyenv経由で管理してください：anyenv install <言語env>（例 jenv/rbenv/goenv）→ その*envでバージョン導入（anyenv-runtimeルール）。"
  fi
fi

exit 0
