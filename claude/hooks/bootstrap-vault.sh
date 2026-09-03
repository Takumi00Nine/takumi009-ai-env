#!/bin/bash
# SessionStart hook: 外部脳(Obsidian)の必読ノートを「Readで全文読め」と強制する。
#
# 旧方式は全文をadditionalContextへダンプしていたが、合計が大きいとハーネスが
# ファイルに退避し、AIには先頭プレビュー(約2KB)しか見えず「読んだ」と錯覚する事故が起きた。
# そこで本スクリプトは「全文は注入しない。各ファイルを Read ツールで開け」という
# 短い必須指示だけを出す。短い指示はサイズ上限に絶対かからない=切り詰められない。
#
# 2026-07-05: Agent Teams 対応。チームメイト/ワーカーのセッションには何も
# 注入しない（2026-09-03 軽量版撤去。in-process では届いていなかったことが
# transcript実測で確認され、absolute-rules必読・Vault書込禁止は職種定義
# 側の共通ルール節が正本になった＝下部 is_worker 分岐参照）。判定は
#   a) stdin JSON の agent_type が付いている（--agent 起動 or サブエージェント）
#   b) 自分の session_id が「他セッションがリーダーのチーム」config.json に載っている
#      （チーム設定は ~/.claude/teams/session-{リーダーID先頭8桁}/config.json）
# 判定に失敗したらフル版へフォールバック（安全側＝遅いだけ）。
# VAULT は環境変数で上書き可（ユニットテスト用。本番は既定値のまま）。
VAULT="${BOOTSTRAP_VAULT:-$HOME/Data/obsidian}"
TEAMS_DIR="${BOOTSTRAP_TEAMS_DIR:-$HOME/.claude/teams}"
# machine-roleマーカー（サブ機判定用。既定値・環境変数名は
# check-sub-update.sh・install-main.sh・install-sub.sh・update-sub.shと共通）。
# 用途は外部脳ヘルス行④（週次メンテ死活検知）のサブ機スキップのみ
# （2026-08-06対応。下部compute_health_lines参照）。
: "${AIENV_MACHINE_ROLE_MARKER:=$HOME/.config/takumi009-ai-env/machine-role}"

# 外部脳ヘルス行（2026-07-10 敵対的レビュー2回目 §5-2・8.0の柱②対応）。
# 「本人が定期的にレポート/ログを見に行かないと死活が分からない」問題への
# 最後の砦として、SessionStart（毎回必ず走る唯一のフック）に軽い死活サマリを
# 1〜4行だけ注入する。リーダー向けフル版のみに注入する（ワーカー分岐には
# 何も注入しない＝2026-09-03 軽量版撤去）。SessionStartは毎回走るため軽量必須：
#   - scripts/check-drift.sh の再実行はしない（フルスキャンで数百msかかりうる）
#   - ディレクトリの glob（forkなし）・ファイル1件へのgrep・ログのtail程度に留める
#   - fail-open: ここで何が起きてもブートストラップ本文は必ず出す
#     （この関数のエラーはグローバルに伝播させない。呼び出し側で出力を捨てるだけ）
: "${VAULT_READS_LOG:=$HOME/.claude/logs/vault-reads.tsv}"
: "${VAULT_RECALL_LOG:=$HOME/.claude/logs/vault-recall.tsv}"
: "${VAULT_AGENT_LOG_STALE_DAYS:=7}"  # scripts/check-drift.sh ⑥ と同じ既定値
# fragments-log（旧fragments-review・2026-07-11リネーム）・vault-inventory の
# レポート出力先（2026-07-11 決定「読まれない人間向け資料をVaultに置かない」で
# Vault配下(Explorations/...)から $HOME/.claude/logs/ 配下へ移設。
# scripts/vault-agents/vault_inventory.py のOUT_DIRと同じ既定値）。
: "${VAULT_INVENTORY_LOG_DIR:=$HOME/.claude/logs/vault-inventory}"
# Preferences提案ディレクトリ（2026-07-18ハードニング・[[Decisions/
# 2026-07-18-external-brain-hardening]]で pending マーカー層を撤去）。
# scripts/vault-agents/maintenance_apply.pyのDEFAULT_PREFERENCES_PROPOSALS_DIRと
# 同じ既定値。正本＝このディレクトリ自体（マーカーJSON等の派生物は持たない）。
: "${PREFERENCES_PROPOSALS_DIR:=$HOME/.claude/logs/maintenance/preferences-proposals}"
# 死活検知: maintenance.sh(週次)のlast-run.json（Critical対処・2026-07-18
# ハードニング）。started_atは実行のたびに（busy/error早期終了でも）
# 無条件更新される契約のため、これが古いままなら「週次メンテ自体が
# 全く起動していない」ことを受動的に検知できる（maintenance.shのコメント
# 「自己ロックアウト対策」参照）。
: "${MAINTENANCE_LAST_RUN_FILE:=$HOME/.claude/logs/maintenance/last-run.json}"
: "${MAINTENANCE_STALE_DAYS:=8}"

