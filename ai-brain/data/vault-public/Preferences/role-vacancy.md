---
date: 2026-09-22
updated: 2026-09-22
tags: [preference, core, roles, vacancy]
project: takumi009-ai-env
related:
  - "[[Preferences/core-workflow]]"
  - "[[Decisions/2026-09-07-profile-axes-consolidation]]"
  - "[[Decisions/2026-09-20-roles-config-only]]"
  - "[[Decisions/2026-09-07-solo-leader-writes-vault]]"
aliases:
  - "職種が空席のとき"
  - "空席時の代替"
  - "vacant_unavailable"
  - "職種の4状態"
---
# 職種が空席のとき（状態 4 つと職種ごとの代替）
[[Preferences/core-workflow]] §7 の下位規則（§7 に残る 2 行＝`unknown` は保留・空席は品質ゲートの消滅ではない）＝空席時の振る舞いはここが正本。
- **キーの値が `unknown` のときは、依存するルールを保留して本人へ上げる**（特定の状態へ倒さない・最低契約④⑤）。
- **職種の状態は4つ**（プロファイルの `role.*` と1:1対応）:
  - `ready`＝採用済みで実行可能性を確認できた。プロファイル側＝`configured`（⚠️ `ready` の必要条件であって十分条件ではない＝spawn 失敗時は `vacant_unavailable`）
  - `not_adopted`＝この職種はこのマシンで使わない（値が無ければ `unknown` として保留）。プロファイル側＝`not_adopted`
  - `vacant_unavailable`＝採用済みだが動かせない（利用上限・認証失敗・定義不在など）。ワーカー職は spawn の失敗で判明＝本節の代替を発火（別候補の再試行は1行報告してから）。プロファイル側＝`unavailable`
  - `vacant_unknown`＝配役が未確定。プロファイル側＝`unknown`（保留して本人へ）
- 空席の2状態（`not_adopted`／`vacant_unavailable`）で以下の代替が発火する。**空席は品質ゲートの消滅ではない**＝①リーダー職が実施するか ②未実施を成果物に明記する。黙って省略しない。
- **検証職が空席** → リーダー職が受入条件と1対1の最小検証を行い「独立検証なし・リーダー検証のみ」を成果物と報告に明記する**か**、「検証未実施（理由）」を明記して本人判断へ上げる。
- **記録職が空席** → 「Vault記録候補:」の定型で応答に明示する（リーダー直筆はしない。単独モードは空席ではない）。
- **ナビ職が空席** → 工程ごとのセッション移動は本人が行う。AI が勝手に代替しない。
- **requirements-analyst / system-designer / adoption-critic が空席** → 工程を飛ばさず、リーダー職が最小限の判定を行い「専任なし」を明記する。
- 列挙に無い職種が空席なら、代替を発明せず「職種空席: <職種> / 影響 / 代替案」で本人に上げる。
- 空席の判定＝リーダー行は機構が起動前に・ワーカー行は採用状況か起動失敗で判明。振る舞いはコア（本節）が決める。
