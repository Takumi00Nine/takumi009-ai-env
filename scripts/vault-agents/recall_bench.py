#!/usr/bin/env python3
"""外部脳(Obsidian Vault)の想起フック(claude/hooks/vault-recall.sh)を自動採点するハーネス。

使い方一覧＝Vault: Knowledge/tools-inventory.md／運用導線＝Projects/vault-hybrid-search.md
正本ベンチ＝ai-env-private docs/vault-recall-benchmark.tsv（27問）

背景: 敵対的レビュー(vault-adversarial-review-2026-07-10.md C-1)により、想起フックの
ヒット率が「机上シミュレーション」でしか測られていないことが指摘された。改善(alias棚卸し・
照合方式の改修)を進めるための唯一の計器として、実フックを実際に叩いて実測する。

採点方法: フックのロジックはここで再実装しない（ドリフト源になるため禁止）。各質問について
`{"session_id": ..., "prompt": "<質問文>"}` をJSONでフック本体(bash)へstdin投入し、
実際に返ってきた additionalContext から提示候補ノートを抽出して判定する。

入力データ形式（ベンチTSV・1行1問）:
  質問文<TAB>期待ノート相対パス（`|`区切りで複数可・いずれか1つが提示されれば正解）
  空行・`#`始まりの行はコメントとしてskip。

オーバーレイ機能（--alias-overlay）: Vaultを一切書き換えずに「aliasを足したら
ヒット率がどう変わるか」を試すための機能。Vaultの想起対象5フォルダ(SCAN_DIRS＝
Knowledge/Preferences/Decisions/Projects/Personal)だけを一時ディレクトリへコピーし、そこへ
apply_aliases.py の process_note()（同じロジックを再利用・重複実装しない）で
overlay TSV のaliasを適用してから、VAULT_RECALL_VAULT をその一時ディレクトリに
向けてフックを叩く。実Vaultは最初から最後まで一切書き込まない。

使い方:
  scripts/vault-agents/recall_bench.py bench.tsv
  scripts/vault-agents/recall_bench.py bench.tsv --json
  scripts/vault-agents/recall_bench.py bench.tsv --alias-overlay overlay.tsv
  scripts/vault-agents/recall_bench.py bench.tsv --vault DIR --hook DIR/vault-recall.sh
"""
import argparse
import datetime
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

# 同じディレクトリ(scripts/vault-agents/)のモジュールをそのまま再利用する
# （alias適用・frontmatter解析のロジック重複によるドリフトを避ける）。
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import apply_aliases  # noqa: E402
import vault_inventory as vi  # noqa: E402

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
DEFAULT_VAULT = pathlib.Path.home() / "Data" / "obsidian"
DEFAULT_HOOK = REPO_ROOT / "claude" / "hooks" / "vault-recall.sh"

# 想起フックが実際に使う SCAN_DIRS（keyword_recall_helper.py:62。8.2ラウンドの
# 統一リファクタリングでキーワード照合ロジックがclaude/hooks/vault-recall.shから
# こちらへ移植された・vault-recall.sh自体は薄い殻でSCAN_DIRSを持たない）と同じ並び。
# 2026-07-11のPersonal想起対象化（Decisions/2026-07-11-personal-recall-scope）で
# 5フォルダになっている。オーバーレイ用の一時Vaultはこの5フォルダだけコピーすれば
# 十分（照合ロジックの実行自体は実物のフックがそのまま行うため、ここでは
# 「コピー範囲」の話でしかない）。
SCAN_DIRS = ("Knowledge", "Preferences", "Decisions", "Projects", "Personal")

