#!/usr/bin/env python3
"""Fragments 週次昇格レビューの候補レポート生成ツール。

直近期間の Fragments 日次ファイルからエントリを抽出し、チェックリスト形式で
Explorations/fragments-review/YYYY-MM-DD.md に出力する（人間向け）。
昇格の判断・Vault への書込は自動で行わない＝レポートを見て Claude に指示する運用
（[[Preferences/fragments-workflow]]・書込はメインセッションの Claude のみ）。

対応フォーマット（fragments-workflow §3 の2形式）:
  - 見出し型:   ## HH:MM タイトル（status: 生/promoted/published を块内で検出）
  - 箇条書き型: - **タイトル**：本文（2026-07〜の実態フォーマット）

実行: LaunchAgent (com.takumi009.fragments-review) が毎週月曜 03:30 に起動
（このリポジトリが配布するplistはRunAtLoad=false。手動kickstart連打や将来の
RunAtLoad有効化での重複実行を想定し）「前回レポートから MIN_INTERVAL_DAYS 未満は
スキップ」ガードあり（--force で無視）。対象期間は前回レポート以降（上限21日・既定7日）。
"""
import datetime
import pathlib
import re
import sys

VAULT = pathlib.Path.home() / "Data" / "obsidian"
FRAGMENTS = VAULT / "Fragments"
OUT_DIR = VAULT / "Explorations" / "fragments-review"
MIN_INTERVAL_DAYS = 5
DEFAULT_WINDOW_DAYS = 7
MAX_WINDOW_DAYS = 21

HEADING_RE = re.compile(r"^## (.+)$")
BULLET_RE = re.compile(r"^- \*\*(.+?)\*\*")
STATUS_RE = re.compile(r"status:\s*(promoted|published|生)")


def main():
    force = "--force" in sys.argv
    today = datetime.date.today()
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    reports = sorted(OUT_DIR.glob("20*.md"))
    since = today - datetime.timedelta(days=DEFAULT_WINDOW_DAYS)
    if reports:
        last = datetime.date.fromisoformat(reports[-1].stem[:10])
        if (today - last).days < MIN_INTERVAL_DAYS and not force:
            print(f"skip: 前回レポート {last} から {MIN_INTERVAL_DAYS} 日未満")
            return
        since = max(last, today - datetime.timedelta(days=MAX_WINDOW_DAYS))

    days = []  # (date, [(title, status, hint)])
    total, done = 0, 0
    for p in sorted(FRAGMENTS.rglob("20*.md")):
        try:
            d = datetime.date.fromisoformat(p.stem)
        except ValueError:
            continue
        if not (since < d <= today):
            continue
        lines = p.read_text(encoding="utf-8").splitlines()
        entries = []
        i = 0
        while i < len(lines):
            m_h, m_b = HEADING_RE.match(lines[i]), BULLET_RE.match(lines[i])
            if m_h:
                # 見出し型: 次の見出しまでを块として status を探す
                block = []
                j = i + 1
                while j < len(lines) and not HEADING_RE.match(lines[j]):
                    block.append(lines[j])
                    j += 1
                st = STATUS_RE.search("\n".join(block))
                entries.append((m_h.group(1).strip(), st.group(1) if st else "生"))
                i = j
            elif m_b:
                st = STATUS_RE.search(lines[i])
                entries.append((m_b.group(1).strip(), st.group(1) if st else "生"))
                i += 1
            else:
                i += 1
        if entries:
            days.append((d, entries, p.relative_to(VAULT).as_posix()))
            total += len(entries)
            done += sum(1 for _, st in entries if st != "生")

    L = []
    L.append("---")
    L.append(f"date: {today.isoformat()}")
    L.append("tags: [explorations, fragments-review, report]")
    L.append("project: external-brain")
    L.append("---")
    L.append("")
    L.append(f"# Fragments 昇格レビュー {today.isoformat()}")
    L.append("")
    L.append(f"対象期間: {since + datetime.timedelta(days=1)} 〜 {today}（エントリ {total} 件"
             f"・うち処理済み {done} 件）。自動生成（`work/takumi009-ai-env/scripts/vault-agents/fragments_review.py`）。")
    L.append("")
    L.append("**使い方**: 下のリストを眺めて、①Knowledge/Decisions/Projects/Preferences へ**昇格**"
             "させたいもの ②note 記事の**種**として Blogs へ送りたいもの、を Claude に伝える"
             "（例:「7/3 の2番を Knowledge に昇格して」）。Claude が昇格先を作成し、Fragments 側に"
             " `status: promoted`＋相互リンクを付ける。**多くのエントリは昇格不要（履歴のまま）で正常**。")
    if not days:
        L.append("")
        L.append("（対象期間に新しいエントリはありません）")
    for d, entries, rel in days:
        L.append("")
        L.append(f"## {d.isoformat()}（[[{rel[:-3]}]]）")
        for n, (title, st) in enumerate(entries, 1):
            mark = "x" if st != "生" else " "
            suffix = f"（{st}）" if st != "生" else ""
            L.append(f"- [{mark}] {n}. {title}{suffix}")
    L.append("")

    out = OUT_DIR / f"{today.isoformat()}.md"
    out.write_text("\n".join(L), encoding="utf-8")
    print(f"レポート生成: {out}（エントリ {total} 件）")


if __name__ == "__main__":
    main()
