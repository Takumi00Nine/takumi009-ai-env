#!/usr/bin/env python3
"""教訓・判断の場面照合。両リーダーの共通入口と棚卸しが使う設定を持つ。"""
import json
import math
import os
import pathlib
import time
import unicodedata

from vault_lib import read_recall_records

RECALL_CONFIG_PATH = pathlib.Path(__file__).resolve().parent.parent / "data" / "recall.json"

GENERIC_TOKENS_ASCII = {"ai", "claude", "codex", "obsidian", "vault", "mcp"}
GENERIC_TOKENS_NONASCII = {
    "ツール", "ルール", "設定", "配信", "メモ", "作業", "運用", "テスト",
    "レビュー", "ワークフロー", "エージェント", "ワーカー", "委任", "フック", "スクリプト", "外部脳",
}


class BudgetExceeded(Exception):
    """場面照合の時間予算を使い切ったことを示す。"""


# 場面照合で使う固定の文字単位。
GRAM_SIZE = 2
MIN_SPECIFIC_GRAMS = 2


def load_recall_config(path=None, **overrides):
    """入口で一度だけ解決する。既定値は data/recall.json のみ。

    VAULT_RECALL_CONFIG でファイルを変更できる。各値は
    VAULT_RECALL_MAX_ITEMS / VAULT_RECALL_THRESHOLD /
    VAULT_RECALL_KEYWORD_BUDGET_MS、最後に呼出元の引数で上書きする。
    """
    config_path = path or os.environ.get("VAULT_RECALL_CONFIG") or RECALL_CONFIG_PATH
    config = json.loads(pathlib.Path(RECALL_CONFIG_PATH).read_text(encoding="utf-8"))
    if pathlib.Path(config_path) != pathlib.Path(RECALL_CONFIG_PATH):
        config.update(json.loads(pathlib.Path(config_path).read_text(encoding="utf-8")))
    env_names = {"max_items": "VAULT_RECALL_MAX_ITEMS",
                 "threshold": "VAULT_RECALL_THRESHOLD",
                 "budget_ms": "VAULT_RECALL_KEYWORD_BUDGET_MS"}
    for key, env_name in (("log_path", "VAULT_RECALL_LOG"),
                          ("health_path", "HEALTH_RECALL_OBSERVATION_FILE")):
        if env_name in os.environ:
            config[key] = os.environ[env_name]
        if key in config:
            config[key] = os.path.expanduser(config[key])
    for key, env_name in env_names.items():
        if env_name in os.environ:
            config[key] = os.environ[env_name]
    config.update({key: value for key, value in overrides.items() if value is not None})
    for key in env_names:
        config[key] = float(config[key])
        if not math.isfinite(config[key]):
            raise ValueError(f"{key} は有限の数値が必要です")
    if config["max_items"] < 0 or not config["max_items"].is_integer():
        raise ValueError("max_items は0以上の整数が必要です")
    config["max_items"] = int(config["max_items"])
    if not 0 <= config["threshold"] <= 1 or config["budget_ms"] < 0:
        raise ValueError("threshold は0〜1、budget_ms は0以上が必要です")
    return config


def normalize_situation(text):
    text = unicodedata.normalize("NFKC", text).lower()
    return "".join(ch for ch in text
                   if not ch.isspace() and not unicodedata.category(ch).startswith("P"))


def situation_grams(text):
    return {text[i:i + GRAM_SIZE] for i in range(len(text) - GRAM_SIZE + 1)}


def score_situations(situations, prompt_grams):
    """場面ごとの一致率の最大値。汎用語だけの一致は線を下げても通さない。"""
    best = 0.0
    generic_words = GENERIC_TOKENS_ASCII | GENERIC_TOKENS_NONASCII
    for situation in situations:
        normalized = normalize_situation(situation)
        specific = normalized
        for word in sorted(generic_words, key=lambda word: (-len(word), word)):
            specific = specific.replace(normalize_situation(word), "")
        specific_grams = {gram for gram in situation_grams(specific)
                          if not all("\u3041" <= ch <= "\u309f" for ch in gram)}
        if len(specific_grams & prompt_grams) < MIN_SPECIFIC_GRAMS:
            continue
        grams = situation_grams(normalized)
        best = max(best, len(grams & prompt_grams) / len(grams))
    return best


def format_recall_records(records):
    lines = []
    for record in records:
        note = record["source"].removesuffix(".md")
        if record["kind"] == "lesson":
            lesson_id = record["id"].split("#", 1)[1]
            lines.append(f"教訓：{record['text']} — [[{note}#教訓: {lesson_id}]]")
        else:
            lines.append(f"本人の判断：{record['text']}（{record['date']}） — [[{note}]]")
    return "\n".join(lines)


def recall_situations(vault_root, prompt, config, started_at=None):
    """共通入口から使う S1 の読取→照合→順位→整形。Vault には書かない。

    config は load_recall_config で解決済みのものを渡す。入口で計測した
    started_at も渡せる。期限を超えたら途中結果を返さず BudgetExceeded。
    戻り値は {candidates: 共通レコード＋score, text: 文面, issues: 書式不備}。
    """
    started_at = time.monotonic() if started_at is None else started_at
    deadline = started_at + config["budget_ms"] / 1000
    if time.monotonic() >= deadline:
        raise BudgetExceeded()
    records, issues = read_recall_records(vault_root)
    prompt_grams = situation_grams(normalize_situation(prompt))
    candidates = []
    for record in records:
        if time.monotonic() >= deadline:
            raise BudgetExceeded()
        score = score_situations(record["situations"], prompt_grams)
        if score > 0 and score >= config["threshold"]:
            candidates.append({**record, "score": score})
    candidates.sort(key=lambda record: (-record["score"], record["id"]))
    candidates = candidates[:config["max_items"]]
    text = format_recall_records(candidates)
    if time.monotonic() >= deadline:
        raise BudgetExceeded()
    return {"candidates": candidates, "text": text, "issues": issues}
