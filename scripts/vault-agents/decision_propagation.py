#!/usr/bin/env python3
"""Decision波及チェックツール（decision-propagation-check）。

外部脳(Obsidian Vault)の運用ルール「体制を変える Decision を書いたら影響語を
grep して現在形ノート（Preferences/Projects/Knowledge）を同時修正し、grep 語と
修正ファイルを Decision の「適用」欄に記録する（波及チェック。履歴ノートは
直さない）」が守られているかを機械検証する読み取り専用CLI。

チェック項目:
  1. 影響語抽出（F2）: Decision 本文から照合語を導出する（辞書ハードコード禁止）。
     導出元は (a) frontmatter の aliases、(b) H1 タイトル、(c) 本文の太字スパン
     （**...**）の3系統。タイトル・太字は句読点/括弧/記号でフレーズ分割してから
     採用し、さらに定型尾部（「〜の決定」「〜する」等の述語ボイラープレート）・
     末尾助詞を剥がした変種も加える（BOILERPLATE_TAIL_RE のコメント参照。語は
     すべて Decision 由来＝辞書ハードコード禁止と両立）。この3系統を選んだ理由: Vault の Decision ノートは「太字＝決定の
     核心語」「aliases＝想起フックの検索キー（＝書き手が選んだ代表語）」という
     書式慣行があり、本文全文の名詞抽出（形態素解析なしでは精度が出ない）より
     も高精度に「体制変更の核心語」だけを拾えるため。
  2. 照合（F3）: Preferences/ Projects/ Knowledge/ の現在形ノート(.md)を走査し、
     影響語がヒットするノートと該当行を列挙する。除外:
       (a) 「廃止/撤去/deprecated/旧〜」等を含む行（vault_inventory.py の
           STALE_LINE_OK の一般化＝新体制側の記述とみなす。定数コメント参照）
       (b) 入力 Decision 自身と Decisions/ 配下（履歴ノート）
       (c) Knowledge/mistakes-archive.md（履歴ノート）
       (d) コードフェンス（``` 〜 ```）内の行（コマンド例・ログ引用は本文の
           方針記述ではないため。裁量判断）
  3. 適用欄突合（F4）: 「## 適用」見出し（「### 適用」「## 適用（YYYY-MM-DD）」
     「## 適用・反映」等の表記ゆれ許容。「適用範囲」のような別語は誤認しない）
     配下から wiki link・ファイルパス・`.md` ファイル名を抽出し、F3 ヒットを
     「適用欄に記録済み」「記録なし＝波及漏れの疑い」に分類する。構造抽出で
     拾えない記載（空白を含む裸のファイル名等）は適用欄本文への部分一致
     フォールバック（recorded_by_text）で救済する。適用欄自体が
     無い Decision は「適用欄なし」として別区分で報告する（漏れとは混ぜない）。
     適用欄に記録されたノートは影響語ヒットの有無によらず「記録済み」区分に
     列挙する（記録の実在確認が主目的のため。ヒット行数は参考情報として併記）。
  4. 偽陽性抑制（F6）: 汎用語の単独ヒットでノートを漏れ扱いしないための2段構え。
     (a) 最低語長: ASCIIのみ4文字未満・非ASCII含み3文字未満の候補語は捨てる
         （vault_inventory.py §10「短すぎるalias」検出と同じ発想。「実装」の
         ような2字熟語は単独では汎用すぎるため）。
     (b) 文書頻度(DF)による希少度フィルタ: 影響語が走査対象ノートのうち
         max(GENERIC_DF_MIN, ceil(対象ノート数×GENERIC_DF_RATIO)) 件以上に
         出現する場合は「Vault 全体で使われる汎用語」とみなし照合から除外する
         （tf-idf の idf に相当。辞書を持たずに Vault 自身から汎用度を学習する
         ため F2 の辞書ハードコード禁止と両立する）。除外した語はレポートに
         明示し、無言で握り潰さない。絶対下限 GENERIC_DF_MIN を置くのは、
         ノート数が少ない小規模 Vault（テスト fixture 等）で比率だけだと
         全語が汎用扱いになる縮退を防ぐため。

出力: 人間可読の Markdown レポートを stdout へ（--out <path> 指定時はファイル
      にも書く。--out が Vault 配下を指す場合は書かずにエラー終了＝A7 の
      読み取り専用保証）。構成＝件数サマリ→Decision 別詳細（影響語一覧・
      記録済みノート・漏れ疑いノート＋該当行抜粋）。
終了コード: 漏れ疑いあり=1／なし=0／実行エラー・走査不完全（読取失敗ノートあり）=2。
　　　　　　影響語を抽出できなかった Decision は「検証不能」区分としてレポートに
　　　　　　明示する（exit には影響させない＝検証不能は漏れの証拠でも不在の証拠
　　　　　　でもないため。サマリの⚠️で目視確認を促す）。
実行方法:
  python3 scripts/vault-agents/decision_propagation.py --decision Decisions/2026-07-05-codex-reviewer-only.md
  python3 scripts/vault-agents/decision_propagation.py --since 2026-06-14 [--out report.md]
  （両方省略時は直近30日の Decision を走査。Vault パスは環境変数 VAULT で
    上書き可・既定 ~/Data/obsidian。Vault へは一切書き込まない）
"""
import argparse
import datetime
import math
import os
import pathlib
import re
import sys
import unicodedata

