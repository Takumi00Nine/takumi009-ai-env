#!/usr/bin/env python3
"""外部脳 Knowledge 自律整理・柱②のマージ品質ゲート（FR12a）。

設計書§1「merge_quality_gate.py」・§2.3手順8・付録A FR12a の実装。
knowledge_merge.py の `gate` サブコマンドから import されて使われる（本体の
オーケストレーション・recall_bench.py の実行はそちらの責務）。単体でも
構造チェックだけを試す用途に最小限のCLIを提供する。

責務（FR12a）:
  (1) recall_bench.py 用ベンチTSVの期待ノートパスを旧→新パスへ機械的に付け替えた
      一時TSVを生成する。**元のベンチTSV本体には一切書込まない**（対象パス制限）。
      実行前後で元TSVのgit statusに差分が無いことを機械アサートし、差分があれば
      改ざん疑いとして例外(GateError)で即block扱いにする。
  (2) 両ノートの見出し・コードブロック・出典URL・日付・frontmatter必須項目が
      統合ノートへ残存しているかを機械差分検査する。
  (3) 「全主張の包含・意味保持（数値改変・意味反転が無いか）」は意味判定であり
      本モジュールではチェックしない（Codex rubric側の役割＝knowledge_merge.py
      evidence が rubric として明記し、Codexのverdictで判定する）。
  AC6: aliases和集合・リンク切れ0の機械チェックも本モジュールが担う
      （vault_inventory.py の parse_frontmatter/normalize_aliases/LINK_RE を
      そのまま再利用し、ロジックの重複によるドリフトを避ける）。
"""
import argparse
import pathlib
import re
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import vault_inventory as vi  # noqa: E402

HEADING_RE = re.compile(r"^(#{1,6})\s+(.+?)\s*$", re.M)
CODE_BLOCK_RE = re.compile(r"```.*?```", re.S)
URL_RE = re.compile(r"https?://[^\s)\]}\"'>]+")
DATE_RE = re.compile(r"\b20\d{2}-\d{2}-\d{2}\b")

# frontmatter必須項目チェックから除外するキー（新ノートで正当に変わる/新規発生する項目）。
# aliasesは専用のcheck_aliases_union()で別途「和集合になっているか」を厳密に見るため
# ここでは除外する（このチェックは「存在するか」だけを見る単純比較のため）。
DEFAULT_FRONTMATTER_EXEMPT_KEYS = frozenset(
    {"aliases", "updated", "date", "deprecated", "superseded_by", "review_by"})


class GateError(Exception):
    """gate処理を継続できない異常（ベンチTSV改ざん疑い等）。呼び出し側は当該候補を
    blockedにして書込せず、必要ならALERTを生成すること（fail-closed）。
    bench_repo/bench_relpathを持つ場合、ALERT生成時に「機械的解消判定」
    （bench_tsv_tamperedタイプ＝再度git diff==0を確認できれば解消）へ渡す。"""

    def __init__(self, message, bench_repo=None, bench_relpath=None):
        super().__init__(message)
        self.bench_repo = bench_repo
        self.bench_relpath = bench_relpath


def strip_code_blocks(text):
    """コードフェンス内を取り除いたテキストを返す（見出し検出・日付検出等が
    コード例の中の文字列を誤検出しないようにするため。vault_inventory.pyの
    CODE_RE運用と同じ考え方）。"""
    return CODE_BLOCK_RE.sub("", text)


def extract_headings(text):
    """ATX見出し（`#`〜`######`）のテキスト部分（`#`記号を除いた本文）を返す。
    コードフェンス内の`#`はコメント等である可能性が高いため対象外にする。"""
    return [m.group(2).strip() for m in HEADING_RE.finditer(strip_code_blocks(text))]


def extract_code_blocks(text):
    """フェンス付きコードブロック（```〜```）をフェンス込みでそのまま抽出する。"""
    return CODE_BLOCK_RE.findall(text)


def extract_urls(text):
    return sorted(set(URL_RE.findall(text)))


def extract_dates(text):
    return sorted(set(DATE_RE.findall(strip_code_blocks(text))))


