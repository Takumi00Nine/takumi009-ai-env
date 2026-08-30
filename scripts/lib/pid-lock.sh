#!/usr/bin/env bash
# 共有シェルライブラリ: PIDファイル方式の多重起動防止ロック（stale自動解除付き）
# （2026-07-16簡素化・cleanup決定#10「共有ロジックの分離原則」・PR1.5③）。
#
# scripts/backup-vault.sh の毎時実行向けに実装・敵対的レビュー3巡（TOCTOU対策の
# noclobber原子取得・ABA問題対策のmkdir回収ミューテックス・回収ミューテックス自体の
# stale判定は自動解除しないfail-closed設計）を経たロジックをそのまま抽出したもの。
# scripts/maintenance.sh（週次ランナー・PR2）のVault書込ロックもこの関数を使う
# （設計書§1.2「stale判定はscripts/lib/の共有シェルライブラリをbackup-vault.shと
# 共用・コピペ実装しない」）。
#
# 呼び出し規約:
#   acquire_pid_lock <lock_file> <stale_seconds> <log_prefix> [<status_file>]
#   成功時: ロックを取得し、プロセス終了時に自動解放するEXIT trapを登録して
#     return 0（trapは呼び出し元が既に設定済みのEXIT trapと合成する＝呼び出し元の
#     他のcleanup処理を上書きしない。詳細は_pid_lock_register_cleanup()参照）。
#   「既に実行中/再取得競合に負けた」場合: メッセージを表示してこのプロセスごと
#     exit 0（このスクリプトの今回の実行を穏当にskipする、という契約。呼び出し元は
#     戻り値を待たずにプロセスが終了する前提で使う）。status_fileを渡していれば
#     （かつ呼び出し元がscripts/lib/status-file.shを既にsource済みなら）
#     write_status_file(status_file, "busy") も行う。
#   「回収ミューテックスの競合が20回試行しても解消しない」場合: fail-closedで
#     exit 1（二重実行より「稀に手動での後片付けが要る」方を選ぶ設計判断）。
#     status_fileがあれば write_status_file(status_file, "error") も行う。
#
#   is_pid_lock_held <lock_file>
#     自分では取得・作成・stale解除しない、読み取り専用の生死チェック（他プロセスが
#     保持中のロックを横から覗く用途。詳細は関数定義直前のコメント参照）。
#     戻り値: 0=保持中／1=未保持（ファイル無し・stale含む）。
#
# 依存: ロックファイルの原子的な公開は`ln`（ハードリンク）で行うため、呼び出し元の
# `set -C`（noclobber）shopt状態には依存しない（詳細は_pid_lock_try_create()参照）。
#
# ロックファイルの形式（2026-08-30 PID再利用対策改修）: 1行目=PID、2行目は
# 次の3状態のいずれか（2026-08-30 Codex三次レビュー指摘・Minor対応で3状態に
# 更新）:
#   - 実際の指紋（`ps -o lstart=`による開始時刻。本改修以降の通常ケース）
#   - _PID_LOCK_FP_UNAVAILABLE予約値（本改修以降のコードがロック作成を試みた
#     が、その瞬間だけpsが使えず指紋を取得できなかった。PIDが生存する限り
#     fail-closedで無条件に生存扱いする＝経過時間を見ない）
#   - 2行目が全く無い（本改修より前に書かれた真の旧形式ロックのみ。この
#     場合だけstale_secondsによる経過時間フォールバックが働く）
# PID番号だけでのstale判定（kill -0）は、元プロセスが異常終了した直後に
# OSが同じPID番号を無関係な別の長時間生存プロセスへ再利用すると、そのPIDが
# 生き続ける限り永久にstale判定できなくなる実害があったため、指紋照合で
# 「本当に同じプロセスか」を区別できるようにした（詳細は_pid_lock_is_alive()
# 参照）。

