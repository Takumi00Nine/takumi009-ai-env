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
  9. Knowledge/Preferences/Decisions/Projects/Personal の aliases 欠落（README除く。
     2026-07-11決定でPersonal追加＝[[Decisions/2026-07-11-personal-recall-scope]]）
  10. 汎用すぎる／短すぎる alias（想起フックの誤ヒット源を機械検出）
  11. review_by の期限超過・14日以内到来（任意フィールド）
  12. vault-reads.tsv による未読ノート検出（90日以上未読・「読んだ」判定はReadのみで行う）＋
      vault-recall.tsv とのsession_id突合による「提示無視率」（提示されたのに読まれない率）＋
      reads/recallログそれぞれの死活判定（2026-07-10 敵対的レビュー C-2/M-1 対応）。
      提示無視率は直近30日（既定・環境変数で上書き可）の時間窓で計算し、同一セッションで
      提示より前に既読だった提示は分母から除外する（2026-07-10 敵対的レビュー2回目 N-2/N-3 対応）。
      さらに提示は (session_id, ノート) 単位に正規化して1回に数え（同一セッションでの
      重複提示による水増しを除去）、「解析できなかったログ行」はERROR行（フックが自ら
      記録する正常なエラーログ）と真に構文が壊れている行を分離して表示する
      （2026-07-13 敵対的レビューround3対応）

出力: ~/.claude/logs/vault-inventory/YYYY-MM-DD.md（人間向け・日本語。2026-07-11
      決定＝「読まれない人間向け資料をVaultに置かない」に伴い、Vault配下
      （旧: Explorations/vault-inventory/）から $HOME/.claude/logs/ 配下へ移設）。
      `--json` 指定時は上記`.md`に加え、機械可読なJSON（棚卸し件数サマリ）を
      標準出力へ返す（2026-07-16簡素化）。missing_updated（Preferences限定の
      updated欠落）は**検出のみ**（レポート§1・n_issues計上）で、機械的な
      修正（FIX機能・action: fix_approve）は2026-07-18本人裁定で丸ごと削除
      した＝[[Decisions/2026-07-18-external-brain-hardening]]（理由＝
      Preferences限定でしか動かず「夜間はPreferencesを書かない」境界の唯一の
      違反経路だった・値も効果限定的）。以後は他の棚卸し項目（date_drift・
      リンク切れ・alias欠落等）と同じく、読み時/棚卸し相談で人間が直す。
実行: 2026-07-16簡素化（設計書§3.2）で、旧・月2回（1日/15日）の間隔ガード
      （MIN_INTERVAL_DAYS・--force）は撤去し週次実行に統一した（週次ランナー
      maintenance.sh・PR2 が呼ぶ。実行頻度の制御自体はLaunchAgent側の間隔に委ねる。
      旧実装は`git log -p`参照）。
