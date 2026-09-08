#!/usr/bin/env python3
"""profile_resolve.py — ローカル実体プロファイル(v2)の分類・parser・validator・
候補評価・stdout契約を1箇所に持つ共有lib（配役表解凍-設計-2026-09-01.md §4.1-g）。

契約の正本: ~/work/takumi009-ai-env-private/docs/core-split/
            profile-resolve-contract-2026-09-01.md
設計の正本: ~/work/takumi009-ai-env-private/docs/core-split/
            配役表解凍-設計-2026-09-01.md

外部ライブラリに依存しない（標準ライブラリのみ）。bootstrap-vault.sh・
install-main.sh から `python3 <このファイル> <subcommand> ...` として呼ばれる
サブプロセス実行を前提とし、モジュールとしてimportされることは想定しない
（ただしテストの都合上 import しても壊れないようにトップレベル副作用は
`if __name__ == "__main__"` の中に閉じる）。

⚠️ 秘匿方針（絶対厳守③）: bedrock.env のうち読むのは「許可された特定キーの
存在・非空」だけ。値そのものをstdout/stderrへ書かない。role/fallback行が
参照する定義（モデル定義ファイル側）のmodel=/provider=の値は resolve() の
出力へ再掲しない（配役の値をDIRECTIVEへ再掲しない＝4.1-f。resolve-leader
だけは settings.json 生成用に値を返す＝これは元々installerが書く値であり、
AI向けDIRECTIVEには流用しない）。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import sys
from typing import Optional


# ============================================================
# §3.4 コード側が唯一の正本として持つ定数群
# ============================================================

# ⚠️ 環境変数からは差し替えない（§3.4「期待版はコードが持つ」の唯一の正本を
# 継承環境の値で動かせる穴を作らない＝Codexレビュー指摘・Major対応。テストで
# 版境界分岐に到達させたい場合はサブプロセス内でモジュール属性
# `profile_resolve.EXPECTED_SCHEMA_VERSION`を直接上書きしてから呼ぶこと
# （本番の起動経路には一切影響しない）。
# 2026-09-08 モデル定義ファイルと候補指定対応（モデル定義ファイルと候補指定-
# 設計-2026-09-08.md §3.1・D-8）: 役割の行の文法を`model=<定義名>[,…]`（候補の
# カンマ列挙）へ変えたのに合わせて5→6へ引き上げた。⚠️ 旧記法
# `model=claude-opus-5`は新文法でも「定義名`claude-opus-5`」として文法的に
# 妥当に読めてしまうため、schema 6のコードは6未満の実体（`schema_version`の
# 行が無い実体を含む）を「追随待ち」として仮想補完せず、一律
# `T4-LEGACY`で解決失敗にする（FR-15）。この非対称（他のキー追加は仮想補完・
# 今回は仮想補完しない）は、文法があいまいに読めてしまう版境界だけの特例
# である。旧`declared<EXPECTED`の仮想補完分岐とT4 advisoryは本案件で撤去した
# （§3.7・T4 advisoryの発生源はここだけだったので、この変更でT4は完全に
# 消える）。
EXPECTED_SCHEMA_VERSION = 6

META_KEYS = ("schema_version", "profile_slug")
CAPABILITY_KEYS = (
    "team_mode",
    "no_read_paths",
    "machine_role",
)
EXTRA_FIXED_KEYS = ("excluded_models",)
FIXED_KEYS_ORDERED = META_KEYS + CAPABILITY_KEYS + EXTRA_FIXED_KEYS  # 宣言順（known-keysの決定的出力用）
FIXED_KEYS = frozenset(FIXED_KEYS_ORDERED)
DYNAMIC_PREFIXES = ("role.", "fallback.")

KEY_RE = re.compile(r"^[A-Za-z0-9_.-]+$")  # 4.1-a: ハイフンを許す
LINE_RE = re.compile(r"^([A-Za-z0-9_.-]+):[ \t]?(.*)$")
ATTR_TOKEN_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_.-]*)=(.+)$")
PROFILE_SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")

ROLE_STATES = frozenset({"configured", "unavailable", "not_adopted", "unknown"})
CAPABILITY_STATES = frozenset({"configured", "unavailable", "unknown"})
PROVIDERS = frozenset({"anthropic-api", "bedrock", "bedrock-mantle", "external"})
EXECUTIONS = frozenset({"subagent", "external-cli", "external-api"})
# 2026-09-08 モデル定義ファイルと候補指定対応（同設計§3.1・FR-8）: role/fallback
# 行が持てる属性は`model`（定義名のカンマ列挙＝候補）だけになった。
# provider/execution/effortは定義ファイル側（MODEL_DEF_ATTR_NAMES）へ移った。
# ⚠️ 互換のために残さない（no-backward-compat）——これだけでFX-B2a
# （role行にprovider=を書く）はparse_v2の「許可されない属性です」でT6に落ちる。
ROLE_ATTR_NAMES = frozenset({"model"})
CAPABILITY_ATTR_NAMES = frozenset({"value"})

# モデル定義ファイル（models.conf）の定義名の形式（同設計§2.3規約4・FR-3）。
MODEL_DEF_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
# モデル定義ファイルの1ブロックが持てる属性名（同設計§2.4）。
MODEL_DEF_ATTR_NAMES = frozenset({"provider", "model", "execution", "effort"})
# モデル定義ファイルの既定パスと注入口（同設計§2.1・§2.2・D-1・D-2）。
DEFAULT_MODEL_DEFS_PATH = "~/.config/takumi009-ai-env/models.conf"

EFFORT_CLAUDE = frozenset({"low", "medium", "high", "xhigh", "max"})
EFFORT_SETTINGS = frozenset({"low", "medium", "high", "xhigh"})  # max不可（V9-e）
EFFORT_CODEX = frozenset({"minimal", "low", "medium", "high", "xhigh"})

SENTINEL = "<fill-in>"

# provider毎のmodel正規表現（適合表§3.3）。[1m]は許容するが判定時は除去する。
MODEL_PATTERNS = {
    "anthropic-api": re.compile(r"^claude-[a-z0-9.-]+(\[1m\])?$"),
    "bedrock": re.compile(r"^[a-z0-9]+(\[1m\])?$"),
    "bedrock-mantle": re.compile(r"^anthropic\.[a-z0-9.-]+$"),
    "external": re.compile(r"^[a-z0-9._-]+$"),
}
BEDROCK_DISALLOWED_MODEL_PREFIXES = ("us.", "eu.", "global.", "arn:")

# V9-d① 実装済みハンドラの写像（execution!=subagentのものだけを列挙する。
# subagent実行は経路そのものがTask toolのspawnであり写像は不要＝常に①を満たす）。
# 2026-09-08 モデル定義ファイルと候補指定対応（同設計§2.4）: 従来は
# (provider,execution,model)の三つ組で`codex-review-default`という1個の
# モデル名だけを許可していたが、FR-13で`execution=external-cli`のmodelは
# 「外部CLIが受理する実IDか予約語default」になり、ハンドラ
# （scripts/codex-exec.sh）はmodel IDを問わず1つしか無いため、写像を
# (provider,execution)の対へ縮める。⚠️ external-apiは対に含めない（未実装の
# まま＝V9-d②は生きている）。
IMPLEMENTED_HANDLERS = frozenset(
    {
        ("external", "external-cli"),
    }
)

# V8-b: 能力軸・excluded_models の value= 厳格形式（U-8裁定）。
CAPABILITY_VALUE_PATTERNS = {
    # team_mode: この案件をどの体制で回すかの既定値（3モード体制-設計-2026-09-06.md
    # §4.1a）。solo|lean|fullの1語のみ。
    "team_mode": re.compile(r"^(?:solo|lean|full)$"),
    # no_read_paths: 読まない・検索しないパスを`~/`表記の実パスでカンマ区切り
    # に列挙する（配役表-能力軸整理-設計-2026-09-07.md §3・要件FR-5。旧版の
    # 別名トークン方式は廃止）。実パスは大文字を含みうるため、本キーだけ
    # _validate_capability_value()の小文字固定規則から除外する。
    "no_read_paths": re.compile(r"^~/[^,\s]+(?:,~/[^,\s]+)*$"),
    # machine_role: この機がメイン機かサブ機かの唯一の正本（同設計§2.1）。
    # main|subの1語のみ。
    "machine_role": re.compile(r"^(?:main|sub)$"),
}
# excluded_modelsのvalue検査は_validate_capability_value()内で要素ごとに
# provider(PROVIDERS)・model(MODEL_PATTERNS)を直接検査する（単純な正規表現1本
# では未知providerを弾けなかった＝Codexレビュー指摘・Major対応。専用の定数は
# 持たない）。

# コア職種マニフェスト（V1-a）: claude/agents/*.md を持たない職種の固定リスト。
# ⚠️ 職種名＝claude/agents/配下のファイル名（拡張子除く）＝Task tool spawn時に
# subagent_typeへ渡す値、という不変条件をここでも維持する（2026-09-03本人裁定:
# scribe職種は「配役表のキーはrole.scribeのままファイル名だけvault-scribe.md」
# という不一致を対応表で吸収する方式を試みたが、サブ機で実際に
# 「role.scribeを見てsubagent_type=scribeでspawn→定義ファイルが無く失敗」が
# 起きたため撤回。対応表〈旧AGENT_FILE_TO_ROLE〉は削除し、配役表側のキーを
# role.vault-scribeへ改名して名前を一致させる方式に統一した）。
# scribeは2026-09-03より claude/agents/vault-scribe.md としてrepoへ収録され
# サブ機へも配布されるようになったため、このリストには含めない（ファイル名
# 走査で自動的に職種名"vault-scribe"としてマニフェストへ入る＝下記
# role_and_core_manifest_diff()参照）。
CORE_ROLES_WITHOUT_REPO_AGENT_FILE = frozenset(
    {"leader", "navi", "ja-doc"}
)
# leaderはspawn対象外なのでV1-bの対象から無条件除外する。
ROLE_EXEMPT_FROM_DEFINITION_CHECK = frozenset({"leader"})

# Bedrockピン留め論理名の導出（§1-3・§6.1）。人はこの名前を書けない
# （role.*が参照する定義のproviderがbedrockのとき、その定義のmodelは
# 別名しか持てないためbedrock_pin_*は常にコードが導出する側）。
BEDROCK_PIN_ENV_VAR = {
    "opus": "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "sonnet": "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "haiku": "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "fable": "ANTHROPIC_DEFAULT_FABLE_MODEL",
}

BEDROCK_ENABLE_KEY = "CLAUDE_CODE_USE_BEDROCK"

# V15: 禁止キー名ガード。大小問わず部分一致で判定する。値は一切読まない
# （キー名だけを見る＝§3.1の文法上、値に秘密が入っていても検出できない
# 残余リスクがある＝F-14。これは既知の限界としてU-8で受容済み）。
FORBIDDEN_KEY_SUBSTRINGS = (
    "access_key",
    "secret",
    "token",
    "password",
    "credential",
    "api_key",
    "auth",
    "authorization",
    "cookie",
    "private_key",
    "passphrase",
)


# ============================================================
# 共通ユーティリティ
# ============================================================


class ProfileError(Exception):
    """MINIMAL行として報告すべき解決失敗（コード＋行番号/キー名のみの理由）。"""

    def __init__(self, code: str, reason: str):
        super().__init__(reason)
        self.code = code
        self.reason = reason


def _read_frontmatter_lines(path: str) -> list[tuple[int, str]]:
    """frontmatter本文の (行番号, 生の行) 一覧を返す。行番号はファイル先頭を1とする。
    frontmatterの開始/終端区切り(---)が無ければ ProfileError(T6) を送出する。
    """
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError as e:
        raise ProfileError("T1", f"実体ファイルを読めません: {type(e).__name__}") from e
    except UnicodeDecodeError as e:
        # Codexレビュー指摘・Major対応: UnicodeDecodeErrorはOSErrorの派生では
        # ないため、従来はここで捕まらず未処理の例外としてtracebackが
        # stderrへ漏れていた（機械可読コードで返す契約に反する）。
        raise ProfileError("T6", f"文字コードが不正です: {type(e).__name__}") from e

    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        raise ProfileError("T6", "frontmatterの開始区切り(---)がありません")
    end_idx = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end_idx = i
            break
    if end_idx is None:
        raise ProfileError("T6", "frontmatterの終端区切り(---)がありません")

    return [(i + 1, lines[i]) for i in range(1, end_idx)]


def _strip_comment(raw: str) -> str:
    """rule 3: 値の後ろの「スペース+#」以降を無視する。"""
    # 属性値はスペース・#を含められない契約なので、最初に現れる「空白+#」で
    # 安全に切ってよい。
    m = re.search(r"\s#", raw)
    return raw[: m.start()] if m else raw


