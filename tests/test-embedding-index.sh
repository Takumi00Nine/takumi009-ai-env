#!/usr/bin/env bash
# scripts/vault-agents/embedding_index.py のユニットテスト（共有モジュール本体）。
#
# embedding_index.py はCLIを持たない純粋なライブラリのため、他のtest-*.shのように
# subprocessでCLIを叩く形にはできない。本テストは1本のpython3スクリプトとして
# 全アサーションを実行する（repo慣習のpass/fail集計・summary行はpython側で再現する）。
# Ollama通信はfetcher引数の依存注入で完全にモックする（実HTTP・実Ollamaに一切
# 依存しない＝設計書§4「Ollama HTTPは依存注入でモック」）。ファイルI/O系
# （write_generation/publish_current/load_index/prune_old_generations）はtempディレクトリ
# のみを使う。
#
# 実行方法: bash tests/test-embedding-index.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

python3 "$REPO_ROOT/scripts/vault-agents/embedding_index.py" >/dev/null 2>&1
# ↑モジュール自体は直接実行してもno-op（CLIエントリポイントを持たない設計の確認・
#   importエラーが無いことのスモークチェック）。

python3 - "$REPO_ROOT" <<'PYEOF'
import sys, pathlib, tempfile, shutil, json, array

repo_root = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(repo_root / "scripts" / "vault-agents"))
import embedding_index as ei

PASS = 0
FAIL = 0


def ok(desc):
    global PASS
    PASS += 1
    print(f"  ok - {desc}")


def ng(desc, detail=""):
    global FAIL
    FAIL += 1
    suffix = f" ({detail})" if detail else ""
    print(f"  NG - {desc}{suffix}")


def assert_eq(desc, expected, actual):
    if expected == actual:
        ok(desc)
    else:
        ng(desc, f"expected={expected!r} actual={actual!r}")


def assert_true(desc, cond, detail=""):
    if cond:
        ok(desc)
    else:
        ng(desc, detail)


def assert_raises(desc, exc_type, fn):
    try:
        fn()
    except exc_type:
        ok(desc)
    except Exception as e:  # noqa: BLE001
        ng(desc, f"期待した例外型と異なる: {type(e).__name__}: {e}")
    else:
        ng(desc, "例外が発生しなかった")


print("=== 1. content_hash: 決定的・内容が違えば異なる ===")
h1 = ei.content_hash("hello")
h2 = ei.content_hash("hello")
h3 = ei.content_hash("world")
assert_eq("同じ内容は同じhash", h1, h2)
assert_true("違う内容は異なるhash", h1 != h3)
assert_eq("sha256hexdigestは64文字", 64, len(h1))

print("=== 2. build_embedding_input: frontmatter除去・title+aliases+本文・コードブロック温存 ===")
text = """---
date: 2026-07-01
aliases:
  - "alias1"
  - "alias2"
---
# 見出し

本文です。

```python
def f():
    pass
```
"""
inp = ei.build_embedding_input("Knowledge/my-note.md", text)
assert_true("ファイル名由来のtitleが含まれる", "my-note" in inp)
assert_true("aliasesが含まれる", "alias1" in inp and "alias2" in inp)
assert_true("frontmatterのdate:行は除去される", "date: 2026-07-01" not in inp)
assert_true("コードブロックは温存される", "def f():" in inp)
assert_true("本文見出しも残る", "見出し" in inp)

print("=== 3. build_embedding_input: 20,000字heuristic truncate ===")
long_text = "---\naliases: []\n---\n" + ("あ" * 30000)
inp_long = ei.build_embedding_input("Knowledge/long.md", long_text)
assert_true("truncate_charsを超えない", len(inp_long) <= ei.TRUNCATE_CHARS, f"len={len(inp_long)}")

