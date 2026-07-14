#!/usr/bin/env python3
"""外部脳ハイブリッド検索・柱①の想起フック補助（claude/hooks/vault-recall.shからsubprocess
で呼ばれる。設計書§1柱①・§2.1・§3(e)）。

役割: クエリ(プロンプト)を受け取り、Ollama /api/embed で埋め込み→インデックス全件との
cosine類似度を計算→閾値以上の上位候補(relpath+score)をJSONで標準出力へ返す。

時間予算管理（設計書§2.1手順4・決定h=内部timeout 当初500ms暫定→2026-07-12に1000msへ変更・本人指示。理由はvault-recall.sh側コメント参照）:
  bashは自身が起動する直前を基準に別途「sleep 0.5 & kill」のハード停止レースを組む
  （GNU timeout非依存・bash 3.2互換）。本スクリプト側はそれとは独立して、自分の
  プロセス開始直後にtime.monotonic()で絶対deadlineを立て、Ollama呼び出し後（HTTP応答
  受信後）に残予算を確認し、不足していれば総当たり類似度計算を行わず打ち切る
  （「HTTP後に残予算確認・不足なら計算せず打ち切り」を文字通り実装）。
  ※ bashからpythonへ「開始時刻」を厳密なmonotonicクロックとして受け渡す手段が
  macOS標準bash 3.2には無い（サブセカンド精度の時計を追加プロセス無しに取得できない）
  ため、本実装では「予算(ミリ秒)」を引数で受け取り、本プロセス自身のmonotonic()を
  基準に絶対deadlineを立てる方式にした（bash側のハードkillレースと合わせて二重に
  予算超過を防ぐ・実装上の解釈はリーダー確認事項として報告する）。

fail-open方針: 失敗系はすべて非0終了・stdoutは書かない（bash側が単一のfail-open
ログ集約ポイントへ握りつぶす）。標準出力は「成功時のみ」JSON1行を書く契約。

出力形式（成功時・stdout 1行JSON）:
  {"candidates": [{"relpath": "Knowledge/foo.md", "score": 0.62}, ...]}
  スコア降順。件数は--top-n（既定20。bash側でキーワード候補との差分・EXCLUDE_RELPATHS
  除外を取った上で最大3件まで絞るため、除外/重複で有効な候補が枯渇しないよう
  余裕を持たせた件数を返す＝3巡目Codexレビュー指摘・Major対応で8から増量）。

削除済みノート対策（設計書§2.1手順6・付録A FR3ケース6）: インデックスの最大1時間
ラグをカバーするため、候補生成時に--vault配下でファイルの実在確認を行い、既に
削除されたノートは候補から除外する。
"""
import argparse
import json
import pathlib
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import embedding_index as ei  # noqa: E402

DEFAULT_VAULT = pathlib.Path.home() / "Data" / "obsidian"
DEFAULT_BUDGET_MS = 1000.0
# bash側(vault-recall.sh)は受け取った候補から①キーワード候補と重複するもの
# ②EXCLUDE_RELPATHS（起動必読ファイル・Personal追加後で6件）を除外した上で、
# 最大3件(MAX_VECTOR_EXTRA)だけを別枠表示する。top_nが小さすぎると、上位に
# 除外/重複対象が偏っただけで有効な候補がbash側フィルタで枯渇しうる
# （3巡目Codexレビュー指摘・Major: Personal追加でEXCLUDE_RELPATHSが5→6件に増え、
# 旧既定値8では最悪ケース（除外6件+キーワード重複5件が上位を占める）で有効な
# ベクトル候補が1件も残らない事態が起こりうることが判明）。cosine類似度の計算
# 自体は閾値通過分すべてに対して行われるため、top_nを増やすこと自体のコストは
# 「ソート済みリストからより多く切り出すだけ」でほぼ無視できる。キーワード最大
# 5件＋EXCLUDE_RELPATHS想定10件（将来の増加余地）＋必要な3件＋余裕、で20に設定。
DEFAULT_TOP_N = 20

# fail-open理由をbash側の単一集約ログへ渡すための終了コード（意味の区別は主に
# stderrメッセージで行う・bash側はいずれも非0終了として同一の集約処理をする）。
EXIT_BAD_QUERY = 1
EXIT_INDEX_UNAVAILABLE = 2
EXIT_BUDGET_EXHAUSTED_BEFORE_HTTP = 3
EXIT_OLLAMA_FAILED = 4
EXIT_BUDGET_EXHAUSTED_AFTER_HTTP = 5


