#!/usr/bin/env python3
"""外部脳ハイブリッド検索・柱①の想起フック補助（claude/hooks/vault-recall.shからsubprocess
で呼ばれる。8.2ラウンド「統一リファクタリング」で追加）。

役割: 旧claude/hooks/vault-recall.sh（8.0/8.1ラウンド版）にbashでインライン実装されていた
「キーワード全体一致＋トークン部分一致の二段構え」照合ロジックを、挙動を一切変えずに
Pythonへ移植したもの。8.1ラウンドで追加されたvector_recall_helper.py（Ollama embed→
cosine類似のベクトル想起）は2026-07-16簡素化
（[[Decisions/2026-07-16-remove-vector-search-embedding-infra]]）で撤去済み。以後
vault-recall.shは本helper単独をサブプロセス起動して表示するだけの薄い殻になった
（移植元の全文は `git log -- claude/hooks/vault-recall-legacy.sh` で参照可能。
vault-recall-legacy.sh自体もこの簡素化で削除した）。

移植方針: ロジックはlegacy版（vault-recall-legacy.sh）のコメントに書かれた設計判断
（全体一致優先・トークン部分一致はratio matched*3>=total・汎用トークン除外・
活用形フォールバック・カタカナ境界分割・部分一致は1ノート最大1回加点、等）をすべて
そのまま踏襲する。各関数の対応関係はlegacyスクリプト内の同名関数コメントを参照
（`git log -p -- claude/hooks/vault-recall-legacy.sh` で全文を確認できる）。ここでは
「なぜbashからPythonへ移すのか」ではなく「移植時にbash実装のどの癖を意図的に
模倣したか」だけを記す。

走査順（tie-break）の再現について: 同スコアのノートはbashのグロブ展開順（ファイル走査順）
で先着優先になる（O(n²)選択ロジックの`>`比較の副作用）。bashのファイル名グロブは現在の
ロケール(LC_ALL)のstrcoll比較でソートされるため、本helperも`locale.strxfrm`で同じ
ロケール（vault-recall.sh側で必ずUTF-8ロケールがexportされた状態でこのプロセスが起動
される）に基づいてファイル名をソートする。ロケール初期化に失敗した環境（テスト実行環境
でen_US.UTF-8が未インストール等）ではPythonの素の文字列比較へ自動フォールバックする
（実機のVaultノート命名規則は小文字kebab-caseがほぼ全てのため、この場合でも実害は
ごく小さいと判断・リーダーへの申告事項）。

入出力契約（vector_recall_helper.pyと同じ流儀）:
  クエリは --query または stdin（省略時）。成功時のみ stdout へJSON1行:
    {"candidates": [{"relpath": "...", "score": N, "keys": [{"key": "...", "partial": bool}, ...]}, ...],
     "unreadable_count": N}
  スコア降順・同点は走査順（この順序で既にソート済み。vault-recall.sh側は先頭5件を
  切り出すだけでよい＝旧bashのO(n²)選択は不要になった）。
  失敗はstderrへメッセージ・非0終了。stdoutには何も書かない（bash側の単一fail-open
  集約ポイントへ握りつぶす契約はvector側と同一）。読み取り専用・Python標準ライブラリのみ。

時間予算管理: キーワード照合はローカルI/Oのみ（HTTP通信なし）でOllama呼び出しのような
不確定な待ちは無いが、vault-recall.sh側の設計（vector_recall_helper.pyと対になる
「bashのハードkillポーリング＋helper自身のmonotonic()予算」の二重防御）に揃えるため、
同じパターンの自己予算チェックを実装する（VAULT_RECALL_KEYWORD_BUDGET_MS・既定1000ms・
vault-recall.sh側で検証してから引数として渡される）。通常はノート走査25件ごとの
チェックが発火する前に処理が終わる想定（130ノート規模で数十ms程度）。
"""
import argparse
import json
import locale
import os
import pathlib
import re
import sys
import time

DEFAULT_VAULT = pathlib.Path.home() / "Data" / "obsidian"
DEFAULT_BUDGET_MS = 1000.0

