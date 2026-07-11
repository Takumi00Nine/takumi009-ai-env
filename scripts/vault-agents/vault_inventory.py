#!/usr/bin/env python3
"""外部脳(Obsidian Vault)の定期棚卸しレポート生成ツール。

チェック項目（external-brain-guide §定期チェック の自動化）:
  1. 方針ノート(Preferences)の updated 欠落
  2. 本文中の最新日付が frontmatter の updated/date より新しい（更新日漏れの疑い）
  3. wiki link ([[...]]) のリンク切れ
  4. 旧方針キーワードの残存（Decisions/mistakes-archive は履歴なので対象外）
  5. 必読5ファイルの注入サイズ監視
  6. status 付きノートの一覧と停滞検知
  8. Fragments の直近統計（capture が続いているか・昇格レビューの目安）
  9. Knowledge/Preferences/Decisions/Projects の aliases 欠落（README除く）
  10. 汎用すぎる／短すぎる alias（想起フックの誤ヒット源を機械検出）
  11. review_by の期限超過・14日以内到来（任意フィールド）
  12. vault-reads.tsv による未読ノート検出（90日以上未読・「読んだ」判定はReadのみで行う）＋
      vault-recall.tsv とのsession_id突合による「提示無視率」（提示されたのに読まれない率）＋
      reads/recallログそれぞれの死活判定（2026-07-10 敵対的レビュー C-2/M-1 対応）。
      提示無視率は直近30日（既定・環境変数で上書き可）の時間窓で計算し、同一セッションで
      提示より前に既読だった提示は分母から除外する（2026-07-10 敵対的レビュー2回目 N-2/N-3 対応）

出力: ~/.claude/logs/vault-inventory/YYYY-MM-DD.md（人間向け・日本語。2026-07-11
      決定＝「読まれない人間向け資料をVaultに置かない」に伴い、Vault配下
      （旧: Explorations/vault-inventory/）から $HOME/.claude/logs/ 配下へ移設）。
実行: LaunchAgent (com.takumi009.vault-inventory) が毎月1日・15日の03:00に起動
      （このリポジトリが配布するplistはRunAtLoad=false。手動kickstartや将来の
      RunAtLoad有効化での重複実行を想定し）「前回レポートから MIN_INTERVAL_DAYS
      未満なら何もしない」ガードあり。手動実行は --force で無視できる。
対処は自動で行わない（要確認項目が残ることはある）が、レポートへの目通し・対処自体は
リーダー（Claude）がレポート生成後の最初のセッションで自律的に行う運用
（2026-07-11 決定・Decisions/2026-07-11-vault-maintenance-hands-off.md。本人へ
個別報告はしない＝監査可能性はレポートファイル・git履歴・Fragments記録で担保）。
対処完了時はレポートのfrontmatterに `processed: YYYY-MM-DD` を追記する
（claude/hooks/bootstrap-vault.sh・scripts/check-drift.sh の未処理レポート検知が
参照するマーカー。本スクリプトはこのキーを出力しないため衝突しない）。
"""
import datetime
import os
import pathlib
import re
import sys
from collections import Counter

VAULT = pathlib.Path.home() / "Data" / "obsidian"
OUT_DIR = pathlib.Path.home() / ".claude" / "logs" / "vault-inventory"
MIN_INTERVAL_DAYS = 10

# 必読5ファイル（bootstrap-vault.sh と同じ並び）
BOOTSTRAP_FILES = [
    "Knowledge/mistakes.md",
    "Preferences/absolute-rules.md",
    "Preferences/profile.md",
    "Personal/profile-personal.md",
    "Preferences/coding-delegation.md",
    "Preferences/vault-operation.md",
]
SIZE_LIMIT_LINES = 40         # 1ファイルの目安（guide §定期チェック）
# 合計の目安（2026-07-11 改定＝Decisions/2026-07-11-bootstrap-size-limit-rebaseline。
# 公式アンカー「CLAUDE.md 200行未満推奨・Auto Memory 200行/25KB打ち切り」に対し、
# 棚卸し間隔中の一時膨張を許容するバッファを取った値。旧: bytes のみ 12288）
SIZE_LIMIT_TOTAL_LINES = 150  # 合計行数
SIZE_LIMIT_TOTAL = 20480      # 合計 20KB

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

