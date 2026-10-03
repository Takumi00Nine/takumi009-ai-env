#!/usr/bin/env bash
# 台帳ツール（Core 組立）＝台帳と実体の突合（FR-14）と、照会 2 つ（鍵→部品パス・知らせ→送り手）。
# 正本＝docs/v1.1-components 設計 §3・§5.6・§10・§11、docs/v1.2-notify-install 設計 §2.1・§2.4。
# 口の契約＝tests/test-ledger.sh・tests/test-notify.sh 冒頭。
#
# 使い方:
#   ledger-tool.sh check         検査 ①〜⑧ を全部行う。合格＝無出力・exit 0。
#                                不合格＝1 件 1 行を stdout（行頭＝検査名）・exit 1。
#                                  ① part ② suite ③ coupling ④ provider-leak ⑤ moves ⑥ forward ⑦ live ⑧ readme
#   ledger-tool.sh lookup <鍵>   鍵→「<repo ルート>/<パス>」を台帳の行順に 1 行ずつ。
#                                exit 0 あり／1 鍵なし（stderr なし）／2 台帳異常／3 実体異常（2・3 は stderr に固定文 1 行）
#   ledger-tool.sh route <知らせ>  知らせ（例＝call.ask・answer）→「<届け先><TAB><repo ルート>/<パス>」を台帳の行順に。
#                                対象＝8 列目「知らせ」に、その知らせか種別だけ（call は call.* 全部）を持つ part 行。
#                                実体の無い・実行可能でない行は 1 行ずつ stderr に固定文（LEDGER: part …）を出して除く。
#                                exit 0 あり／1 該当なし／2 台帳異常／3 該当が全件実体異常
#   ledger-tool.sh live-set      ⑦ が突合する対象＝全部入りの組立が生成した settings.json の全フックの command と、
#                                配置された LaunchAgent の起動対象（一時 HOME は `$HOME` と書く）
# 上書き口: AIENV_LEDGER＝台帳のパス・AIENV_MOVES＝移動表のパス（既定＝repo ルートの core/data/ 配下）。
# 隔離: ⑦ と live-set は repo の複製を一時 HOME に置き、README のメイン機手順（雛形の複写→全部入り→常駐の登録）を
#   SKIP_LAUNCHCTL=1・LAUNCHCTL_TIMEOUT_SECS=1・偽 launchctl／osascript／cmux で走らせる（実 HOME・実 launchd に触れない）。
# 依存: bash 3.2・awk・git・python3（標準 lib）。照会（lookup）は shell と awk だけで行う（python を起動しない）。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ---- 設計定数（§11）＝変えるときはここだけ ----
LEDGER_REL="core/data/ledger.tsv"
MOVES_REL="core/data/moves.tsv"
LEDGER="${AIENV_LEDGER:-$ROOT/$LEDGER_REL}"
MOVES="${AIENV_MOVES:-$ROOT/$MOVES_REL}"
FUNCTIONS="ai-brain team usage notify dock core"   # 機能の語彙
LAYERS="data rules executor connect assembly"      # 層の語彙
ROW_KINDS="part suite notify"                      # 台帳の種類列
NAME_RE='^[a-z][a-z0-9-]*$'                        # フォルダ名・提供元名の構文
NOTICES="call call.alert call.usage call.ask answer"  # 「知らせ」列の語彙＝種別（呼出 call・応答 answer）か 呼出.区分
MSG_HEAD="LEDGER:"                                 # 照会の固定文の先頭語（種別語＝ledger／part）
RC_FOUND=0; RC_NO_KEY=1; RC_LEDGER_BAD=2; RC_PART_BAD=3; RC_USAGE=64
CHECK_FAIL_RC=1
REPO_HOME_REL="work/takumi009-ai-env"              # 組立が想定する repo の置き場（HOME 相対＝README の clone 先）
CONFIG_HOME_REL=".config/takumi009-ai-env"         # 雛形の複写先（README のメイン機手順）
LIVE_MAIN_KEY="core.install"                       # 全部入りの組立の鍵
LIVE_AGENT_KEY_RE='^[a-z][a-z0-9-]*\.install-'     # 常駐の登録の鍵（全部入りの後に台帳の行順で走らせる）