# fail-open理由をbash側の単一集約ログへ渡すための終了コード（vector_recall_helper.pyの
# EXIT_*と同じ考え方。区別は主にstderrメッセージで行い、bash側の分岐自体は増やさない）。
EXIT_BAD_QUERY = 1
EXIT_VAULT_NOT_FOUND = 2
EXIT_BUDGET_EXCEEDED = 3

# 想起支援の対象フォルダ（旧claude/hooks/vault-recall.shのSCAN_DIRSと同じ並び。
# 2026-07-11決定でPersonal追加＝5フォルダ）。
SCAN_DIRS = ("Knowledge", "Preferences", "Decisions", "Projects", "Personal")

# 起動必読ファイル（bootstrap-vault.shと同じ6件）。vault-recall.sh側のEXCLUDE_RELPATHSと
# 完全一致させる必要がある（重複管理・GENERIC_TOKENSと同様に「完全な同期を機械的には
# 強制しないが更新時は両方見直す」運用。vault-recall.sh側コメント参照）。
EXCLUDE_RELPATHS = (
    "Knowledge/mistakes.md",
    "Preferences/absolute-rules.md",
    "Preferences/profile.md",
    "Preferences/coding-delegation.md",
    "Preferences/vault-operation.md",
    "Personal/profile-personal.md",
)

# 一致キー1件あたりのスコア（legacy版のKEY_SCORE_FULL/KEY_SCORE_PARTIALと同じ値・同じ意味）。
KEY_SCORE_FULL = 2
KEY_SCORE_PARTIAL = 1

# キーが「ASCII/非ASCII境界では一切分割できない、1続きの非ASCII文字列」の場合に限り、
# カタカナ連続の境界でも分割を試みる際の区切り文字集合（legacyのTOKEN_SEP_CHARSと同一）。
TOKEN_SEP_CHARS = " \t\r\n-_/.,:;()[]{}\"'!?~=+*&%#@|<>「」『』【】、。・〜～"

KATAKANA_CHARS = ("ァアィイゥウェエォオカガキギクグケゲコゴサザシジスズセゼソゾタダチヂッツヅテデトドナニヌネノハバパヒビピフブプヘベペホボポ"
                   "マミムメモャヤュユョヨラリルレロヮワヲンヴーヵヶ")

# 汎用すぎるトークン（legacyのGENERIC_TOKENS_ASCII/NONASCIIと同一。更新時はvault-recall.sh
# 側の説明コメント・generic-aliases.txtと合わせて見直すことが望ましい）。
GENERIC_TOKENS_ASCII = {"ai", "claude", "codex", "obsidian", "vault", "mcp"}
GENERIC_TOKENS_NONASCII = {
    "ツール", "ルール", "設定", "配信", "メモ", "作業", "運用", "テスト",
    "レビュー", "ワークフロー", "エージェント", "ワーカー", "委任", "フック", "スクリプト", "外部脳",
}

# 活用語尾はひらがな（送り仮名）で書かれる、という日本語表記の性質を利用したフォールバック
# （legacyのHIRAGANA_CHARSと同一。長音符「ー」は含めない＝理由はlegacy側コメント参照）。
HIRAGANA_CHARS = ("あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをん"
                   "がぎぐげござじずぜぞだぢづでどばびぶべぼぱぴぷぺぽゃゅょっ")

_BLOCK_ITEM_RE = re.compile(r"^\s+-\s*(.*)$")
_INLINE_ALIASES_RE = re.compile(r"^aliases:\s*\[(.*)\]\s*$")
_BLOCK_START_RE = re.compile(r"^aliases:\s*$")
_KATAKANA_BOUNDARY_RE = re.compile(r"[ァ-ヶー]+|[^ァ-ヶー]+")

# ノート走査中の予算チェック間隔（vector_recall_helper.pyのCHECK_INTERVALと同じ考え方）。
CHECK_INTERVAL = 25


class BudgetExceeded(Exception):
    """自己予算(monotonic)を使い切った際にscan_candidates()から送出する内部シグナル。"""