# aliases 欠落・review_by・未読 検出の対象フォルダ（README.mdはindexなので除外）
ALIAS_CHECK_DIRS = ("Knowledge/", "Preferences/", "Decisions/", "Projects/")
DATE_ONLY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
REVIEW_SOON_DAYS = 14      # review_by がこの日数以内に来るものを「まもなく」として警告
UNREAD_THRESHOLD_DAYS = 90  # この日数以上 Read/想起ヒットが無ければ「未読」
LOG_STALE_DAYS = 30        # 直近この日数ログ記録が無ければ「フックが止まっている疑い」を注記

# 汎用alias禁止リスト（1行1語・#コメント可。generic-aliases.txt）
GENERIC_ALIASES_FILE = pathlib.Path(__file__).parent / "generic-aliases.txt"

# 想起フック（別ワーカー実装）が吐くログ。パスは環境変数で上書き可（テスト用）。
# 形式: ISO8601時刻<TAB>session_id<TAB>ノート相対パス[<TAB>一致キー]
READS_LOG_PATH = pathlib.Path(
    os.environ.get("VAULT_READS_LOG", str(pathlib.Path.home() / ".claude" / "logs" / "vault-reads.tsv")))
RECALL_LOG_PATH = pathlib.Path(
    os.environ.get("VAULT_RECALL_LOG", str(pathlib.Path.home() / ".claude" / "logs" / "vault-recall.tsv")))
RECALL_TOP_N = 5
DISMISS_MIN_PRESENTED = 3   # 提示無視率の分母に含める最低提示回数（1-2回のノイズを除外）
DISMISS_TOP_N = 10          # 提示無視率ワーストの表示件数


def _positive_int_env(name, default):
    """環境変数を正の整数として読む。未設定・空・非数値・0以下はdefaultへ
    fail-openで戻す（設定ミス1つで棚卸し全体が例外終了しないように＝Codexレビュー
    指摘・Major）。"""
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return default
    try:
        value = int(raw.strip())
    except ValueError:
        return default
    return value if value > 0 else default


# 提示無視率の集計対象を直近この日数に限定する（既定30日・環境変数で上書き可）。
# 全期間累積のままだとalias修正後の改善が指標に反映されない
# （2026-07-10 敵対的レビュー2回目 N-2 対応）。
DISMISS_WINDOW_DAYS = _positive_int_env("VAULT_DISMISS_WINDOW_DAYS", 30)


INLINE_COMMENT_RE = re.compile(r"(?<!\S)#.*$")  # 直前が空白/行頭の#以降をYAML風コメントとみなす


def strip_inline_comment(s):
    """`aliases: [] # 未使用` のような行末コメントを除去する（Codexレビュー指摘）。"""
    return INLINE_COMMENT_RE.sub("", s).strip()