def _peek_declared_schema_version(lines: list[tuple[int, str]]) -> Optional[str]:
    """schema_versionキーの生値だけを緩く走査して取り出す（値の形式検査は
    しない）。役割の行を厳格parseする前段のバージョンゲート専用。"""
    for _lineno, raw in lines:
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        body = _strip_comment(raw).strip()
        if not body:
            continue
        m = LINE_RE.match(body)
        if not m:
            continue
        key, rest = m.group(1), m.group(2).strip()
        if key == "schema_version":
            return rest
    return None


def gate_schema_version(path: str) -> None:
    """2026-09-08 モデル定義ファイルと候補指定対応（同設計§3.7・D-8・FR-15）:
    役割の行の文法が`model=<定義名>[,…]`だけになったため、旧記法
    （`provider=… model=… effort=…`）で書かれた6未満の実体はparse_v2の
    ROLE_ATTR_NAMES検査に先に引っかかり、一般的な`T6`（「許可されない属性
    です」）になってしまう——これだとFR-15が要求する「理由から実体が旧版で
    あることが読める」を満たせない。そこで役割の行を厳格parseする<u>前</u>に
    宣言versionだけを緩く読み、EXPECTED未満または欠落なら直ちに
    `T4-LEGACY`で止める（旧記法の構文がどうであれ、版だけで即座に弾く）。
    ⚠️ schema_versionの値がそもそも数値として不正（非数値・0以下）な場合は
    ここでは判定せず、通常のparse_v2→validate_meta()のT3へ委ねる
    （このゲートは「版が低い/無い」の2ケースだけを先取りする）。
    """
    lines = _read_frontmatter_lines(path)  # T1/T6（frontmatter区切り等）はここで素通り
    raw = _peek_declared_schema_version(lines)
    if raw is None:
        raise ProfileError(
            "T4-LEGACY",
            f"実体が旧版です（schema_versionの行がありません・このコードはschema {EXPECTED_SCHEMA_VERSION} のみを受理します）",
        )
    if re.match(r"^[0-9]+$", raw) and int(raw) > 0 and int(raw) < EXPECTED_SCHEMA_VERSION:
        raise ProfileError(
            "T4-LEGACY",
            f"実体が旧版です（schema_version={int(raw)}・このコードはschema {EXPECTED_SCHEMA_VERSION} のみを受理します）",
        )


def preflight_forbidden_keys(path: str) -> list[tuple[int, str]]:
    """V15（§3.5 評価順②）。frontmatterの内外・v1/v2の別を問わず、ファイル全体を
    キー名だけ緩く走査する（値は一切読まない）。分類・parserより前に実行する
    契約なので、frontmatterが壊れていても独立して動く必要がある。
    """
    hits: list[tuple[int, str]] = []
    try:
        with open(path, encoding="utf-8") as f:
            for lineno, raw in enumerate(f, start=1):
                stripped = raw.strip()
                if not stripped or stripped.startswith("#") or stripped == "---":
                    continue
                m = re.match(r"^([A-Za-z0-9_.-]+):", stripped)
                if not m:
                    continue
                key = m.group(1)
                lower = key.lower()
                if any(sub in lower for sub in FORBIDDEN_KEY_SUBSTRINGS):
                    hits.append((lineno, key))
    except (OSError, UnicodeDecodeError):
        return []
    return hits


# 2026-09-08 モデル定義ファイルと候補指定対応（同設計§3.8・D-13）:
# 旧・版分類関数（v1/v2/mixed判定）を撤去した。schema 6のコードは
# schema_versionの行が無い実体（v1形式そのもの）を含む6未満の全実体を
# T4-LEGACYで一律解決失敗にするため（FR-15）、分類そのものが不要になった
# （no-backward-compat。v1委譲経路の撤去範囲＝同設計§3.8）。


# ============================================================
# v2 parser（§3.1 文法規約）
# ============================================================


class RoleLine:
    __slots__ = ("name", "state", "attrs", "lineno", "kind", "candidates")

    def __init__(self, name: str, state: str, attrs: dict, lineno: int, kind: str):
        self.name = name
        self.state = state
        self.attrs = attrs
        self.lineno = lineno
        self.kind = kind  # "role" | "fallback"
        # 2026-09-08 モデル定義ファイルと候補指定対応（同設計§3.1 RoleLine差分）:
        # role/fallback行の`model=`はカンマ区切りの定義名候補になった。attrsは
        # 生文字列のまま保持し、ここで候補一覧を派生させる（capability行等
        # `model`属性を持たない行はcandidates=[]のまま）。
        raw_model = attrs.get("model")
        self.candidates: list[str] = (
            [c.strip() for c in raw_model.split(",")] if raw_model else []
        )


class ParsedProfile:
    def __init__(self):
        self.meta: dict[str, str] = {}
        self.meta_lineno: dict[str, int] = {}
        self.roles: dict[str, RoleLine] = {}
        self.fallbacks: dict[str, RoleLine] = {}
        self.capability: dict[str, RoleLine] = {}
        self.excluded_models: Optional[RoleLine] = None
        self.extras: dict[str, int] = {}  # 未知キー -> 行番号


def parse_v2(path: str) -> ParsedProfile:
    """§3.1 の8項規約に従って parse する。違反はすべて ProfileError(T6) にする。
    行番号とキー名だけを理由に含める（§3.1-8・値・行全文は含めない）。
    """
    lines = _read_frontmatter_lines(path)
    parsed = ParsedProfile()
    seen_keys: set[str] = set()

    for lineno, raw in lines:
        stripped = raw.strip()
        if not stripped:
            continue  # rule 4
        if stripped.startswith("#"):
            continue  # rule 3a
        body = _strip_comment(raw).strip()  # rule 3b
        if not body:
            continue

        m = LINE_RE.match(body)
        if not m:
            raise ProfileError("T6", f"{lineno}行目: 解析できない行です")
        key, rest = m.group(1), m.group(2).strip()

        if not KEY_RE.match(key):
            raise ProfileError("T6", f"{lineno}行目: キー名の形式が不正です（{key}）")
        if key in seen_keys:
            raise ProfileError("T6", f"{lineno}行目: キーが重複しています（{key}）")
        seen_keys.add(key)

        if key in META_KEYS:
            parsed.meta[key] = rest
            parsed.meta_lineno[key] = lineno
            continue

        # 状態＋属性を持つ行（role./fallback./能力軸3キー/excluded_models）。
        tokens = rest.split()
        state = tokens[0] if tokens else ""
        attr_tokens = tokens[1:]
        if state == "":
            # rule 6: 未記載・空はunknown。
            state = "unknown"

        attrs: dict[str, str] = {}
        for tok in attr_tokens:
            am = ATTR_TOKEN_RE.match(tok)
            if not am:
                raise ProfileError("T6", f"{lineno}行目: 属性の形式が不正です（{key}）")
            aname, aval = am.group(1), am.group(2)
            if aname in attrs:
                raise ProfileError(
                    "T6", f"{lineno}行目: 属性が重複しています（{key}.{aname}）"
                )
            attrs[aname] = aval

        if key.startswith(DYNAMIC_PREFIXES):
            prefix, name = key.split(".", 1)
            kind = "role" if prefix == "role" else "fallback"
            allowed = ROLE_ATTR_NAMES
            for aname in attrs:
                if aname not in allowed:
                    raise ProfileError(
                        "T6", f"{lineno}行目: 許可されない属性です（{key}.{aname}）"
                    )
            line_obj = RoleLine(name, state, attrs, lineno, kind)
            target = parsed.roles if kind == "role" else parsed.fallbacks
            if name in target:
                # 同一プレフィックス内の同名職種重複（例: role.leaderが2行）。
                raise ProfileError("T6", f"{lineno}行目: 職種行が重複しています（{key}）")
            target[name] = line_obj
        elif key == "excluded_models":
            for aname in attrs:
                if aname not in CAPABILITY_ATTR_NAMES:
                    raise ProfileError(
                        "T6", f"{lineno}行目: 許可されない属性です（{key}.{aname}）"
                    )
            parsed.excluded_models = RoleLine(key, state, attrs, lineno, "meta-state")
        elif key in CAPABILITY_KEYS:
            for aname in attrs:
                if aname not in CAPABILITY_ATTR_NAMES:
                    raise ProfileError(
                        "T6", f"{lineno}行目: 許可されない属性です（{key}.{aname}）"
                    )
            parsed.capability[key] = RoleLine(key, state, attrs, lineno, "capability")
        else:
            parsed.extras[key] = lineno

    return parsed


# ============================================================
# メタ検査（V14）・版判定（T3/T4'/T5/T9'）
# ============================================================


