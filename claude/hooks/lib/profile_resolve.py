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
存在・非空」だけ。値そのものをstdout/stderrへ書かない。role/fallback行の
model=/provider= の値は resolve() の出力へ再掲しない（配役の値をDIRECTIVE
へ再掲しない＝4.1-f。resolve-leader だけは settings.json 生成用に値を返す
＝これは元々installerが書く値であり、AI向けDIRECTIVEには流用しない）。
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
# 継承環境の値で動かせる穴を作らない＝Codexレビュー指摘・Major対応。以前は
# テスト専用の環境変数オーバーライドを持たせていたが、本番プロセスの継承
# 環境に紛れ込んだ場合にresolver・bootstrap・known-keys全てのexpected版が
# 静かに変わってしまうため撤去した。T4＝declared<EXPECTED_SCHEMA_VERSIONの
# 仮想補完分岐は現行のEXPECTED=2かつv2分類の下限が2のため実運用では到達
# しない。テストで到達させたい場合はサブプロセス内でモジュール属性
# `profile_resolve.EXPECTED_SCHEMA_VERSION`を直接上書きしてから呼ぶこと
# （本番の起動経路には一切影響しない）。
EXPECTED_SCHEMA_VERSION = 2

META_KEYS = ("schema_version", "profile_slug")
CAPABILITY_KEYS = (
    "inventory_source",
    "reviewer",
    "vault_write",
    "vault_scope",
    "ui.user_call",
    "git_role",
    "web_verification",
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
EXECUTIONS = frozenset({"subagent", "external-mcp", "external-api"})
ROLE_ATTR_NAMES = frozenset({"provider", "model", "execution", "effort"})
CAPABILITY_ATTR_NAMES = frozenset({"value"})

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
IMPLEMENTED_HANDLERS = frozenset(
    {
        ("external", "external-mcp", "codex-review-default"),
    }
)

# V8-b: 能力軸・excluded_models の value= 厳格形式（U-8裁定）。
_TOKEN = r"[a-z0-9][a-z0-9-]{0,31}"
_REPO_SCOPE = r"[a-z0-9][a-z0-9-]{0,31}"
_GIT_STANCE = r"(?:push|commit|pull-only|ask)"
CAPABILITY_VALUE_PATTERNS = {
    "inventory_source": re.compile(rf"^{_TOKEN}(,{_TOKEN}){{0,7}}$"),
    "reviewer": re.compile(r"^(codex-mcp|peer-claude)$"),
    "vault_write": re.compile(r"^(via-scribe|direct)$"),
    "vault_scope": re.compile(r"^(full|[A-Z][A-Za-z0-9]{0,31}(,[A-Z][A-Za-z0-9]{0,31}){0,15})$"),
    "ui.user_call": re.compile(
        r"^(send-message|cmux-notify|stdout-only)(,(send-message|cmux-notify|stdout-only)){0,2}$"
    ),
    "git_role": re.compile(rf"^{_REPO_SCOPE}:{_GIT_STANCE}(,{_REPO_SCOPE}:{_GIT_STANCE})*$"),
    "web_verification": re.compile(r"^(websearch|webfetch)(,(websearch|webfetch)){0,1}$"),
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
    {"leader", "navi", "primary-reviewer", "ja-doc"}
)
# leaderはspawn対象外なのでV1-bの対象から無条件除外する。
ROLE_EXEMPT_FROM_DEFINITION_CHECK = frozenset({"leader"})

# Bedrockピン留め論理名の導出（§1-3・§6.1）。人はこの名前を書けない
# （role.*のprovider=bedrock行はmodel別名しか持てないためbedrock_pin_*は
# 常にコードが導出する側）。
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


def classify_profile(path: str) -> str:
    """§3.5 の分類規則。'v1' | 'v2' | 'mixed' のいずれかを返す。
    frontmatterが壊れている場合も、ここでは判定を諦めずベストエフォートで
    生テキストを直接走査する（後続のparserがT6として正式に検出するため、
    分類自体は失敗させない）。
    """
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except (OSError, UnicodeDecodeError):
        # 呼び出し側が存在確認を済ませている前提だが、フェイルセーフとして
        # v1側（現行実装）へ委ねる＝現行のT1/T6処理に任せる（v1側のbashラッパは
        # python3の非0終了をMINIMAL/T6へ丸める既存のfail-safeを持つ）。
        return "v1"

    lines = text.splitlines()
    has_dynamic = False
    schema_version_raw: Optional[str] = None
    for raw in lines:
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        body = _strip_comment(raw).rstrip()
        m = LINE_RE.match(body.strip())
        if not m:
            continue
        key, val = m.group(1), m.group(2).strip()
        if key.startswith(DYNAMIC_PREFIXES):
            has_dynamic = True
        elif key == "schema_version":
            schema_version_raw = val

    if schema_version_raw is None:
        return "mixed" if has_dynamic else "v1"
    if schema_version_raw == "1":
        return "mixed" if has_dynamic else "v1"
    return "v2"


# ============================================================
# v2 parser（§3.1 文法規約）
# ============================================================


class RoleLine:
    __slots__ = ("name", "state", "attrs", "lineno", "kind")

    def __init__(self, name: str, state: str, attrs: dict, lineno: int, kind: str):
        self.name = name
        self.state = state
        self.attrs = attrs
        self.lineno = lineno
        self.kind = kind  # "role" | "fallback"


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

        # 状態＋属性を持つ行（role./fallback./能力軸7キー/excluded_models）。
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
        raise ProfileError("T3", "schema_versionがありません")
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
    （呼び出し側がstderr相当のwarningとして使う）。T5はProfileErrorを送出する。
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
        # declared < EXPECTED_SCHEMA_VERSION（現行のEXPECTED=2かつv2分類の下限が2
        # のため通常到達しないが、将来EXPECTEDが3以上になった時のための入口を
        # 実装しておく）。欠落した固定キーだけをunknownで仮想補完し、止めない。
        missing = sorted(k for k in FIXED_KEYS if k not in known_present)
        if missing:
            for k in missing:
                if k == "excluded_models":
                    parsed.excluded_models = RoleLine(k, "unknown", {}, 0, "meta-state")
                elif k in CAPABILITY_KEYS:
                    parsed.capability[k] = RoleLine(k, "unknown", {}, 0, "capability")
                elif k in META_KEYS:
                    parsed.meta.setdefault(k, "unknown")
            warnings.append("T4:仮想補完しました（欠落キー: " + ",".join(missing) + "）")

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
    200文字以内・小文字固定＝vault_scopeのフォルダ名を除く）。sentinelは
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
    if key != "vault_scope" and value != value.lower():
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


def validate_role_line_format(line: RoleLine) -> None:
    """V8-a（role/fallback側）・V9-b・V9-d①②。configured/unavailableにのみ適用。"""
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
    if "provider" not in line.attrs or "model" not in line.attrs:
        raise _fail("V8-a", f"role.{line.name}にprovider/modelがありません（{line.lineno}行目）")
    provider = line.attrs["provider"]
    model = line.attrs["model"]
    execution = line.attrs.get("execution", "subagent")
    effort = line.attrs.get("effort")

    if provider not in PROVIDERS:
        raise _fail("V9-b", f"role.{line.name}のproviderが不正です（{line.lineno}行目）")
    if execution not in EXECUTIONS:
        raise _fail("V9-b", f"role.{line.name}のexecutionが不正です（{line.lineno}行目）")

    if provider == "external":
        if "execution" not in line.attrs:
            raise _fail(
                "V9-b", f"role.{line.name}はexternalなのにexecutionが未指定です（{line.lineno}行目）"
            )
    else:
        if execution != "subagent":
            raise _fail(
                "V9-b",
                f"role.{line.name}はこのproviderでこのexecutionを指定できません（{line.lineno}行目）",
            )

    pattern = MODEL_PATTERNS[provider]
    if not pattern.match(model):
        raise _fail("V9-b", f"role.{line.name}のmodel形式が不正です（{line.lineno}行目）")
    if provider == "bedrock" and model.startswith(BEDROCK_DISALLOWED_MODEL_PREFIXES):
        raise _fail("V9-b", f"role.{line.name}のmodelが別名ではありません（{line.lineno}行目）")

    if effort is not None:
        if provider == "external":
            if (provider, execution, model) == ("external", "external-mcp", "codex-review-default"):
                allowed_effort = EFFORT_CODEX
            else:
                raise _fail(
                    "V9-b",
                    f"role.{line.name}のexternalハンドラはeffortを書けません（{line.lineno}行目）",
                )
        else:
            allowed_effort = EFFORT_CLAUDE
        if effort not in allowed_effort:
            raise _fail("V9-b", f"role.{line.name}のeffortが不正です（{line.lineno}行目）")

    # V9-d①②（構造的なハンドラ写像違反。単独で職種を縮退させるのではなく
    # 実体全体をMINIMALへ倒す＝exit契約でV9-d①②はfail区分）。
    # ⚠️ V9-d②は「configuredにできない」という規定であり、unavailable（＝
    # 使いたいが今は動かせないという意図の記録）までは塞がない
    # （設計§5「unknownかunavailableにせよと促す」の逃げ道を残す）。
    if execution == "external-api" and line.state == "configured":
        raise _fail(
            "V9-d",
            f"role.{line.name}のexecution=external-apiはハンドラ未実装です（{line.lineno}行目）",
        )
    if execution != "subagent" and line.state == "configured":
        if (provider, execution, model) not in IMPLEMENTED_HANDLERS:
            raise _fail(
                "V9-d",
                f"role.{line.name}の(provider,execution,model)組がハンドラ未実装です（{line.lineno}行目）",
            )


def validate_roles_and_fallbacks(parsed: ParsedProfile) -> None:
    excluded = _excluded_pairs(parsed)

    for name, line in parsed.roles.items():
        validate_role_line_format(line)
        if line.state in ("configured", "unavailable"):
            pair = (line.attrs["provider"], _normalize_model_for_exclusion(line.attrs["model"]))
            if pair in excluded:
                raise _fail("V16", f"role.{name}が禁止モデルを使っています（{line.lineno}行目）")

    for name, line in parsed.fallbacks.items():
        validate_role_line_format(line)
        if line.state in ("configured", "unavailable"):
            pair = (line.attrs["provider"], _normalize_model_for_exclusion(line.attrs["model"]))
            if pair in excluded:
                raise _fail("V16", f"fallback.{name}が禁止モデルを使っています（{line.lineno}行目）")
        # V6: fallbackが指す職種はrole.表にも存在すること。
        if name not in parsed.roles:
            raise _fail("V6", f"fallback.{name}に対応するrole.{name}がありません（{line.lineno}行目）")


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
    """
    execution = execution or "subagent"
    fake = RoleLine(role_name or "candidate", "configured",
                     {"provider": provider, "model": model, "execution": execution},
                     0, "role")
    if effort is not None:
        fake.attrs["effort"] = effort

    try:
        validate_role_line_format(fake)
    except ProfileError as e:
        code = e.reason.split(":", 1)[0].strip()
        raise CandidateFail(code, e.reason) from e

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


def _evaluate_single_candidate(
    line: RoleLine, agents_dir: Optional[str], bedrock_env: Optional[str], is_leader: bool
) -> tuple[bool, Optional[str], Optional[str]]:
    """1本の候補行（provider/model確定済み・configured前提）を§3.6の3条件で評価する。
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
    name: str, roles: dict, fallbacks: dict, agents_dir, bedrock_env
) -> Candidacy:
    result = Candidacy()
    primary = roles.get(name)
    fb = fallbacks.get(name)
    primary_reason: Optional[str] = None
    fallback_reason: Optional[str] = None

    if primary is not None and primary.state == "configured":
        ok, reason, note = _evaluate_single_candidate(primary, agents_dir, bedrock_env, False)
        if ok:
            result.usable = primary
            result.unknown_note = note
            return result
        primary_reason = reason
    # ⚠️ primary.state == "unavailable" は§3.6のとおり評価しない
    # （primary_reasonはNoneのまま＝「意図的な不使用」であって縮退理由ではない）。

    if fb is not None and fb.state == "configured":
        ok, reason, note = _evaluate_single_candidate(fb, agents_dir, bedrock_env, False)
        if ok:
            result.usable = fb
            result.used_fallback = True
            result.unknown_note = note
            return result
        fallback_reason = reason

    result.vacant = True
    reasons = [r for r in (primary_reason, fallback_reason) if r is not None]
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
    parsed: ParsedProfile, agents_dir, bedrock_env
) -> tuple[Optional[RoleLine], bool, Optional[str]]:
    """§3.5-L。戻り値: (実効リーダー候補 or None, fallbackを採用したか,
    失敗コード or None)。失敗コードは契約書§4のresolve-leader用コード体系
    （LEADER_UNCONFIGURED/LEADER_UNAVAILABLE_NO_FALLBACK/
    LEADER_CANDIDATE_INVALID:<V番号>）に合わせる。
    """
    leader = parsed.roles.get("leader")
    if leader is None or leader.state not in ("configured", "unavailable"):
        return None, False, "LEADER_UNCONFIGURED"

    fb = parsed.fallbacks.get("leader")

    def _leader_extra_checks(line: RoleLine) -> Optional[str]:
        # 契約書§5の評価順どおりV9-eをprovider≠external規則より先に判定する
        # （check_candidate()と同じ順序に揃える。Codexレビュー指摘・Major対応）。
        effort = line.attrs.get("effort")
        if effort is not None and effort not in EFFORT_SETTINGS:
            return "V9-e"
        if line.attrs.get("provider") == "external":
            return "LEADER_PROVIDER_EXTERNAL"
        return None

    def _try(line: RoleLine) -> tuple[bool, Optional[str]]:
        ok, reason, _note = _evaluate_single_candidate(line, agents_dir, bedrock_env, True)
        if not ok:
            return False, reason
        extra = _leader_extra_checks(line)
        if extra is not None:
            return False, extra
        return True, None

    primary_reason: Optional[str] = None
    if leader.state == "configured":
        ok, reason = _try(leader)
        if ok:
            return leader, False, None
        primary_reason = reason
    # leader.state == "unavailable" は§3.6のとおり評価しない（primary_reasonは
    # Noneのまま＝意図的な不使用であって縮退理由ではない）。

    fallback_reason: Optional[str] = None
    if fb is not None and fb.state == "configured":
        ok, reason = _try(fb)
        if ok:
            return fb, True, None
        fallback_reason = reason

    reasons = [r for r in (primary_reason, fallback_reason) if r is not None]
    if reasons:
        reasons.sort(key=lambda r: _LEADER_REASON_PRIORITY.get(r, 99))
        return None, False, f"LEADER_CANDIDATE_INVALID:{reasons[0]}"
    return None, False, "LEADER_UNAVAILABLE_NO_FALLBACK"


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