# 「本当に同一プロセスか」を判定するための指紋（プロセス開始時刻）を取る。
# PID番号だけでは、元プロセスが終了した後にOSが同じ番号を無関係な別プロセスへ
# 再利用した場合と区別できない（kill -0はPID番号の生死しか見ない）ため、
# `ps -o lstart=`（BSD/GNU双方で標準サポートされる開始時刻。秒精度）を
# 併せて記録し、後で「同じPID番号かつ同じ開始時刻」かを照合する
# （2026-08-30 Codex 2巡目差し戻し再指摘・BLOCKING対応: 当初は経過時間だけで
# 生存ロックを強制期限切れにしていたが、それだと本当にまだ動いている正当な
# 所有者まで削除してしまい、二重実行・後継所有者のロックを旧所有者のEXIT trapが
# 誤って削除する、という排他性破壊を招く実害があった。PID+開始時刻の指紋照合なら、
# 経過時間に関係なく「本当に生きている元の所有者」を正しく生存扱いし続けられる）。
_pid_lock_fingerprint() {
  local pid="$1" fp
  # LC_ALL=C TZ=UTCで固定する（Codex二次レビュー指摘・MAJOR対応: `lstart`は
  # epoch値ではなく曜日・月名・時刻を含む表示文字列のため、ロック書込み時と
  # 照合時でロケール・タイムゾーンが異なる呼び出し環境（cronのミニマルなenv
  # とインタラクティブシェルのja_JP.UTF-8など）だと、同一プロセスでも表示
  # 文字列が変わり指紋不一致＝誤stale判定になりうる。生成環境を固定すれば
  # 呼び出し元のロケール設定に関わらず常に同じ文字列になる）。
  fp="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$pid" 2>/dev/null)" || return 1
  fp="$(printf '%s' "$fp" | tr -s '[:space:]' ' ')"
  fp="${fp# }"; fp="${fp% }"
  [[ -n "$fp" ]] || return 1
  printf '%s' "$fp"
}

# 新規作成時に指紋が取得できなかった場合の予約値（2026-08-30 Codex三次
# レビュー指摘・BLOCKING対応）。「2行目が全く無い」（＝本改修より前に書かれた
# 真の旧形式ロック）と「2行目はあるが取得に失敗した」（＝新しいコードで作った
# のにpsが一時的に使えなかった）を区別するために使う。前者だけがmtime
# フォールバックの対象になり、後者はPIDが生存する限りfail-closedで無条件に
# 生存扱いにする（もし両者を区別せず「2行目が実際の指紋文字列でなければ
# 旧形式扱い」にすると、psが一時的に使えないタイミングで作られたロックが
# 実質「指紋なし」に化けてmtimeフォールバックへ落ち、正当な所有者が生存中でも
# stale_seconds経過後に誤って解除される――という当初のBLOCKING指摘と同型の
# バグが、作成時の一瞬のps失敗という形で再発してしまう）。
# 実際の`ps -o lstart=`出力（曜日・月名・時刻・年を含む文字列）とは絶対に
# 一致しない固定文字列にしてある。
_PID_LOCK_FP_UNAVAILABLE='FINGERPRINT-UNAVAILABLE'

