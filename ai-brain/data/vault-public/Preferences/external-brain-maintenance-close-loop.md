---
date: 2026-09-21
updated: 2026-09-21
tags: [preference, external-brain, maintenance, health, fragments, procedure]
project: external-brain
related:
  - "[[Preferences/vault-operation]]"
  - "[[Preferences/fragments-workflow]]"
  - "[[Decisions/2026-09-20-health-self-explain-error-only-autofix]]"
  - "[[Decisions/2026-09-21-maintenance-close-loop]]"
  - "[[Knowledge/external-brain-maintenance-split]]"
  - "[[Projects/takumi009-ai-env]]"
aliases:
  - "外部脳メンテの締めループ"
  - "候補0件まで回す"
  - "ヘルス対処の終了条件"
  - "メンテの締め手順"
---

# 外部脳メンテの締めループ（対処→再実行→読み直し→0 件まで）
> 外部脳のヘルス（棚卸しの要対処）と Fragments 昇格候補を「対応したら必ず 0 件で終わる」ための 1 本の手順。行動則の正本＝[[Decisions/2026-09-20-health-self-explain-error-only-autofix]]（ERROR だけ自発・WARNING は依頼まで黙る）と [[Preferences/fragments-workflow]] §4（昇格の締め 3 手順）。本ノートはそれらを締めの順に並べたもの。なぜ＝[[Decisions/2026-09-21-maintenance-close-loop]]。

## 1. 発火と分岐
- **本ループの対象＝本人が外部脳のヘルス・棚卸し・昇格候補の対処を求めたとき**（WARNING は依頼があるまで言及しない）。⚠️ **昇格対応は本人の明示指示があるときだけ**（[[Preferences/fragments-workflow]] §4「本人が『昇格して』と言ったとき」）。ヘルスだけの依頼で Dock に候補が残る場合は勝手に昇格せず、終端「未完了停止（本人待ち）」で「候補N件＝昇格対応しますか」を 🔸要確認 に出す（自分の案を添える）。
- **`stage=ERROR` は本ループの対象外**＝[[Decisions/2026-09-20-health-self-explain-error-only-autofix]] のとおり、最初の応答で自発的に「診断→主体 AI の項目の対処→その源の本番経路を 1 回だけ再実行（読込＝対象ノートの読み直し 1 回・想起＝想起フックの再実行 1 回）」を行い、失敗したら 2 回目をせず診断結果と対処案の提示に切り替える（2 周の上限は適用しない）。

## 2. 現在値を読む（着手時と各周の終わり）
- 着手時＝直近の【外部脳ヘルス】注入ブロック（stage・items の主体と ok_when・maintenance）。⚠️ 注入は同セッション内では更新されない＝再実行後は下の口を読む。
- 各周の終わり（次の 4 つを読む）:
  1. 判定機の最新結果（items の主体 `actor`・`ok_when` を含む）＝SessionStart フックを手で 1 回実行して【外部脳ヘルス】行を読む: `echo '{"hook_event_name":"SessionStart","source":"startup"}' | ~/work/takumi009-ai-env/claude/hooks/bootstrap-vault.sh | grep '【外部脳ヘルス】'`（同セッションの注入は更新されないため、これが読み直しの口。観測記録が 1 件書かれる副作用は本番と同じ）。主体は判定機が種別から決める（棚卸しの種別はすべて `AI`・maintenance の失敗工程は工程ごと）。
  2. Dock の外部脳行＝`~/work/takumi009-ai-env/cmux/cmux-next-model.sh --frame` の「外部脳」行（3 値 `OK`／`WARNING`／`ERROR`＋末尾「候補N件」）＝終了判定の値。
  3. 棚卸しの内訳＝`~/.claude/logs/vault-inventory/latest.json`（`actionable`・`items`）と同日のレポート `~/.claude/logs/vault-inventory/<日付>.md`（項目ごとの対象・種別・主体）＝次の周の対処対象の特定に使う（主体は上の 1 で読む）。
  4. 週次メンテの結果＝`~/.claude/logs/maintenance/last-run.json`（`run.status`・`completed.fully_ok`・`completed.steps`＝失敗した工程・`fragments_candidates`）。

## 3. 1 周の手順
1. 要対処項目のうち主体 `AI` のものを対処する（Vault 書込は記録職へ）。主体 `本人` の項目は診断と提示まで。
2. 本人が昇格を明示したときだけ、昇格対応し記録職が元エントリへ `status: promoted → [[昇格先]]` の印を足す（[[Preferences/fragments-workflow]] §4 の手順①。締めコマンドはここでは実行しない）。指示が無ければ候補は触らず §4 の本人待ちへ。
3. 本番経路を再実行する（この周で 1 回ずつ・順序固定）:
   - 棚卸し系の対処をしたとき＝週次メンテの手動起動 `~/work/takumi009-ai-env/scripts/maintenance-kick.sh --wait`（`STATUS:completed` かつ `FULLY_OK:true` を確認）。
   - 昇格対応をしたとき＝その後に締めコマンド `~/work/takumi009-ai-env/scripts/fragments-reviewed.sh` を 1 回（§4 の手順②。週次全体の再実行では候補は消えない＝数え始めが変わらないため、週次の後・最後に実行する）。
4. §2 の 4 つの口を読み直す（§4 の手順③の Dock 確認を含む）。

## 4. 終端（3 種・語彙を固定する）
- **完了**＝Dock の外部脳行が `OK 候補0件`。完了報告にはその実測値を添える。これ以外を「完了」と言わない。
- **未完了停止（上限到達）**＝2 周の後も要対処か候補が残る。3 周目はせず、「未完了」と明記して残件と原因の見立てを 🔸要確認 で本人へ出す。
- **未完了停止（本人待ち）**＝主体 `本人` の項目だけが残る、または昇格の指示が無いまま候補が残る。「未完了・残＝本人主体 N 件／昇格判断 N 件」と明記し、要判断を 🔸要確認 で出して終える（0 件扱い・完了扱いにしない）。
- いずれかの終端報告を出すまで、別の話題へ移らない。

## 5. やらないこと
- 再実行を省いて「次回の週次で消える」と報告する。
- 注入ブロックの値で終了判定する（再実行後は §2 の口を読む）。
- operator の起動（対処は注入・Dock の項目だけで行う）。
- Dock の常駐や LaunchAgent の再起動（値は常駐が 60 秒ごとに読む）。
