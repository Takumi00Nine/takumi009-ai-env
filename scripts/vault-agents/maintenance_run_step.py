#!/usr/bin/env python3
"""maintenance.sh（設計書§1.2 Phase 1）が各検出ステップ（check-drift.sh・
fragments_log.py・vault_inventory.py・knowledge_merge_candidates.py・
decision_propagation.py）を起動するための共通ラッパー。

責務（設計書§1.2「各ステップは scripts/vault-agents/maintenance_run_step.py
経由で起動しPython subprocess.run(cmd, timeout=N, start_new_session=True)＋
TimeoutExpired時 os.killpg で子プロセスごと終了（bashのkillは子を止められない
対策・bashのtimeout/gtimeoutはmacOS既定に無いため使わない）」の実装:
  - 子プロセスを新しいセッション/プロセスグループ（start_new_session=True・
    setsid(2)相当）で起動する。これにより子プロセスが自分自身の子（孫プロセス）を
    バックグラウンド起動しても、それらは同じプロセスグループに属する。
  - 指定秒数でタイムアウトしたら、直接の子プロセスだけでなくプロセスグループ
    全体をSIGKILLで強制終了する（bash側の`kill`や素朴な`proc.kill()`は直接の
    子1つしか止められず、孫プロセスが残留し続ける事故を防ぐ）。
  - ラッパー自身がSIGTERM/SIGHUPで終了させられた場合・KeyboardInterrupt
    （SIGINT）を受けた場合も、戻る前に必ず同じプロセスグループkillを行う
    （2026-07-16 Codexレビュー指摘Major対応: タイムアウト経路以外＝maintenance.sh
    自体がタイムアウトやユーザ中断で先に終了するケースで、孫プロセスだけが
    残留する事故を防ぐ）。
  - 標準入出力は継承する（そのまま親（maintenance.sh）のstdout/stderrへ流す）。
    fragments_log.py等のJSON出力ステップの生出力を一切加工せずに素通しする
    ため（バッファリング・二重変換によるJSON破損を避ける）。
  - 終了コード: 通常終了時は子プロセスの終了コードをそのまま返す（シグナル
    終了時はbashの慣習＝128+シグナル番号へ正規化する）。タイムアウト時は124を
    返す（GNU coreutils `timeout(1)` コマンドの慣習に合わせる。macOS標準には
    このコマンドが無いため簡易再実装する形になるが、終了コードの意味だけは
    合わせておくことで、呼び出し側のbash（maintenance.sh）が
    `[[ $rc -eq 124 ]]` のように使い慣れた判定を書ける）。
    **ただし終了コードだけでは「ラッパー自身の状態（タイムアウト/起動失敗/
    使い方エラー）」と「子プロセス自身がたまたま同じ値を返した場合」を完全には
    区別できない**（2026-07-16 Codexレビュー指摘Major・1バイトの終了コードに
    複数の意味を詰め込む以上、原理的に解消しきれない制約として明記する）。
    子プロセス側の終了コードと衝突なく確実に判別したい呼び出し側は、
    `--status-file PATH` を使うこと（機械可読なJSONで`timed_out`/`spawn_error`/
    `usage_error`を返す。子プロセスの終了コードとは独立したチャネル）。
    ただしSIGTERM/SIGHUPでラッパー自身が終了させられた経路では、実際のOS
    シグナルで死ぬ（bashの`$?`が128+シグナル番号になる通常の慣習に合わせる
    ため）ため、--status-fileは書き込まれない（既知の制約。この経路は外部
    からの中断＝maintenance.sh自体の異常終了・システムシャットダウン等の
    非通常系であり、タイムアウト検出という本来の主眼には影響しない）。
    実行開始時に前回分のstatus-fileを削除してから今回分を書くため、**呼び出し
    側は「rc取得後、status-fileが存在せず、または壊れていれば、ラッパーが
    最後まで到達できなかった（＝status-fileの内容は信用できない）」とみなす
    こと**（2026-07-16 Codex 4巡目レビュー指摘Major対応）。ただし`"--"`の
    指定漏れ・`--timeout`/`--status-file`自体の型が不正でargparseが失敗する
    使い方エラーの場合に限っては、--status-fileの値自体が確定する前に失敗する
    ためこの削除処理を実行できない（既知の制約。運用中に繰り返し起こる類の
    問題ではなく、maintenance.sh側の呼び出しコード自体の誤りなので、導入時の
    動作確認で検出される想定）。

実装上の注記（設計書の記述との差異・意図的）: 設計書は「subprocess.run(...)＋
TimeoutExpired時にos.killpg」と書いているが、subprocess.run()は内部でPopenを
生成・破棄するためタイムアウト発生時に呼び出し元へ子プロセスのpidを渡さない
（os.killpg()にはpidが必須）。そのため本実装ではsubprocess.Popen()を直接使い、
`proc.wait(timeout=N)`でタイムアウトを検出したうえでos.killpg()する。外部から
観測できる挙動（timeout秒＋start_new_session＋タイムアウト時はプロセスグループ
ごとSIGKILL）は設計書の意図と完全に一致する。
"""
import argparse
import json
import math
import os
import pathlib
import signal
import subprocess
import sys
import tempfile

