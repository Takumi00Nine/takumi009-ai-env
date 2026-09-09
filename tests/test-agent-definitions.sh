#!/usr/bin/env bash
# claude/agents/*.md と Vault ノートの「内容契約」を見る静的テスト
# （3モード体制-設計-2026-09-06.md §10.3・新設）。
#
# AC-11・AC-12・AC-25 は claude/agents/*.md と Vault ノートの内容契約を
# 見るもので、既存のどのスイートも収容先を持たなかったため新設する
# （test-core-docs-placeholder-schema.sh はコア文書のプレースホルダ検査が
# 主題で、こちらとは主題が異なる）。
#
# ⚠️ このスイートは Vault（~/Data/obsidian）・vault-public/・本人のローカル
# 実体（~/.config/takumi009-ai-env/profile.md）にも依存する項目を含む。
# これらは worker-role-prompts.md の権限表新設（W5）・本人による実体更新
# （§9.2）が終わるまでは赤が正常（設計の段階分割どおり）。該当項目には
# 理由をコメントで明記する。⚠️ 2026-09-08 本人裁定A案で、role.verifier/
# fallback.verifierのFR-21確定値検査・退役キー検査はVault正本／公開
# スナップショットのprofile-sample.md読取をやめ、repo管理下の
# config/profile.md.sampleへ一本化した（詳細＝セクション5・6のコメント）。
#
# 実行方法: bash tests/test-agent-definitions.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
AGENTS_DIR="$REPO_ROOT/claude/agents"
BOOTSTRAP_SCRIPT="$REPO_ROOT/claude/hooks/bootstrap-vault.sh"
PROFILE_LIB="$REPO_ROOT/claude/hooks/lib/profile_resolve.py"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    fail_case "$desc (expected=$expected actual=$actual)"
  fi
}

assert_true() {
  local desc="$1" cond="$2"
  if [[ "$cond" == "1" ]]; then
    pass "$desc"
  else
    fail_case "$desc"
  fi
}

assert_contains_file() {
  local desc="$1" file="$2" needle="$3"
  if [ -f "$file" ] && grep -qF "$needle" "$file"; then
    pass "$desc"
  else
    fail_case "$desc (file=$file needle=[$needle])"
  fi
}

echo "=== 1. AC-12①: claude/agents/verifier.md が在り、tester.md が無い ==="
{
  assert_true "verifier.md が実在する" "$([ -f "$AGENTS_DIR/verifier.md" ] && echo 1 || echo 0)"
  assert_true "tester.md が存在しない（退役済み）" "$([ ! -f "$AGENTS_DIR/tester.md" ] && echo 1 || echo 0)"
}

echo "=== 2. AC-12②: verifier.md の tools: に SendMessage・Edit・Write・Bash を含む（カンマ区切りトークンの完全一致で判定・部分一致にしない） ==="
{
  # ⚠️ 部分文字列一致だと、例えば将来tools:にNotebookEditが加わったときに
  # "Edit"が誤って含まれる扱いになる（並列worktreeのCodexレビュー指摘の
  # 反映・点検対応）。tools:の値をカンマ区切りで分割し、トレリムした
  # トークンとの完全一致で判定する。
  tools_line="$(grep '^tools:' "$AGENTS_DIR/verifier.md" 2>/dev/null || true)"
  tools_value="${tools_line#tools:}"
  for t in SendMessage Edit Write Bash; do
    found=0
    IFS=',' read -ra _tool_tokens <<< "$tools_value"
    for tok in "${_tool_tokens[@]}"; do
      tok="$(printf '%s' "$tok" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      [ "$tok" = "$t" ] && { found=1; break; }
    done
    assert_true "tools: に ${t} をカンマ区切りトークンとして完全一致で含む" "$found"
  done
}

