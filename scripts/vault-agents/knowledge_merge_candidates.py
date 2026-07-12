#!/usr/bin/env python3
"""Knowledge自律整理・柱②の「検出」専用CLI（週次LaunchAgent・LLM不使用）。

設計: docs/design-vault-hybrid-search.md §1柱②表・§2.3手順1／
要件: requirements-vault-hybrid-search-v2.md FR9・FR9a・FR9b・FR9c・付録A FR10a①②。

責務（本スクリプトが行うのはここまで。マージの実行・敵対的レビュー・commitは
scripts/vault-agents/knowledge_merge.py・merge_quality_gate.py の役目で、本スクリプトは
一切書込を行わない・呼び出しもしない）:
  1. embedding_index.py のCURRENT世代（柱①検索側と共有するインデックス）を読み、
     5フォルダ（embedding_index.SCAN_DIRS＝Knowledge/Preferences/Decisions/Projects/
     Personal）の全ノートペアについてcosine類似度を計算する。
  2. FR10a①②のみを機械評価する（③の矛盾/否定表現差/日付差/固有名詞差/コードブロック差は
     Codexによる敵対的レビューの役目＝ここでは評価しない。設計書3巡目Codexレビューの
     単一論点確認で「FR10a×FR9のLLM不使用」整合が確認済み）:
       ① 類似度が閾値（VAULT_MERGE_SIM_THRESHOLD・既定0.80）以上
       ② 相互最近傍（mutual top-1）。判定が僅差でタイになった場合は
          「候補にしない」（FR10a「判定が割れた場合のデフォルトはマージしない」）。
     マージ対象はKnowledge/内・同フォルダのペアのみ（FR10）。それ以外
     （フォルダ横断ペア、および同フォルダだがKnowledge以外のペア）は
     マージ候補にはせず、FR9c方式の検出ログ（初出日・最終検出日・連続検出回数・
     最大類似度）としてのみ集約する。
  3. 候補ごとに relpath ペアから決定的に導出した安定ID・状態
     （pending/merged/skipped/blocked/retry）を state.json に保持する。
     blocked/retryは次回実行でも無条件で引き継ぐ（FR9b「1件の失敗で再試行対象が
     消える事故を防ぐ」）。merged/skippedは終端状態として次回以降追跡しない。
  4. レポートmd（frontmatterにprocessedを付与しない＝claude/hooks/bootstrap-vault.sh・
     scripts/check-drift.shの未処理レポート検知対象になる。レポート全体への
     processed付与はFR9b「全候補が終端状態になった場合のみ」で、これは実際に候補を
     処理するリーダー側の責務）。

fail-open: 埋め込みインデックスが無い/壊れている場合は何も生成せずログのみで
正常終了する（exit 0。柱①側と異なりKnowledgeマージ検出は必須機能ではなく、
次回のインデクサ実行後に自然に再試行されるため＝タスク指示どおり）。

MIN_INTERVAL_DAYSガードはscripts/vault-agents/fragments_log.py・vault_inventory.pyと
同型（前回レポートから既定日数未満の実行はskip・--forceで無視）。週次運用のため
既定7日。
"""
import argparse
import datetime
import fcntl
import hashlib
import json
import math
import os
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import embedding_index as ei  # noqa: E402
import vault_inventory as vi  # noqa: E402  frontmatter解析(deprecated判定)を再利用・重複実装しない

DEFAULT_VAULT = pathlib.Path.home() / "Data" / "obsidian"
DEFAULT_OUT_DIR = pathlib.Path(os.environ.get(
    "KNOWLEDGE_MERGE_CANDIDATES_LOG_DIR",
    str(pathlib.Path.home() / ".claude" / "logs" / "knowledge-merge-candidates")))

# 週次運用（設計書§3(c)＝専用LaunchAgent・週次）。fragments-log(週次・5日)・
# vault-inventory(隔週・10日)と同型の「次回発火より早い連打を弾く」ガードで、
# 本ジョブのcadence(週次)に合わせた既定値をリーダー指示どおり7日に設定する。
MIN_INTERVAL_DAYS = 7

# FR9c「連続検出回数」の週次cadence許容ギャップ（Codexレビュー指摘・Major対応）。
# 週次(7日)運用で1回分の欠落（LaunchAgent一時停止・祝日等）までは連続とみなし、
# それを超える経過日数はジョブの長期停止からの再開とみなしてストリークをリセット
# する。check-drift.shのFRAGMENTS_LOG_STALE_DAYS(週次+猶予=10日)よりやや広めに
# 取り、通知が出るより先にストリークが切れて過少カウントになるのを避ける。
GAP_RESET_DAYS = 14

