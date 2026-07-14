#!/usr/bin/env python3
"""外部脳(Obsidian Vault) alias 一括適用ユーティリティ（リーダーが手動実行する道具）。

使い方一覧＝Vault: Knowledge/tools-inventory.md／運用導線＝Projects/vault-hybrid-search.md

想起フック（claude/hooks/vault-recall.sh）はノートの frontmatter の `aliases:` と
ファイル名を照合キーにする。既存ノートの多くには aliases が無いため、棚卸し
（scripts/vault-agents/vault_inventory.py §9-10）や調査で見つけた候補alias群を
このツールでまとめて frontmatter へ書き込む。

入力: TSV（1行1ノート） `ノート相対パス<TAB>alias1|alias2|...`
  - 相対パスは --vault からの相対（拡張子省略時は自動で .md を補う）
  - alias は `|` 区切り。既存 aliases があれば和集合（重複は追加しない）

安全設計:
  - 既定は dry-run（差分を表示するだけ・書き込まない）。実際に書き込むには --apply。
  - frontmatter の aliases: ブロックと updated: 以外は一切変更しない（他フィールド・
    本文はテキストとしてそのまま温存する。full YAML round-tripはしない＝
    PyYAML等のフォーマット崩れリスクを避ける）。
  - `scripts/vault-agents/generic-aliases.txt`（別ツール vault_inventory.py §10 と
    共有の汎用語禁止リスト）に該当する alias は警告してそのノートへの追加をskipする。
    2026-07-14修正（外部脳の想起・ベンチ機構の総点検・Codex gpt-5.6-sol検証済み欠陥）:
    従来はこのリストが欠落/空でも「何もチェックしない」まま処理を続行する fail-open
    だったため、リスト破損時に汎用語が無警告で書き込まれかねなかった。現在は
    リストが存在しない、または有効な語を1つも含まない場合、書き込み前（dry-runでも）
    に fail-closed でエラー終了する。パスは `APPLY_ALIASES_GENERIC_FILE` 環境変数で
    差し替え可能（テスト用）。
  - PyYAML等の外部ライブラリは使わない（標準ライブラリのみ）。

使い方:
  scripts/vault-agents/apply_aliases.py aliases.tsv              # dry-run（差分表示のみ）
  scripts/vault-agents/apply_aliases.py aliases.tsv --apply      # 実際に書き込む
  scripts/vault-agents/apply_aliases.py aliases.tsv --vault DIR  # Vaultのルートを差し替え（テスト用）
"""
import argparse
import datetime
import difflib
import os
import pathlib
import re
import stat
import sys
import tempfile

VAULT = pathlib.Path.home() / "Data" / "obsidian"
# APPLY_ALIASES_GENERIC_FILE環境変数でテスト用に差し替え可能（既定はリポジトリ本体の
# generic-aliases.txt）。fail-closed化（後述load_generic_aliases/main()）のユニット
# テストで、本物のリストを汚さずに「欠落/空」状態を再現するために使う。
GENERIC_ALIASES_FILE = pathlib.Path(
    os.environ.get("APPLY_ALIASES_GENERIC_FILE", str(pathlib.Path(__file__).parent / "generic-aliases.txt")))

# vault_inventory.py の parse_frontmatter() が読める2形式（フロー配列・ブロックリスト）
# を書く/読む側でも同じ形式として扱う。
FRONTMATTER_RE = re.compile(r"^---\n(.*?)\n---\n?", re.S)
ALIASES_INLINE_RE = re.compile(r"^aliases:\s*\[(.*)\]\s*$")
ALIASES_BLOCK_START_RE = re.compile(r"^aliases:\s*$")
BLOCK_ITEM_RE = re.compile(r"^\s+-\s*(.*)$")
UPDATED_RE = re.compile(r"^updated:\s*.*$")
DATE_RE = re.compile(r"^date:\s*.*$")