VAULT = pathlib.Path(os.environ.get("VAULT", str(pathlib.Path.home() / "Data" / "obsidian")))

# 照合対象の現在形ノートフォルダ（履歴系＝Decisions/mistakes-archive は対象外）
CHECK_DIRS = ("Preferences/", "Projects/", "Knowledge/")
CHECK_EXCLUDE = ("Knowledge/mistakes-archive.md",)
DEFAULT_SINCE_DAYS = 30

# 「廃止/撤去/deprecated/旧」を含む行は新体制側の記述とみなし漏れ判定から除外。
# vault_inventory.py の STALE_LINE_OK（旧方式|旧「|旧C|は旧 の列挙）を一般化し、
# 「旧手順」「旧ルール」「旧体制」等の任意の「旧＋名詞」連結を先読みで包括する
# （Codexレビュー指摘・Major: 列挙方式では拾えない「旧」記述を漏れ疑いへ誤分類
# していた）。「復旧」「新旧」のような別語に含まれる旧は後読みで除外する。
# 「旧 API」のような空白挟みは先読みに \s* を許して拾い、「DEPRECATED」等の
# 大文字混在は re.IGNORECASE で拾う（Codexレビュー3巡目・Major）。
STALE_LINE_OK = re.compile(
    r"廃止|撤去|deprecated|は旧|(?<![復新])旧(?=\s*[A-Za-z0-9ァ-ヶ一-龠々「])", re.IGNORECASE)

DATE_RE = re.compile(r"\b20\d{2}-\d{2}-\d{2}\b")
LINK_RE = re.compile(r"\[\[([^\[\]]+?)\]\]")
BOLD_RE = re.compile(r"\*\*(.+?)\*\*")
H1_RE = re.compile(r"^#\s+(.+)$", re.M)
FENCE_RE = re.compile(r"^\s*(```|~~~)")
CODE_SPAN_RE = re.compile(r"`[^`\n]*`")  # インラインコード（太字抽出の除外用）
# 「## 適用」「### 適用」「## 適用（YYYY-MM-DD）」「## 適用・反映」等を許容。
# 「適用」直後が行末か区切り記号（（ ( ・ : ： 、 空白）の場合のみ適用欄と
# みなし、「## 適用範囲の調整」のような別見出し（実Vaultに実在）は誤認しない。
APPLY_HEADING_RE = re.compile(r"^(#{2,3})\s*適用(?:\s*$|[\s（(・:：、])")
# 適用欄からのファイル名抽出（Codexレビュー指摘・Major対応で空白許容を追加）:
#   1) フォルダ付き *.md パス（空白を含んでよい。フォルダ名アンカー＋ASCII文字
#      クラスで前後の日本語文への食み出しを防ぐ）
#   2) フォルダ付き拡張子なしパス（空白なし。終端が判定できないため従来どおり）
#   3) 裸の *.md ファイル名・空白なし（unicode \w＝日本語ファイル名も拾う従来挙動）
#   4) 裸の *.md ファイル名・空白あり（ASCII語のみ。unicode \w に空白まで許すと
#      前置きの日本語文まで巻き込むため）。空白入り日本語ファイル名は構造抽出
#      できないが、check_decision の適用欄本文への部分一致フォールバックで救済する
APPLY_PATH_RE = re.compile(
    r"\b((?:Preferences|Projects|Knowledge|Decisions|Personal)/[A-Za-z0-9_\-. /]*?\.md"
    r"|(?:Preferences|Projects|Knowledge|Decisions|Personal)/[\w\-./]+"
    r"|[\w\-]+\.md"
    r"|[A-Za-z0-9_-][A-Za-z0-9_\- ]*\.md)\b")

# フレーズ分割の区切り（句読点・括弧・記号。空白は英語複合語を壊すため含めない）
PHRASE_SPLIT_RE = re.compile(r"[、。・：:；;（）()「」『』【】\[\]／/＝=→⇒,!！?？…※→　]+")
# 数字・日付・記号だけの候補語は捨てる
NUMERIC_ONLY_RE = re.compile(r"[\d\s\-./%:年月日回件]+")

