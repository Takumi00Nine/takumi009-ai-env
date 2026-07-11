---
date: 2026-06-14
updated: 2026-07-10
tags: [preference, strict, vrm, license, security]
project: meta
related:
  - "[[Preferences/absolute-rules]]"
  - "[[Preferences/coding-delegation]]"
aliases:
  - "VRM非公開"
  - "3Dアバターデータ非公開"
  - "VRMアバター"
---

# VRM/3Dアバターデータは非公開（ライセンス基準・厳守）

> 本ノートは一般原則「**ライセンス上パブリック公開不可のアセットは公開しない**」（[[Preferences/absolute-rules]] ルール1）の VRM/3Dアバターにおける具体適用。判断基準はライセンスであり「VRM だから一律禁止」ではない——現行アバターは VN3 ライセンスで本体再配布禁止のため非公開。将来、公開可ライセンスのモデルを使う場合はこの限りではない。

**現行アバターの3Dデータ一式は、絶対に public に置いてはいけない。** 対象は VRM 本体だけでなく **`.blend`／`.fbx`／`.psd`／テクスチャpng／unitypackage** など素体データすべて（`~/Data/3d/` 配下の素体一式含む）。公開リポジトリ・GitHub Pages の出力・公開 Actions の成果物など、外部から取得できる場所すべてに置くことを禁止する。例外なく厳守。

一方で、**3Dデータから生成した動画・連番画像・ドット絵などの2D派生物は public に置いてOK**（VN3 ライセンスの二次創作条項の範囲。ライセンス詳細の記録は private 側ノートにある）。

**Why:** 現行アバター素体は **VN3 ライセンスで原本・改変版とも再配布禁止**＝データを外部に出すと規約違反。3Dアバター素体は流用・改変リスクもある。

**How to apply:** Web サイト等で 3D キャラ素材に VRM を使う際は、①レンダリングはローカル（オフライン）で行う ②VRM をビルド/CI に渡さない ③`.gitignore` で除外しコミットしない ④public に出すのは派生物（動画/連番画像）だけ、を徹底する。コーディング等を Claude ワーカーへ委任する場合や Codex にレビューさせる場合（[[Preferences/coding-delegation]]）も、この制約を必ず伝える。
