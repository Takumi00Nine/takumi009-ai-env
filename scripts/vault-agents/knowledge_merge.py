#!/usr/bin/env python3
"""外部脳 Knowledge 自律整理・柱②の「マージ実行」機械化CLI（設計書§1・§2.3・§2.4）。

週次LaunchAgent（knowledge_merge_candidates.py・別ワーカー担当）が検出した
候補（`~/.claude/logs/knowledge-merge-candidates/state.json`）を、リーダーが
手順書（Preferences/knowledge-merge-procedure.md）に従って対話的に処理する際に
使うサブコマンド型CLI。**Vaultへの実際の書込判断・統合ノート本文の執筆はリーダー
（Claude）が行う**。本CLIは「機械的に必ず同じ手順を踏む」部分（証拠採取・構造
チェック・回帰ベンチ・git操作・ALERT生成）を担当し、判断の余地を持たない
（fail-closed＝迷ったら書込まない）。

サブコマンド（設計書§1表・§2.3手順3-13・§2.4）:
  preflight        未解決ALERTラッチの二重チェック＋候補パスの独立検証
                    （state.jsonを信用せず毎回パスを実ファイルで再検証・
                    専用ロック取得後にTOCTOU再確認）
  worktree-setup    `~/.claude/tmp/vault-merge-worktrees/<candidate_id>/` にworktree作成
  draft             統合ノート新規作成＋原ノート2件の非破壊スタブ化＋Vault全体の
                    流入wikilink張替（worktreeへ適用・この段階では一切commitしない）
  evidence          未コミット差分から証拠パックJSON（rubric明記）を生成
  gate              FR12a構造チェック＋ベンチTSV旧→新パスremap採点＋recall回帰ベンチ
  skip              候補を「マージ不適」としてstate.jsonへ直接status=skippedを記録
                    （FR9bが定義する候補状態語彙pending/merged/skipped/blocked/retry
                    のうち、従来skippedを設定するコードパスが本CLIに存在せず、
                    マージ不適と判断した候補が永久にpendingへ留まり続けていた間隙を
                    埋める・2026-07-14追加）。Vault本体・git履歴には一切書込まない
                    （理由はcmd_skipのdocstring参照）
  unskip            skippedを手動再評価のためpendingへ戻す（本人裁定・2026-07-14
                    追加。「skip判断を誤った/状況が変わった」場合の唯一の復帰経路。
                    ガード・監査記録の詳細はcmd_unskipのdocstring参照。副作用として
                    次回週次検出が同じ候補ペアをpendingとして再提示しうる＝意図どおり）
  commit            Codex verdict＋gate結果が全PASSの場合のみworktreeへ1コミット→
                    mainへ`git merge --ff-only`→成功時は保持中の同一ロックのまま
                    reconcile本体を自動実行（state.jsonがstaleなまま次セッションへ
                    渡る事故の再発防止・2026-07-12追加）。reconcileのみ失敗しても
                    commit自体の成功は取り消さない（手動`reconcile`実行を促す警告のみ）。
                    実行前にstate.jsonの候補statusを読み、既にmerged/skipped
                    （終端状態）ならFAILし再commitさせない（2026-07-14追加）。
                    Codexのverdictを取得できない場合（不通・認証切れ・MCP未起動・
                    timeout・利用上限）はFR11aに従いfail-closed＝当該候補のみを
                    codex_unavailable ALERT生成→即reconcileでblocked化する
                    （他候補は妨げない。詳細はcmd_commitの当該except節参照）
  reconcile         git log の candidate_id trailer を正としてstate.jsonを再構成
                    （commit成功時は自動実行されるため、通常は手動実行不要。
                    自動実行が失敗した場合の手動リカバリ用に残す）。ALERTが
                    resolvedになった候補はblocked/retryからpendingへ復帰させる
                    （2026-07-14追加・詳細は_reconcile_lockedのコメント参照）
  alert             ALERTレポート（`~/.claude/logs/vault-merge-alerts/`）の生成
  revert            コミット後に発覚した欠陥の救済revert（週次自動フロー対象外・
                    起動はリーダーの人間判断のみ。設計書§2.4）

各候補の作業ディレクトリは `<candidate_id>` ごとに隔離される（1候補=1worktree）。
worktree内には `.vault-merge-meta.json`（非追跡・git addしない）を置き、
worktree-setup/draft/evidence/gate/commit の各段階がそこへ進行状況を書き足す
形でパイプラインを繋ぐ（引数の受け渡し漏れ・後段での再入力ミスを防ぐため）。

state.json（候補検出側=knowledge_merge_candidates.pyが書く）は、**読込**は
preflight/commit/reconcile/skip/unskipの5つが行うが、**書込**（save_state_atomic
の呼出し）はreconcile（本体=_reconcile_locked、commit成功時・commit失敗時の
FR11a codex_unavailable ALERT生成直後にも自動で呼ばれる）・skip・unskipの3つ
でのみ行う（Codexレビュー指摘・Minor・2026-07-14: 読込主体の一覧に書込主体を
混在させた表現になっており、preflightがあたかも書込むかのように読める不正確な
記述だった。preflightは常に**読込専用**＝候補パスの独立検証結果を返すのみで
save_state_atomic()を一切呼ばない）。preflightはstate.jsonの内容を**信用せず**、
記載された2パスを毎回実ファイルシステムに対して独立検証する（設計書§2.3手順3）。
preflight/commitはさらに、既にmerged/skipped（終端状態）の候補への再処理を
拒否するため候補statusを読む（2026-07-14追加・TERMINAL_STATUSES参照）。
commit/revertはstate.jsonへ直接書込まない（git log trailerをsource of truthに
reconcileで再構成する運用のため、書込主体を一本化し競合を避ける。commitが
行うのは終端状態チェックのための**読込**と、FR11a該当時の_reconcile_locked
呼び出しのみ）。skip/unskipのみ例外的にstate.jsonへ直接書込む（Vault本体の
内容変更を伴わずgit trailerを作れないため。詳細はcmd_skip/cmd_unskipの
docstring参照）。

未解決ALERTのTOCTOU再確認（設計上の一般方針・外部脳総点検5巡目Codexレビュー
指摘対応・2026-07-14）: check_alert_latch()はロック取得直後に一度呼ぶだけでは
不十分で、そこから実際の書込（git commit/state.json保存）までの間に他プロセスが
新規ALERTを書込む窓が残る。write_alert()自体はvault-merge.lockを取得せず書く
設計（lock_conflict種別は「ロック取得に失敗した」事実を書くものであり、ロック
必須化すると自己矛盾で書けなくなる＝write_alert()のdocstring参照）ため、
「ALERT書込側の全ロック化」では解決できない。本ファイルは一貫して「判定側の
再検証を書込に可能な限り近づける」方針を取る（cmd_revertの`_check_clean`/
`_resolve_revert_target`の二重確認、cmd_commitの書込直前latch再確認、cmd_skip/
cmd_unskipのALERT走査が状態保存の直前に位置する構成、いずれも同型）。この方針
でも、判定〜実際のgit/state書込の間に残るごく短い窓（数回のsubprocess呼出し
分）は理論上ゼロにできない**既知の残余**として受容する（本ツールの脅威モデル＝
完全ローカル・単一操作者・悪意ある同時実行プロセスを想定しないに対しては実用上
十分な軽減と判断）。
"""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time
import unicodedata

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import merge_quality_gate as mqg  # noqa: E402
import vault_inventory as vi  # noqa: E402

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
DEFAULT_VAULT = pathlib.Path.home() / "Data" / "obsidian"
DEFAULT_STATE_FILE = pathlib.Path.home() / ".claude" / "logs" / "knowledge-merge-candidates" / "state.json"
DEFAULT_ALERTS_DIR = pathlib.Path.home() / ".claude" / "logs" / "vault-merge-alerts"
DEFAULT_WORKTREES_DIR = pathlib.Path.home() / ".claude" / "tmp" / "vault-merge-worktrees"
DEFAULT_LOCK_FILE = pathlib.Path.home() / ".claude" / "tmp" / "vault-merge.lock"
DEFAULT_RECALL_BENCH = REPO_ROOT / "scripts" / "vault-agents" / "recall_bench.py"
DEFAULT_HOOK = REPO_ROOT / "claude" / "hooks" / "vault-recall.sh"

# Codexレビュー用rubric（設計書§2.3手順7・付録A FR10a③・FR12a(3)）。5項目＋1項目の
# 個別PASS/FAILが構造化必須（1項目でも欠落/FAILならreject）。バージョンはcommit
# trailerとverdict双方に記録し、rubricを改定した際に過去コミットとの対応が
# 追えるようにする。
RUBRIC_VERSION = "1"
RUBRIC_ITEMS = {
    "contradiction": "両ノートの主張間に矛盾が無いか（FR10a③-1）",
    "negation_diff": "肯定/否定表現の食い違いが無いか（FR10a③-2）",
    "date_diff": "日付情報の食い違いが無いか（FR10a③-3）",
    "proper_noun_diff": "固有名詞の食い違いが無いか（FR10a③-4）",
    "code_block_diff": "コードブロック内容の食い違いが無いか（FR10a③-5）",
    "claim_preservation": "統合ノートが両ノートの全主張を包含し意味を保持しているか"
                           "（数値改変・意味反転が無いか・FR12a(3)）",
}
REQUIRED_VERDICT_KEYS = ("candidate_id", "content_fingerprint", "verdict", "reason_code", "rubric_version",
                          "model", "rubric")

CANDIDATE_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,80}$")  # 80: detect側の "cand-"+sha256全64桁(=69字) を許容（2026-07-12 結合バグ修正）
# ALERT種別（設計書§2.3手順3の「ロック不在確認/基準HEAD再設定確認/worktree clean確認」の
# 3種＋gate側のベンチTSV改ざん検知1種＋FR11a「Codex不通」1種）。lock_conflict/
# head_moved/worktree_dirty/bench_tsv_tamperedの4種はalert_machine_resolved()の
# 分岐と1:1対応し、check_alert_latch()の全マージ停止ラッチに参加する（設計書
# FR12b「resolved確認までの全マージ停止ラッチ」）。codex_unavailableのみ例外＝
# FR11a「他候補は妨げない」という要件がFR12bの「全マージ停止」と正面から矛盾する
# ため、check_alert_latch()側で明示的にラッチ対象から除外する（=候補単位の情報
# としてのみstate.jsonのstatus="blocked"に反映され、alert_machine_resolved()は
# 呼ばれない。詳細はcheck_alert_latch()の当該分岐のコメント参照・2026-07-14追加）。
ALERT_TYPES = ("lock_conflict", "head_moved", "worktree_dirty", "bench_tsv_tampered", "codex_unavailable")


# ============================================================
# 排他ロック（flockベース。update_embedding_index.pyと同じ考え方＝OSがプロセス
# 生死にロック生死を直接紐付けるためstale判定という概念が不要になる。柱ごとに
# 独立実装のため軽微な重複はあるが、他ワーカー担当ファイルへの依存を避けるため
# あえてimportせず本ファイル内に閉じる）
# ============================================================

def acquire_lock(lock_path):
    lock_path = pathlib.Path(lock_path)
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o644)
    except OSError:
        return None
    f = os.fdopen(fd, "r+")
    try:
        fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        f.close()
        return None
    return f


def release_lock(held):
    if not held:
        return
    try:
        fcntl.flock(held.fileno(), fcntl.LOCK_UN)
    except OSError:
        pass
    try:
        held.close()
    except OSError:
        pass


def acquire_lock_with_retry(lock_path, attempts=3, backoff_s=2.0):
    """commit/revertの「一時的ロック競合=retry」（設計書§2.3手順10）に対応する
    有界retry。flockはプロセスクラッシュ時もOSが自動解放するため、待てば必ず
    解ける前提で良い（stale判定は不要）。"""
    held = None
    for attempt in range(max(1, attempts)):
        held = acquire_lock(lock_path)
        if held:
            return held
        if attempt < attempts - 1:
            time.sleep(backoff_s * (attempt + 1))
    return held


def git_status_porcelain_dir(path):
    proc = subprocess.run(["git", "-C", str(path), "status", "--porcelain"],
                           capture_output=True, text=True, timeout=15)
    return proc.returncode, (proc.stdout + proc.stderr)


# ============================================================
# candidate_id / パス独立検証（TOCTOU対策・state.jsonを信用しない）
# ============================================================

def sanitize_candidate_id(cid):
    if not cid or not isinstance(cid, str) or not CANDIDATE_ID_RE.match(cid):
        raise ValueError(f"不正なcandidate_id形式です（英数字/_/- のみ・1〜80文字）: {cid!r}")
    return cid


def verify_knowledge_note_path(vault_root, relpath, must_exist=True):
    """Knowledge/直下の通常ファイル(.md)であることを実ファイルシステムに対して
    独立検証する（state.jsonの記載を信用しない・`..`/絶対パス/symlink脱出を拒否）。
    OKなら解決済みPathを返す。ダメならValueErrorを送出する。
    """
    if not relpath or not isinstance(relpath, str):
        raise ValueError(f"パスが指定されていません: {relpath!r}")
    if relpath.startswith("/") or relpath.startswith("~") or ":" in relpath:
        raise ValueError(f"絶対パス/ドライブ表記は許可されません: {relpath!r}")
    parts = pathlib.PurePosixPath(relpath).parts
    if not parts or ".." in parts or "." in parts:
        raise ValueError(f"パストラバーサルの疑いがあるパスです: {relpath!r}")
    if len(parts) != 2 or parts[0] != "Knowledge":
        raise ValueError(f"Knowledge/直下のノートのみ許可されます: {relpath!r}")
    if not relpath.endswith(".md"):
        raise ValueError(f"Markdownノート以外は許可されません: {relpath!r}")

    vault_root = pathlib.Path(vault_root)
    vault_resolved = vault_root.resolve()
    candidate = vault_root / relpath
    if candidate.is_symlink():
        raise ValueError(f"symlinkは許可されません: {relpath!r}")
    try:
        resolved = candidate.resolve(strict=False)
    except OSError as e:
        raise ValueError(f"パスを解決できません: {relpath!r}（{e}）")
    try:
        resolved.relative_to(vault_resolved)
    except ValueError:
        raise ValueError(f"Vault外を指しています（symlink経由の脱出の疑い）: {relpath!r}")
    if must_exist and not resolved.is_file():
        raise ValueError(f"ファイルが存在しません: {relpath!r}")
    if not must_exist and resolved.exists():
        raise ValueError(f"既に存在するパスです（新規ノートのパスを指定してください）: {relpath!r}")
    return resolved


def assert_safe_to_write(root, path):
    """検証(verify_knowledge_note_path)からファイル実書込みまでの間にsymlinkへ
    差し替えられていないかを、書込直前にもう一度確認する（Codexレビュー指摘・
    Major・2巡目再指摘: 最終要素のsymlink有無だけでなく、親ディレクトリの
    差し替えによる実体パスのroot外脱出も再検証する）。leafのis_symlink()に加え、
    resolve()した実体パスがroot配下にあるかを書込直前に再確認する。

    完全な排除（TOCTOU窓のゼロ化）には各path構成要素をopenat(O_NOFOLLOW)で
    辿るFDベースの実装が必要だが、本ツールの脅威モデル（完全ローカル・単一
    操作者・悪意ある同時実行プロセスを想定しない）に対しては、書込直前の
    再チェックで実用上十分な軽減とする（未実装のFDベース対策は残存リスクとして
    最終報告でリーダーへ申告する）。
    """
    path = pathlib.Path(path)
    if path.is_symlink():
        raise ValueError(f"書込直前にsymlinkへの差し替えを検出しました: {path}")
    root_resolved = pathlib.Path(root).resolve()
    try:
        resolved = path.resolve(strict=False)
        resolved.relative_to(root_resolved)
    except (OSError, ValueError):
        raise ValueError(f"書込直前にroot外への脱出を検出しました（親ディレクトリのsymlink差し替えの疑い）: {path}")


# ============================================================
# state.json（読込はpreflight/commit/reconcile/skip/unskip・書込はreconcile/skip/
# unskipのみ。書込はatomic replace）
# ============================================================

# knowledge_merge_candidates.STATE_SCHEMA_VERSIONと必ず同じ値を保つ定数（本ファイル
# 冒頭のacquire_lock()と同じ理由＝他ワーカー担当ファイルへの依存を避けるため
# importせず値を複製している。値を変更する際は両ファイルを同時に見直すこと）。
STATE_SCHEMA_VERSION = 1

# knowledge_merge_candidates.TERMINAL_STATUSESと同じ値を保つ定数（同上の理由で
# 複製）。preflight/commitが終端状態（既にmerged/skippedが確定した候補）への
# 再処理を拒否する際に使う（2026-07-14追加・外部脳総点検で判明: 従来preflight/
# commitのどちらも候補のstatusを一切照合しておらず、既にmerged/skippedになった
# candidate_idへ--candidate-idを明示指定すればpreflight/worktree-setup/draft/
# gate/commitの一連が何の拒否もなく再度走ってしまい、二重マージや無意味な
# revert対象増殖を招きうる間隙があった）。
# 「終端」とは「本CLIの通常経路（preflight/worktree-setup/.../commit）からは
# 抜け出せない」という意味であり、絶対に不変という意味ではない。skippedのみ、
# 人間判断による明示的なunskipコマンド（cmd_unskip・本人裁定2026-07-14追加）で
# pendingへ手動で戻せる（mergedにはこれに相当する経路は無い＝取消すにはrevertで
# 「revertした事実を追加記録する」のみで、merged自体は消えない）。
TERMINAL_STATUSES = ("merged", "skipped")