def _list_md_names(dir_path, collate_key):
    """dir_path直下の*.mdファイル名（隠しファイル除く）を、bashのファイル名グロブと
    同じロケール順でソートして返す。戻り値は (names, enumeration_failed)。

    フォルダが存在しない（5フォルダ全部が常に揃っている前提ではない・SCAN_DIRSの
    どれかを未作成のVaultは正常系）場合は ([], False) を返す。フォルダは存在するが
    列挙自体に失敗した（権限不足・I/Oエラー等）場合は ([], True) を返す。

    Codexレビュー指摘・Major対応: 旧実装は `dir_path.is_dir()` でフォルダ存在を確認した
    上で `dir_path.glob("*.md")` を `try/except OSError` で囲っていたが、実測確認の結果
    pathlib.Path.glob() は列挙中の PermissionError 等の OSError を内部で握りつぶし、
    空のイテレータを返す（実装がそう作られている）。そのためこの try/except は実質的に
    発火しないデッドコードで、5フォルダ全滅（例: chmod 000）でも「候補0件の正常な
    空振り」と区別できず、unreadable_count にも計上されず可観測性が無かった。
    os.scandir() は同じ状況で確実に OSError を送出するため、これを使って明示的に検知する。
    """
    try:
        with os.scandir(dir_path) as it:
            names = [e.name for e in it if e.name.endswith(".md") and not e.name.startswith(".")]
    except FileNotFoundError:
        return [], False  # フォルダが存在しない（正常系）
    except NotADirectoryError:
        return [], False  # 同名の非ディレクトリが存在する（従来のis_dir()判定と同じ扱い・探索対象外）
    except OSError:
        return [], True  # 権限不足等でフォルダ自体を列挙できない（異常系）
    return sorted(names, key=collate_key), False


def parse_args(argv=None):
    ap = argparse.ArgumentParser(description="想起フック用キーワード照合補助（全体一致＋トークン部分一致）。")
    ap.add_argument("--query", default=None, help="クエリ文字列。省略時はstdinから読む")
    ap.add_argument("--vault", default=str(DEFAULT_VAULT), help=f"Vaultのルート（既定: {DEFAULT_VAULT}）")
    ap.add_argument("--budget-ms", type=float, default=DEFAULT_BUDGET_MS, help="このプロセス自身の予算(ms)")
    return ap.parse_args(argv)


def read_query(args):
    if args.query is not None:
        return args.query
    try:
        # bashのhere-string(`<<< "$RAW_PROMPT"`)は末尾に改行を1つ付加するため、それだけを
        # 取り除く（vector_recall_helper.pyのread_query()と同じ考え方）。
        return sys.stdin.read().rstrip("\n")
    except OSError:
        return ""


def _locale_sort_key():
    """呼び出し元(vault-recall.sh)が事前にexportしたLC_ALLを使い、bashのファイル名グロブ
    展開と同じstrcoll順でソートするためのキー関数を返す。ロケール初期化に失敗した場合は
    Pythonの素の文字列比較(コードポイント順)へフォールバックする（ヘッダコメント参照）。
    """
    try:
        locale.setlocale(locale.LC_COLLATE, "")
        return locale.strxfrm
    except locale.Error:
        return lambda s: s


def strip_quotes(s):
    """先頭・末尾の引用符を最大1文字ずつ剥がす（legacyのval/emit_inline_alias_partにおける
    `"${val%\\"}"`→`"${val#\\"}"`→`"${val%\\'}"`→`"${val#\\'}"`の順の副作用をそのまま再現。
    対になっていない引用符でも構わず剥がす、というlegacyの緩さも維持する）。
    """
    if s.endswith('"'):
        s = s[:-1]
    if s.startswith('"'):
        s = s[1:]
    if s.endswith("'"):
        s = s[:-1]
    if s.startswith("'"):
        s = s[1:]
    return s


