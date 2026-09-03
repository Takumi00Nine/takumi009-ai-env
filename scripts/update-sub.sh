#!/usr/bin/env bash
# サブ環境の手動実行コマンド: このリポジトリを git pull し、変化があれば
# codex/config.toml の再生成・Vaultの Preferences 再同期・新しい骨格フォルダの
# 補充を行う（2026-07-08 本人発案・サブ専用）。
#
# 2026-07-23: 定期LaunchAgent（com.takumi009.update-sub・1日2回=09:00/13:00の
# 無人自動pull）は廃止した。代わりに claude/hooks/check-sub-update.sh
# （SessionStartフック）がセッション起動のたびに未反映コミットの有無を実測し、
# あれば本コマンドの手動実行を案内する（本人が能動的に実行する運用へ変更）。
# 本スクリプト自体の処理内容（pull・config.toml再生成・Preferences再同期・
# 骨格フォルダ補充）は変更していない。**サブ専用**＝メインでは実行しない
# （メインは編集側なので自動pullは多地点編集事故のもと）。
#
# 2026-07-24: machine-roleマーカーファイル（既定
# $HOME/.config/takumi009-ai-env/machine-role・中身「sub」。
# scripts/install-sub.shが設置。claude/hooks/check-sub-update.shと同じ
# 環境変数名・既定値を共有）の中身が「sub」でなければ fail() で拒否する
# ガードを追加した（リーダー裁定・Codex一次レビュー指摘Major対応）。メインで
# 誤って本コマンドを手動実行すると 4b の`rsync --delete`でメインVaultの
# `Preferences/`が上書き削除されるため、最後の砦として設けている。
# 処理順序:
#   0. machine-roleマーカーの確認（「sub」でなければ即fail()で拒否）
#   1. スクリプト自身の多重起動防止ロック（scripts/lib/pid-lock.shの
#      acquire_pid_lock()＝backup-vault.sh・maintenance.shと共通の実装。
#      2026-08-30 Codex 2巡目差し戻し・MAJOR対応で独自実装から移行した）。
#      ⚠️ 下記2.の自己更新re-exec後は、新規取得ではなく既存ロックの
#      「引き継ぎ（handoff）」になる（詳細は2.参照）。
#   2. git pull --ff-only（衝突可能性を排除。ff不可ならWARNで終了。サブは
#      編集しない運用のため通常は起きないはずだが、念のため force しない）。
#      ⚠️ 自己更新対策（2026-09-03 本人実査・緊急対応）: pullでこのスクリプト
#      自身（scripts/update-sub.sh）が変わっていた場合、その場で新版へ
#      exec しなおして最初からやり直す。bashはスクリプトを逐次読みするため、
#      実行中の自分自身をpullで書き換えたまま処理を続けると、後続処理が
#      旧版のまま・あるいは不定動作になる既知の危険がある（実際にサブ機で
#      1回目の実行だけagentsのsymlink化〈当時追加直後の新機能〉が効かない
#      という実害が発生した）。execはPIDを保つため、自分の多重起動防止
#      ロックは解放せずそのまま引き継ぐ（1.参照）＝解放→再取得の往復を
#      挟むと、その間に別プロセスへロックを奪われる競合窓が生じ、そのプロセスは
#      既にpull済みのHEADを見て「変更なし」と誤判定し、config.toml再生成・
#      Preferences再同期・骨格フォルダ補充〈4a〜4c〉が次のupstream更新まで
#      欠落しうるため（Codexレビュー指摘・Major対応で解放方式から変更）。
#      再exec後はAIENV_UPDATE_SUB_REEXEC=1・AIENV_UPDATE_SUB_ORIG_BEFORE_HEAD
#      （自己更新前の元のHEAD。実在するcommitであることを検証したうえで
#      信頼する＝環境変数の誤残留対策）を環境変数で引き継ぎ、pullを再実行せず
#      before_head/after_headを復元する（引き継がないと「pull済みでHEAD
#      不変」に見えてしまい、4.の変更検知が誤って空振りする）。
#   2b. settings.json の再生成（§9.0 A-0-1・2026-08-30追加）。⚠️ ここは
#       「HEADが変化していなくても」実行する＝下の3.の早期終了より前に置く
#       （Codex一次レビュー指摘・Nit対応: 3.の「何もせず終了」は git pull由来の
#       処理に限った説明であり、settings.json再生成はHEAD不変でも走る）。
#   2c. claude/agents/*.md を $HOME/.claude/agents/ へ symlink化する
#       （install-main.sh の agents symlinkループ・link()/backup_once()と
#        同じ様式・同じ退避規則。2026-09-03 本人指示で追加＝従来このスクリプトは
#        agentsの同期を一切行っておらず、repoへ新しいロール定義を追加しても
#        サブ機へ配布されない欠落があった。repoから削除されたロールへの
#        dangling symlinkは削除せずWARNのみに留める＝削除は本人判断）。
#       ⚠️ 冪等で軽い処理のため2b.と同じく「HEADが変化していなくても」実行する
#       位置に置く（当初は4.配下〈HEAD変化時のみ〉に置いていたが、2回目以降の
#       実行がHEAD不変で早期終了する経路だとagentsのsymlink化に一切到達しない
#       実バグがあったため、2026-09-03 本人実査で2b.と同じ扱いへ位置を修正した）。
#   3. pull で HEAD が変化していなければ、2b./2c.より後の処理（4.）は何もせず
#      終了（静か・冪等）
#   4. 変化があれば:
#      a. codex/config.toml をテンプレから再生成する
#         （install-main.sh の generate_config_toml() と同等処理。
#          既存の .pre-aienv.bak は上書きしない）
#      b. vault-public/Preferences/ を $HOME/Data/obsidian/Preferences/ へ
#         rsync -a --delete で再同期する（**Preferences 以外には絶対に触らない**＝
#         サブ機ローカルの Fragments 等の断片を消さないため）
#      c. vault-public/ 配下に新しい骨格フォルダ（Preferences以外）があり、
#         $VAULT にまだ存在しなければ mkdir + README.md を補充する
#         （既存フォルダの中身・READMEには触らない）
#
# パスは $HOME 相対（DIR・VAULT・LOCK_FILE は環境変数で上書き可＝ユニットテスト用。
# 本番実行時は既定値のまま呼べば良い）。

set -euo pipefail

