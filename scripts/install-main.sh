#!/usr/bin/env bash
# メイン環境用インストーラ: このリポジトリの claude/・codex/ 配下を
# ライブ位置（~/.claude/・~/.codex/）へ symlink する（dotfiles/install.sh と同方式）。
#
# 冪等（再実行安全）: 既存の「実ファイル」（symlinkでないもの）は初回だけ
# "<dest>.pre-aienv.bak" へ退避してから symlink に置き換える。バックアップは
# 既に存在すれば上書きしない（2回目以降の実行や、symlinkでなく実ファイルを
# 生成し続ける config.toml でも、初回のオリジナルだけを守り続ける。
# Codexレビュー指摘・Major＝旧実装は generate_config_toml() が毎回 backup を
# 上書きし、2回目実行でオリジナルが失われる不具合があった）。
#
# 例外: codex/config.toml は symlink しない。plain TOML は（hooks.json の
# "command" 文字列と違い）シェル変数展開が行われないため、__AIENV_HOME__
# プレースホルダを実ホームパスへ置換した実ファイルとして生成する
# （詳細は codex/config.toml 冒頭のコメント参照）。
#
# 例外その2: claude/settings.json も symlink しない（2026-08-21 リーダー承認・
# machine-role対応）。理由は2つ: ① JSONもTOML同様シェル変数展開されないため、
# "model" フィールドをマシン別（メイン=Fable 5・サブ=Opus 5。サブはPro プランで
# Fable非対応）に出し分けるには値の置き換えが必要。② symlinkのままだと、
# セッション内で `/model` を実行した際にClaude Code自身がユーザー設定ファイルの
# "model" フィールドを書き換える仕様があり、symlink先＝このリポジトリの
# claude/settings.json が意図せず直接書き換わってしまう副作用があった
# （config.tomlのnotify等がCodexアプリに自動書き換えられる問題と同型）。
# generate_settings_json() が実ファイルとして生成することで両方を解消する
# （config.tomlはsedでのテキスト置換だが、settings.jsonはpython3のjson moduleで
# トップレベル"model"キーへ直接代入する＝Codex一次レビュー指摘Minor対応。
# テンプレの__AIENV_MODEL__値はscripts/check-drift.sh①-2が比較に使う目印として
# 残す）。値は --sub-delegate の有無（＝呼び出し経路）から直接決定する（後述の
# AIENV_MODEL_MAIN/AIENV_MODEL_SUB）。machine-roleマーカーの読み返しには依存
# しない＝マーカー不在時の曖昧さという既存の問題が生じない。
#
# 使い方:
#   scripts/install-main.sh                   # 実行（symlink化 / config.toml生成）
#   scripts/install-main.sh --dry-run         # 置換計画だけ表示（何もしない）
#   scripts/install-main.sh --with-dotfiles   # 上記に加え、dotfiles（部品・下請け）も導入する
#   scripts/install-main.sh --print-model [--sub-delegate]
#                                              # model値を1行印字して即終了（副作用ゼロ）
#
# --print-model（2026-08-30 共通コア分離 §9.0 A-0-1 新設）: claude/settings.json の
# "model" 値の**唯一の出力口**。値を標準出力へ1行印字するだけで、生成・配置・
# マーカー書込など一切の副作用を持たない（他の全オプションより先に判定し、
# python3依存チェックより前・machine-roleマーカー書込より前に exit する）。
# scripts/update-sub.sh・scripts/check-drift.sh はこのモードだけを呼び、model値を
# 独自の値表として重複保持しない（設計書§9.0 A-0-1/A-0-3・§11.2 項目1「値出力口を
# 1本に絞る」の実装）。--sub-delegate を同時に付けるとサブ機向けの値
# （AIENV_MODEL_SUB）を、付けなければメイン機向けの値（AIENV_MODEL_MAIN）を返す
# （値の決め方自体は下記「claude/settings.json の model 値を確定する」ブロックと
# 完全に同じロジックを再利用する＝分岐を2箇所に増やさない）。
# ⚠️ **--sub-delegate 本体（symlink化・config.toml生成等を実際に行う経路）を
# 診断（check-drift.sh）から呼んではいけない**——診断中に実システムの状態が
# 変わってしまう。--print-model はこの問題が起きない（副作用ゼロ）ため診断から
# 呼んでよい。
#
# --with-dotfiles（既定OFF・明示オプション時のみ）: $HOME/work/dotfiles が無ければ
# `git clone` し、その後 dotfiles/install.sh を呼ぶ（既に存在する場合は clone を
# skipして install.sh だけ呼ぶ＝dotfiles側のinstall.shは再実行しても安全な設計のため。
# 相談資料§3-5「dotfilesは独立のまま部品として下請け」の実装）。
#
# --sub-delegate（内部専用・install-sub.sh がこのスクリプトへ委譲する際に常に付ける
# フラグ。手動指定は想定しない）: symlink化・config.toml生成・codex MCP登録は
# メイン/サブ共通で行うが、週次drift通知LaunchAgent（com.takumi009.drift-check.plist）
# の設置は**メイン専用機能**のためskipする（2026-07-08 設計決定H-2「メイン専用」の
# 実装。install-backup.sh・install-vault-agents.sh を別スクリプトに分離しているのと
# 同じ意図だが、drift-check はinstall-main.sh本体に統合する指示だったため、
# install-sub.shからの委譲経路だけをこのフラグで区別する）。
# 同フラグはmachine-roleマーカー（後述）の扱いにも使う: --sub-delegate経由の
# 場合は委譲元のinstall-sub.shが既に"sub"を書き込む/書き込む予定のため、本
# スクリプト側では一切マーカーに触れない。
#
# machine-roleマーカー（$HOME/.config/takumi009-ai-env/machine-role）:
# 本スクリプトを --sub-delegate 無しで直接実行した場合（＝実際にメイン機として
# セットアップする場合）は明示的に"main"を書き込む（2026-07-24 Codex一次レビュー
# 指摘Major対応: かつてinstall-sub.shを実行しサブ機だった機体を、後から
# install-main.shを直接実行してメイン機へ移行する運用で、旧"sub"マーカーが
# 残ったままだとclaude/hooks/check-sub-update.sh・scripts/update-sub.shが
# サブ機と誤認し続け、update-sub.shの`rsync --delete`でメインVaultの
# `Preferences/`が上書き削除される事故になり得た）。
#
# 注意: インストール系スクリプトはユーザーが内容を確認したうえで実行する（自動実行しない）。
#       本スクリプトは既存の実ファイルをsymlinkへ置き換えるため、ユーザー本人が
#       立ち会って実行すること。

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${DOTFILES_DIR:=$HOME/work/dotfiles}"
: "${DOTFILES_REPO_URL:=https://github.com/Takumi00Nine/dotfiles}"
# テスト専用: "1" にすると scripts/setup-codex-mcp.sh の呼び出し自体をskipする
# （既定0）。setup-codex-mcp.sh は実 claude/codex CLI を呼びうるため、それらが
# 実際にPATH上にある開発機でテストを走らせると、HOMEをfixtureへ差し替えていても
# 実システムのMCP登録に触れてしまう恐れがある（Codexレビュー指摘・Major。
# scripts/install-sub.sh の SKIP_LAUNCHCTL と同じ考え方の対策）。
: "${SKIP_CODEX_MCP:=0}"
# テスト専用: "1" にすると launchctl への実操作（bootout/bootstrap/enable）だけを
# skipし、plist生成（プレースホルダ置換）はそのまま行う（週次drift通知LaunchAgentの
# 設置に使用。scripts/install-sub.sh の SKIP_LAUNCHCTL と同じ考え方・同じ変数名。
# 実launchd＝gui/$(id -u) はHOMEを差し替えても隔離できないため、テストで誤って
# 実システムのlaunchdへ登録してしまう事故を防ぐ。本番運用では常に既定値=0のまま）。
: "${SKIP_LAUNCHCTL:=0}"
# claude/settings.json の "model" 値（マシン別出し分け・2026-08-21）。環境変数で
# 上書き可（ユニットテスト用。本番は既定値のままでよい）。サブ機はProプラン・
# Fable 5非対応のためOpus 5をpinする（aliasの"opus"は将来の指す先変更に追従して
# しまうため使わない＝Web裏取り済み）。[1m]（1M context）サフィックスはメインの
# Fable 5専用（リーダー指示・サブには付けない）。
: "${AIENV_MODEL_MAIN:=claude-fable-5[1m]}"
: "${AIENV_MODEL_SUB:=claude-opus-5}"
# ローカル実体プロファイル（2026-08-30 共通コア分離 §9.0 A-1 P1機構）の配置先。
# claude/hooks/bootstrap-vault.sh と同じ環境変数名・既定値（マシンローカル・
# repo管理外・非配布＝§11.2 source of truth定義）。
: "${AIENV_LOCAL_PROFILE_PATH:=$HOME/.config/takumi009-ai-env/profile.md}"
# Bedrock最小セット（2026-08-30 共通コア分離 §9.0 A-1-4）: ピン留めの実値
# （推論プロファイルID・リージョン・CLAUDE_CODE_USE_BEDROCK等）の正本となる
# マシンローカルenvファイル。§11.2「ピン留めの実値の置き場」の裁定どおり
# publicなプロファイルには書かず、repo管理外のこのファイルへ分離する。
# AWSの認証情報そのもの（AWS_ACCESS_KEY_ID等）はここに置かない
# （専用の資格情報機構＝AWS CLI/SSO/Bedrock APIキーのままとする。本ファイルが
# 持つのは「どのモデルを指すか」の値のみ）。存在しない（Bedrock未導入機）の
# 場合は何もしない＝既存の全マシンの挙動を変えない。
: "${AIENV_BEDROCK_ENV_FILE:=$HOME/.config/takumi009-ai-env/bedrock.env}"
# Bedrock env ファイルから settings.json の "env" ブロックへ取り込んでよい
# キーの許可リスト（2026-08-25 Codex一次レビュー指摘・Major対応: 当初は
# テンプレと衝突しないキーを無条件で取り込んでいたため、誤ってAWS認証情報
# （AWS_ACCESS_KEY_ID等）を書いてしまうと settings.json 経由で複製・露出する
# 穴があった）。許可するのは「どのモデルを指すか」の値だけで、AWSへの
# 認証情報は対象外（専用の資格情報機構のまま＝絶対厳守③）。
# ⚠️ この配列を唯一の値表とする——check-drift.sh は自前でこの一覧を複製せず、
# 下記 compute_bedrock_env_json() ／ --print-bedrock-env-json を呼んで
# 期待値を得る（2026-08-30 工程横断レビュー指摘・MAJOR-5対応。§9.0 A-0-1の
# 「値出力口の一本化」と同じ設計思想の横展開＝値表を3箇所に増やさない）。
AIENV_ALLOWED_BEDROCK_ENV_KEYS=(
  "CLAUDE_CODE_USE_BEDROCK"
  "AWS_REGION"
  "ANTHROPIC_DEFAULT_OPUS_MODEL"
  "ANTHROPIC_DEFAULT_SONNET_MODEL"
  "ANTHROPIC_DEFAULT_HAIKU_MODEL"
)

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

