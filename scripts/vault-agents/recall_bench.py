#!/usr/bin/env python3
"""外部脳(Obsidian Vault)の想起フック(claude/hooks/vault-recall.sh)を自動採点するハーネス。

背景: 敵対的レビュー(vault-adversarial-review-2026-07-10.md C-1)により、想起フックの
ヒット率が「机上シミュレーション」でしか測られていないことが指摘された。改善(alias棚卸し・
照合方式の改修)を進めるための唯一の計器として、実フックを実際に叩いて実測する。

採点方法: フックのロジックはここで再実装しない（ドリフト源になるため禁止）。各質問について
`{"session_id": ..., "prompt": "<質問文>"}` をJSONでフック本体(bash)へstdin投入し、
実際に返ってきた additionalContext から提示候補ノートを抽出して判定する。

入力データ形式（ベンチTSV・1行1問）:
  質問文<TAB>期待ノート相対パス（`|`区切りで複数可・いずれか1つが提示されれば正解）
  空行・`#`始まりの行はコメントとしてskip。

オーバーレイ機能（--alias-overlay）: Vaultを一切書き換えずに「aliasを足したら
ヒット率がどう変わるか」を試すための機能。Vaultの想起対象4フォルダ(Knowledge/
Preferences/Decisions/Projects)だけを一時ディレクトリへコピーし、そこへ
apply_aliases.py の process_note()（同じロジックを再利用・重複実装しない）で
overlay TSV のaliasを適用してから、VAULT_RECALL_VAULT をその一時ディレクトリに
向けてフックを叩く。実Vaultは最初から最後まで一切書き込まない。

使い方:
  scripts/vault-agents/recall_bench.py bench.tsv
  scripts/vault-agents/recall_bench.py bench.tsv --json
  scripts/vault-agents/recall_bench.py bench.tsv --alias-overlay overlay.tsv
  scripts/vault-agents/recall_bench.py bench.tsv --vault DIR --hook DIR/vault-recall.sh
"""
import argparse
import datetime
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

# 同じディレクトリ(scripts/vault-agents/)のモジュールをそのまま再利用する
# （alias適用・frontmatter解析のロジック重複によるドリフトを避ける）。
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import apply_aliases  # noqa: E402
import vault_inventory as vi  # noqa: E402

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
DEFAULT_VAULT = pathlib.Path.home() / "Data" / "obsidian"
DEFAULT_HOOK = REPO_ROOT / "claude" / "hooks" / "vault-recall.sh"

# 想起フック自身の SCAN_DIRS（claude/hooks/vault-recall.sh:33）と同じ並び。
# オーバーレイ用の一時Vaultはこの4フォルダだけコピーすれば十分（照合ロジックの
# 実行自体は実物のフックがそのまま行うため、ここでは「コピー範囲」の話でしかない）。
SCAN_DIRS = ("Knowledge", "Preferences", "Decisions", "Projects")

MAX_CANDIDATES = 5          # 想起フックが提示する候補の上限（vault-recall.sh:294の5と同じ）
DEFAULT_HOOK_TIMEOUT = 5.0  # 秒。実運用のフック側timeout(settings.json=2秒)より余裕を持たせる
                             # （ベンチ実行環境のプロセス起動オーバーヘッド込みで測るため）。

# フックが1候補ごとに出す行の厳密フォーマット（vault-recall.sh:317-318のCTX組み立てと
# 一致させる）: "- ${relpath}（一致: ${keys_display}）"。緩い判定（"- "始まりだけ見る等）
# だと、将来この表示フォーマットが変わった際に別の情報を relpath として誤採用してしまう
# （Codexレビュー指摘・Major回帰: 単に「（一致:」の有無で分岐しないと、区切り文字だけが
# 変わったケースを検知できずに無言で誤パースする）。
CANDIDATE_LINE_RE = re.compile(r"^- (.+?)（一致: .+）$")


NEGATIVE_MARKER = "-"  # 期待ノート列がこの1文字だけの行＝「候補ゼロが正解」のノイズ検査用行
                        # （8.0ラウンド・ノイズ検査ベンチ用の最小拡張。既存TSVはこの記法を
                        # 使わないため後方互換＝通常行の判定ロジックは一切変えない）。


