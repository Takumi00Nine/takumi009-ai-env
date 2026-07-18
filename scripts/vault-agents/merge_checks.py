#!/usr/bin/env python3
"""Knowledgeマージ品質ゲートの構造チェック（設計書§2.5「merge_checks.py（新設・
merge_quality_gate.pyから抽出温存）」）。

2026-07-16簡素化（[[Decisions/2026-07-16-simplification-item-cleanups]]決定#7
「merge_quality_gate.pyの検証ロジック温存」）に伴い、削除された
scripts/vault-agents/merge_quality_gate.py（旧・knowledge_merge.py gateサブ
コマンドから使われていたマージ品質ゲート本体）から、以下の構造チェック
（~150行）**のみ**を抽出温存し、他は削除した:
  - 見出し文字列の残存（check_structural）
  - コードブロック/URL不変（check_structural）
  - 日付不変（check_structural）
  - frontmatter必須キー（check_frontmatter_required_keys）
  - aliases和集合（check_aliases_union）
  - リンク切れ無し（check_broken_links）

削除したもの（設計書§2.5「CLI・worktree・ALERT機構は削除」）:
  - argparse CLI・単体実行用main()
  - recall_bench.py用ベンチTSVの旧→新パス付け替え(remap_bench_tsv)・
    git worktree改ざん検知(assert_bench_tsv_untouched等)・GateError例外・
    ALERT生成連携。これらは「Codexによる敵対的レビュー（主張/数値/否定の
    保存検査）」を組み込んだ旧・knowledge_merge.py gateオーケストレーション
    専用の仕組みであり、その仕組み自体を設計書§2.7で明示的に不採用とした
    （「旧CLIの『主張/数値/否定の保存検査』は移植しない＝Decision『検出精度の
    低下は受容』の延長として明示的に受容」）ため、あわせて削除した。

利用元: scripts/vault-agents/maintenance_apply.py（PR2・未実装）のMERGE action
適用直前ゲート（設計書§2.4「MERGE: ...merge_checks.py（§2.5）全PASS必須。
PASSしなければ適用せずskip扱い」）。

本モジュールは純粋な検査関数の集まりであり、Vaultへの書込は一切行わない。
frontmatter解析・wikilink正規表現・コードブロック除外正規表現は
scripts/vault-agents/vault_lib.py（vault_inventory.pyの共有ロジック抽出先。
本モジュールも同じ理由でvault_lib側を参照し、`import vault_inventory`は
行わない＝設計書§3.2「import vault_inventoryは全廃」の趣旨を新設の共有
モジュールにも適用する）を再利用する。
"""
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import vault_lib  # noqa: E402

HEADING_RE = re.compile(r"^(#{1,6})\s+(.+?)\s*$", re.M)
CODE_BLOCK_RE = re.compile(r"```.*?```", re.S)
URL_RE = re.compile(r"https?://[^\s)\]}\"'>]+")
DATE_RE = re.compile(r"\b20\d{2}-\d{2}-\d{2}\b")