# F6(a) 最低語長（vault_inventory.py §10 の「短すぎるalias」閾値より1段厳しめ。
# 照合は alias と違い本文全行への substring 一致なので誤ヒット面積が広いため）
ASCII_MIN_LEN = 4
NONASCII_MIN_LEN = 3
# 平仮名だけの語はこの長さ未満なら機能語とみなして捨てる（_clean_term 参照）
HIRAGANA_ONLY_RE = re.compile(r"[ぁ-んー]+")
HIRAGANA_ONLY_MIN_LEN = 5
# F6(b) DF フィルタ: 影響語がこの件数以上のノートに出るなら汎用語として除外。
# 比率 0.08 は実 Vault（126ノート・2026-07-15時点）での較正値＝「リーダー」(DF=31)
# 「成果物」(DF=23)「Edit」(DF=20) といった Vault 全域で使われる語を除外しつつ、
# 「オーケストレーター」(DF=7) 程度の準特異語は残す境界。絶対下限 GENERIC_DF_MIN
# は小規模 Vault（テスト fixture）での縮退防止（docstring チェック項目4参照）
GENERIC_DF_MIN = 5
GENERIC_DF_RATIO = 0.08
# 飽和上限: ノート数が GENERIC_DF_MIN 未満の小規模 Vault では絶対下限5が効かず
# 「Claude」等の汎用語が全ノートにあっても除外されない（Codexレビュー指摘・
# Major）。ノート数3件以上なら「対象ノートの8割以上に出る語」は規模によらず
# 汎用とみなし閾値を切り下げる。2件以下では飽和判定しない（1〜2ノートの fixture
# で唯一の影響語が即汎用化する縮退防止＝A2等の検出性を優先）。
GENERIC_DF_SATURATION = 0.8
GENERIC_DF_SATURATION_MIN_NOTES = 3
# 1 Decision あたりの影響語上限（長い語を優先。実行時間の上限保証＝A1 30秒）
MAX_TERMS = 60
# 漏れ疑いノート1件あたりの該当行抜粋の上限
MAX_EXCERPT_LINES = 5
EXCERPT_WIDTH = 80


def nfc(s):
    """Unicode NFC 正規化。macOS のファイル名は NFD で保持されることがあり、
    本文（通常 NFC）との照合・適用欄パス突合が正規化差で外れる（Codexレビュー
    指摘・Major）。読み込む全テキストとノート相対パスを NFC に揃える。"""
    return unicodedata.normalize("NFC", s)


def strip_fences(text):
    """コードフェンス（```/~~~）ブロックを除いた本文を返す。フェンス内の
    「## 適用」見出し・太字・H1 を実体と誤認しないための前処理（Codexレビュー
    指摘・Major×2: 適用欄の誤検出＝A4 区分破壊・サンプルコード由来の偽影響語）。"""
    out = []
    in_fence = False
    for line in text.splitlines():
        if FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        if not in_fence:
            out.append(line)
    return "\n".join(out)


def effective_text(text):
    """DF 計算用の「有効本文」（casefold 済み。単純 lower() は Unicode の
    大小文字対応を取りこぼすため＝Codexレビュー3巡目・Major。照合系の小文字化は
    すべて casefold に統一）。照合（match_lines）と同じ除外規則＝
    フェンス内・stale 行を落とす。全文カウントだと deprecated 行やコード例で
    DF が水増しされ、真の波及漏れの影響語まで汎用扱いで除外しうる（Codex
    レビュー指摘・Major）。"""
    keep = []
    in_fence = False
    for line in text.splitlines():
        if FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        if in_fence or STALE_LINE_OK.search(line):
            continue
        keep.append(line)
    return "\n".join(keep).casefold()


def parse_frontmatter(text):
    """frontmatter をキー→値(文字列 or リスト)の辞書にする。
    vault_inventory.py の同名関数の簡略版（本ツールが使う date/aliases の
    単一行値・フロー形式リスト・複数行リストのみ対応）。"""
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
        key, val = kv.group(1), kv.group(2).strip()
        if val:
            if val.startswith("[") and val.endswith("]"):
                fm[key] = [x.strip().strip('"').strip("'") for x in val[1:-1].split(",") if x.strip()]
            else:
                fm[key] = val.strip('"')
            i += 1
            continue
        items = []
        j = i + 1
        while j < len(lines):
            bm = re.match(r"\s+-\s+(.+)", lines[j])
            if not bm:
                break
            item = bm.group(1).strip()
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
    """aliases 値（リスト/カンマ区切り文字列/未設定）を文字列リストにする。"""
    if not val:
        return []
    items = val if isinstance(val, list) else re.split(r"[,、]", val)
    return [x.strip() for x in items if x.strip()]