# ロックファイルへの原子的な書込み試行（ファイルが無い時だけ成功する）。
# 1行目=PID、2行目=指紋。取得できなければ_PID_LOCK_FP_UNAVAILABLE予約値を
# 書く（2行目を省略しない＝真の旧形式ロックと区別するため。詳細は
# _pid_lock_is_alive()参照）。
#
# 同じディレクトリに一時ファイルを作って内容を完全に書き終えてから、
# `ln`（ハードリンク作成。リンク先が既に存在するとEEXISTで失敗する＝
# 「存在しない名前への公開」がPOSIXで原子的）でロック名へ公開する
# （2026-08-30 Codex三次レビュー指摘・BLOCKING対応: 従来は`( set -C; ... ) >
# lock_file`方式で、ファイルの存在作成（O_EXCL相当）と内容の書込みが別々の
# syscallになっていた。作成直後・書込み前の一瞬だけ「空のロックファイル」が
# 他プロセスから見える窓があり、その間に別プロセスがPID行を読めず staleと
# 誤判定してrm+再作成してしまうと、元の所有者が後から自分の開いたfdへ
# 書き込んで「取得成功」に見え、両プロセスがロック取得済みになる二重取得
# 事故が起こり得た。ln方式なら、ファイルが「存在する」時点で必ず内容も
# 完全に揃っている＝中途半端な状態を外から観測できない）。
_pid_lock_try_create() {
  local lock_file="$1" fp tmpfile
  fp="$(_pid_lock_fingerprint "$$")" || fp="$_PID_LOCK_FP_UNAVAILABLE"
  tmpfile="$(mktemp "$(dirname -- "$lock_file")/.pid-lock.XXXXXX" 2>/dev/null)" || return 1
  # 書込み自体の終了コードを確認してから公開する（2026-08-30 Codex四次レビュー
  # 指摘・BLOCKING対応: ディスク容量不足・I/Oエラー・quota超過等で書込みが
  # 失敗しても確認せずlnしていると、空/部分的な一時ファイルを公開してしまい
  # 「完全に書き終えてから公開」という契約が崩れる）。
  # ⚠️ 以下の`rm -f -- "$tmpfile"`は全て`|| true`で明示的にガードする
  # （2026-08-30 Codex六次レビュー指摘・MAJOR対応と同型の予防的対応）。
  # 現在の唯一の呼び出し経路（acquire_pid_lock()内の`if _pid_lock_try_create
  # ...; then`・`_pid_lock_try_create ... && created=1`）ではif条件/AND-OR
  # リストとしての評価中は本関数内部でも`set -e`の免除が効くため、この
  # ガードが無くても実害は生じない（2026-08-30 Codex六次レビューで訂正
  # 済み・実証: `bash -c 'set -e; f(){ false; echo reached; }; if f; then
  # :; fi; echo ok'`は"reached"/"ok"とも出力される）。ただし本関数を将来
  # 直接（if条件やAND-ORリストの外で）呼ぶ形に変える場合や単体テストで
  # 直接呼び出す場合には免除が効かなくなるため、防御的に付けている。
  if ! printf '%s\n%s\n' "$$" "$fp" > "$tmpfile" 2>/dev/null; then
    rm -f -- "$tmpfile" || true
    return 1
  fi
  if ln "$tmpfile" "$lock_file" 2>/dev/null; then
    rm -f -- "$tmpfile" || true
    return 0
  fi
  rm -f -- "$tmpfile" || true
  return 1
}

# 取得済みロックファイルのパス一覧（複数回acquire_pid_lockを呼んだ場合に備え配列で
# 保持。通常は1プロセス1ロックだが、将来maintenance.sh等が複数ロックを扱う可能性を
# 閉じない設計）。trap文字列へパスを直接埋め込む方式（旧実装）は、パスに
# シングルクォート・セミコロン等の特殊文字が含まれると生成コマンドが構文エラーに
# なる、あるいは最悪コマンドインジェクションになりうる欠陥があった（Codex一次
# レビュー指摘・Major）。グローバル変数＋名前付きクリーンアップ関数にすることで、
# 関数呼び出し文字列自体は固定（`_pid_lock_cleanup`）にし、実際のパス展開は
# 関数内部で二重引用符付き変数参照として行う（`rm -f -- "$path"`）ため、パスの
# 中身がどのような文字列でもtrap文字列の構文を壊さない。
declare -a _PID_LOCK_ACQUIRED_FILES=()