usage() { sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; }

# ---------------------------------------------------------------- 照会（lookup・route）
# ledger_scan <key|route> <鍵|知らせ> — 台帳の形式を検証し、当たった part 行を「HIT<TAB><提供元><TAB><パス>」で行順に出す。
# 形式不正は「BAD<TAB><原因>」1 行。台帳を読めなければ固定文を stderr に出して RC_LEDGER_BAD。
ledger_scan() {
  if [ ! -f "$LEDGER" ] || [ ! -r "$LEDGER" ]; then
    printf '%s ledger 台帳を読めない %s\n' "$MSG_HEAD" "$LEDGER" >&2
    return "$RC_LEDGER_BAD"
  fi
  # 台帳の形式検証（check と同じ語彙＝$FUNCTIONS/$LAYERS/$ROW_KINDS を使う。種類・列数・
  # part の機能/層・suite の機能語彙・notify の機能＝check が行う判定と同じ）。
  awk -F'\t' -v mode="$1" -v q="$2" -v kinds=" $ROW_KINDS " -v fns=" $FUNCTIONS " -v lys=" $LAYERS " '
    /^#/ || /^[[:space:]]*$/ { next }
    NF < 6 { printf "BAD\t%d 行目の列が足りない\n", NR; exit }
    index(kinds, " " $1 " ") == 0 { printf "BAD\t%d 行目の種類が語彙外\n", NR; exit }
    $1 == "part" && (index(fns, " " $3 " ") == 0 || index(lys, " " $4 " ") == 0) {
      printf "BAD\t%d 行目の機能か層が語彙外\n", NR; exit }
    $1 == "suite" && index(fns, " " $3 " ") == 0 {
      printf "BAD\t%d 行目の機能が語彙外\n", NR; exit }
    $1 == "notify" && $3 != "notify" {
      printf "BAD\t%d 行目の機能が notify でない\n", NR; exit }
    $1 != "part" { next }
    mode == "key" && $6 == q { print "HIT\t" $5 "\t" $2; next }
    mode == "route" && NF >= 8 {
      n = split($8, v, ",")
      for (i = 1; i <= n; i++) if (v[i] == q || index(q, v[i] ".") == 1) { print "HIT\t" $5 "\t" $2; break }
    }
  ' "$LEDGER"
}

# part_ok <鍵|知らせ> <パス> — 実体が実在して実行可能なら 0。そうでなければ固定文を stderr に 1 行出して 1。
part_ok() {
  local p="$ROOT/$2"
  if [ ! -e "$p" ]; then
    printf '%s part %s %s 実体が無い\n' "$MSG_HEAD" "$1" "$2" >&2; return 1
  fi
  if [ -d "$p" ] || [ ! -x "$p" ]; then
    printf '%s part %s %s 実行可能でない\n' "$MSG_HEAD" "$1" "$2" >&2; return 1
  fi
}

# query <key|route> <鍵|知らせ> — 照会 2 つの共通の流れ。key は 1 行でも実体異常なら 3、
# route は実体異常の行だけを除き、全件が除かれたら 3。
query() {
  local mode="$1" q="$2" res bad hits="" tag prov val rc
  res="$(ledger_scan "$mode" "$q")"; rc=$?
  [ "$rc" = "0" ] || return "$rc"
  bad="$(printf '%s\n' "$res" | grep '^BAD' | head -1)"
  if [ -n "$bad" ]; then
    printf '%s ledger %s\n' "$MSG_HEAD" "${bad#BAD	}" >&2
    return "$RC_LEDGER_BAD"
  fi
  [ -n "$res" ] || return "$RC_NO_KEY"
  while IFS=$'\t' read -r tag prov val; do
    if part_ok "$q" "$val"; then
      if [ "$mode" = "key" ]; then hits="$hits$ROOT/$val"$'\n'; else hits="$hits$prov	$ROOT/$val"$'\n'; fi
    elif [ "$mode" = "key" ]; then
      return "$RC_PART_BAD"
    fi
  done <<EOF
$res
EOF
  [ -n "$hits" ] || return "$RC_PART_BAD"
  printf '%s' "$hits"
  return "$RC_FOUND"
}

