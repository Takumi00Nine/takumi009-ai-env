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
# 依存: bashの `set -C`（noclobber）が有効化されていなくても、本関数はサブシェル内で
# 明示的に `( set -C; ... )` するため呼び出し元のshopt状態に依存しない。

# ロックファイルへの原子的な書込み試行（ファイルが無い時だけ成功する＝noclobber）。
_pid_lock_try_create() {
  local lock_file="$1"
  ( set -C; echo "$$" > "$lock_file" ) 2>/dev/null
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
  local f
  for f in "${_PID_LOCK_ACQUIRED_FILES[@]:-}"; do
    [[ -n "$f" ]] && rm -f -- "$f"
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

# 他プロセスが保持中の（自分では取得しない）PIDロックの生死だけを読み取り専用で
# 確認する。acquire_pid_lock()と異なり、ロックファイルの作成・stale判定・回収は
# 一切行わない＝副作用ゼロの読み取り専用チェック（2026-07-16簡素化・設計書§1.2
# 「backup-vault.sh側にも『このロックが取得中なら今回のcommitを見送りexit 0』
# という軽量チェックを追加」＝backup-vault.shがmaintenance.shの
# vault-writer.lockを横から覗く用途向け。自分の所有物ではないロックを勝手に
# stale解除してしまうと、maintenance.sh実行中に本来のロックを壊しかねないため、
# 意図的に「見るだけ」の別関数として分離した）。
# 戻り値: 0=保持中（生きているPIDが書かれている）／1=未保持（ファイル無し・空・
# stale=書かれたPIDが既に死んでいる。stale判定してもファイル自体は削除しない）。
is_pid_lock_held() {
  local lock_file="$1" pid
  [[ -f "$lock_file" ]] || return 1
  pid="$(cat "$lock_file" 2>/dev/null || true)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
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

  if _pid_lock_try_create "$lock_file"; then
    _PID_LOCK_ACQUIRED_FILES+=("$lock_file")
    _pid_lock_register_cleanup
    return 0
  fi

  # 既に存在＝実行中 or stale。中身のPIDを見て判定する。
  local old_pid
  old_pid="$(cat "$lock_file" 2>/dev/null || true)"
  if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
    echo "[$log_prefix] 既に実行中です（pid=${old_pid}）。今回はskipします。"
    _pid_lock_maybe_write_status "$status_file" busy
    exit 0
  fi

  # stale の疑い。毎回まず「既に別プロセスが有効なロックを取得済みでないか」を
  # 確認してから、取れていなければ回収ミューテックスの取得を試みる。
  local attempt
  for attempt in $(seq 1 20); do
    old_pid="$(cat "$lock_file" 2>/dev/null || true)"
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
      echo "[$log_prefix] ロック再取得中に別プロセスが先に取得しました（pid=${old_pid}）。今回はskipします。"
      _pid_lock_maybe_write_status "$status_file" busy
      exit 0
    fi
    if mkdir "$reclaim_mutex" 2>/dev/null; then
      # ミューテックス取得後に改めてPIDを読み直す（古い判定を使い回さず再確認する）。
      old_pid="$(cat "$lock_file" 2>/dev/null || true)"
      if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
        rmdir "$reclaim_mutex" 2>/dev/null || true
        echo "[$log_prefix] 既に実行中です（pid=${old_pid}）。今回はskipします。"
        _pid_lock_maybe_write_status "$status_file" busy
        exit 0
      fi
      echo "[$log_prefix] WARN: stale なロックファイルを検出しました（pid=${old_pid:-unknown} は生存していません）。解除して続行します: $lock_file" >&2
      rm -f "$lock_file"
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
