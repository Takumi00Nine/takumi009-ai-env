#!/usr/bin/env python3
"""AC4性能計測ツール: claude/hooks/vault-recall.sh の実測レイテンシをcold/warm別に
p50/p95で計測する（設計書 docs/design-vault-hybrid-search.md §4「AC4はp50/p95実測
（cold/warm別・ノート数別）を検収の必須完了条件（概算不可・実測必須）」）。

使い方一覧＝Vault: Knowledge/tools-inventory.md／運用導線＝Projects/vault-hybrid-search.md

このスクリプト自体はロジックを一切再実装しない。実物のclaude/hooks/vault-recall.sh
をsubprocessで実際に叩き、壁時計時間を計測するだけ（scripts/vault-agents/recall_bench.py
と同じ「実フックを叩く」方針）。ヒット率の採点はrecall_bench.pyの役目であり、本ツールは
レイテンシのみを扱う。

前提: 対象Vaultの埋め込みインデックスが事前に構築されていること
  （scripts/vault-agents/update_embedding_index.py --vault <vault> を先に実行）。

cold/warmの考え方:
  Ollamaはモデルを一定時間(既定keep_alive=5分)メモリに保持し、以降のリクエストは
  高速に応答する。「cold」とは直近でそのモデルへのリクエストが無く、初回ロードの
  オーバーヘッドが乗る状態。本ツールは自動でモデルをアンロードしない（実行環境や
  Ollamaのバージョンでアンロード手段が変わるため）。cold計測をしたい場合は、
  計測前に運用者が `curl -s localhost:11434/api/generate -d
  '{"model":"<model>","keep_alive":0}'` 等でアンロードしてから
  `--cold-runs N`（既定1）で先頭N件をcoldバケットとして分離計測する。

使い方:
  # 1) 対象Vaultのインデックスを事前構築
  python3 scripts/vault-agents/update_embedding_index.py --vault ~/Data/obsidian

  # 2) ベンチTSV（recall_bench.pyと同形式・質問文<TAB>期待ノート。期待ノート列は
  #    本ツールでは使わないため何が書かれていてもよい）を使って計測
  python3 scripts/vault-agents/measure_recall_latency.py \\
      docs/vault-recall-benchmark.tsv --cold-runs 1

  # ノート数別に見たい場合は --vault違い（サブセットVault）で複数回実行して比較する。

  --json で機械可読出力（リーダーの結合検証レポートへの転記用）。
  --disable-vector でVAULT_RECALL_DISABLE_VECTOR=1をhookへ渡し、キーワードのみモードの
  レイテンシも比較計測できる（AC1「無劣化」確認の补助データにもなる）。
"""
import argparse
import json
import os
import pathlib
import statistics
import subprocess
import sys
import tempfile
import time

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
DEFAULT_HOOK = REPO_ROOT / "claude" / "hooks" / "vault-recall.sh"
DEFAULT_VAULT = pathlib.Path.home() / "Data" / "obsidian"
DEFAULT_TIMEOUT = 10.0  # 秒。実運用のhook timeout(settings.json=2秒)より余裕を持たせる


def read_prompts(bench_tsv):
    """recall_bench.py と同形式のTSVから質問文（1列目）だけを取り出す。
    空行・#始まりはskip。壊れた行（列が無い）もWARNしてskipする。
    """
    prompts = []
    text = pathlib.Path(bench_tsv).read_text(encoding="utf-8")
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.rstrip("\r")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split("\t")
        if not parts[0].strip():
            print(f"WARN: {bench_tsv}:{lineno}: 質問文が空のためskipします", file=sys.stderr)
            continue
        prompts.append(parts[0].strip())
    return prompts


# claude/hooks/vault-recall.sh の log_error() は「柱①/②helperのfail-open(skip)」だけで
# なく、「パイプラインは正常に完走した上での事実記録」にも使い回されている（同ファイル
# 該当コメント参照）: ①削除済みノートのベクトル残存除外（インデックスの最大1時間ラグ・
# 付録A FR3ケース6）は"候補提示自体は正常"と明記した上でlog_vector_fail_openを使わず
# 直接log_errorしている、②読取不可ノート件数（"...件のノートを読み取れませんでした
# （権限不足の可能性・ファイル名キーのみで照合しました）"）もパイプライン自体は完走し
# ている。これらは応答が縮退した結果ではなく通常速度の正常完走の一部であるため、
# fail-open除外の対象から外す（Codexレビュー指摘・Major対応: 全ERROR行を無差別に
# fail-open扱いすると、実運用でごくありふれた「読取不可ノート数件」「削除済みノート
# 1件残存」のような無害な事実記録付きの正常応答までもcold/warm統計から除外してしまい、
# AC4実測の母数を不当に減らす）。既知の無害メッセージだけを許可リスト化し、それ以外の
# ERROR行は安全側に倒して全てfail-open扱いにする（将来log_error()の呼び出し箇所が
# 増えても、無害だと明示的に確認できたものだけを個別に除外する方針）。
_BENIGN_ERROR_MARKERS = (
    "候補提示自体は正常",                # 削除済みノート残存の除外（付録A FR3ケース6）
    "ファイル名キーのみで照合しました",    # 読取不可ノートがあってもパイプラインは完走している
)