# ローカル実体プロファイル（2026-08-30 共通コア分離 §9.0 A-1 P1機構）。
# 正本は各マシンのローカル（$HOME/.config/takumi009-ai-env/profile.md）で
# repo管理外・非配布（§11.2 source of truth定義）。Vault外の固定パスを必読
# リストへ載せる小改修だが、有効化そのものはA-1-3の順序厳守対象（移送先
# core-workflow.mdが未整備のうちに必読へ加えると「どちらも読まれない窓」が
# 開く＝§7.3③）だったため、当初は既定を無効(0)のまま実装し、Vault側改訂
# （core-conduct.md・core-workflow.md）が完了してから切り替える設計にしていた。
# 2026-09-02: Vault反映が完了したため、本人裁定（案A・両機同時切替。
# rollout-runbook.md 現行トラック§7）に従い既定値を 0→1 へ切り替え済み
# （FILES一覧・DIRECTIVE本文は無改変。変わるのはこのフラグの既定値1点のみ）。
: "${BOOTSTRAP_ENABLE_LOCAL_PROFILE:=1}"
: "${AIENV_LOCAL_PROFILE_PATH:=$HOME/.config/takumi009-ai-env/profile.md}"
# v2配役表解凍（配役表解凍-設計-2026-09-01.md §4.1-g・U-5）: 判定式の正本は
# claude/hooks/lib/profile_resolve.py の1箇所だけに置く。installerはhookを
# 個別symlinkしており（install-main.sh:574-599）lib専用のリンクは持たないため、
# bootstrap-vault.sh自身のsymlinkを解決した実体ディレクトリ直下のlib/を見る
# （二重管理を避ける＝A-0-3で潰した「値表2箇所重複」の再発防止と同じ考え方）。
resolve_bootstrap_self_dir() {
  local src="${BASH_SOURCE[0]}"
  while [ -L "$src" ]; do
    local dir
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    case "$src" in
      /*) ;;
      *) src="$dir/$src" ;;
    esac
  done
  cd -P "$(dirname "$src")" && pwd
}
BOOTSTRAP_SELF_DIR="$(resolve_bootstrap_self_dir)"
: "${PROFILE_RESOLVE_LIB:=$BOOTSTRAP_SELF_DIR/lib/profile_resolve.py}"
# Bedrockのピン留め実値ファイル（install-main.shと同じ既定値。§6.1）。
# V9-d③・V12の判定にだけ使う＝値そのものは読まず特定キーの有無/非空だけ見る。
: "${AIENV_BEDROCK_ENV_FILE:=$HOME/.config/takumi009-ai-env/bedrock.env}"
# コア職種マニフェスト（V1-a・V1-b）の実体側入力。claude/hooks/../agents。
: "${AIENV_AGENTS_DIR:=$BOOTSTRAP_SELF_DIR/../agents}"
# installerの生成物（scripts/install-main.sh generate_settings_json()の
# 出力先。scripts/check-drift.shのSETTINGS_JSON_LIVEと同じ既定値）。
# S10/S11/S16対応（check_leader_settings_drift参照）の比較先として読むだけ
# ＝副作用ゼロ。
: "${AIENV_SETTINGS_JSON_FILE:=$HOME/.claude/settings.json}"
# 最小能力表の7キー（§3.3.0）。ここに列挙した7つが「今のスキーマが要求する
# キー」＝これが欠けていれば§9.0 A-1最低契約④⑤どおり最小能力+⚠️へ倒す
# （T5＝既存キー欠落）。逆にfrontmatterにこの7つ以外の見慣れないキーが
# 有っても、それは「まだこのコードが追随していない新しいキー」とみなし
# unknown扱いで無視するだけに留め、最小能力へは倒さない（T4＝新キー未追随。
# schema_version／版管理を作らない以上、キー集合の前方互換をこの非対称な
# 扱いで担保する＝リーダー指示）。
LOCAL_PROFILE_KNOWN_KEYS=(
  "inventory_source"
  "reviewer"
  "vault_write"
  "vault_scope"
  "ui.user_call"
  "git_role"
  "web_verification"
)
# テスト専用: BOOTSTRAP_PRINT_KNOWN_KEYS_ONLY=1のとき、最小能力表7キー
# （LOCAL_PROFILE_KNOWN_KEYS）を1行1キーで標準出力へ返して即終了する。
# stdin JSON読み込み・ヘルス行計算等の本処理には一切進まない。本番では
# 未設定のため無効（2026-08-30追加・MINOR-D対応: test-core-docs-placeholder-
# schema.shがこのキー集合を独自にハードコード再列挙し3重管理になっていたため、
# ハードコードの代わりにこの実行時ソースを参照させる）。
if [ "${BOOTSTRAP_PRINT_KNOWN_KEYS_ONLY:-0}" = "1" ]; then
  printf '%s\n' "${LOCAL_PROFILE_KNOWN_KEYS[@]}"
  exit 0
fi
# 未記入のまま残っていると壊れているのと同じ扱いにする印（T2-MINIMAL。
# 設計書v10.3で確定した表記＝凍結側の別のT2と識別子が衝突しないよう分離）。
# サンプル（Preferences/profile-sample.md）は本人裁定（2026-08-30「初期値は
# メイン機の実値を既定値に戻す」）により全7キーとも実運用値（メイン機の
# 確認済み実値）を入れて配布し、このsentinelはどのキーにも使わない。
# fail-soft機構（sentinel検出・未記入判定）自体はコード契約として維持する
# （サブ機・別マシンで値を書き換えず出荷した場合や、将来キーが増えた場合の
# 安全弁のため）。詳細は
# ~/work/takumi009-ai-env-private/docs/core-split/profile-sample-draft.md）。
LOCAL_PROFILE_SENTINEL='<fill-in>'

# resolve_local_profile_v1 <path> — v1（7キー・状態を持たない自由値）実体を
# fail-softに解決する。§3.5「v1と分類されたときの挙動＝現行実装へ丸ごと委譲する」
# の"現行実装"そのもの＝v2解凍後もロジックを一切変えない（v1の値は日本語自由文
# なのでv2文法を当てると必ず落ちるため）。標準出力へタブ区切り1行を返す:
#   MINIMAL\t<T1|T2-MINIMAL|T5|T6|SYMLINK>\t<理由>   … 最小能力+⚠️で扱うべきケース
#     （SYMLINK＝実体がsymlinkだった。マシンローカル・repo管理外という正本の
#      定義に反するため受理しない＝2026-08-30 Codex一次レビュー指摘・Major対応）
#   OK\t<key1=val1>\x1e<key2=val2>...[\tUNKNOWN_EXTRA:<k1>,<k2>,...]
# 判定はキーの有無・YAMLとして壊れていないかまで（validatorは作らない＝
# 最低契約②）。既定値を発明しない（欠けたキーで補完しない＝最低契約④⑤）。
resolve_local_profile_v1() {
  local path="$1"
  # symlinkは実体として受理しない（2026-08-30 Codex一次レビュー指摘・Major対応:
  # 「マシンローカル・repo管理外」という正本の定義（§11.2）に反し、repo管理下や
  # Vault配下のファイルへのsymlinkを経由してリモート更新が能力表へ暗黙に
  # 反映される経路になりうるため。installer側の非破壊コピーは既存symlinkを
  # 「既に存在する」として保護するだけで、symlinkを実体として生成することは
  # 無い＝この判定はinstaller側の設計と矛盾しない）。`[ -L ]`を`[ -f ]`より先に
  # 判定する（symlink先が通常ファイルの場合`-f`も真になるため）。
  [ -L "$path" ] && { printf 'MINIMAL\tSYMLINK\t実体はsymlinkであってはいけません（マシンローカルの通常ファイルとして直接作成してください）: %s\n' "$path"; return; }
  [ -f "$path" ] || { printf 'MINIMAL\tT1\t実体ファイルが存在しません: %s\n' "$path"; return; }
  local known_joined
  known_joined="$(printf '%s\x1f' "${LOCAL_PROFILE_KNOWN_KEYS[@]}")"
  python3 -c "
import re, sys

path = sys.argv[1]
sentinel = sys.argv[2]
known_keys = [k for k in sys.argv[3].split(chr(0x1f)) if k]

try:
    with open(path, encoding='utf-8') as f:
        text = f.read()
except OSError as e:
    print(f'MINIMAL\tT1\t実体ファイルを読めません: {e}')
    sys.exit(0)

lines = text.splitlines()
if not lines or lines[0].strip() != '---':
    print('MINIMAL\tT6\tfrontmatterの開始区切り(---)がありません')
    sys.exit(0)
try:
    end_idx = lines[1:].index('---') + 1
except ValueError:
    print('MINIMAL\tT6\tfrontmatterの終端区切り(---)がありません')
    sys.exit(0)

values = {}
for raw in lines[1:end_idx]:
    if not raw.strip():
        continue
    m = re.match(r'^([A-Za-z0-9_.]+):[ \t]?(.*)\$', raw)
    if not m:
        print(f'MINIMAL\tT6\t解析できない行があります: {raw!r}')
        sys.exit(0)
    values[m.group(1)] = m.group(2).strip()

# 注意: このコメント文中ではバッククォート・二重引用符のどちらも一切
# 使わない（check-drift.shの既知の落とし穴と同じ理由＝bash側のpython3 -cに
# 続く二重引用符文字列の内側にあるため、どちらの文字も本来閉じるべき
# 境界の途中に現れるとbashの構文解釈が壊れる。実装中にkey:という文字列を
# バッククォートで囲んだ結果、bashがコマンド置換として実行しようとして
# 「command not found」が出る実バグを踏んで気付いた）。
# 値が空（key: のように書かれてはいるが中身が無い）場合はunknownへ
# 正規化する（2026-08-30 工程横断レビュー指摘・Major対応。従来は空文字列の
# ままOK扱いで通過させており、最低契約④＝未記載・空はunknownとして扱う、に
# 反していた）。⚠️ これはキー自体が無いケース＝T5とは別物——キーは存在するので
# missing判定には影響させない。sentinel(未記入固定文言)とも別物——sentinelは
# 明示的な埋め忘れの印としてT2-MINIMALで最小能力へ倒すが、単なる空値はコア側が既に
# unknown値を読んで空席等へ倒す設計（core-workflow.md）に委ねるため、
# ここでは値の正規化だけに留め最小能力へは倒さない。
for k in known_keys:
    if k in values and values[k] == '':
        values[k] = 'unknown'

missing = [k for k in known_keys if k not in values]
if missing:
    print('MINIMAL\tT5\t既知キーが欠落しています: ' + ','.join(missing))
    sys.exit(0)

sentinel_keys = [k for k in known_keys if values.get(k) == sentinel]
if sentinel_keys:
    print('MINIMAL\tT2-MINIMAL\t未記入のままのキーがあります: ' + ','.join(sentinel_keys))
    sys.exit(0)

extra_keys = sorted(set(values) - set(known_keys))
resolved = chr(0x1e).join(f'{k}={values[k]}' for k in known_keys)
out = 'OK\t' + resolved
if extra_keys:
    out += '\tUNKNOWN_EXTRA:' + ','.join(extra_keys)
print(out)
" "$path" "$LOCAL_PROFILE_SENTINEL" "$known_joined" 2>/dev/null \
    || printf 'MINIMAL\tT6\tprofile.mdの解析自体に失敗しました（python3不在・実行時エラー等）\n'
}

# is_v2_resolve_output_well_formed <line> <exit_code> — v2 resolve の出力が
# §5 stdout契約のフィールド文法どおりか（固定順・既知フィールドのみ・
# 単一行）を厳密に検査する（Codex二次・三次レビュー指摘・Major対応:
# 従来はOK/MINIMALで始まる1行というだけを見ており、余分な文字列の混入や
# フィールドの重複・順序違反を素通りさせていた＝§5「未知・重複・順序違反は
# 最小能力へ倒す」に反していた）。
# ⚠️ このregexはclaude/hooks/lib/profile_resolve.pyのdo_resolve()が生成する
# フィールド集合と1対1で対応する。新しいフィールドをresolve()の出力へ足す
# ときは、この関数も同じコミットで更新すること（値表の重複ではなく契約の
# 形式検査であり、profile_resolve.py側には同じ正規表現を持たせない＝
# 判定式を2箇所化しないため、更新漏れの検出は両者を変更するテスト
# （test-bootstrap-vault.sh）が担う）。
is_v2_resolve_output_well_formed() {
  local s="$1" rc="$2"
  # 複数行（改行混入）は問答無用で契約違反。
  [ "$(printf '%s' "$s" | wc -l | tr -d ' ')" = "0" ] || return 1
  # nameは職種名(role.<name>の<name>部分)＝parserのKEY_RE(§3.1)と同じ文字集合
  # [A-Za-z0-9_.-]+を許す（Codexレビュー指摘・Major対応: 小文字ハイフンのみに
  # 限定していたため、大文字・アンダースコア・ドットを含む正常な職種名の
  # 出力を誤ってT10へ倒していた）。
  local name='[A-Za-z0-9_.-]+' code='[A-Za-z0-9_-]+' key='[A-Za-z0-9_.-]+' tab notab
  tab="$(printf '\t')"
  # ⚠️ POSIX ERE（bashの=~が使うバックエンド）はブラケット式内で\tを
  # タブへ解釈しない。実際のタブ文字を埋め込む必要がある。
  notab="[^${tab}]+"
  case "$s" in
    OK"$tab"*)
      [ "$rc" = "0" ] || return 1
      local re="^OK${tab}schema_version=[0-9]+(${tab}FALLBACK:${name}(,${name})*)?(${tab}VACANT:${name}(,${name})*)?(${tab}VACANT_REASON:${name}=${code}(,${name}=${code})*)?(${tab}VACANT_UNKNOWN:${name}(,${name})*)?(${tab}ADVISORY:${code}(,${code})*)?(${tab}UNKNOWN_EXTRA:${key}(,${key})*)?\$"
      [[ "$s" =~ $re ]]
      ;;
    MINIMAL"$tab"*)
      [ "$rc" = "1" ] || return 1
      # 理由部分にタブを含めない＝コード・理由の2フィールドだけに限定する
      # （Codexレビュー指摘・Major対応: `.+`は改行以外の任意文字＝タブも含む
      # ため、余分な第4フィールドが紛れ込んでも受理してしまっていた）。
      local re="^MINIMAL${tab}[A-Za-z0-9_-]+${tab}${notab}\$"
      [[ "$s" =~ $re ]]
      ;;
    *)
      return 1
      ;;
  esac
}

# resolve_local_profile <path> — v1/v2/混在を分類し、適切な経路へ委譲する
# ディスパッチャ（配役表解凍-設計-2026-09-01.md §3.5「評価順を契約として固定
# する」の①〜⑥をここで実行する）。標準出力へタブ区切り1行:
#   MINIMAL\t<コード>\t<理由>          … 最小能力+⚠️（§6.2状態機械A）
#   LEGACY_V1\t<v1のOK生payload>       … v1委譲・現行実装がOKだった場合のみ
#   OK\t<解決値>[\tFALLBACK:...][\tVACANT:...][\tVACANT_REASON:...]
#        [\tVACANT_UNKNOWN:...][\tADVISORY:...][\tUNKNOWN_EXTRA:...]
# ⚠️ v1/v2いずれの分類でも「①存在/symlink→②preflight(V15)」は共通で必ず
# 通す（v1の現行実装には元々V15が無かったため、これはv1経路にとって新規の
# 検査＝意図的な仕様変更）。
resolve_local_profile() {
  local path="$1"
  [ -L "$path" ] && { printf 'MINIMAL\tSYMLINK\t実体はsymlinkであってはいけません（マシンローカルの通常ファイルとして直接作成してください）: %s\n' "$path"; return; }
  [ -f "$path" ] || { printf 'MINIMAL\tT1\t実体ファイルが存在しません: %s\n' "$path"; return; }

  if [ ! -f "$PROFILE_RESOLVE_LIB" ]; then
    printf 'MINIMAL\tT10\tresolver本体が見つかりません: %s\n' "$PROFILE_RESOLVE_LIB"
    return
  fi

  local preflight_out preflight_rc=0
  preflight_out="$(python3 "$PROFILE_RESOLVE_LIB" preflight "$path" 2>/dev/null)"
  preflight_rc=$?
  if [ "$preflight_rc" != "0" ]; then
    if [ -n "$preflight_out" ]; then
      printf 'MINIMAL\t%s\n' "$preflight_out"
    else
      printf 'MINIMAL\tT10\tresolver本体の実行に失敗しました（preflight）\n'
    fi
    return
  fi

  local classification classify_rc=0
  classification="$(python3 "$PROFILE_RESOLVE_LIB" classify "$path" 2>/dev/null)"
  classify_rc=$?
  if [ "$classify_rc" != "0" ] || [ -z "$classification" ]; then
    printf 'MINIMAL\tT10\tresolver本体の実行に失敗しました（classify）\n'
    return
  fi

  case "$classification" in
    v1)
      local v1_out
      v1_out="$(resolve_local_profile_v1 "$path")"
      case "$v1_out" in
        OK*)
          # トップレベルだけLEGACY_V1へ差し替える（7キーの生値は再包装しない
          # ＝§3.5）。UNKNOWN_EXTRA等の後続フィールドはそのまま引き継ぐ。
          printf 'LEGACY_V1\t%s\n' "${v1_out#OK$'\t'}"
          ;;
        *)
          printf '%s\n' "$v1_out"
          ;;
      esac
      ;;
    mixed)
      printf 'MINIMAL\tT3-PRIME\tschema_versionが無いのに職種行(role./fallback.)があります（混在）\n'
      ;;
    v2)
      local v2_out v2_rc=0
      v2_out="$(python3 "$PROFILE_RESOLVE_LIB" resolve "$path" \
        --bedrock-env "$AIENV_BEDROCK_ENV_FILE" --agents-dir "$AIENV_AGENTS_DIR" 2>/dev/null)"
      v2_rc=$?
      if is_v2_resolve_output_well_formed "$v2_out" "$v2_rc"; then
        printf '%s\n' "$v2_out"
      else
        printf 'MINIMAL\tT10\tresolver本体の出力が契約違反です（resolve）\n'
      fi
      ;;
    *)
      printf 'MINIMAL\tT10\tresolver本体が不明な分類結果を返しました\n'
      ;;
  esac
}

# テスト専用: BOOTSTRAP_RESOLVE_PROFILE_ONLY=1のとき、resolve_local_profile_v1()の
# 生出力（MINIMAL/OK行）だけを標準出力へ返して即終了する。stdin JSON読み込み・
# ヘルス行計算等の本処理には一切進まない。本番では未設定のため無効
# （2026-08-30追加・MAJOR-8b「値が空=unknownへの正規化」のユニットテスト用。
# OK分岐の生出力はDIRECTIVE本文に現れないため、直接呼び出す経路が無いと
# 正規化結果を検証できなかった）。⚠️ v2解凍(2026-09-01)でresolve_local_profile()は
# v1/v2/混在の分類ディスパッチャに役割が変わった（OKをLEGACY_V1へ差し替える等）
# ため、このテスト専用フックはv1固有の正規化ロジックを直接検証するべく
# resolve_local_profile_v1()を直接呼ぶよう据え置く（分類・委譲そのものは
# `classify`/`resolve_local_profile()`の別テストで検証する）。
if [ "${BOOTSTRAP_RESOLVE_PROFILE_ONLY:-0}" = "1" ]; then
  resolve_local_profile_v1 "$AIENV_LOCAL_PROFILE_PATH"
  exit 0
fi

# テスト専用: BOOTSTRAP_RESOLVE_PROFILE_DISPATCH_ONLY=1のとき、新設の
# resolve_local_profile()（v1/v2/混在の分類ディスパッチャそのもの）の生出力
# だけを標準出力へ返して即終了する（2026-09-01追加。T12=LEGACY_V1トップ
# レベル差し替え・T3-PRIME=混在・T10=lib欠落を直接検証する経路が無かった
# ため。tester独立検証・§10欠落指摘対応）。本番では未設定のため無効。
if [ "${BOOTSTRAP_RESOLVE_PROFILE_DISPATCH_ONLY:-0}" = "1" ]; then
  resolve_local_profile "$AIENV_LOCAL_PROFILE_PATH"
  exit 0
fi

# check_leader_settings_drift <path> — 配役表解凍-設計-2026-09-01.md
# §6.2-B（状態機械B）のS10（settings.jsonを手で直した/`/model`で保存した）・
# S11（旧settings.jsonを保持したまま放置）・S16（profile更新は成功したが
# settings生成は失敗した）に対応する。3状態はいずれも共通して「次の
# SessionStartでV13が必ず⚠️を出す」ことを設計契約として要求している
# （§6.2-B各行）。しかし週次drift（scripts/check-drift.shのV13＝三者一致の
# フル実装）は「次にcheck-drift.shを手動/cronで実行するまで」気づけない。
# 本関数はそのギャップを埋める軽量版で、SessionStartの毎回で必ず走る。
#
# スコープをv2のrole.leader行に限定する（v1の値出力口＝
# AIENV_MODEL_MAIN/SUBはmachine-role/--sub-delegateに依存する別経路であり、
# ここで再実装すると判定式が2箇所に増える＝A-0-3で潰した重複の再発になる。
# v1はcheck-drift.shの週次V13が既に--print-leader-runtime経由でmodel/effort
# 両方をカバーしている。呼び出し元＝本ファイル下部でprofile_kind="OK"
# （v2の`resolve`が成功）のときだけ本関数を呼ぶ）。
#
# 期待値（何がリーダー行の解決値か）はprofile_resolve.pyのresolve-leader
# サブコマンド1箇所に委譲し、本関数はその結果とsettings.jsonの実値を
# 突き合わせるだけに留める（判定式を複数箇所に増やさない＝§4.1-g・U-5と
# 同じ考え方の横展開。install-main.shの--print-leader-runtimeも同じ
# resolve-leaderを呼ぶ＝値表の正本は1箇所のまま）。
#
# 副作用ゼロ・読み取り専用（settings.jsonは開いて読むだけ）。
# 標準出力: 0行（一致・監視対象外）または1行の⚠️メッセージ。
# ⚠️ 絶対厳守③（認証情報・シークレットを露出しない）はトークン・鍵・
# パスワード・`.env`等の全般が対象であり、本関数はそのいずれも扱わない
# （比較に使うのは"model"/"effortLevel"という設定値のみ）。加えてBedrockの
# ピン留め実値も本関数の比較対象・出力のどちらにも現れない
# （bedrock.envの値そのものはgenerate_settings_json()が"env"ブロックへ
# 別途マージするが、settings.jsonをjson.loadで読む際に構造上そのブロックも
# メモリへは載る。ただし比較・出力のどちらにも一切参照・使用しない＝
# 実際に見るのは"model"/"effortLevel"の2キーだけ。resolve-leaderの出力にも
# ピン実値は含まれない＝profile-resolve-contract §9）。
# ⚠️ 不一致メッセージはフィールド名（model/effortLevel）だけを列挙し、
# 実際の値（settings.json側・プロファイル側どちらも）は一切出力しない。
check_leader_settings_drift() {
  local path="$1"
  local leader_json leader_rc
  leader_json="$(python3 "$PROFILE_RESOLVE_LIB" resolve-leader "$path" \
    --bedrock-env "$AIENV_BEDROCK_ENV_FILE" --agents-dir "$AIENV_AGENTS_DIR" 2>/dev/null)"
  leader_rc=$?
  # 呼び出し元はresolve_local_profile()が既にv2のOKを返した直後にだけ
  # 本関数を呼ぶ契約のため、resolve-leaderは通常ここで成功するはずである
  # （V4＝§3.5-Lのfail条件はresolve()のexit契約に含まれるため、resolve()が
  # OKを返した時点でleader行は候補評価まで通っている）。それでも失敗する
  # 場合はプロファイルが2回のプロセス起動の間に書き換わった・python3が
  # 一時的に落ちた等のレースであり、静かに素通りさせず「監視不能」として
  # 扱う（リーダー要件③＝比較不能を静かに通過させない）。
  if [ "$leader_rc" != "0" ] || [ -z "$leader_json" ]; then
    printf '⚠️ settings.json(%s)との整合を確認できませんでした（配役表のリーダー実行値を再取得できません＝監視不能）。scripts/install-main.sh --check-profile で確認してください。\n' "$AIENV_SETTINGS_JSON_FILE"
    return
  fi

  local cmp_out cmp_rc
  cmp_out="$(python3 -c "
import json, sys

leader_json_raw = sys.argv[1]
settings_path = sys.argv[2]

try:
    leader = json.loads(leader_json_raw)
except Exception:
    print('UNAVAILABLE\t配役表のリーダー実行値を解析できません')
    sys.exit(0)
if not isinstance(leader, dict):
    print('UNAVAILABLE\t配役表のリーダー実行値が想定形式ではありません')
    sys.exit(0)
expected_model = leader.get('model')
if not isinstance(expected_model, str) or not expected_model:
    print('UNAVAILABLE\t配役表のリーダー実行値にmodelがありません')
    sys.exit(0)
# 契約(profile-resolve-contract §4)ではeffort未指定時はキー自体を出さない
# ため、キーが無い場合だけ「未指定」として扱う。キーはあるのに値が文字列
# でない・空文字列という契約違反の形は「未指定」へ静かに丸めず監視不能に
# する（Codex一次レビュー指摘・Major対応: 従来は不正な型を黙ってNone
# 〈未指定〉へ変換しており、resolverの契約違反を検出できずに一致と誤判定
# しうる穴があった）。
if 'effort' in leader:
    expected_effort = leader.get('effort')
    if not isinstance(expected_effort, str) or not expected_effort:
        print('UNAVAILABLE\t配役表のリーダー実行値のeffortが不正です')
        sys.exit(0)
else:
    expected_effort = None

try:
    with open(settings_path, encoding='utf-8') as f:
        settings = json.load(f)
except FileNotFoundError:
    print('UNAVAILABLE\tsettings.jsonが存在しません（installerを実行してください）')
    sys.exit(0)
except (OSError, json.JSONDecodeError):
    print('UNAVAILABLE\tsettings.jsonを読めません（壊れている・権限不足の可能性）')
    sys.exit(0)
if not isinstance(settings, dict):
    print('UNAVAILABLE\tsettings.jsonの内容が想定形式ではありません')
    sys.exit(0)

problems = []
actual_model = settings.get('model')
if actual_model != expected_model:
    problems.append('model' if isinstance(actual_model, str) and actual_model else 'model(欠落)')

has_effort_key = 'effortLevel' in settings
actual_effort = settings.get('effortLevel')
if expected_effort is None:
    if has_effort_key:
        problems.append('effortLevel(想定は未設定)')
else:
    if actual_effort != expected_effort:
        problems.append('effortLevel')

if problems:
    print('MISMATCH\t' + ','.join(problems))
else:
    print('OK')
" "$leader_json" "$AIENV_SETTINGS_JSON_FILE" 2>/dev/null)"
  cmp_rc=$?
  if [ "$cmp_rc" != "0" ] || [ -z "$cmp_out" ]; then
    printf '⚠️ settings.json(%s)との整合を確認できませんでした（比較処理自体が失敗＝監視不能）。\n' "$AIENV_SETTINGS_JSON_FILE"
    return
  fi

  local tab
  tab="$(printf '\t')"
  case "$cmp_out" in
    OK)
      : # 一致。何も出力しない（呼び出し元は空文字列を「警告なし」として扱う）。
      ;;
    "UNAVAILABLE${tab}"*)
      printf '⚠️ settings.json(%s)との整合を確認できませんでした（%s）。\n' "$AIENV_SETTINGS_JSON_FILE" "${cmp_out#UNAVAILABLE"$tab"}"
      ;;
    "MISMATCH${tab}"*)
      printf '⚠️ settings.json(%s)が配役表のリーダー行(role.leader)の解決値と一致していません（不一致フィールド: %s）。scripts/install-main.sh の再実行（サブ機は scripts/update-sub.sh）で追随させるか、意図的な一時切替（/model 等）でなければ確認してください。\n' "$AIENV_SETTINGS_JSON_FILE" "${cmp_out#MISMATCH"$tab"}"
      ;;
    *)
      printf '⚠️ settings.json(%s)との整合を確認できませんでした（比較結果を解釈できません＝監視不能）。\n' "$AIENV_SETTINGS_JSON_FILE"
      ;;
  esac
}

# テスト専用: BOOTSTRAP_CHECK_LEADER_SETTINGS_DRIFT_ONLY=1のとき、
# check_leader_settings_drift()の生出力（0行または1行の⚠️メッセージ）だけを
# 標準出力へ返して即終了する。stdin JSON読み込み・ヘルス行計算等の本処理
# には一切進まない。本番では未設定のため無効（S10/S11/S16結合テスト用・
# 2026-09-01追加）。
if [ "${BOOTSTRAP_CHECK_LEADER_SETTINGS_DRIFT_ONLY:-0}" = "1" ]; then
  check_leader_settings_drift "$AIENV_LOCAL_PROFILE_PATH"
  exit 0
fi

# 2026-07-16簡素化（[[Decisions/2026-07-16-nightly-batch-direct-write]]）で
# 「レポート生成→リーダーがセッション内で処理」という間接ループを廃止し、
# 定常メンテは夜間バッチ(maintenance.sh)がVaultへ直接書き込む方式へ移行した。
# 旧・未処理レポート検知（fragments-log/vault-inventory/knowledge-merge-candidates
# のprocessedマーカー監視）・未解決ALERT監視（knowledge_merge.py由来。同スクリプトは
# 撤去済み）はこの間接ループの一部だったため、対応するreport_frontmatter()・
# latest_unprocessed_report_date()・count_unresolved_alerts()ごと削除した。
# 代替の新鮮度チェック（maintenance.shのlast-run.json・started_atの経過日数のみで
# 判定）はmaintenance.sh新設（PR2）と同時に導入する。旧実装を読みたい場合は
# `git log -p claude/hooks/bootstrap-vault.sh` を参照。

compute_health_lines() {
  local inv_dir lines="" latest count now_epoch stale_names=""

  # ① 最新棚卸しレポートの日付・検出件数（frontmatter/タイトルには件数が無いため、
  # 本文冒頭の「要確認 N 件」を1回のgrepで拾う。取れなければ日付のみ表示する）。
  # 2026-07-11 決定でVault配下(Explorations/vault-inventory)から
  # $HOME/.claude/logs/vault-inventory へ出力先が移設された（vault_inventory.py
  # のOUT_DIRと同じ既定値）。
  inv_dir="$VAULT_INVENTORY_LOG_DIR"
  if [ -d "$inv_dir" ]; then
    shopt -s nullglob
    local files=("$inv_dir"/20*.md)
    shopt -u nullglob
    if [ "${#files[@]}" -gt 0 ]; then
      latest="${files[$((${#files[@]} - 1))]}"  # ファイル名がYYYY-MM-DDなのでglob順=時系列順（bash 3.2互換のため負インデックス不使用）
      count="$(grep -m1 -oE '要確認[^0-9]*[0-9]+' "$latest" 2>/dev/null | grep -oE '[0-9]+$')"
      # 表示は日付のみではなくフルパス（本人がそのままファイルを開けるように・
      # Codexレビュー指摘の運用改善。2026-07-12追加）。
      if [ -n "$count" ]; then
        lines="${lines}- 棚卸し最新: ${latest}（要確認 ${count} 件）
"
      else
        lines="${lines}- 棚卸し最新: ${latest}
"
      fi
    fi
  fi

  now_epoch="$(date -u +%s 2>/dev/null)"

  # ② Preferences提案（2026-07-18ハードニング・[[Decisions/2026-07-18-
  # external-brain-hardening]]で pending マーカー層を撤去）: 提案ディレクトリ
  # 自体（`<slug>.md`＝maintenance_apply.pyのapply_promote_preferences_
  # proposal()が排他書込する下書き本文そのもの）を**正本として直接スキャン**し、
  # `*.md`ファイルの件数を「未確認N件」として毎起動で通知し続ける。承認/却下は
  # リーダーが`.md`（＋sidecarの`.meta.json`）を削除するだけでよく、通知件数が
  # 自然に追従する（派生物のマーカーJSON・破損時自己修復ロジックは持たない＝
  # 部品削減。旧実装はgit log -p参照）。
  # fail-open: ディレクトリが無い/読めない等はここで例外的に落ちずヘルス行を
  # 諦めるだけにする（呼び出し側の`compute_health_lines 2>/dev/null`と二重に
  # fail-openを守る）。
  if [ -d "$PREFERENCES_PROPOSALS_DIR" ]; then
    shopt -s nullglob
    local proposal_files=("$PREFERENCES_PROPOSALS_DIR"/*.md)
    shopt -u nullglob
    local n_proposals="${#proposal_files[@]}"
    if [ "$n_proposals" -gt 0 ]; then
      # ファイル名（拡張子除く＝slug）を決定的な表示順にするため一旦ソートする
      # （globの列挙順はファイルシステム依存で保証されないため）。
      # slug列挙は先頭5件までに抑え、6件目以降は「ほかN件」に畳む
      # （2026-07-17 tester2差し戻し対応・任意Minor: ヘルス行が際限なく
      # 長くなるのを防ぐ。方式変更後も同じ制限を踏襲する）。
      local sorted_slugs=() f base shown_slugs="" remaining=0 i=0
      while IFS= read -r base; do
        sorted_slugs+=("${base%.md}")
      done < <(printf '%s\n' "${proposal_files[@]##*/}" | sort)
      for i in "${!sorted_slugs[@]}"; do
        [ "$i" -ge 5 ] && break
        shown_slugs="${shown_slugs}${shown_slugs:+・}${sorted_slugs[$i]}"
      done
      if [ "$n_proposals" -gt 5 ]; then
        remaining=$((n_proposals - 5))
        shown_slugs="${shown_slugs}・ほか${remaining}件"
      fi
      lines="${lines}- 🆕 夜間バッチで運用ルールの昇格提案があります（未確認${n_proposals}件）: ${shown_slugs}
