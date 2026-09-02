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
# ⚠️ 配役表解凍（2026-09-01・設計書§4.2-f）以降、--sub-delegateはv2プロファイル
# ベースのmodel/effort解決（後述--print-leader-runtime・実インストール時の
# リーダー実行値決定）には一切使わない（受理はするが無視する）。v1委譲期間中の
# --print-modelの出し分け（AIENV_MODEL_MAIN/AIENV_MODEL_SUB）とmachine-role
# マーカーの扱いにだけ引き続き効く。
#
# --print-leader-runtime（2026-09-01 設計書§4.2-a 新設・値出力口の一本化）:
# ローカル実体プロファイル（$AIENV_LOCAL_PROFILE_PATH）を解決し、実効リーダー
# 候補（§3.5-L・本命 or fallback）の model・effort を1行のJSON
# （例 {"model": "claude-opus-5", "effort": "high"}）で標準出力へ印字して
# 即終了する（副作用ゼロ）。effort未指定時はキー自体を出さない（正常な省略と
# 解決失敗を混同しない）。プロファイルがv1（旧7キーのみ・schema_versionが
# 無い/1）と分類された場合は現行実装（AIENV_MODEL_MAIN/AIENV_MODEL_SUBを
# --sub-delegateの有無で選ぶ）へ委譲し、effortはlegacy値"high"を返す
# （v1委譲期間の後方互換・§3.5）。実体が全く存在しない場合もv1委譲と同じ扱いに
# する（P1ロールアウト未完了機を落とさないため）。解決に失敗した場合は
# 標準出力へ1文字も出さず非0終了し、機械可読コード＋短い理由を標準エラーへ
# 1行(`<コード>\t<理由>`)返す（4.2-b。理由は値を含まない）。install-main.sh・
# update-sub.sh・check-drift.shの3者は今後この出力口だけを使う。--print-modelは
# v1委譲期間のみ互換として残す（その後廃止）。
#
# --check-profile（2026-09-01 設計書§4.2-e 新設・副作用ゼロの検査口）:
# ローカル実体プロファイルの整合性を検査し、provider/modelごとに職種を
# グループ化した配役一覧を表示する。手編集を前提にする設計への「編集直後に
# 確かめる口」。`--check-profile --print-schema-version`を付けると一覧表示を
# 省略しschema_versionの値だけを1行返す（値なし・副作用ゼロ・U-7の撤去条件
# 判定に使う）。
#
# --reconfigure-leader / --non-interactive（2026-09-01 設計書§3.9 新設）:
# 前者は既に確定済みのrole.leaderを対話で変更したいときに付ける（未指定なら
# 確定済みの値はそのまま通す＝冪等）。後者は対話を一切行わない（CI・バック
# グラウンド実行での正しい運用。付いていれば`[ -t 0 ]`より常に優先する）。
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
# 共有lib（claude/hooks/lib/profile_resolve.py・2026-09-01 配役表解凍 §4.1-g）と
# コア職種マニフェスト（claude/agents/）の場所。bootstrap-vault.shと同じ
# 「自身の実体パスから同梱libを解決する」方式（U-5）。
: "${AIENV_PROFILE_RESOLVE_LIB:=$DIR/claude/hooks/lib/profile_resolve.py}"
: "${AIENV_AGENTS_DIR:=$DIR/claude/agents}"
# §3.9対話確定の直列化に使う専用ロック（scripts/lib/pid-lock.shを再利用・
# 新規ロック機構は作らない）。プロファイル本体とは別ファイルにする
# （プロファイル自体をロックファイルに転用すると書込み時の原子的置換
# （mktemp+mv）と衝突するため）。
: "${AIENV_LEADER_LOCK_FILE:=$AIENV_LOCAL_PROFILE_PATH.leader.lock}"
: "${AIENV_LEADER_LOCK_STALE_SECONDS:=300}"
# §3.9対話の1問あたりの入力待ちタイムアウト（秒）。TTYが「人が応答する」証明で
# ない（擬似TTYの自動化がありうる）ことへの対策＝タイムアウトで必ず抜ける。
: "${AIENV_LEADER_DIALOG_TIMEOUT:=60}"
# テスト専用: "1" にすると `[ -t 0 ]` の判定結果によらず対話可能とみなす
# （§3.9の対話フローを実TTY無しで決定的に検証するためのテスト用エスケープ
# ハッチ。SKIP_LAUNCHCTL/SKIP_CODEX_MCPと同じ「テスト専用変数」の流儀。
# --non-interactiveが指定されていれば引き続きそちらが優先する）。
: "${AIENV_FORCE_TTY_FOR_TEST:=0}"
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
# 2026-09-01 配役表解凍 §4.2-d 改訂: 固定で許可するのは以下2キーだけへ縮小。
# 旧版はANTHROPIC_DEFAULT_OPUS/SONNET/HAIKU_MODELも無条件固定で許可していたが、
# それらは「プロファイルのrole.*/fallback.*がprovider=bedrockで実際にその別名を
# 使っているときだけ」動的に許可する側へ移した（compute_allowed_bedrock_env_keys()
# 参照）。名前だけ許可リストのパターンに合う任意キーへ秘密値を入れる穴を、
# 人がピン留めの論理名を書けない設計と組み合わせて塞ぐ（迂回もできない）。
AIENV_ALLOWED_BEDROCK_ENV_KEYS=(
  "CLAUDE_CODE_USE_BEDROCK"
  "AWS_REGION"
)

# compute_allowed_bedrock_env_keys — 固定2キー＋動的キーの和集合を1行1キーで
# 標準出力へ書く（2026-09-01 §4.2-d）。動的キー＝ローカル実体プロファイルの
# role.*/fallback.*にprovider=bedrockの行（configured/unavailableのどちらも
# 意図を残す設計＝V8-aに合わせ両方見る）があれば、その model 別名を共有lib
# のlist-rolesサブコマンドへ渡してbedrock_pin_<別名>のenvキー名を導出した
# ものの重複排除。list-rolesは自己完結（存在確認・symlink拒否・preflight・
# 分類・全validatorをlib側が内部で行う契約＝担当A確定）。
#
# 戻り値の契約（2026-09-01 Codex差分レビュー・MAJOR対応で明確化）:
#   exit 0: 成功。動的キー0件（プロファイルが無い／v1／実体はあるが
#           schema_version:2未満＝PROFILE_LEGACY_V1・PROFILE_NOT_FOUND）は
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
      done < <(awk -F'\t' '($3=="configured"||$3=="unavailable") && $4=="bedrock" {print $5}' "$rows_tmp" | sort -u)
    else
      case "$rows_err" in
        PROFILE_LEGACY_V1*|PROFILE_NOT_FOUND*)
          # v1・実体なしはBedrock役職の入力元(role.*行)自体が無い正常な
          # 状態。動的キー0件が正しい結果であり失敗ではない。
          :
          ;;
        *)
          # PROFILE_MIXED・PROFILE_INVALID:*・PROFILE_UNREADABLE等＝実体は
          # あるがv2として妥当でない、または想定外の失敗。「算出不能」を
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

# サンプル雛形の実位置（§3.9 Q2の候補抽出・後段のstep①双方で使う。
# extract_profile_schema_block() 自体はstep①の定義箇所で定義するが、
# 呼び出しはこの変数を経由するため先に定義しておく）。
PROFILE_SAMPLE_SRC="$DIR/vault-public/Preferences/profile-sample.md"

# ============================================================
# 配役表解凍（2026-09-01・設計書§4.2-a〜g・§3.9）: リーダー実行値の解決と
# リーダー配役の対話確定。
# ============================================================