_pid_lock_cleanup() {
  local f owner_pid owner_fp self_fp reclaim_mutex
  for f in "${_PID_LOCK_ACQUIRED_FILES[@]:-}"; do
    [[ -n "$f" ]] || continue
    # rm前に自己所有（PID＋指紋の一致）を確認する（2026-08-30 リーダー追補・
    # tester独立検証指摘・TOCTOU対応）。acquire_pid_lock()内のstale解除
    # ループ自体は所有権を確認済みだが、このEXIT trapは「取得した覚えの
    # あるパス」を無条件でrmしていた。理論上は自プロセス生存中は同一PID
    # 番号を他プロセスが名乗れないためPID一致だけでも十分だが、指紋（開始
    # 時刻）も併せて照合し、ファイルの中身が本当に自分自身が書いたものかを
    # 二重に確認してから消す（万一の取り違え・将来の実装変更に対する
    # 多層防御）。所有権を確認できなければ黙ってこのファイルはスキップする
    # （他プロセスが取得した生存ロックを誤って消さない）。
    # ⚠️ 確認とrmを1つの排他区間にまとめる（2026-08-30 Codex五次レビュー
    # 指摘・MAJOR対応: 確認だけしてrmが別コマンドのままだと、その一瞬の
    # 間に別プロセスがこのロックを回収してしまう競合窓が残っていた）。
    # acquire_pid_lock()のstale解除ループと同じ回収ミューテックス
    # （`${lock_file}.reclaim`）を使い、取得できた区間内でのみ確認・削除
    # する。ミューテックスを取得できない場合は「今まさに誰かがここを
    # 回収中」とみなし、待たずにこのファイルの削除自体を諦める（EXIT trap
    # なのでプロセス終了を長時間ブロックしない設計判断）。
    reclaim_mutex="${f}.reclaim"
    mkdir "$reclaim_mutex" 2>/dev/null || continue
    if [[ -f "$f" ]]; then
      owner_pid="$(sed -n '1p' "$f" 2>/dev/null)" || owner_pid=""
      if [[ "$owner_pid" == "$$" ]]; then
        owner_fp="$(sed -n '2p' "$f" 2>/dev/null)" || owner_fp=""
        if [[ -z "$owner_fp" || "$owner_fp" == "$_PID_LOCK_FP_UNAVAILABLE" ]]; then
          # `rm -f`は通常失敗しないが、万一失敗しても`set -e`下でここが
          # 打ち切られ、直後の`rmdir`（ミューテックス解放）へ到達しない
          # 事故を防ぐため`|| true`で必ず後続へ進める（2026-08-30 Codex
          # 六次レビュー指摘・MAJOR対応: rmdir未到達だと回収ミューテックス
          # が残置され、以後このロックの取得がfail-closedで失敗し続ける）。
          rm -f -- "$f" || true
        else
          self_fp="$(_pid_lock_fingerprint "$$")" || self_fp=""
          # `[[ ... ]] && rm`という単独&&鎖でも書けるが、可読性のため明示的
          # なif文にしている（2026-08-30 Codex六次レビューで訂正: 当初は
          # 「判定が偽だとset -e下で本関数が打ち切られる」実バグだと誤診断
          # していたが、AND-ORリストの最後以外のコマンドはerrexit免除の
          # 対象であり、実際には判定が偽でもerrexitは発動しないことを
          # 実証済み。rm自体の`|| true`は依然として必要＝rm失敗時に直後の
          # rmdirへ到達させるため）。
          if [[ -n "$self_fp" && "$owner_fp" == "$self_fp" ]]; then
            rm -f -- "$f" || true
          fi
        fi
      fi
    fi
    rmdir "$reclaim_mutex" 2>/dev/null || true
  done
}

# 呼び出し元が既に設定しているEXIT trap（あれば）を壊さず、_pid_lock_cleanupを
# 追加合成する（Codex一次レビュー指摘・Major対応: 旧実装は`trap ... EXIT`で
# 無条件上書きしており、呼び出し元が別のcleanup処理を先にtrap登録していた場合に
# それを消してしまっていた）。
_pid_lock_register_cleanup() {
  local existing
  existing="$(trap -p EXIT)"
  if [[ -n "$existing" ]]; then
    # `trap -p EXIT` の出力は `trap -- '既存コマンド' EXIT` 形式。
    # 既存コマンド部分だけを取り出し、本関数呼び出しと `;` で連結する。
    local existing_cmd
    existing_cmd="$(printf '%s' "$existing" | sed -E "s/^trap -- '(.*)' EXIT\$/\\1/")"
    if [[ -n "$existing_cmd" && "$existing_cmd" != "_pid_lock_cleanup" ]]; then
      trap "${existing_cmd}; _pid_lock_cleanup" EXIT
      return
    fi
  fi
  trap "_pid_lock_cleanup" EXIT
}

