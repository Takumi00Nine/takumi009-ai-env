#!/usr/bin/env python3
"""Knowledge自律整理・柱②の「検出」専用CLI（週次・LLM不使用）。

責務（本スクリプトが行うのはここまで。マージの実行はscripts/vault-agents/
maintenance_apply.py・PR2の役目で、本スクリプトは一切書込を行わない・呼び出しもしない）:
  1. Vault内5フォルダ（SCAN_DIRS＝Knowledge/Preferences/Decisions/Projects/Personal）
     直下1階層（サブディレクトリは対象外＝撤去済みembedding_index.list_vault_notes()
     と同じ走査契約）の全ノートペアについてキーワード系類似度を計算する（2026-07-16簡素化・
     [[Decisions/2026-07-16-remove-vector-search-embedding-infra]]でベクトル検索
     基盤(embedding_index.py)を撤去したため、note_similarity()による決定的な
     重み付きJaccard類似度へ作り替えた＝設計書§3.3）。
       note_similarity = 0.4*alias_jaccard + 0.3*title_token_jaccard
                        + 0.2*tag_jaccard + 0.1*outbound_link_jaccard
     重みは設計書で確定済み（0.4/0.3/0.2/0.1）。閾値はVAULT_MERGE_SIM_THRESHOLD
     （実装時較正・後述コメント参照）。
  2. FR10a①②のみを機械評価する（③の矛盾/否定表現差/日付差/固有名詞差/コードブロック差は
     Codexによる敵対的レビューの役目＝ここでは評価しない）:
       ① 類似度が閾値（VAULT_MERGE_SIM_THRESHOLD）以上
       ② 相互最近傍（mutual top-1）。判定が僅差でタイになった場合は
          「候補にしない」（FR10a「判定が割れた場合のデフォルトはマージしない」）。
     マージ対象はKnowledge/内・同フォルダのペアのみ（FR10）。それ以外
     （フォルダ横断ペア、および同フォルダだがKnowledge以外のペア）は
     マージ候補にはせず、FR9c方式の検出ログ（初出日・最終検出日・連続検出回数・
     最大類似度）としてのみ集約する。
  3. 候補ごとに relpath ペアから決定的に導出した安定ID・状態
     （pending/merged/skipped/blocked/retry）を state.json（scripts/vault-agents/
     merge_state.py・2026-07-16簡素化で抽出）に保持する。blocked/retryは次回実行
     でも無条件で引き継ぐ（FR9b「1件の失敗で再試行対象が消える事故を防ぐ」）。
     merged/skippedは終端状態として次回以降追跡しない。
  4. レポートmd（frontmatterにprocessedを付与しない）。

閾値較正メモ（2026-07-16実装時較正・設計書§7-3「暫定閾値0.5＝要再較正」への対応）:
  過去の実際の検出実績（~/.claude/logs/knowledge-merge-candidates/2026-07-12.md・
  埋め込みベースの旧検出器による本物の検出結果＋人間の実際の処理結果）にある
  Knowledgeフォルダ内5ペアについて、本ファイルの新しいnote_similarity()で
  再計算したスコアを実測した:
    - merged（実際に統合された）: streaming-ai-work-best-practices/mvp = 0.364,
      claude-codex-orchestration-best-practice/claude-vs-codex-strengths = 0.271
    - skipped（統合しないと判断された）: claude-codex-parallel-adoption-story/
      reference-video = 0.257, note-com-automation/note-post-mcp = 0.127,
      mistakes-archive/mistakes = 0.309
  重み0.4/0.3/0.2/0.1の下では aliases（重み最大0.4）の一致がこの実測5件全てで
  0（aliasesはノートごとに書き手が独自に付ける傾向が強く、真に重複するノート同士
  でも一致しにくいことが実測で判明）。5件だけでは merged/skipped を完全分離する
  閾値は存在しない（0.271 < 0.309 mistakes-archive/mistakesは意図的分割の
  非マージ対象）が、意図的に分離されているmistakes-archive/mistakesペア(0.309)を
  除外しつつ最も強いmerged実績(0.364)を捉える0.35を暫定閾値として採用する
  （もう一方のmerged実績0.271は捕捉できない＝偽陰性を許容。cleanup決定#8
  「検出精度の低下は受容（マージは元々低頻度運用）」の範囲内の判断）。
  n=5の小標本に基づく較正であり、運用実績が積み上がった段階での再較正を推奨する
  （実装時タスクとしての較正はここまで＝設計書§7確認事項3）。この5件は全て
  「旧embedding検出器が候補として選んだペア」であり、新しいキーワード類似度が
  独自に高スコアを付ける別のペア群（特にaliasesだけが偶然一致するケース）の
  偽陽性率は本較正では評価できていない（Codexレビュー指摘Minor・limitation
  として明記）。運用開始後に生成される実際のレポート（Knowledge全ペアの
  スコア分布）を数週間分観察してから0.30〜0.45帯を再点検するのが望ましい。

fail-open: Vaultが読めない等の異常時は何も生成せずログのみで正常終了する
（exit 0。柱①側と異なりKnowledgeマージ検出は必須機能ではなく、次回実行で
自然に再試行されるため）。

週次の7日間隔ガード（MIN_INTERVAL_DAYS・--force・--min-interval-days）は
2026-07-16に撤去した（tester独立検証F3で実測: ガードのskipメッセージが
`--json`指定時も標準出力へ平文で出力されており、maintenance.sh Phase1④が
毎回有効なJSONを受け取れる契約に違反していた＝実害として、maintenance.sh
経由の週次実行で同日中に手動再実行や再試行が起きた場合にJSON解析が壊れる
経路があった。リーダー裁定「間隔ガードは完全撤去。vault_inventory.pyと同じ
扱い＝ランナーの週次周期が唯一のケイデンス制御」により、fragments_log.py・
vault_inventory.pyと同様にガード自体を撤去した。`--json`の契約:
正常完了時は標準出力へ有効なJSON1行を返す。Vault不在・state.json排他ロック
競合・state.json破損などのskip/error系は標準出力を空にしexit 0のまま終わり
（診断メッセージはstderrへ出す）、標準出力に平文が混入することは無い
＝2026-07-16 Codexレビュー指摘Minor対応。空文字列そのものは有効なJSONでは
ないため「常に有効なJSONを返す」とは表現しない。呼び出し側
（maintenance_apply.pyの_load_json_file()）は空/未解析の標準出力を
「読込失敗」として扱い、静穏週（候補0件の正常なJSON）とは区別する）。
"""
import argparse
import datetime
import hashlib
import json
import math
import os
import pathlib
import re
import stat
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
# frontmatter解析・wikilink正規表現・aliases正規化はvault_lib.pyから再利用する
# （2026-07-16簡素化・cleanup決定#10）。state.json操作・排他ロックはmerge_state.py
# へ抽出済み（設計書§2.4・検出器とmaintenance_apply.pyのMERGE適用が共用する）。
import merge_state
import vault_lib  # noqa: E402

