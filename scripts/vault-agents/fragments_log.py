#!/usr/bin/env python3
"""Fragments 週次昇格候補検出ツール（maintenance.sh Phase 1 ②・2026-07-16簡素化）。

旧実装（fragments_review.py→2026-07-11リネームでfragments_log.py）は人間向けの
チェックリストMarkdownレポートを $HOME/.claude/logs/fragments-log/ へ生成し、
リーダーがセッション内でレポートを読んで昇格判断する運用だった。
[[Decisions/2026-07-16-nightly-batch-direct-write]] で「レポート→リーダー処理」の
間接ループを廃止し、夜間バッチ(maintenance.sh)がヘッドレスClaudeの判断で
Vaultへ直接書き込む方式へ移行したため、本スクリプトは検出専用へ縮小した:
  - 既存の `.md` レポート生成モードは撤去（設計書§3.1）。
  - `--json` で機械可読な検出結果（フラグメント本文全文・ソースファイルの
    SHA-256）を標準出力へ返す。maintenance_apply.py がPhase2のヘッドレスClaude
    へこのJSONを渡し、PROMOTE判断の材料にする。
  - `--since` を必須化（旧実装の「前回レポート日時をレポート自身から読み返す」
    仕組みが無くなったため、呼び出し元＝maintenance.shがlast-run.jsonの
    last_success_atを渡す設計。設計書§1.2 Phase1②）。

対応フォーマット（fragments-workflow §3 の2形式・変更なし）:
  - 見出し型:   ## HH:MM タイトル（status: 生/promoted/published を块内で検出）
  - 箇条書き型: - **タイトル**：本文（2026-07〜の実態フォーマット）

読み取り専用（Vaultには一切書き込まない）。
"""
import argparse
import datetime
import hashlib
import json
import pathlib
import re
import sys

VAULT = pathlib.Path.home() / "Data" / "obsidian"
FRAGMENTS = VAULT / "Fragments"

HEADING_RE = re.compile(r"^## (.+)$")
BULLET_RE = re.compile(r"^- \*\*(.+?)\*\*")
STATUS_RE = re.compile(r"status:\s*(promoted|published|生)")

# サイズ上限（設計書§2.2）。超過したフラグメントはヘッドレスClaudeへの素材から
# 除外し non_actionable: truncated として記録する（次回へ持ち越す・fail-open的に
# 切り詰めて渡すことはしない）。
MAX_FRAGMENT_CHARS = 2000

# --sinceのフォールバック閾値（設計書§1.2「初回/破損/未来日時/30日超過は7日に
# フォールバックしfactログ・中断しない」）。
SINCE_FALLBACK_DAYS = 7
SINCE_MAX_LOOKBACK_DAYS = 30


def resolve_since(raw_since, today):
    """--sinceの生値（ISO8601日時 or 日付文字列）をdatetime.dateへ解決する。

    未指定・パース失敗・未来日時・30日超過（SINCE_MAX_LOOKBACK_DAYS）のいずれかで
    あれば、7日前（SINCE_FALLBACK_DAYS）へfail-openでフォールバックする。
    戻り値: (since_date, fallback_reason_or_None)。fallback_reason はfactログ用
    （中断しない＝例外を投げない）。
    """
    fallback = today - datetime.timedelta(days=SINCE_FALLBACK_DAYS)

    if not raw_since or not raw_since.strip():
        return fallback, "未指定"

    raw = raw_since.strip()
    parsed = None
    try:
        # ISO8601日時（末尾Z許容）・日付のみ、両方を許容する。
        parsed = datetime.date.fromisoformat(raw[:10])
    except ValueError:
        return fallback, f"パース失敗（{raw!r}）"

    if parsed > today:
        return fallback, f"未来日時（{parsed.isoformat()}）"
    if (today - parsed).days > SINCE_MAX_LOOKBACK_DAYS:
        return fallback, f"{SINCE_MAX_LOOKBACK_DAYS}日超過（{parsed.isoformat()}）"
    return parsed, None


def extract_entries(text):
    """1ファイル分のFragments日次テキストから (heading_or_bullet, status, body) の
    リストを返す（旧実装のブロック抽出ロジックを変更なしで踏襲）。
    """
    lines = text.splitlines()
    entries = []
    i = 0
    while i < len(lines):
        m_h, m_b = HEADING_RE.match(lines[i]), BULLET_RE.match(lines[i])
        if m_h:
            block = []
            j = i + 1
            while j < len(lines) and not HEADING_RE.match(lines[j]):
                block.append(lines[j])
                j += 1
            body = "\n".join(block).strip()
            st = STATUS_RE.search(body)
            entries.append((m_h.group(1).strip(), st.group(1) if st else "生", body))
            i = j
        elif m_b:
            st = STATUS_RE.search(lines[i])
            entries.append((m_b.group(1).strip(), st.group(1) if st else "生", lines[i]))
            i += 1
        else:
            i += 1
    return entries