print("=== 3b. is_likely_truncated: truncate検知（2026-07-11リーダー指示・文字数ベース保守的判定） ===")
short_input = "短い本文です。" * 5
assert_true("短い入力はtruncate扱いにならない", not ei.is_likely_truncated(short_input, num_ctx=4096))
# num_ctx*CHARS_PER_TOKEN_CONSERVATIVE(既定1・実Vault較正で2から引き下げ済み)を
# 超える長さなら検知される。ちょうど閾値と同じ文字数でも、記号/Unicode文字等の
# tokenizer上の分割により実際には閾値を超えるトークン数になりうるため、境界値は
# 「以上」でtruncate扱いにする（Codexレビュー指摘・Major対応で`>`から`>=`へ変更）。
over_num_ctx_input = "あ" * (4096 * 1 + 1)
assert_true("num_ctx換算の文字数を超えるとtruncate検知される", ei.is_likely_truncated(over_num_ctx_input, num_ctx=4096))
just_at_threshold = "あ" * (4096 * 1)
assert_true("閾値ちょうどでも過検出側に倒してtruncate検知される（境界値・Codexレビュー指摘）",
            ei.is_likely_truncated(just_at_threshold, num_ctx=4096))
just_under = "あ" * (4096 * 1 - 1)
assert_true("閾値未満はtruncate検知されない", not ei.is_likely_truncated(just_under, num_ctx=4096))
# TRUNCATE_CHARS(20,000字)ちょうどに達している場合も検知される（build_embedding_input内部で
# 実際にheuristic truncateされたケースを表す）。
at_truncate_chars = "x" * ei.TRUNCATE_CHARS
assert_true("TRUNCATE_CHARSちょうどでも検知される（クライアント側truncate相当）",
            ei.is_likely_truncated(at_truncate_chars, num_ctx=999999))
assert_eq("num_ctx省略時はEMBED_NUM_CTXが使われる", ei.is_likely_truncated(short_input),
          ei.is_likely_truncated(short_input, num_ctx=ei.EMBED_NUM_CTX))

print("=== 4. list_vault_notes: README.md除外・存在しないフォルダはスキップ・ソート済み ===")
tmp_vault = pathlib.Path(tempfile.mkdtemp())
try:
    (tmp_vault / "Knowledge").mkdir()
    (tmp_vault / "Knowledge" / "b-note.md").write_text("b", encoding="utf-8")
    (tmp_vault / "Knowledge" / "a-note.md").write_text("a", encoding="utf-8")
    (tmp_vault / "Knowledge" / "README.md").write_text("readme", encoding="utf-8")
    (tmp_vault / "Preferences").mkdir()
    (tmp_vault / "Preferences" / "p.md").write_text("p", encoding="utf-8")
    # Personal/も想起対象（2026-07-11決定・[[Decisions/2026-07-11-personal-recall-scope]]・
    # 4→5フォルダ）に含まれることを確認する。
    (tmp_vault / "Personal").mkdir()
    (tmp_vault / "Personal" / "devices.md").write_text("device", encoding="utf-8")
    # Decisions/Projectsフォルダは意図的に作らない（存在しないフォルダのスキップ確認）
    notes = ei.list_vault_notes(tmp_vault)
    assert_eq("README.mdは含まれない", False, any("README" in n for n in notes))
    assert_eq("3フォルダ分・4件（Personal含む）",
              ["Knowledge/a-note.md", "Knowledge/b-note.md", "Personal/devices.md", "Preferences/p.md"], notes)
finally:
    shutil.rmtree(tmp_vault, ignore_errors=True)

print("=== 5. cosine_similarity ===")
assert_true("同一ベクトルは1.0に近い", abs(ei.cosine_similarity([1.0, 0.0], [1.0, 0.0]) - 1.0) < 1e-9)
assert_true("直交ベクトルは0.0", abs(ei.cosine_similarity([1.0, 0.0], [0.0, 1.0])) < 1e-9)
assert_eq("ゼロベクトルは0.0(0除算しない)", 0.0, ei.cosine_similarity([0.0, 0.0], [1.0, 1.0]))

