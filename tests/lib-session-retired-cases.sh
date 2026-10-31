# 要望8 AC-1・設計「書き換え・削除の範囲」「受入条件の確かめ方」。
# test-config-samples.sh からsource。ハーネスを共用する。
for path in core/connect/claude-code/session-handoff.sh tests/test-session-handoff.sh; do
  if [ ! -e "$REPO_ROOT/$path" ] && [ ! -L "$REPO_ROOT/$path" ]; then
    pass "S8-R01: $path は廃止済み"
  else fail_case "S8-R01: $path が残っている"; fi
done
if awk -F '\t' '!/^#/ && ($2=="core/connect/claude-code/session-handoff.sh" || $2=="tests/test-session-handoff.sh"){found=1} END{exit found}' "$REPO_ROOT/core/data/ledger.tsv"; then
  pass 'S8-R02: 旧起動物・専用テストの現役登録なし'
else fail_case 'S8-R02: 旧起動物・専用テストが現役登録されている'; fi
if ! grep -Ei '^[#]+ .*Session handoff|^[#]+ .*セッション引き継ぎ|session-handoff\.sh' "$REPO_ROOT/README.md" >/dev/null; then
  pass 'S8-R03: README日英に旧節・起動スクリプトの記載なし'
else fail_case 'S8-R03: README日英に旧節・起動スクリプトが残っている'; fi
