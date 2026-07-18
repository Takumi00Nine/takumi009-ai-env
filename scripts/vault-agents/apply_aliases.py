#!/usr/bin/env python3
"""外部脳(Obsidian Vault) alias 一括適用ユーティリティ（リーダーが手動実行する道具）。

使い方一覧＝Vault: Knowledge/tools-inventory.md／運用導線＝Projects/vault-hybrid-search.md

想起フック（claude/hooks/vault-recall.sh）はノートの frontmatter の `aliases:` と
ファイル名を照合キーにする。既存ノートの多くには aliases が無いため、棚卸し
（scripts/vault-agents/vault_inventory.py §9-10）や調査で見つけた候補alias群を
このツールでまとめて frontmatter へ書き込む。

入力: TSV（1行1ノート） `ノート相対パス<TAB>alias1|alias2|...`
  - 相対パスは --vault からの相対（拡張子省略時は自動で .md を補う）
  - alias は `|` 区切り。既存 aliases があれば和集合（重複は追加しない）

安全設計:
  - 既定は dry-run（差分を表示するだけ・書き込まない）。実際に書き込むには --apply。
  - frontmatter の aliases: ブロックと updated: 以外は一切変更しない（他フィールド・
    本文はテキストとしてそのまま温存する。full YAML round-tripはしない＝
    PyYAML等のフォーマット崩れリスクを避ける）。
  - `scripts/vault-agents/generic-aliases.txt`（別ツール vault_inventory.py §10 と
    共有の汎用語禁止リスト）に該当する alias は警告してそのノートへの追加をskipする。
    2026-07-14修正（外部脳の想起・ベンチ機構の総点検・Codex gpt-5.6-sol検証済み欠陥）:
    従来はこのリストが欠落/空でも「何もチェックしない」まま処理を続行する fail-open
    だったため、リスト破損時に汎用語が無警告で書き込まれかねなかった。現在は
    リストが存在しない、または有効な語を1つも含まない場合、書き込み前（dry-runでも）
    に fail-closed でエラー終了する。パスは `APPLY_ALIASES_GENERIC_FILE` 環境変数で
    差し替え可能（テスト用）。
  - PyYAML等の外部ライブラリは使わない（標準ライブラリのみ）。

使い方:
  scripts/vault-agents/apply_aliases.py aliases.tsv              # dry-run（差分表示のみ）
  scripts/vault-agents/apply_aliases.py aliases.tsv --apply      # 実際に書き込む
  scripts/vault-agents/apply_aliases.py aliases.tsv --vault DIR  # Vaultのルートを差し替え（テスト用）

2026-07-16簡素化（cleanup決定#10・Codexレビュー指摘・Major対応）: alias一括適用の
再利用可能な純粋関数（parse_tsv・process_note・require_generic_aliases・
apply_updated・write_note_atomic 等）はすべて scripts/vault-agents/vault_lib.py へ
抽出済み。本ファイルはCLI専業（argparse・diff表示・ファイルI/O orchestration）。
recall_bench.py の --alias-overlay もvault_lib経由でこれらを再利用するため、
本ファイルはこれ以上どこからも import されない（`import apply_aliases` は
設計書どおり全廃）。
"""
import argparse
import datetime
import difflib
import os
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import vault_lib  # noqa: E402

VAULT = pathlib.Path.home() / "Data" / "obsidian"
# APPLY_ALIASES_GENERIC_FILE環境変数でテスト用に差し替え可能（既定はリポジトリ本体の
# generic-aliases.txt）。fail-closed化のユニットテストで、本物のリストを汚さずに
# 「欠落/空」状態を再現するために使う。
GENERIC_ALIASES_FILE = pathlib.Path(
    os.environ.get("APPLY_ALIASES_GENERIC_FILE", str(pathlib.Path(__file__).parent / "generic-aliases.txt")))


