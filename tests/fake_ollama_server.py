#!/usr/bin/env python3
"""テスト専用の偽Ollamaサーバ（scripts/vault-agents/update_embedding_index.py・
vector_recall_helper.pyのCLIレベルテストが実HTTPを叩けるようにするための固定機能。

実Ollamaへは一切依存しない（依存注入でモックする設計書§4の方針を、HTTPクライアント
の外側=CLI境界でも守るため、標準ライブラリhttp.serverだけで最小のスタブを立てる）。

対応エンドポイント:
  GET  /api/tags   -> {"models": [{"name": MODEL, "model": MODEL, "digest": DIGEST}]}
  POST /api/embed  -> {"embeddings": [vector(text) for text in input]}

埋め込みベクトルは「決定的なマーカーベクトル」方式（テストが結果を予測できるように
するため）: 入力テキストに `__MARK_<name>__` という形式のマーカー文字列が含まれていれば、
そのマーカー専用の次元に1.0を立てる。複数のテキストで同じマーカーを共有していれば
cosine類似度はほぼ1.0、マーカーを共有しなければほぼ0になる。マーカーを含まないテキスト
はhashベースの小さなノイズのみ（ゼロベクトル回避）。

環境変数:
  FAKE_OLLAMA_MODEL        既定 qwen3-embedding:0.6b
  FAKE_OLLAMA_DIGEST       既定 fakedigest123
  FAKE_OLLAMA_DIM          既定 16
  FAKE_OLLAMA_FAIL_TAGS    1なら /api/tags を500にする
  FAKE_OLLAMA_FAIL_EMBED   1なら /api/embed を常に500にする
  FAKE_OLLAMA_FAIL_EMBED_FIRST_N  指定件数だけ/api/embedへの最初のN回のリクエストを
                                  500にし、それ以降は成功させる（retry+backoffが実際に
                                  「途中から回復したら成功する」ことを検証するため）
  FAKE_OLLAMA_DELAY_MS     /api/embed応答前に指定msだけ待つ（timeoutテスト用）
  FAKE_OLLAMA_MAX_ITEM_CHARS  既定1000。/api/embedの「配列(バッチ)inputにtruncateが
                              適用されない」という実Ollama 0.31.1の挙動を疑似再現する
                              閾値（下記(1)参照）。
  FAKE_OLLAMA_NBATCH_CHARS    既定2000。「n_batch(既定2048)を超えるトークン数の入力は
                              400」という実Ollama挙動を疑似再現する閾値（下記(2)参照）。
  FAKE_OLLAMA_REQUIRED_NUM_BATCH  既定4096。options.num_batchがこの値以上でなければ
                              (2)の400が発生する。
  FAKE_OLLAMA_REQUIRED_NUM_CTX  既定4096。options.num_ctxがこの値以上でなければ
                              (2)の400が発生する（num_batchとは独立に検証・
                              どちらか一方だけの指定漏れも検知できるようにする）。
  FAKE_OLLAMA_LOG_REQUESTS    指定したパスへ、受信した/api/embedのpayload(JSON)を
                              1行1件で追記する（診断用。呼出順序・keep_alive等の
                              リクエストごとの違いをテストから検証できるようにする）。
  FAKE_OLLAMA_PS_LOADED       1なら GET /api/ps がモデル既ロード済みとして応答する
                              （update_embedding_index.pyのshould_unload_after_run判定
                              テスト用。既定は「何もロードされていない」を返す）。
  FAKE_OLLAMA_FAIL_IF_CONTAINS  指定文字列をinputに含むリクエストだけ常に500にする
                              （retryを使い切っても回復しない恒久失敗を、特定ノートに
                              限定して再現するため）。

実Ollama挙動の疑似再現（リーダー実機検証で確定・2026-07-11）:
(1) /api/embedのinputが配列（バッチ）の場合、Ollamaはtruncate:trueを適用せず、要素が
    1件でもFAKE_OLLAMA_MAX_ITEM_CHARSを超える長さならHTTP 400を返す（`do embedding
    request: ...`相当のエラー文言）。inputが文字列（単一）の場合はtruncateが機能する
    ため、どんな長さでも200を返す。この非対称性のため、scripts/vault-agents/
    embedding_index.py の ollama_embed() は常に1件ずつ文字列inputとして送るよう
    実装されている（配列送信は行わない・行ってはいけない）。
(2) さらに、文字列inputへ切り替えた後も別の機序で400が残っていた: Ollamaは埋め込み
    モデルを既定 n_ctx=4096・n_batch=2048 で起動しており、埋め込み（非因果的処理の
    ため入力全体を1バッチで処理する必要がある）で未キャッシュのトークン数が
    n_batch(2048)を超えると400になる（サーバログ実測: task.n_tokens=3136を
    cached 2048で分割しようとして400）。加えてプロンプトキャッシュの残留により
    同一入力の成否が試行ごとに入れ替わって見える非決定性も確認済み。
    options.num_ctx/num_batchを明示指定（既定8192/8192）することで決定的に解決する
    ため、embedding_index.ollama_embed()は全リクエストにoptionsを付与している。
本サーバはこの(1)(2)両方を再現することで、将来コードが配列バッチ送信へ退行したり
options指定を落としたりした場合に、test-update-embedding-index.sh /
test-vector-recall-helper.sh 側の長文ノート/長文クエリを使ったテストで確実に検知
できるようにする。

引数: ポート番号（0で自動割当）。実際に割り当てたポート番号を標準出力へ1行で書いて
起動する（呼び出し側はこの行を読んでbase-urlを組み立てる）。
"""
import hashlib
import http.server
import json
import os
import sys
import time

