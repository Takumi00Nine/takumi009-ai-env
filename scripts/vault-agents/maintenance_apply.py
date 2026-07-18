#!/usr/bin/env python3
"""maintenance.sh Phase 2「判断＋適用」の実装（設計書§2・§2.4・PR2）。

Phase 1 の3検出器（fragments_log.py・vault_inventory.py・knowledge_merge_
candidates.py）の `--json` 出力を集約し、ヘッドレスClaudeへ1回だけ投げて
JSON Schema制約付きの構造化出力を受け取り、検証のうえVaultへ適用する。

安全設計の骨子（設計書§2・2026-07-16リーダー品質指示「安全設計・失敗系テストは
一切簡略化不可」）:
  - ツール全無効化（`--tools ""` ＋ `--disable-slash-commands`）＋MCP二重遮断
    （`--strict-mcp-config`＝`--mcp-config`を渡さないことでMCPサーバ自体を
    ロードさせない・保険で`--disallowedTools "mcp__*"`も併用）。
  - 出力はJSON Schema制約（`--output-format json`＋`--json-schema`）。
  - 未知idの操作・schema違反・重複id・件数上限超過は1件でもあれば応答全体を
    不採用（部分適用しない・設計書§2.3）。
  - 全action適用直前に対象ソースを再読込しSHA-256をPhase1時点と再照合
    （TOCTOU対策・設計書§2.4）。
  - 新規ノート作成は最終パスへ直接`os.open(O_CREAT|O_EXCL|O_WRONLY)`（temp+
    renameは上書き防止にならないため使わない＝設計書§2.4改訂v2）。
  - PROMOTE先がPreferencesの場合のみ、書込前に共通Personalリンク検査＋
    ngwordsの機械ゲート（scripts/vault-agents/promote-preferences-gate.sh
    経由）を同期適用し、検出時はそのactionのみskip。
  - MERGEはmerge_checks.py（§2.5）全PASS必須＋週上限2件。
  - claude起動不可／timeout／schema違反／未知id参照のいずれでも「一切書き
    込まず」異常通知のみ（設計書§2.6）。本体はstatus-fileへ`anomaly: true`を
    書き、maintenance.sh（Phase3）が異常時のみmacOS通知する契約。

実機検証済みのフラグ（2026-07-16リーダー実施・claude 2.1.211）: `--tools`・
`--json-schema`・`--output-format`・`--system-prompt-file`・
`--disable-slash-commands`・`--strict-mcp-config`・`--disallowedTools` は
いずれも実在し動作確認済み（https://code.claude.com/docs/en/cli-reference・
2026-07-16 Web裏取り済み＝absolute-rules④）。JSON Schema指定時の応答は
`structured_output`キーに構造化出力が入る契約（同docs確認済み）。

責務外（このファイルが行わないこと）:
  - Phase 1 各検出器の起動・タイムアウト管理（maintenance_run_step.py の役目）。
  - Vault書込ロックの取得・解放（maintenance.sh Phase0の役目。本ファイルは
    既にロックが取得済みである前提で動く）。
  - Phase 3 の実施サマリ（Fragments当日ファイルへの1行追記）・通知
    （maintenance.shの役目。本ファイルは--status-file/apply-log.jsonという
    機械可読な結果だけを残す）。
"""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import unicodedata

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import fragments_log  # noqa: E402
import knowledge_merge_candidates  # noqa: E402
import merge_checks  # noqa: E402
import merge_state  # noqa: E402
import vault_lib  # noqa: E402

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent

# PROMOTE先の許可フォルダ（設計書§2.3/2.4改訂v2＝本人裁定でPreferencesも許可・
# 新規ノート作成のみ）。
PROMOTE_TARGET_FOLDERS = ("Knowledge", "Decisions", "Projects", "Preferences")

# MERGE週上限（設計書§1.2「MERGE（Knowledge非破壊マージ・上限2件）」）。
DEFAULT_MAX_MERGE_ACTIONS = 2

# Preferences向けPROMOTEの書込前ゲート（Personal link + ngwords）。
DEFAULT_GATE_SCRIPT = SCRIPT_DIR / "promote-preferences-gate.sh"
DEFAULT_NGWORDS_FILE = SCRIPT_DIR.parent / "ngwords.txt"

# ヘッドレスClaude呼び出しの既定値（本人追加要望＝モデル指定を設定可能にする。
# 実機スモークテストが高価な"fable"セッションモデルへ既定で寄っていたため、
# 週次バッチには不向き＝明示的にsonnetを既定にする＝設計書§2.1関連の実装時要望）。
DEFAULT_CLAUDE_BIN = os.environ.get("MAINTENANCE_APPLY_CLAUDE_BIN", "claude")
DEFAULT_MODEL = os.environ.get("MAINTENANCE_APPLY_MODEL", "sonnet")
DEFAULT_CLAUDE_TIMEOUT = 300.0

VALID_ACTIONS = ("promote", "merge", "fix_approve", "skip")

# validate_structured_output()のadditionalProperties:false相当チェック用
# （2026-07-16 Codex一次レビュー指摘Major対応）。build_output_schema()の
# JSON Schemaが定義するプロパティ名と一致させる。
_ACTION_ALLOWED_KEYS = frozenset({"id", "action", "target_folder", "body", "reason"})


# =============================================================================
# 決定的slug化（設計書§2.4「ファイル名はClaude生成titleではなく候補IDから
# 決定的slug化」）。ClaudeがVaultの実ファイル名に一切影響を与えられないように
# するための中核設計（Claudeが本文中にどんな見出し/題名を書いても、書込先の
# ファイル名はPhase1がPython側で決定した候補ID文字列からのみ導出される）。
# =============================================================================

_SLUG_INVALID_RE = re.compile(r"[^a-z0-9-]+")
_SLUG_DASH_COLLAPSE_RE = re.compile(r"-{2,}")
SLUG_MAX_LEN = 80


def slugify_id(raw_id):
    """候補ID文字列を決定的にslug化する（設計書§2.4: NFC正規化→ASCII fold→
    小文字化→[a-z0-9-]以外は-置換→重複-圧縮→長さ上限）。frag-/inv-/cand-の
    候補IDは元々[a-z0-9-]のみで構成されるためほぼ恒等変換になるが、ID形式が
    将来変わっても安全に動作するよう一般的なパイプラインとして実装する。
    結果が空文字列になった場合は呼び出し側がエラー扱いにすること。
    """
    s = unicodedata.normalize("NFC", raw_id)
    s = s.encode("ascii", "ignore").decode("ascii")
    s = s.lower()
    s = _SLUG_INVALID_RE.sub("-", s)
    s = _SLUG_DASH_COLLAPSE_RE.sub("-", s).strip("-")
    if len(s) > SLUG_MAX_LEN:
        s = s[:SLUG_MAX_LEN].rstrip("-")
    return s


# =============================================================================
# ヘッドレスClaude呼び出し
# =============================================================================

def build_system_prompt(max_merge_actions):
    """固定instruction（--system-prompt-fileへ渡す）。素材（fragments/
    fix_candidates/merge_candidates）は標準入力でJSONとして別途渡す
    （設計書§2.1「命令と素材は可能な限り分離」）。
    """
    return f"""あなたは外部脳(Obsidian Vault)の週次夜間メンテジョブです。
唯一のルール:「確定で大丈夫なものだけ機械的に修正し、疑いがあるものは触らず
放置する」。人間にもリーダーにも判断を運びません。迷ったら何もしない
（そのidをactionsに含めない、またはaction: skip にする）ことが常に正解です。

標準入力で渡されるJSON（フィールド: fragments・fix_candidates・
merge_candidates）を読み、指定されたJSON Schemaに厳密に適合する構造化出力
だけを返してください。それ以外の説明文・前置き・言い訳は一切出力しないで
ください。

# actionの種類
- promote: fragments内の1件を、確定した知見として1つの新規ノートへ昇格する。
  target_folder は "Knowledge"/"Decisions"/"Projects"/"Preferences" のいずれか。
  body には frontmatter（date/tags/project/aliases）込みの新規ノート全文を
  あなたが執筆して入れてください。
    - 昇格するか自信が持てない・内容が断片的・後で書き直しが要りそうな場合は
      昇格せず放置してください（fragmentは消えず来週以降も候補になります）。
    - target_folder に "Preferences" を選ぶ場合、そのノートは**公開
      （public）されます**。以下の4条を必ず守ってください（違反が検出された
      場合、機械ゲートによりそのactionだけ無条件でskipされます）:
        1. 個人情報・経緯・エピソードを書かない（「今どう動くか」だけに削ぐ）。
        2. ユーザーの呼び名（ハンドルネーム）を書かない
           （「ユーザー」「本人」等の中立表現。ID "takumi009" は可）。
        3. Personal配下へのwiki linkやPersonalノート名を書かない。
        4. ホーム配下の絶対パス（`~/`表記等）を書かない。
- merge: merge_candidates内の1件について、両ノートを1つの統合ノートへ非破壊
  マージする（最大週{max_merge_actions}件まで実際に適用されます。それを超える
  分は選ばれても適用時にskipされます。確信度の高い順にmergeを選んでください）。
  body には統合ノート全文（frontmatter込み）をあなたが執筆して入れてください。
  執筆時の鉄則（機械ゲートが検査します。1つでも満たさなければ統合ノート全体が
  不採用になり、両原ノートは変更されません）:
    - 両ノートの見出し文字列を一字も変えずに残す（階層変更・見出し追加は可）。
    - 両ノートの `updated` 日付を本文中に明記する。
    - コードブロック・出典URL・本文中の日付表記は一切変更しない。
    - aliasesは両ノートの和集合にする。
    - frontmatterの必須キー（両ノートにあったキー）を統合ノートにも残す。
  本当に内容が重複していて統合が明白な場合のみ選んでください。少しでも
  論点が違う・矛盾している・統合すると片方の主張が消えると感じたら見送って
  ください（見送りは相互再検討の対象として来週以降も候補になり得ます）。
- fix_approve: fix_candidates内の1件を承認する。修正後の値は既にPythonが
  決定的に計算済みで、あなたの出力に値を含める必要はありません
  （含めても無視されます）。relpath・現在の状況から見て承認して問題なければ
  承認、少しでも不自然（未来のイベントを示唆する日付・不整合）なら見送って
  ください。
- skip: 明示的に見送る場合に使えます（省略して単にactionsに含めなくても
  同じ意味＝両者に差はありません）。

# 厳守事項
- id は与えられた素材のidをそのまま正確にコピーしてください（改変・省略・
  捏造禁止）。1つのidを複数回使わないでください。
- Vaultの実ファイルパスは一切出力しないでください
  （id と action と、promoteのときのみ target_folder という「列挙値」だけを
  使います。ファイル名はあなたの出力からは一切導出されません）。
- 迷ったら何もしない。件数を稼ぐ必要はありません。0件の応答も正解です。
"""