# resolve_leader_runtime — §3.5-Lの実効リーダー候補のmodel/effortを1行JSON
# （例 {"model": "claude-opus-5", "effort": "high"}）で標準出力へ書く
# （成功時・4.2-a）。失敗時は標準出力へ1文字も出さず、標準エラーへ
# `<機械可読コード>\t<短い理由（値を含まない）>`を1行書いてreturn 1
# （4.2-b）。--print-leader-runtime とメイン実行フロー(settings.json生成)の
# 両方がこの1つの関数だけを使う（値出力口の一本化。update-sub.sh・
# check-drift.shも同じ契約の`--print-leader-runtime`だけを呼ぶ設計）。
#
# 2026-09-01 契約更新（担当A確定）: `resolve-leader`は**自己完結**
# （存在確認・symlink拒否・preflight(V15)・分類・parse・全validatorを
# lib内部で行う）。呼び出し側（本関数）は事前チェックを一切重複させず、
# そのまま呼ぶだけでよい（判定式を2箇所に増やさない・BLOCKING対応：
# 従来はここで独自にsymlink/存在/classify判定を行っており、V6/V7/V8/V16等
# leader以外のvalidator違反が有ってもsettings生成へ進みうる欠陥があった）。
# lib自身がv1プロファイルを`PROFILE_LEGACY_V1`として区別して返すため、
# ここでその場合と実体が存在しない`PROFILE_NOT_FOUND`の場合だけ、現行実装
# （AIENV_MODEL_MAIN/AIENV_MODEL_SUBを--sub-delegateの有無で選ぶ）へ委譲し、
# effortはlegacy値"high"を返す（v1委譲期間の後方互換・P1ロールアウト未完了
# 機を落とさないため＝設計§3.5「v1と分類されたときの挙動＝現行実装へ丸ごと
# 委譲する」の一般原則をこの新しい値出力口にも適用する）。それ以外の失敗
# （PROFILE_UNREADABLE・PROFILE_MIXED・PROFILE_INVALID:*・LEADER_*等）は
# そのまま非0で伝播する。
# _print_legacy_leader_runtime_json <model> — v1委譲時のJSON
# {"model": "<model>", "effort": "high"}を安全に組み立てて標準出力へ書く。
# ⚠️ printfでの生文字列埋め込みは、値に`"`・`\`が含まれると不正JSONになる
# （2026-09-01 実測: tests/test-install-sub.sh 4fの`weird"model\value`で
# 再現・AIENV_MODEL_MAIN/SUBは環境変数なので任意の文字列を持ちうる）。
# generate_settings_json()と同じくpython3のjson moduleで組み立てる。
_print_legacy_leader_runtime_json() {
  python3 -c 'import json, sys; print(json.dumps({"model": sys.argv[1], "effort": "high"}))' "$1"
}

resolve_leader_runtime() {
  local path="$AIENV_LOCAL_PROFILE_PATH" lib="$AIENV_PROFILE_RESOLVE_LIB"

  if [ ! -f "$lib" ]; then
    printf 'PROFILE_RESOLVER_MISSING\tresolver本体が見つかりません\n' >&2
    return 1
  fi

  local out err_file
  err_file="$(mktemp 2>/dev/null)" || {
    printf 'PROFILE_RESOLVER_ERROR\t一時ファイルを作成できません\n' >&2
    return 1
  }
  if out="$(python3 "$lib" resolve-leader "$path" \
        --bedrock-env "$AIENV_BEDROCK_ENV_FILE" --agents-dir "$AIENV_AGENTS_DIR" \
        2>"$err_file")"; then
    rm -f "$err_file"
    printf '%s\n' "$out"
    return 0
  fi
  local errline
  errline="$(cat "$err_file" 2>/dev/null)"
  rm -f "$err_file"
  case "$errline" in
    PROFILE_LEGACY_V1*)
      _print_legacy_leader_runtime_json "$AIENV_MODEL_VALUE"
      return 0
      ;;
    PROFILE_NOT_FOUND*)
      # ⚠️ libは「存在しない」と「存在するが通常ファイルではない
      # （ディレクトリ等）」の両方をPROFILE_NOT_FOUNDへ丸める。前者だけを
      # legacy委譲（P1ロールアウト未完了機を落とさない）とし、後者は実体が
      # 壊れているため非0のまま伝播する（ensure_leader_configuredと同じ
      # 判定式・§3.1の対象外を混同しない）。
      # ⚠️ U-7撤去条件（v1互換モードの撤去・両機がschema_version:2確認済み）
      # 成立後は、「実体が本当に存在しない」場合もlegacy委譲(exit 0)ではなく
      # 設計書S2どおり非0終了へ引き上げること（2026-09-01 リーダー裁定・
      # 却下希望1(a)は条件付き承認＝v1互換期間中に限る）。
      if [ -e "$path" ]; then
        printf 'PROFILE_UNREADABLE\tプロファイル実体が壊れています（通常ファイルではありません）\n' >&2
        return 1
      fi
      _print_legacy_leader_runtime_json "$AIENV_MODEL_VALUE"
      return 0
      ;;
    *)
      if [ -n "$errline" ]; then
        printf '%s\n' "$errline" >&2
      else
        printf 'PROFILE_RESOLVER_ERROR\tresolve-leaderが予期せず失敗しました\n' >&2
      fi
      return 1
      ;;
  esac
}

# list_roles_rows <path> — 共有libのlist-rolesを呼び、成功時はTSV行
# （kind\tname\tstate\tprovider\tmodel\texecution\teffort）をそのまま標準
# 出力へ流す。list-rolesは自己完結（存在確認・symlink拒否・preflight・
# 分類・全validatorをlib側が内部で行う契約＝担当A確定）なので、呼び出し側は
# これ以上の事前チェックを重複させない。失敗時は標準出力へ何も出さず、
# 標準エラーへ`<コード>\t<理由>`を1行書いてreturn 1。
list_roles_rows() {
  local path="$1" lib="$AIENV_PROFILE_RESOLVE_LIB" out err_file
  if [ ! -f "$lib" ]; then
    printf 'PROFILE_RESOLVER_MISSING\tresolver本体が見つかりません\n' >&2
    return 1
  fi
  err_file="$(mktemp 2>/dev/null)" || {
    printf 'PROFILE_RESOLVER_ERROR\t一時ファイルを作成できません\n' >&2
    return 1
  }
  if out="$(python3 "$lib" list-roles "$path" 2>"$err_file")"; then
    rm -f "$err_file"
    printf '%s\n' "$out"
    return 0
  fi
  local errline
  errline="$(cat "$err_file" 2>/dev/null)"
  rm -f "$err_file"
  if [ -n "$errline" ]; then
    printf '%s\n' "$errline" >&2
  else
    printf 'PROFILE_RESOLVER_ERROR\tlist-rolesが予期せず失敗しました\n' >&2
  fi
  return 1
}

# find_leader_line_position <path> — role.leader行（フロントマター内・
# 最初の出現）の行番号と、frontmatter終端行番号を
# `LINENO=<n>`/`END_LINENO=<n>`の2行で標準出力へ書く（write_and_verify_leader
# の書込み位置決定専用・状態や属性値は一切読まない）。LINENO=0は「行が存在
# しない（挿入が必要）」を表す。⚠️ 呼び出し時点でlist_roles_rowsが既に成功
# している（＝重複キー等の構文エラーが無いことを確認済み）前提で使う位置
# 特定だけの軽量スキャン——値・状態の正本はlist-rolesのまま。
find_leader_line_position() {
  python3 -c "
import sys
path = sys.argv[1]
try:
    with open(path, encoding='utf-8') as f:
        lines = f.read().splitlines()
except OSError:
    print('LINENO=0'); print('END_LINENO=0'); sys.exit(0)
if not lines or lines[0].strip() != '---':
    print('LINENO=0'); print('END_LINENO=0'); sys.exit(0)
end_idx = None
for i in range(1, len(lines)):
    if lines[i].strip() == '---':
        end_idx = i
        break
if end_idx is None:
    print('LINENO=0'); print('END_LINENO=0'); sys.exit(0)
found = 0
for i in range(1, end_idx):
    if lines[i].strip().startswith('role.leader:'):
        found = i + 1
        break
print(f'END_LINENO={end_idx + 1}')
print(f'LINENO={found}')
" "$1"
}

