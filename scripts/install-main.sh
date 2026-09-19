#!/usr/bin/env bash
# メイン環境用インストーラ: このリポジトリの claude/・codex/ 配下を
# ライブ位置（~/.claude/・~/.codex/）へ symlink する（dotfiles/install.sh と同方式）。
#
# 冪等（再実行安全）: 既存の「実ファイル」（symlinkでないもの）は初回だけ
# "<dest>.pre-aienv.bak" へ退避してから symlink に置き換える。バックアップは
# 既に存在すれば上書きしない（2回目以降の実行や、symlinkでなく実ファイルを
# 生成し続ける config.toml でも、初回のオリジナルだけを守り続ける）。
#
# 例外: codex/config.toml は symlink しない。plain TOML は（hooks.json の
# "command" 文字列と違い）シェル変数展開が行われないため、__AIENV_HOME__
# プレースホルダを実ホームパスへ置換した実ファイルとして生成する
# （詳細は codex/config.toml 冒頭のコメント参照）。
#
# 例外その2: claude/settings.json も symlink しない。理由は2つ: ① JSONもTOML
# 同様シェル変数展開されないため、"model"/"effortLevel" をローカル実体
# プロファイルの role.leader から解決した値へ置き換える必要がある。
# ② symlinkのままだと、セッション内で `/model` を実行した際にClaude Code自身が
# ユーザー設定ファイルの "model" フィールドを書き換える仕様があり、symlink先＝
# このリポジトリの claude/settings.json が直接書き換わる副作用があった。
# generate_settings_json() が python3 の json module でトップレベルの
# "model"/"effortLevel" キーへ代入した実ファイルを生成する（テンプレの
# __AIENV_MODEL__／__AIENV_EFFORT__ は置換対象の目印として残す）。値は機役割
# にも呼び出し経路（--sub-delegate）にも依存せず、role.leader からだけ決まる。
#
# 使い方:
#   scripts/install-main.sh                          # 実行（symlink化 / config.toml・settings.json生成）
#   scripts/install-main.sh --dry-run                # 置換計画だけ表示（何もしない）
#   scripts/install-main.sh --with-dotfiles          # 上記に加え、dotfiles（部品・下請け）も導入する
#   scripts/install-main.sh --check-profile          # ローカル実体プロファイルの resolve 結果を1行返す（副作用ゼロ）
#   scripts/install-main.sh --render-settings-json <path>
#                                                     # settings.json の生成物だけを <path> へ書いて終了（配置は行わない）
#
# --check-profile: resolver（claude/hooks/lib/profile_resolve.py resolve）の
# 結果行（OK/MINIMAL/PROFILE_NOT_FOUND 等・タブ区切り）を stdout の1行目に
# そのまま出し、resolver の終了コードで exit する。scripts/check-drift.sh ⑧が
# stdout 1行目を機械可読行として読む契約のため、案内ログは stdout へ出さない。
#
# --render-settings-json <path>（2026-09-19 着手順3・設計 §3.5）: check-drift ①-2
# の唯一の入力口。雛形配置・symlink化・config.toml生成・dotfiles には一切進まず、
# resolver→動的Bedrock許可キー→generate_settings_json() を <path> を dest に
# して1回だけ実行して exit する。読むものは実 profile／models.conf／bedrock.env
# だけ（インストール本番と同じ環境変数の既定値を同じように読む＝揃える処理は
# 不要）。resolver 失敗・テンプレ欠落・python3 不在は非0で終了し stdout へは
# 何も出さない。
#
# --sub-delegate（内部専用・install-sub.sh がこのスクリプトへ委譲する際に付ける
# 目印）: 受理するが settings.json の値には影響しない。
#
# --with-dotfiles（既定OFF・明示オプション時のみ）: $HOME/work/dotfiles が無ければ
# `git clone` し、その後 dotfiles/install.sh を呼ぶ（既に存在する場合は clone を
# skipして install.sh だけ呼ぶ＝dotfiles側のinstall.shは再実行しても安全な設計）。
#
# 機役割（配役表の `machine_role`）: 本スクリプトは既存の実体プロファイルの
# 内容を一切書き換えない（実体を編集するのは本人だけ）。実体が無いときだけ、
# 雛形配置ブロック（後述）が config/profile.md.sample から新規に作成する。
# リーダー配役（role.leader）が未確定・解決不能なら settings.json は生成せず
# 非0で終了する（対話で確定させる経路と既定モデルへの縮退は 2026-09-19 に
# 退役した＝profile.md を直接編集して再実行する）。
#
# python3 requirement (moved from README "Setup" 2026-09-19): `install-main.sh` requires `python3` (used to generate `claude/settings.json`; also required separately by `check-drift.sh`'s `config.toml`/`settings.json` comparisons). macOS normally ships one via Xcode Command Line Tools, so this usually isn't an issue — if it's missing, `install-main.sh` fails fast at startup with a clear message (run `xcode-select --install`).
# Language runtimes including Python itself aren't managed via brew in this environment (see `anyenv-runtime-management` in the Vault), so it's intentionally not listed in the Brewfile.
#
# Role definitions (moved from README "About vault-public/" 2026-09-19, verbatim): Role definitions (`~/.claude/agents/<role>.md`, one per role under `claude/agents/*.md` in the repo) are symlinks straight into the repo, like the other symlinked destinations above — there is no per-role frontmatter generation.
#
# config/*.sample (moved from README "Main environment" 2026-09-19): `config/*.sample` is the source for these three local config files' real values. `config/profile.md.sample` and `config/models.conf.sample` ship with the real values used on the maintainer's main machine, so a fresh main machine can copy them as-is; a sub machine should copy them too and then edit at least `machine_role` (and, if it plays a different leader role, `role.leader`).
# `config/bedrock.env.sample` (→ `~/.config/takumi009-ai-env/bedrock.env`, permission 0600) is only for machines that actually use Bedrock — don't place it on a subscription-only machine; there is no auto-copy for it, you always copy it yourself. `config/models.conf.sample` likewise has no auto-copy — copy it yourself.
# `config/profile.md.sample` is different: if `~/.config/takumi009-ai-env/profile.md` doesn't exist yet, `install-main.sh` automatically copies `config/profile.md.sample` there for you the first time it runs (an existing skeleton-placement step from before `config/*.sample` existed; it never overwrites a profile that's already there). Copying it yourself beforehand has the same effect — either way you end up with this machine's real values, not a placeholder.
#
# 注意: インストール系スクリプトはユーザーが内容を確認したうえで実行する（自動実行しない）。
#       本スクリプトは既存の実ファイルをsymlinkへ置き換えるため、ユーザー本人が
#       立ち会って実行すること。

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${DOTFILES_DIR:=$HOME/work/dotfiles}"
: "${DOTFILES_REPO_URL:=https://github.com/Takumi00Nine/dotfiles}"
# テスト専用: "1" にすると launchctl への実操作だけを skip する（scripts/install-sub.sh
# と同じ考え方・同じ変数名。実launchd＝gui/$(id -u) はHOMEを差し替えても隔離
# できないため、テストで誤って実システムのlaunchdへ登録する事故を防ぐ。本番は
# 常に既定値=0のまま）。
: "${SKIP_LAUNCHCTL:=0}"
# ローカル実体プロファイルの配置先（claude/hooks/bootstrap-vault.sh と同じ
# 環境変数名・既定値。実体は機ごとのローカル・repo管理外。推奨経路は repo の
# config/profile.md.sample を手でコピーして作ること。実体が無いときだけ後述の
# 「雛形配置」ブロックが同サンプルをコピーする＝既存は上書きしない）。
: "${AIENV_LOCAL_PROFILE_PATH:=$HOME/.config/takumi009-ai-env/profile.md}"
# Bedrock最小セット: ピン留めの実値（推論プロファイルID・リージョン・
# CLAUDE_CODE_USE_BEDROCK等）の正本となるマシンローカルenvファイル。AWSの
# 認証情報そのもの（AWS_ACCESS_KEY_ID等）はここに置かない（専用の資格情報
# 機構のまま）。存在しない（Bedrock未導入機）場合は何もしない。
: "${AIENV_BEDROCK_ENV_FILE:=$HOME/.config/takumi009-ai-env/bedrock.env}"
# 共有lib（claude/hooks/lib/profile_resolve.py）とコア職種マニフェスト
# （claude/agents/）の場所。bootstrap-vault.shと同じ「自身の実体パスから
# 同梱libを解決する」方式。
: "${AIENV_PROFILE_RESOLVE_LIB:=$DIR/claude/hooks/lib/profile_resolve.py}"
: "${AIENV_AGENTS_DIR:=$DIR/claude/agents}"
# Bedrock env ファイルから settings.json の "env" ブロックへ取り込んでよい
# キーの許可リスト（2026-08-25 Codex一次レビュー指摘・Major対応: 当初は
# テンプレと衝突しないキーを無条件で取り込んでいたため、誤ってAWS認証情報
# （AWS_ACCESS_KEY_ID等）を書いてしまうと settings.json 経由で複製・露出する
# 穴があった）。許可するのは「どのモデルを指すか」の値だけで、AWSへの
# 認証情報は対象外（専用の資格情報機構のまま＝絶対厳守③）。
# ⚠️ この配列を唯一の値表とする——check-drift.sh は自前でこの一覧を複製せず、
# check-drift ①-2 は `--render-settings-json` の生成物と diff する
# （2026-08-30 工程横断レビュー指摘・MAJOR-5対応。§9.0 A-0-1の
# 「値出力口の一本化」と同じ設計思想の横展開＝値表を3箇所に増やさない）。
# 2026-09-01 配役表解凍 §4.2-d 改訂: 固定で許可するのは以下2キーだけへ縮小。
# 旧版はANTHROPIC_DEFAULT_OPUS/SONNET/HAIKU_MODELも無条件固定で許可していたが、
# それらは「プロファイルのrole.*が参照する定義名の実効providerが
# bedrockで、実際にその別名を使っているときだけ」動的に許可する側へ移した
# （compute_allowed_bedrock_env_keys()参照。2026-09-08モデル定義ファイルと
# 候補指定対応でproviderは役割の行自身ではなくモデル定義ファイル側の属性に
# なった＝list-rolesの解決結果を見る）。名前だけ許可リストのパターンに合う
# 任意キーへ秘密値を入れる穴を、人がピン留めの論理名を書けない設計と
# 組み合わせて塞ぐ（迂回もできない）。
AIENV_ALLOWED_BEDROCK_ENV_KEYS=(
  "CLAUDE_CODE_USE_BEDROCK"
  "AWS_REGION"
)