echo "=== 3. AC-12③: worker-role-prompts.md（Vault）に権限表がちょうど1つあり、行の主語が8職種を過不足なく覆う ==="
{
  # ⚠️ Vault側（W5）の権限表新設が済むまでは赤が正常。
  WRP="$HOME/Data/obsidian/Preferences/worker-role-prompts.md"
  if [ -f "$WRP" ]; then
    # 見出し「## 職種ごとの権限表」自体がちょうど1回だけ現れることを見る
    # （§7.5「（新設）権限表」節の見出し文言。単に役職名がどこかの表の行に
    # 現れるだけでは「表がちょうど1つ」を証明できない＝7ロール一覧など
    # 他の表と取り違えないため、見出しの唯一性を先に固定する）。
    heading_count="$(grep -c '^## 職種ごとの権限表' "$WRP" || true)"
    assert_eq "権限表の見出しがちょうど1つ" "1" "$heading_count"

    if [ "$heading_count" = "1" ]; then
      # 見出しから次の見出し(## )の手前まで、または末尾までを表本体として
      # 切り出す（bash 3.2互換・配列を使わずawkで完結させる）。
      table_block="$(awk '/^## 職種ごとの権限表/{flag=1; next} /^## /{if(flag){exit}} flag' "$WRP")"
      # ⚠️ 見出しがちょうど1つでも、節内に無関係な表を追加で足すと
      # （役職行を含まない第2表など）role行のカウントだけでは検出できず
      # 「表がちょうど1つ」を証明したことにならない（検証職・第3巡MAJOR
      # 指摘1の反映。`.verify/w3-false-positive-reproduction.log`で再現）。
      # 節内の`|`始まりの連続行を1ブロックとして数え、ブロック数が
      # ちょうど1であることを先に検査してから、その1表だけを役職検査の
      # 対象にする。
      table_count="$(printf '%s\n' "$table_block" | awk '
        /^\|/ { if (!intbl) { tbl++ }; intbl=1; next }
        { intbl=0 }
        END { print tbl+0 }
      ')"
      assert_eq "権限表の節内にMarkdown表ブロックがちょうど1つ" "1" "$table_count"
      if [ "$table_count" = "1" ]; then
        table_rows="$(printf '%s\n' "$table_block" | grep -E '^\|')"
        all_ok=1
        for r in implementer verifier requirements-analyst system-designer adoption-critic researcher operator vault-scribe; do
          n="$(printf '%s\n' "$table_rows" | grep -cE "^\| \`?${r}\`? ")"
          [ "$n" = "1" ] || all_ok=0
        done
        # 8職種**以外**の主語を持つ表の行が紛れ込んでいないこと（過不足なく）。
        other_role_rows="$(printf '%s\n' "$table_rows" | grep -E '^\| `?[a-z][a-z0-9_-]*`? ' \
          | grep -vE '^\| `?(implementer|verifier|requirements-analyst|system-designer|adoption-critic|researcher|operator|vault-scribe)`? ' || true)"
        assert_true "権限表の行の主語が8職種を過不足なく覆う" "$all_ok"
        assert_eq "権限表に8職種以外の主語の行が無い" "" "$other_role_rows"
      fi
    fi
  else
    fail_case "worker-role-prompts.mdが見つからない（Vaultに依存する検査。W5未反映のため赤が正常）"
  fi
}

echo "=== 4. AC-12④: Codexが演じうる職種（vault-scribe以外の7本）のagents/*.mdにsandboxの値が書かれ、§5.2の権限表の値と一致する ==="
{
  # 3モード体制-設計-2026-09-06.md §5.2の権限表を正本値としてハードコードする
  # （Vaultのworker-role-prompts.mdへの依存を避け、この段階でも緑にできる）。
  # ⚠️ macOS既定bash 3.2は連想配列(declare -A)を持たないため、
  # "職種:期待値"のスペース区切りリストで表現する（repo全体で徹底している
  # bash 3.2互換の既存作法）。
  # ⚠️ 値の文字列を含むかだけを見ると、無関係な地の文に値が現れても合格
  # してしまう（境界が無い＝並列worktreeのCodexレビュー指摘の反映・点検
  # 対応）。実際の記述形式`sandbox: <値>`（バッククォート囲み）で境界を
  # 持たせて一致を見る。
  for pair in "implementer:workspace-write" "requirements-analyst:workspace-write" \
              "system-designer:workspace-write" "adoption-critic:workspace-write" \
              "researcher:workspace-write" "operator:workspace-write"; do
    role="${pair%%:*}"; expected="${pair#*:}"
    f="$AGENTS_DIR/${role}.md"
    assert_contains_file "${role}.md にsandbox: ${expected}が境界つきで書かれている" "$f" "\`sandbox: $expected\`"
  done
  # verifierは成果物の種別で2経路（read-only／workspace-write の両方）。
  # verifier.mdはCLIフラグ形式（--sandbox <値>）で記述している。
  assert_contains_file "verifier.md にread-only経路が境界つきで書かれている" "$AGENTS_DIR/verifier.md" "\`--sandbox read-only\`"
  assert_contains_file "verifier.md にworkspace-write経路が境界つきで書かれている" "$AGENTS_DIR/verifier.md" "\`--sandbox workspace-write\`"
  # vault-scribeはCodexが演じない＝「対象外」の1行があればよい。
  assert_contains_file "vault-scribe.md は「Codexは演じない/対象外」と書かれている" "$AGENTS_DIR/vault-scribe.md" "Codex はこの職種を演じない"
}

# 廃止したMCP経路のexecution値を検査するための共有パターン。⚠️ このファイル
# 自身（tests/配下）も検査対象に含める都合上（項目6）、ソース上に完成した
# 文字列そのものを書くと自己参照ヒットしてしまうため、2つに分割して連結する
# （Codex二次レビュー指摘・MINOR対応。定義をここ1箇所にまとめ、以降の項目
# 5・6はこの変数を使い回すことで「別の場所にまた書いてしまう」再発も防ぐ）。
MCP_EXEC_PAT="execution=external-"
MCP_EXEC_PAT="${MCP_EXEC_PAT}mcp"

echo "=== 5. AC-11: 退役キー(role|fallback).(primary-reviewer|tester): がclaude/hooks/・claude/agents/で0件。CORE_ROLES_WITHOUT_REPO_AGENT_FILEにprimary-reviewerを含まない ==="
{
  hits="$(grep -rEn '^(role|fallback)\.(primary-reviewer|tester):' "$REPO_ROOT/claude/hooks" "$REPO_ROOT/claude/agents" 2>/dev/null || true)"
  assert_eq "claude/hooks・claude/agentsに退役キーが0件" "" "$hits"

  # ⚠️ docs/core-split（profile-resolve-contract-2026-09-01.md）は private
  # repoへのsymlinkでこのworktreeには含まれない（設計§3.1a注記）。存在すれば
  # 絶対パスで直接見る（無ければスキップし理由を明記＝存在しないファイルを
  # 検査対象外にするだけで、無いことを合格扱いにはしない）。
  hits_mcp="$(grep -rn "$MCP_EXEC_PAT" "$REPO_ROOT/claude/hooks" "$REPO_ROOT/claude/agents" 2>/dev/null || true)"
  assert_eq "claude/hooks・claude/agentsに廃止したMCP経路のexecution値が0件" "" "$hits_mcp"
  CONTRACT_DOC="$HOME/work/takumi009-ai-env-private/docs/core-split/profile-resolve-contract-2026-09-01.md"
  if [ -f "$CONTRACT_DOC" ]; then
    contract_hits="$(grep -n "$MCP_EXEC_PAT" "$CONTRACT_DOC" || true)"
    assert_eq "profile-resolve-contract-2026-09-01.mdに廃止したMCP経路のexecution値が0件" "" "$contract_hits"
  else
    fail_case "profile-resolve-contract-2026-09-01.mdが見つからない"
  fi

  core_manifest="$(PYTHONPATH="$REPO_ROOT/claude/hooks/lib" python3 -c 'import profile_resolve as pr; print("primary-reviewer" in pr.CORE_ROLES_WITHOUT_REPO_AGENT_FILE)')"
  assert_eq "CORE_ROLES_WITHOUT_REPO_AGENT_FILEにprimary-reviewerを含まない" "False" "$core_manifest"

  # ⚠️ 2026-09-08 本人裁定A案（設定ファイルsample配布）: Vault正本
  # （~/Data/obsidian/Preferences/profile-sample.md）・公開スナップショット
  # （vault-public/Preferences/profile-sample.md）は「正本はrepoの
  # config/*.sample」という案内ノートへ縮める前提になり、schema本体の
  # ```yamlブロックを持たなくなる（vault-scribeの別担当）。したがって
  # この2ファイルを読むassertは削除し、repo管理下で実際にschema本体を
  # 持つ`config/profile.md.sample`を読む検査へ一本化した（そちらは
  # 本ファイルの担当範囲＝公開repo）。
  # ⚠️ 以下2件は本人ローカル実体に依存する検査。本人の§9.2実体更新
  # （schema 4→6）が済むまでは赤が正常。
  # ⚠️ 廃止execution値(MCP_EXEC_PAT)の走査は当初claude/hooks・claude/agents・
  # tests/・契約書だけで、この実体（config/profile.md.sample・
  # メイン機ローカル実体）を通っていなかった（検証職・第3巡MAJOR指摘3の
  # 反映）。それぞれに退役キー検査と同じifブロック内でMCP_EXEC_PAT
  # 検査も追加する。
  CONFIG_SAMPLE="$REPO_ROOT/config/profile.md.sample"
  if [ -f "$CONFIG_SAMPLE" ]; then
    c_hits="$(grep -En '^(role|fallback)\.(primary-reviewer|tester):' "$CONFIG_SAMPLE" || true)"
    assert_eq "config/profile.md.sampleに退役キーが0件" "" "$c_hits"
    c_mcp_hits="$(grep -n "$MCP_EXEC_PAT" "$CONFIG_SAMPLE" || true)"
    assert_eq "config/profile.md.sampleに廃止したMCP経路のexecution値が0件" "" "$c_mcp_hits"
  else
    fail_case "config/profile.md.sampleが見つからない"
  fi

  LOCAL_ENTITY="$HOME/.config/takumi009-ai-env/profile.md"
  if [ -f "$LOCAL_ENTITY" ]; then
    l_hits="$(grep -En '^(role|fallback)\.(primary-reviewer|tester):' "$LOCAL_ENTITY" || true)"
    assert_eq "メイン機のローカル実体に退役キーが0件（本人の§9.2実体更新後に緑化想定）" "" "$l_hits"
    l_mcp_hits="$(grep -n "$MCP_EXEC_PAT" "$LOCAL_ENTITY" || true)"
    assert_eq "メイン機のローカル実体に廃止したMCP経路のexecution値が0件" "" "$l_mcp_hits"
  else
    fail_case "メイン機のローカル実体が見つからない"
  fi
}

