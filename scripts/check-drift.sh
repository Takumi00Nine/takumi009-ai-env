#!/usr/bin/env bash
# ポータブル化されたAI環境の「ズレ」を検知する手動実行ツール（Phase 1.5）。
#
# チェック項目:
#   ① symlink 16ファイル（install-main.sh の link() 呼び出しと同じ集合）が
#      repo の実体を指しているか。加えて①-2として、生成物 ~/.claude/settings.json
#      （2026-08-21よりsymlinkではなく生成物。詳細は下記①-2セクション本体の
#      コメント参照）がrepoテンプレとプレースホルダ展開込みで一致しているか
#   ② ~/.codex/config.toml（生成物）が repo の codex/config.toml テンプレと
#      「プレースホルダ展開を考慮すれば」一致しているか（実ファイルを
#      __AIENV_HOME__ へ逆置換してから、python3標準tomllibでTOMLとして解析し、
#      キー単位で三分類する＝既知アプリ管理キー=テンプレ記載の有無にかかわらず
#      除外／それ以外のテンプレ記載キー=値差分でdrift／未知キー=WARN表示のみで
#      driftにしない。2026-08-10 diff+denylist方式から移行＝
#      [[Decisions/2026-08-10-round6-rulings]] 決定2。denylistは7/27→8/5→8/10と
#      3回壊れたいたちごっこだった）
#   ③ repo（このリポジトリ）に未commitの変更が無いか（`git status --porcelain`が
#      実行自体に失敗した場合は「差分なし」に混同せず監視不能として計上する。
#      2026-07-14 リーダー指摘対応＝旧実装は `|| true` でコマンド失敗と出力ゼロ件を
#      区別できておらず、git破損時に偽の健全表示になり得た）
#   ④ vault-public/Preferences と実 Vault の Preferences に差分が無いか
#      （export-public-vault.sh のエクスポート漏れ検知。`diff -rq`のexit codeで
#      「差分なし／差分あり／実行エラー」を区別する。同じくリーダー指摘対応）
#   ⑤ private であるべき remote（Vaultバックアップ・私的パッチrepo）が
#      実際に GitHub 上で private のままか（`gh repo view --json visibility`）。
#      ai-env 本体（このリポジトリ自身）は「公開予定」のため対象外。
#      remote未設定はチェック対象外（情報表示のみ）。gh コマンド自体が無い環境
#      （未インストール）は drift にはせず WARN 表示のみに留める（2026-07-08
#      adoption-critic指摘対応。「必須指摘」＝private repoの意図しない公開化を
#      検知する恒久対策）。一方、gh はあるのに未認証・権限不足・API失敗で
#      可視性そのものが取得できない場合（GH-CHECK-FAILED）は drift として計上する
#      （2026-07-13 外部脳round4白紙レビュー欠陥③対応。従来はWARN表示のみで
#      drift件数に乗らず、私的リポジトリの意図しない公開化を検知するはずの
#      安全網自体が静かに無効化していても週次通知に出ない穴があった＝
#      「監視不能も異常」として明示的に検知対象にする）。
#   ⑥ vault-agents（maintenance.sh週次ランナー・weekly-review・想起/読取ログ
#      フック）の死活。「maintenance.shの最終開始(started_at)が古すぎる」
#      「vault-reads.tsv/vault-recall.tsvの最終記録が古すぎる」のいずれかを
#      検知する（2026-07-10 敵対的レビュー M-1/M-2 対応。3年ノーメンテ運用では
#      「本人が定期的にレポートを見に行く」以外に死活を知る手段が無かった＝
#      検知網そのものが無人だと無言で死ぬ穴を塞ぐ）。
#      旧・未処理レポート検知（frontmatterのprocessed:マーカー監視）・未解決ALERT監視・
#      個別のvault_inventory.py/fragments_log.py/knowledge_merge_candidates.py
#      レポート新鮮度チェック（LaunchAgent単位）は2026-07-16簡素化
#      （[[Decisions/2026-07-16-nightly-batch-direct-write]]・設計書§4「check-drift.sh
#      のレポート未処理検知・ALERT監視を削除、maintenance新鮮度チェック
#      （started_atの経過日数のみで判定＝自己ロックアウト対策）に置換」）で
#      撤去し、単一の週次ランナー com.takumi009.maintenance
#      （scripts/maintenance.sh。上記3スクリプトはそのPhase1から呼ばれる
#      検出専用CLIへ縮小し、個別LaunchAgentは持たない）の死活を
#      last-run.json基準でまとめて見る方式へ統合した（「レポート→リーダー
#      処理」の間接ループ廃止・ALERT機構の生成元knowledge_merge.py撤去のため。
#      旧実装は`git log -p`参照）。started_atはmaintenance.shが実行開始
#      直後に無条件で更新する値であり、実行中に一部の検出/適用が失敗しても
#      更新され続ける（＝「実行はされているが失敗し続けている」ことまでは
#      本チェックでは検知しない。それはmaintenance.sh自身の異常時macOS通知が
#      担う。本チェックは「そもそも起動すらしていない」自己ロックアウトの
#      検知に専念する設計判断＝リーダー裁定2026-07-16）。
#      $VAULT が無い
#      （サブ機・私的Vault未clone）場合は対象外。maintenance.shは
#      README.mdにも明記の「メイン専用」機能（scripts/install-maintenance.sh
#      を実行していなければ対応LaunchAgent plistが無い）なので、reads/recallログ
#      （install-main.shで標準導入・任意ではない）とは別に、LaunchAgent plistの
#      実在＋launchd上のロード状態（読み取り専用の`launchctl print`照会。
#      本チェックがcheck-drift.sh初のlaunchctl呼び出しだが、状態照会のみで
#      何も変更しないため冒頭の「読み取りのみ」方針には反しない＝
#      リーダー裁定2026-07-16「(a) plist存在＋launchctl登録」対応）で個別に
#      導入・稼働判定してからチェックする（Codexレビュー指摘・Major:
#      reads/recallログだけが存在する普通のmain構成で、未導入の任意機能まで
#      毎回DEAD誤報していた。この設計自体は踏襲する）。
#      weekly-review（「今週の歩み」週次振り返りcanvas。
#      takumi009-ai-env-private/tools/weekly-review/weekly_review.py・
#      LaunchAgent com.takumi009.weekly-review が毎週月曜04:00に無人実行）も同型の
#      新鮮度チェック対象に追加（2026-07-14。従来は本ツールに一切の言及が無く
#      監視対象外だった＝外部脳監視・バックアップ機構総点検で確定）。canvas出力
#      ファイル名は「対象週の月曜日」であり生成日ではないため、ファイル名基準では
#      なく最新ファイルのmtime基準で新鮮度を判定する（processedマーカーによる
#      未処理チェックの対象外＝canvasは本人向けの最終成果物そのものであり、他3種の
#      ような「処理待ちレポート」ではないため）。
#      ログの時刻(TSV1列目)はvault-recall.sh/vault-read-log.shがUTCで書くため、
#      経過日数の算出は `TZ=UTC` を明示してパースする（2026-07-10 敵対的レビュー
#      2回目 N-5 対応。以前はローカルTZとして解釈しており、JST環境では±9hずれ、
#      日境界付近では経過日数が1日多くカウントされ得た＝日単位閾値の誤判定要因）。
#   ⑦ vault-backup（scripts/backup-vault.sh）の push 死活。push失敗はWARNとして
#      /tmp/backup-vault.log（launchagents/com.takumi009.backup-vault.plistが
#      指定する一時領域・再起動で揮発。2026-07-16簡素化でLAラベル・ログファイル名を
#      com.takumi009.vault-backup→com.takumi009.backup-vaultへ改名＝設計書§5）へ
#      出るのみで、origin(GitHub)との乖離が
#      長期化しても気付く手段が無かった（2026-07-13 外部脳round4白紙レビュー
#      新発見の監視穴①対応）。ネットワークアクセスはしない（git fetch はしない。
#      本ツール冒頭の「読み取りのみ」方針どおり）ため、ローカルの
#      origin/main 参照（直近の成功pushでのみ更新される＝git push は成功時に
#      ローカルの追跡ブランチも更新する）だけを判定材料にする。
#      `git rev-list origin/main..main` で「originに無くlocalにあるcommit」
#      （＝push未反映）だけを厳密に求め（ローカルがorigin/mainより単に古い
#      だけのケースを誤検知しないため）、そのうち最も古いcommitの時刻からの
#      経過時間が24時間超ならdrift計上する（origin/mainのtip時刻を基準にすると、
#      長期間無編集の後にたまたま1回pushが失敗しただけでも「何日も前から
#      詰まっている」ように誤検知するため、実際に待たされている最古の未反映
#      commitを基準にする）。origin/main参照が存在しない（一度も成功push
#      していない）場合はlocalの全commitを「未反映」とみなし同じ判定に合流させる
#      （初回セットアップ直後は最古commitも新しいため自然に猶予期間になる）。
#      ローカルmainとorigin/mainが一致していれば「pushすべき差分がそもそも
#      無い」健全な状態としてチェック対象外にする＝Vault未編集の日が続くだけで
#      誤報しないための設計。fetchしない制約による既知の限界＝他マシン/手動
#      操作で実際のorigin/mainがもっと進んでいるのにこのマシンのローカル参照
#      だけが古いケースとは区別できない。
#   ⑦-2 backup-vault.shのロック回収ミューテックス（$LOCK_FILE.reclaim）が
#      長時間残っていないか（2026-07-14追加・Codex二次レビュー指摘・Major対応）。
#      ⑦は「ローカルcommit済みだがpush未反映」を検知するが、回収ミューテックスが
#      固着（前回実行のクラッシュ痕跡）するとバックアップがcommit前にfail-closedで
#      止まり続け、⑦のrev-list判定には何も現れないまま無期限に沈黙しうる別種の
#      穴になるため、ミューテックスディレクトリの新鮮度を直接読む（削除はしない＝
#      読み取りのみ。解除はbackup-vault.sh自身の起動時ロジックに委ねる）。
#
# **fail-fast はしない**（1件でも検知したらexitさせる export-public-vault.sh とは
# 役割が違う。本ツール自体は常にexit 0の「一覧表示するだけ」の手動確認用レポート
# ツールで、必要な時に手で実行する運用＝設計方針。
# 2026-07-16簡素化（[[Decisions/2026-07-16-nightly-batch-direct-write]]）で、
# 週次無人実行の経路は scripts/drift-notify.sh／LaunchAgent
# com.takumi009.drift-check（毎週月曜9:30・macOS通知）から、新設の
# maintenance.sh（週次ランナー・PR2）Phase 1 ①へ移す。旧drift-notify.shは
# 撤去した（通知は異常時のみに縮小・「通知は見ていない」本人指摘）。
# maintenance.sh導入までの間、本ツールは手動実行のみの運用となる。
#
# 読み取りのみ（実 ~/.claude・~/.codex・実Vaultには一切書き込まない）。
#
# 使い方: scripts/check-drift.sh
#   --json: 末尾の人間向けサマリ行の直後に、機械可読なJSON1行を追加でstdoutへ
#     出力する（設計書§1.2「①check-drift.sh実行（per-item機械可読出力を追加＝
#     改訂v2）」＝maintenance.sh Phase1①向け・2026-07-16簡素化）。それ以外の
#     出力（全ての人間向け診断行）は--json有無に関わらず一切変更しない
#     （既存の全アサーション・運用フローとの完全後方互換を優先＝既存の
#     990行規模の診断ロジック・十数箇所のitem_drift()呼び出しを個別に
#     stdout/stderr分離するのは変更範囲・リスクが大きすぎると判断。呼び出し側
#     は「stdoutの最終行だけがJSON、それより前は全て人間向けテキスト」という
#     契約でパースする）。
#     JSON形式: {"total_drift": N, "item4_drift": M, "drift_excluding_item4":
#     N-M, "unknown_config_keys": K}（item4 = ④vault-public/Preferences差分。
#     design上この項目だけは環境故障ではなく公開同期待ちの実体差分のため
#     exit code契約から除外する＝改訂v2 §1.2）。**除外されるのは「④の内容
#     差分（[MISSING]/[DIFF]）」のみ**であり、「④の検査自体が実行できない
#     異常（[DIFF-CHECK-FAILED]）」はitem4_driftに含めず通常のdrift
#     （drift_excluding_item4側）として扱う（2026-07-16 Codexレビュー指摘
#     Major対応: 改訂v2 §1.2は「④の差分は除外・実行異常は対象」と明記して
#     おり、実行異常まで除外すると「監視不能も異常」という本スクリプト
#     自身の方針に反するため）。unknown_config_keysは②のTOML三分類で
#     「テンプレにも既知アプリ管理キー一覧にも無い」と判定された件数
#     （2026-08-10追加・工程横断レビュー指摘Major対応。driftには数えず
#     total_drift/drift_excluding_item4には含めないが、maintenance.sh側が
#     informationalとしてlast_result_summaryへ拾えるようにするための値。
#     詳細＝scripts/maintenance.sh側コメント参照）。
#   終了コード: --json未指定時は**常に0**（既存の「fail-fastしない設計」を
#     維持＝tests/test-check-drift.sh「exit codeは常に0」の既存契約を壊さない）。
#     --json指定時のみ、drift_excluding_item4>0でexit 1にする。この
#     exit code契約自体はcheck-drift.sh単体の仕様として不変（2026-08-10
#     時点でも維持）。呼び出し元のmaintenance.sh Phase1①は2026-08-10に
#     fail-fastを廃止し、この終了コード/JSONを「警告として記録し完走する」
#     ための入力の1つとして読むだけに変わった（[[Decisions/2026-08-10-
#     round6-rulings]]決定1）。呼び出し側の解釈が変わっただけで、
#     check-drift.sh自身がここで返す値の意味・exit code契約は変えていない。

set -uo pipefail  # -e は使わない（1項目の失敗で残りの検査が止まらないようにする）

# DIR は環境変数で上書き可（ユニットテスト用。本番は既定値のままでよい）。
: "${DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${VAULT:=$HOME/Data/obsidian}"
# 私的パッチ（別のprivateリポジトリ）のローカルclone先。環境変数で上書き可
# （ユニットテスト用。本番は既定値のままでよい＝README.md「導入手順」記載のパス）。
: "${AIENV_PRIVATE_REPO:=$HOME/work/takumi009-ai-env-private}"
# ①-2（~/.claude/settings.json）で使う machine-role マーカー。
# scripts/install-main.sh・claude/hooks/check-sub-update.sh 等と同じ環境変数名・
# 既定値・fail-closedの読み方（trimして中身がちょうど"sub"の場合だけサブ扱い。
# マーカー不在・読めない・中身が違う等はすべてmain扱い）を踏襲する。
# ⚠️ model/effort既定値（AIENV_MODEL_MAIN/AIENV_MODEL_SUB等）はここでは持たない
# （2026-08-30 §9.0 A-0-3＝値表2箇所重複の解消）。値の出力口は
# scripts/install-main.sh --print-leader-runtime [--sub-delegate] に一本化し
# （2026-09-01 配役表解凍 §4.2-a・§4.4で--print-modelから改名）、診断側は
# その出力を読むだけにする（①-2で呼び出す）。
: "${AIENV_MACHINE_ROLE_MARKER:=$HOME/.config/takumi009-ai-env/machine-role}"

JSON_MODE=0
for arg in "$@"; do
  case "$arg" in
    --json) JSON_MODE=1 ;;
    *) echo "[check-drift] FAIL: 不明な引数です: $arg" >&2; exit 2 ;;
  esac
done

TOTAL_DRIFT=0
# ④(vault-public/Preferences差分)専用カウンタ。この項目だけはdrift_excluding_
# item4のexit code契約から除外する（改訂v2 §1.2。旧仕様ではこれがmaintenance.sh
# Phase1①のfail-fast判定基準だったが、2026-08-10にmaintenance.sh側は
# fail-fastを廃止し警告記録のみに変更＝[[Decisions/2026-08-10-round6-
# rulings]]決定1。exit code契約自体・この集計方針は不変）ため、TOTAL_DRIFT
# とは別に集計する。
ITEM4_DRIFT=0
# ②のTOML三分類における未知キー（テンプレにも既知アプリ管理キー一覧にも
# 無いキー）の件数。driftには数えない設計だが、WARN表示のみだとRUN_DIRの
# ログ（30日TTL）に埋もれて誰にも読まれないまま消える（工程横断レビュー
# 指摘Major対応・2026-08-10）。--json出力へunknown_config_keysとして含め、
# maintenance.sh側でinformationalとしてlast_result_summaryへ拾えるように
# する（drift/RUN_FULLY_OK/last_resultの判定は変えない＝あくまで可視化
# 導線の追加）。TOTAL_DRIFT/ITEM4_DRIFTと同じく、検査②のどの分岐（正常/
# パース失敗/live・テンプレ欠落）でも参照できるようスクリプト冒頭で
# 初期化しておく。
UNKNOWN_CONFIG_KEYS=0

log() { echo "[check-drift] $*"; }
item_drift() { echo "  - $*"; TOTAL_DRIFT=$((TOTAL_DRIFT + 1)); }
# ④(vault-public/Preferences差分)の**内容差分**専用item_drift()ラッパー
# （[MISSING]・[DIFF]の2箇所のみで使う。[DIFF-CHECK-FAILED]＝検査実行自体の
# 異常は対象外＝通常のitem_drift()を使う。2026-07-16 Codexレビュー指摘Major
# 対応）。通常のitem_drift()と全く同じ出力・TOTAL_DRIFTカウントを行ったうえで、
# 追加でITEM4_DRIFTも加算する。
item4_drift() { item_drift "$@"; ITEM4_DRIFT=$((ITEM4_DRIFT + 1)); }