# compute_allowed_bedrock_env_keys — 固定2キー＋動的キーの和集合を1行1キーで
# 標準出力へ書く（2026-09-01 §4.2-d）。動的キー＝ローカル実体プロファイルの
# role.*の候補が参照するモデル定義（configured/unavailableの
# どちらも意図を残す設計＝V8-aに合わせ両方見る）のうちproviderがbedrockの
# ものがあれば、その model 別名を共有libのlist-rolesサブコマンドへ渡して
# bedrock_pin_<別名>のenvキー名を導出したものの重複排除。list-rolesは
# 自己完結（存在確認・symlink拒否・preflight・全validatorをlib側が内部で
# 行う契約＝担当A確定）。
#
# 戻り値の契約（2026-09-01 Codex差分レビュー・MAJOR対応で明確化）:
#   exit 0: 成功。動的キー0件（プロファイルが無い＝PROFILE_NOT_FOUND）は
#           「Bedrock役職を使っていない」ことの正しい表現であり失敗ではない。
#   exit 1: 算出そのものに失敗（mktemp失敗・実体がv2として妥当なのに
#           list-rolesが予期せず失敗・bedrock-pin-varの解決失敗）。標準出力
#           へは何も書かず、標準エラーへ理由を1行書く。「算出不能」と
#           「Bedrock役職が存在しない」を呼び出し側が区別できるようにする
#           （--print-bedrock-env-jsonがupdate-sub.sh/check-drift.shの唯一の
#           値出力口である以上、動的pinが欠けた不完全な集合をexit 0で返さない）。
compute_allowed_bedrock_env_keys() {
  local path="$AIENV_LOCAL_PROFILE_PATH" lib="$AIENV_PROFILE_RESOLVE_LIB"
  local fixed=("CLAUDE_CODE_USE_BEDROCK" "AWS_REGION")
  local dynamic=() alias var

  if [ -f "$lib" ]; then
    # ⚠️ list-rolesの終了コードをprocess substitution経由のwhileループでは
    # 直接拾えない。一時ファイルへ出力してから終了コードを明示的に確認する。
    local rows_tmp rows_rc=0 rows_err
    rows_tmp="$(mktemp 2>/dev/null)" || {
      printf 'BEDROCK_KEYS_COMPUTE_ERROR\t一時ファイルを作成できません\n' >&2
      return 1
    }
    rows_err="$(python3 "$lib" list-roles "$path" 2>&1 1>"$rows_tmp")" || rows_rc=$?
    if [ "$rows_rc" -eq 0 ]; then
      while IFS= read -r alias; do
        [ -z "$alias" ] && continue
        if ! var="$(python3 "$lib" bedrock-pin-var "$alias" 2>/dev/null)"; then
          rm -f "$rows_tmp"
          printf 'BEDROCK_KEYS_COMPUTE_ERROR\tbedrock-pin-varが失敗しました\n' >&2
          return 1
        fi
        [ -z "$var" ] && continue
        dynamic+=("$var")
      done < <(awk -F'\t' '($2=="configured"||$2=="unavailable") && $4=="bedrock" {print $5}' "$rows_tmp" | sort -u)
    else
      case "$rows_err" in
        PROFILE_NOT_FOUND*)
          # 実体なしはBedrock役職の入力元(role.*行)自体が無い正常な状態。
          # 動的キー0件が正しい結果であり失敗ではない。
          :
          ;;
        *)
          # PROFILE_INVALID:*（旧版=T4-LEGACYを含む）・PROFILE_UNREADABLE等＝
          # 実体はあるがv2として妥当でない、または想定外の失敗。「算出不能」を
          # 「Bedrock役職なし」と区別するため非0で返す。
          rm -f "$rows_tmp"
          printf 'BEDROCK_KEYS_COMPUTE_ERROR\t%s\n' "${rows_err%%$'\n'*}" >&2
          return 1
          ;;
      esac
    fi
    rm -f "$rows_tmp"
  fi

  local seen=" " out=() k
  # ⚠️ bash 3.2（macOS既定）は空配列を`"${arr[@]}"`で展開すると`set -u`下で
  # unbound variableになる（bash 4.4+では修正済みの既知の相違）。
  # `"${arr[@]:-}"`（scripts/lib/pid-lock.shの`_PID_LOCK_ACQUIRED_FILES`と
  # 同じ回避策）で空配列でも安全に展開する。
  for k in "${fixed[@]:-}" "${dynamic[@]:-}"; do
    [ -z "$k" ] && continue
    case "$seen" in *" $k "*) continue ;; esac
    seen="$seen$k "
    out+=("$k")
  done
  printf '%s\n' "${out[@]:-}"
  return 0
}

# bedrock_env_file_kind <path> — Bedrock envファイルの種別を1行で標準出力へ
# 印字する: ABSENT（本当に存在しない＝ENOENT）／UNAVAILABLE（通常ファイル以外
# ＝ディレクトリ・dangling symlink・親ディレクトリの探索権限不足等でlstat自体
# が失敗する場合を含む）／OK（読める可能性のある通常ファイル）。
# ⚠️ シェルの `[ -e ]`/`[ -L ]` だけに頼らずPythonの例外種別で判定する
# （2026-08-30 Codex四次レビュー指摘・MAJOR対応: `[ -e path ]`は親ディレクトリの
# 探索権限が無いだけでも偽になり、「本当に存在しない」場合と区別できない。
# これを呼び出し側がABSENTと誤認すると、実際には存在する設定ファイルを
# 空payloadで上書きしてしまう。os.lstat()でFileNotFoundError〈ENOENT〉のみを
# ABSENTとし、それ以外の全OSError〈権限不足等〉はUNAVAILABLE側へ安全側に倒す）。
bedrock_env_file_kind() {
  python3 -c "
import os, stat, sys
path = sys.argv[1]
try:
    st = os.lstat(path)
except FileNotFoundError:
    print('ABSENT')
    sys.exit(0)
except OSError:
    print('UNAVAILABLE')
    sys.exit(0)
if stat.S_ISLNK(st.st_mode):
    try:
        st = os.stat(path)
    except OSError:
        print('UNAVAILABLE')
        sys.exit(0)
print('OK' if stat.S_ISREG(st.st_mode) else 'UNAVAILABLE')
" "$1"
}

# compute_bedrock_env_json [bedrock-env-file] — Bedrock envファイルを解析し、
# 構造化されたJSONオブジェクトを標準出力へ1行で書く:
#   {"env": {"CLAUDE_CODE_USE_BEDROCK": "1", ...},
#    "rejected_keys": ["AWS_ACCESS_KEY_ID", ...],
#    "malformed_lines": ["3", ...]}
# `env`＝上記許可リストに載っているキーだけの値。`rejected_keys`＝ファイルには
# あったが許可リスト外だったキー名（値は含まない＝絶対厳守③）。
# `malformed_lines`＝`KEY=VALUE`として解析できなかった行番号。
# ⚠️ これがBedrock envファイルの**唯一の解析経路**である（2026-08-30
# 工程横断レビュー指摘・MAJOR-A対応: 従来はinstall-main.shのgenerate_
# settings_json()とupdate-sub.shがそれぞれ独自にファイルを読み・許可リストで
# filterする処理を複製しており、値表こそ共有していたが解析ロジック自体が
# 2箇所に分岐していた。以後は両方ともこの関数（またはこの関数を呼ぶ
# --print-bedrock-env-json）の出力だけを使い、生ファイルを直接readしない）。
# ⚠️ 「ファイルが存在しない」（正常＝Bedrock未導入機）場合だけ
# {"env": {}, "rejected_keys": [], "malformed_lines": []}をexit 0で返す。
# ファイルが存在するのに読めない・解析に失敗した場合はfail-openで空扱いに
# せず非0終了する（2026-08-30 Codex二次レビュー指摘・Major対応: 従来は
# `|| echo '{}'`で読取失敗等のあらゆる異常を「Bedrock未導入」と同じ扱いに
# してしまい、check-drift.sh側が「監視できていないのに一致」と誤判定する
# 経路になっていた）。パーミッションの矯正（chmod 600）はここでは行わない
# （読み取り専用の判定。矯正は呼び出し側＝generate_settings_json()・
# update-sub.shの責務のまま）。
compute_bedrock_env_json() {
  local bedrock_env_file="${1:-}" allowed_joined
  allowed_joined="$(printf '%s\x1f' "${AIENV_ALLOWED_BEDROCK_ENV_KEYS[@]}")"
  # bedrock_env_file_kind()での判定＝ABSENT(ENOENT)だけを「未導入」として
  # 空payload・exit0にする。UNAVAILABLE（権限不足・ディレクトリ等）は
  # そのまま下のpython3実行へ進ませ、実際のopen()失敗（非0終了）として
  # 呼び出し側へ伝播させる（2026-08-30 Codex四次レビュー指摘・MAJOR対応）。
  if [ -z "$bedrock_env_file" ] || [ "$(bedrock_env_file_kind "$bedrock_env_file")" = "ABSENT" ]; then
    echo '{"env": {}, "rejected_keys": [], "malformed_lines": []}'
    return 0
  fi
  python3 -c "
import json, sys
allowed = set(k for k in sys.argv[2].split(chr(0x1f)) if k)
path = sys.argv[1]
env, rejected, malformed = {}, [], []
with open(path) as f:
    for lineno, raw in enumerate(f, start=1):
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        if '=' not in line:
            malformed.append(str(lineno))
            continue
        k, v = line.split('=', 1)
        k, v = k.strip(), v.strip()
        if not k:
            malformed.append(str(lineno))
            continue
        if k not in allowed:
            rejected.append(k)
            continue
        env[k] = v
print(json.dumps({'env': env, 'rejected_keys': rejected, 'malformed_lines': malformed}))
" "$bedrock_env_file" "$allowed_joined"
}

