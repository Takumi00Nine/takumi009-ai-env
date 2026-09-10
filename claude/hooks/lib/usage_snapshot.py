#!/usr/bin/env python3
"""usage_snapshot.py — 使用率のスナップショットを機械可読(JSON 1行)・
人可読(既定・枠あたり1行)で提示する口（B1-a「使用率の見える化」）。

正本: ~/work/takumi009-ai-env-private/docs/core-split/
      使用率提示B1a-実装-2026-09-08.md
要件の出典: ~/work/takumi009-ai-env-private/docs/core-split/
      ローカルLLM段階経路-要件-2026-09-03.md（v20）FR-104・FR-108①②・FR-116・
      AC-91・AC-95。

読み取り元（そのまま使う・触らない）: `~/work/claude-codex-usage` の
LaunchAgent（1分毎）が書くキャッシュ
  <cache_dir>/claude-cache.json
  <cache_dir>/codex-cache.json
既定 cache_dir = ${XDG_CACHE_HOME:-$HOME/.cache}/claude-codex-usage。
環境変数 AIENV_USAGE_CACHE_DIR で上書き可（テスト用にfixtureディレクトリを
差せるように）。

⚠️ B1-a のスコープ（実装記録「使用率提示B1a-実装-2026-09-08.md」§2に
固定表あり。2026-09-08 worker-driven一次レビュー2巡目MAJOR対応で以下を
FR-104の生の列挙との**全差分**として明記＝「予約系フィールドの除外だけが
差分」ではない）:
  - 予約系フィールド（reserved・reserve_percent・plan_file_state）は
    一切持たない（B2で追加）。
  - `model_weekly`はFR-104が別配列として持つ`model_windows`ではなく、
    `windows`配列の1要素（window="model_weekly"）として統合する（指示書
    §2.1が明示した具体的なJSON形状。FR-104の生の配列構成とは異なる）。
  - `age_seconds`・`error`はFR-104の生の列挙には無いフィールドだが、
    指示書§2.1が明示的に追加した（取得の鮮度・取得試行の成否を提示する
    ため）。
  - `error`の値は「last_errorの値そのもの」ではなく、取得器の実装が書く
    閉じた語彙（typeの6値・status）だけを許可リスト方式で要約したもの
    （自由文のmessageは絶対厳守③のため一切再掲しない）。
  - 枠間の差・順位・「偏り」ラベルは一切計算・保持しない（FR-116）。
  - 機構は使用率から候補を選ばない（本人裁定2026-09-04）。本ファイルは
    ①取得と提示だけを行う。

外部ライブラリに依存しない（標準ライブラリのみ）。exit codeは常に0
（提示専用。壊れていても行を出す＝静かな失敗にしない。キャッシュJSONの
解析失敗・必須キー欠落は usage_state=error として表す）。
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
from datetime import datetime, timedelta, timezone
from typing import Optional


# JSTは夏時間を持たないため、zoneinfo/tzdataに依存せず固定UTC+9で表す
# （core-conduct §2「タイムスタンプはJST表示」・外部ライブラリ非依存の両立）。
JST = timezone(timedelta(hours=9))

DEFAULT_CACHE_DIR_NAME = "claude-codex-usage"
DEFAULT_STALE_SECONDS = 600

# ============================================================
# B1-a のフィールド集合（AC-95①「集合の完全一致」の判定対象。
# 実装記録の固定表と同じ集合をここに置き、判定式を2箇所化しない）。
# ⚠️ reserved・reserve_percent・plan_file_state（FR-104のフルセットのうち
# 予約系）はここに含まない（B1-aのスコープ外・B2で追加）。
# ============================================================
TOP_LEVEL_FIELDS = frozenset({"generated_at", "pools"})
POOL_FIELDS = frozenset(
    {
        "pool_ref",
        "kind",
        "usage_state",
        "fetched_at",
        "age_seconds",
        "windows",
        "error",
        "reset_credits",
    }
)
# ⚠️ B1-c（2026-09-09）: 「チケット」（Codex の rate-limit reset credit）の
# 機械可読表現。Claude は残回数を返す API が未確認（機械取得しない）ため、
# claude-subscription には常にこの固定値を持たせて範囲差を明示する
# （本人指示2026-09-09 01:55＝Claude=5h窓のみ／Codex=5h+7d窓の両方）。
# codex-subscription はキャッシュの reset_credits を検証したうえで持たせる
# （+ state）。信用しない（`state:"missing"`へ倒す）のは`available_count`
# そのものが非負整数として解釈できないときだけで、詳細行（credits）が
# 無い／裏付けが無いことは正常形として受理する（公式app-serverの
# count-only応答＝検証職2巡目MAJOR-2対応。`_build_codex_reset_credits`
# 参照）。credits各要素の型不正は要素単位で除外する
# （`_extract_credit_entry`参照）。unlimited は reset_credits: None（§2.2）。
CODEX_RESET_CREDITS_FIELDS = frozenset(
    {"available_count", "reset_scope", "credits", "state"}
)
CLAUDE_RESET_CREDITS_FIELDS = frozenset(
    {"available_count", "reset_scope", "credits", "note"}
)
CREDIT_ENTRY_FIELDS = frozenset(
    {"id", "status", "granted_at_epoch", "expires_at_epoch", "title"}
)
CLAUDE_RESET_CREDITS_FIXED = {
    "available_count": None,
    "reset_scope": ["five_hour"],
    "credits": [],
    "note": "not_machine_readable",
}
# ⚠️ label は five_hour/seven_day では null・model_weekly だけ非null。
# フィールド集合そのものは窓の種類によらず常にこの5つで揃える
# （AC-95①の「集合の完全一致」を型の分岐なしで機械的に検査できるようにする
# ための設計判断＝リーダー裁定「設計相当」の範囲内で実装が決めた点）。
WINDOW_FIELDS = frozenset(
    {"window", "used_percent", "remaining_percent", "resets_at_epoch", "label"}
)

POOL_CACHE_FILE = {
    "claude-subscription": "claude-cache.json",
    "codex-subscription": "codex-cache.json",
}
POOL_HUMAN_LABEL = {
    "claude-subscription": "Claude枠",
    "codex-subscription": "Codex枠",
}
WINDOW_HUMAN_LABEL = {
    "five_hour": "5h",
    "seven_day": "7d",
}

# last_errorの非秘密化（絶対厳守③）。
# ⚠️ 2026-09-08 worker-driven一次レビュー（Codex）BLOCKING-2/3対応で全面
# 再設計した。旧実装は「自由文字列を受け取り、危険そうな部分文字列を含めば
# 伏せる」という否定リスト方式だったが、これは①危険語の網羅が原理的に
# 不可能（`password`・`Authorization: Basic`・`ghp_`・`AKIA`・日本語の
# 「パスワード」等、リストに無い語は素通りする）②実際の取得器
# （~/work/claude-codex-usage/refresh.sh）が書く`last_error`はそもそも
# 自由文字列ではなくオブジェクト`{at,type,message,status,attempts}`であり、
# 旧実装（文字列専用）は常にNoneを返して黙って情報を捨てていた、という
# 二重の欠陥を持っていた（実測: refresh.sh 253〜297行目・write_failure_cache
# ・empty_error_cache）。
# 新方式＝**許可リスト方式**（自由文のmessage/atは一切再掲しない）。
# ⚠️ 2026-09-08 worker-driven一次レビュー2巡目BLOCKING対応: 当初は
# 正規表現`^[a-z_]{1,40}$`で「識別子っぽい形」を許可していたが、これだと
# `type`に秘密っぽい任意の小文字文字列（例:
# `secret_material_encoded_here`）が入っていても素通りしてしまう
# （正規表現は「形」しか見ず「値」を見ていない）。取得器の実装
# （scripts/usage-fetch.sh。旧refresh.shから移設・D-3で拡張）が書く
# error_typeは実測で
# auth_expired・auth・parse・http・timeout・curl・command の7値**だけ**であり、
# それ以外の未知の値は「取得器の未来のバージョンが書くかもしれない値」
# として安全側（ERROR_UNCLASSIFIEDへ丸める）に倒すのが正しい——形式検査
# ではなく**閉じた集合との完全一致**にする。
# ⚠️ 検証職1巡目MINOR-6対応: 取得器（scripts/usage-fetch.sh）はD-3で
# curl系の通信エラー（curl_exit=5/6/7/28/52/55/56）を"curl"というtype値で
# 記録するようになった（旧is_transient扱いを廃し失敗として記録する変更）。
# 実測で取得器が書くtype値は7つ（auth_expired・auth・parse・http・timeout・
# curl・command）に増えており、この許可リストも合わせる。
ALLOWED_ERROR_TYPES = frozenset(
    {"auth_expired", "auth", "parse", "http", "timeout", "curl", "command"}
)
ERROR_MAX_LEN = 120
ERROR_UNCLASSIFIED = "取得エラーがありますが詳細は伏せています（絶対厳守③・自由文は再掲しない）"


def usage_cache_dir(cli_override: Optional[str] = None) -> str:
    """キャッシュディレクトリの位置を決める唯一の関数。⚠️ os.environ を読むのは
    ここだけ（profile_resolve.pyのmodel_defs_path()と同じ設計則。2026-09-08
    worker-driven一次レビューMINOR対応でDEFAULT_CACHE_DIRのXDG_CACHE_HOME
    直接読みをここへ集約した）。
    優先順位（先勝ち・2026-09-08 MAJOR-2対応で`--cache-dir`引数を追加）:
    ①`cli_override`（`--cache-dir`） ②環境変数`AIENV_USAGE_CACHE_DIR`
    ③既定（`${XDG_CACHE_HOME:-~/.cache}/claude-codex-usage`）。指示書
    §2.1は環境変数のみを明記していたが、FR-104/AC-91⑦の「読み取り元パスを
    引数で差し替えられる」という字面もあわせて満たすため、環境変数方式は
    維持したまま引数を追加した（既存の環境変数運用・テストは無改変で動く）。
    """
    if cli_override:
        return os.path.expanduser(cli_override)
    override = os.environ.get("AIENV_USAGE_CACHE_DIR")
    if override:
        return os.path.expanduser(override)
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return os.path.join(base, DEFAULT_CACHE_DIR_NAME)


def _scrub_error(raw) -> Optional[str]:
    """last_errorの値を非秘密の要約へ変換する。⚠️ 絶対厳守③のため、取得器が
    書く自由文（`message`・`at`・`attempts`）は理由の如何を問わず一切再掲
    しない。再掲するのは、取得器の実装が閉じた語彙で書く構造化フィールド
    （`type`＝短い識別子・`status`＝HTTPステータス風の整数）だけで、しかも
    形式検査（許可リスト）に通ったときに限る。想定外の形（自由文字列その
    もの・typeが識別子形式でない等）は固定の一般メッセージへ丸める
    （「情報を出さない」ほうを「間違えて出す」より安全側に倒す）。
    """
    if raw is None:
        return None
    if isinstance(raw, dict):
        parts = []
        type_val = raw.get("type")
        if isinstance(type_val, str) and type_val in ALLOWED_ERROR_TYPES:
            parts.append(f"type={type_val}")
        status_val = raw.get("status")
        if isinstance(status_val, int) and not isinstance(status_val, bool) and 100 <= status_val <= 999:
            parts.append(f"status={status_val}")
        summary = " ".join(parts) if parts else ERROR_UNCLASSIFIED
        return summary[:ERROR_MAX_LEN]
    # 文字列・その他の予期しない型（現行の取得器は書かないが、将来の別実装/
    # フォークが書く可能性を想定した防御）。非nullである以上「何かエラーが
    # あった」ことだけは伝え、中身がどうであれ自由文を再掲しない。
    return ERROR_UNCLASSIFIED


def _reject_non_finite_constant(token: str):
    """json.load()のparse_constantフック。RFC 8259の厳密なJSONは
    NaN/Infinity/-Infinityを値として認めないが、Pythonのjsonモジュールは
    既定でこれを非標準拡張として受理してしまう（2026-09-08 worker-driven
    一次レビューMAJOR-1対応）。ここで例外を送出させ、json.load()全体を
    失敗させる＝キャッシュファイル全体をparse_errorとして扱う（NaN混入は
    ファイルの信頼性そのものへの疑いなので、その値を含む窓だけを黙って
    欠落させるのではなく、ファイル単位で「壊れている」と判定する）。
    """
    raise ValueError(f"non-finite JSON constant rejected: {token}")


def _read_cache_json(path: str) -> tuple[str, Optional[dict]]:
    """戻り値: (状態, パース済みdict or None)。状態は次の3つ:
    "missing"（ファイルが無い）・"parse_error"（JSON解析失敗/dict以外/
    NaN・Infinity混入）・"ok"。
    """
    if not os.path.isfile(path):
        return "missing", None
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f, parse_constant=_reject_non_finite_constant)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError):
        return "parse_error", None
    if not isinstance(data, dict):
        return "parse_error", None
    return "ok", data


def _as_number(value):
    """int/floatならそのまま返す。bool（intのサブクラス）は数値として扱わない
    （JSON上trueがused_percentに紛れ込んでも数値として誤解釈しない防御）。
    それ以外はNone。⚠️ NaN/Infinityは_read_cache_json()のparse_constant
    フックで既にファイル単位で拒否済みのため、ここへは到達しない契約だが、
    将来の呼び出し経路変化に備えて`math.isfinite`でも防御する（多重防御）。
    """
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        if isinstance(value, float) and not math.isfinite(value):
            return None
        return value
    return None


def _extract_window(data: dict, window_name: str) -> Optional[dict]:
    """1つの窓（five_hour/seven_day/model_weekly）を取り出す。使用可能な形で
    ない場合はNone（呼び出し側が「その窓は無いもの」として扱う＝
    model_weeklyがcatalog未整備で無ければ添えないFR-96と同じ規則を、
    five_hour/seven_dayの形式不備にも一様に適用する）。
    """
    raw = data.get(window_name)
    if not isinstance(raw, dict):
        return None
    used = _as_number(raw.get("used_percent"))
    if used is None:
        return None
    remaining = 100 - used
    if remaining < 0:
        remaining = 0
    resets = _as_number(raw.get("resets_at_epoch"))

    label = None
    if window_name == "model_weekly":
        lbl = raw.get("label")
        # ⚠️ labelに改行や制御文字が混じると、人可読出力（枠あたり1行の
        # 契約＝AC-91④）が複数行に分断されうる。2026-09-08 worker-driven
        # 一次レビュー2巡目MAJOR対応: 当初はC0制御文字(0x00-0x1F)とDEL
        # (0x7F)だけを拒否していたが、U+2028(LINE SEPARATOR)・
        # U+2029(PARAGRAPH SEPARATOR)・U+0085(NEL)・双方向制御文字等の
        # Unicode由来の行分断・不可視文字は素通りしていた。
        # `str.isprintable()`はUnicodeの「Other」「Separator」カテゴリ
        # （ASCII空白1文字を除く）をまとめて弾くため、この種の文字を包括的
        # に検出できる（Python公式stdtypes: str.isprintable()の定義）。
        # 加えて表示幅の暴走を防ぐ長さ上限も設ける（40字＝実際のカタログ
        # usage_scope_label例「Fable」より十分大きく、通常値を拒否しない）。
        # 改行・制御文字・長すぎるlabelは「無いもの」と同じ扱いにする
        # （FR-96の「labelが無ければ添えない」を、値が壊れている場合にも
        # 一様に適用する）。
        if (
            not isinstance(lbl, str)
            or lbl == ""
            or len(lbl) > 40
            or not lbl.isprintable()
        ):
            return None  # FR-96: labelが無い/壊れているmodel_weeklyは添えない
        label = lbl

    return {
        "window": window_name,
        "used_percent": used,
        "remaining_percent": remaining,
        "resets_at_epoch": resets,
        "label": label,
    }


# Codexのチケットが常にリセットする範囲（本人指示2026-09-09 01:55）。
# ⚠️ 検証職1巡目MAJOR-2対応: これは取得器（scripts/lib/usage-source.sh）が
# 常に書く定数であり上流データではないため、キャッシュの値をそのまま
# 信用せず、ここでも常にこの固定値を使う（`reset_scope:["secret_scope"]`
# のような壊れた/汚染された値がキャッシュに紛れ込んでいても出力へは
# 一切現れない＝読み手側の多重防御）。
CODEX_RESET_SCOPE = ["five_hour", "seven_day"]


def _valid_epoch(value) -> bool:
    """整数（またはfloatで整数値）かつ0より大きいepochだけを妥当とする。
    ⚠️ 検証職1巡目MAJOR-2対応: 0・負値・非整数floatは「型は数値だが値が
    明らかに壊れているepoch」であり、そのまま日付表示に使うと1970年1月1日
    付近の意味の無い日付を「有効期限」として出してしまう。ここで弾く。
    """
    if isinstance(value, bool):
        return False
    if not isinstance(value, (int, float)):
        return False
    if isinstance(value, float) and not value.is_integer():
        return False
    return value > 0


def _extract_credit_entry(raw) -> Optional[dict]:
    """1件のチケット（reset credit）を検証する。

    ⚠️ 検証職2巡目MAJOR-1対応: `id`・`status`・`granted_at_epoch` は
    必須（非null・正しい型）とし、いずれかが欠落/nullなエントリは丸ごと
    除外する（「有効な別creditが1件あれば、それ以外の全項目nullな
    creditも`state:ok`のcredits[]に残ってしまう」という不具合の再発防止。
    「creditをnull項目付きでJSONへ残す」中途半端な状態は作らない）。
    `expires_at_epoch`・`title` は公式protocol（openai/codex
    codex-rs/app-server-protocol/src/protocol/v2/account.rs）がnullable
    な任意フィールドのため、型不正・値不正（0・負値等）ならその
    フィールドだけをNoneへ倒し、エントリ自体は残す（id/status/
    granted_at_epochが正しい限り「詳細の一部が無い」だけの正常な縮退
    として扱う＝検証職2巡目MAJOR-2の「count-onlyは正常形」と同じ考え方
    をcredit単位にも適用）。
    """
    if not isinstance(raw, dict):
        return None
    id_ = raw.get("id")
    status = raw.get("status")
    granted = raw.get("granted_at_epoch")
    if not (isinstance(id_, str) and id_ != ""):
        return None
    if not (isinstance(status, str) and status != ""):
        return None
    if not _valid_epoch(granted):
        return None
    expires = raw.get("expires_at_epoch")
    if expires is not None and not _valid_epoch(expires):
        expires = None
    title = raw.get("title")
    if title is not None and not isinstance(title, str):
        title = None
    return {
        "id": id_,
        "status": status,
        "granted_at_epoch": granted,
        "expires_at_epoch": expires,
        "title": title,
    }


def _build_codex_reset_credits(data: Optional[dict]) -> dict:
    """codex-subscription 用の reset_credits を組み立てる。data は
    codex-cache.json 全体（無し/壊れていれば None）。

    ⚠️ 検証職2巡目MAJOR-2対応: `available_count`（非負整数として解釈
    できる値）こそが権威値（公式protocol・実装記録§2「Claude側を固定
    文言にした理由」と同じ考え方＝researcher実測の一次情報を最優先する）
    であり、**詳細行（credits）が無い／裏付けが無いことは異常ではない**
    （openai/codex公式app-server README・protocol v2/account.rsの
    `credits: null`＝count-onlyの正常形）。1巡目対応で追加した
    「available_count>0なら未失効の裏付けが必須」というfail-closed化は
    この正常形を`state:"missing"`へ誤分類していたため撤回した。
    信用しない（`state:"missing"`へ倒す）のは以下だけ:
      - `reset_credits`キー自体が無い、または型が壊れている。
      - `available_count`が負値・非整数など、非負整数として解釈できない
        （枚数という権威値そのものが壊れている場合のみfail-closed）。
    `credits`配列の各要素の型検査は`_extract_credit_entry()`が個別に行う
    （壊れた要素は個別に除外されるだけで、reset_credits全体を巻き込まない）。
    表示に使う失効日の選択（status=="available"かつ未失効`>now`のものだけ
    を候補にする）は`_format_ticket_text()`側の責務のまま変更していない。
    """
    missing = {
        "available_count": None,
        "reset_scope": CODEX_RESET_SCOPE,
        "credits": [],
        "state": "missing",
    }
    if not isinstance(data, dict):
        return missing
    raw = data.get("reset_credits")
    if not isinstance(raw, dict):
        return missing
    available_count = _as_number(raw.get("available_count"))
    if isinstance(available_count, float):
        available_count = int(available_count) if available_count.is_integer() else None
    if available_count is not None and available_count < 0:
        available_count = None
    if available_count is None:
        return missing

    credits_raw = raw.get("credits")
    credits = []
    if isinstance(credits_raw, list):
        for entry in credits_raw:
            normalized = _extract_credit_entry(entry)
            if normalized is not None:
                credits.append(normalized)

    return {
        "available_count": available_count,
        "reset_scope": CODEX_RESET_SCOPE,
        "credits": credits,
        "state": "ok",
    }


def _reset_credits_for_pool(pool_ref: str, data: Optional[dict]) -> dict:
    if pool_ref == "claude-subscription":
        # dictはmutableなので、呼び出し元が誤って書き換えても定数側へ
        # 波及しないよう毎回コピーを返す。
        return dict(CLAUDE_RESET_CREDITS_FIXED)
    return _build_codex_reset_credits(data)


def build_subscription_pool(pool_ref: str, cache_dir: str, now: int, stale_seconds: int) -> dict:
    """claude-subscription / codex-subscription 共通の構築ロジック。
    §5 stdout契約の評価順（先勝ち）: ①ファイル不在→missing
    ②JSON解析失敗/必須キー欠落→error ③fetched_atの鮮度→stale/ok。
    """
    path = os.path.join(cache_dir, POOL_CACHE_FILE[pool_ref])
    status, data = _read_cache_json(path)

    if status == "missing":
        return {
            "pool_ref": pool_ref,
            "kind": "subscription",
            "usage_state": "missing",
            "fetched_at": None,
            "age_seconds": None,
            "windows": [],
            "error": None,
            "reset_credits": _reset_credits_for_pool(pool_ref, None),
        }

    if status == "parse_error":
        return {
            "pool_ref": pool_ref,
            "kind": "subscription",
            "usage_state": "error",
            "fetched_at": None,
            "age_seconds": None,
            "windows": [],
            "error": None,
            "reset_credits": _reset_credits_for_pool(pool_ref, None),
        }

    fetched_at = _as_number(data.get("fetched_at"))
    five = _extract_window(data, "five_hour")
    seven = _extract_window(data, "seven_day")
    error_val = _scrub_error(data.get("last_error"))

    # 必須キー欠落（fetched_at・five_hour・seven_dayのいずれか、または
    # 必須窓のresets_at_epoch欠落）はerror（このpoolの読み取り契約における
    # 必須集合。model_weeklyは任意＝FR-96）。
    # ⚠️ 検証職1巡目MINOR-5対応: five_hour/seven_dayはused_percentがあれば
    # resets_at_epochも必須にする（書き手側の契約＝usage-fetch.shのD-15は
    # 既にこれを検証しているため通常は起きないが、旧キャッシュ・手で
    # 壊されたキャッシュに対する読み手側の多重防御として、resets_at_epoch
    # 欠落を黙ってusage_state=okへ倒さない＝coding-doc-style §4）。
    resets_missing = (
        (five is not None and five.get("resets_at_epoch") is None)
        or (seven is not None and seven.get("resets_at_epoch") is None)
    )
    if fetched_at is None or five is None or seven is None or resets_missing:
        return {
            "pool_ref": pool_ref,
            "kind": "subscription",
            "usage_state": "error",
            "fetched_at": int(fetched_at) if fetched_at is not None else None,
            "age_seconds": None,
            "windows": [],
            "error": error_val,
            "reset_credits": _reset_credits_for_pool(pool_ref, data),
        }

    fetched_at = int(fetched_at)
    age_seconds = now - fetched_at
    if age_seconds < 0:
        age_seconds = 0  # 未来のfetched_at（時計ズレ）は0扱い（負のageを出さない）
    state = "stale" if age_seconds > stale_seconds else "ok"

    windows = [five, seven]
    weekly = _extract_window(data, "model_weekly")
    if weekly is not None:
        windows.append(weekly)

    return {
        "pool_ref": pool_ref,
        "kind": "subscription",
        "usage_state": state,
        "fetched_at": fetched_at,
        "age_seconds": age_seconds,
        "windows": windows,
        "error": error_val,
        "reset_credits": _reset_credits_for_pool(pool_ref, data),
    }


def build_unlimited_pool() -> dict:
    """§2.2で固定された3枠目。実体（配役表）はこの枠を定義しない＝常にこの
    固定値を返す（v19一次レビュー1巡目の指摘どおり枠は常に3件）。
    reset_credits は None（unlimited枠にチケットの概念自体が無い＝§2.2）。
    """
    return {
        "pool_ref": "unlimited",
        "kind": "unlimited",
        "usage_state": "not_applicable",
        "fetched_at": None,
        "age_seconds": None,
        "windows": [],
        "error": None,
        "reset_credits": None,
    }


def build_snapshot(cache_dir: str, now: int, stale_seconds: int) -> dict:
    """枠は常にこの順で3件（claude-subscription→codex-subscription→
    unlimited）。⚠️ 枠間の差・順位・偏りラベルは計算しない（FR-116。
    このモジュールに引き算・比較演算を1つも持たない）。
    """
    pools = [
        build_subscription_pool("claude-subscription", cache_dir, now, stale_seconds),
        build_subscription_pool("codex-subscription", cache_dir, now, stale_seconds),
        build_unlimited_pool(),
    ]
    return {"generated_at": now, "pools": pools}


# ============================================================
# 人可読の既定出力（枠あたり1行・FR-108①のSessionStart注入と同じ文面契約）
# ============================================================


def _format_reset(epoch, now: int) -> tuple[Optional[str], bool]:
    """JST表示。戻り値: (表示文字列 or None, 同じ暦日か)。
    同じ暦日ならHH:MM（呼び出し側が「リセット」の語を前置する）、
    それ以外はMM-DD HH:MM（日付が既にリセットの意味を持つため語を前置しない
    ＝設計書の例示 `／7d 残55%（09-14 05:00）` に合わせた表記）。
    """
    if epoch is None:
        return None, False
    # ⚠️ 2026-09-08 worker-driven一次レビューMAJOR-1対応: epochが
    # datetimeの表現範囲外（極端に巨大/過去などの壊れた値）だと
    # OverflowError/OSError/ValueErrorが送出されうる。exit常に0の契約
    # （AC-91①）を守るため、変換に失敗した場合は「リセット時刻不明」
    # （Noneと同じ扱い）へ静かに倒す（クラッシュしない）。
    try:
        dt = datetime.fromtimestamp(epoch, JST)
        now_dt = datetime.fromtimestamp(now, JST)
    except (OverflowError, OSError, ValueError):
        return None, False
    same_day = dt.date() == now_dt.date()
    if same_day:
        return dt.strftime("%H:%M"), True
    return dt.strftime("%m-%d %H:%M"), False


def _format_percent(value) -> str:
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return str(value)


def _format_ticket_date(epoch) -> Optional[str]:
    """チケット（reset credit）の失効日をJSTのMM/DD表記で返す。窓のリセット
    表記（`_format_reset`のMM-DD区切り）とはあえて区切り文字を変え
    （指示書§2.2の例示 `／チケット 1枚（10/05）` に合わせたMM/DD）、時刻は
    持たない（チケットの失効は日単位の情報として十分＝本人指示の例示に
    時刻が無い）。クラッシュしない契約は_format_resetと同じ（AC-91①）。
    """
    try:
        dt = datetime.fromtimestamp(epoch, JST)
    except (OverflowError, OSError, ValueError, TypeError):
        return None
    return dt.strftime("%m/%d")


def _format_ticket_text(pool: dict, now: int) -> str:
    """Codex行の末尾に足す「チケット」句（先頭の「／」は含まない・
    呼び出し側が付ける）。⚠️ 本人指示2026-09-09 02:30＝提示に長い固定文言を
    載せない。範囲差（Claude=5h窓のみ／Codex=5h+7d窓の両方）の説明は
    Vaultの資料側に書き、ここでは枚数と期限だけを出す。

    ⚠️ 検証職3巡目MINOR-2対応（docstring訂正）: `reset_credits`
    （`_build_codex_reset_credits`）は「available_count>0なら未失効の
    availableなチケットが最低1件ある」ことは**保証しない**（この保証は
    検証職1巡目対応で一時追加したが、2巡目MAJOR-2で撤回済み＝公式
    app-serverのcount-only応答〈`credits:null`〉は正常形であり、詳細行・
    裏付けの有無を問わず`available_count`だけが権威値として信頼される）。
    枚数（`available_count`）は常にそのまま表示し、`status=="available"`
    かつ`expires_at_epoch > now`（未失効）の適格な詳細が`credits`の中に
    見つかったときだけ、その中で最も早く失効する1件の日付を追加で添える
    （見つからなければ日付なしの「チケット N枚」のまま）。`credits`配列
    には失効済み・status非availableなエントリも一緒に残り得る（それ自体は
    壊れたデータではないため）。ここで`status=="available"`かつ
    `expires_at_epoch > now`のものだけを候補にしないと、`min()`が過去の
    失効日を「これから来る期限」として誤って選んでしまう（実測で発見）。
    """
    rc = pool.get("reset_credits")
    if not isinstance(rc, dict):
        return "チケット 取得不可"
    count = rc.get("available_count")
    if not isinstance(count, int) or isinstance(count, bool):
        return "チケット 取得不可"
    if count == 0:
        return "チケット 0枚"
    expiries = [
        c.get("expires_at_epoch")
        for c in rc.get("credits", [])
        if isinstance(c, dict)
        and c.get("status") == "available"
        and isinstance(c.get("expires_at_epoch"), (int, float))
        and not isinstance(c.get("expires_at_epoch"), bool)
        and c.get("expires_at_epoch") > now
    ]
    date_str = _format_ticket_date(min(expiries)) if expiries else None
    if date_str is None:
        return f"チケット {count}枚"
    return f"チケット {count}枚（{date_str}）"


def _format_window_segment(window: dict, now: int) -> str:
    remaining = _format_percent(window["remaining_percent"])
    if window["window"] == "model_weekly":
        label = f"{window['label']}週"
        return f"{label} 残{remaining}%"
    label = WINDOW_HUMAN_LABEL[window["window"]]
    reset, same_day = _format_reset(window["resets_at_epoch"], now)
    if reset is None:
        return f"{label} 残{remaining}%"
    if same_day:
        return f"{label} 残{remaining}%（リセット {reset}）"
    return f"{label} 残{remaining}%（{reset}）"


def _human_line_for_subscription(pool: dict, now: int) -> str:
    name = POOL_HUMAN_LABEL[pool["pool_ref"]]
    state = pool["usage_state"]
    if state == "missing":
        return f"{name}: 取得できません（キャッシュ無し＝claude-codex-usage 未導入。導入手順: README §使用率）"
    if state == "error":
        return f"{name}: 取得できません（キャッシュが壊れています。導入手順: README §使用率）"

    segments = [_format_window_segment(w, now) for w in pool["windows"]]
    age_min = pool["age_seconds"] // 60
    suffix = f"・取得 {age_min}分前"
    if state == "stale":
        suffix += " ⚠️古い"
    # ⚠️ 2026-09-08 worker-driven一次レビュー2巡目BLOCKING対応: データ自体
    # （five_hour/seven_day）が新鮮でも、取得器の直近の試行が失敗している
    # （last_errorが非null）ことはJSON側（error欄）だけでなく人可読側にも
    # 出す。usage_stateは変えない（データの鮮度と取得試行の成否は別軸＝
    # 検討経緯論点1）が、「見た目は正常なのに実は取得が壊れかけている」を
    # 静かに隠さない。行数は変えない（枠あたり1行の契約のまま末尾に追記）。
    if pool["error"] is not None:
        suffix += f" ⚠️取得エラー（{pool['error']}）"
    line = f"{name}: " + "／".join(segments) + suffix
    # B1-c（2026-09-09）: Codex行の末尾にだけチケット句を足す（本人指示
    # 2026-09-09 02:30＝長い固定文言は載せない・行数は変えない）。Claude行
    # には何も足さない（Claudeは残回数を返すAPIが未確認＝機械取得しない）。
    if pool["pool_ref"] == "codex-subscription":
        line += "／" + _format_ticket_text(pool, now)
    return line


def render_human(snapshot: dict, now: int) -> str:
    """枠あたり1行（常に3行。FR-108①のSessionStart注入から同じ関数を
    そのまま呼べる形にする）。"""
    lines = []
    for pool in snapshot["pools"]:
        if pool["pool_ref"] == "unlimited":
            lines.append("unlimited（Bedrock・ローカル）: 使用率なし")
        else:
            lines.append(_human_line_for_subscription(pool, now))
    return "\n".join(lines)


# ============================================================
# CLI
# ============================================================


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="使用率スナップショットの提示口（B1-a・FR-104/FR-108/FR-116）"
    )
    parser.add_argument(
        "--json", action="store_true", help="非秘密JSON1行で出力する（既定は人可読・枠あたり1行）"
    )
    parser.add_argument(
        "--now", type=int, default=None, help="現在時刻をepoch秒で指定する（テスト用。既定は実時刻）"
    )
    parser.add_argument(
        "--stale-seconds",
        type=int,
        default=DEFAULT_STALE_SECONDS,
        help=f"fetched_atがこの秒数を超えて古ければstale扱い（既定{DEFAULT_STALE_SECONDS}）",
    )
    parser.add_argument(
        "--cache-dir",
        default=None,
        help="キャッシュディレクトリを差し替える（テスト用。既定はAIENV_USAGE_CACHE_DIR環境変数、"
        "それも無ければ${XDG_CACHE_HOME:-~/.cache}/claude-codex-usage）",
    )
    args = parser.parse_args(argv)

    now = args.now if args.now is not None else int(time.time())
    cache_dir = usage_cache_dir(args.cache_dir)

    snapshot = build_snapshot(cache_dir, now, args.stale_seconds)

    if args.json:
        sys.stdout.write(json.dumps(snapshot, separators=(",", ":")) + "\n")
    else:
        sys.stdout.write(render_human(snapshot, now) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