def _clean_term(raw):
    """フレーズ候補1件を正規化し、影響語として使えるなら返す（不可なら None）。
    最低語長（F6(a)）・数字/日付のみ・markdown 残骸を弾く。"""
    t = LINK_RE.sub(lambda m: m.group(1).split("|")[-1].split("#")[0], raw)
    t = t.strip(" \t*_`\"'「」『』（）()-—―~＊")
    # フレーズ分割で先頭に残った助詞（「を追加」等）は内容語まで剥がす
    t = re.sub(r"^[のをにへはがとでも]+", "", t).strip()
    if not t:
        return None
    if NUMERIC_ONLY_RE.fullmatch(t):
        return None
    is_ascii = all(ord(c) < 128 for c in t)
    if (is_ascii and len(t) < ASCII_MIN_LEN) or (not is_ascii and len(t) < NONASCII_MIN_LEN):
        return None
    # 平仮名だけの短い語（「にする」「ため」等）はほぼ機能語＝内容語を含まない
    # ため捨てる（F6(a) の追加規則。実 Vault 走査でタイトル分割の残骸として
    # 混入することを確認した）
    if HIRAGANA_ONLY_RE.fullmatch(t) and len(t) < HIRAGANA_ONLY_MIN_LEN:
        return None
    return t


# フレーズの定型尾部（「〜の決定」「〜を導入する」等の述語ボイラープレート）と
# 末尾助詞。タイトル/太字は「対象語＋述語」の文型になりがちで、全体フレーズの
# ままだと他ノートの記述（対象語のみ・別の述語）に一致しない。尾部を落とした
# 変種を追加して照合力を上げる。これは影響語そのものの辞書ではなく正規化規則
# （語は必ず入力 Decision 由来）＝F2 の辞書ハードコード禁止と両立する。
# 元のフレーズも捨てず併用するため精度は落ちない（変種は F6 のフィルタも通る）。
BOILERPLATE_TAIL_RE = re.compile(r"(?:の決定|する決定|した決定|の方針|する|した|しない)$")
PARTICLE_TAIL_RE = re.compile(r"[のをにへはがとでも]$")


def _tail_variants(term):
    """定型尾部・末尾助詞を段階的に剥がした変種のリストを返す（元の語は含まない）。"""
    out = []
    cur = term
    while True:
        nxt = PARTICLE_TAIL_RE.sub("", BOILERPLATE_TAIL_RE.sub("", cur))
        if nxt == cur:
            break
        cur = nxt
        if cur:
            out.append(cur)
    return out


def extract_terms(fm, body):
    """F2: Decision から影響語候補を導出する（docstring チェック項目1参照）。
    戻り値は重複除去済み・長い語優先で MAX_TERMS 件まで。"""
    candidates = []
    # (a) aliases（書き手が選んだ代表語＝そのまま採用）
    candidates.extend(normalize_aliases(fm.get("aliases")))
    # (b) H1 タイトル（全体＋フレーズ分割の両方。全体は複合語のまま強い照合語になる）
    m = H1_RE.search(body)
    if m:
        candidates.append(m.group(1))
        candidates.extend(PHRASE_SPLIT_RE.split(m.group(1)))
    # (c) 太字スパン（Decision の核心語の書式慣行）をフレーズ分割。
    # インラインコード内の ** は書式例でありスパンではないため先に除去する
    for bold in BOLD_RE.findall(CODE_SPAN_RE.sub("", body)):
        candidates.extend(PHRASE_SPLIT_RE.split(bold))
    terms, seen = [], set()

    def add(raw):
        t = _clean_term(raw)
        if t is None:
            return None
        key = t.casefold()
        if key not in seen:
            seen.add(key)
            terms.append(t)
        return t

    for raw in candidates:
        t = add(raw)
        if t is None:
            continue
        for v in _tail_variants(t):
            add(v)
    terms.sort(key=len, reverse=True)
    return terms[:MAX_TERMS]


def extract_apply_section(body):
    """F4: 「適用」欄を探す。戻り値 (found, section_text)。
    found=False は適用欄なし。見出しレベル（##/###）以下の行を、同レベル以上の
    次の見出しまで収集する。適用欄が複数あれば連結する（表記ゆれ併存対応）。"""
    lines = body.splitlines()
    found = False
    collected = []
    i = 0
    while i < len(lines):
        m = APPLY_HEADING_RE.match(lines[i])
        if not m:
            i += 1
            continue
        found = True
        level = len(m.group(1))
        i += 1
        while i < len(lines):
            hm = re.match(r"^(#{1,6})\s", lines[i])
            if hm and len(hm.group(1)) <= level:
                break
            collected.append(lines[i])
            i += 1
    return found, "\n".join(collected)