: "${DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${VAULT:=$HOME/Data/obsidian}"
: "${LOCK_FILE:=${TMPDIR:-/tmp}/aienv-update-sub.lock}"
: "${AIENV_MACHINE_ROLE_MARKER:=$HOME/.config/takumi009-ai-env/machine-role}"
# Bedrock最小セット（2026-08-30 §9.0 A-1-4）: install-main.shと同じ環境変数名・
# 既定値。存在しない（Bedrock未導入機）場合は何もしない。
: "${AIENV_BEDROCK_ENV_FILE:=$HOME/.config/takumi009-ai-env/bedrock.env}"
STALE_LOCK_SECONDS="${STALE_LOCK_SECONDS:-3600}"

log() { echo "[update-sub] $*"; }
warn() { echo "[update-sub] WARN: $*" >&2; }
fail() { echo "[update-sub] FAIL: $*" >&2; exit 1; }
# EXIT_CODE — スクリプト全体の最終終了コード（既定0）。設計書§3.9
# 「update-sub.shはリーダー行が未確定ならWARN＋非0終了」を満たすための
# フラグ（Codex一次レビュー指摘・Blocking対応・2026-09-01）。
# ⚠️ **リーダー実行値（--print-leader-runtime）の取得失敗**に加え、**Bedrock
# envファイルが実在するのに読めない／解析できない場合（BEDROCK_STATUS=
# EXISTS_BUT_UNAVAILABLE）も**非0にする（状態機械B・設計書§6.2-B S4「生成
# 中止・旧保持・非0」・2026-09-01工程横断レビュー差し戻しMAJOR対応）。
# install-main.sh側は同じS4裁定を先行実装済みであり、update-sub.shだけが
# WARN＋exit 0のまま非対称になっていた（旧コメント「リーダー未確定とは
# 無関係な既存の失敗モードのため対象にしない＝exit 0のまま」は本裁定と
# 矛盾していたため撤回する）。「対話の途中で止まらない」という§3.9の趣旨に
# 合わせ、失敗を検知しても後続の2c・4a〜4c（agents symlink化・config.toml
# 再生成・Preferences再同期・骨格フォルダ補充）は続行し、スクリプト末尾で
# 初めてこのフラグに従って終了する（deferred方式＝leader未確定時と同じ扱い）。
EXIT_CODE=0

# bedrock_env_file_kind <path> — Bedrock envファイルの種別を1行で標準出力へ
# 印字する: ABSENT（本当に存在しない＝ENOENT）／UNAVAILABLE（通常ファイル以外
# ＝ディレクトリ・dangling symlink・親ディレクトリの探索権限不足等でlstat自体
# が失敗する場合を含む）／OK（読める可能性のある通常ファイル）。
# install-main.sh generate_settings_json()と全く同じ判定ロジックを意図的に
# 複製したもの（両スクリプトはBedrock envファイルの解析自体は
# install-main.sh --print-bedrock-env-json への一本化を維持しており、
# ここで複製するのはファイル種別の軽い判定口のみ＝2026-08-30 Codex四次
# レビュー指摘・MAJOR対応の横展開）。
# ⚠️ シェルの `[ -e ]`/`[ -L ]` だけに頼らずPythonの例外種別で判定する
# （`[ -e path ]`は親ディレクトリの探索権限が無いだけでも偽になり、「本当に
# 存在しない」場合と区別できない。これをABSENTと誤認すると、実際には存在する
# 設定ファイルを空payloadで上書きしてしまう）。
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