# state.json（scripts/vault-agents/knowledge_merge.py も同じファイルを読み書きする）
# の排他ロック。knowledge_merge.py の DEFAULT_LOCK_FILE と意図的に同じパスを使う
# （Codexレビュー指摘・Major: 検出側と実行側が別ロックだとlost updateが起こり得る。
# 週次バッチと対話的マージ処理が同時に走る可能性を排除するため、同一lockファイルで
# 相互排他する）。取得できない場合はfail-open（今回は書込せずexit 0・次回実行に譲る）。
DEFAULT_LOCK_FILE = pathlib.Path.home() / ".claude" / "tmp" / "vault-merge.lock"

# マージ対象はKnowledge/内・同フォルダのみ（FR10改訂）。タプルにしているのは
# 将来Stage 2c等でマージ対象フォルダが増える可能性に備えるため（現時点では1件のみ）。
MERGE_ELIGIBLE_FOLDERS = ("Knowledge",)


def _float_env(name, default, lo=-1.0, hi=1.0):
    """環境変数を有限かつ[lo, hi]範囲内のfloatとして読む。未設定・空・非数値・
    NaN/inf・範囲外はdefaultへfail-openで戻す（embedding_index._positive_int_env()
    と同じ考え方・Codexレビュー指摘・Major/Minor: 以前はfloat()に直接渡しており
    不正な環境変数1つでモジュールimport自体がクラッシュしていたうえ、有限性のみの
    検証では"2"のような範囲外値をそのまま採用してしまっていた）。cosine類似度の
    理論範囲[-1, 1]を既定の許容範囲とする。
    """
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return default
    try:
        value = float(raw.strip())
    except ValueError:
        return default
    if math.isnan(value) or math.isinf(value) or not (lo <= value <= hi):
        return default
    return value


# 類似度閾値（FR10a①・FR7相当のパラメータ化）。要件v2未決事項g「類似度閾値は
# 導入時実測校正」により、この初期値0.80は保守的な仮置き（柱①検索側の想起閾値
# VAULT_EMBED_SIM_THRESHOLD=0.5より意図的に高い＝マージ候補は想起候補よりずっと
# 厳しい基準にする。同一ノート相当の重複を疑うレベルの類似度を要求する）。
DEFAULT_SIM_THRESHOLD = _float_env("VAULT_MERGE_SIM_THRESHOLD", 0.80)

# 相互最近傍の同点判定用の許容誤差。cosine類似度はfloat32(array.array('f'))で
# 保存されたベクトルから計算するため、概念上は完全に同一なベクトル同士でも
# float32量子化により1e-7オーダーの差が生じ得る（Codexレビュー指摘・Major:
# 旧値1e-9はfloat32由来の丸め誤差を吸収する目的を果たせていなかった）。
# 1e-6はfloat32の代表的な相対精度(~1.19e-7)に安全マージンを持たせた値。
TIE_EPSILON = 1e-6

# FR9b: 各候補の状態。merged/skippedは終端（次回以降追跡しない）。
# pending/blocked/retryは非終端（次回実行でも無条件で引き継ぐ）。
TERMINAL_STATUSES = ("merged", "skipped")

STATE_SCHEMA_VERSION = 1


# --- 排他ロック（knowledge_merge.pyと共有・flockベース） -------------------------

def acquire_lock(lock_path):
    """非blockingでflock排他ロックを取得する。取得できればファイルオブジェクトを、
    できなければNoneを返す（knowledge_merge.py acquire_lock()と同じ考え方・
    update_embedding_index.pyのwriter lockとも同型）。
    """
    lock_path = pathlib.Path(lock_path)
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR, 0o644)
        f = os.fdopen(fd, "r+")
    except OSError:
        return None
    try:
        fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        f.close()
        return None
    return f


def release_lock(held):
    if held is None:
        return
    try:
        fcntl.flock(held.fileno(), fcntl.LOCK_UN)
    finally:
        held.close()


# --- 補助関数 ------------------------------------------------------------------

def folder_of(relpath):
    """relpath（例: "Knowledge/foo.md"）の先頭フォルダ名を返す。
    embedding_index.RELPATH_REがSCAN_DIRS直下1階層のみを許容するため、
    "/"で1回splitするだけで安全に取れる。
    """
    return relpath.split("/", 1)[0]


