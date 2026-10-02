#!/usr/bin/env python3
"""締めの実走ハーネスの補助（python3 標準ライブラリだけ）。bash 3.2 に無い処理だけを持つ。

サブコマンド:
  realpath <path>                         リンクを最後まで辿った先（readlink -f 相当）
  moves-main <moves.tsv> <old>            旧パスの主後継（同じ旧パスの行のうち先頭行）。無ければ exit 1・表が読めなければ exit 2
  moves-succ <moves.tsv> <old>            旧パスの後継を全て（1 行 1 件）
  moves-split-new <moves.tsv> <new>       新パスが種別「分割」の新側なら exit 0・違えば exit 1
  norm <rules.tsv> [--moves M] [--extra-move OLD=NEW ...] [--sub FROM=TO ...]   stdin を正規化して stdout へ（下の順。
                                          --extra-move＝移動表に無いフォルダ単位の対応の補足・--moves があるときだけ当てる）
  snap <root> <out.json> [--exclude REL ...]          root 配下のファイル・リンクの状態を記録
  snapdiff <before.json> <after.json> <root>          作成・変更・削除の一覧と、作成・変更の中身
  hooks <settings.json> <event> [<tool>]  イベント（とツール名）に当たる登録フックのコマンド（登録順）
  hook-cmds <settings.json>               全登録フックのコマンド（重複なし・登録順）
  canon <file> json|toml|plist            値として読み、キー順を揃えた JSON で出す
  settings-cmp <base.json> <new.json>     正規化済み settings.json 2 つ: FX-1 にだけある登録を `EXTRA <command>` で出し、
                                          それを除いて一致しなければ `DIFF` と差分を出す（exit 0＝一致・1＝不一致）

移動表の契約（tests/closing/lib-closing.sh 冒頭と同じ）: TSV・`#` 始まりと空行は読まない・列＝旧パス 新パス 種別 転送印。
旧パスが `-` か空＝新規。末尾 `/` の行はフォルダ単位（その配下のパスへ前方一致で当てる）。
"""
import difflib
import hashlib
import json
import os
import re
import subprocess
import sys


def die(msg, rc=2):
    sys.stderr.write("closing_util: %s\n" % msg)
    sys.exit(rc)


# ---------------------------------------------------------------- 移動表
def load_moves(path):
    rows = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\n")
                if not line.strip() or line.lstrip().startswith("#"):
                    continue
                cols = line.split("\t")
                if len(cols) < 3:
                    die("移動表の列が足りない: %r" % line)
                cols += [""] * (4 - len(cols))
                old, new, kind, mark = [c.strip() for c in cols[:4]]
                rows.append({"old": "" if old == "-" else old, "new": new, "kind": kind, "mark": mark})
    except OSError as e:
        die("移動表を読めない: %s" % e)
    return rows


def match_old(row_old, path):
    """行の旧パスが path に当たれば、path の残り（フォルダ行の配下部分）を返す。当たらなければ None。"""
    if not row_old:
        return None
    if row_old.endswith("/"):
        if path == row_old.rstrip("/"):
            return ""
        if path.startswith(row_old):
            return path[len(row_old):]
        return None
    return "" if path == row_old else None


def join_new(new, rest):
    if not rest:
        return new.rstrip("/") if new.endswith("/") else new
    return new.rstrip("/") + "/" + rest


def successors(rows, old):
    out = []
    for r in rows:
        rest = match_old(r["old"], old)
        if rest is not None:
            out.append(join_new(r["new"], rest))
    return out


def is_split_new(rows, new):
    for r in rows:
        if r["kind"] != "分割":
            continue
        n = r["new"]
        if new == n or (n.endswith("/") and (new.startswith(n) or new == n.rstrip("/"))):
            return True
    return False


def main_rows(rows):
    """旧パスごとの主後継（先頭行）。長い旧パスから当てるため長さの降順。"""
    seen = {}
    for r in rows:
        if r["old"] and r["old"] not in seen:
            seen[r["old"]] = r["new"]
    return sorted(seen.items(), key=lambda kv: -len(kv[0]))


# ---------------------------------------------------------------- 正規化
def load_rules(path):
    rules = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            pat, _, rep = line.partition("\t")
            rules.append((re.compile(pat), rep))
    return rules