# frontmatter必須項目チェックから除外するキー（新ノートで正当に変わる/新規発生する項目）。
# aliasesは専用のcheck_aliases_union()で別途「和集合になっているか」を厳密に見るため
# ここでは除外する（このチェックは「存在するか」だけを見る単純比較のため）。
DEFAULT_FRONTMATTER_EXEMPT_KEYS = frozenset(
    {"aliases", "updated", "date", "deprecated", "superseded_by", "review_by"})


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
    """見出し文字列の残存・コードブロック/URL不変・日付不変（設計書§2.5）:
    両原ノートの見出し・コードブロック・出典URL・日付が統合ノートへ残存しているかを
    機械差分検査する。claim preservation（意味保持。数値改変・意味反転が無いか等）
    自体は判定しない（設計書§2.7で明示的に不採用とした敵対的レビュー相当の役目）。
    missing_* が全て空なら pass=True。
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
    """aliases和集合（設計書§2.5・AC6相当）: 統合ノートのaliasesが両原ノート
    aliasesの和集合を包含しているか。"""
    need = set(vault_lib.normalize_aliases(fm_a.get("aliases"))) | set(vault_lib.normalize_aliases(fm_b.get("aliases")))
    have = set(vault_lib.normalize_aliases(fm_merged.get("aliases")))
    missing = sorted(need - have)
    return {"missing_aliases": missing, "pass": not missing}


def check_frontmatter_required_keys(fm_a, fm_b, fm_merged, exempt_keys=None):
    """frontmatter必須キー（設計書§2.5）: 両原ノートのfrontmatterキー（正当に
    変わりうるキーを除く）が統合ノートのfrontmatterにも存在するか（値の一致までは
    求めない＝キーの存在のみ）。
    """
    exempt = exempt_keys if exempt_keys is not None else DEFAULT_FRONTMATTER_EXEMPT_KEYS
    need = (set(fm_a) | set(fm_b)) - set(exempt)
    missing = sorted(k for k in need if k not in fm_merged)
    return {"missing_keys": missing, "pass": not missing}


def check_broken_links(vault_root, overlays=None):
    """リンク切れ無し（設計書§2.5・AC6相当）: vault_root配下全体のwikilinkリンク
    切れが0件かを機械チェックする。vault_lib.py の parse_frontmatter/LINK_RE/
    CODE_RE をそのまま再利用する（リンク解析ロジックを重複実装してドリフト
    させない＝旧merge_quality_gate.pyと同じ方針）。
    読込に失敗したノート（権限エラー・非UTF-8等）は検査対象から静かに除外しない
    （fail-closed方針＝リンク切れが隠れている可能性を無視できないためpass=Falseに
    する。旧merge_quality_gate.pyのCodexレビュー指摘対応をそのまま踏襲。加えて
    vault_rootが存在しない/ディレクトリでない場合や、リンク先がvault_root外へ
    脱出する場合もfail-closedにする＝2026-07-16 Codexレビュー指摘Major対応:
    存在しないパスや通常ファイルを渡すと「空Vaultだから壊れたリンク0件」で
    誤ってpass=Trueになっていた欠陥、および`../`等でvault_root外の実在ファイルへ
    解決されてしまうと壊れているはずのリンクを正常扱いしかねない欠陥を修正）。
    ディスク上のファイルが実体はVault外へのsymlinkである場合も、その中身を
    正常なリンク先として読み込まない（多層防御。knowledge_merge_candidates.py
    のis_active_note()と同じ考え方＝2026-07-16 Codex 2巡目レビュー指摘Minor対応）。

    overlays（省略可・`{relpath: 本文テキスト}`）を渡すと、ディスク上の実ファイル
    より優先してその内容を検査対象に重ねる（実在有無を問わない＝新規作成予定の
    ノートも指定できる）。これにより、maintenance_apply.py（未実装）がMERGE
    適用の**書込前**に「適用後Vaultの状態」を検査できる（設計書§2.4「全PASS
    必須。PASSしなければ適用せずskip扱い」を書込前に満たすための仕組み。
    旧・merge_quality_gate.pyの「隔離git worktreeへ書き込んで検査する」仕組みの
    代替＝2026-07-16 Codex 2巡目レビュー指摘Major対応: 当初docstringのみの修正で
    済ませたが「書込前に呼べば良い」だけでは統合ノート案自体を検査できておらず
    不十分との指摘を受け、overlay機構を追加した）。呼び出し側の想定使用例:
    `check_broken_links(vault_root, overlays={
        "Knowledge/merged-note.md": merged_text,
        "Knowledge/orig-a.md": stub_a_text,
        "Knowledge/orig-b.md": stub_b_text,
    })`
    """
    vault_root = pathlib.Path(vault_root).resolve()
    if not vault_root.is_dir():
        return {"broken_links": [], "unreadable": [f"vault_rootがディレクトリではありません: {vault_root}"], "pass": False}

    # overlayのキーを検証する（2026-07-16 Codex 3巡目レビュー指摘Major対応:
    # 絶対パス・".."・空文字列等をキーに渡すとVault境界チェックを迂回できて
    # いたため、ここで拒否しfail-closedにする。値が文字列でない場合も同様）。
    raw_overlays = overlays or {}
    overlays = {}
    invalid_overlay_keys = []
    for raw_key, value in raw_overlays.items():
        key = pathlib.PurePosixPath(str(raw_key)).as_posix()
        parts = pathlib.PurePosixPath(key).parts
        if (not key or key in (".", "/") or key.startswith("/")
                or ".." in parts or not isinstance(value, str)):
            invalid_overlay_keys.append(raw_key)
            continue
        overlays[key] = value
    if invalid_overlay_keys:
        return {
            "broken_links": [],
            "unreadable": [f"不正なoverlayキー(絶対パス/'..'/空文字列等・Vault相対の"
                            f"POSIXパスのみ許可): {invalid_overlay_keys!r}"],
            "pass": False,
        }

    stems = {}
    notes = {}
    unreadable = []
    for p in sorted(vault_root.rglob("*")):
        if p.is_dir() or ".git" in p.parts:
            continue
        rel = p.relative_to(vault_root).as_posix()
        if rel.startswith("."):
            continue
        if p.is_symlink():
            # symlink先がVault外の任意ファイルである可能性を排除する（多層防御・
            # knowledge_merge_candidates.pyのis_active_note()と同じ考え方）。
            # overlayで明示的に上書き予定のパスならoverlay側の内容を信頼して
            # 読み進めるが、overlay指定が無いsymlinkノートは「検査できない」
            # として静かに除外せずfail-closedにする（2026-07-16 Codex 3巡目
            # レビュー指摘Minor対応: symlinkノート自身が持つリンクが未検査の
            # まま素通りしていた）。
            if rel not in overlays:
                unreadable.append(f"{rel}: symlink（Vault外参照の可能性があるため検査不能・fail-closed）")
            continue
        if rel in overlays:
            continue  # overlayが優先するため、ディスク上の現行内容は読まない
        if p.suffix in (".md", ".canvas"):
            stems.setdefault(p.stem, []).append(rel)
        if p.suffix == ".md":
            try:
                notes[rel] = p.read_text(encoding="utf-8")
            except (OSError, UnicodeError) as e:
                unreadable.append(f"{rel}: {e}")
                continue

    # overlaysを「適用後Vault」として重ねる（新規作成予定のノートも含め、実在有無を
    # 問わず対象にする）。
    for rel, text in overlays.items():
        if rel.endswith((".md", ".canvas")):
            stem = pathlib.PurePosixPath(rel).stem
            stems.setdefault(stem, [])
            if rel not in stems[stem]:
                stems[stem].append(rel)
        if rel.endswith(".md"):
            notes[rel] = text

    def _resolves_within_vault(candidate_rel):
        """candidate_rel(vault_root相対のrelpath文字列)がoverlayに含まれるか、
        またはディスク上に実在し解決後もvault_root配下に留まっているかを返す
        （`../`等によるVault外への脱出を壊れていないリンクと誤判定しないため）。"""
        if candidate_rel in overlays:
            return True
        candidate = vault_root / candidate_rel
        if not candidate.exists():
            return False
        try:
            resolved = candidate.resolve()
        except OSError:
            return False
        return resolved == vault_root or resolved.is_relative_to(vault_root)

    broken = []
    for rel, text in notes.items():
        _, body = vault_lib.parse_frontmatter(text)
        # フェンス＋インラインコード内の書式例（リンクの書き方を説明する引用等）を
        # 誤検知しないよう除外する（2026-07-12 旧実装での実際の誤検知修正を踏襲）。
        for raw in vault_lib.LINK_RE.findall(vault_lib.CODE_RE.sub("", body)):
            target = raw.split("|")[0].split("#")[0].strip()
            if not target:
                continue
            if target.startswith("/"):
                # 絶対パス表記のリンクはVault相対リンクの記法として想定していない
                # （Obsidianのwikilinkは常にVaultルート相対）ため安全側でbroken扱いにする。
                broken.append((rel, raw))
                continue
            if "/" in target:
                candidates = [f"{target}.md", f"{target}.canvas", target]
                if not any(_resolves_within_vault(c) for c in candidates):
                    broken.append((rel, raw))
            elif target not in stems:
                broken.append((rel, raw))
    return {"broken_links": broken, "unreadable": unreadable, "pass": not (broken or unreadable)}


def run_all_checks(orig_text_a, orig_text_b, merged_text, vault_root, overlays):
    """maintenance_apply.pyのMERGE action適用ゲート用エントリポイント。上記
    チェック全項目（broken_links含む）を必ず全て実行し、`{"pass": bool, ...各
    チェック結果}`を返す（設計書§2.4「merge_checks.py（§2.5）全PASS必須。PASS
    しなければ適用せずskip扱い」＝一部チェックだけを省略して通せる抜け道を作らない
    ため、vault_rootは必須引数にした＝2026-07-16 Codexレビュー指摘Major対応）。

    frontmatterは呼び出し元から別途受け取らず、この関数内で3本文から
    vault_lib.parse_frontmatter()を実行する（呼び出し元が本文と食い違う/古い
    frontmatter辞書を誤って渡す事故を構造的に防ぐ＝2026-07-16 Codexレビュー
    指摘Minor対応）。

    overlaysは**必須引数**（省略不可・2026-07-16リーダー裁定）: 「merged_text
    ＝これから書き込む統合ノート案自体に含まれるリンクが検査されない」という
    抜け道が存在すること自体が、設計書§2.4「merge_checks.py全PASS必須」を
    構造的に骨抜きにする（docstringでの注意書き運用に頼るのは今回の簡素化が
    廃止した「コメントで運用を縛る」設計への逆戻り）と判断し、Python関数の
    シグネチャレベルで省略不可にした。加えて、`None`や`{}`（空dict）が明示的に
    渡された場合も「これから書き込む内容が一切検査されていない」状態のまま
    素通りしてしまうため、fail-closedで拒否する（下記参照）。
    呼び出し側（maintenance_apply.py）は必ず
    `overlays={<統合後に生き残るノートのrelpath>: merged_text, <stub化される原
    ノートのrelpath>: stub_text, ...}`
    のように、これから書き込む全ファイルの予定内容を渡すこと（統合後に生き残る
    ノートのrelpathは、maintenance_apply.pyのファイル命名方針＝リーダー裁定
    `Knowledge/<primaryのbasename>--merged-<YYYYMMDD>.md`に従って呼び出し側が
    決定する。本モジュールはファイル命名方針を持たない）。
    """
    if not overlays:
        return {
            "pass": False,
            "error": "overlaysは必須です（Noneまたは空dictは不可）。これから書き込む"
                     "全ファイル（統合ノート案・stub化される原ノート2件）の予定内容を"
                     "渡してください。",
        }
    fm_a, _ = vault_lib.parse_frontmatter(orig_text_a)
    fm_b, _ = vault_lib.parse_frontmatter(orig_text_b)
    fm_merged, _ = vault_lib.parse_frontmatter(merged_text)
    result = {
        "structural": check_structural(orig_text_a, orig_text_b, merged_text),
        "aliases": check_aliases_union(fm_a, fm_b, fm_merged),
        "frontmatter_required_keys": check_frontmatter_required_keys(fm_a, fm_b, fm_merged),
        "broken_links": check_broken_links(vault_root, overlays=overlays),
    }
    # v.get("pass", True)だとキー欠落を「成功」扱いしてしまう。ここでは
    # `is True`で厳密比較し、想定外の形式（pass省略・None等）は成功扱いにしない
    # （2026-07-16 Codexレビュー指摘Major対応・fail-closedの徹底）。
    result["pass"] = all(v.get("pass") is True for v in result.values())
    return result