# parse_leader_role_env <value> — AIENV_LEADER_ROLE（形式:
# "provider=... model=... [effort=...]"・§3.1属性文法と同じ）をデータとして
# 解析する（⚠️ evalしない・§3.9注記）。成功時はENV_PROVIDER/ENV_MODEL/
# ENV_EFFORTを設定してreturn 0。不正な形式・provider/model欠落・属性重複は
# return 1。
parse_leader_role_env() {
  local raw="$1" tok name val rc=0
  ENV_PROVIDER=""; ENV_MODEL=""; ENV_EFFORT=""
  local seen_provider=0 seen_model=0 seen_effort=0
  # ⚠️ `for tok in $raw`は単語分割に加えpathname展開(globbing)も行う
  # （evalではないため直接のコード実行には至らないが、カレントディレクトリの
  # ファイル名次第でトークンが変わりうる＝純粋なデータ解析ではなくなる。
  # Codexレビュー指摘・Minor対応）。一時的に`set -f`でglobを無効化する。
  # ⚠️ 呼び出し元が既に`set -f`（noglob）だった場合に`set +f`で誤って有効化
  # しないよう、元の状態を`$-`から復元する（Codex二次レビュー指摘・Minor対応）。
  local restore_glob=0
  case "$-" in *f*) : ;; *) restore_glob=1 ;; esac
  set -f
  for tok in $raw; do
    case "$tok" in
      *=*) : ;;
      *) rc=1; break ;;
    esac
    name="${tok%%=*}"
    val="${tok#*=}"
    if ! [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || [ -z "$val" ]; then
      rc=1
      break
    fi
    case "$name" in
      provider) [ "$seen_provider" = "1" ] && { rc=1; break; }; ENV_PROVIDER="$val"; seen_provider=1 ;;
      model) [ "$seen_model" = "1" ] && { rc=1; break; }; ENV_MODEL="$val"; seen_model=1 ;;
      effort) [ "$seen_effort" = "1" ] && { rc=1; break; }; ENV_EFFORT="$val"; seen_effort=1 ;;
      *) rc=1; break ;;
    esac
  done
  [ "$restore_glob" = "1" ] && set +f
  [ "$rc" -eq 0 ] || return 1
  [ -n "$ENV_PROVIDER" ] && [ -n "$ENV_MODEL" ] || return 1
  return 0
}

leader_attrs_match() {
  # $1-3: 既存(provider,model,effort) $4-6: env指定(provider,model,effort)
  [ "$1" = "$4" ] && [ "$2" = "$5" ] && [ "${3:-}" = "${6:-}" ]
}

# write_and_verify_leader <provider> <model> <effort> — §3.9の書込み手順:
# 専用ロック取得→再検証(check-candidate --for-leader)→role.leader行1行だけを
# 置換/挿入→commit直前のpreimage一致確認→原子的place。既存のファイルmode・
# 所有者を維持し、書換前にbackup_once()でbackupを取る。他の行には一切触れない。
write_and_verify_leader() {
  # $4=preimage: 呼び出し元（ensure_leader_configured）がロック取得後・
  # 「未確定かどうかを読む」その時点で採取したSHA-256を必ず渡す
  # （2026-09-01 Codex二次レビュー指摘・BLOCKING対応: 従来はこの関数の冒頭で
  # 都度再計算しており、「読取→対話→再検証→書込み」の間に他プロセス／本人が
  # profileを編集していても、対話終了後にここで“今の”内容を新たなpreimageと
  # して受理してしまい、commit直前の一致確認が意味を持たなくなっていた。
  # ロック取得後の最初の読取り時点を正本のpreimageとして固定する）。
  local provider="$1" model="$2" effort="$3" preimage="$4" path="$AIENV_LOCAL_PROFILE_PATH"

  [ -n "$preimage" ] || fail "role.leaderの書込み準備に失敗しました（プロファイルのpreimageがありません）: $path"

  if ! python3 "$AIENV_PROFILE_RESOLVE_LIB" check-candidate \
        --provider "$provider" --model "$model" ${effort:+--effort "$effort"} \
        --for-leader --role-name leader \
        --bedrock-env "$AIENV_BEDROCK_ENV_FILE" --agents-dir "$AIENV_AGENTS_DIR" \
        >/dev/null 2>&1; then
    fail "LEADER_CANDIDATE_INVALID: 指定された配役の検証(check-candidate)に失敗しました（provider/model/effortの組み合わせを見直してください）"
  fi

  local pos_out leader_lineno=0 leader_end_lineno=0 k v
  pos_out="$(find_leader_line_position "$path")"
  while IFS='=' read -r k v; do
    case "$k" in
      LINENO) leader_lineno="$v" ;;
      END_LINENO) leader_end_lineno="$v" ;;
    esac
  done <<EOF_POS
$pos_out
EOF_POS

  local newline="role.leader:               configured provider=${provider} model=${model}"
  [ -n "$effort" ] && newline="${newline} effort=${effort}"

  backup_once "$path"

  local orig_mode orig_uid orig_gid
  orig_mode="$(stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path" 2>/dev/null || echo '')"
  orig_uid="$(stat -f '%u' "$path" 2>/dev/null || stat -c '%u' "$path" 2>/dev/null || echo '')"
  orig_gid="$(stat -f '%g' "$path" 2>/dev/null || stat -c '%g' "$path" 2>/dev/null || echo '')"

  local tmp
  tmp="$(mktemp "$(dirname "$path")/.$(basename "$path").aienv-tmp.XXXXXX")"
  # ⚠️ この関数は他の関数（ensure_leader_configured・run_leader_dialog）の
  # 内側から呼ばれる（トップレベルからの直接呼び出しではない）。bash 3.2では
  # `trap ... RETURN`がこの関数のreturnで消えず、呼び出し元の後続return
  # まで漏れて「$tmpが無い」unbound variableを起こす実挙動を確認済み
  # （関数のネストが無いgenerate_settings_json等の既存箇所では問題にならない
  # パターンだが、ここでは踏む）。そのためRETURN trapは使わず、失敗パスは
  # fail()の即時exitに任せる（既存のgenerate_settings_json等と同じく、
  # 異常系でのtmpファイル残置は許容する）。

  if [ "$leader_lineno" -gt 0 ] 2>/dev/null; then
    awk -v n="$leader_lineno" -v newline="$newline" 'NR==n{print newline; next} {print}' "$path" > "$tmp"
  else
    if ! [ "$leader_end_lineno" -gt 0 ] 2>/dev/null; then
      fail "role.leader行を挿入する位置（frontmatter終端）が特定できません: $path"
    fi
    python3 -c "
import sys
path, newline, outpath, end_lineno = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
with open(path, encoding='utf-8') as f:
    lines = f.readlines()
lines.insert(end_lineno - 1, newline + '\n')
with open(outpath, 'w', encoding='utf-8') as f:
    f.writelines(lines)
" "$path" "$newline" "$tmp" "$leader_end_lineno" || fail "role.leader行の挿入に失敗しました: $path"
  fi

  # ⚠️ ベストエフォート（既存モード/所有者の維持は§3.9の望ましい振る舞いで
  # あって必須要件ではない）。`A && B`は`B`が失敗すると複合コマンド全体の
  # 終了ステータスが非0になり、素の文として書くと`set -e`でここが即終了して
  # しまう（2026-09-01 実測: `chown`は`/usr/sbin/`にありPATHが絞られた環境
  # 〈tests/test-install-main-codex-mcp.sh〉ではcommand not found=127になり、
  # role.leaderの書込み自体が中断していた）。`|| true`で必ず後続へ進める。
  if [ -n "$orig_mode" ]; then
    chmod "$orig_mode" "$tmp" 2>/dev/null || true
  fi
  if [ -n "$orig_uid" ] && [ -n "$orig_gid" ]; then
    chown "$orig_uid:$orig_gid" "$tmp" 2>/dev/null || true
  fi

  local now_hash
  now_hash="$(shasum -a 256 "$path" 2>/dev/null | awk '{print $1}')" || true
  if [ "$now_hash" != "$preimage" ]; then
    fail "並行installerを検出しました（書込み直前にプロファイルが変更されていました）。中止します: $path"
  fi

  mv "$tmp" "$path"
  log "role.leader を確定しました（値はログに出しません）: $path"
}

can_interact() {
  [ "$NON_INTERACTIVE" = "1" ] && return 1
  [ "$AIENV_FORCE_TTY_FOR_TEST" = "1" ] && return 0
  [ -t 0 ] || return 1
  return 0
}

# _read_with_timeout <varname> <timeout> — タイムアウト付きで1行読む。
# 成功時varnameへ設定してreturn 0。タイムアウト・EOFはいずれもreturn 2
# （§3.9「EOF・端末切断・タイムアウトはいずれも非0終了として扱う」。
# 呼び出し側でこれ以上区別する必要が無いため単一のコードにまとめている）。
_read_with_timeout() {
  local __var="$1" __timeout="$2" __val=""
  if ! IFS= read -r -t "$__timeout" __val; then
    return 2
  fi
  printf -v "$__var" '%s' "$__val"
  return 0
}