DEFAULT_VAULT = pathlib.Path.home() / "Data" / "obsidian"
DEFAULT_OUT_DIR = pathlib.Path(os.environ.get(
    "KNOWLEDGE_MERGE_CANDIDATES_LOG_DIR",
    str(pathlib.Path.home() / ".claude" / "logs" / "knowledge-merge-candidates")))

# 想起フック（keyword_recall_helper.py）・棚卸し（vault_inventory.py）と同じ
# 5フォルダを類似検出の走査対象にする（2026-07-11のPersonal想起対象化に追随）。
SCAN_DIRS = ("Knowledge", "Preferences", "Decisions", "Projects", "Personal")

# FR9c「連続検出回数」の週次cadence許容ギャップ。週次(7日)運用で1回分の欠落
# （LaunchAgent一時停止・祝日等）までは連続とみなし、それを超える経過日数は
# ジョブの長期停止からの再開とみなしてストリークをリセットする。
GAP_RESET_DAYS = 14

# マージ対象はKnowledge/内・同フォルダのみ（FR10改訂）。
MERGE_ELIGIBLE_FOLDERS = ("Knowledge",)

# 設計書§2.2「フラグメント本文全文・マージ候補2ノートの全文＋各SHA-256を含める」
# 「サイズ上限超過（fragment 2,000字/マージ候補8,000字）の候補は素材から除外し
# non_actionable: truncated として記録、その回のPROMOTE/MERGE対象にしない」。
# fragments_log.py（MAX_FRAGMENT_CHARS）と同じ方針をマージ候補にも適用する
# （両ノート本文の合計文字数がこれを超えたら、切り詰めて渡すのではなく今回は
# 除外し次回へ持ち越す＝「切り詰めて渡すfail-open案は撤回」の裁定どおり）。
MAX_MERGE_CANDIDATE_CHARS = 8000


def _float_env(name, default, lo=0.0, hi=1.0):
    """環境変数を有限かつ[lo, hi]範囲内のfloatとして読む。未設定・空・非数値・
    NaN/inf・範囲外はdefaultへfail-openで戻す。重み付きJaccardの理論範囲[0, 1]を
    既定の許容範囲とする（旧cosine類似度時代の[-1, 1]から変更＝2026-07-16簡素化）。
    """
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return default
    try:
        value = float(raw.strip())
    except ValueError:
        return default
    if math.isnan(value) or math.isinf(value) or not (lo <= value <= hi):
        return default
    return value


# 類似度閾値（FR10a①・FR7相当のパラメータ化）。2026-07-16実装時較正で0.35に決定
# （較正根拠は本ファイル冒頭のdocstring参照）。
DEFAULT_SIM_THRESHOLD = _float_env("VAULT_MERGE_SIM_THRESHOLD", 0.35)

# 相互最近傍の同点判定用の許容誤差。重み付きJaccardは有理数の除算・乗算の
# 積み重ねで浮動小数点丸め誤差が生じ得るため、旧cosine類似度時代と同じ考え方で
# 「ごく僅かな差は区別できない」とみなす閾値を設ける。
TIE_EPSILON = 1e-6

STATE_SCHEMA_VERSION = merge_state.STATE_SCHEMA_VERSION
TERMINAL_STATUSES = merge_state.TERMINAL_STATUSES
DEFAULT_LOCK_FILE = merge_state.DEFAULT_LOCK_FILE


# --- 補助関数 ------------------------------------------------------------------

def folder_of(relpath):
    """relpath（例: "Knowledge/foo.md"）の先頭フォルダ名を返す。"""
    return relpath.split("/", 1)[0]


def is_active_note(vault_root, relpath):
    """候補生成の対象として扱ってよいノートかを返す。以下のいずれかに該当すれば
    False（対象外）:
      - 実ファイルが存在しない
      - symlink（Vault外ファイルへの参照可能性を排除する多層防御）
      - 既に非破壊マージ済み（frontmatter `deprecated: true`）。原ノート2件は
        削除されず`deprecated: true`+`superseded_by:`付きスタブとして残る（FR12）。
        スタブ化済みの2件が今後も類似度条件を満たし続け、際限なく同じペアを
        「レビュー待ち候補」として再生成し続けるのを防ぐ。

    読み取り失敗（権限等）もFalse（対象外）に倒す。本スクリプトは検出のみで
    Vault書込を一切行わないため、除外側に倒しても実害は「本来出てもよい候補が
    1件出ない」程度に留まる。
    """
    p = pathlib.Path(vault_root) / relpath
    if p.is_symlink():
        return False
    if not p.is_file():
        return False
    try:
        text = p.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return False
    fm, _ = vault_lib.parse_frontmatter(text)
    val = fm.get("deprecated")
    if isinstance(val, str) and val.strip().lower() == "true":
        return False
    return True


def stable_pair_id(relpath_a, relpath_b):
    """両ノートrelpathの正規化ペア（アルファベット順にソート）から決定的に
    候補IDを導出する。sha256の全桁(64 hex文字)をそのままIDに使う（衝突耐性優先）。
    """
    a, b = sorted([relpath_a, relpath_b])
    digest = hashlib.sha256(f"{a}\n{b}".encode("utf-8")).hexdigest()
    return f"cand-{digest}"


# --- キーワード系類似度（2026-07-16簡素化・設計書§3.3） ------------------------

_TITLE_TOKEN_RE = re.compile(r"[-_]+")