log() { echo "[install-main] $*"; }
warn() { echo "[install-main] WARN: $*" >&2; }
fail() { echo "[install-main] FAIL: $*" >&2; exit 1; }

# install-main.sh の link()（下記）が使う sync_managed_symlink()を読み込む
# （update-sub は install-sub 経由でこの link() を呼ぶ＝直接配置はしない。
# 検証4巡目 BLOCKING-1対応・2026-09-14。詳細はscripts/lib/managed-symlink.sh
# 側のコメント参照）。
# 2026-09-17検証1巡目差し戻し MINOR-1対応: 従来はbareな`source`のみで、
# lib欠落・構文破損時にrc=127（関数未定義）のまま後段の`|| warn`に
# 飲み込まれ得た（MAJOR-1と合流して「配置しました」報告のまま静かに壊れる）。
# install-main.sh の link() が使う（update-sub は install-sub 経由）ため、
# 3段のガード（-r・bash -n・declare -F）はここにだけ置く。
if [ ! -r "$DIR/scripts/lib/managed-symlink.sh" ]; then
  fail "共有ライブラリが読み取れません（checkout破損の可能性）: $DIR/scripts/lib/managed-symlink.sh"
fi
if ! /bin/bash -n "$DIR/scripts/lib/managed-symlink.sh" 2>/dev/null; then
  fail "共有ライブラリの構文が不正です（checkout破損の可能性）: $DIR/scripts/lib/managed-symlink.sh"
fi
# shellcheck source=scripts/lib/managed-symlink.sh
source "$DIR/scripts/lib/managed-symlink.sh"
for _managed_symlink_fn in sync_managed_symlink; do
  if ! declare -F "$_managed_symlink_fn" >/dev/null 2>&1; then
    fail "共有ライブラリの読み込みに失敗しました（${_managed_symlink_fn}()が定義されていません）: $DIR/scripts/lib/managed-symlink.sh"
  fi
done
unset _managed_symlink_fn

# fail_settings_generation <message> — settings.json生成に関連する失敗経路
# （S2/S3・S5・S6・S7）専用のfail()ラッパー。設計書§6.2-B S8「生成物が
# 存在しない状態でS2〜S7またはS18」は、deferred非0で処理を続けるS4・S18
# だけでなく即時fail()で終わるS2/S3・S5・S6・S7でも、最終的な終了理由へ
# 機械可読トークンNO_GENERATED_FILEを含めることを要求している（2026-09-01
# 工程横断レビュー指摘・MINOR-2対応。旧実装はスクリプト末尾のdeferred経路
# だけにこのトークンを付けており、即時fail()する経路には付いていなかった）。
# この時点で settings.json が一度も生成されていなければ（＝真の初回
# インストール等）トークンを付加してから通常のfail()（即時exit 1）へ渡す。
# 既存ファイルを保持したまま失敗した場合（旧ファイルが在るとき）はトークンを
# 付けない——「保持」と「欠落」は設計上区別する（§6.2-B S8）。
fail_settings_generation() {
  local msg="$1"
  if [ ! -e "$HOME/.claude/settings.json" ]; then
    msg="${msg}（NO_GENERATED_FILE: settings.jsonが一度も生成されていません）"
  fi
  fail "$msg"
}

# サンプル雛形の実位置（後段のstep①「雛形配置」ブロックで使う。
# 2026-09-08 本人裁定A案で読み元をrepoのconfig/profile.md.sampleへ付け替えた
# ＝生ファイルなのでYAMLフェンス抽出は不要（extract_profile_schema_block()は
# 撤去した。旧・§3.9 Q2の候補抽出は2026-09-08 モデル定義ファイルと候補指定
# 対応でsample_model_candidates()ごと既に廃止済みのためこの変数を使わない）。
PROFILE_SAMPLE_SRC="$DIR/config/profile.md.sample"

# ============================================================
# リーダー実行値の解決と検査口
# ============================================================

# resolve_leader_runtime — 実効リーダー候補のmodel/effortを1行JSON
# （例 {"model": "claude-opus-5", "effort": "high"}）で標準出力へ書く。
# `resolve-leader`は自己完結（存在確認・symlink拒否・preflight・全validatorを
# lib内部で行う契約）なので、ここでは事前チェックを重複させない。失敗時は
# 標準出力へ1文字も出さず、libの標準エラー（`<機械可読コード>\t<理由>`・値を
# 含まない）をそのまま流してreturn 1。実体が無い（PROFILE_NOT_FOUND）場合も
# 失敗として扱う（旧・既定モデルへのlegacy委譲は2026-09-19に退役）。
resolve_leader_runtime() {
  local path="$AIENV_LOCAL_PROFILE_PATH" lib="$AIENV_PROFILE_RESOLVE_LIB" out
  if [ ! -f "$lib" ]; then
    printf 'PROFILE_RESOLVER_MISSING\tresolver本体が見つかりません\n' >&2
    return 1
  fi
  if out="$(python3 "$lib" resolve-leader "$path" \
        --bedrock-env "$AIENV_BEDROCK_ENV_FILE" --agents-dir "$AIENV_AGENTS_DIR")"; then
    printf '%s\n' "$out"
    return 0
  fi
  return 1
}

# check_profile_cmd — --check-profile。resolver の `resolve` 結果行を stdout の
# 1行目にそのまま出し、その終了コードで exit する（副作用ゼロ）。
# ⚠️ stdout 1行目＝機械可読行の契約（scripts/check-drift.sh ⑧ が head -1 を
# タブ分割で判定する）。案内ログを stdout に足さない。
check_profile_cmd() {
  local path="$AIENV_LOCAL_PROFILE_PATH" lib="$AIENV_PROFILE_RESOLVE_LIB" rc=0
  command -v python3 >/dev/null 2>&1 || fail "python3 が見つかりません（--check-profile の実行に必要です）"
  [ -f "$lib" ] || fail "resolver本体（${lib}）が見つかりません"
  python3 "$lib" resolve "$path" --bedrock-env "$AIENV_BEDROCK_ENV_FILE" --agents-dir "$AIENV_AGENTS_DIR" || rc=$?
  exit "$rc"
}

# AIENV_DEFERRED_EXIT_CODE — 「settings.json以外の処理は続行させたいが、最終的な
# 終了コードは非0にする必要がある」状態（bedrock.envが実在するのに読めない／
# 動的Bedrock許可キーの算出失敗／職種定義のdangling）を記録し、スクリプト
# 末尾で最終exit codeへ反映する（他の処理を中断させない・値を再掲しないWARNは
# 各所で既に出している前提）。
AIENV_DEFERRED_EXIT_CODE=0
DRY_RUN=0
WITH_DOTFILES=0
# --sub-delegate は受理するだけ（install-sub.sh 経由の目印。settings.json の
# 値の出し分けには使わない）。
IS_SUB_DELEGATE=0
CHECK_PROFILE=0
RENDER_SETTINGS_JSON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --with-dotfiles) WITH_DOTFILES=1 ;;
    --sub-delegate) IS_SUB_DELEGATE=1 ;;
    --check-profile) CHECK_PROFILE=1 ;;
    --render-settings-json)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "--render-settings-json には出力先パスが必要です" >&2
        exit 1
      fi
      RENDER_SETTINGS_JSON="$2"
      shift
      ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

# --check-profile: 副作用ゼロの検査口。check_profile_cmd()が自身でexitする。
if [ "$CHECK_PROFILE" = "1" ]; then
  check_profile_cmd
fi

# python3依存の早期チェック: generate_settings_json()がclaude/settings.json生成に
# python3のjson moduleを必須で使う。マーカー書込・symlink化等の実処理が始まって
# から中途半端な状態でpython3不在に気付くより、着手前に明確な指示を出す。
# --dry-run は実際には何も生成しない＝python3を必要としないため対象外。
if [ "$DRY_RUN" != "1" ]; then
  command -v python3 >/dev/null 2>&1 || fail_settings_generation "python3 が見つかりません（claude/settings.json の生成に必要です）。Xcode Command Line Tools（xcode-select --install）等でpython3を導入してから再実行してください。"