def extract_recorded_entries(section):
    """適用欄テキストから記録済みノートの識別子を抽出する。
    戻り値: [(表示名, {正規化識別子の集合}), ...]。識別子は正規化パス
    （拡張子なし・小文字）。フォルダ付き記載（Preferences/foo）に stem(foo) の
    識別子まで与えると、同名 stem の別フォルダノート（Knowledge/foo.md）を
    記録済みと誤分類するため与えない（Codexレビュー指摘・Major。裸の記載は
    norm==stem なのでそのまま stem 一致として機能する）。"""
    entries = {}

    def add(name):
        norm = name.strip().strip("`").strip()
        norm = re.sub(r"\.md$", "", norm)
        if not norm:
            return
        entries.setdefault(norm, set()).add(norm.casefold())

    for raw in LINK_RE.findall(section):
        target = raw.split("|")[0].split("#")[0].strip()
        if target:
            add(target)
    for raw in APPLY_PATH_RE.findall(section):
        add(raw)
    return sorted(entries.items())


def collect_notes():
    """照合対象の現在形ノートを ({rel_path: text}, 読取失敗した rel のリスト) で
    返す（F3 の (c) 除外込み・テキストと rel は NFC 正規化）。読取失敗は警告して
    走査を続けるが、呼び出し側は「走査不完全」として exit 2 を返す契約
    （Codexレビュー指摘・Major: 無言の不完全走査で exit 0/1 を返すと
    「漏れなし」を信用できない）。"""
    notes = {}
    unreadable = []
    for prefix in CHECK_DIRS:
        base = VAULT / prefix.rstrip("/")
        if not base.is_dir():
            continue
        for p in sorted(base.rglob("*.md")):
            rel = nfc(p.relative_to(VAULT).as_posix())
            if rel in CHECK_EXCLUDE:
                continue
            try:
                notes[rel] = nfc(p.read_text(encoding="utf-8"))
            except (OSError, UnicodeDecodeError) as e:
                unreadable.append(rel)
                print(f"warning: 読み取り不可のためスキップ: {rel} ({e})", file=sys.stderr)
    return notes, unreadable


def match_lines(text, terms):
    """ノート本文に影響語がヒットする行を [(行番号, 行, 影響語)] で返す。
    STALE_LINE_OK 行（F3(a)）・コードフェンス内（裁量判断＝docstring 2.(d)）は除外。"""
    hits = []
    in_fence = False
    for lineno, line in enumerate(text.splitlines(), 1):
        if FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        if STALE_LINE_OK.search(line):
            continue
        low = line.casefold()
        for t in terms:
            if t.casefold() in low:
                hits.append((lineno, line.strip(), t))
                break  # 同一行の多重ヒットは1件に丸める（行単位の証跡が目的）
    return hits


def split_generic_terms(terms, notes_effective):
    """F6(b): DF フィルタ。terms を (照合に使う語, 汎用のため除外した語) に分ける。
    DF は effective_text()（フェンス内・stale 行除外後・小文字）でカウントする＝
    照合対象になり得る本文だけで汎用度を測る（Codexレビュー指摘・Major対応）。"""
    n = len(notes_effective)
    threshold = max(GENERIC_DF_MIN, math.ceil(n * GENERIC_DF_RATIO))
    if n >= GENERIC_DF_SATURATION_MIN_NOTES:
        threshold = min(threshold, math.ceil(n * GENERIC_DF_SATURATION))
    specific, generic = [], []
    for t in terms:
        df = sum(1 for text in notes_effective.values() if t.casefold() in text)
        (generic if df >= threshold else specific).append((t, df))
    return specific, generic, threshold


def resolve_decision_path(arg):
    """--decision の引数を実ファイルパスに解決する（絶対/CWD相対/Vault相対を許容）。"""
    p = pathlib.Path(arg).expanduser()
    if p.is_file():
        return p.resolve()
    vp = VAULT / arg
    if vp.is_file():
        return vp.resolve()
    raise FileNotFoundError(f"Decision ノートが見つかりません: {arg}")


def decision_date(path, fm):
    """Decision の日付（frontmatter date 優先・無ければファイル名先頭 YYYY-MM-DD）。"""
    raw = fm.get("date")
    if isinstance(raw, str) and re.fullmatch(r"20\d{2}-\d{2}-\d{2}", raw.strip()):
        try:
            return datetime.date.fromisoformat(raw.strip())
        except ValueError:
            pass
    m = re.match(r"(20\d{2}-\d{2}-\d{2})", path.name)
    if m:
        try:
            return datetime.date.fromisoformat(m.group(1))
        except ValueError:
            pass
    return None