# ---------------------------------------------------------------- 全部入りの組立（⑦・live-set）
# assemble <work> — repo の複製を <work>/home/<REPO_HOME_REL> に置き、一時 HOME＝<work>/home で
# 雛形の複写（データ層の *.sample）→ 全部入り（鍵 LIVE_MAIN_KEY）→ 常駐の登録（鍵 LIVE_AGENT_KEY_RE）を走らせる。
# 非 0 で終わった段は「<repo 相対パス><TAB><rc>」を <work>/failed へ。
assemble() {
  local w="$1" h="$1/home" repo="$1/home/$REPO_HOME_REL" stub="$1/stub" c f rel rc
  mkdir -p "$repo" "$stub" "$h/$CONFIG_HOME_REL" || return 1
  : > "$w/failed"
  for c in launchctl osascript cmux; do
    printf '#!/bin/sh\nexit 0\n' > "$stub/$c"; chmod +x "$stub/$c"
  done
  ( cd "$ROOT" && git ls-files -co --exclude-standard -z | while IFS= read -r -d '' f; do
      case "$f" in tests/*) continue ;; esac
      { [ -e "$f" ] || [ -L "$f" ]; } && printf '%s\0' "$f"
    done | tar -cf - --null -T - ) | ( cd "$repo" && tar -xf - ) || return 1
  awk -F'\t' '!/^#/ && $1 == "part" && $4 == "data" && $2 ~ /\.sample$/ { print $2 }' "$LEDGER" \
    | while IFS= read -r rel; do
        f="${rel##*/}"; cp "$repo/$rel" "$h/$CONFIG_HOME_REL/${f%.sample}" 2>/dev/null
      done
  { awk -F'\t' -v k="$LIVE_MAIN_KEY" '!/^#/ && $1 == "part" && $6 == k { print $2 }' "$LEDGER"
    awk -F'\t' -v re="$LIVE_AGENT_KEY_RE" '!/^#/ && $1 == "part" && $6 ~ re { print $2 }' "$LEDGER"
  } | while IFS= read -r rel; do
      rc=0
      env HOME="$h" PATH="$stub:$PATH" SKIP_LAUNCHCTL=1 LAUNCHCTL_TIMEOUT_SECS=1 \
        bash "$repo/$rel" </dev/null >>"$w/assemble.log" 2>&1 || rc=$?
      [ "$rc" = "0" ] || printf '%s\t%s\n' "$rel" "$rc" >> "$w/failed"
    done
  return 0
}

# ---------------------------------------------------------------- 検査の本体（python3 標準 lib）
read -r -d '' PY_CODE <<'PY'
import os, re, sys, json, plistlib, subprocess
from collections import Counter, defaultdict

E = os.environ
ROOT = E["LT_ROOT"]
FUNCS = E["LT_FUNCTIONS"].split()
LAYERS = E["LT_LAYERS"].split()
NOTICES = E["LT_NOTICES"].split()
KINDS = E["LT_ROW_KINDS"].split()
NAME_RE = re.compile(E["LT_NAME_RE"])
REPO_HOME_REL = E["LT_REPO_HOME_REL"]
LEDGER_REL = E["LT_LEDGER_REL"]