def normalize(text, rules, subs, moves_rows, repo_dirname):
    # 1) 実行環境の実パス・コミット hash を記号へ（長いものから）
    for frm, to in sorted(subs, key=lambda s: -len(s[0])):
        if frm:
            text = text.replace(frm, to)
    # 2) 旧パス→主後継（repo 内パスとして現れる所だけ＝<WT>/・<repo 名>/ の直後か、パス文字に続かない位置）
    if moves_rows:
        for old, new in main_rows(moves_rows):
            variants = [(old, new)]
            if old.endswith("/"):
                variants.append((old.rstrip("/"), new.rstrip("/")))
            for o, n in variants:
                tail = "" if o.endswith("/") else r"(?![\w.-])"
                pat = r"(?:(?<=<WT>/)|(?<=%s/)|(?<![\w./~-]))%s%s" % (re.escape(repo_dirname), re.escape(o), tail)
                text = re.sub(pat, lambda _m, n=n: n, text)
    # 3) 時刻・PID・hash 等の正規表現
    for pat, rep in rules:
        text = pat.sub(rep, text)
    return text


# ---------------------------------------------------------------- 状態の記録と差分
def sha256_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def snap(root, out, excludes):
    state = {}
    root = os.path.abspath(root)
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        rel_dir = os.path.relpath(dirpath, root)
        rel_dir = "" if rel_dir == "." else rel_dir + "/"
        keep = []
        for d in dirnames:
            rel = rel_dir + d
            full = os.path.join(dirpath, d)
            if any(rel == e.rstrip("/") or rel.startswith(e) for e in excludes):
                continue
            if os.path.islink(full):
                state[rel] = "L " + os.readlink(full)
                continue
            keep.append(d)
        dirnames[:] = keep
        for fn in filenames:
            rel = rel_dir + fn
            full = os.path.join(dirpath, fn)
            if any(rel.startswith(e) for e in excludes):
                continue
            if os.path.islink(full):
                state[rel] = "L " + os.readlink(full)
            else:
                try:
                    state[rel] = "F " + sha256_file(full)
                except OSError:
                    state[rel] = "F <unreadable>"
    with open(out, "w", encoding="utf-8") as f:
        json.dump(state, f, sort_keys=True)


GIT_INTERNAL = re.compile(r"(^|/)\.git/(objects/|index$)")


def snapdiff(before, after, root):
    with open(before, encoding="utf-8") as f:
        b = json.load(f)
    with open(after, encoding="utf-8") as f:
        a = json.load(f)
    lines, bodies = [], []
    for rel in sorted(set(a) | set(b)):
        if rel not in a:
            lines.append("D " + rel)
        elif rel not in b:
            lines.append("A " + rel)
        elif a[rel] != b[rel]:
            lines.append("M " + rel)
        else:
            continue
        if rel in a:
            full = os.path.join(root, rel)
            if a[rel].startswith("L "):
                bodies.append("=== %s -> %s" % (rel, a[rel][2:]))
            elif GIT_INTERNAL.search(rel):
                bodies.append("=== %s <git-internal>" % rel)
            else:
                try:
                    with open(full, "rb") as f:
                        data = f.read()
                    text = data.decode("utf-8")
                    bodies.append("=== %s\n%s" % (rel, text))
                except (OSError, UnicodeDecodeError):
                    bodies.append("=== %s <binary>" % rel)
    sys.stdout.write("\n".join(lines) + "\n----\n" + "\n".join(bodies) + "\n")


# ---------------------------------------------------------------- settings.json・値の比較
def load_json(p):
    with open(p, encoding="utf-8") as f:
        return json.load(f)


def iter_hooks(settings, event=None, tool=None):
    for ev, groups in (settings.get("hooks") or {}).items():
        if event is not None and ev != event:
            continue
        for g in groups or []:
            m = g.get("matcher", "") or ""
            if tool is not None and m not in ("", "*"):
                try:
                    if not re.search(m, tool):
                        continue
                except re.error:
                    if m != tool:
                        continue
            for h in g.get("hooks") or []:
                if h.get("type", "command") == "command" and h.get("command"):
                    yield ev, m, h["command"]