# 想起フックが実際に提示しうる候補数の上限（2026-07-14修正・外部脳の想起・ベンチ
# 機構の総点検・Codex gpt-5.6-sol検証済み欠陥の是正）。
# 従来はMAX_CANDIDATES=5のみで、キーワード枠(先頭5件)しか勘定しておらず、
# vault-recall.sh側が実際に返しうるベクトル追加枠（キーワード候補に無いものだけ・
# 最大3件・MAX_VECTOR_EXTRA）を採点時点で切り捨てていた。結果、ベクトル追加枠経由
# でしかヒットしない質問が採点上falseにされうる過小評価バグだった。
# フック本体の実値（vault-recall.sh: キーワード枠は`MAX_KEYWORD_CANDIDATES=5`／
# ベクトル追加枠は`MAX_VECTOR_EXTRA=3`、いずれも名前付き定数・2026-07-14修正で
# `SELECTED_IDX`構築ループのリテラル`5`から切り出した）と食い違わないよう、
# tests/test-recall-bench.sh がこれら2定数の定義行をフック本体からgrep抽出して一致
# 検証する（SSOT: 値の変更はフック本体側を先に直し、ここは追随するだけにする）。
MAX_KEYWORD_CANDIDATES = 5       # キーワード枠の上限
MAX_VECTOR_EXTRA_CANDIDATES = 3  # ベクトル追加枠（キーワード候補と重複しないもの）の上限
MAX_CANDIDATES = MAX_KEYWORD_CANDIDATES + MAX_VECTOR_EXTRA_CANDIDATES  # 実際に提示されうる合計上限(8)
DEFAULT_HOOK_TIMEOUT = 5.0  # 秒。実運用のフック側timeout(settings.json=2秒)より余裕を持たせる
                             # （ベンチ実行環境のプロセス起動オーバーヘッド込みで測るため）。

# フックが1候補ごとに出す行の厳密フォーマット（vault-recall.sh:317-318のCTX組み立てと
# 一致させる）: "- ${relpath}（一致: ${keys_display}）"。緩い判定（"- "始まりだけ見る等）
# だと、将来この表示フォーマットが変わった際に別の情報を relpath として誤採用してしまう
# （Codexレビュー指摘・Major回帰: 単に「（一致:」の有無で分岐しないと、区切り文字だけが
# 変わったケースを検知できずに無言で誤パースする）。
CANDIDATE_LINE_RE = re.compile(r"^- (.+?)（(?:一致|類似度): .+）$")  # 類似度＝ベクトル別枠の表示形式（2026-07-12 選定テストで発覚した採点漏れの修正）


NEGATIVE_MARKER = "-"  # 期待ノート列がこの1文字だけの行＝「候補ゼロが正解」のノイズ検査用行
                        # （8.0ラウンド・ノイズ検査ベンチ用の最小拡張。既存TSVはこの記法を
                        # 使わないため後方互換＝通常行の判定ロジックは一切変えない）。


def parse_bench_tsv(path):
    """ベンチTSV(質問文<TAB>期待ノート相対パス(|区切り)、またはノイズ検査用に
    期待ノート列が"-"1文字だけの行)を [(question, [relpath, ...], is_negative), ...] にする。
    "-"の行は「このプロンプトではノートが0件提示されるのが正解」を意味する
    （Vaultのどのノートとも無関係な日常プロンプトでの誤ヒット率を測るノイズ検査用。
    通常の正例行と書式を揃えることでファイル1本で両方扱える）。
    空行・#始まりはコメントとしてskip。壊れた行はWARNしてskip（apply_aliases.parse_tsvと同方針）。
    """
    rows = []
    text = pathlib.Path(path).read_text(encoding="utf-8")
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.rstrip("\r")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 2 or not parts[0].strip() or not parts[1].strip():
            print(f"WARN: {path}:{lineno}: 想定外の形式のためskipします（列数={len(parts)}）: {raw!r}",
                  file=sys.stderr)
            continue
        question = parts[0].strip()
        if parts[1].strip() == NEGATIVE_MARKER:
            rows.append((question, [], True))
            continue
        expected = [e.strip() for e in parts[1].split("|") if e.strip()]
        if not expected:
            print(f"WARN: {path}:{lineno}: 期待ノートが1つもありません。skipします: {raw!r}", file=sys.stderr)
            continue
        rows.append((question, expected, False))
    return rows