# sample_model_candidates <provider> — 配布済みサンプル
# （$PROFILE_SAMPLE_SRC）の```yamlブロックを既存の抽出処理
# （extract_profile_schema_block・step①の定義箇所参照）で取り出し、
# 同じprofile parser（共有lib・list_roles_rows()経由）でconfiguredな行を
# 解析して、指定providerのmodel値を重複排除して1行1候補で返す（§3.9 Q2）。
# ⚠️ list-rolesはサンプルの全行を構造検証し、1行でも不正なら出力全体を
# 失敗させる契約（contract §4.5）。**不正な行だけを落として残りを候補に
# することはしない**——候補一覧を丸ごと使わず「自分で入力」へ倒す
# （呼び出し側=ask_q2側の設計。壊れたサンプルからたまたま形式に適合した
# 行だけを提示すると、それ自体が誤った既定値の押し付けになるため）。
# ⚠️ 候補が0件のとき（サンプルが読めない・yaml抽出に失敗・list-rolesの
# 構造検証に失敗・選んだproviderのconfigured行が0件のいずれか）は、
# 呼び出し側が理由を区別して表示できるよう `SAMPLE_CANDIDATES_REASON` へ
# 4区分のいずれか（`SAMPLE_UNREADABLE` / `YAML_EXTRACT_FAILED` /
# `STRUCTURE_INVALID` / `PROVIDER_NO_CANDIDATES`）を設定して返す
# （F-22・設計書v11 §3.9 Q2「候補を出せないときは理由を必ず区別して出す」。
# 黙って「候補なし」にしない）。共有libが見つからない場合
# （list_roles_rows()のPROFILE_RESOLVER_MISSING）は構造検証自体ができない
# ため`STRUCTURE_INVALID`側へ倒す。
sample_model_candidates() {
  local provider="$1" tmp roles_out out extract_rc
  SAMPLE_CANDIDATES_REASON=""
  if [ ! -f "$PROFILE_SAMPLE_SRC" ]; then
    SAMPLE_CANDIDATES_REASON="SAMPLE_UNREADABLE"
    return 0
  fi
  tmp="$(mktemp 2>/dev/null)" || {
    SAMPLE_CANDIDATES_REASON="SAMPLE_UNREADABLE"
    return 0
  }
  # ⚠️ `[ -f ]`は存在確認だけで読取可能性を保証しない（2026-09-01工程横断
  # レビュー指摘・MINOR-1対応）。実在するのに権限不足・不正UTF-8で読めない
  # サンプルは、extract_profile_schema_block()がexit 2（読取/デコード失敗）
  # を返すので、フェンス不在のexit 1（YAML_EXTRACT_FAILED）とここで区別する。
  extract_rc=0
  extract_profile_schema_block "$PROFILE_SAMPLE_SRC" > "$tmp" 2>/dev/null || extract_rc=$?
  if [ "$extract_rc" -ne 0 ]; then
    rm -f "$tmp"
    if [ "$extract_rc" -eq 2 ]; then
      SAMPLE_CANDIDATES_REASON="SAMPLE_UNREADABLE"
    else
      SAMPLE_CANDIDATES_REASON="YAML_EXTRACT_FAILED"
    fi
    return 0
  fi
  if ! roles_out="$(list_roles_rows "$tmp" 2>/dev/null)"; then
    rm -f "$tmp"
    SAMPLE_CANDIDATES_REASON="STRUCTURE_INVALID"
    return 0
  fi
  rm -f "$tmp"
  out="$(printf '%s\n' "$roles_out" \
    | awk -F'\t' -v p="$provider" '$3=="configured" && $4==p {print $5}' \
    | awk '!seen[$0]++')"
  if [ -z "$out" ]; then
    SAMPLE_CANDIDATES_REASON="PROVIDER_NO_CANDIDATES"
    return 0
  fi
  printf '%s\n' "$out"
}

ask_q1() {
  local default_provider="$1" input default_no=""
  case "$default_provider" in
    anthropic-api) default_no=1 ;;
    bedrock) default_no=2 ;;
    bedrock-mantle) default_no=3 ;;
  esac
  {
    echo "Q1) リーダーの provider を選んでください:"
    echo "  1) anthropic-api"
    echo "  2) bedrock"
    echo "  3) bedrock-mantle"
    [ -n "$default_no" ] && echo "  (Enterで既存値を維持)"
    printf '番号> '
  } >&2
  _read_with_timeout input "$AIENV_LEADER_DIALOG_TIMEOUT" || return 2
  if [ -z "$input" ] && [ -n "$default_no" ]; then
    input="$default_no"
  fi
  case "$input" in
    1) echo "anthropic-api" ;;
    2) echo "bedrock" ;;
    3) echo "bedrock-mantle" ;;
    *) return 1 ;;
  esac
}

ask_q2() {
  local provider="$1" default_model="$2" input candidates count=0 c i=1 reason_text cand_tmp
  # ⚠️ sample_model_candidates()をコマンド置換`$( )`で直接呼ぶと、関数が
  # サブシェルで実行されSAMPLE_CANDIDATES_REASONへの代入が呼び出し側へ
  # 反映されない（bashの既知の挙動。実測: set -u下でunbound variableに
  # なった＝2026-09-01実装時に発見）。標準出力だけを一時ファイルへ
  # リダイレクトする形（サブシェルを作らない）で呼び、候補は後からその
  # ファイルを読んで得る。
  cand_tmp="$(mktemp 2>/dev/null)" || cand_tmp="/dev/null"
  sample_model_candidates "$provider" > "$cand_tmp" 2>/dev/null
  if [ "$cand_tmp" != "/dev/null" ]; then
    candidates="$(cat "$cand_tmp" 2>/dev/null)"
    rm -f "$cand_tmp"
  else
    candidates=""
  fi
  {
    echo "Q2) model を選んでください（provider=${provider}）:"
    if [ -n "$candidates" ]; then
      while IFS= read -r c; do
        [ -z "$c" ] && continue
        echo "  $i) $c"
        i=$((i + 1))
      done <<EOF_CANDIDATES
$candidates
EOF_CANDIDATES
      count=$((i - 1))
    else
      # ⚠️ 候補一覧を生成できない理由は必ず4区分のいずれかで区別して表示
      # する（F-22・設計書v11 §3.9 Q2）。黙って「候補なし」とだけ出さない。
      # 不正行の全文・属性値は出さない（§3.1-8。SAMPLE_CANDIDATES_REASONは
      # 区分コードのみを持ち、list-rolesのエラー詳細文字列は保持しない）。
      case "$SAMPLE_CANDIDATES_REASON" in
        SAMPLE_UNREADABLE) reason_text="サンプル読取不能" ;;
        YAML_EXTRACT_FAILED) reason_text="yaml 抽出失敗" ;;
        PROVIDER_NO_CANDIDATES) reason_text="選択した provider の候補が0件" ;;
        *) reason_text="構造検証失敗" ;;
      esac
      echo "  候補一覧を生成できません（理由: ${reason_text}）。候補は使わず model を手入力してください"
    fi
    echo "  0) 自分で入力する"
    [ -n "$default_model" ] && echo "  (Enterで既存値を維持)"
    printf '番号> '
  } >&2
  _read_with_timeout input "$AIENV_LEADER_DIALOG_TIMEOUT" || return 2
  if [ -z "$input" ] && [ -n "$default_model" ]; then
    echo "$default_model"
    return 0
  fi
  if [ "$input" = "0" ]; then
    printf 'model の値を入力してください> ' >&2
    _read_with_timeout input "$AIENV_LEADER_DIALOG_TIMEOUT" || return 2
    [ -z "$input" ] && return 1
    echo "$input"
    return 0
  fi
  if [[ "$input" =~ ^[0-9]+$ ]] && [ "$count" -gt 0 ] && [ "$input" -ge 1 ] && [ "$input" -le "$count" ]; then
    printf '%s\n' "$candidates" | sed -n "${input}p"
    return 0
  fi
  return 1
}

ask_q3() {
  local default_effort="$1" input
  {
    echo "Q3) effort を選んでください:"
    echo "  1) 未指定（セッション既定を継承）"
    echo "  2) low"
    echo "  3) medium"
    echo "  4) high"
    echo "  5) xhigh"
    [ -n "$default_effort" ] && echo "  (Enterで既存値を維持)"
    printf '番号> '
  } >&2
  _read_with_timeout input "$AIENV_LEADER_DIALOG_TIMEOUT" || return 2
  if [ -z "$input" ] && [ -n "$default_effort" ]; then
    echo "$default_effort"
    return 0
  fi
  case "$input" in
    1) echo "" ;;
    2) echo "low" ;;
    3) echo "medium" ;;
    4) echo "high" ;;
    5) echo "xhigh" ;;
    *) return 1 ;;
  esac
}