def load_decisions(args):
    """F1: 検査対象 Decision の一覧 [(表示パス, 実パス, fm, body)] を返す。"""
    results = []
    if args.decision:
        p = resolve_decision_path(args.decision)
        text = nfc(p.read_text(encoding="utf-8"))
        fm, body = parse_frontmatter(text)
        results.append((display_path(p), p, fm, body))
        return results
    since = (datetime.date.fromisoformat(args.since) if args.since
             else datetime.date.today() - datetime.timedelta(days=DEFAULT_SINCE_DAYS))
    ddir = VAULT / "Decisions"
    if not ddir.is_dir():
        raise FileNotFoundError(f"Decisions フォルダがありません: {ddir}")
    # サブディレクトリの Decision も対象にする（Codexレビュー指摘・Major:
    # 非再帰 glob だと Decisions/archive/ 等を無言で取りこぼす）
    for p in sorted(ddir.rglob("*.md")):
        if p.name == "README.md":
            continue
        text = nfc(p.read_text(encoding="utf-8"))
        fm, body = parse_frontmatter(text)
        d = decision_date(p, fm)
        if d is not None and d >= since:
            results.append((display_path(p), p.resolve(), fm, body))
    return results


def display_path(p):
    """Vault 配下なら Vault 相対、そうでなければそのまま表示する。"""
    try:
        return p.resolve().relative_to(VAULT.resolve()).as_posix()
    except ValueError:
        return str(p)


def recorded_by_text(rel, section_lower):
    """構造抽出（wiki link・パス・*.md）で拾えなかった適用欄記載への保険として、
    ヒットノートの stem が適用欄本文に現れるかを部分一致で調べるフォールバック
    （Codexレビュー指摘・Major対応: 空白を含む裸のファイル名等）。
    フォルダ付きで書かれた出現（`別フォルダ/stem`）を裸の記載と混同すると
    同名 stem の別フォルダノートまで記録済みになる（同レビューの別 Major と
    同型）ため、直前が「/」の出現は自ノートのフォルダと一致する場合のみ数える。
    stem の前後が英数字・ハイフンに連続する出現は別語の一部とみなし数えない。"""
    norm = re.sub(r"\.md$", "", rel).casefold()
    stem = norm.rsplit("/", 1)[-1]
    folder = norm.rsplit("/", 1)[0] + "/" if "/" in norm else ""
    for m in re.finditer(re.escape(stem), section_lower):
        prefix = section_lower[:m.start()]
        if prefix.endswith("/"):
            if folder and prefix.endswith(folder):
                return True
            continue  # 別フォルダ限定の記載＝自ノートの記録ではない
        if prefix and (prefix[-1].isalnum() or prefix[-1] in "-_"):
            continue  # 別語の一部（例: stem=foo に対する my-foo）
        end = m.end()
        if end < len(section_lower) and (section_lower[end].isalnum() or section_lower[end] in "-_"):
            continue  # 別語の一部（例: stem=foo に対する foobar.md）
        return True
    return False


