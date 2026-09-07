#!/usr/bin/env python3
r"""claude/hooks/bash-danger-gate.sh ルール③の判定ロジック。

標準入力からBashコマンド文字列を1つ受け取り、それが
「scripts/codex-exec.sh を経由しない codex exec / codex resume（execの別名
eを含む）の直接実行」に該当するかどうかを判定して、標準出力へ
DENY / ALLOW / PARSE_ERROR のいずれか1行だけを出す。

2026-09-06 codex exec 一本化（Codex呼び出しをscripts/codex-exec.sh経由に
限定）に伴い新設。呼び出し元のbash-danger-gate.shは、以前は正規表現だけで
単純コマンド分割・引用符の中身除去・シェルコメント除去・`--`終端の認識を
自前実装していたが、dogfoodレビュー（5巡）で以下の実装不備が繰り返し
見つかった:
  - コマンド文字列全体に対する除外判定（複合コマンドの無関係な断片へ
    "codex-exec.sh"や"--help"を混ぜるだけでバイパス可能）
  - 「最初の引用符より前で打ち切る」方式（引用符の**後**に来る正当な
    Codex CLI構文＝`codex -c '...' exec`のようなグローバルオプション先出し
    を見逃す）
  - エスケープされた引用符（`\"`）による対応ずれ（`codex -c
    "developer_instructions=a\"b" exec ...`で"exec"まで誤って消える）
車輪の再発明をやめ、Python標準ライブラリのshlex（POSIXシェルの引用符・
エスケープを正しく解釈するトークナイザ）に判定を委譲する方がはるかに
正確であるため、この専用スクリプトへ切り出した。

移行後さらに、以下の不具合が段階的に見つかった（いずれもCodex一次レビュー
指摘・Critical）:
  - 6巡目: shlexの既定`whitespace`は改行を単なる空白として読み捨てる
    （区切りトークンとして残さない）ため、複数行コマンド
    （`echo safe\ncodex exec task`）で直接実行を見逃す。
  - 7巡目: 改行を`;`へ単純置換する対応をしたところ、バックスラッシュ＋改行
    （シェルの行継続記法）が残っていると置換後に`\;`となり、shlexがこれを
    エスケープされたリテラルの`;`として扱ってしまい区切りとして機能しない
    （`echo safe; \`+改行+`codex exec task`で見逃す）。
  - 8巡目: シェルコメント（`#`〜改行）はshlex自身の機能で除去できるが、
    shlexはコメントを終端の改行ごと読み捨ててしまい、その改行を区切り
    トークンとして再現できない。そのため「改行を`;`へ置換してから
    shlexへ渡す」設計のままだと、`echo safe # x\ncodex exec task`で
    コメントが次行の`codex exec task`まで飲み込んでしまい見逃す。
これらはいずれも「shlex自身の改行・コメント処理に、区切りトークン化の
役目まで肩代わりさせようとしたこと」に起因する。8巡目の指摘を機に、
行継続・コメント・改行区切りの正規化は本モジュール側の専用の引用符
認識ステートマシン（`_normalize_separators()`）で先に行い、その結果
（コメント・行継続が除去され、引用符外の改行だけが`;`になったテキスト）
だけをshlexへ渡す設計に改めた。

9巡目でさらに2件見つかった（いずれもCodex一次レビュー指摘・Critical）:
  - `_normalize_separators()`側の`#`判定が「単語の先頭にあるか」を見て
    おらず、`foo#bar`のように単語の途中にある`#`まで一律コメント扱いして
    以降を丸ごと消していた（`echo foo#bar; codex exec task`で"codex exec"
    ごと消える）。POSIXシェルは単語先頭の`#`だけをコメント開始とみなす
    ため、直前の文字が空白・区切りトークン・文字列先頭のいずれかである
    場合のみコメントとして扱うよう修正した。
  - shlex自身が既定で持つ`commenters='#'`設定（`_normalize_separators()`で
    コメントを除去済みのテキストに対しても独立に働く）を無効化していな
    かったため、単語の途中にある`#`（例: `foo#bar`）以降がshlex側で
    二重に読み捨てられていた。`lexer.commenters = ""`で無効化した。

契約:
  - 標準入力: Bashコマンド文字列（1個・末尾改行の有無は問わない）。
  - 標準出力: 次のいずれか1行のみ。
      DENY        - codex exec/resume の直接実行を検出した。
      ALLOW       - 検出しなかった（無関係なコマンド・ラッパー経由・
                    --help/--version等の読み取り系を含む）。
      PARSE_ERROR - 引用符の閉じ忘れ等でトークナイズ自体に失敗した
                    （呼び出し元でfail-closed/フォールバック判定に使う）。
  - 例外を投げない（想定外の入力でも上記3値のいずれかを必ず出す）。

既知の残存限界（意図的に対応していない・「最終防衛線」の趣旨どおり
バイパスを完全に防ぐものではなく、代表的な直接記述を検出するbest-effort
のゲート）:
  - コマンド置換・パラメータ展開（`$(echo codex) exec ...`・
    `codex $(echo exec) ...`・`codex ${x:-exec} ...`）で先頭コマンド語や
    サブコマンド名が動的に決まる場合は検出できない。これは静的な文字列
    解析である以上、実際にシェルとして評価しない限り原理的に解決不能
    （どのツールでも同様の限界を持つ）。
  - サブシェルのグループ化構文は1階層の`( ... )`だけ対応し、ネストした
    サブシェルや`{ ...; }`のコマンドグループ化構文は対象外。
  - シェルの引用符分割による動的生成（例: `co'dex' ex'ec' ...`）・
    `sudo`/`env`/`command`/変数代入等を前置した起動は対象外。
  - execの別名`e`は1文字のため、フラグの値がたまたま`e`である場合
    （例: `codex review -m e`）を誤検知しうる。
  - `codex review`/`codex queue`/`codex fork`/引数なしの対話起動等、
    `exec`/`resume`（`e`別名含む）以外の起動経路は対象外（リーダー指示の
    範囲。`queue`はabsolute-rules不在の継続送信になり得るため、範囲拡大
    の要否は別途リーダー判断）。
"""