def _is_benign_error_message(message):
    return any(marker in message for marker in _BENIGN_ERROR_MARKERS)


def check_fail_open(log_path):
    """1回のフック実行に紐づく使い捨てVAULT_RECALL_LOGを検査し、フックがfail-open
    経路（柱①/柱②いずれかのhelperがOllama不在・インデックス破損・timeout等でskip
    された）を通ったかを判定する。戻り値はfail-openメッセージのリスト（空ならなし）。
    パイプラインが正常完走した上での事実記録（_BENIGN_ERROR_MARKERS参照）は除外する。

    claude/hooks/vault-recall.sh の log_error()/log_row() 契約（同ファイルの該当コメント
    参照）: ERROR行は "ts\\tERROR\\t\\tsession_id\\tmessage" の5列（2列目が固定文字列
    "ERROR"）。正常系のヒット行は "ts\\tsession_id\\trelpath\\t..."、ヒット0件でも
    パイプラインを最後まで走らせた健全な呼び出しではハートビート行
    "ts\\tsession_id\\t(heartbeat)" が書かれる（いずれも2列目はsession_idでありERROR
    という固定文字列にはならない＝ハートビートを誤ってfail-open扱いしない）。

    Codexレビュー指摘・Major対応: フックは「いかなるエラーでもexit 0」のfail-open契約
    （hook自身のヘッダコメント参照）のため、Ollama不通・インデックス破損・timeout等で
    柱①（ベクトル想起）や柱②（キーワード想起）がskipされても rc==0・応答は速いまま
    静かに縮退する。従来の実装はこのログを一切読んでいなかったため、fail-openによる
    「速いだけの縮退応答」を正常なwarmレイテンシとして計測に混入させ、性能計測を
    偽装通過させ得た（AC4は実測必須・概算/偽装不可＝docs/design-vault-hybrid-search.md
    §4）。
    """
    try:
        text = pathlib.Path(log_path).read_text(encoding="utf-8")
    except OSError:
        return []
    messages = []
    for line in text.splitlines():
        if not line.strip():
            continue
        cols = line.split("\t")
        if len(cols) >= 2 and cols[1] == "ERROR":
            message = cols[4] if len(cols) >= 5 else "(詳細不明・ERROR行の列数が想定外)"
            if _is_benign_error_message(message):
                continue
            messages.append(message)
    return messages


def log_has_any_row(log_path):
    """1回のフック実行に紐づく使い捨てVAULT_RECALL_LOGに、1行でも記録があるかを返す
    （空行のみ・ファイル無し・読取失敗はFalse）。

    Codexレビュー指摘・Major（情報提供のみ・fail-open除外の判定自体には使わない）:
    正常に完走した呼び出しは通常、ヒット行かハートビート行のいずれかを必ず残す契約
    だが、10文字未満の短すぎるプロンプトの早期exitはこの限りではなく意図的に無ログ
    のまま正常終了する（claude/hooks/vault-recall.sh該当コメント参照）。この関数だけで
    「無ログ＝異常」と断定してcold/warmから除外すると、短文プロンプトを含むベンチ
    TSVで誤って正当な計測まで弾いてしまうため、除外の判定材料にはせず、利用者が
    目視で気づけるよう出力に注記するためだけに使う。
    """
    try:
        text = pathlib.Path(log_path).read_text(encoding="utf-8")
    except OSError:
        return False
    return any(line.strip() for line in text.splitlines())