def do_resolve(path: str, bedrock_env: Optional[str], agents_dir: Optional[str]) -> tuple[str, int]:
    """戻り値: (標準出力へ書く1行, exit code)。"""
    forbidden_hits = preflight_forbidden_keys(path)
    if forbidden_hits:
        lineno, key = forbidden_hits[0]
        return f"MINIMAL\tT11\t{lineno}行目: 禁止キー名です（{key}）", 1
    try:
        parsed = parse_v2(path)
        declared = validate_meta(parsed)
        warnings = reconcile_schema_version(parsed, declared)
        sentinel_hit = sentinel_violations(parsed)
        if sentinel_hit:
            raise ProfileError(
                "T2-MINIMAL", "未記入のままのキーがあります: " + ",".join(sorted(sentinel_hit))
            )
        validate_capability_keys(parsed)
        validate_roles_and_fallbacks(parsed)
    except ProfileError as e:
        return f"MINIMAL\t{e.code}\t{e.reason}", 1

    # V1-a advisory
    only_in_profile, only_in_manifest = role_and_core_manifest_diff(parsed, agents_dir)

    # §3.5-L リーダー確定
    leader_line, leader_used_fallback, leader_fail_code = resolve_leader_candidate(
        parsed, agents_dir, bedrock_env
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
        cand = evaluate_worker_candidate(name, parsed.roles, parsed.fallbacks, agents_dir, bedrock_env)
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

    for line in list(parsed.roles.values()) + list(parsed.fallbacks.values()):
        if line.state in ("configured", "unavailable"):
            adv = model_effort_advisory(
                line.attrs.get("provider", ""), line.attrs.get("model", ""), line.attrs.get("effort")
            )
            if adv:
                advisory_codes.append(adv)

    fields = [f"OK\tschema_version={declared}"]
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
) -> tuple[Optional[ParsedProfile], Optional[int], Optional[tuple[str, str]]]:
    """`resolve-leader`・`list-roles` が共有する自己完結ロード処理
    （存在確認・symlink拒否・実読取・preflight(V15)・分類・parse・validate）。
    戻り値: 成功時 (parsed, declared_version, None) / 失敗時 (None, None, (コード, 理由))。
    判定式を2箇所に増やさない（U-5・A-0-3と同じ考え方の横展開）。
    """
    if os.path.islink(path):
        return None, None, ("PROFILE_UNREADABLE", "実体がsymlinkです")
    if not os.path.isfile(path):
        return None, None, ("PROFILE_NOT_FOUND", "実体ファイルが存在しません")
    # 実際に読めるかをここで確定させる（Codexレビュー指摘・Major対応:
    # isfile()はパーミッション不足を検出しない。preflight/classifyは内部で
    # OSErrorをfail-soft/フォールバックとして飲み込む契約のため、ここで
    # 先に読めることを確認しないと権限不足がPROFILE_LEGACY_V1等へ誤分類される）。
    try:
        with open(path, encoding="utf-8") as f:
            f.read()  # Codex二次レビュー指摘・Major対応: open()だけでは実際の
            # デコードは行われない。不正なUTF-8はread()まで進めないと検出
            # できず、後続のpreflight/classifyで未処理のUnicodeDecodeError
            # （OSErrorの派生ではない）が漏れる経路になっていた。
    except (OSError, UnicodeDecodeError):
        return None, None, ("PROFILE_UNREADABLE", "実体ファイルを読めません")

    forbidden_hits = preflight_forbidden_keys(path)
    if forbidden_hits:
        return None, None, ("PROFILE_INVALID:T11", "禁止キー名を検出しました")

    classification = classify_profile(path)
    if classification == "v1":
        return None, None, ("PROFILE_LEGACY_V1", "v1形式です。v2へ移行してください")
    if classification == "mixed":
        return None, None, ("PROFILE_MIXED", "schema_versionが無いのに職種行があります")

    try:
        parsed = parse_v2(path)
        declared = validate_meta(parsed)
        reconcile_schema_version(parsed, declared)
        sentinel_hit = sentinel_violations(parsed)
        if sentinel_hit:
            raise ProfileError("T2-MINIMAL", "未記入のキーがあります")
        validate_capability_keys(parsed)
        validate_roles_and_fallbacks(parsed)
    except ProfileError as e:
        return None, None, (f"PROFILE_INVALID:{e.code}", e.reason)

    return parsed, declared, None