MODEL = os.environ.get("FAKE_OLLAMA_MODEL", "qwen3-embedding:0.6b")
DIGEST = os.environ.get("FAKE_OLLAMA_DIGEST", "fakedigest123")
DIM = int(os.environ.get("FAKE_OLLAMA_DIM", "16"))
FAIL_TAGS = os.environ.get("FAKE_OLLAMA_FAIL_TAGS") == "1"
PS_LOADED = os.environ.get("FAKE_OLLAMA_PS_LOADED") == "1"
FAIL_IF_CONTAINS = os.environ.get("FAKE_OLLAMA_FAIL_IF_CONTAINS", "")
FAIL_EMBED = os.environ.get("FAKE_OLLAMA_FAIL_EMBED") == "1"
DELAY_MS = int(os.environ.get("FAKE_OLLAMA_DELAY_MS", "0"))
MAX_ITEM_CHARS = int(os.environ.get("FAKE_OLLAMA_MAX_ITEM_CHARS", "1000"))
NBATCH_CHARS = int(os.environ.get("FAKE_OLLAMA_NBATCH_CHARS", "2000"))
REQUIRED_NUM_BATCH = int(os.environ.get("FAKE_OLLAMA_REQUIRED_NUM_BATCH", "4096"))
REQUIRED_NUM_CTX = int(os.environ.get("FAKE_OLLAMA_REQUIRED_NUM_CTX", "4096"))
FAIL_EMBED_FIRST_N = int(os.environ.get("FAKE_OLLAMA_FAIL_EMBED_FIRST_N", "0"))
LOG_REQUESTS_PATH = os.environ.get("FAKE_OLLAMA_LOG_REQUESTS")
_embed_call_count = 0  # HTTPServer(非Threading)は単一プロセス・単一スレッドで捌くため排他不要

MARK_PREFIX = "__MARK_"
MARK_SUFFIX = "__"