import shlex
import sys

# execのCLI別名 'e' を含む。1文字のため、フラグの値がたまたま 'e' である
# 場合（例: `codex review -m e`）を誤検知しうるが、別名検出を維持する
# トレードオフとして受け入れている（bash-danger-gate.sh側のコメント・
# tests/test-bash-danger-gate.sh参照）。
SUBCOMMANDS = {"exec", "e", "resume"}
# -V（大文字）が正式表記だが、比較は小文字化してから行うため -v も含める。
HELP_FLAGS = {"--help", "-h", "--version", "-v"}
# 区切りトークン（`;`・`&`・`|`・`&&`・`||`）。shlexはpunctuation_chars
# 指定時にこれらを1つの文字列として返す（例: "&&"は"&&"という1トークン。
# "&"を2つには分割しない）。
SEPARATORS = {";", "&", "|", "&&", "||"}


def _normalize_separators(cmd):
    """行継続・シェルコメント・改行区切りを、shlexへ渡す前に正規化する。

    shlex自身の改行/コメント処理に区切りトークン化まで肩代わりさせようと
    すると、コメントが終端の改行ごと読み捨てられ、次の行まで一体化して
    しまう等の不具合が繰り返し見つかった（モジュールdocstring参照）。
    そこで、引用符・エスケープを認識する専用のステートマシンで
    ①行継続（バックスラッシュ＋改行）を跡形もなく除去 ②シェルコメント
    （引用符外の`#`から改行の直前まで）を除去 ③残った引用符外の改行を
    `;`へ変換 の3つを先に行ってから、結果をshlexへ渡す。

    引用符内のバックスラッシュ・引用符終端の判定はPOSIXシェルの規則に
    ならう（シングルクォート内はバックスラッシュに特別な意味を持たない
    ためそのまま保持し、ダブルクォート内のバックスラッシュは次の1文字を
    エスケープする＝閉じ引用符の誤検出やコメント開始の誤判定を防ぐ）。

    戻り値: (正規化後の文字列, 引用符が閉じていないかどうか)。
    """
    out = []
    i = 0
    n = len(cmd)
    quote = None  # None、"'"、または '"'
    while i < n:
        c = cmd[i]
        if quote is None:
            if c == "\\" and i + 1 < n and cmd[i + 1] == "\n":
                i += 2  # 行継続: バックスラッシュ＋改行は跡形もなく消える
                continue
            if c == "\\" and i + 1 < n:
                # 引用符外のバックスラッシュは次の1文字をエスケープする
                # （`\#`はコメント開始ではない・`\'`は引用符開始ではない等）。
                out.append(c)
                out.append(cmd[i + 1])
                i += 2
                continue
            if c == "#":
                # POSIXシェルの規則で、`#`が**単語の先頭**にある場合のみ
                # コメントとして扱う（直前が空白・区切りトークン・文字列の
                # 先頭のいずれか）。`foo#bar`のように単語の途中に現れる`#`は
                # 単なる文字であり、コメント開始ではない（実測bashで確認・
                # Codex一次レビュー指摘・Critical・9巡目）。
                at_word_start = (not out) or out[-1] in (
                    " ",
                    "\t",
                    ";",
                    "&",
                    "|",
                    "\n",
                    "(",
                )
                if at_word_start:
                    j = cmd.find("\n", i)
                    i = n if j == -1 else j
                    continue
                out.append(c)
                i += 1
                continue
            if c in ("'", '"'):
                quote = c
                out.append(c)
                i += 1
                continue
            if c == "\n":
                out.append(";")
                i += 1
                continue
            out.append(c)
            i += 1
        else:
            if quote == '"' and c == "\\" and i + 1 < n and cmd[i + 1] == "\n":
                i += 2  # ダブルクォート内の行継続も同様に除去する
                continue
            if quote == '"' and c == "\\" and i + 1 < n:
                out.append(c)
                out.append(cmd[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
                out.append(c)
                i += 1
                continue
            out.append(c)
            i += 1
    return "".join(out), quote is not None


def is_codex(token):
    """先頭コマンド語がcodex本体かどうか（パス接頭辞は許容）。
    ラッパーのファイル名は"codex"ではなく"codex-exec.sh"なので、これには
    一致しない（特別扱いの除外ロジックが不要になる）。"""
    base = token.rsplit("/", 1)[-1]
    return base.lower() == "codex"


def split_clauses(tokens):
    clauses = [[]]
    for t in tokens:
        if t in SEPARATORS:
            clauses.append([])
        else:
            clauses[-1].append(t)
    return clauses


def clause_is_direct_call(clause):
    # 先頭の "(" はサブシェルのグループ化構文（`( codex exec ... )`）。
    # 空白で区切られていれば独立トークンとして現れるため、対応する末尾の
    # ")" とあわせて取り除いてから判定する（1階層ずつ対応。`{ ...; }`の
    # コマンドグループ化構文は非対応＝既知の残存限界）。
    while clause and clause[0] == "(":
        clause = clause[1:]
        if clause and clause[-1] == ")":
            clause = clause[:-1]
    if not clause or not is_codex(clause[0]):
        return False
    rest = clause[1:]
    # `--` はCLIの「オプション解析の終端」記法。以降はサブコマンドとしても
    # フラグとしても解釈されず、そのままプロンプト/positional引数になる
    # （`codex exec -- --help`の--helpは実際にはプロンプト文字列）。
    if "--" in rest:
        rest = rest[: rest.index("--")]
    lowered = [t.lower() for t in rest]
    # サブコマンド名自体（exec/e/resume）を除いた、フラグでもサブコマンド
    # 名でもないトークンが1つでも残っていれば、それは実質的な引数
    # （プロンプト文字列等）とみなし、--help/--versionだけの「読み取り系」
    # 呼び出しとは判定しない。
    non_flag_extra = [
        t for t in lowered if not t.startswith("-") and t not in SUBCOMMANDS
    ]
    if any(t in HELP_FLAGS for t in lowered) and not non_flag_extra:
        return False
    return any(t in SUBCOMMANDS for t in lowered)


def analyze(cmd):
    normalized, unterminated_quote = _normalize_separators(cmd)
    if unterminated_quote:
        return "PARSE_ERROR"
    try:
        lexer = shlex.shlex(normalized, posix=True, punctuation_chars=";&|")
        lexer.whitespace_split = True
        # シェルコメントは_normalize_separators()側で単語先頭位置を判定した
        # うえで既に除去済み。shlex自身の既定commenters（'#'）を無効化しない
        # と、単語の途中にある`#`（例: `foo#bar`）以降まで二重に読み捨てて
        # しまい、後続の実引数・区切りトークンごと消えてしまう
        # （Codex一次レビュー指摘・Critical・9巡目）。
        lexer.commenters = ""
        tokens = list(lexer)
    except ValueError:
        return "PARSE_ERROR"
    clauses = split_clauses(tokens)
    for clause in clauses:
        if clause_is_direct_call(clause):
            return "DENY"
    return "ALLOW"


def main():
    cmd = sys.stdin.read()
    try:
        result = analyze(cmd)
    except Exception:
        # 想定外の例外でも呼び出し元の判定を止めないよう、フォールバック
        # 判定（呼び出し元での簡易正規表現チェック）に委ねる。
        result = "PARSE_ERROR"
    print(result)


if __name__ == "__main__":
    main()