# タイムアウトを意味する終了コード（GNU coreutils timeout(1)の慣習）。
TIMEOUT_EXIT_CODE = 124

# 使い方エラー（"--"の指定漏れ・実行コマンド未指定・--timeoutの値が不正）を
# 表す終了コード。子プロセスの終了コード(0-255・timeout時124)と混同しないよう、
# 子プロセスを一切起動しないケースに限定して使う。
USAGE_ERROR_EXIT_CODE = 2

# 子プロセスをそもそも起動できなかった場合（実行ファイルが無い・実行権限が無い・
# cwdが不正等）の終了コード。shellの「コマンドが見つからない」慣習(127)に合わせる
# （権限エラー等も127へ丸める簡略化＝126/127の細分けはしない。呼び出し側は
# 「起動できたかどうか」だけを見れば十分なため）。
SPAWN_ERROR_EXIT_CODE = 127

# プロセスグループ強制終了後、ゾンビ化を避けるために最終waitへ許す猶予秒数。
# SIGKILL後の後始末は通常一瞬で終わるため短めの固定値で十分（fail-safe:
# それでも終わらない場合はraiseせず諦めて戻る＝呼び出し側を巻き込まない）。
_KILL_WAIT_SECONDS = 5.0

# 受信したら「子プロセスグループをkillしてから同じシグナルで死ぬ」対象シグナル。
# SIGKILL/SIGSTOPはPythonでハンドラを登録できないため対象外（登録しようとすると
# RuntimeErrorになる）。
_FORWARDED_SIGNALS = (signal.SIGTERM, signal.SIGHUP)


def _normalize_returncode(rc):
    """Popen.returncodeをbashの終了コード慣習へ正規化する。シグナル終了時
    （Pythonの慣習で負値＝-シグナル番号）は`128+シグナル番号`へ変換する
    （2026-07-16 Codexレビュー指摘Minor対応: 変換しないとsys.exit(-15)が
    シェルからは241相当になり、bash利用者が期待する143(=128+SIGTERM)と
    食い違っていた）。通常終了(0以上)はそのまま返す。"""
    if rc is not None and rc < 0:
        return 128 - rc
    return rc


def _kill_process_group(proc):
    """procのプロセスグループ全体をSIGKILLし、直接の子が未回収ならwaitで回収する
    （ゾンビ化防止・fail-safeでタイムアウトしても諦めて戻る）。

    直接の子(proc)が既に終了しているかどうかで判定を分岐しない（2026-07-16
    Codex 4巡目レビュー指摘Major対応: 当初`if proc.poll() is not None: return`
    という早期returnがあり、「直接の子はちょうど終了したが、同じプロセス
    グループに属する孫プロセス（バックグラウンド起動された子の子）はまだ生きて
    いる」という競合状態でグループkillそのものをスキップしてしまっていた）。

    `os.killpg(proc.pid, ...)`と、pidを直接プロセスグループIDとして使う
    （`os.getpgid(proc.pid)`で照会しない・2026-07-16 Codex 5巡目レビュー指摘
    Major対応: `start_new_session=True`によりPGID==起動直後のproc.pidという
    不変条件が最初から成立しているため照会は不要。`os.getpgid()`は「生存中の
    PIDからそのPGIDを引く」API であり、直接の子が既に回収済み(reap済み)だと
    ESRCHになり、pid自体は不変のPGID番号として引き続き有効なのにkillpgへ
    辿り着けず孫プロセスを取り逃がす経路があった）。
    """
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass  # 直接の子も含め既に全滅済み等の稀な競合。fail-open
    if proc.poll() is None:
        try:
            proc.wait(timeout=_KILL_WAIT_SECONDS)
        except subprocess.TimeoutExpired:
            pass