# --- 0. machine-roleマーカーの確認（メインでの誤実行を防ぐ最後の砦） ---
# マーカーが無い・読めない・中身が"sub"以外のいずれでも拒否する（積極的な証明が
# 無ければ動かないfail-closed。scripts/install-sub.shが唯一このマーカーを書く）。
# `|| true` はset -e/pipefail対策（マーカー不在時 `cat` が非0を返し、pipefail下の
# コマンド置換がそのまま script 全体を落としてしまい、直後のfail()の分かりやすい
# メッセージが一切出ないまま黙って落ちる事故になるため。実装中に発見・回帰テストで
# 固定化した実バグ）。前後の空白だけを取り除く（Codex再レビュー指摘・Minor:
# `tr -d '[:space:]'`は内部の空白まで削除してしまうため、"s u b"のような中身
# まで誤って"sub"として通してしまう穴があった。claude/hooks/check-sub-update.sh
# と同じbash 3.2互換のパラメータ展開のみで前後trimする）。
MACHINE_ROLE_RAW="$(cat "$AIENV_MACHINE_ROLE_MARKER" 2>/dev/null)" || true
MACHINE_ROLE="${MACHINE_ROLE_RAW#"${MACHINE_ROLE_RAW%%[![:space:]]*}"}"
MACHINE_ROLE="${MACHINE_ROLE%"${MACHINE_ROLE##*[![:space:]]}"}"
if [ "$MACHINE_ROLE" != "sub" ]; then
  # ${AIENV_MACHINE_ROLE_MARKER}と明示的に波括弧で囲む（2026-07-16
  # scripts/install-backup.shで発見済みの実バグの回帰: bash 3.2(macOS既定)+
  # ja_JP.UTF-8ロケール環境で、裸の$VAR直後に全角記号（）等が続くと変数名の
  # 境界を誤認識し「unbound variable」で本来のFAILメッセージを握り潰してしまう）。
  fail "このマシンはサブ機として登録されていません（machine-roleマーカー: ${AIENV_MACHINE_ROLE_MARKER}）。メイン機でこのコマンドを実行するとVaultのPreferencesが上書き削除される恐れがあるため拒否します。サブ機であれば先に scripts/install-sub.sh を実行してマーカーを設置してください。"
fi

[ -d "$DIR/.git" ] || fail "DIR が git リポジトリではありません: $DIR"
command -v git >/dev/null 2>&1 || fail "git が見つかりません"
command -v rsync >/dev/null 2>&1 || fail "rsync が見つかりません"

# 自己更新によるre-exec（下記2.参照）で渡された環境変数が「本物」かどうかを
# ここで一度だけ判定し、以降の1.（ロック）・2.（pull）双方で同じ判定結果を
# 使う（判定を2箇所へ分散させると、たとえば1.だけ「re-execとみなす」・2.は
# 「みなさない」という食い違いが起こりうるため、単一の正本にする）。
# `AIENV_UPDATE_SUB_REEXEC=1`だけでなく`AIENV_UPDATE_SUB_ORIG_BEFORE_HEAD`が
# このリポジトリに実在するcommitであることまで検証する（Codexレビュー
# 指摘・Minor対応: シェル環境やLaunchAgent設定にこの内部専用変数が誤って
# 残留・伝播した場合、検証無しだと恒久的にgit pull自体をスキップし続けて
# しまう。真正なre-exec以外はこのガードを無視して通常のロック取得・pull
# 経路へフォールバックする）。
IS_SELF_UPDATE_REEXEC=0
if [ "${AIENV_UPDATE_SUB_REEXEC:-}" = "1" ] \
   && [ -n "${AIENV_UPDATE_SUB_ORIG_BEFORE_HEAD:-}" ] \
   && git -C "$DIR" cat-file -e "${AIENV_UPDATE_SUB_ORIG_BEFORE_HEAD}^{commit}" >/dev/null 2>&1; then
  IS_SELF_UPDATE_REEXEC=1
fi

# --- 1. 多重起動防止ロック ---
# 2026-08-30 Codex 2巡目差し戻し・MAJOR対応: 従来は本ファイル内で
# backup-vault.shと同等のロック取得ロジックを独自に複製していたが、
# kill -0のPID生存確認だけでstale判定しており、元プロセスが異常終了した
# 直後にOSが同じPID番号を無関係な別の長時間生存プロセス（ログインシェル等）
# へ再利用すると、そのPIDが生き続ける限り永久に「既に実行中」skipが続く
# バグがあった（STALE_LOCK_SECONDSを宣言しながら一切参照していなかった）。
# scripts/lib/pid-lock.sh側の共有関数acquire_pid_lock()に同じ実バグが
# あったため併せて修正し（stale_secondsを時間側のフェイルセーフとして実際に
# 使うよう変更）、backup-vault.sh・maintenance.shが既に使っているこの共有
# 関数へ本ファイルも切り替えた（設計書§1.2「stale判定はscripts/lib/の
# 共有シェルライブラリをbackup-vault.shと共用・コピペ実装しない」に合わせる
# ＝重複実装の解消）。
# shellcheck source=scripts/lib/pid-lock.sh
source "$DIR/scripts/lib/pid-lock.sh"
if [ "$IS_SELF_UPDATE_REEXEC" = "1" ]; then
  # 自己更新によるre-exec後（下記2.参照）: execはPIDを保つため、直前の
  # プロセスが取得したロックファイルは引き続き自分自身の所有物である
  # （PID・プロセス開始時刻とも不変）。解放してから改めてacquire_pid_lock()
  # で再取得する設計だと、解放〜再取得の間に別プロセスがロックを奪える
  # 競合窓が生じ、そのプロセスは既にpull済みのHEADを見て「変更なし」と
  # 誤判定するため、config.toml再生成・Preferences再同期・骨格フォルダ補充
  # （4a〜4c）が次のupstream更新まで欠落しうる（Codexレビュー指摘・Major
  # 対応: 当初はexec前に明示的に解放していたが、この実害を見落としていた）。
  # そこで一切解放せず、既存のロックファイルを「自分のもの」としてそのまま
  # 引き継ぐ（handoff）。PID一致だけでは不十分（Codexフォローアップレビュー
  # 指摘・Major対応: 共有ライブラリ本体〈_pid_lock_is_alive()〉がPID再利用
  # 問題〈死んだ旧所有者のPID番号が別プロセスへ再利用される〉への対策として
  # PID＋プロセス開始時刻の指紋照合を採用しているのと同じ理由で、handoff側も
  # 指紋まで照合しないと、環境変数の誤残留＋異常終了した旧ロックの残留＋
  # PID番号の再利用が偶然重なった場合に誤って他プロセスのロックを「自分の
  # もの」として引き継いでしまう穴があった）。
  # ⚠️ ライブラリ本体（_pid_lock_is_alive）の「判定不能なら生存扱いへ倒す」
  # という設計は、あくまで“他プロセスの正当なロックを誤って削除しない”ための
  # fail-openであり、目的が逆（Codexフォローアップレビュー指摘・Major対応:
  # 当初はこの判定不能→受理という向きをそのまま流用していたが、handoffは
  # “これを自分のものとして採用してよいか”という判断であり、証明できない
  # 場合はfail-closedで拒否すべきだった）。そのためhandoffでは、記録された
  # 指紋が実指紋（予約値_PID_LOCK_FP_UNAVAILABLEや空の旧形式ではない）で
  # あり、かつ現在の指紋も取得でき、両者が完全一致した場合のみ受理する。
  if [ ! -e "$LOCK_FILE" ]; then
    fail "自己更新の再実行(exec)後、引き継ぐべき多重起動防止ロックが見つかりません（${LOCK_FILE}）。前段の実行がロックを取得できていなかった可能性があります。"
  fi
  lock_owner_pid="$(sed -n '1p' "$LOCK_FILE" 2>/dev/null || true)"
  lock_owner_fp="$(sed -n '2p' "$LOCK_FILE" 2>/dev/null || true)"
  handoff_ok=0
  if [ "$lock_owner_pid" = "$$" ] \
     && [ -n "$lock_owner_fp" ] \
     && [ "$lock_owner_fp" != "$_PID_LOCK_FP_UNAVAILABLE" ]; then
    current_fp="$(_pid_lock_fingerprint "$$" 2>/dev/null || true)"
    if [ -n "$current_fp" ] && [ "$lock_owner_fp" = "$current_fp" ]; then
      handoff_ok=1
    fi
  fi
  if [ "$handoff_ok" != "1" ]; then
    fail "自己更新の再実行(exec)後、多重起動防止ロックの所有者が自分自身と一致しません（記録PID: ${lock_owner_pid:-不明}・自分のPID: $$）。execの直前に別プロセスがロックを奪った可能性があります: ${LOCK_FILE}"
  fi
  _PID_LOCK_ACQUIRED_FILES+=("$LOCK_FILE")
  _pid_lock_register_cleanup
else
  acquire_pid_lock "$LOCK_FILE" "$STALE_LOCK_SECONDS" "update-sub"
fi

# --- 2. git pull --ff-only ---
if ! git -C "$DIR" remote get-url origin >/dev/null 2>&1; then
  warn "remote 'origin' が設定されていません。git pull をスキップします: $DIR"
  exit 0
fi

if [ "$IS_SELF_UPDATE_REEXEC" = "1" ]; then
  # 自己更新によるre-exec後（下記参照）: pullは既に完了しているため
  # 再実行しない。before_headは自己更新が起きる"前"の元の値を環境変数経由で
  # 引き継ぐ（引き継がないと、ここで改めてpullした場合〈既にpull済みなので
  # 差分ゼロ〉before_head=after_headとなり、3.の早期終了で本来届けるべき
  # config.toml再生成・Preferences再同期・骨格フォルダ補充・agents symlink化
  # が丸ごと空振りしてしまう）。
  before_head="${AIENV_UPDATE_SUB_ORIG_BEFORE_HEAD:-}"
  after_head="$(git -C "$DIR" rev-parse HEAD 2>/dev/null || echo '')"
  log "update-sub.sh自身の更新を検知したため、新版のスクリプトで最初からやり直しています（元のHEAD: ${before_head} -> ${after_head}）。"
else
  before_head="$(git -C "$DIR" rev-parse HEAD 2>/dev/null || echo '')"
  pull_rc=0
  git -C "$DIR" pull --ff-only >/dev/null 2>&1 || pull_rc=$?
  if [ "$pull_rc" -ne 0 ]; then
    warn "git pull --ff-only に失敗しました（ローカル変更との衝突等の可能性。サブは編集しない運用のため通常は起きないはずです）: $DIR"
    exit 0
  fi
  after_head="$(git -C "$DIR" rev-parse HEAD 2>/dev/null || echo '')"

  # ⚠️ 自己更新対策（2026-09-03 本人実査・緊急対応）: pullでこのスクリプト
  # 自身（scripts/update-sub.sh）が変わっていたら、その場で新版へexecしなおして
  # 最初からやり直す。bashはスクリプトを逐次読みするため、実行中の自分自身を
  # pullで書き換えたまま処理を続けると、後続処理が旧版のまま・あるいは不定動作
  # になる既知の危険がある（サブ機の実機で、1回目の実行だけagentsのsymlink化が
  # 効かないという実害が発生し発見した）。
  if [ "$before_head" != "$after_head" ]; then
    # git diff自体が失敗した場合（オブジェクト破損・before_headが不正な値等）は
    # 「自己更新なし」に丸めず、安全側（自己更新ありとみなして新版へやり直す）に
    # 倒す（Codex一次レビュー指摘・Major対応: `2>/dev/null || echo ''`だと
    # git diffの失敗と「差分ゼロ」を区別できず、fail-openで保護が効かなくなる
    # 経路があった）。
    self_changed=""
    diff_rc=0
    self_changed="$(git -C "$DIR" diff --name-only "$before_head" "$after_head" -- scripts/update-sub.sh 2>/dev/null)" || diff_rc=$?
    if [ "$diff_rc" -ne 0 ] || [ -n "$self_changed" ]; then
      if [ "$diff_rc" -ne 0 ]; then
        log "update-sub.sh自身が変わったかどうかを判定できませんでした（git diff失敗・コード${diff_rc}）。安全側として新版のスクリプトで最初からやり直します（${before_head} -> ${after_head}）。"
      else
        log "update-sub.sh自身が更新されました（${before_head} -> ${after_head}）。新版のスクリプトで最初からやり直します。"
      fi
      # ⚠️ ロックは解放しない（1.のhandoff方式を参照）。execはPIDを保つため、
      # 既に取得済みのロックファイルはexec後もそのまま自分自身の所有物であり、
      # 解放→再取得という往復を挟まないことで、その間に別プロセスへロックを
      # 奪われる競合窓自体を作らない（Codexレビュー指摘・Major対応: 当初は
      # ここでexec前に明示的解放していたが、解放〜再取得の間に別プロセスが
      # 割り込むと、そのプロセスは既にpull済みのHEADを見て「変更なし」と
      # 誤判定し、config.toml再生成・Preferences再同期・骨格フォルダ補充
      # 〈4a〜4c〉が次のupstream更新まで欠落しうる実害があった）。
      export AIENV_UPDATE_SUB_REEXEC=1
      export AIENV_UPDATE_SUB_ORIG_BEFORE_HEAD="$before_head"
      # LOCK_FILEを明示的にexportする（Codexレビュー指摘・Minor対応:
      # LOCK_FILEが呼び出し元の環境変数由来ではなく`: "${LOCK_FILE:=...}"`の
      # 既定値だった場合、この行が無いとexportされず子プロセスへ引き継がれ
      # ない。今回の新版はexec先も自分自身＝同じ既定値ロジックなので実害は
      # 出ないが、将来ロック既定パスの算出方法が変わった場合でも、1.が
      # handoffする対象を「実際に取得したロックのパスそのもの」に固定する
      # ための安全策）。
      export LOCK_FILE
      # execが対象を起動できない場合（パーミッション不足・破損等）でも
      # フォールスルーせずfail()を確実に届けるため、execfailを立てておく
      # （Codex一次レビュー指摘・Minor対応: execfail無しだと非対話bashは
      # exec失敗時にそのままshell自体を終了し、直後のfail()に到達しない）。
      shopt -s execfail
      exec bash "$DIR/scripts/update-sub.sh" "$@"
      fail "update-sub.sh自身の更新を検知しましたが、新版への再実行(exec)に失敗しました: $DIR/scripts/update-sub.sh"
    fi
  fi
fi

# --- 2b. settings.json の再生成（git の HEAD が変わっていなくても実行する。
#         §9.0 A-0-1・§11.2 項目3）---
# 値の正本＝model/effortの出力口を install-main.sh --print-leader-runtime に
# 一本化した（2026-09-01 配役表解凍 §4.2-a・§4.3。scripts/check-drift.shも
# 同じ出力口を呼ぶ）。プロファイルがv1（旧7キーのみ・schema_versionが無い/1）
# または実体が存在しない場合は、値出力口自身がAIENV_MODEL_MAIN/AIENV_MODEL_SUB
# （--sub-delegateの有無で選ぶ現行の解決）へ委譲する＝v1委譲期間の後方互換
# （§3.5）。旧`--print-model`は廃止予定のためもう呼ばない。HEAD不変でも実行
# するのは、プロファイルの手編集（リーダー行だけの変更）がgit履歴を進めなくても
# 再生成に反映されるようにするため（§11.2 項目3の受入条件そのもの）。
# 「早期終了（3.の変化無しexit）より前」に置くのが要点——変化無しでも
# settings.jsonだけは追随させる。生成に失敗したら旧ファイルは一切触らない
# （mktemp+mvの原子性。install-main.sh generate_settings_json() と同じ設計判断の
# 意図的な複製＝4a.のconfig.toml再生成と同じ流儀）。
SETTINGS_JSON_SRC="$DIR/claude/settings.json"
SETTINGS_JSON_DEST="$HOME/.claude/settings.json"
if [ ! -f "$SETTINGS_JSON_SRC" ]; then
  warn "claude/settings.json のテンプレが見つかりません（checkout破損の可能性）: $SETTINGS_JSON_SRC"
elif ! command -v python3 >/dev/null 2>&1; then
  warn "python3 が見つからないため settings.json の再生成をskipしました（旧ファイルは保持します）"
elif [ ! -x "$DIR/scripts/install-main.sh" ]; then
  warn "scripts/install-main.sh が見つかりません（checkout破損の可能性）。settings.json の再生成をskipします（旧ファイルは保持します）"
else
  # leader_runtime_error_message <コード> [<理由>] — install-main.sh
  # --print-leader-runtime が標準エラーへ返す機械可読コード（4.2-b。
  # `<コード>\t<理由>`の1行）を人向け文言へ変換する（2026-09-01 設計書§4.3。
  # 旧実装はここを`2>/dev/null`で理由ごと捨てて汎用WARNへ丸めていた＝静かに
  # 既定モデルへ倒れる経路を作らないための機構が理由まで見えないと直しようが
  # なかった。文面には必ず「プロファイルのリーダー行を確認してください」を
  # 含める＝リーダー指示）。scripts/check-drift.shにも同名の関数を意図的に
  # 複製している（両スクリプトは互いをsourceしない独立プロセスで、変換ロジックは
  # 数行のみのため共有libを新設するほどではない＝bedrock_env_file_kind()等
  # ここまでの既存の複製方針と同型）。
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

  MODEL_VALUE=""
  EFFORT_VALUE=""
  MODEL_OK=0
  # ⚠️ `if MODEL_VALUE=$(...); then`の条件は「コマンド置換の終了コード」だけを
  # 見ており、$MODEL_VALUE自体は非0終了でも出力があれば非空になりうる
  # （2026-08-30 Codex四次レビュー指摘・MAJOR対応: 以前は後続の判定で
  # `[ -n "$MODEL_VALUE" ]`だけを見ていたため、値出力口が部分出力を残して
  # 非0終了した場合に「取得成功」と誤判定し、取得失敗時のWARN分岐へ到達
  # しないまま生成経路へ入ってしまい、かつBEDROCK_STATUS/BEDROCK_PAYLOADが
  # 未初期化のままset -u下で異常終了しうる欠陥があった）。取得成功/失敗は
  # 明示フラグMODEL_OKで判定する。
  _leader_runtime_err_tmp="$(mktemp 2>/dev/null)" || _leader_runtime_err_tmp=""
  if [ -n "$_leader_runtime_err_tmp" ]; then
    # ⚠️ --sub-delegateは付けたまま渡す。v2解決自体には使われない（§4.2-f）が、
    # v1委譲期間中のフォールバック値（AIENV_MODEL_MAIN/AIENV_MODEL_SUBの
    # 出し分け）は引き続きこのフラグの有無だけで決まる。外すとv1機でサブが
    # メイン既定値へ倒れてしまう（2026-09-01実測で発見・回帰させない）。
    if _leader_runtime_json="$("$DIR/scripts/install-main.sh" --print-leader-runtime --sub-delegate 2>"$_leader_runtime_err_tmp")"; then
      # model・effortの抽出はinstall-main.sh本体（resolve_leader_runtime呼び出し
      # 直後）と同じ「1回のpython3呼び出しで両方取り出す」方式（値の再パースを
      # 増やさない）。⚠️ JSONとして読めることだけでなく、契約（4.2-a）が定める
      # 形自体も検査する: ①stdoutが物理行1行だけ（契約「1行のJSON」）②
      # トップレベルはobject③modelは非空文字列かつC0制御文字・DEL（0x00-0x1F・
      # 0x7F）を含まない④effortは**キーが存在する場合に限り**同様の非空
      # clean文字列（存在しない＝正常な省略。空文字列を許すとupdate側とcheck-
      # drift側で「未指定」の判定基準が食い違う）。enumそのもの（低/中/高等）
      # まではここで検査しない（enumはprovider/配送先ごとに異なりresolver側が
      # 唯一の正本＝値表の重複を増やさない）。契約違反はJSON解析失敗と同列に
      # resolve-leaderの出力契約違反として扱う（2026-09-01 Codex一次・二次
      # レビュー指摘・Major対応: 従来はjson.load()が例外を出さなければ無条件で
      # 信頼しており、非文字列値・制御文字混入・複数行整形JSON・
      # `"effort": ""`のような矛盾値の契約違反を検出できなかった）。
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
if "effort" in d:
    effort = d["effort"]
    if not is_clean_str(effort):
        sys.exit(1)
else:
    effort = ""
print(model)
print(effort)
' 2>/dev/null)"; then
        MODEL_VALUE="$(printf '%s\n' "$_leader_runtime_fields" | sed -n '1p')"
        EFFORT_VALUE="$(printf '%s\n' "$_leader_runtime_fields" | sed -n '2p')"
        MODEL_OK=1
      else
        warn "$(leader_runtime_error_message "PROFILE_RESOLVER_ERROR" "リーダー実行値のJSON解析に失敗しました（resolve-leaderの出力契約違反の可能性）")"
      fi
    else
      # ⚠️ 契約（4.2-b）は「標準エラーへ`<コード>\t<理由>`を1行」を定めている。
      # 契約外（複数行・タブ無し・理由が空/制御文字混入等）の出力は、たとえ
      # 1行目だけを見ても内容をそのまま理由として再掲しない＝契約違反自体を
      # 汎用文言に倒し、契約外の生テキストをログへ流さない
      # （2026-09-01 Codex二次レビュー指摘・Major対応: 従来は1行目を取り出す
      # だけで、その中身の妥当性〈タブの有無・理由の空文字・制御文字混入〉を
      # 検証していなかった）。
      _leader_runtime_stderr_parsed="$(python3 -c '
import re, sys

def is_clean_str(s):
    return s != "" and not any(ord(c) < 0x20 or ord(c) == 0x7f for c in s)

# 機械可読コードは契約（4.2-b・profile-resolve-contract-2026-09-01.md §4）が
# 列挙する既知の集合に限定する（2026-09-01 Codex三次レビュー指摘・Major
# 対応: 構文的にcleanなだけの未知コードを無条件で通すと、将来の実装不具合で
# 任意文字列が「コード」として素通りしログへ再掲されうる）。
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
        warn "リーダー実行値の取得に失敗しました（scripts/install-main.sh --print-leader-runtime）: $(leader_runtime_error_message "${_leader_runtime_code:-PROFILE_RESOLVER_ERROR}" "$_leader_runtime_reason")"
      else
        warn "リーダー実行値の取得に失敗しました（scripts/install-main.sh --print-leader-runtime）: $(leader_runtime_error_message "PROFILE_RESOLVER_ERROR" "標準エラーの出力が契約（4.2-b・1行のコード+理由）に従っていません")"
      fi
    fi
    rm -f "$_leader_runtime_err_tmp"
  else
    warn "リーダー実行値の取得に失敗しました: 一時ファイルを作成できませんでした"
  fi
  BEDROCK_STATUS="ABSENT"
  BEDROCK_PAYLOAD='{"env": {}, "rejected_keys": [], "malformed_lines": []}'
  if [ "$MODEL_OK" = "1" ]; then
    mkdir -p "$(dirname "$SETTINGS_JSON_DEST")"
    # Bedrock envファイルの状態を3分類する: ABSENT(未導入・正常)／
    # EXISTS_BUT_UNAVAILABLE(存在するのに読めない・解析できない)／OK。
    # EXISTS_BUT_UNAVAILABLEの場合はsettings.json本体の再生成ごと中止し
    # 既存ファイルを保持する（「生成失敗時は旧ファイルを触らない」契約＝
    # 設計書§11.2。2026-08-30 Codex 3巡目差し戻し・MAJOR対応: 従来は
    # パーミッション矯正失敗・print-bedrock-env-jsonの解析失敗のいずれも
    # 「Bedrock未導入」と同じ空payloadへ丸めた上でsettings.json本体の
    # 再生成・mv上書きを続行しており、既存設定に書かれていた
    # CLAUDE_CODE_USE_BEDROCK・リージョン・モデルpin等が黙って消え得た。
    # Bedrockパスがディレクトリの場合も`-f`テストが無警告のまま偽になり、
    # 同じ経路で空設定へ進んでいた。install-main.sh generate_settings_json()
    # と同じ設計に揃える）。
    bedrock_kind="$(bedrock_env_file_kind "$AIENV_BEDROCK_ENV_FILE")"
    if [ "$bedrock_kind" != "ABSENT" ]; then
      if [ "$bedrock_kind" = "UNAVAILABLE" ]; then
        warn "Bedrock envファイルのパスが通常ファイルではありません（ディレクトリ・dangling symlink・親ディレクトリの探索権限不足等の可能性）。settings.jsonの再生成を中止し、既存ファイルを保持します: $AIENV_BEDROCK_ENV_FILE"
        BEDROCK_STATUS="EXISTS_BUT_UNAVAILABLE"
      else
        # 非公開の値を持つため、読む前にパーミッションを0600へ揃える
        # （install-main.sh generate_settings_json()と同じ流儀。絶対厳守③）。
        # 矯正に失敗した/矯正後も600でない場合はfail-openで読み進めない
        # （Codex一次レビュー指摘Major対応の横展開）。
        chmod 600 "$AIENV_BEDROCK_ENV_FILE" 2>/dev/null || true
        bedrock_env_perm="$(stat -f '%Lp' "$AIENV_BEDROCK_ENV_FILE" 2>/dev/null || stat -c '%a' "$AIENV_BEDROCK_ENV_FILE" 2>/dev/null || echo '')"
        if [ "$bedrock_env_perm" != "600" ]; then
          warn "Bedrock envファイルのパーミッションを0600へ揃えられませんでした（現在: ${bedrock_env_perm:-不明}）。settings.jsonの再生成を中止し、既存ファイルを保持します: $AIENV_BEDROCK_ENV_FILE"
          BEDROCK_STATUS="EXISTS_BUT_UNAVAILABLE"
        else
          # Bedrock envファイルの解析は install-main.sh --print-bedrock-
          # env-json（＝compute_bedrock_env_json()）だけが行う（2026-08-30
          # 工程横断レビュー指摘・MAJOR-A対応: 以前はここで許可リスト・生
          # ファイルの読取処理を独自に複製しており〈値表は同一だが解析
          # ロジックが2箇所に分岐〉、installer/updaterの生成結果が食い違い
          # うる構造だった。生ファイルは一切直接readしない）。
          if BEDROCK_PAYLOAD="$("$DIR/scripts/install-main.sh" --print-bedrock-env-json 2>/dev/null)"; then
            BEDROCK_STATUS="OK"
          else
            warn "Bedrock envファイルの解析に失敗しました。settings.jsonの再生成を中止し、既存ファイルを保持します: $AIENV_BEDROCK_ENV_FILE"
            BEDROCK_STATUS="EXISTS_BUT_UNAVAILABLE"
            BEDROCK_PAYLOAD='{"env": {}, "rejected_keys": [], "malformed_lines": []}'
          fi
        fi
      fi
    fi
  fi
  if [ "$MODEL_OK" != "1" ]; then
    # 取得失敗の理由は上のwarn（leader_runtime_error_message経由）で既に出力済み。
    # settings.json の再生成をskipします（旧ファイルは保持します）。
    # ⚠️ 設計書§3.9「update-sub.shはリーダー行が未確定ならWARN＋非0終了」の
    # 実装（2026-09-01 Codex一次レビュー指摘・Blocking対応）。ここでは
    # 直ちにexitせず、後続の4a〜4d（config.toml再生成・Preferences再同期・
    # 骨格フォルダ補充・agents symlink化）は続行させたうえで、スクリプト末尾で
    # このフラグに従って終了する＝「対話の途中で止まらない」という同節の趣旨を
    # 保ちつつ、最終的な終了コードには必ず反映させる。
    EXIT_CODE=1
  elif [ "$BEDROCK_STATUS" = "EXISTS_BUT_UNAVAILABLE" ]; then
    # settings.json本体の再生成ごとskipし旧ファイルを保持する（上でWARN済み）。
    # ⚠️ ここも非0終了にする（状態機械B S4・2026-09-01工程横断レビュー差し戻し
    # MAJOR対応。上のEXIT_CODEコメント参照）。leader未確定の場合と同じ
    # deferred方式＝4a〜4dは続行し、スクリプト末尾でこのフラグに従って終了する。
    EXIT_CODE=1
  else
    settings_tmp="$(mktemp "$(dirname "$SETTINGS_JSON_DEST")/.$(basename "$SETTINGS_JSON_DEST").aienv-tmp.XXXXXX")"
    if PY_OUT="$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
if not isinstance(data, dict) or data.get('model') != '__AIENV_MODEL__':
    got = data.get('model') if isinstance(data, dict) else type(data).__name__
    print('template \"model\" field is not the __AIENV_MODEL__ placeholder (got: ' + repr(got) + ')', file=sys.stderr)
    sys.exit(1)
# effortLevelの目印検査はmodel側と対で行う（2026-09-01 配役表解凍 §4.2-g・
# install-main.sh generate_settings_json()と同じ検証。片側だけ検査すると
# 誰かがテンプレへ特定のeffort値を直接ハードコードしても検出できない）。
if data.get('effortLevel') != '__AIENV_EFFORT__':
    got_effort = data.get('effortLevel')
    print('template \"effortLevel\" field is not the __AIENV_EFFORT__ placeholder (got: ' + repr(got_effort) + ')', file=sys.stderr)
    sys.exit(1)
data['model'] = sys.argv[3]
effort = sys.argv[5]
if effort:
    data['effortLevel'] = effort
else:
    # 未指定はキー自体を削除する（セッション/アカウント既定に従う。
    # ⚠️ v1委譲期間だけはeffortにlegacy値'high'が入るためキーは維持される
    # ＝install-main.sh generate_settings_json()と同じ非対称。§4.2-g）。
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
" "$SETTINGS_JSON_SRC" "$settings_tmp" "$MODEL_VALUE" "$BEDROCK_PAYLOAD" "$EFFORT_VALUE" 2>&1)"; then
      mv "$settings_tmp" "$SETTINGS_JSON_DEST"
      log "settings.json を再生成しました（model=${MODEL_VALUE}, effort=${EFFORT_VALUE:-未指定}）: $SETTINGS_JSON_DEST"
      while IFS= read -r py_out_line; do
        case "$py_out_line" in
          SKIPPED_ENV_KEYS:*)
            warn "Bedrock envファイルのキーがテンプレ側envと衝突したためスキップしました（キー名: ${py_out_line#SKIPPED_ENV_KEYS:}）: $AIENV_BEDROCK_ENV_FILE"
            ;;
          REJECTED_ENV_KEYS:*)
            warn "Bedrock envファイルに許可リスト外のキーがあったため取り込みませんでした（キー名: ${py_out_line#REJECTED_ENV_KEYS:}）: $AIENV_BEDROCK_ENV_FILE"
            ;;
          MALFORMED_ENV_LINES:*)
            warn "Bedrock envファイルに解析できない行がありました（行番号: ${py_out_line#MALFORMED_ENV_LINES:}）: $AIENV_BEDROCK_ENV_FILE"
            ;;
        esac
      done <<EOF