# ロック保有者PIDが「本当に生きている（＝自分が書いたロックの正当な保有者が
# まだ動いている）」かを判定する。
#
# 判定の優先順位（2026-08-30 Codex 2巡目・三次差し戻し・BLOCKING対応）:
#   1. kill -0でPID番号自体が死んでいれば即stale（従来どおり）。
#   2. ロックファイル2行目が_PID_LOCK_FP_UNAVAILABLE予約値なら、PIDが生存する
#      限り無条件で生存扱い（経過時間を一切見ない）。これは「新しいコードが
#      ロック作成を試みたが、その瞬間だけpsが使えず指紋を取得できなかった」
#      ケース専用（2026-08-30 Codex三次レビュー指摘・BLOCKING対応: 当初は
#      作成時に指紋取得が失敗すると2行目自体を省略しており、真の旧形式
#      ロックと区別が付かずmtimeフォールバックへ落ちてしまっていた。これだと
#      作成時の一瞬のps失敗だけで、後からstale_secondsが経過した時点で
#      正当な生存所有者を誤って解除してしまう＝最初のBLOCKING指摘と同型の
#      再発だった。予約値で「真に指紋を記録できなかった」ことを明示すれば、
#      このケースは時間に関わらずfail-closedにできる）。
#   3. 2行目に実際の指紋（開始時刻）が記録されていれば、現在そのPIDを
#      持つプロセスの指紋と照合する。一致すれば「本当に同じプロセス」＝
#      経過時間に関わらず生存扱い（どれだけ長時間動いていても、正当な
#      所有者を強制的に期限切れにしない＝二重実行・後継所有者のロックを
#      旧所有者が誤って削除する事故を防ぐ）。不一致（PID番号が別プロセスへ
#      再利用された）ならstale。現在の指紋が取得できない場合（psの一瞬の
#      レース・権限制約等）は「判定不能」を「生存」側へ倒す（Codex二次
#      レビュー指摘・BLOCKING対応）。
#   4. 2行目が全く無い（空行・行自体が無い）真の旧形式ロックファイル
#      （本改修以前に書かれたものが引き継がれた場合のみ。本改修以降のコードは
#      2行目を必ず書く＝上記2の予約値かこの3の実指紋のどちらか）に限り、
#      経過時間がstale_seconds未満なら生存扱いとするフォールバックを使う
#      （stale_secondsはこの経路でのみ効く）。経過時間の起点（ロックファイル
#      のmtime）が取得できない場合は「判定不能」を「生存」側へ倒す
#      （fail-closedで排他性を優先。Codex指摘のMAJOR対応）。
_pid_lock_is_alive() {
  local lock_file="$1" pid="$2" stale_seconds="$3"
  local stored_fp current_fp mtime now age
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1

  stored_fp="$(sed -n '2p' "$lock_file" 2>/dev/null)"
  if [[ "$stored_fp" == "$_PID_LOCK_FP_UNAVAILABLE" ]]; then
    return 0   # 作成時に指紋取得が失敗しただけ→PID生存する限り無条件で生存扱い
  fi
  if [[ -n "$stored_fp" ]]; then
    current_fp="$(_pid_lock_fingerprint "$pid")" || return 0   # 判定不能→生存扱い
    [[ "$current_fp" == "$stored_fp" ]]
    return
  fi

  # 旧形式（指紋なし）フォールバック。mtime取得は2つの`stat`方言を別々の
  # 代入として順に試す（Codex指摘・MAJOR対応: 単一のコマンド置換で
  # `stat -f ... || stat -c ...`と`||`連結すると、GNU環境で最初の`stat -f`が
  # 一部出力してから失敗した場合に出力が連結されて非数値になりうる）。
  if ! mtime="$(stat -f %m "$lock_file" 2>/dev/null)"; then
    if ! mtime="$(stat -c %Y "$lock_file" 2>/dev/null)"; then
      return 0   # 判定不能→生存扱い（fail-closedで排他性を優先）
    fi
  fi
  [[ "$mtime" =~ ^[0-9]+$ ]] || return 0   # 非数値も判定不能扱い
  now="$(date +%s)"
  age=$(( now - mtime ))
  [[ "$age" -lt "$stale_seconds" ]]
}

