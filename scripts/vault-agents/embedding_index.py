#!/usr/bin/env python3
"""外部脳ハイブリッド検索・柱①の共有モジュール。

責務（設計: docs/design-vault-hybrid-search.md §1 柱①・§2.2・§3(d)）:
  - インデックスI/O（世代ディレクトリ gen-<id>/ ＋ CURRENT ポインタの原子更新）
  - content hash（sha256・ノート本文の変更検知）
  - Ollama HTTPクライアント（urllib・依存注入可能）
  - cosine類似度計算
  - 埋め込み入力の生成（タイトル＋aliases＋本文・frontmatter除去・truncate）
  - インデックス読込検証（schema_version/model/model_digest/dim/件数/バイト長）

CLIエントリポイントは持たない。update_embedding_index.py（書き手）・
vector_recall_helper.py（読み手）がimportして使う（ロジック重複を避ける＝
scripts/vault-agents/recall_bench.py 等の既存の「同じディレクトリのモジュールを
importして再利用する」方針を踏襲）。

保存形式（設計書§3(a)採用案＝標準ライブラリのみ）:
  <index_dir>/
    CURRENT                … 現行世代ディレクトリ名（プレーンテキスト1行）
    gen-<timestamp>-<pid>/
      meta.json             … schema_version/model/model_digest/dim/count/notes[]
      vectors.bin           … array.array('f') を notes と同じ順序でtobytes()した生バイナリ

<index_dir> の既定値はリポジトリ内 `.cache/vault-embeddings/`（git管理外・.gitignore済み）。
"""
import array
import datetime
import hashlib
import json
import os
import pathlib
import re
import shutil
import sys
import time
import urllib.error
import urllib.request
import urllib.parse

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import vault_inventory as vi  # noqa: E402  frontmatter解析・aliases正規化を再利用（重複実装しない）

# 2026-07-11後半: options.num_ctx/num_batch付与（n_batch超過400対策）でOllamaへの
# 送信内容が変わったため2へ上げる（Codexレビュー指摘・Major: schema_versionを
# 据え置くと、この変更より前に構築されていた既存インデックスの未変更ノートが
# 「content hash一致」のまま古い設定で生成されたベクトルを再利用してしまい、同じ
# 世代内に生成条件の異なるベクトルが混在しうる。version上げにより次回実行時に
# 強制フルリビルドされ、全ベクトルが新しいoptions付きで再生成されることを保証する）。
#
# 2026-07-11 truncated_notes追加時に3へ上げる（Codexレビュー指摘・Major: 直前の
# schema_version=2世代はnum_ctx/num_batchメタデータを持つが、truncated_notesは
# 持たない。もしnum_ctx/num_batchが偶然一致し、ノートの追加/削除/内容変更が無い
# 実行だった場合、read_index()はtruncated_notesフィールド欠如を空リストへ
# フォールバックするだけで不一致とみなさず、no_change早期returnしてしまう＝
# 長文ノートが実在してもtruncated_notesが永久に空のまま観測不能になる。version
# 上げにより、このケースも含めて次回実行時に強制フルリビルドされることを保証する）。
SCHEMA_VERSION = 3

# モデルは設定可能・既定は0.6b（researcherのモデル選定テスト前の暫定・設計書§5②）。
DEFAULT_MODEL = os.environ.get("VAULT_EMBED_MODEL", "qwen3-embedding:0.6b")
DEFAULT_BASE_URL = os.environ.get("VAULT_EMBED_BASE_URL", "http://127.0.0.1:11434")

# 想起フック(claude/hooks/vault-recall.sh)のSCAN_DIRSと同じ5フォルダ（FR4）。
# 2026-07-11決定（[[Decisions/2026-07-11-personal-recall-scope]]）でPersonal/を
# 想起対象へ追加（4→5フォルダ）。
SCAN_DIRS = ("Knowledge", "Preferences", "Decisions", "Projects", "Personal")

# 埋め込み入力のheuristic truncate（Ollama側 truncate:true との二重安全網・設計書§3(d)）。
TRUNCATE_CHARS = 20000

# 類似度閾値（FR7・パラメータ化）。当初0.5暫定→2026-07-12に0.4へ実測校正（本人指示＝
# 要件v2未決事項g「導入時実測校正」の実施。本人立ち会いの実地テストで、正解ノートの
# スコアが0.48〜0.50帯に密集して0.5を割る取りこぼしが3例観測された（devices 0.4824/
# 0.4852・蒸留済みクエリでも0.5045ぎりぎり等）。候補提示は参考情報（読むか否かは
# リーダー判断・表示最大3件）のため「外れ1行のコスト＜沈黙のコスト」という非対称性から
# 本人が0.4を選択。0.42以下はノイズ帯が濃くなることも同日実測済み＝これ以上の引き下げは
# 慎重に。0.6b vs 4bのモデル選定テスト（月曜）でモデルと閾値をセットで正式決定する）。
DEFAULT_SIM_THRESHOLD = float(os.environ.get("VAULT_EMBED_SIM_THRESHOLD", "0.4"))