def build_overlay_vault(vault_root, overlay_path):
    """SCAN_DIRSだけを一時ディレクトリへコピーし、overlay TSVのaliasを適用して返す。
    実Vault(vault_root)は一切書き込まない。呼び出し側が使用後に必ずrmtreeすること。

    途中で例外（TSV読込失敗・generic-aliases.txt欠落等）が起きた場合は、既に作成済みの
    一時ディレクトリを自分で片付けてから再送出する（2026-07-14修正・Codexレビュー指摘・
    Minor: 従来は呼び出し側main()がoverlay_dir変数へ代入する前に例外を送出すると、
    tmp_dirが誰にも参照されないまま残ってしまっていた＝作成済みの一時Vaultコピーが
    リークするだけで実Vaultへの実害は無いが、3年ノーメンテ運用での/tmp肥大化を避ける）。
    """
    tmp_dir = pathlib.Path(tempfile.mkdtemp(prefix="recall-bench-vault-"))
    try:
        tmp_resolved = tmp_dir.resolve()
        for d in SCAN_DIRS:
            src = vault_root / d
            if src.is_dir():
                shutil.copytree(src, tmp_dir / d)

        rows = apply_aliases.parse_tsv(str(overlay_path))
        # generic-aliases.txtが欠落/空のまま続行しない（fail-closed・2026-07-14修正・
        # Codex一次レビュー指摘・Major: apply_aliases.py本体はmain()でfail-closed化
        # 済みだが、load_generic_aliases()自体は「無ければ空集合」を返す純粋関数のため、
        # ここで直接それを呼ぶと本来skipすべき汎用aliasがオーバーレイへ紛れ込み、誤った
        # 採点結果を生みかねない。apply_aliases.require_generic_aliases()へ差し替え、
        # fail-closedの判定を1箇所に集約する）。
        generic_words = apply_aliases.require_generic_aliases()
        today = datetime.date.today().isoformat()
        applied = skipped = 0
        for relpath, aliases in rows:
            # overlay TSVの相対パスが絶対パス・"../"・symlink等で一時Vaultの外を指していても
            # 書き換えないようにする（Codexレビュー指摘・Critical: apply_aliases.py本体の
            # resolve()+relative_to()チェックはmain()内にしか無く、process_note()自体は
            # パス検証をしない純粋関数のため、呼び出し側=ここで独立に必ず確認する）。
            candidate = tmp_dir / relpath
            try:
                resolved = candidate.resolve()
                resolved.relative_to(tmp_resolved)
            except (OSError, ValueError):
                print(f"WARN: overlay対象パスが一時Vaultの外を指しているためskipします: {relpath}", file=sys.stderr)
                skipped += 1
                continue
            if not resolved.is_file():
                print(f"WARN: overlay対象ノートが一時Vaultに見つかりません（コピー範囲外か存在しない）: {relpath}",
                      file=sys.stderr)
                skipped += 1
                continue
            text = resolved.read_text(encoding="utf-8")
            result = apply_aliases.process_note(text, aliases, generic_words, today)
            if result["error"]:
                print(f"WARN: overlay適用失敗 {relpath}: {result['error']}", file=sys.stderr)
                skipped += 1
                continue
            if result["changed"]:
                # apply_aliases.write_note_atomic()を再利用（2026-07-14修正・リーダー指示
                # apply_aliases.py:307のatomic化と同じ理由。ここは一時コピーへの書込みで
                # 実害は小さいが、process_note()等と同様にロジック重複を避けるため共通化する）。
                apply_aliases.write_note_atomic(resolved, result["new_text"])
                applied += 1
        print(f"overlay適用: {applied}件（skip {skipped}件） ※一時コピーのみ・実Vaultは無変更", file=sys.stderr)
        return tmp_dir
    except BaseException:
        # require_generic_aliases()のsys.exit(1)（SystemExit＝BaseExceptionのみ捕捉されExceptionでは
        # 捕捉されない）も含めて確実に一時ディレクトリを片付けてから再送出する。
        shutil.rmtree(tmp_dir, ignore_errors=True)
        raise


# vault-recall.sh のログ契約（claude/hooks/vault-recall.sh log_error()/log_fact()）:
# ERROR行は `log_row "ERROR\t\t${SESSION_ID:-}\t$1[\t${LOG_LEVEL_INFO}]"` として書かれ、
# log_row()自身がさらに先頭へ"$ts\t"を付ける。tabで分割すると
# [ts, "ERROR", "", session_id, message, (level省略可)] の5〜6列になる（3列目=空文字は
# vault_inventory.py側の「3列目=ノート相対パス」パーサに誤集計させないための意図的な
# 空欄・同ファイルの該当コメント参照）。fail-openの検知はこの2列目（0-indexで1）が
# 固定文字列"ERROR"かどうかで判定する。
LOG_ERROR_MARKER_COL = 1     # 0-indexでの列位置（"ERROR"固定文字列）
LOG_ERROR_MESSAGE_COL = 4    # 0-indexでの列位置（エラーメッセージ本文）

