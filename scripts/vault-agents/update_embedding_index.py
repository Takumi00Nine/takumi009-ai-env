#!/usr/bin/env python3
"""外部脳ハイブリッド検索・柱①の埋め込みインデックス差分更新CLI。

scripts/backup-vault.sh の末尾からbest-effortで（毎時）相乗り実行される
（設計書§1柱①・§2.2・§3(b)採用案＝毎時vault-backup相乗り）。単独実行も可能。

処理順序（設計書§2.2）:
  1. 専用writer lock取得（fcntl.flock・既に実行中ならexit 0でskip）
  2. Ollama疎通確認（GET /api/tags）。不通ならログのみexit 0（インデックス更新は
     必須機能ではない＝fail-open。検索側は既存インデックスのままフォールバックする）
  3. 現行インデックス(CURRENT)を「現在の設定(model/model_digest)」で検証読込。
     schema_versionまたはmodel_digest不一致ならフルリビルド（=差分無しとして全件embed）
  4. 現存ファイル一覧（4フォルダ・README.md除く）を基準に、sha256差分検知
     （content hash一致は埋め込み再利用、不一致/新規は再embed。旧インデックスに
     あって現存しないノートは新世代のnotesリストから自然に除外＝削除ノート対応）
  5. 新世代ディレクトリへフルスナップショットを書き、CURRENTをos.replaceで原子更新
  6. 直近3世代以上を残してそれより古い世代を削除

fail-open方針とexit codeの使い分け（Codexレビュー指摘・Major: 旧docstringは全異常を
一律exit 0と記述していたが実装と食い違っていたため明確化）:
  - Ollama不通・モデル未pull（＝処理を「始める前」の疎通確認段階の異常）は
    exit 0（ログのみ・fail-open）。既存インデックスは無変更のまま残るため、検索側は
    古いが壊れていないインデックスを使い続けられる（設計書付録A FR3障害マトリクス）。
    backup-vault.sh側もこのCLI呼び出し自体をbest-effort（非0終了でもbackup-vault.sh
    本体は失敗させない）として扱うため、どちらのexit codeでも運用上の実害は無い。
  - 埋め込みAPI異常（500・timeout等。retry+backoffを使い切った後の
    「処理を始めてから」の失敗）はexit 1で明確に失敗を返す。既存インデックスへの
    書込は一切発生していないため安全（write_generation/publish_currentは全埋め込み
    成功後にのみ呼ばれる）。exit codeを区別するのは、定期実行の監視で「疎通すら
    できない（環境未整備）」と「疎通はできるが処理中に失敗した（一時的な負荷等）」を
    切り分けられるようにするため。
  - ローカル引数の誤り（Vaultが存在しない等）もexit 1で明確に落とす（手動/CI実行での
    設定ミスに気付けるようにするため。定期実行時は--vault等を固定するのでここには
    到達しない想定）。
"""
import argparse
import fcntl
import os
import pathlib
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import embedding_index as ei  # noqa: E402

DEFAULT_VAULT = pathlib.Path.home() / "Data" / "obsidian"
DEFAULT_HTTP_TIMEOUT = 30.0       # 秒。想起フックより余裕を持たせる
DEFAULT_TAGS_TIMEOUT = 3.0        # 秒。疎通確認自体は短時間で見切る
DEFAULT_STALE_LOCK_SECONDS = 3600  # scripts/backup-vault.shと同じ考え方（実行間隔=1時間）
DEFAULT_EMBED_RETRIES = 6         # 実機検証で判明した間欠的EOF/400対策（embed_with_retry参照）
DEFAULT_EMBED_BACKOFF_S = 1.5