DRY_RUN=0
WITH_DOTFILES=0
IS_SUB_DELEGATE=0
PRINT_MODEL=0
PRINT_BEDROCK_ENV_JSON=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --with-dotfiles) WITH_DOTFILES=1 ;;
    --sub-delegate) IS_SUB_DELEGATE=1 ;;
    --print-model) PRINT_MODEL=1 ;;
    --print-bedrock-env-json) PRINT_BEDROCK_ENV_JSON=1 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

# --- claude/settings.json の model 値を確定する ---
# --sub-delegate の有無（＝install-sub.sh経由か、直接実行か）だけで決まる。
# machine-roleマーカーファイルの読み返しには依存しない（同マーカーは
# fail-closed設計＝「積極的な証明（sub）が無ければmain扱い」だが、本値は
# そもそも読み返しが不要な一次情報＝どちらのインストーラ経路で呼ばれたかから
# 直接決まるため、マーカー不在時の曖昧さという既存の問題自体が生じない）。
if [ "$IS_SUB_DELEGATE" = "1" ]; then
  AIENV_MODEL_VALUE="$AIENV_MODEL_SUB"
else
  AIENV_MODEL_VALUE="$AIENV_MODEL_MAIN"
fi

# --print-model: 値を1行印字して即終了する（副作用ゼロ）。python3依存チェック・
# machine-roleマーカー書込・symlink化等の実処理より前に判定する（値の出力口が
# 「読むだけ」であることを保証するため。§9.0 A-0-1）。
if [ "$PRINT_MODEL" = "1" ]; then
  printf '%s\n' "$AIENV_MODEL_VALUE"
  exit 0