$PY_OUT
EOF
    else
      rm -f "$settings_tmp"
      warn "settings.json の生成に失敗しました（旧ファイルは保持します）: ${PY_OUT}"
    fi
  fi
fi

# --- 2c. claude/agents/*.md を ~/.claude/agents/ へ symlink化する（git の
#         HEAD が変わっていなくても実行する。2b.と同じ理由） ---
# 本人指示（2026-09-03・最優先）: 従来このスクリプトは claude/agents/ の同期を
# 一切行っておらず、repoへ新しいロール定義（例: vault-scribe.md）を追加しても
# サブ機へ配布されない欠落があった（install-main.sh は agents を含む全symlinkを
# 再構築するが、update-sub.sh はサブ機の日常運用で使う軽量更新のため、新規
# agentファイルの取り込みに install-sub.sh のフル再実行が必要になっていた）。
# install-main.sh の agents symlinkループ・link()/backup_once()と同じ様式・
# 同じ退避規則（意図的な複製。ロジックを変える場合は install-main.sh 側も
# 合わせて見直すこと＝4a.の config.toml再生成と同じ流儀。共有関数化も検討したが
# 「最小差分を優先」という本人指示により見送った）。
# ⚠️ 当初は4.配下（HEAD変化時のみ実行）に置いていたが、サブ機の実機で
# 「2回目以降の実行はHEAD不変で3.の早期終了に入り、agentsのsymlink化に
# 一切到達しない」という実バグが発生したため、2026-09-03 本人実査で2b.と
# 同じ「HEAD不変でも実行する」位置へ移した（冪等で軽い処理のため毎回
# 走らせて問題ない）。
AGENTS_SRC_DIR="$DIR/claude/agents"
AGENTS_DEST_DIR="$HOME/.claude/agents"
if [ -d "$AGENTS_SRC_DIR" ]; then
  mkdir -p "$AGENTS_DEST_DIR"
  agents_md_count=0
  for f in "$AGENTS_SRC_DIR"/*.md; do
    [ -e "$f" ] || continue
    agents_md_count=$((agents_md_count + 1))
    name="$(basename "$f")"
    dest="$AGENTS_DEST_DIR/$name"
    if [ -L "$dest" ]; then
      # 既にsymlinkの場合: リンク先が正しければ何もしない（no-op）。違えば
      # （古いrepoパスを指している・danglingを含む）張り直す＝install-main.shの
      # `ln -sfn` と同じ「常に正しい状態へ収束させる」方針。
      [ "$(readlink "$dest")" = "$f" ] && continue
    elif [ -e "$dest" ]; then
      # symlinkでない実ファイルが既にある場合はinstall-main.sh backup_once()と
      # 同じ規則で退避してからsymlink化する（.pre-aienv.bakが既にあれば二重に
      # 退避しない＝インストール前オリジナルを保持し続ける）。
      if [ ! -e "$dest.pre-aienv.bak" ]; then
        cp "$dest" "$dest.pre-aienv.bak"
        log "backed up: $dest -> $dest.pre-aienv.bak"
      fi
    fi
    ln -sfn "$f" "$dest"
    log "linked: $dest -> $f"
  done
  if [ "$agents_md_count" -eq 0 ]; then
    # ⚠️ .mdが0件の場合もcheckout破損の可能性として扱い、以降のdangling走査は
    # 行わない（Codexフォローアップレビュー指摘・Minor対応: ディレクトリ自体は
    # あるが中身が空／.md以外しか無い状態も、ディレクトリ丸ごと欠落と同じ
    # 「checkout全体の異常」であり、既存の全symlinkを個別の「削除された
    # ロール」として誤って警告してしまう事故を防ぐため、この場合もdangling
    # 走査をskipする＝上のディレクトリ丸ごと欠落時の分岐と同じ扱いに揃える）。
    warn "claude/agents/ に .md ファイルが1つもありません（checkout破損の可能性）。roleのsymlink化はskipされました: $AGENTS_SRC_DIR"
  else
    # repoから削除されたロールのsymlink（dangling）は削除せず警告のみに留める
    # （本人指示: 削除は本人判断）。aienv管理下（$AGENTS_SRC_DIR配下を指す）
    # symlinkに限定して検査する＝本スクリプトが関与しない他アプリ由来のsymlinkを
    # 誤検知しないため。⚠️ $AGENTS_SRC_DIR自体が存在しない・中身が空の場合は
    # この走査を行わない（Codex一次・フォローアップレビュー指摘・Minor対応:
    # checkout全体が壊れているケースと個別ロール削除のケースを混同し、既存の
    # 全symlinkを誤って「削除されたロール」として警告してしまう事故を防ぐ）。
    if [ -d "$AGENTS_DEST_DIR" ]; then
      for existing in "$AGENTS_DEST_DIR"/*.md; do
        [ -L "$existing" ] || continue
        target="$(readlink "$existing")"
        case "$target" in
          "$AGENTS_SRC_DIR"/*)
            [ -e "$target" ] || warn "repoから削除されたロール定義へのsymlinkが残っています（削除はしません・本人判断）: $existing -> $target"
            ;;
        esac
      done
    fi
  fi
else
  warn "claude/agents/ が見つかりません（checkout破損の可能性）。roleのsymlink化をskipします: $AGENTS_SRC_DIR"
fi

# --- 3. repoの更新が無ければ、4.（config.toml再生成・Preferences再同期・
#         骨格フォルダ補充）は行わず終了する（settings.json再生成は2b.・
#         agents symlink化は2c.で既に済んでいる＝Codex一次レビュー指摘・
#         Nit対応の横展開） ---
if [ "$before_head" = "$after_head" ]; then
  log "変更なし（repoのHEAD: ${after_head}）。settings.json再生成・agents symlink化のほかは何もしません。"
  # ⚠️ ここで無条件に0終了すると、2b.でEXIT_CODEへ記録したリーダー未確定の
  # 失敗（§3.9）が握り潰される（2026-09-01 Codex一次レビュー指摘・Blocking
  # 対応の一部）。
  exit "$EXIT_CODE"
fi

log "更新を検知しました: ${before_head} -> ${after_head}"

# --- 4a. codex/config.toml をテンプレから再生成する ---
# install-main.sh の generate_config_toml() と同等の処理（意図的な複製。
# ロジックを変える場合はinstall-main.sh側も合わせて見直すこと）。
CONFIG_SRC="$DIR/codex/config.toml"
CONFIG_DEST="$HOME/.codex/config.toml"
if [ -f "$CONFIG_SRC" ]; then
  if [ -e "$CONFIG_DEST" ] && [ ! -L "$CONFIG_DEST" ] && [ ! -e "$CONFIG_DEST.pre-aienv.bak" ]; then
    cp "$CONFIG_DEST" "$CONFIG_DEST.pre-aienv.bak"
    log "backed up: $CONFIG_DEST -> $CONFIG_DEST.pre-aienv.bak"
  fi
  mkdir -p "$(dirname "$CONFIG_DEST")"
  # $HOME はここでは sed の「置換値」側（s#PATTERN#REPLACEMENT#）として使うため、
  # エスケープが必要なのは置換値の特殊文字（& \）と区切り文字（#）だけでよい
  # （install-main.sh の generate_config_toml() と全く同じ用途・同じエスケープ）。
  # 検索パターン側で使う check-drift.sh とは必要なエスケープの種類が異なる点に注意
  # （Codexレビュー指摘・Minor：正規表現メタ文字まで一律エスケープすると、
  # $HOME に "." 等が含まれる環境で生成される config.toml に余計な "\" が混入する）。
  escaped_home=$(printf '%s' "$HOME" | sed -e 's/[&\]/\\&/g' -e 's/#/\\#/g')
  config_tmp="$(mktemp "$(dirname "$CONFIG_DEST")/.$(basename "$CONFIG_DEST").aienv-tmp.XXXXXX")"
  sed "s#__AIENV_HOME__#${escaped_home}#g" "$CONFIG_SRC" > "$config_tmp"
  mv "$config_tmp" "$CONFIG_DEST"
  log "config.toml を再生成しました: $CONFIG_DEST"
else
  warn "codex/config.toml のテンプレが見つかりません（checkout破損の可能性）: $CONFIG_SRC"
fi

# --- 4b. Preferences をrsyncで再同期する（Preferences以外は絶対に触らない） ---
VP_PREFS="$DIR/vault-public/Preferences"
VAULT_PREFS="$VAULT/Preferences"
if [ -d "$VP_PREFS" ]; then
  mkdir -p "$VAULT_PREFS"
  rsync -a --delete "$VP_PREFS/" "$VAULT_PREFS/"
  log "Preferences を再同期しました: $VP_PREFS -> $VAULT_PREFS"
else
  warn "vault-public/Preferences が見つかりません（checkout破損の可能性）: $VP_PREFS"
fi

# --- 4c. 新しい骨格フォルダがあれば補充する（既存フォルダには一切触らない） ---
if [ -d "$DIR/vault-public" ]; then
  for d in "$DIR"/vault-public/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    [ "$name" = "Preferences" ] && continue
    dest="$VAULT/$name"
    if [ ! -e "$dest" ]; then
      mkdir -p "$dest"
      if [ -f "$d/README.md" ]; then
        cp "$d/README.md" "$dest/README.md"
      fi
      log "新しい骨格フォルダを補充しました: $dest"
    fi
  done
fi

log "done."
# ⚠️ EXIT_CODEは2b.でリーダー実行値の取得に失敗した場合、またはBedrock env
# ファイルが実在するのに読めない／解析できない場合（BEDROCK_STATUS=
# EXISTS_BUT_UNAVAILABLE）に1になる（設計書§3.9「update-sub.shはリーダー行が
# 未確定ならWARN＋非0終了」・状態機械B S4。2026-09-01 Codex一次レビュー指摘・
# Blocking対応／同日工程横断レビュー差し戻しMAJOR対応）。2c・4a〜4cは
# いずれの場合も続行済みのため、ここで初めて反映する。
exit "$EXIT_CODE"