# FR9bが定義する候補状態語彙の全体（pending/merged/skipped/blocked/retryの5つ）。
# cmd_commitが既存レコードのstatusを検証する際、未知の値（想定外の破損・改ざん・
# 手動編集ミスの兆候）をfail-closedで拒否するために使う（Codexレビュー指摘・
# Major対応・2026-07-14追加。cmd_skipは元々未知status値を拒否していたが
# （cmd_skipのdocstring参照）、cmd_commitのTERMINAL_STATUSESチェックは既知の
# 終端状態のみを弾き、未知の値はチェックをすり抜けてcommitへ進んでしまって
# いた）。candidate_id自体がstate.jsonに未登録（commit_cand is None）の場合は
# この定数では検証しない（statusという概念自体が無いため）が、既定では別途
# fail-closedで拒否する（cmd_commit内の`args.allow_unregistered_candidate`
# チェック参照。state.json消失/state-file誤指定と、preflightの--note-a/
# --note-bによる意図的な「stateに未登録の候補を手動で試す」運用を区別できない
# ため、後者は`--allow-unregistered-candidate`の明示指定でのみ許可する＝
# リーダー判断・2026-07-14追加。Codexレビュー指摘・Major対応）。
KNOWN_CANDIDATE_STATUSES = ("pending", "merged", "skipped", "blocked", "retry")