def do_resolve_leader(path: str, bedrock_env: Optional[str], agents_dir: Optional[str]) -> tuple[Optional[dict], Optional[tuple[str, str]]]:
    """戻り値: (成功時のJSON辞書 or None, (機械可読コード, 短い理由) or None)。
    契約書§4のとおり自己完結（存在確認・symlink拒否・preflight・分類まで
    このコマンド自身が行う。呼び出し元＝install-main.shの`--print-leader-
    runtime`が`classify`を別途呼ばずに使える単発の呼び出し口にするため）。
    """
    parsed, _declared, err = _load_and_validate_v2_self_contained(path)
    if err is not None:
        return None, err

    leader_line, _leader_used_fallback, leader_fail_code = resolve_leader_candidate(
        parsed, agents_dir, bedrock_env
    )
    if leader_line is None:
        return None, (leader_fail_code or "LEADER_UNCONFIGURED", "リーダー配役を確定できません")

    result = {"model": leader_line.attrs["model"]}
    effort = leader_line.attrs.get("effort")
    if effort is not None:
        result["effort"] = effort
    return result, None


def do_list_roles(path: str) -> tuple[Optional[list[tuple]], Optional[tuple[str, str]]]:
    """`list-roles`本体。⚠️ AI向けDIRECTIVEには絶対に流用しない
    （resolve()の「配役の値を再掲しない」秘匿方針の唯一の例外＝Bの
    `--check-profile`・4.2-dの動的Bedrock許可リスト計算専用。リーダー裁定
    2026-09-01でこの例外を承認）。ピン留めの実値（bedrock.env側）は一切
    扱わない——role/fallback行にはBedrockの別名（opus/sonnet等）しか
    書けないため、値を再掲してもピン実値の秘匿設計とは矛盾しない。
    戻り値: (成功時のタプル一覧 or None, (機械可読コード, 短い理由) or None)。
    各タプル: (kind, name, state, provider, model, execution, effort)
    """
    parsed, _declared, err = _load_and_validate_v2_self_contained(path)
    if err is not None:
        return None, err

    rows: list[tuple] = []
    for kind, table in (("role", parsed.roles), ("fallback", parsed.fallbacks)):
        for name in sorted(table):
            line = table[name]
            if line.state in ("not_adopted", "unknown"):
                rows.append((kind, name, line.state, "", "", "", ""))
            else:
                rows.append(
                    (
                        kind,
                        name,
                        line.state,
                        line.attrs.get("provider", ""),
                        line.attrs.get("model", ""),
                        line.attrs.get("execution", "subagent"),
                        line.attrs.get("effort", ""),
                    )
                )
    return rows, None


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

    p_classify = sub.add_parser("classify")
    p_classify.add_argument("path")

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

    p_check = sub.add_parser("check-candidate")
    p_check.add_argument("--provider", required=True)
    p_check.add_argument("--model", required=True)
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

    if args.cmd == "classify":
        if not os.path.isfile(args.path):
            return 2
        _print_out(classify_profile(args.path))
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

    if args.cmd == "check-candidate":
        try:
            check_candidate(
                args.provider,
                args.model,
                args.effort,
                args.execution,
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