# ERROR行の中には「真の失敗(fail-open)」ではなく「パイプラインが正常完走した上での
# 事実記録」（claude/hooks/vault-recall.sh log_fact()・削除済みノートのベクトル残存
# 除外/読取不可ノート件数）が混在する。2026-07-14修正・外部脳の想起・ベンチ機構の
# 総点検: 従来はこの区別をメッセージ本文の部分一致(BENIGN_ERROR_MARKER)だけで行って
# おり、しかもこのマーカーは削除済みノート残存の1ケースしかカバーしておらず
# （読取不可ノート件数のメッセージは非該当のためfail-open扱いされてしまう漏れが
# あった）、hook側の文言が変わると無言で判定が壊れる脆い状態だった。log_fact()は
# 6列目に固定文字列"INFO"(LOG_LEVEL_INFO_VALUE)を付与するため、ここでも文言では
# なく列の値で判定する（フォーマットベースの判別へ置換・Codex一次レビュー指摘）。
# 列が無い（6列未満）場合は従来どおり真の失敗として扱う（fail-closed寄りの安全側＝
# 新形式を出せない壊れたhookを誤って無害と判定しない）。
LOG_LEVEL_COL = 5            # 0-indexでの列位置（"INFO"なら正常完走時の事実記録）
LOG_LEVEL_INFO_VALUE = "INFO"


def _read_new_error_rows(log_path, offset_before):
    """log_pathのoffset_beforeバイト以降に追記された行のうち、vault-recall.shの
    log_error()契約（上記LOG_ERROR_MARKER_COL列が"ERROR"固定文字列）に一致する行の
    メッセージ一覧を返す。log_fact()由来の行（LOG_LEVEL_COL列がLOG_LEVEL_INFO_VALUE・
    実際にはfail-openではない正常完走時の事実記録）は除外する。

    戻り値はメッセージのリスト、またはログ読み取り自体に失敗した場合はNone
    （空リスト=「検査したがERROR行は無かった」とNone=「検査できなかった」を
    呼び出し側が区別できるようにする・Codex一次レビュー指摘・Major: 読み取り失敗を
    空リストへフォールバックすると、ログ検査が機能しない状況を静かに「fail-open
    なし」と誤認してしまい、このハーネス自体が無言のfail-openになる）。

    offset_beforeはos.path.getsize()由来のバイト数のため、text modeの
    seek()（0以外はtell()が返したcookieでなければ未定義動作）ではなくバイナリ
    modeで開いてseekし、読み取ったバイト列を最後にUTF-8としてdecodeする
    （Codex一次レビュー指摘・Major: text modeへ生のバイトoffsetを渡すのは
    移植性が無く、環境によってはValueErrorで落ちうる）。
    """
    try:
        with open(log_path, "rb") as f:
            f.seek(offset_before)
            new_bytes = f.read()
    except OSError:
        return None
    new_text = new_bytes.decode("utf-8", errors="replace")
    messages = []
    for line in new_text.splitlines():
        if not line:
            continue
        cols = line.split("\t")
        if len(cols) > LOG_ERROR_MARKER_COL and cols[LOG_ERROR_MARKER_COL] == "ERROR":
            if len(cols) > LOG_LEVEL_COL and cols[LOG_LEVEL_COL] == LOG_LEVEL_INFO_VALUE:
                continue  # log_fact()由来＝正常完走時の事実記録（真の失敗ではない）
            msg = cols[LOG_ERROR_MESSAGE_COL] if len(cols) > LOG_ERROR_MESSAGE_COL else "(メッセージ列なし)"
            messages.append(msg)
    return messages