def title_tokens(relpath):
    """ファイル名（拡張子・フォルダ除く）をハイフン/アンダースコアで分割した
    小文字トークン集合を返す（例: "claude-codex-strengths.md" ->
    {"claude","codex","strengths"}）。
    """
    stem = pathlib.Path(relpath).stem
    return set(t for t in _TITLE_TOKEN_RE.split(stem.lower()) if t)


def extract_tags(fm):
    """frontmatterのtags値を小文字トークン集合にする。リスト形式（`tags: [a, b]`）
    だけでなくscalar文字列形式（`tags: foo`）も1要素として受理し、Obsidianの
    `#foo`表記も先頭`#`を除いてリスト形式と同一視する（Codexレビュー指摘Minor
    対応・正当なfrontmatter記法が無条件に空集合へ落ちて偽陰性になるのを防ぐ）。
    リスト/文字列以外の壊れた値（数値・辞書等）は無視してfail-open。
    """
    val = fm.get("tags")
    if isinstance(val, str):
        val = [val]
    if not isinstance(val, list):
        return set()
    out = set()
    for t in val:
        s = str(t).strip().lower()
        if s.startswith("#"):
            s = s[1:]
        if s:
            out.add(s)
    return out


def build_link_resolver(notes):
    """wikilinkのターゲット文字列を「正規relpath（拡張子なし・小文字化）」へ
    解決するためのルックアップ辞書2種を返す（Codexレビュー指摘Minor対応:
    `[[foo]]`と`[[Knowledge/foo.md]]`が同じノートを指していても文字列としては
    不一致になり、outbound linksのJaccardが不当に下がっていた）。
      by_full: "knowledge/foo" -> 正規relpath（拡張子なし・大文字小文字温存）
      by_base: "foo"（basenameのみ・小文字） -> 正規relpath、ただし複数ノートで
        basenameが衝突する場合はNone（曖昧なので解決しない＝安全側）
    """
    by_full = {}
    by_base = {}
    for note in notes:
        relpath = note["relpath"]
        canonical = relpath[:-3] if relpath.endswith(".md") else relpath
        by_full[canonical.lower()] = canonical
        base_key = pathlib.PurePosixPath(canonical).name.lower()
        if base_key in by_base:
            if by_base[base_key] != canonical:
                by_base[base_key] = None  # 衝突: 解決不能とマークする
        else:
            by_base[base_key] = canonical
    return by_full, by_base


def resolve_link_target(target, by_full, by_base):
    """wikilinkのターゲット文字列を正規relpath（拡張子なし・小文字化）へ解決する。
    インデックス内のノートに解決できない場合は、従来どおり生の文字列を小文字化
    しただけの値へfail-openする（Vault外参照・存在しないノートへのリンク等）。
    """
    t = target.strip()
    if t.endswith(".md"):
        t = t[:-3]
    key_full = t.lower()
    if key_full in by_full:
        return by_full[key_full]
    base_key = pathlib.PurePosixPath(t).name.lower()
    resolved = by_base.get(base_key)
    if resolved:
        return resolved
    return key_full


def extract_outbound_links(body, by_full=None, by_base=None):
    """本文中のwikilink（vault_lib.LINK_RE）からリンク先の正規化パス集合を返す
    （エイリアス表記・見出し参照・ブロック参照は除去し、リンク先自体だけを比較
    対象にする）。by_full/by_baseを渡すとbuild_link_resolver()による曖昧性のない
    正規化（短縮リンク/フルパス/.md有無の表記ゆれ統一）を行う。省略時は従来どおり
    生文字列の小文字化のみ（単体テスト・呼び出し互換用）。
    """
    links = set()
    for raw in vault_lib.LINK_RE.findall(body):
        target = raw.split("|")[0].split("#")[0].split("^")[0].strip()
        if not target:
            continue
        if by_full is not None:
            links.add(resolve_link_target(target, by_full, by_base))
        else:
            links.add(target.lower())
    return links


def note_features(vault_root, relpath, by_full=None, by_base=None):
    """1ノート分の類似度計算用特徴量を返す（読み取り失敗時はNone）。UnicodeDecodeError
    はOSErrorのサブクラスではないため、非UTF-8/バイナリファイルでも1件のせいで
    CLI全体が例外終了しないよう明示的に捕捉する（Codexレビュー指摘Minor対応）。
    """
    p = pathlib.Path(vault_root) / relpath
    try:
        text = p.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return None
    fm, body = vault_lib.parse_frontmatter(text)
    aliases = set(a.lower() for a in vault_lib.normalize_aliases(fm.get("aliases")))
    return {
        "aliases": aliases,
        "title": title_tokens(relpath),
        "tags": extract_tags(fm),
        "links": extract_outbound_links(body, by_full, by_base),
    }


def _jaccard(set_a, set_b):
    """集合の Jaccard 係数（|A∩B|/|A∪B|）。両方空なら0.0（無関係扱い・
    「何も無い同士」を人為的に高類似度と誤判定しないため）。"""
    union = set_a | set_b
    if not union:
        return 0.0
    return len(set_a & set_b) / len(union)


# 設計書§3.3で確定済みの重み（aliases/タイトルトークン/タグ/outbound links）。
SIMILARITY_WEIGHTS = (0.4, 0.3, 0.2, 0.1)


def note_similarity(features_a, features_b, weights=SIMILARITY_WEIGHTS):
    """2ノートの特徴量から重み付きJaccard類似度を返す（[0, 1]の範囲）。
    埋め込みcosine類似度撤去に伴う代替検出（2026-07-16簡素化・設計書§3.3）。
    """
    w_alias, w_title, w_tags, w_links = weights
    j_alias = _jaccard(features_a["aliases"], features_b["aliases"])
    j_title = _jaccard(features_a["title"], features_b["title"])
    j_tags = _jaccard(features_a["tags"], features_b["tags"])
    j_links = _jaccard(features_a["links"], features_b["links"])
    return (w_alias * j_alias) + (w_title * j_title) + (w_tags * j_tags) + (w_links * j_links)


class NoteIndex:
    """SCAN_DIRS配下の対象ノート一覧を保持するだけの軽量な構造体（旧
    embedding_index.Indexの代替）。特徴量抽出・キャッシュは
    collect_active_features()側が担う（Codexレビュー指摘Minor対応: 当初持たせて
    いたfeatures_of()は常にKeyErrorになる壊れた契約だったため撤去した）。
    """

    def __init__(self, notes):
        self.notes = notes  # [{"relpath": ...}, ...]（旧embedding_index.Indexと同じ形）

    def __len__(self):
        return len(self.notes)