def is_active_note(vault_root, relpath):
    """候補生成の対象として扱ってよいノートかを返す。以下のいずれかに該当すれば
    False（対象外）:
      - 実ファイルが存在しない（embedding_index.pyのインデックス更新には最大1時間
        ラグがあり、削除直後のノートがまだインデックスに残っている可能性がある。
        柱①検索側FR3「削除済みノートは候補生成時に存在確認して除外」と同じ防御を
        検出側でも行う＝Codexレビュー指摘・Minor）
      - symlink（Vault外ファイルへの参照可能性を排除する多層防御。
        embedding_index.pyが世代ディレクトリ/meta.json/vectors.binに対して行う
        symlink拒否と同じ考え方をここでも踏襲する）
      - 既に非破壊マージ済み（frontmatter `deprecated: true`）。knowledge_merge.py
        がマージを確定させると原ノート2件は削除されず`deprecated: true`+
        `superseded_by:`付きスタブとして残る（FR12）。スタブ化済みの2件が今後も
        類似度条件を満たし続け、際限なく同じペアを「レビュー待ち候補」として
        再生成し続けるのを防ぐ（設計書に明記された要件ではないが、非破壊マージ
        方式の帰結として本スクリプトが担うべき自明な安全策と判断。実装中の判断＝
        最終報告で申告）。

    読み取り失敗（権限等）もFalse（対象外）に倒す。柱①検索側は「見逃しより誤検出
    を許容する」fail-open方針だが、本スクリプトは検出のみでVault書込を一切行わない
    ため、除外側に倒しても実害は「本来出てもよい候補が1件出ない」程度に留まる
    （Codexレビュー指摘対応・実装判断）。
    """
    p = pathlib.Path(vault_root) / relpath
    if p.is_symlink():
        return False
    if not p.is_file():
        return False
    try:
        text = p.read_text(encoding="utf-8")
    except OSError:
        return False
    fm, _ = vi.parse_frontmatter(text)
    val = fm.get("deprecated")
    if isinstance(val, str) and val.strip().lower() == "true":
        return False
    return True


def stable_pair_id(relpath_a, relpath_b):
    """両ノートrelpathの正規化ペア（アルファベット順にソート）から決定的に
    候補IDを導出する。ノートの発見順序・インデックス内の並び順に依存しない
    （インデックスが再構築されても同じペアには常に同じIDが振られる＝
    state.jsonでの継続追跡に必須）。

    sha256の全桁(64 hex文字)をそのままIDに使う（Codexレビュー指摘・Minor:
    以前は先頭12文字＝48bitのみ使用しており、衝突時にdict代入で一方が無言で
    上書きされ得た。3年ノーメンテ運用で検知不能な衝突を避けるため、表示の
    簡潔さより衝突耐性を優先する）。
    """
    a, b = sorted([relpath_a, relpath_b])
    digest = hashlib.sha256(f"{a}\n{b}".encode("utf-8")).hexdigest()
    return f"cand-{digest}"


def pairwise_similarities(index):
    """インデックス内の全ノートペア(i<j)のcosine類似度を辞書 (i,j)->sim で返す。"""
    n = len(index)
    vectors = [index.vector(i) for i in range(n)]
    sims = {}
    for i in range(n):
        for j in range(i + 1, n):
            sims[(i, j)] = ei.cosine_similarity(vectors[i], vectors[j])
    return sims


def sim_of(sims, i, j):
    return sims[(i, j)] if i < j else sims[(j, i)]


def best_neighbor(i, candidates, sims, threshold):
    """candidates（iを含まない集合）の中でiに最も類似度が高いものを1件返す。
    戻り値は (best_j, best_sim) または None（候補なし／同点タイ／閾値未満）。

    同点タイの判定はTIE_EPSILON以内の差を「区別できない」とみなす。1位が
    確定できない場合はNoneを返す（FR10a「判定が割れた場合のデフォルトは
    マージしない」＝相互最近傍を判定できないため必然的に候補から外れる）。
    """
    best_j = None
    best_sim = None
    tie = False
    for j in candidates:
        s = sim_of(sims, i, j)
        if best_sim is None or s > best_sim + TIE_EPSILON:
            best_sim = s
            best_j = j
            tie = False
        elif abs(s - best_sim) <= TIE_EPSILON:
            tie = True
    if best_j is None or tie or best_sim < threshold:
        return None
    return best_j, best_sim