echo "======================================================================"
echo "① symlink が repo を向いているか"
echo "======================================================================"

# 2026-08-21: bash-danger-gate.sh・next-pane-resolve.sh・check-sub-update.sh の
# 3件が本一覧から漏れていた（install-main.shは配置しているのに監視対象外だった
# 既存不具合。今回のsettings.json対応でこの配列を触ったのを機にCodex一次
# レビュー指摘・Major対応として合わせて追加。settings.json/①-2の対応とは独立の
# 修正のため、READMEの「N件」表記もこの3件を含めた実数に更新している）。
SYMLINKS=(
  "$HOME/.claude/hooks/bootstrap-vault.sh|$DIR/claude/hooks/bootstrap-vault.sh"
  "$HOME/.claude/hooks/delegation-gate-v2.sh|$DIR/claude/hooks/delegation-gate-v2.sh"
  "$HOME/.claude/hooks/bash-danger-gate.sh|$DIR/claude/hooks/bash-danger-gate.sh"
  "$HOME/.claude/hooks/vault-recall.sh|$DIR/claude/hooks/vault-recall.sh"
  "$HOME/.claude/hooks/vault-read-log.sh|$DIR/claude/hooks/vault-read-log.sh"
  "$HOME/.claude/hooks/next-pane-resolve.sh|$DIR/claude/hooks/next-pane-resolve.sh"
  "$HOME/.claude/hooks/check-sub-update.sh|$DIR/claude/hooks/check-sub-update.sh"
  # 2026-08-30追加: settings.jsonには2026-08-10導入時から登録済みだったが、
  # install-main.shへのlink配置が漏れていた（同型4回目・§9.0 A-0-2で修理）。
  # このSYMLINKS一覧にも同時に漏れていたため、あわせて追加する。
  "$HOME/.claude/hooks/context-size-warn.sh|$DIR/claude/hooks/context-size-warn.sh"
  "$HOME/.codex/AGENTS.md|$DIR/codex/AGENTS.md"
  "$HOME/.codex/hooks.json|$DIR/codex/hooks.json"
)
if [ -d "$DIR/claude/agents" ]; then
  for f in "$DIR"/claude/agents/*.md; do
    [ -e "$f" ] || continue
    name="$(basename "$f")"
    SYMLINKS+=("$HOME/.claude/agents/$name|$DIR/claude/agents/$name")
  done
fi

sym_drift=0
for pair in "${SYMLINKS[@]}"; do
  dest="${pair%%|*}"
  expect="${pair#*|}"
  if [ ! -e "$dest" ] && [ ! -L "$dest" ]; then
    item_drift "[MISSING] $dest が存在しません（未インストール？）"
    sym_drift=$((sym_drift + 1))
  elif [ ! -L "$dest" ]; then
    item_drift "[NOT-SYMLINK] $dest は symlink ではありません（実ファイルのまま。pre-aienv.bak退避漏れ or 手動編集？）"
    sym_drift=$((sym_drift + 1))
  else
    actual="$(readlink "$dest")"
    if [ "$actual" != "$expect" ]; then
      item_drift "[WRONG-TARGET] $dest -> ${actual} （期待: ${expect}）"
      sym_drift=$((sym_drift + 1))
    fi
  fi
done
log "symlink総数: ${#SYMLINKS[@]}件 / drift: ${sym_drift}件"
[ "$sym_drift" -eq 0 ] && log "  -> ✅ 全symlinkがrepoを指しています"

echo
echo "======================================================================"
echo "①-2 ~/.claude/settings.json（生成物）と repo テンプレのプレースホルダ展開差分"
echo "======================================================================"

# claude/settings.json は2026-08-21からsymlinkではなく生成物（scripts/install-main.sh
# generate_settings_json()。理由は同ファイル冒頭コメント参照＝JSONもシェル変数
# 展開されない・symlinkのままだと`/model`実行時にClaude Code自身がrepo管理下の
# ファイルを直接書き換えてしまう副作用があった）。①のsymlink一覧からは除外し、
# ②のTOML比較と同型（プレースホルダ展開込みの内容比較）だがJSON向けに簡略化した
# チェックをここで行う。まず旧symlinkのまま残っていないか（[UNEXPECTED-SYMLINK]）
# を確認してから、生成物としての内容比較に進む。
#
# ⚠️ "model"キーはもはや特別扱いしない（2026-09-01工程横断レビュー差し戻し
# MAJOR対応）。旧実装はセッション内`/model`での意図的な一時切替を理由に
# 不一致を常にINFO表示へ丸めており、旧modelのまま放置されても週次総drift
# 0になっていた。V13は「週次driftで拾う」契約（設計書§6.2-B S10）であり、
# effortLevelとの非対称も生んでいたため、他のキーと同じDRIFT分類
# （MISSING-KEY/DIFF/EXTRA-KEY）で扱う（意図的な切替の除外はしない）。
#
# 既知アプリ管理キー一覧（2026-08-30追加・§9.0検出事項⑤/
# [[Knowledge/symlink-config-app-writeback-pitfall]]）: Claude Code自身が
# settings.jsonへ書き戻すキー。実測2件はいずれもトップレベルキーのため、
# トップレベルキー完全一致でのみ除外する（Codex一次レビュー指摘・Minor対応:
# config.tomlの②はテーブルの深さを問わないleaf key判定だが、settings.jsonで
# 同じ判定にすると別階層に偶然同名キーがあった場合まで誤って除外してしまう。
# table prefix一覧は設けない）。これら以外のテンプレに無いキー（EXTRA-KEY）は
# 引き続きWARNに留めずdrift計上する。
KNOWN_APP_MANAGED_SETTINGS_JSON_KEYS=(
  "agentPushNotifEnabled"   # Claude Codeアプリが自動追記する通知設定（2026-08-28実測・実害なし）
  "inputNeededNotifEnabled" # 同上
)
#
# machine-roleマーカーを読み、期待されるmodel/effort値を決定する
# （fail-closed＝マーカー不在・読めない・中身が「sub」以外はすべてmain扱い。
# 他フックと同じ判定パターンを踏襲）。値そのものは自前の値表を持たず、値出力口
# （scripts/install-main.sh --print-leader-runtime [--sub-delegate]）を呼んで
# 得る（§9.0 A-0-3＝値表2箇所重複の解消・2026-09-01 配役表解凍 §4.2-a・§4.4で
# --print-modelから改名。診断からは副作用ゼロの--print-leader-runtimeだけを
# 呼び、--sub-delegate本体は呼ばない。⚠️ --sub-delegateフラグ自体はv1委譲期間の
# フォールバック値選択〈AIENV_MODEL_MAIN/AIENV_MODEL_SUB〉に引き続き使うため、
# --print-leader-runtimeと併用する＝§4.2-f）。
#
# leader_runtime_error_message <コード> [<理由>] — install-main.sh
# --print-leader-runtime が標準エラーへ返す機械可読コード（4.2-b）を人向け
# 文言へ変換する（2026-09-01 設計書§4.4。旧実装はここを`2>/dev/null`で理由を
# 捨てて[MODEL-VALUE-UNAVAILABLE]の定型文だけに丸めていた）。
# scripts/update-sub.shにも同名の関数を意図的に複製している（両スクリプトは
# 互いをsourceしない独立プロセスで、変換ロジックは数行のみのため共有libを
# 新設するほどではない＝bedrock_env_file_kind()等ここまでの既存の複製方針と
# 同型）。
leader_runtime_error_message() {
  local code="$1" reason="${2:-}" msg=""
  case "$code" in
    PROFILE_NOT_FOUND|PROFILE_UNREADABLE)
      msg="プロファイル実体を読み取れませんでした（不在・symlink・権限不足等の可能性）"
      ;;
    PROFILE_MIXED)
      msg="プロファイルのschema_versionが職種行と整合していません（v2の職種行があるのにschema_versionが1のまま）"
      ;;
    PROFILE_LEGACY_V1)
      msg="プロファイルがv1形式のままです。v2へ移行してください"
      ;;
    PROFILE_INVALID:*)
      msg="プロファイルの構文または検証エラーです（${code#PROFILE_INVALID:}）"
      ;;
    PROFILE_RESOLVER_MISSING)
      msg="resolver本体（共有lib）が見つかりません"
      ;;
    LEADER_UNCONFIGURED)
      msg="リーダー配役が未確定です（unknown・not_adopted・行なしのいずれか）"
      ;;
    LEADER_UNAVAILABLE_NO_FALLBACK)
      msg="リーダーの本命・fallbackの双方が使用不可です"
      ;;
    LEADER_CANDIDATE_INVALID:*)
      msg="リーダー候補の検証に失敗しました（条件番号: ${code#LEADER_CANDIDATE_INVALID:}）"
      ;;
    PROFILE_RESOLVER_ERROR|*)
      msg="リーダー実行値を解決できませんでした（原因不明。コード: ${code:-なし}）"
      ;;
  esac
  [ -n "$reason" ] && msg="${msg}（${reason}）"
  printf '%s。プロファイルのリーダー行（role.leader）を確認してください: %s' "$msg" "$AIENV_LOCAL_PROFILE_PATH_HINT"
}
: "${AIENV_LOCAL_PROFILE_PATH_HINT:=$HOME/.config/takumi009-ai-env/profile.md}"

SETTINGS_JSON_LIVE="$HOME/.claude/settings.json"
SETTINGS_JSON_TEMPLATE="$DIR/claude/settings.json"
MACHINE_ROLE_RAW="$(cat "$AIENV_MACHINE_ROLE_MARKER" 2>/dev/null)"
MACHINE_ROLE="${MACHINE_ROLE_RAW#"${MACHINE_ROLE_RAW%%[![:space:]]*}"}"
MACHINE_ROLE="${MACHINE_ROLE%"${MACHINE_ROLE##*[![:space:]]}"}"
EXPECTED_MODEL=""
EXPECTED_EFFORT=""
EXPECTED_EFFORT_SET=0
EXPECTED_MODEL_UNAVAILABLE_REASON=""
# Bedrock envファイルの期待マージ分（2026-08-30 工程横断レビュー指摘・
# MAJOR-5対応）。値表・許可リストをここに複製せず、install-main.shの
# --print-bedrock-env-json（副作用ゼロの値出力口）を呼ぶ。
# ⚠️ 「ファイルが存在しない」場合だけexit 0で{}が返る。ファイルが存在する
# のに読取・解析に失敗した場合は非0終了する（install-main.sh
# compute_bedrock_env_json()参照）ため、ここでは fail-open で{}へ丸めず、
# 失敗を独立したフラグ（EXPECTED_BEDROCK_ENV_UNAVAILABLE）として持ち回り、
# 後段で[BEDROCK-ENV-VALUE-UNAVAILABLE]としてdrift計上する（Codex二次
# レビュー指摘・Major対応: 従来は失敗時も{}扱いにしており、Bedrock envが
# 監視できていないのに「一致」と誤判定しうる穴があった）。exit0・非空文字列
# でも中身がJSONとして壊れている／トップレベルがdictでない／envキーが
# dictでない（旧flat形式含む）場合は同様に監視不能として扱う（2026-08-30
# Codex 2巡目差し戻し・MAJOR対応: 従来はexit0・非空なら無条件で信頼しており、
# 壊れた/旧形式のpayloadを静かに「空env」として受理する穴があった）。
EXPECTED_BEDROCK_ENV_JSON='{"env": {}, "rejected_keys": [], "malformed_lines": []}'
EXPECTED_BEDROCK_ENV_UNAVAILABLE=0
if [ -x "$DIR/scripts/install-main.sh" ]; then
  # --sub-delegateは併用する（v2解決自体には使われない＝§4.2-fだが、
  # v1委譲期間中のフォールバック値〈AIENV_MODEL_MAIN/AIENV_MODEL_SUB〉の
  # 出し分けは引き続きこのフラグの有無だけで決まるため、外すとv1機の
  # サブがメイン既定値へ倒れてしまう＝2026-09-01実測で発見・回帰させない）。
  _leader_runtime_print_args=(--print-leader-runtime)
  [ "$MACHINE_ROLE" = "sub" ] && _leader_runtime_print_args+=(--sub-delegate)
  _leader_runtime_err_tmp="$(mktemp 2>/dev/null)" || _leader_runtime_err_tmp=""
  if [ -n "$_leader_runtime_err_tmp" ]; then
    if _leader_runtime_json="$("$DIR/scripts/install-main.sh" "${_leader_runtime_print_args[@]}" 2>"$_leader_runtime_err_tmp")"; then
      # ⚠️ JSONとして読めることだけでなく契約（4.2-a）が定める形自体も検査
      # する: ①stdoutが物理行1行だけ②トップレベルはobject③modelは非空文字列
      # かつC0制御文字・DEL（0x00-0x1F・0x7F）を含まない④effortは**キーが
      # 存在する場合に限り**同様の非空clean文字列（2026-09-01 Codex一次・
      # 二次レビュー指摘・Major対応。scripts/update-sub.shの同名処理と
      # 意図的に同じ検査を複製）。
      if _leader_runtime_fields="$(printf '%s' "$_leader_runtime_json" | python3 -c '
import json, sys

def is_clean_str(s):
    if not isinstance(s, str) or s == "":
        return False
    return not any(ord(c) < 0x20 or ord(c) == 0x7f for c in s)

raw = sys.stdin.read()
if raw.count(chr(10)) > 1 or (raw.count(chr(10)) == 1 and not raw.endswith(chr(10))):
    sys.exit(1)
d = json.loads(raw)
if not isinstance(d, dict):
    sys.exit(1)
model = d.get("model")
if not is_clean_str(model):
    sys.exit(1)
print(model)
if "effort" in d:
    effort = d["effort"]
    if not is_clean_str(effort):
        sys.exit(1)
    print("1")
    print(effort)
else:
    print("0")
    print("")
' 2>/dev/null)"; then
        EXPECTED_MODEL="$(printf '%s\n' "$_leader_runtime_fields" | sed -n '1p')"
        EXPECTED_EFFORT_SET="$(printf '%s\n' "$_leader_runtime_fields" | sed -n '2p')"
        EXPECTED_EFFORT="$(printf '%s\n' "$_leader_runtime_fields" | sed -n '3p')"
      else
        EXPECTED_MODEL_UNAVAILABLE_REASON="$(leader_runtime_error_message "PROFILE_RESOLVER_ERROR" "リーダー実行値のJSON解析に失敗しました（resolve-leaderの出力契約違反の可能性）")"
      fi
    else
      # ⚠️ 契約（4.2-b）は「標準エラーへ`<コード>\t<理由>`を1行」を定めている。
      # 契約外（複数行・タブ無し・理由が空/制御文字混入等）の出力は生テキスト
      # のまま理由として再掲しない（2026-09-01 Codex二次レビュー指摘・
      # Major対応。scripts/update-sub.shと同じ検査を複製）。
      _leader_runtime_stderr_parsed="$(python3 -c '
import re, sys

def is_clean_str(s):
    return s != "" and not any(ord(c) < 0x20 or ord(c) == 0x7f for c in s)

# 機械可読コードは契約（4.2-b・profile-resolve-contract-2026-09-01.md §4）が
# 列挙する既知の集合に限定する（2026-09-01 Codex三次レビュー指摘・Major
# 対応。scripts/update-sub.shと同じ検査を複製）。
KNOWN_CODE_RE = re.compile(
    r"^(PROFILE_NOT_FOUND|PROFILE_UNREADABLE|PROFILE_MIXED|PROFILE_LEGACY_V1|"
    r"PROFILE_RESOLVER_MISSING|PROFILE_RESOLVER_ERROR|LEADER_UNCONFIGURED|"
    r"LEADER_UNAVAILABLE_NO_FALLBACK|"
    r"PROFILE_INVALID:[A-Za-z0-9_-]+|LEADER_CANDIDATE_INVALID:[A-Za-z0-9_-]+)$"
)

with open(sys.argv[1], encoding="utf-8", errors="replace") as f:
    raw = f.read()
lines = raw.split(chr(10))
if lines and lines[-1] == "":
    lines = lines[:-1]
if len(lines) != 1 or chr(9) not in lines[0]:
    print("INVALID")
    sys.exit(0)
code, reason = lines[0].split(chr(9), 1)
if not KNOWN_CODE_RE.match(code) or not is_clean_str(reason):
    print("INVALID")
    sys.exit(0)
print("VALID")
print(code)
print(reason)
' "$_leader_runtime_err_tmp" 2>/dev/null)"
      if [ "$(printf '%s\n' "$_leader_runtime_stderr_parsed" | sed -n '1p')" = "VALID" ]; then
        _leader_runtime_code="$(printf '%s\n' "$_leader_runtime_stderr_parsed" | sed -n '2p')"
        _leader_runtime_reason="$(printf '%s\n' "$_leader_runtime_stderr_parsed" | sed -n '3p')"
        EXPECTED_MODEL_UNAVAILABLE_REASON="$(leader_runtime_error_message "${_leader_runtime_code:-PROFILE_RESOLVER_ERROR}" "$_leader_runtime_reason")"
      else
        EXPECTED_MODEL_UNAVAILABLE_REASON="$(leader_runtime_error_message "PROFILE_RESOLVER_ERROR" "標準エラーの出力が契約（4.2-b・1行のコード+理由）に従っていません")"
      fi
    fi
    rm -f "$_leader_runtime_err_tmp"
  else
    EXPECTED_MODEL_UNAVAILABLE_REASON="一時ファイルを作成できませんでした"
  fi
  if ! EXPECTED_BEDROCK_ENV_JSON="$("$DIR/scripts/install-main.sh" --print-bedrock-env-json 2>/dev/null)"; then
    EXPECTED_BEDROCK_ENV_UNAVAILABLE=1
    EXPECTED_BEDROCK_ENV_JSON='{"env": {}, "rejected_keys": [], "malformed_lines": []}'
  elif [ -z "$EXPECTED_BEDROCK_ENV_JSON" ]; then
    EXPECTED_BEDROCK_ENV_UNAVAILABLE=1
    EXPECTED_BEDROCK_ENV_JSON='{"env": {}, "rejected_keys": [], "malformed_lines": []}'
  elif ! python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)
sys.exit(0 if isinstance(d, dict) and isinstance(d.get('env'), dict) else 1)
" "$EXPECTED_BEDROCK_ENV_JSON" 2>/dev/null; then
    # exit0・非空文字列でも、JSON不正／トップレベルがdictでない／envキーが
    # dictでない（旧flat形式やスキーマ崩れを含む）場合はここで検出し、
    # fail-openで{}へ丸めず監視不能として扱う（2026-08-30 Codex 2巡目差し戻し・
    # MAJOR対応: 従来はexit0かつ空文字列でなければ無条件で信頼しており、
    # 壊れた/旧形式のpayloadを静かに「空env」として受理してしまう穴があった）。
    EXPECTED_BEDROCK_ENV_UNAVAILABLE=1
    EXPECTED_BEDROCK_ENV_JSON='{"env": {}, "rejected_keys": [], "malformed_lines": []}'
  fi
else
  EXPECTED_BEDROCK_ENV_UNAVAILABLE=1
  EXPECTED_MODEL_UNAVAILABLE_REASON="scripts/install-main.sh が見つからないか実行権限がありません"
fi

if [ -L "$SETTINGS_JSON_LIVE" ]; then
  # 2026-08-21より前のinstall-main.shはsettings.jsonをsymlinkしていた（旧方式）。
  # 旧symlinkがrepoテンプレをそのまま指している場合、テンプレの"model"値は
  # __AIENV_MODEL__プレースホルダの生文字列のままであり、下の内容比較ロジックへ
  # 素通しすると（"model"は特別扱いのため）誤って「一致」と判定されかねない
  # （Codex一次レビュー指摘・Major対応）。symlinkのままである時点で「/model実行時に
  # repo管理下のファイルが直接書き換わる」旧来の問題が解消されていないため、
  # 内容比較を行わず即座にdrift計上する。
  item_drift "[UNEXPECTED-SYMLINK] $SETTINGS_JSON_LIVE がsymlinkのままです（2026-08-21以降は生成物であるべき。旧versionのinstall-main.shを適用した環境の可能性が高いため、scripts/install-main.shを再実行してください）"
elif [ ! -f "$SETTINGS_JSON_LIVE" ]; then
  item_drift "[MISSING] $SETTINGS_JSON_LIVE が存在しません（未インストール？）"
elif [ ! -f "$SETTINGS_JSON_TEMPLATE" ]; then
  item_drift "[MISSING] リポジトリ側テンプレが見つかりません: $SETTINGS_JSON_TEMPLATE"
elif [ -z "$EXPECTED_MODEL" ]; then
  # 値出力口（install-main.sh --print-leader-runtime）が値を返さなかった場合は
  # fail-openで「一致」扱いにせず監視不能として drift 計上する
  # （③GIT-STATUS-CHECK-FAILED・⑤GH-CHECK-FAILEDと同型の既存の設計思想。
  # 2026-09-01 配役表解凍 §4.4: 理由は4.2-bの機械可読コードを
  # leader_runtime_error_message()で人向け文言へ変換したもの＝旧実装の
  # `2>/dev/null`による定型文への丸めを廃止）。
  item_drift "[MODEL-VALUE-UNAVAILABLE] リーダー実行値の出力口（scripts/install-main.sh --print-leader-runtime）が値を返しませんでした＝監視不能: ${EXPECTED_MODEL_UNAVAILABLE_REASON:-理由不明}"
elif [ "$EXPECTED_BEDROCK_ENV_UNAVAILABLE" = "1" ]; then
  # Bedrock env値の出力口（install-main.sh --print-bedrock-env-json）が
  # 非0終了した場合（envファイルは存在するのに読取・解析に失敗）は、
  # fail-openで{}扱いにせず監視不能として drift 計上する（2026-08-30
  # Codex二次レビュー指摘・Major対応と同型の既存の設計思想）。
  item_drift "[BEDROCK-ENV-VALUE-UNAVAILABLE] Bedrock env値の出力口（scripts/install-main.sh --print-bedrock-env-json）が失敗しました（envファイルの読取・解析エラーの可能性）＝監視不能"
else
  app_managed_keys_joined="$(printf '%s\x1f' "${KNOWN_APP_MANAGED_SETTINGS_JSON_KEYS[@]}")"
  SETTINGS_JSON_CLASSIFY_OUT="$(python3 -c "
import sys, json

def flatten(d, prefix=''):
    out = {}
    if isinstance(d, dict):
        for k, v in d.items():
            path = f'{prefix}.{k}' if prefix else k
            if isinstance(v, dict) and v:
                out.update(flatten(v, path))
            else:
                out[path] = v
    return out

def render(obj, model):
    if isinstance(obj, dict):
        return {k: render(v, model) for k, v in obj.items()}
    if isinstance(obj, list):
        return [render(v, model) for v in obj]
    if isinstance(obj, str):
        return obj.replace('__AIENV_MODEL__', model)
    return obj

try:
    with open(sys.argv[1]) as f:
        live = json.load(f)
except Exception as e:
    print(f'PARSE_FAILED\tlive\t{type(e).__name__}: {e}')
    sys.exit(0)

try:
    with open(sys.argv[2]) as f:
        template = json.load(f)
except Exception as e:
    print(f'PARSE_FAILED\ttemplate\t{type(e).__name__}: {e}')
    sys.exit(0)

# テンプレの"model"値が __AIENV_MODEL__ の目印から変わっていないかを確認する
# （Codex二次レビュー指摘・Minor対応: ここを確認せずrender()するだけだと、誰かが
# テンプレへ再び特定モデルをハードコードする回帰＝今回のタスクの発端そのもの＝が
# 起きても、そのハードコード値がそのまま「期待値」として扱われてしまい検知
# できなかった）。scripts/install-main.sh generate_settings_json() も同じ検証を
# install時に行う（インストール時とdrift監視時の二重の安全網）。
if not isinstance(template, dict) or template.get('model') != '__AIENV_MODEL__':
    got = template.get('model') if isinstance(template, dict) else type(template).__name__
    print(f'TEMPLATE_INVALID\t{got!r}')
    sys.exit(0)

# effortLevelの目印検査はmodel側と対で行う（2026-09-01 配役表解凍 §4.4）。
# ⚠️ model側だけ守ると、誰かがテンプレへ特定のeffort値を直接ハードコード
# しても検出できない非対称が残る（4.2-g・install-main.sh generate_settings_
# json()と同じ検証）。
if template.get('effortLevel') != '__AIENV_EFFORT__':
    got_effort = template.get('effortLevel')
    print(f'TEMPLATE_INVALID_EFFORT\t{got_effort!r}')
    sys.exit(0)

expected_model = sys.argv[3]
app_managed_keys = set(k for k in sys.argv[4].split(chr(0x1f)) if k)
expected_effort_set = sys.argv[6] == '1' if len(sys.argv) > 6 else False
expected_effort = sys.argv[7] if len(sys.argv) > 7 else ''
# effortLevelは値そのものをテンプレの文字列置換（render）に任せない
# （§3.8・4.2-g: 未指定時は"効かない値へ空文字を埋める"のではなく**キー自体を
# 削除**するのが正しい生成規則であり、V13は「effortLevelキーが存在しないこと」
# を検査対象にする＝存在したらdrift。render()の単純な文字列置換ではキーの
# 削除を表現できないため、flatten()より前にdictへ直接反映する）。
if expected_effort_set:
    template['effortLevel'] = expected_effort
else:
    template.pop('effortLevel', None)
live_flat = flatten(live)
tmpl_flat = flatten(render(template, expected_model))

# Bedrock envファイルからの期待マージ分（2026-08-30 工程横断レビュー指摘・
# MAJOR-5対応）: install-main.sh --print-bedrock-env-json（値出力口の一本化・
# ①-2の他項目と同じ設計）が返す値をテンプレの期待値へ合成する。これが無いと、
# 正しくBedrockのenvをマージ済みのsettings.jsonが恒常的にEXTRA-KEY drift
# 扱いになってしまう（installer/update-subは正しく動いているのに毎回
# 誤報が出る状態）。
# ⚠️ 出力形式は{'env': {...}, 'rejected_keys': [...], 'malformed_lines': [...]}
# という構造化オブジェクト（2026-08-30 工程横断レビュー指摘・MAJOR-A対応で
# rejected_keys/malformed_linesを呼び出し側〈generate_settings_json・
# update-sub.sh〉へ伝えるために追加された）。check-drift.shはこのうち
# 'env'サブオブジェクトだけを期待値の合成に使う（rejected_keys・
# malformed_linesはdrift判定に使わない＝それらはsettings.jsonへ反映されない
# ことが正しい挙動のため）。
try:
    expected_bedrock_payload = json.loads(sys.argv[5]) if len(sys.argv) > 5 else {}
    if not isinstance(expected_bedrock_payload, dict):
        expected_bedrock_payload = {}
except Exception:
    expected_bedrock_payload = {}
expected_bedrock_env = expected_bedrock_payload.get('env') or {}
if not isinstance(expected_bedrock_env, dict):
    expected_bedrock_env = {}
for _k, _v in expected_bedrock_env.items():
    tmpl_flat[f'env.{_k}'] = _v

for key in sorted(set(live_flat) | set(tmpl_flat)):
    # ⚠️ "model"キーはもはや特別扱いしない（2026-09-01工程横断レビュー
    # 差し戻しMAJOR対応）。旧実装はセッション内の/modelスラッシュコマンドでの
    # 意図的な一時切替を理由にmodel不一致を常にMODEL_INFOへ丸めており、旧
    # モデルのまま放置されても週次総drift 0になっていた（V13は「週次driftで
    # 拾う」契約＝設計書§6.2-B S10「次回生成で上書きされる。その前にV13が
    # ⚠️＋週次drift」・
    # effortLevelとの非対称も解消する。意図的な切替の除外はしない＝下の通常
    # DRIFT分類（MISSING-KEY/DIFF/EXTRA-KEY）へeffortLevel等と同列に合流させる）。
    # 既知アプリ管理キー（2026-08-30追加・§9.0検出事項⑤）: トップレベルの
    # キー名完全一致でのみ除外する（Codex一次レビュー指摘・Minor対応:
    # config.toml②はテーブルの深さを問わないleaf key判定だが、settings.jsonの
    # 実測2件は両方ともトップレベルキーであり、leaf判定のままだと
    # 別階層（例: 別セクション配下）に偶然同名キーがあった場合まで誤って
    # 除外してしまう。実測範囲に限定してトップレベル一致のみ許容する）。
    # テンプレ記載の有無に関わらず優先する＝Claude Codeが書き戻す値なので、
    # テンプレとの厳密一致も追随判定も意味を持たない。
    if '.' not in key and key in app_managed_keys:
        continue
    # "env."配下のキーは値を出力しない（2026-08-30 Codex一次レビュー指摘・Major
    # 対応: §9.0 A-1-4でBedrock envファイルの値がsettings.jsonの"env"ブロックへ
    # 取り込まれるようになったため、推論プロファイルARN等（アカウントIDを含み
    # うる＝§4.5）がdrift出力・週次通知ログに平文で載る経路になっていた。
    # 絶対厳守③に従い、キー名は出すが値は常に<redacted>にする）。
    def _show(v):
        return '<redacted>' if key.startswith('env.') else repr(v)
    if key in tmpl_flat:
        if key not in live_flat:
            print(f'DRIFT\tMISSING-KEY\t{key}\t{_show(tmpl_flat[key])}')
        elif live_flat[key] != tmpl_flat[key]:
            print(f'DRIFT\tDIFF\t{key}\t{_show(tmpl_flat[key])}\t{_show(live_flat[key])}')
    else:
        # config.tomlの②と異なり、settings.jsonには既知アプリ管理キー一覧に
        # 載らないその他の未知キーはWARN表示に留めず即drift計上する（Codex一次
        # レビュー指摘・Major対応: WARNのみだとpermissions等への意図しない追加
        # 変更が総drift0のまま見逃され続ける）。
        print(f'DRIFT\tEXTRA-KEY\t{key}\t{_show(live_flat[key])}')
" "$SETTINGS_JSON_LIVE" "$SETTINGS_JSON_TEMPLATE" "$EXPECTED_MODEL" "$app_managed_keys_joined" "$EXPECTED_BEDROCK_ENV_JSON" "$EXPECTED_EFFORT_SET" "$EXPECTED_EFFORT" 2>&1)"
  SETTINGS_JSON_CLASSIFY_RC=$?
  if [ "$SETTINGS_JSON_CLASSIFY_RC" -ne 0 ]; then
    item_drift "[JSON-PARSE-FAILED] 検査①-2の実行自体に失敗しました（python3 exit=${SETTINGS_JSON_CLASSIFY_RC}）＝監視不能。詳細: ${SETTINGS_JSON_CLASSIFY_OUT}"
  else
    drift_before=$TOTAL_DRIFT
    while IFS=$'\t' read -r kind a b c d; do
      [ -z "$kind" ] && continue
      case "$kind" in
        PARSE_FAILED)
          case "$a" in
            live) parse_failed_path="$SETTINGS_JSON_LIVE" ;;
            template) parse_failed_path="$SETTINGS_JSON_TEMPLATE" ;;
            *) parse_failed_path="(${a})" ;;
          esac
          item_drift "[JSON-PARSE-FAILED] ${parse_failed_path} をJSONとして解析できませんでした（${b}）＝監視不能"
          ;;
        TEMPLATE_INVALID)
          item_drift "[TEMPLATE-INVALID] ${SETTINGS_JSON_TEMPLATE} の 'model' フィールドが __AIENV_MODEL__ の目印から変わっています（現在: ${a}）。誰かが特定モデルをテンプレへ直接ハードコードした可能性があります。__AIENV_MODEL__ プレースホルダへ戻してください"
          ;;
        TEMPLATE_INVALID_EFFORT)
          # 2026-09-01 配役表解凍 §4.4: model側と対のeffortLevel目印検査
          # （__AIENV_EFFORT__）。片側だけ検査すると「誰かがテンプレへeffort
          # を直接ハードコードした」を検出できず非対称が残る。
          item_drift "[TEMPLATE-INVALID] ${SETTINGS_JSON_TEMPLATE} の 'effortLevel' フィールドが __AIENV_EFFORT__ の目印から変わっています（現在: ${a}）。誰かが特定のeffortをテンプレへ直接ハードコードした可能性があります。__AIENV_EFFORT__ プレースホルダへ戻してください"
          ;;
        DRIFT)
          case "$a" in
            MISSING-KEY)
              item_drift "[MISSING-KEY] キー '${b}' が ${SETTINGS_JSON_LIVE} にありません（テンプレ値: ${c}）"
              ;;
            DIFF)
              item_drift "[DIFF] キー '${b}' の値がテンプレと異なります（テンプレ: ${c} / 実ファイル: ${d}）"
              ;;
            EXTRA-KEY)
              item_drift "[EXTRA-KEY] キー '${b}' が ${SETTINGS_JSON_LIVE} にのみ存在します（テンプレにありません。値: ${c}）"
              ;;
          esac
          ;;
      esac
    done <<EOF
$SETTINGS_JSON_CLASSIFY_OUT
EOF
    if [ "$TOTAL_DRIFT" -eq "$drift_before" ]; then
      log "  -> ✅ settings.jsonはテンプレと一致しています"
    fi
  fi
fi

echo
echo "======================================================================"
echo "①-3 実効model/effortを上書きしうる他の経路の存在確認（値は出さない・2026-09-01 設計書§4.4 V13拡張）"
echo "======================================================================"

# V13の三者一致（①-2）はファイル内容の比較でしかなく、環境変数は設定より
# 優先するため、ファイルが一致していても実効値は別の経路で上書きされうる
# （§1-12）。ここでは**キーの存在だけ**を検査し、値は一切出力しない
# （絶対厳守③）。検出しても「上書き経路が存在する」という事実の通知であり、
# 意図的な運用（例: プロジェクト固有の一時設定）の可能性もあるため fail
# ではなくdrift計上（週次通知＝V13は「drift専用」＝resolverの契約ではない）。
#
# ⚠️ 既知の限界（残余リスクとして受容・設計書§9-1/V13の記述どおり）:
#  - CLIの `--model`/`--effort`・セッション内の `/model`/`/effort` 一時切替は
#    検出できない。
#  - project/local settings は**このスクリプトを実行した時点のカレント
#    ディレクトリ**（$PWD）だけを見る。他のプロジェクトディレクトリの
#    .claude/settings*.json は検知できない（1台のワークツリーだけを
#    継続監視する用途を超えるため、本ツールでは複数プロジェクトを走査しない）。
: "${AIENV_MANAGED_SETTINGS_FILE:=/Library/Application Support/ClaudeCode/managed-settings.json}"
V13_OVERRIDE_OUT="$(python3 -c "
import json, os, sys

def key_exists(path, key):
    # 戻り値: 'yes'/'no'/'unavailable'（値は一切読み取り結果に含めない）。
    if not os.path.isfile(path):
        return 'absent'
    try:
        with open(path, encoding='utf-8') as f:
            d = json.load(f)
    except Exception:
        return 'unavailable'
    if not isinstance(d, dict):
        return 'unavailable'
    return 'yes' if key in d else 'no'

pwd_settings = os.path.join(os.getcwd(), '.claude', 'settings.json')
pwd_local_settings = os.path.join(os.getcwd(), '.claude', 'settings.local.json')
managed_settings = sys.argv[1]
live_settings = sys.argv[2]
expected_model = sys.argv[3]

# --- model側 ---
if os.environ.get('ANTHROPIC_MODEL') is not None:
    print('MODEL_OVERRIDE\tANTHROPIC_MODEL（環境変数）')
if os.environ.get('ANTHROPIC_DEFAULT_MODEL') is not None:
    print('MODEL_OVERRIDE\tANTHROPIC_DEFAULT_MODEL（環境変数）')
for label, path in (('プロジェクト設定(.claude/settings.json)', pwd_settings),
                     ('プロジェクトローカル設定(.claude/settings.local.json)', pwd_local_settings),
                     ('managed settings', managed_settings)):
    r = key_exists(path, 'model')
    if r == 'yes':
        print(f'MODEL_OVERRIDE\t{label}のmodelキー')
    elif r == 'unavailable':
        print(f'UNAVAILABLE\t{label}（modelキー確認）')

# --- effort側 ---
if os.environ.get('CLAUDE_CODE_EFFORT_LEVEL') is not None:
    print('EFFORT_OVERRIDE\tCLAUDE_CODE_EFFORT_LEVEL（環境変数）')
for label, path in (('プロジェクト設定(.claude/settings.json)', pwd_settings),
                     ('プロジェクトローカル設定(.claude/settings.local.json)', pwd_local_settings),
                     ('managed settings', managed_settings)):
    r = key_exists(path, 'effortLevel')
    if r == 'yes':
        print(f'EFFORT_OVERRIDE\t{label}のeffortLevelキー')
    elif r == 'unavailable':
        print(f'UNAVAILABLE\t{label}（effortLevelキー確認）')

# --- modelSettings.<model>.effortLevel（live設定ファイル自身の中） ---
# ⚠️ modelSettings・modelSettings.<model>のどちらかが辞書型でない（壊れた/
# 想定外の構造）場合は「無い」と混同せず監視不能として報告する（2026-09-01
# Codex一次レビュー指摘・Major対応: 従来はisinstance()チェックがFalseの
# 場合に何も出力せず、型不正を静かに「健全」扱いしていた＝false negative）。
if expected_model:
    r_live = key_exists(live_settings, 'modelSettings')
    if r_live == 'unavailable':
        print('UNAVAILABLE\tmodelSettings（live settings.json確認）')
    elif r_live == 'yes':
        try:
            with open(live_settings, encoding='utf-8') as f:
                live_d = json.load(f)
            ms = live_d.get('modelSettings')
            if not isinstance(ms, dict):
                print('UNAVAILABLE\tmodelSettings（live settings.json確認・型不正）')
            elif expected_model in ms:
                entry = ms[expected_model]
                if not isinstance(entry, dict):
                    print(f'UNAVAILABLE\tmodelSettings.<model>（live settings.json確認・型不正）')
                elif 'effortLevel' in entry:
                    print('EFFORT_OVERRIDE\tmodelSettings.<model>.effortLevel（live settings.json）')
        except Exception:
            print('UNAVAILABLE\tmodelSettings（live settings.json確認）')
" "$AIENV_MANAGED_SETTINGS_FILE" "$SETTINGS_JSON_LIVE" "$EXPECTED_MODEL" 2>&1)"
V13_OVERRIDE_RC=$?
if [ "$V13_OVERRIDE_RC" -ne 0 ]; then
  item_drift "[V13_UNAVAILABLE] 実効model/effortの上書き経路確認自体に失敗しました（python3 exit=${V13_OVERRIDE_RC}）＝監視不能。詳細: ${V13_OVERRIDE_OUT}"
else
  v13_override_before=$TOTAL_DRIFT
  while IFS=$'\t' read -r v13_kind v13_detail; do
    [ -z "$v13_kind" ] && continue
    case "$v13_kind" in
      MODEL_OVERRIDE)
        item_drift "[EFFECTIVE_MODEL_OVERRIDE_PRESENT] ${v13_detail}が存在します（値は出しません）＝settings.json側が正しくてもこちらが優先され実効modelが食い違う可能性があります。意図した設定でなければ削除してください"
        ;;
      EFFORT_OVERRIDE)
        item_drift "[EFFECTIVE_EFFORT_OVERRIDE_PRESENT] ${v13_detail}が存在します（値は出しません）＝settings.json側が正しくてもこちらが優先され実効effortが食い違う可能性があります。意図した設定でなければ削除してください"
        ;;
      UNAVAILABLE)
        item_drift "[V13_UNAVAILABLE] ${v13_detail}を確認できませんでした（JSON解析失敗等）＝監視不能"
        ;;
    esac
  done <<EOF
$V13_OVERRIDE_OUT
EOF
  if [ "$TOTAL_DRIFT" -eq "$v13_override_before" ]; then
    log "  -> ✅ 実効model/effortを上書きしうる既知の経路（環境変数・project/local/managed settings・modelSettings）は検出されませんでした（CLIフラグ・セッション内一時切替は検出対象外＝残余リスク）"
  fi
fi

echo
echo "======================================================================"
echo "② ~/.codex/config.toml（生成物）と repo テンプレのプレースホルダ展開差分"
echo "======================================================================"

# キー単位のTOML三分類（2026-08-10 denylist方式から移行・
# [[Decisions/2026-08-10-round6-rulings]] 決定2）。
# 旧: diff+ignore正規表現denylist方式。Codexアプリのビルド更新のたび新キーが
# 増えて壊れるいたちごっこだった（7/27破損→8/5 denylist追加で修正→8/10別キーで
# 再発＝3回実証。旧denylist本体は git log -p 参照）。
# 新: python3標準tomllib（Python 3.12実測確認済み）でlive・テンプレ双方をTOMLと
# して解析し、ドット区切りのキーパス単位で3分類する:
#   (a) 下記の既知アプリ管理キー一覧に一致するキー … 除外（driftにしない。
#       テンプレ記載の有無より優先して判定する＝テンプレにも記載があり
#       installの基底値提供に使うキーでも、アプリ管理キー一覧に載せれば
#       監視から外せる＝2026-08-14 NODE_REPL_TRUSTED_CODE_PATHS対応で優先順位を
#       明確化。将来また未知の新キーが増えても壊れないよう、一覧はベスト
#       エフォートの初期値であり網羅を目指さない設計）
#   (b) (a)に該当せずテンプレに記載のキー … 値差分・欠落を通常どおりdrift計上する
#   (c) どちらでもない未知キー … WARN表示のみ（drift件数には数えない。旧denylist
#       のいたちごっこを構造的に断つための本設計変更の核心＝アプリの新キー
#       追加を検知はするが、それだけでは中断しない）
# TOMLとして解析できない場合（live・テンプレいずれか）は「監視不能」を明示し
# drift計上する（fail-openで偽の健全表示にしない＝既存③GIT-STATUS-CHECK-FAILED・
# ⑤GH-CHECK-FAILEDと同型の設計思想）。
#
# 既知アプリ管理キー一覧（旧denylistの初期リスト化）。テーブルプレフィックス
# （配下の全キーを除外）とリーフキー名（テーブルの深さを問わずキー名一致で
# 除外）の2種類。
KNOWN_APP_MANAGED_TOML_TABLE_PREFIXES=(
  "marketplaces"            # プラグインのキャッシュパス・last_updated。次回起動時にCodexが再スキャンする
  "hooks.state"              # hooks.json の信頼ハッシュキャッシュ（新Macでは初回に一度だけ再確認されるだけ）
  "projects"                 # フォルダごとのtrust_level履歴
  "tui"                      # オンボーディング通知の既読カウンタ等（実質的な設定ではない）
  "shell_environment_policy" # Codex.appがファイル末尾の機械管理領域に自動追記するセクション。ビルド毎に変わるNODE_REPL_TRUSTED_BROWSER_CLIENT_SHA256S等を含む。2026-08-03のアプリ書換で出現・2026-08-05実測確認
)
KNOWN_APP_MANAGED_TOML_LEAF_KEYS=(
  "notify"                                    # Codexアプリがインストール時のパスで自動再設定する。ユーザーがテンプレ上でコメントアウトして無効化していても実ファイルには復活しうる
  "NODE_REPL_TRUSTED_BROWSER_CLIENT_SHA256S"  # Codex.appの内部ビルドに紐づくハッシュ（アップデートのたび変わる）
  "BROWSER_USE_CODEX_APP_VERSION"             # Codex.appのバージョン文字列（アップデートのたび変わる）
  "NODE_REPL_TRUSTED_CODE_PATHS"              # ChatGPT.appが自パス(cua_node/lib/node_modules)を追記する実績あり（2026-08-14実測・本人裁定）。テンプレにも記載があるが下記のとおりアプリ管理判定を優先するため、install時の基底値提供とdrift監視除外を両立できる
)

CONFIG_TOML_LIVE="$HOME/.codex/config.toml"
CONFIG_TOML_TEMPLATE="$DIR/codex/config.toml"
if [ ! -f "$CONFIG_TOML_LIVE" ]; then
  item_drift "[MISSING] $CONFIG_TOML_LIVE が存在しません（未インストール？）"
elif [ ! -f "$CONFIG_TOML_TEMPLATE" ]; then
  item_drift "[MISSING] リポジトリ側テンプレが見つかりません: $CONFIG_TOML_TEMPLATE"
else
  # 実ファイル側の実ホームパスを __AIENV_HOME__ へ逆置換してからテンプレと比較する
  # （置換方向を逆にすることで、sedのメタ文字エスケープを$HOME側だけで気にすればよくなる）。
  # 正規表現メタ文字に加え、sed区切り文字として使っている # 自体もエスケープする
  # （Codexレビュー指摘・Minor：$HOME に # が含まれる環境で sed コマンドが壊れる）。
  escaped_home=$(printf '%s' "$HOME" | sed -e 's/[.[\*^$()+?{}|\\]/\\&/g' -e 's/#/\\#/g')
  LIVE_NORMALIZED_TMP="$(mktemp "${TMPDIR:-/tmp}/check-drift-config-toml-live.XXXXXX" 2>/dev/null || true)"
  if [ -z "$LIVE_NORMALIZED_TMP" ]; then
    item_drift "[TOML-PARSE-FAILED] 検査②用の一時ファイルを作成できませんでした＝監視不能"
  else
    sed "s#${escaped_home}#__AIENV_HOME__#g" "$CONFIG_TOML_LIVE" > "$LIVE_NORMALIZED_TMP"
    table_prefixes_joined="$(printf '%s\x1f' "${KNOWN_APP_MANAGED_TOML_TABLE_PREFIXES[@]}")"
    leaf_keys_joined="$(printf '%s\x1f' "${KNOWN_APP_MANAGED_TOML_LEAF_KEYS[@]}")"
    # sys.argv経由でパスを渡す（Codexレビュー指摘Major横展開＝シェル変数の
    # コード直接埋め込みは値に'が含まれるだけで構文が壊れる。本ファイル
    # ⑥のstarted_at読み取りと同じ流儀）。分類結果はタブ区切り1行1件でstdoutへ
    # 出す（値はrepr()経由なので改行・タブ自体はエスケープされ、この
    # タブ区切りパースを壊さない）。
    TOML_CLASSIFY_OUT="$(python3 -c "
import sys, tomllib

def flatten(d, prefix=''):
    out = {}
    for k, v in d.items():
        path = f'{prefix}.{k}' if prefix else k
        if isinstance(v, dict):
            if v:
                out.update(flatten(v, path))
            else:
                out[path] = v
        else:
            out[path] = v
    return out

def load(path):
    with open(path, 'rb') as f:
        return tomllib.load(f)

table_prefixes = [p for p in sys.argv[3].split(chr(0x1f)) if p]
leaf_keys = set(k for k in sys.argv[4].split(chr(0x1f)) if k)

def is_app_managed(key):
    # 注意: このコメント文中ではバッククォート・二重引用符のどちらも一切
    # 使わない（bashのpython3 -c ...二重引用符文字列の内側にあるため、
    # どちらの文字も本来閉じるべき境界の途中に現れるとbashの構文解釈が
    # 壊れる＝本ファイル自身の他所のコメントで既知の落とし穴として明記
    # 済み。実測でこのdocstring執筆時にも同種のバグ＝バッククォートの
    # 混入を一度踏んで気付いた。Codex一次レビュー2周目指摘Minor対応で
    # 二重引用符も除去）。
    #
    # leaf_keys側はテーブルの深さを問わずキー名一致で判定する（旧denylistの
    # MACHINE_MANAGED_TOML_KEY_PATTERNSが行頭正規表現でセクションを問わず
    # マッチしていたのと同じ挙動をあえて踏襲＝回帰ではない）。既知の限界
    # （2026-08-10時点で解消せず受容）: このためtable_prefixes配下ではない
    # 無関係なテーブルに偶然notifyやNODE_REPL_TRUSTED_BROWSER_CLIENT_SHA256S
    # 等と同名のキーがあっても誤って除外されうる。また table_prefixes側は
    # ドット連結文字列の前方一致のため、TOML仕様上有効な引用ドットキー
    # （例: projects.foo という文字列そのものを1個のキー名とする書き方）が
    # テーブル[projects.foo]配下のキーと文字列表現上区別できない。実運用
    # では~/.codex/config.tomlはCodexアプリの生成物のみを対象にしており、
    # これらの構造は実際には出現しない（2026-08-10時点で実測確認済み）
    # ため、個人用drift検知ツールとしては過剰実装と判断し見送る（③の
    # diff -B同様の既存の受容パターン）。
    leaf = key.rsplit('.', 1)[-1]
    if leaf in leaf_keys:
        return True
    return any(key == p or key.startswith(p + '.') for p in table_prefixes)

try:
    live = flatten(load(sys.argv[1]))
except Exception as e:
    print(f'PARSE_FAILED\tlive\t{type(e).__name__}: {e}')
    sys.exit(0)

try:
    template = flatten(load(sys.argv[2]))
except Exception as e:
    print(f'PARSE_FAILED\ttemplate\t{type(e).__name__}: {e}')
    sys.exit(0)

for key in sorted(set(live) | set(template)):
    # is_app_managed()をテンプレ記載判定より先に評価する（2026-08-14 本人裁定
    # 対応。従来はテンプレ記載キーが常にis_app_managed判定より優先されており、
    # アプリ管理キー一覧に加えるだけではテンプレにも記載のあるキー
    # （NODE_REPL_TRUSTED_CODE_PATHS）を除外できなかった。テンプレ記載キーでも
    # アプリ管理リストが優先されることで、installが書き込む基底値の提供
    # （テンプレ自体は変更しない）とdrift監視からの除外を両立する）。
    if is_app_managed(key):
        continue
    if key in template:
        if key not in live:
            print(f'DRIFT\tMISSING-KEY\t{key}\t{template[key]!r}')
        elif live[key] != template[key]:
            print(f'DRIFT\tDIFF\t{key}\t{template[key]!r}\t{live[key]!r}')
    else:
        print(f'WARN\t{key}\t{live[key]!r}')
" "$LIVE_NORMALIZED_TMP" "$CONFIG_TOML_TEMPLATE" "$table_prefixes_joined" "$leaf_keys_joined" 2>&1)"
    TOML_CLASSIFY_RC=$?
    rm -f "$LIVE_NORMALIZED_TMP"
    if [ "$TOML_CLASSIFY_RC" -ne 0 ]; then
      item_drift "[TOML-PARSE-FAILED] 検査②の実行自体に失敗しました（python3 exit=${TOML_CLASSIFY_RC}）＝監視不能。詳細: ${TOML_CLASSIFY_OUT}"
    else
      drift_before=$TOTAL_DRIFT
      warn_count=0
      while IFS=$'\t' read -r kind a b c d; do
        [ -z "$kind" ] && continue
        case "$kind" in
          PARSE_FAILED)
            case "$a" in
              live) parse_failed_path="$CONFIG_TOML_LIVE" ;;
              template) parse_failed_path="$CONFIG_TOML_TEMPLATE" ;;
              *) parse_failed_path="(${a})" ;;
            esac
            item_drift "[TOML-PARSE-FAILED] ${parse_failed_path} をTOMLとして解析できませんでした（${b}）＝監視不能"
            ;;
          DRIFT)
            case "$a" in
              MISSING-KEY)
                item_drift "[MISSING-KEY] キー '${b}' が ${CONFIG_TOML_LIVE} にありません（テンプレ値: ${c}）"
                ;;
              DIFF)
                item_drift "[DIFF] キー '${b}' の値がテンプレと異なります（テンプレ: ${c} / 実ファイル: ${d}）"
                ;;
            esac
            ;;
          WARN)
            warn_count=$((warn_count + 1))
            UNKNOWN_CONFIG_KEYS=$((UNKNOWN_CONFIG_KEYS + 1))
            log "  -> ⚠️ WARN: 未知キー '${a}'（値: ${b}）はテンプレにも既知アプリ管理キー一覧にもありません。アプリ更新等で追加された可能性・driftには数えません"
            ;;
        esac
      done <<EOF
$TOML_CLASSIFY_OUT
EOF
      if [ "$TOTAL_DRIFT" -eq "$drift_before" ]; then
        log "  -> ✅ TOML三分類で一致しています（テンプレ記載キーはすべて一致・既知アプリ管理キー/未知キー${warn_count}件は除外）"
      fi
    fi
  fi
fi

echo
echo "======================================================================"
echo "③ repo（このリポジトリ）に未commitの変更が無いか"
echo "======================================================================"

if [ -d "$DIR/.git" ]; then
  # `|| true` でコマンド失敗を握りつぶすと、git自体が壊れて実行できない場合も
  # 「出力が空＝差分なし＝健全」に混同してしまう（2026-07-14 リーダー指摘。
  # ⑤のGH-CHECK-FAILED・⑦のVAULT-PUSH-CHECK-FAILEDと同じ「監視不能も異常」の
  # 原則に反していた）。exit codeでコマンド失敗と「差分ゼロ件で正常終了」を
  # 区別する。
  if git_status="$(git -C "$DIR" status --porcelain 2>&1)"; then
    if [ -z "$git_status" ]; then
      log "  -> ✅ 未commitの変更はありません"
    else
      n=$(printf '%s\n' "$git_status" | grep -c . || true)
      item_drift "[UNCOMMITTED] 未commitの変更が ${n} 件あります"
      printf '%s\n' "$git_status" | sed 's/^/    /'
    fi
  else
    item_drift "[GIT-STATUS-CHECK-FAILED] git -C ${DIR} status --porcelain の実行に失敗しました（リポジトリ破損等の可能性）＝未commitの変更の有無を判定できません。確認: git -C ${DIR} status"
    printf '%s\n' "$git_status" | sed 's/^/    /'
  fi
else
  log "  -> リポジトリがまだ git 管理下にありません（.git が無い）。チェック対象外"
fi

echo
echo "======================================================================"
echo "④ vault-public/Preferences と実Vaultの Preferences の差分（エクスポート漏れ検知）"
echo "======================================================================"

VP_PREFS="$DIR/vault-public/Preferences"
VAULT_PREFS="$VAULT/Preferences"
if [ ! -d "$VP_PREFS" ]; then
  item4_drift "[MISSING] $VP_PREFS が見つかりません（export-public-vault.sh 未実行？）"
elif [ ! -d "$VAULT_PREFS" ]; then
  log "  -> 実Vaultの Preferences が見つかりません（${VAULT_PREFS}）。このマシンに私的パッチが無い（サブ機）想定ならチェック対象外"
else
  # `diff -rq` の exit code: 0=差分なし／1=差分あり／2=読み取り不能等のエラー。
  # 旧実装は `|| true` で握りつぶしていたため、2（エラー）も1（差分あり）も
  # 出力が空なら「差分なし＝健全」に混同し得た（2026-07-14 リーダー指摘。
  # 「監視不能も異常」の原則に反していた）。exit codeで3者を区別する。
  diff_out="$(diff -rq "$VAULT_PREFS" "$VP_PREFS" 2>&1)"
  diff_rc=$?
  if [ "$diff_rc" -eq 0 ]; then
    log "  -> ✅ 差分なし（vault-public/Preferences は実Vaultの最新を反映しています）"
  elif [ "$diff_rc" -eq 1 ]; then
    n=$(printf '%s\n' "$diff_out" | grep -c . || true)
    item4_drift "[DIFF] 実Vault と vault-public/Preferences に差分が ${n} 件あります（export-public-vault.sh の再実行が必要な可能性）"
    printf '%s\n' "$diff_out" | sed 's/^/    /'
  else
    # DIFF-CHECK-FAILEDは「④の内容差分」ではなく「④の検査自体が実行できない」
    # という実行異常であり、改訂v2 §1.2は「④の差分は除外するが実行異常は
    # exit code契約の対象」と明記している（2026-07-16 Codexレビュー指摘Major
    # 対応: 当初item4_drift()にしていたため、diff -rqが失敗するだけで
    # drift_excluding_item4>0のexit code契約をすり抜けられてしまっていた
    # ＝本スクリプト自身の「監視不能も異常」という方針とも矛盾していた）。
    # 通常のitem_drift()（drift_excluding_item4に算入される）を使う。
    item_drift "[DIFF-CHECK-FAILED] diff -rq ${VAULT_PREFS} ${VP_PREFS} の実行に失敗しました（exit ${diff_rc}。ファイル読み取り不能等の可能性）＝差分の有無を判定できません。確認: diff -rq ${VAULT_PREFS} ${VP_PREFS}"
    printf '%s\n' "$diff_out" | sed 's/^/    /'
  fi
fi

echo
echo "======================================================================"
echo "⑤ private であるべき remote の可視性検証"
echo "======================================================================"

# github.com の remote URL（scp風/ssh/https の主要な記法。認証情報付きHTTPS・
# ポート443経由のssh.github.com・末尾スラッシュも含む）から owner/repo を取り出す。
# github.com 以外（gitlab等）は呼び出し側で「対象外」として扱う。GitHubらしき
# URLなのに解析できなかった場合は呼び出し側で区別して警告する（Codexレビュー指摘・
# Major：解析できないURLを黙って「対象外」にすると、実際はGitHub上のprivate repoが
# public化されていても気付けないまま安全網が抜けてしまう）。
parse_github_owner_repo() {
  local url="$1" rest=""
  # 末尾スラッシュ・.git拡張子を先に正規化する。
  url="${url%/}"
  url="${url%.git}"

  case "$url" in
    git@github.com:*)
      rest="${url#git@github.com:}"
      ;;
    ssh://git@github.com/*)
      rest="${url#ssh://git@github.com/}"
      ;;
    ssh://git@ssh.github.com:*/*)
      # ポート443経由のSSH（ファイアウォールでポート22が塞がれている環境向けの
      # GitHub公式代替記法）: ssh://git@ssh.github.com:443/owner/repo
      rest="${url#ssh://git@ssh.github.com:}"
      rest="${rest#*/}"
      ;;
    https://github.com/*|http://github.com/*)
      rest="${url#*github.com/}"
      ;;
    https://*@github.com/*|http://*@github.com/*)
      # 認証情報付きHTTPS: https://user[:token]@github.com/owner/repo
      rest="${url#*@github.com/}"
      ;;
    *)
      return 1
      ;;
  esac

  case "$rest" in
    */*)
      printf '%s' "$rest"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# remote URL をログ表示用にマスクする（`https://user:token@host/...` のような
# 認証情報付きURLの `user:token@` 部分を `<redacted>@` に置換する）。
# 絶対厳守ルール③「認証情報・シークレットを露出しない」への対応
# （Codexレビュー指摘・Major：解析できなかったURLをそのままログ/LaunchAgentログへ
# 出力すると、埋め込まれたトークンが露出しうる）。認証情報を含まないURL（scp風
# git@host:path等）はそのまま返す。
redact_remote_url() {
  printf '%s' "$1" | sed -E 's#://[^/@[:space:]]*@#://<redacted>@#'
}

# gh の可用性は1回だけ判定する（ループ内で毎回 command -v するのは無駄なため）。
GH_AVAILABLE=0
if command -v gh >/dev/null 2>&1; then
  GH_AVAILABLE=1
fi

# 検証対象: 「ラベル|ローカルclone先パス」の組。ai-env 本体（$DIR）は
# 「public化予定」のため意図的に対象外（設計どおり）。
VISIBILITY_TARGETS=(
  "Vaultバックアップ|${VAULT}"
  "私的パッチrepo|${AIENV_PRIVATE_REPO}"
)

for pair in "${VISIBILITY_TARGETS[@]}"; do
  vlabel="${pair%%|*}"
  vpath="${pair#*|}"

  if [ ! -d "${vpath}/.git" ]; then
    log "  -> ${vlabel}: ローカルにgitリポジトリが無いためチェック対象外（${vpath}）"
    continue
  fi

  vremote="$(git -C "${vpath}" remote get-url origin 2>/dev/null || true)"
  if [ -z "${vremote}" ]; then
    log "  -> ${vlabel}: remote 'origin' が未設定のためチェック対象外（${vpath}）"
    continue
  fi

  vowner_repo="$(parse_github_owner_repo "${vremote}" || true)"
  if [ -z "${vowner_repo}" ]; then
    vremote_redacted="$(redact_remote_url "${vremote}")"
    case "${vremote}" in
      *github.com*)
        # GitHubらしきURLだが対応外の記法で解析できなかった。安全網が黙って
        # 抜けないよう、非GitHubの場合とは別メッセージで目立たせる（drift扱いには
        # しない＝解析できないだけでpublic化されたと断定はできないため）。
        echo "  [GH-URL-UNPARSEABLE] ${vlabel}: remote URLを解析できませんでした（GitHubらしき形式ですが対応外の記法の可能性。手動で 'gh repo view' 等で可視性を確認してください）: ${vremote_redacted}"
        ;;
      *)
        log "  -> ${vlabel}: GitHub以外のremoteのため可視性チェック対象外（${vremote_redacted}）"
        ;;
    esac
    continue
  fi

  if [ "${GH_AVAILABLE}" != "1" ]; then
    echo "  [GH-UNAVAILABLE] ${vlabel} (${vowner_repo}) の可視性を確認できません（gh コマンドが見つかりません。brew install gh でインストールしてください）"
    continue
  fi

  vvisibility="$(gh repo view "${vowner_repo}" --json visibility -q .visibility 2>/dev/null || true)"
  if [ -z "${vvisibility}" ]; then
    # gh は存在するのに可視性を取得できない＝監視そのものが機能していない状態。
    # 従来はWARN表示のみでdrift件数に乗らず、private誤公開検知の安全網が無効化
    # していても週次通知で気付けない穴があった（2026-07-13 外部脳round4対応・
    # 「監視不能も異常」）。
    item_drift "[GH-CHECK-FAILED] ${vlabel} (${vowner_repo}) の可視性を取得できませんでした（gh 未認証・権限不足・ネットワーク不通の可能性。'gh auth status' を確認してください）"
    continue
  fi

  if [ "${vvisibility}" = "PRIVATE" ]; then
    log "  -> ${vlabel} (${vowner_repo}): ✅ PRIVATE です"
  else
    item_drift "[VISIBILITY] ${vlabel} (${vowner_repo}) は private ではありません（現在: ${vvisibility}）。至急 'gh repo edit ${vowner_repo} --visibility private' 等で非公開化し、公開範囲に機密情報が既に露出していないか確認してください（Preferences/absolute-rules.md ③に関わる重大インシデントの可能性）"
  fi
done

echo
echo "======================================================================"
echo "⑥ vault-agents 死活チェック（maintenance.sh週次ランナー・weekly-review・reads/recallログ）"
echo "======================================================================"

# maintenance.sh（週次ランナー・com.takumi009.maintenance）と、
# vault-recall.sh/vault-read-log.sh（UserPromptSubmit/PostToolUseフック）が
# 「動いているはずなのに実は死んでいる」を検知する。ここは既存の週次drift
# 通知に相乗りさせ、見に行かなくても通知される経路にする。
: "${VAULT_AGENT_LOG_STALE_DAYS:=7}"
: "${VAULT_READS_LOG:=$HOME/.claude/logs/vault-reads.tsv}"
: "${VAULT_RECALL_LOG:=$HOME/.claude/logs/vault-recall.tsv}"
# maintenance.sh（週次ランナー）の死活判定に使うlast-run.json（scripts/
# maintenance.shが実行開始直後にstarted_atを無条件更新する自己ロックアウト
# 対策ファイル）。既定値はmaintenance.sh自身のLAST_RUN_FILE既定値と同一
# （2026-07-16簡素化・設計書§4「maintenance新鮮度チェック（started_atの
# 経過日数のみで判定）」・リーダー裁定2026-07-16）。
: "${MAINTENANCE_LAST_RUN_FILE:=$HOME/.claude/logs/maintenance/last-run.json}"
: "${MAINTENANCE_STALE_DAYS:=8}"    # 週次(目安7日) + 猶予1日（リーダー裁定2026-07-16の明示値）
# weekly-review（「今週の歩み」週次振り返りcanvas・takumi009-ai-env-private/
# tools/weekly-review/weekly_review.py。LaunchAgent com.takumi009.weekly-review が
# 毎週月曜04:00に無人実行。2026-07-14追加＝外部脳監視・バックアップ機構総点検で
# 「本ツールにweekly-reviewへの言及が無く監視対象外だった」欠陥への対応）の
# 出力先。private repo側のスクリプトと同じ既定値。
: "${WEEKLY_REVIEW_DIR:=$VAULT/Explorations/weekly-review}"
: "${WEEKLY_REVIEW_STALE_DAYS:=10}"      # 週次(目安7日) + 猶予（fragments-logと同型）

# maintenance.shは README.md にも明記の「メイン専用」機能で、
# vault-reads.tsv/vault-recall.tsv を書くフック（vault-recall.sh/vault-read-log.sh。
# install-main.shで標準導入）とは導入の必須性が異なる（Codexレビュー
# 指摘・Major: reads/recallログだけが存在する状態＝任意機能は未導入だが標準フックは
# 動いている、というごく普通の main機構成で、下のvault_agents_untouchedだけで
# ゲートするとDEADが恒常的に誤報され続けてしまう。旧vault-inventory/
# fragments-log/knowledge-merge-detect時代からの設計方針をそのまま踏襲）。
# LaunchAgent plist（$HOME/Library/LaunchAgents/com.takumi009.<name>.plist）の
# 実在をもって「この機能を導入したか」を個別に判定し、未導入なら新鮮度チェック
# そのものをスキップする（reads/recallログの死活判定には影響しない＝
# 未導入で標準フックの死活検知まで消してしまわないため）。
: "${LAUNCH_AGENTS_DIR:=$HOME/Library/LaunchAgents}"
vault_agent_installed() {
  [ -f "${LAUNCH_AGENTS_DIR}/com.takumi009.$1.plist" ]
}

# vault-agents関連のシグナル（reads/recallログ2種＋maintenance/weekly-reviewの
# LaunchAgent plist2種＋maintenanceのlast-run.json＝計5種）が1つも無ければ
# 「一度も導入されていない」とみなしてセクション全体を対象外にする（旧実装は
# vault-inventory/fragments-log/knowledge-merge-detectの出力ディレクトリ有無も
# シグナルに含んでいたが、これら3スクリプトはmaintenance.sh Phase1から呼ばれる
# 検出専用CLIへ縮小し個別LaunchAgentを持たなくなったため、判定基準を
# maintenance側の signal へ差し替えた＝2026-07-16簡素化・リーダー裁定対応）。
# plistもシグナルに含める（Codexレビュー指摘・Major再指摘: 出力の有無だけで
# 判定すると「plistは導入済みだが初回実行前・またはジョブが一度も成功していない」
# ケースが出力側の不在と見分けられず、セクション全体が対象外になって本来出るべき
# DEADが出せなくなる）。
vault_agents_untouched=1
[ -f "$MAINTENANCE_LAST_RUN_FILE" ] && vault_agents_untouched=0
# WEEKLY_REVIEW_DIR は $VAULT 配下（Vault自体は複数マシン間でgit同期される）を
# 意図的に signal から除外している（Codexレビュー指摘・Major対応: 他の出力先
# （$HOME/.claude/logs/... 配下）はローカル専用でマシン間同期されないが、
# canvas出力だけはVault経由で同期されるため、reads/recallフックもweekly-review
# LaunchAgentも一切導入していないサブ機が、単に「他マシンが生成したcanvasを
# Vault同期で受け取っているだけ」でuntouched=0と誤判定され、reads/recallの
# DEADが誤報される穴があった。ローカル導入の判定はweekly-review plist（下記）
# だけで行う）。
[ -f "$VAULT_READS_LOG" ] && vault_agents_untouched=0
[ -f "$VAULT_RECALL_LOG" ] && vault_agents_untouched=0
vault_agent_installed "maintenance" && vault_agents_untouched=0
vault_agent_installed "weekly-review" && vault_agents_untouched=0

if [ ! -d "$VAULT" ]; then
  log "  -> Vaultが見つかりません（${VAULT}）。このマシンに私的Vaultが無い（サブ機）想定ならチェック対象外"
elif [ "$vault_agents_untouched" = "1" ]; then
  log "  -> vault-agentsの出力（${MAINTENANCE_LAST_RUN_FILE}・${VAULT_READS_LOG}・${VAULT_RECALL_LOG}）・maintenance/weekly-review plist（${LAUNCH_AGENTS_DIR}/com.takumi009.{maintenance,weekly-review}.plist）が1件も見つかりません。vault-agentsが一度も導入されていない想定ならチェック対象外"
else
  # epoch(秒)から現在までの経過日数を返す。未来のepoch（時計ズレ・ファイル破損）
  # では負値をそのまま返す＝呼び出し側で「未来日=異常」と判定できるようにする
  # （Codexレビュー指摘・Major: 経過日数の閾値判定は上限（stale）しか見ていないと、
  # 未来日時が「新しすぎるので健全」に誤判定される＝閾値ガードの下限漏れ。
  # Knowledge/fail-open-and-observable-guards §1と同型の欠陥）。
  # $1 は date +%s の出力（数字のみ）が前提。bash 3.2 の算術評価器は
  # `$(コマンド置換) - "$1"` のように command substitution と quoted変数展開が
  # 混在すると誤ってパースする既知の癖があるため（実測確認済み）、$1 はクォート
  # せずに渡す（値は常に数字のみなのでword-splitting等のリスクは無い）。
  #
  # 秒差が負（epochが未来）の場合は、単純な `秒差 / 86400` ではなく絶対値を
  # 切り上げてから符号反転する（Codex二次レビュー指摘・Minor対応: bashの整数
  # 除算は0方向へ丸めるため、24時間未満の未来スキュー（例: -3600秒）が
  # `-3600/86400=0` に丸まってしまい、「未来なのに経過日数0＝健全」に誤判定
  # されてしまっていた。1秒でも未来なら必ず負の日数〈最小-1〉を返すことで、
  # 呼び出し側の `age < 0` によるFUTURE-DATE判定を確実に発火させる。
  # weekly-reviewの新規mtime基準FUTURE-DATE判定にも直接影響するため合わせて修正）。
  age_days_from_epoch() {
    local epoch=$1 diff future_days
    diff=$(( $(date -u +%s) - epoch ))
    if [ "$diff" -lt 0 ]; then
      future_days=$(( (-diff + 86399) / 86400 ))
      echo $(( -future_days ))
    else
      echo $(( diff / 86400 ))
    fi
  }

  # TSVログの最終行1列目(ISO8601・末尾Z)の経過日数を返す（無ければ非0で返す）。
  # ERROR行（vault-recall.sh/vault-read-log.shのlog_error()が書く行）も含めた
  # 「ファイルに何か書かれた最終時刻」＝ログが死んでいるかどうかの一次判定に使う。
  #
  # ログの時刻は vault-recall.sh/vault-read-log.sh が `date -u +...Z` で書く
  # UTC時刻（Codexレビュー指摘・N-5対応前は末尾Zを外しただけで `date -j -f`
  # に渡していたため、実行環境のローカルTZ（例: JST=+9h）として誤って解釈
  # されていた＝2026-07-10 敵対的レビュー2回目 N-5。`TZ=UTC` を明示して
  # パースすることで、UTC時刻をUTCとして正しく経過日数に変換する）。
  log_last_line_age_days() {
    local f="$1" ts epoch
    [ -f "$f" ] || return 1
    ts="$(tail -1 "$f" 2>/dev/null | cut -f1)"
    [ -z "$ts" ] && return 1
    ts="${ts%Z}"
    epoch="$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$ts" +%s 2>/dev/null)" || return 1
    age_days_from_epoch "$epoch"
  }

  # ERROR行以外（3列目=ノート相対パスが空でない行）の最終行の経過日数を返す。
  # vault_inventory.py の read_log() と同じ判定基準（NF>=3 かつ 3列目が空でない）。
  # フックは実行されているがERROR行しか出せていない（例: jq破損で毎回失敗）状態を
  # log_last_line_age_days だけでは「鮮度は健全」と見誤ってしまうため分離する
  # （Codexレビュー指摘・Major: 最終行だけを見ると、ERROR行を出し続ける壊れた
  # フックでも「直近に記録あり＝健全」と誤判定してしまう）。
  # log_last_line_age_days と同様、時刻はUTCとして明示的にパースする
  # （N-5対応。ローカルTZ解釈による±9hのズレを避ける）。
  log_last_valid_line_age_days() {
    local f="$1" ts epoch
    [ -f "$f" ] || return 1
    ts="$(awk -F'\t' 'NF>=3 && $3!="" {t=$1} END{if (t!="") print t}' "$f" 2>/dev/null)"
    [ -z "$ts" ] && return 1
    ts="${ts%Z}"
    epoch="$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$ts" +%s 2>/dev/null)" || return 1
    age_days_from_epoch "$epoch"
  }

  # maintenance.sh週次ランナー1件分の判定をまとめる（2026-07-16簡素化・
  # 設計書§4「maintenance新鮮度チェック（started_atの経過日数のみで判定＝
  # 自己ロックアウト対策）」・リーダー裁定2026-07-16「(a) plist存在＋
  # launchctl登録 (b) last-run.jsonのstarted_at経過日数（週次なので8日超で
  # drift扱い）」への対応。旧vault-inventory/knowledge-merge-detectの個別
  # check_report_freshness()はこの単一チェックへ統合した）。
  #
  # (a) plistの実在＋launchd上のロード状態を確認する。plist自体はこの関数の
  #     呼び出し元でvault_agent_installed()により既に確認済み（未導入なら
  #     この関数自体を呼ばない）なので、ここでは「plistはあるのにlaunchd上に
  #     ロードされていない」ケースのみを追加で検知する。launchctlコマンドが
  #     無い実行環境（macOS以外）では確認そのものをスキップし、情報表示のみ
  #     に留める（drift扱いにはしない＝「監視不能も異常」の原則は、後続の
  #     started_at基準の判定でカバーされるため、launchctl不在自体は致命では
  #     ない）。
  check_maintenance_freshness() {
    local f="$MAINTENANCE_LAST_RUN_FILE" started_at epoch age

    if command -v launchctl >/dev/null 2>&1; then
      if ! launchctl print "gui/$(id -u)/com.takumi009.maintenance" >/dev/null 2>&1; then
        item_drift "[MAINTENANCE-NOT-LOADED] com.takumi009.maintenance.plistは存在しますが、launchd上にロードされていません＝bootstrap未実行か手動でbootoutされた可能性。確認: launchctl print gui/$(id -u)/com.takumi009.maintenance ／ 再導入: scripts/install-maintenance.sh"
      fi
    else
      log "  -> maintenance.sh週次ランナー: launchctlコマンドが見つからないためlaunchd上のロード状態を確認できません（macOS以外の実行環境の可能性）"
    fi

    # (b) last-run.jsonのstarted_at経過日数。
    if [ ! -f "$f" ]; then
      item_drift "[MAINTENANCE-DEAD] last-run.jsonが一度も見つかりません（${f}）＝maintenance.shが一度も実行されていない疑い。確認: launchctl kickstart -k gui/$(id -u)/com.takumi009.maintenance"
      return
    fi

    # last-run.jsonの読み取りはmaintenance.sh自身のread_last_run_field()と
    # 同じpython3 json.load方式（本ツールとしては初のpython3依存だが、
    # maintenance.sh側が既に前提としている依存なので新規追加ではない）。
    # ファイルパスはPythonコード文字列へ直接埋め込まず sys.argv 経由で渡す
    # （Codexレビュー指摘・Major対応: シェル変数のコード直接埋め込みは、
    # パスに ' が含まれるだけで構文が壊れ、細工されたパスでは任意コード実行の
    # 経路になりうる。$MAINTENANCE_LAST_RUN_FILE は環境変数で上書き可能なため
    # 単一ユーザーローカル運用でも防御的に塞ぐ）。
    started_at="$(python3 -c "
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as fh:
        d = json.load(fh)
    v = d.get('started_at')
    print(v if isinstance(v, str) else '')
except Exception:
    print('')
" "$f" 2>/dev/null)"
    if [ -z "$started_at" ]; then
      item_drift "[MAINTENANCE-DEAD] ${f} からstarted_atを読み取れませんでした（壊れているか未生成）＝maintenance.sh停止の疑い。確認: cat ${f}"
      return
    fi

    started_at="${started_at%Z}"
    epoch="$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$started_at" +%s 2>/dev/null)"
    if [ -z "$epoch" ]; then
      item_drift "[MAINTENANCE-DEAD] ${f} のstarted_at（${started_at}）を日時として解析できませんでした＝ファイル破損の可能性。確認: cat ${f}"
      return
    fi

    age="$(age_days_from_epoch "$epoch")"
    if [ "$age" -lt 0 ]; then
      item_drift "[MAINTENANCE-FUTURE-DATE] ${f} のstarted_atが未来です＝ファイル破損かシステム時計のズレの可能性。確認: cat ${f}"
      return
    fi
    if [ "$age" -gt "$MAINTENANCE_STALE_DAYS" ]; then
      item_drift "[MAINTENANCE-STALE] maintenance.shの最終開始（started_at）から ${age} 日経過（目安 ${MAINTENANCE_STALE_DAYS} 日）＝週次ランナー停止の疑い。確認: launchctl print gui/$(id -u)/com.takumi009.maintenance ／ $HOME/.claude/logs/maintenance/latest 配下のログ"
    else
      log "  -> ✅ maintenance.sh週次ランナー: 最終開始 ${age}日前（目安${MAINTENANCE_STALE_DAYS}日以内）"
    fi
  }

  # $VAULT/Fragments 配下（weekly_review.pyのcollect()と同じ
  # `(VAULT/"Fragments").rglob("20*.md")`探索）に、$1(epoch秒)以降の日付の
  # Fragmentsファイルが1件でもあるかを調べる（2026-07-14 リーダー指摘対応・
  # 設計情報反映: weekly_review.pyは対象週にFragments記録が1件も無ければ
  # 「skip: ... に Fragments 記録なし」として意図的にcanvasを生成しない仕様。
  # 単純なmtime新鮮度チェックだけだと、この正常なskip（材料が無いだけ）と
  # 実際の生成失敗〈LaunchAgent停止等〉を区別できず、①素材が無いだけの静かな週を
  # STALE誤報する ②逆に本当に壊れているのに「そのうち動くはず」と静観してしまう、
  # という二重の死角があった。Fragmentsの実在で「生成すべき材料があったのに
  # 生成されなかったか」を判別する）。
  # 戻り値: 0=記録あり（本物の異常の疑い）／1=記録なし（正常なskipの可能性）／
  # 2=探索自体に失敗し判定不能（Codex三次レビュー指摘・Major対応: `find`が
  # 権限不備等で失敗しても従来は出力ゼロ件＝「記録なし」と誤って同一視しており、
  # 「監視不能も異常」の原則に反していた。呼び出し側で3値を区別する）。
  weekly_review_fragments_exist_since() {
    local since_epoch="$1" fdir="$VAULT/Fragments"
    local since_date_str since_midnight_epoch find_out rc f base d_epoch found=1
    [ -d "$fdir" ] || return 1
    # 比較粒度をどちらも「日付」に揃える（Codex三次レビュー指摘・Major対応:
    # Fragmentsのファイル名日付はローカル日付の0時としてepoch化される一方、
    # 比較対象のsince_epoch（canvasの実mtime）は時刻成分を含むため、そのまま
    # 比較すると「canvas生成と同じ日に書かれたFragment」が誤ってcanvasより古い
    # 扱いになり、以後Fragmentが増えなければSTALEを永久に抑止しうる欠陥があった。
    # since_epochをローカル日付の0時へ正規化し、`>=`で比較する）。
    since_date_str="$(date -j -f "%s" "$since_epoch" +%Y-%m-%d 2>/dev/null)" || return 1
    since_midnight_epoch="$(date -j -f "%Y-%m-%d" "$since_date_str" +%s 2>/dev/null)" || return 1
    find_out="$(find "$fdir" -name '20*.md' -type f 2>&1)"
    rc=$?
    [ "$rc" -eq 0 ] || return 2
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      base="$(basename "$f" .md)"
      d_epoch="$(date -j -f "%Y-%m-%d" "$base" +%s 2>/dev/null)" || continue
      if [ "$d_epoch" -ge "$since_midnight_epoch" ]; then
        found=0
        break
      fi
    done <<EOF
$find_out
EOF
    return "$found"
  }

  # weekly-review（週次振り返りcanvas）1件分の新鮮度判定。$1=ディレクトリ $2=しきい値(日)
  #
  # check_maintenance_freshness()（started_at＝実行開始日時基準）とは判定方式を
  # 変えている。weekly_review.pyの出力ファイル名は「生成日」ではなく
  # 「対象週（直前の完全な週）の月曜日」＝生成日の7日前固定になるため、ファイル名
  # ベースで判定すると生成直後でも常にage=7からスタートしてしまい、started_at
  # 基準と同じしきい値運用ができない（オフセットの分だけしきい値を余分に緩める
  # 必要が生じ、STALE等の他チェックと閾値の意味が揃わなくなる）。かわりに
  # 最新ファイルの実際の更新時刻(mtime)を基準にする＝生成直後はage=0、次回生成
  # （1週間後）直前でage=7弱まで自然に増える、という設計にすることで、しきい値も
  # 他チェックと同じ考え方（週次+猶予）を流用できる。
  check_weekly_review_freshness() {
    local dir="$1" threshold="$2" latest epoch age frag_rc
    latest="$(ls -t "$dir"/20*.canvas 2>/dev/null | head -1)"
    if [ -z "$latest" ]; then
      # 一度もcanvasが無い＝LaunchAgent停止の疑いだが、Fragments自体が一度も
      # 記録されていないなら「材料が無いのでweekly_review.py側の仕様どおり
      # 生成されていないだけ」の可能性がある。Fragmentsの実在有無で区別する。
      weekly_review_fragments_exist_since 0
      frag_rc=$?
      case "$frag_rc" in
        0)
          item_drift "[WEEKLY-REVIEW-DEAD] 週次振り返りcanvasが一度も見つかりません（${dir}）が、Fragments記録は存在します＝com.takumi009.weekly-review LaunchAgent停止の疑い。確認: launchctl list | grep weekly-review"
          ;;
        2)
          item_drift "[WEEKLY-REVIEW-FRAGMENTS-CHECK-FAILED] ${VAULT}/Fragments の探索に失敗しました（権限不備等の可能性）＝週次振り返りcanvas未生成が正常なskipか実際の生成失敗か判定できません。確認: ls -la ${VAULT}/Fragments"
          ;;
        *)
          log "  -> 週次振り返りcanvasが一度も見つかりません（${dir}）が、Fragments記録も一度も無いため、weekly_review.pyの仕様（対象週にFragments記録が無ければ生成しない）による正常な未生成の可能性があります。継続してFragmentsが記録されないままなら次回以降も同様です。"
          ;;
      esac
      return
    fi
    epoch="$(stat -f %m "$latest" 2>/dev/null)"
    if [ -z "$epoch" ]; then
      item_drift "[WEEKLY-REVIEW-DEAD] ${latest} の更新時刻を取得できませんでした（ファイル破損等の可能性）。確認: ls -la ${dir}"
      return
    fi
    age="$(age_days_from_epoch "$epoch")"
    if [ "$age" -lt 0 ]; then
      item_drift "[WEEKLY-REVIEW-FUTURE-DATE] ${latest} の更新時刻が未来です＝システム時計のズレの可能性。確認: ls -la ${dir}"
      return
    fi
    if [ "$age" -gt "$threshold" ]; then
      # 最新canvasの生成以降にFragments記録があるのに新しいcanvasが出ていない
      # なら「生成すべき材料はあったのに生成されなかった」＝実際の生成失敗の
      # 疑いが強い。Fragments記録自体が無いなら、weekly_review.py仕様どおりの
      # 正常なskipが続いているだけの可能性があるため、drift扱いにはせず
      # 情報表示に留める（誤報でこの監視自体の信頼性を落とさないため）。
      weekly_review_fragments_exist_since "$epoch"
      frag_rc=$?
      case "$frag_rc" in
        0)
          item_drift "[WEEKLY-REVIEW-STALE] 最新の週次振り返りcanvas（$(basename "$latest")）の更新から ${age} 日経過（目安 ${threshold} 日）＝この間にFragments記録があるのに生成されていません。com.takumi009.weekly-review LaunchAgent停止の疑い。確認: launchctl list | grep weekly-review"
          ;;
        2)
          item_drift "[WEEKLY-REVIEW-FRAGMENTS-CHECK-FAILED] ${VAULT}/Fragments の探索に失敗しました（権限不備等の可能性）＝最新の週次振り返りcanvasが${age}日前のままなのが正常なskipか実際の生成失敗か判定できません。確認: ls -la ${VAULT}/Fragments"
          ;;
        *)
          log "  -> 週次振り返りcanvasの更新から${age}日経過していますが（目安${threshold}日）、この間Fragments記録が無いため、weekly_review.pyの仕様（対象週にFragments記録が無ければ生成しない）による正常な未生成の可能性があります。Fragments記録があるのに生成されない場合のみ異常として検知します。"
          ;;
      esac
    else
      log "  -> ✅ 週次振り返りcanvas: 更新${age}日前（目安${threshold}日以内）"
    fi
  }

  # ログ系（vault-reads.tsv・vault-recall.tsv）1件分の判定をまとめる。
  #   $1=ログパス $2=ラベル $3=しきい値(日) $4=表示名 $5=フックパス $6=補足（recallのみ「ヒット0件」注記）
  check_log_freshness() {
    local f="$1" label="$2" threshold="$3" name="$4" hook="$5" extra_hint="${6:-}" age valid_age
    if ! age="$(log_last_line_age_days "$f")"; then
      item_drift "[${label}-DEAD] ${name} が無い、または記録が一度もありません（${f}）＝${hook} フック停止の疑い${extra_hint}。確認: tail -1 ${f}"
      return
    fi
    if [ "$age" -lt 0 ]; then
      item_drift "[${label}-FUTURE-DATE] ${name} の最終記録が未来日時です（${f}）＝ファイル破損かシステム時計のズレの可能性。確認: tail -5 ${f}"
      return
    fi
    if [ "$age" -gt "$threshold" ]; then
      # 最終行(ERROR含む)自体が古い＝STALE。有効行がそれより新しいことは
      # log_last_line_age_days の定義上起きない（有効行もrows全体の一部）ため、
      # ここでは素直にSTALEとして報告する。
      item_drift "[${label}-STALE] ${name} の最終記録が ${age} 日前（目安 ${threshold} 日）＝${hook} フック停止の疑い${extra_hint}。確認: tail -1 ${f}"
      return
    fi
    # 最終行(ERROR含む)は新しいが、有効な行（ERROR以外）が無い/古い＝動いてはいるが
    # 失敗し続けている疑い。staleとは別種の異常として報告する（無言のfail-open防止）。
    if valid_age="$(log_last_valid_line_age_days "$f")"; then
      # 有効行はあるが、その時刻だけが未来（例: 一時的に未来日時の有効行が書かれ、
      # 直後に現在日時のERROR行が追記された）ケースも「新しすぎるので健全」に
      # 誤判定しない（Codexレビュー指摘・Major回帰: 最終行(age)側のFUTURE-DATE
      # チェックだけでは valid_age 側の未来日時を見逃す）。
      if [ "$valid_age" -lt 0 ]; then
        item_drift "[${label}-FUTURE-DATE] ${name} の有効な記録の日時が未来です（${f}）＝ファイル破損かシステム時計のズレの可能性。確認: tail -5 ${f}"
        return
      fi
    fi
    if [ -z "${valid_age:-}" ] || [ "$valid_age" -gt "$threshold" ]; then
      item_drift "[${label}-ERRORING] ${name} は最近書き込まれていますが、有効な記録（ERROR行以外）が無い/古い状態です＝${hook} は実行されているが失敗し続けている疑い。確認: tail -5 ${f}"
      return
    fi
    log "  -> ✅ ${name}: 最終記録 ${age}日前"
  }

  # 未処理レポート検知（旧check_report_processed）・未解決ALERT監視
  # （旧count_unresolved_alerts）は撤去した（2026-07-16簡素化・
  # [[Decisions/2026-07-16-nightly-batch-direct-write]]で「レポート→リーダー処理」の
  # 間接ループとALERT機構（knowledge_merge.py由来。同スクリプトは撤去済み）を廃止。
  # 旧実装を読みたい場合は `git log -p scripts/check-drift.sh` を参照）。
  # 旧vault-inventory/knowledge-merge-detectの個別DEAD/FUTURE-DATE/STALE検知は
  # check_maintenance_freshness()（started_at基準）へ統合した
  # （設計書§4・リーダー裁定2026-07-16）。

  if vault_agent_installed "maintenance"; then
    check_maintenance_freshness
  else
    log "  -> maintenance.sh週次ランナー: 未導入（${LAUNCH_AGENTS_DIR}/com.takumi009.maintenance.plist が無い。scripts/install-maintenance.sh 未実行）のためチェック対象外"
  fi
  if vault_agent_installed "weekly-review"; then
    check_weekly_review_freshness "$WEEKLY_REVIEW_DIR" "$WEEKLY_REVIEW_STALE_DAYS"
  else
    log "  -> 週次振り返りcanvas: 任意機能未導入（${LAUNCH_AGENTS_DIR}/com.takumi009.weekly-review.plist が無い。takumi009-ai-env-private/install-private.sh --with-launchagents 未実行。メイン専用の個人ツール）のためチェック対象外"
  fi
  check_log_freshness "$VAULT_READS_LOG" "VAULT-READS-LOG" "$VAULT_AGENT_LOG_STALE_DAYS" \
    "vault-reads.tsv" "claude/hooks/vault-read-log.sh"
  check_log_freshness "$VAULT_RECALL_LOG" "VAULT-RECALL-LOG" "$VAULT_AGENT_LOG_STALE_DAYS" \
    "vault-recall.tsv" "claude/hooks/vault-recall.sh" \
    "、またはヒット0件の日々が続いている可能性（ヒット時のみ記録する仕様のため区別できません）"
fi

echo
echo "======================================================================"
echo "⑦ Vaultバックアップの push 死活（main と origin/main の乖離）"
echo "======================================================================"

# しきい値・対象ブランチ名は環境変数で上書き可（ユニットテスト用。本番は既定値
# のままでよい。VaultはREADME.md記載の運用どおり main ブランチを使う想定）。
: "${VAULT_BACKUP_PUSH_STALE_HOURS:=24}"
: "${VAULT_BACKUP_BRANCH:=main}"

if [ ! -d "$VAULT/.git" ]; then
  log "  -> Vaultがgit管理下にありません（${VAULT}）。このマシンに私的Vaultが無い（サブ機）想定ならチェック対象外"
elif ! git -C "$VAULT" remote get-url origin >/dev/null 2>&1; then
  log "  -> remote 'origin' が未設定のためチェック対象外（${VAULT}）"
elif ! git -C "$VAULT" rev-parse --verify "${VAULT_BACKUP_BRANCH}" >/dev/null 2>&1; then
  # ローカルブランチ自体が無い（Vaultにまだ1つもcommitが無い等）＝判定材料が
  # そもそも無い。drift にはせずfail-openで明示表示する。
  echo "  [VAULT-PUSH-CHECK-UNAVAILABLE] ローカルブランチ '${VAULT_BACKUP_BRANCH}' が見つかりません（Vaultにまだ1つもcommitが無い等の可能性。判定不能のためfail-open。確認: git -C ${VAULT} branch -a）"
else
  # 「push未反映のcommit」を rev-list の二点範囲(A..B)で厳密に求める（Codexレビュー
  # 指摘・Major対応: 従来は local/origin のSHAが一致するかしか見ておらず、
  # ローカルがorigin/mainより単に古い（＝reset等で巻き戻った）場合まで
  # 「未反映commitあり」と誤検知しうる欠陥があった。rev-listなら
  # 「originに無くlocalにあるcommit」だけを厳密に数えられ、逆方向の乖離は
  # 自然に0件になる）。
  if git -C "$VAULT" rev-parse --verify "origin/${VAULT_BACKUP_BRANCH}" >/dev/null 2>&1; then
    unpushed_range="origin/${VAULT_BACKUP_BRANCH}..${VAULT_BACKUP_BRANCH}"
    never_pushed=0
  else
    # origin/<branch> 参照自体が無い＝このマシンから一度も成功pushしていない
    # （ブランチ自体はある）。従来はここをfail-open即終了にしていたが、初回pushが
    # 認証不良等でずっと失敗し続けている最も危険なケースが永久に検知されない穴が
    # あった（Codexレビュー指摘・Major対応）。「全commitが未反映」とみなし、
    # 以下の経過時間判定にそのまま合流させる（=既存のSTALE猶予がそのまま
    # 初回セットアップ直後の猶予にもなる）。
    unpushed_range="${VAULT_BACKUP_BRANCH}"
    never_pushed=1
  fi

  # rev-list自体の失敗（Vaultのgitオブジェクト破損等）と「未反映commitが0件」を
  # 区別する（Codexレビュー指摘・Major対応: `|| true` で握りつぶすと、コマンド失敗も
  # 空出力も同じ「健全」表示になってしまい、⑤のGH-CHECK-FAILEDと同じ「監視不能も
  # 異常」の原則に反する）。
  if ! unpushed_shas="$(git -C "$VAULT" rev-list "$unpushed_range" 2>/dev/null)"; then
    item_drift "[VAULT-PUSH-CHECK-FAILED] git rev-list ${unpushed_range} の実行に失敗しました（Vaultのgitリポジトリ破損等の可能性）＝push死活を判定できません。確認: git -C ${VAULT} fsck"
  elif [ -z "$unpushed_shas" ]; then
    if [ "$never_pushed" = "1" ]; then
      echo "  [VAULT-PUSH-CHECK-UNAVAILABLE] 判定材料が不足しています（${VAULT_BACKUP_BRANCH}に有効なcommitがありません）。判定不能のためfail-open"
    else
      # rev-listが空＝「originに無くlocalにあるcommit」は無い、という意味であり、
      # localとorigin/mainが同一コミットとは限らない（localがorigin/mainより
      # 単に遅れている＝reset等で巻き戻った場合も同じく空になる。Codexレビュー
      # 指摘・Minor対応: 以前は無条件に「同一コミット」と表示しており、巻き戻り
      # ケースでは事実と異なるメッセージになっていた）。
      local_sha="$(git -C "$VAULT" rev-parse --verify "${VAULT_BACKUP_BRANCH}" 2>/dev/null || true)"
      origin_sha="$(git -C "$VAULT" rev-parse --verify "origin/${VAULT_BACKUP_BRANCH}" 2>/dev/null || true)"
      if [ -n "$local_sha" ] && [ "$local_sha" = "$origin_sha" ]; then
        log "  -> ✅ ${VAULT_BACKUP_BRANCH} と origin/${VAULT_BACKUP_BRANCH} は同一コミット（push未反映の差分なし）"
      else
        log "  -> ✅ ${VAULT_BACKUP_BRANCH} に origin/${VAULT_BACKUP_BRANCH} へ未反映のcommitはありません（push未反映の差分なし。ローカルがorigin/${VAULT_BACKUP_BRANCH}より遅れているだけの可能性があります）"
      fi
    fi
  else
    # 未反映commit全件のコミット時刻を取り、最も古い（最小epoch）ものをSTALE判定の
    # 基準に、最も新しい（最大epoch）ものをFUTURE-DATE判定の基準にする（Codex
    # レビュー指摘・Major対応: `git rev-list` の出力順は履歴の走査順であり厳密な
    # 時刻降順ではないため、末尾(tail -1)を素朴に「最古」と仮定すると、
    # merge/cherry-pick等でコミット時刻が非単調な場合に誤ったcommitを基準にしうる。
    # 最小epochだけで判定すると、複数の未反映commitのうち一部だけが未来日時でも
    # 見逃す＝最大epochも別途追跡して未来判定に使う＝Codex二次レビュー指摘・
    # Major再対応）。個々の `git log` 取得が1件でも失敗した場合は、部分的な情報で
    # 誤った健全/STALE判定をしないよう監視不能のdriftとして扱う（Codex二次レビュー
    # 指摘・Minor対応: 従来は失敗したSHAを黙ってスキップし、残りだけで判定を続行
    # していた）。
    oldest_epoch=""
    oldest_unpushed_sha=""
    newest_epoch=""
    newest_unpushed_sha=""
    epoch_fetch_failed=0
    while IFS= read -r sha; do
      [ -z "$sha" ] && continue
      if ! epoch="$(git -C "$VAULT" log -1 --format=%ct "$sha" 2>/dev/null)" || [ -z "$epoch" ]; then
        epoch_fetch_failed=1
        continue
      fi
      if [ -z "$oldest_epoch" ] || [ "$epoch" -lt "$oldest_epoch" ]; then
        oldest_epoch="$epoch"
        oldest_unpushed_sha="$sha"
      fi
      if [ -z "$newest_epoch" ] || [ "$epoch" -gt "$newest_epoch" ]; then
        newest_epoch="$epoch"
        newest_unpushed_sha="$sha"
      fi
    done <<EOF
$unpushed_shas
EOF
    never_pushed_note=""
    [ "$never_pushed" = "1" ] && never_pushed_note="（一度も成功pushしていない可能性）"
    if [ "$epoch_fetch_failed" = "1" ]; then
      item_drift "[VAULT-PUSH-CHECK-FAILED] 未反映commitの一部でコミット時刻を取得できませんでした（Vaultのgitリポジトリ破損等の可能性）＝push死活を正しく判定できません。確認: git -C ${VAULT} log ${unpushed_range} --oneline"
    elif [ -z "$oldest_epoch" ]; then
      echo "  [VAULT-PUSH-CHECK-UNAVAILABLE] 未反映commitのコミット時刻を取得できませんでした（判定不能のためfail-open）"
    else
      now_epoch="$(date -u +%s)"
      if [ "$newest_epoch" -gt "$now_epoch" ]; then
        item_drift "[VAULT-PUSH-FUTURE-DATE] 未反映commit(${newest_unpushed_sha:0:8})のコミット時刻が未来です${never_pushed_note}＝システム時計のズレの可能性。確認: git -C ${VAULT} log ${unpushed_range} --oneline"
      else
        # 秒単位のまま閾値比較する（Codexレビュー指摘・Minor対応: 先に時間へ
        # 切り捨ててから比較すると、24時間ちょうど〜24時間59分が非driftになる
        # 境界漏れがあった）。表示用の時間数は参考値として別途丸める。
        age_seconds=$(( now_epoch - oldest_epoch ))
        threshold_seconds=$(( VAULT_BACKUP_PUSH_STALE_HOURS * 3600 ))
        age_hours_display=$(( age_seconds / 3600 ))
        if [ "$age_seconds" -gt "$threshold_seconds" ]; then
          item_drift "[VAULT-PUSH-STALE] ${VAULT_BACKUP_BRANCH} に origin/${VAULT_BACKUP_BRANCH} へ未反映のcommitがあり、最も古い未反映commitから ${age_hours_display} 時間経過しています（目安 ${VAULT_BACKUP_PUSH_STALE_HOURS} 時間）${never_pushed_note}＝vault-backupのpushが詰まっている疑い。確認: tail -50 /tmp/backup-vault.log 、git -C ${VAULT} log ${unpushed_range} --oneline （fetchしていないローカル参照のみでの判定のため、他マシンからの直接pushやfetch不足など他要因の可能性も含む＝上部コメント参照）"
        else
          log "  -> ${VAULT_BACKUP_BRANCH} は origin/${VAULT_BACKUP_BRANCH} より進んでいますが、最も古い未反映commitから ${age_hours_display} 時間（目安${VAULT_BACKUP_PUSH_STALE_HOURS}時間以内）のため様子見です${never_pushed_note}"
        fi
      fi
    fi
  fi
fi

echo
echo "⑦-2. scripts/backup-vault.sh のロック回収ミューテックス固着チェック"
# 2026-07-14 追加（Codex二次レビュー指摘・Major対応）。backup-vault.shの
# stale判定〜片付け〜再作成を1プロセスに直列化するmkdir排他ミューテックス
# （$LOCK_FILE.reclaim）は、旧来あった自己修復（stat mtime→rmdir）を
# 撤去しfail-closed設計にした（自己修復自体が別のABAレースを招くため。
# scripts/backup-vault.shのコメント参照）。そのため前回実行がミューテックス
# 保持中にクラッシュ（kill -9・電源断等）した極めて稀なケースでは、以後の
# バックアップがcommit前にfail-closedし続け無期限に止まりうる。commitが
# 1件も作られない＝上の⑦（ローカルcommitとorigin/mainの乖離）はrev-listが
# 常に空のままのため、この固着を検知できない別種の穴になる。読み取りのみ
# （削除はしない＝解除の判断はbackup-vault.sh自身の起動時ロジックに委ね、
# ここでABAレースを再導入しない）。
: "${VAULT_BACKUP_LOCK_FILE:=${TMPDIR:-/tmp}/aienv-backup-vault.lock}"
: "${VAULT_BACKUP_RECLAIM_STUCK_MINUTES:=10}"  # 回収区間は通常一瞬で完了するため、10分残っていれば固着とみなす
VAULT_BACKUP_RECLAIM_DIR="${VAULT_BACKUP_LOCK_FILE}.reclaim"
if [ -d "$VAULT_BACKUP_RECLAIM_DIR" ]; then
  if reclaim_mtime=$(stat -f %m "$VAULT_BACKUP_RECLAIM_DIR" 2>/dev/null) || \
     reclaim_mtime=$(stat -c %Y "$VAULT_BACKUP_RECLAIM_DIR" 2>/dev/null); then
    reclaim_now_epoch="$(date -u +%s)"
    if [ "$reclaim_mtime" -gt "$reclaim_now_epoch" ]; then
      # mtimeが未来＝システム時計のズレかファイル破損の可能性（Codex三次レビュー
      # 指摘・Minor対応: 未来mtimeだと経過分数が負になり「-N分前・様子見」という
      # 健全表示に誤判定されていた＝他の新鮮度チェックと同じ下限ガードを揃える）。
      item_drift "[VAULT-BACKUP-LOCK-FUTURE-DATE] ${VAULT_BACKUP_RECLAIM_DIR} の更新時刻が未来です＝システム時計のズレかファイル破損の可能性。確認: ls -la ${VAULT_BACKUP_RECLAIM_DIR}"
    else
      reclaim_age_minutes=$(( ( reclaim_now_epoch - reclaim_mtime ) / 60 ))
      if [ "$reclaim_age_minutes" -ge "$VAULT_BACKUP_RECLAIM_STUCK_MINUTES" ]; then
        item_drift "[VAULT-BACKUP-LOCK-STUCK] backup-vault.shのロック回収ミューテックス（${VAULT_BACKUP_RECLAIM_DIR}）が${reclaim_age_minutes}分前から残っています（目安${VAULT_BACKUP_RECLAIM_STUCK_MINUTES}分）＝前回実行が回収処理中にクラッシュし、以後のバックアップがcommit前にfail-closedし続けている疑い。確認: tail -50 /tmp/backup-vault.log 。解消方法: 実行中のbackup-vault.shプロセスが無いことを確認してから rmdir ${VAULT_BACKUP_RECLAIM_DIR}"
      else
        log "  -> ロック回収ミューテックスは${reclaim_age_minutes}分前から存在しますが、目安${VAULT_BACKUP_RECLAIM_STUCK_MINUTES}分以内のため様子見です（backup-vault.sh実行中の可能性）"
      fi
    fi
  elif [ -d "$VAULT_BACKUP_RECLAIM_DIR" ]; then
    # statが失敗したのにディレクトリはまだ存在する＝mtime取得不能の異常
    # （権限不備・ファイルシステム異常等）。`echo 0` でepoch0(1970年)に
    # フォールバックすると「大昔から固着」に化けて誤ってSTUCK扱いになるため
    # （Codex三次レビュー指摘・Minor対応）、監視不能として別種別で報告する。
    item_drift "[VAULT-BACKUP-LOCK-CHECK-FAILED] ${VAULT_BACKUP_RECLAIM_DIR} の更新時刻を取得できませんでした（権限不備等の可能性）＝固着しているかどうか判定できません。確認: ls -la ${VAULT_BACKUP_RECLAIM_DIR}"
  else
    # statの実行〜再確認の間にディレクトリが消えた＝backup-vault.sh側が
    # 正常に片付け終えただけ（健全）。stat失敗を「消えていた」と誤ってSTUCK
    # 扱いにしない（同じくCodex三次レビュー指摘・Minor対応）。
    log "  -> ✅ ロック回収ミューテックスは残っていません（確認中に解消されました）"
  fi
else
  log "  -> ✅ ロック回収ミューテックスは残っていません"
fi

echo
echo "======================================================================"
echo "⑧ ローカル実体プロファイルの検証状態（--check-profile・2026-09-01 設計書§4.4）"
echo "======================================================================"

# --check-profile（4.2-e）は副作用ゼロの検査口。resolve()の契約
# （profile-resolve-contract-2026-09-01.md §3）どおり、成功時はOK行の直後に
# 配役一覧を続けて表示するが、**stdoutの1行目だけが機械可読の契約**
# （OK/MINIMALのタブ区切り）。ここではその1行目だけを見る。
if [ ! -x "$DIR/scripts/install-main.sh" ]; then
  log "  -> scripts/install-main.sh が見つからないため --check-profile を実行できません。チェック対象外"
else
  # ⚠️ stdoutとstderrを別々に捕捉する（2026-09-01 Codex二次レビュー指摘・
  # Major対応: 従来は`2>&1`で合流させており、両方に出力があった場合に
  # 機械可読な1行目を見失う恐れがあった）。機械可読の契約
  # （resolve()の出力契約＝profile-resolve-contract-2026-09-01.md §3）は
  # check_profile_cmd()の正常系ではstdout側に現れる（pythonが見つからない
  # 等の事前チェックだけはfail()経由でstderrへ出て即exitする＝その場合は
  # stdoutが空になる）。判定にはstdoutの1行目を使い、stdoutが空のときだけ
  # stderrの1行目で補う。
  CHECK_PROFILE_STDOUT=""
  CHECK_PROFILE_STDERR=""
  CHECK_PROFILE_RC=0
  _check_profile_err_tmp="$(mktemp 2>/dev/null)" || _check_profile_err_tmp=""
  if [ -n "$_check_profile_err_tmp" ]; then
    CHECK_PROFILE_STDOUT="$("$DIR/scripts/install-main.sh" --check-profile 2>"$_check_profile_err_tmp")" || CHECK_PROFILE_RC=$?
    CHECK_PROFILE_STDERR="$(cat "$_check_profile_err_tmp" 2>/dev/null)"
    rm -f "$_check_profile_err_tmp"
  else
    # 一時ファイルを作れない異常時のみ、やむを得ず合流させる
    # （fail-openで「一致」扱いにはしない＝後段のPROFILE-VALIDATION-FAILEDへ
    # 素直に流れる）。
    CHECK_PROFILE_STDOUT="$("$DIR/scripts/install-main.sh" --check-profile 2>&1)" || CHECK_PROFILE_RC=$?
  fi
  CHECK_PROFILE_FIRST_LINE="$(printf '%s\n' "$CHECK_PROFILE_STDOUT" | head -1)"
  if [ -z "$CHECK_PROFILE_FIRST_LINE" ] && [ -n "$CHECK_PROFILE_STDERR" ]; then
    CHECK_PROFILE_FIRST_LINE="$(printf '%s\n' "$CHECK_PROFILE_STDERR" | head -1)"
  fi

  # 1行目を厳密にタブ区切りで分類する（RCの成否に関わらず常に1回だけ解析
  # する。2026-09-01 Codex一次レビュー指摘・Major対応: 従来は`grep -q '^OK'`
  # という前方一致だけでRC!=0時の分岐を決めており、非0終了なのに偶然
  # 'OK'から始まる出力（契約違反）であれば検証失敗を見逃しうる穴があった。
  # 併せて、本来のOK/MINIMAL/PROFILE_NOT_FOUND判定もexit codeに頼らず
  # 1行目の内容そのもの＝厳密な等価比較で行う）。パーサ自体の終了コードも
  # 確認し、解析不能（python3不在・予期せぬ例外等）を「正常終了」に丸めない。
  CHECK_PROFILE_PARSED=""
  CHECK_PROFILE_PARSE_RC=0
  CHECK_PROFILE_PARSED="$(python3 -c "
import sys
line = sys.argv[1]
parts = line.split(chr(9))
status = parts[0] if parts else ''
advisory = ''
unknown_extra = ''
if status == 'OK':
    for p in parts[1:]:
        if p.startswith('ADVISORY:'):
            advisory = p[len('ADVISORY:'):]
        elif p.startswith('UNKNOWN_EXTRA:'):
            unknown_extra = p[len('UNKNOWN_EXTRA:'):]
print('STATUS' + chr(9) + status)
print('ADVISORY' + chr(9) + advisory)
print('UNKNOWN_EXTRA' + chr(9) + unknown_extra)
" "$CHECK_PROFILE_FIRST_LINE" 2>/dev/null)" || CHECK_PROFILE_PARSE_RC=$?
  CP_STATUS="$(printf '%s\n' "$CHECK_PROFILE_PARSED" | awk -F'\t' '$1=="STATUS"{print $2}')"
  CP_ADVISORY="$(printf '%s\n' "$CHECK_PROFILE_PARSED" | awk -F'\t' '$1=="ADVISORY"{print $2}')"
  CP_UNKNOWN_EXTRA="$(printf '%s\n' "$CHECK_PROFILE_PARSED" | awk -F'\t' '$1=="UNKNOWN_EXTRA"{print $2}')"
  # v1委譲経路の唯一の既知の安全な非OK応答（check_profile_cmd()がlist-roles
  # のPROFILE_LEGACY_V1を捕捉して出す固定文言。install-main.sh:998の
  # log()呼び出しをそのまま転記＝log()は"[install-main] "を前置するため
  # その形まで含めて**完全一致**で判定する（2026-09-01 Codex三次レビュー
  # 指摘・Major対応: 前方一致/部分一致だと「未知の異常応答にたまたま同じ
  # 部分文字列が含まれる」ケースを誤って安全と判定しうる）。
  # ⚠️ 文言一致は他チーム（担当B）の実装文言に依存する弱い結合だが、
  # 「exit 0なら中身を見ずOK以外も健全」というfail-openより安全側。
  CP_IS_KNOWN_V1_MESSAGE=0
  if [ "$CHECK_PROFILE_FIRST_LINE" = "[install-main] プロファイルはv2形式ではありません（v1）。v1互換のまま運用されています。v2へ移行してください（§3.5）。" ]; then
    CP_IS_KNOWN_V1_MESSAGE=1
  fi

  if [ "$CHECK_PROFILE_PARSE_RC" -ne 0 ]; then
    item_drift "[PROFILE-VALIDATION-FAILED] --check-profile の出力を解析できませんでした（python3 exit=${CHECK_PROFILE_PARSE_RC}）＝監視不能。詳細: ${CHECK_PROFILE_FIRST_LINE:-空}"
  elif [ "$CHECK_PROFILE_RC" -ne 0 ] && [ "$CP_STATUS" = "PROFILE_NOT_FOUND" ] && case "$CHECK_PROFILE_FIRST_LINE" in *$'\t'*) true ;; *) false ;; esac; then
    # ⚠️ ローカル実体が一度も作られていない（P1ロールアウト未完了・v1委譲
    # 期間中のマシン）を「壊れている」と誤検知しない。他の値出力口
    # （resolve_leader_runtime）と同じく「実体が無い＝v1委譲」を落ちない
    # 挙動として扱う設計方針（§3.5）をここでも踏襲する。機械可読コード
    # （PROFILE_NOT_FOUND）の**厳密一致**で判定する＝人向け文言は
    # install-main.sh側の実装変更で変わりうるため、コード側で判定する
    # 方が壊れにくい。⚠️ タブ区切りの理由が続く正規の形（`<コード>\t<理由>`）
    # であることも要求する（2026-09-01 Codex三次レビュー指摘・Major対応:
    # 裸の"PROFILE_NOT_FOUND"1語だけでも同じ扱いになっていた＝契約の
    # 「タブ+理由」を満たさない出力を素通ししていた）。
    log "  -> ローカル実体プロファイルがまだ存在しません（P1ロールアウト未完了・v1委譲期間の可能性）。チェック対象外"
  elif [ "$CHECK_PROFILE_RC" -ne 0 ]; then
    # ⚠️ fail区分のvalidator違反は resolver 側（install-main.sh --print-
    # leader-runtime／settings.json生成）で既に止まる契約（§5「resolverの
    # exit契約」）。ここで検出するのは「同じ違反を①-2とは独立の経路
    # （--check-profile）から見て、SessionStart/週次通知でも必ず拾う」ため
    # であり、fail条件を二重に定義するものではない（設計書§4.4の注記）。
    # ⚠️ CP_STATUSが厳密に'OK'と一致する場合を除きすべて対象にする
    # （2026-09-01 Codex一次レビュー指摘・Major対応: 従来は前方一致の
    # 誤判定余地があった）。
    item_drift "[PROFILE-VALIDATION-FAILED] --check-profile が非0終了しました（${CHECK_PROFILE_FIRST_LINE:-理由不明}）＝ローカル実体プロファイルの検証に失敗しています。修正方法は上記の出力（行番号とキー名）を参照してください: $AIENV_LOCAL_PROFILE_PATH_HINT"
  elif [ "$CP_STATUS" != "OK" ] && [ "$CP_IS_KNOWN_V1_MESSAGE" != "1" ]; then
    # ⚠️ RC=0なのにOK行でも既知のv1委譲文言でもない＝空status・未知status・
    # 契約変更等の可能性がある「監視不能」であり、無条件の健全表示にしない
    # （2026-09-01 Codex二次レビュー指摘・Major対応: 従来はexit 0であれば
    # OK以外を無条件でv1委譲とみなし健全扱いしていた＝false negative）。
    item_drift "[PROFILE-VALIDATION-FAILED] --check-profile はexit 0でしたが、既知の応答形式（OK行／v1委譲の案内）のいずれとも一致しない出力でした＝監視不能。詳細: ${CHECK_PROFILE_FIRST_LINE:-空}"
  elif [ "$CP_STATUS" != "OK" ]; then
    # RC=0・既知のv1委譲文言＝list-rolesがPROFILE_LEGACY_V1を返し
    # install-main.sh側がログ表示のみでexit 0にする既存の委譲経路（§3.5）。
    # 壊れているわけではないため drift にはしない（既存のv1委譲の扱いを
    # 維持）。
    log "  -> ✅ --check-profile は正常終了しました（v1委譲）"
  else
    check_profile_drift_before=$TOTAL_DRIFT
    check_profile_had_info=0
    if [ -n "$CP_ADVISORY" ]; then
      # advisory のうち V1-a・V9-f・T4系（T4・T4-PRIME）・JUDGEMENT_UNKNOWN を
      # driftとして週次通知に出す（残課題台帳#3・本人裁定2026-09-01）。
      # ⚠️ プロファイル契約（profile-resolve-contract-2026-09-01.md §3）が
      # ADVISORY:に列挙しうる6コードのうち、監視不能系（版が仮想補完された
      # T4／このマシンのコードが古い可能性があるT4-PRIME／Bedrock経路・pin
      # 留めの判定不能だが通したJUDGEMENT_UNKNOWN）は「監視できていない」
      # こと自体が異常であり、V1-a・V9-fと同様にdrift計上へ拡張する。一方
      # EFFORT_COMPATIBILITY_UNVERIFIED（別名等でmodel実体を判別できない
      # ためのeffort適合警告）だけは恒常的に成立しうるノイズのため、本人裁定
      # により引き続きINFO表示に留めdriftへは数えない。⚠️ 契約が列挙する6
      # コードのいずれとも一致しない未知コードはEFFORT_COMPATIBILITY_
      # UNVERIFIEDと同列のINFOへは丸めず、PROFILE-ADVISORY-UNKNOWNとして
      # drift計上する（Codex一次レビュー指摘・Major対応: 6コード限定の契約に
      # 対する不一致自体が監視不能だから）。
      IFS=',' read -ra cp_advisory_items <<< "$CP_ADVISORY"
      for cp_item in "${cp_advisory_items[@]}"; do
        [ -z "$cp_item" ] && continue
        case "$cp_item" in
          V1-a|V9-f|T4|T4-PRIME|JUDGEMENT_UNKNOWN)
            item_drift "[PROFILE-ADVISORY:${cp_item}] ローカル実体プロファイルにadvisory該当があります（条件番号: ${cp_item}）。詳細は install-main.sh --check-profile の出力を確認してください: $AIENV_LOCAL_PROFILE_PATH_HINT"
            ;;
          EFFORT_COMPATIBILITY_UNVERIFIED)
            check_profile_had_info=1
            log "  -> ℹ️ INFO: advisory該当があります（条件番号: ${cp_item}）。恒常ノイズ回避のためdriftには数えません（本人裁定2026-09-01）"
            ;;
          *)
            # ⚠️ プロファイル契約（§3）がADVISORY:に列挙する6コードのいずれとも
            # 一致しない未知コード（将来の追加漏れ・contract側との版ずれ等の
            # 可能性）は、無条件でINFOへ丸めない（Codex一次レビュー指摘・Major
            # 対応: 従来は`*)`が唯一INFO扱いのデフォルト分岐であり、契約の
            # 6コード以外＝本来はresolverとの契約不一致であるものまで
            # 「恒常ノイズ」として静かに見逃していた）。監視不能として
            # drift計上する。
            item_drift "[PROFILE-ADVISORY-UNKNOWN:${cp_item}] ローカル実体プロファイルに未知のadvisory条件番号があります（条件番号: ${cp_item}）。プロファイル契約（profile-resolve-contract-2026-09-01.md §3）の6コードのいずれとも一致しません＝resolverとの契約不一致の可能性があり監視不能です: $AIENV_LOCAL_PROFILE_PATH_HINT"
            ;;
        esac
      done
    fi
    if [ -n "$CP_UNKNOWN_EXTRA" ]; then
      # ⚠️ UNKNOWN_EXTRAはadvisoryとは別扱い（§4a・T9'）: AI側は必読除外＝
      # 最小能力として振る舞うため、独立した[PROFILE-AI-UNREADABLE]項目で
      # 出す（キー名のみ・値は出さない＝絶対厳守③・V15と同じ秘匿方針）。
      item_drift "[PROFILE-AI-UNREADABLE] ローカル実体プロファイルに未知キーがあり、AI側は必読から除外されています（キー名: ${CP_UNKNOWN_EXTRA}）。機械側の解決値は有効なままですが、AIはこのプロファイルを読めていません。対処: scripts/update-sub.sh でコードを追随させるか、未知キーを削除してください: $AIENV_LOCAL_PROFILE_PATH_HINT"
    fi
    if [ "$TOTAL_DRIFT" -eq "$check_profile_drift_before" ]; then
      if [ "$check_profile_had_info" = "1" ]; then
        # 2026-09-01 Codex二次レビュー指摘・Minor対応: 対象外advisory
        # （INFO表示）が出ているのに「何も検出されなかった」と言うのは
        # 自己矛盾。driftが0件であることだけを言う。
        log "  -> ✅ --check-profile は正常終了しました（drift対象のadvisory・未知キーは検出されませんでした。対象外advisoryは上記INFO参照）"
      else
        log "  -> ✅ --check-profile は正常終了し、advisory・未知キーも検出されませんでした"
      fi
    fi
  fi
fi

echo
echo "======================================================================"
log "総drift件数: ${TOTAL_DRIFT}"
echo "======================================================================"

if [ "$JSON_MODE" = "1" ]; then
  DRIFT_EXCLUDING_ITEM4=$((TOTAL_DRIFT - ITEM4_DRIFT))
  # 呼び出し側（maintenance.sh Phase1①）は「stdoutの最終行だけがJSON」という
  # 契約でパースする（ファイル冒頭の使い方コメント参照）。ここまでの人間向け
  # 出力は変更していないため、このJSON行が常にstdoutの最終行になる。
  printf '{"total_drift": %d, "item4_drift": %d, "drift_excluding_item4": %d, "unknown_config_keys": %d}\n' \
    "$TOTAL_DRIFT" "$ITEM4_DRIFT" "$DRIFT_EXCLUDING_ITEM4" "$UNKNOWN_CONFIG_KEYS"
  if [ "$DRIFT_EXCLUDING_ITEM4" -gt 0 ]; then
    exit 1
  fi
  exit 0
fi