fi
# バックアップは「.pre-aienv.bak がまだ無いときだけ」作る（何度実行しても
# 常にインストール前オリジナルを保持する。symlink化後は dest が symlink に
# なるため自然と対象外になるが、generate_config_toml() のように毎回実ファイルを
# 書く経路ではこのガードが無いと2回目の実行でオリジナルが消える）。
# ⚠️ symlink化する経路（link()）は、既存backupと内容が異なる通常ファイルへの
# 対応（衝突しない追加backupへの保存）が別途必要なため、この単純な
# backup_once()ではなく scripts/lib/managed-symlink.sh の
# sync_managed_symlink() を使う（検証3巡目 BLOCKING-1・検証4巡目 BLOCKING-1
# 対応。generate_config_toml()・generate_settings_json()は意図的に毎回内容が変わる正規の再生成・書換
# 経路であり、この単純なbackup_once()のままでよい＝最初の1回だけ保持）。
backup_once() {
  local dest="$1"
  # ⚠️ `cp`失敗を明示的にreturn 1へ変換する（2026-09-01工程横断レビュー
  # 指摘・MAJOR対応: 呼び出し側で`backup_once "$dest" || fail_settings_
  # generation ...`のように`||`の左辺として呼ぶと、bashの仕様上この関数の
  # 実行全体でset -eが無効化される〈関数呼び出しが&&/||リストの一部の
  # ときは、その関数本体の中の失敗コマンドも即時終了を起こさない〉。
  # `cp`が失敗しても暗黙のset -eには頼らず、この関数自身が`return 1`する
  # ことで、`log "backed up: ..."`が実行されない＝実際には失敗している
  # のに成功したかのようなログが出る事故を防ぐ）。
  if [ -e "$dest" ] && [ ! -L "$dest" ] && [ ! -e "$dest.pre-aienv.bak" ]; then
    if ! cp "$dest" "$dest.pre-aienv.bak"; then
      return 1
    fi
    log "backed up: $dest -> $dest.pre-aienv.bak"
  fi
}

# would_backup <dest> [--additional-on-diff] — dry-run表示用。第2引数無しは
# backup_once()相当（.pre-aienv.bakがまだ無いかだけを見る）、
# --additional-on-diff指定時はsync_managed_symlink()相当（既存backupと内容が
# 異なるかも見る）の判定を、書き込みなしで再現する。link()のdry-run分岐だけが
# 後者を使う。
would_backup() {
  local dest="$1" mode="${2:-}"
  [ -e "$dest" ] && [ ! -L "$dest" ] || return 1
  if [ ! -e "$dest.pre-aienv.bak" ]; then
    return 0
  fi
  [ "$mode" = "--additional-on-diff" ] && ! cmp -s "$dest" "$dest.pre-aienv.bak"
}

# link <repo-relative-source> <destination>
# dotfiles/install.sh の link() と同方式。実際の退避＋symlink化は
# scripts/lib/managed-symlink.sh の sync_managed_symlink() へ委譲する
# （install-main.sh の link() が使う＝update-sub は install-sub 経由。
# 検証4巡目 BLOCKING-1対応。同ファイルのコメント参照）。
# source が無い場合は「このリポジトリの必須構成が壊れている」ことを意味するため
# skip扱いにせず fail する（Codexレビュー指摘・Minor：黙って進むと壊れた
# checkoutでも "done" と表示されてしまう）。
link() {
  local src="$DIR/$1" dest="$2"
  [ -e "$src" ] || fail "リポジトリのファイルが見つかりません（checkout破損の可能性）: $src"
  if [ "$DRY_RUN" = "1" ]; then
    if would_backup "$dest" --additional-on-diff; then
      if [ -e "$dest.pre-aienv.bak" ]; then
        log "[dry-run] would back up (既存の.pre-aienv.bakと内容が異なる通常ファイルのため追加保存): $dest -> $dest.pre-aienv.bak.<timestamp>"
      else
        log "[dry-run] would back up: $dest -> $dest.pre-aienv.bak"
      fi
    fi
    log "[dry-run] would link: $dest -> $src"
    return
  fi
  sync_managed_symlink "$src" "$dest" "install-main"
}

# generate_config_toml <repo-relative-source> <destination>
# symlink ではなく「プレースホルダ置換した実ファイル」を配置する
# （config.toml は plain TOML でシェル変数展開されないため）。
# 置換は sed のメタ文字（& \ その他区切り文字）を $HOME 側でエスケープしてから行い、
# 生成は mktemp への書き込み→mv で原子的に行う（Codexレビュー指摘・Minor：
# $HOME に & や \ が含まれる環境での置換破損、書き込み中断時の破損を防ぐ）。
generate_config_toml() {
  local src="$DIR/$1" dest="$2" escaped_home tmp
  [ -e "$src" ] || fail "リポジトリのファイルが見つかりません（checkout破損の可能性）: $src"
  if [ "$DRY_RUN" = "1" ]; then
    would_backup "$dest" && log "[dry-run] would back up: $dest -> $dest.pre-aienv.bak"
    log "[dry-run] would generate (not symlink): $dest <- $src （__AIENV_HOME__ を $HOME へ置換）"
    return
  fi
  mkdir -p "$(dirname "$dest")"
  backup_once "$dest"
  escaped_home=$(printf '%s' "$HOME" | sed -e 's/[&\]/\\&/g' -e 's/#/\\#/g')
  # dest と同じディレクトリに一時ファイルを作る（mv が同一ファイルシステム内の
  # atomic rename になることを保証するため。$TMPDIR が別ボリュームだと
  # atomicにならない可能性があるとのCodexレビュー指摘・Nit）。異常終了時は
  # trap で後始末する。
  tmp="$(mktemp "$(dirname "$dest")/.$(basename "$dest").aienv-tmp.XXXXXX")"
  trap 'rm -f "$tmp"' RETURN
  sed "s#__AIENV_HOME__#${escaped_home}#g" "$src" > "$tmp"
  mv "$tmp" "$dest"
  log "generated: $dest <- $src （__AIENV_HOME__ を $HOME へ置換）"
}