def build_index(vault_root):
    """SCAN_DIRS直下1階層（サブディレクトリは対象外）の実在.mdファイルを走査し、
    NoteIndexを返す（読み取り専用・一覧のみ、特徴量抽出はここでは行わない）。
    走査を1階層に限定するのは、撤去済みembedding_index.list_vault_notes()・
    RELPATH_RE（SCAN_DIRS直下限定）と同じ走査契約を維持するため（Codexレビュー
    指摘Major対応: 当初rglob()で再帰走査しており、契約が暗黙に変わっていた）。
    埋め込みインデックスと異なり永続化はしない＝毎回その場でVaultを走査する
    （キーワード特徴量抽出はcosine類似度計算用ベクトル生成よりずっと軽量な
    ため、埋め込みインデクサのような差分更新の仕組みは不要と判断）。
    """
    vault_root = pathlib.Path(vault_root)
    notes = []
    for d in SCAN_DIRS:
        base = vault_root / d
        if not base.is_dir():
            continue
        for p in sorted(base.glob("*.md")):
            if p.name == "README.md":
                continue
            relpath = p.relative_to(vault_root).as_posix()
            notes.append({"relpath": relpath})
    return NoteIndex(notes)


def collect_active_features(index, vault_root):
    """is_active_note()を満たすノートのみ特徴量を抽出する。非アクティブ
    （symlink・deprecated・存在しない）ノートの本文は一切読まない（Codexレビュー
    指摘Minor対応: 当初はpairwise_similarities()がインデックス内の全ノートを
    無条件に読み直しており、is_active_note()による除外が特徴量抽出側には
    及んでいなかった）。

    戻り値: (active, features)
      active: is_active_noteかつ特徴量読み取りに成功したノートindex(i)の
        昇順リスト
      features: i -> note_features()の戻り値dict
    """
    notes = index.notes
    by_full, by_base = build_link_resolver(notes)
    active = []
    features = {}
    for i, note in enumerate(notes):
        relpath = note["relpath"]
        if not is_active_note(vault_root, relpath):
            continue
        f = note_features(vault_root, relpath, by_full, by_base)
        if f is None:
            # is_active_note()通過直後にファイルが消えた等の稀なレース。
            # 読めない以上は特徴量を持てないので対象から外す（fail-open）。
            continue
        active.append(i)
        features[i] = f
    return active, features


def pairwise_similarities(active, features):
    """active（ノートindexのリスト）内の全ペア(i<j)の類似度を辞書 (i,j)->sim
    で返す（特徴量は事前にcollect_active_features()でキャッシュ済みのものを
    使う。ここではファイル読み取りは行わない）。
    """
    sims = {}
    for a_pos in range(len(active)):
        i = active[a_pos]
        for b_pos in range(a_pos + 1, len(active)):
            j = active[b_pos]
            sims[(i, j)] = note_similarity(features[i], features[j])
    return sims


def sim_of(sims, i, j):
    return sims[(i, j)] if i < j else sims[(j, i)]


def best_neighbor(i, candidates, sims, threshold):
    """candidates（iを含まない集合）の中でiに最も類似度が高いものを1件返す。
    戻り値は (best_j, best_sim) または None（候補なし／同点タイ／閾値未満）。

    同点タイの判定はTIE_EPSILON以内の差を「区別できない」とみなす。1位が
    確定できない場合はNoneを返す（FR10a「判定が割れた場合のデフォルトは
    マージしない」＝相互最近傍を判定できないため必然的に候補から外れる）。
    """
    best_j = None
    best_sim = None
    tie = False
    for j in candidates:
        s = sim_of(sims, i, j)
        if best_sim is None or s > best_sim + TIE_EPSILON:
            best_sim = s
            best_j = j
            tie = False
        elif abs(s - best_sim) <= TIE_EPSILON:
            tie = True
    if best_j is None or tie or best_sim < threshold:
        return None
    return best_j, best_sim


def mutual_pairs_over(indices, neighbor_fn):
    """indices内の各ノートについてneighbor_fn(i)（best_neighbor相当）を呼び、
    相互に最近傍同士(mutual top-1)であるペアを (i, j, sim)（i<j）のリストで返す。
    """
    best = {}
    for i in indices:
        best[i] = neighbor_fn(i)
    pairs = []
    for i in indices:
        nb = best.get(i)
        if nb is None:
            continue
        j, sim = nb
        nb2 = best.get(j)
        if nb2 is not None and nb2[0] == i and i < j:
            pairs.append((i, j, sim))
    return pairs


def detect_pairs(index, vault_root, threshold):
    """今回の実行で検出したペアを (merge_detected, other_detected) の2 dict で返す。
    どちらも candidate_id -> レコードdict（"first_seen"/"last_seen"等の時系列
    フィールドは含まない＝呼び出し側がstate.jsonとマージする際に付与する）。

    merge_detected: Knowledge同フォルダ・FR10a①②通過（マージ・レビュー対象候補）。
      レコード: {"note_a", "note_b", "folder", "similarity"}
    other_detected: フォルダ横断（kind="cross_folder"）または同フォルダだが
      Knowledge以外（kind="same_folder_other"）・FR10a①②通過（マージ対象外・
      観測のみ＝FR9c）。
      レコード: {"note_a", "note_b", "kind", "folder_a", "folder_b", "similarity"}
    """
    notes = index.notes
    active, features = collect_active_features(index, vault_root)
    sims = pairwise_similarities(active, features)

    folder_groups = {}
    for i in active:
        folder_groups.setdefault(folder_of(notes[i]["relpath"]), []).append(i)

    merge_detected = {}
    other_detected = {}

    # --- 同フォルダ内の相互最近傍（②「同フォルダ内」・FR10a） -------------------
    for folder, indices in folder_groups.items():
        if len(indices) < 2:
            continue

        def _same_folder_neighbor(i, _indices=indices):
            cands = [j for j in _indices if j != i]
            return best_neighbor(i, cands, sims, threshold)

        for i, j, sim in mutual_pairs_over(indices, _same_folder_neighbor):
            a, b = sorted([notes[i]["relpath"], notes[j]["relpath"]])
            cid = stable_pair_id(a, b)
            if folder in MERGE_ELIGIBLE_FOLDERS:
                merge_detected[cid] = {"note_a": a, "note_b": b, "folder": folder, "similarity": sim}
            else:
                other_detected[cid] = {
                    "note_a": a, "note_b": b, "kind": "same_folder_other",
                    "folder_a": folder, "folder_b": folder, "similarity": sim,
                }

    # --- フォルダ横断の相互最近傍（観測のみ・FR9c） -----------------------------
    def _cross_folder_neighbor(i, _active=active):
        folder = folder_of(notes[i]["relpath"])
        cands = [j for j in _active if folder_of(notes[j]["relpath"]) != folder]
        return best_neighbor(i, cands, sims, threshold)

    for i, j, sim in mutual_pairs_over(active, _cross_folder_neighbor):
        a, b = sorted([notes[i]["relpath"], notes[j]["relpath"]])
        cid = stable_pair_id(a, b)
        other_detected[cid] = {
            "note_a": a, "note_b": b, "kind": "cross_folder",
            "folder_a": folder_of(a), "folder_b": folder_of(b), "similarity": sim,
        }

    return merge_detected, other_detected