def parse_frontmatter(text):
    """frontmatterをキー→値の辞書にする。既存の単一行 `key: value` はそのまま文字列で
    返す（従来どおり）。値が空の行（`key:` のみ）の直後に YAML の複数行リスト
    （`  - item`）が続く場合はそれをリストとして拾う（aliases 等の検出用に追加）。
    フロー形式リスト（`key: [a, b]`）もリストにする。行末の `# comment` は除去する。
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


def normalize_aliases(val):
    """frontmatterの aliases 値（リスト/カンマ区切り文字列/未設定）を alias文字列のリストにする。"""
    if not val:
        return []
    items = val if isinstance(val, list) else re.split(r"[,、]", val)
    return [x.strip() for x in items if x.strip()]


def load_generic_aliases():
    """generic-aliases.txt を読み、汎用alias禁止リスト（小文字化した集合）を返す。"""
    words = set()
    if GENERIC_ALIASES_FILE.exists():
        for line in GENERIC_ALIASES_FILE.read_text(encoding="utf-8").splitlines():
            word = line.split("#", 1)[0].strip()
            if word:
                words.add(word.lower())
    return words


def parse_iso(ts):
    """ISO8601文字列をnaive datetime（ローカル時刻基準）にする。
    'Z'終端・タイムゾーン付き（例: +09:00）・無し、いずれも許容し、tz付きはローカル時刻へ
    変換してから tzinfo を落とす（naive/aware混在での比較エラーを防ぐ＝Codexレビュー指摘）。
    壊れていればNone。
    """
    try:
        dt = datetime.datetime.fromisoformat(ts.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is not None:
        dt = dt.astimezone().replace(tzinfo=None)
    return dt


def read_log(path):
    """想起/読取フックのTSVログを読む。
    形式: ISO8601時刻<TAB>session_id<TAB>ノート相対パス[<TAB>...]。ERROR行は
    session_idの位置がメッセージにずれる実装（vault-recall.sh/vault-read-log.sh）が
    あるため、3列目（ノート相対パス）が空の行は「ノートに紐づく記録」としては
    使わない（従来どおり。3列目空はERROR行の目印＝下流誤集計防止のfail-open設計、
    Knowledge/fail-open-and-observable-guards §4）。

    戻り値:
      rows: (timestamp, session_id, rel_path) のリスト。ノート相対パスを伴う
            有効行のみ（session_idの提示↔Read突合・未読判定に使う）。
      skipped: タブ不足・時刻不正・3列目空（ERROR行含む）で rows に入らなかった
               行数＝「解析できなかったログ行」としてレポートに出す（従来どおり）。
      last_activity: 時刻が解析できた行（3列目が空のERROR行も含む）の最新時刻。
               ノートへの記録が無くても「ログファイル自体は書き込まれている」ことの
               目安になる＝reads/recallそれぞれの死活判定（stale）専用
               （2026-07-10 敵対的レビュー M-1 対応。rowsの集計とは独立させ、
               ノート集計の可否とログの生死を混同しない）。
    """
    rows = []
    skipped = 0
    last_activity = None
    if not path.exists():
        return rows, skipped, last_activity
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            skipped += 1
            continue
        ts = parse_iso(parts[0])
        if ts is None:
            skipped += 1
            continue
        if last_activity is None or ts > last_activity:
            last_activity = ts
        if not parts[2].strip():
            skipped += 1
            continue
        rows.append((ts, parts[1].strip(), parts[2]))
    return rows, skipped, last_activity


def compute_dismissal_rates(recall_rows, reads_rows, today):
    """「提示されたのに読まれない率」（レビューC-2の看板メトリクス）をノート別に出す。

    判定: recall_rows の1提示イベント (ts, session_id, rel) ごとに、同一
    session_id・同一 rel の reads_rows に ts以降 の Read が1件でもあれば
    「読まれた」とみなす（同一セッション内で後からReadされたか、という素朴な定義。
    セッション内で複数回提示された場合、1回のReadが複数の提示イベントを
    満たすことを許容する＝厳密な1:1消費ではなく「提示後に読まれる習慣があるか」の
    指標として設計）。session_id が空（旧ログ・stdin解析失敗等）の行は突合できない
    ため「読まれた」判定に加算しない（fail-closed側＝過大評価を避ける）。

    集計対象は today から DISMISS_WINDOW_DAYS 日以内の提示イベントに限定する
    （全期間累積のままだとalias修正後の改善が指標に映らない＝2026-07-10
    敵対的レビュー2回目 N-2 対応）。さらに、同一セッションで「提示より前に
    既読」だった提示イベントは分母から除外する（正当な既読スキップを無視と
    誤って数えないため＝同N-3対応。判定できるのは session_id が空でない行のみ）。

    戻り値: (rows, total_all, windowed_total, excluded_pre_read)
      rows: [(rel_path, presented_count, read_rate_percent), ...]
        窓内かつ既読前提示を除いた上で DISMISS_MIN_PRESENTED 回以上のノートのみ・
        読まれた率が低い順（同率は提示回数が多い方を先に＝より確度の高い
        「無視されている」証拠）に最大 DISMISS_TOP_N 件。
      total_all: recall_rows 全体（窓の内外問わず）の提示イベント数。
      windowed_total: 窓内の提示イベント数（既読前提示の除外前）。
      excluded_pre_read: 窓内のうち「提示より前に既読」で除外した件数。
    """
    reads_by_key = {}
    for ts, sid, rel in reads_rows:
        if not sid:
            continue
        reads_by_key.setdefault((sid, rel), []).append(ts)

    total_all = len(recall_rows)
    windowed_total = 0
    excluded_pre_read = 0
    presented = Counter()
    read_after = Counter()
    for ts, sid, rel in recall_rows:
        age_days = (today - ts.date()).days
        # 上限（古すぎ）だけでなく下限（未来日時＝負のage）も見る。上限しか
        # 見ないと未来日時のイベントが常に窓内扱いになり無視率を歪める
        # （Codexレビュー指摘・Minor。他の閾値ガードと同様に上下限をセットで
        # 設計する＝Knowledge/fail-open-and-observable-guards §1と同型）。
        # 未来日時ログ自体の警告は別途 recall_log_future 等で出す＝ここでは
        # 集計対象から静かに外すだけに留める。
        if age_days < 0 or age_days > DISMISS_WINDOW_DAYS:
            continue
        windowed_total += 1
        read_ts_list = reads_by_key.get((sid, rel)) if sid else None
        if sid and read_ts_list and any(rts < ts for rts in read_ts_list):
            excluded_pre_read += 1
            continue
        presented[rel] += 1
        if not sid:
            continue
        if read_ts_list and any(rts >= ts for rts in read_ts_list):
            read_after[rel] += 1

    rows = []
    for rel, n in presented.items():
        if n < DISMISS_MIN_PRESENTED:
            continue
        rate = round(read_after.get(rel, 0) / n * 100)
        rows.append((rel, n, rate))
    rows.sort(key=lambda r: (r[2], -r[1]))
    return rows[:DISMISS_TOP_N], total_all, windowed_total, excluded_pre_read


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
        # Explorations/vault-inventory/ 配下は2026-07-11以前の出力先（移設済み）。
        # 過去分がVault内に残っていても検査対象（aliases欠落・リンク切れ等）に
        # 巻き込まないよう、引き続き除外する。
        if p.suffix in (".md", ".canvas") and not rel.startswith(".") \
                and not rel.startswith("Explorations/vault-inventory/"):
            stems.setdefault(p.stem, []).append(rel)
            if p.suffix == ".md":
                text = p.read_text(encoding="utf-8")
                fm, body = parse_frontmatter(text)
                notes[rel] = (fm, body, text)

    missing_updated, date_drift, broken_links, stale_hits = [], [], [], []
    status_rows, stalled = [], []
    missing_aliases, generic_alias_hits = [], []
    review_overdue, review_soon, review_invalid = [], [], []
    generic_words = load_generic_aliases()

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

        # 9./10. aliases 欠落・汎用/短すぎるalias（Knowledge/Preferences/Decisions/Projects・README除く）
        if rel.startswith(ALIAS_CHECK_DIRS) and not rel.endswith("README.md"):
            aliases = normalize_aliases(fm.get("aliases"))
            if not aliases:
                missing_aliases.append(rel)
            for a in aliases:
                reasons = []
                if a.lower() in generic_words:
                    reasons.append("汎用語(禁止リスト)")
                is_ascii = all(ord(c) < 128 for c in a)
                if (not is_ascii and len(a) < 2) or (is_ascii and len(a) < 3):
                    reasons.append("短すぎ")
                if reasons:
                    generic_alias_hits.append((rel, a, "・".join(reasons)))

        # 11. review_by の期限（任意フィールド。全フォルダ対象）
        rb = fm.get("review_by")
        if rb:
            if not isinstance(rb, str) or not DATE_ONLY_RE.match(rb):
                review_invalid.append((rel, str(rb)))
            else:
                try:
                    rb_date = datetime.date.fromisoformat(rb)
                except ValueError:
                    review_invalid.append((rel, rb))
                else:
                    delta = (rb_date - today).days
                    if delta < 0:
                        review_overdue.append((rel, rb, -delta))
                    elif delta <= REVIEW_SOON_DAYS:
                        review_soon.append((rel, rb, delta))

    # 5. 注入サイズ
    size_rows, total_bytes, total_lines = [], 0, 0
    for f in BOOTSTRAP_FILES:
        p = VAULT / f
        n_lines = len(p.read_text(encoding="utf-8").splitlines())
        n_bytes = p.stat().st_size
        total_bytes += n_bytes
        total_lines += n_lines
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

    # 12. 未読ノート検出＋提示無視率（vault-reads.tsv / vault-recall.tsv）
    # 「読まれた」判定は vault-reads.tsv（実際のRead実績）のみで行う。vault-recall.tsv
    # （提示ログ）は last_seen には混ぜない＝「提示され続けているのに一度もReadされて
    # いないノート」が未読一覧から隠れてしまう無言fail-openを修正（2026-07-10
    # 敵対的レビュー C-2 対応。旧実装は reads/recall を混合していた）。
    reads_rows, reads_skipped, reads_last_activity = read_log(READS_LOG_PATH)
    recall_rows, recall_skipped, recall_last_activity = read_log(RECALL_LOG_PATH)
    log_skipped = reads_skipped + recall_skipped

    last_seen = {}
    for ts, _sid, rel in reads_rows:
        if rel not in last_seen or ts > last_seen[rel]:
            last_seen[rel] = ts
    # log_start/log_end/成熟判定は「今も存在する検査対象ノート」への reads 記録だけで
    # 見る。rename/delete/move済みの古いパスへの記録がlog_startを押し下げ、実際には
    # 観測期間が足りないのに成熟判定してしまう無言fail-openを防ぐ（Codexレビュー指摘）。
    tracked_reads_rows = [(ts, rel) for ts, _sid, rel in reads_rows
                           if rel.startswith(ALIAS_CHECK_DIRS) and not rel.endswith("README.md") and rel in notes]
    log_start = min((ts for ts, _ in tracked_reads_rows), default=None)
    log_age_days = (today - log_start.date()).days if log_start else None
    log_mature = log_age_days is not None and log_age_days >= UNREAD_THRESHOLD_DAYS

    # reads/recall それぞれ独立に死活判定する（フックの死は片方だけ起きうるため、
    # 混ぜて見ると生きている方のログが死んでいる方を覆い隠す＝2026-07-10
    # 敵対的レビュー M-1 対応）。staleは「ノートに紐づく“有効な”行(rows)」の最新時刻
    # だけで見る（Codexレビュー指摘・Major: last_activityはERROR行の時刻も拾うため、
    # ERROR行だけを吐き続ける壊れたフックでも「直近に記録あり＝健全」と誤判定して
    # しまう。閾値ガードは上下限だけでなく「何を鮮度の根拠にするか」も誤ると同種の
    # fail-closedになる＝Knowledge/fail-open-and-observable-guards §1と同型）。
    reads_log_valid_end = max((ts for ts, _sid, _rel in reads_rows), default=None)
    recall_log_valid_end = max((ts for ts, _sid, _rel in recall_rows), default=None)
    reads_log_stale = reads_log_valid_end is not None and (today - reads_log_valid_end.date()).days > LOG_STALE_DAYS
    recall_log_stale = recall_log_valid_end is not None and (today - recall_log_valid_end.date()).days > LOG_STALE_DAYS
    # 「ログには最近何か書かれている(last_activity)のに、有効な行(rows)が1件も無い」
    # ＝フックは実行されているが毎回失敗している疑い（ERROR行だけが積み上がっている
    # 状態）。staleとは別に明示的なメッセージを出す（無言のfail-open防止）。
    reads_log_broken = reads_last_activity is not None and reads_log_valid_end is None
    recall_log_broken = recall_last_activity is not None and recall_log_valid_end is None
    # 未来日時のログ行（システム時計のズレ・ファイル破損）は経過日数が負になり、
    # 上のstale判定（>LOG_STALE_DAYS）を永久にすり抜けて「健全」に誤判定される
    # （閾値ガードの下限漏れ＝Codexレビュー指摘・Major。fail-open-and-observable-guards
    # §1「上下限をセットで設計する」と同型の欠陥）。ここも無言で見逃さず注記する。
    reads_log_future = reads_last_activity is not None and reads_last_activity.date() > today
    recall_log_future = recall_last_activity is not None and recall_last_activity.date() > today

    unread_confirmed, unread_watch = [], []
    if log_start is not None:
        for rel in sorted(r for r in notes if r.startswith(ALIAS_CHECK_DIRS) and not r.endswith("README.md")):
            ts = last_seen.get(rel)
            age = (today - ts.date()).days if ts else None
            if age is not None and age < UNREAD_THRESHOLD_DAYS:
                continue
            row = (rel, age)
            (unread_confirmed if log_mature else unread_watch).append(row)

    recall_top = Counter(rel for _, _sid, rel in recall_rows).most_common(RECALL_TOP_N)
    dismissal_rows, dismissal_total_all, dismissal_windowed, dismissal_excluded_pre_read = \
        compute_dismissal_rates(recall_rows, reads_rows, today)
    # session_id が空の提示行はRead側と突合できず「読まれた」判定に加算されない
    # （fail-closed側＝過大評価を避ける設計）。無言のfail-openにしないよう件数を出す
    # （Codexレビュー指摘・Minor: 突合不能行が混ざっていることが可視化されないと、
    # 古いログ形式混在時などに提示無視率を過信しかねない）。reads側の空session_idも
    # 同じ理由で数える（Codexレビュー指摘・再レビュー分Minor: recall側だけの注記だと
    # 破損/旧形式のvault-reads.tsvによる読了率の過小評価に気づけない）。
    recall_no_session = sum(1 for _, sid, _ in recall_rows if not sid)
    reads_no_session = sum(1 for _, sid, _ in reads_rows if not sid)

    # ---- レポート生成 ----
    n_issues = (len(missing_updated) + len(date_drift) + len(broken_links) + len(stale_hits) + len(stalled)
                + len(missing_aliases) + len(generic_alias_hits) + len(review_overdue) + len(review_invalid)
                + len(unread_confirmed) + (1 if log_skipped else 0)
                + (1 if reads_log_stale else 0) + (1 if recall_log_stale else 0)
                + (1 if reads_log_broken else 0) + (1 if recall_log_broken else 0)
                + (1 if reads_log_future else 0) + (1 if recall_log_future else 0))
    L = []
    L.append("---")
    L.append(f"date: {today.isoformat()}")
    L.append("tags: [vault-inventory, report]")
    L.append("project: external-brain")
    L.append("---")
    L.append("")
    L.append(f"# 外部脳 棚卸しレポート {today.isoformat()}")
    L.append("")
    L.append(f"自動生成（`work/takumi009-ai-env/scripts/vault-agents/`）。ノート {len(notes)} 件を検査し、"
             f"**要確認 {n_issues} 件**。生成後の最初のセッションで、リーダー（Claude）が下記項目を確認し"
             "自律的に対処する（本人の指示は不要）。対処完了時は本レポートのfrontmatterに"
             " `processed: YYYY-MM-DD` を追記する。")

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
    L.append(f"## 5. 必読{len(BOOTSTRAP_FILES)}ファイルの注入サイズ")
    L.append(f"合計 {total_lines} 行 / {total_bytes:,} bytes"
             f"（目安 {SIZE_LIMIT_TOTAL_LINES} 行 / {SIZE_LIMIT_TOTAL:,} bytes）"
             + (" ⚠️ **要圧縮**"
                if total_lines > SIZE_LIMIT_TOTAL_LINES or total_bytes > SIZE_LIMIT_TOTAL
                else " ✅"))
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
    L.append(f"## 9. aliases が無いノート（Knowledge/Preferences/Decisions/Projects・README除く・{len(missing_aliases)}件）")
    L.append("aliases は想起フック（プロンプトから関連ノートを引く仕組み）の検索キー。"
             "無いノートは想起されない＝frontmatterに `aliases:` を追記する。")
    if not missing_aliases:
        L.append("✅ 問題なし")
    else:
        L.extend(f"- `{r}`" for r in missing_aliases)

    L.append("")
    L.append(f"## 10. 汎用すぎる／短すぎる alias（誤ヒットの疑い・{len(generic_alias_hits)}件）")
    L.append(f"広すぎる語（`scripts/vault-agents/generic-aliases.txt` 収録）や短すぎる語は想起フックの"
             "誤ヒット源になる＝より具体的な語に直すか、他のaliasと組み合わせて残すか検討する。")
    if not generic_alias_hits:
        L.append("✅ 問題なし")
    else:
        L.extend(f"- `{r}` — alias `{a}`（{why}）" for r, a, why in generic_alias_hits)

    L.append("")
    L.append(f"## 11. review_by の期限（任意フィールド・超過{len(review_overdue)}件／{REVIEW_SOON_DAYS}日以内{len(review_soon)}件）")
    L.append("review_by は外部情報系ノート（モデル情報など陳腐化しやすいもの）に任意で付ける確認期限。"
             "超過・接近したノートは内容を見直し、review_by を更新するか役目を終えていれば外す。")
    if not review_overdue and not review_soon and not review_invalid:
        L.append("✅ 問題なし")
    else:
        L.append("**期限超過:**" if review_overdue else "**期限超過:** なし")
        L.extend(f"- `{r}` — review_by {d}（{days}日超過）" for r, d, days in review_overdue)
        L.append(f"**{REVIEW_SOON_DAYS}日以内に到来:**" if review_soon else f"**{REVIEW_SOON_DAYS}日以内に到来:** なし")
        L.extend(f"- `{r}` — review_by {d}（あと{days}日）" for r, d, days in review_soon)
    if review_invalid:
        L.append("**形式不正（`YYYY-MM-DD`で書き直す）:**")
        L.extend(f"- `{r}` — review_by: `{d}`" for r, d in review_invalid)

    L.append("")
    L.append(f"## 12. 未読ノート（vault-reads.tsv・{UNREAD_THRESHOLD_DAYS}日以上未読）")
    L.append(f"「読まれた」判定は実際のRead実績（vault-reads.tsv）のみで行う（想起フックの提示"
             "＝vault-recall.tsvは「読まれた」扱いにしない。提示されるだけで未読判定から外れて"
             "しまう無言fail-openを防ぐ＝2026-07-10 敵対的レビュー C-2 対応）。"
             f"{UNREAD_THRESHOLD_DAYS}日以上Readが無いノートは本当に必要か・aliasが弱くて"
             "想起されていないだけか、を見直す材料にする。")
    if reads_skipped:
        L.append(f"⚠️ 解析できなかった vault-reads.tsv 行 {reads_skipped} 件（タブ区切り不正・時刻不正）"
                 "＝ログ破損の疑い。件数が多い場合はフックの出力形式を確認する。")
    if reads_no_session:
        L.append(f"⚠️ session_id が空のRead行 {reads_no_session} 件は提示無視率のRead側突合に使えません"
                 "（＝無視率が実態より高く出ている可能性）。")
    if reads_log_stale:
        L.append(f"⚠️ vault-reads.tsv: 直近 {LOG_STALE_DAYS} 日以内の有効な記録が無い"
                 f"（最終記録: {reads_log_valid_end.date().isoformat()}）"
                 "＝読取ログフック（claude/hooks/vault-read-log.sh）が動いていない可能性。"
                 "確認: `tail -1 ~/.claude/logs/vault-reads.tsv` 。以下の未読判定はその前提での参考値。")
    if reads_log_broken:
        L.append(f"⚠️ vault-reads.tsv: 最近ログは書かれています（最終: {reads_last_activity.date().isoformat()}）"
                 "が、有効なノート記録（ERROR行以外）が1件もありません＝フックは実行されているが"
                 "毎回失敗し続けている疑い。確認: `tail -5 ~/.claude/logs/vault-reads.tsv`")
    if reads_log_future:
        L.append(f"⚠️ vault-reads.tsv: 最終記録が未来日時（{reads_last_activity.isoformat()}）です"
                 "＝ファイル破損かシステム時計のズレの可能性。以下の判定に用いた日付計算が"
                 "信頼できない場合があります。確認: `tail -5 ~/.claude/logs/vault-reads.tsv`")
    if log_start is None:
        L.append("ログ蓄積中（まだ記録がありません）＝判定は次回以降。全ノートを未読扱いにはしていない。"
                 "vault-reads.tsv 自体が存在しない/空の場合の死活通知は"
                 "`scripts/check-drift.sh`（週次drift通知）が担当する＝ここでは断定しない。")
    else:
        if not log_mature:
            L.append(f"⚠️ ログ蓄積中（開始日: {log_start.date().isoformat()}・現在 {log_age_days} 日分・"
                     f"目安 {UNREAD_THRESHOLD_DAYS} 日未満）＝以下は暫定の「要観察」であり断定ではない。")
        rows = unread_watch if not log_mature else unread_confirmed
        if not rows:
            L.append("✅ 該当なし")
        else:
            L.extend(f"- `{r}`" + (f"（{age}日未読）" if age is not None else "（ログ開始以来記録なし）")
                     for r, age in rows)

    L.append("")
    L.append(f"### 提示無視率ワースト（vault-recall.tsv・提示{DISMISS_MIN_PRESENTED}回以上・ワースト{DISMISS_TOP_N}件）")
    L.append("同一セッション内で提示された後にReadされた割合。低いほど「提示されるのに読まれない」"
             "悪玉alias／不要ノートの疑い（提示→Read のsession_id突合。看板メトリクス・"
             "2026-07-10 敵対的レビュー C-2 対応）。")
    L.append(f"観測: 直近{DISMISS_WINDOW_DAYS}日・全期間の提示は{dismissal_total_all}件"
             f"（うち窓内{dismissal_windowed}件を対象）。全期間累積ではなく直近の窓だけを見ることで、"
             "alias修正後の改善が次回レポートに反映されるようにしています"
             "（2026-07-10 敵対的レビュー2回目 N-2 対応）。")
    L.append(f"うち、同一セッションで提示より前に既読だった提示{dismissal_excluded_pre_read}件は"
             "「正当な既読スキップ」とみなし分母から除外しました"
             "（2026-07-10 敵対的レビュー2回目 N-3 対応）。")
    if recall_skipped:
        L.append(f"⚠️ 解析できなかった vault-recall.tsv 行 {recall_skipped} 件＝ログ破損の疑い。")
    if recall_log_stale:
        L.append(f"⚠️ vault-recall.tsv: 直近 {LOG_STALE_DAYS} 日以内の有効な記録が無い"
                 f"（最終記録: {recall_log_valid_end.date().isoformat()}）"
                 "＝想起フック（claude/hooks/vault-recall.sh）が動いていない、またはヒット0件の日々が"
                 "続いている可能性（ヒット時のみ記録する仕様のため区別できない＝既知の限界）。"
                 "確認: `tail -1 ~/.claude/logs/vault-recall.tsv` 。以下の無視率もその前提での参考値。")
    if recall_log_broken:
        L.append(f"⚠️ vault-recall.tsv: 最近ログは書かれています（最終: {recall_last_activity.date().isoformat()}）"
                 "が、有効なノート記録（ERROR行以外）が1件もありません＝フックは実行されているが"
                 "毎回失敗し続けている疑い。確認: `tail -5 ~/.claude/logs/vault-recall.tsv`")
    if recall_log_future:
        L.append(f"⚠️ vault-recall.tsv: 最終記録が未来日時（{recall_last_activity.isoformat()}）です"
                 "＝ファイル破損かシステム時計のズレの可能性。以下の判定に用いた日付計算が"
                 "信頼できない場合があります。確認: `tail -5 ~/.claude/logs/vault-recall.tsv`")
    if recall_no_session:
        L.append(f"⚠️ session_id が空の提示行 {recall_no_session} 件はRead側と突合できないため、"
                 "「読まれた」に加算していません（＝無視率が実態より高く出ている可能性）。")
    if not dismissal_rows:
        L.append("該当なし（提示3回以上のノートがまだありません）")
    else:
        L.extend(f"- `{rel}` — 提示{n}回中 読まれた率{rate}%" for rel, n, rate in dismissal_rows)

    if recall_top:
        L.append("")
        L.append(f"おまけ: vault-recall.tsv 提示回数 上位{len(recall_top)}件（誤ヒットの多いaliasの手がかり）")
        L.extend(f"- `{r}` — {n}回" for r, n in recall_top)
    L.append("")

    out = OUT_DIR / f"{today.isoformat()}.md"
    out.write_text("\n".join(L), encoding="utf-8")
    print(f"レポート生成: {out}（要確認 {n_issues} 件）")


if __name__ == "__main__":
    main()
