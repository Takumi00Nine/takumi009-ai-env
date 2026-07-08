#!/usr/bin/env python3
"""外部脳(Obsidian Vault)の定期棚卸しレポート生成ツール。

チェック項目（external-brain-guide §定期チェック の自動化）:
  1. 方針ノート(Preferences)の updated 欠落
  2. 本文中の最新日付が frontmatter の updated/date より新しい（更新日漏れの疑い）
  3. wiki link ([[...]]) のリンク切れ
  4. 旧方針キーワードの残存（Decisions/mistakes-archive は履歴なので対象外）
  5. 必読5ファイルの注入サイズ監視
  6. status 付きノートの一覧と停滞検知
  7. Fragments の直近統計（capture が続いているか・昇格レビューの目安）

出力: Explorations/vault-inventory/YYYY-MM-DD.md（人間向け・日本語）
実行: LaunchAgent (com.takumi009.vault-inventory) が毎月1日・15日の03:00に起動
      （このリポジトリが配布するplistはRunAtLoad=false。手動kickstartや将来の
      RunAtLoad有効化での重複実行を想定し）「前回レポートから MIN_INTERVAL_DAYS
      未満なら何もしない」ガードあり。手動実行は --force で無視できる。
修正は自動で行わない（レポートを見て Claude と相談する運用）。
"""
import datetime
import pathlib
import re
import sys

VAULT = pathlib.Path.home() / "Data" / "obsidian"
OUT_DIR = VAULT / "Explorations" / "vault-inventory"
MIN_INTERVAL_DAYS = 10

# 必読5ファイル（bootstrap-vault.sh と同じ並び）
BOOTSTRAP_FILES = [
    "Knowledge/mistakes.md",
    "Preferences/absolute-rules.md",
    "Preferences/profile.md",
    "Preferences/coding-delegation.md",
    "Preferences/vault-operation.md",
]
SIZE_LIMIT_LINES = 40      # 1ファイルの目安（guide §定期チェック）
SIZE_LIMIT_TOTAL = 12288   # 合計 12KB

# 旧方針キーワード（体制が変わったら追記・削除する）
STALE_PATTERNS = {
    "Codex委任(実装/調査)": re.compile(r"Codex\s*(へ|に)\s*(委任|委託)|委任先\s*[=は]\s*Codex|Codexへの(実装|調査)委任"),
    "使用率ルーティング": re.compile(r"使用率(ベース|で寄せ|ルーティング)"),
    # 旧ゲート（WebSearch|WebFetch 版）のみ。v2（Edit|Write 版）は現行体制＝対象外
    "delegation-gate(旧・非v2)": re.compile(r"delegation-gate(?![-\s]?v2)"),
    "旧ワーカー(sonnet-4-6)": re.compile(r"sonnet-4-6|Sonnet 4\.6"),
}
# 旧方針チェックの対象フォルダ（Decisions=履歴・mistakes-archive=履歴 は対象外）
STALE_CHECK_DIRS = ("Preferences/", "Projects/", "Knowledge/")
STALE_EXCLUDE = ("Knowledge/mistakes-archive.md",)
# 「廃止/撤去/deprecated/旧」を含む行は新体制側の記述とみなし警告から除外
STALE_LINE_OK = re.compile(r"廃止|撤去|deprecated|旧方式|旧「|旧C|は旧")

# 現役ルールとして正しい記述（レポートに出さない）: (ファイル, 行に含まれる文字列)
STALE_ALLOWLIST = [
    ("Preferences/absolute-rules.md", "Codex へ委任する全プロンプトでこのノートを必読"),
    ("Preferences/web-verify-before-acting.md", "毎回 Codex に委任すると"),  # Why欄の経緯説明
    ("Knowledge/anthropic-claude-models-2026-06.md", "02-05 Opus 4.6"),  # リリース履歴（事実）
    ("Knowledge/claude-codex-orchestration-best-practice.md", "参考価格"),  # 公式価格の引用（事実）
    ("Projects/news-report-automation.md", "モデル sonnet-4-6"),  # 稼働中クラウドルーティンの設定値（事実）
]