def check_structural(orig_text_a, orig_text_b, merged_text):
    """FR12a(2): 両原ノートの見出し・コードブロック・出典URL・日付が統合ノートへ
    残存しているかを機械差分検査する。claim preservation（意味保持）自体は判定
    しない（Codex rubric側の役割）。missing_* が全て空なら pass=True。
    """
    headings_needed = list(dict.fromkeys(extract_headings(orig_text_a) + extract_headings(orig_text_b)))
    code_needed = list(dict.fromkeys(extract_code_blocks(orig_text_a) + extract_code_blocks(orig_text_b)))
    urls_needed = sorted(set(extract_urls(orig_text_a)) | set(extract_urls(orig_text_b)))
    dates_needed = sorted(set(extract_dates(orig_text_a)) | set(extract_dates(orig_text_b)))

    merged_headings = set(extract_headings(merged_text))
    missing_headings = [h for h in headings_needed if h not in merged_headings]
    # コードブロック・URL・日付は「統合ノート全文に部分文字列として存在するか」で見る
    # （厳密な位置・見出し配下かは問わない。マージによる並べ替え自体は許容する）。
    missing_code = [c for c in code_needed if c not in merged_text]
    missing_urls = [u for u in urls_needed if u not in merged_text]
    missing_dates = [d for d in dates_needed if d not in merged_text]

    return {
        "missing_headings": missing_headings,
        "missing_code_blocks": missing_code,
        "missing_urls": missing_urls,
        "missing_dates": missing_dates,
        "pass": not (missing_headings or missing_code or missing_urls or missing_dates),
    }


def check_aliases_union(fm_a, fm_b, fm_merged):
    """AC6: 統合ノートのaliasesが両原ノートaliasesの和集合を包含しているか。"""
    need = set(vi.normalize_aliases(fm_a.get("aliases"))) | set(vi.normalize_aliases(fm_b.get("aliases")))
    have = set(vi.normalize_aliases(fm_merged.get("aliases")))
    missing = sorted(need - have)
    return {"missing_aliases": missing, "pass": not missing}


def check_frontmatter_required_keys(fm_a, fm_b, fm_merged, exempt_keys=None):
    """FR12a(2): 両原ノートのfrontmatterキー（正当に変わりうるキーを除く）が
    統合ノートのfrontmatterにも存在するか（値の一致までは求めない＝キーの存在のみ）。
    """
    exempt = exempt_keys if exempt_keys is not None else DEFAULT_FRONTMATTER_EXEMPT_KEYS
    need = (set(fm_a) | set(fm_b)) - set(exempt)
    missing = sorted(k for k in need if k not in fm_merged)
    return {"missing_keys": missing, "pass": not missing}


def check_broken_links(worktree_root):
    """AC6: worktree全体のwikilinkリンク切れが0件かを機械チェックする。
    vault_inventory.py の parse_frontmatter/LINK_RE をそのまま再利用する
    （リンク解析ロジックを重複実装してドリフトさせない）。
    読込に失敗したノート（権限エラー等）は「検査対象から静かに除外」しない
    （Codexレビュー指摘・Minor: fail-closed方針＝リンク切れが隠れている可能性を
    無視できないためpass=Falseにする）。
    """
    worktree_root = pathlib.Path(worktree_root)
    stems = {}
    notes = {}
    unreadable = []
    for p in sorted(worktree_root.rglob("*")):
        if p.is_dir() or ".git" in p.parts:
            continue
        rel = p.relative_to(worktree_root).as_posix()
        if rel.startswith("."):
            continue
        if p.suffix in (".md", ".canvas"):
            stems.setdefault(p.stem, []).append(rel)
        if p.suffix == ".md":
            try:
                notes[rel] = p.read_text(encoding="utf-8")
            except OSError as e:
                unreadable.append(f"{rel}: {e}")
                continue

    broken = []
    for rel, text in notes.items():
        _, body = vi.parse_frontmatter(text)
        for raw in vi.LINK_RE.findall(vi.CODE_RE.sub("", body)):  # 本家と同一の除外（フェンス＋インラインコード内の書式例）＝2026-07-12 初回マージで誤検知修正
            target = raw.split("|")[0].split("#")[0].strip()
            if not target:
                continue
            if "/" in target:
                if not ((worktree_root / f"{target}.md").exists()
                        or (worktree_root / f"{target}.canvas").exists()
                        or (worktree_root / target).exists()):
                    broken.append((rel, raw))
            elif target not in stems:
                broken.append((rel, raw))
    return {"broken_links": broken, "unreadable": unreadable, "pass": not (broken or unreadable)}


def find_git_root(path):
    """pathの親ディレクトリからgitリポジトリのトップレベルを探す。見つからなければNone。"""
    try:
        proc = subprocess.run(["git", "-C", str(pathlib.Path(path).parent), "rev-parse", "--show-toplevel"],
                               capture_output=True, text=True, timeout=10)
    except OSError:
        return None
    if proc.returncode != 0:
        return None
    return pathlib.Path(proc.stdout.strip())


def git_status_porcelain(repo_root, relpath):
    """指定パス1件分の `git status --porcelain` 出力を返す。gitコマンド自体が
    失敗した場合はGateErrorを送出する（安全性を確認できない＝fail-closed）。"""
    proc = subprocess.run(["git", "-C", str(repo_root), "status", "--porcelain", "--", relpath],
                           capture_output=True, text=True, timeout=15)
    if proc.returncode != 0:
        raise GateError(f"git status に失敗しました（{relpath}）: {proc.stderr.strip()}")
    return proc.stdout