echo "=== 6. AC-11追加分: config/profile.md.sample・メイン機ローカル実体のrole.verifier/fallback.verifierがFR-21の確定値と一致する ==="
{
  # role.verifier/fallback.verifierの属性をFR-21の確定値と突合する
  # （Codex一次レビュー指摘・MAJOR対応（1巡目）: 当初はVault正本しか見ておらず、
  # 公開スナップショット・メイン機ローカル実体が対象外だった。また
  # fallback.verifierに`execution`を明記していないこと＝実効値が既定の
  # `subagent`になることも見ていなかった。
  # （2巡目MAJOR対応）: 部分文字列一致だと`provider=external-invalid`や
  # `model=codex-review-default-old`のような誤値・接尾辞付き値でも合格して
  # しまい、重複行があっても連結結果に含まれれば検出できなかった。対象行が
  # ちょうど1行であることを先に確認し、空白区切りのトークンをexact matchで
  # 比較する（値の途中一致を許さない）。
  check_verifier_fr21() {
    local label="$1" f="$2"
    if [ ! -f "$f" ]; then
      fail_case "${label}: ファイルが見つからない"
      return
    fi
    local role_count fb_count role_line fb_line
    role_count="$(grep -cE '^role\.verifier:' "$f" || true)"
    fb_count="$(grep -cE '^fallback\.verifier:' "$f" || true)"
    assert_eq "${label}: role.verifier行はちょうど1行" "1" "$role_count"
    assert_eq "${label}: fallback.verifier行はちょうど1行" "1" "$fb_count"
    [ "$role_count" != "1" ] || [ "$fb_count" != "1" ] && return
    role_line="$(grep -E '^role\.verifier:' "$f")"
    fb_line="$(grep -E '^fallback\.verifier:' "$f")"
    # 2026-09-08 モデル定義ファイルと候補指定対応（同設計§12.2・FR-21）:
    # provider=/execution=/effort=は定義ファイル側の属性へ移り、role/fallback
    # 行が持てる属性はmodel（定義名のカンマ列挙）だけになった
    # （ROLE_ATTR_NAMES={"model"}）。role.verifierの確定値は実機の実値
    # （設定ファイルsample配布・2026-09-08）に合わせた定義名
    # `codex-review-default`で行そのものを完全一致させる（`codex-high`は
    # Vault旧サンプルの例示名であり実値ではなかった＝A案でconfig/
    # profile.md.sampleへ読み元を付け替えるのに合わせて訂正。`key:`と値の
    # 間の桁揃え目的の連続空白は正規化してから比較する＝サンプルの実書式に
    # 合わせる）。
    role_line_norm="$(printf '%s' "$role_line" | sed -E 's/^role\.verifier:[[:space:]]+/role.verifier: /')"
    assert_eq "${label}: role.verifierがconfigured model=codex-review-default（行完全一致）" \
      "role.verifier: configured model=codex-review-default" "$role_line_norm"
    # fallback.verifierの確定的な定義名は本人裁定待ち（リーダー指示・未確定）
    # のため固定しない。「configured・定義名ちょうど1件（カンマ無し＝候補は
    # 1件だけ）」という構造だけを見る。⚠️ executionの明記チェックは、新文法で
    # 行にexecution属性を書くこと自体が構文エラーになった（parse_v2の
    # 「許可されない属性です」）ため、意味を失い削除した。
    # ⚠️ Vault正本の実体行は末尾にコメント（`# 候補は1件だけ…`）を持つため、
    # 行末アンカーの手前で任意の空白+コメントを許容する（行完全一致にしない）。
    assert_true "${label}: fallback.verifierがconfigured・定義名ちょうど1件（カンマ無し）" \
      "$(printf '%s' "$fb_line" | grep -qE '^fallback\.verifier:[[:space:]]+configured model=[a-z0-9][a-z0-9-]*([[:space:]]+#.*)?$' && echo 1 || echo 0)"
  }
  # ⚠️ 2026-09-08 本人裁定A案: Vault正本・公開スナップショットは案内ノート化
  # されschema本体を持たなくなる前提のため、それらを読むcheck_verifier_fr21
  # 呼び出しは削除し、repo管理下でschema本体を持つconfig/profile.md.sample
  # （公開repo・本ファイルの担当範囲）への1本化へ差し替えた。
  check_verifier_fr21 "config/profile.md.sample" "$REPO_ROOT/config/profile.md.sample"
  check_verifier_fr21 "メイン機ローカル実体" "$HOME/.config/takumi009-ai-env/profile.md"

  # 廃止したMCP経路のexecution値がtests/内に1件も無いこと（意図的な陰性
  # fixtureが無い＝要件AC-11の走査対象。Codex一次レビュー指摘・MAJOR対応）。
  # MCP_EXEC_PAT（ファイル冒頭で定義・分割連結済み）を再利用する。⚠️ パスで
  # 自己ファイルを除外すると、将来このファイル自身に廃止値のfixtureが
  # 混入しても検出できなくなるため、tests/全体を除外なしで走査する
  # （Codex二次レビュー指摘・MINOR対応）。
  tests_mcp_hits="$(grep -rn "$MCP_EXEC_PAT" "$REPO_ROOT/tests" 2>/dev/null || true)"
  assert_eq "tests/内に廃止したMCP経路のexecution値が0件（意図的な陰性fixtureは現状無い・自己ファイルも除外なしで走査）" "" "$tests_mcp_hits"
}