def load_state(state_file):
    state_file = pathlib.Path(state_file)
    if not state_file.exists():
        return {"schema_version": STATE_SCHEMA_VERSION, "candidates": {}}
    try:
        data = json.loads(state_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        raise ValueError(f"state.jsonの読込/解析に失敗しました（{state_file}）: {e}")
    if not isinstance(data, dict) or not isinstance(data.get("candidates"), dict):
        raise ValueError(f"state.jsonの形式が想定外です（'candidates'オブジェクトが必要）: {state_file}")
    # schema_versionの検証をknowledge_merge_candidates.load_state()と対称にする
    # （外部脳総点検で判明した非対称・2026-07-14修正: 従来この関数はschema_version
    # 自体を一切検証せず、無い/不一致でも素通りしていた。knowledge_merge_candidates.py
    # は同じstate.jsonに対し「必須＋一致検証」というfail-closed方式を取っており、
    # 同一ファイルを共有する2スクリプト間で検証強度が非対称だと、一方が緩い
    # チェックで書込んだ内容を他方がfail-closedで拒否する/しないが噛み合わない
    # 事故につながる。fail-closed側＝candidates.py方式に統一する）。
    if "schema_version" not in data:
        raise ValueError(f"state.jsonに'schema_version'がありません（破損/改ざんの可能性）: {state_file}")
    if data["schema_version"] != STATE_SCHEMA_VERSION:
        raise ValueError(
            f"state.jsonのschema_versionが不一致です（{data['schema_version']!r} != {STATE_SCHEMA_VERSION}）: {state_file}")
    return data


def save_state_atomic(state_file, data):
    state_file = pathlib.Path(state_file)
    state_file.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=str(state_file.parent), prefix=".state-", suffix=".json.tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2, sort_keys=True)
            f.write("\n")
        os.replace(tmp_path, state_file)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


# ============================================================
# worktreeメタ情報（`.vault-merge-meta.json`・git addしない＝非追跡のまま各段階が
# 進行状況を書き足す。worktree-setup/draft/evidence/gate/commit を跨ぐ受け渡し）
# ============================================================

META_FILENAME = ".vault-merge-meta.json"


def meta_path(worktree):
    return pathlib.Path(worktree) / META_FILENAME


def read_meta(worktree):
    p = meta_path(worktree)
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def write_meta(worktree, meta):
    meta_path(worktree).write_text(
        json.dumps(meta, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def evidence_file_path(worktrees_dir, cid):
    return pathlib.Path(worktrees_dir) / f"{cid}.evidence.json"


def verdict_file_path(worktrees_dir, cid):
    return pathlib.Path(worktrees_dir) / f"{cid}.verdict.json"


def gate_file_path(worktrees_dir, cid):
    return pathlib.Path(worktrees_dir) / f"{cid}.gate.json"


# ============================================================
# git ヘルパ
# ============================================================

def run_git(args, cwd, check=True, timeout=60):
    proc = subprocess.run(["git", "-C", str(cwd)] + list(args), capture_output=True, text=True, timeout=timeout)
    if check and proc.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} 失敗（cwd={cwd}）: {proc.stderr.strip()}")
    return proc


def git_head(cwd):
    return run_git(["rev-parse", "HEAD"], cwd).stdout.strip()


def git_show(cwd, ref, relpath):
    """`git show <ref>:<relpath>` の内容を返す。無ければNone（削除/未追跡等）。"""
    proc = run_git(["show", f"{ref}:{relpath}"], cwd, check=False)
    if proc.returncode != 0:
        return None
    return proc.stdout


def collect_stems(worktree, exclude=frozenset()):
    stems = {}
    for p in pathlib.Path(worktree).rglob("*.md"):
        if ".git" in p.parts:
            continue
        rel = p.relative_to(worktree).as_posix()
        if rel in exclude:
            continue
        stems.setdefault(p.stem, []).append(rel)
    return stems


# ============================================================
# ALERTレポート（`~/.claude/logs/vault-merge-alerts/`・frontmatter:
# candidate_id/alert_type/command/processed/resolved/attempt_count/next_retry/
# base_head。processed(認知)とresolved(解消)を分離＝FR12b）
# ============================================================

_ALERT_FM_KEYS = ("candidate_id", "alert_type", "command", "processed", "resolved",
                   "attempt_count", "next_retry", "base_head", "bench_repo", "bench_relpath", "target_path")


def alert_file_path(alerts_dir, candidate_id, alert_type, today):
    return pathlib.Path(alerts_dir) / f"{today.isoformat()}-{candidate_id}-{alert_type}.md"


def parse_alert(path):
    text = pathlib.Path(path).read_text(encoding="utf-8")
    fm, body = vi.parse_frontmatter(text)
    return fm, body, text


def render_alert(fm, body):
    lines = ["---"]
    for k in _ALERT_FM_KEYS:
        v = fm.get(k)
        if v not in (None, ""):
            lines.append(f"{k}: {v}")
    lines.append("---")
    lines.append("")
    lines.append(body.strip())
    lines.append("")
    return "\n".join(lines)


def write_alert(alerts_dir, candidate_id, alert_type, command, message, base_head=None,
                 bench_repo=None, bench_relpath=None, target_path=None, today=None):
    """ALERTレポートを生成/更新する。同日・同candidate・同typeの既存ファイルが
    あればattempt_countをインクリメントしresolvedをクリアする（再発扱い・
    FR12b「resolved確認までの全マージ停止ラッチ」の再発火に対応）。
    next_retryは attempt_count 日後（最大7日）の単純バックオフ（決定的・要承認の
    運用パラメータでは無いため固定値。実運用で不足すれば設定値化を検討）。

    本関数は意図的にvault-merge.lockを取得しない（設計上の制約・モジュール
    docstringの「未解決ALERTのTOCTOU再確認」節参照）: lock_conflict種別のALERT
    はまさに「ロック取得に失敗した」事実を書くためのものであり、write_alert()
    自体がロック必須だと、ロックが取れない状況でこそ書きたいALERTが書けない
    という自己矛盾に陥る。この結果、他の書込コマンド（commit/skip/unskip等）が
    ロックを保持している最中でも、別プロセスが（gate等から）ALERTを書込む余地は
    構造的に残る。各コマンド側はこれを「判定側の再検証を書込に可能な限り近づける」
    ことで軽減する（cmd_commitの書込直前latch再確認等）。
    """
    if alert_type not in ALERT_TYPES:
        raise ValueError(f"未知のalert_typeです: {alert_type!r}")
    today = today or datetime.date.today()
    alerts_dir = pathlib.Path(alerts_dir)
    alerts_dir.mkdir(parents=True, exist_ok=True)
    path = alert_file_path(alerts_dir, candidate_id, alert_type, today)
    attempt_count = 1
    if path.exists():
        fm, _, _ = parse_alert(path)
        try:
            attempt_count = int(fm.get("attempt_count", 0)) + 1
        except (TypeError, ValueError):
            attempt_count = 1
    next_retry = (today + datetime.timedelta(days=min(attempt_count, 7))).isoformat()
    fm = {
        "candidate_id": candidate_id,
        "alert_type": alert_type,
        "command": command,
        "attempt_count": attempt_count,
        "next_retry": next_retry,
    }
    if base_head:
        fm["base_head"] = base_head
    if bench_repo:
        fm["bench_repo"] = str(bench_repo)
    if bench_relpath:
        fm["bench_relpath"] = bench_relpath
    if target_path:
        fm["target_path"] = str(target_path)
    body = f"# vault-merge ALERT: {candidate_id} ({alert_type})\n\n{message}\n"
    path.write_text(render_alert(fm, body), encoding="utf-8")
    return path


def alert_machine_resolved(fm, vault_root, lock_path, worktrees_dir, lock_already_held=False):
    """ALERT種別ごとの機械的解消判定（設計書§2.3手順3「ロック不在確認/基準HEAD
    再設定確認/worktree clean確認」）。戻り値: (resolved: bool, reason: str|None)。
    未知のalert_typeはfail-closed（常にFalse）。

    lock_already_held: 呼び出し元（cmd_preflightのTOCTOU再確認）が既にlock_pathの
    flockを保持している場合True。flockは同一プロセス内でも別fdからの再取得は
    ブロックされるため（同一inodeへの多重flockは通常のプロセス内排他とは別物）、
    自分自身が既に保持している状態でacquire_lock()を再試行すると常に失敗し
    「他プロセスが保持中」と誤検出してしまう。既に保持している=他プロセスの
    競合が無いことは自明なため、その場合は再取得を試みず直ちに解消済み扱いにする。
    """
    alert_type = fm.get("alert_type")
    candidate_id = fm.get("candidate_id")

    if alert_type == "lock_conflict":
        if lock_already_held:
            return True, None
        held = acquire_lock(lock_path)
        if held:
            release_lock(held)
            return True, None
        return False, "マージロックがまだ他プロセスに保持されています"

    if alert_type == "head_moved":
        base_head = fm.get("base_head")
        if not base_head:
            return False, "base_headが記録されていません（機械判定不能）"
        wt = pathlib.Path(worktrees_dir) / str(candidate_id)
        meta = read_meta(wt) if wt.exists() else {}
        if not meta.get("base_head"):
            return False, "worktreeが再作成されていません（worktree-setupのやり直しが必要）"
        if meta["base_head"] != base_head:
            # ALERT記録時のbase_headと異なる新しいbase_headでworktreeが再作成されて
            # いれば「基準HEADの再設定」が完了したとみなす。
            return True, None
        return False, "worktreeのbase_headがALERT記録時から更新されていません（worktree-setupのやり直しが必要）"

    if alert_type == "worktree_dirty":
        # target_path（ALERT生成時に記録された実際にdirtyだった場所）を優先する。
        # commit由来（候補のworktree）だけでなくrevert由来（vault本体=vault_root）でも
        # 同じalert_typeを使うため、記録が無い旧形式ALERTのみworktrees_dir/candidate_id
        # へフォールバックする（Codexレビュー起因の修正時に発覚した実装バグ:
        # revertのALERTでも常に候補worktreeを見ており、vault_root側のdirty解消を
        # 正しく検知できていなかった）。
        target = fm.get("target_path")
        target_dir = pathlib.Path(target) if target else (pathlib.Path(worktrees_dir) / str(candidate_id))
        if not target_dir.exists():
            return True, None  # 対象自体が破棄済みなら未追跡変更の懸念も消滅
        rc, out = git_status_porcelain_dir(target_dir)
        if rc != 0:
            return False, f"git statusの確認に失敗しました: {out.strip()}"
        return (not out.strip()), (None if not out.strip() else f"{target_dir} に未追跡/未コミット変更が残っています")

    if alert_type == "bench_tsv_tampered":
        repo = fm.get("bench_repo")
        rel = fm.get("bench_relpath")
        if not repo or not rel:
            return False, "bench_repo/bench_relpathが記録されていません（機械判定不能）"
        try:
            status = mqg.git_status_porcelain(repo, rel)
        except mqg.GateError as e:
            return False, str(e)
        return (not status.strip()), (None if not status.strip() else "ベンチTSVがまだ未コミット状態です")

    return False, f"未知のalert_type（fail-closed）: {alert_type!r}"


def alert_is_resolved(fm, vault_root, lock_path, worktrees_dir, lock_already_held=False):
    """1件のALERTが「厳格に」解消済みかを判定する（resolved欄の日付形式＋
    alert_machine_resolved()のAND。codex_unavailableのみresolved欄の日付形式
    のみで判定＝下記参照）。_reconcile_locked（blocked/retryを「進める」/
    「戻す」の両方向）とcmd_skip・cmd_unskip（いずれも当該候補の未解決ALERTが
    あればFAIL）が共有する単一のsource of truth（Codexレビュー指摘・Major・
    2巡目再指摘対応で_reconcile_locked内のローカル関数として導入し、リーダー
    判断によりcmd_skipからも使うため2026-07-14にモジュールレベルへ引き上げ。
    同日追加のcmd_unskipもcmd_skipと対称のガードとして同じ判定を再利用する）。
    """
    resolved_field = fm.get("resolved")
    resolved_field_ok = bool(resolved_field) and bool(
        re.match(r"^\d{4}-\d{2}-\d{2}$", str(resolved_field)))
    if not resolved_field_ok:
        return False
    if fm.get("alert_type") == "codex_unavailable":
        # codex_unavailableはalert_machine_resolved()に分岐が無い（check_alert_
        # latch()と同じ理由＝候補単位のみ・「機械的な解消判定」という概念自体が
        # 無い＝Codexの到達性を外部から検証する手段が無い）。よってこの種別
        # だけはresolved欄の日付形式のみで判定する（機械判定ANDは要求しない。
        # 無いと「機械判定できないので常に未解決扱い」というalert_machine_
        # resolvedの既定fail-closed分岐に落ち、逆に「常に未解決なのでblocked
        # から一生戻れない」という別の詰みを生む）。実際の再試行可否はcmd_commit
        # が都度verdictを検証して決めるため（TERMINAL_STATUSESのみでblocked
        # 自体はゲートしない設計・cmd_commit参照）、resolved欄の真偽が甘くても
        # 実害はskip可否（Vault非破壊のbookkeeping操作）に留まる。
        return True
    machine_ok, _ = alert_machine_resolved(fm, vault_root, lock_path, worktrees_dir,
                                            lock_already_held=lock_already_held)
    return machine_ok


def check_alert_latch(vault_root, alerts_dir, lock_path, worktrees_dir, lock_already_held=False):
    """未解決ALERTの二重チェック（`resolved:`欄＋機械的解消判定のAND）。1件でも
    未解決ならlatch_active=True（マージ処理全体を停止＝FR10/FR12bのラッチ）。
    lock_already_held: 呼び出し元が既にlock_pathを保持中か（alert_machine_resolved参照）。
    """
    alerts_dir = pathlib.Path(alerts_dir)
    unresolved = []
    if not alerts_dir.is_dir():
        return False, unresolved
    for path in sorted(alerts_dir.glob("*.md")):
        try:
            fm, _, _ = parse_alert(path)
        except OSError as e:
            unresolved.append({"path": str(path), "reasons": [f"読込失敗（fail-closed）: {e}"]})
            continue
        if fm.get("alert_type") == "codex_unavailable":
            # FR11a「他候補は妨げない」＝candidate単位のみを塞ぐALERTであり、
            # FR12bの全マージ停止ラッチには参加させない（ALERT_TYPESの定義部
            # コメント参照）。resolved欄の有無に関わらずここでは常にスキップする
            # （＝latch_active/unresolvedの計算対象外）。個別候補のblocked状態は
            # state.json側（_reconcile_locked）が別途resolved欄のみを見て管理する。
            continue
        resolved_field = fm.get("resolved")
        resolved_field_ok = bool(resolved_field) and bool(re.match(r"^\d{4}-\d{2}-\d{2}$", str(resolved_field)))
        machine_ok, machine_reason = alert_machine_resolved(fm, vault_root, lock_path, worktrees_dir,
                                                              lock_already_held=lock_already_held)
        if resolved_field_ok and machine_ok:
            continue
        reasons = []
        if not resolved_field_ok:
            reasons.append("resolved欄が未記入または形式不正（YYYY-MM-DD）")
        if not machine_ok:
            reasons.append(machine_reason or "機械的解消判定NG")
        unresolved.append({"path": str(path), "candidate_id": fm.get("candidate_id"),
                            "alert_type": fm.get("alert_type"), "reasons": reasons})
    return (len(unresolved) > 0), unresolved


# ============================================================
# frontmatter/本文の機械的マージ（draft用）
# ============================================================

def _fm_date(fm):
    v = fm.get("updated") or fm.get("date")
    if not v or not isinstance(v, str):
        return None
    try:
        return datetime.date.fromisoformat(v.strip())
    except ValueError:
        return None


def merge_frontmatter(fm_a, fm_b, leader_fm, today):
    """統合ノートのfrontmatterを機械的に決める。
    - aliases: 両原ノート＋リーダー入力の和集合（順序保持・重複除去）。専用処理。
    - date/updated: 統合ノートは「本日新規作成された」ノートとして扱い、リーダー
      入力に無ければ常に本日日付にする（原ノートのdate/updatedを引き継がない＝
      統合という編集行為が行われた日を正しく残す）。
    - 上記以外: リーダー入力を最優先。無ければ「正本＝updatedが新しい方」の
      原ノートの値で補う（設計書§2.3手順5「正本＝updatedが新しい方」。project/
      review_by等、原ノート間で値が割れうるフィールドの決定に使う）。
    戻り値: (merged_fm, primary_is_a: bool)
    """
    da, db = _fm_date(fm_a), _fm_date(fm_b)
    primary_is_a = True
    if da and db:
        primary_is_a = da >= db
    elif db and not da:
        primary_is_a = False
    primary_fm = fm_a if primary_is_a else fm_b

    merged = dict(leader_fm)
    for k, v in primary_fm.items():
        if k in ("aliases", "date", "updated"):
            continue
        merged.setdefault(k, v)

    alias_union = []
    seen = set()
    for src in (fm_a, fm_b, leader_fm):
        for a in vi.normalize_aliases(src.get("aliases")):
            if a not in seen:
                seen.add(a)
                alias_union.append(a)
    merged["aliases"] = alias_union
    merged.setdefault("date", today.isoformat())
    merged.setdefault("updated", today.isoformat())
    return merged, primary_is_a


_KNOWN_FM_ORDER = ("date", "updated", "tags", "project", "aliases", "review_by")


def render_note(fm, body):
    lines = ["---"]

    def emit(k, v):
        if isinstance(v, list):
            lines.append(f"{k}:")
            lines.extend(f"  - {item}" for item in v)
        else:
            lines.append(f"{k}: {v}")

    emitted = set()
    for k in _KNOWN_FM_ORDER:
        if k in fm:
            emit(k, fm[k])
            emitted.add(k)
    for k, v in fm.items():
        if k in emitted:
            continue
        emit(k, v)
    lines.append("---")
    lines.append("")
    lines.append(body.strip())
    lines.append("")
    return "\n".join(lines)


def build_stub(orig_fm, merged_title_ref, summary_lines, today):
    """原ノートの非破壊スタブ（`deprecated: true`＋`superseded_by:`＋短い要約）を作る。
    元のfrontmatterは可能な限り保持し、deprecated/superseded_by/updatedのみ上書きする
    （aliasesも保持＝統合ノート側の和集合と合わせ、旧ノート単体で参照された場合の
    想起手掛かりを残す）。
    """
    fm = dict(orig_fm)
    fm["deprecated"] = "true"
    fm["superseded_by"] = f"[[{merged_title_ref}]]"
    fm["updated"] = today.isoformat()
    body_lines = [f"> このノートは [[{merged_title_ref}]] に統合されました。"]
    if summary_lines:
        body_lines.append("")
        body_lines.extend(summary_lines)
    return render_note(fm, "\n".join(body_lines))


# ============================================================
# backlink（流入wikilink）張替
# ============================================================

CODE_SPLIT_RE = re.compile(r"(```.*?```|~~~.*?~~~|`[^`\n]*`)", re.S)
WIKILINK_RE = re.compile(r"(!?)\[\[([^\[\]]+?)\]\]")
FRONTMATTER_BLOCK_RE = re.compile(r"\A---\n.*?\n---\n?", re.S)


def _norm_key(s):
    """wikilinkターゲット/見出し文字列の**比較専用**正規化（Unicode NFC・
    ASCII部分のみ大小無視）。出力に書き戻す文字列は常に原文のままで、この
    正規化は「同じノート/見出しを指しているか」の判定にのみ用いる（Codex
    レビュー指摘・Major: NFC/NFD揺れ・大小文字違いで同一ノートを指す表記が
    張替から漏れていた）。"""
    if s is None:
        return s
    normalized = unicodedata.normalize("NFC", s)
    return "".join(c.lower() if ord(c) < 128 else c for c in normalized)


def note_ref_forms(relpath):
    """あるノートを指しうるwikilink表記のバリエーション（stem単独／フォルダ込みパス）。
    比較用に正規化済みキーの集合を返す（_norm_key参照）。"""
    p = pathlib.PurePosixPath(relpath)
    stem = p.stem
    full = str(p.with_suffix(""))
    forms = {stem}
    if full != stem:
        forms.add(full)
    return {_norm_key(f) for f in forms}


def rewrite_links_in_text(text, old_forms, new_ref, merged_headings):
    """1ファイル分のテキストに対しwikilink張替を行う。対象は `[[note]]`/
    `[[note|表示]]`/`[[note#見出し]]`（見出しは統合ノートに同名見出しが存在する
    場合のみ）。frontmatterブロック全体（`related:`含む）・コードフェンス/
    インラインコード・埋め込み(`![[...]]`)・`[]()`形式（そもそも本正規表現の
    対象外）は張替対象外にする（設計書§2.3手順5）。
    戻り値: (新テキスト, 置換件数, 見出し不一致でskipした件数)。
    """
    m = FRONTMATTER_BLOCK_RE.match(text)
    fm_block, body = (m.group(0), text[m.end():]) if m else ("", text)

    replaced = 0
    skipped_heading = 0
    normalized_headings = {_norm_key(h) for h in merged_headings}

    def process_segment(seg):
        nonlocal replaced, skipped_heading

        def repl(mobj):
            nonlocal replaced, skipped_heading
            bang, inner = mobj.group(1), mobj.group(2)
            if bang == "!":
                return mobj.group(0)  # 埋め込み(![[...]])は対象外
            target_part, _, display_part = inner.partition("|")
            target, _, heading = target_part.partition("#")
            target = target.strip()
            if _norm_key(target) not in old_forms:
                return mobj.group(0)
            if heading and _norm_key(heading.strip()) not in normalized_headings:
                skipped_heading += 1
                return mobj.group(0)
            new_inner = new_ref + (f"#{heading}" if heading else "") + (f"|{display_part}" if display_part else "")
            replaced += 1
            return f"[[{new_inner}]]"

        return WIKILINK_RE.sub(repl, seg)

    parts = CODE_SPLIT_RE.split(body)
    new_body = "".join(process_segment(p) if i % 2 == 0 else p for i, p in enumerate(parts))
    return fm_block + new_body, replaced, skipped_heading


def apply_backlink_rewrite(worktree, note_a_rel, note_b_rel, merged_rel, merged_headings):
    old_forms = note_ref_forms(note_a_rel) | note_ref_forms(note_b_rel)
    merged_p = pathlib.PurePosixPath(merged_rel)
    stems_elsewhere = collect_stems(worktree, exclude={note_a_rel, note_b_rel, merged_rel})
    # 統合先stemが既存の別ノートと衝突する場合はフルパス表記を使う（曖昧参照防止）。
    new_ref = str(merged_p.with_suffix("")) if merged_p.stem in stems_elsewhere else merged_p.stem

    changed_files = []
    total_replaced = 0
    total_skipped_heading = 0
    worktree = pathlib.Path(worktree)
    for p in sorted(worktree.rglob("*.md")):
        if ".git" in p.parts:
            continue
        if p.is_symlink():
            # symlink化されたノートは張替対象外にする（Codexレビュー指摘・Major:
            # 原ノート2件だけでなく、backlink張替の走査対象全般でsymlinkを
            # 追従してしまうと意図しないファイルへ書込む経路になる）。
            continue
        rel = p.relative_to(worktree).as_posix()
        if rel in (note_a_rel, note_b_rel, merged_rel):
            continue  # スタブ/統合ノート自身は対象外（自己参照の生成防止）
        # 注記（Codexレビュー指摘・Minor: CRLF混入時に除外判定(CODE_SPLIT_RE等)を
        # すり抜けないか）: pathlib.Path.read_text()は既定でuniversal newlines変換を
        # 行うため、ディスク上の実バイト列が\r\n/\rでも、ここで得るtextは常にLF化
        # 済みになる（実機確認済み）。従ってCRLF由来の除外漏れは本コードパスでは
        # 構造的に発生しない＝追加のCRLF検知は不要と判断した。
        text = p.read_text(encoding="utf-8")
        new_text, n, skipped = rewrite_links_in_text(text, old_forms, new_ref, merged_headings)
        total_skipped_heading += skipped
        if n:
            assert_safe_to_write(worktree, p)
            p.write_text(new_text, encoding="utf-8")
            changed_files.append({"path": rel, "replaced": n})
            total_replaced += n
    return {"changed_files": changed_files, "total_replaced": total_replaced,
            "skipped_heading_links": total_skipped_heading, "new_ref": new_ref}


# ============================================================
# Codex verdict 検証（fail-closed）
# ============================================================

def validate_verdict(verdict, expected_candidate_id=None, expected_content_fingerprint=None):
    """CodexのverdictJSONを構造検証する。不正/欠落があればValueErrorを送出する
    （呼び出し側=commitは当該候補をblockedのまま書込しないこと＝fail-closed）。
    expected_candidate_id/expected_content_fingerprintを渡した場合、verdict内の
    candidate_id・content_fingerprintがそれぞれ一致するかも検証する（Codexレビュー
    指摘・Critical・2巡目再指摘: candidate_id一致だけでは、証拠パック生成後に
    draft内容が変わっていても検出できない。両方一致して初めて「Codexが見た内容と
    現在の内容が同一」を保証できる＝別候補や古い証拠パックへの回答の使い回しを
    機械検出する）。
    """
    if not isinstance(verdict, dict):
        raise ValueError("verdictはオブジェクトである必要があります")
    missing = [k for k in REQUIRED_VERDICT_KEYS if k not in verdict]
    if missing:
        raise ValueError(f"verdictに必須キーが欠落しています: {missing}")
    if expected_candidate_id is not None and verdict.get("candidate_id") != expected_candidate_id:
        raise ValueError(
            f"verdictのcandidate_idが一致しません（{verdict.get('candidate_id')!r} != {expected_candidate_id!r}）")
    if expected_content_fingerprint is not None and verdict.get("content_fingerprint") != expected_content_fingerprint:
        raise ValueError(
            "verdictのcontent_fingerprintが現在のworktree内容と一致しません"
            "（証拠パック生成後に内容が変わった疑い・古いverdictの使い回しの疑い）")
    if verdict["verdict"] not in ("approve", "reject", "block"):
        raise ValueError(f"verdictの値が不正です: {verdict['verdict']!r}")
    if not isinstance(verdict["reason_code"], str) or not verdict["reason_code"].strip():
        raise ValueError("reason_codeが空です")
    if verdict["rubric_version"] != RUBRIC_VERSION:
        raise ValueError(f"rubric_versionが現行と一致しません（{verdict['rubric_version']!r} != {RUBRIC_VERSION!r}）")
    if not isinstance(verdict["model"], str) or not verdict["model"].strip():
        raise ValueError("modelが空です（レビューに使用したモデル識別子を記録してください）")
    rubric = verdict["rubric"]
    if not isinstance(rubric, dict):
        raise ValueError("rubricはオブジェクトである必要があります")
    missing_items = [k for k in RUBRIC_ITEMS if k not in rubric]
    if missing_items:
        raise ValueError(f"rubricに必須項目が欠落しています: {missing_items}")
    bad_items = [k for k in RUBRIC_ITEMS if rubric.get(k) not in ("PASS", "FAIL")]
    if bad_items:
        raise ValueError(f"rubric項目の値がPASS/FAILではありません: {bad_items}")
    if verdict["verdict"] == "approve":
        failed = [k for k in RUBRIC_ITEMS if rubric.get(k) != "PASS"]
        if failed:
            raise ValueError(f"verdict=approveなのにFAIL項目があります（矛盾・reject扱いすべき）: {failed}")
    return True


# ============================================================
# サブコマンド実装
# ============================================================

def format_preflight_human(payload):
    lines = [f"preflight: ok={payload.get('ok')}" + (f" reason={payload['reason']}" if payload.get("reason") else "")]
    for r in payload.get("unresolved") or []:
        lines.append(f"  未解決ALERT: {r}")
    for r in payload.get("results") or []:
        mark = "OK" if r.get("cleared") else "NG"
        lines.append(f"  [{mark}] {r.get('candidate_id')}: {r.get('reason', '')}"
                      f" (note_a={r.get('note_a')}, note_b={r.get('note_b')})")
    return "\n".join(lines)


def cmd_preflight(args):
    vault_root = pathlib.Path(args.vault).resolve()
    alerts_dir = pathlib.Path(args.alerts_dir)
    lock_path = pathlib.Path(args.lock_file)
    worktrees_dir = pathlib.Path(args.worktrees_dir)

    def report(payload, ok):
        print(json.dumps(payload, ensure_ascii=False, indent=2) if args.json else format_preflight_human(payload))
        return 0 if ok else 1

    # ① 未解決ALERTラッチの一次チェック（ロック取得前・軽量な早期棄却）
    latch_active, unresolved = check_alert_latch(vault_root, alerts_dir, lock_path, worktrees_dir)
    if latch_active:
        return report({"ok": False, "reason": "unresolved_alerts", "unresolved": unresolved}, False)

    try:
        state = load_state(args.state_file)
    except ValueError as e:
        return report({"ok": False, "reason": "state_load_error", "error": str(e)}, False)

    if args.candidate_id:
        ids = [args.candidate_id]
    else:
        ids = [cid for cid, c in state["candidates"].items() if c.get("status") in ("pending", "retry")]

    if not ids:
        return report({"ok": True, "reason": "no_candidates", "results": []}, True)

    held = acquire_lock(lock_path)
    if not held:
        return report({"ok": False, "reason": "lock_busy"}, False)
    try:
        # ② 専用ロック取得後の再確認（TOCTOU対策・設計書§2.3手順3）。
        # 自分自身が既にlock_pathを保持しているため、lock_conflict種別のALERTに
        # 対しては再取得を試みない（同一プロセスでも別fdからのflock再取得は
        # ブロックされ「他プロセスが保持中」と誤検出するため＝alert_machine_resolved参照）。
        latch_active2, unresolved2 = check_alert_latch(vault_root, alerts_dir, lock_path, worktrees_dir,
                                                         lock_already_held=True)
        if latch_active2:
            return report({"ok": False, "reason": "unresolved_alerts_recheck", "unresolved": unresolved2}, False)

        # ロック取得後にstate.jsonを再読込する（TOCTOU対策・Codexレビュー指摘・
        # Minor: ロック取得前に読んだstateのまま判定すると、ロック待機中に候補が
        # 終端状態(merged/skipped)へ更新されていても古いpending/retry情報で
        # cleared=trueを返しうる。preflight自体はVaultへ書込まずcleared=trueは
        # あくまで後続作業の入口を開く合図に過ぎないため実害は限定的だが、実際に
        # Vaultを書込むcmd_commitは別途ロック内でstate.jsonを再読込している＝
        # ここでも同じ防御を揃える）。バッチ選定対象の候補一覧(ids)自体はロック
        # 取得前の値のまま据え置く（再選定すると「ロック待機中に新規検出された
        # 候補」まで巻き込み挙動が変わるため）。候補ごとの状態/パス判定のみを
        # 最新のstateで行う。
        try:
            state = load_state(args.state_file)
        except ValueError as e:
            return report({"ok": False, "reason": "state_load_error", "error": str(e)}, False)

        results = []
        for cid in ids:
            try:
                sanitize_candidate_id(cid)
            except ValueError as e:
                results.append({"candidate_id": cid, "cleared": False, "reason": str(e)})
                continue
            cand = state["candidates"].get(cid)
            if cand is not None and cand.get("status") in TERMINAL_STATUSES:
                # 終端状態（merged/skipped）からの再処理は拒否する（fail-closed・
                # 2026-07-14追加）。バッチ選定（--candidate-id省略時）は既にstatus
                # in (pending, retry)で絞り込み済みのためここへは到達しないが、
                # --candidate-idで既にmerged/skipped確定済みの候補を明示指定
                # された場合はここで初めて弾かれる（二重マージ等を防ぐ最終防波堤）。
                results.append({"candidate_id": cid, "cleared": False,
                                 "reason": f"終端状態（{cand.get('status')}）の候補は再処理できません（fail-closed）",
                                 "note_a": cand.get("note_a"), "note_b": cand.get("note_b")})
                continue
            if cand is not None:
                note_a, note_b = cand.get("note_a"), cand.get("note_b")
            elif args.candidate_id == cid and args.note_a and args.note_b:
                note_a, note_b = args.note_a, args.note_b  # 手動オーバーライド（stateに未登録の候補を試す場合）
            else:
                results.append({"candidate_id": cid, "cleared": False, "reason": "state.jsonに候補が見つかりません"})
                continue
            try:
                verify_knowledge_note_path(vault_root, note_a)
                verify_knowledge_note_path(vault_root, note_b)
                if note_a == note_b:
                    raise ValueError("note_aとnote_bが同一パスです")
            except ValueError as e:
                results.append({"candidate_id": cid, "cleared": False, "reason": str(e),
                                 "note_a": note_a, "note_b": note_b})
                continue
            results.append({"candidate_id": cid, "cleared": True, "note_a": note_a, "note_b": note_b})

        ok_any = any(r["cleared"] for r in results)
        return report({"ok": True, "results": results}, ok_any)
    finally:
        release_lock(held)


def cmd_worktree_setup(args):
    vault_root = pathlib.Path(args.vault).resolve()
    cid = sanitize_candidate_id(args.candidate_id)
    worktrees_dir = pathlib.Path(args.worktrees_dir)
    worktrees_dir.mkdir(parents=True, exist_ok=True)
    target = worktrees_dir / cid
    branch = f"{args.branch_prefix}{cid}"

    try:
        toplevel = run_git(["rev-parse", "--show-toplevel"], vault_root).stdout.strip()
    except RuntimeError as e:
        print(f"FAIL: Vaultがgitリポジトリではありません（{e}）", file=sys.stderr)
        return 1
    if pathlib.Path(toplevel).resolve() != vault_root.resolve():
        print(f"FAIL: --vault はgitリポジトリのルートを指定してください（実際のルート: {toplevel}）", file=sys.stderr)
        return 1

    if args.force_recreate and target.exists():
        # head_moved ALERTからの復旧（設計書§2.3手順3「基準HEAD再設定確認」）:
        # 既存worktree/branchを破棄し、現在のHEADから作り直す。draft以降の内容は
        # 現在のmainに対してもう一度やり直す必要がある（backlink張替等は内容依存の
        # ためrebaseでは代替できない＝leaderが手順書に従いdraftからやり直す前提）。
        run_git(["worktree", "remove", "--force", str(target)], vault_root, check=False)
        run_git(["branch", "-D", branch], vault_root, check=False)

    if target.exists():
        meta = read_meta(target)
        if meta.get("candidate_id") != cid:
            print(f"FAIL: worktree先が既に別用途で存在します: {target}", file=sys.stderr)
            return 1
        print(f"worktree-setup: 既存worktreeを再利用します: {target}")
    else:
        # ブランチが既に存在するか（worktree自体は消したがbranchは残っている再開ケース
        # を含む＝`git worktree list`ではなく`git branch --list`で判定する必要がある）。
        branch_proc = run_git(["branch", "--list", branch], vault_root, check=False)
        if branch_proc.stdout.strip():
            run_git(["worktree", "add", str(target), branch], vault_root)
        else:
            run_git(["worktree", "add", "-b", branch, str(target), "HEAD"], vault_root)

    base_head = git_head(target)
    meta = read_meta(target)
    meta.update({
        "candidate_id": cid,
        "branch": branch,
        "base_head": base_head,
        "worktree_setup_at": datetime.datetime.now().isoformat(timespec="seconds"),
    })
    write_meta(target, meta)
    print(json.dumps({"worktree": str(target), "branch": branch, "base_head": base_head}, ensure_ascii=False))
    return 0


def cmd_draft(args):
    cid = sanitize_candidate_id(args.candidate_id)
    wt = pathlib.Path(args.worktrees_dir) / cid
    if not wt.is_dir():
        print(f"FAIL: worktreeがありません。先にworktree-setupを実行してください: {wt}", file=sys.stderr)
        return 1
    meta = read_meta(wt)
    if not meta.get("candidate_id"):
        print(f"FAIL: worktreeのメタ情報がありません（worktree-setup未実行の疑い）: {wt}", file=sys.stderr)
        return 1

    try:
        note_a_path = verify_knowledge_note_path(wt, args.note_a)
        note_b_path = verify_knowledge_note_path(wt, args.note_b)
        if args.note_a == args.note_b:
            raise ValueError("note-aとnote-bが同一です")
        if args.merged_note_path in (args.note_a, args.note_b):
            raise ValueError("merged-note-pathは原ノートと異なるパスにしてください")
        merged_path = verify_knowledge_note_path(wt, args.merged_note_path, must_exist=False)
    except ValueError as e:
        print(f"FAIL: パス検証に失敗しました: {e}", file=sys.stderr)
        return 1

    merged_input_file = pathlib.Path(args.merged_note_file)
    if not merged_input_file.is_file():
        print(f"FAIL: 統合ノート本文ファイルが見つかりません: {merged_input_file}", file=sys.stderr)
        return 1

    # 注記（Codexレビュー指摘・Minor: CRLF混入時に除外判定(CODE_SPLIT_RE等)をすり抜け
    # ないか）: pathlib.Path.read_text()は既定でuniversal newlines変換を行うため、
    # ディスク上の実バイト列が\r\n/\rでも、ここで得るtextは常にLF化済みになる
    # （実機確認済み）。従ってCRLF由来の除外漏れは本コードパスでは構造的に発生
    # しない＝追加のCRLF検知は不要と判断した。
    note_a_text = note_a_path.read_text(encoding="utf-8")
    note_b_text = note_b_path.read_text(encoding="utf-8")
    merged_input_text = merged_input_file.read_text(encoding="utf-8")

    fm_a, _ = vi.parse_frontmatter(note_a_text)
    fm_b, _ = vi.parse_frontmatter(note_b_text)
    orig_hash_a = hashlib.sha256(note_a_path.read_bytes()).hexdigest()
    orig_hash_b = hashlib.sha256(note_b_path.read_bytes()).hexdigest()

    leader_fm, leader_body = vi.parse_frontmatter(merged_input_text)
    today = datetime.date.today()
    merged_fm, primary_is_a = merge_frontmatter(fm_a, fm_b, leader_fm, today)
    merged_text = render_note(merged_fm, leader_body)
    merged_headings = set(mqg.extract_headings(merged_text))

    try:
        merged_path.parent.mkdir(parents=True, exist_ok=True)
        assert_safe_to_write(wt, merged_path)
        merged_path.write_text(merged_text, encoding="utf-8")

        stems_elsewhere = collect_stems(wt, exclude={args.note_a, args.note_b, args.merged_note_path})
        merged_title_ref = (str(pathlib.PurePosixPath(args.merged_note_path).with_suffix(""))
                             if merged_path.stem in stems_elsewhere else merged_path.stem)

        default_summary = ["（統合先ノートを参照。要約はリーダーが手順書に従い後日補記可能。）"]
        summary_a = args.stub_summary_a.splitlines() if args.stub_summary_a else default_summary
        summary_b = args.stub_summary_b.splitlines() if args.stub_summary_b else default_summary

        assert_safe_to_write(wt, note_a_path)
        note_a_path.write_text(build_stub(fm_a, merged_title_ref, summary_a, today), encoding="utf-8")
        assert_safe_to_write(wt, note_b_path)
        note_b_path.write_text(build_stub(fm_b, merged_title_ref, summary_b, today), encoding="utf-8")

        rewrite_result = apply_backlink_rewrite(wt, args.note_a, args.note_b, args.merged_note_path, merged_headings)
    except ValueError as e:
        print(f"FAIL: 書込直前の安全確認に失敗しました: {e}", file=sys.stderr)
        return 1

    meta.update({
        "note_a": args.note_a,
        "note_b": args.note_b,
        "note_a_content_hash": orig_hash_a,
        "note_b_content_hash": orig_hash_b,
        "merged_note_path": args.merged_note_path,
        "merged_title_ref": merged_title_ref,
        "primary_source": args.note_a if primary_is_a else args.note_b,
        "backlink_rewrite": rewrite_result,
        "draft_at": datetime.datetime.now().isoformat(timespec="seconds"),
    })
    # draft完了直後の内容フィンガープリントを記録する（evidence/gate/commitが
    # 「証拠パック生成時と同じ内容か」を検証する基準値・compute_worktree_fingerprint
    # のdocstring参照）。
    try:
        meta["content_fingerprint"] = compute_worktree_fingerprint(wt, meta)
    except ValueError as e:
        print(f"FAIL: draft完了直後のfingerprint計算に失敗しました: {e}", file=sys.stderr)
        return 1
    write_meta(wt, meta)

    print(json.dumps({
        "worktree": str(wt), "merged_note_path": args.merged_note_path,
        "stub_a": args.note_a, "stub_b": args.note_b,
        "backlink_rewrite": rewrite_result,
    }, ensure_ascii=False, indent=2))
    return 0


def cmd_evidence(args):
    cid = sanitize_candidate_id(args.candidate_id)
    wt = pathlib.Path(args.worktrees_dir) / cid
    meta = read_meta(wt)
    required = ("note_a", "note_b", "merged_note_path", "base_head", "content_fingerprint")
    missing = [k for k in required if not meta.get(k)]
    if missing:
        print(f"FAIL: draftが未実行、またはmeta情報が不足しています（欠落: {missing}）", file=sys.stderr)
        return 1

    note_a, note_b, merged_rel = meta["note_a"], meta["note_b"], meta["merged_note_path"]
    orig_a = git_show(wt, meta["base_head"], note_a) or ""
    orig_b = git_show(wt, meta["base_head"], note_b) or ""
    fm_a, _ = vi.parse_frontmatter(orig_a)
    fm_b, _ = vi.parse_frontmatter(orig_b)

    merged_full = (wt / merged_rel).read_text(encoding="utf-8")
    fm_merged, body_merged = vi.parse_frontmatter(merged_full)

    stub_a_text = (wt / note_a).read_text(encoding="utf-8")
    stub_b_text = (wt / note_b).read_text(encoding="utf-8")

    knowledge_titles = sorted(
        p.stem for p in (wt / "Knowledge").glob("*.md")
        if p.relative_to(wt).as_posix() not in (note_a, note_b, merged_rel))

    resolved_links, broken_links = [], []
    stems = collect_stems(wt)
    for raw in vi.LINK_RE.findall(mqg.strip_code_blocks(body_merged)):
        target = raw.split("|")[0].split("#")[0].strip()
        if not target:
            continue
        ok = (target in stems) or (wt / f"{target}.md").exists()
        (resolved_links if ok else broken_links).append(raw)

    evidence = {
        "candidate_id": cid,
        "content_fingerprint": meta["content_fingerprint"],
        "rubric_version": RUBRIC_VERSION,
        "rubric_items": RUBRIC_ITEMS,
        "note_a": {"path": note_a, "frontmatter": fm_a, "content_hash": meta.get("note_a_content_hash")},
        "note_b": {"path": note_b, "frontmatter": fm_b, "content_hash": meta.get("note_b_content_hash")},
        "merged_note": {"path": merged_rel, "frontmatter": fm_merged, "text": merged_full},
        "stub_preview": {"note_a": stub_a_text, "note_b": stub_b_text},
        "backlink_rewrite": meta.get("backlink_rewrite"),
        "existing_titles_in_target_folder": knowledge_titles,
        "resolved_internal_links": resolved_links,
        "broken_internal_links": broken_links,
        "instructions_for_reviewer": (
            "rubric_itemsの各項目についてPASS/FAILを個別に判定してください。1項目でもFAIL、"
            "または判定に必要な情報が不足する場合はverdict=block、reason_code="
            "BLOCK_INSUFFICIENT_CONTEXTとして返してください。verdict=approveにできるのは"
            "全項目PASSの場合のみです。出力JSONには本証拠パックのcandidate_idと"
            "content_fingerprintを、そのまま`candidate_id`・`content_fingerprint`キーとして"
            f"含めてください（値: candidate_id={cid!r}, content_fingerprint={meta['content_fingerprint']!r}。"
            "別候補や、証拠パック生成後に内容が変わった状態への回答の使い回しを"
            "機械検出するため必須）。"
        ),
    }
    out_path = pathlib.Path(args.out) if args.out else evidence_file_path(args.worktrees_dir, cid)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(evidence, ensure_ascii=False, indent=2), encoding="utf-8")

    meta["evidence_path"] = str(out_path)
    meta["evidence_generated_at"] = datetime.datetime.now().isoformat(timespec="seconds")
    write_meta(wt, meta)

    print(f"証拠パック生成: {out_path}")
    return 0


def run_recall_bench(bench_tsv, vault_dir, hook, env):
    cmd = [sys.executable, str(DEFAULT_RECALL_BENCH), str(bench_tsv), "--vault", str(vault_dir),
           "--hook", str(hook), "--json", "--allow-hook-errors"]
    proc = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=300)
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        raise mqg.GateError(f"recall_bench.pyの出力解析に失敗しました: {e}\n{proc.stdout[:500]}\n{proc.stderr[:500]}")
    return {"hits": data.get("hits", 0), "total": data.get("total", 0), "hook_errors": data.get("hook_errors", 0)}