# ラッパー起動直後（Popen生成〜シグナルハンドラ登録の間）にSIGTERM/SIGHUP/SIGINT
# を受けると、ハンドラ未登録のため既定動作（即終了）でラッパーだけが死に、
# 既に起動済みの子プロセスグループが残留する競合がある（2026-07-16 Codex 4巡目
# レビュー指摘Major対応）。この一瞬をpthread_sigmask()で塞ぐ対象シグナル。
_BLOCKED_DURING_SETUP = (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)


def _make_child_sigmask_restorer(old_mask):
    """Popen(preexec_fn=...)用のクロージャを返す。fork直後・exec直前に
    **子プロセス側**で呼ばれ、シグナルマスクを`old_mask`（run_step()呼び出し
    元がもともと持っていたマスク＝一時ブロック前の状態）へ戻す。

    親側でrun_step()開始時に一時ブロックしたSIGTERM/SIGHUP/SIGINTのマスクは、
    POSIXの仕様上fork()でそのまま子へ継承され、exec()でも解除されない
    （execはシグナル『ハンドラ』を既定値へ戻すだけでシグナル『マスク』は
    引き継がれる）。放置すると、起動した子プロセス（check-drift.sh等の検出
    スクリプトやその孫プロセス）がこれらのシグナルを受け取れなくなってしまう
    （2026-07-16 Codex 4巡目レビュー後の自己点検で発見・修正: run_step()の
    テストで「子プロセス自身がSIGTERMで自殺する」ケースが子に効かなくなる
    副作用として顕在化した）。

    空集合(set())へ戻すのではなく`old_mask`（呼び出し元が元々ブロックして
    いたかもしれないシグナル集合）へ戻す（2026-07-16 Codex 5巡目レビュー指摘
    Minor対応: run_step()をライブラリとして他プロセスから呼び出す将来の利用
    シーンで、呼び出し元が意図的にブロックしていた別のシグナルまで子側で
    勝手に解除してしまわないようにする）。

    preexec_fnはasync-signal-safeな処理のみ許される制約があり、かつ
    「マルチスレッドの親プロセスではexec前にデッドロックしうる」とPythonの
    ドキュメントが警告している。本CLI（maintenance_run_step.py）は単一
    スレッドで実行する前提であり、その前提下でのみ安全である（2026-07-16
    Codex 5巡目レビュー指摘Minor対応: 「安全である」との言い切りが強すぎた
    ため、単一スレッド前提であることを明記する）。run_step()をマルチスレッド
    環境からライブラリ呼び出しする用途は想定していない。
    """
    def _restore():
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
    return _restore


