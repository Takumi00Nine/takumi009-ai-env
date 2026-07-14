#!/usr/bin/env bash
# ポータブル化されたAI環境の「ズレ」を検知する手動実行ツール（Phase 1.5）。
#
# チェック項目:
#   ① symlink 12ファイル（install-main.sh の link() 呼び出しと同じ集合）が
#      repo の実体を指しているか
#   ② ~/.codex/config.toml（生成物）が repo の codex/config.toml テンプレと
#      「プレースホルダ展開を考慮すれば」一致しているか（実ファイルを
#      __AIENV_HOME__ へ逆置換してからテンプレと diff する）
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
#   ⑥ vault-agents（棚卸し・fragments-log・weekly-review・想起/読取ログフック）の死活。
#      「最新の棚卸しレポートが古すぎる」「fragments-logが古すぎる」
#      「vault-reads.tsv/vault-recall.tsvの最終記録が古すぎる」のいずれかを検知する
#      （2026-07-10 敵対的レビュー M-1/M-2 対応。3年ノーメンテ運用では「本人が定期的に
#      レポートを見に行く」以外に死活を知る手段が無かった＝検知網そのものが無人だと
#      無言で死ぬ穴を塞ぐ）。加えて「レポートは生成されているがリーダーに処理された
#      形跡（frontmatterの processed: 行）が無いまま何日も放置されている」も検知する
#      （2026-07-11 決定・claude/hooks/bootstrap-vault.sh の未処理レポート検知の
#      二次安全網。判定基準は同じ。2026-07-14修正: 従来は「最新1件」しか見ておらず、
#      drift-check LaunchAgent（毎週月曜9:30）がレポート生成（fragments-log 月3:30・
#      knowledge-merge-detect 月4:15）と同日実行のため、latestは常にage=0＝グレース
#      （既定3日）を構造的に超えられず、過去の未処理レポートが永久に検知されない
#      穴があった＝対象ディレクトリの未処理（processedマーカー無し）レポート全件を
#      判定対象に変更）。棚卸し・fragments-logの出力先は同決定で
#      Vault配下(Explorations/...)から $HOME/.claude/logs/ 配下へ移設済み
#      （「読まれない人間向け資料をVaultに置かない」）。$VAULT が無い
#      （サブ機・私的Vault未clone）場合は対象外。棚卸し・fragments-logは
#      README.mdにも明記の「メイン専用・任意」機能（scripts/install-vault-agents.sh
#      を実行していなければ対応LaunchAgent plistが無い）なので、reads/recallログ
#      （install-main.shで標準導入・任意ではない）とは別に、LaunchAgent plistの
#      実在で個別に導入判定してからチェックする（Codexレビュー指摘・Major:
#      reads/recallログだけが存在する普通のmain構成で、未導入の任意機能まで
#      毎回DEAD誤報していた）。weekly-review（「今週の歩み」週次振り返りcanvas。
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
#      /tmp/vault-backup.log（launchagents/com.takumi009.vault-backup.plistが
#      指定する一時領域・再起動で揮発）へ出るのみで、origin(GitHub)との乖離が
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
# ツールで、必要な時に手で実行する運用＝設計方針。ただし本ツールが陳腐化しない
# よう、scripts/drift-notify.sh 経由で launchagents/com.takumi009.drift-check.plist
# （メイン専用）から週1で無人実行され、drift>0ならmacOS通知される
# （2026-07-08 adoption-critic指摘対応・H-2）。
#
# 読み取りのみ（実 ~/.claude・~/.codex・実Vaultには一切書き込まない）。
#
# 使い方: scripts/check-drift.sh

set -uo pipefail  # -e は使わない（1項目の失敗で残りの検査が止まらないようにする）

# DIR は環境変数で上書き可（ユニットテスト用。本番は既定値のままでよい）。
: "${DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${VAULT:=$HOME/Data/obsidian}"
# 私的パッチ（別のprivateリポジトリ）のローカルclone先。環境変数で上書き可
# （ユニットテスト用。本番は既定値のままでよい＝README.md「導入手順」記載のパス）。
: "${AIENV_PRIVATE_REPO:=$HOME/work/takumi009-ai-env-private}"

TOTAL_DRIFT=0

log() { echo "[check-drift] $*"; }
item_drift() { echo "  - $*"; TOTAL_DRIFT=$((TOTAL_DRIFT + 1)); }

echo "======================================================================"
echo "① symlink が repo を向いているか"
echo "======================================================================"