# --- state.json 更新ロジック（merge_state.pyのload/save/lockと組み合わせて使う） ---

def merge_candidate_state(existing, detected, today_iso):
    """Knowledgeマージ・レビュー待ち候補のstate.jsonセクションを更新する（FR9b）。
    ロジックは2026-07-16簡素化前と不変（類似度の算出方法だけが変わった）。
    """
    new_candidates = {cid: dict(rec) for cid, rec in existing.items()}

    for cid, rec in detected.items():
        sim = rec["similarity"]
        if cid in new_candidates:
            cur = new_candidates[cid]
            if cur.get("status") in TERMINAL_STATUSES:
                continue  # tombstone: 再検出されても終端状態からは復活させない
            cur["last_seen"] = today_iso
            cur["similarity"] = round(sim, 6)
            cur["max_similarity"] = round(max(float(cur.get("max_similarity", sim)), sim), 6)
        else:
            new_candidates[cid] = {
                "note_a": rec["note_a"],
                "note_b": rec["note_b"],
                "folder": rec["folder"],
                "status": "pending",
                "similarity": round(sim, 6),
                "max_similarity": round(sim, 6),
                "first_seen": today_iso,
                "last_seen": today_iso,
            }
    return new_candidates


def active_candidates_only(candidates):
    """レポート表示・件数カウント用に、終端状態(tombstone)を除いた候補のみを返す。"""
    return {cid: rec for cid, rec in candidates.items() if rec.get("status") not in TERMINAL_STATUSES}


def _read_note_text_or_none(vault_root, relpath):
    """state.json由来のrelpathからノート全文を安全に読み取る。以下のいずれかに
    該当すればNone（fail-open。呼び出し側が「今回のJSON出力からは除外・
    state.jsonは変更しない＝次回再試行」として扱う）:
      - 解決後のパスがvault_root配下に収まらない（`..`等によるVault外参照。
        state.jsonが破損/改ざんされていた場合の多層防御＝2026-07-16 Codex
        4巡目レビュー指摘Major対応: is_active_note()呼び出しだけでは相対パスの
        Vault境界を検証しておらず、`../../etc/passwd`のような値が万一
        state.jsonに混入していても参照先が通常ファイルでありさえすれば
        通過してしまっていた）。
      - symlink（os.open()にO_NOFOLLOWを渡し、「symlinkか確認 → 読み込む」の
        2段階の間隙で別プロセスが差し替えるTOCTOU競合もカーネルレベルで
        一括して拒否する。同じくCodex4巡目レビュー指摘Major対応: 従来の
        is_active_note()は`is_symlink()`確認とその後の`read_text()`が別々の
        システムコールであり、両者の間でsymlinkへ差し替えられると防げなかった）。
      - 通常ファイルでない（デバイスファイル等）。
      - 存在しない・読み取り失敗・非UTF-8。
      - frontmatterのdeprecatedがtrue（既に非破壊マージ済みのstub）。

    is_active_note()と論理的な判定基準は同じだが、1回のopen()呼び出しに融合し
    二重の全文読込によるメモリ使用量増加も避ける（2026-07-16 Codexレビュー
    指摘Minor対応）。

    既知の残存限界（2026-07-16 Codex 5巡目レビュー指摘・リーダー裁定待ちとして
    明記。深追いせず現状のfail-open範囲で受容）:
      - 親ディレクトリ自体をsymlinkへ差し替えるTOCTOU競合（`candidate.parent.
        resolve()`と`os.open()`の間の一瞬）は塞いでいない。完全に塞ぐには
        Vault/Knowledgeを`O_DIRECTORY|O_NOFOLLOW`のdir fdとして開き、basenameを
        その dir_fd 相対で`O_NOFOLLOW`オープンする必要がある。本ツールは
        単一ユーザーのローカルPersonal Vault専用CLIであり、この競合を突くには
        同一マシン上で悪意ある別プロセスが同時に走っている必要がある（既に
        マルウェア感染等のより大きな問題がある状況）と判断し、実装コストとの
        兼ね合いで見送った。
      - ノート全文を一度に`f.read()`しており、巨大ファイルに対するメモリ上限は
        無い（文字数チェックはread後）。個人Vaultのノートは人手で書かれる
        ものであり実務上無制限に巨大化する想定が薄いため、ストリーミング化は
        見送った。
    """
    vault_root = pathlib.Path(vault_root).resolve()
    candidate = vault_root / relpath
    try:
        resolved_parent = candidate.parent.resolve()
    except OSError:
        return None
    # 親ディレクトリがVault配下に収まっているかを先に確認する（対象ファイル
    # 自体がsymlinkの場合、candidate自体をresolve()するとsymlink先を辿って
    # しまい判定に使えないため、親ディレクトリの解決結果で`..`越境の有無を
    # 判定する。ファイル自体がsymlinkかどうかは後続のO_NOFOLLOWで別途拒否する）。
    if not (resolved_parent == vault_root or resolved_parent.is_relative_to(vault_root)):
        return None

    open_flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        open_flags |= os.O_NOFOLLOW
    try:
        fd = os.open(str(candidate), open_flags)
    except OSError:
        return None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return None
        with os.fdopen(fd, "r", encoding="utf-8") as f:
            fd = None  # fdopen成功後はf.close()がfdの面倒も見るため二重closeを避ける
            text = f.read()
    except (OSError, UnicodeError):
        return None
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass

    fm, _ = vault_lib.parse_frontmatter(text)
    val = fm.get("deprecated")
    if isinstance(val, str) and val.strip().lower() == "true":
        return None
    return text


