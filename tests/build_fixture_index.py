#!/usr/bin/env python3
"""テスト専用ヘルパー: 埋め込みインデックスのフィクスチャを、実Ollama通信なしで
直接構築する（scripts/vault-agents/embedding_index.py の write_generation()/
publish_current() を直接呼ぶ）。

tests/test-knowledge-merge-candidates.sh から使う。knowledge_merge_candidates.py は
インデックスを「読むだけ」（Ollama通信を一切行わない）ため、tests/fake_ollama_server.py
のようなHTTPモックは不要で、既知のベクトル値を直接注入した方が閾値境界・同点タイ等の
決定的なテストがしやすい。

入力: --spec-file で渡すJSONファイル。形式:
{
  "dim": 3,
  "model": "test-model",            (省略可・既定"test-model")
  "model_digest": "digest1",        (省略可・既定"digest1")
  "notes": {
    "Knowledge/a.md": {
      "body": "本文",
      "vector": [1.0, 0.0, 0.0],
      "frontmatter": {"deprecated": "true"}   (省略可)
    },
    ...
  }
}
各ノートはVault側にも実ファイルとして書き出す（knowledge_merge_candidates.pyが
deprecated判定のためVaultから直接frontmatterを読むため）。
"""
import argparse
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "scripts" / "vault-agents"))
import embedding_index as ei  # noqa: E402


def note_text(note):
    fm = note.get("frontmatter")
    body = note["body"]
    if fm:
        lines = ["---"]
        for k, v in fm.items():
            lines.append(f"{k}: {v}")
        lines.append("---")
        lines.append(body)
        return "\n".join(lines)
    return body


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vault", required=True)
    ap.add_argument("--idx", required=True)
    ap.add_argument("--spec-file", required=True)
    args = ap.parse_args()

    spec = json.loads(pathlib.Path(args.spec_file).read_text(encoding="utf-8"))
    vault = pathlib.Path(args.vault)
    idx = pathlib.Path(args.idx)
    dim = spec["dim"]
    model = spec.get("model", "test-model")
    model_digest = spec.get("model_digest", "digest1")

    nwv = []
    for rel, note in spec["notes"].items():
        text = note_text(note)
        p = vault / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")
        chash = ei.content_hash(text)
        nwv.append((rel, chash, note["vector"]))

    gen = ei.new_generation_id()
    ei.write_generation(idx, gen, model=model, model_digest=model_digest, dim=dim, notes_with_vectors=nwv)
    ei.publish_current(idx, gen)
    print(gen)


if __name__ == "__main__":
    main()
