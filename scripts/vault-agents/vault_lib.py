#!/usr/bin/env python3
"""外部脳(Obsidian Vault)の複数スクリプトが共有する薄いライブラリ
（2026-07-16簡素化・cleanup決定#10「共有ロジックの分離原則」・PR1.5②）。

抽出元と抽出理由:
  - frontmatter解析(parse_frontmatter)・wikilink正規表現(LINK_RE)・
    aliases正規化(normalize_aliases)・汎用alias禁止リスト読込
    (load_generic_aliases) は scripts/vault-agents/vault_inventory.py に
    定義されていたが、CLI（棚卸し検出）と共有ライブラリが同一ファイルに同居していた
    （embedding_index.py・knowledge_merge_candidates.py・knowledge_merge.py・
    merge_quality_gate.py・recall_bench.py が `import vault_inventory` して
    これらの関数だけを使っていた＝2026-07-15棚卸しレポートで指摘された構造）。
    本ファイルへ抽出し、vault_inventory.py 自身も含め全員がここを参照する側へ回る。
  - apply_updated・write_note_atomic・require_generic_aliases・parse_tsv・
    process_note・find_aliases_block・build_aliases_block・strip_quotes・
    split_flow_list は scripts/vault-agents/apply_aliases.py に定義されていた
    alias一括適用ロジック。PR2の maintenance_apply.py（当初はFIX機能の
    missing_updated適用のためだったが、FIXは2026-07-18本人裁定で削除済み＝
    [[Decisions/2026-07-18-external-brain-hardening]]。現在はMERGE時の原ノート
    スタブ化＝build_merge_stub_text()がupdated:更新にapply_updatedを再利用する）
    がapply_updated/write_note_atomicを再利用するために先出しで共有化した
    のが最初の動機（設計書§3.5）だが、Codexレビュー指摘・Major対応でスコープを
    拡大した: recall_bench.py（--alias-overlayのオーバーレイ適用）が
    process_note/parse_tsv/require_generic_aliasesも必要としており、これらを
    apply_aliases.py側に残したままだと`import apply_aliases`が全廃できず
    （設計書「import apply_aliases は全廃」の要件を満たせない）、かつ
    apply_aliases.py↔recall_bench.pyの2ファイル間で「共有で使っているもの」の
    分離原則（cleanup決定#10）にも反する。よって alias 一括適用の再利用可能な
    純粋関数一式をここへ集約し、apply_aliases.py自身もCLI（argparse・diff表示・
    ファイルI/O orchestration）専業へ縮小した。

方針: 本ファイルは「複数ファイルから使われる純粋な解析・書込ヘルパ」のみを置く。
各CLIツール固有のビジネスロジック（棚卸しの各チェック項目・非破壊マージ判定 等）は
これまでどおり元のファイルに残す。
"""
import os
import pathlib
import re
import sys
import stat
import tempfile

# --- frontmatter解析（旧 vault_inventory.py） ---------------------------------

# `aliases: [] # 未使用` のような行末コメントを除去する（直前が空白/行頭の#以降を
# YAML風コメントとみなす）。
INLINE_COMMENT_RE = re.compile(r"(?<!\S)#.*$")


def strip_inline_comment(s):
    """`aliases: [] # 未使用` のような行末コメントを除去する。"""
    return INLINE_COMMENT_RE.sub("", s).strip()


def parse_frontmatter(text):
    """frontmatterをキー→値の辞書にする。既存の単一行 `key: value` はそのまま文字列で
    返す。値が空の行（`key:` のみ）の直後に YAML の複数行リスト（`  - item`）が
    続く場合はそれをリストとして拾う（aliases 等の検出用）。フロー形式リスト
    （`key: [a, b]`）もリストにする。行末の `# comment` は除去する。

    戻り値: (frontmatter辞書, frontmatterブロックを除いた本文)。frontmatterが
    無い（先頭が `---` で始まらない等）場合は ({}, text) をそのまま返す。
    """
    m = re.match(r"---\n(.*?)\n---\n?", text, re.S)
    if not m:
        return {}, text
    fm = {}
    lines = m.group(1).splitlines()
    i = 0
    while i < len(lines):
        kv = re.match(r"(\w+):\s*(.*)", lines[i])
        if not kv:
            i += 1
            continue
        key, val = kv.group(1), strip_inline_comment(kv.group(2).strip())
        if val:
            if val.startswith("[") and val.endswith("]"):
                fm[key] = [x.strip().strip('"').strip("'") for x in val[1:-1].split(",") if x.strip()]
            else:
                fm[key] = val.strip('"')
            i += 1
            continue
        # 値が空 -> 複数行リストの可能性を見る（無ければ従来どおりキーごと無視）
        items = []
        j = i + 1
        while j < len(lines):
            bm = re.match(r"\s+-\s+(.+)", lines[j])
            if not bm:
                break
            item = strip_inline_comment(bm.group(1))
            if item:
                items.append(item.strip('"').strip("'"))
            j += 1
        if items:
            fm[key] = items
            i = j
        else:
            i += 1
    return fm, text[m.end():]