DATE_RE = re.compile(r"\b(20\d{2}-\d{2}-\d{2})\b")
LINK_RE = re.compile(r"\[\[([^\[\]]+?)\]\]")
CODE_RE = re.compile(r"```.*?```|`[^`\n]*`", re.S)  # コードフェンス・インラインコード
STALE_PROJECT_DAYS = 30


def parse_frontmatter(text):
    m = re.match(r"---\n(.*?)\n---\n?", text, re.S)
    if not m:
        return {}, text
    fm = {}
    for line in m.group(1).splitlines():
        kv = re.match(r"(\w+):\s*(.+)", line)
        if kv:
            fm[kv.group(1)] = kv.group(2).strip().strip('"')
    return fm, text[m.end():]


def main():
    force = "--force" in sys.argv
    today = datetime.date.today()
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    # 重複実行防止ガード（手動kickstart連打・将来のRunAtLoad有効化等を想定）
    reports = sorted(OUT_DIR.glob("20*.md"))
    if reports and not force:
        last = datetime.date.fromisoformat(reports[-1].stem[:10])
        if (today - last).days < MIN_INTERVAL_DAYS:
            print(f"skip: 前回レポート {last} から {MIN_INTERVAL_DAYS} 日未満")
            return

    notes = {}   # rel_path -> (frontmatter, body, fulltext)
    stems = {}   # ファイル名(拡張子なし) -> [rel_path]
    for p in sorted(VAULT.rglob("*")):
        rel = p.relative_to(VAULT).as_posix()
        if p.suffix in (".md", ".canvas") and not rel.startswith(".") \
                and not rel.startswith("Explorations/vault-inventory/"):
            stems.setdefault(p.stem, []).append(rel)
            if p.suffix == ".md":
                text = p.read_text(encoding="utf-8")
                fm, body = parse_frontmatter(text)
                notes[rel] = (fm, body, text)

    missing_updated, date_drift, broken_links, stale_hits = [], [], [], []
    status_rows, stalled = [], []

    for rel, (fm, body, text) in notes.items():
        top = rel.split("/")[0]

        # 1. Preferences の updated 欠落
        if top == "Preferences" and not rel.endswith("README.md") and "updated" not in fm:
            missing_updated.append(rel)

        # 2. 本文日付 > frontmatter 日付（Fragments/Blogs/Explorations は対象外）
        if top in ("Preferences", "Knowledge", "Projects", "Decisions"):
            ref = fm.get("updated") or fm.get("date")
            body_dates = [d for d in DATE_RE.findall(body) if d <= today.isoformat()]
            if ref and body_dates and max(body_dates) > ref:
                date_drift.append((rel, ref, max(body_dates)))

        # 3. リンク切れ（全フォルダ対象。コード内の書式例は除外）
        for raw in LINK_RE.findall(CODE_RE.sub("", text)):
            target = raw.split("|")[0].split("#")[0].strip()
            if not target:
                continue
            if "/" in target:
                if not ((VAULT / f"{target}.md").exists() or (VAULT / f"{target}.canvas").exists()
                        or (VAULT / target).exists()):
                    broken_links.append((rel, raw))
            elif target not in stems:
                broken_links.append((rel, raw))

        # 4. 旧方針キーワード
        if rel.startswith(STALE_CHECK_DIRS) and rel not in STALE_EXCLUDE:
            for i, line in enumerate(text.splitlines(), 1):
                if STALE_LINE_OK.search(line):
                    continue
                if any(rel == f and s in line for f, s in STALE_ALLOWLIST):
                    continue
                for label, pat in STALE_PATTERNS.items():
                    if pat.search(line):
                        stale_hits.append((rel, i, label, line.strip()[:80]))

        # 6. status 一覧・停滞検知
        if "status" in fm:
            ref = fm.get("updated") or fm.get("date") or ""
            age = (today - datetime.date.fromisoformat(ref)).days if DATE_RE.fullmatch(ref) else None
            status_rows.append((rel, fm["status"], ref, age))
            active = any(k in fm["status"] for k in ("active", "in_progress", "pending"))
            if active and age is not None and age > STALE_PROJECT_DAYS:
                stalled.append((rel, fm["status"], ref, age))

    # 5. 注入サイズ
    size_rows, total_bytes = [], 0
    for f in BOOTSTRAP_FILES:
        p = VAULT / f
        n_lines = len(p.read_text(encoding="utf-8").splitlines())
        n_bytes = p.stat().st_size
        total_bytes += n_bytes
        size_rows.append((f, n_lines, n_bytes, n_lines > SIZE_LIMIT_LINES))

    # 7. Fragments 統計（直近14日）
    frag_files, frag_entries, promoted_total = 0, 0, 0
    for p in sorted((VAULT / "Fragments").rglob("20*.md")):
        d = datetime.date.fromisoformat(p.stem)
        text = p.read_text(encoding="utf-8")
        promoted_total += len(re.findall(r"status:\s*promoted", text))
        if (today - d).days <= 14:
            frag_files += 1
            _, body = parse_frontmatter(text)
            frag_entries += len(re.findall(r"^(## |- \*\*)", body, re.M))

    # ---- レポート生成 ----
    n_issues = len(missing_updated) + len(date_drift) + len(broken_links) + len(stale_hits) + len(stalled)
    L = []
    L.append("---")
    L.append(f"date: {today.isoformat()}")
    L.append("tags: [explorations, vault-inventory, report]")
    L.append("project: external-brain")
    L.append("---")
    L.append("")
    L.append(f"# 外部脳 棚卸しレポート {today.isoformat()}")
    L.append("")
    L.append(f"自動生成（`work/takumi009-ai-env/scripts/vault-agents/`）。ノート {len(notes)} 件を検査し、"
             f"**要確認 {n_issues} 件**。修正は自動で行っていない＝気になる項目を Claude に相談する。")

    def section(title, rows, fmt, empty="✅ 問題なし"):
        L.append("")
        L.append(f"## {title}")
        if not rows:
            L.append(empty)
        else:
            L.extend(fmt(r) for r in rows)

    section(f"1. updated が無い方針ノート（Preferences・{len(missing_updated)}件）",
            missing_updated, lambda r: f"- `{r}`")
    section(f"2. 本文の日付が frontmatter より新しい（更新日漏れの疑い・{len(date_drift)}件）",
            date_drift, lambda r: f"- `{r[0]}` — frontmatter: {r[1]} ＜ 本文最新: {r[2]}")
    section(f"3. リンク切れ（{len(broken_links)}件）",
            broken_links, lambda r: f"- `{r[0]}` → `[[{r[1]}]]`")
    section(f"4. 旧方針キーワード残存（{len(stale_hits)}件・Decisions/履歴は対象外）",
            stale_hits, lambda r: f"- `{r[0]}:{r[1]}` 【{r[2]}】 {r[3]}")

    L.append("")
    L.append("## 5. 必読5ファイルの注入サイズ")
    L.append(f"合計 {total_bytes:,} bytes（目安 {SIZE_LIMIT_TOTAL:,}）"
             + (" ⚠️ **要圧縮**" if total_bytes > SIZE_LIMIT_TOTAL else " ✅"))
    for f, n_lines, n_bytes, over in size_rows:
        L.append(f"- `{f}` — {n_lines} 行 / {n_bytes:,} bytes"
                 + (f" ⚠️ {SIZE_LIMIT_LINES}行超" if over else ""))

    section(f"6. 停滞プロジェクト（active/in_progress/pending なのに {STALE_PROJECT_DAYS} 日以上更新なし・{len(stalled)}件）",
            stalled, lambda r: f"- `{r[0]}` — {r[1]}（最終 {r[2]}・{r[3]}日前）")

    L.append("")
    L.append("## 7. status 付きノート一覧")
    for rel, st, ref, age in sorted(status_rows, key=lambda r: str(r[1])):
        L.append(f"- `{rel}` — **{st}**（{ref}" + (f"・{age}日前）" if age is not None else "）"))

    L.append("")
    L.append("## 8. Fragments（直近14日）")
    L.append(f"- 日次ファイル {frag_files} 件 / エントリ約 {frag_entries} 件"
             + ("（⚠️ capture が止まっている可能性）" if frag_files == 0 else " ✅ capture 継続中"))
    L.append(f"- `status: promoted` マーク累計 {promoted_total} 件（週次昇格レビューの参考値）")
    L.append("")

    out = OUT_DIR / f"{today.isoformat()}.md"
    out.write_text("\n".join(L), encoding="utf-8")
    print(f"レポート生成: {out}（要確認 {n_issues} 件）")


if __name__ == "__main__":
    main()