def parse_bench_tsv(path):
    """ベンチTSV(質問文<TAB>期待ノート相対パス(|区切り)、またはノイズ検査用に
    期待ノート列が"-"1文字だけの行)を [(question, [relpath, ...], is_negative), ...] にする。
    "-"の行は「このプロンプトではノートが0件提示されるのが正解」を意味する
    （Vaultのどのノートとも無関係な日常プロンプトでの誤ヒット率を測るノイズ検査用。
    通常の正例行と書式を揃えることでファイル1本で両方扱える）。
    空行・#始まりはコメントとしてskip。壊れた行はWARNしてskip（apply_aliases.parse_tsvと同方針）。
    """
    rows = []
    text = pathlib.Path(path).read_text(encoding="utf-8")
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.rstrip("\r")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 2 or not parts[0].strip() or not parts[1].strip():
            print(f"WARN: {path}:{lineno}: 想定外の形式のためskipします（列数={len(parts)}）: {raw!r}",
                  file=sys.stderr)
            continue
        question = parts[0].strip()
        if parts[1].strip() == NEGATIVE_MARKER:
            rows.append((question, [], True))
            continue
        expected = [e.strip() for e in parts[1].split("|") if e.strip()]
        if not expected:
            print(f"WARN: {path}:{lineno}: 期待ノートが1つもありません。skipします: {raw!r}", file=sys.stderr)
            continue
        rows.append((question, expected, False))
    return rows


def build_overlay_vault(vault_root, overlay_path):
    """SCAN_DIRSだけを一時ディレクトリへコピーし、overlay TSVのaliasを適用して返す。
    実Vault(vault_root)は一切書き込まない。呼び出し側が使用後に必ずrmtreeすること。
    """
    tmp_dir = pathlib.Path(tempfile.mkdtemp(prefix="recall-bench-vault-"))
    tmp_resolved = tmp_dir.resolve()
    for d in SCAN_DIRS:
        src = vault_root / d
        if src.is_dir():
            shutil.copytree(src, tmp_dir / d)

    rows = apply_aliases.parse_tsv(str(overlay_path))
    generic_words = apply_aliases.load_generic_aliases()
    today = datetime.date.today().isoformat()
    applied = skipped = 0
    for relpath, aliases in rows:
        # overlay TSVの相対パスが絶対パス・"../"・symlink等で一時Vaultの外を指していても
        # 書き換えないようにする（Codexレビュー指摘・Critical: apply_aliases.py本体の
        # resolve()+relative_to()チェックはmain()内にしか無く、process_note()自体は
        # パス検証をしない純粋関数のため、呼び出し側=ここで独立に必ず確認する）。
        candidate = tmp_dir / relpath
        try:
            resolved = candidate.resolve()
            resolved.relative_to(tmp_resolved)
        except (OSError, ValueError):
            print(f"WARN: overlay対象パスが一時Vaultの外を指しているためskipします: {relpath}", file=sys.stderr)
            skipped += 1
            continue
        if not resolved.is_file():
            print(f"WARN: overlay対象ノートが一時Vaultに見つかりません（コピー範囲外か存在しない）: {relpath}",
                  file=sys.stderr)
            skipped += 1
            continue
        text = resolved.read_text(encoding="utf-8")
        result = apply_aliases.process_note(text, aliases, generic_words, today)
        if result["error"]:
            print(f"WARN: overlay適用失敗 {relpath}: {result['error']}", file=sys.stderr)
            skipped += 1
            continue
        if result["changed"]:
            resolved.write_text(result["new_text"], encoding="utf-8")
            applied += 1
    print(f"overlay適用: {applied}件（skip {skipped}件） ※一時コピーのみ・実Vaultは無変更", file=sys.stderr)
    return tmp_dir