def validate_meta(parsed: ParsedProfile) -> int:
    """V14: schema_versionは正整数1個・profile_slugは規約どおり・メタキー重複なし
    （重複はparse_v2が既にT6で検出済みなのでここでは形式のみ見る）。
    戻り値: declared schema_version（整数）。不正ならProfileError(T3)。
    """
    raw = parsed.meta.get("schema_version")
    if raw is None:
        # 2026-09-08 モデル定義ファイルと候補指定対応（同設計§3.1・§3.7・D-8）:
        # schema_versionの行が無い実体はv1形式そのものなので、T3（メタ欠落）
        # ではなくT4-LEGACY（旧版）として扱う。FR-15の固定語「旧版」をここで
        # 満たす（5口すべてが同じコードに落ちる＝reconcile_schema_versionの
        # declared<EXPECTED分岐と同じコード）。
        raise ProfileError(
            "T4-LEGACY",
            f"実体が旧版です（schema_versionの行がありません・このコードはschema {EXPECTED_SCHEMA_VERSION} のみを受理します）",
        )
    if not re.match(r"^[0-9]+$", raw) or int(raw) <= 0:
        raise ProfileError("T3", "schema_versionの形式が不正です")
    version = int(raw)

    slug = parsed.meta.get("profile_slug")
    if slug is not None and not PROFILE_SLUG_RE.match(slug):
        raise ProfileError("T14", "profile_slugの形式が不正です")

    return version


def reconcile_schema_version(parsed: ParsedProfile, declared: int) -> list[str]:
    """T4'（実体の版>コードの版）・T5（版が同じなのに固定キーが欠落）・
    T9'（UNKNOWN_EXTRA）を判定する。戻り値はadvisory文言のリスト
    （呼び出し側がstderr相当のwarningとして使う）。T5・T4-LEGACYはProfileErrorを
    送出する。
    2026-09-08 モデル定義ファイルと候補指定対応（同設計§3.1・§3.7・D-8）:
    `declared < EXPECTED`の仮想補完分岐（欠落キーをunknownで補って通す・
    T4 advisory）を撤去した。役割の行の文法が`model=<定義名>[,…]`へ変わり、
    旧記法（`model=claude-opus-5`等）が新文法でも「定義名」として文法的に
    妥当に読めてしまうため、6未満はすべて`T4-LEGACY`で解決失敗にする
    （FR-15。追随待ちとして通さない）。この分岐がT4 advisoryの唯一の
    発生源だったので、T4は本案件でコードから完全に消える。
    """
    warnings: list[str] = []
    known_present = set(parsed.meta) | set(parsed.capability)
    if parsed.excluded_models is not None:
        known_present.add("excluded_models")

    if declared == EXPECTED_SCHEMA_VERSION:
        missing = sorted(
            k
            for k in FIXED_KEYS
            if k not in known_present
        )
        if missing:
            raise ProfileError("T5", "既知キーが欠落しています: " + ",".join(missing))
    elif declared > EXPECTED_SCHEMA_VERSION:
        warnings.append("T4-PRIME:このマシンのコードが古い可能性があります（版がコードの期待より新しい）")
    else:
        # declared < EXPECTED_SCHEMA_VERSION（schema_versionの行自体が無い
        # ケースはvalidate_meta()が先にT4-LEGACYで捕まえるので、ここに来る
        # のは数値として書かれてはいるが6未満の実体だけ）。
        raise ProfileError(
            "T4-LEGACY",
            f"実体が旧版です（schema_version={declared}・このコードはschema {EXPECTED_SCHEMA_VERSION} のみを受理します）",
        )

    if parsed.extras:
        # T9': 機械側は既知キー部分のみ有効・AI側は必読除外（§4a）。
        pass  # 呼び出し側がUNKNOWN_EXTRAフィールドとして出力する。

    return warnings


def sentinel_violations(parsed: ParsedProfile) -> list[str]:
    """T2': sentinel <fill-in> が残っているキーの一覧（能力軸・excluded_modelsの
    value=属性と、メタ値の両方を見る）。"""
    hit = []
    for key, line in parsed.capability.items():
        if line.attrs.get("value") == SENTINEL:
            hit.append(key)
    if parsed.excluded_models is not None and parsed.excluded_models.attrs.get("value") == SENTINEL:
        hit.append("excluded_models")
    for key, val in parsed.meta.items():
        if val == SENTINEL:
            hit.append(key)
    return hit


# ============================================================
# validator（§5）
# ============================================================


def _fail(code: str, detail: str) -> ProfileError:
    return ProfileError("T8", f"{code}: {detail}")


def _validate_capability_value(key: str, value: str) -> None:
    """V8-bの個別厳格形式＋共通規則（空要素・末尾カンマ・要素重複の禁止・
    200文字以内・小文字固定）。sentinelは
    sentinel_violations()が先に捕まえる契約なのでここには来ない前提だが、
    念のためsentinelは形式検査の対象外にする（多重にMINIMALへ倒れても
    実害は無いため防御的に許容する）。
    """
    if value == SENTINEL:
        return
    if len(value) > 200:
        raise _fail("V8-b", f"{key}のvalueが長すぎます")
    if key == "excluded_models" and value == "none":
        return  # noneは唯一の単独トークンとして許可（カンマ規則の対象外）
    if value == "" or value.endswith(","):
        raise _fail("V8-b", f"{key}のvalueが空または末尾カンマです")
    parts = value.split(",")
    if any(p == "" for p in parts):
        raise _fail("V8-b", f"{key}のvalueに空要素があります")
    if len(parts) != len(set(parts)):
        raise _fail("V8-b", f"{key}のvalueに重複要素があります")
    # no_read_pathsは実パス書式（`~/`表記）であり大文字を含みうるため、
    # 小文字固定規則の対象外にする（要件FR-5・リーダー裁定2026-09-07）。
    if key != "no_read_paths" and value != value.lower():
        raise _fail("V8-b", f"{key}のvalueは小文字である必要があります")

    if key == "excluded_models":
        # Codexレビュー指摘・Major対応: 従来の正規表現(EXCLUDED_MODELS_VALUE_RE)は
        # provider部分が任意の小文字トークンを受理してしまい、未知providerでも
        # 形式検査を素通りしてV16の一致判定が静かに無効化されていた。要素ごとに
        # providerをPROVIDERS集合、modelを対応するMODEL_PATTERNSで検査する。
        for item in parts:
            if item.count("/") != 1:
                raise _fail("V8-b", f"{key}の要素形式が不正です")
            provider, model = item.split("/", 1)
            if provider not in PROVIDERS:
                raise _fail("V8-b", f"{key}のproviderが不正です")
            if not MODEL_PATTERNS[provider].match(model):
                raise _fail("V8-b", f"{key}のmodel形式が不正です")
        return

    pattern = CAPABILITY_VALUE_PATTERNS.get(key)
    if pattern and not pattern.match(value):
        raise _fail("V8-b", f"{key}のvalue形式が不正です")


def validate_capability_keys(parsed: ParsedProfile) -> None:
    """V7・V8-a（能力軸・excluded_models側）・V8-b。excluded_modelsも能力軸と
    同じ3状態enum（§3.3）なので同一ロジックで検査する（設計を裏切らない）。
    """
    lines_by_key: dict[str, RoleLine] = dict(parsed.capability)
    if parsed.excluded_models is not None:
        lines_by_key["excluded_models"] = parsed.excluded_models

    for key in (*CAPABILITY_KEYS, "excluded_models"):
        line = lines_by_key.get(key)
        if line is None:
            continue  # 欠落はreconcile_schema_versionのT5が既に検出済み
        if line.state not in CAPABILITY_STATES:
            raise _fail("V7", f"{key}の状態が不正です（{line.lineno}行目）")
        if line.state == "configured":
            if "value" not in line.attrs:
                raise _fail("V8-a", f"{key}にvalue属性がありません（{line.lineno}行目）")
            _validate_capability_value(key, line.attrs["value"])
        else:
            if line.attrs:
                raise _fail(
                    "V8-a", f"{key}はunavailable/unknown状態で属性を持てません（{line.lineno}行目）"
                )


def _normalize_model_for_exclusion(model: str) -> str:
    return re.sub(r"\[1m\]$", "", model)


def _excluded_pairs(parsed: ParsedProfile) -> set[tuple[str, str]]:
    if parsed.excluded_models is None or parsed.excluded_models.state != "configured":
        return set()  # unavailable/unknownは「除外リストが今は無い」に等しい
    value = parsed.excluded_models.attrs.get("value", "none")
    if value in ("none", SENTINEL):
        return set()
    pairs = set()
    for item in value.split(","):
        if "/" not in item:
            continue
        provider, model = item.split("/", 1)
        pairs.add((provider, _normalize_model_for_exclusion(model)))
    return pairs


# ============================================================
# モデル定義ファイル（models.conf）（同設計§2.2〜§2.4）
# ============================================================


def model_defs_path() -> str:
    """モデル定義ファイルの位置を決める唯一の関数。⚠️ このファイルで
    os.environ を読むのはここだけ（D-2）。⚠️ 相対パスは受理しない——受理すると、
    同じ変数を見ていても呼び出し元のcwd（bootstrapはHOME・installerはrepo
    ルート・CLIは任意）ごとに別のファイルを指し、FR-1の「すべてが同じ変数を
    見る」が「同じ実体を指す」を意味しなくなる（同設計§2.2）。
    """
    raw = os.environ.get("AIENV_MODEL_DEFS_FILE") or DEFAULT_MODEL_DEFS_PATH
    if not (raw.startswith("/") or raw.startswith("~/")):
        raise ProfileError("T13", "AIENV_MODEL_DEFS_FILEは絶対パスか~/始まりで指定してください")
    return os.path.expanduser(raw)


class ModelDef:
    """モデル定義ファイルの1ブロック（同設計§2.3）。宣言順を保つため
    dict[定義名, ModelDef]の値として保持される想定（呼び出し側がdictの
    挿入順を維持する）。"""

    __slots__ = ("name", "provider", "model", "execution", "effort", "lineno")

    def __init__(self, name: str, lineno: int):
        self.name = name
        self.provider: Optional[str] = None
        self.model: Optional[str] = None
        self.execution: Optional[str] = None
        self.effort: Optional[str] = None
        self.lineno = lineno


_MODEL_DEF_BLOCK_RE = re.compile(r"^\[(.*)\]$")
_MODEL_DEF_ATTR_RE = re.compile(r"^([a-z][a-z0-9_-]*)=(\S+)$")