# generate_settings_json <repo-relative-source> <destination> <model-value> [bedrock-env-file]
# claude/settings.json も config.toml と同じ理由（JSONはシェル変数展開されない・
# symlinkだとClaude Code自身の `/model` 書込がリポジトリ側ファイルへ直接及んでしまう）
# で symlink ではなく実ファイルとして生成する。ただし置換方式は config.toml の
# sedプレースホルダ置換とは異なりpython3のjson moduleでトップレベル"model"キーへ
# 直接代入する（Codex一次レビュー指摘・Minor対応: sedのメタ文字エスケープは
# `&`・`\`・sed区切り文字のみを想定しており、JSON側の引用符・バックスラッシュ
# エスケープには対応していない＝環境変数上書き値に`"`や`\`が含まれると不正JSONを
# 生成しうる欠陥があった。json moduleでの直接代入ならエスケープ処理自体が不要で
# 構造的に安全）。テンプレの"model"値（__AIENV_MODEL__）は置換対象の目印・
# ドキュメントとして残すのみで、実際の置換はテキストマッチではなくキー代入で行う
# （scripts/check-drift.sh の①-2はテンプレの__AIENV_MODEL__を期待値へ文字列置換して
# 比較するため、テンプレ側のプレースホルダ表記自体は維持すること）。
# Bedrock env取り込みの許可リスト（AIENV_ALLOWED_BEDROCK_ENV_KEYS）は
# スクリプト冒頭（引数解析より前）で既に宣言済み——ここでは再宣言しない
# （値表を複数箇所に増やさないため。2026-08-30 工程横断レビュー指摘・MAJOR-5
# 対応で、宣言をこの関数より前へ移動した）。
# 4番目の引数（bedrock-env-file）は2026-08-30 §9.0 A-1-4追加: 存在すれば
# KEY=VALUE形式で読み、上記許可リストに載っていて、かつテンプレ由来のenvキー
# （DISABLE_AUTOUPDATER等）と衝突しないキーだけを"env"ブロックへ追加する
# （許可リスト外・衝突キーはいずれもスキップしキー名だけをログに残す。値は
# 一切出力しない＝絶対厳守③。§11.2「ピン留めの実値の置き場」の裁定どおり、
# 値そのものはテンプレにもpublicなプロファイルにも書かない）。ファイルが無い
# （Bedrock未導入機）場合は何もしない。
# 5番目の引数（effort）は2026-09-01 配役表解凍 §4.2-g追加: 実効リーダー候補の
# effortから"effortLevel"を生成する。空文字なら"effortLevel"キー自体を出力
# しない（未指定＝セッション/アカウント既定に従う。既定値を発明しない・§3.8）。
# テンプレの"effortLevel"値（__AIENV_EFFORT__）が目印のままであることも
# "model"と同じ理由で検証してから置換/削除する。
generate_settings_json() {
  local src="$DIR/$1" dest="$2" model="$3" bedrock_env_file="${4:-}" effort="${5:-}" tmp PY_ERR PY_OUT
  local bedrock_status bedrock_env_perm bedrock_payload bedrock_kind
  # ⚠️ テンプレ欠落（設計書S5）。fail_settings_generation()を使う（他の
  # link()・generate_config_toml()内の同文言はsettings.json以外のファイル
  # 用なので対象外＝そちらは変更しない）。
  [ -e "$src" ] || fail_settings_generation "リポジトリのファイルが見つかりません（checkout破損の可能性）: $src"
  # Bedrock envファイルの状態を3分類する（bedrock_env_file_kind()参照）:
  # ABSENT(未導入・正常)／EXISTS_BUT_UNAVAILABLE(存在するのに読めない・解析
  # できない)／OK。EXISTS_BUT_UNAVAILABLEの場合は「生成失敗時は旧ファイルを
  # 触らない」契約（設計書§11.2）を守るため、settings.json本体の生成ごと
  # 中止し既存ファイルを保持する（2026-08-30 Codex 3巡目差し戻し・MAJOR
  # 対応: 従来はパーミッション矯正失敗・compute_bedrock_env_json()の解析
  # 失敗のいずれも「Bedrock未導入」と同じ空payloadへ丸めた上でsettings.json
  # 本体の生成・mv上書きを続行しており、既存設定に書かれていたCLAUDE_CODE_
  # USE_BEDROCK・リージョン・モデルpin等が黙って消え得た）。
  # ⚠️ DRY_RUNでも（副作用の無い読み取り専用判定のため）この分類を行う
  # （2026-08-30 Codex四次レビュー指摘・Minor対応: 従来は`[ -f ]`だけの
  # dry-run独自判定で、実行時なら中止になるケース〈ディレクトリ・dangling
  # symlink等〉でも「settings.jsonを生成する」と誤った計画表示をしていた）。
  # ⚠️ この判定は mkdir/backup_once/mktemp より前に行う（Codex四次レビュー
  # 指摘・Minor対応: 中止するだけなのに`.pre-aienv.bak`や一時ファイルを
  # 新規作成してしまう副作用を避けるため）。
  # ⚠️ シェルの`[ -e ]`/`[ -L ]`だけに頼らずbedrock_env_file_kind()
  # （os.lstat()の例外種別で判定）を使う（2026-08-30 Codex四次レビュー
  # 指摘・MAJOR対応: `[ -e ]`は親ディレクトリの探索権限が無いだけでも偽に
  # なり、「本当に存在しない」場合と区別できない。dangling symlinkも同様に
  # 誤ってABSENT扱いされていた）。
  bedrock_status="ABSENT"
  if [ -n "$bedrock_env_file" ]; then
    bedrock_kind="$(bedrock_env_file_kind "$bedrock_env_file")"
  else
    bedrock_kind="ABSENT"
  fi
  if [ "$DRY_RUN" = "1" ]; then
    if [ "$bedrock_kind" = "UNAVAILABLE" ]; then
      # ⚠️ ここでは`would_backup`を表示しない（Codex五次レビュー指摘・Minor
      # 対応: UNAVAILABLE側は生成自体を中止するため`.pre-aienv.bak`も
      # 実際には作られない。dry-runの計画表示を実実行の分岐と一致させる）。
      log "[dry-run] Bedrock envファイルが読めない・解析できない見込みのため、settings.jsonの生成は中止され既存ファイルが保持される見込みです: $bedrock_env_file"
    else
      would_backup "$dest" && log "[dry-run] would back up: $dest -> $dest.pre-aienv.bak"
      log "[dry-run] would generate (not symlink): $dest <- $src (\"model\"/\"effortLevel\"を更新)"
      if [ "$bedrock_kind" = "OK" ]; then
        log "[dry-run] would merge env from: $bedrock_env_file"
      fi
    fi
    return
  fi
  if [ "$bedrock_kind" != "ABSENT" ]; then
    if [ "$bedrock_kind" = "UNAVAILABLE" ]; then
      warn "Bedrock envファイルのパスが通常ファイルではありません（ディレクトリ・dangling symlink・親ディレクトリの探索権限不足等の可能性）。settings.jsonの生成を中止し、既存ファイルを保持します: $bedrock_env_file"
      bedrock_status="EXISTS_BUT_UNAVAILABLE"
    else
      # Bedrock env ファイルは非公開の値（推論プロファイルID等）を持つため、
      # 読む前にパーミッションを0600へ揃える（既に0600ならno-op。絶対厳守③）。
      # ⚠️ 矯正に失敗した、または矯正後もちょうど600でない場合は
      # fail-openで読み進めない（Codex一次レビュー指摘・Major対応:
      # `chmod ... || true` だけだと読取専用FS・所有者不一致等で0644のまま
      # 残っても気付かず非公開値を取り込んでしまっていた）。
      chmod 600 "$bedrock_env_file" 2>/dev/null || true
      bedrock_env_perm="$(stat -f '%Lp' "$bedrock_env_file" 2>/dev/null || stat -c '%a' "$bedrock_env_file" 2>/dev/null || echo '')"
      if [ "$bedrock_env_perm" != "600" ]; then
        warn "Bedrock envファイルのパーミッションを0600へ揃えられませんでした（現在: ${bedrock_env_perm:-不明}）。settings.jsonの生成を中止し、既存ファイルを保持します: $bedrock_env_file"
        bedrock_status="EXISTS_BUT_UNAVAILABLE"
      else
        # Bedrock envファイルの解析は compute_bedrock_env_json() だけが行う
        # （2026-08-30 工程横断レビュー指摘・MAJOR-A対応: 以前はここで生
        # ファイルを直接読む処理を複製していた。update-sub.shは install-sub
        # 経由でこの関数を呼ぶ経路へ揃えた＝値表・解析ロジックとも複製箇所は増やさない）。
        if bedrock_payload="$(compute_bedrock_env_json "$bedrock_env_file")"; then
          bedrock_status="OK"
        else
          warn "Bedrock envファイルの解析に失敗しました。settings.jsonの生成を中止し、既存ファイルを保持します: $bedrock_env_file"
          bedrock_status="EXISTS_BUT_UNAVAILABLE"
        fi
      fi
    fi
  fi
  if [ "$bedrock_status" = "EXISTS_BUT_UNAVAILABLE" ]; then
    # ⚠️ ここは非0ではなく0で返す（2026-08-30 Codex四次レビュー指摘・
    # BLOCKING対応: 「既存settings.jsonを意図的に保持して中止した」のは
    # この関数の正常な仕事の一部であり、失敗ではない。非0で返すと呼び出し
    # 側で`|| true`のような一律の抑制が必要になり、mktemp/mv失敗等の本当の
    # 異常まで一緒に握り潰してしまう。呼び出し側は裸の関数呼び出しのまま
    # `set -e`を効かせ続けられるようにする）。
    # ⚠️ ただし設計書S4「bedrock.envが実在するのに読めない/解析できない場合
    # は非0終了」の要件があるため（2026-09-01 リーダー裁定・差し戻し対応:
    # 「不在」は非Bedrock機で常に起きる正常系なのでexit 0のまま維持するが、
    # 「実在するのに壊れている」を exit 0 のままにすると監視側〈check-drift〉
    # と非対称になる）、
    # AIENV_DEFERRED_EXIT_CODEを立てて他の処理（hooksのsymlink化等）は
    # そのまま続行させつつ、スクリプト末尾で最終的な終了コードへ反映する。
    AIENV_DEFERRED_EXIT_CODE=1
    return 0
  fi

  # ⚠️ 設計書S7（mktemp/mv/権限/容量の失敗）対応: 従来は裸呼び出しで`set -e`
  # 任せ（メッセージ無し・NO_GENERATED_FILE判定も無し）だったため、
  # fail_settings_generation()で明示的に捕捉する（2026-09-01工程横断
  # レビュー指摘・MINOR-2追加対応）。
  mkdir -p "$(dirname "$dest")" || fail_settings_generation "settings.jsonの配置先ディレクトリを作成できません: $(dirname "$dest")"
  backup_once "$dest" || fail_settings_generation "settings.jsonの既存バックアップ作成に失敗しました: $dest.pre-aienv.bak"
  tmp="$(mktemp "$(dirname "$dest")/.$(basename "$dest").aienv-tmp.XXXXXX")" || fail_settings_generation "settings.json生成用の一時ファイルを作成できません"
  trap 'rm -f "$tmp"' RETURN
  if [ "$bedrock_status" != "OK" ]; then
    bedrock_payload='{"env": {}, "rejected_keys": [], "malformed_lines": []}'
  fi
  # テンプレの"model"値が __AIENV_MODEL__ の目印のままであることを検証してから
  # 上書きする（Codex二次レビュー指摘・Minor対応: 検証無しに常時上書きすると、
  # 誰かがテンプレへ再び特定モデルをハードコードしてしまう回帰＝今回のタスクの
  # 発端そのもの＝が起きても、installは何も気付かず成功してしまう。fail()で
  # 早期に気付けるようにする）。
  if ! PY_OUT="$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
if not isinstance(data, dict) or data.get('model') != '__AIENV_MODEL__':
    got = data.get('model') if isinstance(data, dict) else type(data).__name__
    print('template \"model\" field is not the __AIENV_MODEL__ placeholder (got: ' + repr(got) + ')', file=sys.stderr)
    sys.exit(1)
if data.get('effortLevel') != '__AIENV_EFFORT__':
    got = data.get('effortLevel')
    print('template \"effortLevel\" field is not the __AIENV_EFFORT__ placeholder (got: ' + repr(got) + ')', file=sys.stderr)
    sys.exit(1)
data['model'] = sys.argv[3]
effort = sys.argv[5]
if effort:
    data['effortLevel'] = effort
else:
    data.pop('effortLevel', None)

payload = json.loads(sys.argv[4])
template_env_keys = set((data.get('env') or {}).keys())
skipped = []
if payload.get('env'):
    data.setdefault('env', {})
    for k, v in payload['env'].items():
        if k in template_env_keys:
            skipped.append(k)
            continue
        data['env'][k] = v

with open(sys.argv[2], 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
if skipped:
    print('SKIPPED_ENV_KEYS:' + ','.join(skipped))
if payload.get('rejected_keys'):
    print('REJECTED_ENV_KEYS:' + ','.join(payload['rejected_keys']))
if payload.get('malformed_lines'):
    print('MALFORMED_ENV_LINES:' + ','.join(payload['malformed_lines']))
" "$src" "$tmp" "$model" "$bedrock_payload" "$effort" 2>&1)"; then
    fail_settings_generation "settings.json の生成に失敗しました（テンプレの検証またはpython3 json処理エラー。checkout破損・テンプレへの誤ったmodel値ハードコード・python3不在等の可能性）: $src${PY_OUT:+ (詳細: $PY_OUT)}"
  fi
  mv "$tmp" "$dest" || fail_settings_generation "settings.jsonの原子的な配置(mv)に失敗しました: $tmp -> $dest"
  # ⚠️ 値（model/effort）はログへ再掲しない（設計§6.2-B S1「ログは
  # `model updated`〈値を出さない〉」・値出力口の一本化。2026-09-01 Codex
  # 二次レビュー指摘・MAJOR対応）。値を確認したい場合は
  # `--render-settings-json`（生成物）を見る。
  log "generated: $dest <- $src (\"model\"/\"effortLevel\" updated)"
  while IFS= read -r py_out_line; do
    case "$py_out_line" in
      SKIPPED_ENV_KEYS:*)
        warn "Bedrock envファイルのキーがテンプレ側envと衝突したためスキップしました（キー名: ${py_out_line#SKIPPED_ENV_KEYS:}）: $bedrock_env_file"
        ;;
      REJECTED_ENV_KEYS:*)
        warn "Bedrock envファイルに許可リスト外のキーがあったため取り込みませんでした（キー名: ${py_out_line#REJECTED_ENV_KEYS:}・許可リスト: ${AIENV_ALLOWED_BEDROCK_ENV_KEYS[*]}）: $bedrock_env_file"
        ;;
      MALFORMED_ENV_LINES:*)
        warn "Bedrock envファイルに解析できない行がありました（行番号: ${py_out_line#MALFORMED_ENV_LINES:}）: $bedrock_env_file"
        ;;
    esac
  done <<EOF