def run_step(cmd, timeout, cwd=None, env=None):
    """cmdを新しいプロセスグループで起動しtimeout秒待つ。標準入出力は継承する。

    戻り値: (returncode, timed_out)
      timed_out=False: returncodeは子プロセスの終了コード（_normalize_returncode
        適用済み）。
      timed_out=True: returncodeは常にTIMEOUT_EXIT_CODE(124)。

    ラッパー自身がSIGTERM/SIGHUPを受けた場合・KeyboardInterrupt（SIGINT）を
    受けた場合も、抜ける前に必ず子プロセスグループをkillする（2026-07-16
    Codexレビュー指摘Major対応）。シグナルによる終了はbashの慣習で
    `128+シグナル番号`をそのままsys.exit()するため、ここではraise/exitせず
    呼び出し元(main)へ例外を伝播させるか、シグナルハンドラ内で直接終了する。

    子プロセス起動からシグナルマスク解除までの間はSIGTERM/SIGHUP/SIGINTを
    ブロックする（pthread_sigmask）。この間に届いたシグナルはOSに保留され、
    マスク解除時に配送される＝取りこぼしなく必ずハンドラ（またはSIGINTの
    既定のKeyboardInterrupt化）を経由させる。

    マスク解除（`pthread_sigmask(SIG_SETMASK, old_mask)`）そのものの実行中に
    保留中のSIGINTが配送されKeyboardInterruptが送出される可能性があるため、
    Popen生成からproc.wait()完了までの**全体**を単一のtry/except
    KeyboardInterruptで囲む（2026-07-16 Codex 5巡目レビュー指摘Major対応:
    当初はマスク解除をtry/finallyの外に置いており、解除処理そのものの最中に
    発生したKeyboardInterruptを取りこぼし、子プロセスグループが残留しうる
    構造になっていた）。
    """
    old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, _BLOCKED_DURING_SETUP)
    proc = None
    prev_handlers = {}
    try:
        # preexec_fnで子プロセス側のシグナルマスクを元へ戻す（親の一時ブロックが
        # そのまま子へ漏れ伝播しないように＝_make_child_sigmask_restorer参照）。
        proc = subprocess.Popen(cmd, cwd=cwd, env=env, start_new_session=True,
                                 preexec_fn=_make_child_sigmask_restorer(old_mask))

        def _on_forwarded_signal(signum, _frame):
            _kill_process_group(proc)
            # デフォルトハンドラに戻してから自分自身へ同じシグナルを再送する
            # （bashの慣習どおり終了コードが128+シグナル番号になるようにする。
            # sys.exit()だとSystemExitが伝播するだけでOS的な「シグナル終了」には
            # ならないため、実際にシグナルで死ぬ）。
            signal.signal(signum, signal.SIG_DFL)
            os.kill(os.getpid(), signum)

        prev_handlers = {sig: signal.signal(sig, _on_forwarded_signal) for sig in _FORWARDED_SIGNALS}
        # ハンドラ登録（SIGTERM/SIGHUP）完了後にブロック解除する。SIGINTは
        # ハンドラを差し替えない（Python既定のKeyboardInterrupt化のままでよい）。
        # この行自体の実行中にSIGINTが配送されても、この行は外側の
        # try/except KeyboardInterruptの内側にあるため取りこぼさない。
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)

        try:
            proc.wait(timeout=timeout)
            return _normalize_returncode(proc.returncode), False
        except subprocess.TimeoutExpired:
            _kill_process_group(proc)
            return TIMEOUT_EXIT_CODE, True
    except KeyboardInterrupt:
        if proc is not None:
            _kill_process_group(proc)
        raise
    finally:
        for sig, handler in prev_handlers.items():
            signal.signal(sig, handler)
        # マスク解除の呼び出し自体は成功パスの中盤で既に行っているが、Popen()
        # がOSErrorで失敗した場合等・そこへ到達できなかった経路でもマスクを
        # 必ず元へ戻す（2026-07-16 Codex 5巡目レビュー対応の自己点検で発見:
        # 復元をfinallyの外に置いていたため、Popen失敗時に呼び出し元プロセスの
        # SIGTERM/SIGHUP/SIGINTが永久にブロックされたまま残る欠陥があった）。
        # 同じold_maskで複数回呼んでも副作用は無い（idempotent）。
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)


def _write_status_file(path, status):
    """機械可読な実行結果をJSONで書き出す（tempfile.mkstemp+os.replaceで原子更新。
    2026-07-16 Codexレビュー指摘Major対応の一部＝子プロセスの終了コードと
    124/127/2が衝突し得る問題を、呼び出し側が明示的に選択できる独立チャネルで
    回避できるようにする）。書込に失敗してもラッパー本体の終了コードは
    そのまま返す（status-fileはあくまで補助情報でありfail-open）。
    予測可能な固定tmp名（`.name.tmp-PID`）ではなくtempfile.mkstempで一時ファイル
    自体を作らせる（2026-07-16 Codex 4巡目レビュー指摘・同一status-fileパスへの
    並行呼び出しやシンボリックリンク攻撃への耐性をわずかに高める）。
    """
    p = pathlib.Path(path)
    fd = None
    tmp_path = None
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp_name = tempfile.mkstemp(prefix=f".{p.name}.tmp-", dir=str(p.parent))
        tmp_path = pathlib.Path(tmp_name)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            fd = None  # fdopen後はfのclose()がfdの面倒も見るため二重closeを避ける
            f.write(json.dumps(status, ensure_ascii=False, indent=2, sort_keys=True))
        os.replace(str(tmp_path), str(p))
        tmp_path = None
    except OSError as e:
        print(f"警告: --status-fileへの書込に失敗しました({path}): {e}", file=sys.stderr)
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
        if tmp_path is not None:
            try:
                tmp_path.unlink()
            except OSError:
                pass