def main():
    ap = argparse.ArgumentParser(
        description="TSV（ノート相対パス<TAB>alias1|alias2|...）から Vault ノートへ aliases: を一括適用する。")
    ap.add_argument("tsv", help="入力TSVファイル")
    ap.add_argument("--apply", action="store_true", help="実際に書き込む（既定はdry-runで差分表示のみ）")
    ap.add_argument("--vault", default=str(VAULT), help=f"Vaultのルート（既定: {VAULT}）")
    args = ap.parse_args()

    vault = pathlib.Path(args.vault)
    vault_resolved = vault.resolve()
    try:
        rows = vault_lib.parse_tsv(args.tsv)
    except OSError as e:
        print(f"FAIL: TSVを読めません: {args.tsv}（{e}）", file=sys.stderr)
        sys.exit(1)

    if not rows:
        print("適用対象がありません（TSVが空、または全行が不正/コメントでskipされました）。")
        return

    # fail-closed（2026-07-14修正・Codex検証済み欠陥の是正）: 汎用語禁止リストが
    # 欠落/空の場合、これまでは「何もチェックしない」まま書き込みまで進んでいた
    # （fail-open）。汎用語チェックが安全に機能しない状態で処理を続けると、本来
    # skipすべき汎用alias（"Claude"等）が無警告でVaultへ書き込まれうるため、
    # dry-run/--applyいずれの場合でも書き込みより前でエラー終了する
    # （vault_lib.require_generic_aliases()経由・sys.exit(1)）。
    generic_words = vault_lib.require_generic_aliases(GENERIC_ALIASES_FILE)
    today = datetime.date.today().isoformat()

    n_changed = n_skip_missing = n_skip_nochange = n_error = 0
    for relpath, new_aliases in rows:
        path = vault / relpath
        # TSVの相対パスに ".." 等が含まれていてもVault外を書き換えないよう、解決後の
        # 実パスがVault配下であることを確認する（Codexレビュー指摘・Major:
        # 単純な `vault / relpath` だけでは `../../outside.md` のようなパスを
        # 拒否できず、--apply時にVault外のファイルを書き換えてしまいうる）。
        try:
            resolved = path.resolve()
            resolved.relative_to(vault_resolved)
        except (OSError, ValueError):
            print(f"ERROR {relpath}: Vaultの外を指しているためskipします（{path}）")
            n_error += 1
            continue
        if not path.is_file():
            print(f"SKIP {relpath}: ノートが見つかりません（{path}）")
            n_skip_missing += 1
            continue

        original = path.read_text(encoding="utf-8")
        result = vault_lib.process_note(original, new_aliases, generic_words, today)

        if result["error"]:
            print(f"ERROR {relpath}: {result['error']}")
            n_error += 1
            continue

        for g in result["skipped_generic"]:
            print(f"WARN {relpath}: alias \"{g}\" は汎用語禁止リスト該当のためskipします"
                  f"（{GENERIC_ALIASES_FILE.name}）")

        if not result["changed"]:
            print(f"SKIP {relpath}: 追加すべき新規aliasがありません"
                  f"（既存: {', '.join(result['existing']) or 'なし'}）")
            n_skip_nochange += 1
            continue

        label = "APPLY" if args.apply else "DRY-RUN"
        print(f"{label} {relpath}: +{result['added']}"
              f"（既存{len(result['existing'])}件 → 合計{len(result['existing']) + len(result['added'])}件・"
              f"updated: {today}）")
        diff = difflib.unified_diff(
            original.splitlines(keepends=True), result["new_text"].splitlines(keepends=True),
            fromfile=f"{relpath} (現在)", tofile=f"{relpath} ({'適用後' if args.apply else '適用予定'})",
        )
        sys.stdout.writelines(diff)

        if args.apply:
            # symlinkノートの場合、書込み先はリンクそのものではなく解決済みの実体
            # (resolved)にする（Codex一次レビュー指摘・Major: os.replace()はpathが
            # symlinkだとリンク自体を通常ファイルへ置き換えてしまい、リンク先の実体は
            # 更新されないままリンクが消える回帰を招く。read_text()はsymlinkを透過的に
            # 辿るため気づきにくい）。resolvedは冒頭のVault境界チェックで既に計算済み。
            vault_lib.write_note_atomic(resolved, result["new_text"])

        n_changed += 1

    print()
    print(f"サマリ: 対象{len(rows)}件 / 変更{'適用' if args.apply else '予定'}{n_changed}件 / "
          f"変更なしskip{n_skip_nochange}件 / ノート未検出skip{n_skip_missing}件 / エラー{n_error}件")
    if not args.apply and n_changed:
        print("（dry-runです。反映するには --apply を付けて再実行してください）")


if __name__ == "__main__":
    main()