def parse_model_defs(path: str) -> dict[str, ModelDef]:
    """§2.3の文法規約に従って models.conf を parse する。⚠️ 配役表のパーサ
    （parse_v2）とは別関数（文法が違うので分岐で混ぜない）。
    違反はすべて ProfileError(T12) にする（行番号つき）。ファイルが無い・
    読めない・UTF-8として壊れている場合は ProfileError(T7)。
    """
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except (OSError, UnicodeDecodeError) as e:
        raise ProfileError(
            "T7", f"モデル定義ファイルを読めません（{path}）: {type(e).__name__}"
        ) from e

    defs: dict[str, ModelDef] = {}
    current: Optional[ModelDef] = None
    seen_attrs: set[str] = set()

    for lineno, raw in enumerate(text.splitlines(), start=1):
        stripped = raw.strip()
        if not stripped:  # rule 1
            continue
        if stripped.startswith("#"):  # rule 2
            continue

        block_m = _MODEL_DEF_BLOCK_RE.match(stripped)
        if block_m:
            name = block_m.group(1)
            if not MODEL_DEF_NAME_RE.match(name):  # rule 4
                raise ProfileError("T12", f"{lineno}行目: 定義名の形式が不正です")
            if name in defs:  # rule 7
                raise ProfileError("T12", f"{lineno}行目: 定義名が重複しています（{name}）")
            current = ModelDef(name, lineno)
            defs[name] = current
            seen_attrs = set()
            continue

        attr_m = _MODEL_DEF_ATTR_RE.match(stripped)  # rule 3・5（行末コメント・
        # 空白混じりの値はこの正規表現に一致せず自動的にT12へ落ちる）
        if not attr_m:
            raise ProfileError("T12", f"{lineno}行目: 解析できない行です")
        aname, aval = attr_m.group(1), attr_m.group(2)
        if current is None:  # rule 6
            raise ProfileError("T12", f"{lineno}行目: 定義ブロックの外に属性行があります")
        if aname in seen_attrs:  # rule 8
            raise ProfileError(
                "T12", f"{lineno}行目: 属性が重複しています（{current.name}.{aname}）"
            )
        seen_attrs.add(aname)
        if aname not in MODEL_DEF_ATTR_NAMES:
            raise ProfileError("T12", f"{lineno}行目: 未知の属性名です（{aname}）")
        setattr(current, aname, aval)

    return defs


def validate_model_def(d: ModelDef) -> None:
    """§2.4の属性検査。1定義（ModelDef）を検査する。違反はProfileError(T12)。
    ⚠️ 検査は定義ファイル側で行い、行番号は定義ファイルの行番号を出す（D-4）。
    """
    if d.provider is None:
        raise ProfileError("T12", f"{d.lineno}行目: providerがありません（{d.name}）")
    if d.provider not in PROVIDERS:
        raise ProfileError("T12", f"{d.lineno}行目: providerが不正です（{d.name}）")
    if d.model is None:
        raise ProfileError("T12", f"{d.lineno}行目: modelがありません（{d.name}）")

    pattern = MODEL_PATTERNS[d.provider]
    if not pattern.match(d.model):
        raise ProfileError("T12", f"{d.lineno}行目: model形式が不正です（{d.name}）")
    if d.provider == "bedrock" and d.model.startswith(BEDROCK_DISALLOWED_MODEL_PREFIXES):
        raise ProfileError("T12", f"{d.lineno}行目: modelが別名ではありません（{d.name}）")

    execution = d.execution or "subagent"
    if execution not in EXECUTIONS:
        raise ProfileError("T12", f"{d.lineno}行目: executionが不正です（{d.name}）")
    if d.provider == "external":
        if d.execution is None:
            raise ProfileError(
                "T12", f"{d.lineno}行目: providerがexternalなのにexecutionが未指定です（{d.name}）"
            )
    else:
        if execution != "subagent":
            raise ProfileError(
                "T12", f"{d.lineno}行目: このproviderでこのexecutionは指定できません（{d.name}）"
            )
    d.execution = execution  # 既定値を確定させる

    if d.effort is not None:
        # execution=external-cliならCodex方言・それ以外はClaude方言
        # （§2.4「同時にeffortの許可集合を…execution=external-cliならCodex方言へ
        # 広げる」）。
        allowed_effort = EFFORT_CODEX if execution == "external-cli" else EFFORT_CLAUDE
        if d.effort not in allowed_effort:
            raise ProfileError("T12", f"{d.lineno}行目: effortが不正です（{d.name}）")


def validate_model_defs(defs: dict[str, ModelDef]) -> None:
    for d in defs.values():
        validate_model_def(d)


def load_model_defs(path: str) -> dict[str, ModelDef]:
    """読取→parse→validateをまとめる。失敗はProfileError("T7"/"T12", …)。"""
    defs = parse_model_defs(path)
    validate_model_defs(defs)
    return defs


def agent_declared_model(role: str, agents_dir: Optional[str]) -> Optional[str]:
    """claude/agents/<role>.md の frontmatter の model: を返す。ファイルが無い・
    model: 行が無い・agents_dirがNoneならNone（＝突合しない）。
    突合は文字列の完全一致で行う（前後の空白と引用符だけ除去する。⚠️ 別名へ
    翻訳しない・[1m]を正規化しない＝FR-12）。
    """
    if not agents_dir:
        return None
    path = os.path.join(agents_dir, f"{role}.md")
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except (OSError, UnicodeDecodeError):
        return None
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return None
    end_idx = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end_idx = i
            break
    if end_idx is None:
        return None
    for raw in lines[1:end_idx]:
        m = re.match(r"^model:\s*(.*)$", raw.strip())
        if m:
            return m.group(1).strip().strip("\"'")
    return None


# ============================================================
# role/fallback行の候補解決（同設計§3.2 評価順①〜⑤）
# ============================================================


def validate_role_line_format(line: RoleLine) -> None:
    """②役割の行の文法検査（V7・V8-a）。2026-09-08 モデル定義ファイルと候補
    指定対応: role/fallback行の属性は`model`（定義名のカンマ列挙）だけになった
    （FR-8）。provider/execution/effortの形式検査は定義ファイル側
    （validate_model_def）へ移った。ここで見るのは状態enum・属性の有無・
    候補名の形式（MODEL_DEF_NAME_RE）・候補名の重複だけ。
    """
    if line.state not in ROLE_STATES:
        raise _fail("V7", f"role.{line.name}の状態が不正です（{line.lineno}行目）")

    if line.state in ("not_adopted", "unknown"):
        if line.attrs:
            raise _fail(
                "V8-a",
                f"role.{line.name}はnot_adopted/unknown状態で属性を持てません（{line.lineno}行目）",
            )
        return

    # configured / unavailable
    if "model" not in line.attrs:
        raise _fail("V8-a", f"role.{line.name}にmodelがありません（{line.lineno}行目）")
    candidates = line.candidates
    if not candidates or any(c == "" for c in candidates):
        raise _fail("V8-a", f"role.{line.name}のmodelに空の候補があります（{line.lineno}行目）")
    if len(candidates) != len(set(candidates)):
        raise _fail(
            "V8-a", f"role.{line.name}のmodelに同じ定義名が重複しています（{line.lineno}行目）"
        )
    for c in candidates:
        # ⚠️ 形式に一致しない文字列はエコーしない（値・任意文字列を理由に
        # 含めない原則の例外にしない＝§3.2「2段構えを崩さないこと」）。
        if not MODEL_DEF_NAME_RE.match(c):
            raise _fail("V8-a", f"role.{line.name}の候補名の形式が不正です（{line.lineno}行目）")


def resolve_role_candidates(
    line: RoleLine, model_defs: dict[str, ModelDef], excluded: set[tuple[str, str]]
) -> list[ModelDef]:
    """③候補名の解決（V17）・④除外判定（V16）・⑤ハンドラ未実装（V9-d②）。
    lineはvalidate_role_line_format済み（state in configured/unavailable・
    candidatesが非空で形式検査済み）である前提。戻り値は記述順の解決済み
    ModelDef一覧。違反はProfileError(T8)を送出する（その行ごとエラー）。
    """
    prefix = "fallback." if line.kind == "fallback" else "role."
    resolved: list[ModelDef] = []
    for cand in line.candidates:
        d = model_defs.get(cand)
        if d is None:
            raise _fail(
                "V17",
                f"{prefix}{line.name} が未定義の定義名を参照しています（{cand}・{line.lineno}行目）",
            )
        resolved.append(d)

    for d in resolved:
        pair = (d.provider, _normalize_model_for_exclusion(d.model))
        if pair in excluded:
            raise _fail("V16", f"{prefix}{line.name}が禁止モデルを使っています（{line.lineno}行目）")

    if line.state == "configured":
        # V9-d①②（構造的なハンドラ写像違反。単独で職種を縮退させるのではなく
        # 実体全体をMINIMALへ倒す＝exit契約でV9-d①②はfail区分）。⚠️ V9-d②は
        # 「configuredにできない」という規定であり、unavailable（＝使いたいが
        # 今は動かせないという意図の記録）までは塞がない。
        for d in resolved:
            execution = d.execution or "subagent"
            if execution == "external-api":
                raise _fail(
                    "V9-d",
                    f"{prefix}{line.name}のexecution=external-apiはハンドラ未実装です（{line.lineno}行目）",
                )
            if execution != "subagent" and (d.provider, execution) not in IMPLEMENTED_HANDLERS:
                raise _fail(
                    "V9-d",
                    f"{prefix}{line.name}の(provider,execution)組がハンドラ未実装です（{line.lineno}行目）",
                )

    return resolved


def resolve_roles_and_fallbacks(
    parsed: ParsedProfile, model_defs: dict[str, ModelDef]
) -> dict[tuple[str, str], list[ModelDef]]:
    """role.表・fallback.表のすべての行についてV7/V8-a（②）を検査し、
    configured/unavailable状態の行は候補解決・除外判定・ハンドラ検査
    （③④⑤）まで行う。戻り値: {(kind, name): [解決済みModelDef, ...]}
    （configured/unavailableの行だけがキーを持つ。記述順を保つ）。
    """
    excluded = _excluded_pairs(parsed)
    resolved: dict[tuple[str, str], list[ModelDef]] = {}

    for name, line in parsed.roles.items():
        validate_role_line_format(line)
        if line.state in ("configured", "unavailable"):
            resolved[("role", name)] = resolve_role_candidates(line, model_defs, excluded)

    for name, line in parsed.fallbacks.items():
        validate_role_line_format(line)
        if line.state in ("configured", "unavailable"):
            resolved[("fallback", name)] = resolve_role_candidates(line, model_defs, excluded)
        # V6: fallbackが指す職種はrole.表にも存在すること。
        if name not in parsed.roles:
            raise _fail("V6", f"fallback.{name}に対応するrole.{name}がありません（{line.lineno}行目）")

    return resolved