$PY_OUT
EOF
}

# resolve_settings_inputs — settings.json 生成の入力を確定する:
#   AIENV_SETTINGS_MODEL／AIENV_SETTINGS_EFFORT＝resolve_leader_runtime() の
#   JSON から（解決できなければ fail_settings_generation で即時非0＝設計書S2）。
#   AIENV_ALLOWED_BEDROCK_ENV_KEYS＝固定2キー＋動的キー（compute_allowed_
#   bedrock_env_keys()）。算出に失敗した場合は fail-open で固定2キーへ縮退せず、
#   AIENV_SKIP_SETTINGS_GENERATION=1・AIENV_DEFERRED_EXIT_CODE=1 を立てる
#   （設計書§6.2-B S18＝生成をスキップして既存ファイルを保持し、他の処理は
#   完走させたうえで末尾で非0。「動的キー0件」という正常な結果〈exit 0契約〉
#   と「算出そのものの失敗」〈exit 1契約〉の区別を呼び出し側でも維持する）。
# インストール本番と --render-settings-json の両方がこの1つの関数だけを使う。
resolve_settings_inputs() {
  AIENV_SETTINGS_MODEL=""
  AIENV_SETTINGS_EFFORT=""
  AIENV_SKIP_SETTINGS_GENERATION=0
  local err_tmp json fields errline
  # ⚠️ 裸の代入のままだと、mktemp失敗時に`set -e`で即座に終了するが
  # fail_settings_generation()を経由しないためNO_GENERATED_FILEが付かない。
  err_tmp="$(mktemp)" || fail_settings_generation "リーダー実行値確認用の一時ファイルを作成できません"
  if json="$(resolve_leader_runtime 2>"$err_tmp")"; then
    rm -f "$err_tmp"
    # 2つのpython3呼び出しに分けず1回で両方抽出する。
    fields="$(printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d["model"])
print(d.get("effort", ""))
')" || fail_settings_generation "リーダー実行値のJSON解析に失敗しました（resolve-leaderの出力契約違反の可能性）"
    AIENV_SETTINGS_MODEL="$(printf '%s\n' "$fields" | sed -n '1p')"
    AIENV_SETTINGS_EFFORT="$(printf '%s\n' "$fields" | sed -n '2p')"
  else
    errline="$(head -1 "$err_tmp" 2>/dev/null)"
    rm -f "$err_tmp"
    # 「既存ファイルを保持します」は旧ファイルが実在するときだけ正しい表現。
    # 真の初回インストール等では保持ではなく欠落（NO_GENERATED_FILE）であり、
    # fail_settings_generation()がその区別を末尾へ付加する。
    fail_settings_generation "リーダー実行値を解決できませんでした（${errline:-不明なエラー}）。settings.jsonの生成を中止します。"
  fi

  AIENV_ALLOWED_BEDROCK_ENV_KEYS=("CLAUDE_CODE_USE_BEDROCK" "AWS_REGION")
  local keys_tmp keys_rc=0 keys_err key
  keys_tmp="$(mktemp 2>/dev/null)" || keys_tmp=""
  if [ -z "$keys_tmp" ]; then
    warn "動的Bedrock許可キーの算出に失敗しました（一時ファイルを作成できません）。settings.jsonの生成をスキップし、既存ファイルを保持します。"
    AIENV_SKIP_SETTINGS_GENERATION=1
    AIENV_DEFERRED_EXIT_CODE=1
    return 0
  fi
  keys_err="$(compute_allowed_bedrock_env_keys 2>&1 1>"$keys_tmp")" || keys_rc=$?
  if [ "$keys_rc" -eq 0 ]; then
    AIENV_ALLOWED_BEDROCK_ENV_KEYS=()
    while IFS= read -r key; do
      [ -n "$key" ] && AIENV_ALLOWED_BEDROCK_ENV_KEYS+=("$key")
    done < "$keys_tmp"
  else
    warn "動的Bedrock許可キーの算出に失敗しました（${keys_err:-不明なエラー}）。settings.jsonの生成をスキップし、既存ファイルを保持します。"
    AIENV_SKIP_SETTINGS_GENERATION=1
    AIENV_DEFERRED_EXIT_CODE=1
  fi
  rm -f "$keys_tmp"
}

# --- --render-settings-json <path>: 生成物だけを書いて終了する（check-drift ①-2 の入力口）---
# 雛形配置・symlink化・config.toml・dotfiles には進まない。<path> は呼び出し側が
# 用意した一時ディレクトリ内を想定（backup_once は dest 不在で no-op・mktemp/mv
# も <path> と同じディレクトリ）。実 $HOME/.claude 配下には何も作らない。
# 既知の残余＝bedrock env ファイルが実在する機では generate_settings_json() の
# chmod 600（冪等）。
if [ -n "$RENDER_SETTINGS_JSON" ]; then
  resolve_settings_inputs
  if [ "$AIENV_SKIP_SETTINGS_GENERATION" = "1" ]; then
    fail "動的Bedrock許可キーを算出できないため settings.json を生成できません: $RENDER_SETTINGS_JSON"
  fi
  generate_settings_json claude/settings.json "$RENDER_SETTINGS_JSON" "$AIENV_SETTINGS_MODEL" "$AIENV_BEDROCK_ENV_FILE" "$AIENV_SETTINGS_EFFORT"
  if [ "$AIENV_DEFERRED_EXIT_CODE" != "0" ] || [ ! -f "$RENDER_SETTINGS_JSON" ]; then
    fail "settings.json を生成できませんでした（Bedrock envファイルが実在するのに読めない等。詳細は上記のWARN）: $RENDER_SETTINGS_JSON"
  fi
  exit 0
fi

# --- ローカル実体プロファイルの雛形配置（2026-08-30 共通コア分離 §9.0 A-1 P1機構） ---
# サンプル（config/profile.md.sample・repo管理下）から $AIENV_LOCAL_PROFILE_PATH
# の雛形を作る。メイン/サブ共通（--sub-delegate経由でも実行する＝claude/・
# codex/のsymlink化と同じ扱い）。
# ⚠️ 2026-09-01 配役表解凍 §4.2-c: この雛形配置ブロックは settings.json 生成
# （旧・本ブロックの後段にあった）より**前**へ入れ替えた（旧実装は生成が
# 雛形配置より前にあり、入力〈プロファイル〉が出力〈settings.json〉より後に
# 置かれる順序では、role.leaderがv2雛形でunknownのまま初回インストールが
# 必ず「未確定」でリーダー実行値を解決できず失敗する。設計書§3.9の処理順
# 「①雛形配置→②preflight→③分類→④leader確定→⑤validator→⑥settings.json生成」
# の①を実際に⑥より前へ動かした）。
#
# 非破壊性（P1受入条件③）: 宛先が通常ファイル／ディレクトリ／symlink／
# broken symlinkのいずれで既に存在していてもコピーせず警告するだけに留める
# （`[ -e ]`だけだとbroken symlinkを「存在しない」と誤判定するため`[ -L ]`も
# 見る）。書込はmktemp+mvで原子的に行う（P1受入条件④・他の生成物と同じ流儀）。
#
# ⚠️ 2026-09-08 本人裁定A案（設定ファイルsample配布）: 読み元をVaultノート
# （vault-public/Preferences/profile-sample.md）から repo の
# config/profile.md.sample へ付け替えた。config/profile.md.sampleは
# 実体そのままの生ファイル（```yamlフェンスやObsidianノートのfrontmatter
# メタデータで包まれていない・schema本体が先頭`---`から直接始まる）ため、
# 旧来のYAMLフェンス抽出（`extract_profile_schema_block()`。2026-08-30
# 工程横断レビュー指摘・BLOCKING対応で新設していた）は不要になり撤去した。
# 単純にファイルをそのまま実体としてコピーするだけでよい。
if [ -e "$AIENV_LOCAL_PROFILE_PATH" ] || [ -L "$AIENV_LOCAL_PROFILE_PATH" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] ローカル実体プロファイルは既に存在するため雛形コピーはskipします: $AIENV_LOCAL_PROFILE_PATH"
  else
    warn "ローカル実体プロファイルは既に存在するため雛形コピーをskipしました（既存を壊さない）: $AIENV_LOCAL_PROFILE_PATH"
  fi
elif [ "$DRY_RUN" = "1" ]; then
  log "[dry-run] would copy profile sample: $PROFILE_SAMPLE_SRC -> $AIENV_LOCAL_PROFILE_PATH"