def mutual_pairs_over(indices, neighbor_fn):
    """indices内の各ノートについてneighbor_fn(i)（best_neighbor相当）を呼び、
    相互に最近傍同士(mutual top-1)であるペアを (i, j, sim)（i<j）のリストで返す。
    """
    best = {}
    for i in indices:
        best[i] = neighbor_fn(i)
    pairs = []
    for i in indices:
        nb = best.get(i)
        if nb is None:
            continue
        j, sim = nb
        nb2 = best.get(j)
        if nb2 is not None and nb2[0] == i and i < j:
            pairs.append((i, j, sim))
    return pairs


def detect_pairs(index, vault_root, threshold):
    """今回の実行で検出したペアを (merge_detected, other_detected) の2 dict で返す。
    どちらも candidate_id -> レコードdict（"first_seen"/"last_seen"等の時系列
    フィールドは含まない＝呼び出し側がstate.jsonとマージする際に付与する）。

    merge_detected: Knowledge同フォルダ・FR10a①②通過（マージ・レビュー対象候補）。
      レコード: {"note_a", "note_b", "folder", "similarity"}
    other_detected: フォルダ横断（kind="cross_folder"）または同フォルダだが
      Knowledge以外（kind="same_folder_other"）・FR10a①②通過（マージ対象外・
      観測のみ＝FR9c）。
      レコード: {"note_a", "note_b", "kind", "folder_a", "folder_b", "similarity"}
    """
    notes = index.notes
    n = len(notes)
    # 削除済み/symlink/スタブ化済み(deprecated: true)のノートは候補生成の対象から
    # 除外する（is_active_note()のdocstring参照）。
    active = [i for i in range(n) if is_active_note(vault_root, notes[i]["relpath"])]
    sims = pairwise_similarities(index)

    folder_groups = {}
    for i in active:
        folder_groups.setdefault(folder_of(notes[i]["relpath"]), []).append(i)

    merge_detected = {}
    other_detected = {}

    # --- 同フォルダ内の相互最近傍（②「同フォルダ内」・FR10a） -------------------
    for folder, indices in folder_groups.items():
        if len(indices) < 2:
            continue

        def _same_folder_neighbor(i, _indices=indices):
            cands = [j for j in _indices if j != i]
            return best_neighbor(i, cands, sims, threshold)

        for i, j, sim in mutual_pairs_over(indices, _same_folder_neighbor):
            a, b = sorted([notes[i]["relpath"], notes[j]["relpath"]])
            cid = stable_pair_id(a, b)
            if folder in MERGE_ELIGIBLE_FOLDERS:
                merge_detected[cid] = {"note_a": a, "note_b": b, "folder": folder, "similarity": sim}
            else:
                other_detected[cid] = {
                    "note_a": a, "note_b": b, "kind": "same_folder_other",
                    "folder_a": folder, "folder_b": folder, "similarity": sim,
                }

    # --- フォルダ横断の相互最近傍（観測のみ・FR9c） -----------------------------
    def _cross_folder_neighbor(i, _active=active):
        folder = folder_of(notes[i]["relpath"])
        cands = [j for j in _active if folder_of(notes[j]["relpath"]) != folder]
        return best_neighbor(i, cands, sims, threshold)

    for i, j, sim in mutual_pairs_over(active, _cross_folder_neighbor):
        a, b = sorted([notes[i]["relpath"], notes[j]["relpath"]])
        cid = stable_pair_id(a, b)
        other_detected[cid] = {
            "note_a": a, "note_b": b, "kind": "cross_folder",
            "folder_a": folder_of(a), "folder_b": folder_of(b), "similarity": sim,
        }

    return merge_detected, other_detected


# --- state.json 読み書き --------------------------------------------------------

class StateError(Exception):
    """既存のstate.jsonが読めるが内容が壊れている/想定外の形式であることを表す
    （Codexレビュー指摘・Major: 以前はここで空状態へ静かに作り直しており、
    knowledge_merge.py側が書き込んだblocked/retryや監査用フィールドが永久に
    消失し得た。呼び出し側(main())はこの例外を「今回は書込せずexit 0」の
    fail-openシグナルとして扱う＝壊れたファイルを黙って上書きしない）。
    """


def empty_state():
    return {"schema_version": STATE_SCHEMA_VERSION, "candidates": {}, "detections": {}}