def role_and_core_manifest_diff(parsed: ParsedProfile, agents_dir: Optional[str]) -> tuple[list[str], list[str]]:
    """V1-a: role.表とコア職種マニフェストの対称差（advisory・職種名のみ）。
    戻り値: (role表にはあるがマニフェストに無い, マニフェストにはあるがrole表に無い)
    """
    manifest = set(CORE_ROLES_WITHOUT_REPO_AGENT_FILE)
    if agents_dir and os.path.isdir(agents_dir):
        for fname in os.listdir(agents_dir):
            if fname.endswith(".md"):
                # 職種名＝ファイル名（拡張子除く）の不変条件どおり、正規化は
                # 一切行わない（2026-09-03本人裁定: 対応表によるファイル名→
                # 職種名の変換〈旧AGENT_FILE_TO_ROLE〉は撤回した。ファイル名と
                # 異なる職種名を使いたい場合は、配役表側のキーをファイル名へ
                # 改名して揃える）。
                manifest.add(fname[: -len(".md")])
    role_names = set(parsed.roles)
    only_in_profile = sorted(role_names - manifest)
    only_in_manifest = sorted(manifest - role_names)
    return only_in_profile, only_in_manifest


def role_definition_exists(name: str, execution: str, agents_dir: Optional[str]) -> bool:
    """V1-b: executionがsubagent（既定含む）の候補について定義ファイルが存在すること。
    leaderは無条件除外（呼び出し側でスキップ済みである前提だが、防御的に真を返す）。
    """
    if name in ROLE_EXEMPT_FROM_DEFINITION_CHECK:
        return True
    if execution != "subagent":
        return True  # external-*はV1-bの対象外
    if agents_dir is None:
        return True  # agents_dir未指定＝判定材料が無い＝判定不能を"存在する"側へ倒す
    # 職種名＝ファイル名（拡張子除く）の不変条件どおり、常にagents_dir配下を
    # 職種名そのままで引く（2026-09-03本人裁定: scribe職種の機体ローカル
    # 定義への専用写像〈旧ROLE_LOCAL_AGENT_FILE〉は撤回した。vault-scribe.mdは
    # repo収録済みでagents_dir配下にあるため、他の職種と同じ経路で判定できる）。
    return os.path.isfile(os.path.join(agents_dir, f"{name}.md"))


# ============================================================
# Bedrock関連（V9-d③・V12）
# ============================================================


def bedrock_env_file_kind(path: Optional[str]) -> str:
    if not path:
        return "ABSENT"
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return "ABSENT"
    except OSError:
        return "UNAVAILABLE"
    if stat.S_ISLNK(st.st_mode):
        try:
            st = os.stat(path)
        except OSError:
            return "UNAVAILABLE"
    return "OK" if stat.S_ISREG(st.st_mode) else "UNAVAILABLE"


def _read_bedrock_env_wanted(path: str, wanted_keys: set[str]) -> Optional[dict[str, str]]:
    """wanted_keysに含まれるキーだけを読む。それ以外のキー（AWS認証情報等）は
    一切保持しない（絶対厳守③）。読めない場合はNone。
    ⚠️ tester独立検証・Major差し戻し対応（2026-09-01）: bedrock.envに不正な
    UTF-8バイト列が含まれると、for行での読取中にUnicodeDecodeError（OSErrorの
    派生ではない）が送出され、従来はここで捕まらず未処理例外として
    resolve/check-candidate/resolve-leaderへ伝播していた（--check-profileでは
    生tracebackがstdoutへ流れ§4契約違反、bootstrap経由では2>/dev/nullで
    吸収されるが全職種が一律T10へ丸められ、§3.7「判定不能はワーカーなら
    通す」より広い縮退になっていた）。既存の「読めない＝None」経路
    （呼び出し側のbedrock_route_enabled/bedrock_pin_satisfiedがUNAVAILABLE/
    unknownとして扱う）へ合流させる。"""
    result: dict[str, str] = {}
    try:
        with open(path, encoding="utf-8") as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k = k.strip()
                if k in wanted_keys:
                    result[k] = v.strip()
    except (OSError, UnicodeDecodeError):
        return None
    return result


def bedrock_route_enabled(bedrock_env: Optional[str]) -> str:
    """V9-d③。戻り値: 'enabled' | 'disabled' | 'unknown'（§3.7の判定不能）。"""
    kind = bedrock_env_file_kind(bedrock_env)
    if kind == "ABSENT":
        return "disabled"
    if kind == "UNAVAILABLE":
        return "unknown"
    values = _read_bedrock_env_wanted(bedrock_env, {BEDROCK_ENABLE_KEY})
    if values is None:
        return "unknown"
    v = values.get(BEDROCK_ENABLE_KEY, "").strip().lower()
    return "enabled" if v in ("1", "true") else "disabled"


def bedrock_pin_env_var(alias: str) -> Optional[str]:
    alias = re.sub(r"\[1m\]$", "", alias)
    return BEDROCK_PIN_ENV_VAR.get(alias)


def bedrock_pin_satisfied(provider: str, model: str, bedrock_env: Optional[str]) -> str:
    """V12。戻り値: 'satisfied' | 'missing' | 'unknown'。providerがbedrock以外は
    'satisfied'（対象外）を返す。"""
    if provider != "bedrock":
        return "satisfied"
    var = bedrock_pin_env_var(model)
    if var is None:
        return "missing"  # 別名がそもそも認識できない＝ピンの導出先が無い
    kind = bedrock_env_file_kind(bedrock_env)
    if kind == "ABSENT":
        return "missing"
    if kind == "UNAVAILABLE":
        return "unknown"
    values = _read_bedrock_env_wanted(bedrock_env, {var})
    if values is None:
        return "unknown"
    val = values.get(var, "")
    return "satisfied" if val.strip() != "" else "missing"


# ============================================================
# check-candidate（§8注記の共有関数。CLIエントリはmain()側）
# ============================================================


class CandidateFail(Exception):
    def __init__(self, code: str, reason: str):
        super().__init__(reason)
        self.code = code
        self.reason = reason


def check_candidate(
    provider: str,
    model: str,
    effort: Optional[str],
    execution: Optional[str],
    for_leader: bool,
    role_name: Optional[str],
    bedrock_env: Optional[str],
    agents_dir: Optional[str],
) -> None:
    """1組の(provider, model, effort)を検査する。違反はCandidateFailを送出する。
    role_nameが指定されたときだけV1-b/V9-d③/V12まで評価する
    （契約書§5の評価順どおり）。
    2026-09-08 モデル定義ファイルと候補指定対応: role/fallback行がもう
    provider/execution/effortを持たない（validate_role_line_formatの意味が
    変わった）ため、旧`fake = RoleLine(...)`経由での検査をやめ、
    validate_model_def()と同じ規則をここへ複製する（新しい判定規則は
    作らない・§2.4の規則をそのまま使う）。
    """
    execution = execution or "subagent"
    label = role_name or "candidate"

    if provider not in PROVIDERS:
        raise CandidateFail("V9-b", f"role.{label}のproviderが不正です")
    if execution not in EXECUTIONS:
        raise CandidateFail("V9-b", f"role.{label}のexecutionが不正です")
    if provider != "external" and execution != "subagent":
        raise CandidateFail(
            "V9-b", f"role.{label}はこのproviderでこのexecutionを指定できません"
        )

    pattern = MODEL_PATTERNS[provider]
    if not pattern.match(model):
        raise CandidateFail("V9-b", f"role.{label}のmodel形式が不正です")
    if provider == "bedrock" and model.startswith(BEDROCK_DISALLOWED_MODEL_PREFIXES):
        raise CandidateFail("V9-b", f"role.{label}のmodelが別名ではありません")

    if effort is not None:
        if provider == "external":
            if execution == "external-cli":
                allowed_effort = EFFORT_CODEX
            else:
                raise CandidateFail("V9-b", f"role.{label}のexternalハンドラはeffortを書けません")
        else:
            allowed_effort = EFFORT_CLAUDE
        if effort not in allowed_effort:
            raise CandidateFail("V9-b", f"role.{label}のeffortが不正です")

    # V9-d①②（構造的なハンドラ写像違反。fakeの状態は常にconfigured相当）。
    if execution == "external-api":
        raise CandidateFail("V9-d", f"role.{label}のexecution=external-apiはハンドラ未実装です")
    if execution != "subagent" and (provider, execution) not in IMPLEMENTED_HANDLERS:
        raise CandidateFail("V9-d", f"role.{label}の(provider,execution)組がハンドラ未実装です")

    if for_leader:
        # 契約書§5の評価順どおりV9-eをleader専用「provider≠external」規則より
        # 先に判定する（Codexレビュー指摘・Major対応: 従来は逆順でexternal規則が
        # 先に落ちており、V9-eで弾かれるべきexternal×Codex方言以外のeffort値が
        # LEADER-EXTERNALとして誤って報告されていた）。
        if effort is not None and effort not in EFFORT_SETTINGS:
            raise CandidateFail("V9-e", "settings.jsonのeffortLevelが受理しない値です")
        if provider == "external":
            raise CandidateFail("LEADER_PROVIDER_EXTERNAL", "リーダーにprovider=externalは指定できません")

    if role_name is not None:
        if not role_definition_exists(role_name, execution, agents_dir):
            raise CandidateFail("V1-b", f"{role_name}の定義ファイルがありません")
        route = bedrock_route_enabled(bedrock_env) if provider in ("bedrock", "bedrock-mantle") else "enabled"
        if provider in ("bedrock", "bedrock-mantle") and route == "disabled":
            raise CandidateFail("V9-d3", "Bedrock経路が有効になっていません")
        if provider in ("bedrock", "bedrock-mantle") and route == "unknown":
            raise CandidateFail("V9-d3-UNKNOWN", "Bedrock経路の有効性を判定できません")
        pin = bedrock_pin_satisfied(provider, model, bedrock_env)
        if pin == "missing":
            raise CandidateFail("V12", "Bedrockのピン留めが記入されていません")
        if pin == "unknown":
            raise CandidateFail("V12-UNKNOWN", "ピン留めの充足を判定できません")


# ============================================================
# §3.6 候補評価・§3.5-L リーダー状態遷移
# ============================================================


class Candidacy:
    """1職種の候補評価結果。"""

    def __init__(self):
        self.usable: Optional[RoleLine] = None  # 採用された行（本命 or fallback）
        self.used_fallback = False
        self.vacant = False
        self.vacant_reason: Optional[str] = None  # 条件番号
        self.unknown_note: Optional[str] = None  # §3.7 判定不能（leader以外は通す）


class Candidate:
    """1候補（配役表の1行×解決済みModelDef 1つ）を表す軽量ビュー。
    2026-09-08 モデル定義ファイルと候補指定対応: role/fallback行が複数候補を
    持てるようになったため、_evaluate_single_candidate()等の既存関数
    （RoleLine.attrsの{provider,model,execution,[effort]}形状を期待する）を
    そのまま再利用できるよう、1候補ぶんだけこの形へ写す。
    """

    __slots__ = ("name", "def_name", "attrs")

    def __init__(self, role_name: str, d: "ModelDef"):
        self.name = role_name  # role_definition_exists()が引く職種名
        self.def_name = d.name
        self.attrs = {"provider": d.provider, "model": d.model, "execution": d.execution}
        if d.effort is not None:
            self.attrs["effort"] = d.effort