# Ollama /api/embed へ渡すoptions.num_ctx/num_batch（リーダー実機検証で機序を確定・
# 2026-07-11後半）。Ollamaは埋め込みモデルを既定 n_ctx=4096・n_batch=2048 で起動する。
# 埋め込み（非因果的）は入力全体を1バッチで処理する必要があるため、未キャッシュの
# トークン数が n_batch(2048) を超えるノート（2048<tokens<=4096）は400になる
# （サーバログ実測: task.n_tokens=3136をcached 2048で分割しようとして400）。
# さらに「失敗した試行でも2048トークン分がスロットにキャッシュされ、後続の同一入力は
# 残り分だけの処理になり成功する」というプロンプトキャッシュ由来の非決定性（複数
# スロットのLRU選択により、何度か叩くうちに温まったスロットに当たると成功に転じる）
# も確認済み＝「同一内容が成功したり失敗したりする」ように見えていた正体。
# options.num_batch/num_ctxを明示指定すると、この既定値問題を回避して決定的に解決
# することを実機で確認済み（サーバ再起動でキャッシュを消した直後でも200・再送も200）。
#
# 既定値4096への変更（リーダー実機再測定・2026-07-11更に後半・OLLAMA_NUM_PARALLEL=1・
# Flash Attention有効を確認済みの上での計測）: num_ctx=8192でモデルロード6.7GB・
# num_ctx=4096で3.6GB（ほぼ線形）。メモリの支配項は並列スロット数ではなくnum_ctx
# そのものと判明したため、24GB機での常用を考え既定を8192→4096へ引き下げる
# （環境変数VAULT_EMBED_NUM_CTX/VAULT_EMBED_NUM_BATCHでの上書きは従来どおり可能）。
# num_batch=num_ctxを維持する限り「1バッチ処理」要件は満たされ、上記のn_batch超過
# 400は再発しない。トレードオフ: 4096トークン相当を超える長文ノート（external-brain-
# guide等ごく少数）はtruncateで後半が落ちるが、タイトル＋aliases＋前半に意味信号が
# 集中しており埋め込み品質への影響は限定的と判断（実測確認は運用側で継続）。
# 8192の根拠（値そのものは変更後も8192側の説明として残す）: qwen3-embeddingは32K対応・
# 上限まで使うなら20,000字truncate後の日本語でも余裕を持って
# 1バッチに収まる・0.6b/4bともメモリ影響は軽微（リーダー実機検証・2026-07-11）。
def _positive_int_env(name, default):
    """環境変数を正の整数として読む。未設定・空・非数値・0以下はdefaultへfail-openで
    戻す（設定ミス1つでインポート自体が例外終了しないように・Codexレビュー指摘・Minor:
    以前はint()に直接渡しており非整数値でImportError相当のクラッシュ、0/負数もそのまま
    Ollamaへ送られてしまっていた）。vault_inventory.pyの同名関数と同じ考え方。
    """
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return default
    try:
        value = int(raw.strip())
    except ValueError:
        return default
    return value if value > 0 else default


EMBED_NUM_CTX = _positive_int_env("VAULT_EMBED_NUM_CTX", 4096)
EMBED_NUM_BATCH = _positive_int_env("VAULT_EMBED_NUM_BATCH", 4096)

# truncate検知（クライアント側の保守的な文字数ベース判定・2026-07-11リーダー指示）:
# サーバ内トークナイズを厳密再現せず、「1トークンあたりの文字数」を実際より小さめに
# 見積もることで過検出側に倒す（見逃しより誤検出の方が安全＝ノート分割の衛生ループの
# 入力として使うため）。実Vaultでの実測較正（2026-07-11）: 当初2文字/トークンで
# 試したところ、リーダーが実測で確認した「10KB超・7本」に対し実際には1本しか
# 検知できなかった（frontmatter除去でファイルサイズと埋め込み入力の文字数が
# 大きく乖離する・日本語主体コンテンツは1文字あたりのトークン数がさらに多い傾向が
# 実測でも裏付けられたため）。1文字/トークン（＝num_ctxとほぼ同じ文字数を閾値とする、
# 最も保守的な＝過検出寄りの見積もり）に較正し直した。
CHARS_PER_TOKEN_CONSERVATIVE = 1

INDEX_REL_DIR = pathlib.PurePosixPath(".cache/vault-embeddings")  # リポジトリルート相対

VECTOR_DTYPE = "f"  # array.array typecode（float32）
VECTOR_ITEMSIZE = array.array(VECTOR_DTYPE).itemsize  # 実測4（環境依存を避けるため動的取得）

DEFAULT_KEEP_GENERATIONS = 3  # 直近3世代以上保持（設計書§2.2）

# 想起フック（対話セッション側）がOllamaを実際に使おうとした形跡を示すマーカー
# ファイル（3巡目Codexレビュー指摘・Major対応）。update_embedding_index.pyが
# 「ジョブ開始時点ではモデル未ロードだったが、実行中(フルビルド時は数十秒かかる)に
# 対話セッションが割り込んだ」ケースをTOCTOUなしで検知するために使う。
# /api/psの再確認では「自分自身の直前のリクエストで既にロード済み」と「他者が
# ロードした」を区別できず自己汚染してしまうため使えないが、このマーカーは
# 想起フック側（別プロセス）が独立して更新するため、indexer自身の活動とは
# 混同しない。
ACTIVITY_MARKER_PATH = pathlib.Path(os.environ.get(
    "VAULT_EMBED_ACTIVITY_MARKER", str(pathlib.Path.home() / ".claude" / "logs" / "ollama-recall-activity.marker")))


def touch_activity_marker(path=None):
    """想起フック側がOllama embedを試みる直前に呼ぶ（best-effort・失敗しても
    握りつぶす＝マーカー更新の失敗で想起処理自体を妨げない）。"""
    p = pathlib.Path(path) if path else ACTIVITY_MARKER_PATH
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.touch(exist_ok=True)
        os.utime(p, None)  # 既存ファイルでも確実にmtimeを更新する
    except OSError:
        pass


