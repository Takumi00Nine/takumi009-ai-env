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
#      ai-env 本体（このリポジトリ自身）は「public化予定」のため対象外。
#      remote未設定はチェック対象外（情報表示のみ）。gh 不在・未認証・API失敗は
#      drift にはせず WARN 表示のみに留める（2026-07-08 adoption-critic指摘対応。
#      「必須指摘」＝private repoの意図しない公開化を検知する恒久対策）。
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
log "総drift件数: ${TOTAL_DRIFT}"
echo "======================================================================"