def _is_direct_merge_eligible_note(relpath):
    """relpathが「<MERGE_ELIGIBLE_FOLDERSのいずれか>/<basename>.md」という形
    （対象フォルダの直下1階層・README.md除く）に厳密一致するかを返す。

    folder_of()（文字列を最初の'/'で区切るだけ）は`Knowledge/sub/a.md`
    （サブディレクトリ）や`Knowledge/../Personal/private.md`（traversal）も
    `folder_of(...) == "Knowledge"`と誤判定してしまう（どちらも文字列の先頭が
    "Knowledge/"であることに変わりはないため）。PurePosixPathの`parts`で
    「フォルダ名・ファイル名の正確に2要素」であることを検証すれば、余分な
    構成要素（サブディレクトリ名・".."等）を含むパスは自動的に弾かれる
    （2026-07-16 Codex 6巡目レビュー指摘Major対応: 当初のfolder_of()ベースの
    検証はこの2種類の迂回経路を防げていなかった）。
    """
    p = pathlib.PurePosixPath(relpath)
    if p.as_posix() != relpath:
        # 冗長な区切り（"//"）・先頭"./"・末尾"/"等、正規形と異なる表記は
        # 安全側で拒否する（曖昧な表記を許容しない）。
        return False
    parts = p.parts
    if len(parts) != 2:
        return False
    folder, name = parts
    if folder not in MERGE_ELIGIBLE_FOLDERS:
        return False
    if not name.endswith(".md") or name == "README.md":
        return False
    return True


def _candidate_record_is_valid_for_enrichment(cid, rec):
    """state.json由来の候補レコードが「Knowledge同フォルダの正当なマージ候補
    ペア」の形をしているかを検証する（2026-07-16 Codex 5/6巡目レビュー指摘
    Major対応: `_read_note_text_or_none()`のVault境界検証だけでは、state.json
    が改ざんされた場合に「Vault配下ではあるがKnowledge以外・本来のMERGE対象外
    のフォルダ（Personal等の個人的な内容を含みうるフォルダ）」やサブディレクトリ
    /traversal経由のノートまで読み取って外部のヘッドレスClaudeへ送信して
    しまう経路が残っていた。MERGE_ELIGIBLE_FOLDERS＝Knowledgeの直下1階層のみ
    という設計上の境界を、enrichment段階でも独立に再検証する）。

    検証項目: (1) note_a・note_bの両方が_is_direct_merge_eligible_note()
    （対象フォルダ直下1階層・厳密な正規形パス）を満たす、(2) folderフィールドが
    note_a/note_bの実際のフォルダと一致する、(3) note_a≠note_b、(4) cid
    （stateのキー）がstable_pair_id(note_a, note_b)の再計算値と一致する
    （＝パスだけが差し替えられ、対応するIDが更新されていない改ざんを検出する）。
    """
    folder = rec.get("folder")
    note_a = rec.get("note_a")
    note_b = rec.get("note_b")
    if not isinstance(note_a, str) or not isinstance(note_b, str):
        return False
    if note_a == note_b:
        return False
    if not _is_direct_merge_eligible_note(note_a) or not _is_direct_merge_eligible_note(note_b):
        return False
    if folder_of(note_a) != folder or folder_of(note_b) != folder:
        return False
    if cid != stable_pair_id(note_a, note_b):
        return False
    return True


def enrich_candidates_with_texts(vault_root, active_candidates):
    """--json出力向けに、各アクティブ候補へ両ノートの全文＋各SHA-256を追加する
    （設計書§2.2「フラグメント本文全文・マージ候補2ノートの全文＋各SHA-256を
    含める」＝maintenance_apply.pyがヘッドレスClaudeへ渡す統合ノート素材、および
    適用直前のTOCTOU再照合〈設計書§2.4〉の両方に使う）。

    両ノート合計文字数がMAX_MERGE_CANDIDATE_CHARS(8,000字)を超える候補は
    `non_actionable: "truncated"`を付けて別リストへ分離する（「切り詰めて渡す
    fail-open案は撤回。次回へ持ち越す」の裁定どおり＝今回のPROMOTE/MERGE対象
    にはしない。state.json自体は変更しないため次回実行時に自然に再度候補に
    なる）。truncated側にはnote_a_text/note_b_textを含めない（2026-07-16
    Codexレビュー指摘Minor対応: fragments_log.pyのMAX_FRAGMENT_CHARSパターンは
    truncated側にも全文を残すが、フラグメント〈Fragments日次ノートの1見出し/
    箇条書き単位〉と異なりKnowledgeノート全文は事実上無制限に大きくなり得る
    ため、「除外して次回へ持ち越す」という上限の趣旨に反してJSON出力
    （stdout・後段の集約）を肥大化させないよう、truncated側はid・パス・
    SHA-256・文字数などの識別情報のみを残す（2026-07-16 Codex 6巡目レビュー
    指摘Minor対応: 「メモリを肥大化させない」という表現は実態より強く、
    判定前に両ノート全文を一度読み込む一時的なメモリ消費自体は残っている
    ＝下記の「既知の残存限界」参照。ここで防いでいるのはJSON出力サイズの
    肥大化のみと明記する）。

    候補レコードが「Knowledge同フォルダの正当なペア」の形をしていない
    （_candidate_record_is_valid_for_enrichment()参照。state.json改ざんで
    フォルダ制約やID整合性が崩れている場合を検出する）・どちらかのノートが
    安全に読み取れない（_read_note_text_or_none()参照: Vault境界外・symlink・
    存在しない・deprecated:true・読み取り失敗）候補は、今回の--json出力からは
    除外する（fail-open。state.jsonは変更しないため次回再試行される）。

    引数のactive_candidatesは{cid: rec}辞書（active_candidates_only()の戻り値）。
    戻り値: (enriched, truncated, unreadable_ids)。
      enriched: [{"id": cid, ...recの全フィールド..., "note_a_text":...,
        "note_a_sha256":..., "note_b_text":..., "note_b_sha256":...}, ...]
      truncated: [{"id": cid, ...recの全フィールド..., "note_a_sha256":...,
        "note_b_sha256":..., "combined_chars": int, "non_actionable":
        "truncated"}, ...]（本文テキストは含めない）
      （どちらもcid昇順）。unreadable_idsは除外したcandidate_idのリスト
      （フォルダ制約・ID整合性違反による除外もこちらにまとめて含める）。
    """
    enriched = []
    truncated = []
    unreadable_ids = []
    for cid in sorted(active_candidates):
        rec = active_candidates[cid]
        if not _candidate_record_is_valid_for_enrichment(cid, rec):
            unreadable_ids.append(cid)
            continue
        text_a = _read_note_text_or_none(vault_root, rec["note_a"])
        text_b = _read_note_text_or_none(vault_root, rec["note_b"])
        if text_a is None or text_b is None:
            unreadable_ids.append(cid)
            continue
        sha_a = hashlib.sha256(text_a.encode("utf-8")).hexdigest()
        sha_b = hashlib.sha256(text_b.encode("utf-8")).hexdigest()
        if len(text_a) + len(text_b) > MAX_MERGE_CANDIDATE_CHARS:
            out_rec = dict(rec)
            out_rec["id"] = cid
            out_rec["note_a_sha256"] = sha_a
            out_rec["note_b_sha256"] = sha_b
            out_rec["combined_chars"] = len(text_a) + len(text_b)
            out_rec["non_actionable"] = "truncated"
            truncated.append(out_rec)
        else:
            out_rec = dict(rec)
            out_rec["id"] = cid
            out_rec["note_a_text"] = text_a
            out_rec["note_a_sha256"] = sha_a
            out_rec["note_b_text"] = text_b
            out_rec["note_b_sha256"] = sha_b
            enriched.append(out_rec)
    return enriched, truncated, unreadable_ids