def run_once(hook, vault, index_dir, prompt, session_id, timeout, disable_vector):
    payload = json.dumps({"session_id": session_id, "prompt": prompt}, ensure_ascii=False)
    env = os.environ.copy()
    env["VAULT_RECALL_VAULT"] = str(vault)
    if index_dir:
        env["VAULT_EMBED_INDEX_DIR"] = str(index_dir)
    if disable_vector:
        env["VAULT_RECALL_DISABLE_VECTOR"] = "1"
    # fail-open検出専用の使い捨てログ（実運用ログを汚さない）。呼び出しごとに新規
    # ファイルにすることで、check_fail_open()がsession_idマッチング無しに「この1回の
    # 呼び出しでERROR行が書かれたか」を直接判定できるようにする（固定パスへ全実行分を
    # 蓄積する旧実装だと、判定のたびにログ全体からsession_idで絞り込む必要があり、
    # 実行のたびに肥大化するファイルをフックがI/Oする副作用も避けたい）。
    log_fd, log_path_str = tempfile.mkstemp(prefix="vault-recall-latency-log-", suffix=".tsv")
    os.close(log_fd)
    log_path = pathlib.Path(log_path_str)
    env["VAULT_RECALL_LOG"] = str(log_path)

    start = time.perf_counter()
    try:
        proc = subprocess.run(["bash", str(hook)], input=payload, capture_output=True, text=True,
                               timeout=timeout, env=env)
        rc = proc.returncode
        err = None
    except subprocess.TimeoutExpired:
        rc = None
        err = f"timeout({timeout}s)"
    elapsed_ms = (time.perf_counter() - start) * 1000.0
    fail_open_msgs = check_fail_open(log_path)
    # fail_open_msgsが空でもログ自体が完全に空（1行も無い）場合はrc==0でも要注意
    # （log_has_any_row()のdocstring参照。除外はしないが目視で気づけるよう記録だけ残す）。
    empty_log = not fail_open_msgs and not log_has_any_row(log_path)
    try:
        log_path.unlink()
    except OSError:
        pass
    return elapsed_ms, rc, err, fail_open_msgs, empty_log


def percentile(sorted_vals, pct):
    """線形補間によるパーセンタイル（外部ライブラリ非依存の簡易実装）。"""
    if not sorted_vals:
        return float("nan")
    if len(sorted_vals) == 1:
        return sorted_vals[0]
    k = (len(sorted_vals) - 1) * (pct / 100.0)
    f = int(k)
    c = min(f + 1, len(sorted_vals) - 1)
    if f == c:
        return sorted_vals[f]
    return sorted_vals[f] + (sorted_vals[c] - sorted_vals[f]) * (k - f)