print("=== 6. write_generation -> publish_current -> load_index の往復 ===")
idx_dir = pathlib.Path(tempfile.mkdtemp())
try:
    notes = [
        ("Knowledge/a.md", "hashA", [1.0, 0.0, 0.0]),
        ("Knowledge/b.md", "hashB", [0.0, 1.0, 0.0]),
    ]
    gen_id = ei.new_generation_id()
    assert_true("世代IDはgen-で始まる", gen_id.startswith("gen-"))
    ei.write_generation(idx_dir, gen_id, "modelX", "digestX", 3, notes)
    ei.publish_current(idx_dir, gen_id)
    assert_eq("CURRENTの中身は世代ID", gen_id, (idx_dir / "CURRENT").read_text(encoding="utf-8").strip())

    loaded = ei.load_index(idx_dir)
    assert_eq("読み込んだ件数", 2, len(loaded))
    assert_eq("model", "modelX", loaded.model)
    assert_eq("model_digest", "digestX", loaded.model_digest)
    assert_eq("dim", 3, loaded.dim)
    assert_eq("1件目のrelpath", "Knowledge/a.md", loaded.notes[0]["relpath"])
    v0 = list(loaded.vector(0))
    assert_true("1件目のベクトルが一致", abs(v0[0] - 1.0) < 1e-6 and abs(v0[1]) < 1e-6)

    # expected_model/expected_model_digestの検証
    ok_loaded = ei.load_index(idx_dir, expected_model="modelX", expected_model_digest="digestX")
    assert_eq("model一致条件つきでも読める", 2, len(ok_loaded))
    assert_raises("modelが不一致ならIndexError_", ei.IndexError_,
                  lambda: ei.load_index(idx_dir, expected_model="otherModel", retries=0))
    assert_raises("model_digestが不一致ならIndexError_", ei.IndexError_,
                  lambda: ei.load_index(idx_dir, expected_model_digest="otherDigest", retries=0))
finally:
    shutil.rmtree(idx_dir, ignore_errors=True)

print("=== 6b. write_generation/load_index: num_ctx/num_batch/truncated_notesのメタデータ（2026-07-11リーダー指示） ===")
idx_dir = pathlib.Path(tempfile.mkdtemp())
try:
    notes = [
        ("Knowledge/a.md", "hashA", [1.0, 0.0]),
        ("Knowledge/long-note.md", "hashB", [0.0, 1.0]),
    ]
    gen_id = ei.new_generation_id()
    ei.write_generation(idx_dir, gen_id, "modelX", "digestX", 2, notes,
                         num_ctx=4096, num_batch=4096, truncated_notes=["Knowledge/long-note.md"])
    ei.publish_current(idx_dir, gen_id)

    meta = json.loads((idx_dir / gen_id / "meta.json").read_text(encoding="utf-8"))
    assert_eq("meta.jsonにnum_ctxが記録される", 4096, meta["num_ctx"])
    assert_eq("meta.jsonにnum_batchが記録される", 4096, meta["num_batch"])
    assert_eq("meta.jsonにtruncated_notesが記録される", ["Knowledge/long-note.md"], meta["truncated_notes"])

    loaded = ei.load_index(idx_dir)
    assert_eq("Index.num_ctx", 4096, loaded.num_ctx)
    assert_eq("Index.num_batch", 4096, loaded.num_batch)
    assert_eq("Index.truncated_notes", ["Knowledge/long-note.md"], loaded.truncated_notes)

    # num_ctx/num_batch未指定時はEMBED_NUM_CTX/EMBED_NUM_BATCH（現在の設定）が使われる。
    gen_id2 = ei.new_generation_id()
    ei.write_generation(idx_dir, gen_id2, "modelX", "digestX", 2, notes)
    meta2 = json.loads((idx_dir / gen_id2 / "meta.json").read_text(encoding="utf-8"))
    assert_eq("num_ctx省略時はEMBED_NUM_CTXが使われる", ei.EMBED_NUM_CTX, meta2["num_ctx"])
    assert_eq("num_batch省略時はEMBED_NUM_BATCHが使われる", ei.EMBED_NUM_BATCH, meta2["num_batch"])
    assert_eq("truncated_notes省略時は空リスト", [], meta2["truncated_notes"])

    # expected_num_ctx/expected_num_batchの検証（model/model_digestと同じ考え方）。
    # CURRENTはgen_id2のwrite_generation()実行後もpublish_current()を呼んでいない
    # ため引き続きgen_id(num_ctx=4096)を指したままである点に注意。
    ok_loaded = ei.load_index(idx_dir, expected_num_ctx=4096, expected_num_batch=4096)
    assert_eq("num_ctx/num_batch一致条件つきでも読める", 2, len(ok_loaded))
    assert_raises("num_ctxが不一致ならIndexError_", ei.IndexError_,
                  lambda: ei.load_index(idx_dir, expected_num_ctx=8192, retries=0))
    assert_raises("num_batchが不一致ならIndexError_", ei.IndexError_,
                  lambda: ei.load_index(idx_dir, expected_num_batch=8192, retries=0))
finally:
    shutil.rmtree(idx_dir, ignore_errors=True)