# 他プロセスが保持中の（自分では取得しない）PIDロックの生死だけを読み取り専用で
# 確認する。acquire_pid_lock()と異なり、ロックファイルの作成・stale判定・回収は
# 一切行わない＝副作用ゼロの読み取り専用チェック（2026-07-16簡素化・設計書§1.2
# 「backup-vault.sh側にも『このロックが取得中なら今回のcommitを見送りexit 0』
# という軽量チェックを追加」＝backup-vault.shがmaintenance.shの
# vault-writer.lockを横から覗く用途向け。自分の所有物ではないロックを勝手に
# stale解除してしまうと、maintenance.sh実行中に本来のロックを壊しかねないため、
# 意図的に「見るだけ」の別関数として分離した）。
# 戻り値: 0=保持中／1=未保持（ファイル無し・空・PID自体が死んでいる・指紋が
# 記録されておりPID番号が別プロセスへ再利用されたと確認できた場合）。
# stale判定してもファイル自体は削除しない（読み取り専用の契約は不変）。
#
# 指紋照合（2026-08-30 Codex二次レビュー指摘・MAJOR対応）: acquire_pid_lock()
# 側と同じPID再利用問題がここにも存在した（PID生存＝即held扱いだと、元の
# 所有者が異常終了しPID番号が別プロセスへ再利用された場合に「保持中」の
# 誤判定が続き、backup-vault.shがVault書込ロックを永久にheld扱いしてbackup
# を止め続けてしまう）。ただし本関数は「見るだけ」（stale解除の権限を持たない
# 読み取り専用peek）という設計上の制約があるため、判定不能な場合は
# 「未保持」より安全側の「保持中」（＝呼び出し元に今回のcommitを見送らせる。
# 誤ってbackupを許可してmaintenance.shの処理と競合させるよりは、余分に
# 1回commitを見送る方が安全）に倒す。「不一致を確認できた」場合だけ明確に
# 未保持とする。
is_pid_lock_held() {
  local lock_file="$1" pid stored_fp current_fp
  [[ -f "$lock_file" ]] || return 1
  pid="$(sed -n '1p' "$lock_file" 2>/dev/null)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1

  stored_fp="$(sed -n '2p' "$lock_file" 2>/dev/null)"
  # 2行目が全く無い（真の旧形式）→PID生存のみでheld扱い。
  # _PID_LOCK_FP_UNAVAILABLE予約値（作成時にps取得が失敗しただけ）→
  # PID生存する限り無条件でheld扱い（_pid_lock_is_alive()と同じ理由。
  # ここで通常の指紋比較にかけると、実際の指紋文字列と一致しないため
  # 誤ってnot held判定になってしまう＝2026-08-30 Codex三次レビュー指摘・
  # BLOCKING対応と同型の穴を塞ぐ）。
  [[ -z "$stored_fp" || "$stored_fp" == "$_PID_LOCK_FP_UNAVAILABLE" ]] && return 0
  current_fp="$(_pid_lock_fingerprint "$pid")" || return 0   # 判定不能→held扱い
  [[ "$current_fp" == "$stored_fp" ]]
}

# $1=status_file(空文字列可) $2=status_word。status_fileが空、または
# write_status_file関数が未ロード（scripts/lib/status-file.shを未sourceの
# 呼び出し元）の場合は何もしない（pid-lock.shはstatus-file.shへハード依存しない
# ＝互いに独立してsource可能な設計を維持するためのダックタイピング）。
_pid_lock_maybe_write_status() {
  local status_file="$1" status_word="$2"
  [[ -n "$status_file" ]] || return 0
  declare -f write_status_file >/dev/null 2>&1 || return 0
  write_status_file "$status_file" "$status_word"
}