def summarize(label, values):
    if not values:
        return {"label": label, "count": 0}
    vs = sorted(values)
    return {
        "label": label,
        "count": len(vs),
        "p50_ms": round(percentile(vs, 50), 1),
        "p95_ms": round(percentile(vs, 95), 1),
        "mean_ms": round(statistics.mean(vs), 1),
        "max_ms": round(max(vs), 1),
        "min_ms": round(min(vs), 1),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("bench_tsv", help="質問文<TAB>...形式のTSV（質問文列のみ使用。recall_bench.pyと共用可）")
    ap.add_argument("--vault", default=str(DEFAULT_VAULT))
    ap.add_argument("--hook", default=str(DEFAULT_HOOK))
    ap.add_argument("--index-dir", default=None, help="VAULT_EMBED_INDEX_DIR上書き（既定: hook/embedding_indexの既定値）")
    ap.add_argument("--cold-runs", type=int, default=1,
                     help="先頭N回を「cold」ラベルで分離集計する（既定1）。ただし本ツールは"
                          "Ollamaのモデルを自動アンロードしないため、実際にモデル未ロード状態から"
                          "計測できるのは通常この引数を1のまま使った場合の1回目のみ（2回目以降は"
                          "1回目の呼び出しで既にモデルがロードされ、事実上warmになる。Codexレビュー"
                          "指摘・Minor: N>1を指定しても2件目以降が真にcoldである保証は無いため、"
                          "計測前に手動でアンロードした上でN=1運用を推奨する＝上のモジュールdocstring参照）")
    ap.add_argument("--repeat", type=int, default=1, help="bench_tsv全体を何周するか（既定1）")
    ap.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT)
    ap.add_argument("--session-id", default="latency-measure")
    ap.add_argument("--disable-vector", action="store_true", help="VAULT_RECALL_DISABLE_VECTOR=1で計測（キーワードのみモードとの比較用）")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    hook_path = pathlib.Path(args.hook).resolve()
    if not hook_path.is_file():
        print(f"FAIL: hookが見つかりません: {hook_path}", file=sys.stderr)
        sys.exit(1)
    vault_root = pathlib.Path(args.vault).resolve()
    if not vault_root.is_dir():
        print(f"FAIL: vaultが見つかりません: {vault_root}", file=sys.stderr)
        sys.exit(1)

    prompts = read_prompts(args.bench_tsv) * max(args.repeat, 1)
    if not prompts:
        print("FAIL: 計測対象の質問が1件もありません。", file=sys.stderr)
        sys.exit(1)

    cold_vals, warm_vals = [], []
    errors = []
    fail_open_events = []
    empty_log_events = []
    for i, prompt in enumerate(prompts, 1):
        elapsed_ms, rc, err, fail_open_msgs, empty_log = run_once(
            hook_path, vault_root, args.index_dir, prompt,
            f"{args.session_id}-{i}", args.timeout, args.disable_vector)
        if fail_open_msgs:
            # フックがfail-open経路（柱①/②いずれかのhelperをskip）を通った計測は、
            # cold/warmどちらの集計からも除外し別枠で明示する（run_once()のdocstring・
            # check_fail_open()のdocstring参照。除外しないと「速いだけの縮退応答」が
            # 正常なwarmレイテンシへ混入し、AC4の実測要件を偽装通過しうる）。
            fail_open_events.append((i, prompt, elapsed_ms, rc, fail_open_msgs))
            continue
        if empty_log:
            # ログが完全に空（ヒット行もハートビート行も無い）＝短文プロンプトの意図的な
            # 無ログ早期exitか、log_error()経由すら通らない想定外の異常かを本ツールだけ
            # では区別できない（log_has_any_row()のdocstring参照）。除外はせず通常どおり
            # cold/warmへ計上した上で、目視確認できるよう別枠に記録するだけに留める
            # （Codexレビュー指摘・Major: 完全な無ログを無条件で見逃さないための注記）。
            empty_log_events.append((i, prompt, elapsed_ms, rc))
        bucket = cold_vals if i <= args.cold_runs else warm_vals
        bucket.append(elapsed_ms)
        if err or (rc is not None and rc != 0):
            errors.append((i, prompt, rc, err))

    cold_summary = summarize("cold", cold_vals)
    warm_summary = summarize("warm", warm_vals)

    if args.json:
        print(json.dumps({
            "hook": str(hook_path),
            "vault": str(vault_root),
            "vector_disabled": args.disable_vector,
            "cold": cold_summary,
            "warm": warm_summary,
            "errors": [{"index": i, "prompt": p, "rc": rc, "err": err} for i, p, rc, err in errors],
            "fail_open_excluded": [
                {"index": i, "prompt": p, "elapsed_ms": round(e, 1), "rc": rc, "messages": msgs}
                for i, p, e, rc, msgs in fail_open_events
            ],
            "empty_log_included": [
                {"index": i, "prompt": p, "elapsed_ms": round(e, 1), "rc": rc}
                for i, p, e, rc in empty_log_events
            ],
        }, ensure_ascii=False, indent=2))
    else:
        mode = "キーワードのみ" if args.disable_vector else "ハイブリッド(キーワード+ベクトル)"
        print(f"=== vault-recall.sh レイテンシ計測（{mode}） ===")
        print(f"hook: {hook_path}")
        print(f"vault: {vault_root}")
        print(f"総実行回数: {len(prompts)}（cold={len(cold_vals)} warm={len(warm_vals)} "
              f"fail_open除外={len(fail_open_events)}）")
        print()
        for s in (cold_summary, warm_summary):
            if s["count"] == 0:
                print(f"[{s['label']}] 対象0件")
                continue
            print(f"[{s['label']}] n={s['count']} p50={s['p50_ms']}ms p95={s['p95_ms']}ms "
                  f"mean={s['mean_ms']}ms min={s['min_ms']}ms max={s['max_ms']}ms")
        if fail_open_events:
            print()
            print(f"⚠️ {len(fail_open_events)}件はフックがfail-open経路（柱①/②のskip）を通ったため"
                  "レイテンシ計測から除外しました（実測ではなく縮退応答＝AC4の対象外）:")
            for i, p, e, rc, msgs in fail_open_events[:10]:
                print(f"  [{i}] elapsed={round(e, 1)}ms rc={rc} prompt={p[:60]!r}")
        if empty_log_events:
            print()
            print(f"ℹ️ {len(empty_log_events)}件はログが完全に空でした（10文字未満の短文プロンプトによる"
                  "意図的な無ログか、想定外の異常かは本ツールだけでは判別できません・除外はせずcold/warmへ"
                  "計上済み・要目視確認）:")
            for i, p, e, rc in empty_log_events[:10]:
                print(f"  [{i}] elapsed={round(e, 1)}ms rc={rc} prompt={p[:60]!r}")
                for m in msgs[:3]:
                    print(f"       - {m[:150]}")
        if errors:
            print()
            print(f"⚠️ {len(errors)}件でhookが異常終了/timeoutしました（レイテンシ値には含めているが要確認）:")
            for i, p, rc, err in errors[:10]:
                print(f"  [{i}] rc={rc} err={err} prompt={p[:60]!r}")

    if errors or fail_open_events:
        sys.exit(2)


if __name__ == "__main__":
    main()