def load_state(path):
    """state.jsonを読み込む。ファイルが存在しない（初回実行）場合のみ空状態から
    始める。ファイルが存在するのに読込/解析に失敗する・形式が想定外・
    schema_versionが不一致の場合はStateErrorを送出する（既存データを破棄して
    空状態へ静かにフォールバックしない＝Codexレビュー指摘・Major対応）。

    schema_versionは「キーが存在するなら現行STATE_SCHEMA_VERSIONと一致必須」
    「キー自体が無ければ不正（本スクリプトが書くstate.jsonは常にこのキーを含む
    ため、欠如は破損/改ざんの兆候）」とする（Codexレビュー指摘・Major対応:
    以前は存在確認なしに現行値へ上書きしており、将来schemaが変わった場合に
    互換性の無いデータを誤って読み進めてしまう可能性があった）。
    """
    p = pathlib.Path(path)
    if not p.is_file():
        return empty_state()
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        raise StateError(f"state.jsonの読込/解析に失敗しました: {e}") from e
    if not isinstance(data, dict):
        raise StateError("state.jsonの形式が不正です（オブジェクトではありません）")
    if "schema_version" not in data:
        raise StateError("state.jsonに'schema_version'がありません（破損/改ざんの可能性）")
    if data["schema_version"] != STATE_SCHEMA_VERSION:
        raise StateError(
            f"state.jsonのschema_versionが不一致です（index={data['schema_version']!r} "
            f"expected={STATE_SCHEMA_VERSION}）")
    if "candidates" in data and not isinstance(data["candidates"], dict):
        raise StateError("state.jsonの'candidates'がオブジェクトではありません")
    if "detections" in data and not isinstance(data["detections"], dict):
        raise StateError("state.jsonの'detections'がオブジェクトではありません")
    data.setdefault("candidates", {})
    data.setdefault("detections", {})
    return data