fi

# --print-bedrock-env-json: Bedrock envファイルの内容（許可リスト適用済み）を
# JSONで1行印字して即終了する（副作用ゼロ）。check-drift.shが「期待する
# settings.json」を計算する際に呼ぶ値出力口（2026-08-30 §9.0 A-0-1と同じ
# 設計思想の横展開・MAJOR-5対応）。
if [ "$PRINT_BEDROCK_ENV_JSON" = "1" ]; then
  # compute_bedrock_env_json()の終了コードをそのまま呼び出し元へ伝える
  # （ファイルが存在するのに読取・解析に失敗した場合は非0終了する。
  # 2026-08-30 Codex二次レビュー指摘・Major対応: fail-openで{}を返して
  # しまうと呼び出し側が「監視できていないのに一致」と誤判定しうる）。
  bedrock_env_json_rc=0
  compute_bedrock_env_json "$AIENV_BEDROCK_ENV_FILE" || bedrock_env_json_rc=$?
  exit "$bedrock_env_json_rc"
fi

log() { echo "[install-main] $*"; }
warn() { echo "[install-main] WARN: $*" >&2; }
fail() { echo "[install-main] FAIL: $*" >&2; exit 1; }

# python3依存の早期チェック（Codex二次レビュー指摘・Minor対応: generate_settings_json()が
# claude/settings.json生成にpython3のjson moduleを必須で使うようになった＝2026-08-21。
# マーカー書込・symlink化等の実処理が始まってから中途半端な状態でpython3不在に
# 気付くより、着手前に明確な指示を出す方が親切。--dry-run は実際には何も生成
# しない＝python3を必要としないため対象外にする）。macOSは通常システムpython3
# （またはXcode Command Line Tools経由）を持つため通常は問題にならない想定。
if [ "$DRY_RUN" != "1" ]; then
  command -v python3 >/dev/null 2>&1 || fail "python3 が見つかりません（claude/settings.json の生成に必要です）。Xcode Command Line Tools（xcode-select --install）等でpython3を導入してから再実行してください。"