"
    fi
  fi

  # ④ 死活検知（Critical対処・2026-07-18ハードニング／2周目・全体構成再レビュー
  #
  # サブ機スキップ（2026-08-06追加。本人報告・実害対応）: maintenance.sh（週次
  # メンテ）とそれを起動するLaunchAgentはメイン機専用機能であり、サブ機には
  # 設計上存在しない（install-sub.shはmaintenance.sh関連のインストールを一切
  # 行わない）。そのためサブ機ではlast-run.jsonが常に不在のままとなり、
  # 以下の判定が「毎セッション必ず」④の警告を出し続けてしまっていた
  # （本来は正常な状態にもかかわらず）。判定はcheck-sub-update.shの
  # machine-roleマーカー読取・trimパターンをそのまま流用し一貫させる
  # （fail-closed＝マーカーが無い/読めない/中身が"sub"以外はすべて
  # 「メイン機」とみなし従来どおり④を実行する。積極的な証明＝厳密に
  # "sub"の場合のみスキップする）。①②等の他セクションは元々ディレクトリ
  # 不在時に静かにスキップするfail-open設計のため対象外（変更しない）。
  local machine_role_raw machine_role
  machine_role_raw="$(cat "$AIENV_MACHINE_ROLE_MARKER" 2>/dev/null)"
  machine_role="${machine_role_raw#"${machine_role_raw%%[![:space:]]*}"}"
  machine_role="${machine_role%"${machine_role##*[![:space:]]}"}"

  if [ "$machine_role" != "sub" ]; then
  # Codex+Fable5収束後の小修正＝impl4）: maintenance.sh(週次)のlast-run.json
  # started_atが${MAINTENANCE_STALE_DAYS}日以上前のままなら「週次メンテ自体が
  # 動いていない」疑いとして警告する（started_atはbusy/error早期終了でも
  # 無条件更新される契約＝maintenance.sh参照。メンテ全停止を受動的に検知する
  # 最後の砦）。2周目で以下2点を追加（「複雑化させない」原則で既存判定への
  # 足しに留める）:
  #   (a) last_success_atのN日停滞検知＝started_atは新しくてもlast_success_at
  #       が${MAINTENANCE_STALE_DAYS}日以上古ければ「起動はするが成功していない」
  #       ＝「毎週起動して毎週失敗」の不可視を塞ぐ（Phase1①のfail-fastや
  #       Phase2の失敗が続いていても、started_atだけ見ていると気付けない）。
  #   (b) last-run.json不在・JSON破損・両フィールドとも未記録、または
  #       実在するいずれかのフィールドの値が解析不能／未来日時（空文字列・
  #       null・不正な文字列を含む＝2周目再レビューでhas()による区別へ
  #       修正済み）のときは `[ -f ]`等で静かにスキップせず「状態記録が
  #       無い/壊れています」と警告する＝初回未稼働・状態ファイル消失/破損・
  #       片方だけの破損の不可視を塞ぐ。
  # fail-open: jqが無い/JSON破損/フィールド欠落/時刻パース不能のいずれでも
  # クラッシュはしない（このcompute_health_lines関数自体が呼び出し側で
  # 2>/dev/nullされる二重の安全網もそのまま維持）。
  #
  # tester4差し戻し・Major対応（2周目・全体構成再レビュー独立検証で発見された
  # A②の穴）: 従来は(b)の判定が「started_epoch・success_epochの両方が空の
  # ときだけ」発火しており、片方だけ値が壊れている（不正な文字列・未来日時）
  # ケースを静かに見逃していた。最も痛いのは「last_success_atだけ破損・
  # started_atは正常」＝(a)が狙う「起動するが成功しない」検知そのものが
  # 破損データによって無効化される。修正: 各フィールドについて「値は有るのに
  # 信用できない（解析不能または未来日時）」状態を`*_broken`として個別に
  # 判定し、いずれか一方でもbrokenなら(b)の警告を出す（「値が無い」＝キー
  # 自体が未設定という正常な過渡状態＝初回未成功等とは区別する。7l系テストが
  # 保証する「last_success_at未設定でも警告なし」は壊さない）。
  #
  # 再レビュー指摘Major対応: 「キーが無い(has()==false)」と「キーはあるが
  # 値が偽値（空文字列/null）」を`.field // empty`だけでは区別できない
  # （どちらも`jq -r`の出力としては空文字列になる。`jq -r '"" // empty'`も
  # 出力上は空文字列と見分けが付かない）。maintenance.sh自身は常に有効な
  # ISO8601文字列しか書かない契約のため、後者（キーは実在するが値が空/null）
  # は書込側の異常（破損）を示す信号であり、「まだ一度も成功していない」という
  # 正常な過渡状態（＝キー自体が無い）と混同してはいけない。`has()`で
  # キーの実在を独立に確認し、実在するのに解析できない/未来日時の場合のみ
  # brokenとする（キーが存在しないなら`*_broken`は立てない＝7l系テストの
  # 正常無警告契約を保つ）。
  if [ -n "$now_epoch" ]; then
    local started_at last_success_at started_epoch success_epoch started_age success_age
    local started_broken=0 success_broken=0 has_started="" has_success=""
    started_at=""
    last_success_at=""
    if [ -f "$MAINTENANCE_LAST_RUN_FILE" ]; then
      started_at="$(jq -r '.started_at // empty' "$MAINTENANCE_LAST_RUN_FILE" 2>/dev/null)"
      last_success_at="$(jq -r '.last_success_at // empty' "$MAINTENANCE_LAST_RUN_FILE" 2>/dev/null)"
      has_started="$(jq -r 'has("started_at")' "$MAINTENANCE_LAST_RUN_FILE" 2>/dev/null)"
      has_success="$(jq -r 'has("last_success_at")' "$MAINTENANCE_LAST_RUN_FILE" 2>/dev/null)"
    fi

    started_epoch=""
    if [ "$has_started" = "true" ]; then
      [ -n "$started_at" ] && started_epoch="$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "${started_at%Z}" +%s 2>/dev/null)"
      # キーは実在するのに解析できない（空文字列/null/不正な文字列）、
      # または未来日時（時計ズレ/破損の疑い）なら壊れているとみなす。
      # 以降のstale判定には使わせない。
      if [ -z "$started_epoch" ] || [ "$started_epoch" -gt "$now_epoch" ]; then
        started_broken=1
        started_epoch=""
      fi
    fi
    success_epoch=""
    if [ "$has_success" = "true" ]; then
      [ -n "$last_success_at" ] && success_epoch="$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "${last_success_at%Z}" +%s 2>/dev/null)"
      if [ -z "$success_epoch" ] || [ "$success_epoch" -gt "$now_epoch" ]; then
        success_broken=1
        success_epoch=""
      fi
    fi

    # 注意（2026-08-10 実測発見・工程横断レビュー対応中に判明）: このmacOS
    # 標準bash（3.2.57・/bin/bash）は、二重引用符文字列の中で `$VARNAME`
    # （波括弧無し）の直後に全角文字（例: `）`）が続くと、変数名の切れ目を
    # 誤認識し値が化ける実害がある（`$VAR）` → 空/文字化けした展開。
    # `${VAR}）`のように波括弧で明示的に閉じれば発生しない）。本関数の
    # $MAINTENANCE_LAST_RUN_FILE を含む行は必ず`${MAINTENANCE_LAST_RUN_FILE}）`
    # の形（波括弧付き）で書くこと。既存の各行も本対応でこの形へ揃えた。
    if { [ -z "$started_at" ] && [ -z "$last_success_at" ]; } \
       || [ "$started_broken" -eq 1 ] || [ "$success_broken" -eq 1 ]; then
      # (b) ファイル不在／JSON破損／両フィールドとも記録が無い、または
      # いずれかのフィールドに値は有るが解析不能/未来日時＝状態記録が
      # 部分的にでも信用できない。
      lines="${lines}- ⚠️ 週次メンテの状態記録が無い/壊れています（要確認。last-run.json: ${MAINTENANCE_LAST_RUN_FILE}）
"
    else
      [ -n "$started_epoch" ] && started_age=$(( (now_epoch - started_epoch) / 86400 ))
      [ -n "$success_epoch" ] && success_age=$(( (now_epoch - success_epoch) / 86400 ))
      if [ -n "$started_epoch" ] && [ "$started_age" -ge "$MAINTENANCE_STALE_DAYS" ]; then
        lines="${lines}- ⚠️ 週次メンテが${started_age}日動いていません（要確認。last-run.json: ${MAINTENANCE_LAST_RUN_FILE}）
"
      elif [ -z "$started_epoch" ] && [ -n "$success_epoch" ] && [ "$success_age" -ge "$MAINTENANCE_STALE_DAYS" ]; then
        # started_atが未設定（キー自体が無い）の場合のみ、従来どおり
        # last_success_atへフォールバックする（started_atの値が壊れている
        # ケースは上のstarted_broken判定で既に(b)枝へ拾われている）。
        lines="${lines}- ⚠️ 週次メンテが${success_age}日動いていません（要確認。last-run.json: ${MAINTENANCE_LAST_RUN_FILE}）
"
      elif [ -n "$started_epoch" ] && [ -n "$success_epoch" ] && [ "$success_age" -ge "$MAINTENANCE_STALE_DAYS" ]; then
        # (a) started_atは新しい(=起動はしている)がlast_success_atだけが
        # 古い＝起動するが成功し続けていない疑い。
        lines="${lines}- ⚠️ 週次メンテが起動はするが${success_age}日成功していません（要確認。last-run.json: ${MAINTENANCE_LAST_RUN_FILE}）
"
      fi
    fi
  fi

  # last_result（旧D4・[[Decisions/2026-08-10-round6-rulings]]決定1のセット
  # 条件「警告・失敗の可視化」）: 前回の週次メンテ実行結果がwarn/failなら
  # ⚠️1行を追加する。上のstarted_at/last_success_at経過日数ベースの死活
  # 監視とは別軸＝「動いてはいるが直近1回で警告/失敗があった」を、
  # started_at自体は新しいままの間も翌セッション冒頭で必ず拾えるように
  # する（正本＝[[Decisions/2026-08-05-bootstrap-health-warning-report]]
  # 「検知は機能していたが誰も拾わず放置された」への対処＝既存ヘルス行の
  # 方式に合わせる）。last_resultはmaintenance.sh側でsuccess/warn/failの
  # 3値のみを書く契約（scripts/maintenance.sh参照）。それ以外の値・キー
  # 欠落・ファイル不在・jq不在はfail-openで無視する（この行が出ないだけで、
  # 上記①〜④の判定には影響しない）。
  #
  # success＋last_result_summary非空はℹ️（情報提供のみ・⚠️とは区別）で表示
  # する（2026-08-10 工程横断レビュー指摘Major対応）。用途＝②のTOML三分類で
  # 検出された未知config.tomlキーのように、driftでも異常でもないが
  # RUN_DIRログ（30日TTL）に埋もれさせず翌セッションまでは見えるように
  # したい情報（scripts/maintenance.shのadd_info_note()参照）。last_result
  # 自体をwarnへ昇格させない（本人裁定）ため、⚠️と混同されないよう記号・
  # 文言を明確に分ける。
  if [ -f "$MAINTENANCE_LAST_RUN_FILE" ]; then
    local last_result last_result_summary
    last_result="$(jq -r '.last_result // empty' "$MAINTENANCE_LAST_RUN_FILE" 2>/dev/null)"
    last_result_summary="$(jq -r '.last_result_summary // empty' "$MAINTENANCE_LAST_RUN_FILE" 2>/dev/null)"
    if [ "$last_result" = "warn" ] || [ "$last_result" = "fail" ]; then
      lines="${lines}- ⚠️ 前回の週次メンテ結果: ${last_result}${last_result_summary:+（${last_result_summary}）}（last-run.json: ${MAINTENANCE_LAST_RUN_FILE}）
"
    elif [ "$last_result" = "success" ] && [ -n "$last_result_summary" ]; then
      lines="${lines}- ℹ️ 前回の週次メンテ結果: success（${last_result_summary}）（last-run.json: ${MAINTENANCE_LAST_RUN_FILE}）
"
    fi
  fi
  fi  # machine_role != sub（サブ機では④の全判定を無警告でスキップ）

  # ③ check-drift.sh ⑥相当の簡易死活。reads/recallログそれぞれの「最終有効行」
  # （3列目=ノート相対パスが空でない行）の経過日数が閾値超なら死の疑いを出す。
  # 全行走査はしない（tail の範囲内に有効行が無ければ判定を諦めてfail-openする＝
  # 詳細判定はcheck-drift.sh（週次drift通知）の役目で、ここは毎回軽く見るだけ）。
  if [ -n "$now_epoch" ]; then
    local pair name f ts epoch age
    for pair in "vault-reads.tsv|$VAULT_READS_LOG" "vault-recall.tsv|$VAULT_RECALL_LOG"; do
      name="${pair%%|*}"
      f="${pair#*|}"
      [ -f "$f" ] || continue
      ts="$(tail -n 50 "$f" 2>/dev/null | awk -F'\t' 'NF>=3 && $3!="" {t=$1} END{if (t!="") print t}')"
      [ -n "$ts" ] || continue
      ts="${ts%Z}"
      epoch="$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$ts" +%s 2>/dev/null)" || continue
      age=$(( (now_epoch - epoch) / 86400 ))
      if [ "$age" -gt "$VAULT_AGENT_LOG_STALE_DAYS" ]; then
        stale_names="${stale_names}${stale_names:+・}${name}"
      fi
    done
  fi
  if [ -n "$stale_names" ]; then
    lines="${lines}- ⚠️ フック死の疑い: ${stale_names}（直近${VAULT_AGENT_LOG_STALE_DAYS}日以内の有効な記録なし。詳細は scripts/check-drift.sh を実行して確認）