def run_hook(hook_path, vault_dir, prompt, session_id, log_path, timeout):
    """実物のフックをsubprocessで叩き、(提示候補relpathのリスト, エラーメッセージ or None)を返す。
    ロジックは一切再実装しない。フックの異常（非0終了・timeout・壊れたJSON・空出力）は
    無言で握りつぶさず、エラーメッセージ付きで「候補ゼロ(fail)」として扱う
    （このハーネス自体が「無言のfail-open」にならないようにする）。
    """
    payload = json.dumps({"session_id": session_id, "prompt": prompt}, ensure_ascii=False)
    env = os.environ.copy()
    env["VAULT_RECALL_VAULT"] = str(vault_dir)
    env["VAULT_RECALL_LOG"] = str(log_path)
    try:
        proc = subprocess.run(
            ["bash", str(hook_path)], input=payload, capture_output=True, text=True,
            timeout=timeout, env=env,
        )
    except subprocess.TimeoutExpired:
        return [], f"hookがtimeout({timeout}s)しました"
    except OSError as e:
        return [], f"hookを起動できませんでした: {e}"

    if proc.returncode != 0:
        return [], f"hookが非0終了しました（rc={proc.returncode}）: {proc.stderr.strip()[:200]}"

    out = proc.stdout.strip()
    if not out:
        return [], None  # 正常系「ヒット無し」。additionalContextを出さないのがフックの仕様。

    try:
        data = json.loads(out)
    except json.JSONDecodeError as e:
        return [], f"hook出力のJSON解析に失敗しました（{e}）: {out[:200]!r}"

    # 型が想定外（hookSpecificOutputがオブジェクトでない・additionalContextが文字列でない等）
    # の場合、素朴に.get()や.splitlines()を呼ぶとハーネス自体が例外で落ちる（Codexレビュー
    # 指摘・Minor）。フック実装が将来変わってフォーマットが崩れた場合を「候補0件の正常系」
    # と誤認しないよう、ここでエラーとして可視化する（無言のfail-open防止）。
    hso = data.get("hookSpecificOutput") if isinstance(data, dict) else None
    if not isinstance(hso, dict):
        return [], f"hook出力の形式が想定外です（hookSpecificOutputがオブジェクトではありません）: {out[:200]!r}"
    ctx = hso.get("additionalContext", "")
    if not isinstance(ctx, str):
        return [], f"hook出力の形式が想定外です（additionalContextが文字列ではありません）: {out[:200]!r}"

    candidates = []
    malformed_lines = []
    for line in ctx.splitlines():
        line = line.strip()
        if not line.startswith("- "):
            continue
        m = CANDIDATE_LINE_RE.match(line)
        if not m:
            # "- "で始まる箇条書き行なのに厳密フォーマットに一致しない＝表示フォーマットが
            # 変わった可能性（Codexレビュー指摘・Major回帰: 緩い分割だと区切り文字が変わった
            # ケースを検知できず、別の文字列をrelpathとして誤採用してしまう）。
            malformed_lines.append(line)
            continue
        relpath = m.group(1).strip()
        if relpath:
            candidates.append(relpath)

    if malformed_lines:
        return [], (f"候補行の形式が想定と異なります（表示フォーマット変更の可能性・"
                     f"{len(malformed_lines)}行）: {malformed_lines[0][:200]!r}")

    # additionalContextが非空なのに候補行を1件も抽出できなかった場合も同様に、hook側の
    # 表示フォーマットが根本から変わった可能性が高い（Codexレビュー指摘・Major: これを
    # 無言で「候補0件=miss」として扱うと、フォーマット変更をヒット率低下と誤認したまま
    # 気づけない）。
    if ctx.strip() and not candidates:
        return [], f"additionalContextはあるが候補行を1件も抽出できませんでした（表示フォーマット変更の可能性）: {ctx[:200]!r}"

    return candidates[:MAX_CANDIDATES], None


def note_aliases(vault_dir, relpath):
    """ノートの現在のaliasesを返す。ノートが無ければNone（fail一覧の「現aliases」表示用）。"""
    path = vault_dir / relpath
    if not path.is_file():
        return None
    fm, _ = vi.parse_frontmatter(path.read_text(encoding="utf-8"))
    return vi.normalize_aliases(fm.get("aliases"))