def run_bench_gate(args, vault_root, wt, note_a, note_b, merged_rel):
    repo_root, relpath = mqg.assert_bench_tsv_untouched(args.bench_tsv)
    bench_text = pathlib.Path(args.bench_tsv).read_text(encoding="utf-8")
    path_map = {note_a: merged_rel, note_b: merged_rel}
    remapped_text = mqg.remap_bench_tsv(bench_text, path_map)

    tmp_fd, tmp_tsv = tempfile.mkstemp(prefix="vault-merge-bench-", suffix=".tsv")
    os.close(tmp_fd)
    pathlib.Path(tmp_tsv).write_text(remapped_text, encoding="utf-8")
    bench_exc = None
    before = after = None
    try:
        env = os.environ.copy()
        env["VAULT_RECALL_DISABLE_VECTOR"] = "1"  # gate.py採点は「キーワードのみモード」（設計書指示）
        before = run_recall_bench(args.bench_tsv, vault_root, args.hook, env)
        after = run_recall_bench(tmp_tsv, wt, args.hook, env)
    except mqg.GateError as e:
        bench_exc = e
    except (subprocess.SubprocessError, OSError) as e:
        # timeout/起動失敗等もGateError化してfinallyでの改ざん確認を必ず経由させる
        # （Codexレビュー指摘・Major: mqg.GateError以外の例外もこのブロック全体を
        # 素通りしてしまうと改ざん確認がスキップされる）。
        bench_exc = mqg.GateError(f"recall_bench.pyの実行に失敗しました: {e}")
    finally:
        try:
            os.unlink(tmp_tsv)
        except OSError:
            pass
        # 実行後にもう一度アサート（実行前後を挟む二重チェック＝改ざん検知窓を最小化）。
        # ベンチ実行自体が例外終了した場合でも改ざん確認は必ず行う（Codexレビュー
        # 指摘・Major: finallyに置かないとJSON解析失敗/timeout時に改ざん検知が
        # スキップされてしまい、fail-closedの穴になる）。
        # 改ざん確認（tamper_exc）はbench_exc（recall_bench.py自体の失敗）より常に
        # 優先し、repo_root/relpathを必ず付与する（Codexレビュー指摘・Major・
        # 2巡目再指摘: `bench_exc = bench_exc or e`だと改ざん確認自体の失敗が
        # 既存bench_excに隠れ、ALERTのbench_repo/bench_relpathが欠落しうる。
        # repo_root/relpathはこの時点で既にassert_bench_tsv_untouched成功時に
        # 確定済みのため、常に付与できる）。
        tamper_exc = None
        try:
            status_after = mqg.git_status_porcelain(repo_root, relpath)
            if status_after.strip():
                tamper_exc = mqg.GateError(
                    f"gate実行後にベンチTSVへの変更が検出されました（改ざん疑い）: {relpath}\n{status_after}",
                    bench_repo=str(repo_root), bench_relpath=relpath)
        except mqg.GateError as e:
            tamper_exc = mqg.GateError(
                f"gate実行後の改ざん確認自体に失敗しました: {e}", bench_repo=str(repo_root), bench_relpath=relpath)
        if tamper_exc is not None:
            bench_exc = tamper_exc
        elif bench_exc is not None and (bench_exc.bench_repo is None or bench_exc.bench_relpath is None):
            bench_exc.bench_repo = str(repo_root)
            bench_exc.bench_relpath = relpath
    if bench_exc is not None:
        raise bench_exc

    regression = after["hits"] < before["hits"]
    return {
        "pass": (not regression) and after["hook_errors"] == 0,
        "before": before, "after": after,
        "bench_repo": str(repo_root), "bench_relpath": relpath,
        "regression": regression,
    }