acquire_pid_lock() {
  # $4=status_file（省略可・2026-07-16簡素化・設計書§1.2）。busy/error確定時に
  # write_status_file()（status-file.shが呼び出し元でsource済みの場合のみ）へ
  # 機械可読な状態を書いてから、従来どおりexitする。
  local lock_file="$1" stale_seconds="$2" log_prefix="${3:-lock}" status_file="${4:-}"
  local reclaim_mutex="${lock_file}.reclaim"

  # stale_secondsは（指紋なし旧形式ロックのフォールバック経路でのみとはいえ）
  # 算術比較に使うため、正の整数であることを呼び出し時点で検証する
  # （Codex一次レビュー指摘・Minor対応: 非数値は算術エラーに、0や負数は
  # フォールバック経路で生存ロックを即時解除してしまう）。
  if [[ ! "$stale_seconds" =~ ^[1-9][0-9]*$ ]]; then
    echo "[$log_prefix] FAIL: stale_secondsが正の整数ではありません（呼び出し元のバグ）: '${stale_seconds}'" >&2
    exit 1
  fi

  if _pid_lock_try_create "$lock_file"; then
    _PID_LOCK_ACQUIRED_FILES+=("$lock_file")
    _pid_lock_register_cleanup
    return 0
  fi

  # 既に存在＝実行中 or stale。中身のPIDを見て判定する。
  local old_pid
  old_pid="$(sed -n "1p" "$lock_file" 2>/dev/null || true)"
  if _pid_lock_is_alive "$lock_file" "$old_pid" "$stale_seconds"; then
    echo "[$log_prefix] 既に実行中です（pid=${old_pid}）。今回はskipします。"
    _pid_lock_maybe_write_status "$status_file" busy
    exit 0
  fi

  # stale の疑い。毎回まず「既に別プロセスが有効なロックを取得済みでないか」を
  # 確認してから、取れていなければ回収ミューテックスの取得を試みる。
  local attempt
  for attempt in $(seq 1 20); do
    old_pid="$(sed -n "1p" "$lock_file" 2>/dev/null || true)"
    if _pid_lock_is_alive "$lock_file" "$old_pid" "$stale_seconds"; then
      echo "[$log_prefix] ロック再取得中に別プロセスが先に取得しました（pid=${old_pid}）。今回はskipします。"
      _pid_lock_maybe_write_status "$status_file" busy
      exit 0
    fi
    if mkdir "$reclaim_mutex" 2>/dev/null; then
      # ミューテックス取得後に改めてPIDを読み直す（古い判定を使い回さず再確認する）。
      old_pid="$(sed -n "1p" "$lock_file" 2>/dev/null || true)"
      if _pid_lock_is_alive "$lock_file" "$old_pid" "$stale_seconds"; then
        rmdir "$reclaim_mutex" 2>/dev/null || true
        echo "[$log_prefix] 既に実行中です（pid=${old_pid}）。今回はskipします。"
        _pid_lock_maybe_write_status "$status_file" busy
        exit 0
      fi
      echo "[$log_prefix] WARN: stale なロックファイルを検出しました（pid=${old_pid:-unknown}・PIDが生存していない、PID番号が別プロセスへ再利用された、または指紋なし旧形式ロックで経過時間がstale_seconds=${stale_seconds}秒を超過）。解除して続行します: $lock_file" >&2
      # `|| true`でガードする（2026-08-30 Codex六次レビュー指摘・MAJOR対応と
      # 同型の予防的対応: 未ガードのままrmが失敗すると`set -e`下でここが
      # 打ち切られ、直後の`rmdir`〈回収ミューテックス解放〉へ到達しない）。
      rm -f "$lock_file" || true
      local created=0
      _pid_lock_try_create "$lock_file" && created=1
      rmdir "$reclaim_mutex" 2>/dev/null || true
      if [[ "$created" -eq 1 ]]; then
        _PID_LOCK_ACQUIRED_FILES+=("$lock_file")
        _pid_lock_register_cleanup
        return 0
      fi
      # rm直後・再作成までのごく一瞬に、別プロセスが先にロックを取得できた場合
      # （正常な競合。二重実行にはならない）。即failせずループ先頭へ戻り、
      # 現在の所有者を再確認する。
      continue
    fi
    # 回収ミューテックスは他プロセスが保持中。少し待ってから再試行する。
    sleep 0.05
  done
  echo "[$log_prefix] FAIL: ロック取得に失敗しました（他プロセスとの競合が解消しません。回収ミューテックス（${reclaim_mutex}）が長時間残っている場合は、前回実行がクラッシュした痕跡の可能性があります。実行中のプロセスが無いことを確認してから手動で削除してください: rmdir ${reclaim_mutex}）: $lock_file" >&2
  _pid_lock_maybe_write_status "$status_file" error
  exit 1
}