def embed_with_retry(text, model, base_url, timeout, retries=DEFAULT_EMBED_RETRIES, backoff_s=DEFAULT_EMBED_BACKOFF_S):
    """1ノート分の埋め込みをretry+backoff付きで取得する（1ノート=1リクエスト・
    embedding_index.ollama_embed()が内部で文字列inputとして送る＝配列送信はしない。

    かつてはバッチ（複数ノートまとめて1リクエスト）送信＋失敗時の二分割フォールバック
    という実装だったが、リーダーの実機検証（2026-07-11・Ollama 0.31.1）により
    「/api/embedの配列(バッチ)入力経路はtruncate:trueを適用せず、長文アイテムが1件
    でもあれば要素数1の配列であっても決定的に400になる」ことが確定した。文字列input
    （単一）ならtruncateが正しく機能するため、根治策は「常に1ノート=1リクエスト・
    文字列inputのみ」（=ollama_embed()側で保証済み）にすることであり、本関数の
    二分割フォールバックは不要になった（削除済み・復活させないこと）。

    retry+backoffは、それとは別の事象（実機で追加検証・2026-07-11後半）への対策として
    残す: 文字列inputに切り替えた後も、複数エージェントが同時稼働する高負荷な開発機上
    では特定のノートに固定されない形でEOF/400が間欠的に発生することを確認した（同一
    ノートを繰り返し単体テストすると成功する時と失敗する時があり、フルビルド実行毎に
    失敗する箇所が変わる＝内容非依存・負荷/タイミング依存の真の非決定性に見えたが、
    その後リーダーがn_batch(既定2048)超過＋プロンプトキャッシュ残留が正体と実機で
    確定させた＝embedding_index.ollama_embed()のoptions.num_ctx/num_batch付与で
    解消済み。それでも尚残り得る一時的な通信障害への保険として、retries/backoffは
    標準より手厚いまま維持する（best-effortの背景ジョブであり次回実行での再試行も
    安全なため、無限リトライにはしない）。

    keep_aliveは意図的に持たない（3巡目Codexレビュー指摘・Major: 「最後の1件だけに
    keep_alive:0を付ける」実装だと、その1件のretry+backoff待機中(最悪約240秒)に
    対話利用の判定が古びてしまう。通常のノート埋め込みリクエストは全て既定keep_alive
    のまま送り、モデルのアンロードはループ完了後に専用の空inputリクエストとして
    1回だけ・送信直前に判定し直して行う設計へ変更した＝_run()内のfinallyブロック
    参照）。
    """
    last_err = None
    for attempt in range(retries + 1):
        try:
            return ei.ollama_embed([text], model=model, base_url=base_url, timeout=timeout)[0]
        except Exception as e:  # noqa: BLE001
            last_err = e
            if attempt < retries:
                time.sleep(backoff_s * (attempt + 1))
    raise last_err


# --- writer lock（fcntl.flockベース。2巡目Codexレビュー指摘・Major: 旧実装は
#     os.O_EXCLのPIDファイル+mtime staleness方式で、stale判定・unlink直前の再確認を
#     どれだけ丁寧にしてもTOCTOU（検証と削除が別操作である以上、原理的に競合window
#     を完全には閉じられない）を抱えていた。flockはOSがプロセスの生死にファイル
#     ロックの生死を直接紐付けるため（保持プロセスが正常終了はもちろんkill -9で
#     クラッシュしても、OSがそのプロセスの全fdを閉じる際に自動でロックを解放する）、
#     「stale判定」という概念自体が不要になり、この問題クラスを構造的に排除できる） ---