def compute_worktree_fingerprint(worktree, meta):
    """draftが変更した全ファイル（原ノート2件・統合ノート・backlink張替対象）の
    現在の内容とbase_headを1つのハッシュへ畳み込む。draft完了直後に記録
    （meta["content_fingerprint"]）し、evidence/gate/commitの各段階で再計算した
    値がこれと一致することを要求することで、「Codexが承認した内容」「gateが
    評価した内容」「実際にcommitされる内容」が別物にすり替わっていないことを
    保証する（Codexレビュー指摘・Critical、2巡目再指摘含む: 従来はcandidate_idの
    一致だけで、証拠パック生成後にdraft内容が変わっていても検出できなかった）。

    対象ファイルが読めない・存在しない・symlink・worktree外を指す等、内容を
    確実に確定できない場合はValueErrorを送出する（Codexレビュー指摘・Major・
    2巡目再指摘: 固定文字列へのフォールバックは「読込不能」と「たまたま同じ
    内容」を区別できずfail-closedに反する）。
    """
    worktree = pathlib.Path(worktree).resolve()
    paths = sorted({meta.get("note_a"), meta.get("note_b"), meta.get("merged_note_path")} -
                    {None} |
                    {c["path"] for c in (meta.get("backlink_rewrite") or {}).get("changed_files", [])})
    h = hashlib.sha256()
    h.update((meta.get("base_head") or "").encode("utf-8"))
    for rel in paths:
        target = worktree / rel
        if target.is_symlink():
            raise ValueError(f"fingerprint計算対象がsymlinkです（安全性確認不可）: {rel}")
        try:
            resolved = target.resolve(strict=True)
            resolved.relative_to(worktree)
        except (OSError, ValueError) as e:
            raise ValueError(f"fingerprint計算対象を安全に読めません（{rel}）: {e}")
        h.update(b"\x00")
        h.update(rel.encode("utf-8"))
        h.update(b"\x00")
        h.update(resolved.read_bytes())
    return h.hexdigest()


def validate_gate_result(gate_result, expected_cid, expected_fingerprint, allow_bench_skip=False):
    """gate結果JSONの構造的整合性（候補ID・fingerprint一致・必須セクションの型・
    bench非skip）のみを検証する（fail-closed）。不正・不一致であればValueErrorを
    送出する（呼び出し側=commitはBLOCKEDとして書込しないこと）。

    「gate_result['pass']が実際にTrueかどうか」の判定は意図的にここでは行わない
    （呼び出し側で別途チェックさせる）。整合性は取れているが正当にFAILだった
    gate結果（＝正常な意思決定としてのSKIP）と、そもそも改ざん・使い回し・
    構造不正が疑われるgate結果（＝異常としてのBLOCKED）を区別するため
    （Codexレビュー指摘対応時に単純にpass判定だけへ寄せると、この区別が失われる）。
    """
    if not isinstance(gate_result, dict):
        raise ValueError("gate結果はオブジェクトである必要があります")
    if "pass" not in gate_result or not isinstance(gate_result["pass"], bool):
        raise ValueError("gate結果のpassがbool型で存在しません")
    if gate_result.get("candidate_id") != expected_cid:
        raise ValueError(f"gate結果のcandidate_idが一致しません（{gate_result.get('candidate_id')!r} != {expected_cid!r}）")
    if gate_result.get("fingerprint") != expected_fingerprint:
        raise ValueError("gate結果のfingerprintが現在のworktree内容と一致しません（gate後に内容が変更された疑い）")
    bench = gate_result.get("bench")
    if not isinstance(bench, dict):
        raise ValueError("gate結果にbench情報がありません")
    if bench.get("skipped") and not allow_bench_skip:
        raise ValueError("gate結果のbenchがskippedです（--allow-bench-skipを明示しない限りcommitできません）")
    if "pass" not in bench or not isinstance(bench["pass"], bool):
        raise ValueError("gate結果のbench.passがbool型で存在しません")
    if not bench.get("skipped"):
        # 非skip時（実ベンチ実行時）は回帰採点の主要フィールドも構造検証する
        # （Codexレビュー指摘・Major・2巡目再指摘: 空dict同然のbenchセクションでも
        # 通ってしまう抜け道を塞ぐ）。
        missing_bench_keys = [k for k in ("before", "after", "regression") if k not in bench]
        if missing_bench_keys:
            raise ValueError(f"gate結果のbenchに必須項目が欠落しています（非skip時必須）: {missing_bench_keys}")

    section_pass = {}
    for key in ("structural", "aliases", "frontmatter_required_keys", "broken_links"):
        section = gate_result.get(key)
        if not isinstance(section, dict) or "pass" not in section or not isinstance(section["pass"], bool):
            raise ValueError(f"gate結果の{key}セクションが不正です（'pass'がbool型で必要）")
        section_pass[key] = section["pass"]

    # トップレベルpassが各セクションの論理積と自己矛盾していないかを再計算で検証する
    # （Codexレビュー指摘・Major・2巡目再指摘: 従来は各セクションが辞書型であることしか
    # 確認しておらず、`{"pass": true, "structural": {}}`のような中身の無いセクションでも
    # 通ってしまっていた）。
    computed_pass = all(section_pass.values()) and bench["pass"]
    if computed_pass != gate_result["pass"]:
        raise ValueError(
            f"gate結果のpassが各セクションの論理積と一致しません（改ざん/破損の疑い・"
            f"セクション別: {section_pass}, bench: {bench['pass']}, 記録されたpass: {gate_result['pass']}）")
    return True


def cmd_gate(args):
    vault_root = pathlib.Path(args.vault).resolve()
    cid = sanitize_candidate_id(args.candidate_id)
    wt = pathlib.Path(args.worktrees_dir) / cid
    meta = read_meta(wt)
    required = ("note_a", "note_b", "merged_note_path", "base_head")
    missing = [k for k in required if not meta.get(k)]
    if missing:
        print(f"FAIL: draftが未実行です（欠落: {missing}）", file=sys.stderr)
        return 1

    note_a, note_b, merged_rel = meta["note_a"], meta["note_b"], meta["merged_note_path"]
    orig_a = git_show(wt, meta["base_head"], note_a) or ""
    orig_b = git_show(wt, meta["base_head"], note_b) or ""
    merged_text = (wt / merged_rel).read_text(encoding="utf-8")

    fm_a, _ = vi.parse_frontmatter(orig_a)
    fm_b, _ = vi.parse_frontmatter(orig_b)
    fm_merged, _ = vi.parse_frontmatter(merged_text)

    result = {
        "candidate_id": cid,
        "structural": mqg.check_structural(orig_a, orig_b, merged_text),
        "aliases": mqg.check_aliases_union(fm_a, fm_b, fm_merged),
        "frontmatter_required_keys": mqg.check_frontmatter_required_keys(fm_a, fm_b, fm_merged),
        "broken_links": mqg.check_broken_links(wt),
    }

    if args.skip_bench:
        result["bench"] = {"skipped": True, "pass": True}
    elif not args.bench_tsv:
        print("FAIL: --bench-tsv が必要です（明示的にskipする場合は --skip-bench）", file=sys.stderr)
        return 1
    else:
        try:
            result["bench"] = run_bench_gate(args, vault_root, wt, note_a, note_b, merged_rel)
        except mqg.GateError as e:
            write_alert(args.alerts_dir, cid, "bench_tsv_tampered", "gate", str(e),
                        bench_repo=e.bench_repo, bench_relpath=e.bench_relpath)
            result["bench"] = {"pass": False, "error": str(e)}
            result["pass"] = False
            _write_gate_result(args.worktrees_dir, cid, result)
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return 1

    result["pass"] = all([
        result["structural"]["pass"], result["aliases"]["pass"],
        result["frontmatter_required_keys"]["pass"], result["broken_links"]["pass"],
        result["bench"].get("pass", True),
    ])
    # commit時にgate結果と現在のworktree内容が一致することを再検証するための
    # fingerprint（compute_worktree_fingerprint参照・Codexレビュー指摘・Critical対応）。
    result["fingerprint"] = compute_worktree_fingerprint(wt, meta)
    _write_gate_result(args.worktrees_dir, cid, result)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["pass"] else 2


def _write_gate_result(worktrees_dir, cid, result):
    gate_file_path(worktrees_dir, cid).write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")


def cmd_skip(args):
    """候補を「マージ不適」として明示的に終端状態skippedへ遷移させる（FR9bが
    定義する候補状態語彙pending/merged/skipped/blocked/retryのうち、従来
    skippedを設定するコードパスが本CLIに一つも存在せず、リーダーが「マージ不適」
    と判断した候補が永久にpendingへ留まり週次レポートに再検出され続けていた
    間隙を埋める・2026-07-14追加）。

    commit/revertと異なりstate.jsonへ**直接**書込む（git log trailerをsource of
    truthにreconcileで再構成する運用の対象外）。理由:
    - skip判断はVault本体への内容変更を一切伴わない（統合ノートも作らず原ノートも
      変更しない）。そもそも対応するコミットが存在しないため、reconcileが読み
      取れるsource of truth（git log trailer）を作りようがない。
    - これはblocked/retry（ALERTファイルというgit外の情報源から_reconcile_locked
      がstate.jsonへ直接書込む既存の前例）と同じ構造であり、「Vaultへの実書込みを
      伴わない状態遷移はstate.json直書き」という既に確立した設計方針の範囲内。
    - 万一state.jsonが失われても、週次検出側(knowledge_merge_candidates.py)は
      次回実行時に同じrelpathペアを再検出しpendingとして再提案する（fail-safe
      方向＝安全側の既定に落ちる。tombstone設計＝TERMINAL_STATUSESのdocstring参照）。

    ロックはreconcileと同型（vault-merge.lockを共有・acquire_lock_with_retry）を
    用いる。state.jsonはknowledge_merge_candidates.py（週次検出側・別ワーカー
    担当）とも共有されるため、読込→更新→書込を丸ごとロック内に収めlost update
    を防ぐ（cmd_reconcileのコメントと同じ理由）。

    ガード（fail-closed＝迷ったら書込まない）:
      - candidate_idがstate.jsonに存在しない → FAIL
      - **git log（candidate_id trailer）に、この候補の非revertマージコミットが
        既に存在し、かつそれが現在のVault HEADから到達可能（=実際に反映済み）
        → FAIL**（state.jsonのstatusフィールドだけを信用しない。commit成功
        直後のreconcile自動実行が失敗した場合、state.jsonはstale=pendingの
        まま残りうる＝cmd_commit末尾のWARNコメント参照。state.jsonの
        status=="merged"という自己申告だけに頼ると、このstale窓でskipが
        「既に実際にはマージ済みの候補」を誤ってskipped扱いにしてしまう。
        git logをsource of truthとして直接参照するのはcmd_revertと同じ考え方
        ＝list_merge_commits参照。HEAD到達可能性まで見るのは、ff-only失敗で
        候補ブランチにだけ残った未反映コミットを「マージ済み」と誤判定しない
        ため＝_commit_reachable_from_head参照）
      - status=="blocked" → FAIL（先に対応するALERTのresolved欄を埋めreconcileを
        実行すること。ALERT未解決のままskipで揉み消せてしまうのを防ぐ）
      - status in ("pending", "retry") → skippedへ遷移してOK
      - status=="skipped"（既にskip済み） → 冪等に成功。reasonは上書きせず
        既存値を維持する（後から異なるreasonで誤って上書きする事故を防ぐ）
      - 上記以外の未知のstatus値 → FAIL（fail-closed）
      - **当該candidate_idに未解決ALERTが1件でもあれば → FAIL**（リーダー判断・
        2026-07-14追加。上のstatus=="blocked"チェックは、reconcileが未実行で
        statusがまだ"pending"/"retry"のままの間（=== 19b. ===参照）はすり抜けて
        しまうため、二重防御として本CLI自身でもALERTディレクトリを直接走査する。
        「未解決」の判定はalert_is_resolved()（resolved欄の日付形式＋
        alert_machine_resolved()のAND。codex_unavailableのみ日付形式のみ）を
        _reconcile_lockedと共有する。ALERTファイルが1件でも読込失敗する場合も
        fail-closedでFAILする＝全件が確実に解消済みと確認できない限りskipしない）

    TOCTOU残余（モジュールdocstring「未解決ALERTのTOCTOU再確認」参照）: 上記の
    ALERT走査は意図的にstate.json保存（save_state_atomic）の直前に置き、その間には
    `cand["status"] = "skipped"`等の代入3行しか挟まない＝実用上ほぼゼロ化している。
    ただしwrite_alert()自体はロックを取らない設計のため、この走査完了〜保存の間に
    他プロセスが新規ALERTを書込む窓は理論上ゼロにはならない（既知の残余として受容）。
    """
    cid = sanitize_candidate_id(args.candidate_id)
    reason = (args.reason or "").strip()
    if not reason:
        print("FAIL: --reason は空にできません", file=sys.stderr)
        return 1

    held = acquire_lock_with_retry(args.lock_file, attempts=3)
    if not held:
        print("FAIL: state.jsonの排他ロックを取得できませんでした（knowledge_merge_candidates.py実行中の可能性・"
              "しばらく待って再実行してください）", file=sys.stderr)
        return 1
    try:
        try:
            state = load_state(args.state_file)
        except ValueError as e:
            print(f"FAIL: {e}", file=sys.stderr)
            return 1

        cand = state["candidates"].get(cid)
        if cand is None:
            print(f"FAIL: candidate_id={cid} がstate.jsonに見つかりません", file=sys.stderr)
            return 1

        # state.jsonのstatusフィールドだけでなく、git log自体をsource of truthと
        # して直接確認する（Codexレビュー指摘・Major対応: commit成功直後の自動
        # reconcileが失敗するとstate.jsonがstale=pendingのまま残りうる窓があり、
        # status=="merged"チェックだけでは実際には既にマージ済みの候補を誤って
        # skippedにしてしまう。list_merge_commits()を直接参照するのはcmd_revert
        # と同じ考え方）。
        vault_root = pathlib.Path(args.vault).resolve()
        try:
            merge_commits = [c for c in list_merge_commits(vault_root)
                             if c.get("candidate_id") == cid and c.get("action") != "revert"]
            # list_merge_commits()は`git log --all`のためVault本体の現在HEADへ未到達の
            # コミット（例: worktree上でcommitした直後にff-onlyマージが失敗し、候補
            # ブランチ`vault-merge/<cid>`上にだけtrailer付きコミットが残っているケース＝
            # head_moved ALERT参照）も拾ってしまう（Codexレビュー指摘・Major・2巡目
            # 再指摘）。skipにとって意味のある「既にマージ済み」は現在のVault HEADへ
            # 実際に反映されているコミットのみなので、ここでHEADからの到達可能性
            # （`git merge-base --is-ancestor`）で絞り込む。判定コマンド自体の失敗も
            # fail-closedでFAILさせる（_commit_reachable_from_head参照）。
            merge_commits = [c for c in merge_commits if _commit_reachable_from_head(vault_root, c["hash"])]
        except RuntimeError as e:
            print(f"FAIL: git履歴の確認に失敗しました（fail-closed・{e}）", file=sys.stderr)
            return 1
        if merge_commits:
            print(f"FAIL: candidate_id={cid} は既にgit履歴にマージコミットが存在します"
                  f"（hash={merge_commits[0]['hash']}）。skip不可（取消すにはrevertを使う）。"
                  "state.jsonのstatusがstaleな可能性があるため、先に `reconcile` を実行してください。",
                  file=sys.stderr)
            return 1

        status = cand.get("status")
        if status == "merged":
            print(f"FAIL: candidate_id={cid} は既にmergedです（skip不可。取消すにはrevertを使ってください）",
                  file=sys.stderr)
            return 1
        if status == "blocked":
            print(f"FAIL: candidate_id={cid} はblocked状態です（先に対応するALERTのresolved欄を埋め"
                  "reconcileを実行してください。ALERT未解決のままskipはできません）", file=sys.stderr)
            return 1
        if status == "skipped":
            print(json.dumps({"ok": True, "candidate_id": cid, "status": "skipped", "idempotent": True,
                               "skip_reason": cand.get("skip_reason"), "skipped_at": cand.get("skipped_at")},
                              ensure_ascii=False))
            print("skip: 既にskipped済みです（reasonは上書きせず既存値を維持しました）")
            return 0
        if status not in ("pending", "retry"):
            print(f"FAIL: candidate_id={cid} のstatusが未知の値です（fail-closed）: {status!r}", file=sys.stderr)
            return 1

        # 当該candidate_idの未解決ALERTを直接確認する（リーダー判断・2026-07-14
        # 追加・cmd_skipのdocstring参照）。status=="blocked"チェック（上）は
        # reconcile実行後にしか効かないため、reconcile未実行でstatusがまだ
        # "pending"/"retry"の間はここが唯一の防波堤になる（二重防御）。
        alerts_dir = pathlib.Path(args.alerts_dir)
        if alerts_dir.exists() and not alerts_dir.is_dir():
            # --alerts-dirが誤って通常ファイル等を指している場合はfail-closedで
            # 拒否する（Codexレビュー指摘・Minor: 存在しない場合は「ALERTがまだ
            # 一度も生成されていない」という正常な初回状態として扱う既存の慣習
            # （check_alert_latch/_reconcile_lockedと同じ）を維持するが、パスが
            # 存在するのにディレクトリでない場合は設定ミス/改ざんの疑いが強く、
            # 「ALERTなし」と誤認してskipを通してしまうのを防ぐ）。
            print(f"FAIL: --alerts-dirがディレクトリではありません（fail-closed）: {alerts_dir}", file=sys.stderr)
            return 1
        unresolved_alerts = []
        if alerts_dir.is_dir():
            for path in sorted(alerts_dir.glob("*.md")):
                try:
                    fm, _, _ = parse_alert(path)
                except OSError as e:
                    print(f"FAIL: ALERTファイルの読込に失敗しました（fail-closed・{path}: {e}）", file=sys.stderr)
                    return 1
                if fm.get("candidate_id") != cid:
                    continue
                if not alert_is_resolved(fm, vault_root, args.lock_file, args.worktrees_dir, lock_already_held=True):
                    unresolved_alerts.append(str(path))
        if unresolved_alerts:
            print(f"FAIL: candidate_id={cid} に未解決ALERTがあります（{unresolved_alerts}）。"
                  "先に対応するALERTのresolved欄を埋めreconcileを実行してください。"
                  "ALERT未解決のままskipはできません。", file=sys.stderr)
            return 1

        today = datetime.date.today().isoformat()
        cand["status"] = "skipped"
        cand["skip_reason"] = reason
        cand["skipped_at"] = today
        save_state_atomic(args.state_file, state)

        print(json.dumps({"ok": True, "candidate_id": cid, "status": "skipped",
                          "skip_reason": reason, "skipped_at": today}, ensure_ascii=False))
        return 0
    finally:
        release_lock(held)