def split_inline_aliases(inner):
    """インライン配列(例: `a, "b, c", d`)の中身を、クォート内のカンマでは分割せずに
    1文字ずつ走査して分割する（legacyのsplit_inline_aliases/emit_inline_alias_partの移植）。
    """
    keys = []
    cur = ""
    quote = ""
    i = 0
    n = len(inner)
    while i < n:
        ch = inner[i]
        if quote:
            if ch == "\\" and i + 1 < n:
                cur += ch + inner[i + 1]
                i += 2
                continue
            cur += ch
            if ch == quote:
                quote = ""
            i += 1
            continue
        if ch in ('"', "'"):
            quote = ch
            cur += ch
        elif ch == ",":
            _emit_inline_part(cur, keys)
            cur = ""
        else:
            cur += ch
        i += 1
    _emit_inline_part(cur, keys)
    return keys


def _emit_inline_part(part, keys):
    part = part.strip()
    part = strip_quotes(part)
    if part:
        keys.append(part)


def collect_keys_for_file(vault_root, relpath):
    """1ファイル分の照合キー(ファイル名由来 + frontmatterのaliases)を集める
    （legacyのcollect_keys_for_file()の移植）。戻り値は (keys, unreadable)。
    """
    keys = []
    name = relpath.rsplit("/", 1)[-1]
    stem = name[:-3] if name.endswith(".md") else name
    keys.append(stem)
    nohy = stem.replace("-", "")
    if nohy != stem:
        keys.append(nohy)

    path = vault_root / relpath
    if not path.is_file():
        return keys, False
    if not os.access(path, os.R_OK):
        return keys, True

    try:
        # newline=""でuniversal newline変換を無効化し、改行は"\n"だけで分割する
        # （legacyのbash `read -r`はCRLFファイルの各行末に"\r"を残したまま扱う。
        # Python標準のtext.splitlines()やopen()の既定モードは"\r\n"を"\n"へ正規化
        # してしまい、CRLFノートで"---"判定がlegacyと食い違う＝Codexレビュー指摘・
        # Major対応。この対策により、CRLFノートの1行目"---\r"はlegacyと同じく
        # "---"と一致せずfrontmatter解析をskipする（挙動完全一致を優先）。
        with path.open("r", encoding="utf-8", errors="replace", newline="") as f:
            text = f.read()
    except OSError:
        return keys, True

    lines = text.split("\n")
    in_fm = False
    mode = 0  # 0=通常, 1=aliasesブロックリストの項目待ち
    for idx, line in enumerate(lines):
        if idx == 0:
            if line == "---":
                in_fm = True
            continue
        if not in_fm:
            break  # frontmatterが無いノート
        if line == "---":
            break  # frontmatter終端

        if mode == 1:
            m = _BLOCK_ITEM_RE.match(line)
            if m:
                val = strip_quotes(m.group(1))
                if val:
                    keys.append(val)
                continue
            mode = 0  # ブロックリスト終了。このlineは以下のチェックへフォールスルーする

        m = _INLINE_ALIASES_RE.match(line)
        if m:
            keys.extend(split_inline_aliases(m.group(1)))
            continue

        if _BLOCK_START_RE.match(line):
            mode = 1
            continue

    return keys, False


def has_mixed_katakana(s):
    """キーに片仮名とそれ以外の両方が混ざっている場合だけTrue（legacyのhas_mixed_katakana）。"""
    has_kata = False
    has_other = False
    for ch in s:
        if ch in KATAKANA_CHARS:
            has_kata = True
        else:
            has_other = True
        if has_kata and has_other:
            return True
    return False


def tokenize_katakana_boundary(key):
    """カタカナ連続とそれ以外の境界でkeyを分割する（legacyのtokenize_katakana_boundary。
    bashは外部grepをforkしていたが、Pythonでは標準ライブラリのreで完結する）。
    """
    parts = [p for p in _KATAKANA_BOUNDARY_RE.findall(key) if p]
    return parts or [key]