print("=== 6c. load_index: num_ctx/num_batchフィールド無しはexpected指定時に不一致扱いになる（truncated_notesは残す） ===")
idx_dir = pathlib.Path(tempfile.mkdtemp())
try:
    gen_id = ei.new_generation_id()
    ei.write_generation(idx_dir, gen_id, "m", "dg", 1, [("Knowledge/a.md", "h", [0.5])])
    ei.publish_current(idx_dir, gen_id)
    meta_path = idx_dir / gen_id / "meta.json"
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    del meta["num_ctx"]
    del meta["num_batch"]
    meta_path.write_text(json.dumps(meta), encoding="utf-8")

    loaded = ei.load_index(idx_dir)
    assert_eq("num_ctx/num_batchフィールド欠如時はNone扱いで読み込める(expected未指定なら検証しない)", None, loaded.num_ctx)
    assert_raises("expected_num_ctx指定時は欠如を不一致として拒否する", ei.IndexError_,
                  lambda: ei.load_index(idx_dir, expected_num_ctx=4096, retries=0))
finally:
    shutil.rmtree(idx_dir, ignore_errors=True)

print("=== 6d. load_index: truncated_notesはschema v3で必須フィールド（欠如/null/不正形式は無条件でIndexError_・"
      "Codexレビュー指摘Minor対応） ===")
for mutate, label in [
    (lambda m: m.pop("truncated_notes"), "フィールド自体が無い"),
    (lambda m: m.__setitem__("truncated_notes", None), "値がnull"),
    (lambda m: m.__setitem__("truncated_notes", "not-a-list"), "文字列(配列でない)"),
    (lambda m: m.__setitem__("truncated_notes", [1, 2]), "要素が文字列でない"),
    (lambda m: m.__setitem__("truncated_notes", ["Knowledge/a.md", "Knowledge/a.md"]), "重複したrelpath"),
    (lambda m: m.__setitem__("truncated_notes", ["../escape.md"]), "不正な形式のrelpath"),
    (lambda m: m.__setitem__("truncated_notes", ["Knowledge/not-in-notes.md"]), "notesに存在しないrelpath"),
]:
    idx_dir = pathlib.Path(tempfile.mkdtemp())
    try:
        gen_id = ei.new_generation_id()
        ei.write_generation(idx_dir, gen_id, "m", "dg", 1, [("Knowledge/a.md", "h", [0.5])],
                             num_ctx=4096, num_batch=4096, truncated_notes=[])
        ei.publish_current(idx_dir, gen_id)
        meta_path = idx_dir / gen_id / "meta.json"
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        mutate(meta)
        meta_path.write_text(json.dumps(meta), encoding="utf-8")
        assert_raises(f"truncated_notes異常({label})はIndexError_（expected未指定でも常に拒否）", ei.IndexError_,
                      lambda: ei.load_index(idx_dir, retries=0))
    finally:
        shutil.rmtree(idx_dir, ignore_errors=True)

idx_dir = pathlib.Path(tempfile.mkdtemp())
try:
    gen_id = ei.new_generation_id()
    ei.write_generation(idx_dir, gen_id, "m", "dg", 1, [("Knowledge/a.md", "h", [0.5])],
                         num_ctx=4096, num_batch=4096, truncated_notes=["Knowledge/a.md"])
    ei.publish_current(idx_dir, gen_id)
    loaded = ei.load_index(idx_dir)
    assert_eq("正常なtruncated_notesは通常通り読み込める", ["Knowledge/a.md"], loaded.truncated_notes)
finally:
    shutil.rmtree(idx_dir, ignore_errors=True)

print("=== 7. load_index: 各種破損パターンでIndexError_ ===")


def fresh_index_dir():
    d = pathlib.Path(tempfile.mkdtemp())
    gen_id = ei.new_generation_id()
    ei.write_generation(d, gen_id, "m", "dg", 2, [("Knowledge/a.md", "h1", [0.5, 0.5])])
    ei.publish_current(d, gen_id)
    return d, gen_id


d, gen_id = fresh_index_dir()
try:
    assert_raises("CURRENT不在", ei.IndexError_, lambda: ei.load_index(pathlib.Path(tempfile.mkdtemp()), retries=0))

    # schema_version不一致
    meta_path = d / gen_id / "meta.json"
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    meta["schema_version"] = 999
    meta_path.write_text(json.dumps(meta), encoding="utf-8")
    assert_raises("schema_version不一致", ei.IndexError_, lambda: ei.load_index(d, retries=0))