def cmd_unskip(args):
    """cmd_skipでskippedへ遷移させた候補を、手動再評価のためpendingへ戻す
    （本人裁定・2026-07-14追加＝「マージ不適」と判断した候補を後から見直したい、
    という人間判断のための唯一の復帰経路。knowledge_merge_candidates.py（週次
    検出側）はskipped/mergedをTERMINAL_STATUSESとして扱い自動では触らないため、
    このコマンドを使わない限りskippedは事実上永久に固定される）。

    cmd_skipと対称のガード（fail-closed＝迷ったら書込まない）:
      - status!="skipped" → FAIL（pending/retryはそもそもunskip不要、blockedは
        先にALERT解消→reconcileが筋、mergedは絶対に戻せない終端。状態ごとに
        個別の許可条件を作るより「skipped以外は一律FAIL」というホワイトリスト
        方式の方が単純で間違いにくい）。
      - git log（candidate_id trailer）に現在のVault HEADから到達可能な非revert
        マージコミットが既に存在する → FAIL（cmd_skipと全く同じ理由・同じ
        _commit_reachable_from_head参照。skip自体はVault非破壊のbookkeeping
        操作のため通常この矛盾は起きないはずだが、state.jsonの手動編集ミスや
        破損に備え、git logをsource of truthとして直接照合するfail-closedを
        skipと対称に維持する）。
      - 当該candidate_idに未解決ALERTが1件でもあれば → FAIL（cmd_skipと同じ
        alert_is_resolved()を共有。ALERT未解決のまま状態をいじれてしまうのを
        防ぐという二重防御の考え方もcmd_skipと同型）。

    監査性: skip_reason/skipped_atは一切上書きしない（「いつ・なぜskipと判断
    されたか」という履歴事実そのものは消さない）。unskip_reason/unskipped_atを
    追加記録するのみ（同一候補が将来また複数回skip↔unskipを往復しても、直近の
    skip理由と直近のunskip理由が両方読める状態を保つ＝上書きし続けると往復履歴が
    失われるため、この2フィールドは「直近1回分」の記録として割り切る）。

    副作用（意図どおり・cmd_skipのdocstring「tombstone設計」参照）: statusを
    pendingへ戻すことで、次回のknowledge_merge_candidates.py（週次検出）実行時に
    同じ候補ペアが改めてpending候補として週次レポートに現れうる。これは
    「もう一度検討したい」という本コマンドの目的そのものであり、tombstone
    （skipped）を明示的に破る唯一の経路として設計している。
    """
    cid = sanitize_candidate_id(args.candidate_id)
    reason = (args.reason or "").strip()
    if not reason:
        print("FAIL: --reason は空にできません", file=sys.stderr)
        return 1

    held = acquire_lock_with_retry(args.lock_file, attempts=3)
    if not held:
        print("FAIL: state.jsonの排他ロックを取得できませんでした（knowledge_merge_candidates.py実行中の可能性・"
              "しばらく待って再実行してください）", file=sys.stderr)
        return 1
    try:
        try:
            state = load_state(args.state_file)
        except ValueError as e:
            print(f"FAIL: {e}", file=sys.stderr)
            return 1

        cand = state["candidates"].get(cid)
        if cand is None:
            print(f"FAIL: candidate_id={cid} がstate.jsonに見つかりません", file=sys.stderr)
            return 1

        status = cand.get("status")
        if status != "skipped":
            print(f"FAIL: candidate_id={cid} はskipped状態ではありません（現在: {status!r}）。"
                  "unskipはskipped→pendingの手動再評価専用です（skipped以外は一律拒否・fail-closed）。",
                  file=sys.stderr)
            return 1

        # state.jsonのstatusフィールドだけでなく、git log自体をsource of truthと
        # して直接確認する（cmd_skipと同じ理由・_commit_reachable_from_head参照）。
        vault_root = pathlib.Path(args.vault).resolve()
        try:
            merge_commits = [c for c in list_merge_commits(vault_root)
                             if c.get("candidate_id") == cid and c.get("action") != "revert"]
            merge_commits = [c for c in merge_commits if _commit_reachable_from_head(vault_root, c["hash"])]
        except RuntimeError as e:
            print(f"FAIL: git履歴の確認に失敗しました（fail-closed・{e}）", file=sys.stderr)
            return 1
        if merge_commits:
            print(f"FAIL: candidate_id={cid} は既にgit履歴にマージコミットが存在します"
                  f"（hash={merge_commits[0]['hash']}）。unskip不可（state.jsonとgit履歴の矛盾の疑い・"
                  "先に`reconcile`を実行し状態を確認してください）。", file=sys.stderr)
            return 1

        # 当該candidate_idの未解決ALERTを直接確認する（cmd_skipと同じ・二重防御。
        # 通常skipped候補にALERTは残らないはずだが、blockedからの手動編集ミス等に
        # 備えfail-closedにする）。
        alerts_dir = pathlib.Path(args.alerts_dir)
        if alerts_dir.exists() and not alerts_dir.is_dir():
            print(f"FAIL: --alerts-dirがディレクトリではありません（fail-closed）: {alerts_dir}", file=sys.stderr)
            return 1
        unresolved_alerts = []
        if alerts_dir.is_dir():
            for path in sorted(alerts_dir.glob("*.md")):
                try:
                    fm, _, _ = parse_alert(path)
                except OSError as e:
                    print(f"FAIL: ALERTファイルの読込に失敗しました（fail-closed・{path}: {e}）", file=sys.stderr)
                    return 1
                if fm.get("candidate_id") != cid:
                    continue
                if not alert_is_resolved(fm, vault_root, args.lock_file, args.worktrees_dir, lock_already_held=True):
                    unresolved_alerts.append(str(path))
        if unresolved_alerts:
            print(f"FAIL: candidate_id={cid} に未解決ALERTがあります（{unresolved_alerts}）。"
                  "先に対応するALERTのresolved欄を埋めreconcileを実行してください。"
                  "ALERT未解決のままunskipはできません。", file=sys.stderr)
            return 1

        # TOCTOU残余（モジュールdocstring/cmd_skipのdocstring参照）: 上記ALERT走査
        # から保存までは代入3行のみ＝実用上ほぼゼロ化しているが、write_alert()が
        # ロックを取らない設計のため理論上の窓は残る（既知の残余として受容）。
        today = datetime.date.today().isoformat()
        cand["status"] = "pending"
        cand["unskip_reason"] = reason
        cand["unskipped_at"] = today
        save_state_atomic(args.state_file, state)

        print(json.dumps({
            "ok": True, "candidate_id": cid, "status": "pending",
            "unskip_reason": reason, "unskipped_at": today,
            "skip_reason": cand.get("skip_reason"), "skipped_at": cand.get("skipped_at"),
        }, ensure_ascii=False))
        return 0
    finally:
        release_lock(held)


def cmd_commit(args):
    vault_root = pathlib.Path(args.vault).resolve()
    cid = sanitize_candidate_id(args.candidate_id)
    wt = pathlib.Path(args.worktrees_dir) / cid
    meta = read_meta(wt)
    required = ("note_a", "note_b", "merged_note_path", "base_head", "branch")
    missing = [k for k in required if not meta.get(k)]
    if missing:
        print(f"FAIL: draft未実行またはmeta不足: {missing}", file=sys.stderr)
        return 1

    verdict_path = pathlib.Path(args.verdict_file) if args.verdict_file else verdict_file_path(args.worktrees_dir, cid)
    gate_path = pathlib.Path(args.gate_file) if args.gate_file else gate_file_path(args.worktrees_dir, cid)

    held = acquire_lock_with_retry(args.lock_file, attempts=args.lock_retries)
    if not held:
        write_alert(args.alerts_dir, cid, "lock_conflict", "commit",
                    "マージロックの取得に失敗しました（他プロセスが保持中と思われます）。")
        print("BLOCKED: マージロックを取得できませんでした（ALERT生成・retry可能）", file=sys.stderr)
        return 3
    try:
        # 専用ロック取得後に未解決ALERTラッチを再確認する（Codexレビュー指摘・Major:
        # preflight通過後に新たなALERTが発生していた場合でも書込を止める必要がある）。
        latch_active, unresolved = check_alert_latch(vault_root, args.alerts_dir, args.lock_file,
                                                       args.worktrees_dir, lock_already_held=True)
        if latch_active:
            print(f"BLOCKED: 未解決ALERTがあるためコミットしません（ラッチ）: {unresolved}", file=sys.stderr)
            return 8

        # 候補の終端状態チェック（fail-closed・2026-07-14追加）。commitはstate.json
        # へ直接書込まない方針は据え置くが（cmd_commitの他コメント参照）、既に
        # merged/skippedが確定した候補への再commitだけは事前に読込のみで拒否する
        # （preflightのTERMINAL_STATUSESチェックと対の防波堤。preflightをすり抜けて
        # 直接commitを叩かれた場合でも二重マージを防ぐ）。ロック保持後にstate.jsonを
        # 読むためTOCTOUの窓は最小。blocked/retryはここでは弾かない（retryは
        # 再挑戦できることが設計上の意図であり、head_moved等のALERT解消後の
        # 再commitフローを壊さないため＝既存テスト=== 9. ===で確認）。
        try:
            commit_state = load_state(args.state_file)
        except ValueError as e:
            print(f"FAIL: state.jsonの読込に失敗しました（{e}）", file=sys.stderr)
            return 1
        commit_cand = commit_state["candidates"].get(cid)
        if commit_cand is None and not args.allow_unregistered_candidate:
            # candidate_idがstate.jsonに未登録の場合は既定でfail-closed拒否する
            # （リーダー判断・2026-07-14追加。Codexレビュー指摘・Major: state.json
            # 消失・誤ったstate-file指定・候補レコード欠落と、意図的な「stateに
            # 未登録の候補を手動で試す」運用（preflightの--note-a/--note-bによる
            # 手動オーバーライド）とを区別できないままcommitを通してしまっていた）。
            # 手動運用（preflightで--note-a/--note-bを使い、stateに未登録のまま
            # worktree-setup/draft/evidence/gate/commitと進める意図的なフロー）
            # だけは`--allow-bench-skip`と同じ二重明示エスケープハッチの流儀で
            # `--allow-unregistered-candidate`を要求する（既定は安全側＝拒否）。
            print(f"FAIL: candidate_id={cid} がstate.jsonに見つかりません（fail-closed・既定拒否）。"
                  "state.json消失/state-file誤指定/候補レコード欠落の可能性があります。"
                  "stateに未登録のまま意図的に手動commitする場合のみ"
                  "--allow-unregistered-candidate を明示してください。", file=sys.stderr)
            return 1
        if commit_cand is not None and commit_cand.get("status") in TERMINAL_STATUSES:
            print(f"FAIL: candidate_id={cid} は既に終端状態（{commit_cand.get('status')}）です。"
                  "再commitはできません（取消すにはrevertを使ってください）。", file=sys.stderr)
            return 1
        if commit_cand is not None and commit_cand.get("status") not in KNOWN_CANDIDATE_STATUSES:
            # 未知のstatus値はfail-closedで拒否する（Codexレビュー指摘・Major対応・
            # cmd_skipと同じ考え方＝KNOWN_CANDIDATE_STATUSES参照）。
            print(f"FAIL: candidate_id={cid} のstatusが未知の値です（fail-closed）: "
                  f"{commit_cand.get('status')!r}", file=sys.stderr)
            return 1

        # state.jsonのstatusフィールドだけでなく、git log自体もsource of truthとして
        # 直接確認する（Codexレビュー指摘・Major対応・cmd_skipと同じ考え方＝
        # list_merge_commits参照）。上のTERMINAL_STATUSESチェックだけでは、commit
        # 成功直後の自動reconcileが何らかの理由で失敗しstate.jsonがstale=pendingの
        # まま残った窓（cmd_commit末尾のWARNコメント参照）で、実際には既にmainへ
        # 反映済みの候補に対してworktree-setup --force-recreate→draft→gate→commitを
        # やり直すと、同じcandidate_idの2件目のマージコミットを作れてしまう
        # （TERMINAL_STATUSESチェックはstate.jsonの自己申告に依存するため、この
        # staleウィンドウでは無力）。HEAD到達可能性まで見るのは、ff-only失敗で
        # 候補ブランチにだけ残った未反映コミットを誤って「既にマージ済み」と
        # 判定しないため（_commit_reachable_from_head参照）。
        try:
            existing_merges = [c for c in list_merge_commits(vault_root)
                                if c.get("candidate_id") == cid and c.get("action") != "revert"]
            existing_merges = [c for c in existing_merges if _commit_reachable_from_head(vault_root, c["hash"])]
        except RuntimeError as e:
            print(f"FAIL: git履歴の確認に失敗しました（fail-closed・{e}）", file=sys.stderr)
            return 1
        if existing_merges:
            print(f"FAIL: candidate_id={cid} は既にgit履歴にマージコミットが存在します"
                  f"（hash={existing_merges[0]['hash']}）。再commit不可（取消すにはrevertを使ってください）。"
                  "state.jsonのstatusがstaleな可能性があるため、先に`reconcile`を実行してください。",
                  file=sys.stderr)
            return 1

        # verdict/gate結果の読込・fingerprint検証は、ロック取得後・git add直前という
        # 可能な限り狭い窓に置く（Codexレビュー指摘・Critical・2巡目再指摘: ロック
        # 取得前にfingerprintを計算すると、ロック待機中の変更を見逃すTOCTOU窓が残る）。
        try:
            expected_fp = compute_worktree_fingerprint(wt, meta)
        except ValueError as e:
            print(f"BLOCKED: 現在のworktree内容のfingerprintを計算できません（{e}）", file=sys.stderr)
            return 4

        try:
            verdict = json.loads(verdict_path.read_text(encoding="utf-8"))
            validate_verdict(verdict, expected_candidate_id=cid, expected_content_fingerprint=expected_fp)
        except (OSError, json.JSONDecodeError, ValueError) as e:
            # FR11a（Codex障害時・fail-closed）: verdictファイルが存在しない/読めない/
            # JSONとして壊れている/構造的に不正（必須キー欠落・候補ID不一致・
            # fingerprint不一致・rubric不正等、validate_verdict()参照）のいずれも、
            # 本CLI視点では「Codexから使用可能なverdictを得られなかった」点で区別
            # できない（不通・認証切れ・MCP未起動・timeout・利用上限のいずれも、
            # 呼び出し元＝リーダーが書くverdictファイルが正しく生成されないという
            # 同じ観測結果になる）。fail-closedに倒し、当該candidate_idのみを
            # blocked化する（他候補は妨げない＝FR11a本文どおり。ALERT_TYPES/
            # check_alert_latch()のcodex_unavailable分岐参照：このALERTは意図的に
            # FR12bの全マージ停止ラッチ対象外にしてあるため、他候補のpreflight/
            # commitを止めない）。ALERT生成後、保持中の同一ロックのままreconcile
            # 本体を呼び、この候補のstatusを即座にblockedへ反映する（commit成功時に
            # reconcileを自動実行する既存パターンと同型・cmd_commit末尾参照）。
            write_alert(args.alerts_dir, cid, "codex_unavailable", "commit",
                        f"Codexのverdictを取得できませんでした（不通/timeout/認証切れ/利用上限、"
                        f"またはverdict自体が不正・別候補や古い証拠パックへの回答の使い回しの疑い。"
                        f"fail-closed・FR11a）: {e}")
            alert_reconcile_rc, _ = _reconcile_locked(args)
            if alert_reconcile_rc != 0:
                print(f"WARN: ALERT生成後のreconcileに失敗しました（rc={alert_reconcile_rc}）。"
                      "state.jsonのstatusがstaleな可能性があります。手動で`reconcile`を実行してください。",
                      file=sys.stderr)
            print(f"BLOCKED: verdictが不正・読込不能・現在の内容と不一致のため書込しません"
                  f"（Codex不通等の可能性・当該候補のみblocked化・ALERT生成・FR11a。他候補は妨げません）: {e}",
                  file=sys.stderr)
            return 4
        if verdict["verdict"] != "approve":
            print(f"SKIP: Codex verdict={verdict['verdict']}（reason={verdict['reason_code']}）のためコミットしません",
                  file=sys.stderr)
            return 5

        try:
            gate_result = json.loads(gate_path.read_text(encoding="utf-8"))
            validate_gate_result(gate_result, cid, expected_fp, allow_bench_skip=args.allow_bench_skip)
        except (OSError, json.JSONDecodeError, ValueError) as e:
            print(f"BLOCKED: gate結果が不正・読込不能・現在の内容と不一致のため書込しません（{e}）", file=sys.stderr)
            return 4
        if gate_result["pass"] is not True:
            print("SKIP: gateがFAILのためコミットしません（worktree破棄のみ）", file=sys.stderr)
            return 5

        current_head = git_head(wt)
        rc, status_out = git_status_porcelain_dir(wt)
        if rc != 0:
            print(f"FAIL: git status に失敗しました: {status_out}", file=sys.stderr)
            return 1
        expected_dirty = {meta["note_a"], meta["note_b"], meta["merged_note_path"]} | \
            {c["path"] for c in (meta.get("backlink_rewrite") or {}).get("changed_files", [])}
        # `.vault-merge-meta.json`（本CLIが各段階の進行状況を書き足す非追跡ファイル）は
        # 常にworktree直下に存在しうるが、意図的にgit addしない対象なので
        # 「想定外の変更」判定からは除外する（META_FILENAME参照）。
        # `git status --porcelain` は "XY path" 形式（2文字ステータス+空白+パス）。
        unexpected = [line for line in status_out.splitlines()
                      if line.strip() and line[3:].strip() not in expected_dirty
                      and line[3:].strip() != META_FILENAME]
        if unexpected:
            write_alert(args.alerts_dir, cid, "worktree_dirty", "commit",
                        f"draft後に想定外の変更が検出されました: {unexpected}", target_path=wt)
            print(f"BLOCKED: worktreeに想定外の変更があります（ALERT生成）: {unexpected}", file=sys.stderr)
            return 6

        # 書込直前の最終ラッチ再確認（TOCTOU対策・外部脳総点検5巡目Codexレビュー
        # 指摘・Major、6巡目再指摘で配置をさらに書込直前へ移動: 冒頭の
        # check_alert_latch()呼出し（ロック取得直後）から、ここに至るまでに
        # state.json読込・fingerprint再計算・verdict/gate読込・検証・git status
        # 確認という無視できない処理を挟んでおり、この間に他プロセスが新規ALERT
        # を書込んでも（write_alert()自体はロックを取らない設計＝write_alertの
        # docstring参照）冒頭の一度きりのチェックでは検知できないまま実際の
        # git書込（add/commit/merge）へ進んでしまう窓があった。cmd_revertが既に
        # 採っている「実際の書込直前でもう一度latchを確認する」パターンに揃え、
        # かつ本チェック自体もgit statusの直後・`git add`の直前という実際の書込に
        # 最も近い位置へ置く（初版ではgit status確認より前に置いており、6巡目
        # レビューでその間の窓もまだ縮められると指摘された）。
        # なお本チェックとその直後のgit操作（`git add`/`git commit`/`git merge`の
        # 数回のsubprocess呼出し）の間にも理論上の窓は残る（モジュールdocstring
        # 「未解決ALERTのTOCTOU再確認」の既知の残余を参照。これを完全にゼロ化
        # するには書込側=write_alert()の全ロック化が必要だが、lock_conflict種別の
        # ALERTは「ロック取得に失敗した」事実を書くものであり、ロック必須化すると
        # 書けなくなる本末転倒のため採用しない）。
        latch_active_pre_write, unresolved_pre_write = check_alert_latch(
            vault_root, args.alerts_dir, args.lock_file, args.worktrees_dir, lock_already_held=True)
        if latch_active_pre_write:
            print(f"BLOCKED: 未解決ALERTがあるためコミットしません（書込直前の再確認ラッチ）: "
                  f"{unresolved_pre_write}", file=sys.stderr)
            return 8

        add_paths = sorted(expected_dirty)
        run_git(["add", "--"] + add_paths, wt)

        trailer_lines = [
            f"candidate_id: {cid}",
            f"note_a: {meta['note_a']}",
            f"note_b: {meta['note_b']}",
            f"note_a_content_hash: {meta.get('note_a_content_hash', '')}",
            f"note_b_content_hash: {meta.get('note_b_content_hash', '')}",
            f"merged_note_path: {meta['merged_note_path']}",
            f"codex_verdict: {verdict['verdict']}",
            f"reason_code: {verdict['reason_code']}",
            f"rubric_version: {verdict['rubric_version']}",
            f"model: {verdict['model']}",
            f"backlink_rewrite_count: {(meta.get('backlink_rewrite') or {}).get('total_replaced', 0)}",
            f"report_id: {args.report_id or ''}",
            "action: merge",
        ]
        message = (f"Knowledge自律整理: {meta['note_a']} + {meta['note_b']} -> {meta['merged_note_path']}\n\n"
                   + "\n".join(trailer_lines) + "\n")
        run_git(["commit", "-m", message], wt)
        new_commit = git_head(wt)

        try:
            run_git(["merge", "--ff-only", meta["branch"]], vault_root)
        except RuntimeError as e:
            write_alert(args.alerts_dir, cid, "head_moved", "commit",
                        f"main へのfast-forwardマージに失敗しました（HEAD移動または競合の疑い）: {e}",
                        base_head=current_head)
            print(f"BLOCKED: main へのff-onlyマージに失敗しました（ALERT生成）: {e}", file=sys.stderr)
            return 7

        # commit成功直後、保持中のvault-merge.lockを離さないまま reconcile 本体を
        # 呼ぶ（state.jsonがstaleなまま次セッションへ渡る事故の再発防止）。ここで
        # cmd_reconcile(args)を素朴に呼ぶとロック取得を再度試みてしまい、flockは
        # 同一プロセス内でも別fdからの再取得をブロックするため自己競合で必ず失敗
        # する（_reconcile_lockedのdocstring参照）。reconcileのみ失敗してもcommit
        # 自体の成功は取り消さない（fail-closedにする理由が無い＝git履歴が
        # source of truthのため、reconcileは後からいつでもやり直せる）。
        reconcile_rc, _reconcile_touched = _reconcile_locked(args)
        reconcile_ok = reconcile_rc == 0
        if not reconcile_ok:
            print(f"WARN: commitは成功しましたがreconcileに失敗しました（rc={reconcile_rc}）。"
                  "state.jsonがstaleなままです＝手動で `knowledge_merge.py reconcile` を実行してください。",
                  file=sys.stderr)

        print(json.dumps({"ok": True, "candidate_id": cid, "commit": new_commit,
                          "merged_into": str(vault_root), "reconcile_ok": reconcile_ok}, ensure_ascii=False))
        print("残る手順: 週次レポートの候補状態欄を更新（手順書=Vault: Preferences/knowledge-merge-procedure.md 手順A-7）")
        return 0
    finally:
        release_lock(held)