def save_state(path, state):
    """一時ファイルに書いてからos.replaceで原子更新する（embedding_index.py
    write_generation()/publish_current()と同じ考え方＝更新途中の中途半端な内容を
    読み手に見せない）。"""
    p = pathlib.Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.parent / f".{p.name}.tmp-{os.getpid()}"
    tmp.write_text(json.dumps(state, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")
    os.replace(str(tmp), str(p))


def merge_candidate_state(existing, detected, today_iso):
    """Knowledgeマージ・レビュー待ち候補のstate.jsonセクションを更新する。

    ルール（FR9b）:
      - 既存が終端状態(merged/skipped)なら、state.json内にtombstoneとして残しつつ
        （キー自体は消さない）、再検出されても状態を変更しない＝既に処理済みの
        ペアとしてレポート表示・件数からは除外する（active_candidates_only()参照。
        tombstoneを残さずキー自体を消すと、原ノートが変更されない限り次回実行で
        即座に新規pendingとして復活してしまう＝Codexレビュー指摘・Major対応）。
        候補IDはrelpathペアのみに基づく（content_hashを含まない）ため、
        一度merged/skippedになったペアは、その後どちらかのノートの本文が
        大きく書き換えられて実質的に別内容になったとしても、同じrelpathの
        組み合わせである限り永久にtombstoneのまま再提案されない（特にskippedは
        「一度reject＝将来にわたって再評価しない」という保守的な既定になっている。
        内容変更を機に再評価させたい場合はcontent_hashをtombstoneに含める設計へ
        変更する必要があり、これは実装範囲外の判断としてリーダーへ確認する）。
      - 既存がpending/blocked/retry（非終端）なら、今回再検出されたか否かに
        関わらず必ず引き継ぐ（「1件の失敗で再試行対象が消える事故を防ぐ」）。
        既存レコードの未知フィールド（knowledge_merge.py等が追加した監査用
        情報）もdict(rec)でそのままコピーし、消さない。statusはこのスクリプト
        からは変更しない（状態遷移はマージ実行側の責務）。
      - 既存に無い新規検出はstatus="pending"で追加する。
    """
    # 終端状態(merged/skipped)もtombstoneとしてstate.jsonに残す（キー自体を削除
    # しない）。Codexレビュー指摘・Major: 以前は終端状態を辞書からdropしていたため、
    # 同じ実行のdetectedループで（is_active_note()のdeprecatedチェックが効かない
    # "skipped"のように原ノートが変更されないケースで）即座に新規pendingとして
    # 再生成されてしまっていた。tombstoneを残しておき、detected側の処理で
    # 「既存が終端状態なら無視する」ことで、原ノートが変更されない限り再提案しない。
    new_candidates = {cid: dict(rec) for cid, rec in existing.items()}

    for cid, rec in detected.items():
        sim = rec["similarity"]
        if cid in new_candidates:
            cur = new_candidates[cid]
            if cur.get("status") in TERMINAL_STATUSES:
                continue  # tombstone: 再検出されても終端状態からは復活させない
            cur["last_seen"] = today_iso
            cur["similarity"] = round(sim, 6)
            cur["max_similarity"] = round(max(float(cur.get("max_similarity", sim)), sim), 6)
        else:
            new_candidates[cid] = {
                "note_a": rec["note_a"],
                "note_b": rec["note_b"],
                "folder": rec["folder"],
                "status": "pending",
                "similarity": round(sim, 6),
                "max_similarity": round(sim, 6),
                "first_seen": today_iso,
                "last_seen": today_iso,
            }
    return new_candidates


def active_candidates_only(candidates):
    """レポート表示・件数カウント用に、終端状態(tombstone)を除いた候補のみを返す。
    state.json自体にはtombstoneを残したまま（merge_candidate_state()参照）、
    表示側だけでフィルタする。
    """
    return {cid: rec for cid, rec in candidates.items() if rec.get("status") not in TERMINAL_STATUSES}


def _date_gap_days(prev_iso, today_iso):
    """prev_iso(YYYY-MM-DD)からtoday_isoまでの経過日数を返す。パース不能なら
    Noneを返す（呼び出し側はNoneを「ギャップ不明＝ストリーク断絶扱い」とする）。
    """
    try:
        prev_date = datetime.date.fromisoformat(prev_iso)
        today_date = datetime.date.fromisoformat(today_iso)
    except (TypeError, ValueError):
        return None
    return (today_date - prev_date).days


def merge_detection_state(existing, detected, today_iso, gap_reset_days=GAP_RESET_DAYS):
    """フォルダ横断／同フォルダ非Knowledgeの検出ログ（観測専用・FR9c）を更新する。

    候補ごとの状態(pending等)は持たない（マージ対象にならないため）。
    「一定期間継続したものだけ」という要件文言（"連続検出回数"というフィールド名の
    直訳）に合わせ、今回再検出されなかったペアはストリークが途切れたとみなして
    追跡を打ち切る（除去）。これは実装判断であり、"継続"の解釈を「累積」ではなく
    「連続」と読んだ結果である＝最終報告で申告。

    連続検出回数の加算ルール（Codexレビュー指摘・Major対応）:
      - 同一暦日内での複数回実行（--force連打・手動kickstart連打等）では増やさない
        （last_seenが今日の日付と一致する＝同日内の再検出）。
      - 前回last_seenから今日までの経過日数が0<gap<=gap_reset_days（既定14日＝
        週次cadence1回分の欠落まで許容する猶予）なら+1する。
      - それ以外（経過日数が長すぎる＝ジョブの長期停止からの再開・日付解析不能・
        未来日時等）はストリーク断絶とみなし、consecutive_detections・first_seen
        ともに「今回を初出」として1へリセットする（以前は経過日数に関わらず
        一律+1していたため、ジョブが数ヶ月止まっていた後の再開でも連続検出回数が
        水増しされ得た）。
    """
    new_detections = {}
    for cid, rec in detected.items():
        sim = rec["similarity"]
        prev = existing.get(cid)
        if isinstance(prev, dict) and prev.get("note_a") == rec["note_a"] and prev.get("note_b") == rec["note_b"]:
            prev_last_seen = prev.get("last_seen")
            gap = _date_gap_days(prev_last_seen, today_iso)
            if prev_last_seen == today_iso:
                first_seen = prev.get("first_seen", today_iso)
                consecutive = int(prev.get("consecutive_detections", 1))
            elif gap is not None and 0 < gap <= gap_reset_days:
                first_seen = prev.get("first_seen", today_iso)
                consecutive = int(prev.get("consecutive_detections", 0)) + 1
            else:
                first_seen = today_iso
                consecutive = 1
            max_sim = max(float(prev.get("max_similarity", sim)), sim)
        else:
            first_seen = today_iso
            consecutive = 1
            max_sim = sim
        new_detections[cid] = {
            "note_a": rec["note_a"],
            "note_b": rec["note_b"],
            "kind": rec["kind"],
            "folder_a": rec["folder_a"],
            "folder_b": rec["folder_b"],
            "similarity": round(sim, 6),
            "max_similarity": round(max_sim, 6),
            "first_seen": first_seen,
            "last_seen": today_iso,
            "consecutive_detections": consecutive,
        }
    return new_detections


# --- レポート生成 ---------------------------------------------------------------

def _wikilink(relpath):
    return f"[[{relpath[:-3]}]]" if relpath.endswith(".md") else f"[[{relpath}]]"


def build_report(today, candidates, detections, threshold):
    lines = []
    lines.append("---")
    lines.append(f"date: {today.isoformat()}")
    lines.append("tags: [knowledge-merge-candidates, report]")
    lines.append("project: external-brain")
    lines.append("---")
    lines.append("")
    lines.append(f"# Knowledge統合候補 週次検出 {today.isoformat()}")
    lines.append("")
    lines.append(
        "自動生成（`work/takumi009-ai-env/scripts/vault-agents/knowledge_merge_candidates.py`）。"
        f"LLM不使用・決定的処理のみ（類似度閾値={threshold}・相互最近傍のみを評価）。"
        "**このレポートに載る候補はFR10a①②（類似度閾値＋相互最近傍）を機械的に通過した"
        "「レビュー待ち候補」であり、マージが確定したものではない**。③（矛盾・否定表現差・"
        "日付差・固有名詞差・コードブロック差の敵対的レビュー）はこの後リーダーが"
        "`knowledge_merge.py`経由でCodexに評価させて初めて判定される。"
    )
    lines.append("")
    lines.append("処理手順: [[Preferences/knowledge-merge-procedure]]")
    lines.append("")
    lines.append("## Knowledgeマージ・レビュー待ち候補")
    lines.append("")
    if candidates:
        lines.append("| candidate_id | note_a | note_b | 類似度 | 最大類似度 | 状態 | 初出日 | 最終検出日 |")
        lines.append("|---|---|---|---|---|---|---|---|")
        for cid in sorted(candidates):
            rec = candidates[cid]
            lines.append(
                f"| {cid} | {_wikilink(rec['note_a'])} | {_wikilink(rec['note_b'])} |"
                f" {rec['similarity']:.4f} | {rec['max_similarity']:.4f} | {rec['status']} |"
                f" {rec['first_seen']} | {rec['last_seen']} |"
            )
    else:
        lines.append("（今回・繰り越し含め対象候補なし）")
    lines.append("")
    lines.append("## フォルダ横断・同フォルダ(Knowledge以外)の検出ログ（観測のみ・マージ対象外／FR9c）")
    lines.append("")
    if detections:
        lines.append("| candidate_id | note_a | note_b | 種別 | 初出日 | 最終検出日 | 連続検出回数 | 最大類似度 |")
        lines.append("|---|---|---|---|---|---|---|---|")
        for cid in sorted(detections):
            rec = detections[cid]
            lines.append(
                f"| {cid} | {_wikilink(rec['note_a'])} | {_wikilink(rec['note_b'])} | {rec['kind']} |"
                f" {rec['first_seen']} | {rec['last_seen']} | {rec['consecutive_detections']} |"
                f" {rec['max_similarity']:.4f} |"
            )
    else:
        lines.append("（対象なし）")
    lines.append("")
    return "\n".join(lines)


# --- CLI -------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--vault", default=str(DEFAULT_VAULT), help=f"Vaultのルート（既定: {DEFAULT_VAULT}）")
    ap.add_argument("--index-dir", default=None, help="埋め込みインデックス置き場所（既定: embedding_index.index_root()）")
    ap.add_argument("--out-dir", default=str(DEFAULT_OUT_DIR), help=f"レポート/state.json出力先（既定: {DEFAULT_OUT_DIR}）")
    ap.add_argument("--sim-threshold", type=float, default=DEFAULT_SIM_THRESHOLD, help="FR10a①の類似度閾値")
    ap.add_argument("--min-interval-days", type=int, default=MIN_INTERVAL_DAYS)
    ap.add_argument("--lock-file", default=str(DEFAULT_LOCK_FILE),
                     help="state.jsonの排他ロック（scripts/vault-agents/knowledge_merge.pyと共有・既定: "
                          f"{DEFAULT_LOCK_FILE}）")
    ap.add_argument("--force", action="store_true", help="MIN_INTERVAL_DAYSガードを無視して強制実行する")
    args = ap.parse_args(argv)

    # CLI引数のバリデーション（Codexレビュー指摘・Minor: argparseのtype=floatは
    # "nan"/"inf"等もそのまま通してしまい、不正値のまま閾値ゲートが実質無効化
    # されたり判定不能になり得た。不正なら既定値へfail-openでフォールバックする）。
    sim_threshold = args.sim_threshold
    if math.isnan(sim_threshold) or math.isinf(sim_threshold) or not (-1.0 <= sim_threshold <= 1.0):
        print(f"警告: --sim-threshold の値が不正です({sim_threshold!r})。既定値{DEFAULT_SIM_THRESHOLD}にフォールバックします。")
        sim_threshold = DEFAULT_SIM_THRESHOLD

    min_interval_days = args.min_interval_days
    if min_interval_days <= 0:
        print(f"警告: --min-interval-days の値が不正です({min_interval_days})。既定値{MIN_INTERVAL_DAYS}にフォールバックします。")
        min_interval_days = MIN_INTERVAL_DAYS

    out_dir = pathlib.Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    state_path = out_dir / "state.json"

    today = datetime.date.today()

    # 重複実行防止ガード（fragments_log.py/vault_inventory.pyと同型）。
    reports = sorted(out_dir.glob("20*.md"))
    if reports and not args.force:
        last = datetime.date.fromisoformat(reports[-1].stem[:10])
        if (today - last).days < min_interval_days:
            print(f"skip: 前回レポート {last} から {min_interval_days} 日未満")
            return 0

    try:
        index = ei.load_index(args.index_dir, expected_model=None, retries=1)
    except ei.IndexError_ as e:
        # fail-open（設計書§1「インデックス不在は生成せず正常終了＋ログ」）。
        # Knowledgeマージ検出は柱①検索と異なり必須機能ではなく、次回の
        # インデクサ(update_embedding_index.py)実行後に自然に再試行される。
        print(f"skip: 埋め込みインデックスを読み込めません（{e}）。次回のインデクサ実行後に再試行してください。")
        return 0

    # インデックス読込・検出計算はstate.jsonに触れないため、ロック取得前に済ませる
    # （ロック保持時間を最小化する）。state.jsonの読込・更新・保存・レポート生成
    # までを通してロック内で行う（Codexレビュー指摘・Major: knowledge_merge.py
    # （対話的マージ処理）と排他ロックを共有していないと同時実行時にlost update
    # が起こり得た。さらに、レポート生成をロック外にすると、保存直後・レポート
    # 書出前の一瞬にknowledge_merge.py側がstate.jsonを更新した場合、レポート内容
    # とstate.jsonの間に不整合が生じ得るため、レポート書出まで同じロックで守る）。
    merge_detected, other_detected = detect_pairs(index, args.vault, sim_threshold)
    today_iso = today.isoformat()

    lock_path = pathlib.Path(args.lock_file)
    held = acquire_lock(lock_path)
    if held is None:
        print(f"skip: state.jsonの排他ロックを取得できません（他プロセスが処理中の可能性）: {lock_path}")
        return 0
    try:
        try:
            state = load_state(state_path)
        except StateError as e:
            # fail-open（Codexレビュー指摘・Major: 壊れたstate.jsonを黙って空状態へ
            # 作り直すと、他プロセスが書き込んだblocked/retry・監査情報が永久消失
            # し得た。今回は何も書き込まずexit 0とし、手動での復旧判断に委ねる）。
            print(f"skip: {e}（state.jsonの内容は変更していません。手動確認が必要です）")
            return 0

        new_candidates = merge_candidate_state(state.get("candidates", {}), merge_detected, today_iso)
        new_detections = merge_detection_state(state.get("detections", {}), other_detected, today_iso)

        state["schema_version"] = STATE_SCHEMA_VERSION
        state["candidates"] = new_candidates
        state["detections"] = new_detections
        state["updated_at"] = today_iso
        save_state(state_path, state)

        # レポート・ログ表示は終端状態(tombstone)を除いたアクティブな候補のみ
        # （active_candidates_only()参照。state.json自体にはtombstoneを残す）。
        active_candidates = active_candidates_only(new_candidates)
        report_text = build_report(today, active_candidates, new_detections, sim_threshold)
        out_path = out_dir / f"{today_iso}.md"
        tmp_report = out_path.parent / f".{out_path.name}.tmp-{os.getpid()}"
        tmp_report.write_text(report_text, encoding="utf-8")
        os.replace(str(tmp_report), str(out_path))
    finally:
        release_lock(held)

    print(
        f"レポート生成: {out_path}（レビュー待ち候補 {len(active_candidates)} 件・"
        f"検出ログ {len(new_detections)} 件）"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