def run_hook(hook_path, vault_dir, prompt, session_id, log_path, timeout):
    """実物のフックをsubprocessで叩き、(提示候補relpathのリスト, エラーメッセージ or None)を返す。
    ロジックは一切再実装しない。フックの異常（非0終了・timeout・壊れたJSON・空出力）は
    無言で握りつぶさず、エラーメッセージ付きで「候補ゼロ(fail)」として扱う
    （このハーネス自体が「無言のfail-open」にならないようにする）。
    """
    payload = json.dumps({"session_id": session_id, "prompt": prompt}, ensure_ascii=False)
    env = os.environ.copy()
    env["VAULT_RECALL_VAULT"] = str(vault_dir)
    env["VAULT_RECALL_LOG"] = str(log_path)

    # このクエリの呼び出し前のログサイズを記録しておき、このクエリ中に追記された行
    # だけを検査対象にする（2026-07-14修正・リーダー指示: VAULT_RECALL_LOGをフックへ
    # 渡すだけで一度も読まずに削除していたバグの是正）。score()は全クエリで同じ
    # log_pathを使い回すが、呼び出しは逐次実行（並行実行しない）のため、オフセット
    # 方式で「このクエリ分」だけを安全に切り出せる。
    try:
        log_offset_before = os.path.getsize(log_path)
    except OSError:
        log_offset_before = 0

    try:
        proc = subprocess.run(
            ["bash", str(hook_path)], input=payload, capture_output=True, text=True,
            timeout=timeout, env=env,
        )
    except subprocess.TimeoutExpired:
        return [], f"hookがtimeout({timeout}s)しました"
    except OSError as e:
        return [], f"hookを起動できませんでした: {e}"

    if proc.returncode != 0:
        return [], f"hookが非0終了しました（rc={proc.returncode}）: {proc.stderr.strip()[:200]}"

    # fail-open検知（2026-07-14修正・リーダー指示: VAULT_RECALL_LOGをフックへ渡す
    # だけで一度も読まずに削除していたバグの是正）。additionalContextの有無に
    # 関わらず、exit 0直後にここで検査する（Codex一次レビュー指摘・Major:
    # 「出力が空の場合だけ」に限定すると、keyword/vectorの片方だけがfail-openし
    # もう片方が候補を返したケースでadditionalContextが非空になり、劣化した
    # 計測結果をそのまま正常採点してしまう＝ベクトル経由でしか出ない期待ノートを
    # 「通常のmiss」と誤認しうる）。vault-recall.shのlog_heartbeat()は
    # PIPELINE_HAD_ERRORが立っていれば書かない契約（同ファイルの該当コメント参照）
    # なので、候補の有無に関わらずERROR行の有無だけで「fail-openが起きたか」を
    # 判定できる。
    fail_open_msgs = _read_new_error_rows(log_path, log_offset_before)
    if fail_open_msgs is None:
        return [], ("想起ログ（VAULT_RECALL_LOG）の読み取りに失敗しました。fail-open検知が"
                     "できないため計測失敗として扱います。")
    if fail_open_msgs:
        return [], (f"hookはexit 0で完了しましたが、想起ログにfail-openの記録が"
                     f"{len(fail_open_msgs)}件あります（候補の有無に関わらず計測失敗として扱います）: "
                     f"{fail_open_msgs[0][:200]}")

    out = proc.stdout.strip()
    if not out:
        return [], None  # 正常系「ヒット無し」。additionalContextを出さないのがフックの仕様。

    try:
        data = json.loads(out)
    except json.JSONDecodeError as e:
        return [], f"hook出力のJSON解析に失敗しました（{e}）: {out[:200]!r}"

    # 型が想定外（hookSpecificOutputがオブジェクトでない・additionalContextが文字列でない等）
    # の場合、素朴に.get()や.splitlines()を呼ぶとハーネス自体が例外で落ちる（Codexレビュー
    # 指摘・Minor）。フック実装が将来変わってフォーマットが崩れた場合を「候補0件の正常系」
    # と誤認しないよう、ここでエラーとして可視化する（無言のfail-open防止）。
    hso = data.get("hookSpecificOutput") if isinstance(data, dict) else None
    if not isinstance(hso, dict):
        return [], f"hook出力の形式が想定外です（hookSpecificOutputがオブジェクトではありません）: {out[:200]!r}"
    ctx = hso.get("additionalContext", "")
    if not isinstance(ctx, str):
        return [], f"hook出力の形式が想定外です（additionalContextが文字列ではありません）: {out[:200]!r}"

    candidates = []
    malformed_lines = []
    for line in ctx.splitlines():
        line = line.strip()
        if not line.startswith("- "):
            continue
        m = CANDIDATE_LINE_RE.match(line)
        if not m:
            # "- "で始まる箇条書き行なのに厳密フォーマットに一致しない＝表示フォーマットが
            # 変わった可能性（Codexレビュー指摘・Major回帰: 緩い分割だと区切り文字が変わった
            # ケースを検知できず、別の文字列をrelpathとして誤採用してしまう）。
            malformed_lines.append(line)
            continue
        relpath = m.group(1).strip()
        if relpath:
            candidates.append(relpath)

    if malformed_lines:
        return [], (f"候補行の形式が想定と異なります（表示フォーマット変更の可能性・"
                     f"{len(malformed_lines)}行）: {malformed_lines[0][:200]!r}")

    # additionalContextが非空なのに候補行を1件も抽出できなかった場合も同様に、hook側の
    # 表示フォーマットが根本から変わった可能性が高い（Codexレビュー指摘・Major: これを
    # 無言で「候補0件=miss」として扱うと、フォーマット変更をヒット率低下と誤認したまま
    # 気づけない）。
    if ctx.strip() and not candidates:
        return [], f"additionalContextはあるが候補行を1件も抽出できませんでした（表示フォーマット変更の可能性）: {ctx[:200]!r}"

    # 候補数がフック契約の上限(MAX_CANDIDATES=8)を超えている場合も、無言で先頭8件だけを
    # 正常系として切り詰めない（2026-07-14修正・Codex一次レビュー指摘・Major: 旧実装の
    # `candidates[:MAX_CANDIDATES]` は、フック側が契約を超えて壊れている（例:
    # キーワード枠の5件上限が効いていない等の回帰）ケースを「たまたま先頭8件が正常」と
    # 誤認させ、9件目以降にしか無い期待ノートを静かにmiss扱いにしてしまう。上限超過は
    # hookエラーとして可視化し、他のフォーマット異常系と同じ経路で判定不能扱いにする）。
    if len(candidates) > MAX_CANDIDATES:
        return [], (f"候補数がフック契約の上限({MAX_CANDIDATES}件=キーワード枠"
                     f"{MAX_KEYWORD_CANDIDATES}件+ベクトル追加枠{MAX_VECTOR_EXTRA_CANDIDATES}件)を"
                     f"超えています（{len(candidates)}件・hookが契約を超えて壊れている可能性）: "
                     f"{candidates[:MAX_CANDIDATES + 3]}")

    return candidates, None