def parse_args(argv=None):
    ap = argparse.ArgumentParser(description="想起フック用ベクトル検索補助（Ollama embed→類似度上位を返す）。")
    ap.add_argument("--query", default=None, help="クエリ文字列。省略時はstdinから読む")
    ap.add_argument("--vault", default=str(DEFAULT_VAULT), help=f"Vaultのルート（既定: {DEFAULT_VAULT}）")
    ap.add_argument("--index-dir", default=None, help="インデックス置き場所（既定: embedding_index.index_root()）")
    ap.add_argument("--model", default=ei.DEFAULT_MODEL,
                     help=f"インデックス読込時に検証する期待モデル名（既定: {ei.DEFAULT_MODEL}・"
                          "update_embedding_index.pyの--model既定値と同じSSOT=embedding_index.DEFAULT_MODEL）")
    ap.add_argument("--base-url", default=ei.DEFAULT_BASE_URL)
    ap.add_argument("--budget-ms", type=float, default=DEFAULT_BUDGET_MS, help="このプロセス自身の予算(ms)")
    ap.add_argument("--top-n", type=int, default=DEFAULT_TOP_N)
    ap.add_argument("--threshold", type=float, default=ei.DEFAULT_SIM_THRESHOLD)
    return ap.parse_args(argv)


def read_query(args):
    if args.query is not None:
        return args.query
    try:
        # bashのhere-string(`<<< "$PROMPT"`)は末尾に改行を1つ付加するため、それだけを
        # 取り除く（内部の改行やその他の空白は保持する＝クエリの意味を変えないため
        # rstrip("\n")に限定し、strip()は使わない）。
        return sys.stdin.read().rstrip("\n")
    except OSError:
        return ""