def build_material(fragments, fix_candidates, merge_candidates):
    """ヘッドレスClaudeへ標準入力で渡す素材JSON（設計書§2.2「命令と素材は
    可能な限り分離」）。相手に実ファイルパスの手がかりを不必要に与えない
    ため、merge_candidatesにはnote_a/note_bのrelpathを含めない（統合ノート
    本文の執筆に必要なのは両ノートの本文テキストのみであり、ファイル名は
    apply層が候補IDから決定的に導出するためClaudeに知らせる必要がない）。
    """
    return {
        "fragments": [
            {"id": f["id"], "date": f.get("date"),
             "heading_or_bullet": f.get("heading_or_bullet"), "body": f.get("body")}
            for f in fragments
        ],
        "fix_candidates": [
            {"id": c["id"], "relpath": c.get("relpath"), "fix_date": c.get("fix_date")}
            for c in fix_candidates
        ],
        "merge_candidates": [
            {"id": m["id"], "note_a_text": m.get("note_a_text"), "note_b_text": m.get("note_b_text")}
            for m in merge_candidates
        ],
    }


def build_output_schema(frag_ids, fix_ids, merge_ids):
    """`--json-schema`へ渡すJSON Schema（設計書§2.3「additionalProperties:
    false・action enum・id正規表現・配列最大件数を強制」）。idはenumで既知
    集合に絞る（schema層での防御・多層防御の1枚目。真の権威はPython側の
    validate_structured_output()＝schema層の検証をclaude CLI自身がどこまで
    厳密に強制するかに依存せず、常に独立してPython側で再検証する）。
    """
    all_ids = sorted(frag_ids | fix_ids | merge_ids)
    return {
        "type": "object",
        "additionalProperties": False,
        "required": ["actions"],
        "properties": {
            "actions": {
                "type": "array",
                "maxItems": len(all_ids),
                "items": {
                    "type": "object",
                    "additionalProperties": False,
                    "required": ["id", "action"],
                    "properties": {
                        "id": {"type": "string", "enum": all_ids},
                        "action": {"type": "string", "enum": list(VALID_ACTIONS)},
                        "target_folder": {"type": "string", "enum": list(PROMOTE_TARGET_FOLDERS)},
                        "body": {"type": "string"},
                        "reason": {"type": "string"},
                    },
                },
            },
        },
    }