# run_leader_dialog <default_provider> <default_model> <default_effort> <preimage> —
# Q1→Q2→Q3の1組を検査し、3回失敗したら中止する（§3.9「回数はこの組単位で
# 数える」）。EOF・タイムアウト・端末切断は即時非0（リトライしない）。
# <preimage>はensure_leader_configuredがロック取得後の最初の読取り時点で
# 採取した値をそのままwrite_and_verify_leaderへ引き継ぐ。
run_leader_dialog() {
  local default_provider="$1" default_model="$2" default_effort="$3" preimage="$4"
  local attempt provider model effort rc

  for attempt in 1 2 3; do
    # ⚠️ `x="$(f)"; rc=$?`は`set -e`下で危険（`f`が非0を返すとこの代入文
    # 自体の終了コードが非0になり、`rc=$?`へ辿り着く前にerrexitで即終了する）。
    # 必ず`|| rc=$?`で代入コマンドそのものをガードする。
    rc=0
    provider="$(ask_q1 "$default_provider")" || rc=$?
    if [ "$rc" -eq 2 ]; then fail "LEADER_DIALOG_ABORTED: 対話が中断されました（EOF/タイムアウト/端末切断）"; fi
    if [ "$rc" -ne 0 ]; then warn "Q1(provider)の入力が不正でした（${attempt}/3回目）。もう一度お答えください。"; continue; fi

    rc=0
    model="$(ask_q2 "$provider" "$default_model")" || rc=$?
    if [ "$rc" -eq 2 ]; then fail "LEADER_DIALOG_ABORTED: 対話が中断されました（EOF/タイムアウト/端末切断）"; fi
    if [ "$rc" -ne 0 ]; then warn "Q2(model)の入力が不正でした（${attempt}/3回目）。もう一度お答えください。"; continue; fi

    rc=0
    effort="$(ask_q3 "$default_effort")" || rc=$?
    if [ "$rc" -eq 2 ]; then fail "LEADER_DIALOG_ABORTED: 対話が中断されました（EOF/タイムアウト/端末切断）"; fi
    if [ "$rc" -ne 0 ]; then warn "Q3(effort)の入力が不正でした（${attempt}/3回目）。もう一度お答えください。"; continue; fi

    if python3 "$AIENV_PROFILE_RESOLVE_LIB" check-candidate \
         --provider "$provider" --model "$model" ${effort:+--effort "$effort"} \
         --for-leader --role-name leader \
         --bedrock-env "$AIENV_BEDROCK_ENV_FILE" --agents-dir "$AIENV_AGENTS_DIR" \
         >/dev/null 2>&1; then
      write_and_verify_leader "$provider" "$model" "$effort" "$preimage"
      return 0
    fi
    warn "入力された配役の検証に失敗しました（${attempt}/3回目）。もう一度お答えください。"
  done
  fail "LEADER_DIALOG_FAILED: リーダー配役の対話が3回とも検証に失敗したため中止しました"
}

# ensure_leader_configured — §3.9の入力優先順位表（10行）どおりにrole.leader
# を確定させる。v1/混在プロファイル・DRY_RUN・実体不在・lib不在ではv2の
# ときだけ動く対話には踏み込まない（それぞれ理由は各分岐のコメント参照）。
ensure_leader_configured() {
  local path="$AIENV_LOCAL_PROFILE_PATH"

  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] リーダー配役を対話で確認します"
    return 0
  fi

  # list-rolesは自己完結（存在確認・symlink拒否・preflight・分類・全
  # validatorをlib内部で行う契約）。ここでの独自の事前チェックは重複させ
  # ない。PROFILE_LEGACY_V1／PROFILE_NOT_FOUND（実体無し・P1未整備機）は
  # 対話しない（v1委譲・legacy委譲はresolve_leader_runtime側の責務）。
  # それ以外の失敗（PROFILE_MIXED・PROFILE_INVALID:*等＝実体そのものが
  # 壊れている）も、ここでは書き込みを試みず、後段のresolve_leader_runtime
  # が同じエラーを検出してsettings生成を中止する（判定式を2箇所に増やさ
  # ない）。⚠️ 例外＝AIENV_LEADER_ROLE/--reconfigure-leader指定時は
  # PROFILE_LEGACY_V1で明示的にfail（v1実体へv2の行を書き足して混在を
  # 自分で作ってしまう経路を塞ぐ・§3.9）。
  #
  # ⚠️ BLOCKING対応（2026-09-01 Codex一次レビュー指摘）: ロックは「未確定
  # かどうかを読む」時点から取得し、settings生成完了まで（プロセス終了時の
  # EXIT trapで自動解放されるまで）保持する。読取りをロック外で行うと、
  # 2つのinstallerが別々に「未確定」を読んで別々の回答を確定させたあと、
  # ロックが直列化するのは書込みの機械的な部分だけになり、後勝ちが前者の
  # 回答を静かに上書きするlost updateを防げない（§3.9「読取→対話→再検証→
  # profile更新→settings生成を専用ロックで直列化する」の「読取」を含む）。
  # ロックはこの1箇所だけで取得し、write_and_verify_leader側では再取得
  # しない（pid-lock.shは同一プロセスからの再取得を「別プロセスが実行中」
  # と誤認し、即exit 0でスクリプト全体を打ち切ってしまうため）。
  # ⚠️ pid-lock.sh自体はスクリプル冒頭（トップレベル）で既にsourceして
  # ある——関数の中でsourceすると、pid-lock.sh側の`declare -a
  # _PID_LOCK_ACQUIRED_FILES=()`がbashの仕様でこの関数にlocal化されてしまい
  # （2026-09-01 実測: `source`をこの関数内で行っていたところ、成功時も
  # 失敗時もEXIT trapによるロックファイルの自動削除が一切起きない実害を
  # 確認した＝関数return時にlocal配列が消え、EXIT trap発火時には空配列を
  # 見てcleanupが何もしない）、EXIT trapでの解放が機能しなくなる。
  acquire_pid_lock "$AIENV_LEADER_LOCK_FILE" "$AIENV_LEADER_LOCK_STALE_SECONDS" "install-main-leader"

  # ⚠️ preimageはロック取得後・最初の読取り（list_roles_rows）と同じ時点で
  # 採取する（2026-09-01 Codex二次レビュー指摘・BLOCKING対応: 対話の後・
  # write_and_verify_leader内で採り直すと、「読取った時点」ではなく「対話が
  # 終わった時点」の内容を正当なpreimageとして受理してしまい、対話中に
  # 本人・他プロセスがprofileを編集していても検出できない）。write_and_
  # verify_leaderへは常にこの値を渡す。
  local leader_preimage
  leader_preimage="$(shasum -a 256 "$path" 2>/dev/null | awk '{print $1}')" || true

  local rows rows_rc=0 rows_err_tmp rows_err
  rows_err_tmp="$(mktemp 2>/dev/null)" || return 0
  if ! rows="$(list_roles_rows "$path" 2>"$rows_err_tmp")"; then
    rows_rc=1
  fi
  rows_err="$(cat "$rows_err_tmp" 2>/dev/null)"
  rm -f "$rows_err_tmp"

  if [ "$rows_rc" -ne 0 ]; then
    case "$rows_err" in
      PROFILE_LEGACY_V1*)
        # v1実体が既にある。v2の行を書き足すと混在(T3')を自分で作って
        # しまうため、AIENV_LEADER_ROLE/--reconfigure-leader指定時は明示的に
        # fail（§3.9「v1と分類されたら対話しない」）。
        if [ -n "${AIENV_LEADER_ROLE:-}" ] || [ "$RECONFIGURE_LEADER" = "1" ]; then
          fail "プロファイルがv2形式ではありません（v1）。先に schema_version: 2 と職種行への移行を行ってから、リーダー配役の指定/対話をやり直してください: $path"
        fi
        return 0
        ;;
      PROFILE_NOT_FOUND*)
        # ⚠️ libは「存在しない」と「存在するが通常ファイルではない
        # （ディレクトリ等）」の両方をPROFILE_NOT_FOUNDへ丸める
        # （_load_and_validate_v2_self_containedはos.path.isfile()のみで
        # 判定）。前者はP1ロールアウト未完了機の正常な状態（AIENV_LEADER_ROLE
        # を指定していても、書き込み先のv2実体が無いだけなので単に無視して
        # legacy委譲へ進む）だが、後者は実体が壊れている（§3.1の対象外）ので
        # 混在させず区別する。
        if [ -e "$path" ]; then
          fail "プロファイル実体が壊れています（通常ファイルではありません）: $path"
        fi
        return 0
        ;;
      *)
        return 0
        ;;
    esac
  fi

  LEADER_STATE=""; LEADER_PROVIDER=""; LEADER_MODEL=""; LEADER_EFFORT=""
  local kind name state provider model execution effort
  while IFS=$'\t' read -r kind name state provider model execution effort; do
    if [ "$kind" = "role" ] && [ "$name" = "leader" ]; then
      LEADER_STATE="$state"
      LEADER_PROVIDER="$provider"
      LEADER_MODEL="$model"
      LEADER_EFFORT="$effort"
      break
    fi
  done <<EOF_ROWS