def recent_activity(path=None, within_seconds=120):
    """マーカーファイルがwithin_seconds秒以内に更新されていればTrueを返す
    （ファイル無し・stat失敗は「直近の活動なし」扱いでFalse）。"""
    p = pathlib.Path(path) if path else ACTIVITY_MARKER_PATH
    try:
        age = time.time() - p.stat().st_mtime
    except OSError:
        return False
    return age <= within_seconds

# new_generation_id()が生成する形式に厳密一致させる（CURRENTポインタの内容検証・
# Codexレビュー指摘Critical）。
GEN_NAME_RE = re.compile(r"^gen-\d{8}T\d{6}Z-\d+$")

# meta.json内のnotes[].relpathとして許容する形式: SCAN_DIRS直下1階層＋.md拡張子のみ
# （絶対パス・".."・"\\"・シンボリックリンク的脱出を拒否する・Codexレビュー指摘Critical:
# 改ざん/破損したインデックスがVault外や任意ファイルへの参照を埋め込んでいても、
# 読み手（vector_recall_helper.py）がそれを候補として提示してしまわないようにする）。
RELPATH_RE = re.compile(r"^(?:%s)/[^/\\]+\.md$" % "|".join(re.escape(d) for d in SCAN_DIRS))


def is_valid_relpath(relpath):
    """meta.json由来のrelpathが安全な形式か（SCAN_DIRS直下の.mdファイル名のみ）を返す。"""
    if not isinstance(relpath, str):
        return False
    if "\x00" in relpath or ".." in relpath.split("/"):
        return False
    return bool(RELPATH_RE.match(relpath))


class IndexError_(Exception):
    """インデックスの読込/整合性検証に失敗したことを表す（呼び出し側が
    fail-open（vector_recall_helper.py）/フルリビルド判定（update_embedding_index.py）
    を行うための専用例外。組み込みのIndexErrorと紛らわしいため末尾に _ を付ける）。"""


def repo_root():
    return pathlib.Path(__file__).resolve().parent.parent.parent


def index_root(override=None):
    """インデックスの置き場所（ディレクトリ）を返す。優先順位:
    引数override > 環境変数VAULT_EMBED_INDEX_DIR（テスト用） > リポジトリ内既定値。
    """
    if override:
        return pathlib.Path(override)
    env = os.environ.get("VAULT_EMBED_INDEX_DIR")
    if env:
        return pathlib.Path(env)
    return repo_root() / INDEX_REL_DIR


# --- content hash ------------------------------------------------------------

def content_hash(text):
    """ノート本文（生テキスト）のsha256 hexdigest。差分更新の変更検知に使う
    （設計書§2.2「sha256差分検知」）。埋め込み入力の生成ロジックが将来変わっても
    未変更ノートの再埋め込みを引き起こさないよう、生ファイル内容そのものを
    ハッシュ対象にする（embedding入力生成の変更はschema_versionの責務）。"""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


# --- 埋め込み入力生成 ---------------------------------------------------------

def build_embedding_input(relpath, text):
    """埋め込み入力＝タイトル(ファイル名由来)＋aliases＋本文
    （frontmatter YAML除去・コードブロックは温存＝設計書§3(d)）。
    vault_inventory.parse_frontmatter()がfrontmatterブロックを取り除いた本文
    （コードブロック等はそのまま残る）を返すため、それをそのまま使う。
    20,000字を超える場合はheuristic truncateする（Ollama側 truncate:true との
    二重安全網）。
    """
    stem = pathlib.PurePosixPath(relpath).stem
    fm, body = vi.parse_frontmatter(text)
    aliases = vi.normalize_aliases(fm.get("aliases"))
    header_parts = [stem] + aliases
    header = "\n".join(p for p in header_parts if p)
    combined = f"{header}\n\n{body.strip()}" if header else body.strip()
    if len(combined) > TRUNCATE_CHARS:
        combined = combined[:TRUNCATE_CHARS]
    return combined


def is_likely_truncated(embedding_input, num_ctx=None):
    """embedding_input（build_embedding_input()の戻り値）が、Ollama側でtruncateされて
    いる可能性が高いかを文字数ベースの保守的な判定で返す（2026-07-11リーダー指示:
    「どのノートが実際に切られたかを観測可能にしたい」＝ノート分割の衛生ループへの
    入力）。サーバ内トークナイズの厳密再現は行わない・過検出側に倒す（CHARS_PER_TOKEN_
    CONSERVATIVEのヘッダコメント参照）。判定は2条件のOR:
      (1) クライアント側heuristic truncate(TRUNCATE_CHARS=20,000字)にちょうど達している
          （build_embedding_input()内部で実際に切られたことを意味する）。
      (2) num_ctx(既定EMBED_NUM_CTX)を保守的な文字/トークン比で換算した文字数「以上」
          （truncate:trueによるサーバ側のトークン単位truncateが働いた可能性が高い。
          ちょうど閾値と同じ文字数でも実tokenizerでは1トークン未満の文字を含む記号・
          Unicode文字等によりnum_ctxを超過しうるため、境界値は非truncate扱いにせず
          truncate候補側に倒す＝Codexレビュー指摘・Major対応で`>`から`>=`へ変更）。
    """
    if num_ctx is None:
        num_ctx = EMBED_NUM_CTX
    if len(embedding_input) >= TRUNCATE_CHARS:
        return True
    return len(embedding_input) >= num_ctx * CHARS_PER_TOKEN_CONSERVATIVE