def score(rows, hook_path, vault_dir, session_id, timeout):
    log_fd, log_path = tempfile.mkstemp(prefix="recall-bench-log-", suffix=".tsv")
    os.close(log_fd)
    results = []
    try:
        for i, (question, expected, is_negative) in enumerate(rows, 1):
            candidates, hook_error = run_hook(hook_path, vault_dir, question, session_id, log_path, timeout)
            # ノイズ検査行(is_negative)は「候補が1件も出ないこと」が正解。通常行は
            # 従来どおり期待ノートのいずれかが候補に含まれていればPASS。
            # いずれの場合もhook自体が異常終了/異常出力した行はPASSにしない
            # （Codexレビュー指摘・Major: run_hook()は異常時candidates=[]を返すため、
            # 対策なしだとノイズ検査行が「たまたま0件」と区別できず誤ってPASS集計
            # されてしまう＝インフラ異常を精度の実績と混同する）。
            if hook_error:
                passed = False
            elif is_negative:
                passed = len(candidates) == 0
            else:
                passed = any(e in candidates for e in expected)
            results.append({
                "index": i,
                "question": question,
                "expected": expected,
                "is_negative": is_negative,
                "candidates": candidates,
                "pass": passed,
                "hook_error": hook_error,
                "expected_aliases": {e: note_aliases(vault_dir, e) for e in expected},
            })
    finally:
        try:
            os.remove(log_path)
        except OSError:
            pass
    return results