対処は自動で行わない（要確認項目が残ることはある）。旧来の「レポートへの目通し・
対処自体はリーダーがセッション内で自律的に行う」運用は2026-07-16簡素化
（[[Decisions/2026-07-16-nightly-batch-direct-write]]）で撤去し、`.md`レポートは
週次の棚卸し相談用の人間向け資料としてのみ残す（`processed:`マーカー運用・
未処理レポート検知は同時に撤去済み＝旧実装は`git log -p`参照）。
"""
import argparse
import datetime
import json
import os
import pathlib
import re
import sys
from collections import Counter

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
# frontmatter解析・wikilink正規表現・aliases正規化・汎用alias禁止リスト読込は
# 2026-07-16簡素化（cleanup決定#10）でvault_lib.pyへ抽出済み（他4本＝
# embedding_index.py→撤去済み・knowledge_merge_candidates.py・knowledge_merge.py→
# 撤去済み・merge_quality_gate.py→撤去済み・recall_bench.pyが`import vault_inventory`
# していたのはこれらの関数だけを再利用するためだった＝CLI/共有ライブラリ同居の解消）。
import vault_lib  # noqa: E402

VAULT = pathlib.Path.home() / "Data" / "obsidian"
OUT_DIR = pathlib.Path.home() / ".claude" / "logs" / "vault-inventory"

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
# wikilink検出用正規表現はvault_lib.LINK_REへ、コードフェンス/インラインコード検出用
# 正規表現はvault_lib.CODE_REへ抽出済み（2026-07-16簡素化。merge_checks.py新設時に
# 共用するため後者も抽出）。
CODE_RE = vault_lib.CODE_RE
STALE_PROJECT_DAYS = 30

# aliases 欠落・汎用/短すぎるalias・未読 検出の対象フォルダ（README.mdはindexなので
# 除外）。2026-07-11決定（[[Decisions/2026-07-11-personal-recall-scope]]）でPersonal/
# を想起対象＋aliases必須ルールの対象へ追加（4→5フォルダ）。この定数は§9(aliases
# 欠落)・§10(汎用/短すぎるalias)・§12(未読検出)で共有しているため、Personal追加の
# 効果はこの3項目に及ぶ（§11のreview_by検査は本定数を使わず全ノート無条件が対象
# のため、Personalは以前から対象＝波及なし。リーダー指示は§9限定の言及だったが、
# 対象フォルダ定数が元々§9/§10/§12で共有設計のため分離せずそのまま適用した
# ＝Codexレビュー指摘で§11は対象外と判明・コメント訂正）。
ALIAS_CHECK_DIRS = ("Knowledge/", "Preferences/", "Decisions/", "Projects/", "Personal/")
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
# claude/hooks/vault-recall.sh の HEARTBEAT_MARKER と同じ文字列（想起ヒット0件の
# 呼び出しが「フックは動いている」ことを示すために3列目へ書く印。ノートパスではない
# ため read_log() 上は通常の有効行として3列目非空でrowsに入るが、そのまま提示回数
# 上位・提示無視率ワースト（どちらも実ノートを対象とした集計）へ混ぜると実ノートで
# ないものが「よく提示されるノート」として並んでしまう＝2026-07-13外部脳round4対応・
# 小修正4）。死活判定（recall_log_valid_end等）では従来どおり有効な活動として扱う
# （heartbeatの導入目的そのものなので、rows自体からは除かない）。
HEARTBEAT_MARKER = "(heartbeat)"


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


# strip_inline_comment・parse_frontmatterはvault_lib.pyへ抽出済み（2026-07-16簡素化）。

# 2026-08-06 status語彙4値統一（active/paused/completed/closed）に伴い
# in_progress/pending を撤去。paused は意図的保留＝停滞検知の対象外。
ACTIVE_STATUS_KEYS = ("active",)
# 先頭（前置の空白は許容）に一致させる。文字列中の任意位置を許すsearch()だと
# "not-active"のようなハイフン区切りの値でも"active"に単語境界一致してしまう
# （Codexレビュー指摘・Major: 当初はsearch()を使っており、このdocstringが謳う
# 「先頭トークンだけを見て判定する」を実装が満たしていなかった）。
_ACTIVE_STATUS_RE = re.compile(r"^\s*(?:%s)\b" % "|".join(re.escape(k) for k in ACTIVE_STATUS_KEYS))


def status_is_active(status):
    """frontmatterのstatus値が稼働系（ACTIVE_STATUS_KEYS）に該当するかを返す。

    文字列値は先頭トークンを単語境界(\\b)で判定する（match()・文字列中の任意位置に
    一致するsearch()は使わない）。旧実装は`k in fm["status"]`という部分文字列一致
    だったため、"inactive"が"active"を含むことによって誤って停滞検知対象（active扱い）
    になるバグがあった（Codexレビュー指摘・実装ミス）。単純な完全一致(==)にしなかったのは、
    実Vaultのstatus値には`status: closed（2026-07-05 解決・...）`のような注記付き値が
    実在し、これを壊さず先頭トークンだけを見て判定する必要があるため（先頭アンカー＋
    単語境界一致ならどちらも正しく扱える。"not-active"のような非先頭一致は誤検知しない）。
    リスト値（YAML複数行/フロー形式でstatusを書いた場合）は要素の完全一致で判定する
    （リストの各要素は元々1トークンの値である想定のため部分一致の必要が無い）。
    """
    if isinstance(status, list):
        return any(s in ACTIVE_STATUS_KEYS for s in status)
    if isinstance(status, str):
        return bool(_ACTIVE_STATUS_RE.match(status))
    return False


# normalize_aliases・load_generic_aliasesはvault_lib.pyへ抽出済み（2026-07-16簡素化）。


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


# ERROR行は claude/hooks/vault-recall.sh の
# `log_row "ERROR\t\t${SESSION_ID:-}\t$1[\t${LOG_LEVEL_INFO}]"` として書かれる
# （log_error()はレベル列を省略・log_fact()だけ6列目に固定文字列"INFO"を付与する
# ＝vault-recall.sh側コメント参照）。0-indexで添字5（6列目）がこのレベル列。
# scripts/vault-agents/recall_bench.py の同名定数と契約を揃える（2026-07-15追加）。
LOG_LEVEL_COL = 5
LOG_LEVEL_INFO_VALUE = "INFO"


def read_log(path):
    """想起/読取フックのTSVログを読む。
    形式: ISO8601時刻<TAB>session_id<TAB>ノート相対パス[<TAB>...]。ERROR行は
    session_idの位置がメッセージにずれる実装（vault-recall.sh/vault-read-log.sh）が
    あるため、3列目（ノート相対パス）が空の行は「ノートに紐づく記録」としては
    使わない（従来どおり。3列目空はERROR行の目印＝下流誤集計防止のfail-open設計、
    Knowledge/fail-open-and-observable-guards §4）。

    2列目が"ERROR"固定文字列の行のうち、6列目（0-indexで LOG_LEVEL_COL）に
    vault-recall.sh log_fact() が付与する固定文字列"INFO"(LOG_LEVEL_INFO_VALUE)が
    あるものは、真の失敗ではなくパイプライン正常完走時の事実記録（削除済みノートの
    ベクトル残存除外・読取不可ノート件数）。2列目の"ERROR"は下流互換のため変えない
    契約（vault-recall.sh側コメント参照）だが、error_rows（＝フックが記録した
    "真のエラー"件数としてレポートに表示）へこのINFO行まで算入すると、レポート上
    「ERROR行」の件数がフックの正常な事実記録で水増しされ、死活判定とは無関係な
    表示精度の問題を生む（2026-07-15 総点検で判明。死活判定＝rows/last_activityの
    集計には元々影響しない）。6列目が無い旧形式のERROR行（列数5以下・レベル列を
    書かないlog_error()由来）は後方互換として従来どおりerror_rowsに数える。

    戻り値:
      rows: (timestamp, session_id, rel_path) のリスト。ノート相対パスを伴う
            有効行のみ（session_idの提示↔Read突合・未読判定に使う）。
      skipped: タブ不足・時刻不正・「2列目がERROR以外なのに3列目が空」で rows に
               入らなかった行数＝**真に構文として解析できなかった行**（ログ破損の
               疑い）としてレポートに出す。
      error_rows: 2列目が"ERROR"かつ3列目が空かつ6列目がINFO(事実記録)ではない
               行数＝フックが自ら記録する仕様通りの正常な「真の失敗」エラーログ
               （vault-recall.sh/vault-read-log.shのlog_error）。従来はskippedへ
               合算し「ログ破損の疑い」として表示していたが、ERROR行は正常なログ
               であり真の構文破損とは区別すべき（2026-07-13 敵対的レビューround3の
               実バグ級指摘。78行の実体がERROR行78件だったのに「解析できなかった
               行＝ログ破損の疑い」と表示していた）。log_fact()由来のINFO行は
               skippedにもerror_rowsにも数えない（構文破損でも真の失敗でもない）。
               死活判定（reads_log_broken等のERRORING検知）の入力としては
               従来どおりrowsに含めず扱う（last_activityには含まれる）。
      last_activity: 時刻が解析できた行（3列目が空のERROR行・INFO行も含む）の
               最新時刻。ノートへの記録が無くても「ログファイル自体は書き込まれて
               いる」ことの目安になる＝reads/recallそれぞれの死活判定（stale）専用
               （2026-07-10 敵対的レビュー M-1 対応。rowsの集計とは独立させ、
               ノート集計の可否とログの生死を混同しない）。
    """
    rows = []
    skipped = 0
    error_rows = 0
    last_activity = None
    if not path.exists():
        return rows, skipped, error_rows, last_activity
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
            if parts[1].strip() == "ERROR":
                is_fact = (len(parts) > LOG_LEVEL_COL
                           and parts[LOG_LEVEL_COL] == LOG_LEVEL_INFO_VALUE)
                if not is_fact:
                    error_rows += 1
            else:
                skipped += 1
            continue
        rows.append((ts, parts[1].strip(), parts[2]))
    return rows, skipped, error_rows, last_activity


def compute_dismissal_rates(recall_rows, reads_rows, today):
    """「提示されたのに読まれない率」（レビューC-2の看板メトリクス）をノート別に出す。

    判定: 正規化後の1提示単位 (representative_ts, session_id, rel)（後述）ごとに、
    同一 session_id・同一 rel の reads_rows に representative_ts以降 の Read が
    1件でもあれば「読まれた」とみなす（同一セッション内で後からReadされたか、
    という素朴な定義。厳密な1:1消費ではなく「提示後に読まれる習慣があるか」の
    指標として設計）。session_id が空（旧ログ・stdin解析失敗等）の行は突合できない
    ため「読まれた」判定に加算しない（fail-closed側＝過大評価を避ける）。

    集計対象は today から DISMISS_WINDOW_DAYS 日以内の提示イベントに限定する
    （全期間累積のままだとalias修正後の改善が指標に映らない＝2026-07-10
    敵対的レビュー2回目 N-2 対応）。

    窓内の提示イベントはさらに (session_id, rel) 単位で正規化し、同一セッション内で
    同じノートが複数回提示されても1回に数える（2026-07-13 敵対的レビューround3・
    「無視率改善ループ1周目の実績」対応。長時間セッションで過去の棚卸しレポートの
    引用やフック自身の過去提示文がプロンプト本文に再登場して再ヒットし、同一ノートが
    同一セッションで何十回も提示扱いになって無視率ワーストが水増しされるアーティ
    ファクトを除去する。session_id が空の行は他行とグルーピングできない＝実際には
    別セッション由来かもしれない複数行を誤って1つに集約しないよう、行インデックスで
    ユニーク化し従来どおり1行=1提示単位のまま扱う。よってこの正規化は
    「session_id単位の集約」ではなく厳密には「(session_id, rel)が非空の場合のみ効く
    集約」である）。正規化後は、グループ内の最小の提示時刻（代表提示時刻）を基準に
    「提示より前に既読」だった提示単位を分母から除外する（正当な既読スキップを
    無視と誤って数えないため＝同N-3対応。判定できるのは session_id が空でない行のみ）。
    既読判定そのもの（代表提示時刻以降のReadの有無）のロジックの骨格は変えない。

    戻り値: (rows, total_all, windowed_total, excluded_pre_read)
      rows: [(rel_path, presented_normalized, read_rate_percent, raw_presented), ...]
        窓内かつ既読前提示を除いた上で、正規化後の提示回数（session_id空の行を含む
        ため厳密な「提示セッション数」とは限らない）が
        DISMISS_MIN_PRESENTED 回以上のノートのみ・読まれた率が低い順（同率は提示
        回数が多い方を先に＝より確度の高い「無視されている」証拠）に最大
        DISMISS_TOP_N 件。raw_presented は窓内・正規化前かつ既読前提示の除外前の
        生の提示イベント数（参考値。presented_normalizedと直接比較すると既読前
        除外の分だけ差が出ることがある＝重複提示アーティファクトの規模を
        大まかに掴むための数値であり、厳密な差分ではない）。
      total_all: recall_rows 全体（窓の内外問わず）の提示イベント数（正規化前）。
      windowed_total: 窓内の提示イベント数（正規化・既読前提示の除外前）。
      excluded_pre_read: 正規化後のうち「提示より前に既読」で除外した件数。
    """
    reads_by_key = {}
    for ts, sid, rel in reads_rows:
        if not sid:
            continue
        reads_by_key.setdefault((sid, rel), []).append(ts)

    total_all = len(recall_rows)
    windowed_events = []
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
        windowed_events.append((ts, sid, rel))
    windowed_total = len(windowed_events)

    # 参考値: 正規化前の生の提示回数（窓内）
    raw_presented = Counter(rel for _, _sid, rel in windowed_events)

    # (session_id, rel) 単位に正規化（同一グループは最初の提示時刻を代表イベントに）。
    # session_id が空の行はグルーピングできないため、行インデックスでユニーク化し
    # 1行=1グループのまま扱う。
    grouped = {}
    for idx, (ts, sid, rel) in enumerate(windowed_events):
        key = (sid, rel) if sid else (idx, sid, rel)
        if key not in grouped or ts < grouped[key][0]:
            grouped[key] = (ts, sid, rel)

    excluded_pre_read = 0
    presented = Counter()
    read_after = Counter()
    for ts, sid, rel in grouped.values():
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
        rows.append((rel, n, rate, raw_presented.get(rel, 0)))
    rows.sort(key=lambda r: (r[2], -r[1]))
    return rows[:DISMISS_TOP_N], total_all, windowed_total, excluded_pre_read


def main():
    ap = argparse.ArgumentParser(description="外部脳(Obsidian Vault)の定期棚卸し検出ツール。")
    ap.add_argument("--json", action="store_true",
                     help="機械可読なJSON出力を標準出力へ返す（maintenance.sh向け・.mdレポートも従来どおり生成する）")
    args = ap.parse_args()

    today = datetime.date.today()
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    # 2026-07-16簡素化（設計書§3.2）: 隔週実行前提の間隔ガード（月2回・
    # MIN_INTERVAL_DAYS）を撤去し週次実行に統一した（旧LaunchAgentの発火日制御の
    # 名残の分岐をなくす＝本人指示）。maintenance.shが週次で呼ぶ前提のため、
    # 実行頻度そのものの制御は呼び出し側（LaunchAgent間隔）に委ねる。

    notes = {}   # rel_path -> (frontmatter, body, fulltext)
    stems = {}   # ファイル名(拡張子なし) -> [rel_path]
    unreadable_notes = []   # 読込に失敗した.mdの一覧（壊れたsymlink・`.md`名ディレクトリ等）
    for p in sorted(VAULT.rglob("*")):
        rel = p.relative_to(VAULT).as_posix()
        # Explorations/vault-inventory/ 配下は2026-07-11以前の出力先（移設済み）。
        # 過去分がVault内に残っていても検査対象（aliases欠落・リンク切れ等）に
        # 巻き込まないよう、引き続き除外する。
        if p.suffix in (".md", ".canvas") and not rel.startswith(".") \
                and not rel.startswith("Explorations/vault-inventory/"):
            if p.suffix != ".md":
                # .canvasは読込を行わない（従来どおりstemsへ登録するだけ）ため
                # 対象外＝以下の存在チェック・try/exceptは.md限定。
                stems.setdefault(p.stem, []).append(rel)
                continue
            # 存在チェック＋読込自体をtry/exceptで包む（2026-07-16 tester独立
            # 検証で発見されたBOOTSTRAP_FILES欠落クラッシュと同型の欠陥を
            # Codexレビューが本ループでも指摘・リーダー裁定「出荷パイプライン
            # のクラッシュ級は今直す」＋設計判断「読込失敗は警告表示（静かな
            # 除外は不採用）」に対応。壊れたsymlink（`.md`拡張子だがrglob
            # では見えても実体が無い）・`.md`という名前のディレクトリ
            # （read_text()がIsADirectoryErrorを送出）はis_file()==Falseで
            # 検知できるが、権限不備・非UTF-8content・走査中の削除競合等
            # read_text()自体が例外を送出しうる他の経路も併せて塞ぐため、
            # is_file()チェックとtry/exceptの両方で防御する（Codexレビュー
            # 指摘Major対応: is_file()自体もOSErrorを送出しうる環境がある
            # ため、is_file()呼び出しもtry節の内側に含める）。deprecated:true
            # ノートの既存fail-open（「検出のみ・止めない」）と同じ思想で
            # 整合させる＝notesへは追加せずunreadable_notesへ記録して
            # レポートへ警告表示するに留め、CLI全体は継続する。
            #
            # stemsへの登録は「実際に読める通常ファイルだった場合のみ」行う
            # （Codexレビュー指摘Minor対応: 存在チェック前に無条件でstemsへ
            # 登録していたため、壊れたsymlink/`.md`名ディレクトリへの
            # wikilinkが§3のリンク切れ検出から漏れ、過少検出になっていた。
            # §0の「読込に失敗したノート」で別種の異常として可視化される
            # ため、リンク切れ判定側では「実体が無い」ものとして扱う）。
            unreadable_reason = None
            try:
                is_regular_file = p.is_file()
            except OSError as e:
                is_regular_file = False
                unreadable_reason = f"存在確認に失敗しました: {e}"
            if is_regular_file:
                stems.setdefault(p.stem, []).append(rel)
                try:
                    text = p.read_text(encoding="utf-8")
                except (OSError, UnicodeDecodeError) as e:
                    unreadable_reason = f"読込に失敗しました: {e}"
                else:
                    fm, body = vault_lib.parse_frontmatter(text)
                    notes[rel] = (fm, body, text)
            elif unreadable_reason is None:
                unreadable_reason = "ファイルが見つかりません（壊れたsymlink等の可能性）"
            if unreadable_reason is not None:
                unreadable_notes.append((rel, unreadable_reason))

    missing_updated, date_drift, broken_links, stale_hits = [], [], [], []
    status_rows, stalled, status_future_dated = [], [], []
    missing_aliases, generic_alias_hits = [], []
    review_overdue, review_soon, review_invalid = [], [], []
    generic_words = vault_lib.load_generic_aliases(GENERIC_ALIASES_FILE)

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
        for raw in vault_lib.LINK_RE.findall(CODE_RE.sub("", text)):
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
            # 上限（古すぎ＝停滞）だけでなく下限（未来日＝age<0）も見る（Codexレビュー
            # 指摘: 347-353行目のcompute_dismissal_rates()・fail-open-and-observable-guards
            # §1「閾値ガードは上下限をセットで設計する」と同じ既存原則が、ここでは
            # 未適用だった。誤入力/システム時計ズレでupdated/dateが未来日になっていると、
            # ageが負になり下のstalled判定（age > STALE_PROJECT_DAYS）を永久にすり抜けて
            # 「健全」に誤判定される＝無言で見逃さず要確認へ計上する）。
            if age is not None and age < 0:
                status_future_dated.append((rel, fm["status"], ref, age))
            active = status_is_active(fm["status"])
            if active and age is not None and age > STALE_PROJECT_DAYS:
                stalled.append((rel, fm["status"], ref, age))

        # 9./10. aliases 欠落・汎用/短すぎるalias（Knowledge/Preferences/Decisions/Projects/Personal・README除く）
        if rel.startswith(ALIAS_CHECK_DIRS) and not rel.endswith("README.md"):
            aliases = vault_lib.normalize_aliases(fm.get("aliases"))
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
    # 必読ファイルは存在チェックしてから読む（2026-07-16 tester独立検証で
    # 発見・リーダー裁定対応: 以前は無条件でread_text()しており、6ファイル中
    # いずれか1つでも欠けると未処理のFileNotFoundErrorでCLI全体がクラッシュ
    # していた＝サブ機・骨格未整備のVault・ファイル名変更直後などで実際に
    # 起こりうる。claude/hooks/bootstrap-vault.sh側は既に「存在するファイル
    # だけ必読リストに載せる」よう改修済みだったが、本スクリプトの同名ロジック
    # には同じ改修が及んでいなかった。クラッシュさせず「検出のみ」として
    # missing_bootstrap_filesへ記録し、レポート§5にwarningとして載せる
    # ＝設計判断不要の小差分・bootstrap-vault.sh側と同じ扱いへ揃えるだけ）。
    size_rows, total_bytes, total_lines = [], 0, 0
    missing_bootstrap_files = []
    for f in BOOTSTRAP_FILES:
        p = VAULT / f
        if not p.is_file():
            missing_bootstrap_files.append(f)
            continue
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
            _, body = vault_lib.parse_frontmatter(text)
            frag_entries += len(re.findall(r"^(## |- \*\*)", body, re.M))

    # 12. 未読ノート検出＋提示無視率（vault-reads.tsv / vault-recall.tsv）
    # 「読まれた」判定は vault-reads.tsv（実際のRead実績）のみで行う。vault-recall.tsv
    # （提示ログ）は last_seen には混ぜない＝「提示され続けているのに一度もReadされて
    # いないノート」が未読一覧から隠れてしまう無言fail-openを修正（2026-07-10
    # 敵対的レビュー C-2 対応。旧実装は reads/recall を混合していた）。
    reads_rows, reads_skipped, reads_error_rows, reads_last_activity = read_log(READS_LOG_PATH)
    recall_rows, recall_skipped, recall_error_rows, recall_last_activity = read_log(RECALL_LOG_PATH)
    # 「解析できなかった行」の要確認カウントは真に構文破損の疑いがある skipped のみ
    # （ERROR行はフックが仕様通り記録した正常なログなので issue 数に含めない。
    # 2026-07-13 敵対的レビューround3対応）。
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

    # 提示回数上位・提示無視率ワースト集計はheartbeat行（実ノートではない）を
    # 除外する（HEARTBEAT_MARKER定義のコメント参照）。recall_rows自体（死活判定に
    # 使う）はheartbeatを含んだまま残す。
    recall_note_rows = [r for r in recall_rows if r[2] != HEARTBEAT_MARKER]
    recall_top = Counter(rel for _, _sid, rel in recall_note_rows).most_common(RECALL_TOP_N)
    dismissal_rows, dismissal_total_all, dismissal_windowed, dismissal_excluded_pre_read = \
        compute_dismissal_rates(recall_note_rows, reads_rows, today)
    # session_id が空の提示行はRead側と突合できず「読まれた」判定に加算されない
    # （fail-closed側＝過大評価を避ける設計）。無言のfail-openにしないよう件数を出す
    # （Codexレビュー指摘・Minor: 突合不能行が混ざっていることが可視化されないと、
    # 古いログ形式混在時などに提示無視率を過信しかねない）。reads側の空session_idも
    # 同じ理由で数える（Codexレビュー指摘・再レビュー分Minor: recall側だけの注記だと
    # 破損/旧形式のvault-reads.tsvによる読了率の過小評価に気づけない）。
    # recall_note_rows（heartbeat除外後）で数える（Codexレビュー指摘・Minor対応:
    # heartbeat行は「提示」ではないため、session_id空のheartbeatが混ざると
    # 「session_idが空の提示行」注記の件数が実態より過大になり、無視率の
    # 信頼性評価を誤解させうる）。
    recall_no_session = sum(1 for _, sid, _ in recall_note_rows if not sid)
    reads_no_session = sum(1 for _, sid, _ in reads_rows if not sid)

    # ---- レポート生成 ----
    # 要確認件数(n_issues)は本文にレポートされる⚠️付き警告種別を漏れなく積む。
    # 過去の実装は§5(注入サイズ超過)・§8(Fragments capture停止疑い)・
    # §11のreview_soon(14日以内到来)・session_idが空のRead/提示行(§12)を
    # 算入しておらず、本文に⚠️が出ているのに「要確認 0件」表示になり得た
    # （2026-07-14 外部脳バックログ・唯一未裏取りだったCodex指摘の確認により確定。
    # unread_watch（ログ未成熟時の暫定「要観察」）は意図的に対象外のまま＝
    # 断定ではない旨がレポート本文・コードコメント双方で明示されているため）。
    size_over_total = total_lines > SIZE_LIMIT_TOTAL_LINES or total_bytes > SIZE_LIMIT_TOTAL
    size_over_files = sum(1 for _f, _n_lines, _n_bytes, over in size_rows if over)
    fragments_stopped = frag_files == 0
    n_issues = (len(missing_updated) + len(date_drift) + len(broken_links) + len(stale_hits) + len(stalled)
                + len(status_future_dated)
                + len(missing_aliases) + len(generic_alias_hits) + len(review_overdue) + len(review_invalid)
                + len(review_soon)
                + len(unread_confirmed) + (1 if log_skipped else 0)
                + (1 if reads_log_stale else 0) + (1 if recall_log_stale else 0)
                + (1 if reads_log_broken else 0) + (1 if recall_log_broken else 0)
                + (1 if reads_log_future else 0) + (1 if recall_log_future else 0)
                + (1 if size_over_total else 0) + size_over_files + len(missing_bootstrap_files)
                + len(unreadable_notes)
                + (1 if fragments_stopped else 0)
                + (1 if reads_no_session else 0) + (1 if recall_no_session else 0))
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
             f"**要確認 {n_issues} 件**。本レポートは検出のみで自動対処はしない（2026-07-16簡素化で"
             "「最初のセッションでリーダーが自律対処」運用は撤去済み）。綻び（鮮度・リンク切れ・alias）は"
             "気づいた時点で読み時に直し、更新日ズレ・波及漏れ疑い等は次回の棚卸し相談で人間と目視する"
             "＝[[Knowledge/external-brain-maintenance-split]]。運用ノート:"
             " [[Knowledge/external-brain-guide#定期チェック（陳腐化・肥大化の検出）]]")

    def section(title, rows, fmt, empty="✅ 問題なし"):
        L.append("")
        L.append(f"## {title}")
        if not rows:
            L.append(empty)
        else:
            L.extend(fmt(r) for r in rows)

    section(f"0. 読込に失敗したノート（壊れたsymlink・`.md`名ディレクトリ・非UTF-8等・"
            f"{len(unreadable_notes)}件・他の全チェックの対象外）",
            unreadable_notes, lambda r: f"- `{r[0]}` — {r[1]}")

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
    for f in missing_bootstrap_files:
        L.append(f"- `{f}` — ⚠️ ファイルが見つかりません（サブ機・骨格未整備・"
                 "ファイル名変更直後等の可能性。注入サイズの合計には計上していません）")

    section(f"6. 停滞プロジェクト（active なのに {STALE_PROJECT_DAYS} 日以上更新なし・{len(stalled)}件）",
            stalled, lambda r: f"- `{r[0]}` — {r[1]}（最終 {r[2]}・{r[3]}日前）")
    section(f"6b. statusノートのupdated/dateが未来日（システム時計ズレ/誤入力の疑い・{len(status_future_dated)}件）",
            status_future_dated, lambda r: f"- `{r[0]}` — {r[1]}（{r[2]}は今日から見て未来日）")

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
    L.append(f"## 9. aliases が無いノート（Knowledge/Preferences/Decisions/Projects/Personal・README除く・{len(missing_aliases)}件）")
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
    if reads_skipped or reads_error_rows:
        # ERROR行（フックが自ら記録する正常なエラーログ）と真に構文が壊れている行を
        # 分離して表示する（従来はERROR行をskippedへ合算し「ログ破損の疑い」として
        # 表示していたため、真の破損と区別できなかった＝2026-07-13
        # 敵対的レビューround3の実バグ級指摘対応）。
        L.append(f"解析対象外の vault-reads.tsv 行 {reads_skipped + reads_error_rows} 件"
                 f"（うち ERROR行 {reads_error_rows} 件・真に解析不能な行 {reads_skipped} 件）。"
                 "ERROR行はフックが仕様通り記録した正常なエラーログ（下記の死活判定で扱う）。"
                 + (f" ⚠️ 真に解析不能な行が {reads_skipped} 件あります"
                    "（タブ区切り不正・時刻不正）＝ログ破損の疑い。件数が多い場合は"
                    "フックの出力形式を確認する。" if reads_skipped else ""))
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
    L.append(f"### 提示無視率ワースト（vault-recall.tsv・正規化後の提示{DISMISS_MIN_PRESENTED}回以上・ワースト{DISMISS_TOP_N}件）")
    L.append("同一セッション内で提示された後にReadされた割合。低いほど「提示されるのに読まれない」"
             "悪玉alias／不要ノートの疑い（提示→Read のsession_id突合。看板メトリクス・"
             "2026-07-10 敵対的レビュー C-2 対応）。")
    L.append("分母は (session_id, ノート) 単位に正規化した提示回数（同一セッション内で同じ"
             "ノートが何度も再登場しても1回に数える。長時間セッションで過去の棚卸しレポートの"
             "引用やフック自身の過去提示文がプロンプト本文に再登場して再ヒットし、無視率ワーストが"
             "水増しされるアーティファクトを除去＝2026-07-13 敵対的レビューround3対応。session_idが"
             "空の行は突合不能なため正規化されず1行のまま数える＝下記の件数は厳密な「セッション数」"
             "ではなく「正規化後の提示回数」。正規化前の生の提示回数は各行末尾に参考値として併記）。")
    L.append(f"観測: 直近{DISMISS_WINDOW_DAYS}日・全期間の提示は{dismissal_total_all}件"
             f"（うち窓内{dismissal_windowed}件を対象）。全期間累積ではなく直近の窓だけを見ることで、"
             "alias修正後の改善が次回レポートに反映されるようにしています"
             "（2026-07-10 敵対的レビュー2回目 N-2 対応）。")
    L.append(f"うち、正規化後の提示のうち提示より前に既読だった{dismissal_excluded_pre_read}件は"
             "「正当な既読スキップ」とみなし分母から除外しました"
             "（2026-07-10 敵対的レビュー2回目 N-3 対応）。")
    if recall_skipped or recall_error_rows:
        L.append(f"解析対象外の vault-recall.tsv 行 {recall_skipped + recall_error_rows} 件"
                 f"（うち ERROR行 {recall_error_rows} 件・真に解析不能な行 {recall_skipped} 件）。"
                 "ERROR行はフックが仕様通り記録した正常なエラーログ（下記の死活判定で扱う）。"
                 + (f" ⚠️ 真に解析不能な行が {recall_skipped} 件あります＝ログ破損の疑い。"
                    if recall_skipped else ""))
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
        L.append(f"該当なし（正規化後の提示{DISMISS_MIN_PRESENTED}回以上のノートがまだありません）")
    else:
        L.extend(f"- `{rel}` — 提示{n}回中 読まれた率{rate}%（生提示回数{raw_n}）"
                 for rel, n, rate, raw_n in dismissal_rows)

    if recall_top:
        L.append("")
        L.append(f"おまけ: vault-recall.tsv 提示回数 上位{len(recall_top)}件（誤ヒットの多いaliasの手がかり）")
        L.extend(f"- `{r}` — {n}回" for r, n in recall_top)
    L.append("")

    out = OUT_DIR / f"{today.isoformat()}.md"
    out.write_text("\n".join(L), encoding="utf-8")

    if args.json:
        # --json時は標準出力をJSON1行のみにする（呼び出し元=maintenance_run_step.py
        # がそのままjson.loads()する契約。人間向けメッセージは標準エラーへ回す・
        # fragments_log.pyと同じ流儀）。missing_updated_fix_candidatesキーは
        # FIX機能撤去（2026-07-18本人裁定・[[Decisions/2026-07-18-external-
        # brain-hardening]]）に伴い削除した＝missing_updatedは検出のみで
        # n_issuesへの計上と`.md`レポート§1への表示にとどまる。
        payload = {
            "date": today.isoformat(),
            "report_path": str(out),
            "n_issues": n_issues,
            "n_notes": len(notes),
        }
        print(f"レポート生成: {out}（要確認 {n_issues} 件）", file=sys.stderr)
        print(json.dumps(payload, ensure_ascii=False))
    else:
        print(f"レポート生成: {out}（要確認 {n_issues} 件）")


if __name__ == "__main__":
    main()