def _evaluate_single_candidate(
    line, agents_dir: Optional[str], bedrock_env: Optional[str], is_leader: bool
) -> tuple[bool, Optional[str], Optional[str]]:
    """1本の候補（Candidate。provider/model確定済み）を§3.6の3条件で評価する。
    戻り値: (使用可か, 縮退理由の条件番号(最初に確定したもの), 判定不能メモ)
    優先順: V1-b -> V9-d3(Bedrock有効性) -> V12(ピン留め)
    """
    execution = line.attrs.get("execution", "subagent")
    if not role_definition_exists(line.name, execution, agents_dir):
        return False, "V1-b", None

    provider = line.attrs["provider"]
    model = line.attrs["model"]
    if provider in ("bedrock", "bedrock-mantle"):
        route = bedrock_route_enabled(bedrock_env)
        if route == "disabled":
            return False, "V9-d", None
        if route == "unknown":
            if is_leader:
                return False, "V9-d", "leaderはBedrock経路の判定不能でfail扱いです"
            return True, None, "Bedrock経路の有効性を判定できません（判定不能・通します）"

    pin = bedrock_pin_satisfied(provider, model, bedrock_env)
    if pin == "missing":
        return False, "V12", None
    if pin == "unknown":
        if is_leader:
            return False, "V12", "leaderはピン留め充足の判定不能でfail扱いです"
        return True, None, "ピン留め充足を判定できません（判定不能・通します）"

    return True, None, None


# §3.6優先順（V1-b→V9-d→V12）。双方の候補が使用不可のとき、どちらの理由を
# 採るかをこの優先順で決める（Codex一次レビュー指摘・Major対応: 従来は
# fallbackの理由で本命の理由を無条件に上書きしており、本命=V1-b／
# fallback=V12のときV12が返って優先順に違反していた）。
_REASON_PRIORITY = {"V1-b": 0, "V9-d": 1, "V12": 2}


def evaluate_worker_candidate(
    name: str,
    roles: dict,
    fallbacks: dict,
    resolved: dict,
    agents_dir,
    bedrock_env,
) -> Candidacy:
    """§3.3(a)。2026-09-08 モデル定義ファイルと候補指定対応: 1行が複数候補を
    持てるようになったため「1行1候補」から「1行n候補」へ広げる。役割の行
    （configured）の候補を記述順に評価し、1つでも使用可なら空席でない。
    全候補が使用不可のときだけfallback行（configured）の候補を同じ規則で
    評価する。⚠️ ここでの「記述順に評価」は選択ではない（返すのは真偽値
    だけ。選択を行うのはresolve-candidateだけ＝D-6）。resolvedは
    resolve_roles_and_fallbacks()の戻り値（{(kind,name): [ModelDef,...]}）。
    """
    result = Candidacy()
    primary = roles.get(name)
    fb = fallbacks.get(name)
    reasons: list[str] = []

    if primary is not None and primary.state == "configured":
        for d in resolved.get(("role", name), []):
            ok, reason, note = _evaluate_single_candidate(
                Candidate(name, d), agents_dir, bedrock_env, False
            )
            if ok:
                result.usable = primary
                result.unknown_note = note
                return result
            if reason is not None:
                reasons.append(reason)
    # ⚠️ primary.state == "unavailable" は§3.6のとおり評価しない
    # （「意図的な不使用」であって縮退理由ではない）。

    if fb is not None and fb.state == "configured":
        for d in resolved.get(("fallback", name), []):
            ok, reason, note = _evaluate_single_candidate(
                Candidate(name, d), agents_dir, bedrock_env, False
            )
            if ok:
                result.usable = fb
                result.used_fallback = True
                result.unknown_note = note
                return result
            if reason is not None:
                reasons.append(reason)

    result.vacant = True
    if reasons:
        reasons.sort(key=lambda r: _REASON_PRIORITY.get(r, 99))
        result.vacant_reason = reasons[0]
    return result


# リーダー専用の失敗理由優先順（§5の「本命・fallback双方が候補評価または
# V9-e/leader専用規則で使用不可」を1つの条件番号へ集約するための順序。
# ワーカーと同じV1-b→V9-d→V12を基本に、候補評価を通過した後だけ判定される
# leader専用規則(V9-e/LEADER_PROVIDER_EXTERNAL)を優先度下位に足す）。
_LEADER_REASON_PRIORITY = {
    "V1-b": 0,
    "V9-d": 1,
    "V12": 2,
    "V9-e": 3,
    "LEADER_PROVIDER_EXTERNAL": 4,
}


def resolve_leader_candidate(
    parsed: ParsedProfile, resolved: dict, agents_dir, bedrock_env
) -> tuple[Optional[RoleLine], Optional["ModelDef"], bool, Optional[str]]:
    """§3.5-L・FR-16。2026-09-08 モデル定義ファイルと候補指定対応:
    リーダー行の<u>先頭の候補だけ</u>を解決・評価する（settings.jsonが値を
    1つしか持てないため。⚠️ 2件目以降はsettings.jsonの値に影響しない——
    優先度の意味づけではない＝RV-2）。fallback.leaderの候補が2件以上なら
    D-7と同じ規則でLEADER_FALLBACK_AMBIGUOUSにする。
    戻り値: (実効リーダー行(RoleLine) or None, 実効ModelDef or None,
    fallbackを採用したか, 失敗コード or None)。
    """
    leader = parsed.roles.get("leader")
    if leader is None or leader.state not in ("configured", "unavailable"):
        return None, None, False, "LEADER_UNCONFIGURED"

    fb = parsed.fallbacks.get("leader")

    def _leader_extra_checks(d: "ModelDef") -> Optional[str]:
        # 契約書§5の評価順どおりV9-eをprovider≠external規則より先に判定する
        # （check_candidate()と同じ順序に揃える。Codexレビュー指摘・Major対応）。
        effort = d.effort
        if effort is not None and effort not in EFFORT_SETTINGS:
            return "V9-e"
        if d.provider == "external":
            return "LEADER_PROVIDER_EXTERNAL"
        return None

    def _try_head(role_name: str, candidates: list) -> tuple[Optional["ModelDef"], Optional[str]]:
        if not candidates:
            return None, "V1-b"  # 防御的（V8-aが非空を既に保証している）
        head = candidates[0]
        ok, reason, _note = _evaluate_single_candidate(
            Candidate(role_name, head), agents_dir, bedrock_env, True
        )
        if not ok:
            return None, reason
        extra = _leader_extra_checks(head)
        if extra is not None:
            return None, extra
        return head, None

    primary_reason: Optional[str] = None
    if leader.state == "configured":
        d, reason = _try_head("leader", resolved.get(("role", "leader"), []))
        if d is not None:
            return leader, d, False, None
        primary_reason = reason
    # leader.state == "unavailable" は§3.6のとおり評価しない（primary_reasonは
    # Noneのまま＝意図的な不使用であって縮退理由ではない）。

    fallback_reason: Optional[str] = None
    if fb is not None and fb.state == "configured":
        fb_candidates = resolved.get(("fallback", "leader"), [])
        if len(fb_candidates) >= 2:
            return None, None, False, "LEADER_FALLBACK_AMBIGUOUS"
        d, reason = _try_head("leader", fb_candidates)
        if d is not None:
            return fb, d, True, None
        fallback_reason = reason

    reasons = [r for r in (primary_reason, fallback_reason) if r is not None]
    if reasons:
        reasons.sort(key=lambda r: _LEADER_REASON_PRIORITY.get(r, 99))
        return None, None, False, f"LEADER_CANDIDATE_INVALID:{reasons[0]}"
    return None, None, False, "LEADER_UNAVAILABLE_NO_FALLBACK"


KNOWN_NO_XHIGH_ANTHROPIC = frozenset({"claude-opus-4.6", "claude-sonnet-4.6"})


def model_effort_advisory(provider: str, model: str, effort: Optional[str]) -> Optional[str]:
    """V9-f（advisory・failにしない）。既知の非対応モデル×xhighの組み合わせだけを
    条件番号V9-fとして警告する。別名（bedrockのopus/sonnet/haiku/fable）は実モデルの
    版を判別できないため EFFORT_COMPATIBILITY_UNVERIFIED を返す。
    """
    if effort != "xhigh":
        return None
    base = re.sub(r"\[1m\]$", "", model)
    if provider == "anthropic-api" and base in KNOWN_NO_XHIGH_ANTHROPIC:
        return "V9-f"
    if provider == "bedrock":
        return "EFFORT_COMPATIBILITY_UNVERIFIED"
    return None


# ============================================================
# resolve() 本体（§5 stdout契約）
# ============================================================


def determine_team_mode(parsed: ParsedProfile) -> str:
    """team_mode能力軸から`TEAM_MODE:`へ出す値を決める（3モード体制-設計-
    2026-09-06.md §4.1の表）。`configured value=<solo|lean|full>`のときだけ
    その値を返し、それ以外（unavailable/unknown/欠落からの仮想補完）は
    "unknown"を返す。⚠️ 新しい検査規則は作らない（FR-8）——ここに来る時点で
    validate_capability_keys()のV7/V8-bを通過済みなので、configuredの
    valueは既にsolo|lean|fullのいずれかであることが保証されている。
    """
    line = parsed.capability.get("team_mode")
    if line is not None and line.state == "configured":
        return line.attrs.get("value", "unknown")
    return "unknown"


def determine_machine_role(parsed: ParsedProfile) -> str:
    """machine_role能力軸から`MACHINE_ROLE:`へ出す値を決める（配役表-能力軸
    整理-設計-2026-09-07.md §2.1・v1.4でunavailableの扱いを明確化）。
    `configured value=<main|sub>`のときはその値、`unavailable`のときは
    "unavailable"、それ以外（unknown・欠落からの仮想補完）は"unknown"を
    返す。⚠️ 新しい検査規則は作らない（FR-1）——ここに来る時点で
    validate_capability_keys()のV7/V8-bを通過済みなので、configuredの
    valueは既にmain|subのいずれかであることが保証されている。
    ⚠️ Codex一次レビュー指摘（MAJOR-1・2026-09-07）対応: 従来は
    unavailableもunknownへ潰していたため、bootstrap-vault.sh側で
    「machine_roleが未確定」の保留行がunavailableでも誤って出ていた
    （FR-9・設計§4.3は「保留はunknownのときだけ」）。unavailableを
    区別できる値として返すことで、呼び出し側が保留行の要否を
    正しく判定できるようにする。
    """
    line = parsed.capability.get("machine_role")
    if line is not None:
        if line.state == "configured":
            return line.attrs.get("value", "unknown")
        if line.state == "unavailable":
            return "unavailable"
    return "unknown"


