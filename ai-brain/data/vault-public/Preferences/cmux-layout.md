---
date: 2026-07-05
updated: 2026-08-07
tags: [preference, cmux, layout, agent-teams]
project: meta
related:
  - "[[Decisions/2026-08-07-teammate-in-process-permanent]]"
  - "[[Decisions/2026-07-05-cmux-3column-layout]]"
  - "[[Decisions/2026-07-05-show-in-cmux-pane]]"
  - "[[Preferences/coding-delegation]]"
  - "[[Knowledge/cmux-cli]]"
aliases:
  - "2列レイアウト"
  - "3列レイアウト"
  - "cmuxワークスペース"
---

# cmux ワークスペースの標準レイアウト（リーダー＋成果物の最大2列）

claude-teams 運用時のワークスペースは**左＝リーダー／右＝成果物の最大2列**で構成する（2026-08-07 改定＝[[Decisions/2026-08-07-teammate-in-process-permanent]]）:

| 列 | 用途 |
|---|---|
| 左 | オーケストレーター（リーダーの claude 端末） |
| 右 | 成果物表示（`show-review.sh` が開く markdown プレビュー／ブラウザ。タブで束ねる） |

- **チームメイトはペインを持たない**: 起動関数 `cct` が `--teammate-mode in-process` を既定注入し、エージェントパネル内で動作する（↑↓選択・Enter でトランスクリプト表示&直接メッセージ・x で停止）。ペイン分割に戻すときのみ `cct --teammate-mode auto`。
- **初期状態はリーダー1ペインのみ**。成果物を見せるときだけ右列を増やす。2列を超える列は作らない。
- **幅は cmux の素の分割比率に任せる**（カスタム幅矯正はしない）: リーダーのみ 100% → 成果物表示で 50/50。手動リサイズも自由（何も戻さない）。
- 成果物列の配置は実行時に `~` 展開される dotfiles 内 `cmux/show-review.sh` が担当（表示ルール本体＝[[Preferences/coding-delegation]]「ユーザーへの提示」節。Vault 内ノートは表示対象外）。

## deprecated 2026-08-07（旧3列標準・チームメイト中央列）
- 旧構成＝左リーダー／中央チームメイト縦積み／右成果物の最大3列（[[Decisions/2026-07-05-cmux-3column-layout]]）。中央列は in-process 恒久化で消滅。
- ペイン運用時代の実測知見（spawn 時の自動リサイズ・右列自動縦積みの正体）は [[Knowledge/cmux-cli]] に保全。