def list_merge_commits(vault_root):
    """git log 全体からcandidate_id trailerを持つコミットを抽出する
    （reconcileのsource of truth・設計書§2.3手順12）。git log自体が失敗した場合は
    RuntimeErrorを送出する（Codexレビュー指摘・Major: 従来は空リストへ静かに
    フォールバックしており、_reconcile_locked()がgit log失敗時でも「候補無し」と
    誤認してstate.jsonを保存＝stale stateを見逃したままreconcile成功扱いに
    なってしまっていた）。"""
    fmt = "%H%x01%B%x02"
    proc = run_git(["log", "--all", f"--pretty=format:{fmt}"], vault_root, check=False)
    if proc.returncode != 0:
        raise RuntimeError(f"git log に失敗しました（cwd={vault_root}）: {proc.stderr.strip()}")
    commits = []
    known_keys = ("candidate_id", "action", "note_a", "note_b", "merged_note_path", "report_id", "reverts_commit")
    for chunk in proc.stdout.split("\x02"):
        if not chunk.strip():
            continue
        h, _, body = chunk.partition("\x01")
        info = {"hash": h.strip()}
        for line in body.splitlines():
            m = re.match(r"^([a-zA-Z_]+):\s*(.*)$", line)
            if m and m.group(1) in known_keys:
                info[m.group(1)] = m.group(2).strip()
        if "candidate_id" in info:
            commits.append(info)
    return commits


def _commit_reachable_from_head(cwd, commit_hash):
    """commit_hashが現在のHEADから到達可能な祖先か（=Vault本体に実際に反映
    済みか）を`git merge-base --is-ancestor`で判定する。list_merge_commits()の
    `git log --all`は、ff-only失敗で候補ブランチ上にだけ残った未反映コミット
    （head_moved ALERT参照）も含んでしまうため、cmd_skipがそれを「既にマージ
    済み」と誤判定しないための絞り込みに使う（Codexレビュー指摘・Major）。
    判定コマンド自体が失敗（returncodeが0/1以外）した場合はfail-closedで
    RuntimeErrorを送出する（呼び出し側=cmd_skipはFAILとして書込しないこと）。
    """
    proc = subprocess.run(["git", "-C", str(cwd), "merge-base", "--is-ancestor", commit_hash, "HEAD"],
                           capture_output=True, text=True, timeout=15)
    if proc.returncode == 0:
        return True
    if proc.returncode == 1:
        return False
    raise RuntimeError(
        f"git merge-base --is-ancestor の判定に失敗しました（commit={commit_hash}）: {proc.stderr.strip()}")


def _reconcile_locked(args):
    """cmd_reconcileの本体（呼び出し元がvault-merge.lockを既に保持している前提・
    ロックの取得/解放は一切行わない）。cmd_reconcile（自身でロック取得後に呼ぶ）と
    cmd_commit（コミット成功直後、保持中の同一ロックのまま呼ぶ）の双方から使う。
    cmd_commitとcmd_reconcileは同じlock_fileを使うため、cmd_commit内で単純に
    cmd_reconcile(args)を呼ぶとロック取得を二重に試みることになり、flockは同一
    プロセス内でも別fdからの再取得をブロックするため自己競合で必ず失敗する
    （alert_machine_resolvedのlock_already_held解説と同じ理由）。本体をここへ
    抽出し、ロック取得は各呼び出し元の責務に一本化することでこれを避ける。
    戻り値: (returncode: int, touched: int|None)。touchedはreturncode==0の時のみ意味を持つ。
    """
    vault_root = pathlib.Path(args.vault).resolve()
    try:
        state = load_state(args.state_file)
    except ValueError as e:
        print(f"FAIL: {e}", file=sys.stderr)
        return 1, None

    # ここから先（git log読取〜state.json書込）はまとめてfail-closed化する
    # （Codexレビュー指摘・Major・2件: ①save_state_atomic()の例外(権限不足・
    # ディスク枯渇・atomic replace失敗等)が従来無捕捉のまま呼び出し元へ伝播し、
    # cmd_commitから呼ばれた際に「commit成功はそのまま維持・reconcileのみ失敗を
    # 警告」という契約を満たせず例外で処理全体が落ちていた。②list_merge_commits()
    # がgit log失敗時に静かに空リストへフォールバックしていたため、stale state
    # を見逃したままreconcile成功として扱われていた。BaseException(KeyboardInterrupt
    # 等)はここでは飲み込まない）。
    try:
        # FR9bが定義するstatus語彙は pending/merged/skipped/blocked/retry の5つのみ
        # （"reverted"は含まれない）。revertは「一度mergedになった候補が後日救済
        # されたという追加の監査事実」として扱い、statusはmerged候補が持つ他の
        # フィールドとして`reverted_commit`にのみ記録する（knowledge_merge_candidates.py
        # のTERMINAL_STATUSES=("merged","skipped")とも整合させる＝別の状態値を
        # 勝手に増やして相手ワーカーの状態機械の前提を崩さないため）。
        # git logはnewest-first順で返るため、同一candidate_idに複数の同種コミットが
        # あっても最初に見つかったもの（＝最新）を採用する（setdefaultで2件目以降を
        # 無視）。merge/revertは別々に集計し、統合ノートの有無に関わらず両方の事実を
        # 反映する（処理順序に依存する上書き事故を避ける）。
        # list_merge_commits()は`git log --all`のためVault本体の現在HEADへ未到達の
        # コミット（worktree上でcommitした直後にff-onlyマージが失敗し、候補ブランチ
        # `vault-merge/<cid>`上にだけtrailer付きコミットが残っているケース＝
        # head_moved ALERT参照）も拾ってしまう。cmd_skipは`_commit_reachable_from_head`
        # で既にこれを絞り込んでいた（2026-07-12）が、reconcile本体では未適用のまま
        # 残っており、ff-only失敗直後に（誤って）reconcileを実行すると、実際には
        # mainへ反映されていない候補を"merged"と誤登録し得る間隙があった（外部脳
        # 総点検・2026-07-14修正。同じ絞り込みをcmd_revertにも適用＝下記参照）。
        commits = list_merge_commits(vault_root)
        merge_by_cid, revert_by_cid = {}, {}
        for c in commits:
            cid = c.get("candidate_id")
            if not cid:
                continue
            if not _commit_reachable_from_head(vault_root, c["hash"]):
                continue
            target = revert_by_cid if c.get("action") == "revert" else merge_by_cid
            target.setdefault(cid, c["hash"])

        touched = 0
        for cid, hash_ in merge_by_cid.items():
            cand = state["candidates"].setdefault(cid, {"candidate_id": cid})
            cand["status"] = "merged"
            cand["merged_commit"] = hash_
            touched += 1
        for cid, hash_ in revert_by_cid.items():
            cand = state["candidates"].setdefault(cid, {"candidate_id": cid})
            cand["reverted_commit"] = hash_
            touched += 1

        # ALERTからのstatus同期（「未解決なら進める」「解消したら戻す」の両方向を
        # 同一の厳格な解消判定=alert_is_resolved()で行う＝Codexレビュー指摘・
        # Major・2巡目再指摘対応: 当初は「進める」方向がresolved欄の有無のみ
        # （真偽のみ）、「戻す」方向が「resolved欄の日付形式＋alert_machine_
        # resolved()」という非対称な強度になっており、statusがまだ"pending"の
        # 候補に対しては「進める」側の弱い判定しか働かないため、resolved欄が
        # 形式不正/機械判定NGでも見かけ上blocked化されずpendingのまま残り、
        # cmd_skip()で終端化できてしまう（=== 19. ===の揉み消し経路と同型の
        # 間隙が"pending"側にも残っていた）。alert_is_resolved()はcmd_skip()も
        # 使う共有ヘルパーのためモジュールレベルへ定義（同関数のdocstring参照）。
        def _alert_is_resolved(fm):
            return alert_is_resolved(fm, vault_root, args.lock_file, args.worktrees_dir, lock_already_held=True)

        alerts_dir = pathlib.Path(args.alerts_dir)
        if alerts_dir.is_dir():
            # ALERTファイルが1件でも読込失敗する場合は、その回のreconcileでは
            # ALERT起因のstatus同期処理自体を全面的に見送る（fail-closed・
            # Codexレビュー指摘・Major: 読込失敗したALERTのcandidate_idが分からない
            # 以上、それを除外して「他は全部resolvedだった」と判断すると、本当は
            # 未解決だった候補まで誤って動かしかねない。現状維持の方が安全）。
            alerts_readable = True
            alert_records = []  # [(path, fm), ...] sorted順（=最新のALERTが最後）
            for path in sorted(alerts_dir.glob("*.md")):
                try:
                    fm, _, _ = parse_alert(path)
                except OSError:
                    alerts_readable = False
                    continue
                alert_records.append((path, fm))

            if alerts_readable:
                # candidate_idごとに「未解決ALERTの種別すべて」と「（あれば）
                # sorted順で最後に見つかった未解決ALERTのパス」を1回の走査で
                # 集計する（Codexレビュー指摘・Major・3巡目再指摘: 当初は「最後に
                # 見つかった未解決ALERT1件」の種別だけでstatusを決めていたため、
                # 同一候補にlock_conflict以外の未解決ALERT（例: 古いworktree_dirty）
                # と新しいlock_conflictが同時に存在する場合、ファイル名の日付順で
                # lock_conflictが最後に処理されるとstatus="retry"になってしまい、
                # cmd_skipはretryを拒否しないため「worktree_dirty側は実際には
                # 未解決のままskipできる」というfail-closedに反する経路が残って
                # いた。「lock_conflict以外の未解決が1件でもあればblocked、全件
                # lock_conflictの場合のみretry」という安全側の集約に変更する）。
                unresolved_cids = set()
                unresolved_types = {}  # cid -> {alert_type, ...}（未解決分のみ）
                last_unresolved_path = {}  # cid -> path（last_alert記録用・最新のもの）
                for path, fm in alert_records:
                    cid = fm.get("candidate_id")
                    if not cid:
                        continue
                    if not _alert_is_resolved(fm):
                        unresolved_cids.add(cid)
                        unresolved_types.setdefault(cid, set()).add(fm.get("alert_type"))
                        last_unresolved_path[cid] = path

                # 進める: 未解決ALERTがある候補はblocked/retryへ（merged/skipped/
                # revertedは対象外＝skip後にreconcileしてもskippedが消えない
                # ガードを維持・2026-07-14 skipコマンド追加時の対応）。
                for cid, types in unresolved_types.items():
                    if cid not in state["candidates"]:
                        continue
                    cand = state["candidates"][cid]
                    if cand.get("status") in ("merged", "skipped") or cand.get("reverted_commit"):
                        continue
                    non_lock_types = types - {"lock_conflict"}
                    cand["status"] = "retry" if not non_lock_types else "blocked"
                    cand["last_alert"] = str(last_unresolved_path[cid])
                    touched += 1

                # 戻す: 未解決ALERTが無くなった候補はblocked/retryからpendingへ
                # （外部脳総点検・2026-07-14追加。ALERTがresolvedになった候補が
                # 永久にblocked/retryへ留まり続け、cmd_skipのFAILメッセージ
                # 「先に対応するALERTのresolved欄を埋めreconcileを実行して
                # ください」が効果の無い指示になっていた間隙を埋める）。
                for cid, cand in state["candidates"].items():
                    if cand.get("status") in ("blocked", "retry") and cid not in unresolved_cids:
                        cand["status"] = "pending"
                        touched += 1

        save_state_atomic(args.state_file, state)
    except Exception as e:
        print(f"FAIL: reconcile処理中にエラーが発生しました（state.jsonは更新されていない可能性があります）: {e}",
              file=sys.stderr)
        return 1, None

    return 0, touched


