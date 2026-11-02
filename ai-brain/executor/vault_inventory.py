#!/usr/bin/env python3
"""外部脳(Obsidian Vault)の定期棚卸しレポート生成ツール。

チェック項目（external-brain-guide §定期チェック の自動化）:
  1. 方針ノート(Preferences)の updated 欠落
  2. 本文中の最新日付が frontmatter の updated/date より新しい（更新日漏れの疑い）
  3. wiki link ([[...]]) のリンク切れ
  4. 旧方針キーワードの残存（Decisions/mistakes-archive は履歴なので対象外）
  5. 必読ファイル（BOOTSTRAP_FILES＝bootstrap-vault.shのFILES配列と同期）の注入サイズ監視
  6. status 付きノートの一覧と停滞検知
  8. Fragments の直近統計（capture が続いているか・昇格レビューの目安）
  11. review_by の期限超過・14日以内到来（任意フィールド）

出力: ~/.claude/logs/vault-inventory/YYYY-MM-DD.md（人間向け・日本語。2026-07-11
      決定＝「読まれない人間向け資料をVaultに置かない」に伴い、Vault配下
      （旧: Explorations/vault-inventory/）から $HOME/.claude/logs/ 配下へ移設）。
      `--json` 指定時は上記`.md`に加え、機械可読なJSON（棚卸し件数サマリ）を
      標準出力へ返す（2026-07-16簡素化）。missing_updated（Preferences限定の
      updated欠落）は**検出のみ**（レポート§1・actionable計上）で、機械的な
      修正（FIX機能・action: fix_approve）は2026-07-18本人裁定で丸ごと削除
      した＝[[Decisions/2026-07-18-external-brain-hardening]]（理由＝
      Preferences限定でしか動かず「夜間はPreferencesを書かない」境界の唯一の
      違反経路だった・値も効果限定的）。以後は他の棚卸し項目（date_drift・
      リンク切れ等）と同じく、読み時/棚卸し相談で人間が直す。
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
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
# frontmatter解析・wikilink正規表現・aliases正規化・汎用alias禁止リスト読込は
# 2026-07-16簡素化（cleanup決定#10）でvault_lib.pyへ抽出済み（他4本＝
# embedding_index.py→撤去済み・knowledge_merge.py→撤去済み・merge_quality_gate.py→
# 撤去済み・重複候補検出関連の旧CLI（2026-09-19退役）・recall_bench.pyが`import vault_inventory`
# していたのはこれらの関数だけを再利用するためだった＝CLI/共有ライブラリ同居の解消）。
import vault_lib  # noqa: E402

VAULT = pathlib.Path.home() / "Data" / "obsidian"
OUT_DIR = pathlib.Path.home() / ".claude" / "logs" / "vault-inventory"

# 必読ファイル（bootstrap-vault.sh の FILES 配列・最終形と同じ並び）。
# 2026-08-30 §9.0 A-1-3波及改修（本人承認済み）でbootstrap-vault.sh側が
# Knowledge/mistakes.mdを除去しPreferences/core-conduct.md・
# Preferences/core-workflow.mdを追加したのに合わせて同期した
# （リーダー裁定・mistakes.md現役則「schema・設定のキーやスロットを増減する
# 時は参照側と必ずセットで直す」該当。放置すると週次メンテの棚卸しが
# check-drift誤報と同型の恒常ノイズを出すため）。
# 2026-09-05 P3段階4対応: bootstrap-vault.sh側がPreferences/profile.md・
# Preferences/coding-delegation.mdを必読FILES配列から外した（コアへの
# 移送完了・配布済みのため。共通コア分離-設計 §9.3 P3）のに合わせて同期した。
# ローカル実体プロファイル（$HOME/.config/takumi009-ai-env/profile.md）は
# Vault外の固定パスであり本リストの対象外のまま（bootstrap-vault.sh側でも
# BOOTSTRAP_FILES/FILESとは別扱い＝従来どおり）。
BOOTSTRAP_FILES = [
    "Preferences/absolute-rules.md",
    "Preferences/core-conduct.md",
    "Preferences/core-workflow.md",
    "Personal/profile-personal.md",
    "Preferences/vault-operation.md",
]
# 2026-08-30 §9.0 A-1-3波及改修（本人承認済み・リーダー裁定）に伴う再基準化:
# BOOTSTRAP_FILESへcore-conduct.md・core-workflow.mdを追加した結果、必読
# 集合の実測がメイン機で274行/44,563バイト（旧閾値150行/20,480バイトを
# 大きく超過・core-conduct.md単体66行・core-workflow.md単体84行で旧40行
# 閾値も超過）となり、要確認件数が常時3件以上の恒常ノイズを出していた
# （check-drift誤報と同型の問題）。裁定＝「予算の再基準化」（コア本文の
# 圧縮はしない＝採用済み本文のchurn回避）。閾値は「現必読集合の実測＋20%
# 程度の余裕」へ引き上げた。
# 2026-09-05 P3段階4で再基準化: Preferences/profile.md・coding-delegation.md
# をBOOTSTRAP_FILESから外した結果、実測がメイン機で248行/37,911バイトへ
# 縮小した（内訳: absolute-rules.md 17行/2,502B・core-conduct.md 76行/
# 13,849B・core-workflow.md 98行/12,819B・profile-personal.md 17行/1,756B・
# vault-operation.md 40行/6,985B）。同じ「実測＋20%程度の余裕」の基準で
# 閾値を引き下げる（引き上げっぱなしにすると縮小後も要確認件数が常時0件の
# まま検出力を失うノイズの逆型になるため）。今後必読集合が変わった際は
# 本閾値も再度見直すこと。
SIZE_LIMIT_LINES = 120        # 1ファイルの目安（旧100。実測最大値
                               # core-workflow.md 98行 × 約1.2 ≒ 120行）
SIZE_LIMIT_TOTAL_LINES = 300  # 合計行数（旧330。実測248行 × 約1.2 ≒ 300行）
SIZE_LIMIT_TOTAL = 45500      # 合計バイト数（旧53,500。実測37,911バイト
                               # × 約1.2 ≒ 45,500バイト）

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
    ("Preferences/absolute-rules.md", "Codex へ委任する全プロンプト"),  # 現役ルール（Codex の口の必読強制・2026-09-16 文面追補で「（初回も --resume も）」が入った）
    ("Knowledge/core-rules-compression-archive.md", "Codex へ委任する全プロンプト"),  # 同上の原文保管（圧縮台帳）
    ("Preferences/web-verify-before-acting.md", "毎回 Codex に委任すると"),  # Why欄の経緯説明
    ("Knowledge/anthropic-claude-models-2026-06.md", "02-05 Opus 4.6"),  # リリース履歴（事実）
    ("Knowledge/claude-codex-orchestration-best-practice.md", "参考価格"),  # 公式価格の引用（事実）
    ("Projects/news-report-automation.md", "モデル sonnet-4-6"),  # 稼働中クラウドルーティンの設定値（事実）
]

DATE_RE = re.compile(r"\b(20\d{2}-\d{2}-\d{2})\b")
# wikilink検出用正規表現はvault_lib.LINK_REへ、コードフェンス/インラインコード検出用
# 正規表現はvault_lib.CODE_REへ抽出済み（2026-07-16簡素化。品質ゲート用CLI（2026-09-19退役）
# 新設時に共用するため後者も抽出）。
CODE_RE = vault_lib.CODE_RE
STALE_PROJECT_DAYS = 30

DATE_ONLY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
REVIEW_SOON_DAYS = 14      # review_by がこの日数以内に来るものを「まもなく」として警告
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


def write_latest_json(payload):
    """棚卸しの正本 `OUT_DIR/latest.json` を tmp→os.replace で原子的に書く
    （design-step2 §3.1・§6.1）。書込失敗は例外のまま呼び出し元(main)へ
    伝播させる＝maintenance_run_step.py の_write_status_file()と異なり
    fail-openにしない設計（md書込失敗と同じくPhase1③をanomaly化させ、
    latest.jsonは前回のまま日付で古さが見えるようにする＝design-step2 §6.4）。
    """
    fd, tmp_name = tempfile.mkstemp(prefix=".latest.json.tmp-", dir=str(OUT_DIR))
    tmp_path = pathlib.Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(json.dumps(payload, ensure_ascii=False))
        os.replace(str(tmp_path), str(OUT_DIR / "latest.json"))
    except Exception:
        tmp_path.unlink(missing_ok=True)
        raise


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
        # 過去分がVault内に残っていても検査対象（リンク切れ等）に
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
    review_overdue, review_soon, review_invalid = [], [], []

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
            # 古すぎる状態だけでなく、誤入力や時計ズレによる未来日も要確認に数える。
            if age is not None and age < 0:
                status_future_dated.append((rel, fm["status"], ref, age))
            active = status_is_active(fm["status"])
            if active and age is not None and age > STALE_PROJECT_DAYS:
                stalled.append((rel, fm["status"], ref, age))

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

    # ---- レポート生成 ----
    # actionable（旧・要確認件数の全種別合算）は「AIが直せる対処可能な項目」だけを数える
    # （design-step2 §3.1・本人裁定2026-09-19③）。数える＝§0 unreadable_notes・
    # §1 missing_updated・§2 date_drift・§3 broken_links・§4 stale_hits・
    # §6b status_future_dated・
    # §11 review_overdue+review_invalid。数えない（md には従来どおり⚠️付き
    # 情報表示のまま残す）＝§5 サイズ超過・必読欠落（旧裁定の6ファイル基準が
    # 前提から外れた＝§10-4・段3-4の必読圧縮まで据え置き）・§6 停滞プロジェクト・
    # §8 Fragments capture停止疑い・§11 review_soon（14日以内到来）・
    # （AIが機械的に直せない/人間の目視相談が要る項目のため）。
    size_over_total = total_lines > SIZE_LIMIT_TOTAL_LINES or total_bytes > SIZE_LIMIT_TOTAL
    size_over_files = sum(1 for _f, _n_lines, _n_bytes, over in size_rows if over)
    fragments_stopped = frag_files == 0
    sections = {
        "unreadable": len(unreadable_notes),
        "missing_updated": len(missing_updated),
        "date_drift": len(date_drift),
        "broken_links": len(broken_links),
        "stale_keywords": len(stale_hits),
        "status_future_dated": len(status_future_dated),
        "review_overdue": len(review_overdue),
        "review_invalid": len(review_invalid),
    }
    actionable = sum(sections.values())
    # items＝要確認 1 件ごとの {kind, target, detail}（health-self-explain 設計 v1.2 §3.5・
    # 2026-09-20）。kind は sections のキーと同じ語彙、並びは sections と同じ順、
    # target／detail は md レポートの各節の行と同じ材料（読み手＝health_judge.py が
    # 注入ブロックの棚卸し項目 4 点＝種別・対象・主体・減る条件に写す）。
    # 検出ロジックは不変（SO-3）＝actionable に数える 10 種別の行をそのまま並べる
    # だけなので len(items) == actionable を書き手が保証する（テストで検査）。
    # 停滞プロジェクト・サイズ超過・未読・要観察は actionable に数えないので載せない（R-1）。
    items = []
    items.extend({"kind": "unreadable", "target": rel, "detail": reason}
                 for rel, reason in unreadable_notes)
    items.extend({"kind": "missing_updated", "target": rel, "detail": "updated が無い（Preferences）"}
                 for rel in missing_updated)
    items.extend({"kind": "date_drift", "target": rel,
                  "detail": f"frontmatter: {fm_date} ＜ 本文最新: {body_date}"}
                 for rel, fm_date, body_date in date_drift)
    items.extend({"kind": "broken_links", "target": rel, "detail": f"[[{target}]]"}
                 for rel, target in broken_links)
    items.extend({"kind": "stale_keywords", "target": f"{rel}:{line_no}", "detail": f"【{label}】 {snippet}"}
                 for rel, line_no, label, snippet in stale_hits)
    items.extend({"kind": "status_future_dated", "target": rel,
                  "detail": f"{status}（{ref}は今日から見て未来日）"}
                 for rel, status, ref, _age in status_future_dated)
    items.extend({"kind": "review_overdue", "target": rel, "detail": f"review_by {rb}（{days}日超過）"}
                 for rel, rb, days in review_overdue)
    items.extend({"kind": "review_invalid", "target": rel, "detail": f"review_by: {rb}"}
                 for rel, rb in review_invalid)
    assert len(items) == actionable, f"items({len(items)}) != actionable({actionable})"
    L = []
    L.append("---")
    L.append(f"date: {today.isoformat()}")
    L.append("tags: [vault-inventory, report]")
    L.append("project: external-brain")
    L.append("---")
    L.append("")
    L.append(f"# 外部脳 棚卸しレポート {today.isoformat()}")
    L.append("")
    L.append(f"自動生成（`work/takumi009-ai-env/ai-brain/executor/`）。ノート {len(notes)} 件を検査し、"
             f"**要確認 {actionable} 件（対処可能な項目のみ。停滞・未読・サイズは各節の情報表示）**。"
             "本レポートは検出のみで自動対処はしない（2026-07-16簡素化で"
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
    L.append(f"## 11. review_by の期限（任意フィールド・超過{len(review_overdue)}件／{REVIEW_SOON_DAYS}日以内{len(review_soon)}件）")
    L.append("review_by は外部情報系ノート（モデル情報など陳腐化しやすいもの）に任意で付ける確認期限。"
             "超過・接近したノートは内容を見直し、review_by を更新するか役目を終えていれば外す。")
    if not review_overdue and not review_soon and not review_invalid:
        L.append("✅ 問題なし")
    else:
        L.append("**期限超過:**" if review_overdue else "**期限超過:** なし")
        L.extend(f"- `{r}` — review_by {d}（{days}日超過）" for r, d, days in review_overdue)
        L.append(f"**{REVIEW_SOON_DAYS}日以内に到来（情報・actionableには数えない）:**"
                 if review_soon else f"**{REVIEW_SOON_DAYS}日以内に到来（情報）:** なし")
        L.extend(f"- `{r}` — review_by {d}（あと{days}日）" for r, d, days in review_soon)
    if review_invalid:
        L.append("**形式不正（`YYYY-MM-DD`で書き直す）:**")
        L.extend(f"- `{r}` — review_by: `{d}`" for r, d in review_invalid)

    L.append("")
    out = OUT_DIR / f"{today.isoformat()}.md"
    out.write_text("\n".join(L), encoding="utf-8")

    # latest.json＝最新棚卸しの正本（design-step2 §3.1・§6.1）。mdの直後に
    # 原子的に書く。書込に失敗すれば例外がmain()を抜けてexit≠0になり、
    # Phase1③がanomaly化する（latest.jsonは前回のまま＝日付で古さが見える・
    # design-step2 §6.4）。
    write_latest_json({
        "date": today.isoformat(),
        "report_path": str(out),
        "actionable": actionable,
        "n_notes": len(notes),
        "sections": sections,
        "items": items,
    })

    if args.json:
        # --json時は標準出力をJSON1行のみにする（呼び出し元=maintenance_run_step.py
        # がそのままjson.loads()する契約。人間向けメッセージは標準エラーへ回す・
        # fragments_log.pyと同じ流儀）。missing_updated_fix_candidatesキーは
        # FIX機能撤去（2026-07-18本人裁定・[[Decisions/2026-07-18-external-
        # brain-hardening]]）に伴い削除した＝missing_updatedは検出のみで
        # actionableへの計上と`.md`レポート§1への表示にとどまる。
        payload = {
            "date": today.isoformat(),
            "report_path": str(out),
            "actionable": actionable,
            "n_notes": len(notes),
        }
        print(f"レポート生成: {out}（要確認 {actionable} 件）", file=sys.stderr)
        print(json.dumps(payload, ensure_ascii=False))
    else:
        print(f"レポート生成: {out}（要確認 {actionable} 件）")


if __name__ == "__main__":
    main()