def check_decision(disp, path, fm, body, notes, notes_effective):
    """1 Decision の波及チェック。レポート用の結果 dict を返す。
    影響語抽出・適用欄検出はフェンス除去後の本文（strip_fences）で行う。"""
    visible = strip_fences(body)
    terms = extract_terms(fm, visible)
    specific, generic, df_threshold = split_generic_terms(terms, notes_effective)
    has_apply, apply_section = extract_apply_section(visible)
    recorded_entries = extract_recorded_entries(apply_section) if has_apply else []
    recorded_ids = set()
    for _name, ids in recorded_entries:
        recorded_ids.update(ids)

    self_resolved = path.resolve()
    term_list = [t for t, _df in specific]
    hits_by_note = {}
    for rel, text in notes.items():
        if (VAULT / rel).resolve() == self_resolved:  # F3(b) 入力 Decision 自身
            continue
        hits = match_lines(text, term_list)
        if hits:
            hits_by_note[rel] = hits

    # 分類（F4）: 適用欄が無い Decision のヒットは「漏れ疑い」に混ぜず
    # unclassified_hits（適用欄なし＝突合不能）として別区分にする（A4）。
    # stem 一致が効くのは裸の記載（norm==stem）のみ・構造抽出できない記載は
    # recorded_by_text() のフォールバックで救う（Codexレビュー指摘・Major×2対応）。
    apply_lower = apply_section.casefold()
    recorded_hits, missing_hits, unclassified_hits = {}, {}, {}
    for rel, hits in hits_by_note.items():
        if not has_apply:
            unclassified_hits[rel] = hits
            continue
        norm = re.sub(r"\.md$", "", rel).casefold()
        stem = norm.rsplit("/", 1)[-1]
        if norm in recorded_ids or stem in recorded_ids or recorded_by_text(rel, apply_lower):
            recorded_hits[rel] = hits
        else:
            missing_hits[rel] = hits

    # 表示用の記録済み一覧（Codexレビュー指摘・Major対応）:
    # - ノートと突合できた記載はノートの完全パスで表示（曖昧な記載名のままにしない）
    # - フォールバック（適用欄本文一致）でしか突合できなかったノートも完全パスで列挙
    # - 空白入り日本語名の末尾断片（正規表現が「メモ 帳.md」から「帳」だけを拾った
    #   もの）は誤解を招く偽エントリなので、フォールバック一致ノートの stem 末尾と
    #   一致する未突合エントリを表示から抑止する
    def _stem(rel):
        return re.sub(r"\.md$", "", rel).casefold().rsplit("/", 1)[-1]

    entry_match = {}
    for name, ids in recorded_entries:
        entry_match[name] = next(
            (rel for rel in recorded_hits
             if re.sub(r"\.md$", "", rel).casefold() in ids or _stem(rel) in ids), None)
    fallback_rels = sorted(set(recorded_hits) - {r for r in entry_match.values() if r})
    recorded_display = []
    for name, _ids in recorded_entries:
        rel = entry_match[name]
        if rel:
            recorded_display.append((rel, len(recorded_hits[rel]), "entry"))
        else:
            is_fragment = any(_stem(rel).endswith(name.casefold()) and _stem(rel) != name.casefold()
                              for rel in fallback_rels)
            if not is_fragment:
                recorded_display.append((name, None, "entry"))
    for rel in fallback_rels:
        recorded_display.append((rel, len(recorded_hits[rel]), "fallback"))

    return {
        "disp": disp,
        "date": decision_date(path, fm),
        "terms": specific,
        "generic_terms": generic,
        "df_threshold": df_threshold,
        "has_apply": has_apply,
        "recorded_entries": recorded_entries,
        "recorded_display": recorded_display,
        "recorded_hits": recorded_hits,
        "missing_hits": missing_hits,
        "unclassified_hits": unclassified_hits,
    }


def build_report(results, n_notes, since_label, unreadable):
    """F5: Markdown レポートを組み立てる。戻り値 (テキスト, 漏れ疑いの総ノート数)。"""
    today = datetime.date.today().isoformat()
    n_missing_notes = sum(len(r["missing_hits"]) for r in results)
    n_no_apply = sum(1 for r in results if not r["has_apply"])
    n_no_terms = sum(1 for r in results if not r["terms"])
    L = []
    L.append(f"# Decision波及チェックレポート {today}")
    L.append("")
    L.append(f"対象: {since_label}／Decision {len(results)} 件・現在形ノート {n_notes} 件"
             f"（{'・'.join(d.rstrip('/') for d in CHECK_DIRS)}）を照合。")
    L.append(f"- **波及漏れの疑い: {n_missing_notes} ノート**"
             f"（Decision {sum(1 for r in results if r['missing_hits'])} 件）")
    L.append(f"- 適用欄に記録済み: {sum(len(r['recorded_entries']) for r in results)} 記載")
    L.append(f"- 適用欄なし Decision: {n_no_apply} 件（漏れ区分とは別扱い＝要目視確認）")
    if n_no_terms:
        # 影響語0件は「漏れなし」ではなく「検証不能」（Codexレビュー指摘・Major:
        # 無言の exit 0 だと検証不能入力を漏れなしと誤認させる）
        L.append(f"- ⚠️ 影響語を抽出できなかった Decision: {n_no_terms} 件"
                 "（検証不能＝漏れなしを意味しない。要目視確認）")
    if unreadable:
        L.append(f"- ⚠️ 読み取れなかったノート: {len(unreadable)} 件（走査不完全＝exit 2）: "
                 + "・".join(f"`{r}`" for r in unreadable))
    for r in results:
        L.append("")
        L.append(f"## `{r['disp']}`" + (f"（{r['date']}）" if r["date"] else ""))
        L.append(f"- 影響語（{len(r['terms'])}件）: "
                 + ("・".join(f"`{t}`" for t, _ in r["terms"]) if r["terms"] else "（抽出できず）"))
        if not r["terms"]:
            L.append("- ⚠️ **影響語抽出不能**（aliases・タイトル・太字から照合語を導出"
                     "できない、または全語が汎用判定＝この Decision は未検証。"
                     "漏れなしを意味しない）")
        if r["generic_terms"]:
            L.append(f"- 汎用のため照合から除外した影響語（DF≥{r['df_threshold']}ノート）: "
                     + "・".join(f"`{t}`(DF={df})" for t, df in r["generic_terms"]))
        if not r["has_apply"]:
            L.append("- ⚠️ **適用欄なし**（「## 適用」見出しが見つからない＝波及チェックの記録が"
                     "存在しない。漏れ疑いとは別区分。影響語ヒットは参考として下に列挙）")
            if r["unclassified_hits"]:
                L.append("- 参考: 影響語ヒットノート（適用欄が無いため記録済み/漏れの突合不能）:")
                for rel, hits in sorted(r["unclassified_hits"].items()):
                    L.append(f"  - `{rel}`（ヒット {len(hits)} 行）")
            else:
                L.append("- 参考: 影響語ヒットノートなし")
            continue
        L.append("### 適用欄に記録済み")
        if not r["recorded_display"]:
            L.append("（適用欄はあるがノートの記載を抽出できなかった）")
        for name, nhits, kind in r["recorded_display"]:
            if nhits is None:
                L.append(f"- `{name}` — 影響語ヒットなし（記録のみ）")
            elif kind == "fallback":
                L.append(f"- `{name}` — 影響語ヒット {nhits} 行（適用欄本文の記載に一致）")
            else:
                L.append(f"- `{name}` — 影響語ヒット {nhits} 行")
        L.append("### 波及漏れの疑い（影響語ヒットあり・適用欄に記録なし）")
        if not r["missing_hits"]:
            L.append("✅ なし")
        for rel, hits in sorted(r["missing_hits"].items()):
            L.append(f"- `{rel}`（ヒット {len(hits)} 行）")
            for lineno, line, term in hits[:MAX_EXCERPT_LINES]:
                L.append(f"  - L{lineno}: {line[:EXCERPT_WIDTH]}（影響語: `{term}`）")
            if len(hits) > MAX_EXCERPT_LINES:
                L.append(f"  - …ほか {len(hits) - MAX_EXCERPT_LINES} 行")
    L.append("")
    return "\n".join(L), n_missing_notes