def cmd_reconcile(args):
    # state.jsonはknowledge_merge_candidates.py（週次検出側・別ワーカー担当）も
    # 読み書きする共有ファイル。両者は同じ`vault-merge.lock`を排他ロックとして
    # 共有する設計（knowledge_merge_candidates.pyのDEFAULT_LOCK_FILEコメント参照）
    # のため、reconcileの読込→更新→書込を丸ごとロック内に収め、週次検出の書込と
    # 競合して片方の更新が失われる（lost update）ことを防ぐ。
    held = acquire_lock_with_retry(args.lock_file, attempts=3)
    if not held:
        print("FAIL: state.jsonの排他ロックを取得できませんでした（knowledge_merge_candidates.py実行中の可能性・"
              "しばらく待って再実行してください）", file=sys.stderr)
        return 1
    try:
        rc, touched = _reconcile_locked(args)
        if rc == 0:
            print(f"reconcile完了: {touched}件のcandidate状態をgit log trailer/ALERTから同期しました。")
        return rc
    finally:
        release_lock(held)


def cmd_alert(args):
    path = write_alert(args.alerts_dir, sanitize_candidate_id(args.candidate_id), args.alert_type,
                        args.command, args.message, base_head=args.base_head)
    print(f"ALERT生成: {path}")
    return 0


def cmd_revert(args):
    """コミット後に発覚した欠陥の救済revert（設計書§2.4）。週次自動フローには
    組み込まない＝呼び出しはリーダーの人間判断のみ想定。"""
    vault_root = pathlib.Path(args.vault).resolve()
    cid = sanitize_candidate_id(args.candidate_id)

    def _check_clean(command_label):
        rc, out = git_status_porcelain_dir(vault_root)
        if rc != 0:
            print(f"FAIL: git status に失敗しました: {out}", file=sys.stderr)
            return False, 1
        if out.strip():
            write_alert(args.alerts_dir, cid, "worktree_dirty", command_label,
                        f"vault本体に未コミットの変更が残っているためrevertを見送りました: {out}",
                        target_path=vault_root)
            print("BLOCKED: vault本体がcleanではありません（ALERT生成）", file=sys.stderr)
            return False, 6
        return True, 0

    def _resolve_revert_target():
        """現在のVault HEADから見て、candidate_idの非revertマージコミットを1件だけ
        特定する。0件/複数件/git log失敗はいずれも(None, メッセージ, 終了コード)を
        返す（呼び出し側はFAILとして処理を打ち切ること）。ロック取得前後の両方で
        呼び出し、ロック取得後の再呼び出しを実際のrevertに使う「正」とする
        （Codexレビュー指摘・Major・2026-07-14: ロック取得前の一度きりの判定では、
        判定からロック取得までの間にHEADが動いた場合、`_check_clean`と異なりここ
        だけ再確認していなかったためTOCTOU窓が残っていた。`git revert`はtargetの
        祖先関係を見ずに指定コミットの逆パッチを機械的に適用するため、判定後に
        到達不能になったコミットをそのままrevertすると意図しない差分を適用し
        かねない）。
        """
        try:
            commits = [c for c in list_merge_commits(vault_root)
                       if c.get("candidate_id") == cid and c.get("action") != "revert"]
            # list_merge_commits()は`git log --all`のため、ff-only失敗で候補ブランチ
            # `vault-merge/<cid>`上にだけ残った未反映コミット（head_moved ALERT参照）も
            # 拾ってしまう。現在のVault HEADから到達不能＝実際にはmainへ反映されて
            # いないコミットを`git revert`しても意味が無い（何も打ち消さない・むしろ
            # 意図しない差分を適用しかねない）ため、cmd_skip・_reconcile_lockedと同じ
            # `_commit_reachable_from_head`で絞り込む（外部脳総点検・2026-07-14修正）。
            commits = [c for c in commits if _commit_reachable_from_head(vault_root, c["hash"])]
        except RuntimeError as e:
            return None, f"revert対象コミットの検索に失敗しました: {e}", 1
        if not commits:
            return None, f"candidate_id={cid} のマージコミットが見つかりません", 1
        if len(commits) > 1:
            # git log は新しい順に並ぶが、candidate_idが複数コミットにまたがるのは
            # 通常あり得ない異常（候補IDの再利用等の疑い）。どれを戻すべきか自動選択
            # せずblockする（Codexレビュー指摘・Major: 従来はcommits[-1]で「最も古い」
            # コミットを暗黙に選んでおり、意図と逆の結果になり得た）。
            return None, (f"candidate_id={cid} に一致するマージコミットが複数見つかりました"
                           f"（候補ID再利用の疑い・自動選択しません）: {[c['hash'] for c in commits]}"), 1
        return commits[0]["hash"], None, 0

    ok, rc = _check_clean("revert")
    if not ok:
        return rc

    # ロック取得前の早期棄却（revert対象が無い/曖昧ならロックを取らずに済ませる）。
    # main()のグローバルRuntimeErrorハンドラでも最終的にFAIL表示・終了コード1には
    # なるが、worktree-setup同様ここでも分かりやすいメッセージに変換しておく。
    target, err, rc = _resolve_revert_target()
    if target is None:
        print(f"FAIL: {err}", file=sys.stderr)
        return rc

    held = acquire_lock_with_retry(args.lock_file, attempts=args.lock_retries)
    if not held:
        write_alert(args.alerts_dir, cid, "lock_conflict", "revert", "マージロックの取得に失敗しました。")
        print("BLOCKED: マージロックを取得できませんでした（ALERT生成）", file=sys.stderr)
        return 3
    try:
        # ロック取得後の再確認（TOCTOU対策・Codexレビュー指摘・Critical: 初回確認
        # からロック取得までの間に別プロセスが書込んだ変更を巻き込む窓を閉じる）。
        ok, rc = _check_clean("revert")
        if not ok:
            return rc
        latch_active, unresolved = check_alert_latch(vault_root, args.alerts_dir, args.lock_file,
                                                       args.worktrees_dir, lock_already_held=True)
        if latch_active:
            print(f"BLOCKED: 未解決ALERTがあるためrevertしません（ラッチ）: {unresolved}", file=sys.stderr)
            return 8

        # revert対象コミットもロック取得後に再確定する（TOCTOU対策・Codexレビュー
        # 指摘・Major: `_check_clean`と同様、ロック取得前の判定だけでは判定から
        # ロック取得までの間にHEADが動いた場合を捉えられない。ここで確定した値を
        # 実際の`git revert`に使う＝ロック取得前のtargetは早期棄却の判定にのみ使う）。
        target, err, rc = _resolve_revert_target()
        if target is None:
            print(f"FAIL: {err}（ロック取得後の再確認で判明）", file=sys.stderr)
            return rc

        current_head = git_head(vault_root)
        proc = run_git(["revert", "--no-commit", target], vault_root, check=False)
        if proc.returncode != 0:
            run_git(["revert", "--abort"], vault_root, check=False)
            write_alert(args.alerts_dir, cid, "head_moved", "revert",
                        f"revertがコンフリクトしたため中止しました（{target}）: {proc.stderr.strip()}",
                        base_head=current_head)
            print(f"BLOCKED: revertがコンフリクトしました（ALERT生成）: {proc.stderr.strip()}", file=sys.stderr)
            return 7
        trailer = f"candidate_id: {cid}\nreverts_commit: {target}\naction: revert\nreason: {args.reason or ''}\n"
        message = f"Revert Knowledge自律整理: {cid}\n\n{trailer}"
        run_git(["commit", "-m", message], vault_root)
        new_commit = git_head(vault_root)
        print(json.dumps({"ok": True, "candidate_id": cid, "revert_commit": new_commit, "reverted": target},
                          ensure_ascii=False))
        return 0
    finally:
        release_lock(held)


# ============================================================
# CLI
# ============================================================

def build_parser():
    ap = argparse.ArgumentParser(
        description="Knowledge自律整理・マージ実行の機械化CLI（設計書§2.3/2.4）。")
    sp = ap.add_subparsers(dest="cmd", required=True)

    def common(p, *, state=False, alerts=False, worktrees=False, lock=False):
        p.add_argument("--vault", default=str(DEFAULT_VAULT), help=f"Vaultのルート（既定: {DEFAULT_VAULT}）")
        if state:
            p.add_argument("--state-file", default=str(DEFAULT_STATE_FILE))
        if alerts:
            p.add_argument("--alerts-dir", default=str(DEFAULT_ALERTS_DIR))
        if worktrees:
            p.add_argument("--worktrees-dir", default=str(DEFAULT_WORKTREES_DIR))
        if lock:
            p.add_argument("--lock-file", default=str(DEFAULT_LOCK_FILE))

    p = sp.add_parser("preflight", help="未解決ALERTラッチ確認＋候補パス独立検証")
    common(p, state=True, alerts=True, worktrees=True, lock=True)
    p.add_argument("--candidate-id")
    p.add_argument("--note-a")
    p.add_argument("--note-b")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_preflight)

    p = sp.add_parser("worktree-setup", help="候補用worktreeを作成")
    common(p, worktrees=True)
    p.add_argument("--candidate-id", required=True)
    p.add_argument("--branch-prefix", default="vault-merge/")
    p.add_argument("--force-recreate", action="store_true",
                   help="既存worktree/branchを破棄し現在のHEADから作り直す"
                        "（head_moved ALERTからの復旧用。draft以降はやり直しになる）")
    p.set_defaults(func=cmd_worktree_setup)

    p = sp.add_parser("draft", help="統合ノート作成＋原ノートのスタブ化＋backlink張替（worktree内・未コミット）")
    common(p, worktrees=True)
    p.add_argument("--candidate-id", required=True)
    p.add_argument("--note-a", required=True)
    p.add_argument("--note-b", required=True)
    p.add_argument("--merged-note-path", required=True)
    p.add_argument("--merged-note-file", required=True,
                   help="リーダーが用意した統合ノート本文ファイル（frontmatter任意）")
    p.add_argument("--stub-summary-a", help="note-aスタブの数行要約（省略時は既定文言）")
    p.add_argument("--stub-summary-b", help="note-bスタブの数行要約（省略時は既定文言）")
    p.set_defaults(func=cmd_draft)

    p = sp.add_parser("evidence", help="Codexレビュー用の証拠パックJSONを生成")
    common(p, worktrees=True)
    p.add_argument("--candidate-id", required=True)
    p.add_argument("--out", help="出力先（既定: <worktrees-dir>/<candidate-id>.evidence.json）")
    p.set_defaults(func=cmd_evidence)

    p = sp.add_parser("gate", help="FR12a品質ゲート＋recall回帰ベンチ採点")
    common(p, worktrees=True, alerts=True)
    p.add_argument("--candidate-id", required=True)
    p.add_argument("--bench-tsv", help="recall_bench.py用ベンチTSV（元ファイルは書込禁止・git diff==0を機械アサート）")
    p.add_argument("--skip-bench", action="store_true", help="ベンチ実行を明示的にskipする（既定は--bench-tsv必須）")
    p.add_argument("--hook", default=str(DEFAULT_HOOK))
    p.set_defaults(func=cmd_gate)

    p = sp.add_parser("skip", help="候補を「マージ不適」としてstate.jsonへ直接status=skippedを記録"
                                    "（FR9b終端状態語彙の間隙埋め・2026-07-14追加）")
    # alerts/worktrees=True: 当該candidate_idに未解決ALERTが無いか直接確認するため
    # （リーダー判断・2026-07-14追加＝status=="blocked"チェックだけでは、reconcile
    # 未実行でstatusがまだ"pending"のままの間隙をすり抜けられたため）。
    common(p, state=True, alerts=True, worktrees=True, lock=True)
    p.add_argument("--candidate-id", required=True)
    p.add_argument("--reason", required=True, help="マージ不適と判断した理由（skip_reasonとして記録）")
    p.set_defaults(func=cmd_skip)

    p = sp.add_parser("unskip", help="skippedを手動再評価のためpendingへ戻す（本人裁定・2026-07-14追加）")
    # alerts/worktrees=True: cmd_skipと同じ二重防御（当該candidate_idの未解決ALERT
    # を直接確認）のため。
    common(p, state=True, alerts=True, worktrees=True, lock=True)
    p.add_argument("--candidate-id", required=True)
    p.add_argument("--reason", required=True, help="再評価したい理由（unskip_reasonとして記録・skip_reasonは上書きしない）")
    p.set_defaults(func=cmd_unskip)

    p = sp.add_parser("commit", help="全PASS確認後にworktreeへ1コミット→mainへff-onlyマージ→reconcile自動実行")
    common(p, state=True, worktrees=True, alerts=True, lock=True)
    p.add_argument("--candidate-id", required=True)
    p.add_argument("--verdict-file", help="既定: <worktrees-dir>/<candidate-id>.verdict.json")
    p.add_argument("--gate-file", help="既定: <worktrees-dir>/<candidate-id>.gate.json")
    p.add_argument("--report-id", help="週次検出レポートID（commit trailer記録用）")
    p.add_argument("--lock-retries", type=int, default=3)
    p.add_argument("--allow-bench-skip", action="store_true",
                   help="gate結果のbenchがskippedでもcommitを許可する（既定は拒否＝"
                        "回帰ベンチ未実施での正式マージを防ぐ。手順書外の手動判断が必要な場合のみ使用）")
    p.add_argument("--allow-unregistered-candidate", action="store_true",
                   help="candidate_idがstate.jsonに未登録でもcommitを許可する（既定は拒否＝"
                        "state.json消失/state-file誤指定と意図的な手動候補を区別できないため。"
                        "preflightの--note-a/--note-bによる手動オーバーライドを実際にcommitまで"
                        "進める場合のみ明示的に使用・リーダー判断2026-07-14追加）")
    p.set_defaults(func=cmd_commit)

    p = sp.add_parser("reconcile", help="git logのcandidate_id trailerを正としてstate.jsonを再構成")
    # worktrees=True: blocked/retryからの復帰判定でalert_machine_resolved()を呼ぶため
    # （worktree_dirty種別のtarget_path未記録時のフォールバック先として必要・
    # Codexレビュー指摘・Major対応で追加・2026-07-14）。
    common(p, state=True, alerts=True, worktrees=True, lock=True)
    p.set_defaults(func=cmd_reconcile)

    p = sp.add_parser("alert", help="ALERTレポートを手動生成（通常はcommit/revertが自動生成）")
    common(p, alerts=True)
    p.add_argument("--candidate-id", required=True)
    p.add_argument("--alert-type", required=True, choices=ALERT_TYPES)
    p.add_argument("--command", required=True)
    p.add_argument("--message", required=True)
    p.add_argument("--base-head")
    p.set_defaults(func=cmd_alert)

    p = sp.add_parser("revert", help="コミット後に発覚した欠陥の救済revert（週次自動フロー対象外・人間判断で起動）")
    common(p, alerts=True, lock=True, worktrees=True)
    p.add_argument("--candidate-id", required=True)
    p.add_argument("--reason")
    p.add_argument("--lock-retries", type=int, default=3)
    p.set_defaults(func=cmd_revert)

    return ap


def main(argv=None):
    ap = build_parser()
    args = ap.parse_args(argv)
    try:
        return args.func(args) or 0
    except RuntimeError as e:
        print(f"FAIL: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