echo "=== 7. AC-25: FR-40の1行が対象5職種の各1件に現れ、verifier・operator・vault-scribeには0件 ==="
{
  FR40_LINE='自分ではレビューを起動しない。リーダーが起動する検証に応じ、指摘の反映は自分が行う。'
  # ⚠️ `grep -c`は0件一致のとき"0"を出力しつつ非0終了するため、
  # `|| echo 0`を足すと出力が二重化する（0\n0）。フォールバックは付けず、
  # ファイル不在時だけ空文字にする。
  for role in implementer requirements-analyst system-designer researcher adoption-critic; do
    f="$AGENTS_DIR/${role}.md"
    if [ -f "$f" ]; then n="$(grep -cF "$FR40_LINE" "$f")"; else n="(file missing)"; fi
    assert_eq "${role}.md: FR-40の1行がちょうど1件" "1" "$n"
  done
  for role in verifier operator vault-scribe; do
    f="$AGENTS_DIR/${role}.md"
    if [ -f "$f" ]; then n="$(grep -cF "$FR40_LINE" "$f")"; else n="(file missing)"; fi
    assert_eq "${role}.md: FR-40の1行は0件（対象外）" "0" "$n"
  done
}

echo "=== 8(意味の検査・機械化しない): core-worker.md §6に職種の義務(自分では起動しない等)が書かれていないこと ==="
{
  echo "  skip - RV-4と同じ枠でレビュー観点として見る（本テストでは機械化しない）"
}