finally:
    shutil.rmtree(d, ignore_errors=True)

d, gen_id = fresh_index_dir()
try:
    meta_path = d / gen_id / "meta.json"
    meta_path.write_text("{not valid json", encoding="utf-8")
    assert_raises("JSON破損", ei.IndexError_, lambda: ei.load_index(d, retries=0))
finally:
    shutil.rmtree(d, ignore_errors=True)

d, gen_id = fresh_index_dir()
try:
    vec_path = d / gen_id / "vectors.bin"
    vec_path.write_bytes(b"\x00\x01\x02")  # バイト長不一致
    assert_raises("vectors.binバイト長不一致(次元不一致相当)", ei.IndexError_, lambda: ei.load_index(d, retries=0))
finally:
    shutil.rmtree(d, ignore_errors=True)

d, gen_id = fresh_index_dir()
try:
    meta_path = d / gen_id / "meta.json"
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    meta["count"] = 999  # notes配列の長さと不一致
    meta_path.write_text(json.dumps(meta), encoding="utf-8")
    assert_raises("count不整合", ei.IndexError_, lambda: ei.load_index(d, retries=0))
finally:
    shutil.rmtree(d, ignore_errors=True)

d, gen_id = fresh_index_dir()
try:
    (d / gen_id / "vectors.bin").unlink()
    assert_raises("vectors.bin欠如", ei.IndexError_, lambda: ei.load_index(d, retries=0))
finally:
    shutil.rmtree(d, ignore_errors=True)

d, gen_id = fresh_index_dir()
try:
    (d / "CURRENT").write_text("../escape", encoding="utf-8")
    assert_raises("CURRENTのパストラバーサル的な値を拒否", ei.IndexError_, lambda: ei.load_index(d, retries=0))
finally:
    shutil.rmtree(d, ignore_errors=True)

print("=== 7b. load_index: notes内に重複relpathがあるとIndexError_（fail-closed・Codexレビュー指摘対応） ===")
idx_dir = pathlib.Path(tempfile.mkdtemp())
try:
    gen_id = ei.new_generation_id()
    ei.write_generation(idx_dir, gen_id, "m", "dg", 1,
                         [("Knowledge/a.md", "h1", [0.5]), ("Knowledge/b.md", "h2", [0.6])])
    ei.publish_current(idx_dir, gen_id)
    meta_path = idx_dir / gen_id / "meta.json"
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    # count・vectors.binのバイト長は変えず、notes[1]のrelpathをnotes[0]と重複させる
    # （破損/改ざんされたmeta.jsonの再現。件数不整合チェックやバイト長チェックとは
    # 独立に、重複relpath自体の検証が効くことを確認する）。
    meta["notes"][1]["relpath"] = meta["notes"][0]["relpath"]
    meta_path.write_text(json.dumps(meta), encoding="utf-8")
    assert_raises("notes内の重複relpathはIndexError_", ei.IndexError_, lambda: ei.load_index(idx_dir, retries=0))
finally:
    shutil.rmtree(idx_dir, ignore_errors=True)

idx_dir = pathlib.Path(tempfile.mkdtemp())
try:
    gen_id = ei.new_generation_id()
    ei.write_generation(idx_dir, gen_id, "m", "dg", 1,
                         [("Knowledge/a.md", "h1", [0.5]), ("Knowledge/b.md", "h2", [0.6])])
    ei.publish_current(idx_dir, gen_id)
    loaded = ei.load_index(idx_dir)
    assert_eq("重複の無い正常なnotesは従来どおり読み込める", 2, len(loaded.notes))
finally:
    shutil.rmtree(idx_dir, ignore_errors=True)