def toml_load(p):
    try:
        import tomllib  # python 3.11+
        with open(p, "rb") as f:
            return tomllib.load(f)
    except ImportError:
        pass
    # 最小パーサ（tomllib が無い python 用）: [表] と key = value の行だけ。値は文字列のまま。
    doc, cur = {}, None
    with open(p, encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            if s.startswith("[") and s.endswith("]"):
                cur = doc
                for part in s.strip("[]").split("."):
                    cur = cur.setdefault(part.strip().strip('"'), {})
                continue
            k, _, v = s.partition("=")
            (cur if cur is not None else doc)[k.strip().strip('"')] = v.strip()
    return doc


def canon(path, kind):
    if kind == "json":
        doc = load_json(path)
    elif kind == "toml":
        doc = toml_load(path)
    elif kind == "plist":
        out = subprocess.run(["plutil", "-convert", "json", "-o", "-", path], capture_output=True, check=True)
        doc = json.loads(out.stdout)
    else:
        die("canon: 種類が不正: %s" % kind)
    return json.dumps(doc, sort_keys=True, ensure_ascii=False, indent=1)


def settings_cmp(base_p, new_p):
    base, new = load_json(base_p), load_json(new_p)
    base_set = {(ev, m, c) for ev, m, c in iter_hooks(base)}
    extras = [(ev, m, c) for ev, m, c in iter_hooks(new) if (ev, m, c) not in base_set]
    for _ev, _m, c in extras:
        print("EXTRA " + c)
    extra_cmds = {c for _ev, _m, c in extras}
    for ev, groups in list((new.get("hooks") or {}).items()):
        for g in groups or []:
            g["hooks"] = [h for h in (g.get("hooks") or []) if h.get("command") not in extra_cmds]
        new["hooks"][ev] = [g for g in groups if g.get("hooks")]
    a = json.dumps(base, sort_keys=True, ensure_ascii=False, indent=1).splitlines()
    b = json.dumps(new, sort_keys=True, ensure_ascii=False, indent=1).splitlines()
    if a == b:
        return 0
    print("DIFF")
    for line in difflib.unified_diff(a, b, "FX-2", "FX-1", lineterm=""):
        print(line)
    return 1


# ---------------------------------------------------------------- 入口
def main(argv):
    if not argv:
        die("サブコマンドが無い")
    cmd, args = argv[0], argv[1:]
    if cmd == "realpath":
        print(os.path.realpath(args[0]))
    elif cmd in ("moves-main", "moves-succ"):
        succ = successors(load_moves(args[0]), args[1])
        if not succ:
            return 1
        print(succ[0] if cmd == "moves-main" else "\n".join(succ))
    elif cmd == "moves-split-new":
        return 0 if is_split_new(load_moves(args[0]), args[1]) else 1
    elif cmd == "norm":
        rules_p, rest = args[0], args[1:]
        moves_rows, subs, repo_dirname, extra = None, [], "takumi009-ai-env", []
        i = 0
        while i < len(rest):
            if rest[i] == "--moves":
                moves_rows = load_moves(rest[i + 1]); i += 2
            elif rest[i] == "--sub":
                frm, _, to = rest[i + 1].partition("="); subs.append((frm, to)); i += 2
            elif rest[i] == "--extra-move":
                o, _, n = rest[i + 1].partition("="); extra.append({"old": o, "new": n, "kind": "補足", "mark": ""}); i += 2
            elif rest[i] == "--repo-dirname":
                repo_dirname = rest[i + 1]; i += 2
            else:
                die("norm: 不明な引数 %s" % rest[i])
        if moves_rows is not None:
            moves_rows = moves_rows + extra   # 補足は移動表の後ろ＝同じ旧パスなら移動表が勝つ・長い旧パス（ファイル行）から当てる
        text = sys.stdin.buffer.read().decode("utf-8", "replace")
        sys.stdout.write(normalize(text, load_rules(rules_p), subs, moves_rows, repo_dirname))
    elif cmd == "snap":
        excludes = [args[i + 1] for i in range(2, len(args) - 1) if args[i] == "--exclude"]
        snap(args[0], args[1], excludes)
    elif cmd == "snapdiff":
        snapdiff(args[0], args[1], args[2])
    elif cmd == "hooks":
        tool = args[2] if len(args) > 2 else None
        for _ev, _m, c in iter_hooks(load_json(args[0]), args[1], tool):
            print(c)
    elif cmd == "hook-cmds":
        seen = []
        for _ev, _m, c in iter_hooks(load_json(args[0])):
            if c not in seen:
                seen.append(c)
        print("\n".join(seen))
    elif cmd == "canon":
        print(canon(args[0], args[1]))
    elif cmd == "settings-cmp":
        return settings_cmp(args[0], args[1])
    else:
        die("不明なサブコマンド: %s" % cmd)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]) or 0)