SYMLINKS=(
  "$HOME/.claude/settings.json|$DIR/claude/settings.json"
  "$HOME/.claude/hooks/bootstrap-vault.sh|$DIR/claude/hooks/bootstrap-vault.sh"
  "$HOME/.claude/hooks/delegation-gate-v2.sh|$DIR/claude/hooks/delegation-gate-v2.sh"
  "$HOME/.claude/hooks/vault-recall.sh|$DIR/claude/hooks/vault-recall.sh"
  "$HOME/.claude/hooks/vault-read-log.sh|$DIR/claude/hooks/vault-read-log.sh"
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
echo "② ~/.codex/config.toml（生成物）と repo テンプレのプレースホルダ展開差分"
echo "======================================================================"

# Codex アプリが自動書き換えする機械管理キー（2026-07-08 実測で確認済み）。
# repo テンプレ（codex/config.toml）はこれらを意図的に含まない「キュレート版」
# なので、素朴な比較だと再インストール不要なのに毎回driftを報告してしまう。
# 比較前に live・テンプレ双方から同じものを取り除いてから比較する
# （2026-07-08 設計判断：検査②の慢性drift対応）。
#
# セクション丸ごと除去（ヘッダ行から次のセクションヘッダ直前まで）。
# 単純な前方一致（例: "[projects"）だと将来 [projects_backup] のような別の
# セクションまで誤って巻き込みかねないため、TOML table 名の境界
# （直後が "." のサブテーブル区切り、または "]" の終端）まで見て判定する
# （Codexレビュー指摘・Major）。bash側は可読性重視でliteralな正規表現文字列を
# 書き、awkの `-v` 代入は文字列リテラルとしてバックスラッシュを1段階解釈する
# ため、実際にawk側へ渡したい `\[` `\.` `\]` は `\\[` `\\.` `\\]` と2重に
# エスケープしている（実測で確認済み・単純escapeだと `\[` → `[` に潰れて
# 通常の正規表現扱いになり境界チェックが効かなくなる）。
MACHINE_MANAGED_TOML_SECTION_HEADER_REGEXES=(
  '^\\[marketplaces(\\.|\\])'  # プラグインのキャッシュパス・last_updated。次回起動時にCodexが再スキャンする
  '^\\[hooks\\.state(\\.|\\])' # hooks.json の信頼ハッシュキャッシュ（新Macでは初回に一度だけ再確認されるだけ）
  '^\\[projects(\\.|\\])'      # フォルダごとのtrust_level履歴
  '^\\[tui(\\.|\\])'           # オンボーディング通知の既読カウンタ等（実質的な設定ではない）
)
# 単一キー行の除去（セクション化されておらず、値がマシン/バージョン固有）。
# 行頭からの空白許容つきキー名アンカーにする（Codexレビュー指摘・Major：未アンカーの
# `NODE_REPL_TRUSTED_BROWSER_CLIENT_SHA256S` 等は他行への意図しない部分一致を招き、
# 逆に `^notify = ` は空白の書き方が違う実ファイル（例: `notify=[...]`）を消し漏らす）。
MACHINE_MANAGED_TOML_KEY_PATTERNS=(
  '^[[:space:]]*notify[[:space:]]*='                                # Codexアプリがインストール時のパスで自動再設定する。ユーザーがテンプレ上でコメントアウトして無効化していても実ファイルには復活しうる
  '^[[:space:]]*NODE_REPL_TRUSTED_BROWSER_CLIENT_SHA256S[[:space:]]*='  # Codex.appの内部ビルドに紐づくハッシュ（アップデートのたび変わる）
  '^[[:space:]]*BROWSER_USE_CODEX_APP_VERSION[[:space:]]*='            # Codex.appのバージョン文字列（アップデートのたび変わる）
)

# 標準入力のTOMLから機械管理キーを取り除き、標準出力へ出す。
# 空行の除去はしない。代わりに比較側で `diff -B`（空行だけの差分は無視）を
# 使い、セクション除去に伴う空行数のズレを吸収する。
#
# 既知の限界（Codexレビュー指摘・Major、2026-07-08時点で解消せず受容）:
# `diff -B` は行単位の判定のため、TOMLの複数行文字列（"""..."""）の内部に
# ある意味のある空行の増減も「空行だけの差分」として無視してしまいうる。
# 正しく避けるには複数行文字列の内外をawk側で状態管理する必要があるが、
# ~/.codex/config.toml はCodexアプリが生成する単純なkey=value/配列/
# テーブルの集合で複数行文字列は使われていない（本ファイル執筆時点で
# 現物を確認済み）ため、このdrift検知ツール（個人用・手動確認用）としては
# 過剰実装と判断し見送る。将来テンプレ側で複数行文字列を使うことになったら
# 要再検討。
strip_machine_managed_toml() {
  local section_regexes_joined
  section_regexes_joined="$(printf '%s\x1f' "${MACHINE_MANAGED_TOML_SECTION_HEADER_REGEXES[@]}")"
  local key_pattern_joined
  key_pattern_joined="$(IFS='|'; echo "${MACHINE_MANAGED_TOML_KEY_PATTERNS[*]}")"

  awk -v regexes="$section_regexes_joined" '
    BEGIN { n = split(regexes, arr, "\x1f") }
    {
      line = $0
      trimmed = line
      sub(/^[ \t]+/, "", trimmed)
      if (trimmed ~ /^\[/) {
        skip = 0
        for (i = 1; i <= n; i++) {
          if (arr[i] != "" && trimmed ~ arr[i]) { skip = 1; break }
        }
      }
      if (!skip) print line
    }
  ' | grep -vE "$key_pattern_joined"
}

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
  live_normalized="$(sed "s#${escaped_home}#__AIENV_HOME__#g" "$CONFIG_TOML_LIVE" | strip_machine_managed_toml)"
  template_content="$(strip_machine_managed_toml < "$CONFIG_TOML_TEMPLATE")"
  # -B（空行だけの差分は無視）で比較する。セクション除去箇所の前後に残る
  # 空行の本数がテンプレ側とたまたま合わなくても、それだけでは drift 扱いに
  # しないため（内容の差分は通常どおり検知する）。
  if diff -q -B <(printf '%s\n' "$live_normalized") <(printf '%s\n' "$template_content") >/dev/null 2>&1; then
    log "  -> ✅ プレースホルダ展開を考慮すれば一致しています（機械管理キー除外後）"
  else
    item_drift "[DIFF] $CONFIG_TOML_LIVE がテンプレと異なります（手動編集された、またはテンプレ更新後に未再生成の可能性。機械管理キーは除外済み）"
    diff -B <(printf '%s\n' "$live_normalized") <(printf '%s\n' "$template_content") | head -20 | sed 's/^/    /'
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
  item_drift "[MISSING] $VP_PREFS が見つかりません（export-public-vault.sh 未実行？）"
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
    item_drift "[DIFF] 実Vault と vault-public/Preferences に差分が ${n} 件あります（export-public-vault.sh の再実行が必要な可能性）"
    printf '%s\n' "$diff_out" | sed 's/^/    /'
  else
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
echo "⑥ vault-agents 死活チェック（棚卸し・fragments-log・weekly-review・reads/recallログ）"
echo "======================================================================"

# vault_inventory.py（隔週）・fragments_log.py（週次）のLaunchAgentと、
# vault-recall.sh/vault-read-log.sh（UserPromptSubmit/PostToolUseフック）が
# 「動いているはずなのに実は死んでいる」を検知する。vault_inventory.py 側にも
# §12でreads/recallの死活を出すが、そちらは本人がレポートを開かないと見えない
# （M-2で指摘された穴そのもの）。ここは既存の週次drift通知に相乗りさせ、
# 見に行かなくても通知される経路にする。
#
# しきい値は vault_inventory.py §12（レポート本文内の参考情報・目安30日）より
# 厳しくしている。ここは能動通知の発火条件＝早めに鳴らしてよい
# （「誤報を恐れて沈黙するより軽い誤報を許容する側に倒す」設計方針）。
: "${VAULT_INVENTORY_STALE_DAYS:=20}"    # 隔週(目安15日) + 猶予
: "${FRAGMENTS_LOG_STALE_DAYS:=10}"      # 週次(目安7日) + 猶予
: "${VAULT_AGENT_LOG_STALE_DAYS:=7}"
: "${VAULT_READS_LOG:=$HOME/.claude/logs/vault-reads.tsv}"
: "${VAULT_RECALL_LOG:=$HOME/.claude/logs/vault-recall.tsv}"
# fragments-log（旧fragments-review）・vault-inventory のレポート出力先
# （2026-07-11 決定でVault配下(Explorations/...)から $HOME/.claude/logs/ 配下へ
# 移設。claude/hooks/bootstrap-vault.sh・scripts/vault-agents/fragments_log.py・
# vault_inventory.py と同じ既定値・同じ環境変数名）。
: "${FRAGMENTS_LOG_DIR:=$HOME/.claude/logs/fragments-log}"
: "${VAULT_INVENTORY_LOG_DIR:=$HOME/.claude/logs/vault-inventory}"
# knowledge-merge-candidates（外部脳Knowledge自律整理・柱②・週次・2026-07-12追加）の
# レポート出力先。claude/hooks/bootstrap-vault.sh・
# scripts/vault-agents/knowledge_merge_candidates.py と同じ既定値・同じ環境変数名。
: "${KNOWLEDGE_MERGE_CANDIDATES_LOG_DIR:=$HOME/.claude/logs/knowledge-merge-candidates}"
: "${KNOWLEDGE_MERGE_STALE_DAYS:=10}"    # 週次(目安7日) + 猶予（fragments-logと同型）
# 未解決ALERTレポート出力先（FR12b／要件v2未決事項j）。knowledge_merge.py等の
# マージ実行側が生成する想定（本ツールは読み取りのみ）。
: "${VAULT_MERGE_ALERTS_DIR:=$HOME/.claude/logs/vault-merge-alerts}"
# weekly-review（「今週の歩み」週次振り返りcanvas・takumi009-ai-env-private/
# tools/weekly-review/weekly_review.py。LaunchAgent com.takumi009.weekly-review が
# 毎週月曜04:00に無人実行。2026-07-14追加＝外部脳監視・バックアップ機構総点検で
# 「本ツールにweekly-reviewへの言及が無く監視対象外だった」欠陥への対応）の
# 出力先。private repo側のスクリプトと同じ既定値。
: "${WEEKLY_REVIEW_DIR:=$VAULT/Explorations/weekly-review}"
: "${WEEKLY_REVIEW_STALE_DAYS:=10}"      # 週次(目安7日) + 猶予（fragments-logと同型）
# 未処理レポートの猶予日数（2026-07-11 決定・claude/hooks/bootstrap-vault.sh の
# 未処理レポート検知と同じ判定基準＝frontmatter `processed: YYYY-MM-DD` の有無）。
# bootstrap-vault.sh は毎セッション気づけるための一次検知、こちらは「気づいたのに
# 何セッションも処理されないまま放置」を捕捉する二次の安全網。生成直後は未処理が
# 正常（次回セッションで処理されるまでの間）なので、STALE系より短い猶予を持たせる。
: "${UNPROCESSED_REPORT_GRACE_DAYS:=3}"

# 棚卸し・fragments-logは README.md にも明記の「メイン専用・任意」機能で、
# vault-reads.tsv/vault-recall.tsv を書くフック（vault-recall.sh/vault-read-log.sh。
# install-main.shで標準導入・任意ではない）とは導入の必須性が異なる（Codexレビュー
# 指摘・Major: reads/recallログだけが存在する状態＝任意機能は未導入だが標準フックは
# 動いている、というごく普通の main機構成で、下のvault_agents_untouchedだけで
# ゲートすると棚卸し/fragments-logのDEADが恒常的に誤報され続けてしまう）。
# LaunchAgent plist（$HOME/Library/LaunchAgents/com.takumi009.<name>.plist）の
# 実在をもって「この任意機能を導入したか」を個別に判定し、未導入ならレポート系の
# 新鮮度・未処理チェックそのものをスキップする（reads/recallログの死活判定には
# 影響しない＝任意機能の未導入で標準フックの死活検知まで消してしまわないため）。
: "${LAUNCH_AGENTS_DIR:=$HOME/Library/LaunchAgents}"
vault_agent_installed() {
  [ -f "${LAUNCH_AGENTS_DIR}/com.takumi009.$1.plist" ]
}

# vault-agents関連のシグナル（棚卸し・fragments-logの出力2種＋reads/recallログ2種＋
# 棚卸し・fragments-logのLaunchAgent plist2種＝計6種）が1つも無ければ「一度も
# 導入されていない」とみなしてセクション全体を対象外にする（旧実装は
# $VAULT/Explorations の有無で判定していたが、2026-07-11 決定で棚卸し・
# fragments-logの出力先がVault配下から $HOME/.claude/logs/ 配下へ移り、
# Explorations自体がもう作られなくなったため判定基準を移設先へ合わせた）。
# plist2種もシグナルに含める（Codexレビュー指摘・Major再指摘: 出力4種だけで
# 判定すると「plistは導入済みだが初回実行前・またはジョブが一度も成功していない」
# ケースが出力側の不在と見分けられず、セクション全体が対象外になって本来出るべき
# DEADが出せなくなる）。
vault_agents_untouched=1
[ -d "$FRAGMENTS_LOG_DIR" ] && vault_agents_untouched=0
[ -d "$VAULT_INVENTORY_LOG_DIR" ] && vault_agents_untouched=0
[ -d "$KNOWLEDGE_MERGE_CANDIDATES_LOG_DIR" ] && vault_agents_untouched=0
[ -d "$VAULT_MERGE_ALERTS_DIR" ] && vault_agents_untouched=0
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
vault_agent_installed "vault-inventory" && vault_agents_untouched=0
vault_agent_installed "fragments-log" && vault_agents_untouched=0
vault_agent_installed "knowledge-merge-detect" && vault_agents_untouched=0
vault_agent_installed "weekly-review" && vault_agents_untouched=0

if [ ! -d "$VAULT" ]; then
  log "  -> Vaultが見つかりません（${VAULT}）。このマシンに私的Vaultが無い（サブ機）想定ならチェック対象外"
elif [ "$vault_agents_untouched" = "1" ]; then
  log "  -> vault-agentsの出力（${FRAGMENTS_LOG_DIR}・${VAULT_INVENTORY_LOG_DIR}・${KNOWLEDGE_MERGE_CANDIDATES_LOG_DIR}・${VAULT_MERGE_ALERTS_DIR}・${VAULT_READS_LOG}・${VAULT_RECALL_LOG}）・weekly-review plist（${LAUNCH_AGENTS_DIR}/com.takumi009.weekly-review.plist）が1件も見つかりません。vault-agentsが一度も導入されていない想定ならチェック対象外"
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

  # ディレクトリ内の最新 YYYY-MM-DD.md の日付から today までの経過日数を返す
  # （BSD date。1件も無ければ非0で返し、呼び出し側で「一度も生成されていない」扱い）。
  latest_report_age_days() {
    local dir="$1" latest base epoch
    latest="$(ls "$dir"/20*.md 2>/dev/null | sort | tail -1)"
    [ -z "$latest" ] && return 1
    base="$(basename "$latest")"
    base="${base%.md}"
    epoch="$(date -j -f "%Y-%m-%d" "$base" +%s 2>/dev/null)" || return 1
    age_days_from_epoch "$epoch"
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

  # レポート系（棚卸し・fragments-log）1件分の判定をまとめる。
  #   $1=ディレクトリ $2=ラベル(drift種別プレフィクス) $3=しきい値(日) $4=表示名 $5=grep対象LaunchAgent名
  check_report_freshness() {
    local dir="$1" label="$2" threshold="$3" name="$4" agent="$5" age
    if ! age="$(latest_report_age_days "$dir")"; then
      item_drift "[${label}-DEAD] ${name}が一度も見つかりません（${dir}）＝com.takumi009.${agent} LaunchAgent停止の疑い。確認: launchctl list | grep ${agent}"
      return
    fi
    if [ "$age" -lt 0 ]; then
      item_drift "[${label}-FUTURE-DATE] ${dir} の最新ファイル名の日付が未来です＝ファイル名破損かシステム時計のズレの可能性。確認: ls ${dir}"
      return
    fi
    if [ "$age" -gt "$threshold" ]; then
      item_drift "[${label}-STALE] 最新の${name}が ${age} 日前（目安 ${threshold} 日）＝com.takumi009.${agent} LaunchAgent停止の疑い。確認: launchctl list | grep ${agent}"
    else
      log "  -> ✅ ${name}: ${age}日前（目安${threshold}日以内）"
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
  # 棚卸し・fragments-log等（latest_report_age_days＝ファイル名の日付＝生成日）とは
  # 判定方式を変えている。weekly_review.pyの出力ファイル名は「生成日」ではなく
  # 「対象週（直前の完全な週）の月曜日」＝生成日の7日前固定になるため、ファイル名
  # ベースで判定すると生成直後でも常にage=7からスタートしてしまい、latest_report_
  # age_days/check_report_freshnessと同じしきい値運用ができない（オフセットの
  # 分だけしきい値を余分に緩める必要が生じ、STALE等の他チェックと閾値の意味が
  # 揃わなくなる）。かわりに最新ファイルの実際の更新時刻(mtime)を基準にする＝
  # 生成直後はage=0、次回生成（1週間後）直前でage=7弱まで自然に増える、という
  # fragments-log等と同じ挙動になるため、しきい値もfragments-logと同じ考え方
  # （週次+猶予）を流用できる。
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

  # レポート系1件分の「未処理」判定（2026-07-11 決定・claude/hooks/bootstrap-vault.sh
  # の未処理レポート検知と同じ基準＝最新レポートのfrontmatterに
  # `processed: YYYY-MM-DD` 行が無ければ未処理）。bootstrap-vault.sh は毎セッションの
  # 一次検知、こちらは「セッションが開かれても何日も処理されないまま放置」を捕捉する
  # 二次の安全網（週次drift通知に相乗り）。DEAD/FUTURE-DATE/STALE は
  # check_report_freshness 側で既に報告済みのため、ここでは二重報告しない
  # （レポートが1件も無い・日付が未来・既にSTALE閾値を超えている場合は静かに戻る＝
  # 「新しい報告が来ていない」という同一原因の症状を2種類のdrift項目で重複報告しない）。
  # ファイル先頭のfrontmatter（先頭行が `---` の場合のみ、次の `---` 行の直前まで）を
  # 標準出力へ書く。先頭行が `---` でない・読み取れない等はfrontmatter無し扱いで
  # 空を返す（claude/hooks/bootstrap-vault.sh と同じ実装＝frontmatter外の本文に
  # 偶然 `processed: YYYY-MM-DD` があってもマーカーと誤認しない。Codexレビュー
  # 指摘・Major）。
  report_frontmatter() {
    awk 'NR==1 { if ($0 != "---") exit; next } /^---[[:space:]]*$/ { exit } { print }' "$1" 2>/dev/null
  }

  # ディレクトリ内の*.mdファイルのうち、frontmatterに`resolved: YYYY-MM-DD`行が
  # 無いもの（＝未解決ALERT）の件数を返す（claude/hooks/bootstrap-vault.shの
  # count_unresolved_alerts()と同じ判定基準。FR12b／要件v2未決事項j「resolved確認
  # までの全マージ停止ラッチ」の週次drift通知側での可視化）。ALERTファイル名は
  # 日付先頭固定ではない想定（候補IDベース等）のため*.md全件を対象にする。
  count_unresolved_alerts() {
    local dir="$1" count=0 f
    for f in "$dir"/*.md; do
      [ -e "$f" ] || continue
      if ! report_frontmatter "$f" | grep -qE '^resolved:[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]*$'; then
        count=$((count + 1))
      fi
    done
    echo "$count"
  }

  #   $1=ディレクトリ $2=ラベル(drift種別プレフィクス) $3=しきい値(日・freshnessと同じ値を渡す) $4=表示名
  #
  # 2026-07-14 修正: 旧実装は「最新1件」だけを判定していた。drift-check
  # LaunchAgentは毎週月曜9:30に実行され、レポート生成（fragments-log 月3:30・
  # knowledge-merge-detect 月4:15）と同日実行のため、latestは本ツール実行時点で
  # 常にage=0（当日生成）＝グレース期間(既定3日)を構造的に超えられず、過去の
  # 未処理レポート（＝最新が処理されて入れ替わり、超過グレースのまま放置された
  # 旧レポート）が永久に検知されない穴があった（外部脳監視・バックアップ機構
  # 総点検で確定）。対象ディレクトリの「processedマーカー無し」全レポートを
  # 判定対象にし、age > グレースのものを（複数あれば件数＋最古/最新パスで）
  # drift計上するよう修正。STALE側チェック（latestの生成自体が停止している疑い。
  # check_report_freshnessで既に報告済み）との二重報告は、latestがSTALE閾値超過
  # している場合だけそのファイルを対象から除外することで避ける（それより古い
  # 個々のレポートの未処理は「生成停止」とは別症状のため引き続き判定する）。
  check_report_processed() {
    local dir="$1" label="$2" threshold="$3" name="$4"
    local files latest latest_age
    files="$(ls "$dir"/20*.md 2>/dev/null | sort)"
    [ -z "$files" ] && return
    latest="$(printf '%s\n' "$files" | tail -1)"
    latest_age="$(latest_report_age_days "$dir" 2>/dev/null)" || latest_age=""
    # 「latestが処理済みマーカーを持つか」は表示用に別途保持する（旧実装の
    # ✅ ...処理済みマーカーあり メッセージを、latest以外に未処理レポートが
    # 無い場合に限り引き続き出すため）。
    local latest_processed=0
    if report_frontmatter "$latest" | grep -qE '^processed:[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]*$'; then
      latest_processed=1
    fi

    local unprocessed_count=0 oldest_path="" oldest_age="" newest_path="" newest_age="" within_grace_count=0
    # latestが新鮮度チェック側（STALEまたはFUTURE-DATE）で既に報告済みのため
    # ここでは判定対象から除外した、というフラグ（Codexレビュー指摘・Minor対応:
    # 当初STALEだけを見ておりFUTURE-DATE除外時にフラグが立たず、他に未処理対象が
    # 無いと「未処理レポートなし」という事実と異なる健全表示になっていた）。
    local latest_skipped_by_freshness_check=0
    local f base epoch age
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      base="$(basename "$f" .md)"
      epoch="$(date -j -f "%Y-%m-%d" "$base" +%s 2>/dev/null)" || continue
      age="$(age_days_from_epoch "$epoch")"
      if [ "$age" -lt 0 ]; then
        # FUTURE-DATEはfreshness側で既に報告済み。二重報告しない。
        [ "$f" = "$latest" ] && latest_skipped_by_freshness_check=1
        continue
      fi
      if [ "$f" = "$latest" ] && [ -n "$latest_age" ] && [ "$latest_age" -gt "$threshold" ]; then
        latest_skipped_by_freshness_check=1
        continue  # 生成自体が停止している疑い＝STALE側で既に報告済み。ここでは二重報告しない
      fi
      if report_frontmatter "$f" | grep -qE '^processed:[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]*$'; then
        continue
      fi
      if [ "$age" -gt "$UNPROCESSED_REPORT_GRACE_DAYS" ]; then
        unprocessed_count=$((unprocessed_count + 1))
        if [ -z "$oldest_path" ]; then
          oldest_path="$f"
          oldest_age="$age"
        fi
        newest_path="$f"
        newest_age="$age"
      else
        within_grace_count=$((within_grace_count + 1))
      fi
    done <<EOF
$files
EOF

    if [ "$unprocessed_count" -gt 0 ]; then
      # 表示は日付のみではなくフルパス（本人がそのまま開けるように・2026-07-12追加）。
      item_drift "[${label}-UNPROCESSED] ${name}に未処理（frontmatterの processed: 行が無い）レポートが${unprocessed_count}件あります（目安 ${UNPROCESSED_REPORT_GRACE_DAYS} 日超）。最古: ${oldest_path}（${oldest_age}日前）／最新: ${newest_path}（${newest_age}日前）。次回セッションで確認・処理してください。"
      return
    fi
    # 以下、優先順位を明示的に分岐する（Codexレビュー指摘・Minor対応:
    # 「処理済み」と「他に猶予期間内の未処理がある」が両立する場合に片方だけを
    # 表示すると情報が欠落する。また、latestがSTALE除外（上のループでskip）された
    # 結果たまたま他に対象が無い場合、単純な優先順位だけだと「未処理レポートなし」
    # という事実と異なるメッセージになり得るため専用の分岐を用意する）。
    if [ "$latest_processed" -eq 1 ] && [ "$within_grace_count" -gt 0 ]; then
      log "  -> ${name}: 処理済みマーカーあり（$(basename "$latest" .md)）／他に未処理のレポートが${within_grace_count}件ありますが猶予期間内です（目安${UNPROCESSED_REPORT_GRACE_DAYS}日以内）"
    elif [ "$latest_processed" -eq 1 ]; then
      log "  -> ✅ ${name}: 処理済みマーカーあり（$(basename "$latest" .md)）"
    elif [ "$within_grace_count" -gt 0 ]; then
      log "  -> ${name}: 未処理のレポートが${within_grace_count}件ありますが猶予期間内です（目安${UNPROCESSED_REPORT_GRACE_DAYS}日以内）"
    elif [ "$latest_skipped_by_freshness_check" -eq 1 ]; then
      log "  -> ${name}: 最新レポートは新鮮度チェック側（STALEまたはFUTURE-DATE）で既に報告済みのため、未処理判定はここでは保留します"
    else
      log "  -> ✅ ${name}: 未処理レポートなし"
    fi
  }

  if vault_agent_installed "vault-inventory"; then
    check_report_freshness "$VAULT_INVENTORY_LOG_DIR" "VAULT-INVENTORY" \
      "$VAULT_INVENTORY_STALE_DAYS" "棚卸しレポート" "vault-inventory"
    check_report_processed "$VAULT_INVENTORY_LOG_DIR" "VAULT-INVENTORY" \
      "$VAULT_INVENTORY_STALE_DAYS" "棚卸しレポート"
  else
    log "  -> 棚卸しレポート: 任意機能未導入（${LAUNCH_AGENTS_DIR}/com.takumi009.vault-inventory.plist が無い。scripts/install-vault-agents.sh 未実行）のためチェック対象外"
  fi
  if vault_agent_installed "fragments-log"; then
    check_report_freshness "$FRAGMENTS_LOG_DIR" "FRAGMENTS-LOG" \
      "$FRAGMENTS_LOG_STALE_DAYS" "fragments-logレポート" "fragments-log"
    check_report_processed "$FRAGMENTS_LOG_DIR" "FRAGMENTS-LOG" \
      "$FRAGMENTS_LOG_STALE_DAYS" "fragments-logレポート"
  else
    log "  -> fragments-logレポート: 任意機能未導入（${LAUNCH_AGENTS_DIR}/com.takumi009.fragments-log.plist が無い。scripts/install-vault-agents.sh 未実行）のためチェック対象外"
  fi
  if vault_agent_installed "knowledge-merge-detect"; then
    check_report_freshness "$KNOWLEDGE_MERGE_CANDIDATES_LOG_DIR" "KNOWLEDGE-MERGE-CANDIDATES" \
      "$KNOWLEDGE_MERGE_STALE_DAYS" "Knowledge統合候補レポート" "knowledge-merge-detect"
    check_report_processed "$KNOWLEDGE_MERGE_CANDIDATES_LOG_DIR" "KNOWLEDGE-MERGE-CANDIDATES" \
      "$KNOWLEDGE_MERGE_STALE_DAYS" "Knowledge統合候補レポート"
  else
    log "  -> Knowledge統合候補レポート: 任意機能未導入（${LAUNCH_AGENTS_DIR}/com.takumi009.knowledge-merge-detect.plist が無い。scripts/install-vault-agents.sh 未実行）のためチェック対象外"
  fi
  if vault_agent_installed "weekly-review"; then
    check_weekly_review_freshness "$WEEKLY_REVIEW_DIR" "$WEEKLY_REVIEW_STALE_DAYS"
  else
    log "  -> 週次振り返りcanvas: 任意機能未導入（${LAUNCH_AGENTS_DIR}/com.takumi009.weekly-review.plist が無い。takumi009-ai-env-private/install-private.sh --with-launchagents 未実行。メイン専用の個人ツール）のためチェック対象外"
  fi
  # 未解決ALERT（FR12b・要件v2未決事項j）。棚卸し/fragments-log/knowledge-merge-
  # candidatesのような「定期生成物の新鮮度」チェックとは性質が異なる（ALERTは
  # イベント駆動＝正常時は1件も生成されない）ため、plist導入有無に関わらず
  # ディレクトリが存在すれば常にチェックする（bootstrap-vault.shの④と同じ考え方）。
  if [ -d "$VAULT_MERGE_ALERTS_DIR" ]; then
    unresolved_alert_count="$(count_unresolved_alerts "$VAULT_MERGE_ALERTS_DIR")"
    if [ "$unresolved_alert_count" -gt 0 ]; then
      item_drift "[VAULT-MERGE-ALERT-UNRESOLVED] ${VAULT_MERGE_ALERTS_DIR} に未解決ALERT（frontmatterのresolved:行が無いファイル）が${unresolved_alert_count}件あります＝Knowledgeマージ全体が停止中の疑い（FR10ラッチ）。確認: ls ${VAULT_MERGE_ALERTS_DIR}"
    else
      log "  -> ✅ 未解決ALERT: 0件"
    fi
  else
    log "  -> 未解決ALERT: ${VAULT_MERGE_ALERTS_DIR} が無い（ALERT未発生の想定）ためチェック対象外"
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
          item_drift "[VAULT-PUSH-STALE] ${VAULT_BACKUP_BRANCH} に origin/${VAULT_BACKUP_BRANCH} へ未反映のcommitがあり、最も古い未反映commitから ${age_hours_display} 時間経過しています（目安 ${VAULT_BACKUP_PUSH_STALE_HOURS} 時間）${never_pushed_note}＝vault-backupのpushが詰まっている疑い。確認: tail -50 /tmp/vault-backup.log 、git -C ${VAULT} log ${unpushed_range} --oneline （fetchしていないローカル参照のみでの判定のため、他マシンからの直接pushやfetch不足など他要因の可能性も含む＝上部コメント参照）"
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
        item_drift "[VAULT-BACKUP-LOCK-STUCK] backup-vault.shのロック回収ミューテックス（${VAULT_BACKUP_RECLAIM_DIR}）が${reclaim_age_minutes}分前から残っています（目安${VAULT_BACKUP_RECLAIM_STUCK_MINUTES}分）＝前回実行が回収処理中にクラッシュし、以後のバックアップがcommit前にfail-closedし続けている疑い。確認: tail -50 /tmp/vault-backup.log 。解消方法: 実行中のbackup-vault.shプロセスが無いことを確認してから rmdir ${VAULT_BACKUP_RECLAIM_DIR}"
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
log "総drift件数: ${TOTAL_DRIFT}"
echo "======================================================================"