print("=== 8. prune_old_generations: 直近3世代を残し古いものを削除・stale tmp掃除 ===")
d = pathlib.Path(tempfile.mkdtemp())
try:
    gen_ids = []
    for i in range(5):
        gid = f"gen-2026071{i}T000000Z-1"
        ei.write_generation(d, gid, "m", "dg", 1, [("Knowledge/a.md", "h", [1.0])])
        gen_ids.append(gid)
    ei.prune_old_generations(d, keep=3)
    remaining = sorted(p.name for p in d.iterdir() if p.is_dir() and p.name.startswith("gen-"))
    assert_eq("直近3世代だけ残る", gen_ids[-3:], remaining)

    # stale tmpディレクトリ（1時間超）はbest-effortで削除、新しいものは残す
    stale_tmp = d / "gen-stale.tmp-999"
    stale_tmp.mkdir()
    fresh_tmp = d / "gen-fresh.tmp-999"
    fresh_tmp.mkdir()
    import time
    future_now = time.time() + 7200  # 2時間後を「現在時刻」として渡し、staleを2時間経過扱いにする
    ei.prune_old_generations(d, keep=3, now=future_now)
    assert_true("1時間超のtmpディレクトリは削除される", not stale_tmp.exists())
finally:
    shutil.rmtree(d, ignore_errors=True)

print("=== 9. index_root(): override > 環境変数 > リポジトリ内既定値の優先順位 ===")
import os
assert_eq("override引数が最優先", pathlib.Path("/explicit/override"), ei.index_root("/explicit/override"))
os.environ["VAULT_EMBED_INDEX_DIR"] = "/from/env"
try:
    assert_eq("環境変数が次点", pathlib.Path("/from/env"), ei.index_root(None))
finally:
    del os.environ["VAULT_EMBED_INDEX_DIR"]
assert_eq("既定値はリポジトリ内.cache/vault-embeddings",
          ei.repo_root() / ei.INDEX_REL_DIR, ei.index_root(None))

print("=== 10. ollama_embed: fetcher依存注入（実HTTP不使用）・1件ずつ文字列inputで送る仕様の検証 ===")
# リーダー実機検証(2026-07-11・Ollama 0.31.1)で確定: /api/embedのinputが配列(バッチ)だと
# truncate:trueが効かず長文アイテムで決定的に400になる。文字列input(単一)ならtruncateが
# 機能するため、ollama_embed()は常に1件ずつ文字列として個別リクエストする実装にした
# （配列送信は復活させない）。ここではその契約自体を回帰確認する。
calls = []


def fake_fetcher_ok(url, payload, timeout):
    calls.append((url, payload, timeout))
    return {"embeddings": [[0.1, 0.2]]}  # 1件のリクエストには必ず1件で応答する


vecs = ei.ollama_embed(["a", "b", "c"], model="m", base_url="http://example.invalid", timeout=1.0,
                        fetcher=fake_fetcher_ok)
assert_eq("件数がtextsと一致", 3, len(vecs))
assert_eq("textsの件数だけ個別にfetcherが呼ばれる（配列でまとめて1回ではない）", 3, len(calls))
assert_true("URLにbase_urlが反映される", calls[0][0] == "http://example.invalid/api/embed")
assert_true("truncate:Trueが送られる", calls[0][1]["truncate"] is True)
assert_eq("inputは配列ではなく文字列そのもの（1件目）", "a", calls[0][1]["input"])
assert_true("inputがlistでないことを型でも確認", not isinstance(calls[0][1]["input"], list))
assert_eq("inputは配列ではなく文字列そのもの（2件目）", "b", calls[1][1]["input"])
assert_eq("inputは配列ではなく文字列そのもの（3件目）", "c", calls[2][1]["input"])

# n_batch(既定2048)超過400対策（リーダー実機検証・2026-07-11後半）の回帰確認:
# 全リクエストにoptions.num_ctx/num_batchが付与されていること。
assert_eq("options.num_ctxが既定値(EMBED_NUM_CTX/BATCH)で付与される", ei.EMBED_NUM_CTX, calls[0][1]["options"]["num_ctx"])
assert_eq("options.num_batchが既定値(EMBED_NUM_CTX/BATCH)で付与される", ei.EMBED_NUM_BATCH, calls[0][1]["options"]["num_batch"])
assert_eq("EMBED_NUM_CTXの既定値は4096（2026-07-11リーダー実測でメモリ削減のため8192から変更）", 4096, ei.EMBED_NUM_CTX)
assert_eq("EMBED_NUM_BATCHの既定値は4096", 4096, ei.EMBED_NUM_BATCH)
assert_true("keep_alive未指定ならpayloadにキー自体が無い", "keep_alive" not in calls[0][1])

# keep_alive（リーダー実機実測・2026-07-11後半追加）: 明示的に渡した場合のみpayloadに
# 含まれ、渡さなければキー自体が無い（Ollama側の既定に委ねる）ことを確認する。
calls_ka = []