# wikilink（[[...]]）検出用の正規表現（vault_inventory.py §3 リンク切れ検査・
# その他のリンク集計で使用）。
LINK_RE = re.compile(r"\[\[([^\[\]]+?)\]\]")

# コードフェンス（```〜```）・インラインコード（`〜`）検出用の正規表現。リンク切れ
# 検査等で「コード例の中に書式として出てくる[[...]]やURL」を誤検知しないために
# 本文から除外する用途で使う（2026-07-16 merge_checks.py新設に伴いvault_inventory.py
# から抽出＝設計書§2.5「import vault_inventoryは全廃」の対象を将来の共有モジュール
# にも適用）。
CODE_RE = re.compile(r"```.*?```|`[^`\n]*`", re.S)


def normalize_aliases(val):
    """frontmatterの aliases 値（リスト/カンマ区切り文字列/未設定）を alias文字列のリストにする。"""
    if not val:
        return []
    items = val if isinstance(val, list) else re.split(r"[,、]", val)
    return [x.strip() for x in items if x.strip()]


def load_generic_aliases(path):
    """汎用alias禁止リストファイル（1行1語・#コメント可）を読み、小文字化した
    禁止語の集合を返す。ファイルが存在しなければ空集合を返す（fail-openな
    純粋関数。欠落/空を異常として扱うかどうかは呼び出し側の責務＝
    本ファイルのrequire_generic_aliases()のような判断はここでは行わない）。

    `path` はどのファイルを読むか（既定パス・環境変数上書き等）を呼び出し側が
    解決してから渡す（各CLIごとにGENERIC_ALIASES_FILEの解決方法＝環境変数名等が
    異なるため、本関数は「渡されたパスを読む」ことだけに専念する）。
    """
    words = set()
    path = pathlib.Path(path)
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            word = line.split("#", 1)[0].strip()
            if word:
                words.add(word.lower())
    return words


# --- ノート書込ヘルパ（旧 apply_aliases.py） -----------------------------------
# 「候補ID方式（旧 vault_inventory.py）」節にあった stable_fix_id() は、FIX機能
# （棚卸しmissing_updatedの機械修正）が2026-07-18本人裁定で丸ごと削除された
# ことに伴い不要になったため撤去した（[[Decisions/2026-07-18-external-brain-
# hardening]]2周目。旧実装はgit log -p参照）。

_UPDATED_LINE_RE = re.compile(r"^updated:\s*.*$")
_DATE_LINE_RE = re.compile(r"^date:\s*.*$")


def apply_updated(lines, today):
    """updated: を today に更新する（無ければ date: の直後に挿入、date: も無ければ
    先頭に挿入）。`lines` はfrontmatterブロック内の行リスト（呼び出し側が既に
    frontmatter範囲を切り出し済みの前提）。破壊的に書き換えて同じリストを返す。
    """
    for i, line in enumerate(lines):
        if _UPDATED_LINE_RE.match(line):
            lines[i] = f"updated: {today}"
            return lines
    for i, line in enumerate(lines):
        if _DATE_LINE_RE.match(line):
            lines.insert(i + 1, f"updated: {today}")
            return lines
    lines.insert(0, f"updated: {today}")
    return lines