$rows
EOF_ROWS
  # 行そのものが無い＝§3.1規約6「未記載・空はunknown」と同じ扱い（挿入が
  # 必要な状態としてwrite_and_verify_leaderが処理する）。
  [ -n "$LEADER_STATE" ] || LEADER_STATE="unknown"

  if [ -n "${AIENV_LEADER_ROLE:-}" ]; then
    parse_leader_role_env "$AIENV_LEADER_ROLE" \
      || fail "AIENV_LEADER_ROLE の形式が不正です（'provider=... model=... [effort=...]' の形で指定してください）"
  fi

  case "$LEADER_STATE" in
    configured)
      if [ -n "${AIENV_LEADER_ROLE:-}" ]; then
        if [ "$RECONFIGURE_LEADER" = "1" ]; then
          write_and_verify_leader "$ENV_PROVIDER" "$ENV_MODEL" "$ENV_EFFORT" "$leader_preimage"
          return 0
        fi
        if leader_attrs_match "$LEADER_PROVIDER" "$LEADER_MODEL" "$LEADER_EFFORT" \
             "$ENV_PROVIDER" "$ENV_MODEL" "$ENV_EFFORT"; then
          return 0
        fi
        fail "LEADER_ROLE_CONFLICT: AIENV_LEADER_ROLE が既存の role.leader と一致しません（変えるには --reconfigure-leader を付けてください）"
      fi
      if [ "$RECONFIGURE_LEADER" != "1" ]; then
        log "リーダー配役は確定済みです（変更するには --reconfigure-leader）"
        return 0
      fi
      if can_interact; then
        run_leader_dialog "$LEADER_PROVIDER" "$LEADER_MODEL" "$LEADER_EFFORT" "$leader_preimage"
      else
        fail "LEADER_UNCONFIGURED_NONINTERACTIVE: 非対話環境のため --reconfigure-leader でのリーダー変更はできません（AIENV_LEADER_ROLE を指定するか、対話可能な端末から実行してください）"
      fi
      ;;
    unavailable)
      # §3.5-L: unavailableは本命を評価せず直接fallback評価へ進む
      # （§3.9の対話対象＝「未確定」はunknown/not_adopted/行が無いの3種のみ
      # で、unavailableは含まれない。設計に無い対話分岐を追加しない）。
      # fallback評価・空席判定はresolve_leader_runtime側の責務。
      return 0
      ;;
    unknown|not_adopted)
      if [ -n "${AIENV_LEADER_ROLE:-}" ]; then
        write_and_verify_leader "$ENV_PROVIDER" "$ENV_MODEL" "$ENV_EFFORT" "$leader_preimage"
        return 0
      fi
      if can_interact; then
        run_leader_dialog "" "" "" "$leader_preimage"
      else
        fail "LEADER_UNCONFIGURED_NONINTERACTIVE: リーダー配役が未確定です（role.leader: ${LEADER_STATE}）。対話できない環境のため中止しました（AIENV_LEADER_ROLE を指定するか、対話可能な端末から実行してください）"
      fi
      ;;
    *)
      fail "role.leader の状態を判定できません（想定外の値）: $path"
      ;;
  esac
}

# check_profile_cmd — 4.2-e。副作用ゼロの検査口。provider/modelごとに職種を
# グループ化した配役一覧を表示する。list-roles（担当A確定・自己完結契約）で
# 構造を取得し、resolve()でFALLBACK/VACANT/ADVISORY等の状態を補う。
check_profile_cmd() {
  local path="$AIENV_LOCAL_PROFILE_PATH" lib="$AIENV_PROFILE_RESOLVE_LIB"

  command -v python3 >/dev/null 2>&1 || fail "python3 が見つかりません（--check-profile の実行に必要です）"
  [ -f "$lib" ] || fail "resolver本体（$lib）が見つかりません"

  if [ "$CHECK_PROFILE_SCHEMA_VERSION_ONLY" = "1" ]; then
    # print-schema-versionは自己完結ではない既存契約（§6）のため、
    # 呼び出し前チェックをここでだけ維持する。
    [ -L "$path" ] && fail "プロファイルがsymlinkです（--check-profile非対応）: $path"
    [ -e "$path" ] || fail "プロファイル実体が見つかりません: $path"
    local ver
    if ver="$(python3 "$lib" print-schema-version "$path" 2>/dev/null)"; then
      printf '%s\n' "$ver"
      exit 0
    fi
    exit 1
  fi

  # list-rolesは自己完結（存在確認・symlink拒否・preflight・分類・全
  # validatorをlib内部で行う契約＝担当A確定）。成功すればそれだけでv2かつ
  # 妥当と分かるため、独自の事前チェック・classify呼び出しを重複させない。
  local roles_tsv roles_rc=0 roles_err_tmp roles_err
  roles_err_tmp="$(mktemp 2>/dev/null)" || fail "一時ファイルを作成できません"
  if ! roles_tsv="$(python3 "$lib" list-roles "$path" 2>"$roles_err_tmp")"; then
    roles_rc=1
  fi
  roles_err="$(cat "$roles_err_tmp" 2>/dev/null)"
  rm -f "$roles_err_tmp"

  if [ "$roles_rc" -ne 0 ]; then
    case "$roles_err" in
      PROFILE_LEGACY_V1*)
        log "プロファイルはv2形式ではありません（v1）。v1互換のまま運用されています。v2へ移行してください（§3.5）。"
        exit 0
        ;;
      *)
        printf '%s\n' "$roles_err"
        exit 1
        ;;
    esac
  fi

  local resolve_line rc=0
  resolve_line="$(python3 "$lib" resolve "$path" --bedrock-env "$AIENV_BEDROCK_ENV_FILE" --agents-dir "$AIENV_AGENTS_DIR")" || rc=$?
  printf '%s\n' "$resolve_line"

  # ⚠️ resolveが非0（V9-d③のBedrock有効性・V12のピン留め等・list-rolesの
  # 全validatorだけでは検出できない候補評価の失敗）のときは配役一覧の表示を
  # 省略し、resolveの結果（機械可読な状態）だけで終了する（2026-09-01 Codex
  # 二次レビュー指摘・MAJOR対応：list-roles成功後でもresolveが失敗しうる
  # ため、一覧を無条件に出すと「検証に失敗した実体の値」を見せてしまう）。
  if [ "$rc" -ne 0 ]; then
    exit "$rc"
  fi

  log "配役一覧（provider/modelでグループ化。値は再掲であり§4.1-f一般則の例外＝人が手編集を確認するための唯一の非AI向け表示）:"
  # ⚠️ effortが実行値になるのはrole.leader（実効候補）だけで、ワーカー行は
  # 「参考値（実行値ではない）」（§3.8）。leader行にはこの注記を付けない
  # （2026-09-01 Codex二次レビュー指摘・MAJOR対応）。
  printf '%s\n' "$roles_tsv" \
    | awk -F'\t' '
        $3=="configured" || $3=="unavailable" {
          line = $1"."$2"("$3")"
          if ($7 != "") {
            if ($1 == "role" && $2 == "leader") {
              line = line " effort=" $7
            } else {
              line = line " effort=" $7 "（参考値・実行値ではない）"
            }
          }
          print $4"/"$5"\t" line
        }' \
    | sort \
    | awk -F'\t' '{
        key=$1
        if (key != prev) { if (prev != "") print ""; print key ":"; prev = key }
        print "  - " $2
      }'

  exit 0
}