def main(argv=None):
    ap = argparse.ArgumentParser(description="Decision波及チェック（読み取り専用）")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--decision", help="単一 Decision ノートのパス（絶対/CWD相対/Vault相対）")
    g.add_argument("--since", help="Decisions/ 配下でこの日付以降の date を持つノートを走査 (YYYY-MM-DD)")
    ap.add_argument("--out", help="レポートをこのファイルにも書く（Vault 配下は拒否）")
    args = ap.parse_args(argv)

    try:
        if args.since:
            datetime.date.fromisoformat(args.since)  # 早期の形式検証
        out_path = None
        if args.out:
            out_path = pathlib.Path(args.out).expanduser().resolve()
            try:
                out_path.relative_to(VAULT.resolve())
                print(f"error: --out が Vault 配下を指しています（読み取り専用のため拒否）: {out_path}",
                      file=sys.stderr)
                return 2
            except ValueError:
                pass  # Vault 外 → OK
        if not VAULT.is_dir():
            print(f"error: Vault が見つかりません: {VAULT}", file=sys.stderr)
            return 2
        decisions = load_decisions(args)
        notes, unreadable = collect_notes()
        notes_effective = {rel: effective_text(t) for rel, t in notes.items()}
        results = [check_decision(disp, p, fm, body, notes, notes_effective)
                   for disp, p, fm, body in decisions]
        if args.decision:
            since_label = f"--decision {args.decision}"
        elif args.since:
            since_label = f"--since {args.since}"
        else:
            since_label = f"直近{DEFAULT_SINCE_DAYS}日"
        report, n_missing = build_report(results, len(notes), since_label, unreadable)
    except (FileNotFoundError, ValueError, OSError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 2

    print(report)
    if out_path:
        # 書込失敗（権限なし・出力先がディレクトリ等）も「実行エラー=2」の契約に
        # 含める（Codexレビュー指摘・Major: 例外処理外だと traceback + exit 1 に
        # なり、漏れ疑いあり=1 と区別できない）。stdout へのレポートは出力済み。
        try:
            out_path.parent.mkdir(parents=True, exist_ok=True)
            out_path.write_text(report, encoding="utf-8")
        except OSError as e:
            print(f"error: --out へ書き込めません: {e}", file=sys.stderr)
            return 2
        print(f"（レポートを保存: {out_path}）", file=sys.stderr)
    if unreadable:
        # 走査不完全＝結果を信用できないため実行エラー扱い（レポートは出力済み）
        print(f"error: {len(unreadable)} 件のノートを読み取れず走査が不完全です", file=sys.stderr)
        return 2
    return 1 if n_missing else 0


if __name__ == "__main__":
    sys.exit(main())