def assert_git_tracked(repo_root, relpath):
    """`git status --porcelain`だけでは「追跡されていて差分0」と「そもそも
    追跡されておらず(.gitignore等で)無視されている未追跡ファイル」を区別できない
    （後者もstatus出力は空になる・Codexレビュー指摘・Major）。`git ls-files`で
    実際に追跡対象であることを独立確認する。"""
    proc = subprocess.run(["git", "-C", str(repo_root), "ls-files", "--error-unmatch", "--", relpath],
                           capture_output=True, text=True, timeout=15)
    if proc.returncode != 0:
        raise GateError(
            f"ベンチTSVがgitの追跡対象ではありません（未追跡/.gitignore等・安全性確認不可・即block): {relpath}")


def assert_bench_tsv_untouched(bench_tsv_path):
    """FR12a(1): ベンチTSV本体がgate処理によって書き換えられていないことを
    機械アサートする。git管理下に無い、または追跡されていないファイルは安全性を
    確認できないため、存在の有無に関わらずGateErrorで即block（fail-closed）にする。
    戻り値: (repo_root, relpath)。呼び出し側は処理完了後にも同じ引数で再度呼び、
    差分が生じていないかをもう一度確認すること（実行前後の二重チェック）。
    """
    bench_tsv_path = pathlib.Path(bench_tsv_path).resolve()
    if not bench_tsv_path.is_file():
        raise GateError(f"ベンチTSVが見つかりません: {bench_tsv_path}")
    repo_root = find_git_root(bench_tsv_path)
    if repo_root is None:
        raise GateError(f"ベンチTSVがgit管理下にありません（安全性確認不可・即block): {bench_tsv_path}")
    relpath = bench_tsv_path.relative_to(repo_root).as_posix()
    assert_git_tracked(repo_root, relpath)
    status = git_status_porcelain(repo_root, relpath)
    if status.strip():
        raise GateError(
            f"ベンチTSVに未コミット差分が検出されました（改ざん疑い・即block): {relpath}\n{status}",
            bench_repo=str(repo_root), bench_relpath=relpath)
    return repo_root, relpath


def remap_bench_tsv(bench_tsv_text, path_map):
    """ベンチTSV（recall_bench.pyのparse_bench_tsv形式）の期待ノートパス列だけを
    旧→新パス対応表(path_map: {旧relpath: 新relpath})で機械的に付け替えたテキストを
    返す。質問文・コメント行・ノイズ検査行("-"1文字)・列数自体は変更しない。
    同一行内で複数の旧パスが同じ新パスへ収束する場合は重複を除いて1つにまとめる。
    """
    out_lines = []
    for raw in bench_tsv_text.splitlines():
        line = raw.rstrip("\r")
        if not line.strip() or line.lstrip().startswith("#"):
            out_lines.append(line)
            continue
        parts = line.split("\t")
        if len(parts) != 2:
            out_lines.append(line)  # 想定外の形式はそのまま通す（parse側で従来どおりWARN/skip）
            continue
        question, expected_field = parts
        if expected_field.strip() == "-":
            out_lines.append(line)
            continue
        items = [e.strip() for e in expected_field.split("|") if e.strip()]
        remapped = []
        for item in items:
            new_item = path_map.get(item, item)
            if new_item not in remapped:
                remapped.append(new_item)
        out_lines.append(f"{question}\t{'|'.join(remapped)}")
    return "\n".join(out_lines) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="FR12aマージ品質ゲート（構造差分検査・単体実行用の最小CLI。"
                     "recall回帰ベンチはknowledge_merge.py gateが担当）。")
    ap.add_argument("--orig-note-a", required=True, help="原ノートAの原文ファイル")
    ap.add_argument("--orig-note-b", required=True, help="原ノートBの原文ファイル")
    ap.add_argument("--merged-note", required=True, help="統合ノート案ファイル")
    ap.add_argument("--worktree", help="リンク切れチェック対象のworktreeルート（省略時はskip）")
    args = ap.parse_args(argv)

    orig_a = pathlib.Path(args.orig_note_a).read_text(encoding="utf-8")
    orig_b = pathlib.Path(args.orig_note_b).read_text(encoding="utf-8")
    merged_text = pathlib.Path(args.merged_note).read_text(encoding="utf-8")
    fm_a, _ = vi.parse_frontmatter(orig_a)
    fm_b, _ = vi.parse_frontmatter(orig_b)
    fm_merged, _ = vi.parse_frontmatter(merged_text)

    result = {
        "structural": check_structural(orig_a, orig_b, merged_text),
        "aliases": check_aliases_union(fm_a, fm_b, fm_merged),
        "frontmatter_required_keys": check_frontmatter_required_keys(fm_a, fm_b, fm_merged),
    }
    if args.worktree:
        result["broken_links"] = check_broken_links(args.worktree)

    import json
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if all(v.get("pass", True) for v in result.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