# AIENV_DEFERRED_EXIT_CODE — 2026-09-01 リーダー裁定（差し戻し対応）:
# 「settings.json以外の処理は続行させたいが、最終的な終了コードは非0にする
# 必要がある」状態（例＝bedrock.envが実在するのに読めない/解析できない・
# 設計書§6.2-B S4／動的Bedrock許可キーの算出失敗・S18）を記録する。
# generate_settings_json()内（S4等）、または動的Bedrock許可キーの算出直後の
# 生成前判定ブロック（S18）で立て、スクリプト末尾でこれを見て最終exit code
# へ反映する（他の処理を中断させない・値を再掲しないWARNは各所で既に
# 出している前提）。
AIENV_DEFERRED_EXIT_CODE=0
DRY_RUN=0
WITH_DOTFILES=0
IS_SUB_DELEGATE=0
PRINT_MODEL=0
PRINT_BEDROCK_ENV_JSON=0
PRINT_LEADER_RUNTIME=0
CHECK_PROFILE=0
CHECK_PROFILE_SCHEMA_VERSION_ONLY=0
RECONFIGURE_LEADER=0
NON_INTERACTIVE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --with-dotfiles) WITH_DOTFILES=1 ;;
    --sub-delegate) IS_SUB_DELEGATE=1 ;;
    --print-model) PRINT_MODEL=1 ;;
    --print-bedrock-env-json) PRINT_BEDROCK_ENV_JSON=1 ;;
    --print-leader-runtime) PRINT_LEADER_RUNTIME=1 ;;
    --check-profile) CHECK_PROFILE=1 ;;
    # --print-schema-version は --check-profile のサブモード（4.2-e）。
    # 単独では意味を持たない（--check-profileが無ければ無視される）。
    --print-schema-version) CHECK_PROFILE_SCHEMA_VERSION_ONLY=1 ;;
    --reconfigure-leader) RECONFIGURE_LEADER=1 ;;
    --non-interactive) NON_INTERACTIVE=1 ;;
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
  # 2026-09-01 配役表解凍 §4.2-d: 許可リストは固定2キー＋動的キー
  # （compute_allowed_bedrock_env_keys()）の和集合にしてから解析する
  # （settings.json生成側と同じ値表を使う＝check-drift.shの期待値計算が
  # 実際にsettings.jsonへ反映される集合と一致し続けるようにするため）。
  command -v python3 >/dev/null 2>&1 || fail "python3 が見つかりません（--print-bedrock-env-json の実行に必要です）"
  # ⚠️ 動的キー算出（compute_allowed_bedrock_env_keys）の失敗はfail-openで
  # 固定2キーへ丸めない（2026-09-01 Codexレビュー指摘・MAJOR対応）。
  # --print-bedrock-env-jsonはupdate-sub.sh/check-drift.shの唯一の値出力口
  # であり、「算出不能」を「Bedrock役職なし」と混同すると動的pinが欠けた
  # 不完全な集合をexit 0で返してしまう（test 16と同じ「fail-openで偽装
  # しない」契約をここにも揃える）。
  _bedrock_keys_tmp="$(mktemp 2>/dev/null)" || fail "一時ファイルを作成できません"
  _bedrock_keys_err="$(compute_allowed_bedrock_env_keys 2>&1 1>"$_bedrock_keys_tmp")" || {
    rm -f "$_bedrock_keys_tmp"
    fail "動的Bedrock許可キーの算出に失敗しました（${_bedrock_keys_err:-不明なエラー}）"
  }
  AIENV_ALLOWED_BEDROCK_ENV_KEYS=()
  while IFS= read -r _bedrock_allowed_key; do
    [ -n "$_bedrock_allowed_key" ] && AIENV_ALLOWED_BEDROCK_ENV_KEYS+=("$_bedrock_allowed_key")
  done < "$_bedrock_keys_tmp"
  rm -f "$_bedrock_keys_tmp"
  # compute_bedrock_env_json()の終了コードをそのまま呼び出し元へ伝える
  # （ファイルが存在するのに読取・解析に失敗した場合は非0終了する。
  # 2026-08-30 Codex二次レビュー指摘・Major対応: fail-openで{}を返して
  # しまうと呼び出し側が「監視できていないのに一致」と誤判定しうる）。
  bedrock_env_json_rc=0
  compute_bedrock_env_json "$AIENV_BEDROCK_ENV_FILE" || bedrock_env_json_rc=$?
  exit "$bedrock_env_json_rc"
fi

# --print-leader-runtime: 実効リーダー候補のmodel/effortを1行JSONで印字して
# 即終了する（副作用ゼロ・4.2-a）。resolve_leader_runtime()の戻り値を
# そのまま伝播する（成功時stdoutにJSON・失敗時stdoutは空でstderrに機械可読
# コード）。install-main・update-sub.sh・check-drift.shの3者が今後この
# 出力口だけを使う。
if [ "$PRINT_LEADER_RUNTIME" = "1" ]; then
  command -v python3 >/dev/null 2>&1 || fail "python3 が見つかりません（--print-leader-runtime の実行に必要です）"
  leader_runtime_rc=0
  resolve_leader_runtime || leader_runtime_rc=$?
  exit "$leader_runtime_rc"
fi

# --check-profile: 副作用ゼロの検査口（4.2-e）。check_profile_cmd()が
# 自身でexitする。
if [ "$CHECK_PROFILE" = "1" ]; then
  check_profile_cmd
fi

# python3依存の早期チェック（Codex二次レビュー指摘・Minor対応: generate_settings_json()が
# claude/settings.json生成にpython3のjson moduleを必須で使うようになった＝2026-08-21。
# マーカー書込・symlink化等の実処理が始まってから中途半端な状態でpython3不在に
# 気付くより、着手前に明確な指示を出す方が親切。--dry-run は実際には何も生成
# しない＝python3を必要としないため対象外にする）。macOSは通常システムpython3
# （またはXcode Command Line Tools経由）を持つため通常は問題にならない想定。
if [ "$DRY_RUN" != "1" ]; then
  command -v python3 >/dev/null 2>&1 || fail_settings_generation "python3 が見つかりません（claude/settings.json の生成に必要です）。Xcode Command Line Tools（xcode-select --install）等でpython3を導入してから再実行してください。"
fi

# バックアップは「.pre-aienv.bak がまだ無いときだけ」作る（何度実行しても
# 常にインストール前オリジナルを保持する。symlink化後は dest が symlink に
# なるため自然と対象外になるが、generate_config_toml() のように毎回実ファイルを
# 書く経路ではこのガードが無いと2回目の実行でオリジナルが消える）。
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
    # ⚠️ ただし設計書S4「bedrock.envが実在するのに読めない/解析できない場合
    # は非0終了」の要件があるため（2026-09-01 リーダー裁定・差し戻し対応:
    # 「不在」は非Bedrock機で常に起きる正常系なのでexit 0のまま維持するが、
    # 「実在するのに壊れている」は--print-bedrock-env-json側は既にfail-open
    # せず非0を返す設計になっており、installer本体だけexit 0のままだと
    # 「check-driftは落ちるのにinstallerは成功する」非対称が残る）、
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
  # `--print-leader-runtime`（値出力口）を使う。
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