def acquire_lock(lock_path, stale_seconds=DEFAULT_STALE_LOCK_SECONDS):
    """flock(LOCK_EX|LOCK_NB)で排他ロックを取得する。取得できれば開いたファイル
    オブジェクト（release_lockへそのまま渡す）、既に別プロセスが保持中ならNoneを返す。
    呼び出し側はNoneの場合exit 0でskipする（backup-vault.shの「既に実行中なのでskip」
    と同方針）。stale_seconds引数は過去バージョンとのCLI互換のため残すが未使用
    （flock方式にはstale概念が存在しない）。

    symlink対策（3巡目Codexレビュー指摘・Major）: lock_pathが（改ざん/破損等で）
    書込可能な任意ファイルへのsymlinkにすり替えられていても、そのリンク先を壊さない
    よう os.O_NOFOLLOW でsymlinkそのものを拒否する（追従しない）。取得したロックの
    判定にファイル内容は使わないため、PID等の書込は行わない（書込先自体が攻撃面に
    なり得るため、診断用途であっても避ける＝最小権限）。
    """
    lock_path = pathlib.Path(lock_path)
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o644)
    except OSError:
        return None  # symlink（ELOOP）・権限エラー等はロック取得失敗として扱う
    f = os.fdopen(fd, "r+")
    try:
        fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        f.close()
        return None
    return f


def release_lock(lock_path, held):
    """acquire_lock()が返したファイルオブジェクトを受け取り、flockを解放してcloseする。
    ロックファイル自体は削除しない（削除するとunlink直後に別プロセスが同じパスへ新規
    作成し、両者が別々のinodeを別々にflockして排他が効かなくなるTOCTOUを生むため。
    ファイルを残したまま毎回開いてflockする方式なら、この種の競合が原理的に起きない）。
    """
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


def parse_args(argv=None):
    ap = argparse.ArgumentParser(description="Vault埋め込みインデックスの差分更新CLI。")
    ap.add_argument("--vault", default=str(DEFAULT_VAULT), help=f"Vaultのルート（既定: {DEFAULT_VAULT}）")
    ap.add_argument("--index-dir", default=None, help="インデックス置き場所（既定: リポジトリ内.cache/vault-embeddings）")
    ap.add_argument("--model", default=ei.DEFAULT_MODEL, help=f"埋め込みモデル名（既定: {ei.DEFAULT_MODEL}）")
    ap.add_argument("--base-url", default=ei.DEFAULT_BASE_URL, help=f"Ollama base URL（既定: {ei.DEFAULT_BASE_URL}）")
    ap.add_argument("--lock-file", default=None, help="writer lockのパス（既定: <index-dir>/writer.lock）")
    ap.add_argument("--stale-lock-seconds", type=float, default=DEFAULT_STALE_LOCK_SECONDS)
    ap.add_argument("--http-timeout", type=float, default=DEFAULT_HTTP_TIMEOUT, help="埋め込みAPI呼び出しのtimeout秒")
    ap.add_argument("--tags-timeout", type=float, default=DEFAULT_TAGS_TIMEOUT, help="疎通確認(GET /api/tags)のtimeout秒")
    ap.add_argument("--keep-generations", type=int, default=ei.DEFAULT_KEEP_GENERATIONS)
    ap.add_argument("--embed-retries", type=int, default=DEFAULT_EMBED_RETRIES,
                     help="1ノートあたりの埋め込みretry回数（高負荷時の間欠的EOF/400対策。既定は本番向けに手厚め。"
                          "テストでは小さくして高速化できる）")
    ap.add_argument("--embed-backoff-s", type=float, default=DEFAULT_EMBED_BACKOFF_S, help="埋め込みretry間のバックオフ基準秒数")
    args = ap.parse_args(argv)
    # 負値は「無限ループ相当のretry」「time.sleep()の例外で元のOllamaエラーが隠れる」
    # といった分かりにくい壊れ方をするため、ここで明確な引数エラーとして弾く
    # （Codexレビュー指摘・Minor）。
    if args.embed_retries < 0:
        ap.error("--embed-retries は0以上を指定してください")
    if args.embed_backoff_s < 0:
        ap.error("--embed-backoff-s は0以上を指定してください")
    return args