def load_generic_aliases():
    """generic-aliases.txt を読み、小文字化した禁止語の集合を返す（無ければ空集合）。
    vault_inventory.py の load_generic_aliases() と同じ書式（1行1語・#コメント可）。
    単体では欠落/空をチェックしない純粋関数（fail-closedの判定はrequire_generic_aliases()
    に集約する）。
    """
    words = set()
    if GENERIC_ALIASES_FILE.exists():
        for line in GENERIC_ALIASES_FILE.read_text(encoding="utf-8").splitlines():
            word = line.split("#", 1)[0].strip()
            if word:
                words.add(word.lower())
    return words


def require_generic_aliases():
    """load_generic_aliases()を呼び、欠落/空ならfail-closedでプロセスを終了する（exit 1）。

    2026-07-14修正（外部脳の想起・ベンチ機構の総点検・Codex gpt-5.6-sol検証済み欠陥の
    是正）: リストが欠落/空の状態は「汎用語チェックが安全に機能しない」ことを意味し、
    load_generic_aliases()単体（空集合を返すだけの純粋関数）を直接呼ぶ全ての呼び出し元
    （本ファイルのmain()、および scripts/vault-agents/recall_bench.py の
    build_overlay_vault() ―どちらも独立した呼び出し元で重複実装するとfail-closedの
    抜け漏れが起きやすいため、ここへ集約する）が共通してこの関数を経由する契約にする。
    書き込み・採点いずれの用途でも、チェックが機能しない状態のまま処理を続けない。
    """
    if not GENERIC_ALIASES_FILE.exists():
        print(f"FAIL: {GENERIC_ALIASES_FILE} が見つかりません。汎用語禁止チェックを安全に"
              "行えないため中断します（fail-closed）。", file=sys.stderr)
        sys.exit(1)
    words = load_generic_aliases()
    if not words:
        print(f"FAIL: {GENERIC_ALIASES_FILE} に有効な語が1つもありません。汎用語禁止チェックを"
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


def apply_updated(lines, today):
    """updated: を today に更新する（無ければ date: の直後に挿入、date: も無ければ先頭に挿入）。"""
    for i, line in enumerate(lines):
        if UPDATED_RE.match(line):
            lines[i] = f"updated: {today}"
            return lines
    for i, line in enumerate(lines):
        if DATE_RE.match(line):
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
    knowledge_merge.py の save_state_atomic() と同じパターン（tempfile.mkstemp +
    os.fdopen + os.replace、失敗時は一時ファイルをunlinkしてから例外を再送出）。

    呼び出し側の注意（Codex一次レビュー指摘・Major）: `path` がsymlinkの場合、
    os.replace()はリンクそのものを通常ファイルへ置き換えてしまいリンク先は
    更新されない。symlinkノートを扱う呼び出し側は、解決済みの実体パスを渡すこと
    （apply_aliases.main()・recall_bench.build_overlay_vault()はいずれも既に
    resolve()済みのパスを渡す設計にしてある）。
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
        # 一時ファイルを残さない（Codex一次レビュー指摘・Minor）。os.fchmod()や
        # os.fdopen()自体が失敗した場合、fdはまだfileオブジェクトに包まれておらず
        # 生の整数のままなので、二重closeを避けつつここで明示的にcloseする
        # （Codex一次レビュー指摘・Minor2巡目: 従来はこの経路でfdがcloseされず
        # ファイルディスクリプタがリークしていた）。
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


def main():
    ap = argparse.ArgumentParser(
        description="TSV（ノート相対パス<TAB>alias1|alias2|...）から Vault ノートへ aliases: を一括適用する。")
    ap.add_argument("tsv", help="入力TSVファイル")
    ap.add_argument("--apply", action="store_true", help="実際に書き込む（既定はdry-runで差分表示のみ）")
    ap.add_argument("--vault", default=str(VAULT), help=f"Vaultのルート（既定: {VAULT}）")
    args = ap.parse_args()

    vault = pathlib.Path(args.vault)
    vault_resolved = vault.resolve()
    try:
        rows = parse_tsv(args.tsv)
    except OSError as e:
        print(f"FAIL: TSVを読めません: {args.tsv}（{e}）", file=sys.stderr)
        sys.exit(1)

    if not rows:
        print("適用対象がありません（TSVが空、または全行が不正/コメントでskipされました）。")
        return

    # fail-closed（2026-07-14修正・Codex検証済み欠陥の是正）: 汎用語禁止リストが
    # 欠落/空の場合、これまでは「何もチェックしない」まま書き込みまで進んでいた
    # （fail-open）。汎用語チェックが安全に機能しない状態で処理を続けると、本来
    # skipすべき汎用alias（"Claude"等）が無警告でVaultへ書き込まれうるため、
    # dry-run/--applyいずれの場合でも書き込みより前でエラー終了する（require_generic_aliases()
    # 経由・sys.exit(1)）。
    generic_words = require_generic_aliases()
    today = datetime.date.today().isoformat()

    n_changed = n_skip_missing = n_skip_nochange = n_error = 0
    for relpath, new_aliases in rows:
        path = vault / relpath
        # TSVの相対パスに ".." 等が含まれていてもVault外を書き換えないよう、解決後の
        # 実パスがVault配下であることを確認する（Codexレビュー指摘・Major:
        # 単純な `vault / relpath` だけでは `../../outside.md` のようなパスを
        # 拒否できず、--apply時にVault外のファイルを書き換えてしまいうる）。
        try:
            resolved = path.resolve()
            resolved.relative_to(vault_resolved)
        except (OSError, ValueError):
            print(f"ERROR {relpath}: Vaultの外を指しているためskipします（{path}）")
            n_error += 1
            continue
        if not path.is_file():
            print(f"SKIP {relpath}: ノートが見つかりません（{path}）")
            n_skip_missing += 1
            continue

        original = path.read_text(encoding="utf-8")
        result = process_note(original, new_aliases, generic_words, today)

        if result["error"]:
            print(f"ERROR {relpath}: {result['error']}")
            n_error += 1
            continue

        for g in result["skipped_generic"]:
            print(f"WARN {relpath}: alias \"{g}\" は汎用語禁止リスト該当のためskipします"
                  f"（{GENERIC_ALIASES_FILE.name}）")

        if not result["changed"]:
            print(f"SKIP {relpath}: 追加すべき新規aliasがありません"
                  f"（既存: {', '.join(result['existing']) or 'なし'}）")
            n_skip_nochange += 1
            continue

        label = "APPLY" if args.apply else "DRY-RUN"
        print(f"{label} {relpath}: +{result['added']}"
              f"（既存{len(result['existing'])}件 → 合計{len(result['existing']) + len(result['added'])}件・"
              f"updated: {today}）")
        diff = difflib.unified_diff(
            original.splitlines(keepends=True), result["new_text"].splitlines(keepends=True),
            fromfile=f"{relpath} (現在)", tofile=f"{relpath} ({'適用後' if args.apply else '適用予定'})",
        )
        sys.stdout.writelines(diff)

        if args.apply:
            # symlinkノートの場合、書込み先はリンクそのものではなく解決済みの実体
            # (resolved)にする（Codex一次レビュー指摘・Major: os.replace()はpathが
            # symlinkだとリンク自体を通常ファイルへ置き換えてしまい、リンク先の実体は
            # 更新されないままリンクが消える回帰を招く。read_text()はsymlinkを透過的に
            # 辿るため気づきにくい）。resolvedは冒頭のVault境界チェックで既に計算済み。
            write_note_atomic(resolved, result["new_text"])

        n_changed += 1

    print()
    print(f"サマリ: 対象{len(rows)}件 / 変更{'適用' if args.apply else '予定'}{n_changed}件 / "
          f"変更なしskip{n_skip_nochange}件 / ノート未検出skip{n_skip_missing}件 / エラー{n_error}件")
    if not args.apply and n_changed:
        print("（dry-runです。反映するには --apply を付けて再実行してください）")


if __name__ == "__main__":
    main()