def invoke_claude(claude_bin, model, system_prompt_path, schema, material, timeout):
    """ヘッドレスClaudeを1回起動する（`--max-turns 1`）。

    戻り値: (structured_output_or_None, anomaly_kind_or_None, detail_or_None)。
    anomaly_kindがNoneでない場合、structured_outputは常にNone（呼び出し側は
    「一切書き込まない」＝設計書§2.6）。
    """
    prompt_text = (
        "以下は標準入力で渡すJSON素材です。system promptの指示に厳密に従い、"
        "指定されたJSON Schemaに適合する構造化出力のみを返してください。"
    )
    argv = [
        claude_bin, "-p", prompt_text,
        "--tools", "", "--disable-slash-commands", "--max-turns", "1",
        "--output-format", "json", "--json-schema", json.dumps(schema, ensure_ascii=False),
        # MCPの二重遮断（設計書§2.1・実装時要望: --toolsはMCPツールを対象外
        # とするため、--mcp-configを渡さないことでMCPサーバ自体を一切ロード
        # させない第一の壁＋--disallowedTools "mcp__*"を保険の第二の壁にする）。
        "--strict-mcp-config", "--disallowedTools", "mcp__*",
        "--model", model,
        "--system-prompt-file", str(system_prompt_path),
    ]
    stdin_payload = json.dumps(material, ensure_ascii=False)
    try:
        proc = subprocess.run(argv, input=stdin_payload, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError:
        return None, "spawn_error", f"claudeコマンドが見つかりません: {claude_bin}"
    except subprocess.TimeoutExpired:
        return None, "timeout", f"タイムアウトしました（{timeout}秒）"
    except OSError as e:
        return None, "spawn_error", str(e)

    if proc.returncode != 0:
        return None, "claude_exit_error", f"claudeが異常終了しました(rc={proc.returncode}): {proc.stderr[:2000]}"

    try:
        response = json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        return None, "invalid_json", f"claude出力をJSONとして解析できません: {e}"
    if not isinstance(response, dict):
        return None, "invalid_json", "claude出力のトップレベルがオブジェクトではありません"

    if response.get("is_error"):
        return None, "claude_is_error", f"claudeがis_error=trueを返しました: {response.get('result')!r}"

    # 設計書§2.1「ツールが1つでも有効なままならその回のPhase2は『異常』として
    # 中止しフォールバック」。--tools ""でツール全無効化した実機検証
    # （2026-07-16・claude 2.1.211。--output-format json実行の生JSONで
    # トップレベルに"permission_denials":[]が含まれることをリーダーが実測
    # 確認済み）で確認できたpermission_denialsフィールドを空配列であることの
    # 傍証として使う（ツール使用を試みてdenyされた形跡があれば異常）。
    # フィールド自体が存在しない応答形状であっても、それだけを理由に失敗
    # させない（fail-open。将来のCLIバージョンでフィールド名/形状が変わる
    # 可能性への防御的な保険として維持する）。
    # フィールドが存在するのにlist型でない（dict/文字列等）場合も、想定外の
    # 応答形状としてfail-closedで異常扱いにする（2026-07-16 Codex一次レビュー
    # 指摘Minor対応: 従来は`isinstance(denials, list) and denials`のみで、
    # list以外の型は無条件で「異常なし」を素通りしていた）。
    denials = response.get("permission_denials")
    if denials is not None:
        if not isinstance(denials, list):
            return None, "tool_use_detected", f"permission_denialsの型が想定外です: {denials!r}"
        if denials:
            return None, "tool_use_detected", f"permission_denialsが空ではありません: {denials!r}"

    structured = response.get("structured_output")
    if structured is None:
        return None, "no_structured_output", "claude応答にstructured_outputがありません（schema不適合の可能性）"
    return structured, None, None


def validate_structured_output(data, frag_ids, fix_ids, merge_ids):
    """Claude応答の構造化出力を検証する（設計書§2.3「未知idの操作・schema
    違反・重複id・上限超過は1件でもあれば応答全体を不採用（部分適用しない）」）。

    schema自体（--json-schemaでclaude CLIに強制させた形状）を信頼しきらず、
    ここで独立に完全な再検証を行う（fail-closedの徹底＝merge_checks.pyの
    overlays必須化と同じ設計哲学）。action種別とid種別（frag-/inv-/cand-が
    どの候補集合に属するか）の不一致（例: fragment idにaction: mergeを
    指定）も「未知idの操作」の一種としてここで拒否する（応答全体を不採用に
    する＝individual skipで済ませない）。

    戻り値: (actions_list, None) または (None, エラー理由の文字列)。
    """
    if not isinstance(data, dict):
        return None, "structured_outputがオブジェクトではありません"
    # トップレベルのadditionalProperties:false相当（2026-07-16 Codex一次レビュー
    # 指摘Major対応: --json-schemaでCLIへ強制させた形状をPython側で再現せず、
    # "actions"以外の未知キーが素通りしていた）。
    if set(data.keys()) - {"actions"}:
        return None, f"未知のトップレベルキーがあります: {sorted(set(data.keys()) - {'actions'})}"
    actions = data.get("actions")
    if not isinstance(actions, list):
        return None, "actionsが配列ではありません"

    all_ids = frag_ids | fix_ids | merge_ids
    if len(actions) > len(all_ids):
        return None, f"actions件数({len(actions)})が候補件数({len(all_ids)})を超えています"

    seen = set()
    validated = []
    for a in actions:
        if not isinstance(a, dict):
            return None, "actions内に非オブジェクトの要素があります"
        # action要素側のadditionalProperties:false相当（同上のCodex指摘対応）。
        unknown_keys = set(a.keys()) - _ACTION_ALLOWED_KEYS
        if unknown_keys:
            return None, f"actions要素に未知のキーがあります: {sorted(unknown_keys)}"
        aid, kind = a.get("id"), a.get("action")
        if not isinstance(aid, str) or not isinstance(kind, str):
            return None, "id/actionが文字列ではない要素があります"
        if "reason" in a and not isinstance(a["reason"], str):
            return None, f"reasonが文字列ではありません: {aid}"
        if "target_folder" in a and not isinstance(a["target_folder"], str):
            return None, f"target_folderが文字列ではありません: {aid}"
        if aid not in all_ids:
            return None, f"未知のid参照: {aid}"
        if aid in seen:
            return None, f"idの重複: {aid}"
        seen.add(aid)
        if kind not in VALID_ACTIONS:
            return None, f"不正なaction: {aid}={kind}"
        if kind == "promote" and aid not in frag_ids:
            return None, f"id種別とactionの不一致（promoteはfragment idのみ許可）: {aid}"
        if kind == "merge" and aid not in merge_ids:
            return None, f"id種別とactionの不一致（mergeはmerge candidate idのみ許可）: {aid}"
        if kind == "fix_approve" and aid not in fix_ids:
            return None, f"id種別とactionの不一致（fix_approveはinventory idのみ許可）: {aid}"
        if kind == "promote":
            if a.get("target_folder") not in PROMOTE_TARGET_FOLDERS:
                return None, f"promoteのtarget_folderが不正です: {aid}"
            if not isinstance(a.get("body"), str) or not a["body"].strip():
                return None, f"promoteにbodyがありません: {aid}"
        if kind == "merge":
            if not isinstance(a.get("body"), str) or not a["body"].strip():
                return None, f"mergeにbodyがありません: {aid}"
        validated.append(a)
    return validated, None


# =============================================================================
# 共通ヘルパ（Vault境界・排他書込・ゲート呼び出し）
# =============================================================================

def safe_new_note_path(vault_root, target_folder, filename):
    """新規ノート作成用のパスを検証する（設計書§2.4改訂v2「apply層で
    resolve()＋Vault境界検査＋symlink拒否を自前実装する（流用関数単体には
    境界保証が無いため）」）。target_folderディレクトリ自体がsymlinkの場合や
    Vault境界外へ解決される場合はNoneを返す。対象ファイル自体の存在チェック・
    最終的なsymlink拒否はexclusive_create()側のO_EXCL+O_NOFOLLOWで行う
    （TOCTOU: このチェックとopen()の間でtarget_folderがsymlinkへ差し替え
    られる可能性はO_NOFOLLOWがsymlink化されたfilenameを拒否することで
    軽減する。target_folderディレクトリそのものの差し替えは
    knowledge_merge_candidates._read_note_text_or_none()と同じ既知の残存
    限界＝単一ユーザーのローカルVault専用CLIとして受容）。
    """
    vault_root = pathlib.Path(vault_root).resolve()
    folder_dir = vault_root / target_folder
    try:
        resolved_folder = folder_dir.resolve()
    except OSError:
        return None
    if not (resolved_folder == vault_root or resolved_folder.is_relative_to(vault_root)):
        return None
    if not folder_dir.is_dir() or folder_dir.is_symlink():
        return None
    return resolved_folder / filename


def exclusive_create(path, text):
    """新規ノートを最終パスへ直接`os.open(O_CREAT|O_EXCL|O_WRONLY)`で排他
    書込する（設計書§2.4改訂v2「temp+renameは上書き防止にならない
    （os.replaceは常に成功する）→新規ノートは最終パスへ直接
    O_CREAT|O_EXCL|O_WRONLYで書く」）。O_NOFOLLOWも付与し、対象パスが既に
    symlinkとして存在する場合も拒否する。
    """
    flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(str(path), flags, 0o644)
    except FileExistsError:
        return False, "already_exists"
    except OSError as e:
        return False, str(e)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            fd = None
            f.write(text)
    except OSError as e:
        return False, str(e)
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
    return True, None


def run_preferences_gate(gate_script, vault_root, body_text, ngwords_file):
    """PROMOTE先がPreferencesの場合の書込前ゲート（設計書§2.4改訂v2「事前
    ゲート: Preferences向けPROMOTEの最終全文にPersonalリンク検査＋ngwords
    チェックを同期適用。検出したらそのactionのみskip」）。
    scripts/vault-agents/promote-preferences-gate.sh（personal-link-check.sh
    を再利用）へ委譲する。戻り値: (ok: bool, reason_or_None)。
    """
    fd, tmp_path = tempfile.mkstemp(suffix=".md", prefix=".promote-gate-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(body_text)
        argv = ["bash", str(gate_script), "--vault", str(vault_root), "--text-file", tmp_path]
        if ngwords_file:
            argv += ["--ngwords-file", str(ngwords_file)]
        try:
            proc = subprocess.run(argv, capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired) as e:
            return False, f"gate_execution_error: {e}"
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
    if proc.returncode == 0:
        return True, None
    return False, (proc.stderr.strip() or f"gate_exit_{proc.returncode}")


# =============================================================================
# PROMOTE（Fragments昇格）
# =============================================================================

def find_existing_promoted_file(vault_root, slug):
    """4つのPROMOTE先フォルダいずれかに`<slug>.md`が既に存在するかを調べる
    （設計書§2.4「②失敗/クラッシュ時は次回実行で『同一slugの既存ファイル』を
    検知し②のみ再試行（冪等リトライ方式＝B案採用）」の判定に使う）。存在すれば
    そのフォルダ名を、無ければNoneを返す。前回実行がClaudeの選んだ
    target_folderに関わらず「このIDは既にどこかへ昇格済み」と判定できるよう、
    4フォルダ全部を見る（前回と今回でClaudeの判断が変わり得るため）。

    symlinkは対象外にする（2026-07-16 Codex一次レビュー指摘Minor対応:
    `is_file()`はsymlinkも透過的に真を返すため、対象パスがVault外を指す
    symlinkであってもこの判定だけでは検知できず、Fragments側のリンクを
    Vault外参照へ誤って紐付けかねない。symlinkが存在する場合は「既存の
    昇格済みファイルではない」とみなし、通常のstep1新規作成経路
    （safe_new_note_path→exclusive_create のO_EXCL+O_NOFOLLOW）に委ねる）。

    対象フォルダ自体（例: Knowledge/）がsymlinkの場合も同様に拒否する
    （2026-07-16 Codex三次レビュー指摘Major対応: `p.is_symlink()`は最終
    パス要素しか見ないため、親フォルダ自体がVault外へのsymlinkに差し替え
    られていると、その配下の無関係な通常ファイルを「既に昇格済み」と誤認
    しうる欠陥があった。フォルダ自体のsymlink拒否＋resolve後のVault境界
    検査を追加する）。
    """
    resolved_vault = pathlib.Path(vault_root).resolve()
    for folder in PROMOTE_TARGET_FOLDERS:
        folder_dir = pathlib.Path(vault_root) / folder
        if folder_dir.is_symlink():
            continue
        try:
            resolved_folder = folder_dir.resolve()
        except OSError:
            continue
        if not (resolved_folder == resolved_vault or resolved_folder.is_relative_to(resolved_vault)):
            continue
        p = resolved_folder / f"{slug}.md"
        if p.is_file() and not p.is_symlink():
            return folder
    return None


def locate_fragment_block(text, target_id, source_relpath):
    """Fragments日次テキストからtarget_idに対応するブロックを探し、行範囲を
    返す（fragments_log.extract_entries()と同じ抽出ロジックだが、書込み用に
    body文字列ではなく行インデックス範囲を返す点が異なる）。
    戻り値: {"kind": "heading"|"bullet", "start": int, "end": int} または
    見つからなければNone（endはheadingでは次見出し/EOFのexclusive index、
    bulletでは start+1）。
    """
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        m_h = fragments_log.HEADING_RE.match(lines[i])
        m_b = fragments_log.BULLET_RE.match(lines[i])
        if m_h:
            j = i + 1
            while j < len(lines) and not fragments_log.HEADING_RE.match(lines[j]):
                j += 1
            heading = m_h.group(1).strip()
            if fragments_log.stable_fragment_id(source_relpath, heading) == target_id:
                return {"kind": "heading", "start": i, "end": j}
            i = j
        elif m_b:
            bullet = m_b.group(1).strip()
            if fragments_log.stable_fragment_id(source_relpath, bullet) == target_id:
                return {"kind": "bullet", "start": i, "end": i + 1}
            i += 1
        else:
            i += 1
    return None


def apply_promoted_marker(text, loc, link_target_no_ext):
    """locが指すブロックへ`status: promoted`＋リンクを追記する（設計書§2.4
    「②成功したらFragments当日ファイルの該当ブロックへstatus: promoted＋
    リンク追記」）。headingブロックはブロック末尾（次見出し/EOFの直前）へ新規
    行を挿入、bulletブロックは1行しかないため同じ行の末尾に追記する
    （fragments_log.STATUS_REは`status:\\s*(promoted|published|生)`を
    ブロック本文全体に対して検索するため、どちらの挿入位置でも次回スキャン時に
    正しく`status: promoted`として検出される）。
    """
    lines = text.splitlines()
    marker = f"status: promoted → [[{link_target_no_ext}]]"
    if loc["kind"] == "heading":
        lines.insert(loc["end"], marker)
    else:
        lines[loc["start"]] = lines[loc["start"]] + f" ({marker})"
    out = "\n".join(lines)
    return out + "\n" if text.endswith("\n") else out


def apply_promote(vault_root, frag_rec, act, today_iso, gate_script, ngwords_file, dry_run, source_cache):
    aid = frag_rec["id"]
    target_folder = act.get("target_folder")
    body = act.get("body")

    if target_folder not in PROMOTE_TARGET_FOLDERS:
        return {"id": aid, "action": "promote", "applied": False, "reason": "invalid_target_folder"}
    if not isinstance(body, str) or not body.strip():
        return {"id": aid, "action": "promote", "applied": False, "reason": "empty_body"}
    if not body.lstrip().startswith("---"):
        return {"id": aid, "action": "promote", "applied": False, "reason": "body_missing_frontmatter"}

    source_relpath = frag_rec.get("source_relpath")
    source_path = pathlib.Path(vault_root) / source_relpath
    # Vault全体ではなくVault/Fragments配下であることを要求する（2026-07-16
    # Codex三次レビュー指摘Major対応: _validate_fragment_record()が既に
    # source_relpathの構造を検証しているが、apply_promote()自体が将来
    # 未検証のレコードで直接呼ばれる経路が増えても安全なように、適用時にも
    # 独立してFragments配下限定の境界検査を行う＝多層防御）。
    resolved_vault = pathlib.Path(vault_root).resolve()
    resolved_fragments_root = resolved_vault / "Fragments"
    try:
        resolved_source = source_path.resolve()
        resolved_source.relative_to(resolved_fragments_root)
    except (OSError, ValueError):
        return {"id": aid, "action": "promote", "applied": False, "reason": "source_vault_boundary_violation"}

    cached = source_cache.get(source_relpath)
    if cached is None:
        # 初回参照: Phase1時点のsource_sha256と実際に照合する（真のTOCTOU検査）。
        try:
            current_source_text = source_path.read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            return {"id": aid, "action": "promote", "applied": False, "reason": "source_unreadable_toctou"}
        current_sha = hashlib.sha256(current_source_text.encode("utf-8")).hexdigest()
        if current_sha != frag_rec.get("source_sha256"):
            return {"id": aid, "action": "promote", "applied": False, "reason": "source_changed_toctou"}
        source_cache[source_relpath] = current_source_text
    else:
        # 同一実行内で既に他のfragmentのPROMOTEが同じFragments日次ファイルへ
        # 書込み済み（2026-07-16 Codex一次レビュー指摘Major対応: 同じ日次
        # ファイルから複数件PROMOTEすると、1件目のstep2書込みでファイル全体の
        # SHA-256が変わり、Phase1時点のsource_sha256と2件目以降が毎回不一致に
        # なって誤ってsource_changed_toctouでskipされていた。maintenance.shが
        # Phase0〜Phase3までVault書込ロックを保持する前提のため、このプロセス
        # 自身の書込み以外の理由でこの実行時間内にファイルが変わることは
        # 想定しない。「このプロセス自身が最後に書いた内容」をキャッシュし
        # 次のPROMOTEの土台にする＝真のTOCTOU検査は各ファイルにつき初回の
        # ディスク読込時にのみ行う）。
        current_source_text = cached

    if target_folder == "Preferences":
        gate_ok, gate_reason = run_preferences_gate(gate_script, vault_root, body, ngwords_file)
        if not gate_ok:
            return {"id": aid, "action": "promote", "applied": False,
                    "reason": f"preferences_gate_detected: {gate_reason}"}

    slug = slugify_id(aid)
    if not slug:
        return {"id": aid, "action": "promote", "applied": False, "reason": "empty_slug"}
    filename = f"{slug}.md"

    existing_folder = find_existing_promoted_file(vault_root, slug)
    if existing_folder is not None:
        # 冪等リトライ経路: ①(新規ノート作成)は前回実行で既に完了済みとみなし、
        # ②(Fragmentsマーキング)のみ再試行する。
        link_target_folder = existing_folder
        step1_status = "already_exists"
        write_path_relpath = f"{existing_folder}/{filename}"
    else:
        new_path = safe_new_note_path(vault_root, target_folder, filename)
        if new_path is None:
            return {"id": aid, "action": "promote", "applied": False, "reason": "target_folder_unsafe"}
        if dry_run:
            step1_status = "dry_run_would_create"
        else:
            ok, err = exclusive_create(new_path, body)
            if not ok:
                return {"id": aid, "action": "promote", "applied": False, "reason": f"create_failed:{err}"}
            step1_status = "created"
        link_target_folder = target_folder
        write_path_relpath = f"{target_folder}/{filename}"

    loc = locate_fragment_block(current_source_text, aid, source_relpath)
    if loc is None:
        return {"id": aid, "action": "promote", "applied": step1_status != "dry_run_would_create",
                "reason": "note_path", "note_path": write_path_relpath,
                "step1": step1_status, "step2": "source_block_not_found"}

    block_text_now = "\n".join(current_source_text.splitlines()[loc["start"]:loc["end"]])
    if fragments_log.STATUS_RE.search(block_text_now):
        step2_status = "already_marked"
    elif dry_run:
        step2_status = "dry_run_would_mark"
    else:
        # 書込み直前にもう一度だけディスクを読み、`current_source_text`
        # （初回はPhase1照合済みの実測値、2件目以降はこのプロセス自身が最後に
        # 書いた内容のキャッシュ）と一致するかを最終確認する（2026-07-16
        # Codex二次レビュー指摘Major対応「TOCTOU再照合後にも競合窓が残る」。
        # Preferencesゲート・O_EXCL作成を挟んだ後の最終防御。自分自身の直前の
        # 書込みは`current_source_text`＝キャッシュ済みの値と一致するため
        # 誤検知しない。外部からの変更だけを検出する）。
        # ここまで来た時点でstep1（新規ノート作成 or 既存ファイル検知）は既に
        # 完了しているため、以降でstep2を見送る場合もapplied自体は
        # `step1_status != "dry_run_would_create"`に揃える（620行目の
        # source_block_not_found時と同じ規約）。
        try:
            recheck_text = resolved_source.read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            return {"id": aid, "action": "promote", "applied": step1_status != "dry_run_would_create",
                    "note_path": write_path_relpath, "step1": step1_status,
                    "step2": "source_unreadable_at_final_recheck"}
        if recheck_text != current_source_text:
            return {"id": aid, "action": "promote", "applied": step1_status != "dry_run_would_create",
                    "note_path": write_path_relpath, "step1": step1_status,
                    "step2": "source_changed_at_final_recheck"}

        link_target_no_ext = f"{link_target_folder}/{slug}"
        new_source_text = apply_promoted_marker(current_source_text, loc, link_target_no_ext)
        vault_lib.write_note_atomic(resolved_source, new_source_text)
        step2_status = "marked"
        source_cache[source_relpath] = new_source_text  # 次の同一ファイル向けPROMOTEはこれを土台にする

    return {"id": aid, "action": "promote", "applied": True, "note_path": write_path_relpath,
            "step1": step1_status, "step2": step2_status}


# =============================================================================
# FIX（棚卸し機械修正・missing_updatedのみ＝設計書§3.5）
# =============================================================================

def apply_fix_updated(text, fix_date):
    """FIXの値（Phase1で決定的に計算済みのfix_date）をfrontmatterの
    updated:へ適用する（vault_lib.apply_updated()＝apply_aliases.py由来の
    共有ヘルパをそのまま再利用。frontmatter以外の本文には一切触れない）。
    frontmatterが見つからなければNoneを返す。
    """
    m = vault_lib.FRONTMATTER_RE.match(text)
    if not m:
        return None
    lines = m.group(1).split("\n")
    rest = text[m.end():]
    lines = vault_lib.apply_updated(lines, fix_date)
    return "---\n" + "\n".join(lines) + "\n---\n" + rest


def apply_fix(vault_root, fix_rec, dry_run):
    aid = fix_rec["id"]
    relpath = fix_rec.get("relpath")
    path = pathlib.Path(vault_root) / relpath
    try:
        resolved = path.resolve()
        resolved.relative_to(pathlib.Path(vault_root).resolve())
    except (OSError, ValueError):
        return {"id": aid, "action": "fix_approve", "applied": False, "reason": "vault_boundary_violation"}
    try:
        current_text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return {"id": aid, "action": "fix_approve", "applied": False, "reason": "unreadable_toctou"}
    current_sha = hashlib.sha256(current_text.encode("utf-8")).hexdigest()
    if current_sha != fix_rec.get("source_sha256"):
        return {"id": aid, "action": "fix_approve", "applied": False, "reason": "source_changed_toctou"}

    # sha256一致は「Phase1がこの値を検出した時点の全文と現在の全文が完全一致」を
    # 意味するため、Phase1が同じ全文から計算したfix_dateはfm["date"]と必ず
    # 一致し、updatedキーも欠落しているはずである（数学的に導かれる）。それでも
    # 直接確認しておく（2026-07-16 Codex二次レビュー指摘Major対応: sha256照合
    # だけに依存せず、実際にfrontmatterを見て「今も本当にupdatedが無く、
    # dateがfix_dateと一致する」ことを確認する多層防御。中間JSON改ざんで
    # fix_date単体だけが書き換えられていた場合でもここで検知できる）。
    fm_now, _ = vault_lib.parse_frontmatter(current_text)
    if "updated" in fm_now:
        return {"id": aid, "action": "fix_approve", "applied": False, "reason": "updated_already_present"}
    if fm_now.get("date") != fix_rec.get("fix_date"):
        return {"id": aid, "action": "fix_approve", "applied": False, "reason": "fix_date_mismatch"}

    new_text = apply_fix_updated(current_text, fix_rec.get("fix_date"))
    if new_text is None:
        return {"id": aid, "action": "fix_approve", "applied": False, "reason": "no_frontmatter"}

    if dry_run:
        return {"id": aid, "action": "fix_approve", "applied": True, "relpath": relpath, "reason": "dry_run"}

    # 書込み直前にもう一度だけ再読込し、ここまでの処理中に外部で変更されて
    # いないかを最終確認する（2026-07-16 Codex二次レビュー指摘Major対応
    # 「TOCTOU再照合後にも競合窓が残る」。FIXは介在処理が軽量なため窓は
    # 元々小さいが、一貫した安全網として同じパターンを適用する）。
    try:
        recheck_text = resolved.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return {"id": aid, "action": "fix_approve", "applied": False, "reason": "unreadable_at_final_recheck"}
    if recheck_text != current_text:
        return {"id": aid, "action": "fix_approve", "applied": False, "reason": "source_changed_at_final_recheck"}

    vault_lib.write_note_atomic(resolved, new_text)
    return {"id": aid, "action": "fix_approve", "applied": True, "relpath": relpath}


# =============================================================================
# MERGE（Knowledge非破壊マージ）
# =============================================================================

def _parse_updated_date(fm):
    val = fm.get("updated")
    if not isinstance(val, str):
        return None
    try:
        return datetime.date.fromisoformat(val.strip())
    except ValueError:
        return None


def determine_primary(relpath_a, text_a, relpath_b, text_b):
    """primaryノート（統合後に生き残るファイル名の元になるノート）を決める
    （リーダー裁定「primary＝2ノートのうちfrontmatter updatedが新しい方。
    同値ならファイル名昇順で先」）。updatedが片方にしか無い/不正な場合は
    「値がある方」を優先し、両方欠落/不正/同値ならファイル名の昇順で決める。
    """
    fm_a, _ = vault_lib.parse_frontmatter(text_a)
    fm_b, _ = vault_lib.parse_frontmatter(text_b)
    d_a, d_b = _parse_updated_date(fm_a), _parse_updated_date(fm_b)
    if d_a is not None and d_b is not None and d_a != d_b:
        return (relpath_a, text_a) if d_a > d_b else (relpath_b, text_b)
    if d_a is not None and d_b is None:
        return (relpath_a, text_a)
    if d_b is not None and d_a is None:
        return (relpath_b, text_b)
    return (relpath_a, text_a) if relpath_a <= relpath_b else (relpath_b, text_b)


_DEPRECATED_LINE_RE = re.compile(r"^deprecated:\s*.*$")
_SUPERSEDED_LINE_RE = re.compile(r"^superseded_by:\s*.*$")


def _set_scalar_line(lines, key_re, key, value):
    for i, line in enumerate(lines):
        if key_re.match(line):
            lines[i] = f"{key}: {value}"
            return lines
    lines.append(f"{key}: {value}")
    return lines


def build_merge_stub_text(orig_text, merged_relpath, today_iso):
    """原ノートの非破壊スタブ本文を作る（旧・knowledge_merge.py
    build_stub()の踏襲＝git log参照: 元frontmatterをほぼそのまま温存し
    deprecated/superseded_by/updatedのみ上書き、本文はポインタ1行に置換する。
    「原文温存」は本文をライブファイルに残すという意味ではなく、削除せず
    git履歴として残す＝非破壊の意味＝[[Decisions/2026-07-16-nightly-batch-
    direct-write]]。full再シリアライズ(dictからのYAML再構築)はせず、
    apply_fix_updated()と同じ行ベース編集にとどめてフォーマット崩れの
    リスクを避ける）。frontmatterが無いノートはNoneを返す（呼び出し側で
    skip）。
    """
    m = vault_lib.FRONTMATTER_RE.match(orig_text)
    if not m:
        return None
    fm_lines = m.group(1).split("\n")
    merged_ref = merged_relpath[:-3] if merged_relpath.endswith(".md") else merged_relpath
    fm_lines = _set_scalar_line(fm_lines, _DEPRECATED_LINE_RE, "deprecated", "true")
    fm_lines = _set_scalar_line(fm_lines, _SUPERSEDED_LINE_RE, "superseded_by", f"[[{merged_ref}]]")
    fm_lines = vault_lib.apply_updated(fm_lines, today_iso)
    stub_body = f"\n> このノートは [[{merged_ref}]] に統合されました。\n"
    return "---\n" + "\n".join(fm_lines) + "\n---\n" + stub_body


def mark_candidate_merged(state_dir, lock_file, cid, merged_relpath, today_iso):
    """state.json内の候補をmerged終端へ遷移する（merge_state.py・検出器と
    apply層が同じstate.json・同じロックを共有する契約）。ロック取得不能・
    state破損時はfail-open（Vaultへのファイル書込自体は既に完了しているため、
    state.json更新の失敗はここでは致命的としない＝呼び出し側がwarningとして
    記録する）。
    """
    state_path = pathlib.Path(state_dir) / "state.json"
    held = merge_state.acquire_lock(lock_file)
    if held is None:
        return False, "lock_unavailable"
    try:
        try:
            state = merge_state.load_state(state_path)
        except merge_state.StateError as e:
            return False, f"state_error: {e}"
        cand = state.get("candidates", {}).get(cid)
        if cand is None:
            return False, "candidate_missing_in_state"
        cand["status"] = "merged"
        cand["merged_at"] = today_iso
        cand["merged_relpath"] = merged_relpath
        merge_state.save_state(state_path, state)
        return True, None
    finally:
        merge_state.release_lock(held)


def apply_merge(vault_root, merge_rec, act, today_iso, dry_run, merge_state_dir, merge_lock_file):
    aid = merge_rec["id"]
    body = act.get("body")
    if not isinstance(body, str) or not body.strip():
        return {"id": aid, "action": "merge", "applied": False, "reason": "empty_body"}
    if not body.lstrip().startswith("---"):
        return {"id": aid, "action": "merge", "applied": False, "reason": "body_missing_frontmatter"}

    note_a, note_b = merge_rec.get("note_a"), merge_rec.get("note_b")
    if not isinstance(note_a, str) or not isinstance(note_b, str):
        return {"id": aid, "action": "merge", "applied": False, "reason": "invalid_candidate_record"}
    if (not knowledge_merge_candidates._is_direct_merge_eligible_note(note_a)
            or not knowledge_merge_candidates._is_direct_merge_eligible_note(note_b)):
        return {"id": aid, "action": "merge", "applied": False, "reason": "not_merge_eligible"}

    # TOCTOU再照合（設計書§2.4「全action適用直前に対象ソースファイルを
    # 再読込しSHA-256をPhase1時点と再照合、不一致ならそのactionのみskip」）。
    text_a = knowledge_merge_candidates._read_note_text_or_none(vault_root, note_a)
    text_b = knowledge_merge_candidates._read_note_text_or_none(vault_root, note_b)
    if text_a is None or text_b is None:
        return {"id": aid, "action": "merge", "applied": False, "reason": "note_unreadable_toctou"}
    if (hashlib.sha256(text_a.encode("utf-8")).hexdigest() != merge_rec.get("note_a_sha256")
            or hashlib.sha256(text_b.encode("utf-8")).hexdigest() != merge_rec.get("note_b_sha256")):
        return {"id": aid, "action": "merge", "applied": False, "reason": "note_changed_toctou"}

    primary_relpath, _ = determine_primary(note_a, text_a, note_b, text_b)
    primary_stem = pathlib.PurePosixPath(primary_relpath).stem
    today_ymd = today_iso.replace("-", "")
    merged_relpath = f"Knowledge/{primary_stem}--merged-{today_ymd}.md"

    stub_a = build_merge_stub_text(text_a, merged_relpath, today_iso)
    stub_b = build_merge_stub_text(text_b, merged_relpath, today_iso)
    if stub_a is None or stub_b is None:
        return {"id": aid, "action": "merge", "applied": False, "reason": "orig_note_no_frontmatter"}

    overlays = {merged_relpath: body, note_a: stub_a, note_b: stub_b}
    check = merge_checks.run_all_checks(text_a, text_b, body, str(vault_root), overlays)
    if check.get("pass") is not True:
        return {"id": aid, "action": "merge", "applied": False, "reason": "merge_checks_failed",
                "check_detail": check}

    new_path = safe_new_note_path(vault_root, "Knowledge", pathlib.PurePosixPath(merged_relpath).name)
    if new_path is None:
        return {"id": aid, "action": "merge", "applied": False, "reason": "target_folder_unsafe"}

    if dry_run:
        return {"id": aid, "action": "merge", "applied": True, "merged_relpath": merged_relpath,
                "reason": "dry_run"}

    ok, err = exclusive_create(new_path, body)
    if not ok:
        return {"id": aid, "action": "merge", "applied": False, "reason": f"create_failed:{err}"}

    # 統合ノート作成(O_EXCL)完了後・原ノート2件をスタブ化する前に、もう一度
    # TOCTOU再照合する（2026-07-16 Codex一次レビュー指摘Major対応「適用直前の
    # TOCTOU再照合後にも競合窓が残る」: merge_checks.run_all_checks()は
    # Vault全体のwikilinkを走査するため相応の時間がかかりうり、最初のTOCTOU
    # 検査からこの時点までの間に原ノートが変わる余地があった）。この再照合が
    # 失敗した場合、統合ノートは既に作成済みのため完全なロールバックはしない
    # （PROMOTE同様、専用journal機構は追加しない＝リーダー裁定「専用journal
    # 不採用」をMERGEにも一般化）。原ノート2件はこの場合変更せず、結果へ
    # partial_merge_state=Trueを明記して棚卸し相談での目視回収対象にする。
    text_a_recheck = knowledge_merge_candidates._read_note_text_or_none(vault_root, note_a)
    text_b_recheck = knowledge_merge_candidates._read_note_text_or_none(vault_root, note_b)
    if text_a_recheck != text_a or text_b_recheck != text_b:
        return {"id": aid, "action": "merge", "applied": True, "merged_relpath": merged_relpath,
                "partial_merge_state": True,
                "reason": "note_changed_after_merged_note_created_stubs_not_written"}

    # 原ノート2件を非破壊スタブ化する。書込み自体が例外を送出した場合
    # （ディスク枯渇・権限変化等）も、統合ノートは既に作成済みのため
    # main()まで例外を伝播させず構造化結果として記録する（2026-07-16 Codex
    # 一次レビュー指摘Major対応「MERGE途中のI/O失敗で部分適用となり、
    # status-fileも残らない」＝例外未捕捉でstatus-file自体が書かれない事故を
    # 防ぐ。低頻度(週2件上限)・非破壊・git監査ありの運用特性を前提にした
    # §2.7の受容範囲内での「記録だけは必ず残す」対応）。
    try:
        path_a = (pathlib.Path(vault_root) / note_a).resolve()
        path_b = (pathlib.Path(vault_root) / note_b).resolve()
        vault_lib.write_note_atomic(path_a, stub_a)
        vault_lib.write_note_atomic(path_b, stub_b)
    except OSError as e:
        return {"id": aid, "action": "merge", "applied": True, "merged_relpath": merged_relpath,
                "partial_merge_state": True, "reason": f"stub_write_failed:{e}"}

    ok_state, state_reason = mark_candidate_merged(merge_state_dir, merge_lock_file, aid, merged_relpath, today_iso)
    result = {"id": aid, "action": "merge", "applied": True, "merged_relpath": merged_relpath}
    if not ok_state:
        result["state_update_warning"] = state_reason
    return result


# =============================================================================
# オーケストレーション
# =============================================================================

def apply_actions(vault_root, actions, fragments_by_id, fix_by_id, merge_by_id, *, today_iso,
                   max_merge_actions, gate_script, ngwords_file, dry_run, merge_state_dir, merge_lock_file):
    results = []
    merge_applied = 0
    # 同一実行内で同じFragments日次ファイルから複数件PROMOTEする場合に
    # 使う共有キャッシュ（apply_promote()のsource_cache引数参照・2026-07-16
    # Codex一次レビュー指摘Major対応）。
    source_cache = {}
    for act in actions:
        aid, kind = act["id"], act["action"]
        if kind == "skip":
            results.append({"id": aid, "action": "skip", "applied": False, "reason": act.get("reason") or "claude_skip"})
            continue
        # 個々のaction適用中の予期しない例外（ディスクI/Oエラー・権限変化等）が
        # main()まで伝播してstatus-file/apply-log.json自体が書かれずに
        # プロセスがクラッシュする事故を防ぐ（2026-07-16 Codex一次レビュー
        # 指摘Major対応「MERGE途中のI/O失敗でstatus-fileも残らない」の
        # 一般化＝PROMOTE/FIXも含め全action種別に同じ安全網を適用する）。
        try:
            if kind == "promote":
                results.append(apply_promote(vault_root, fragments_by_id[aid], act, today_iso,
                                              gate_script, ngwords_file, dry_run, source_cache))
            elif kind == "fix_approve":
                results.append(apply_fix(vault_root, fix_by_id[aid], dry_run))
            elif kind == "merge":
                if merge_applied >= max_merge_actions:
                    results.append({"id": aid, "action": "merge", "applied": False,
                                     "reason": "merge_weekly_cap_exceeded"})
                    continue
                r = apply_merge(vault_root, merge_by_id[aid], act, today_iso, dry_run,
                                 merge_state_dir, merge_lock_file)
                results.append(r)
                if r["applied"]:
                    merge_applied += 1
            else:  # pragma: no cover - validate_structured_output()で既に排除済み
                results.append({"id": aid, "action": kind, "applied": False, "reason": "unexpected_action"})
        except Exception as e:  # noqa: BLE001 - 意図的な全捕捉（安全網。詳細はコメント参照）
            results.append({"id": aid, "action": kind, "applied": False,
                             "reason": f"unexpected_exception: {type(e).__name__}: {e}"})
    return results


def _summarize_results(results):
    """apply_actions()の戻り値からstatus-file向けの集計を作る純粋関数
    （2026-07-16 Codex三次レビュー指摘Minor対応: main()に直書きしていた
    集計ロジックを独立関数へ抽出し、`partial_merge_state`発生時に
    `anomaly=True`となることを合成resultsを使って直接ユニットテストできる
    ようにする）。

    partial_merge_state=True（統合ノートは作成済みだが原ノートのstub化が
    TOCTOU再検出/例外で見送られた状態）は「成功したMERGE」と区別して数える
    （2026-07-16 Codex二次レビュー指摘Major対応: 従来はn_mergedにも普通に
    加算され、anomaly=falseのまま通知されず、次回以降オーファンな統合ノートが
    静かに残り続けていた）。
    """
    n_promoted = sum(1 for r in results if r["action"] == "promote" and r["applied"])
    n_merged = sum(1 for r in results if r["action"] == "merge" and r["applied"] and not r.get("partial_merge_state"))
    n_merged_partial = sum(1 for r in results if r["action"] == "merge" and r.get("partial_merge_state"))
    n_fixed = sum(1 for r in results if r["action"] == "fix_approve" and r["applied"])
    n_skipped = sum(1 for r in results if not r["applied"])
    has_anomaly = n_merged_partial > 0
    reason = "n_merged_partial>0（統合ノートは作成済みだが原ノートのstub化が未完了）" if has_anomaly else None
    return {
        "n_promoted": n_promoted, "n_merged": n_merged, "n_merged_partial": n_merged_partial,
        "n_fixed": n_fixed, "n_skipped": n_skipped, "has_anomaly": has_anomaly, "reason": reason,
    }


_SHA256_HEX_RE = re.compile(r"^[0-9a-f]{64}$")


def _looks_like_sha256_hex(s):
    return isinstance(s, str) and bool(_SHA256_HEX_RE.match(s))


def _validate_fragment_record(rid, rec):
    """Phase1 fragments_log.py --json の1レコードを再検証する（2026-07-16
    Codex一次レビュー指摘Major対応: 中間JSONファイル（`~/.claude/logs/
    maintenance/<date>/<time>-<pid>/`配下）の内容を無条件に信頼せず、
    idが実際に(source_relpath, heading_or_bullet)から再計算できる値と
    一致するかを確認する。フィールド欠落・型不正・id再計算不一致はすべて
    不正レコードとして除外する。

    2026-07-16 Codex二次レビュー指摘Major対応で以下も追加検証する
    （id再計算一致のみだと、apply_promote()のstep2（Fragments側マーキング）が
    Fragments以外のファイルへ向かう入力を理論上排除できていなかった）:
      - source_relpathがFragments/配下の日次ファイル形式
        （`Fragments/YYYY-MM/YYYY-MM-DD.md`・fragments_log.pyの
        `FRAGMENTS.rglob("20*.md")`走査契約に対応）であること。
      - bodyが文字列であること（構造化出力へ渡す素材として扱う前提）。
      - source_sha256がsha256の16進64桁として妥当な形式であること。
    """
    if not isinstance(rec, dict):
        return False
    source_relpath, heading, source_sha256 = (
        rec.get("source_relpath"), rec.get("heading_or_bullet"), rec.get("source_sha256"))
    if not all(isinstance(x, str) and x for x in (source_relpath, heading, source_sha256)):
        return False
    if not isinstance(rec.get("body"), str):
        return False
    if not _looks_like_sha256_hex(source_sha256):
        return False
    # fragments_log.pyのFRAGMENTS.rglob("20*.md")契約（Fragments/配下・任意の
    # 深さ・ファイル名stemがISO日付として解釈できる）に合わせる。現行運用は
    # `Fragments/YYYY-MM/YYYY-MM-DD.md`の2階層だが、月フォルダ名とファイル名の
    # 日付が一致することまではfragments_log.py自身が要求していないため、
    # ここでも過度に厳格な構造は課さない（正規表現の厳密化ではなく実際の
    # 走査契約に合わせる）。
    p = pathlib.PurePosixPath(source_relpath)
    # `PurePosixPath.as_posix()`は".."をそのまま温存するため、正規形かどうかの
    # 往復比較だけでは`Fragments/../Preferences/2026-07-15.md`のような
    # traversalを検出できない（2026-07-16 Codex三次レビュー指摘Major対応:
    # 実際にこの値がid再計算一致さえすれば通過してしまい、Vault境界検査は
    # Vault全体基準のためPreferencesノートをFragments扱いで誤ってマーキング
    # しうる欠陥があった）。".."/"."が含まれる場合は明示的に拒否する
    # （knowledge_merge_candidates.py・merge_checks.pyの同種チェックと同じ
    # 考え方）。
    if p.as_posix() != source_relpath or len(p.parts) < 2 or p.parts[0] != "Fragments":
        return False
    if ".." in p.parts or "." in p.parts:
        return False
    m = re.match(r"^(20\d\d-\d\d-\d\d)\.md$", p.parts[-1])
    if not m:
        return False
    # ファイル名部分が数字パターンとしては`YYYY-MM-DD.md`でも、実在しない暦日
    # （例: "2026-99-99.md"）はfragments_log.py自身の
    # `datetime.date.fromisoformat(p.stem)`検証を通過しない契約と食い違う
    # （2026-07-16 Codex三次レビュー指摘Major対応）。
    try:
        datetime.date.fromisoformat(m.group(1))
    except ValueError:
        return False
    return fragments_log.stable_fragment_id(source_relpath, heading) == rid


def _validate_fix_record(rid, rec, today):
    """Phase1 vault_inventory.py --json の1レコードを再検証する。設計書§3.5
    「missing_updated（Preferences限定）」の範囲（Preferences直下1階層・
    README.md除く）を外れる・idが再計算不一致・fix_dateが検証不能/未来日の
    いずれも不正レコードとして除外する（fixable=Trueは呼び出し側で既に
    フィルタ済みの前提）。
    """
    if not isinstance(rec, dict):
        return False
    relpath, source_sha256, fix_date = rec.get("relpath"), rec.get("source_sha256"), rec.get("fix_date")
    if not all(isinstance(x, str) and x for x in (relpath, source_sha256, fix_date)):
        return False
    if not _looks_like_sha256_hex(source_sha256):
        return False
    if vault_lib.stable_fix_id(relpath) != rid:
        return False
    p = pathlib.PurePosixPath(relpath)
    if p.as_posix() != relpath or len(p.parts) != 2 or p.parts[0] != "Preferences":
        return False
    if not p.parts[1].endswith(".md") or p.parts[1] == "README.md":
        return False
    try:
        parsed = datetime.date.fromisoformat(fix_date)
    except ValueError:
        return False
    return parsed <= today


def _validate_merge_record(rid, rec):
    """knowledge_merge_candidates.pyが既に実装済みの検証関数
    (`_candidate_record_is_valid_for_enrichment`)をそのまま再利用する
    （2026-07-16 cleanup決定#10「共有ロジックの分離原則」・独自の再実装で
    ドリフトさせない）。加えてnote_a_sha256/note_b_sha256がsha256の16進64桁
    として妥当な形式であることを確認する（TOCTOU再照合で使う値のため）。

    2026-07-16 Codex二次レビュー指摘Major対応: note_a_text/note_b_text
    （build_material()経由でClaudeへ渡す本文素材）が、同じレコード内の
    note_a_sha256/note_b_sha256（apply_merge()のTOCTOU再照合が実際に使う値）と
    内容的に一致することも確認する。両者が食い違っていると、Claudeが見た
    本文と、書込み直前にディスクへ再照合する対象（sha256のみで照合）が
    別物になりかねない。
    """
    if not isinstance(rec, dict):
        return False
    if not knowledge_merge_candidates._candidate_record_is_valid_for_enrichment(rid, rec):
        return False
    sha_a, sha_b = rec.get("note_a_sha256"), rec.get("note_b_sha256")
    if not (_looks_like_sha256_hex(sha_a) and _looks_like_sha256_hex(sha_b)):
        return False
    text_a, text_b = rec.get("note_a_text"), rec.get("note_b_text")
    if not isinstance(text_a, str) or not isinstance(text_b, str):
        return False
    if hashlib.sha256(text_a.encode("utf-8")).hexdigest() != sha_a:
        return False
    if hashlib.sha256(text_b.encode("utf-8")).hexdigest() != sha_b:
        return False
    return True


def _index_by_id_no_collision(records, validator, label, warnings):
    """レコード列をid→レコードのdictにする。idの衝突（同一Phase1出力内に
    同じidが複数出現）・再検証失敗レコードは黙って後勝ちで上書きせず除外し、
    warningsへ記録する（2026-07-16 Codex一次レビュー指摘Major対応:
    `{r["id"]: r for r in records}`という素朴な辞書内包表記は衝突時に
    無言で片方を捨てていた。同一Fragments日次ファイル内に同名の見出し/
    箇条書きが2つあるとid＝sha256(source_relpath+heading_or_bullet)が
    衝突しうる）。validatorは(id, record)を受け取りboolを返す関数。

    非オブジェクト要素・id欠落要素も黙って読み飛ばさずwarningsへ記録する
    （2026-07-16 Codex三次レビュー指摘Major対応: 従来は`{"fragments": [42]}`
    のような構造異常が一切の痕跡を残さず「候補0件」に丸め込まれ、呼び出し側
    が`record_warnings`の有無で「Phase1出力が壊れていたか」を判定できて
    いなかった）。
    """
    counts = {}
    for r in records:
        rid = r.get("id") if isinstance(r, dict) else None
        if isinstance(rid, str) and rid:
            counts[rid] = counts.get(rid, 0) + 1
    collided = {rid for rid, n in counts.items() if n > 1}

    result = {}
    for r in records:
        if not isinstance(r, dict):
            warnings.append(f"{label}: 非オブジェクトの要素があるため除外します: {r!r}")
            continue
        rid = r.get("id")
        if not isinstance(rid, str) or not rid:
            warnings.append(f"{label}: idが欠落/不正な要素があるため除外します")
            continue
        if rid in collided or rid in result:
            continue
        if not validator(rid, r):
            warnings.append(f"{label}: Phase1レコードの再検証に失敗したため除外します: {rid}")
            continue
        result[rid] = r

    for rid in sorted(collided):
        warnings.append(f"{label}: id衝突のため除外します（{counts[rid]}件重複）: {rid}")
    return result


def _load_json_file(path, label):
    """Phase1中間JSONファイルを読み込む。

    戻り値: (data_or_None, warning_or_None, is_failure)。
    `is_failure`は「--fragments-json等が明示指定されたのに読めなかった/
    形式が不正だった」場合のみTrue（2026-07-16 Codex三次レビュー指摘Major
    対応: 「未指定（今回対象外）」という正常系と「指定されたが壊れていた」
    という異常系を呼び出し側が区別できるようにする。前者は毎週普通に起こる
    （検出器が候補0件だったステップは呼び出し元がそもそも--*-jsonを渡さない
    運用も許容する）が、後者は中間ファイル破損の兆候であり、結果として
    候補0件になった場合でも「静かなno_candidates」と区別してanomaly通知
    すべき）。
    """
    if not path:
        return None, None, False
    p = pathlib.Path(path)
    if not p.is_file():
        return None, f"{label}: ファイルが見つかりません（{path}）", True
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        return None, f"{label}: 読込/解析に失敗しました（{e}）", True
    # トップレベルがオブジェクトでない（配列・文字列・数値等）場合、後続の
    # `.get()`呼び出しがAttributeErrorで例外送出し、main()を無防備にクラッシュ
    # させうる（2026-07-16 Codex二次レビュー指摘Major対応）。ここで検出専用の
    # 読込失敗として扱い、file-not-found/parse-errorと同じfail-open経路に
    # 合流させる。
    if not isinstance(data, dict):
        return None, f"{label}: 想定外の形式です（トップレベルがオブジェクトではありません）", True
    return data, None, False


# maintenance.sh側が要求する7必須キー契約（ok/anomaly/n_promoted/n_merged/
# n_merged_partial/n_fixed/n_skipped）のうち、個数系5キーの既定値。
# 呼び出し箇所ごとに手でキーを列挙する方式は、必須キーが追加された際に
# 一部の呼び出し箇所だけ追従漏れするリスクがある（2026-07-16 tester独立
# 検証F2で実測: n_merged_partial追加時に6箇所中5箇所が追従漏れし、
# maintenance.sh側の7キー必須検証で毎回anomaly誤判定→静穏週のたびに
# 偽アラート＋last_success_atが進まず--sinceが巻き戻らない実害が発生した。
# 個別補完ではなく、単一ヘルパ内で既定値を保証する方式へ一本化する
# ＝「必須キーは単一箇所で管理」という共有ロジック分離原則の適用）。
_STATUS_FILE_COUNT_DEFAULTS = {
    "n_promoted": 0,
    "n_merged": 0,
    "n_merged_partial": 0,
    "n_fixed": 0,
    "n_skipped": 0,
}


def _write_status_file(path, **fields):
    # 個数系5キーは呼び出し側が明示指定しなければ既定値(0)で補う。呼び出し
    # 側が明示指定した値は当然そちらを優先する（**fieldsで上書きされる
    # ため、dictのマージ順序＝defaults→fieldsで自然に実現できる）。
    merged = dict(_STATUS_FILE_COUNT_DEFAULTS)
    merged.update(fields)
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.parent / f".{path.name}.tmp-{os.getpid()}"
    tmp.write_text(json.dumps(merged, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")
    os.replace(str(tmp), str(path))


def build_argparser():
    ap = argparse.ArgumentParser(
        description="maintenance.sh Phase 2（判断＋適用）: Phase1検出結果をヘッドレスClaude"
                     "へ渡し、検証済みの構造化出力に基づきPROMOTE/MERGE/FIXをVaultへ適用する。")
    ap.add_argument("--vault", default=str(pathlib.Path.home() / "Data" / "obsidian"))
    ap.add_argument("--fragments-json", default=None, help="fragments_log.py --jsonの出力ファイル")
    ap.add_argument("--inventory-json", default=None, help="vault_inventory.py --jsonの出力ファイル")
    ap.add_argument("--merge-json", default=None, help="knowledge_merge_candidates.py --jsonの出力ファイル")
    ap.add_argument("--workdir", required=True, help="今回実行の中間ファイル置き場（実行ごと一意ディレクトリ）")
    ap.add_argument("--status-file", default=None, help="機械可読な実行結果（既定: <workdir>/apply-status.json）")
    ap.add_argument("--claude-bin", default=DEFAULT_CLAUDE_BIN)
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--claude-timeout", type=float, default=DEFAULT_CLAUDE_TIMEOUT)
    ap.add_argument("--max-merge-actions", type=int, default=DEFAULT_MAX_MERGE_ACTIONS)
    ap.add_argument("--dry-run", action="store_true", help="Vaultへ書き込まず判定結果のみ表示する")
    ap.add_argument("--today", default=None, help="YYYY-MM-DD（テスト用の日付固定。省略時は実行日）")
    ap.add_argument("--gate-script", default=str(DEFAULT_GATE_SCRIPT))
    ap.add_argument("--ngwords-file", default=str(DEFAULT_NGWORDS_FILE))
    ap.add_argument("--merge-state-dir", default=str(knowledge_merge_candidates.DEFAULT_OUT_DIR))
    ap.add_argument("--merge-lock-file", default=str(merge_state.DEFAULT_LOCK_FILE))
    return ap


def main(argv=None):
    args = build_argparser().parse_args(argv)
    vault_root = pathlib.Path(args.vault).resolve()
    workdir = pathlib.Path(args.workdir)
    workdir.mkdir(parents=True, exist_ok=True)
    status_file = pathlib.Path(args.status_file) if args.status_file else workdir / "apply-status.json"
    log_file = workdir / "apply-log.json"

    warnings = []
    # 「明示指定されたが読めなかった/形式が不正だった」件数（2026-07-16 Codex
    # 三次レビュー指摘Major対応: 未指定＝今週たまたま検出0件だった正常系と、
    # 指定されたのに壊れていた異常系を区別し、後者はcandidates=0でも
    # `no_candidates`という静かな正常終了に丸め込まない）。
    input_load_failures = 0
    frag_payload, w1, f1 = _load_json_file(args.fragments_json, "fragments")
    inv_payload, w2, f2 = _load_json_file(args.inventory_json, "inventory")
    merge_payload, w3, f3 = _load_json_file(args.merge_json, "merge")
    for w, failed in ((w1, f1), (w2, f2), (w3, f3)):
        if w:
            warnings.append(w)
            print(f"FACT: {w}", file=sys.stderr)
        if failed:
            input_load_failures += 1

    today_date = datetime.date.today()
    if args.today:
        try:
            today_date = datetime.date.fromisoformat(args.today)
        except ValueError:
            print(f"警告: --todayの値が不正です({args.today!r})。実行日にフォールバックします。", file=sys.stderr)
    today_iso = today_date.isoformat()

    def _as_list(payload, key, label):
        # payload自体がNone（未指定/読込失敗。既にinput_load_failuresへ計上済み）
        # の場合は静かに空配列を返す。payloadが実在するdictなのに期待キーが
        # 丸ごと欠落している場合は「想定と異なる形式のファイルを渡された」
        # 疑いがあるため、キーが存在するが値が空配列という正常系とは区別して
        # warning化する（2026-07-16 Codex四次レビュー指摘Major対応）。
        # 値が明示的に`null`の場合も、以前は無条件で空配列へ丸め込んでいて
        # 「配列ではない」warningを迂回できていたため、isinstance検査へ
        # 合流させる（Noneの特別扱いを撤去）。
        nonlocal input_load_failures
        if payload is None:
            return []
        if key not in payload:
            warnings.append(f"{label}: '{key}'キーが見つかりません（想定外の形式の可能性）")
            print(f"FACT: {label}: '{key}'キーが見つかりません（想定外の形式の可能性）", file=sys.stderr)
            input_load_failures += 1
            return []
        val = payload[key]
        if not isinstance(val, list):
            warnings.append(f"{label}: '{key}'が配列ではないため無視します（型={type(val).__name__}）")
            print(f"FACT: {label}: '{key}'が配列ではないため無視します（型={type(val).__name__}）", file=sys.stderr)
            input_load_failures += 1
            return []
        return val

    fragments_raw = _as_list(frag_payload, "fragments", "fragments")
    fix_all = _as_list(inv_payload, "missing_updated_fix_candidates", "inventory")
    # fixable=Falseの要素はvault_inventory.pyが機械的に「今回は修正不可」と
    # 判定した正常な検出結果であり、warning化の対象ではない（例:
    # skip_reason=duplicate_date_key等）。非オブジェクト要素だけを区別して
    # warning化する（2026-07-16 Codex四次レビュー指摘Major対応: 従来は
    # `isinstance(c, dict) and c.get("fixable") is True`という単一の内包
    # 表記フィルタで、非オブジェクト要素とfixable=False要素の両方が無言で
    # 同じように消えており、前者（構造異常の兆候）が一切観測できなかった）。
    fix_candidates_raw = []
    for c in fix_all:
        if not isinstance(c, dict):
            warnings.append(f"inventory: 非オブジェクトの要素があるため除外します: {c!r}")
            input_load_failures += 1
            continue
        fixable = c.get("fixable")
        if fixable is True:
            fix_candidates_raw.append(c)
        elif fixable is False:
            pass  # vault_inventory.pyが機械的に「今回は修正不可」と判定した正常な検出結果
        else:
            # fixableキーの欠落・bool以外の型（文字列"true"・数値1・null等）は
            # vault_inventory.pyの実際の出力契約（fixableは常にbool）と食い違う
            # 構造異常として扱う（2026-07-16 Codex五次レビュー指摘Major対応:
            # 従来は`is True`との単純比較のみで、これらがすべて無言で
            # fixable=False相当（正常な修正不可）と区別できずに消えていた）。
            warnings.append(f"inventory: fixableがbool型ではありません（型={type(fixable).__name__}）")
            input_load_failures += 1
    merge_candidates_raw = _as_list(merge_payload, "candidates", "merge")

    # Phase1中間JSONのレコード整合性をここで独立に再検証する（2026-07-16
    # Codex一次レビュー指摘Major対応。§2.3「未知idの操作は応答全体を不採用」の
    # 前提となる「既知id集合＝Phase1が実際に検出した正当な候補」自体が
    # 中間ファイル改ざん/破損で汚染されていないことを保証する）。
    record_warnings = []
    fragments_by_id = _index_by_id_no_collision(
        fragments_raw, _validate_fragment_record, "fragments_records", record_warnings)
    fix_by_id = _index_by_id_no_collision(
        fix_candidates_raw, lambda rid, rec: _validate_fix_record(rid, rec, today_date),
        "fix_records", record_warnings)
    merge_by_id = _index_by_id_no_collision(
        merge_candidates_raw, _validate_merge_record, "merge_records", record_warnings)
    for w in record_warnings:
        print(f"FACT: {w}", file=sys.stderr)
    warnings.extend(record_warnings)

    fragments = list(fragments_by_id.values())
    fix_candidates = list(fix_by_id.values())
    merge_candidates = list(merge_by_id.values())
    frag_ids, fix_ids, merge_ids = set(fragments_by_id), set(fix_by_id), set(merge_by_id)
    all_ids = frag_ids | fix_ids | merge_ids

    if not all_ids:
        # レコードが1件も無かった「静かな週」と、(a) Phase1レコードが1件以上
        # あったのに全件が再検証で除外された、または(b) 明示指定された中間
        # JSONファイルが読めなかった/形式が不正だった「中間ファイル破損の
        # 疑い」を区別する（2026-07-16 Codex二次・三次レビュー指摘Major対応:
        # 後者を`no_candidates`と同じ静かなexit 0にすると、パイプライン自体の
        # 故障（例: `{"fragments": "broken"}`・トップレベルが配列・個々の
        # 要素が非オブジェクト等）が誰にも気づかれないまま毎週繰り返されうる）。
        # fix_candidates_raw（fixable=Trueのみ）ではなくfix_all（フィルタ前）を
        # 見る（2026-07-16 Codex四次レビュー指摘Major対応: 「検出はしたが
        # 修正不可」という正常系だけでfix_candidates_rawが常に空になる週でも、
        # fix_all自体は非空でありhad_raw_recordsをTrueにできる必要がある）。
        had_raw_records = bool(fragments_raw) or bool(fix_all) or bool(merge_candidates_raw)
        structural_problem = (had_raw_records and bool(record_warnings)) or input_load_failures > 0
        if structural_problem:
            print("ANOMALY: phase1_input_invalid: "
                  "Phase1中間JSONの読込失敗または全候補が再検証で除外されました", file=sys.stderr)
            _write_status_file(status_file, ok=False, anomaly=True, reason="phase1_input_invalid", warnings=warnings)
            return 0
        _write_status_file(status_file, ok=True, anomaly=False, reason="no_candidates", warnings=warnings)
        print("FACT: 今回はPROMOTE/MERGE/FIXいずれの候補もありません。claudeは起動しません。", file=sys.stderr)
        return 0

    # material構築〜適用までを丸ごとtry/exceptで囲む（2026-07-16 Codex一次
    # レビュー指摘Major対応の一般化: apply_actions()内は個々のaction単位で
    # 既に安全網があるが、その手前（schema構築・claude呼び出し・応答検証）で
    # 予期しない例外が起きると、それまでmain()に安全網が無くstatus-file/
    # apply-log.json自体が書かれずプロセスがクラッシュしてしまう。「一切
    # 書き込まず異常通知」という設計書§2.6の精神を、想定済みのanomaly経路
    # だけでなく真に予期しない例外にも一貫して適用する）。
    try:
        material = build_material(fragments, fix_candidates, merge_candidates)
        schema = build_output_schema(frag_ids, fix_ids, merge_ids)
        system_prompt_path = workdir / "system-prompt.txt"
        system_prompt_path.write_text(build_system_prompt(args.max_merge_actions), encoding="utf-8")

        structured, anomaly_kind, anomaly_detail = invoke_claude(
            args.claude_bin, args.model, system_prompt_path, schema, material, args.claude_timeout)
        if anomaly_kind:
            print(f"ANOMALY: {anomaly_kind}: {anomaly_detail}", file=sys.stderr)
            _write_status_file(status_file, ok=False, anomaly=True,
                                reason=f"{anomaly_kind}: {anomaly_detail}", warnings=warnings)
            return 0  # 設計書§2.6: 一切書き込まず正常終了。異常通知はstatus-file経由でmaintenance.shへ。

        actions, verr = validate_structured_output(structured, frag_ids, fix_ids, merge_ids)
        if verr:
            print(f"ANOMALY: schema_violation: {verr}", file=sys.stderr)
            _write_status_file(status_file, ok=False, anomaly=True,
                                reason=f"schema_violation: {verr}", warnings=warnings)
            return 0

        results = apply_actions(
            vault_root, actions, fragments_by_id, fix_by_id, merge_by_id, today_iso=today_iso,
            max_merge_actions=args.max_merge_actions, gate_script=args.gate_script,
            ngwords_file=args.ngwords_file, dry_run=args.dry_run,
            merge_state_dir=args.merge_state_dir, merge_lock_file=args.merge_lock_file)
    except Exception as e:  # noqa: BLE001 - 意図的な全捕捉（安全網。詳細はコメント参照）
        print(f"ANOMALY: unexpected_exception: {type(e).__name__}: {e}", file=sys.stderr)
        _write_status_file(status_file, ok=False, anomaly=True,
                            reason=f"unexpected_exception: {type(e).__name__}: {e}",
                            warnings=warnings)
        return 0

    summary = _summarize_results(results)

    # ここから先の書込み自体が失敗しても（ディスク枯渇・権限変化等）、
    # 生のtracebackでクラッシュするより、可能な限り状況をstderrへ残して
    # 正常終了する方がまだ運用上ましと判断する（2026-07-16 Codex二次レビュー
    # 指摘Major対応: 最終ログ/status-file書込み自体がtryの外にあり無防備
    # だった。ここが失敗する状況ではstatus-file自体も書けない可能性が高く
    # 完全な保証はできないが、素のクラッシュだけは避ける）。
    try:
        log_file.write_text(json.dumps({"date": today_iso, "results": results, "warnings": warnings},
                                        ensure_ascii=False, indent=2), encoding="utf-8")
    except OSError as e:
        print(f"警告: apply-log.jsonの書込みに失敗しました: {e}", file=sys.stderr)

    try:
        _write_status_file(status_file, ok=not summary["has_anomaly"], anomaly=summary["has_anomaly"],
                            reason=summary["reason"], n_promoted=summary["n_promoted"],
                            n_merged=summary["n_merged"], n_merged_partial=summary["n_merged_partial"],
                            n_fixed=summary["n_fixed"], n_skipped=summary["n_skipped"], warnings=warnings)
    except OSError as e:
        print(f"警告: status-fileの書込みに失敗しました: {e}", file=sys.stderr)

    n_promoted, n_merged = summary["n_promoted"], summary["n_merged"]
    n_merged_partial, n_fixed, n_skipped = summary["n_merged_partial"], summary["n_fixed"], summary["n_skipped"]

    print(f"完了: promote={n_promoted} merge={n_merged} merge_partial={n_merged_partial} "
          f"fix={n_fixed} skip={n_skipped}（詳細: {log_file}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