def main(argv=None):
    args = parse_args(argv)

    vault_root = pathlib.Path(args.vault).resolve()
    if not vault_root.is_dir():
        print(f"FAIL: vaultが見つかりません: {vault_root}", file=sys.stderr)
        return 1

    index_dir = ei.index_root(args.index_dir)
    index_dir.mkdir(parents=True, exist_ok=True)

    lock_path = pathlib.Path(args.lock_file) if args.lock_file else index_dir / "writer.lock"
    held = acquire_lock(lock_path, stale_seconds=args.stale_lock_seconds)
    if not held:
        print("skip: 既に実行中です（別プロセスがwriter lockを保持）")
        return 0

    try:
        return _run(args, vault_root, index_dir)
    finally:
        release_lock(lock_path, held)


def _run(args, vault_root, index_dir):
    # --- 1. Ollama疎通確認（不通ならログのみexit 0＝fail-open。設計書§2.2） ---
    try:
        tags = ei.fetch_ollama_tags(args.base_url, timeout=args.tags_timeout)
    except Exception as e:  # noqa: BLE001 - Ollama不通の理由は多岐（接続拒否/timeout/DNS等）なので広く捕捉
        print(f"skip: Ollamaに接続できません（次回実行時に再試行します）: {e}")
        return 0

    digest = ei.model_digest_from_tags(tags, args.model)
    if digest is None:
        print(f"skip: モデル {args.model!r} がOllamaにpullされていません（次回実行時に再試行します）")
        return 0

    # このジョブ自身が今回モデルをロードするのか、対話セッション側で既に予熱・ロード
    # 済みだったのかを、実際に埋め込みを始める前に判定しておく（Codexレビュー指摘・
    # Major: 判定を後回しにすると、判定時には既に自分自身の埋め込みリクエストで
    # ロードされてしまい「既にロード済み」と誤判定してしまう）。既にロード済みなら
    # ジョブ終了時にアンロードしない（対話中の想起フックが次回コールドロードになり
    # 500ms予算を圧迫するのを防ぐ・想起フック側の「既定keep_alive維持」方針との
    # 一貫性）。判定できない場合（/api/ps自体が失敗等）も安全側＝アンロードしない
    # （対話セッションへの悪影響を避けることを優先）。
    #
    # 3巡目Codexレビュー指摘・Major（TOCTOU）: この開始時1回きりの判定だけでは、
    # フルビルド（実測約53秒）実行中に対話利用が新たに始まったケースを検知できない。
    # /api/psを実行の最後に再確認する方式は、既に自分自身の直前リクエストで
    # ロード済みになっているため「自分か他者か」を区別できず機能しない（自己汚染）。
    # そこで想起フック側(vector_recall_helper.py)が独立して更新する活動マーカー
    # （embedding_index.touch_activity_marker/recent_activity）を、実際に
    # keep_alive:0を送る直前（_safe_to_unload_now）でも確認する。これにより
    # 「開始時は未ロードでも実行中に対話利用が割り込んだ」ケースも、最後の送信
    # 直前という狭い窓に限ってではあるが検知できる（完全な解消ではないが、実害の
    # 上限も小さい＝想起フック側は失敗してもfail-openでキーワード結果を保持する
    # ため、万一アンロードしてしまっても次のクエリ1回がcold loadになるだけ）。
    should_unload_after_run = False
    try:
        ps_data = ei.fetch_ollama_ps(args.base_url, timeout=args.tags_timeout)
        should_unload_after_run = not ei.model_loaded_in_ps(ps_data, args.model)
    except Exception:  # noqa: BLE001 - 判定できなければアンロードしない安全側へ
        should_unload_after_run = False

    def _safe_to_unload_now():
        """実際にkeep_alive:0を送ってよいかを送信直前に再確認する。開始時点で既に
        ロード済みだった場合は常にFalse。開始時点は未ロードでも、直近
        (既定120秒以内)に想起フックがOllamaを使おうとした形跡があれば、実行中に
        対話利用が割り込んだとみなしFalseにする。"""
        if not should_unload_after_run:
            return False
        return not ei.recent_activity()

    # --- 2. 現行インデックスの検証読込（schema_version/model_digest/num_ctx/num_batch
    #     不一致→フルリビルド。num_ctx/num_batchの検証追加は2026-07-11リーダー指示:
    #     既定値変更（8192→4096等）や環境変数上書きの変更を検知するため） ---
    old_index = None
    rebuild_reason = None
    try:
        old_index = ei.load_index(index_dir, expected_model=args.model, expected_model_digest=digest, retries=0,
                                   expected_num_ctx=ei.EMBED_NUM_CTX, expected_num_batch=ei.EMBED_NUM_BATCH)
    except ei.IndexError_ as e:
        rebuild_reason = str(e)

    old_by_relpath = {}
    if old_index is not None:
        for i, n in enumerate(old_index.notes):
            old_by_relpath[n["relpath"]] = (n["content_hash"], i)

    # --- 3. 現存ファイル一覧を基準にsha256差分検知 ---
    notes_now = ei.list_vault_notes(vault_root)

    if not notes_now and old_index is None:
        print("変更なし（対象ノートが1件もなく、インデックスも未初期化のため何もしません）")
        return 0

    to_embed = []   # [(relpath, embedding_input, content_hash), ...]
    reused = {}     # relpath -> (content_hash, vector)
    unreadable = 0
    truncated_relpaths = set()
    for relpath in notes_now:
        path = vault_root / relpath
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as e:
            unreadable += 1
            print(f"WARN: 読込に失敗したためskipします: {relpath}（{e}）", file=sys.stderr)
            continue
        chash = ei.content_hash(text)
        # truncate検知（2026-07-11リーダー指示）: 差分の有無に関わらず「現在の内容で
        # embedding_inputを構成したらtruncateされるか」を全ノートについて判定する
        # （build_embedding_input自体はHTTPを伴わない軽量処理のため、reused分も含めて
        # 毎回計算してもコストは無視できる）。同時に、to_embedへ渡す埋め込み入力
        # 文字列もここで確定させ、後段の埋め込みループでの再計算を避ける。
        embedding_input = ei.build_embedding_input(relpath, text)
        if ei.is_likely_truncated(embedding_input, num_ctx=ei.EMBED_NUM_CTX):
            truncated_relpaths.add(relpath)
        prev = old_by_relpath.get(relpath)
        if prev is not None and prev[0] == chash:
            reused[relpath] = (chash, old_index.vector(prev[1]))
        else:
            to_embed.append((relpath, embedding_input, chash))

    no_change = (
        old_index is not None
        and not to_embed
        and len(reused) == len(notes_now)
        and len(old_by_relpath) == len(notes_now)  # 削除も無い＝旧件数と現件数が一致
    )
    if no_change:
        print(f"変更なし。インデックス更新をskipします（{len(notes_now)}件・世代={old_index.generation}）")
        return 0

    # --- 4. 新規/変更分を1ノート=1リクエストでOllamaへ（embedding_index.ollama_embed()の
    #     ヘッダコメント・embed_with_retry()のdocstring参照＝配列バッチ送信はしない） ---
    # 通常のノート埋め込みリクエストにはkeep_aliveを一切付与しない（3巡目Codex
    # レビュー指摘・Major: 「最後の1件にだけkeep_alive:0を付ける」実装だと、その1件が
    # retry+backoffで待たされている間（最悪約240秒）に対話利用の判定が古びてしまい、
    # 「送信直前に再確認」という意図と実装が食い違っていた）。モデルのアンロードは
    # ループ完了後（成功/失敗どちらでも）に専用の空inputリクエストとして1回だけ、
    # かつ送信する**その瞬間に**_safe_to_unload_now()を判定してから行う。これにより
    # 判定からアンロード要求送信までの窓を、関数呼出しからHTTP送信開始までの
    # 極短時間へ限定できる。
    newly_embedded = {}  # relpath -> (content_hash, vector)
    dim = old_index.dim if old_index is not None else None
    embed_failure = None
    try:
        for relpath, embedding_input, chash in to_embed:
            try:
                vec = embed_with_retry(embedding_input, args.model, args.base_url, args.http_timeout,
                                        retries=args.embed_retries, backoff_s=args.embed_backoff_s)
            except Exception as e:  # noqa: BLE001
                embed_failure = f"{relpath}: {e}"
                break
            if dim is None:
                dim = len(vec)
            newly_embedded[relpath] = (chash, vec)
    finally:
        # 後始末の要否は「1件でも成功したか」ではなく「to_embedが非空＝embedを試行
        # したか」で判定する（3巡目Codexレビュー指摘・Major: 1件目が全retry失敗した
        # 場合、成功ベースの判定だと後始末が一度も行われない。失敗したリクエストでも
        # モデルロード/プロンプトキャッシュ更新は起こり得るため、試行した事実だけで
        # best-effortのアンロードを試みる）。
        if to_embed and _safe_to_unload_now():
            # 失敗しても無視する（best-effort・本来の成功/失敗判定を上書きしない）。
            try:
                ei.ollama_embed([""], model=args.model, base_url=args.base_url,
                                 timeout=args.tags_timeout, keep_alive=0)
            except Exception:  # noqa: BLE001
                pass

    if embed_failure is not None:
        print(f"FAIL: 埋め込み生成に失敗しました（{embed_failure}・今回の更新は中断・既存インデックスは無変更）",
              file=sys.stderr)
        return 1

    if dim is None:
        # ここに到達するのは「notes_nowが非空なのにto_embedが空でold_indexも無い」という
        # 理論上あり得ない状態のみ（notes_nowが非空ならold_by_relpathが空の場合、全件が
        # to_embedへ入るため）。想定外の状態としてfail-openせずFAILにする。
        print("FAIL: 埋め込み次元を決定できませんでした（想定外の状態）。", file=sys.stderr)
        return 1

    # --- 5. 新世代を「現存ファイル一覧」の順序で書く（削除ノートは自然に除外） ---
    all_notes = []
    for relpath in notes_now:
        if relpath in newly_embedded:
            chash, vec = newly_embedded[relpath]
        elif relpath in reused:
            chash, vec = reused[relpath]
        else:
            continue  # 読込失敗でskipされたノート
        all_notes.append((relpath, chash, vec))

    # この世代に実際に含まれるノートのうち、truncate検知(is_likely_truncated)に
    # 該当したものだけをtruncated_notesとして記録する（読込失敗でskipされたノートは
    # all_notesに無いため自然に除外される）。
    all_relpaths_in_gen = {relpath for relpath, _, _ in all_notes}
    truncated_notes = sorted(truncated_relpaths & all_relpaths_in_gen)

    gen_id = ei.new_generation_id()
    ei.write_generation(index_dir, gen_id, args.model, digest, dim, all_notes,
                         num_ctx=ei.EMBED_NUM_CTX, num_batch=ei.EMBED_NUM_BATCH,
                         truncated_notes=truncated_notes)
    ei.publish_current(index_dir, gen_id)
    ei.prune_old_generations(index_dir, keep=args.keep_generations)

    deleted = len(set(old_by_relpath) - set(notes_now)) if old_index is not None else 0
    msg = (f"インデックス更新完了: 世代={gen_id} 総数={len(all_notes)} "
           f"新規/変更={len(newly_embedded)} 再利用={len(reused)} 削除={deleted}")
    if rebuild_reason:
        msg += f"（フルリビルド理由: {rebuild_reason}）"
    if unreadable:
        msg += f"（読込失敗{unreadable}件はskip）"
    print(msg)
    # truncate検知結果を1行出力する（2026-07-11リーダー指示:「どのノートが実際に
    # 切られたかを観測可能にしたい」＝後段のノート分割衛生ループへの入力）。0件の
    # 場合は出力しない（ログの静穏さを優先・毎時運用で大半は0件のはずのため）。
    if truncated_notes:
        print(f"truncate検知: {len(truncated_notes)}件 ({', '.join(truncated_notes)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
