#!/usr/bin/env python3
"""AC4性能計測ツール: claude/hooks/vault-recall.sh の実測レイテンシをcold/warm別に
p50/p95で計測する（設計書 docs/design-vault-hybrid-search.md §4「AC4はp50/p95実測
（cold/warm別・ノート数別）を検収の必須完了条件（概算不可・実測必須）」）。

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


def run_once(hook, vault, index_dir, prompt, session_id, timeout, disable_vector):
    payload = json.dumps({"session_id": session_id, "prompt": prompt}, ensure_ascii=False)
    env = os.environ.copy()
    env["VAULT_RECALL_VAULT"] = str(vault)
    if index_dir:
        env["VAULT_EMBED_INDEX_DIR"] = str(index_dir)
    if disable_vector:
        env["VAULT_RECALL_DISABLE_VECTOR"] = "1"
    # 提示ログへ書き込ませない（計測専用の使い捨てログパスに逃がす）。
    env["VAULT_RECALL_LOG"] = str(pathlib.Path.home() / ".claude" / "logs" / "vault-recall-latency-measure.tsv")

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
    return elapsed_ms, rc, err


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
    for i, prompt in enumerate(prompts, 1):
        elapsed_ms, rc, err = run_once(hook_path, vault_root, args.index_dir, prompt,
                                        f"{args.session_id}-{i}", args.timeout, args.disable_vector)
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
        }, ensure_ascii=False, indent=2))
    else:
        mode = "キーワードのみ" if args.disable_vector else "ハイブリッド(キーワード+ベクトル)"
        print(f"=== vault-recall.sh レイテンシ計測（{mode}） ===")
        print(f"hook: {hook_path}")
        print(f"vault: {vault_root}")
        print(f"総実行回数: {len(prompts)}（cold={len(cold_vals)} warm={len(warm_vals)}）")
        print()
        for s in (cold_summary, warm_summary):
            if s["count"] == 0:
                print(f"[{s['label']}] 対象0件")
                continue
            print(f"[{s['label']}] n={s['count']} p50={s['p50_ms']}ms p95={s['p95_ms']}ms "
                  f"mean={s['mean_ms']}ms min={s['min_ms']}ms max={s['max_ms']}ms")
        if errors:
            print()
            print(f"⚠️ {len(errors)}件でhookが異常終了/timeoutしました（レイテンシ値には含めているが要確認）:")
            for i, p, rc, err in errors[:10]:
                print(f"  [{i}] rc={rc} err={err} prompt={p[:60]!r}")

    if errors:
        sys.exit(2)


if __name__ == "__main__":
    main()