def tokenize_key(key):
    """キー文字列をトークン配列へ分解する（legacyのtokenize_key()の移植）。
    区切り文字・ASCII/非ASCII境界を暗黙の境界として分割し、1続きの非ASCII文字列だけは
    最後の手段としてカタカナ境界分割も試す。純数字トークン・最小長未満のトークンは除く。
    """
    raw = []
    cur = ""
    cur_class = None
    for ch in key:
        if not ch.isascii():
            cls = "N"
        elif ch in TOKEN_SEP_CHARS:
            cls = "S"
        else:
            cls = "A"

        if cls == "S":
            if cur:
                raw.append(cur)
            cur = ""
            cur_class = None
        elif cls != cur_class:
            if cur:
                raw.append(cur)
            cur = ch
            cur_class = cls
        else:
            cur += ch
    if cur:
        raw.append(cur)

    if len(raw) == 1:
        only = raw[0]
        if not only.isascii() and len(only) >= 4 and has_mixed_katakana(only):
            boundary = tokenize_katakana_boundary(only)
            if len(boundary) >= 2:
                raw = boundary

    tokens = []
    for t in raw:
        if t.isdigit():
            continue
        tlen = len(t)
        if t.isascii():
            if tlen >= 3:
                tokens.append(t)
        else:
            if tlen >= 2:
                tokens.append(t)
    return tokens


def is_generic_token(tok):
    """legacyのis_generic_token()の移植。ASCIIは大小文字無視、非ASCIIは完全一致。"""
    if tok.isascii():
        return tok.lower() in GENERIC_TOKENS_ASCII
    return tok in GENERIC_TOKENS_NONASCII


def is_hiragana_char(ch):
    return ch in HIRAGANA_CHARS


def token_matches(tok, prompt):
    """1トークンがプロンプト中に見つかるか（legacyのtoken_matches()の移植）。
    非ASCIIトークン(3文字以上)は末尾1文字を落とした活用形フォールバックも試す
    （末尾がひらがなの場合のみ）。
    """
    if not tok.isascii():
        if tok in prompt:
            return True
        tlen = len(tok)
        if tlen >= 3 and is_hiragana_char(tok[-1]):
            if tok[:-1] in prompt:
                return True
        return False
    return tok.lower() in prompt.lower()


def full_match(key, prompt):
    """キー全体がプロンプトに連続部分文字列として含まれるか（legacyの全体一致判定）。
    ASCIIキーは3文字以上・大小文字無視、非ASCIIキーは2文字以上・素の部分文字列一致。
    """
    if key.isascii():
        return len(key) >= 3 and key.lower() in prompt.lower()
    return len(key) >= 2 and key in prompt


def score_note(keys, prompt):
    """1ノート分の照合キー配列を採点する（legacyの「各ファイルについてプロンプトとの
    照合を行う」forループ本体の移植）。戻り値は (note_score, matched_keys)。
    matched_keysは [(key, is_partial), ...] で、実際にヒットしたキーだけを出現順に含む。

    重複キーの扱い: legacyはKEY_SEP前後を挟んだ完全一致部分文字列検索で「既にヒット済みの
    同一キー文字列」を弾いていた（prefix関係にある別キーを誤って重複扱いしないための
    Codexレビュー対応。全文は`git log -p -- claude/hooks/vault-recall-legacy.sh`参照）。
    Pythonでは集合(set)による完全一致の
    メンバーシップ判定がそのまま同じ振る舞いになる（prefix問題がそもそも起きない、より
    単純で同値な実装）。
    """
    seen = set()
    matched = []
    full_score = 0
    has_partial = False

    for key in keys:
        if not key or key in seen:
            continue

        key_score = 0
        is_partial = False
        if full_match(key, prompt):
            key_score = KEY_SCORE_FULL
        else:
            # 全体一致しなかったキーだけ追加コストをかけてトークン部分一致を試す。
            toks = tokenize_key(key)
            tok_total = len(toks)
            if tok_total >= 2:
                tok_matched = sum(1 for t in toks if not is_generic_token(t) and token_matches(t, prompt))
                if tok_matched >= 1 and tok_matched * 3 >= tok_total:
                    key_score = KEY_SCORE_PARTIAL
                    is_partial = True
            elif tok_total == 1:
                # 単一トークンキーでも活用形フォールバックだけは試す（一致率の閾値判定は
                # 不要＝フォールバック自体が成立した場合だけ部分一致として扱う）。
                t = toks[0]
                if not is_generic_token(t) and token_matches(t, prompt):
                    key_score = KEY_SCORE_PARTIAL
                    is_partial = True

        if key_score == 0:
            continue

        seen.add(key)
        matched.append((key, is_partial))
        if is_partial:
            # 1ノートにつき部分一致の加点は最大1回分だけ（legacyのnote_has_partialと同じ）。
            has_partial = True
        else:
            full_score += key_score

    note_score = full_score + (KEY_SCORE_PARTIAL if has_partial else 0)
    return note_score, matched