else
  # ⚠️ 2026-09-08 本人裁定A案: `[ -f ]`での存在確認を独立の分岐にせず、`cp`を
  # 直接試みてその失敗（無い・ディレクトリ・権限不足等いずれも）を1つの
  # 分岐へ統一した（生ファイルの単純コピーになったので、旧来の「フェンスが
  # 見つからない」失敗種別が無くなり、"存在しない"と"読めない"を分ける
  # 実益も無くなったため。installer全体は落とさずWARNに留める＝
  # --with-dotfiles失敗時と同じsoft-fail方針）。
  mkdir -p "$(dirname "$AIENV_LOCAL_PROFILE_PATH")"
  profile_tmp="$(mktemp "$(dirname "$AIENV_LOCAL_PROFILE_PATH")/.$(basename "$AIENV_LOCAL_PROFILE_PATH").aienv-tmp.XXXXXX")"
  if PROFILE_COPY_ERR="$(cp "$PROFILE_SAMPLE_SRC" "$profile_tmp" 2>&1 1>/dev/null)"; then
    mv "$profile_tmp" "$AIENV_LOCAL_PROFILE_PATH"
    log "ローカル実体プロファイルの雛形を作成しました: $AIENV_LOCAL_PROFILE_PATH <- ${PROFILE_SAMPLE_SRC}（config/profile.md.sampleをそのままコピー）"
  else
    rm -f "$profile_tmp"
    warn "config/profile.md.sampleを読み取れませんでした（無い・checkout破損・権限不足等の可能性）。雛形コピーをskipします: ${PROFILE_SAMPLE_SRC}（詳細: ${PROFILE_COPY_ERR}）"
  fi
fi

# --- リーダー実行値と動的Bedrock許可キーの決定（雛形配置の直後・settings.json生成の直前）---
# --dry-run では resolver を呼ばない（「--dry-run は python3 を要求しない」保証を
# 崩さない。計画表示は generate_settings_json() の dry-run 分岐が行う）。
AIENV_SETTINGS_MODEL=""
AIENV_SETTINGS_EFFORT=""
AIENV_SKIP_SETTINGS_GENERATION=0
if [ "$DRY_RUN" != "1" ]; then
  resolve_settings_inputs
fi

# --- claude/ ---
# settings.json はsymlinkではなく生成（マシン別modelプレースホルダ置換。上記
# 「例外その2」コメント参照）。
# ⚠️ Bedrock envファイルが存在するのに読めない・解析できない場合、
# generate_settings_json()はWARNを出しsettings.json本体の生成を中止・既存
# ファイルを保持したまま**AIENV_DEFERRED_EXIT_CODEを立てて戻る**（設計書
# §6.2-B S4「bedrock.envが実在するのに読めない/解析できない場合は非0終了」。
# 詳細は同関数のコメント参照）。他の処理（hooksのsymlink化等）はそのまま
# 続行させ、最終的な終了コードだけスクリプト末尾で非0へ反映する。これは
# 意図した安全側の分岐であり、`|| true`のような一律の抑制は付けない
# （2026-08-30 Codex四次レビュー指摘・BLOCKING対応: `|| true`を付けると、
# この関数内で本当に発生した異常＝mktemp/mv/backup_once失敗等まで一緒に
# 握り潰してしまい、`set -e`の保護が意図せず外れてしまっていた）。
# ⚠️ 動的Bedrock許可キーの算出自体に失敗した場合（AIENV_SKIP_SETTINGS_
# GENERATION=1）は、generate_settings_json()を呼ぶことすらせず既存ファイルを
# 保持する（設計書§6.2-B S18・2026-09-01工程横断レビュー差し戻し・MAJOR
# 対応。判定・WARN・AIENV_DEFERRED_EXIT_CODEの計上は上のブロックで既に
# 済ませている）。
if [ "$AIENV_SKIP_SETTINGS_GENERATION" != "1" ]; then
  generate_settings_json claude/settings.json "$HOME/.claude/settings.json" "$AIENV_SETTINGS_MODEL" "$AIENV_BEDROCK_ENV_FILE" "$AIENV_SETTINGS_EFFORT"
fi
link claude/hooks/bootstrap-vault.sh    "$HOME/.claude/hooks/bootstrap-vault.sh"
link claude/hooks/delegation-gate-v2.sh "$HOME/.claude/hooks/delegation-gate-v2.sh"
# 危険コマンド deny ゲート(PreToolUse Bash)。2026-08-06 追加: 2026-07-19 の
# フック導入時にリポジトリ収録が漏れており、サブ機で settings.json が
# 存在しないパスを参照して起動時警告が出ていた。
link claude/hooks/bash-danger-gate.sh "$HOME/.claude/hooks/bash-danger-gate.sh"
# 外部脳 想起支援(UserPromptSubmit)・利用ログ(PostToolUse Read) の2フック
# （2026-07-10 追加。settings.json への hooks 登録はリーダーが別途行う＝
# このスクリプトはsymlink配置のみを担当）。
link claude/hooks/vault-recall.sh    "$HOME/.claude/hooks/vault-recall.sh"
link claude/hooks/vault-read-log.sh  "$HOME/.claude/hooks/vault-read-log.sh"
# Nextペイン番号参照の自動解決(UserPromptSubmit)。cmux-next-watch --list の
# 対応表を注入する（2026-08-06 追加・表示ツール本体は ~/work/tools 側）。
link claude/hooks/next-pane-resolve.sh "$HOME/.claude/hooks/next-pane-resolve.sh"
link claude/hooks/task-pane-resolve.sh "$HOME/.claude/hooks/task-pane-resolve.sh"
# サブ機更新チェック(SessionStart)。settings.json は main/sub 共通でこのフックを
# 登録するため、リンクも main/sub 共通で配置する（スクリプト側が配役表の
# `machine_role`で判定し、メイン機では無出力で即 exit 0＝fail-closed）。
# 2026-07-28 追加: 2026-07-23 実装時にリンク配置が漏れており、両機で
# SessionStart に「No such file or directory」の非ブロッキングエラーが出ていた。
link claude/hooks/check-sub-update.sh "$HOME/.claude/hooks/check-sub-update.sh"
# セッション肥大化警告(UserPromptSubmit)。settings.json には2026-08-10導入時から
# 登録されていたが、本スクリプトへのlink配置が漏れていた（2026-08-30発覚・
# context-size-warn.sh/bash-danger-gate.sh/next-pane-resolve.sh/check-sub-update.sh
# に続く同型4回目。settings.json登録とinstaller配置の2点セット突合を
# scripts/check-drift.sh側にも追加している＝§9.0 A-0-2）。
link claude/hooks/context-size-warn.sh "$HOME/.claude/hooks/context-size-warn.sh"
# 対象8職種のAgent呼出しへmodel明示を強制するPreToolUseガード。
link claude/hooks/agent-model-guard.sh "$HOME/.claude/hooks/agent-model-guard.sh"
# 配役表に職種行がある職種のin-process起動（Agentツール）境界(PreToolUse
# ^Agent$。ラッパー起動-設計-v1.1.1.md §4・D-3)。agent-model-guard.shと
# 同じeventに並ぶ。
link claude/hooks/inprocess-gate.sh "$HOME/.claude/hooks/inprocess-gate.sh"
# 子（scripts/claude-exec.sh経由の名前無しworker）専用のVault保護柵。親の
# settings.jsonのPreToolUseには登録しない（子の--settingsインライン
# JSONが$HOME/.claude/hooks/vault-write-gate.shを直接参照する＝設計§2.5・
# 裁定A）。配置だけはここで行う。
link claude/hooks/vault-write-gate.sh "$HOME/.claude/hooks/vault-write-gate.sh"
# 使用率の毎発言注入(UserPromptSubmit)。SessionStart側と同じ共有関数を使う。
link claude/hooks/usage-inject.sh "$HOME/.claude/hooks/usage-inject.sh"