def note_aliases(vault_dir, relpath):
    """ノートの現在のaliasesを返す。ノートが無ければNone（fail一覧の「現aliases」表示用）。"""
    path = vault_dir / relpath
    if not path.is_file():
        return None
    fm, _ = vi.parse_frontmatter(path.read_text(encoding="utf-8"))
    return vi.normalize_aliases(fm.get("aliases"))


def score(rows, hook_path, vault_dir, session_id, timeout):
    log_fd, log_path = tempfile.mkstemp(prefix="recall-bench-log-", suffix=".tsv")
    os.close(log_fd)
    results = []
    try:
        for i, (question, expected, is_negative) in enumerate(rows, 1):
            candidates, hook_error = run_hook(hook_path, vault_dir, question, session_id, log_path, timeout)
            # ノイズ検査行(is_negative)は「候補が1件も出ないこと」が正解。通常行は
            # 従来どおり期待ノートのいずれかが候補に含まれていればPASS。
            # いずれの場合もhook自体が異常終了/異常出力した行はPASSにしない
            # （Codexレビュー指摘・Major: run_hook()は異常時candidates=[]を返すため、
            # 対策なしだとノイズ検査行が「たまたま0件」と区別できず誤ってPASS集計
            # されてしまう＝インフラ異常を精度の実績と混同する）。
            if hook_error:
                passed = False
            elif is_negative:
                passed = len(candidates) == 0
            else:
                passed = any(e in candidates for e in expected)
            results.append({
                "index": i,
                "question": question,
                "expected": expected,
                "is_negative": is_negative,
                "candidates": candidates,
                "pass": passed,
                "hook_error": hook_error,
                "expected_aliases": {e: note_aliases(vault_dir, e) for e in expected},
            })
    finally:
        try:
            os.remove(log_path)
        except OSError:
            pass
    return results