def scan_candidates(vault_root, prompt, deadline):
    """SCAN_DIRS配下の*.mdを走査し、スコア>0のノートを候補として集める。
    スコア降順・同点は走査順（helperの出力契約）でソート済みのリストを返す。
    予算(deadline)を使い切った場合はBudgetExceededを送出する。
    """
    if time.monotonic() >= deadline:
        raise BudgetExceeded()

    collate_key = _locale_sort_key()
    candidates = []
    unreadable_count = 0
    processed = 0

    for d in SCAN_DIRS:
        dir_path = vault_root / d
        # bashのglob("*.md")はdotglob無効時ドットファイル(隠しファイル)を対象外にする
        # （POSIX glob規約）が、pathlib.Path.glob("*.md")は".hidden.md"にも一致して
        # しまう＝legacyとの候補集合の食い違い(Codexレビュー指摘・Major)。_list_md_names()
        # は明示的に先頭"."始まりの名前を除外して同じ挙動にする。
        names, enumeration_failed = _list_md_names(dir_path, collate_key)
        if enumeration_failed:
            # 権限不足等でフォルダ自体を列挙できなかった（正常な「候補0件」と区別する
            # ため unreadable_count へ計上する・Codexレビュー指摘・Major対応。個々のノート
            # 読取失敗と同じ集計フィールドへ寄せる＝JSON出力契約(スキーマ)を変えずに
            # 可観測にする）。
            unreadable_count += 1
            continue

        for name in names:
            processed += 1
            if processed % CHECK_INTERVAL == 0 and time.monotonic() >= deadline:
                raise BudgetExceeded()

            if name == "README.md":
                continue
            relpath = f"{d}/{name}"
            if relpath in EXCLUDE_RELPATHS:
                continue

            keys, unreadable = collect_keys_for_file(vault_root, relpath)
            if unreadable:
                unreadable_count += 1

            note_score, matched = score_note(keys, prompt)
            if note_score > 0:
                candidates.append({
                    "relpath": relpath,
                    "score": note_score,
                    "keys": [{"key": k, "partial": p} for k, p in matched],
                })

    # Pythonのsort()は安定ソート＝スコアの同点は元の走査順（挿入順）のまま保たれる。
    candidates.sort(key=lambda c: -c["score"])
    return candidates, unreadable_count


def main(argv=None):
    t0 = time.monotonic()
    args = parse_args(argv)
    deadline = t0 + max(args.budget_ms, 0.0) / 1000.0

    query = read_query(args)
    if not query or not query.strip():
        print("クエリが空です", file=sys.stderr)
        return EXIT_BAD_QUERY

    vault_root = pathlib.Path(args.vault)
    if not vault_root.is_dir():
        print(f"Vaultディレクトリが見つかりません: {vault_root}", file=sys.stderr)
        return EXIT_VAULT_NOT_FOUND

    try:
        candidates, unreadable_count = scan_candidates(vault_root, query, deadline)
    except BudgetExceeded:
        print("予算超過のため照合を打ち切りました", file=sys.stderr)
        return EXIT_BUDGET_EXCEEDED

    out = {"candidates": candidates, "unreadable_count": unreadable_count}
    print(json.dumps(out, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