def main(argv=None):
    t0 = time.monotonic()
    args = parse_args(argv)
    deadline = t0 + max(args.budget_ms, 0.0) / 1000.0

    query = read_query(args)
    if not query or not query.strip():
        print("クエリが空です", file=sys.stderr)
        return EXIT_BAD_QUERY

    vault_root = pathlib.Path(args.vault)

    try:
        # expected_modelを渡してmodel検証を有効化する（設計書§2.2「読み手はschema_version/
        # model_digest/dim/件数/vectors.binバイト長を検証」違反の是正・Codexレビュー指摘。
        # 従来はNoneを渡しており、embedding_index.load_index()内のmodel検証チェックが
        # 常に省略されていた。ollama_embed()呼び出しには常にindex.model（インデックスに
        # 記録済みのモデル名）を使うため、モデル切替時（例: 0.6b→4b）でも次元さえ一致すれば
        # dim不一致チェックをすり抜け、設定変更後もインデックスが再構築されるまで
        # 永久に旧モデルでクエリembedし続けてしまう（無言の設定ドリフト）。ここで
        # 現在の設定（--model・既定はSSOTのembedding_index.DEFAULT_MODEL）と
        # インデックスのmodelを照合し、不一致ならインデックス側の検証で早期にfail-open
        # させる（EXIT_INDEX_UNAVAILABLE・bash側は次のフルリビルドまでベクトル想起を
        # 諦める＝キーワード想起は影響を受けない）。
        index = ei.load_index(args.index_dir, expected_model=args.model, retries=1)
    except ei.IndexError_ as e:
        print(f"インデックスを読み込めません: {e}", file=sys.stderr)
        return EXIT_INDEX_UNAVAILABLE

    # 残予算が僅少(<10ms)ならHTTP接続自体のオーバーヘッドで確実にtimeoutするため、
    # 試行すらせず打ち切る（remaining<=0の単純比較だと「わずかに正の残余」で
    # urllib側のtimeout例外に化けてしまい、EXIT_OLLAMA_FAILEDと区別しづらくなる）。
    MIN_USEFUL_BUDGET_S = 0.01
    remaining = deadline - time.monotonic()
    if remaining <= MIN_USEFUL_BUDGET_S:
        print("予算超過のためOllama呼び出し前に打ち切りました", file=sys.stderr)
        return EXIT_BUDGET_EXHAUSTED_BEFORE_HTTP

    # 対話セッション側でOllamaを実際に使おうとした形跡としてマーカーを更新する
    # （3巡目Codexレビュー指摘・Major対応: update_embedding_index.pyが実行中の
    # 対話利用を検知できるようにするため。呼び出し自体の成否に関わらず「使おうと
    # した」事実を記録する＝best-effort・失敗しても想起処理は妨げない）。
    ei.touch_activity_marker()

    try:
        vectors = ei.ollama_embed([query], model=index.model, base_url=args.base_url, timeout=remaining)
    except Exception as e:  # noqa: BLE001 - 通信/JSON異常を広く「Ollama失敗」として集約する
        print(f"Ollama /api/embed の呼び出しに失敗しました: {e}", file=sys.stderr)
        return EXIT_OLLAMA_FAILED

    if not vectors or len(vectors[0]) != index.dim:
        print(f"クエリ埋め込みの次元がインデックスと不一致です（query={len(vectors[0]) if vectors else 0} index={index.dim}）",
              file=sys.stderr)
        return EXIT_INDEX_UNAVAILABLE

    # --- HTTP後に残予算確認・不足なら計算せず打ち切り（設計書§2.1手順4） ---
    if time.monotonic() >= deadline:
        print("予算超過のため類似度計算前に打ち切りました", file=sys.stderr)
        return EXIT_BUDGET_EXHAUSTED_AFTER_HTTP

    try:
        vault_root_resolved = vault_root.resolve()
    except OSError as e:
        print(f"Vaultルートの解決に失敗しました: {e}", file=sys.stderr)
        return EXIT_INDEX_UNAVAILABLE

    query_vec = vectors[0]
    scored = []
    excluded_missing = 0
    # 予算超過チェックは総当たりループの途中でも一定間隔ごとに行う（Codexレビュー
    # 指摘・Major: HTTP直後の1回だけでは、ノート数が多い場合にcosine計算・実在確認
    # 自体が予算を超過しうる。CHECK_INTERVALごとに軽くmonotonic()を見るだけなので
    # オーバーヘッドは無視できる）。
    CHECK_INTERVAL = 25
    for i, note in enumerate(index.notes):
        if i % CHECK_INTERVAL == 0 and time.monotonic() >= deadline:
            print("予算超過のため類似度計算を打ち切りました", file=sys.stderr)
            return EXIT_BUDGET_EXHAUSTED_AFTER_HTTP

        relpath = note["relpath"]
        # 削除済みノート対策: インデックスの最大1時間ラグをカバーするため実在確認する
        # （設計書§2.1手順6・付録A FR3ケース6）。embedding_index.load_index()が
        # relpathの形式（SCAN_DIRS直下の.mdのみ）を既に検証しているが、ここでも
        # 解決後パスがVault root配下であることを独立に再確認する（多層防御・
        # Codexレビュー指摘Critical: 改ざん/破損したインデックスに対する縦深防御）。
        candidate = vault_root / relpath
        try:
            resolved = candidate.resolve()
            resolved.relative_to(vault_root_resolved)
        except (OSError, ValueError):
            excluded_missing += 1
            continue
        if not resolved.is_file():
            excluded_missing += 1
            continue
        score = ei.cosine_similarity(query_vec, index.vector(i))
        if score >= args.threshold:
            scored.append((relpath, score))

    # ループ内の周期チェックは「計算を続けるかどうか」の判断であり、ループを最後まで
    # 終えた後のsort/JSON生成は未チェックのまま実行されていた（2巡目Codexレビュー
    # 指摘・Minor）。件数が少なければ無視できるコストだが、一応ここでも確認する
    # （最終防衛線はbash側のkillレースだが、可能な範囲でhelper自身も自律的に早期終了する）。
    if time.monotonic() >= deadline:
        print("予算超過のため出力直前に打ち切りました", file=sys.stderr)
        return EXIT_BUDGET_EXHAUSTED_AFTER_HTTP

    scored.sort(key=lambda t: t[1], reverse=True)
    top = scored[:max(args.top_n, 0)]

    out = {
        "candidates": [{"relpath": rp, "score": round(score, 4)} for rp, score in top],
        "excluded_missing": excluded_missing,
    }
    print(json.dumps(out, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