def do_resolve(path: str, bedrock_env: Optional[str], agents_dir: Optional[str]) -> tuple[str, int]:
    """戻り値: (標準出力へ書く1行, exit code)。"""
    forbidden_hits = preflight_forbidden_keys(path)
    if forbidden_hits:
        lineno, key = forbidden_hits[0]
        return f"MINIMAL\tT11\t{lineno}行目: 禁止キー名です（{key}）", 1
    try:
        gate_schema_version(path)
        parsed = parse_v2(path)
        declared = validate_meta(parsed)
        warnings = reconcile_schema_version(parsed, declared)
        sentinel_hit = sentinel_violations(parsed)
        if sentinel_hit:
            raise ProfileError(
                "T2-MINIMAL", "未記入のままのキーがあります: " + ",".join(sorted(sentinel_hit))
            )
        validate_capability_keys(parsed)
        # 2026-09-08 モデル定義ファイルと候補指定対応（同設計§3.2①・D-2）:
        # 定義ファイルの読取・検証は5口すべてがmodel_defs_path()経由で行う。
        model_defs = load_model_defs(model_defs_path())
        resolved = resolve_roles_and_fallbacks(parsed, model_defs)
    except ProfileError as e:
        return f"MINIMAL\t{e.code}\t{e.reason}", 1

    # V1-a advisory
    only_in_profile, only_in_manifest = role_and_core_manifest_diff(parsed, agents_dir)

    # §3.5-L リーダー確定（先頭候補のみ・FR-16）
    leader_line, leader_def, leader_used_fallback, leader_fail_code = resolve_leader_candidate(
        parsed, resolved, agents_dir, bedrock_env
    )
    if leader_line is None:
        return f"MINIMAL\tT8\tV4: {leader_fail_code}", 1

    fallback_roles: list[str] = []
    vacant_roles: list[str] = []
    vacant_reason_pairs: list[str] = []
    vacant_unknown_roles: list[str] = []
    advisory_codes: list[str] = []

    if leader_used_fallback:
        # 4.1-f: leaderの縮退・fallback採用も職種名として必ず注入する
        # （Codex一次レビュー指摘・Major対応: 従来はワーカーだけを対象に
        # していたため、leaderがfallback救済されてもSessionStartで見えなかった）。
        fallback_roles.append("leader")

    all_role_names = set(parsed.roles)
    for name in sorted(all_role_names):
        if name == "leader":
            continue
        line = parsed.roles[name]
        if line.state in ("not_adopted",):
            continue
        if line.state == "unknown":
            vacant_unknown_roles.append(name)
            continue
        cand = evaluate_worker_candidate(
            name, parsed.roles, parsed.fallbacks, resolved, agents_dir, bedrock_env
        )
        if cand.usable is not None:
            if cand.used_fallback:
                fallback_roles.append(name)
            if cand.unknown_note:
                # §3.7: 判定不能でも通したワーカーは、通したこと自体を
                # ADVISORYとして黙って捨てない（Codex一次レビュー指摘・Major）。
                advisory_codes.append("JUDGEMENT_UNKNOWN")
        elif cand.vacant:
            vacant_roles.append(name)
            if cand.vacant_reason:
                vacant_reason_pairs.append(f"{name}={cand.vacant_reason}")

    # コアマニフェストにはあるがrole.表に行が無い職種もVACANT_UNKNOWN。
    for name in only_in_manifest:
        if name != "leader" and name not in vacant_unknown_roles and name not in all_role_names:
            vacant_unknown_roles.append(name)

    if only_in_profile or only_in_manifest:
        advisory_codes.append("V1-a")

    for w in warnings:
        advisory_codes.append(w.split(":", 1)[0])

    # D-9・FR-12: 役割の行とfallback行の全候補（configured/unavailable）を
    # claude/agents/<職種>.md のmodel:と突合する。⚠️ leaderは対象外
    # （ROLE_EXEMPT_FROM_DEFINITION_CHECK）。agent_declared_model()がNoneを
    # 返す職種（判定材料が無い）も対象外。
    for (_kind, name), defs_list in resolved.items():
        if name in ROLE_EXEMPT_FROM_DEFINITION_CHECK:
            continue
        declared_model = agent_declared_model(name, agents_dir)
        if declared_model is None:
            continue
        for d in defs_list:
            if d.provider != "anthropic-api" or d.execution != "subagent":
                continue
            actual = (d.model or "").strip().strip("\"'")
            if actual != declared_model:
                advisory_codes.append(f"MODEL_MISMATCH:{name}:{d.name}")

    for defs_list in resolved.values():
        for d in defs_list:
            adv = model_effort_advisory(d.provider, d.model, d.effort)
            if adv:
                advisory_codes.append(adv)

    team_mode = determine_team_mode(parsed)
    machine_role = determine_machine_role(parsed)
    fields = [f"OK\tschema_version={declared}", f"TEAM_MODE:{team_mode}", f"MACHINE_ROLE:{machine_role}"]
    if fallback_roles:
        fields.append("FALLBACK:" + ",".join(sorted(fallback_roles)))
    if vacant_roles:
        fields.append("VACANT:" + ",".join(sorted(set(vacant_roles))))
    if vacant_reason_pairs:
        fields.append("VACANT_REASON:" + ",".join(sorted(vacant_reason_pairs)))
    if vacant_unknown_roles:
        fields.append("VACANT_UNKNOWN:" + ",".join(sorted(set(vacant_unknown_roles))))
    if advisory_codes:
        fields.append("ADVISORY:" + ",".join(sorted(set(advisory_codes))))
    if parsed.extras:
        fields.append("UNKNOWN_EXTRA:" + ",".join(sorted(parsed.extras)))

    return "\t".join(fields), 0


def _load_and_validate_v2_self_contained(
    path: str,
) -> tuple[
    Optional[ParsedProfile],
    Optional[dict],
    Optional[dict],
    Optional[int],
    Optional[tuple[str, str]],
]:
    """`resolve-leader`・`list-roles`・`resolve-candidate` が共有する自己完結
    ロード処理（存在確認・symlink拒否・実読取・preflight(V15)・parse・
    validate・モデル定義ファイルの読取検証・候補解決）。
    2026-09-08 モデル定義ファイルと候補指定対応（同設計§3.8・D-13）:
    v1/mixed分類（旧分類関数の呼び出し）と、それに伴う2種の早期returnを撤去した——schema 6のコードはv1/版なしの実体も含めて6未満を
    一律T4-LEGACYで解決失敗にするため、分類そのものが不要になった
    （no-backward-compat）。
    戻り値: 成功時 (parsed, model_defs, resolved, declared_version, None) /
    失敗時 (None, None, None, None, (コード, 理由))。
    判定式を2箇所に増やさない（U-5・A-0-3と同じ考え方の横展開）。
    """
    if os.path.islink(path):
        return None, None, None, None, ("PROFILE_UNREADABLE", "実体がsymlinkです")
    if not os.path.isfile(path):
        return None, None, None, None, ("PROFILE_NOT_FOUND", "実体ファイルが存在しません")
    # 実際に読めるかをここで確定させる（Codexレビュー指摘・Major対応:
    # isfile()はパーミッション不足を検出しない）。
    try:
        with open(path, encoding="utf-8") as f:
            f.read()  # Codex二次レビュー指摘・Major対応: open()だけでは実際の
            # デコードは行われない。不正なUTF-8はread()まで進めないと検出
            # できない。
    except (OSError, UnicodeDecodeError):
        return None, None, None, None, ("PROFILE_UNREADABLE", "実体ファイルを読めません")

    forbidden_hits = preflight_forbidden_keys(path)
    if forbidden_hits:
        return None, None, None, None, ("PROFILE_INVALID:T11", "禁止キー名を検出しました")

    try:
        gate_schema_version(path)
        parsed = parse_v2(path)
        declared = validate_meta(parsed)
        reconcile_schema_version(parsed, declared)
        sentinel_hit = sentinel_violations(parsed)
        if sentinel_hit:
            raise ProfileError("T2-MINIMAL", "未記入のキーがあります")
        validate_capability_keys(parsed)
        model_defs = load_model_defs(model_defs_path())
        resolved = resolve_roles_and_fallbacks(parsed, model_defs)
    except ProfileError as e:
        return None, None, None, None, (f"PROFILE_INVALID:{e.code}", e.reason)

    return parsed, model_defs, resolved, declared, None


def do_resolve_leader(path: str, bedrock_env: Optional[str], agents_dir: Optional[str]) -> tuple[Optional[dict], Optional[tuple[str, str]]]:
    """戻り値: (成功時のJSON辞書 or None, (機械可読コード, 短い理由) or None)。
    契約書§4のとおり自己完結（存在確認・symlink拒否・preflight・parse・
    validateまでこのコマンド自身が行う）。出力の形（JSONのキー集合）は
    変えない（`model`・`effort`。effort未指定ならキーごと出さない＝AC-9）。
    """
    parsed, _model_defs, resolved, _declared, err = _load_and_validate_v2_self_contained(path)
    if err is not None:
        return None, err

    leader_line, leader_def, _used_fallback, leader_fail_code = resolve_leader_candidate(
        parsed, resolved, agents_dir, bedrock_env
    )
    if leader_def is None:
        return None, (leader_fail_code or "LEADER_UNCONFIGURED", "リーダー配役を確定できません")

    result = {"model": leader_def.model}
    if leader_def.effort is not None:
        result["effort"] = leader_def.effort
    return result, None


def do_list_roles(path: str) -> tuple[Optional[list[tuple]], Optional[tuple[str, str]]]:
    """`list-roles`本体。⚠️ AI向けDIRECTIVEには絶対に流用しない
    （resolve()の「配役の値を再掲しない」秘匿方針の唯一の例外＝Bの
    `--check-profile`・4.2-dの動的Bedrock許可リスト計算専用。リーダー裁定
    2026-09-01でこの例外を承認）。ピン留めの実値（bedrock.env側）は一切
    扱わない——role/fallback行にはBedrockの別名（opus/sonnet等）しか
    書けないため、値を再掲してもピン実値の秘匿設計とは矛盾しない。
    2026-09-08 モデル定義ファイルと候補指定対応（FR-17）: 1候補1行・8列
    （kind,name,state,定義名,provider,model,execution,effort）。⚠️ 突合は
    しない（一致状態もadvisoryも持たない＝resolveだけが行う。FR-12）。
    戻り値: (成功時のタプル一覧 or None, (機械可読コード, 短い理由) or None)。
    """
    parsed, _model_defs, resolved, _declared, err = _load_and_validate_v2_self_contained(path)
    if err is not None:
        return None, err

    rows: list[tuple] = []
    for kind, table in (("role", parsed.roles), ("fallback", parsed.fallbacks)):
        for name in sorted(table):
            line = table[name]
            if line.state in ("not_adopted", "unknown"):
                rows.append((kind, name, line.state, "", "", "", "", ""))
            else:
                for d in resolved.get((kind, name), []):
                    rows.append(
                        (
                            kind,
                            name,
                            line.state,
                            d.name,
                            d.provider,
                            d.model,
                            d.execution,
                            d.effort or "",
                        )
                    )
    return rows, None