def list_vault_notes(vault_root):
    """5フォルダ（SCAN_DIRS）の*.mdを相対パス(posix区切り)のソート済みリストで返す。README.mdは
    各フォルダの説明用ファイルであり想起フックの照合対象からも除外されているため、
    同じ方針で除外する（claude/hooks/vault-recall.sh:449と同じ扱い）。
    """
    vault_root = pathlib.Path(vault_root)
    out = []
    for d in SCAN_DIRS:
        dir_path = vault_root / d
        if not dir_path.is_dir():
            continue
        for p in sorted(dir_path.glob("*.md")):
            if p.name == "README.md":
                continue
            out.append(p.relative_to(vault_root).as_posix())
    return sorted(out)


# --- Ollama HTTPクライアント（urllib・依存注入可能） ---------------------------

_LOOPBACK_HOSTS = ("127.0.0.1", "localhost", "::1")


def _assert_local_base_url(base_url):
    """完全ローカル制約（設計書冒頭「完制約: 完全ローカル」）を実装で担保する。既定では
    loopback以外のホストへの送信を拒否する（Codexレビュー指摘・Major: base_urlを
    無制限に上書きでき、プロンプト/Vault本文が任意ホストへ送信され得た）。
    VAULT_EMBED_ALLOW_REMOTE=1で明示的に許可できる（将来的なリモートOllama運用が
    本人判断で必要になった場合の脱出口。既定は不許可＝安全側）。
    """
    if os.environ.get("VAULT_EMBED_ALLOW_REMOTE") == "1":
        return
    host = (urllib.parse.urlparse(base_url).hostname or "").lower()
    if host not in _LOOPBACK_HOSTS:
        raise ValueError(
            f"base_urlはloopback以外への送信を許可していません（完全ローカル制約）: {base_url}"
            "（VAULT_EMBED_ALLOW_REMOTE=1で明示的に許可可能）")


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    """3xxリダイレクトを一切追わない（Codexレビュー指摘・Major: loopback上の応答者が
    悪意/誤設定でリダイレクトを返した場合に外部ホストへ転送されるのを防ぐ多層防御）。
    Noneを返すとurllibはリダイレクトを追わず3xxレスポンスをそのまま呼び出し元へ渡す
    （json.loads側で異常として検知され、fail-open/fail-closed経路へ落ちる）。
    """

    def redirect_request(self, *args, **kwargs):
        return None


_NO_REDIRECT_OPENER = urllib.request.build_opener(_NoRedirectHandler)


