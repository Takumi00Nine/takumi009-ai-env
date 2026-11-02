#!/usr/bin/env python3
"""Vault の共通 Markdown 解析。"""
import pathlib
import re
from datetime import date

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
# 本文から除外する用途で使う（2026-07-16にvault_inventory.pyから抽出＝設計書§2.5
# 「import vault_inventoryは全廃」の対象を将来の共有モジュールにも適用）。
CODE_RE = re.compile(r"```.*?```|`[^`\n]*`", re.S)


# --- 教訓・判断の共通読取（note-templates.md の定型ブロック） ----------------

# Knowledge・Decisions の現物（2026-11-02）で確認した冒頭の失効表記。
# 「撤回済み企画の資料」も採用し、語の後の区切りは残して本文への言及を拾わない。
# 引用なしの警告、日付が先の撤回、repo 退役も現物にある。
RECALL_BANNER_RE = re.compile(
    r"^(?:>\s*(?:⚠[️︎]?\s*)?|⚠[️︎]?\s*)(?:\*\*)?"
    r"(?:\d{4}-\d{2}-\d{2}\s+)?"
    r"(?:(?:想起|repo\s+)?退役(?:済み)?|撤回(?:済み(?:企画の資料)?)?|白紙化(?:済み)?|"
    r"(?:一部|部分|前提の一部)撤回|deprecated)(?=[\s（(：:＝=・*]|$)",
    re.I,
)


def without_fenced_code(body):
    """書式例の見出し・項目を読まない。バッククォートとチルダのフェンスに対応。"""
    lines, fence_char, fence_size = [], None, 0
    for line in body.splitlines():
        fence = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line)
        if fence_char:
            if (fence and fence[1][0] == fence_char
                    and len(fence[1]) >= fence_size and not fence[2].strip()):
                fence_char = None
        elif fence:
            fence_char, fence_size = fence[1][0], len(fence[1])
        else:
            lines.append(line)
    return "\n".join(lines)


def recall_note_is_excluded(fm, body):
    """退役指定と冒頭の現行バナーだけを見る。本文の撤回への言及は使わない。"""
    if str(fm.get("retired", "")).lower() == "true":
        return True
    introduction = re.split(r"(?m)^##\s", body, maxsplit=1)[0]
    return any(RECALL_BANNER_RE.match(line) for line in introduction.splitlines())


def read_recall_records(vault_root, *, skip_sources=(), include_incomplete=False):
    """毎回 Markdown を読む。戻り値は (records, issues)。

    共通欄は kind/id/source/text/situations。判断は date、教訓は
    occurrences=[{date, source}] と、印があるときだけ state を持つ。
    source は Vault 相対パス、発生の source は同じ行の出典リンク全体。
    起きたこと等の書式不備は issues=[{id, source, fields}] に返す。
    text/situations の欠けは提示対象から除く。集計では include_incomplete で
    それらも返す（発生記録は数える）。skip_sources は棚卸しで読込不能と判定済みのノート。
    自然文からは推測しない。
    """
    vault_root = pathlib.Path(vault_root)
    records, issues = [], []
    for folder, kind in (("Knowledge", "lesson"), ("Decisions", "decision")):
        for path in sorted((vault_root / folder).glob("*.md")):
            if path.name.lower() == "readme.md" or path.name.startswith("."):
                continue
            source = path.relative_to(vault_root).as_posix()
            if source in skip_sources:
                continue
            fm, body = parse_frontmatter(path.read_text(encoding="utf-8"))
            body = without_fenced_code(body)
            if recall_note_is_excluded(fm, body):
                continue
            if kind == "lesson":
                blocks = []
                for section in re.split(r"(?m)^##[ \t]+", body)[1:]:
                    heading, _, content = section.partition("\n")
                    match = re.fullmatch(r"教訓:\s*(\S+)\s*", heading)
                    if match:
                        blocks.append((f"{source}#{match[1]}", content))
                    elif heading.startswith("教訓"):
                        issues.append({"id": f"{source}#{heading}", "source": source,
                                       "fields": ["教訓の見出し（教訓: ID）"]})
            else:
                # 判断3行は H1 直後。以後の理由・経緯の項目を混ぜない。
                heading = re.search(r"(?m)^#\s+.*\n?", body)
                content = body[heading.end():] if heading else ""
                blocks = [(source, re.split(r"(?m)^#{1,6}\s", content)[0])]

            for record_id, content in blocks:
                fields, current = {}, None
                for line in content.splitlines():
                    field = re.match(r"^- ([^:]+):\s*(.*)$", line)
                    item = re.match(r"^ {2,}-\s+(.+)$", line)
                    if field:
                        current = field[1]
                        fields[current] = [] if current in ("効く場面", "発生記録") else field[2]
                    elif item and current in ("効く場面", "発生記録"):
                        fields[current].append(item[1].strip())
                    elif line.strip():
                        current = None

                text_field = "教訓1行" if kind == "lesson" else "判断1行"
                required = [text_field, "効く場面"]
                required += ["起きたこと", "発生記録"] if kind == "lesson" else ["判断の日付"]
                missing = [key for key in required if not fields.get(key)]
                record = {"kind": kind, "id": record_id, "source": source,
                          "text": fields.get(text_field, ""),
                          "situations": fields.get("効く場面", [])}
                if kind == "lesson":
                    occurrences = []
                    for occurrence in fields.get("発生記録", []):
                        day, _, links = occurrence.partition(" ")
                        try:
                            day = date.fromisoformat(day).isoformat()
                            valid = bool(LINK_RE.search(links))
                        except ValueError:
                            valid = False
                        if valid:
                            occurrences.append({"date": day, "source": links.strip()})
                        elif "発生記録" not in missing:
                            missing.append("発生記録")
                    record["occurrences"] = sorted(occurrences, key=lambda row: row["date"])
                    if fields.get("状態"):
                        record["state"] = fields["状態"]
                else:
                    record["date"] = fields.get("判断の日付", "")
                    if record["date"]:
                        try:
                            record["date"] = date.fromisoformat(record["date"]).isoformat()
                        except ValueError:
                            missing.append("判断の日付")
                if missing:
                    issues.append({"id": record_id, "source": source, "fields": missing})
                if include_incomplete or (record["text"] and record["situations"]):
                    records.append(record)
    return records, issues