# --- ローカル実体プロファイルの雛形配置（2026-08-30 共通コア分離 §9.0 A-1 P1機構） ---
# サンプル（vault-public/Preferences/profile-sample.md・repo管理下）から
# $AIENV_LOCAL_PROFILE_PATH の雛形を作る。メイン/サブ共通（--sub-delegate経由でも
# 実行する＝claude/・codex/のsymlink化と同じ扱い）。
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
# ⚠️ PROFILE_SAMPLE_SRC自体は§3.9 Q2の候補抽出でも使うためスクリプト冒頭
# （引数解析より前）で既に宣言済み——ここでは再宣言しない（値表を複数箇所に
# 増やさないため）。
extract_profile_schema_block() {
  # 引数: サンプルファイルのパス。標準出力へYAML frontmatterブロック
  # （`---`〜`---`を含む）を書く。
  # 終了コードを2種類に分ける（2026-09-01 工程横断レビュー指摘・MINOR-1
  # 対応）: exit 1＝読めた内容の中にフェンスが見つからない（YAML抽出失敗
  # 相当）／exit 2＝ファイル自体が読めない・デコードできない（読取不能
  # 相当）。⚠️ 従来はどちらも`sys.exit(1)`または素通しの例外（デフォルトで
  # exit 1相当）に丸められており、呼び出し側（sample_model_candidates()）が
  # 「実在するが権限不足・不正UTF-8のサンプル」を`YAML_EXTRACT_FAILED`
  # （F-22の4区分の1つ）と誤分類していた。`[ -f ]`は読取可能性を保証しない
  # （存在確認だけ）ため、実際の読取り時点で失敗を検出しここで初めて区別する。
  python3 -c "
import re, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        text = f.read()
except (OSError, UnicodeDecodeError) as e:
    print('サンプルを読み取れません（' + type(e).__name__ + '）', file=sys.stderr)
    sys.exit(2)
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

# --- リーダー実行値の決定（2026-09-01 配役表解凍 §4.2-a〜g・§3.9）---
# §3.9の処理順どおり、雛形配置(上)の直後・settings.json生成の直前に
# ④leader行の確定（v2のときだけ・対話はensure_leader_configured内部で
# 発生しうる）→値出力口(resolve_leader_runtime)でmodel/effortを得る、を行う。
# --dry-runでは対話・resolver呼び出しとも一切行わない（既存の
# 「--dry-runはpython3を要求しない」保証を崩さないため。計画表示は
# 既定値のプレースホルダのまま行う＝dry-runの精度より安全側の単純さを優先）。
#
# §3.9対話確定のロックが使う scripts/lib/pid-lock.sh を、ここ（トップ
# レベル・関数の外）でsourceする。⚠️ 関数の中でsourceすると、pid-lock.sh側の
# `declare -a _PID_LOCK_ACQUIRED_FILES=()`がbashの仕様でその関数へlocal化
# されてしまい、関数がreturnした時点で配列が消え、後で発火するEXIT trap
# （_pid_lock_cleanup）がロックファイルを解放できなくなる（2026-09-01実測・
# Codex一次レビュー指摘対応）。⚠️ --print-model 等の早期exitモードより後、
# 実インストールフローの直前でsourceする（それらのモードにpid-lock.shへの
# 依存を持ち込まない＝tests/test-check-drift.shのようにinstall-main.sh単体を
# 別ディレクトリへコピーしてscripts/lib/を持たないfixtureが--print-model等の
# 値出力口だけを使う既存の使い方を壊さないため）。
if [ "$DRY_RUN" != "1" ]; then
  # shellcheck disable=SC1091
  source "$DIR/scripts/lib/pid-lock.sh"
fi
ensure_leader_configured

AIENV_SETTINGS_MODEL="$AIENV_MODEL_VALUE"
AIENV_SETTINGS_EFFORT=""
# ⚠️ DRY_RUN=1のときは動的Bedrock許可キーの算出そのものを行わない（副作用の
# 無い計画表示だけのため）。generate_settings_json()呼び出し側のガードで
# 未初期化を参照しないよう、DRY_RUNの内外どちらでも既定値を先に確定させる。
AIENV_SKIP_SETTINGS_GENERATION=0
if [ "$DRY_RUN" != "1" ]; then
  # ⚠️ 裸の代入のままだと、mktemp失敗時に`set -e`で即座に終了するが
  # fail_settings_generation()を経由しないためNO_GENERATED_FILEが付かない
  # （2026-09-01工程横断レビュー指摘・MINOR対応）。`||`で明示的に渡す。
  _leader_runtime_err_tmp="$(mktemp)" || fail_settings_generation "リーダー実行値確認用の一時ファイルを作成できません"
  if _leader_runtime_json="$(resolve_leader_runtime 2>"$_leader_runtime_err_tmp")"; then
    rm -f "$_leader_runtime_err_tmp"
    # ⚠️ 2つのpython3呼び出しに分けず1回で両方抽出する（値の再パースを
    # 減らす・失敗時に`set -e`が即座に働くよう`||`で明示的にfail()へ渡す）。
    _leader_runtime_fields="$(printf '%s' "$_leader_runtime_json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d["model"])
print(d.get("effort", ""))
')" || fail_settings_generation "リーダー実行値のJSON解析に失敗しました（resolve-leaderの出力契約違反の可能性）"
    AIENV_SETTINGS_MODEL="$(printf '%s\n' "$_leader_runtime_fields" | sed -n '1p')"
    AIENV_SETTINGS_EFFORT="$(printf '%s\n' "$_leader_runtime_fields" | sed -n '2p')"
  else
    _leader_runtime_errline="$(cat "$_leader_runtime_err_tmp" 2>/dev/null)"
    rm -f "$_leader_runtime_err_tmp"
    # ⚠️ 「既存ファイルを保持します」は旧ファイルが実在するときだけ正しい
    # 表現。真の初回インストール等では保持ではなく欠落（NO_GENERATED_FILE）
    # であり、fail_settings_generation()がその区別を末尾へ付加する
    # （2026-09-01工程横断レビュー指摘・MINOR-2対応）ため、ここでは
    # 「保持」を断定しない中立な表現にする。
    fail_settings_generation "リーダー実行値を解決できませんでした（${_leader_runtime_errline:-不明なエラー}）。settings.jsonの生成を中止します。"
  fi
  # 動的Bedrock許可キー（§4.2-d）。プロファイルのrole.*/fallback.*が
  # 実際にprovider=bedrockで使っている別名だけをここで確定させ、
  # generate_settings_json()・compute_bedrock_env_json()が唯一の値表として
  # 参照する配列を更新する。
  # ⚠️ 算出に失敗した場合は、settings.json本体の生成そのものをスキップし
  # 既存ファイルを保持したうえでAIENV_DEFERRED_EXIT_CODEを立てる（設計書
  # §6.2-B S18そのもの＝2026-09-01工程横断レビュー差し戻し・MAJOR対応で
  # 追加された状態。S4〈bedrock.env実在するのに読めない〉と同型のdeferred
  # 非0裁定を、この失敗モードにも適用する）。
  # 旧実装はWARNのみで固定2キー（CLAUDE_CODE_USE_BEDROCK・AWS_REGION）へ
  # 縮退してsettings.json生成を続行しており、未知のworker別名1件でも他の
  # 正常な動的pinキーまで許可集合から落ち、既存settingsに書かれていたpinが
  # 静かに消え得た。「動的キー0件」という正常な結果（compute_allowed_
  # bedrock_env_keys()のexit 0契約）と「算出そのものの失敗」（exit 1契約）の
  # 区別は、この呼び出し側でも維持する（関数の契約を変えない）。
  AIENV_SKIP_SETTINGS_GENERATION=0
  AIENV_ALLOWED_BEDROCK_ENV_KEYS=("CLAUDE_CODE_USE_BEDROCK" "AWS_REGION")
  _bedrock_keys_tmp="$(mktemp 2>/dev/null)" || _bedrock_keys_tmp=""
  if [ -z "$_bedrock_keys_tmp" ]; then
    warn "動的Bedrock許可キーの算出に失敗しました（一時ファイルを作成できません）。settings.jsonの生成をスキップし、既存ファイルを保持します。"
    AIENV_SKIP_SETTINGS_GENERATION=1
    AIENV_DEFERRED_EXIT_CODE=1
  else
    _bedrock_keys_rc=0
    _bedrock_keys_err="$(compute_allowed_bedrock_env_keys 2>&1 1>"$_bedrock_keys_tmp")" || _bedrock_keys_rc=$?
    if [ "$_bedrock_keys_rc" -eq 0 ]; then
      AIENV_ALLOWED_BEDROCK_ENV_KEYS=()
      while IFS= read -r _bedrock_allowed_key; do
        [ -n "$_bedrock_allowed_key" ] && AIENV_ALLOWED_BEDROCK_ENV_KEYS+=("$_bedrock_allowed_key")
      done < "$_bedrock_keys_tmp"
    else
      warn "動的Bedrock許可キーの算出に失敗しました（${_bedrock_keys_err:-不明なエラー}）。settings.jsonの生成をスキップし、既存ファイルを保持します。"
      AIENV_SKIP_SETTINGS_GENERATION=1
      AIENV_DEFERRED_EXIT_CODE=1
    fi
    rm -f "$_bedrock_keys_tmp"
  fi
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
    warn "他の配置処理は完了しましたが、settings.jsonの生成に失敗したため非0終了します（詳細は上記のWARNを参照してください）。"
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