def _http_post_json(url, payload, timeout):
    _assert_local_base_url(url)
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"}, method="POST")
    with _NO_REDIRECT_OPENER.open(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _http_get_json(url, timeout):
    _assert_local_base_url(url)
    req = urllib.request.Request(url, method="GET")
    with _NO_REDIRECT_OPENER.open(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def fetch_ollama_tags(base_url=DEFAULT_BASE_URL, timeout=3.0, fetcher=None):
    """GET /api/tags の結果(dict)を返す。疎通確認とmodel_digest取得を兼ねる。
    通信/JSON異常はそのまま例外を伝播させる（呼び出し側でfail-open/fail-closedを判断させる
    ため、ここでは握りつぶさない＝呼び出し側のtry/exceptに委ねる設計）。
    fetcher(url, timeout) -> dict を差し替えるとテストでHTTPを完全モックできる。
    """
    fetcher = fetcher or _http_get_json
    return fetcher(f"{base_url}/api/tags", timeout)


def model_digest_from_tags(tags_data, model):
    """fetch_ollama_tags()の戻り値からmodelのdigestを取り出す。未取得(未pull)ならNone。"""
    if not isinstance(tags_data, dict):
        return None
    for m in tags_data.get("models", []) or []:
        if not isinstance(m, dict):
            continue
        if m.get("name") == model or m.get("model") == model:
            return m.get("digest")
    return None


def fetch_ollama_ps(base_url=DEFAULT_BASE_URL, timeout=3.0, fetcher=None):
    """GET /api/ps の結果(dict)を返す（現在メモリにロード中のモデル一覧）。
    update_embedding_index.pyが「このジョブ自身がモデルをロードしたのか、対話セッション
    側で既にロード済みだったのか」を判定してkeep_alive:0の要否を決めるために使う
    （リーダー実機実測対応・2026-07-11後半・Codexレビュー指摘・Major: 毎時ジョブが
    対話セッション用に予熱済みのモデルまでアンロードしてしまうと、次の想起フックが
    コールドロードになり500ms予算を圧迫する）。
    通信/JSON異常はそのまま例外を伝播させる（呼び出し側でfail-open判断に使う）。
    fetcher(url, timeout) -> dict を差し替えるとテストでHTTPを完全モックできる。
    """
    fetcher = fetcher or _http_get_json
    return fetcher(f"{base_url}/api/ps", timeout)


def model_loaded_in_ps(ps_data, model):
    """fetch_ollama_ps()の戻り値からmodelが現在ロード済みかを返す。"""
    if not isinstance(ps_data, dict):
        return False
    for m in ps_data.get("models", []) or []:
        if not isinstance(m, dict):
            continue
        if m.get("name") == model or m.get("model") == model:
            return True
    return False


def ollama_embed(texts, model=DEFAULT_MODEL, base_url=DEFAULT_BASE_URL, timeout=30.0, fetcher=None,
                  keep_alive=None):
    """texts(list[str])と同じ順序・件数の埋め込みベクトル(list[list[float]])を返す。

    重要（リーダー実機検証で確定・2026-07-11・Ollama 0.31.1・qwen3-embedding:0.6b）:
    Ollamaの`/api/embed`は input が配列（バッチ）の場合 truncate:true を適用しない
    実装になっており、長文アイテムが1件でも含まれると（配列の要素数が1件であっても）
    400を返す。input が文字列（単一）の場合はtruncateが正しく機能する（20,000字でも
    200になることを確認済み）。そのため本関数は内部で必ず「1件ずつ文字列inputとして
    個別にHTTPリクエストする」実装にし、複数件をまとめて1回のリクエストへ詰める配列
    送信は一切行わない（過去に配列送信の実装があったが、この仕様により長文ノートで
    恒常的に400が発生することが判明し廃止した＝**復活させないこと**。呼び出し側の
    署名(list in/list out)は変えず、内部実装だけをこの制約に適合させている）。
    件数が多い場合はHTTP往復が増えるが、Vault規模（数百ノート程度・毎時差分更新は
    通常わずか数件）では実用上問題にならない（KISS優先＝リーダー指示）。

    追加で確定した機序（リーダー実機検証・2026-07-11後半・EMBED_NUM_CTX/EMBED_NUM_BATCH
    参照）: 1件ずつ文字列inputへ切り替えた後も、Ollamaの既定n_batch(2048)を超える
    トークン数のノートで400になる事象が残っていた。原因はOllamaが埋め込みモデルを
    既定n_ctx=4096・n_batch=2048で起動しており、埋め込み（非因果的処理のため入力
    全体を1バッチで処理する必要がある）で未キャッシュトークン数がn_batchを超えると
    400になるため（さらにプロンプトキャッシュの残留により同一入力の成否が試行ごとに
    入れ替わって見える非決定性も確認済み）。options.num_ctx/num_batchを明示指定する
    ことで決定的に解決するため、全リクエストに付与する。

    keep_alive（リーダー実機実測・2026-07-11後半追加）: Noneなら省略しOllama側の既定
    keep_alive（対話中の再ロード防止のため既定のまま維持したい想起フック用）に任せる。
    0を渡すとサーバへ`"keep_alive": 0`を伝え、このリクエスト処理後にモデルを即座に
    アンロードさせる（毎時インデクサジョブがoptions.num_ctx=8192等により6.7GB前後を
    5分間（Ollama既定keep_alive）専有し続けるのを防ぐため、update_embedding_index.py
    が実行内の最後の埋め込みリクエストにのみ指定する。想起フック側では指定しない
    ＝既定のまま）。texts内の全itemに同じkeep_aliveを適用する（呼び出し側は基本的に
    1件ずつ渡す運用のため実質的に1リクエストにのみ影響する）。

    fetcher(url, payload, timeout) -> dict を差し替えるとHTTPを完全モックできる
    （依存注入・単体テスト用。1回のfetcher呼び出し = テキスト1件に対応する）。
    通信/JSON/応答形式の異常はそのまま例外(urllib.error.*/OSError/ValueError/
    json.JSONDecodeError)を伝播させる（呼び出し側がfail-open/fail-closedを判断する）。
    """
    if not texts:
        return []
    fetcher = fetcher or _http_post_json
    results = []
    for text in texts:
        payload = {
            "model": model,
            "input": text,  # 配列にしない（ヘッダコメント参照）
            "truncate": True,
            "options": {"num_ctx": EMBED_NUM_CTX, "num_batch": EMBED_NUM_BATCH},
        }
        if keep_alive is not None:
            payload["keep_alive"] = keep_alive
        data = fetcher(f"{base_url}/api/embed", payload, timeout)
        if not isinstance(data, dict):
            raise ValueError(f"Ollama /api/embed の応答が不正です（オブジェクトではありません）: {str(data)[:200]}")
        embeddings = data.get("embeddings")
        if not isinstance(embeddings, list) or len(embeddings) != 1:
            raise ValueError(
                f"Ollama /api/embed の応答が不正です（embeddings件数不一致・"
                f"期待=1 実測={len(embeddings) if isinstance(embeddings, list) else 'N/A'}）")
        results.append(embeddings[0])
    return results


# --- 類似度計算 ---------------------------------------------------------------

def cosine_similarity(a, b):
    """cosine類似度。ゼロベクトル同士/片方がゼロベクトルの場合は0.0を返す
    （0除算回避。破損データでの例外よりfail-openを優先）。"""
    dot = 0.0
    norm_a = 0.0
    norm_b = 0.0
    for x, y in zip(a, b):
        dot += x * y
        norm_a += x * x
        norm_b += y * y
    if norm_a <= 0.0 or norm_b <= 0.0:
        return 0.0
    return dot / ((norm_a ** 0.5) * (norm_b ** 0.5))


# --- インデックス表現 ----------------------------------------------------------

class Index:
    """読込済みインデックス（1世代分）。vectors はnotesと同じ順序のarray.array('f')。"""

    def __init__(self, generation, model, model_digest, dim, notes, vectors,
                 num_ctx=None, num_batch=None, truncated_notes=None):
        self.generation = generation
        self.model = model
        self.model_digest = model_digest
        self.dim = dim
        self.notes = notes  # [{"relpath": ..., "content_hash": ...}, ...]
        self._vectors = vectors
        self.num_ctx = num_ctx            # expected_num_ctx/expected_num_batch未指定で
        self.num_batch = num_batch        # load_index()を呼んだ場合は検証されないため、
        self.truncated_notes = truncated_notes or []  # 理論上はNoneのままにもなり得る
        # （load_index()呼び出し側の裁量。一方truncated_notesはschema v3の
        # _load_index_once()で常に文字列の配列であることを検証済みのためNoneには
        # ならないが、Index単体でのテスト用直接構築（Noneを渡すケース）にも備えて
        # ここでも空リストへフォールバックしておく）。

    def __len__(self):
        return len(self.notes)

    def vector(self, i):
        """i番目のノートのベクトルをarray.array('f')のスライスとして返す。"""
        start = i * self.dim
        return self._vectors[start:start + self.dim]


# --- インデックス書込 ----------------------------------------------------------

def new_generation_id():
    """新しい世代ディレクトリ名を返す（時刻昇順=文字列昇順になるよう固定長timestamp
    ＋pidを付与。同一プロセス内での衝突は起きない＝1回のCLI実行で1世代しか書かない）。"""
    ts = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    return f"gen-{ts}-{os.getpid()}"


def write_generation(root, gen_id, model, model_digest, dim, notes_with_vectors,
                      num_ctx=None, num_batch=None, truncated_notes=None):
    """notes_with_vectors: [(relpath, content_hash, vector), ...]。この順序がそのまま
    vectors.binの格納順＝meta.jsonのnotes順になる（呼び出し側が「現存ファイル一覧」の
    順序で渡すことで、削除済みノートは自然に除外される＝設計書§2.2）。
    一時ディレクトリに完全に書き終えてから最終名へrenameする（CURRENT更新前なので
    この時点ではどの読み手からも参照されていない＝部分書込を見せる心配がない）。

    num_ctx/num_batch（2026-07-11リーダー指示）: この世代を構築した際のOllama options
    値をメタデータへ記録する。load_index()のexpected_num_ctx/expected_num_batchと
    比較することで、既定値変更（例: 8192→4096）や環境変数上書きの変更を検知して
    フルリビルドへ倒せる（model/model_digestの検証と同じ考え方）。Noneの場合は
    embedding_index.EMBED_NUM_CTX/EMBED_NUM_BATCH（現在の設定）を使う。

    truncated_notes（2026-07-11リーダー指示）: この世代でtruncateされた可能性が高いと
    判定されたノートのrelpath一覧（is_likely_truncated()参照）。観測用途のみで
    読込検証には使わない。Noneなら空リストとして記録する。
    """
    root = pathlib.Path(root)
    root.mkdir(parents=True, exist_ok=True)
    tmp_dir = root / f"{gen_id}.tmp-{os.getpid()}"
    if tmp_dir.exists():
        shutil.rmtree(tmp_dir, ignore_errors=True)
    tmp_dir.mkdir(parents=True)

    notes_meta = []
    flat = array.array(VECTOR_DTYPE)
    for relpath, chash, vector in notes_with_vectors:
        if len(vector) != dim:
            shutil.rmtree(tmp_dir, ignore_errors=True)
            raise ValueError(f"ベクトル次元が不一致です（{relpath}: {len(vector)} != {dim}）")
        notes_meta.append({"relpath": relpath, "content_hash": chash})
        flat.extend(float(x) for x in vector)

    (tmp_dir / "vectors.bin").write_bytes(flat.tobytes())
    meta = {
        "schema_version": SCHEMA_VERSION,
        "model": model,
        "model_digest": model_digest,
        "dim": dim,
        "count": len(notes_meta),
        "created_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "num_ctx": num_ctx if num_ctx is not None else EMBED_NUM_CTX,
        "num_batch": num_batch if num_batch is not None else EMBED_NUM_BATCH,
        "truncated_notes": sorted(truncated_notes) if truncated_notes else [],
        "notes": notes_meta,
    }
    (tmp_dir / "meta.json").write_text(json.dumps(meta, ensure_ascii=False), encoding="utf-8")

    final_dir = root / gen_id
    if final_dir.exists():
        shutil.rmtree(final_dir, ignore_errors=True)
    os.rename(str(tmp_dir), str(final_dir))
    return final_dir


def publish_current(root, gen_id):
    """CURRENTポインタをos.replaceで原子更新する（設計書§2.2）。一時ファイルに書いてから
    置き換えるため、更新途中の中途半端な内容が読み手に見えることはない。"""
    root = pathlib.Path(root)
    tmp = root / f".CURRENT.tmp-{os.getpid()}"
    tmp.write_text(gen_id, encoding="utf-8")
    os.replace(str(tmp), str(root / "CURRENT"))


def prune_old_generations(root, keep=DEFAULT_KEEP_GENERATIONS, now=None):
    """直近keep世代（既定3）より古いgen-*ディレクトリを削除する（設計書§2.2「直近3世代
    以上保持」）。世代名は先頭が固定長timestampのため文字列昇順=時刻昇順。
    クラッシュ等で消し残った一時ディレクトリ(*.tmp-*)は、実行中の別プロセスのものを
    誤って消さないよう十分な猶予(1時間)を置いてbest-effortで掃除する。

    CURRENTが指す世代は、文字列ソート上の位置に関わらず常に保護し削除しない
    （Codexレビュー指摘・Major: 時計が後退した状態で新世代をpublishすると、文字列順
    では最古になり得てpruneで消えてしまう）。keepは最低1にclampする（0以下を渡すと
    CURRENT自体が消えかねないため）。
    """
    root = pathlib.Path(root)
    if not root.is_dir():
        return
    keep = max(int(keep), 1)
    if now is None:
        now = time.time()

    current_gen = None
    try:
        current_gen = (root / "CURRENT").read_text(encoding="utf-8").strip()
    except OSError:
        current_gen = None

    generations = []
    for p in root.iterdir():
        if not p.is_dir():
            continue
        name = p.name
        if ".tmp-" in name:
            try:
                age = now - p.stat().st_mtime
            except OSError:
                continue
            if age > 3600:
                shutil.rmtree(p, ignore_errors=True)
            continue
        if name.startswith("gen-"):
            generations.append(p)
    generations.sort(key=lambda p: p.name)
    if len(generations) > keep:
        for p in generations[:len(generations) - keep]:
            if current_gen and p.name == current_gen:
                continue  # CURRENTが指す世代は無条件で保護する
            shutil.rmtree(p, ignore_errors=True)


# --- インデックス読込（検証込み） ------------------------------------------------

def _load_index_once(root, expected_model, expected_model_digest, expected_num_ctx=None, expected_num_batch=None):
    root = pathlib.Path(root)
    current_path = root / "CURRENT"
    if not current_path.is_file():
        raise IndexError_(f"CURRENTポインタがありません（未初期化）: {current_path}")
    try:
        gen_name = current_path.read_text(encoding="utf-8").strip()
    except OSError as e:
        raise IndexError_(f"CURRENTポインタの読込に失敗しました: {e}") from e
    # gen_nameをパス要素として直接使うため、パストラバーサル的な値を厳密に拒否する
    # （壊れた/改ざんされたCURRENTでroot外を指させない防御・Codexレビュー指摘Critical:
    # "/"や".."の単純拒否だけでは不十分。new_generation_id()が生成する形式
    # "gen-<timestamp>-<pid>"に厳密一致するもの以外は一律拒否する）。
    if not GEN_NAME_RE.match(gen_name):
        raise IndexError_(f"CURRENTポインタの内容が不正です（gen-<timestamp>-<pid>形式ではありません）: {gen_name!r}")
    gen_dir = root / gen_name
    # 世代ディレクトリ自体がsymlinkでない・解決後もindex root配下であることを確認する
    # （改ざんされたindex_dirがroot外のディレクトリへのsymlinkにすり替えられていても
    # 追従しない・Codexレビュー指摘Critical）。
    if gen_dir.is_symlink():
        raise IndexError_(f"世代ディレクトリがsymlinkです（許可しません）: {gen_dir}")
    try:
        resolved_root = root.resolve()
        resolved_gen_dir = gen_dir.resolve()
        resolved_gen_dir.relative_to(resolved_root)
    except (OSError, ValueError) as e:
        raise IndexError_(f"世代ディレクトリがindex root配下ではありません: {gen_dir}（{e}）") from e
    meta_path = gen_dir / "meta.json"
    vec_path = gen_dir / "vectors.bin"
    if meta_path.is_symlink() or vec_path.is_symlink():
        raise IndexError_(f"meta.json/vectors.binがsymlinkです（許可しません）: {gen_dir}")
    if not meta_path.is_file() or not vec_path.is_file():
        raise IndexError_(f"世代ディレクトリが不完全です（meta.json/vectors.binが揃っていません）: {gen_dir}")
    try:
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        raise IndexError_(f"meta.jsonの読込/解析に失敗しました: {e}") from e
    if not isinstance(meta, dict):
        raise IndexError_("meta.jsonの形式が不正です（オブジェクトではありません）")

    schema_version = meta.get("schema_version")
    if schema_version != SCHEMA_VERSION:
        raise IndexError_(f"schema_versionが不一致です（index={schema_version!r} expected={SCHEMA_VERSION}）")

    model = meta.get("model")
    model_digest = meta.get("model_digest")
    dim = meta.get("dim")
    notes = meta.get("notes")
    count = meta.get("count")

    if not isinstance(dim, int) or dim <= 0:
        raise IndexError_(f"dimが不正です: {dim!r}")
    if not isinstance(notes, list):
        raise IndexError_("notesの形式が不正です（配列ではありません）")
    if not isinstance(count, int) or count != len(notes):
        raise IndexError_(f"件数が不整合です（meta.count={count!r} len(notes)={len(notes)}）")
    seen_relpaths = set()
    for n in notes:
        if not isinstance(n, dict) or not isinstance(n.get("relpath"), str) or not isinstance(n.get("content_hash"), str):
            raise IndexError_("notes内の要素形式が不正です")
        if not is_valid_relpath(n["relpath"]):
            raise IndexError_(f"notes内のrelpathが安全な形式ではありません（絶対パス/../脱出等の可能性）: {n['relpath']!r}")
        # 重複relpathはfail-closed（IndexError_）で拒否する（Codexレビュー指摘・Major:
        # write_generation()が呼び出し元の順序をそのまま書くだけでrelpathの一意性を
        # 強制していないため、通常運用ではlist_vault_notes()の一意な走査結果しか渡らない
        # が、破損/改ざんされたmeta.jsonでは重複が混入し得る）。truncated_notes側の
        # 重複チェック（このすぐ下の別ブロック・下方参照）と同じ「メタデータの構造的
        # 整合性はfail-closedで検証する」流儀に揃える。重複を黙って一意化する対応も
        # 検討したが、vectors.binの並び順=notesの並び順であるIndex.vector(i)の実装上、
        # 同一relpathに対して意味の異なる複数のベクトルが存在すること自体が「どちらが
        # 正か決められない」矛盾したデータであり、機械的な一意化（例:
        # 最初/最後の出現を採用）では読み手が気づかないまま不定の結果を返しかねない。
        # symlink/パストラバーサル拒否と同様、Critical寄りの構造検証としてここで
        # 早期にrejectする（呼び出し側=vector_recall_helper.pyはIndexError_を捕捉して
        # fail-openするため、検索側fail-openの制約は破らない）。
        if n["relpath"] in seen_relpaths:
            raise IndexError_(f"notesに重複したrelpathが含まれています: {n['relpath']!r}")
        seen_relpaths.add(n["relpath"])

    if expected_model is not None and model != expected_model:
        raise IndexError_(f"modelが設定と一致しません（index={model!r} expected={expected_model!r}）")
    if expected_model_digest is not None and model_digest != expected_model_digest:
        raise IndexError_(f"model_digestが一致しません（index={model_digest!r} expected={expected_model_digest!r}）")

    num_ctx = meta.get("num_ctx")
    num_batch = meta.get("num_batch")
    # truncated_notesはschema_version>=3で必須フィールドとする（Codexレビュー指摘・
    # Minor: この関数の冒頭で既にschema_version != SCHEMA_VERSIONを拒否しているため、
    # ここに到達した時点でschema v3であることが保証されている。v3のwriter
    # (write_generation)は常にtruncated_notesを配列として書き出すため、欠如やnullは
    # 「truncated_notes導入前の旧世代との互換」ではなく破損/改ざんとして扱うべき
    # ＝欠如・null・非配列・非文字列要素のいずれもIndexError_にする。schema v2以前
    # との互換読込みは冒頭のschema_versionチェックで既に拒否されるため考慮不要）。
    truncated_notes = meta.get("truncated_notes")
    if not (isinstance(truncated_notes, list) and all(isinstance(t, str) for t in truncated_notes)):
        raise IndexError_("truncated_notesの形式が不正です（欠如／nullを含め、文字列の配列である必要があります）")
    # truncated_notesは観測用途のみ（アクセス制御には使わない）だが、メタデータの
    # 信頼性を保つため中身も検証する（Codexレビュー指摘・Minor: 不正relpath/重複/
    # notes配列に存在しないrelpathを無検証で受理していた）。is_valid_relpath()の
    # チェックはnotes内の各relpathと同じ基準を流用し、さらにnotesのrelpath集合の
    # 部分集合であることも確認する。
    for t in truncated_notes:
        if not is_valid_relpath(t):
            raise IndexError_(f"truncated_notes内のrelpathが安全な形式ではありません: {t!r}")
    if len(set(truncated_notes)) != len(truncated_notes):
        raise IndexError_("truncated_notesに重複したrelpathが含まれています")
    note_relpaths = {n["relpath"] for n in notes}
    unknown = sorted(set(truncated_notes) - note_relpaths)
    if unknown:
        raise IndexError_(f"truncated_notesにnotesへ存在しないrelpathが含まれています: {unknown!r}")
    # num_ctx/num_batchの不一致でフルリビルドへ倒す（2026-07-11リーダー指示: 既定値
    # 変更や環境変数上書きの変更を検知する仕組み。model/model_digestと同じ考え方。
    # 旧形式(このフィールドが無い世代)は「不一致」として扱う＝安全側でリビルドを促す）。
    if expected_num_ctx is not None and num_ctx != expected_num_ctx:
        raise IndexError_(f"num_ctxが設定と一致しません（index={num_ctx!r} expected={expected_num_ctx!r}）")
    if expected_num_batch is not None and num_batch != expected_num_batch:
        raise IndexError_(f"num_batchが設定と一致しません（index={num_batch!r} expected={expected_num_batch!r}）")

    try:
        raw = vec_path.read_bytes()
    except OSError as e:
        raise IndexError_(f"vectors.binの読込に失敗しました: {e}") from e
    expected_bytes = len(notes) * dim * VECTOR_ITEMSIZE
    if len(raw) != expected_bytes:
        raise IndexError_(
            f"vectors.binのバイト長が不整合です（実測={len(raw)} 期待={expected_bytes}"
            f"・件数={len(notes)}・dim={dim}）")
    vectors = array.array(VECTOR_DTYPE)
    try:
        vectors.frombytes(raw)
    except (ValueError, OverflowError) as e:
        raise IndexError_(f"vectors.binの解析に失敗しました: {e}") from e

    return Index(gen_name, model, model_digest, dim, notes, vectors,
                 num_ctx=num_ctx, num_batch=num_batch, truncated_notes=truncated_notes)


def load_index(root=None, expected_model=None, expected_model_digest=None, retries=1,
                expected_num_ctx=None, expected_num_batch=None):
    """CURRENTが指す世代を読み込み検証する。失敗時は最大retries回（既定1回）
    CURRENTから読み直す（設計書§2.2「不整合はCURRENT再読込1回→失敗ならfail-open」）。
    全て失敗すればIndexError_を送出する（呼び出し側の責務でfail-open/フルリビルド判定）。
    expected_num_ctx/expected_num_batch: 指定するとmeta.jsonのnum_ctx/num_batchと比較し、
    不一致（旧形式で当該フィールドが無い場合を含む）ならIndexError_にする
    （update_embedding_index.pyがEMBED_NUM_CTX/EMBED_NUM_BATCHの変更を検知して
    フルリビルドへ倒すために使う。想起フック側は通常渡さない＝既存インデックスの
    dim不一致で自然にfail-openされるため、追加のHTTP往復無しに済む既存の設計を維持）。
    """
    root = index_root(root)
    last_err = IndexError_("インデックスが見つかりません")
    for _ in range(max(1, retries + 1)):
        try:
            return _load_index_once(root, expected_model, expected_model_digest,
                                     expected_num_ctx=expected_num_ctx, expected_num_batch=expected_num_batch)
        except IndexError_ as e:
            last_err = e
            continue
    raise last_err