def _date_gap_days(prev_iso, today_iso):
    try:
        prev_date = datetime.date.fromisoformat(prev_iso)
        today_date = datetime.date.fromisoformat(today_iso)
    except (TypeError, ValueError):
        return None
    return (today_date - prev_date).days


def merge_detection_state(existing, detected, today_iso, gap_reset_days=GAP_RESET_DAYS):
    """フォルダ横断／同フォルダ非Knowledgeの検出ログ（観測専用・FR9c）を更新する。
    ロジックは2026-07-16簡素化前と不変。
    """
    new_detections = {}
    for cid, rec in detected.items():
        sim = rec["similarity"]
        prev = existing.get(cid)
        if isinstance(prev, dict) and prev.get("note_a") == rec["note_a"] and prev.get("note_b") == rec["note_b"]:
            prev_last_seen = prev.get("last_seen")
            gap = _date_gap_days(prev_last_seen, today_iso)
            if prev_last_seen == today_iso:
                first_seen = prev.get("first_seen", today_iso)
                consecutive = int(prev.get("consecutive_detections", 1))
            elif gap is not None and 0 < gap <= gap_reset_days:
                first_seen = prev.get("first_seen", today_iso)
                consecutive = int(prev.get("consecutive_detections", 0)) + 1
            else:
                first_seen = today_iso
                consecutive = 1
            max_sim = max(float(prev.get("max_similarity", sim)), sim)
        else:
            first_seen = today_iso
            consecutive = 1
            max_sim = sim
        new_detections[cid] = {
            "note_a": rec["note_a"],
            "note_b": rec["note_b"],
            "kind": rec["kind"],
            "folder_a": rec["folder_a"],
            "folder_b": rec["folder_b"],
            "similarity": round(sim, 6),
            "max_similarity": round(max_sim, 6),
            "first_seen": first_seen,
            "last_seen": today_iso,
            "consecutive_detections": consecutive,
        }
    return new_detections


# --- レポート生成 ---------------------------------------------------------------

def _wikilink(relpath):
    return f"[[{relpath[:-3]}]]" if relpath.endswith(".md") else f"[[{relpath}]]"


def build_report(today, candidates, detections, threshold):
    lines = []
    lines.append("---")
    lines.append(f"date: {today.isoformat()}")
    lines.append("tags: [knowledge-merge-candidates, report]")
    lines.append("project: external-brain")
    lines.append("---")
    lines.append("")
    lines.append(f"# Knowledge統合候補 週次検出 {today.isoformat()}")
    lines.append("")
    lines.append(
        "自動生成（`work/takumi009-ai-env/scripts/vault-agents/knowledge_merge_candidates.py`）。"
        f"LLM不使用・決定的処理のみ（キーワード系重み付きJaccard類似度閾値={threshold}・"
        "相互最近傍のみを評価）。"
        "**このレポートに載る候補はFR10a①②（類似度閾値＋相互最近傍）を機械的に通過した"
        "「レビュー待ち候補」であり、マージが確定したものではない**。③（矛盾・否定表現差・"
        "日付差・固有名詞差・コードブロック差の判断）は週次メンテ（maintenance.sh Phase2）の"
        "ヘッドレスClaudeが本文全文を読んで行い、確信できる候補のみ週上限2件まで非破壊マージ"
        "（元ノートはsuperseded_byスタブ化）する。手動でのCLI処理は不要（旧knowledge_merge.py"
        "は撤去済み）。見送られた候補はこのレポートに残り続け、次回の棚卸し相談で人間が判断する。"
    )
    lines.append("")
    lines.append("運用ノート: [[Preferences/knowledge-merge-procedure]]")
    lines.append("")
    lines.append("## Knowledgeマージ・レビュー待ち候補")
    lines.append("")
    if candidates:
        lines.append("| candidate_id | note_a | note_b | 類似度 | 最大類似度 | 状態 | 初出日 | 最終検出日 |")
        lines.append("|---|---|---|---|---|---|---|---|")
        for cid in sorted(candidates):
            rec = candidates[cid]
            lines.append(
                f"| {cid} | {_wikilink(rec['note_a'])} | {_wikilink(rec['note_b'])} |"
                f" {rec['similarity']:.4f} | {rec['max_similarity']:.4f} | {rec['status']} |"
                f" {rec['first_seen']} | {rec['last_seen']} |"
            )
    else:
        lines.append("（今回・繰り越し含め対象候補なし）")
    lines.append("")
    lines.append("## フォルダ横断・同フォルダ(Knowledge以外)の検出ログ（観測のみ・マージ対象外／FR9c）")
    lines.append("")
    if detections:
        lines.append("| candidate_id | note_a | note_b | 種別 | 初出日 | 最終検出日 | 連続検出回数 | 最大類似度 |")
        lines.append("|---|---|---|---|---|---|---|---|")
        for cid in sorted(detections):
            rec = detections[cid]
            lines.append(
                f"| {cid} | {_wikilink(rec['note_a'])} | {_wikilink(rec['note_b'])} | {rec['kind']} |"
                f" {rec['first_seen']} | {rec['last_seen']} | {rec['consecutive_detections']} |"
                f" {rec['max_similarity']:.4f} |"
            )
    else:
        lines.append("（対象なし）")
    lines.append("")
    return "\n".join(lines)