"
  fi

  printf '%s' "$lines"
}

INPUT=$(cat 2>/dev/null || true)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)
AGENT_TYPE=$(printf '%s' "$INPUT" | jq -r '.agent_type // ""' 2>/dev/null)

is_worker=0
[ -n "$AGENT_TYPE" ] && is_worker=1
if [ "$is_worker" = "0" ] && [ -n "$SESSION_ID" ] && [ -d "$TEAMS_DIR" ]; then
  own_team="session-${SESSION_ID:0:8}"
  for cfg in "$TEAMS_DIR"/*/config.json; do
    [ -f "$cfg" ] || continue
    team_dir=$(basename "$(dirname "$cfg")")
    [ "$team_dir" = "$own_team" ] && continue  # 自分がリーダーのチーム設定は除外
    if grep -q "$SESSION_ID" "$cfg" 2>/dev/null; then
      is_worker=1
      break
    fi
  done
fi

if [ "$is_worker" = "1" ]; then
  # 2026-09-03 軽量版撤去＝共通ルールは agents/*.md の共通ルール節が正本。
  # in-process ワーカーには本フックの注入が届いていなかった（transcript実測で
  # 確認）ため、absolute-rules必読・Vault書込禁止は既に職種定義側へ移管済み。
  # 旧DIRECTIVE第3項目「obsidian-mcpは使わない」は該当ツールを職種定義の
  # tools:に付与しないことで担保する（別経路のため本フックでの言及は不要）。
  # ペイン型・定義なし個体を再採用する場合は、その起動経路で共通ルールの
  # 供給を改めて実装・実測すること。
  exit 0
else
  # 2026-08-30 §9.0 A-1-3 波及改修（本人承認済み・順序厳守どおり
  # 移送先core-conduct.md/core-workflow.mdがVault側に配置済み/配置中になった
  # 段階で実施＝§7.3③「移送先が必読として読まれる状態になってから移送元を
  # 外す」）: `Knowledge/mistakes.md` を必読から除去し、代わりに
  # `Preferences/core-conduct.md`・`Preferences/core-workflow.md` を追加した
  # （§9.3 P2受入①）。`coding-delegation.md`・`profile.md` はこの段では外さない
  # （移送先未作成のためP3で外す＝設計書のP2/P3段階分けどおり）。
  # ⚠️ サブ機/メイン機で別配列に分岐させていない——サブ機（private層を持たない
  # 環境）での欠落判定は下のfor文の存在確認（`-f`）だけで行われ、
  # core-conduct.md・core-workflow.mdはいずれもPreferences配下＝vault-public
  # スナップショット経由でサブへも同一pushで届く（Knowledge/
  # vault-public-distribution-scope）ため、単一のFILES配列のままで
  # メイン/サブ両方に正しく効く。
  FILES=(
    "Preferences/absolute-rules.md"
    "Preferences/core-conduct.md"
    "Preferences/core-workflow.md"
    "Preferences/profile.md"
    "Personal/profile-personal.md"
    "Preferences/coding-delegation.md"
    "Preferences/vault-operation.md"
  )
  # 意図的にサブ機へ配らない（private層）ファイル。FILES配列のうちこれ**だけ**が
  # 「無くて正常」（2026-07-08リーダー指示）。それ以外は全てPreferences配下＝
  # vault-publicスナップショット経由でメイン/サブ両方へ同一pushで届く想定の
  # 必須publicノートであり、欠落は同期失敗・checkout破損・移送順序ミス等の
  # 異常を示す（2026-08-30 Codex一次レビュー指摘・Major対応: 従来は全ての
  # 欠落を一律「privateノートはこのマシンには無い」として無警告で握り潰して
  # いたため、core-conduct.md・core-workflow.mdのような必須publicノートが
  # 欠落しても「サブでは普通にある欠落」と誤認され、§7.3③が懸念する
  # 「移送元も移送先も読まれない窓」が実際に開いていても気づけなかった）。
  LOCAL_ONLY_FILES=(
    "Personal/profile-personal.md"
  )
  is_local_only_file() {
    local target="$1" candidate
    for candidate in "${LOCAL_ONLY_FILES[@]}"; do
      [ "$candidate" = "$target" ] && return 0
    done
    return 1
  }

  # 必読ファイル一覧を絶対パス+存在確認+行数付きで生成（行数を載せておくと、
  # 後でReadした結果が全文かどうかAI自身が照合できる）。
  # サブ機（private層を持たない環境）では Personal/profile-personal.md が
  # 存在しないため、「見つかりません」と毎回警告するのではなく
  # **存在するファイルだけを必読リストに載せる**（2026-07-08 リーダー指示・install-sub.sh対応）。
  # メイン機（全7ファイルが揃う環境）の挙動は変わらない＝7ファイル全部が列挙される。
  list=""
  present_count=0
  missing_count=0
  unexpected_missing=""
  unexpected_missing_count=0
  for f in "${FILES[@]}"; do
    abs="$VAULT/$f"
    if [ -f "$abs" ]; then
      lines=$(wc -l < "$abs" | tr -d ' ')
      list="$list
  - $abs  （全${lines}行：Readで全文を読むこと）"
      present_count=$((present_count + 1))
    elif is_local_only_file "$f"; then
      missing_count=$((missing_count + 1))
    else
      # private層ではない＝サブでも本来存在するはずのpublicノートが欠落している
      # （同期失敗・checkout破損・移送順序ミス等）。「無くて正常」の件数には
      # 数えず、別枠で強めに警告する。
      unexpected_missing="$unexpected_missing
  - $abs"
      unexpected_missing_count=$((unexpected_missing_count + 1))
    fi
  done
  if [ "$missing_count" -gt 0 ]; then
    list="$list
  （private ノートはこのマシンには無い（サブ）: ${missing_count}件は対象外）"
  fi
  if [ "$unexpected_missing_count" -gt 0 ]; then
    list="$list
  ⚠️ 必読のはずのpublicノートが見つかりません（想定外・同期失敗やcheckout破損の可能性。scripts/update-sub.shの再実行・scripts/check-drift.shでの確認を推奨）:$unexpected_missing"
  fi

  # ローカル実体プロファイル（P1機構・2026-09-02から既定有効。
  # BOOTSTRAP_ENABLE_LOCAL_PROFILE=0を明示したときだけ、Vault外の固定パスを
  # 必読リストへ追加しない旧来の挙動（P1導入前）に戻る）。
  #
  # 必読掲載条件（§4a・U-8裁定 2026-09-01）: 「通常ファイル→preflight→浅い
  # 走査→分類別parser→fail区分のvalidator非違反→UNKNOWN_EXTRA無し」の**全部**
  # が成功したときだけ全文Readを指示する。1つでも欠ければ「利用不可」の
  # 短い注記だけを list に載せ、全文は読ませない（AI側は最小能力として振る舞う。
  # 機械側の解決可否とは独立＝§4a表の「機械は既知キー部分が有効でもAIは除外」）。
  LOCAL_PROFILE_WARNING=""
  if [ "$BOOTSTRAP_ENABLE_LOCAL_PROFILE" = "1" ]; then
    # resolve_local_profile()自身がsymlink拒否(SYMLINK)・不在(T1)を含めた
    # 全状態を返すため、必読リスト表示側で-L/-fを個別に再判定しない
    # （判定式を2箇所に増やさない＝A-0-3と同型の重複防止）。
    profile_status="$(resolve_local_profile "$AIENV_LOCAL_PROFILE_PATH")"
    profile_kind="${profile_status%%$'\t'*}"
    profile_rest="${profile_status#*$'\t'}"
    profile_has_unknown_extra=0
    printf '%s' "$profile_status" | grep -q 'UNKNOWN_EXTRA:' && profile_has_unknown_extra=1

    if { [ "$profile_kind" = "OK" ] || [ "$profile_kind" = "LEGACY_V1" ]; } \
       && [ "$profile_has_unknown_extra" = "0" ]; then
      profile_lines=$(wc -l < "$AIENV_LOCAL_PROFILE_PATH" | tr -d ' ')
      list="$list
  - $AIENV_LOCAL_PROFILE_PATH  （全${profile_lines}行：Readで全文を読むこと。ローカル実体プロファイル＝非配布）"
      present_count=$((present_count + 1))
    elif [ "$profile_kind" = "MINIMAL" ]; then
      profile_reason_code="${profile_rest%%$'\t'*}"
      case "$profile_reason_code" in
        T1)
          list="$list
  - $AIENV_LOCAL_PROFILE_PATH  （未作成。installerでサンプルから雛形を作成してください）"
          ;;
        SYMLINK)
          list="$list
  - $AIENV_LOCAL_PROFILE_PATH  （symlinkのため実体として受理しません。通常ファイルとして作り直してください）"
          ;;
        *)
          list="$list
  - $AIENV_LOCAL_PROFILE_PATH  （プロファイル利用不可のため全文はReadさせません。詳細は下記【ローカル実体プロファイル】を参照）"
          ;;
      esac
    else
      list="$list
  - $AIENV_LOCAL_PROFILE_PATH  （プロファイル利用不可のため全文はReadさせません。詳細は下記【ローカル実体プロファイル】を参照）"
    fi

    if [ "$profile_kind" = "MINIMAL" ]; then
      profile_reason_code="${profile_rest%%$'\t'*}"
      profile_reason_msg="${profile_rest#*$'\t'}"
      if [ "$profile_reason_code" = "T11" ]; then
        LOCAL_PROFILE_WARNING="⚠️ ローカル実体プロファイル(${AIENV_LOCAL_PROFILE_PATH})に認証情報らしいキー名があります（${profile_reason_msg}）。該当行を削除してください。認証情報は専用の資格情報機構（AWS CLI/SSO等）へ置いてください。bedrock.envに置いてよいのは認証情報ではないモデルのピン留め値だけです。最小能力（reviewer等の各キーは空席・unavailable相当）として扱い、fail-softの申告（Preferences/core-workflow.md §7 職種が空席のとき）を行うこと。"
      else
        LOCAL_PROFILE_WARNING="⚠️ ローカル実体プロファイル(${AIENV_LOCAL_PROFILE_PATH})を解決できません（${profile_reason_code}: ${profile_reason_msg}）。最小能力（reviewer等の各キーは空席・unavailable相当）として扱い、fail-softの申告（Preferences/core-workflow.md §7 職種が空席のとき）を行うこと。既定値を発明しない。"
      fi
    elif [ "$profile_has_unknown_extra" = "1" ]; then
      # T9'（U-8裁定）: 未知キーの「値」にV15では検出できない秘密が
      # 書かれている可能性があるため、advisoryとして読ませ続けることをやめ、
      # AI向けには必読除外・最小能力として振る舞わせる（機械側の解決は有効）。
      # ⚠️ リーダー裁定（UNKNOWN_EXTRAフィールド追加の承認と同時、2026-09-01）:
      # 「プロファイル利用不可＝最小能力」「ワーカー起動は本人確認へ倒す」を
      # 文言として明示する（4.1-fのDIRECTIVE注入契約どおり、この信号を根拠に
      # 具体的な振る舞いまで書く。単に「最小能力として扱ってください」だけでは
      # ワーカー起動時に何をすべきかが伝わらない）。
      unknown_extra="${profile_status#*UNKNOWN_EXTRA:}"
      LOCAL_PROFILE_WARNING="⚠️ ローカル実体プロファイルに未知のキーがあります（${unknown_extra}）。機械側（resolver/installer）は既知キー部分のみ有効ですが、**プロファイル利用不可＝最小能力**としてAI向けには必読から除外します（U-8裁定・秘匿優先。まだこのマシンのコードが追随していない新しいキーの可能性があります）。配役の状態が確認できない以上、**ワーカー起動は本人確認へ倒してください**（Preferences/core-workflow.md §7 職種が空席のとき）。"
    elif [ "$profile_kind" = "LEGACY_V1" ]; then
      LOCAL_PROFILE_WARNING="⚠️ ローカル実体プロファイルはv1形式です。配役表を使うにはv2へ移行してください（${AIENV_LOCAL_PROFILE_PATH}）。"
    elif printf '%s' "$profile_status" | grep -q -E '(FALLBACK|VACANT|VACANT_REASON|VACANT_UNKNOWN|ADVISORY):'; then
      # 4.1-f: 配役の値そのものは再掲しないが、縮退・fallback・未確定の
      # 職種名と条件番号はDIRECTIVEへ必ず注入する（静かな失敗を防ぐ）。
      casting_note="$(printf '%s' "$profile_status" | sed -E 's/^OK\t//')"
      LOCAL_PROFILE_WARNING="ℹ️ 配役表の状態（職種名と条件番号のみ・値は含みません）: ${casting_note}。詳細はPreferences/core-workflow.md §7（職種が空席のとき）を参照してください。"
    fi

    # S10/S11/S16対応（check_leader_settings_drift参照）: v2の`resolve`が
    # OKを返した（＝role.leaderが候補評価まで通った）セッションでは、
    # settings.jsonがその解決値へ追随しているかを毎回軽く比較する。
    # ⚠️ UNKNOWN_EXTRAの有無を問わない（上のAI向け必読可否＝§4a・U-8とは
    # 独立の判定。resolve-leaderはUNKNOWN_EXTRAを見ないため機械側は既知キー
    # 部分が有効＝§4aの表のとおり）。LEGACY_V1（v1委譲）はスコープ外
    # （関数コメント参照。週次drift＝check-drift.shのV13が既にv1をカバー）。
    if [ "$profile_kind" = "OK" ]; then
      leader_settings_drift_warning="$(check_leader_settings_drift "$AIENV_LOCAL_PROFILE_PATH")"
      if [ -n "$leader_settings_drift_warning" ]; then
        if [ -n "$LOCAL_PROFILE_WARNING" ]; then
          LOCAL_PROFILE_WARNING="${LOCAL_PROFILE_WARNING}
${leader_settings_drift_warning}"
        else
          LOCAL_PROFILE_WARNING="$leader_settings_drift_warning"
        fi
      fi
    fi
  fi

  # 外部脳ヘルス行（fail-open: 失敗してもブートストラップ本文は必ず出す）。
  HEALTH_LINES="$(compute_health_lines 2>/dev/null)" || HEALTH_LINES=""

  read -r -d '' DIRECTIVE <<EOF
【セッション開始ブートストラップ｜ハーネス強制注入】

重要: 必読ノートの全文はこのメッセージには注入されていない。
あなたは下記ファイルをまだ読んでいない。プレビューや要約で読んだ気にならないこと。

① タスクに着手する前に、まず Read ツールで以下を「全文」読む（${present_count}ファイルを1回の並列 Read で同時取得すること）:
$list

② 上記を読み終えるまで、ユーザー依頼の実作業（調査・検索・コード変更・委任を含む）に着手しない。
③ ユーザーの質問に関連するキーワードで Vault($VAULT) を Read/Grep/Glob で検索し、ヒットしたノートを読んでから回答する(obsidian-mcp は使わない)。
④ 新たな知見・判断・好み・プロジェクト変化が出たら、その場で Vault へ記録する。決定者はリーダー・執筆は常駐チームメイト vault-scribe へ委任（リーダー直筆は禁止＝delegation-gate が deny。2026-08-12 本人指示で「軽い1件は直筆可」の例外撤廃）。scribe 不在なら起動してから振る。他ワーカー/Codex は「Vault記録候補:」で申告。フロントマター必須。
⑤ オーケストレーター行動則: 実装・調査・テスト等の「作る工程」は自分でやらず、着手前にチームメイト/Agentワーカーへ委任する（Preferences/coding-delegation）。リーダー自身の Edit/Write が正当なのは、~/.claude・scratchpad・リーダー自身の成果物への軽微な修正・ユーザーの直接作業指示のみ（Vault は含まない＝執筆は vault-scribe へ委任・直筆はフックが deny）。ワーカー/チームメイトが作成した成果物（要件定義書・設計書・コード等）への修正（レビュー指摘の反映含む）はリーダーが直接行わず、作成元ロールへ差し戻す。作成個体が停止済み・別セッションなら同ロールのチームメイトを再起動して委任する（Decisions/2026-08-14-deliverable-revision-by-creator）。許可パス外への直接編集は delegation-gate-v2 フックが deny する（委任するか、理由をユーザーに明示してマーカー touch）。
${HEALTH_LINES:+
【外部脳ヘルス】（scripts/check-drift.sh ⑥の簡易版。詳細確認は本体を実行）
$HEALTH_LINES}
${LOCAL_PROFILE_WARNING:+
【ローカル実体プロファイル】
$LOCAL_PROFILE_WARNING}
EOF
fi

jq -n --arg ctx "$DIRECTIVE" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