def write_note_atomic(path, text):
    """ノートへのtext書込みをatomicに行う（2026-07-14修正・リーダー指示: 従来の
    `path.write_text()` 直書きは非atomicで、書込み中のクラッシュ・強制終了・
    ディスク枯渇等で部分書込（frontmatterが壊れた中途半端な内容）がそのまま
    正規パスに残るリスクがあった）。同ディレクトリに一時ファイルを作って書き込み、
    os.replace()で置き換える。この方式なら書込み完了前にプロセスが死んでも、
    正規パスの内容は「更新前の全文」か「更新後の全文」のいずれかにしかならない
    （POSIXのos.replaceは同一ファイルシステム内でatomicなrenameを保証。同じ
    ディレクトリへ一時ファイルを作るため別ファイルシステムを跨ぐ心配が無い）。

    呼び出し側の注意（Codex一次レビュー指摘・Major）: `path` がsymlinkの場合、
    os.replace()はリンクそのものを通常ファイルへ置き換えてしまいリンク先は
    更新されない。symlinkノートを扱う呼び出し側は、解決済みの実体パスを渡すこと。

    新規ファイル作成（上書き防止が必要な場面）にはこの関数を使わない
    （os.replaceは対象が存在しなくても常に成功してしまうため上書き防止にならない
    ＝設計書§2.4改訂v2。新規作成は呼び出し側で
    `os.open(path, O_CREAT|O_EXCL|O_WRONLY)` を使う）。本関数は既存ファイルの
    部分編集（updated書換・マージ時の原ノートstub化等）専用。
    """
    path = pathlib.Path(path)
    # 既存ファイルのパーミッションを一時ファイルへ引き継ぐ（Codex一次レビュー指摘・
    # Major: tempfile.mkstemp()は既定0600で作成するため、対策なしだと
    # os.replace()後にノートの元パーミッション(例: 0644)が0600へ変わってしまう）。
    # 新規作成（既存ファイルが無い）の場合はNoneのままにし、mkstemp()の既定
    # （プロセスumask適用済みの0600）に委ねる。
    original_mode = None
    try:
        original_mode = stat.S_IMODE(path.stat().st_mode)
    except OSError:
        original_mode = None
    fd, tmp_path = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.", suffix=".tmp")
    fd_owned_by_file_obj = False  # os.fdopen()が成功しfdの所有権をfileオブジェクトへ渡したか
    try:
        if original_mode is not None:
            os.fchmod(fd, original_mode)  # ここで失敗した場合、fdはまだ生の整数のまま
        f = os.fdopen(fd, "w", encoding="utf-8")
        fd_owned_by_file_obj = True  # 以降はf.close()がfdのcloseを担う（os.close()と併用しない）
        try:
            f.write(text)
        finally:
            f.close()
        os.replace(tmp_path, path)
    except BaseException:
        # KeyboardInterrupt等のBaseException（Exceptionのサブクラスではない）でも
        # 一時ファイルを残さない。os.fchmod()やos.fdopen()自体が失敗した場合、fdは
        # まだfileオブジェクトに包まれておらず生の整数のままなので、二重closeを
        # 避けつつここで明示的にcloseする。
        if not fd_owned_by_file_obj:
            try:
                os.close(fd)
            except OSError:
                pass
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


# --- alias一括適用ロジック（旧 apply_aliases.py） -------------------------------

# parse_frontmatter()が読める2形式（フロー配列・ブロックリスト）を書く/読む側でも
# 同じ形式として扱う。
FRONTMATTER_RE = re.compile(r"^---\n(.*?)\n---\n?", re.S)
ALIASES_INLINE_RE = re.compile(r"^aliases:\s*\[(.*)\]\s*$")
ALIASES_BLOCK_START_RE = re.compile(r"^aliases:\s*$")
BLOCK_ITEM_RE = re.compile(r"^\s+-\s*(.*)$")


def require_generic_aliases(path):
    """load_generic_aliases(path)を呼び、欠落/空ならfail-closedでプロセスを
    終了する（exit 1）。

    リストが欠落/空の状態は「汎用語チェックが安全に機能しない」ことを意味し、
    load_generic_aliases()単体（空集合を返すだけの純粋関数）を直接呼ぶ全ての
    呼び出し元（apply_aliases.py main()・recall_bench.py build_overlay_vault()―
    どちらも独立した呼び出し元で重複実装するとfail-closedの抜け漏れが起きやすい
    ため、ここへ集約する）が共通してこの関数を経由する契約にする。書き込み・
    採点いずれの用途でも、チェックが機能しない状態のまま処理を続けない。
    """
    path = pathlib.Path(path)
    if not path.exists():
        print(f"FAIL: {path} が見つかりません。汎用語禁止チェックを安全に"
              "行えないため中断します（fail-closed）。", file=sys.stderr)
        sys.exit(1)
    words = load_generic_aliases(path)
    if not words:
        print(f"FAIL: {path} に有効な語が1つもありません。汎用語禁止チェックを"
              "安全に行えないため中断します（fail-closed）。", file=sys.stderr)
        sys.exit(1)
    return words


def strip_quotes(s):
    """前後のクォートを外す。ダブルクォートは `\\"` `\\\\` 等のエスケープを
    build_aliases_block() と対称に解除し、シングルクォートはYAML流儀の `''` → `'`
    エスケープを解除する（Codexレビュー指摘・Major/Minor: 単純な strip('"') だと
    エスケープされた引用符を含む既存aliasを壊す）。"""
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in ("'", '"'):
        inner = s[1:-1]
        if s[0] == '"':
            inner = re.sub(r"\\(.)", r"\1", inner)
        else:
            inner = inner.replace("''", "'")
        return inner
    return s