echo "=== 9. agents/verifier.md の出力形式に、出力先ファイルの先頭3行の固定形が連続3行・この順序で書かれている ==="
{
  # ⚠️ 部分文字列一致だけでは「3行の連続性・順序・先頭3行であること」を
  # 検証できない（Codex一次レビュー指摘・MINOR対応）。3行連続のブロックを
  # 実際に探す。
  # ⚠️ 1・2行目のパターンに`^`/`$`が無いと、行頭に接頭辞・行末に不正な
  # 末尾を付けても部分一致で「見つかった」扱いになる。また2行目は
  # ` — <1行の理由>` の必須サフィックスまで見ないと、理由部分が欠けた
  # 行でも合格してしまう（検証職・第3巡MAJOR指摘2の反映）。3行とも
  # インデントを含めて`^...$`で行全体を固定し、2行目は
  # `打ち切り可否: <可|不可> — <1行の理由>` 全体を照合する。
  VERIFIER_MD="$AGENTS_DIR/verifier.md"
  three_line_block="$(awk '
    /^[ \t]*件数: BLOCKING <n> \/ MAJOR <n> \/ MINOR <n>[ \t]*$/ { l1=NR }
    l1 && NR==l1+1 && /^[ \t]*打ち切り可否: <可\|不可> — <1行の理由>[ \t]*$/ { l2=NR }
    l2 && NR==l2+1 && /^[ \t]*---[ \t]*$/ { print "FOUND"; exit }
  ' "$VERIFIER_MD" 2>/dev/null)"
  assert_eq "verifier.md: 件数:/打ち切り可否:/--- の3行が連続してこの順序で存在する" "FOUND" "$three_line_block"
}