def vector_for(text):
    vec = [0.0] * DIM
    marked = False
    i = 0
    while True:
        start = text.find(MARK_PREFIX, i)
        if start < 0:
            break
        end = text.find(MARK_SUFFIX, start + len(MARK_PREFIX))
        if end < 0:
            break
        name = text[start:end + len(MARK_SUFFIX)]
        idx = int(hashlib.md5(name.encode()).hexdigest(), 16) % DIM
        vec[idx] = 1.0
        marked = True
        i = end + len(MARK_SUFFIX)
    if not marked:
        h = hashlib.md5(text.encode()).digest()
        for j in range(DIM):
            vec[j] += ((h[j % len(h)] / 255.0) - 0.5) * 0.01
    return vec


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # noqa: A003 - stderrへのログを無効化(テスト出力を汚さない)
        pass

    def _send_json(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        if self.path == "/api/tags":
            if FAIL_TAGS:
                self._send_json(500, {"error": "fake tags failure"})
                return
            self._send_json(200, {"models": [{"name": MODEL, "model": MODEL, "digest": DIGEST}]})
            return
        if self.path == "/api/ps":
            # update_embedding_index.pyがkeep_alive:0を送るべきか（このジョブ自身が
            # モデルをロードしたのか、対話セッション側で既にロード済みだったのか）を
            # 判定するために叩く。既定は「何もロードされていない」（models: []）で、
            # FAKE_OLLAMA_PS_LOADED=1なら対象モデルが既にロード済みであるかのように
            # 応答する（should_unload_after_run=Falseになるケースを再現するため）。
            if PS_LOADED:
                self._send_json(200, {"models": [{"name": MODEL, "model": MODEL}]})
            else:
                self._send_json(200, {"models": []})
            return
        self._send_json(404, {"error": "not found"})

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            payload = {}
        if self.path == "/api/embed":
            if LOG_REQUESTS_PATH:
                try:
                    with open(LOG_REQUESTS_PATH, "a", encoding="utf-8") as f:
                        f.write(json.dumps(payload, ensure_ascii=False) + "\n")
                except OSError:
                    pass  # 診断用ログの書込失敗でリクエスト処理自体は妨げない
            if FAIL_EMBED:
                self._send_json(500, {"error": "fake embed failure"})
                return
            if FAIL_IF_CONTAINS and FAIL_IF_CONTAINS in json.dumps(payload.get("input", "")):
                # 特定の内容を含むリクエストだけ恒久的に失敗させる（retryを使い切っても
                # 回復しないケースを再現するため。「途中のノートで恒久失敗した場合の
                # モデルアンロード後始末」のテスト用＝FAKE_OLLAMA_LOG_REQUESTSと併用）。
                self._send_json(500, {"error": "fake embed failure (matched FAIL_IF_CONTAINS)"})
                return
            if FAIL_EMBED_FIRST_N > 0:
                global _embed_call_count
                _embed_call_count += 1
                if _embed_call_count <= FAIL_EMBED_FIRST_N:
                    self._send_json(500, {"error": f"fake embed failure ({_embed_call_count}/{FAIL_EMBED_FIRST_N})"})
                    return
            if DELAY_MS:
                time.sleep(DELAY_MS / 1000.0)
            raw_input = payload.get("input")
            is_array = isinstance(raw_input, list)
            if is_array:
                inputs = raw_input
            elif isinstance(raw_input, str):
                inputs = [raw_input]
            else:
                inputs = []

            # 実Ollama 0.31.1の挙動を疑似再現(1): 配列(バッチ)inputはtruncateが効かず、
            # 長文アイテムが1件でもあれば（配列の要素数が1件でも）400になる。文字列
            # input（単一）はtruncate相当が常に機能し、どんな長さでも成功する
            # （モジュールdocstring(1)参照）。
            if is_array and any(isinstance(t, str) and len(t) > MAX_ITEM_CHARS for t in inputs):
                self._send_json(400, {
                    "error": "do embedding request: simulated EOF (array input does not truncate; "
                              "see tests/fake_ollama_server.py FAKE_OLLAMA_MAX_ITEM_CHARS)"})
                return

            # 実Ollama挙動の疑似再現(2): n_batch(既定2048)を超えるトークン数(疑似的に
            # 文字数で代用)の入力は、options.num_ctx/num_batchの**両方**を十分な値で
            # 明示しない限り400になる（モジュールdocstring(2)参照）。配列/文字列
            # どちらのinputでも起こる事象のため、is_arrayに関わらずここでチェックする。
            # num_batchだけでなくnum_ctxも独立に検証する（Codexレビュー指摘・Minor:
            # num_ctxだけが実装から抜け落ちる退行を検知できるようにするため）。
            options = payload.get("options") if isinstance(payload.get("options"), dict) else {}
            num_batch = options.get("num_batch")
            num_ctx = options.get("num_ctx")
            has_sufficient_options = (
                isinstance(num_batch, int) and num_batch >= REQUIRED_NUM_BATCH
                and isinstance(num_ctx, int) and num_ctx >= REQUIRED_NUM_CTX
            )
            if not has_sufficient_options and any(isinstance(t, str) and len(t) > NBATCH_CHARS for t in inputs):
                self._send_json(400, {
                    "error": "do embedding request: simulated EOF (n_batch/n_ctx insufficient; "
                              "see tests/fake_ollama_server.py FAKE_OLLAMA_NBATCH_CHARS/"
                              "FAKE_OLLAMA_REQUIRED_NUM_BATCH/FAKE_OLLAMA_REQUIRED_NUM_CTX)"})
                return

            self._send_json(200, {"embeddings": [vector_for(t) for t in inputs]})
            return
        self._send_json(404, {"error": "not found"})


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    server = http.server.HTTPServer(("127.0.0.1", port), Handler)
    print(server.server_port, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