def split_flow_list(inner):
    """フロー配列の中身（例: `a, "b, c", d`）を、クォート内のカンマでは分割しない
    ように1文字ずつ走査して分割する（Codexレビュー指摘・Major: 単純な
    `.split(",")` だと `aliases: ["foo, bar"]` のようなクォート内カンマを含む
    既存aliasが誤って2つに割れてしまう）。"""
    items, cur, quote, i, n = [], [], None, 0, len(inner)
    while i < n:
        ch = inner[i]
        if quote:
            if ch == "\\" and i + 1 < n:
                cur.append(ch)
                cur.append(inner[i + 1])
                i += 2
                continue
            cur.append(ch)
            if ch == quote:
                quote = None
            i += 1
            continue
        if ch in ("'", '"'):
            quote = ch
            cur.append(ch)
            i += 1
            continue
        if ch == ",":
            items.append("".join(cur))
            cur = []
            i += 1
            continue
        cur.append(ch)
        i += 1
    items.append("".join(cur))
    return [strip_quotes(x) for x in items if x.strip()]


def parse_tsv(path):
    """TSV（相対パス<TAB>alias1|alias2|...）を (relpath, [alias, ...]) のリストにする。
    空行・#始まりの行はコメントとしてskip。壊れた行はWARNしてskip（fail-open）。
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
        relpath = parts[0].strip()
        if not relpath.endswith(".md"):
            relpath += ".md"
        aliases = [a.strip() for a in parts[1].split("|") if a.strip()]
        if not aliases:
            print(f"WARN: {path}:{lineno}: aliasが1つもありません。skipします: {raw!r}", file=sys.stderr)
            continue
        rows.append((relpath, aliases))
    return rows


def find_aliases_block(lines):
    """frontmatter行リストから既存の aliases: ブロックを探す。
    戻り値: (start_idx, end_idx_exclusive, existing_aliases)。無ければ (None, None, [])。
    """
    for i, line in enumerate(lines):
        m = ALIASES_INLINE_RE.match(line)
        if m:
            return i, i + 1, split_flow_list(m.group(1))
        if ALIASES_BLOCK_START_RE.match(line):
            j = i + 1
            items = []
            while j < len(lines):
                bm = BLOCK_ITEM_RE.match(lines[j])
                if not bm:
                    break
                items.append(strip_quotes(bm.group(1)))
                j += 1
            return i, j, items
    return None, None, []


def build_aliases_block(aliases):
    """related: と同じ書式（ブロックリスト・ダブルクォート）で aliases: ブロックを作る。"""
    out = ["aliases:"]
    for a in aliases:
        safe = a.replace("\\", "\\\\").replace('"', '\\"')
        out.append(f'  - "{safe}"')
    return out


def process_note(text, new_aliases, generic_words, today):
    """1ノート分のテキストを処理し、結果dictを返す（書き込みはしない・純粋関数）。

    戻り値のキー:
      error            frontmatterが無い等でskipすべき理由（無ければNone）
      existing         既存のaliases（重複除去はしない・見つかった順）
      added            今回新たに追加するalias（generic該当・既存重複は含まない）
      skipped_generic  generic-aliases.txt該当のためskipしたalias
      changed          実際にファイルを書き換える必要があるか
      new_text         changed=Trueのときの新テキスト（Falseならtextと同一）
    """
    m = FRONTMATTER_RE.match(text)
    if not m:
        return {"error": "frontmatterが見つかりません（'---'で始まっていない）"}

    lines = m.group(1).split("\n")
    rest = text[m.end():]

    start, end, existing = find_aliases_block(lines)
    existing_set = set(existing)

    to_add, skipped_generic, seen = [], [], set(existing_set)
    for a in new_aliases:
        if a in seen:
            continue
        if a.lower() in generic_words:
            skipped_generic.append(a)
            continue
        to_add.append(a)
        seen.add(a)

    if not to_add:
        return {
            "error": None, "existing": existing, "added": [], "skipped_generic": skipped_generic,
            "changed": False, "new_text": text,
        }

    merged = existing + to_add
    block = build_aliases_block(merged)
    new_lines = (lines + block) if start is None else (lines[:start] + block + lines[end:])
    new_lines = apply_updated(new_lines, today)

    new_text = "---\n" + "\n".join(new_lines) + "\n---\n" + rest
    return {
        "error": None, "existing": existing, "added": to_add, "skipped_generic": skipped_generic,
        "changed": True, "new_text": new_text,
    }