def format_human(results, vault_desc, hook_path, overlay_used):
    total = len(results)
    hits = sum(1 for r in results if r["pass"])
    rate = (hits / total * 100) if total else 0.0
    lines = []
    lines.append("=== 想起ベンチマーク採点 ===")
    lines.append(f"Vault: {vault_desc}" + ("（aliasオーバーレイ適用・一時コピーに対して実行）" if overlay_used else ""))
    lines.append(f"Hook: {hook_path}")
    lines.append(f"質問数: {total}")
    lines.append("")
    for r in results:
        mark = "PASS" if r["pass"] else "FAIL"
        lines.append(f"[{r['index']:>2}] {mark}  Q: {r['question']}")
        cand = "、".join(r["candidates"]) if r["candidates"] else "(なし)"
        lines.append(f"      提示候補: {cand}")
        if r["is_negative"]:
            lines.append("      期待ノート: (候補ゼロが正解・ノイズ検査行)")
        else:
            lines.append(f"      期待ノート: {'、'.join(r['expected'])}")
        if r["hook_error"]:
            lines.append(f"      ⚠️ hookエラー: {r['hook_error']}")
    lines.append("")
    lines.append(f"=== サマリ: ヒット率 {hits}/{total} ({rate:.1f}%) ===")

    negatives = [r for r in results if r["is_negative"]]
    if negatives:
        # hook異常行（timeout・壊れた出力等）は「提示0件」の実績ではなくインフラ
        # 異常なので、ノイズ率の平均/最大からは除外する（Codexレビュー指摘・Minor:
        # 混ぜると本来の判定不能行が「静かなノイズ0件」として平均に紛れ込む）。
        negatives_clean = [r for r in negatives if not r["hook_error"]]
        negatives_error = [r for r in negatives if r["hook_error"]]
        lines.append("")
        if negatives_clean:
            counts = [len(r["candidates"]) for r in negatives_clean]
            avg = sum(counts) / len(counts)
            lines.append(f"=== ノイズ検査: 提示数の平均 {avg:.2f}件 / 最大 {max(counts)}件"
                         f"（{len(negatives_clean)}問・hook異常{len(negatives_error)}件は集計除外） ===")
        else:
            lines.append(f"=== ノイズ検査: 集計対象0件（{len(negatives_error)}問すべてhook異常） ===")

    fails = [r for r in results if not r["pass"]]
    lines.append("")
    lines.append(f"=== FAIL一覧（alias改善の材料・{len(fails)}件） ===")
    if not fails:
        lines.append("なし")
    else:
        for r in fails:
            if r["hook_error"]:
                lines.append(f"- [{r['index']}] {r['question']}")
                lines.append(f"    ⚠️ hookエラーのため判定不能（ノイズ/ヒットいずれの実績にも数えない）: {r['hook_error']}")
                continue
            if r["is_negative"]:
                lines.append(f"- [{r['index']}] {r['question']}")
                lines.append(f"    ノイズ検査: 候補ゼロが正解だが {r['candidates']} が提示された")
                continue
            bits = []
            for exp in r["expected"]:
                al = r["expected_aliases"].get(exp)
                if al is None:
                    bits.append(f"{exp}: (ノート未検出)")
                elif al:
                    bits.append(f"{exp}: {', '.join(al)}")
                else:
                    bits.append(f"{exp}: (aliasesなし)")
            lines.append(f"- [{r['index']}] {r['question']}")
            lines.append(f"    期待: {' / '.join(r['expected'])} / 提示候補: {r['candidates'] or '(なし)'}")
            lines.append(f"    現aliases: {' | '.join(bits)}")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(
        description="想起フック(claude/hooks/vault-recall.sh)を実際に叩いてベンチ問題を採点する。")
    ap.add_argument("bench_tsv", help="ベンチTSV（質問文<TAB>期待ノート相対パス(|区切り)）")
    ap.add_argument("--vault", default=str(DEFAULT_VAULT), help=f"Vaultのルート（既定: {DEFAULT_VAULT}）")
    ap.add_argument("--hook", default=str(DEFAULT_HOOK), help=f"想起フックのパス（既定: {DEFAULT_HOOK}）")
    ap.add_argument("--alias-overlay",
                     help="ノート相対パス<TAB>alias1|alias2|... のTSV。指定すると実Vaultを書き換えずに"
                          "一時コピーへ適用してから採点する（次工程のalias調整の下見用）")
    ap.add_argument("--session-id", default="bench", help="hookへ渡すsession_id（既定: bench）")
    ap.add_argument("--hook-timeout", type=float, default=DEFAULT_HOOK_TIMEOUT,
                     help=f"1問あたりのhook実行timeout秒（既定: {DEFAULT_HOOK_TIMEOUT}）")
    ap.add_argument("--json", action="store_true", help="機械可読なJSONサマリを標準出力へ出す")
    ap.add_argument("--allow-hook-errors", action="store_true",
                     help="hook実行の異常（timeout・壊れた出力・非0終了）があってもexit 0にする"
                          "（既定は異常1件以上でexit 2＝recallの不一致とhookのインフラ異常を区別する）")
    args = ap.parse_args()

    hook_path = pathlib.Path(args.hook).resolve()
    if not hook_path.is_file():
        print(f"FAIL: hookが見つかりません: {hook_path}", file=sys.stderr)
        sys.exit(1)

    vault_root = pathlib.Path(args.vault).resolve()
    if not vault_root.is_dir():
        print(f"FAIL: vaultが見つかりません: {vault_root}", file=sys.stderr)
        sys.exit(1)

    try:
        rows = parse_bench_tsv(args.bench_tsv)
    except OSError as e:
        print(f"FAIL: ベンチTSVを読めません: {args.bench_tsv}（{e}）", file=sys.stderr)
        sys.exit(1)
    if not rows:
        print("FAIL: 採点対象がありません（TSVが空、または全行が不正/コメントでskipされました）。", file=sys.stderr)
        sys.exit(1)

    overlay_dir = None
    try:
        if args.alias_overlay:
            overlay_dir = build_overlay_vault(vault_root, pathlib.Path(args.alias_overlay).resolve())
            active_vault = overlay_dir
            vault_desc = f"{vault_root}（一時コピー: {overlay_dir}）"
        else:
            active_vault = vault_root
            vault_desc = str(vault_root)

        results = score(rows, hook_path, active_vault, args.session_id, args.hook_timeout)
    finally:
        if overlay_dir is not None:
            shutil.rmtree(overlay_dir, ignore_errors=True)

    total = len(results)
    hits = sum(1 for r in results if r["pass"])
    hook_errors = sum(1 for r in results if r["hook_error"])

    if args.json:
        print(json.dumps({
            "vault": vault_desc,
            "hook": str(hook_path),
            "overlay": bool(args.alias_overlay),
            "total": total,
            "hits": hits,
            "hit_rate": (hits / total) if total else 0.0,
            "hook_errors": hook_errors,
            "results": results,
        }, ensure_ascii=False, indent=2))
    else:
        print(format_human(results, vault_desc, hook_path, bool(args.alias_overlay)))
        if hook_errors:
            print(f"\n⚠️ {hook_errors}件でhookが異常終了/異常出力しました"
                  "（recallの不一致ではなくインフラ異常。上記の各行のhookエラー欄を確認）", file=sys.stderr)

    # hookのインフラ異常（timeout・壊れた出力・非0終了）は、recall本来の不一致（正常な
    # miss）と区別してexit 2にする（Codexレビュー指摘・Major: 常にexit 0だと、CI/自動運用で
    # 壊れたフックを「低いヒット率」と誤認しうる。--allow-hook-errorsで従来どおりexit 0に戻せる）。
    if hook_errors and not args.allow_hook_errors:
        sys.exit(2)


if __name__ == "__main__":
    main()