# --- CLI -------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--vault", default=str(DEFAULT_VAULT), help=f"Vaultのルート（既定: {DEFAULT_VAULT}）")
    ap.add_argument("--out-dir", default=str(DEFAULT_OUT_DIR), help=f"レポート/state.json出力先（既定: {DEFAULT_OUT_DIR}）")
    ap.add_argument("--sim-threshold", type=float, default=DEFAULT_SIM_THRESHOLD, help="FR10a①の類似度閾値")
    ap.add_argument("--lock-file", default=str(DEFAULT_LOCK_FILE),
                     help=f"state.jsonの排他ロック（既定: {DEFAULT_LOCK_FILE}）")
    ap.add_argument("--json", action="store_true", help="機械可読なJSON出力を標準出力へ返す（maintenance.sh向け）")
    args = ap.parse_args(argv)

    sim_threshold = args.sim_threshold
    if math.isnan(sim_threshold) or math.isinf(sim_threshold) or not (0.0 <= sim_threshold <= 1.0):
        print(f"警告: --sim-threshold の値が不正です({sim_threshold!r})。既定値{DEFAULT_SIM_THRESHOLD}にフォールバックします。",
              file=sys.stderr)
        sim_threshold = DEFAULT_SIM_THRESHOLD

    out_dir = pathlib.Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    state_path = out_dir / "state.json"

    today = datetime.date.today()

    # 週次7日間隔ガード（MIN_INTERVAL_DAYS・--force・--min-interval-days）は
    # 2026-07-16に撤去した（tester独立検証F3対応。理由はモジュールdocstring
    # 参照）。実行するたびに毎回検出処理を行う（fragments_log.py・
    # vault_inventory.pyと同じ扱い＝ランナーの週次周期が唯一のケイデンス制御）。

    vault_root = pathlib.Path(args.vault)
    if not vault_root.is_dir():
        print(f"skip: Vaultが見つかりません（{vault_root}）。次回実行時に再試行してください。", file=sys.stderr)
        return 0

    index = build_index(vault_root)
    merge_detected, other_detected = detect_pairs(index, vault_root, sim_threshold)
    today_iso = today.isoformat()

    lock_path = pathlib.Path(args.lock_file)
    held = merge_state.acquire_lock(lock_path)
    if held is None:
        # --vaultが見つからない場合（917行目）と同じくstderrへ出す（2026-07-16
        # Codexレビュー指摘Minor対応: 標準出力へ書くと、--json指定時に平文が
        # 混入し「標準出力へ平文を混入させない」契約に違反する。標準出力を
        # 空のままexit 0にすることで、maintenance_apply.py側の_load_json_file()が
        # 空/未解析エラーとして検出しinput_load_failuresへ正しく計上する
        # ＝ロック競合を「候補0件の静穏週」と誤混同せず、既存のphase1_input_
        # invalid判定へ自然に合流させる）。
        print(f"skip: state.jsonの排他ロックを取得できません（他プロセスが処理中の可能性）: {lock_path}", file=sys.stderr)
        return 0
    try:
        try:
            state = merge_state.load_state(state_path)
        except merge_state.StateError as e:
            # 同上（Codexレビュー指摘Minor対応）。
            print(f"skip: {e}（state.jsonの内容は変更していません。手動確認が必要です）", file=sys.stderr)
            return 0

        new_candidates = merge_candidate_state(state.get("candidates", {}), merge_detected, today_iso)
        new_detections = merge_detection_state(state.get("detections", {}), other_detected, today_iso)

        state["schema_version"] = STATE_SCHEMA_VERSION
        state["candidates"] = new_candidates
        state["detections"] = new_detections
        state["updated_at"] = today_iso
        merge_state.save_state(state_path, state)

        active_candidates = active_candidates_only(new_candidates)
        report_text = build_report(today, active_candidates, new_detections, sim_threshold)
        out_path = out_dir / f"{today_iso}.md"
        tmp_report = out_path.parent / f".{out_path.name}.tmp-{os.getpid()}"
        tmp_report.write_text(report_text, encoding="utf-8")
        os.replace(str(tmp_report), str(out_path))
    finally:
        merge_state.release_lock(held)

    if args.json:
        enriched, truncated, unreadable_ids = enrich_candidates_with_texts(vault_root, active_candidates)
        payload = {
            "date": today_iso,
            "report_path": str(out_path),
            "sim_threshold": sim_threshold,
            "candidates": enriched,
            "candidates_truncated": truncated,
            "n_candidates": len(enriched),
            "n_detections": len(new_detections),
        }
        if unreadable_ids:
            print(f"FACT: 候補 {len(unreadable_ids)} 件はノート読込に失敗したため今回のJSON出力から"
                  f"除外しました（state.jsonは変更していないため次回実行時に再試行されます）: "
                  f"{', '.join(unreadable_ids[:5])}{'...' if len(unreadable_ids) > 5 else ''}",
                  file=sys.stderr)
        print(f"レポート生成: {out_path}（レビュー待ち候補 {len(active_candidates)} 件・"
              f"検出ログ {len(new_detections)} 件）", file=sys.stderr)
        print(json.dumps(payload, ensure_ascii=False))
    else:
        print(
            f"レポート生成: {out_path}（レビュー待ち候補 {len(active_candidates)} 件・"
            f"検出ログ {len(new_detections)} 件）"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