echo "=== 10. §10.3-10: 開幕1行の文面がcore-conduct.md（正本・Vault）とbootstrap-vault.sh（複製）で一致する ==="
{
  # ⚠️ Vault側（W5・core-conduct.md §1改訂）が済むまでは赤が正常。
  CORE_CONDUCT="$HOME/Data/obsidian/Preferences/core-conduct.md"
  impl_lines="$(BOOTSTRAP_PRINT_TEAM_MODE_LINES_ONLY=1 bash "$BOOTSTRAP_SCRIPT" </dev/null)"
  # ⚠️ 抽出そのものが失敗・空になった場合に「比較対象0件だから全部見つかった
  # 扱い」という偽陽性を出さないよう、まず4行ちょうど取れていることを先に
  # 検査する（Codex一次レビュー指摘・MAJOR対応: 当初はloop本体が1回も
  # 回らなくてもall_present=1のまま素通りしていた）。
  impl_line_count="$(printf '%s\n' "$impl_lines" | grep -c . || true)"
  assert_eq "BOOTSTRAP_PRINT_TEAM_MODE_LINES_ONLYの出力がちょうど4行" "4" "$impl_line_count"
  if [ -f "$CORE_CONDUCT" ] && [ "$impl_line_count" = "4" ]; then
    # ⚠️ `grep -qF`による「正本のどこかに部分文字列として含まれるか」だけの
    # 判定だと、正本側の当該箇条書き行に末尾差分（誤字・追記等）があっても、
    # 実装側の文面がその行の先頭部分一致として拾われ「見つかった」扱いに
    # なってしまい、正本側の改変を見逃す（検証職・第3巡MAJOR指摘4の反映）。
    # 正本の箇条書き（`  - <label>: 🧭...`）からラベル部分を除去して本文
    # だけを4行抽出し、件数・順序を含めて実装側の4行と完全一致させる。
    core_lines="$(sed -n 's/^  - [^:]*: \(🧭.*\)$/\1/p' "$CORE_CONDUCT")"
    core_line_count="$(printf '%s\n' "$core_lines" | grep -c . || true)"
    assert_eq "core-conduct.md正本の箇条書き抽出がちょうど4行" "4" "$core_line_count"
    assert_eq "実装側の4本(3モード+未確定)がcore-conduct.md正本の4本と件数・順序込みで完全一致する（W5反映後に緑化想定）" "$core_lines" "$impl_lines"
  elif [ ! -f "$CORE_CONDUCT" ]; then
    fail_case "core-conduct.mdが見つからない（Vault側の§7.2改訂がまだ反映されていない可能性。W5完了後に緑化想定）"
  fi
}

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