def fake_fetcher_keep_alive(url, payload, timeout):
    calls_ka.append(payload)
    return {"embeddings": [[0.1]]}


ei.ollama_embed(["a"], fetcher=fake_fetcher_keep_alive, keep_alive=0)
assert_eq("keep_alive=0を渡すとpayloadに含まれる", 0, calls_ka[0]["keep_alive"])

calls_ka2 = []


def fake_fetcher_no_keep_alive(url, payload, timeout):
    calls_ka2.append(payload)
    return {"embeddings": [[0.1]]}


ei.ollama_embed(["a"], fetcher=fake_fetcher_no_keep_alive)
assert_true("keep_alive未指定(既定None)ならpayloadにキーが無い", "keep_alive" not in calls_ka2[0])


def fake_fetcher_mismatch(url, payload, timeout):
    return {"embeddings": [[0.1], [0.2]]}  # 1件のリクエストなのに2件応答する異常系


assert_raises("embeddings件数不一致(1件のはずが2件)はValueError", ValueError,
              lambda: ei.ollama_embed(["a"], fetcher=fake_fetcher_mismatch))


def fake_fetcher_not_dict(url, payload, timeout):
    return ["not", "a", "dict"]


assert_raises("応答がdictでなければValueError", ValueError,
              lambda: ei.ollama_embed(["a"], fetcher=fake_fetcher_not_dict))

assert_eq("空リストはHTTPを呼ばず空リストを返す", [], ei.ollama_embed([], fetcher=lambda *a: (_ for _ in ()).throw(AssertionError("呼ばれてはいけない"))))

print("=== 11. fetch_ollama_tags / model_digest_from_tags: fetcher依存注入 ===")


def fake_tags_fetcher(url, timeout):
    return {"models": [{"name": "modelA", "digest": "digestA"}, {"model": "modelB", "digest": "digestB"}]}


tags = ei.fetch_ollama_tags(base_url="http://example.invalid", timeout=1.0, fetcher=fake_tags_fetcher)
assert_eq("modelAのdigestが取れる(nameキー)", "digestA", ei.model_digest_from_tags(tags, "modelA"))
assert_eq("modelBのdigestが取れる(modelキー)", "digestB", ei.model_digest_from_tags(tags, "modelB"))
assert_eq("未pullモデルはNone", None, ei.model_digest_from_tags(tags, "modelC"))
assert_eq("tags_dataが不正な形式でもNone(例外にしない)", None, ei.model_digest_from_tags("not a dict", "modelA"))

print("=== 12. fetch_ollama_ps / model_loaded_in_ps: fetcher依存注入 ===")


def fake_ps_fetcher(url, timeout):
    return {"models": [{"name": "modelA", "model": "modelA"}]}


ps = ei.fetch_ollama_ps(base_url="http://example.invalid", timeout=1.0, fetcher=fake_ps_fetcher)
assert_true("ロード済みモデルはTrue", ei.model_loaded_in_ps(ps, "modelA"))
assert_true("未ロードモデルはFalse", not ei.model_loaded_in_ps(ps, "modelB"))
assert_true("ps_dataが不正な形式でもFalse(例外にしない)", not ei.model_loaded_in_ps("not a dict", "modelA"))
assert_true("modelsが空でもFalse", not ei.model_loaded_in_ps({"models": []}, "modelA"))

print("=== 13. touch_activity_marker / recent_activity: 想起フック活動マーカー ===")
marker_dir = tempfile.mkdtemp()
marker_path = pathlib.Path(marker_dir) / "activity.marker"
assert_true("マーカーファイルが無ければ活動なし扱い", not ei.recent_activity(path=marker_path))
ei.touch_activity_marker(path=marker_path)
assert_true("touch直後は直近の活動ありと判定される", ei.recent_activity(path=marker_path, within_seconds=120))
assert_true("within_secondsを0にすればほぼ確実に範囲外になる", not ei.recent_activity(path=marker_path, within_seconds=0))
shutil.rmtree(marker_dir, ignore_errors=True)
assert_true("親ディレクトリが消えていてもtouch自体はfail-openで例外にしない",
            ei.touch_activity_marker(path=marker_path) is None)

print()
print(f"=== summary: {PASS} passed, {FAIL} failed ===")
sys.exit(0 if FAIL == 0 else 1)
PYEOF
