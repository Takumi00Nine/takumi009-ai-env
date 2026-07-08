---
date: 2026-07-05
updated: 2026-07-08
tags: [preference, cmux, layout, agent-teams]
project: meta
related:
  - "[[Decisions/2026-07-05-cmux-3column-layout]]"
  - "[[Decisions/2026-07-05-show-in-cmux-pane]]"
  - "[[Preferences/coding-delegation]]"
  - "[[Knowledge/cmux-cli]]"
---

# cmux ワークスペースの標準レイアウト（最大3列）

claude-teams 運用時のワークスペースは**最大3列**で構成する（[[Decisions/2026-07-05-cmux-3column-layout]]）:

| 列 | 用途 |
|---|---|
| 左 | オーケストレーター（リーダーの claude 端末） |
| 中央 | チームメイト（ロールごとのペインを**縦積み**） |
| 右 | 成果物表示（`show-review.sh` が開く markdown プレビュー／ブラウザ。タブで束ねる） |

- **初期状態はリーダー1ペインのみ**。列は必要になったときだけ増やす（成果物を見せる→右列、ワーカーを起こす→中央列）。3列を超える列は作らない。
- **幅は cmux の素の分割比率に任せる**（カスタム幅矯正はしない）。自然になる形＝リーダーのみ 100% → 成果物表示で 50/50 → ワーカー列がある状態では概ね **50%（リーダー）/ 25%（チームメイト）/ 25%（成果物）**。手動リサイズも自由（何も戻さない）。
- 成果物列の配置は `~/work/dotfiles/cmux/show-review.sh` が担当（表示ルール本体＝[[Preferences/coding-delegation]]「ユーザーへの提示」節。Vault 内ノートは表示対象外）。
- **実現方法**: 追加の仕組みは不要で、①チームメイト＝`cmux claude-teams` の組み込み挙動（リーダーの右列に自動縦積み・設定不可＝[[Knowledge/cmux-cli]]）②成果物＝show-review.sh が**最右ペインを起点に右 split** することで、左=リーダー/中央=チームメイト/右=成果物が自然に成立する。
- **要観察1点**: 「成果物列が先にあり、その後にチームメイトを初 spawn」した場合の配置（組み込み挙動がどこに積むか）は未実測。実運用で崩れたら layout の再調整を検討。
- **既知の挙動**: チームメイト2体目以降の spawn で、リーダー幅が自動的に約25〜30%まで縮む（1体目 spawn 時点では50/50を維持）。これは cmux の分割機能ではなく **Claude Code（Agent Teams）の TmuxBackend が spawn 直後に発行する明示的なリサイズコマンド**によるもので、無効化フラグは無い。カスタム矯正では戻さず、Claude Code の仕様として受け入れる（技術詳細は [[Knowledge/cmux-cli]]。再カスタムしたくなったら同ノートの手順で低コストに対応可）。