def do_resolve_candidate(
    path: str, role: str, model_def_name: Optional[str], bedrock_env: Optional[str], agents_dir: Optional[str]
) -> tuple[Optional["ModelDef"], Optional[tuple[str, str]]]:
    """`resolve-candidate`本体（新設・候補指定の口＝C。同設計§3.6）。
    戻り値: (実効ModelDef or None, (機械可読コード, 短い理由) or None)。
    ⚠️ `--model-def`が受理するのは`role.<職種>`の候補だけ（D-5）。fallbackの
    定義名を直接渡した場合を含め、候補外はCANDIDATE_NOT_IN_LISTにする
    （FR-10の迂回を塞ぐ）。
    2026-09-08 Codexレビュー指摘・MAJOR対応（1巡目）:
    - AC-11「定義名の省略は無条件でexit 2」を満たすため、`model_def_name`の
      省略判定をプロファイル読取・検証より前に行う（壊れた/不在の配役表・
      定義ファイルでも省略時は常にCANDIDATE_UNSPECIFIED）。
    - `role.<職種>`が`unavailable`（本人が「使いたいが今は動かせない」と
      申告した状態）でも、指定した定義名がその行の候補に実在するなら
      「候補にある」と判定する（FR-7）。ただしunavailableな本命は
      §3.6のとおり評価せず（意図的な不使用）、直ちにfallbackへ進む
      （FR-10）。fallbackも使用不可なら`CANDIDATE_UNUSABLE:ROLE_UNAVAILABLE`
      という安定コードで確定する（本命側にV-codeが存在しないため新設）。
    """
    if model_def_name is None:
        return None, ("CANDIDATE_UNSPECIFIED", "定義名を指定してください")

    parsed, _model_defs, resolved, _declared, err = _load_and_validate_v2_self_contained(path)
    if err is not None:
        return None, err

    role_line = parsed.roles.get(role)
    role_candidates = resolved.get(("role", role), [])
    if (
        role_line is None
        or role_line.state not in ("configured", "unavailable")
        or model_def_name not in [d.name for d in role_candidates]
    ):
        return None, ("CANDIDATE_NOT_IN_LIST", f"{model_def_name}はrole.{role}の候補にありません")

    def _mismatch(d: "ModelDef") -> bool:
        # D-14: 突合が一致しないanthropic-api/subagentの定義は返さない。
        if d.provider != "anthropic-api" or d.execution != "subagent":
            return False
        if role in ROLE_EXEMPT_FROM_DEFINITION_CHECK:
            return False
        declared_model = agent_declared_model(role, agents_dir)
        if declared_model is None:
            return False
        return (d.model or "").strip().strip("\"'") != declared_model

    selected = next(d for d in role_candidates if d.name == model_def_name)
    if role_line.state == "configured":
        ok, reason, _note = _evaluate_single_candidate(
            Candidate(role, selected), agents_dir, bedrock_env, False
        )
        if ok:
            if _mismatch(selected):
                return None, ("CANDIDATE_UNUSABLE:MODEL_MISMATCH", f"{selected.name}のmodelが職種定義と一致しません")
            return selected, None
        primary_reason = reason
    else:
        # role_line.state == "unavailable"：§3.6のとおり本命は評価せず
        # （意図的な不使用であって縮退理由ではない）、直ちにfallbackへ進む。
        primary_reason = "ROLE_UNAVAILABLE"

    fb_line = parsed.fallbacks.get(role)
    fb_candidates = resolved.get(("fallback", role), [])
    if fb_line is None or fb_line.state != "configured" or not fb_candidates:
        return None, (f"CANDIDATE_UNUSABLE:{primary_reason}", "候補が使用不可です")
    if len(fb_candidates) >= 2:
        fb_names = ",".join(d.name for d in fb_candidates)
        return None, (
            "FALLBACK_AMBIGUOUS",
            f"fallback.{role}の候補が複数あります（{fb_names}）。本人が1件へ絞ってください",
        )

    fb_def = fb_candidates[0]
    fb_ok, fb_reason, _note2 = _evaluate_single_candidate(
        Candidate(role, fb_def), agents_dir, bedrock_env, False
    )
    if not fb_ok:
        return None, (f"CANDIDATE_UNUSABLE:{fb_reason}", "fallbackの候補も使用不可です")
    if _mismatch(fb_def):
        return None, ("CANDIDATE_UNUSABLE:MODEL_MISMATCH", f"{fb_def.name}のmodelが職種定義と一致しません")
    return fb_def, None


# ============================================================
# CLI
# ============================================================


def _print_out(s: str) -> None:
    sys.stdout.write(s + "\n")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="profile_resolve.py")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_preflight = sub.add_parser("preflight")
    p_preflight.add_argument("path")

    p_resolve = sub.add_parser("resolve")
    p_resolve.add_argument("path")
    p_resolve.add_argument("--bedrock-env")
    p_resolve.add_argument("--agents-dir")

    p_resolve_leader = sub.add_parser("resolve-leader")
    p_resolve_leader.add_argument("path")
    p_resolve_leader.add_argument("--bedrock-env")
    p_resolve_leader.add_argument("--agents-dir")

    p_list_roles = sub.add_parser("list-roles")
    p_list_roles.add_argument("path")

    # resolve-candidate（新設・候補指定の口＝C。同設計§3.6）。
    p_resolve_candidate = sub.add_parser("resolve-candidate")
    p_resolve_candidate.add_argument("path")
    p_resolve_candidate.add_argument("--role", required=True)
    p_resolve_candidate.add_argument("--model-def")
    p_resolve_candidate.add_argument("--bedrock-env")
    p_resolve_candidate.add_argument("--agents-dir")

    # check-candidate: --model-defを受け付ける（--provider/--model/--effort/
    # --executionと排他）。定義を引いてから既存の検査へ渡すだけ（同設計§5.3）。
    # ⚠️ --provider+--modelの呼び方も残す（resolve内部と契約書§5の既存利用）。
    p_check = sub.add_parser("check-candidate")
    p_check.add_argument("--provider")
    p_check.add_argument("--model")
    p_check.add_argument("--model-def")
    p_check.add_argument("--effort")
    p_check.add_argument("--execution")
    p_check.add_argument("--for-leader", action="store_true")
    p_check.add_argument("--role-name")
    p_check.add_argument("--bedrock-env")
    p_check.add_argument("--agents-dir")

    p_schema = sub.add_parser("print-schema-version")
    p_schema.add_argument("path")

    sub.add_parser("known-keys")

    p_pin = sub.add_parser("bedrock-pin-var")
    p_pin.add_argument("alias")

    args = parser.parse_args(argv)

    if args.cmd == "preflight":
        hits = preflight_forbidden_keys(args.path)
        if hits:
            lineno, key = hits[0]
            _print_out(f"T11\t{lineno}行目: 禁止キー名です（{key}）")
            return 1
        return 0

    if args.cmd == "resolve":
        line, code = do_resolve(args.path, args.bedrock_env, args.agents_dir)
        _print_out(line)
        return code

    if args.cmd == "resolve-leader":
        result, err = do_resolve_leader(args.path, args.bedrock_env, args.agents_dir)
        if err is not None:
            code, reason = err
            sys.stderr.write(f"{code}\t{reason}\n")
            return 1
        _print_out(json.dumps(result))
        return 0

    if args.cmd == "list-roles":
        rows, err = do_list_roles(args.path)
        if err is not None:
            code, reason = err
            sys.stderr.write(f"{code}\t{reason}\n")
            return 1
        for row in rows:
            _print_out("\t".join(row))
        return 0

    if args.cmd == "resolve-candidate":
        selected, err = do_resolve_candidate(
            args.path, args.role, args.model_def, args.bedrock_env, args.agents_dir
        )
        if err is not None:
            code, reason = err
            sys.stderr.write(f"{code}\t{reason}\n")
            return 2 if code in ("CANDIDATE_UNSPECIFIED", "CANDIDATE_NOT_IN_LIST", "FALLBACK_AMBIGUOUS") else 1
        _print_out(f"OK\t{selected.name}\t{selected.model}\t{selected.execution}\t{selected.effort or ''}")
        if selected.execution == "external-cli":
            parts = []
            if selected.model != "default":
                parts.append(f"--model {selected.model}")
            if selected.effort:
                parts.append(f"--effort {selected.effort}")
            _print_out("CODEX_ARGS\t" + " ".join(parts))
        return 0

    if args.cmd == "check-candidate":
        if args.model_def is not None:
            if any(
                v is not None
                for v in (args.provider, args.model, args.effort, args.execution)
            ):
                _print_out("FAIL\tT12\t--model-defは--provider/--model/--effort/--executionと同時に指定できません")
                return 1
            try:
                model_defs = load_model_defs(model_defs_path())
            except ProfileError as e:
                _print_out(f"FAIL\t{e.code}\t{e.reason}")
                return 1
            d = model_defs.get(args.model_def)
            if d is None:
                _print_out(f"FAIL\tV17\t未定義の定義名です（{args.model_def}）")
                return 1
            provider, model, effort, execution = d.provider, d.model, d.effort, d.execution
        else:
            if args.provider is None or args.model is None:
                _print_out("FAIL\tT12\t--provider/--modelまたは--model-defのどちらかを指定してください")
                return 1
            provider, model, effort, execution = args.provider, args.model, args.effort, args.execution
        try:
            check_candidate(
                provider,
                model,
                effort,
                execution,
                args.for_leader,
                args.role_name,
                args.bedrock_env,
                args.agents_dir,
            )
        except CandidateFail as e:
            _print_out(f"FAIL\t{e.code}\t{e.reason}")
            return 1
        _print_out("OK")
        return 0

    if args.cmd == "print-schema-version":
        try:
            parsed = parse_v2(args.path)
            declared = validate_meta(parsed)
        except ProfileError:
            return 1
        _print_out(str(declared))
        return 0

    if args.cmd == "known-keys":
        _print_out("FIXED:" + ",".join(FIXED_KEYS_ORDERED))
        _print_out("PREFIXES:" + ",".join(DYNAMIC_PREFIXES))
        _print_out(f"SCHEMA_VERSION:{EXPECTED_SCHEMA_VERSION}")
        return 0

    if args.cmd == "bedrock-pin-var":
        var = bedrock_pin_env_var(args.alias)
        if var is None:
            return 1
        _print_out(var)
        return 0

    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