def _invalidate_status_file(path):
    """--status-fileで指定されたパスに前回実行分の残骸が残っている場合、実行
    開始時点で削除しておく（2026-07-16 Codex 4巡目レビュー指摘Major対応:
    今回の実行が最終書込まで到達できずに異常終了した場合、削除しておかないと
    呼び出し側が古い(前回実行の)status-fileを「今回の結果」として誤読しうる。
    削除に失敗しても以降の処理は続行する＝fail-open。呼び出し側の契約は
    「rc取得後、status-fileが存在せず/壊れていれば『ラッパーが最後まで到達
    できなかった』とみなす」こと（本体の設計判断であり、失敗を握り潰さない）。
    """
    try:
        pathlib.Path(path).unlink(missing_ok=True)
    except OSError:
        pass


def main(argv=None):
    argv = sys.argv[1:] if argv is None else list(argv)

    if "--" not in argv:
        print("使い方: maintenance_run_step.py --timeout SECONDS [--status-file PATH] -- CMD [ARGS...]",
              file=sys.stderr)
        return USAGE_ERROR_EXIT_CODE
    sep = argv.index("--")
    own_args, cmd = argv[:sep], argv[sep + 1:]

    ap = argparse.ArgumentParser(
        description="タイムアウト付き・プロセスグループ単位で子プロセスを実行する"
                     "（maintenance.sh Phase1の各検出ステップ起動用）。")
    ap.add_argument("--timeout", type=float, required=True, help="タイムアウト秒数（正の有限数）")
    ap.add_argument("--cwd", default=None, help="子プロセスの作業ディレクトリ（省略時は継承）")
    ap.add_argument("--status-file", default=None,
                     help="機械可読な実行結果(JSON)の出力先（省略可・子プロセスの終了コードと"
                          "終了コード自体が衝突し得る場合の独立した判定手段）")
    args = ap.parse_args(own_args)

    if args.status_file:
        # 今回の実行が最終書込まで到達できない場合に備え、まず前回分の残骸を
        # 消しておく（2026-07-16 Codex 4巡目レビュー指摘Major対応）。
        _invalidate_status_file(args.status_file)

    def _finish(rc, *, timed_out=False, spawn_error=False, usage_error=False):
        if args.status_file:
            _write_status_file(args.status_file, {
                "returncode": rc,
                "timed_out": timed_out,
                "spawn_error": spawn_error,
                "usage_error": usage_error,
                "ok": (rc == 0 and not timed_out and not spawn_error and not usage_error),
            })
        return rc

    if not cmd:
        print("使い方: '--'の後に実行するコマンドを指定してください", file=sys.stderr)
        return _finish(USAGE_ERROR_EXIT_CODE, usage_error=True)
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        # isfinite()でNaN・+inf・-infをまとめて拒否する（2026-07-16 Codexレビュー
        # 指摘Minor対応: 当初はNaNのみ弾いておりtimeout=infが素通りしていた
        # ＝設定ミスでPhase1が無期限停止しうる欠陥だった）。
        print(f"エラー: --timeoutは正の有限数である必要があります({args.timeout!r})", file=sys.stderr)
        return _finish(USAGE_ERROR_EXIT_CODE, usage_error=True)

    try:
        rc, timed_out = run_step(cmd, args.timeout, cwd=args.cwd)
    except OSError as e:
        # 実行ファイルが見つからない・実行権限が無い・cwdが不正等、子プロセスを
        # そもそも起動できなかった場合（2026-07-16 Codexレビュー指摘Minor対応:
        # 当初はFileNotFoundErrorのみ捕捉しておりPermissionError等が未処理
        # だった）。
        print(f"エラー: コマンドを起動できません: {' '.join(cmd)} ({e})", file=sys.stderr)
        return _finish(SPAWN_ERROR_EXIT_CODE, spawn_error=True)

    if timed_out:
        print(f"maintenance_run_step: タイムアウト({args.timeout}秒)によりプロセスグループを"
              f"強制終了しました: {' '.join(cmd)}", file=sys.stderr)
    return _finish(rc, timed_out=timed_out)


if __name__ == "__main__":
    sys.exit(main())