def format_human(results, vault_desc, hook_path, overlay_used):
    total = len(results)
    hits = sum(1 for r in results if r["pass"])
    rate = (hits / total * 100) if total else 0.0
    lines = []
    lines.append("=== 想起ベンチマーク採点 ===")
    lines.append(f"Vault: {vault_desc}" + ("（aliasオーバーレイ適用・一時コピーに対して実行）" if overlay_used else ""))
    lines.append(f"Hook: {hook_path}")
    lines.append(f"質問数: {total}")
    lines.append("")
    for r in results:
        mark = "PASS" if r["pass"] else "FAIL"
        lines.append(f"[{r['index']:>2}] {mark}  Q: {r['question']}")
        cand = "、".join(r["candidates"]) if r["candidates"] else "(なし)"
        lines.append(f"      提示候補: {cand}")
        if r["is_negative"]:
            lines.append("      期待ノート: (候補ゼロが正解・ノイズ検査行)")
        else:
            lines.append(f"      期待ノート: {'、'.join(r['expected'])}")
        if r["hook_error"]:
            lines.append(f"      ⚠️ hookエラー: {r['hook_error']}")
    lines.append("")
    lines.append(f"=== サマリ: ヒット率 {hits}/{total} ({rate:.1f}%) ===")

    negatives = [r for r in results if r["is_negative"]]
    if negatives:
        # hook異常行（timeout・壊れた出力等）は「提示0件」の実績ではなくインフラ
        # 異常なので、ノイズ率の平均/最大からは除外する（Codexレビュー指摘・Minor:
        # 混ぜると本来の判定不能行が「静かなノイズ0件」として平均に紛れ込む）。
        negatives_clean = [r for r in negatives if not r["hook_error"]]
        negatives_error = [r for r in negatives if r["hook_error"]]
        lines.append("")
        if negatives_clean:
            counts = [len(r["candidates"]) for r in negatives_clean]
            avg = sum(counts) / len(counts)
            lines.append(f"=== ノイズ検査: 提示数の平均 {avg:.2f}件 / 最大 {max(counts)}件"
                         f"（{len(negatives_clean)}問・hook異常{len(negatives_error)}件は集計除外） ===")
        else:
            lines.append(f"=== ノイズ検査: 集計対象0件（{len(negatives_error)}問すべてhook異常） ===")

    fails = [r for r in results if not r["pass"]]
    lines.append("")
    lines.append(f"=== FAIL一覧（alias改善の材料・{len(fails)}件） ===")
    if not fails:
        lines.append("なし")
    else:
        for r in fails:
            if r["hook_error"]:
                lines.append(f"- [{r['index']}] {r['question']}")
                lines.append(f"    ⚠️ hookエラーのため判定不能（ノイズ/ヒットいずれの実績にも数えない）: {r['hook_error']}")
                continue
            if r["is_negative"]:
                lines.append(f"- [{r['index']}] {r['question']}")
                lines.append(f"    ノイズ検査: 候補ゼロが正解だが {r['candidates']} が提示された")
                continue
            bits = []
            for exp in r["expected"]:
                al = r["expected_aliases"].get(exp)
                if al is None:
                    bits.append(f"{exp}: (ノート未検出)")
                elif al:
                    bits.append(f"{exp}: {', '.join(al)}")
                else:
                    bits.append(f"{exp}: (aliasesなし)")
            lines.append(f"- [{r['index']}] {r['question']}")
            lines.append(f"    期待: {' / '.join(r['expected'])} / 提示候補: {r['candidates'] or '(なし)'}")
            lines.append(f"    現aliases: {' | '.join(bits)}")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(
        description="想起フック(claude/hooks/vault-recall.sh)を実際に叩いてベンチ問題を採点する。")
    ap.add_argument("bench_tsv", help="ベンチTSV（質問文<TAB>期待ノート相対パス(|区切り)）")
    ap.add_argument("--vault", default=str(DEFAULT_VAULT), help=f"Vaultのルート（既定: {DEFAULT_VAULT}）")
    ap.add_argument("--hook", default=str(DEFAULT_HOOK), help=f"想起フックのパス（既定: {DEFAULT_HOOK}）")
    ap.add_argument("--alias-overlay",
                     help="ノート相対パス<TAB>alias1|alias2|... のTSV。指定すると実Vaultを書き換えずに"
                          "一時コピーへ適用してから採点する（次工程のalias調整の下見用）")
    ap.add_argument("--session-id", default="bench", help="hookへ渡すsession_id（既定: bench）")
    ap.add_argument("--hook-timeout", type=float, default=DEFAULT_HOOK_TIMEOUT,
                     help=f"1問あたりのhook実行timeout秒（既定: {DEFAULT_HOOK_TIMEOUT}）")
    ap.add_argument("--json", action="store_true", help="機械可読なJSONサマリを標準出力へ出す")
    ap.add_argument("--allow-hook-errors", action="store_true",
                     help="hook実行の異常（timeout・壊れた出力・非0終了）があってもexit 0にする"
                          "（既定は異常1件以上でexit 2＝recallの不一致とhookのインフラ異常を区別する）")
    args = ap.parse_args()

    hook_path = pathlib.Path(args.hook).resolve()
    if not hook_path.is_file():
        print(f"FAIL: hookが見つかりません: {hook_path}", file=sys.stderr)
        sys.exit(1)

    vault_root = pathlib.Path(args.vault).resolve()
    if not vault_root.is_dir():
        print(f"FAIL: vaultが見つかりません: {vault_root}", file=sys.stderr)
        sys.exit(1)

    try:
        rows = parse_bench_tsv(args.bench_tsv)
    except OSError as e:
        print(f"FAIL: ベンチTSVを読めません: {args.bench_tsv}（{e}）", file=sys.stderr)
        sys.exit(1)
    if not rows:
        print("FAIL: 採点対象がありません（TSVが空、または全行が不正/コメントでskipされました）。", file=sys.stderr)
        sys.exit(1)

    overlay_dir = None
    try:
        if args.alias_overlay:
            overlay_dir = build_overlay_vault(vault_root, pathlib.Path(args.alias_overlay).resolve())
            active_vault = overlay_dir
            vault_desc = f"{vault_root}（一時コピー: {overlay_dir}）"
        else:
            active_vault = vault_root
            vault_desc = str(vault_root)

        results = score(rows, hook_path, active_vault, args.session_id, args.hook_timeout)
    finally:
        if overlay_dir is not None:
            shutil.rmtree(overlay_dir, ignore_errors=True)

    total = len(results)
    hits = sum(1 for r in results if r["pass"])
    hook_errors = sum(1 for r in results if r["hook_error"])

    if args.json:
        print(json.dumps({
            "vault": vault_desc,
            "hook": str(hook_path),
            "overlay": bool(args.alias_overlay),
            "total": total,
            "hits": hits,
            "hit_rate": (hits / total) if total else 0.0,
            "hook_errors": hook_errors,
            "results": results,
        }, ensure_ascii=False, indent=2))
    else:
        print(format_human(results, vault_desc, hook_path, bool(args.alias_overlay)))
        if hook_errors:
            print(f"\n⚠️ {hook_errors}件でhookが異常終了/異常出力しました"
                  "（recallの不一致ではなくインフラ異常。上記の各行のhookエラー欄を確認）", file=sys.stderr)

    # hookのインフラ異常（timeout・壊れた出力・非0終了）は、recall本来の不一致（正常な
    # miss）と区別してexit 2にする（Codexレビュー指摘・Major: 常にexit 0だと、CI/自動運用で
    # 壊れたフックを「低いヒット率」と誤認しうる。--allow-hook-errorsで従来どおりexit 0に戻せる）。
    if hook_errors and not args.allow_hook_errors:
        sys.exit(2)


if __name__ == "__main__":
    main()