OUTSIDE_RE = re.compile(r"^(README\.md|LICENSE|\.gitignore|Brewfile|tests/)")   # 部品外（要件 §2）
SUITE_RE = re.compile(r"^tests/test-[^/]*\.sh$")
KEY_RE = re.compile(r"^([a-z][a-z0-9-]*)\.[a-z][a-z0-9-]*$")                     # 鍵＝<機能>.<働き>
COMMENT_RE = re.compile(r"^\s*(#|//)")
SHEBANG_RE = re.compile(r"^#!.*(/|env )(sh|bash|python[0-9.]*)(\s|$)")
LEAK_RES = [                                                                      # 式 C（要件 §7）
    re.compile(r"\.(claude|codex)([^0-9A-Za-z_-]|$)"),
    re.compile(r"(^|[\s;|&(=])(claude|codex)([\s;|&)]|$)"),
    re.compile(r"[=\[(]\s*[\"'](claude|codex)[\"']"),
]
LEAK_EXCLUDE_RE = re.compile(r"\.claude.{1,5}logs")
LEAK_OK_LAYERS = ("connect", "assembly")
MOVE_KINDS = ("移動", "分割", "新規")
SPLIT, NEW = "分割", "新規"
NO_MARK = ("", "-")
README_HEADINGS = ("### Structure", "### 構成")
TREE_RE = re.compile(r"^([│├└─\s]*)(\S+)")

out = []
def rep(check, target, why=""):
    out.append(("%s %s %s" % (check, target, why)).rstrip())