def stable_fragment_id(source_relpath, heading_or_bullet):
    """内容ベースの安定ID（設計書§2.2: frag-<sha256(source_relpath + 見出し/箇条書き
    行文字列)[:12]>）。連番は使わない（挿入で意味がズレるため）。
    """
    digest = hashlib.sha256((source_relpath + heading_or_bullet).encode("utf-8")).hexdigest()
    return f"frag-{digest[:12]}"


def collect_fragments(since_date, today):
    """Fragments配下の日次ファイル（since_date < d <= today）からエントリを集める。
    戻り値: (actionable, truncated, scanned_files, scan_errors)
      actionable: PROMOTE候補として渡してよいフラグメントのdictリスト
      truncated: サイズ上限超過でnon_actionable扱いになったフラグメントのdictリスト
      scanned_files: 走査したファイル数
      scan_errors: 読み取りに失敗したファイルの相対パスリスト（fail-open・件数記録用）
    """
    actionable, truncated, scan_errors = [], [], []
    scanned_files = 0
    if not FRAGMENTS.is_dir():
        return actionable, truncated, scanned_files, scan_errors

    for p in sorted(FRAGMENTS.rglob("20*.md")):
        try:
            d = datetime.date.fromisoformat(p.stem)
        except ValueError:
            continue
        if not (since_date < d <= today):
            continue
        try:
            text = p.read_text(encoding="utf-8")
        except OSError:
            scan_errors.append(str(p.relative_to(VAULT)))
            continue
        scanned_files += 1
        source_relpath = p.relative_to(VAULT).as_posix()
        source_sha256 = hashlib.sha256(text.encode("utf-8")).hexdigest()
        for heading_or_bullet, status, body in extract_entries(text):
            if status != "生":
                # 既に処理済み（promoted/published）のエントリは候補にしない
                # （旧実装のチェックボックス既存check相当・昇格候補は未処理のみ）。
                continue
            frag_id = stable_fragment_id(source_relpath, heading_or_bullet)
            record = {
                "id": frag_id,
                "source_relpath": source_relpath,
                "source_sha256": source_sha256,
                "date": d.isoformat(),
                "heading_or_bullet": heading_or_bullet,
                "body": body,
            }
            if len(body) > MAX_FRAGMENT_CHARS:
                record["non_actionable"] = "truncated"
                truncated.append(record)
            else:
                actionable.append(record)
    return actionable, truncated, scanned_files, scan_errors


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--since", required=True,
                     help="この日時より後のFragmentsエントリのみを対象にする（ISO8601日時/日付。"
                          "未指定不可＝必須。不正値は7日前へfail-openでフォールバックする）")
    ap.add_argument("--json", action="store_true", help="JSON形式で標準出力へ返す（maintenance.sh向け）")
    args = ap.parse_args(argv)

    today = datetime.date.today()
    since_date, fallback_reason = resolve_since(args.since, today)

    actionable, truncated, scanned_files, scan_errors = collect_fragments(since_date, today)

    if fallback_reason:
        print(f"FACT: --sinceを7日前へフォールバックしました（理由: {fallback_reason}）", file=sys.stderr)
    if scan_errors:
        print(f"FACT: 読み取れなかったFragmentsファイルが{len(scan_errors)}件あります: "
              f"{', '.join(scan_errors[:5])}{'...' if len(scan_errors) > 5 else ''}", file=sys.stderr)

    if args.json:
        payload = {
            "since": since_date.isoformat(),
            "until": today.isoformat(),
            "since_fallback_reason": fallback_reason,
            "scanned_files": scanned_files,
            "scan_error_count": len(scan_errors),
            "fragments": actionable,
            "truncated": truncated,
        }
        print(json.dumps(payload, ensure_ascii=False))
    else:
        print(f"対象期間: {since_date.isoformat()} 〜 {today.isoformat()}"
              f"（走査{scanned_files}ファイル・候補{len(actionable)}件・"
              f"サイズ超過truncated{len(truncated)}件・読取エラー{len(scan_errors)}件）")
        for rec in actionable:
            print(f"  [{rec['id']}] {rec['source_relpath']}: {rec['heading_or_bullet']}")


if __name__ == "__main__":
    main()