# 前提修正 P-2（設計§2）: 職種定義の配布結果を必ず報告する。
# ①新しく配置した定義（初回未配置）②repoから消えた定義へのdangling symlinkの
# 2つを固定文（§2.1）で報告し、②が1件でもあれば非0終了する（①は終了コードに
# 影響しない）。⚠️ dangling は削除しない（削除は本人判断という既存方針を
# 変えない）。
# 案件③ B-1 D-4（設計-v1.1.3.md §5 手順1）: effort-per-role v2が入れた
# 「素材＋配役表由来のeffort行」を持つ生成実ファイル方式を退役し、配置先
# 職種定義は再び symlink 化する（link()＝sync_managed_symlink() 経由。他の
# 管理symlinkと同じ退避規則）。B-1のラッパーがeffortの実行値を--effortで
# 子へ渡すため、職種定義ファイル側にeffort:行を持たせる必要が無くなった。
AGENTS_SRC_DIR="$DIR/claude/agents"
AGENTS_DEST_DIR="$HOME/.claude/agents"
[ -d "$AGENTS_SRC_DIR" ] || fail "リポジトリのディレクトリが見つかりません（checkout破損の可能性）: $AGENTS_SRC_DIR"
AGENTS_NEWLY_PLACED=()
for f in "$AGENTS_SRC_DIR"/*.md; do
  [ -e "$f" ] || fail "claude/agents/ 配下に .md が1つもありません（checkout破損の可能性）"
  name="$(basename "$f")"
  dest="$AGENTS_DEST_DIR/$name"
  # symlink・実ファイルいずれの形でも一切存在しなかったものだけを「初回未配置」
  # として数える（既存の名前を張り替えたケースは対象外＝設計§2.1「新しい定義を
  # 配置した」）。
  if [ "$DRY_RUN" != "1" ] && [ ! -e "$dest" ] && [ ! -L "$dest" ]; then
    AGENTS_NEWLY_PLACED+=("${name%.md}")
  fi
  link "claude/agents/$name" "$dest"
done

if [ "$DRY_RUN" != "1" ]; then
  if [ "${#AGENTS_NEWLY_PLACED[@]}" -gt 0 ]; then
    log "AGENTS: 初回未配置 ${#AGENTS_NEWLY_PLACED[@]}件（正常・配置しました）: $(IFS=,; echo "${AGENTS_NEWLY_PLACED[*]}")"
  fi

  # dangling 検出: aienv管理下（$AGENTS_SRC_DIR配下を指す）symlinkに限定して
  # 検査する（本スクリプトが関与しない他アプリ由来のsymlinkを誤検知しないため。
  # install-main.sh の link() が使う経路＝update-sub は install-sub 経由）。削除はしない。
  AGENTS_DANGLING=()
  for existing in "$AGENTS_DEST_DIR"/*.md; do
    [ -L "$existing" ] || continue
    target="$(readlink "$existing")"
    case "$target" in
      "$AGENTS_SRC_DIR"/*)
        [ -e "$target" ] || AGENTS_DANGLING+=("$(basename "$existing" .md)")
        ;;
    esac
  done
  if [ "${#AGENTS_DANGLING[@]}" -gt 0 ]; then
    log "AGENTS: dangling ${#AGENTS_DANGLING[@]}件（異常・repo から消えた定義のリンクが残っています。削除は本人が判断）: $(IFS=,; echo "${AGENTS_DANGLING[*]}")"
    AIENV_DEFERRED_EXIT_CODE=1
  fi
fi

if [ "$DRY_RUN" != "1" ]; then
  chmod +x "$DIR/claude/hooks/bootstrap-vault.sh" "$DIR/claude/hooks/delegation-gate-v2.sh" \
           "$DIR/claude/hooks/bash-danger-gate.sh" "$DIR/claude/hooks/next-pane-resolve.sh" \
           "$DIR/claude/hooks/task-pane-resolve.sh" \
           "$DIR/claude/hooks/vault-recall.sh" "$DIR/claude/hooks/vault-read-log.sh" \
           "$DIR/claude/hooks/check-sub-update.sh" "$DIR/claude/hooks/context-size-warn.sh" \
           "$DIR/claude/hooks/agent-model-guard.sh" \
           "$DIR/claude/hooks/inprocess-gate.sh" "$DIR/claude/hooks/vault-write-gate.sh" \
           "$DIR/claude/hooks/usage-inject.sh" \
           "$DIR/cmux/cmux-task-model.sh" "$DIR/cmux/cmux-next-model.sh" \
           "$DIR/cmux/cmux-task-declare.sh"
  # 締めレビュー2巡目 #2対応（2026-09-14）: agent-model-guard.sh専用の
  # 固有理由コード付き実行可能性チェックはここで削除した。
  # 上のlink()がsync_managed_symlink()経由で既にsrc欠落を汎用の「リポジトリ
  # のファイルが見つかりません（checkout破損の可能性）」でfail済みであり、
  # このchmod自体もsrc欠落なら`set -euo pipefail`により非0で停止するため、
  # この専用ガードは実際には発火しえない残骸だった（他のどのフックにも
  # 同種の専用チェックは無く、汎用経路だけで担保されている）。実行可能性の
  # 継続的な監視はscripts/check-drift.shの汎用`[NOT-EXECUTABLE]`検査
  # （$HOME/.claude/hooks/*.sh全体対象）が担う。
fi

# --- codex/ ---
link codex/AGENTS.md   "$HOME/.codex/AGENTS.md"
link codex/hooks.json  "$HOME/.codex/hooks.json"
generate_config_toml codex/config.toml "$HOME/.codex/config.toml"

# Codex呼び出し経路のMCPサーバー登録ステップは2026-09-06 codex exec一本化に
# 伴い廃止した（Claude Code側からのMCP経由呼び出しをやめ、Bash経由の
# scripts/codex-exec.sh に一本化。詳細は
# docs/core-split/codex-exec-only-検討経緯-2026-09-06.md）。Codex呼び出しは
# 各ワーカーが scripts/codex-exec.sh を直接叩く方式になったため、インストーラ側の
# 自動登録ステップは不要になった。

# 週次drift通知LaunchAgent（com.takumi009.drift-check.plist・scripts/drift-notify.sh）は
# 2026-07-16簡素化（[[Decisions/2026-07-16-nightly-batch-direct-write]]）で撤去した。
# 週次無人実行の経路は新設 maintenance.sh（PR2・install-maintenance.shが設置）へ移す。
# 既存マシンで稼働中の旧LAは install-maintenance.sh の移行処理（旧ラベルのbootout）で
# 片付ける（本スクリプトでは何もしない）。

# 使用率取得器 LaunchAgent（com.takumi009.usage-fetch・scripts/usage-fetch.sh）は
# 2026-09 B1-b（使用率取得器移設）で `claude-codex-usage/refresh.sh` から移設した
# （docs/core-split/使用率取得器移設B1b-設計-2026-09-08.md）。install-backup.sh・
# install-maintenance.sh と同じ理由で、本スクリプトからは呼び出さない（毎分実行
# ジョブの導入は「新旧の入れ替え順序」「本人確認を挟む切替手順」を持つ独立の
# installer にする＝scripts/install-usage-fetch.sh。メイン機の標準セットアップは
# install-main.sh の実行後にこれを個別に実行する。詳細＝README「セットアップ」
# 節・使用率取得器移設B1b-実装-2026-09-08.md）。サブ機は install-sub.sh の
# 「LaunchAgent を一切設置しない」方針を崩さず、導入する場合は本人が
# scripts/install-usage-fetch.sh を直接実行する（設計書§8 Q-7・(C)案）。
# ⚠️ ローカル実体プロファイルの雛形配置は、settings.json生成より前（本ファイル
# 上部・generate_settings_json呼び出しの直前）へ移動した（2026-09-01 配役表
# 解凍 §4.2-c）。ここには残さない。

# --- dotfiles（部品・下請け）。--with-dotfiles 明示時のみ ---
# git clone・dotfiles/install.sh の実行はどちらも「実システムへの実行」であり
# 失敗しても致命的ではない（ネットワーク不通・後で手動でやり直せる）ため、
# 失敗時は warn に留めて本スクリプト自体は続行する（export-public-vault.sh の
# push失敗時と同方針＝soft-fail）。
if [ "$WITH_DOTFILES" = "1" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    if [ -d "$DOTFILES_DIR" ]; then
      log "[dry-run] dotfiles は既に存在するため clone はskipします: $DOTFILES_DIR"
    else
      log "[dry-run] would run: git clone $DOTFILES_REPO_URL $DOTFILES_DIR"
    fi
    log "[dry-run] would run: (cd $DOTFILES_DIR && ./install.sh)"
  else
    if [ -d "$DOTFILES_DIR" ]; then
      log "dotfiles は既に存在するため clone はskipします: $DOTFILES_DIR"
    else
      log "cloning dotfiles: $DOTFILES_REPO_URL -> $DOTFILES_DIR"
      if ! git clone "$DOTFILES_REPO_URL" "$DOTFILES_DIR"; then
        warn "dotfiles の clone に失敗しました。--with-dotfiles をスキップします（ネットワーク等を確認して手動で再試行してください）: git clone $DOTFILES_REPO_URL $DOTFILES_DIR"
      fi
    fi
    if [ -x "$DOTFILES_DIR/install.sh" ]; then
      log "running: $DOTFILES_DIR/install.sh"
      if ( cd "$DOTFILES_DIR" && ./install.sh ); then
        log "dotfiles install.sh 完了"
      else
        warn "dotfiles/install.sh が失敗しました（exit非0）。dotfiles側を個別に確認してください: $DOTFILES_DIR/install.sh"
      fi
    else
      warn "dotfiles/install.sh が見つからない、または実行権限がありません（clone失敗、または想定外のリポジトリ構成の可能性）: $DOTFILES_DIR/install.sh"
    fi
  fi
fi

if [ "$DRY_RUN" = "1" ]; then
  log "[dry-run] 完了。実際の変更は一切行っていません。"
elif [ "$AIENV_DEFERRED_EXIT_CODE" != "0" ]; then
  # ⚠️ "done."（成功を示す文言）は出さない（2026-09-01 Codex差分レビュー
  # 指摘・MINOR対応: 直後に非0終了するのに"done."が出ると、人が見たときに
  # 成功したように誤読しうる）。settings.json生成失敗等の理由は各所の
  # warn()で既に出力済みのため、ここでは締めの一言だけを出す。
  # ⚠️ 設計書§6.2-B S8「生成物が存在しない状態でS2〜S7」は、最終的な終了
  # 理由へ機械可読トークンNO_GENERATED_FILEを含めることを要求している
  # （2026-09-01 工程横断レビュー指摘・MINOR-2対応。従来は終了コードのみで、
  # 「旧settings.jsonを保持したまま失敗」〈S2〜S7一般〉と「settings.json自体
  # が一度も存在しない」〈S8〉をログ上のテキストから区別できなかった）。
  if [ ! -e "$HOME/.claude/settings.json" ]; then
    warn "他の配置処理は完了しましたが、settings.jsonの生成に失敗したため非0終了します（NO_GENERATED_FILE: settings.jsonが一度も生成されていません。詳細は上記のWARNを参照してください）。"
  else
    # 前提修正 P-2: AIENV_DEFERRED_EXIT_CODE は settings.json 生成失敗以外
    # （AGENTS: dangling 等）でも立つようになったため、settings.json 側の
    # 失敗だと断定しない汎用文言にする（settings.json 自体は存在＝生成は
    # 成功している）。詳細は上記の各 WARN／AGENTS: 行を参照させる。
    warn "他の配置処理は完了しましたが、一部の処理で異常があったため非0終了します（詳細は上記のWARN／AGENTS: 行を参照してください）。"
  fi
else
  log "done."
fi

# ⚠️ AIENV_DEFERRED_EXIT_CODEが立っていれば（設計書S4等・generate_settings_
# json()参照）、他の全処理を完走させたうえでここで初めて非0終了する
# （2026-09-01 リーダー裁定・差し戻し対応）。
if [ "$AIENV_DEFERRED_EXIT_CODE" != "0" ]; then
  exit "$AIENV_DEFERRED_EXIT_CODE"
fi