def read_tsv(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if line.strip() and not line.startswith("#"):
                rows.append((n, line.split("\t")))
    return rows

def git_files():
    r = subprocess.run(["git", "-C", ROOT, "ls-files", "-z"], stdout=subprocess.PIPE, check=True)
    return [f for f in r.stdout.decode("utf-8").split("\0") if f]

def full(p):
    return os.path.join(ROOT, p.rstrip("/"))

def is_program(p):
    if p.endswith((".sh", ".py")):
        return True
    try:
        with open(full(p), "rb") as f:
            return bool(SHEBANG_RE.match(f.readline().decode("utf-8", "replace")))
    except OSError:
        return False

def code_lines(p):
    try:
        with open(full(p), encoding="utf-8", errors="replace") as f:
            return [(n, l.rstrip("\n")) for n, l in enumerate(f, 1) if not COMMENT_RE.match(l)]
    except OSError:
        return []

class Row:
    def __init__(self, n, c):
        self.n, self.kind, self.path, self.func, self.layer, self.prov, self.key = n, *c[:6]
        self.notice = c[7].strip() if len(c) > 7 and c[7].strip() else "-"   # 8 列目「知らせ」（無ければ -）

def notice_ok(v):
    # 「知らせ」の値＝語彙（種別か 呼出.区分）のカンマ区切り。
    return all(t in NOTICES for t in v.split(","))

def load_moves(path):
    rows = []
    for n, c in read_tsv(path):
        if len(c) < 3:
            rep("moves", "%s:%d" % (os.path.relpath(path, ROOT), n), "列が足りない")
            continue
        c = (c + ["", ""])[:4]
        rows.append(dict(n=n, old=c[0].strip(), new=c[1].strip(), kind=c[2].strip(), mark=c[3].strip()))
    return rows

def main_successors(mrows):
    m = {}
    for r in mrows:
        if r["old"] not in ("", "-") and r["old"] not in m:
            m[r["old"]] = r["new"]
    return m

def check_static(ledger, moves):
    try:
        lrows = read_tsv(ledger)
    except OSError as e:
        rep("part", os.path.relpath(ledger, ROOT), "台帳を読めない（%s）" % e.strerror)
        return
    try:
        mrows = load_moves(moves)
    except OSError as e:
        rep("moves", os.path.relpath(moves, ROOT), "移動表を読めない（%s）" % e.strerror)
        mrows = []
    rows = []
    for n, c in lrows:
        if len(c) < 6:
            rep("part", "%s:%d" % (os.path.relpath(ledger, ROOT), n), "列が足りない")
        elif c[0] not in KINDS:
            rep("part", c[1], "種類 %s が語彙外" % c[0])
        else:
            rows.append(Row(n, c))
    parts_rows = [r for r in rows if r.kind == "part"]
    suite_rows = [r for r in rows if r.kind == "suite"]
    notify_rows = [r for r in rows if r.kind == "notify"]
    forwards = {r["old"].rstrip("/") for r in mrows if r["mark"] not in NO_MARK and r["old"] not in ("", "-")}
    files = git_files()
    fileset = set(files)
    parts = [f for f in files if not OUTSIDE_RE.match(f) and f not in forwards
             and (os.path.lexists(full(f)))]

    def covering(p):
        return [r for r in parts_rows if r.path == p or (r.path.endswith("/") and p.startswith(r.path))]

    # ① 部品↔台帳
    info = {}
    for f in parts:
        c = covering(f)
        if not c:
            rep("part", f, "台帳に行が無い")
        elif len(c) > 1:
            rep("part", f, "台帳の行が複数（%s）" % " ".join(r.path for r in c))
        else:
            info[f] = c[0]
    for r in parts_rows:
        p = r.path
        exists = os.path.isdir(full(p)) if p.endswith("/") else os.path.isfile(full(p))
        why = []
        if not exists:
            why.append("実在しない")
        if r.func not in FUNCS:
            why.append("機能 %s が語彙外" % r.func)
        if r.layer not in LAYERS:
            why.append("層 %s が語彙外" % r.layer)
        if r.layer == "connect" and not NAME_RE.match(r.prov):
            why.append("提供元 %s が構文外" % r.prov)
        if r.layer != "connect" and r.prov != "-":
            why.append("接続でない行に提供元 %s" % r.prov)
        box = "%s/%s/" % (r.func, r.layer) + ("%s/" % r.prov if r.layer == "connect" else "")
        rest = p[len(box):].rstrip("/") if p.startswith(box) else ""
        if (not rest or "/" in rest) and not (p.endswith("/") and p == box):
            why.append("置き場が %s の直下でない" % box)
        if r.key != "-":
            m = KEY_RE.match(r.key)
            if not m or m.group(1) != r.func:
                why.append("鍵 %s が <機能>.<働き> でない" % r.key)
            if exists and (p.endswith("/") or not os.access(full(p), os.X_OK)):
                why.append("鍵 %s の実体が実行可能でない" % r.key)
        if r.notice != "-":
            if not notice_ok(r.notice):
                why.append("知らせ %s が語彙外" % r.notice)
            if not (r.func == "notify" and r.layer == "connect"):
                why.append("知らせを持つのは Notify の接続の部品だけ")
            elif p.endswith("/") or not os.access(full(p), os.X_OK):
                why.append("知らせを持つ部品が実行可能でない")
        if why:
            rep("part", p, "・".join(why))
    # 口＝Notify の実行器の部品はちょうど 1 行で鍵を持つ（Notify が置かれているときだけ＝FR-8）。
    mouth = [r for r in parts_rows if r.func == "notify" and r.layer == "executor"]
    if any(r.func == "notify" for r in parts_rows) and (len(mouth) != 1 or mouth[0].key == "-"):
        rep("part", "notify/executor/", "口（鍵を持つ Notify の実行器の部品）が %d 行（ちょうど 1 行であること）"
            % sum(1 for r in mouth if r.key != "-"))
    by_key = defaultdict(list)
    for r in parts_rows:
        if r.key != "-":
            by_key[r.key].append(r)
    for k, rs in by_key.items():
        if len(rs) > 1 and not (all(r.layer == "connect" for r in rs) and len({r.func for r in rs}) == 1):
            for r in rs:
                rep("part", r.path, "鍵 %s が複数行（同じ機能の接続行だけが共有できる）" % k)
    for r in notify_rows:
        why = []
        if r.func != "notify":
            why.append("Notify 所在の機能が notify でない")
        if r.path.startswith("Vault:"):
            if r.prov != "-":
                why.append("発する側（Vault の規則ノート）の提供元は - であること（%s）" % r.prov)
        elif not NAME_RE.match(r.prov):
            why.append("下流の取次の届け先 %s が構文外" % r.prov)
        if not r.path.startswith(("Vault:", "~/", "/")) and not os.path.isfile(full(r.path)):
            why.append("実在しない")
        if why:
            rep("part", r.path, "・".join(why))

    # ② スイートに機能 1 つ
    for f in files:
        if SUITE_RE.match(f):
            n = sum(1 for r in suite_rows if r.path == f)
            if n != 1:
                rep("suite", f, "台帳の行が %d 件（1 件であること）" % n)
    for r in suite_rows:
        if not os.path.isfile(full(r.path)):
            rep("suite", r.path, "実在しない")
        if r.func not in FUNCS:
            rep("suite", r.path, "機能 %s が語彙外" % r.func)

    programs = [f for f in parts if f in info and is_program(f)]

    # ③ 結合参照（§10.2）
    def q_pattern(q):
        if not is_program(q):
            return re.compile(re.escape(q))
        b = os.path.basename(q)
        alts = [r"(^|[^0-9A-Za-z_.-])%s([^0-9A-Za-z_-]|$)" % re.escape(b)]
        if b.endswith(".py"):
            alts.append(r"(^|[^0-9A-Za-z_.-])%s([^0-9A-Za-z_.-]|$)" % re.escape(b[:-3]))
        return re.compile("|".join("(?:%s)" % a for a in alts), re.M)
    # 同じファイル名の部品（例＝送り手 deliver.sh）への 1 つの名指しは 1 組＝パスごと書かれた部品、
    # 無ければ台帳の行順で最初の部品として報告する。
    qs = sorted(((q, info[q], q_pattern(q)) for q in parts if q in info and info[q].func != "core"),
                key=lambda t: t[1].n)
    for p in programs:
        P = info[p]
        if P.func == "core":
            continue
        text = "\n".join(l for _, l in code_lines(p))
        hits = []
        for q, Q, pat in qs:
            if q == p:
                continue
            same_conn = P.layer == "connect" and P.func == Q.func and P.prov == Q.prov
            if not (Q.func != P.func or (Q.layer == "connect" and not same_conn)):
                continue
            if pat.search(text):
                hits.append(q)
        names = []
        for q in hits:
            b = os.path.basename(q)
            if b not in names:
                names.append(b)
                same = [x for x in hits if os.path.basename(x) == b]
                rep("coupling", "%s -> %s" % (p, next((x for x in same if x in text), same[0])))

    # ④ 式 C に当たる部品は 接続・組立 のどちらか
    for p in programs:
        if info[p].layer in LEAK_OK_LAYERS:
            continue
        for n, l in code_lines(p):
            l = LEAK_EXCLUDE_RE.sub("", l)
            if any(rx.search(l) for rx in LEAK_RES):
                rep("provider-leak", p, "%d 行目が提供元の識別子に当たる" % n)
                break

    # ⑤ 移動表の 3 条件（FR-13）。移動表に行の無い部品・スイート（v1.1 の後に足したもの）は問わない（v1.2 FR-20）
    for r in mrows:
        if r["kind"] not in MOVE_KINDS:
            rep("moves", r["new"], "種別 %s が語彙外" % r["kind"])
        if r["old"] == "":
            rep("moves", r["new"], "由来（旧パス）が空")
        elif (r["old"] == "-") != (r["kind"] == NEW):
            rep("moves", r["new"], "旧パス - と種別 新規 は対で使う")
    origins = Counter(r["new"] for r in mrows if r["old"] != "")
    for new, c in origins.items():
        if c > 1:
            rep("moves", new, "由来が %d 件（1 件であること）" % c)
    olds = defaultdict(list)
    for r in mrows:
        if r["old"] not in ("", "-"):
            olds[r["old"]].append(r)
    for old, rs in olds.items():
        if len(rs) > 1 and any(r["kind"] != SPLIT for r in rs):
            rep("moves", rs[0]["new"], "旧 %s の後継が複数なのに種別が分割でない" % old)

    # ⑥ 転送のリンク先＝主後継
    mains = main_successors(mrows)
    done = set()
    for r in mrows:
        old = r["old"]
        if r["mark"] in NO_MARK or old in ("", "-") or old in done:
            continue
        done.add(old)
        link = old.rstrip("/")
        lp = full(link)
        if not os.path.islink(lp):
            rep("forward", link, "転送 symlink が無い")
            continue
        if link not in fileset:
            rep("forward", link, "git が追跡していない")
        if os.path.isabs(os.readlink(lp)):
            rep("forward", link, "相対リンクでない")
        if not os.path.exists(lp):
            rep("forward", link, "リンク先が無い（主後継 %s）" % mains[old])
        elif os.path.realpath(lp) != os.path.realpath(full(mains[old])):
            rep("forward", link, "リンク先が主後継 %s と違う" % mains[old])

    # ⑧ README の構成節のフォルダ名＝実フォルダ・台帳の場所。提供元のフォルダ（<機能>/connect/<提供元>/）は
    # 載っていなくてよい（載っていれば実在すること）。台帳に行の無い機能（取り外した木）の記載は問わない（v1.2 §2.4）。
    real, providers = set(), set()
    listed_funcs = {r.func for r in rows}
    for f in files:
        if f in forwards or "/" not in f or not os.path.lexists(full(f)):
            continue
        seg = f.split("/")
        real.add(seg[0] + "/")
        if seg[0] == "tests" or seg[0] not in FUNCS:
            continue
        if len(seg) > 2:
            real.add("/".join(seg[:2]) + "/")
        if len(seg) > 3 and seg[1] == "connect":
            providers.add("/".join(seg[:3]) + "/")
        r = info.get(f)
        if r is not None and r.path.endswith("/"):
            real.add(r.path)
    try:
        with open(os.path.join(ROOT, "README.md"), encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        rep("readme", "README.md", "読めない")
        return
    lines = text.split("\n")
    for h in README_HEADINGS:
        idx = [i for i, l in enumerate(lines) if l.strip() == h]
        if not idx:
            rep("readme", h, "構成節が無い")
            continue
        i = idx[0] + 1
        while i < len(lines) and not lines[i].startswith("```"):
            i += 1
        folders, stack = set(), []
        i += 1
        while i < len(lines) and not lines[i].startswith("```"):
            m = TREE_RE.match(lines[i])
            i += 1
            if not m:
                continue
            depth = len(m.group(1)) // 4
            if depth == 0:
                stack = []
                continue
            stack = stack[:depth - 1]
            if m.group(2).endswith("/"):
                folders.add("".join(stack) + m.group(2))
                stack.append(m.group(2))
        for d in sorted(real - folders):
            rep("readme", d, "README の構成節（%s）に無い" % h)
        for d in sorted(folders - real - providers):
            if d.split("/")[0] in FUNCS and d.split("/")[0] not in listed_funcs:
                continue
            rep("readme", d, "実フォルダが無い（%s）" % h)
    if LEDGER_REL not in text:
        rep("readme", LEDGER_REL, "台帳の場所が README に無い")

def live_items(h):
    items = []
    try:
        with open(os.path.join(h, ".claude", "settings.json"), encoding="utf-8") as f:
            s = json.load(f)
        for groups in (s.get("hooks") or {}).values():
            for g in groups:
                for hk in g.get("hooks", []):
                    if "command" in hk:
                        items.append(hk["command"])
    except (OSError, ValueError):
        s = None
    la = os.path.join(h, "Library", "LaunchAgents")
    for name in sorted(os.listdir(la)) if os.path.isdir(la) else []:
        try:
            with open(os.path.join(la, name), "rb") as f:
                items.append(plistlib.load(f)["ProgramArguments"][0])
        except Exception:
            items.append(os.path.join(la, name))
    return s, [i.replace(h, "$HOME") for i in items]

def check_live(w):
    h = os.path.join(w, "home")
    copy = os.path.realpath(os.path.join(h, REPO_HOME_REL))
    with open(os.path.join(w, "failed"), encoding="utf-8") as f:
        for line in f:
            rel, rc = line.rstrip("\n").split("\t")
            rep("live", rel, "組立が失敗（rc=%s）" % rc)
    s, items = live_items(h)
    if s is None:
        rep("live", "$HOME/.claude/settings.json", "生成されていない")

    def target(label, path, need_x):
        if not os.path.exists(path):
            rep("live", label, "実在しない")
            return
        real = os.path.realpath(path)
        orig = os.path.join(ROOT, real[len(copy) + 1:]) if real.startswith(copy + "/") else real
        if not os.path.exists(orig):
            rep("live", label, "repo に実体が無い")
        elif need_x and (os.path.isdir(orig) or not os.access(orig, os.X_OK)):
            rep("live", label, "実行可能でない")

    for i in items:
        target(i, i.replace("$HOME", h).split()[0], True)
    allow = ((s or {}).get("permissions") or {}).get("allow") or []
    for a in allow:
        m = re.match(r"^Bash\((.*?)(:\*)?\)$", a)
        if not m:
            continue
        for k, word in enumerate(m.group(1).split()):
            for pre in ("~/", "$HOME/"):
                if word.startswith(pre + REPO_HOME_REL + "/"):
                    target(word, os.path.join(h, word[len(pre):]), k == 0)

cmd = sys.argv[1]
if cmd == "static":
    check_static(sys.argv[2], sys.argv[3])
elif cmd == "live":
    check_live(sys.argv[2])
elif cmd == "live-items":
    for i in live_items(os.path.join(sys.argv[2], "home"))[1]:
        out.append(i)
if out:
    print("\n".join(out))
PY

py() {
  LT_ROOT="$ROOT" LT_FUNCTIONS="$FUNCTIONS" LT_LAYERS="$LAYERS" LT_ROW_KINDS="$ROW_KINDS" LT_NAME_RE="$NAME_RE" \
  LT_REPO_HOME_REL="$REPO_HOME_REL" LT_LEDGER_REL="$LEDGER_REL" \
  LT_NOTICES="$NOTICES" python3 -c "$PY_CODE" "$@"
}

WORK=""
cleanup() { [ -n "$WORK" ] && { chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"; }; }
trap cleanup EXIT

case "${1:-}" in
  lookup)
    [ $# -eq 2 ] || { usage; exit "$RC_USAGE"; }
    query key "$2"; exit $? ;;
  route)
    [ $# -eq 2 ] || { usage; exit "$RC_USAGE"; }
    query route "$2"; exit $? ;;
  check)
    WORK="$(mktemp -d)" || exit 2
    result="$(py static "$LEDGER" "$MOVES")" || { echo "台帳ツール: 検査の実行に失敗" >&2; exit 2; }
    assemble "$WORK"
    live="$(py live "$WORK")" || { echo "台帳ツール: ⑦ の実行に失敗" >&2; exit 2; }
    result="$(printf '%s\n%s\n' "$result" "$live" | grep . || true)"
    [ -z "$result" ] && exit 0
    printf '%s\n' "$result"
    exit "$CHECK_FAIL_RC" ;;
  live-set)
    WORK="$(mktemp -d)" || exit 2
    assemble "$WORK"
    py live-items "$WORK"; exit $? ;;
  *)
    usage; exit "$RC_USAGE" ;;
esac