fi

# バックアップは「.pre-aienv.bak がまだ無いときだけ」作る（何度実行しても
# 常にインストール前オリジナルを保持する。symlink化後は dest が symlink に
# なるため自然と対象外になるが、generate_config_toml() のように毎回実ファイルを
# 書く経路ではこのガードが無いと2回目の実行でオリジナルが消える）。
backup_once() {
  local dest="$1"
  if [ -e "$dest" ] && [ ! -L "$dest" ] && [ ! -e "$dest.pre-aienv.bak" ]; then
    cp "$dest" "$dest.pre-aienv.bak"
    log "backed up: $dest -> $dest.pre-aienv.bak"
  fi
}

# would_backup <dest> — dry-run表示用（backup_once相当の判定のみ、書き込みしない）
would_backup() {
  local dest="$1"
  [ -e "$dest" ] && [ ! -L "$dest" ] && [ ! -e "$dest.pre-aienv.bak" ]
}

# link <repo-relative-source> <destination>
# dotfiles/install.sh の link() と同方式（バックアップは backup_once() 経由）。
# source が無い場合は「このリポジトリの必須構成が壊れている」ことを意味するため
# skip扱いにせず fail する（Codexレビュー指摘・Minor：黙って進むと壊れた
# checkoutでも "done" と表示されてしまう）。
link() {
  local src="$DIR/$1" dest="$2"
  [ -e "$src" ] || fail "リポジトリのファイルが見つかりません（checkout破損の可能性）: $src"
  if [ "$DRY_RUN" = "1" ]; then
    would_backup "$dest" && log "[dry-run] would back up: $dest -> $dest.pre-aienv.bak"
    log "[dry-run] would link: $dest -> $src"
    return
  fi
  mkdir -p "$(dirname "$dest")"
  backup_once "$dest"
  ln -sfn "$src" "$dest"
  log "linked: $dest -> $src"
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
# 対応で --print-bedrock-env-json を新設した際に、宣言をこの関数より前へ
# 移動した）。
# 4番目の引数（bedrock-env-file）は2026-08-30 §9.0 A-1-4追加: 存在すれば
# KEY=VALUE形式で読み、上記許可リストに載っていて、かつテンプレ由来のenvキー
# （DISABLE_AUTOUPDATER等）と衝突しないキーだけを"env"ブロックへ追加する
# （許可リスト外・衝突キーはいずれもスキップしキー名だけをログに残す。値は
# 一切出力しない＝絶対厳守③。§11.2「ピン留めの実値の置き場」の裁定どおり、
# 値そのものはテンプレにもpublicなプロファイルにも書かない）。ファイルが無い
# （Bedrock未導入機）場合は何もしない。
generate_settings_json() {
  local src="$DIR/$1" dest="$2" model="$3" bedrock_env_file="${4:-}" tmp PY_ERR PY_OUT
  local bedrock_status bedrock_env_perm bedrock_payload bedrock_kind
  [ -e "$src" ] || fail "リポジトリのファイルが見つかりません（checkout破損の可能性）: $src"
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
      log "[dry-run] would generate (not symlink): $dest <- $src （\"model\"を ${model} へ設定）"
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
        # ファイルを直接読む処理を複製していた。update-sub.shも同じ関数を
        # 呼ぶ経路へ揃えた＝値表・解析ロジックとも複製箇所は増やさない）。
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
    return 0
  fi

  mkdir -p "$(dirname "$dest")"
  backup_once "$dest"
  tmp="$(mktemp "$(dirname "$dest")/.$(basename "$dest").aienv-tmp.XXXXXX")"
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
data['model'] = sys.argv[3]

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
" "$src" "$tmp" "$model" "$bedrock_payload" 2>&1)"; then
    fail "settings.json の生成に失敗しました（テンプレの検証またはpython3 json処理エラー。checkout破損・テンプレへの誤ったmodel値ハードコード・python3不在等の可能性）: $src${PY_OUT:+ (詳細: $PY_OUT)}"
  fi
  mv "$tmp" "$dest"
  log "generated: $dest <- $src （\"model\"を ${model} へ設定）"
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

# --- machine-roleマーカー: --sub-delegate無し（＝メイン機としての直接実行）の
#     場合だけ明示的に"main"を書く。--sub-delegate経由では一切触れない
#     （委譲元のinstall-sub.shが"sub"を書き込む/書き込む予定のため。詳細は
#     本ファイル冒頭のコメント参照）。
#
# Codex再レビュー指摘・Major対応: 他の全処理より前（symlink化・config.toml生成
# 等の実処理が始まる前）に真っ先に書く。末尾に置いていた旧実装だと、直接実行の
# 途中でchecked-out破損等によりfail()して停止した場合、旧"sub"マーカーが
# 上書きされないまま残ってしまい、Main Vault上でscripts/update-sub.shが
# 引き続き許可されてしまう欠陥があった（本人が直接install-main.shを実行した
# 時点で「メイン機として使うつもりだ」という意思は既に確定しているため、
# 後続処理の成否に関わらず真っ先にマーカーを確定させるのが安全側）。
# 書込自体（mkdir/mktemp/mv）が失敗した場合はset -eによりここで即座に
# スクリプト全体が停止する（他のfail-fast処理と同じ扱い＝黙って続行しない）。
if [ "$IS_SUB_DELEGATE" != "1" ]; then
  : "${AIENV_MACHINE_ROLE_MARKER:=$HOME/.config/takumi009-ai-env/machine-role}"
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] would write: $AIENV_MACHINE_ROLE_MARKER (content: main)"
  else
    mkdir -p "$(dirname "$AIENV_MACHINE_ROLE_MARKER")"
    marker_tmp="$(mktemp "$(dirname "$AIENV_MACHINE_ROLE_MARKER")/.$(basename "$AIENV_MACHINE_ROLE_MARKER").aienv-tmp.XXXXXX")"
    printf 'main\n' > "$marker_tmp"
    mv "$marker_tmp" "$AIENV_MACHINE_ROLE_MARKER"
    log "machine-role マーカーを設置しました（main）: $AIENV_MACHINE_ROLE_MARKER"
  fi
fi

# --- claude/ ---
# settings.json はsymlinkではなく生成（マシン別modelプレースホルダ置換。上記
# 「例外その2」コメント参照）。
# ⚠️ Bedrock envファイルが存在するのに読めない・解析できない場合、
# generate_settings_json()はWARNを出しsettings.json本体の生成を中止・既存
# ファイルを保持したまま**正常終了（exit 0相当）**する（設計書§11.2「生成
# 失敗時は旧ファイルを触らない」契約。詳細は同関数のコメント参照）。これは
# 意図した安全側の分岐であり失敗ではないため、`|| true`のような一律の抑制は
# 付けない（2026-08-30 Codex四次レビュー指摘・BLOCKING対応: `|| true`を
# 付けると、この関数内で本当に発生した異常＝mktemp/mv/backup_once失敗等まで
# 一緒に握り潰してしまい、`set -e`の保護が意図せず外れてしまっていた）。
generate_settings_json claude/settings.json "$HOME/.claude/settings.json" "$AIENV_MODEL_VALUE" "$AIENV_BEDROCK_ENV_FILE"
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
# サブ機更新チェック(SessionStart)。settings.json は main/sub 共通でこのフックを
# 登録するため、リンクも main/sub 共通で配置する（スクリプト側が machine-role
# マーカーで判定し、メイン機では無出力で即 exit 0＝fail-closed）。
# 2026-07-28 追加: 2026-07-23 実装時にリンク配置が漏れており、両機で
# SessionStart に「No such file or directory」の非ブロッキングエラーが出ていた。
link claude/hooks/check-sub-update.sh "$HOME/.claude/hooks/check-sub-update.sh"
# セッション肥大化警告(UserPromptSubmit)。settings.json には2026-08-10導入時から
# 登録されていたが、本スクリプトへのlink配置が漏れていた（2026-08-30発覚・
# context-size-warn.sh/bash-danger-gate.sh/next-pane-resolve.sh/check-sub-update.sh
# に続く同型4回目。settings.json登録とinstaller配置の2点セット突合を
# scripts/check-drift.sh側にも追加している＝§9.0 A-0-2）。
link claude/hooks/context-size-warn.sh "$HOME/.claude/hooks/context-size-warn.sh"

[ -d "$DIR/claude/agents" ] || fail "リポジトリのディレクトリが見つかりません（checkout破損の可能性）: $DIR/claude/agents"
for f in "$DIR"/claude/agents/*.md; do
  [ -e "$f" ] || fail "claude/agents/ 配下に .md が1つもありません（checkout破損の可能性）"
  name="$(basename "$f")"
  link "claude/agents/$name" "$HOME/.claude/agents/$name"
done

if [ "$DRY_RUN" != "1" ]; then
  chmod +x "$DIR/claude/hooks/bootstrap-vault.sh" "$DIR/claude/hooks/delegation-gate-v2.sh" \
           "$DIR/claude/hooks/bash-danger-gate.sh" "$DIR/claude/hooks/next-pane-resolve.sh" \
           "$DIR/claude/hooks/vault-recall.sh" "$DIR/claude/hooks/vault-read-log.sh" \
           "$DIR/claude/hooks/check-sub-update.sh" "$DIR/claude/hooks/context-size-warn.sh"
fi

# --- codex/ ---
link codex/AGENTS.md   "$HOME/.codex/AGENTS.md"
link codex/hooks.json  "$HOME/.codex/hooks.json"
generate_config_toml codex/config.toml "$HOME/.codex/config.toml"

# --- codex MCP登録（scripts/setup-codex-mcp.sh）。install-sub.shはこのスクリプトへ
#     委譲しているため自動的に恩恵を受ける。Claude Code未導入環境でも installer 全体を
#     落とさないよう、失敗はWARNに留めて続行する（2026-07-08 設計判断）。 ---
if [ "$SKIP_CODEX_MCP" = "1" ]; then
  log "SKIP_CODEX_MCP=1 のため codex MCP 登録はskipします（テスト用）"
elif [ "$DRY_RUN" = "1" ]; then
  log "[dry-run] would run: $DIR/scripts/setup-codex-mcp.sh"
else
  if [ -x "$DIR/scripts/setup-codex-mcp.sh" ]; then
    if "$DIR/scripts/setup-codex-mcp.sh"; then
      :
    else
      warn "codex MCP の登録に失敗しました（Claude Code未導入等の可能性）。手動で確認してください: scripts/setup-codex-mcp.sh"
    fi
  else
    warn "scripts/setup-codex-mcp.sh が見つかりません（checkout破損の可能性）"
  fi
fi

# 週次drift通知LaunchAgent（com.takumi009.drift-check.plist・scripts/drift-notify.sh）は
# 2026-07-16簡素化（[[Decisions/2026-07-16-nightly-batch-direct-write]]）で撤去した。
# 週次無人実行の経路は新設 maintenance.sh（PR2・install-maintenance.shが設置）へ移す。
# 既存マシンで稼働中の旧LAは install-maintenance.sh の移行処理（旧ラベルのbootout）で
# 片付ける（本スクリプトでは何もしない）。

# --- ローカル実体プロファイルの雛形配置（2026-08-30 共通コア分離 §9.0 A-1 P1機構） ---
# サンプル（vault-public/Preferences/profile-sample.md・repo管理下）から
# $AIENV_LOCAL_PROFILE_PATH の雛形を作る。メイン/サブ共通（--sub-delegate経由でも
# 実行する＝claude/・codex/のsymlink化と同じ扱い）。
# 非破壊性（P1受入条件③）: 宛先が通常ファイル／ディレクトリ／symlink／
# broken symlinkのいずれで既に存在していてもコピーせず警告するだけに留める
# （`[ -e ]`だけだとbroken symlinkを「存在しない」と誤判定するため`[ -L ]`も
# 見る）。書込はmktemp+mvで原子的に行う（P1受入条件④・他の生成物と同じ流儀）。
#
# ⚠️ 実サンプルの入力形式不整合（2026-08-30 工程横断レビュー指摘・BLOCKING対応）:
# `profile-sample.md`はObsidianノートであり、**先頭のfrontmatter（date/tags/…）は
# ノート自体のメタデータであって最小能力表7キーではない**。7キー本体は本文中の
# ```yaml フェンスコードブロックの中にYAML frontmatter形式で書かれている
# （そのブロック自体が独立した`---`区切りを持つ）。単純にノート全体を
# コピーするだけでは、bootstrap-vault.shのresolve_local_profile()が
# ノートの先頭frontmatterを解析してしまい、7キー全てが「既存キー欠落」（T5）
# という誤判定になる（結合テストが合成fixtureだったため見逃されていた不具合）。
# 対策: サンプル本文の**最初の```yamlフェンスブロックのうち、内容が`---`で
# 始まるもの**を抽出し、そのYAML frontmatter部分だけをローカル実体として書く
# （サンプル側にマーカー等の追加変更は不要＝現行の実サンプルはこの条件を
# 満たしている）。
PROFILE_SAMPLE_SRC="$DIR/vault-public/Preferences/profile-sample.md"
extract_profile_schema_block() {
  # 引数: サンプルファイルのパス。標準出力へYAML frontmatterブロック
  # （`---`〜`---`を含む）を書く。見つからなければ非0終了する。
  python3 -c "
import re, sys
with open(sys.argv[1], encoding='utf-8') as f:
    text = f.read()
blocks = re.findall(r'\`\`\`yaml\n(.*?)\n\`\`\`', text, re.DOTALL)
candidate = next((b for b in blocks if b.lstrip().startswith('---')), None)
if candidate is None:
    print('YAML frontmatterブロック（内容が---で始まる \`\`\`yamlフェンス）が見つかりません', file=sys.stderr)
    sys.exit(1)
sys.stdout.write(candidate.rstrip('\n') + '\n')
" "$1"
}
if [ -e "$AIENV_LOCAL_PROFILE_PATH" ] || [ -L "$AIENV_LOCAL_PROFILE_PATH" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] ローカル実体プロファイルは既に存在するため雛形コピーはskipします: $AIENV_LOCAL_PROFILE_PATH"
  else
    warn "ローカル実体プロファイルは既に存在するため雛形コピーをskipしました（既存を壊さない）: $AIENV_LOCAL_PROFILE_PATH"
  fi
elif [ "$DRY_RUN" = "1" ]; then
  log "[dry-run] would extract profile schema block and write: $PROFILE_SAMPLE_SRC -> $AIENV_LOCAL_PROFILE_PATH"
elif [ -f "$PROFILE_SAMPLE_SRC" ]; then
  mkdir -p "$(dirname "$AIENV_LOCAL_PROFILE_PATH")"
  profile_tmp="$(mktemp "$(dirname "$AIENV_LOCAL_PROFILE_PATH")/.$(basename "$AIENV_LOCAL_PROFILE_PATH").aienv-tmp.XXXXXX")"
  # `2>&1 1>"$profile_tmp"`の順序が重要（Codex二次レビュー指摘・Minor対応）:
  # 先に`2>&1`でstderrを「その時点のstdout」＝この$(...)キャプチャ先へ
  # 複製してから、`1>"$profile_tmp"`でstdoutだけをファイルへ切り替える
  # （標準的なstdout/stderr入れ替えテクニック）。逆順（`> file 2>&1`）だと
  # stdout・stderrの両方がファイルへ吸い込まれ、PROFILE_EXTRACT_ERRが常に
  # 空になり失敗時の詳細メッセージが出なくなっていた。
  if PROFILE_EXTRACT_ERR="$(extract_profile_schema_block "$PROFILE_SAMPLE_SRC" 2>&1 1>"$profile_tmp")"; then
    mv "$profile_tmp" "$AIENV_LOCAL_PROFILE_PATH"
    log "ローカル実体プロファイルの雛形を作成しました: $AIENV_LOCAL_PROFILE_PATH <- ${PROFILE_SAMPLE_SRC}（最小能力表ブロックのみ抽出）"
  else
    rm -f "$profile_tmp"
    warn "profile-sample.mdから最小能力表ブロックを抽出できませんでした（サンプルの形式が変わった可能性）。雛形コピーをskipします: ${PROFILE_SAMPLE_SRC}（詳細: ${PROFILE_EXTRACT_ERR}）"
  fi
else
  # サンプルがまだリポジトリに存在しない場合（P1機構のロールアウト未完了時）は
  # installer全体を落とさずWARNに留める（--with-dotfiles失敗時と同じsoft-fail方針）。
  warn "vault-public/Preferences/profile-sample.md が見つかりません（P1機構のロールアウト未完了、またはcheckout破損の可能性）: $PROFILE_SAMPLE_SRC"
fi

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
else
  log "done."
fi
