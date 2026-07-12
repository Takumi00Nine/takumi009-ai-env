#!/usr/bin/env bash
# ポータブル化されたAI環境の「ズレ」を検知する手動実行ツール（Phase 1.5）。
#
# チェック項目:
#   ① symlink 12ファイル（install-main.sh の link() 呼び出しと同じ集合）が
#      repo の実体を指しているか
#   ② ~/.codex/config.toml（生成物）が repo の codex/config.toml テンプレと
#      「プレースホルダ展開を考慮すれば」一致しているか（実ファイルを
#      __AIENV_HOME__ へ逆置換してからテンプレと diff する）
#   ③ repo（このリポジトリ）に未commitの変更が無いか
#   ④ vault-public/Preferences と実 Vault の Preferences に差分が無いか
#      （export-public-vault.sh のエクスポート漏れ検知）
#   ⑤ private であるべき remote（Vaultバックアップ・私的パッチrepo）が
#      実際に GitHub 上で private のままか（`gh repo view --json visibility`）。
#      ai-env 本体（このリポジトリ自身）は「公開予定」のため対象外。
#      remote未設定はチェック対象外（情報表示のみ）。gh 不在・未認証・API失敗は
#      drift にはせず WARN 表示のみに留める（2026-07-08 adoption-critic指摘対応。
#      「必須指摘」＝private repoの意図しない公開化を検知する恒久対策）。
#   ⑥ vault-agents（棚卸し・fragments-log・想起/読取ログフック）の死活。
#      「最新の棚卸しレポートが古すぎる」「fragments-logが古すぎる」
#      「vault-reads.tsv/vault-recall.tsvの最終記録が古すぎる」のいずれかを検知する
#      （2026-07-10 敵対的レビュー M-1/M-2 対応。3年ノーメンテ運用では「本人が定期的に
#      レポートを見に行く」以外に死活を知る手段が無かった＝検知網そのものが無人だと
#      無言で死ぬ穴を塞ぐ）。加えて「レポートは生成されているがリーダーに処理された
#      形跡（frontmatterの processed: 行）が無いまま何日も放置されている」も検知する
#      （2026-07-11 決定・claude/hooks/bootstrap-vault.sh の未処理レポート検知の
#      二次安全網。判定基準は同じ）。棚卸し・fragments-logの出力先は同決定で
#      Vault配下(Explorations/...)から $HOME/.claude/logs/ 配下へ移設済み
#      （「読まれない人間向け資料をVaultに置かない」）。$VAULT が無い
#      （サブ機・私的Vault未clone）場合は対象外。棚卸し・fragments-logは
#      README.mdにも明記の「メイン専用・任意」機能（scripts/install-vault-agents.sh
#      を実行していなければ対応LaunchAgent plistが無い）なので、reads/recallログ
#      （install-main.shで標準導入・任意ではない）とは別に、LaunchAgent plistの
#      実在で個別に導入判定してからチェックする（Codexレビュー指摘・Major:
#      reads/recallログだけが存在する普通のmain構成で、未導入の任意機能まで
#      毎回DEAD誤報していた）。
#      ログの時刻(TSV1列目)はvault-recall.sh/vault-read-log.shがUTCで書くため、
#      経過日数の算出は `TZ=UTC` を明示してパースする（2026-07-10 敵対的レビュー
#      2回目 N-5 対応。以前はローカルTZとして解釈しており、JST環境では±9hずれ、
#      日境界付近では経過日数が1日多くカウントされ得た＝日単位閾値の誤判定要因）。
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
  git_status="$(git -C "$DIR" status --porcelain 2>/dev/null || true)"
  if [ -z "$git_status" ]; then
    log "  -> ✅ 未commitの変更はありません"
  else
    n=$(printf '%s\n' "$git_status" | grep -c . || true)
    item_drift "[UNCOMMITTED] 未commitの変更が ${n} 件あります"
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
  diff_out="$(diff -rq "$VAULT_PREFS" "$VP_PREFS" 2>/dev/null || true)"
  if [ -z "$diff_out" ]; then
    log "  -> ✅ 差分なし（vault-public/Preferences は実Vaultの最新を反映しています）"
  else
    n=$(printf '%s\n' "$diff_out" | grep -c . || true)
    item_drift "[DIFF] 実Vault と vault-public/Preferences に差分が ${n} 件あります（export-public-vault.sh の再実行が必要な可能性）"
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
    echo "  [GH-CHECK-FAILED] ${vlabel} (${vowner_repo}) の可視性を取得できませんでした（gh 未認証・権限不足・ネットワーク不通の可能性。'gh auth status' を確認してください）"
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
echo "⑥ vault-agents 死活チェック（棚卸し・fragments-log・reads/recallログ）"
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
[ -f "$VAULT_READS_LOG" ] && vault_agents_untouched=0
[ -f "$VAULT_RECALL_LOG" ] && vault_agents_untouched=0
vault_agent_installed "vault-inventory" && vault_agents_untouched=0
vault_agent_installed "fragments-log" && vault_agents_untouched=0
vault_agent_installed "knowledge-merge-detect" && vault_agents_untouched=0

if [ ! -d "$VAULT" ]; then
  log "  -> Vaultが見つかりません（${VAULT}）。このマシンに私的Vaultが無い（サブ機）想定ならチェック対象外"
elif [ "$vault_agents_untouched" = "1" ]; then
  log "  -> vault-agentsの出力（${FRAGMENTS_LOG_DIR}・${VAULT_INVENTORY_LOG_DIR}・${KNOWLEDGE_MERGE_CANDIDATES_LOG_DIR}・${VAULT_MERGE_ALERTS_DIR}・${VAULT_READS_LOG}・${VAULT_RECALL_LOG}）が1件も見つかりません。vault-agentsが一度も導入されていない想定ならチェック対象外"
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
  age_days_from_epoch() {
    local epoch=$1
    echo $(( ( $(date -u +%s) - epoch ) / 86400 ))
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
  check_report_processed() {
    local dir="$1" label="$2" threshold="$3" name="$4" latest age
    latest="$(ls "$dir"/20*.md 2>/dev/null | sort | tail -1)"
    [ -z "$latest" ] && return
    age="$(latest_report_age_days "$dir")" || return
    [ "$age" -ge 0 ] || return
    [ "$age" -le "$threshold" ] || return  # STALE側で既に報告済み
    if report_frontmatter "$latest" | grep -qE '^processed:[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]*$'; then
      log "  -> ✅ ${name}: 処理済みマーカーあり（$(basename "$latest" .md)）"
      return
    fi
    if [ "$age" -gt "$UNPROCESSED_REPORT_GRACE_DAYS" ]; then
      # 表示は日付のみではなくフルパス（本人がそのまま開けるように・2026-07-12追加）。
      item_drift "[${label}-UNPROCESSED] 最新の${name}（${latest}）が生成から${age}日経過してもリーダーに処理された形跡（frontmatterの processed: 行）がありません（目安 ${UNPROCESSED_REPORT_GRACE_DAYS} 日）。次回セッションで確認・処理してください。"
    else
      log "  -> ${name}: 未処理（生成から${age}日・目安${UNPROCESSED_REPORT_GRACE_DAYS}日以内は許容）"
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
log "総drift件数: ${TOTAL_DRIFT}"
echo "======================================================================"
