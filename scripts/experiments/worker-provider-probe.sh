#!/usr/bin/env bash
#
# 使い捨て実験スクリプト（2026-09-02 作成 / 2026-09-03 拡張×2 / 2026-09-04
# 拡張×2〈AU既定モデルID・G系400切り分け変種〉）検証後に削除すること。
# Throwaway experiment script (created 2026-09-02, extended twice on
# 2026-09-03, twice more on 2026-09-04 — AU default model ID, then variants
# to isolate the G-family 400s) — delete after verification is done.
#
# 目的（JA）:
#   EXP-3: Bedrock 経由で起動しているリーダーセッション（環境に
#   CLAUDE_CODE_USE_BEDROCK=1 / AWS_REGION / AWS_PROFILE /
#   ANTHROPIC_DEFAULT_*_MODEL が入っている）の Bash から `claude -p` を
#   別プロセスとして起動したとき、サブスク（Anthropic ログイン）側の
#   provider で動かせるかを、5つのバリアント(A〜E)で実測して1行ずつ比較する。
#   EXP-1: 同じサブ機で、Bedrock を `ANTHROPIC_BASE_URL` 経路（bedrock-runtime
#   の /anthropic ルート、または bedrock-mantle）経由で `claude -p` から
#   正常に呼べるかを、curl 直叩き(F1〜F3)と `claude -p`(G1〜G5, 任意でH1・G6)の
#   バリアントで実測して1行ずつ比較する。Bedrock資格情報はプロファイル
#   （アクセスキー+シークレット）のままとし、Bedrock APIキーは発行しない方針
#   （本人裁定・2026-09-03）のため、ベアラートークンは AWS 公式の
#   aws-bedrock-token-generator でプロファイルから自機生成する
#   （--token-from-profile / G6）。
#   いずれも読み取り専用・何も書き換えない確認用スクリプト。
#
# Purpose (EN):
#   EXP-3: Probe whether `claude -p` (spawned as a separate process from Bash
#   while the parent leader session is running via Bedrock, i.e. with
#   CLAUDE_CODE_USE_BEDROCK=1 / AWS_REGION / AWS_PROFILE /
#   ANTHROPIC_DEFAULT_*_MODEL set in the environment) can be made to run
#   against the subscription (Claude.ai OAuth login) provider instead, by
#   trying 5 variants (A-E) of env/settings overrides and comparing one
#   summary line per variant.
#   EXP-1: On the same worker machine, probe whether Bedrock can be reached
#   through the `ANTHROPIC_BASE_URL` route (the bedrock-runtime `/anthropic`
#   path, or bedrock-mantle) from both plain curl (F1-F3) and `claude -p`
#   (G1-G5, optionally H1 and G6), one summary line per variant. Per the
#   2026-09-03 decision, Bedrock credentials stay a profile (access key +
#   secret) — no Bedrock API key is issued — so the bearer token is instead
#   generated locally from that profile via AWS's own
#   aws-bedrock-token-generator (--token-from-profile / G6).
#   Both probes are read-only and do not modify anything.
#   EXP-1追加（2026-09-04）: G1〜G4/G6/H1が(F1〜F3のcurl直叩きは通るのに)
#   全変種400 "Request metadata contains a value that violates the regular
#   expression"で落ちる原因を切り分けるため、F4〜F6(curlのbodyへmetadataを
#   足して受理条件を探る)・X1(実AWSを呼ばずローカルHTTPサーバーでclaude -pの
#   生リクエストを捕捉する)・G7/G8(claude起動時のbeta/attributionヘッダを
#   抑止する既知の環境変数を試す)を追加。
#   Added 2026-09-04: to isolate why G1-G4/G6/H1 all fail with a 400
#   "Request metadata contains a value that violates the regular expression"
#   (while F1-F3's plain curl succeeds), added F4-F6 (add a metadata field to
#   curl's body to probe what's accepted), X1 (a local HTTP server that
#   never calls AWS, capturing the raw request `claude -p` actually builds),
#   and G7/G8 (try known env vars that suppress claude's beta/attribution
#   headers).
#
# 一次情報（WebFetchで確認済み） / Sources verified via WebFetch:
#   - bedrock-runtime + Bedrock API key（2026-09-03確認）:
#     POST https://bedrock-runtime.{region}.amazonaws.com/anthropic/v1/messages
#     ヘッダ x-api-key（または Authorization: Bearer）+ anthropic-version: 2023-06-01
#     https://docs.aws.amazon.com/bedrock/latest/userguide/inference-messages-api.html
#     https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys.html
#   - bedrock-mantle（2026-09-03確認）:
#     POST https://bedrock-mantle.{region}.api.aws/anthropic/v1/messages
#     （x-api-keyのみ確認。count_tokensは本来こちらが正式ルート。実測で
#     bedrock-runtime側の/anthropic/v1/messages/count_tokensは200+
#     UnknownOperationExceptionを返すことを確認=このドキュメント記載と整合）。
#   - Claude Code の資格情報変数とヘッダの対応（2026-09-03確認）:
#     ANTHROPIC_AUTH_TOKEN -> Authorization: Bearer / ANTHROPIC_API_KEY -> x-api-key
#     apiKeyHelperの値はAuthorization/x-api-key両方へ送られる
#     https://code.claude.com/docs/en/llm-gateway-connect
#   - aws-bedrock-token-generator（プロファイルからの短期トークン生成・2026-09-03確認）:
#     provide_token(region=..., expiry=..., aws_credentials_provider=...)。
#     region省略時はAWS_REGION、expiry省略時は既定1時間・最大12時間、
#     プロファイル選択はboto3標準のクレデンシャルチェーン(AWS_PROFILE環境変数)経由。
#     https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys.html
#     (Generate a short-term API key > Python)
#     https://github.com/aws/aws-bedrock-token-generator-python/blob/main/README.md
#   - Claude Sonnet 5 の Geo/Global inference ID（--model 既定値の根拠・
#     2026-09-04確認）: bedrock-runtime の Geo inference ID は us./eu./au.、
#     Global は global.anthropic.claude-sonnet-5。ap-southeast-2 は
#     Geo(au.)/Global のみ利用可（In-Region 不可）。
#     https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-sonnet-5.html
#   - G系400切り分け(F4〜F6/X1/G7/G8)の根拠（2026-09-04確認）:
#     AWS公式の/anthropic Messages APIスキーマに`metadata`フィールドは無い
#     （公式gateway互換ガイド）。ANTHROPIC_BASE_URL経由でclaude -pがAPI互換
#     エンドポイントへ送る内容は、api.anthropic.com向けの全bodyフィールド
#     （metadataを含むと推定）をそのまま送ると記載:
#     https://code.claude.com/docs/en/llm-gateway-protocol
#     CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS/CLAUDE_CODE_ATTRIBUTION_HEADER
#     は公式ドキュメントページには未掲載(2026-09-04時点)だが、複数の独立した
#     GitHub Issue・コミュニティ記事で存在・効果が確認できる(1次情報ほど
#     確度は高くないため、G7/G8の結果は「決定的」ではなく「参考」として扱う):
#     https://github.com/anthropics/claude-code/issues/20031
#     https://github.com/anthropics/claude-code/issues/50085
#
# 使い方（JA） / Usage (EN):
#   git pull 後に、このリポジトリのルートから実行する:
#     bash scripts/experiments/worker-provider-probe.sh [オプション]
#   （実行属性が付いているので ./scripts/experiments/worker-provider-probe.sh でも可）
#   Run from the repo root after `git pull`:
#     bash scripts/experiments/worker-provider-probe.sh [options]
#   (executable bit is set, so ./scripts/experiments/worker-provider-probe.sh also works)
#
# オプション（JA） / Options (EN):
#   --only <名前,...>   実行するバリアントだけを選ぶ（例: --only A,B,F1,G2）。
#                       Restrict which variants run (e.g. --only A,B,F1,G2).
#   --model <ID>        G1〜G4/G6 で使う Bedrock 上のモデルID（既定: 下記参照。
#                       現在の既定は au.anthropic.claude-sonnet-5＝サブ機が
#                       AU/ap-southeast-2 のため。他 Region では明示指定）。
#                       Bedrock model ID for G1-G4/G6 (default: see below.
#                       Currently defaults to au.anthropic.claude-sonnet-5
#                       since the worker machine is in AU/ap-southeast-2;
#                       pass explicitly for other regions).
#   --mantle            任意バリアント G5（bedrock-mantle 経由）も実行する。
#                       Also run the optional G5 variant (via bedrock-mantle).
#   --with-websearch    任意バリアント H1（WebSearch ツール許可）も実行する。
#                       Also run the optional H1 variant (WebSearch allowed).
#   --with-helper       任意バリアント G6（apiKeyHelper経由）も実行する。
#                       Also run the optional G6 variant (via apiKeyHelper).
#   --token-from-profile[=<プロファイル名>]
#                       AWS_BEARER_TOKEN_BEDROCK が(env/bedrock.envのどちらにも)
#                       無い場合に限り、AWSプロファイルから短期トークンを自機生成して
#                       F1〜F3/G1〜G5/H1で使う（venv内のaws-bedrock-token-generator
#                       を使用。値は"="形式でのみ受け付ける。省略時はAWS_PROFILE、
#                       それも無ければ"default"）。G6は(このフラグの有無に関わらず)
#                       常に自前でプロファイルからトークンを生成する。
#                       When AWS_BEARER_TOKEN_BEDROCK is not found (in env or
#                       bedrock.env), generate a short-term token locally from
#                       an AWS profile for use by F1-F3/G1-G5/H1 (via
#                       aws-bedrock-token-generator inside a venv). Value is
#                       accepted only via the "=" form; defaults to
#                       $AWS_PROFILE or "default". G6 always generates its
#                       own token from a profile regardless of this flag.
#   --token-venv <dir>  上記で使う venv のパス（既定: $BEDROCK_TOKEN_VENV か
#                       ~/.venvs/bedrock-token）。venv/モジュールが無くても
#                       自動インストールはしない（読み取り専用の原則）— セットアップ
#                       手順を表示して該当バリアントをスキップ/エラーにする。
#                       venv path for the above (default: $BEDROCK_TOKEN_VENV
#                       or ~/.venvs/bedrock-token). Never auto-installs a
#                       missing venv/module (read-only principle) — prints
#                       setup instructions and skips/errors the affected
#                       variant(s) instead.
#   --out <path>        1行サマリの表を Markdown ファイルにも書き出す（秘密は書かない）。
#                       Also write the one-line summaries as a Markdown table
#                       to this path (never writes secrets).
#   --dry-run           何も実行せず、各バリアントで set/unset する環境変数名と
#                       実行コマンド（値はマスク）だけを表示する。
#                       Print, per variant, which env vars would be set/unset
#                       and the command that would run (values masked) —
#                       nothing is actually executed.
#   -h, --help          このヘッダを表示して終了する。
#                       Print this header and exit.
#
# バリアント（JA） / Variants (EN):
#   [EXP-3: claude -p のプロバイダ切替 / provider override for claude -p]
#   A) 素の継承        : そのまま `claude -p ...`
#   B) env除去          : `env -u CLAUDE_CODE_USE_BEDROCK -u AWS_PROFILE -u AWS_REGION claude -p ...`
#   C) --settings "0"   : `--settings '{"env":{"CLAUDE_CODE_USE_BEDROCK":"0"}}'`
#   D) --settings ""    : `--settings '{"env":{"CLAUDE_CODE_USE_BEDROCK":""}}'`
#   E) B + C 併用       : env除去と --settings "0" の両方
#
#   [EXP-1: ANTHROPIC_BASE_URL 経路での Bedrock 到達性 / reachability via ANTHROPIC_BASE_URL]
#   F1) curl x-api-key       : POST {bedrock-runtime}/anthropic/v1/messages, x-api-key ヘッダ
#   F2) curl Bearer          : 同上リクエストを Authorization: Bearer ヘッダで
#   F3) curl count_tokens    : POST {bedrock-runtime}/anthropic/v1/messages/count_tokens
#                              （F1/F2 のうち通った方のヘッダを再利用。実測では
#                              bedrock-runtime側は200+UnknownOperationExceptionを
#                              返す=count_tokensはbedrock-mantle専用という記載と整合）
#   G1) claude -p base_url   : ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN、Bedrock系env除去
#   G2) G1 + settings打消し  : G1 に加え --settings で CLAUDE_CODE_USE_BEDROCK/MANTLE を "0" に
#   G3) G2 のAPIキー版       : G2 の認証を ANTHROPIC_API_KEY（x-api-key送信）に変更
#   G4) G2 + [1m]           : G2 のモデルIDに `[1m]` サフィックスを付与（受理されるか確認）
#   G5) mantle版（--mantle） : BASE_URL を bedrock-mantle・モデルIDを anthropic.claude-sonnet-5 に
#   G6) apiKeyHelper版（--with-helper）: ANTHROPIC_AUTH_TOKEN/API_KEYは渡さず、
#                              --settingsのapiKeyHelperにヘルパースクリプト
#                              （プロファイルから都度トークン生成・$OUTDIR内・
#                              パーミッション700）を指定。--settingsインラインで
#                              apiKeyHelperが受理されるか自体も観測項目
#                              （実測でapiKeySource=apiKeyHelperとなることを確認済み）。
#   H1) WebSearch許可（--with-websearch）: G2 の設定で --allowedTools WebSearch を許可して実行
#       ※解釈上の注意: H1は(他のG変種と同じく)--permission-mode planで動く。
#       planモード自体がWebSearchの実行を止める可能性を排除できていないため、
#       G2が成功しているのにH1のtools列が空(WebSearchが使われた形跡なし)の
#       場合は、「ANTHROPIC_BASE_URL経路でWebSearchは使えない」と結論する前に、
#       `--only H1`から`--permission-mode plan`を外した実行を1回だけ手動で
#       試すこと(このスクリプトは実APIを叩かずに判定できないため、注記のみで
#       留める)。
#       Interpretation note: H1 runs with --permission-mode plan, like the
#       other G variants. Whether plan mode itself can prevent WebSearch
#       from actually executing has not been ruled out. So if G2 succeeds
#       but H1's tools column is empty (no sign WebSearch ran), don't
#       conclude "WebSearch doesn't work over ANTHROPIC_BASE_URL" without
#       first manually trying `--only H1` once with --permission-mode plan
#       removed (this can't be determined without hitting the real API, so
#       it's left as a note rather than automated).
#
#   [G系400の原因切り分け追加変種（2026-09-04追加・既定では実行しない。
#    --only で明示指定した場合のみ実行される） /
#    Additional variants to isolate the G-family 400s (added 2026-09-04, not
#    in the default set — only run when named explicitly via --only)]
#   F4) curl metadata短い値  : F1のbodyに`metadata:{user_id:"probe-user"}`を追加
#   F5) curl metadata Claude Code類似 : `metadata.user_id`をuser_<64桁hex>_
#                              account_<uuid>_session_<uuid>形式(英数・_・-の
#                              み)の固定ダミー値にして送る
#   F6) curl metadata JSON文字列値 : `metadata.user_id`の値そのものを
#                              {"device_id":...,"account_uuid":...,
#                              "session_id":...}形式のJSON文字列(波括弧・
#                              引用符を含む)にして送る
#      F4〜F6はいずれもF1と同じx-api-key認証・POST /v1/messagesで、
#      httpコードとエラー本文の要旨(error.type/error.message先頭120字)を
#      1行サマリに出す。
#   X1) ローカル捕捉（実AWS不要）: 127.0.0.1の空きポートに最小HTTPサーバーを
#                              立て、ANTHROPIC_BASE_URL/ANTHROPIC_AUTH_TOKEN
#                              (ダミー値)をそこへ向けたclaude -p(G2相当)を
#                              実行し、実際に届いたリクエストのbodyトップ
#                              レベルキー一覧・metadataフィールドのJSON全文・
#                              anthropic-betaヘッダ・model値だけを記録する
#                              (system prompt・messages本文・Authorization
#                              ヘッダは一切記録しない)。何を受けても400を
#                              返して打ち切る(HEAD warm-upやcount_tokensが
#                              先に来る場合を考慮し最大3リクエストまで待つ)。
#   G7) G2 + no-experimental-betas : G2に
#                              CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1を追加
#   G8) G2 + no-attribution-header : G2に
#                              CLAUDE_CODE_ATTRIBUTION_HEADER=0を追加
#
#   F4) curl, short metadata value: same POST as F1 with
#       `metadata:{user_id:"probe-user"}` added to the body.
#   F5) curl, Claude-Code-like metadata: same, but `metadata.user_id` is a
#       fixed dummy value shaped like user_<64-hex>_account_<uuid>_
#       session_<uuid> (alnum/underscore/hyphen only).
#   F6) curl, JSON-string metadata value: same, but `metadata.user_id`'s
#       value is itself a JSON-formatted string (containing braces/quotes)
#       like {"device_id":...,"account_uuid":...,"session_id":...}.
#      F4-F6 all reuse F1's x-api-key auth against POST /v1/messages, and
#      report the http code plus an error-body summary (error.type /
#      error.message, first 120 chars) as a one-line summary.
#   X1) Local capture (no real AWS call): spins up a minimal HTTP server on
#       a free 127.0.0.1 port, points ANTHROPIC_BASE_URL/ANTHROPIC_AUTH_TOKEN
#       (a dummy value) at it, runs `claude -p` (G2-equivalent) against it,
#       and records only the actual request's body top-level keys, the full
#       JSON text of the metadata field, the anthropic-beta header, and the
#       model value (never the system prompt, message content, or
#       Authorization header). Always answers 400 regardless of what it
#       receives (waits up to 3 requests to account for a possible HEAD
#       warm-up or an early count_tokens call).
#   G7) G2 + no-experimental-betas: G2 with
#       CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1 added.
#   G8) G2 + no-attribution-header: G2 with
#       CLAUDE_CODE_ATTRIBUTION_HEADER=0 added.
#
# 安全のための制約（JA）:
#   - 各バリアントに 90 秒のタイムアウト（macOS 標準 bash には timeout/gtimeout が
#     無い前提で、プロセスグループごと kill する実装。参考:
#     Knowledge/macos-bash-timeout-process-group.md）。
#   - EXP-3 側のツール実行はさせない（--allowedTools "" と --permission-mode plan の併用）。
#     EXP-1 の G1〜G6/H1 は共通の基底引数(--permission-mode plan・--safe-mode・
#     --output-format stream-json・--verbose)を共有し、G1〜G6はそこへ
#     --allowedTools "" --tools "" を足してツール実行自体を無効化する。
#     H1だけがその例外で、ツール集合を --allowedTools WebSearch --tools WebSearch
#     に絞って明示的にWebSearchだけを許可する（--permission-mode plan/--safe-mode
#     自体はH1でも変えない）。
#   - API キー等の値は一切表示しない。環境変数は「名前と set/unset の有無」のみ表示する。
#     curl の認証ヘッダは -K の設定ファイル（作業ディレクトリ内・パーミッション600）経由で
#     渡し、コマンドライン引数（ps 等で見える経路）には値を載せない。表示直前には常に
#     redact() でトークン文字列そのものが紛れ込んでいないかも保険的に置換する。
#     AWS_BEARER_TOKEN_BEDROCK自体も値を取り込んだ直後にunsetする。これは
#     A〜E(claude起動)やF1〜F3(curlの-K経由なので元々不要)の子プロセスへ
#     この変数名で漏れる経路を断つためのもので、G1〜G5がANTHROPIC_AUTH_TOKEN/
#     API_KEYとして同じ値を意図的にexportしてclaudeへ渡すこと自体は防がない
#     (それこそがG1〜G5で検証したい対象そのものであり、その子プロセスに
#     ps e等で見える形になるのは避けられない・想定内)。G1〜G5では対象外の認証変数
#     (ANTHROPIC_API_KEY/ANTHROPIC_AUTH_TOKEN/CLAUDE_CODE_OAUTH_TOKEN)も
#     reset_auth_env()で毎回unsetしてから対象の1つだけexportし、相互汚染を防ぐ。
#     ~/.config/takumi009-ai-env/bedrock.envは今もサブシェル内でsource(=シェル
#     コードとして実行)されるが、evalは一切使わず親はサブシェルが書いた
#     一時ファイル(600)をcatするだけ。そのため何か起きてもサブシェル内に
#     閉じ、親シェルのコードがその出力によって実行されることはない
#     (「コード注入不可」は言い過ぎだったため訂正。詳細はコード内コメント参照)。
#   - Bedrock 資格情報 (AWS_BEARER_TOKEN_BEDROCK、または --token-from-profile
#     で生成したトークン) が見つからない場合、F1〜F3/G1〜G5/H1 は理由を1行表示して
#     スキップする（--dry-run 時は説明のみ表示して継続）。G6 はvenv/モジュールが
#     無ければ同様にスキップし、--token-from-profileそのものはvenv/モジュールが
#     無いとセットアップ手順を表示してexit 1する（自動インストールはしない）。
#   - 何もファイルを書き換えない（一時ディレクトリと --out 指定先のみ使用。
#     一時ディレクトリ(G6のヘルパースクリプト含む)は終了時に削除、--out 先にも
#     秘密は書かない）。
#
# Safety constraints (EN):
#   - 90s timeout per variant, implemented via process-group kill (macOS stock
#     bash has no timeout/gtimeout). See Knowledge/macos-bash-timeout-process-group.md.
#   - EXP-3 variants disable tool use for the probed `claude -p` calls
#     (--allowedTools "" plus --permission-mode plan). EXP-1's G1-G6/H1 all
#     share a base set of args (--permission-mode plan, --safe-mode,
#     --output-format stream-json, --verbose); G1-G6 add --allowedTools ""
#     --tools "" on top, fully disabling tool use (and, via --safe-mode,
#     CLAUDE.md/skills/plugins/hooks/MCP servers too — reducing the surface
#     through which an exported secret could reach something else). H1 is
#     the sole exception: it narrows the tool set to
#     --allowedTools WebSearch --tools WebSearch instead, while keeping the
#     same --permission-mode plan / --safe-mode as the others.
#   - Never prints secret values — only env var names and set/unset status.
#     curl auth headers are passed via a -K config file (in the working temp
#     dir, mode 600) rather than as command-line arguments (which would be
#     visible via `ps`, etc). Every printed string also goes through
#     redact() as a defense-in-depth substitution of the raw token, if any.
#     AWS_BEARER_TOKEN_BEDROCK itself is unset right after its value is
#     captured. This closes the leak path under that specific variable name
#     for A-E's claude children and for F1-F3 (which never needed it as an
#     env var anyway, since curl gets it via -K). It does not, and is not
#     meant to, stop G1-G5 from deliberately exporting the same value as
#     ANTHROPIC_AUTH_TOKEN/API_KEY for claude to pick up — that's the very
#     thing G1-G5 are testing, so it being visible via `ps e` etc. to that
#     one child process is expected and unavoidable.
#     G1-G5 also unset the other credential vars (ANTHROPIC_API_KEY/
#     ANTHROPIC_AUTH_TOKEN/CLAUDE_CODE_OAUTH_TOKEN) via reset_auth_env()
#     before exporting only the one being tested, preventing cross-
#     contamination. Reading ~/.config/takumi009-ai-env/bedrock.env still
#     sources it (i.e. executes it as shell code) inside a subshell, but
#     never uses eval — the parent only `cat`s a 600-mode temp file the
#     subshell wrote, so anything that went wrong stays confined to that
#     subshell rather than executing as code in the parent ("no code-
#     injection path" was an overstatement; see the inline comment for
#     detail).
#   - When the Bedrock credential (AWS_BEARER_TOKEN_BEDROCK, or a token
#     generated via --token-from-profile) is not found, F1-F3/G1-G5/H1 are
#     skipped with a one-line reason (--dry-run still prints the would-be
#     command and continues). G6 is skipped the same way if the venv/module
#     is missing; --token-from-profile itself prints setup instructions and
#     exits 1 if the venv/module is missing (never auto-installs).
#   - Read-only: writes only to a temp dir removed on exit (including G6's
#     helper script), plus the --out destination if given (never contains
#     secrets).

set -euo pipefail
# 秘密(AWS_BEARER_TOKEN_BEDROCK等)をexportする箇所があるため、このスクリプトは
# 絶対に `bash -x` / `set -x` で実行しない（xtraceはredact()の対象外でトークンが
# そのままログへ出る）。デバッグ時も -x は使わないこと。
# NEVER run this script with `bash -x` / `set -x`: it exports secrets
# (AWS_BEARER_TOKEN_BEDROCK etc.), and xtrace is not covered by redact() —
# it would print the raw token. Do not add -x even for debugging.
set +x

TIMEOUT_SECS=90
PROMPT="Reply with exactly: OK"

KNOWN_VARIANTS="A B C D E F1 F2 F3 F4 F5 F6 X1 G1 G2 G3 G4 G5 G6 G7 G8 H1"
DEFAULT_VARIANTS="A B C D E F1 F2 F3 G1 G2 G3 G4"

ONLY_LIST=""
OUT_PATH=""
DRY_RUN=0
DO_MANTLE=0
DO_WEBSEARCH=0
DO_HELPER=0
CLI_MODEL=""
TOKEN_FROM_PROFILE=0
PROFILE_NAME=""
TOKEN_VENV="${BEDROCK_TOKEN_VENV:-$HOME/.venvs/bedrock-token}"

print_help() {
  # ヘッダのコメント行(先頭の#!行を除く、連続する#行)をそのまま出す。
  # 行番号を決め打ちしない実装（ヘッダ加筆時にズレて壊れるのを防ぐ）。
  # Dump the leading run of '#'-comment lines (skipping the #! line) as
  # help text. Does not hardcode a line number, so it stays correct as the
  # header comment grows/shrinks over time.
  awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --only)
      ONLY_LIST="${2:?--only には値が必要です / --only requires a value}"
      shift 2
      ;;
    --only=*)
      ONLY_LIST="${1#*=}"
      # スペース区切り形式(${2:?...})は空値を弾くのに、"="形式は
      # "${1#*=}" が単に空文字を返すだけで黙って通してしまっていた。
      # 両形式で挙動を揃える(Opus5レビュー指摘・2026-09-03)。
      # The space-separated form (${2:?...}) rejects an empty value, but
      # the "=" form previously let "${1#*=}" silently produce an empty
      # string. Aligned the two forms (per Opus 5 review, 2026-09-03).
      [ -n "$ONLY_LIST" ] || { echo "ERROR: --only には値が必要です / --only requires a value" >&2; exit 1; }
      shift
      ;;
    --model)
      CLI_MODEL="${2:?--model には値が必要です / --model requires a value}"
      shift 2
      ;;
    --model=*)
      CLI_MODEL="${1#*=}"
      [ -n "$CLI_MODEL" ] || { echo "ERROR: --model には値が必要です / --model requires a value" >&2; exit 1; }
      shift
      ;;
    --out)
      OUT_PATH="${2:?--out には値が必要です / --out requires a value}"
      shift 2
      ;;
    --out=*)
      OUT_PATH="${1#*=}"
      [ -n "$OUT_PATH" ] || { echo "ERROR: --out には値が必要です / --out requires a value" >&2; exit 1; }
      shift
      ;;
    --mantle)
      DO_MANTLE=1
      shift
      ;;
    --with-websearch)
      DO_WEBSEARCH=1
      shift
      ;;
    --with-helper)
      DO_HELPER=1
      shift
      ;;
    --token-from-profile)
      # 値は任意(getopt long-option の "="形式のみで受け付け、スペース区切りの
      # 次語は取らない)。次の引数が別のプロファイル名なのか次のオプションなのか
      # 曖昧になるのを避けるため。値省略時は後段で AWS_PROFILE / "default" に解決する。
      # Value is optional and accepted only via the "=" form (not a following
      # bare word), to avoid ambiguity between "next word is the profile name"
      # vs "next word is another option". When omitted, resolved later to
      # $AWS_PROFILE or "default".
      TOKEN_FROM_PROFILE=1
      shift
      ;;
    --token-from-profile=*)
      TOKEN_FROM_PROFILE=1
      PROFILE_NAME="${1#*=}"
      shift
      ;;
    --token-venv)
      TOKEN_VENV="${2:?--token-venv には値が必要です / --token-venv requires a value}"
      shift 2
      ;;
    --token-venv=*)
      TOKEN_VENV="${1#*=}"
      [ -n "$TOKEN_VENV" ] || { echo "ERROR: --token-venv には値が必要です / --token-venv requires a value" >&2; exit 1; }
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    *)
      echo "ERROR: 未知のオプション: $1 / unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# --only はカンマ区切り/スペース区切りどちらでも受け付け、内部ではスペース区切りに揃える。
# --only accepts comma- or space-separated names; normalize to space-separated internally.
ONLY_LIST="${ONLY_LIST//,/ }"
if [ -n "$ONLY_LIST" ]; then
  UNKNOWN_ONLY_NAMES=""
  for v in $ONLY_LIST; do
    case " $KNOWN_VARIANTS " in
      *" $v "*) : ;;
      *) UNKNOWN_ONLY_NAMES="$UNKNOWN_ONLY_NAMES $v" ;;
    esac
  done
  # 未知の名前があれば黙って0件実行にせず、その場でエラー終了する
  # (自動実行時に「全部スキップ=exit 0」を成功と誤認しないようにするため)。
  # Fail fast on unknown names instead of silently running zero variants
  # (so an automated run never mistakes "everything skipped" for success).
  if [ -n "$UNKNOWN_ONLY_NAMES" ]; then
    echo "ERROR: --only に未知のバリアント名:$UNKNOWN_ONLY_NAMES / unknown variant name(s) in --only:$UNKNOWN_ONLY_NAMES" >&2
    echo "       既知のバリアント / known variants: $KNOWN_VARIANTS" >&2
    exit 1
  fi
fi

# --token-from-profile / --with-helper で使うプロファイル名の既定値解決。
# ここでの $AWS_PROFILE は呼び出し元シェルの値であり、後で各variant_G*内の
# reset_auth_env が(claude起動用の)子プロセス側でunsetするのとは無関係。
# Resolve the default profile name used by --token-from-profile / --with-helper.
# $AWS_PROFILE here is the caller's own shell value; unrelated to
# reset_auth_env unsetting it later inside each variant_G*'s child process.
if [ -z "$PROFILE_NAME" ]; then
  PROFILE_NAME="${AWS_PROFILE:-default}"
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "ERROR: claude コマンドが見つかりません（PATH を確認してください） / claude command not found in PATH" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq コマンドが見つかりません / jq command not found in PATH" >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl コマンドが見つかりません / curl command not found in PATH" >&2
  exit 1
fi

OUTDIR=$(mktemp -d "${TMPDIR:-/tmp}/worker-provider-probe.XXXXXX")

# 大域umask: $OUTDIR配下に書くもの(stream-jsonログ・curl応答本文・
# token_gen.stdout/stderr等)は個別にumaskを効かせる箇所以外もすべて600に
# したい。--token-from-profile経由のトークンがtoken_gen.stdoutへ0644で
# 残っていた(局所umaskが3箇所にしか無かったため)ことが実測で判明したので、
# ここで大域に締める(Opus5レビュー指摘・2026-09-03 2巡目)。個別のumaskサブ
# シェルは冗長になるが害はないためそのまま残す。
# Global umask: everything written under $OUTDIR (stream-json logs, curl
# response bodies, token_gen.stdout/stderr, etc.) should be 600, not just
# the few spots that had a local umask subshell. Testing found the
# --token-from-profile token was left world/group-readable (0644) in
# token_gen.stdout because only 3 call sites had a local umask. Tightening
# globally here closes that (per Opus 5 review round 2, 2026-09-03). The
# existing local umask subshells become redundant but are harmless, so
# they're left in place.
umask 077

# 実行中の子プロセス(グループ)のPID。SIGINT/TERM/HUP受信時にここを見て
# プロセスグループごと kill する。run_with_timeout 実行中のみ非空。
# PID of the currently-running child (process group). Signal handler below
# uses this to kill the whole group on SIGINT/TERM/HUP. Non-empty only while
# run_with_timeout is running.
CURRENT_PID=""
LAST_RC=0
LAST_TIMED_OUT=0

# 直接の子(リーダー)PIDではなく、プロセスグループ(-PGID)宛てに送る。
# リーダーが先に終了していても、同じグループの孫プロセスが残っていれば
# グループIDは有効なままなので、存在確認なしで送っても無害
# (該当なしなら kill は失敗するだけ = || true で握りつぶす)。
# Send to the process group (-PGID), not just the direct child PID: even
# if the leader already exited, a stray grandchild in the same group keeps
# the pgid alive. Sending unconditionally is harmless when there is
# nothing left (kill just fails, suppressed by || true).
sweep_group() {
  local pgid="$1" grace_secs="${2:-1}"
  [ -z "$pgid" ] && return 0
  # TERM が実際に何かへ届いた場合のみ猶予をおいて KILL する
  # (何も残っていなければ kill は失敗するだけで、余計な sleep もしない)。
  # Only wait-and-KILL if TERM actually reached something (if nothing is
  # left, kill just fails and we skip the extra sleep).
  if kill -TERM -- -"$pgid" 2>/dev/null; then
    sleep "$grace_secs"
    kill -KILL -- -"$pgid" 2>/dev/null || true
  fi
}

cleanup() {
  sweep_group "$CURRENT_PID"
  rm -rf "$OUTDIR"
}
trap cleanup EXIT
on_term_signal() {
  local exit_code="$1"
  cleanup
  trap - EXIT
  exit "$exit_code"
}
# シグナルごとに慣例の終了コードを使う (128+シグナル番号: INT=130, HUP=129, TERM=143)。
# Use the conventional exit code per signal (128+signum: INT=130, HUP=129, TERM=143).
trap 'on_term_signal 130' INT
trap 'on_term_signal 143' TERM
trap 'on_term_signal 129' HUP

# --- 90秒タイムアウト付きでコマンドを実行し、標準出力/エラーを $1 に書く ---
# --- Run a command with a 90s timeout, writing stdout/stderr to $1 ---
# macOS 標準 bash に timeout/gtimeout が無いため、ジョブ制御で新しい
# プロセスグループを作らせ、タイムアウト時はグループごと kill する。
# 結果は LAST_RC / LAST_TIMED_OUT (グローバル) に入れる。タイムアウト時は
# 対象プロセスの実際の終了コードに関わらず LAST_RC=124 に固定する
# （TERM を自前ハンドラで正常終了扱いする対象があっても誤って exit=0 と
# 表示しないため）。
# Results go into the globals LAST_RC / LAST_TIMED_OUT. On timeout, LAST_RC
# is forced to 124 regardless of the target's actual wait status (so a
# process that traps TERM and exits 0 is not misreported as success).
run_with_timeout() {
  local outfile="$1"
  shift
  local waited=0 timed_out=0 rc

  set -m
  ( "$@" >"$outfile" 2>&1 ) &
  CURRENT_PID=$!
  set +m

  while kill -0 "$CURRENT_PID" 2>/dev/null; do
    if [ "$waited" -ge "$TIMEOUT_SECS" ]; then
      timed_out=1
      sweep_group "$CURRENT_PID" 2
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done

  if wait "$CURRENT_PID" 2>/dev/null; then
    rc=0
  else
    rc=$?
  fi

  # リーダー(直接の子)は終了していても、同じプロセスグループの孫が
  # 残っている場合がある。CURRENT_PID を空にする前にグループを掃除する
  # (タイムアウト経路で既にKILL済みでも、対象が無ければ sweep_group は無害)。
  # The leader (direct child) may have exited while a grandchild in the same
  # process group is still running. Sweep the group before clearing
  # CURRENT_PID (harmless no-op if nothing is left, e.g. already killed
  # above on the timeout path).
  sweep_group "$CURRENT_PID"
  CURRENT_PID=""

  if [ "$timed_out" -eq 1 ]; then
    LAST_RC=124
    LAST_TIMED_OUT=1
  else
    LAST_RC=$rc
    LAST_TIMED_OUT=0
  fi
}

# --- stream-json (NDJSON) の出力から安全にフィールドを取り出す ---
# --- Safely extract a field from stream-json (NDJSON) output ---
# タイムアウトで kill された場合、末尾の行が途中で切れて不正 JSON になりうる。
# 1行ずつ fromjson を試み、パースできない行は捨ててから集計する。
# On timeout-kill the last line may be truncated/invalid JSON; parse line by
# line with fromjson and drop unparseable lines before aggregating.
parse_field() {
  local outfile="$1" jqfilter="$2" val
  # `set -euo pipefail` 環境で、jqが(不正JSON等で)非0終了した場合に
  # このコマンド置換代入だけでスクリプト全体が落ちないよう `|| true` で
  # 明示的に握りつぶす(その場合 val は空になり、直後のフォールバックで "?" になる)。
  # Under `set -euo pipefail`, guard this plain assignment's command
  # substitution with `|| true` so a non-zero jq exit (e.g. on malformed
  # JSON) cannot kill the whole script; val just ends up empty and falls
  # back to "?" below.
  val=$( (jq -R 'fromjson? // empty' "$outfile" 2>/dev/null | jq -rs "$jqfilter" 2>/dev/null) || true )
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    val="?"
  fi
  # 改行/CR/タブが混じっていても必ず1行に収める（1バリアント1行の表示を保証）。
  # すべての抽出フィールドがここを通るので個別サニタイズは不要。
  # Collapse newlines/CR/tabs so every extracted field is single-line; since
  # all fields go through here, no per-field sanitization is needed elsewhere.
  val=$(printf '%s' "$val" | tr '\n\r\t' '   ')
  printf '%s' "$val"
}

# EXP-1 側の詳細は下に追記された SUMMARY_ROWS に集約するので、report() 自体は
# 元のまま（A〜E に対して実行するコマンド自体・標準出力の表示形式は変えない）。
# 末尾の record_summary 呼び出しだけが新規追加で、標準出力の見た目には影響
# しない。ただし、A〜E は今や親シェルが AWS_BEARER_TOKEN_BEDROCK を unset
# した後の環境で実行される(EXP-1追加に伴う望ましい副作用。詳細は後述の
# unset の箇所を参照)ため、「環境が完全に不変」ではない点は正確に区別する。
# EXP-1 detail rows are collected in SUMMARY_ROWS below; report() itself is
# left as-is (the command actually invoked for A-E, and A-E's stdout
# format, are unchanged). Only the record_summary call at the end is new,
# and it does not affect what is printed to stdout. A-E do, however, now
# run in an environment where the parent shell has already unset
# AWS_BEARER_TOKEN_BEDROCK (a desirable side effect of the EXP-1 additions;
# see the unset further below) — so "the environment is entirely
# unchanged" would be an overstatement, distinct from "the invoked command
# is unchanged" (per Opus 5 review, 2026-09-03).
report() {
  local name="$1" outfile="$2" rc="$3" timed_out="$4"
  local model apikey provider result_text timeout_tag

  model=$(parse_field "$outfile" '[.[] | select(.type=="system" and .subtype=="init")][0].model // "?"')
  apikey=$(parse_field "$outfile" '[.[] | select(.type=="system" and .subtype=="init")][0].apiKeySource // "?"')
  provider=$(parse_field "$outfile" '(([.[] | select(.type=="result")][0].modelUsage // {}) | to_entries[0].value.provider) // "?"')
  result_text=$(parse_field "$outfile" '[.[] | select(.type=="result")][0].result // "?"')

  timeout_tag="no"
  [ "$timed_out" -eq 1 ] && timeout_tag="yes(124)"

  printf '%-26s model=%-20s apiKeySource=%-14s provider=%-12s result=%-8s exit=%-5s timeout=%s\n' \
    "$name" "$model" "$apikey" "$provider" "$result_text" "$rc" "$timeout_tag"

  # A〜E は Bedrock トークンを一切扱わないので実質no-opだが、report2との
  # 非対称を無くすため record_summary へ渡す値だけは redact() を通す
  # (printfでの標準出力側はA〜Eの表示形式を変えないためそのまま)。
  # A-E never touch a Bedrock token, so this is effectively a no-op, but
  # pass the record_summary value through redact() anyway to remove the
  # asymmetry with report2 (per Opus 5 review, 2026-09-03). The printf line
  # above is left untouched so A-E's stdout format doesn't change.
  record_summary "$name" "exit=$rc" "model=$model apiKeySource=$apikey provider=$provider result=$(redact "$result_text") timeout=$timeout_tag"
}

run_variant() {
  local name="$1"
  shift
  local outfile="$OUTDIR/$(echo "$name" | tr -c 'A-Za-z0-9' '_').json"
  run_with_timeout "$outfile" "$@"
  report "$name" "$outfile" "$LAST_RC" "$LAST_TIMED_OUT"
}

# =====================================================================
# ここから EXP-1 用の追加インフラ（2026-09-03 追加）
# EXP-1 additional infrastructure (added 2026-09-03)
# =====================================================================

# --only / --out / --dry-run のための1行サマリ集約バッファ。
# Buffer of one-line summaries for --out (and future --only reporting).
SUMMARY_ROWS=()
# 実際に実行された(dry-runで説明だけ出したのではなく、run_with_timeoutを
# 経て報告された)バリアント数。report()/report2()/curl_report()は必ず
# 最後にrecord_summary()を呼ぶので、ここを唯一のカウント地点にできる。
# スクリプト末尾で「0件なら専用exitコード」の判定に使う(Opus5レビュー
# 指摘・2026-09-03 2巡目: 資格情報/venv不在で全スキップしてもexit 0に
# なっていた点への対応)。
# Count of variants that actually executed (went through run_with_timeout
# and got reported), as opposed to dry-run's description-only lines.
# report()/report2()/curl_report() always end by calling record_summary(),
# so this is the single counting point. Used at the end of the script to
# exit with a dedicated code if zero variants ran (per Opus 5 review round
# 2, 2026-09-03: previously exited 0 even when everything was skipped due
# to a missing credential/venv).
EXECUTED_COUNT=0
record_summary() {
  EXECUTED_COUNT=$((EXECUTED_COUNT + 1))
  # "|" 区切り。値(エラー本文の断片等)に "|" が混じっていると
  # write_out_file 側の `IFS='|' read` で列がずれる上、Markdown表の
  # セル内でも列区切りと誤認される。バックスラッシュエスケープは
  # `read` のIFS分割には効かない(バックスラッシュを解釈しない)ため、
  # 区切り文字と衝突しない別のUnicode文字(¦ U+00A6)に置き換える方式にする
  # (Opus5レビュー指摘・2026-09-03)。
  # Pipe-delimited. A stray "|" in a value (e.g. an error-text fragment)
  # would both misalign columns in write_out_file's `IFS='|' read` and be
  # misread as a column separator inside the Markdown table cell.
  # Backslash-escaping wouldn't help `read`'s IFS-based splitting (it
  # doesn't interpret escapes there), so instead substitute a different
  # Unicode character (¦ U+00A6) that never collides with the delimiter
  # (per Opus 5 review, 2026-09-03).
  local a="${1//|/¦}" b="${2//|/¦}" c="${3//|/¦}"
  SUMMARY_ROWS+=("$a|$b|$c")
}

write_out_file() {
  [ -z "$OUT_PATH" ] && return 0
  [ "$DRY_RUN" -eq 1 ] && return 0
  # macOS標準bash(3.2)は `set -u` 下で空配列の "${arr[@]}" 展開が
  # "unbound variable" の致命エラーになる(bash 4.4+では起きない)。
  # 未ガードだとこのエラーでスクリプトが停止し、しかもEXIT trap の cleanup()
  # が最後に成功終了するせいで最終的な $? が 0 に上書きされ、見た目は
  # 正常終了なのに壊れた(ヘッダだけの)ファイルが残る、という実測で発見した
  # 致命的な組み合わせだった。要素数を先に確認してから展開する。
  # macOS's stock bash (3.2) treats "${arr[@]}" on an empty array as a
  # fatal "unbound variable" under `set -u` (not an issue on bash 4.4+).
  # Left unguarded, that error would kill the script — and because the
  # EXIT trap's cleanup() then succeeds, the final $? gets overwritten back
  # to 0, so it looks like success while leaving a broken (header-only)
  # file behind. This exact combination was found by testing. Check the
  # element count before expanding.
  # 書き込み処理自体が既にサブシェル( ... )の中なので、SUMMARY_ROWSを
  # コピーせずそのまま参照して問題ない(コピーは大域変数を1つ増やすだけの
  # 無駄だった。Opus5レビュー指摘・2026-09-03 2巡目)。件数ガードは
  # bash 3.2のset -u対策として引き続き必要。
  # The write itself already runs inside a subshell ( ... ), so it's safe
  # to reference SUMMARY_ROWS directly without copying it first — the
  # earlier snapshot copy just added an unnecessary global variable (per
  # Opus 5 review round 2, 2026-09-03). The element-count guard is still
  # needed for the bash 3.2 `set -u` issue described above.
  #
  # OUT_PATH に既存ファイルが緩いパーミッション(例:0644)で存在していた場合、
  # ">"での上書きは中身だけ差し替えて既存のパーミッションビットをそのまま
  # 引き継ぐ(umaskは新規作成時にしか効かない)。mktempで0600の一時ファイルを
  # 同じディレクトリに作って書き込み、最後にmvで置き換えることで、既存の
  # パーミッションに関係なく確実に0600にする(Codexレビュー指摘・2026-09-03)。
  # mktempが作る一時ファイルは(ambient umaskに関係なく)既定で0600になる
  # ことを実機で確認済み。
  # If OUT_PATH already exists with loose permissions (e.g. 0644),
  # overwriting it via ">" only replaces the content and keeps the
  # existing permission bits (umask only applies to newly created files).
  # Write to a 0600 temp file in the same directory via mktemp, then mv it
  # into place, so the result is 0600 regardless of any pre-existing
  # permissions (per Codex review, 2026-09-03). Confirmed on this machine
  # that mktemp's own temp files default to 0600 regardless of the ambient
  # umask.
  local tmp_out
  if ! tmp_out=$(mktemp "${OUT_PATH}.XXXXXX" 2>/dev/null); then
    echo "ERROR: --out 先への書き込みに失敗しました(一時ファイルを作成できません): $OUT_PATH / Failed to write --out destination (could not create temp file): $OUT_PATH" >&2
    return 1
  fi
  if ! (
    {
      echo "# worker-provider-probe results"
      echo
      echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo
      echo "| Variant | Exit/Status | Detail |"
      echo "| --- | --- | --- |"
      if [ "${#SUMMARY_ROWS[@]}" -gt 0 ]; then
        local row name status detail
        for row in "${SUMMARY_ROWS[@]}"; do
          IFS='|' read -r name status detail <<< "$row"
          printf '| %s | %s | %s |\n' "$name" "$status" "$detail"
        done
      fi
    } > "$tmp_out"
  ); then
    rm -f "$tmp_out"
    echo "ERROR: --out 先への書き込みに失敗しました: $OUT_PATH / Failed to write --out destination: $OUT_PATH" >&2
    return 1
  fi
  if ! mv -f "$tmp_out" "$OUT_PATH"; then
    rm -f "$tmp_out"
    echo "ERROR: --out 先への書き込みに失敗しました(置き換えに失敗): $OUT_PATH / Failed to write --out destination (mv failed): $OUT_PATH" >&2
    return 1
  fi
  echo "Wrote summary table to: $OUT_PATH"
}

# sedの検索パターン用に正規表現メタ文字をエスケープし、リテラル文字列として
# 扱えるようにする（区切り文字に "/" を使うため "/" 自体もエスケープする）。
# Escape regex metacharacters (including "/", our sed delimiter) so a value
# can be embedded in a sed search pattern and matched literally.
sed_escape_literal() {
  printf '%s' "$1" | sed -e 's/[.[\*^$/]/\\&/g'
}

# 表示直前に必ず通す保険的な置換。3種類の置換を併用する:
#   (1) BEARER_TOKEN が非空なら、その値そのものをリテラル一致で置換
#       （sedで実装 — bashの ${s//$BEARER_TOKEN/...} はパターン部分が
#       シェルのglob展開ルールで解釈されるため、トークンに `*` `?` `[` 等の
#       glob特殊文字が含まれた場合に意図通り一致しない懸念があった。
#       Opus5レビュー指摘・2026-09-03で修正）。
#   (2) 値に依存しないパターン置換: Bedrock短期トークンは "bedrock-api-key-"
#       で始まる(aws-bedrock-token-generatorで生成したトークンで実測確認)。
#       G6のapiKeyHelperが都度生成するトークンは親(BEARER_TOKEN)が値を
#       知らないため(1)だけではno-opになる。そのケースを拾うための追加。
#   (3) AWSアクセスキーID形式(AKIA/ASIAで始まる20文字)も値非依存で置換する。
#       generate_token_from_profileが失敗した際のboto3の生トレースバックに
#       万一含まれても(通常AWS SDKは認証情報自体をエラーメッセージへ出さない
#       設計だが、断定はできないため保険として)拾えるようにする
#       (Codexレビュー指摘・2026-09-03)。シークレットアクセスキー自体は
#       固定の接頭辞が無く安全に正規表現化できないため対象外。
# Defense-in-depth substitution applied right before printing, combining:
#   (1) A literal match of BEARER_TOKEN's actual value, when non-empty
#       (implemented via sed rather than bash's ${s//$BEARER_TOKEN/...},
#       whose pattern side is interpreted using shell glob rules — a token
#       containing `*`/`?`/`[` could fail to match as intended; fixed per
#       Opus 5 review, 2026-09-03).
#   (2) A value-independent pattern match: short-term Bedrock tokens start
#       with "bedrock-api-key-" (confirmed by generating one via
#       aws-bedrock-token-generator). This covers G6's apiKeyHelper, whose
#       token the parent process never learns, so (1) alone would be a
#       no-op for it.
#   (3) A value-independent match for AWS access key ID format (20 chars
#       starting with AKIA/ASIA), in case one ever ended up in a raw boto3
#       traceback from a failed generate_token_from_profile call (AWS SDKs
#       are designed not to print credentials in error text, but this isn't
#       guaranteed, so it's covered as insurance per Codex review,
#       2026-09-03). The secret access key itself has no fixed prefix and
#       can't be safely pattern-matched, so it isn't covered here.
#
# 実装メモ: (1)は以前 `sed -e "s/${pattern}/.../"` のように、エスケープ済み
# パターンをsedの-e引数へ直接埋め込んでいたため、そのsedプロセス自身の
# 実行中はps等から引数として秘密の(エスケープ済みだが復元可能な)値が見える
# 短い時間があった。sedスクリプトを一時ファイル(600・$OUTDIR配下)に書き、
# `sed -f`で読ませる方式に変更し、コマンドライン引数には一切値を載せない
# (curlの-K設定ファイルと同じ考え方。Codexレビュー指摘・2026-09-03)。
# Implementation note: (1) used to embed the escaped pattern directly into
# sed's `-e` argument (`sed -e "s/${pattern}/.../"`, which meant the secret
# (escaped but recoverable) was briefly visible via `ps` etc. as that sed
# process's own argument. Changed to write the sed script to a 600-mode
# temp file under $OUTDIR and read it via `sed -f`, so no value ever
# appears as a command-line argument (same idea as curl's -K config file;
# per Codex review, 2026-09-03).
REDACT_SED_SCRIPT="$OUTDIR/.redact_pattern.sed"
redact() {
  local s="$1" pattern
  s=$(printf '%s' "$s" | sed -E 's/bedrock-api-key-[A-Za-z0-9_=-]+/[REDACTED]/g')
  s=$(printf '%s' "$s" | sed -E 's/(AKIA|ASIA)[A-Z0-9]{16}/[REDACTED]/g')
  if [ -n "${BEARER_TOKEN:-}" ]; then
    pattern=$(sed_escape_literal "$BEARER_TOKEN")
    printf 's/%s/[REDACTED]/g\n' "$pattern" > "$REDACT_SED_SCRIPT"
    s=$(printf '%s' "$s" | sed -f "$REDACT_SED_SCRIPT")
  fi
  printf '%s' "$s"
}

# --- Bedrock 資格情報 / リージョンの解決 ---
# --- Resolve Bedrock credential / region ---
# ~/.config/takumi009-ai-env/bedrock.env は今も bash -c のサブシェル内で
# source される(=シェルコードとして実行される)ことに変わりはない
# （信頼済みのローカル設定ファイルという前提）。以前のeval方式との違いは、
# その結果を「親シェルへどう持ち帰るか」だけ: 親は2つの一時ファイル(600)を
# catするだけでeval等の実行はしない。そのため、たとえsourceされた内容が
# 何か問題を起こしてもその影響範囲はサブシェル内に閉じ、親シェルのコードが
# その出力によって実行されることはない、という意味での安全性
# （「コード注入不可」は言い過ぎだったため訂正。Opus5レビュー指摘・2026-09-03）。
# ~/.config/takumi009-ai-env/bedrock.env is still sourced (i.e. executed as
# shell code) inside a bash -c subshell — that hasn't changed (it's treated
# as a trusted local config file). What changed from the earlier eval-based
# design is only how the result gets back to this parent shell: the parent
# just `cat`s two 600-mode temp files, it never evals anything. So even if
# something in the sourced file misbehaved, that stays confined to the
# subshell — the parent shell's own code is never executed as a result of
# that output. ("No code injection possible" was an overstatement; corrected
# per Opus 5 review, 2026-09-03.)
BEDROCK_ENV_FILE="$HOME/.config/takumi009-ai-env/bedrock.env"
FILE_BEARER_TOKEN=""
FILE_REGION=""
if [ -f "$BEDROCK_ENV_FILE" ]; then
  FILE_TOKEN_TMP="$OUTDIR/.file_bearer_token"
  FILE_REGION_TMP="$OUTDIR/.file_region"
  (
    umask 077
    bash -c '
      set -a
      source "$1" >/dev/null 2>&1
      printf "%s" "${AWS_BEARER_TOKEN_BEDROCK:-}" > "$2"
      printf "%s" "${AWS_REGION:-}" > "$3"
    ' _ "$BEDROCK_ENV_FILE" "$FILE_TOKEN_TMP" "$FILE_REGION_TMP" 2>/dev/null
  ) || true
  [ -f "$FILE_TOKEN_TMP" ] && FILE_BEARER_TOKEN=$(cat "$FILE_TOKEN_TMP" 2>/dev/null || true)
  [ -f "$FILE_REGION_TMP" ] && FILE_REGION=$(cat "$FILE_REGION_TMP" 2>/dev/null || true)
fi

BEARER_TOKEN=""
BEARER_TOKEN_SOURCE="none"
if [ -n "${AWS_BEARER_TOKEN_BEDROCK:-}" ]; then
  BEARER_TOKEN="$AWS_BEARER_TOKEN_BEDROCK"
  BEARER_TOKEN_SOURCE="env"
elif [ -n "$FILE_BEARER_TOKEN" ]; then
  BEARER_TOKEN="$FILE_BEARER_TOKEN"
  BEARER_TOKEN_SOURCE="file"
fi
# 呼び出し元のシェルにあった生の AWS_BEARER_TOKEN_BEDROCK は、値を BEARER_TOKEN へ
# 取り込んだ後は不要。以降に起動する curl/claude 子プロセスへこの変数自体が
# (ヘッダとは別経路で) 継承されて `ps e` 等で見えてしまわないよう、ここで
# unset する(Codexレビュー指摘・2026-09-03)。
# The raw AWS_BEARER_TOKEN_BEDROCK from the caller's shell is no longer
# needed once its value is captured into BEARER_TOKEN. Unset it here so it
# is not inherited (via `ps e` or /proc/PID/environ) by any curl/claude
# child process spawned below, independent of the header-based path
# (per Codex review, 2026-09-03).
unset AWS_BEARER_TOKEN_BEDROCK 2>/dev/null || true

REGION="us-east-1"
if [ -n "${AWS_REGION:-}" ]; then
  REGION="$AWS_REGION"
elif [ -n "$FILE_REGION" ]; then
  REGION="$FILE_REGION"
fi

# 既定は au.（Geo prefix はソース Region に対応するものが必須。サブ機は
# AU〈AWS Region ap-southeast-2 / Sydney〉のため au. を既定にする。他
# Region で実行する場合は --model で us./eu./global. を明示指定すること。
# 一次情報: https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-sonnet-5.html
# （Programmatic Access 表・Regional Availability 表。ap-southeast-2 は
# Geo(au.)/Global のみ利用可・In-Region 不可。2026-09-04 本人実測+裏取り）。
# Default is au. — the Geo prefix must match the source region. The worker
# machine is in AU (AWS region ap-southeast-2 / Sydney), so au. is the
# default here. Pass --model explicitly (us./eu./global.) when running from
# a different region. Source: AWS's official model card page above
# (Programmatic Access / Regional Availability tables; ap-southeast-2 only
# supports Geo(au.)/Global, not In-Region; verified 2026-09-04).
MODEL_ID="au.anthropic.claude-sonnet-5"
if [ -n "$CLI_MODEL" ]; then
  MODEL_ID="$CLI_MODEL"
elif [ -n "${ANTHROPIC_DEFAULT_SONNET_MODEL:-}" ]; then
  MODEL_ID="$ANTHROPIC_DEFAULT_SONNET_MODEL"
fi

BEDROCK_RUNTIME_BASE="https://bedrock-runtime.${REGION}.amazonaws.com/anthropic"
BEDROCK_RUNTIME_MSG_URL="${BEDROCK_RUNTIME_BASE}/v1/messages"
BEDROCK_MANTLE_BASE="https://bedrock-mantle.${REGION}.api.aws/anthropic"
MANTLE_MODEL_ID="anthropic.claude-sonnet-5"

# curl の認証ヘッダは -K の設定ファイル経由で渡す（コマンドライン引数に
# 値を載せない）。umask 077 のサブシェルで作成し、パーミッションは 600。
# 関数化しているのは、--token-from-profile でこの後 BEARER_TOKEN が
# (最初は空 → プロファイルから生成後の値へ)更新された際に作り直せるようにするため。
# Pass curl's auth header via a -K config file (never as a CLI argument).
# Created inside a umask-077 subshell so the resulting file is mode 600.
# Factored into a function so it can be re-run after --token-from-profile
# fills in BEARER_TOKEN later (it starts out empty at this point when that
# flag is used).
CFG_XAPIKEY="$OUTDIR/hdr_xapikey.cfg"
CFG_BEARER="$OUTDIR/hdr_bearer.cfg"
# curlの -K 設定ファイルで二重引用符内の値は \\ \" \t \n \r \v をエスケープ
# シーケンスとして解釈する(curlのマニュアル記載)。トークンにバックスラッシュや
# 二重引用符が万一含まれても文字化けしないよう、埋め込み前に自前でエスケープする。
# Opus5レビューでは「非引用形式にすればエスケープ依存を無くせる」との指摘が
# あったが、実機のcurl 8.7.1で検証したところ、非引用形式では
# `header = x-api-key: TOKEN` の値がヘッダとして一切送信されない(httpbinで
# 実測: ヘッダが消える)ため不採用とし、引用形式を維持のうえエスケープで
# 対応する（却下理由として報告・最終採否はリーダー）。
# curl's -K config file interprets \\ \" \t \n \r \v as escape sequences
# inside double-quoted values (per curl's manual). Escape the token
# ourselves before embedding it so a literal backslash or double-quote
# (however unlikely in practice) can't corrupt it. The Opus 5 review
# suggested switching to the unquoted form to avoid depending on this
# escaping at all, but testing against real curl 8.7.1 showed the
# unquoted form silently drops the header entirely (confirmed against
# httpbin.org — no header arrives at all), so that alternative was
# rejected in favor of keeping quotes and escaping (flagged for the
# team lead to make the final call).
curl_cfg_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}
write_curl_auth_configs() {
  if [ -n "$BEARER_TOKEN" ]; then
    local escaped
    escaped=$(curl_cfg_escape "$BEARER_TOKEN")
    ( umask 077; printf 'header = "x-api-key: %s"\n' "$escaped" > "$CFG_XAPIKEY" )
    ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$escaped" > "$CFG_BEARER" )
  fi
}
write_curl_auth_configs

REQ_BODY=$(jq -n --arg model "$MODEL_ID" --arg prompt "$PROMPT" \
  '{model:$model, max_tokens:8, messages:[{role:"user", content:$prompt}]}')
COUNT_BODY=$(jq -n --arg model "$MODEL_ID" --arg prompt "$PROMPT" \
  '{model:$model, messages:[{role:"user", content:$prompt}]}')

# --- F4/F5/F6用: metadata.user_idの固定ダミー値 ---
# --- For F4/F5/F6: fixed dummy values for metadata.user_id ---
# 実在のdevice/account/sessionではない、構造だけを模したプレースホルダ
# （毎回同じ固定値。Claude Code自体がbodyへ組み込むuser_idの実際の形式は
# 未確認のため、F5は「英数・アンダースコア・ハイフンのみの長い値」という
# 仮説形状、F6は「値自体がJSON文字列」という別仮説を検証する）。
# Not a real device/account/session — a structural placeholder only (always
# the same fixed value). The actual shape of the user_id Claude Code itself
# embeds is unconfirmed, so F5 probes the hypothesis "a long value using
# only alnum/underscore/hyphen", and F6 probes the separate hypothesis "the
# value itself is a JSON string".
DUMMY_DEVICE_HEX="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
DUMMY_ACCOUNT_UUID="12345678-90ab-cdef-1234-567890abcdef"
DUMMY_SESSION_UUID="abcdef12-3456-7890-abcd-ef1234567890"
F5_METADATA_USER_ID="user_${DUMMY_DEVICE_HEX}_account_${DUMMY_ACCOUNT_UUID}_session_${DUMMY_SESSION_UUID}"
F6_METADATA_USER_ID=$(jq -nc --arg d "$DUMMY_DEVICE_HEX" --arg a "$DUMMY_ACCOUNT_UUID" --arg s "$DUMMY_SESSION_UUID" \
  '{device_id:$d, account_uuid:$a, session_id:$s}')

REQ_BODY_F4=$(jq -n --arg model "$MODEL_ID" --arg prompt "$PROMPT" --arg uid "probe-user" \
  '{model:$model, max_tokens:8, messages:[{role:"user", content:$prompt}], metadata:{user_id:$uid}}')
REQ_BODY_F5=$(jq -n --arg model "$MODEL_ID" --arg prompt "$PROMPT" --arg uid "$F5_METADATA_USER_ID" \
  '{model:$model, max_tokens:8, messages:[{role:"user", content:$prompt}], metadata:{user_id:$uid}}')
REQ_BODY_F6=$(jq -n --arg model "$MODEL_ID" --arg prompt "$PROMPT" --arg uid "$F6_METADATA_USER_ID" \
  '{model:$model, max_tokens:8, messages:[{role:"user", content:$prompt}], metadata:{user_id:$uid}}')

# --- --token-from-profile / G6 用: aws-bedrock-token-generator (venv) ---
# --- For --token-from-profile / G6: aws-bedrock-token-generator (venv) ---
# 本人裁定(2026-09-03): Bedrock資格情報はプロファイル(アクセスキー+シークレット)の
# ままとし、Bedrock APIキーは発行しない。ベアラートークンは AWS公式の
# aws-bedrock-token-generator (presigned URL方式・追加IAM権限不要) で
# プロファイルから自機生成する。一次情報:
# https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys.html
# (Generate a short-term API key > Python)
# https://github.com/aws/aws-bedrock-token-generator-python/blob/main/README.md
# (provide_token(region=..., expiry=..., aws_credentials_provider=...);
# region省略時はAWS_REGION、expiry省略時は既定1時間・最大12時間、
# プロファイル選択はboto3標準のクレデンシャルチェーン=AWS_PROFILE環境変数)。
# 「読み取り専用」の原則により、venv/モジュールが無くても自動インストールはせず、
# セットアップ手順を表示してこのバリアント(群)だけをスキップ/エラーにする。
# Per the 2026-09-03 decision: Bedrock credentials stay a profile
# (access key + secret), no Bedrock API key is issued. The bearer token is
# instead generated locally from that profile via AWS's own
# aws-bedrock-token-generator (presigned-URL based, no extra IAM permission
# needed). Sources verified via WebFetch above. Per the read-only principle,
# a missing venv/module is never auto-installed — we print setup
# instructions and skip/fail only the affected variant(s).
TOKEN_VENV_PY=""
resolve_token_venv_python() {
  # 戻り値 / return codes: 0=OK, 2=venv(python)が無い, 3=モジュール未インストール
  # 0=OK, 2=venv/python missing, 3=module not installed
  TOKEN_VENV_PY="$TOKEN_VENV/bin/python3"
  [ -x "$TOKEN_VENV_PY" ] || TOKEN_VENV_PY="$TOKEN_VENV/bin/python"
  if [ ! -x "$TOKEN_VENV_PY" ]; then
    return 2
  fi
  if ! "$TOKEN_VENV_PY" -c "import aws_bedrock_token_generator" >/dev/null 2>/dev/null; then
    return 3
  fi
  return 0
}
print_token_venv_setup_instructions() {
  echo "  python3 -m venv $TOKEN_VENV"
  echo "  $TOKEN_VENV/bin/pip install aws-bedrock-token-generator"
}

TOKEN_GEN_ERR=""
TOKEN_GEN_ERRFILE="$OUTDIR/token_gen.stderr"
# boto3 の資格情報解決(SSO/credential_process/IMDS等)は、設定によっては
# ネットワーク応答待ちで無期限にハングしうる。EC2以外でも環境変数は無害な
# ため常に設定し、IMDSの再試行を1回・1秒でタイムアウトさせる
# (Opus5レビュー指摘・2026-09-03)。それでも他の経路(SSOブラウザ認証待ち等)は
# ハングし得るため、下の token_gen_worker 自体も run_with_timeout の
# プロセスグループkillで必ず打ち切る(F/G/Hの他バリアントと同じ90秒)。
# boto3's credential resolution (SSO/credential_process/IMDS, etc.) can hang
# indefinitely waiting on a network response depending on configuration.
# These env vars are harmless even off EC2, so set them unconditionally to
# cap IMDS retries to 1 attempt / 1s (per Opus 5 review, 2026-09-03). Other
# hang sources (e.g. a browser-based SSO prompt) are still possible, so
# token_gen_worker itself is also always run through run_with_timeout's
# process-group kill (same 90s as every other F/G/H variant).
token_gen_worker() {
  local profile="$1" region="$2"
  env AWS_PROFILE="$profile" \
      AWS_METADATA_SERVICE_TIMEOUT=1 \
      AWS_METADATA_SERVICE_NUM_ATTEMPTS=1 \
      "$TOKEN_VENV_PY" -c '
import sys
from aws_bedrock_token_generator import provide_token
sys.stdout.write(provide_token(region=sys.argv[1]))
' "$region" 2>"$TOKEN_GEN_ERRFILE"
}

# BEARER_TOKEN / BEARER_TOKEN_SOURCE (グローバル)を書き換える。
# resolve_token_venv_python を先に呼び、rc=0 であることを確認してから呼ぶこと。
# Mutates the globals BEARER_TOKEN / BEARER_TOKEN_SOURCE. Call
# resolve_token_venv_python first and only proceed on rc=0.
generate_token_from_profile() {
  local profile="$1" region="$2" tokenfile out
  tokenfile="$OUTDIR/token_gen.stdout"
  run_with_timeout "$tokenfile" token_gen_worker "$profile" "$region"
  out=$(cat "$tokenfile" 2>/dev/null || true)
  if [ "$LAST_TIMED_OUT" -eq 1 ]; then
    TOKEN_GEN_ERR="${TIMEOUT_SECS}秒でタイムアウトしました(SSO/credential_process/IMDS等でハングした可能性) / timed out after ${TIMEOUT_SECS}s (possibly hung on SSO/credential_process/IMDS)"
    return 1
  fi
  if [ "$LAST_RC" -ne 0 ] || [ -z "$out" ]; then
    local snippet
    # stderr にはトークンそのものは含まれない想定だが、万一SigV4署名の断片等が
    # 混ざっても影響を抑えるため120文字に切り詰め、redact()も通す。
    # stderr should never contain the token itself, but truncate to 120
    # chars and pass through redact() anyway in case a SigV4 signature
    # fragment or similar ever leaked into a botocore error message.
    snippet=$( (head -c 200 "$TOKEN_GEN_ERRFILE" | tr '\n\r\t' '   ' | cut -c1-120) 2>/dev/null || true )
    snippet=$(redact "$snippet")
    TOKEN_GEN_ERR="${snippet:-(no details / 詳細不明)}"
    return 1
  fi
  BEARER_TOKEN="$out"
  BEARER_TOKEN_SOURCE="profile:$profile"
  return 0
}

F1_STATUS=""
F2_STATUS=""
choose_f3_header() {
  case "$F1_STATUS" in
    2??) echo "xapikey"; return 0 ;;
  esac
  case "$F2_STATUS" in
    2??) echo "bearer"; return 0 ;;
  esac
  # どちらも通っていなければ x-api-key を既定にフォールバック(結果は
  # ステータスコードとしてそのまま記録されるので、成功を偽装しない)。
  # Fall back to x-api-key when neither succeeded (the actual status code
  # is still recorded as-is, so this never fakes a success).
  echo "xapikey"
}

# --- curl バリアント用の実行・レポート ---
# --- Execution/reporting for curl-based variants ---
curl_report() {
  local name="$1" desc="$2" statusfile="$3" bodyfile="$4" errfile="$5" rc="$6" timed_out="$7"
  local status snippet timeout_tag success_filter

  # 全てのコマンド置換代入を `|| true` で保護する: `set -euo pipefail` 下では
  # 素の `var=$(cmd)` はcmd失敗時にスクリプト全体を落とす(local変数宣言と違い
  # 保護されない)。不正/空のレスポンス本文でjqが非0終了しても、この1変種の
  # レポートを "?" にするだけで他の変種の実行を止めないようにする。
  # Guard every command-substitution assignment with `|| true`: under
  # `set -euo pipefail`, a bare `var=$(cmd)` (unlike a `local var=$(cmd)`
  # declaration) kills the whole script if cmd fails. A malformed/empty
  # response body making jq exit non-zero should only degrade this one
  # variant's report to "?", not abort every remaining variant.
  status=$( (tr -d '[:space:]' < "$statusfile") 2>/dev/null || true )
  [ -z "$status" ] && status="?"

  # F3 (count_tokens) の成功レスポンスは .content ではなく .input_tokens を返す。
  # F1/F2 (messages) は .content[0].text。
  # どちらも「期待するフィールドが無ければ empty」を返す形にして、
  # 2xxなのに期待外の本文(例: bedrock-runtimeにcount_tokensを投げた際の
  # UnknownOperationException)だった場合に "(no expected field in response)"
  # へ正しくフォールバックさせる(実測で発見: bedrock-runtime の
  # /anthropic/v1/messages/count_tokens は 200 + UnknownOperationException を
  # 返す=count_tokensはbedrock-mantle専用というAWS公式記載と整合)。
  # F3's (count_tokens) success response has .input_tokens, not .content;
  # F1/F2 (messages) have .content[0].text. Both filters yield empty when the
  # expected field is absent, so a 2xx response with an unexpected body
  # (e.g. the UnknownOperationException that bedrock-runtime returns for
  # count_tokens — confirmed empirically, consistent with AWS's docs saying
  # count_tokens is bedrock-mantle-only) correctly falls back to
  # "(no expected field in response)" instead of masking the anomaly.
  case "$name" in
    F3*) success_filter='if (.input_tokens? != null) then ("input_tokens=" + (.input_tokens|tostring)) else empty end' ;;
    *)   success_filter='.content[0].text? // empty' ;;
  esac

  case "$status" in
    2??)
      snippet=$( (jq -r "$success_filter" "$bodyfile" 2>/dev/null) || true )
      [ -z "$snippet" ] && snippet="(no expected field in response)"
      ;;
    *)
      snippet=$( (head -c 200 "$bodyfile") 2>/dev/null || true )
      if [ -z "$snippet" ] && [ -f "$errfile" ]; then
        snippet=$( (head -c 200 "$errfile") 2>/dev/null || true )
      fi
      ;;
  esac
  snippet=$( (printf '%s' "$snippet" | tr '\n\r\t' '   ' | cut -c1-120) || true )
  snippet=$(redact "$snippet")
  [ -z "$snippet" ] && snippet="-"

  timeout_tag="no"
  [ "$timed_out" -eq 1 ] && timeout_tag="yes(124)"

  case "$name" in
    F1*) F1_STATUS="$status" ;;
    F2*) F2_STATUS="$status" ;;
  esac

  printf '%-26s %-46s status=%-5s exit=%-5s timeout=%-9s msg=%s\n' \
    "$name" "$desc" "$status" "$rc" "$timeout_tag" "$snippet"

  record_summary "$name" "status=$status" "$desc msg=$snippet timeout=$timeout_tag"
}

run_curl_variant() {
  local name="$1" desc="$2" bodyfile="$3" errfile="$4"
  shift 4
  local statusfile="$OUTDIR/$(echo "$name" | tr -c 'A-Za-z0-9' '_').status"
  run_with_timeout "$statusfile" "$@"
  curl_report "$name" "$desc" "$statusfile" "$bodyfile" "$errfile" "$LAST_RC" "$LAST_TIMED_OUT"
}

# --- claude -p バリアント(G/H)用の拡張レポート ---
# --- Extended reporting for claude -p variants (G/H) ---
# report() と同じ抽出方式を再利用しつつ、tools(使用ツール名)と、
# 何も stream-json イベントが得られなかった場合の生ログ先頭120文字を追加する。
# A〜E 用の report() 自体には触れない(そちらの出力形式・挙動は変えない)。
# Reuses the same extraction approach as report(), adding a tools column
# (which tool names were used) and, when no stream-json event parsed at
# all, the first 120 chars of the raw log. report() itself (used by A-E)
# is untouched.
report2() {
  local name="$1" outfile="$2" rc="$3" timed_out="$4"
  local model apikey provider result_text tools timeout_tag raw_snippet

  model=$(parse_field "$outfile" '[.[] | select(.type=="system" and .subtype=="init")][0].model // "?"')
  apikey=$(parse_field "$outfile" '[.[] | select(.type=="system" and .subtype=="init")][0].apiKeySource // "?"')
  provider=$(parse_field "$outfile" '(([.[] | select(.type=="result")][0].modelUsage // {}) | to_entries[0].value.provider) // "?"')
  result_text=$(parse_field "$outfile" '[.[] | select(.type=="result")][0].result // "?"')
  tools=$(parse_field "$outfile" '[.[] | select(.type=="assistant") | .message.content[]? | select(.type=="tool_use") | .name] | unique | join(",")')

  result_text=$(redact "$result_text")

  # 生ログの末尾120文字を、rc!=0 か result が取れなかった場合に必ず出す
  # (init/model等は取れたが途中で失敗し result だけ"?"、というケースでも
  # 原因が完全に失われないようにする。以前は3項目全部が"?"の時だけ表示していた)。
  # 先頭ではなく末尾を見るのは、initイベント取得後に失敗したケースでは
  # 先頭がずっと正常なsystem/initのJSONで埋まっており、実際のエラーは
  # ログの末尾側にあることが多いため(Codexレビュー指摘・2026-09-03)。
  # Always surface the last 120 raw chars when rc!=0 or the result text is
  # missing (not only when model/apikey/result are ALL "?" as before), so a
  # mid-run failure after a successful init doesn't lose all diagnostic info.
  # Tail rather than head: when failure happens after a successful init
  # event, the start of the log is normal system/init JSON, and the actual
  # error tends to be near the end (per Codex review, 2026-09-03).
  raw_snippet="-"
  if [ "$rc" != "0" ] || [ "$result_text" = "?" ]; then
    raw_snippet=$( (tail -c 500 "$outfile" | tr '\n\r\t' '   ' | tail -c 120) 2>/dev/null || true )
    raw_snippet=$(redact "$raw_snippet")
    [ -z "$raw_snippet" ] && raw_snippet="-"
  fi

  timeout_tag="no"
  [ "$timed_out" -eq 1 ] && timeout_tag="yes(124)"

  printf '%-26s model=%-24s apiKeySource=%-14s provider=%-10s tools=%-12s result=%-10s exit=%-5s timeout=%-9s err=%s\n' \
    "$name" "$model" "$apikey" "$provider" "$tools" "$result_text" "$rc" "$timeout_tag" "$raw_snippet"

  record_summary "$name" "exit=$rc" "model=$model apiKeySource=$apikey provider=$provider tools=$tools result=$result_text timeout=$timeout_tag err=$raw_snippet"
}

run_variant_ext() {
  local reportfn="$1" name="$2"
  shift 2
  local outfile="$OUTDIR/$(echo "$name" | tr -c 'A-Za-z0-9' '_').json"
  run_with_timeout "$outfile" "$@"
  "$reportfn" "$name" "$outfile" "$LAST_RC" "$LAST_TIMED_OUT"
}

# --- バリアント選択 / dry-run 表示 ---
# --- Variant selection / dry-run display ---
should_run() {
  local name="$1" list
  if [ -n "$ONLY_LIST" ]; then
    list="$ONLY_LIST"
  else
    list="$DEFAULT_VARIANTS"
    if [ "$DO_MANTLE" -eq 1 ]; then
      list="$list G5"
    fi
    if [ "$DO_HELPER" -eq 1 ]; then
      list="$list G6"
    fi
    if [ "$DO_WEBSEARCH" -eq 1 ]; then
      list="$list H1"
    fi
  fi
  case " $list " in
    *" $name "*) return 0 ;;
    *) return 1 ;;
  esac
}

# --dry-run の場合は実行せず説明を1行出す(戻り値0)。
# 実行が必要な場合は何も出さず戻り値1を返す(呼び出し側が本処理を続ける)。
# In --dry-run mode, print a one-line description instead of running
# (returns 0). Otherwise print nothing and return 1 (caller proceeds).
maybe_dry_run_or() {
  local name="$1" desc="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] %-6s %s\n' "$name" "$desc"
    return 0
  fi
  return 1
}

# F/G/H は資格情報が無くても --dry-run なら説明だけ表示する。
# F/G/H proceed without a credential only in --dry-run mode (description only).
can_execute_fg() {
  [ "$DRY_RUN" -eq 1 ] && return 0
  [ -n "$BEARER_TOKEN" ]
}

# G6 は BEARER_TOKEN ではなく apiKeyHelper が都度プロファイルから生成する方式
# なので、can_execute_fg ではなく venv/モジュールの有無だけを見る。
# G6 doesn't rely on BEARER_TOKEN — its apiKeyHelper generates a token from
# the profile on each invocation — so it only needs the venv/module present,
# not can_execute_fg's BEARER_TOKEN check.
can_execute_g6() {
  [ "$DRY_RUN" -eq 1 ] && return 0
  resolve_token_venv_python
}

# X1 は BEARER_TOKEN も AWS も一切使わない(127.0.0.1のローカルサーバーへ
# claude -pを向けるだけ)ため、python3の有無だけを見る。
# X1 never uses BEARER_TOKEN or AWS at all (it just points `claude -p` at a
# local 127.0.0.1 server), so it only needs python3 to be present.
can_execute_x1() {
  [ "$DRY_RUN" -eq 1 ] && return 0
  command -v python3 >/dev/null 2>&1
}

echo "=== 関連env変数の有無（名前のみ・値は非表示） / relevant env vars presence (names only, no values) ==="
# 注意: AWS_BEARER_TOKEN_BEDROCK はこの時点で既に unset 済み(子プロセスへ
# 継承させないため、値をBEARER_TOKENへ取り込んだ直後にunsetしている)。
# そのため上のループには含めず、代わりに次行の「由来」(env/file/none)で
# 起動時点の状態を報告する(unset後の"unset"表示による誤解を防ぐ)。
# Note: AWS_BEARER_TOKEN_BEDROCK has already been unset by this point (to
# avoid inheriting it into child processes, right after its value was
# captured into BEARER_TOKEN). It is therefore excluded from the loop below;
# the "由来"(source: env/file/none) line after it reports the state at
# invocation time instead, avoiding a misleading post-unset "unset" reading.
for v in CLAUDE_CODE_USE_BEDROCK AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION \
         ANTHROPIC_API_KEY ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL \
         ANTHROPIC_DEFAULT_HAIKU_MODEL; do
  # ${!v+x} は「変数が定義されているか」（空文字での定義も含む）を、値を
  # 展開せずに判定する。${!v:-} だと空文字定義を unset と誤判定するため使わない。
  # ${!v+x} tests whether the var is defined (even if empty) without
  # expanding its value; ${!v:-} would misreport an empty-but-set var as unset.
  if [ "${!v+x}" = "x" ]; then
    echo "  $v: set"
  else
    echo "  $v: unset"
  fi
done
# 「由来」はここでは出さない: --token-from-profile はこのブロックより後
# (F/G/H実行直前)で解決されるため、ここで表示すると成功時も常に "none" と
# 誤表示してしまう(実測で発見)。正しい最終的な由来は後段(F/G/Hセクション)で
# 別途表示する。region/model はこの後変わらないのでここでも正確。
# The "source" is deliberately not printed here: --token-from-profile is
# resolved later (right before the F/G/H section), so printing it here
# would always show "none" even on success (found by testing). The
# accurate final source is printed again later, right before F/G/H. region
# and model don't change after this point, so those are accurate here.
echo "  AWS_BEARER_TOKEN_BEDROCK: (取得後に unset 済み / unset after capture) region=$REGION model=$MODEL_ID"

echo
echo "=== claude -p provider probe (EXP-3, 5 variants, timeout ${TIMEOUT_SECS}s each) ==="

COMMON_ARGS=(-p "$PROMPT" --output-format stream-json --verbose --allowedTools "" --permission-mode plan)

if should_run "A"; then
  if ! maybe_dry_run_or "A" "claude ${COMMON_ARGS[*]}"; then
    run_variant "A: plain inheritance" \
      claude "${COMMON_ARGS[@]}"
  fi
fi

if should_run "B"; then
  if ! maybe_dry_run_or "B" "unset: CLAUDE_CODE_USE_BEDROCK,AWS_PROFILE,AWS_REGION / claude ${COMMON_ARGS[*]}"; then
    run_variant "B: env -u removal" \
      env -u CLAUDE_CODE_USE_BEDROCK -u AWS_PROFILE -u AWS_REGION \
      claude "${COMMON_ARGS[@]}"
  fi
fi

if should_run "C"; then
  if ! maybe_dry_run_or "C" "claude ${COMMON_ARGS[*]} --settings '{\"env\":{\"CLAUDE_CODE_USE_BEDROCK\":\"0\"}}'"; then
    run_variant "C: --settings \"0\"" \
      claude "${COMMON_ARGS[@]}" --settings '{"env":{"CLAUDE_CODE_USE_BEDROCK":"0"}}'
  fi
fi

if should_run "D"; then
  if ! maybe_dry_run_or "D" "claude ${COMMON_ARGS[*]} --settings '{\"env\":{\"CLAUDE_CODE_USE_BEDROCK\":\"\"}}'"; then
    run_variant "D: --settings \"\"" \
      claude "${COMMON_ARGS[@]}" --settings '{"env":{"CLAUDE_CODE_USE_BEDROCK":""}}'
  fi
fi

if should_run "E"; then
  if ! maybe_dry_run_or "E" "unset: CLAUDE_CODE_USE_BEDROCK,AWS_PROFILE,AWS_REGION / claude ${COMMON_ARGS[*]} --settings '{\"env\":{\"CLAUDE_CODE_USE_BEDROCK\":\"0\"}}'"; then
    run_variant "E: B + C combined" \
      env -u CLAUDE_CODE_USE_BEDROCK -u AWS_PROFILE -u AWS_REGION \
      claude "${COMMON_ARGS[@]}" --settings '{"env":{"CLAUDE_CODE_USE_BEDROCK":"0"}}'
  fi
fi

echo
echo "=== Bedrock via ANTHROPIC_BASE_URL probe (EXP-1, timeout ${TIMEOUT_SECS}s each) ==="

# G6 は BEARER_TOKEN を使わない(apiKeyHelperが都度プロファイルから生成する)ため、
# 「BEARER_TOKENが要る変種が選ばれているか」はG6を除いて別途判定する。これを
# --token-from-profile の実行判定とSKIPメッセージの両方で使う(G6だけを選んだ
# 実行で、無駄にトークン生成を試みたり、実際は動くG6を指して「F/G/Hをskip」と
# 誤表示したりしないため)。
# G6 doesn't use BEARER_TOKEN (its apiKeyHelper generates one from the
# profile on each invocation), so "is a BEARER_TOKEN-dependent variant
# selected" is tracked separately, excluding G6. Used both to gate the
# --token-from-profile attempt and the SKIP message below, so that
# selecting only G6 doesn't needlessly attempt token generation or
# misleadingly claim "F/G/H skipped" while G6 actually runs.
ANY_TOKEN_DEPENDENT_SELECTED=0
for v in F1 F2 F3 F4 F5 F6 G1 G2 G3 G4 G5 G7 G8 H1; do
  if should_run "$v"; then
    ANY_TOKEN_DEPENDENT_SELECTED=1
    break
  fi
done

# --token-from-profile: AWS_BEARER_TOKEN_BEDROCK が(envにもbedrock.envにも)
# 見つからなかった場合のみ、プロファイルから短期トークンを自機生成して
# BEARER_TOKEN を埋める。ANY_TOKEN_DEPENDENT_SELECTED を条件にしているのは、
# それらを1つも選んでいない実行(例: --only A --token-from-profile、または
# --only G6 --token-from-profile)で無駄にvenvを要求してエラー終了させない
# ため。「自動インストールしない」原則により、venv/モジュールが無ければ
# セットアップ手順を表示してexit 1する。
# --token-from-profile: only when AWS_BEARER_TOKEN_BEDROCK was not found
# (neither in env nor bedrock.env), generate a short-term token locally
# from the profile to fill BEARER_TOKEN. Gated on
# ANY_TOKEN_DEPENDENT_SELECTED so a run that selects none of them (e.g.
# --only A --token-from-profile, or --only G6 --token-from-profile) doesn't
# needlessly demand a venv and fail. Per the "never auto-install"
# principle, a missing venv/module prints setup instructions and exits 1.
if [ "$TOKEN_FROM_PROFILE" -eq 1 ] && [ -z "$BEARER_TOKEN" ] && [ "$ANY_TOKEN_DEPENDENT_SELECTED" -eq 1 ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    # resolve_token_venv_python はファイル存在チェックのみ(pythonは実行しない)
    # なので dry-run でも安全に呼べる。実際に使われる解決結果
    # (bin/python3 が無ければ bin/python にフォールバック)をそのまま表示に使う
    # (以前は bin/python3 を決め打ち表示していた。Opus5レビュー指摘・2026-09-03)。
    # resolve_token_venv_python only checks file existence (never executes
    # python), so it's safe to call even in dry-run. Use its actual
    # resolution (falls back to bin/python if bin/python3 is missing) in
    # the displayed command instead of hardcoding bin/python3 (per Opus 5
    # review, 2026-09-03).
    resolve_token_venv_python || true
    echo "[dry-run] token   would run: env AWS_PROFILE='$PROFILE_NAME' $TOKEN_VENV_PY -c 'provide_token(region=\"$REGION\")' (aws-bedrock-token-generator)"
  else
    # `resolve_token_venv_python` を裸の文として呼ぶと、`set -e` 下では
    # 非0終了時にこの行で即座にスクリプトが落ち、直後の `vrc=$?` にも
    # エラーメッセージ表示にも到達しない(実測で発見)。`|| vrc=$?` で
    # 明示的に受け止める。
    # Calling `resolve_token_venv_python` as a bare statement would, under
    # `set -e`, abort the script right here on a non-zero exit — before
    # `vrc=$?` or the error message below ever run (found by testing).
    # Catch it explicitly with `|| vrc=$?` instead.
    vrc=0
    resolve_token_venv_python || vrc=$?
    if [ "$vrc" -ne 0 ]; then
      if [ "$vrc" -eq 2 ]; then
        echo "ERROR: venv が見つかりません: $TOKEN_VENV / venv not found: $TOKEN_VENV" >&2
      else
        echo "ERROR: aws-bedrock-token-generator が $TOKEN_VENV にインストールされていません / not installed in $TOKEN_VENV" >&2
      fi
      echo "セットアップ / setup:" >&2
      print_token_venv_setup_instructions >&2
      exit 1
    fi
    if ! generate_token_from_profile "$PROFILE_NAME" "$REGION"; then
      echo "ERROR: プロファイル '$PROFILE_NAME' からのトークン生成に失敗しました: $TOKEN_GEN_ERR" >&2
      echo "ERROR: token generation from profile '$PROFILE_NAME' failed: $TOKEN_GEN_ERR" >&2
      exit 1
    fi
    echo "プロファイル '$PROFILE_NAME' から短期Bedrockトークンを生成しました(region=$REGION, 既定1時間有効) / Generated a short-term Bedrock token from profile '$PROFILE_NAME' (region=$REGION, default 1h validity)"
    # BEARER_TOKEN が(空 → 実値へ)変わったので curl用の -K 設定ファイルを作り直す。
    # BEARER_TOKEN changed (empty -> real value); rebuild curl's -K config files.
    write_curl_auth_configs
  fi
fi

if [ "$DRY_RUN" -eq 0 ]; then
  echo "  AWS_BEARER_TOKEN_BEDROCK 由来(最終) / final source: $BEARER_TOKEN_SOURCE"
fi

if [ "$ANY_TOKEN_DEPENDENT_SELECTED" -eq 1 ] && [ "$DRY_RUN" -eq 0 ] && [ -z "$BEARER_TOKEN" ]; then
  echo "SKIP F1-F3,F4-F6/G1-G5,G7-G8/H1: AWS_BEARER_TOKEN_BEDROCK が見つかりません(環境変数・${BEDROCK_ENV_FILE}・--token-from-profileのいずれからも取得できませんでした。G6・X1のみを選んだ場合はこのメッセージが出ても正常です)。 / Skipping F1-F3,F4-F6/G1-G5,G7-G8/H1: AWS_BEARER_TOKEN_BEDROCK could not be obtained (from env, ${BEDROCK_ENV_FILE}, or --token-from-profile). This message is expected/harmless if you only selected G6 and/or X1."
fi

CURL_BODY_F1="$OUTDIR/body_F1.json"
CURL_BODY_F2="$OUTDIR/body_F2.json"
CURL_BODY_F3="$OUTDIR/body_F3.json"
CURL_ERR_F1="$OUTDIR/f1.stderr"
CURL_ERR_F2="$OUTDIR/f2.stderr"
CURL_ERR_F3="$OUTDIR/f3.stderr"

variant_F1() {
  curl -sS --max-time 60 --connect-timeout 15 -K "$CFG_XAPIKEY" -X POST "$BEDROCK_RUNTIME_MSG_URL" \
    -H "anthropic-version: 2023-06-01" -H "Content-Type: application/json" \
    -d "$REQ_BODY" -o "$CURL_BODY_F1" -w '%{http_code}' 2>"$CURL_ERR_F1"
}
variant_F2() {
  curl -sS --max-time 60 --connect-timeout 15 -K "$CFG_BEARER" -X POST "$BEDROCK_RUNTIME_MSG_URL" \
    -H "anthropic-version: 2023-06-01" -H "Content-Type: application/json" \
    -d "$REQ_BODY" -o "$CURL_BODY_F2" -w '%{http_code}' 2>"$CURL_ERR_F2"
}
variant_F3() {
  local cfg
  if [ "$(choose_f3_header)" = "bearer" ]; then cfg="$CFG_BEARER"; else cfg="$CFG_XAPIKEY"; fi
  curl -sS --max-time 60 --connect-timeout 15 -K "$cfg" -X POST "${BEDROCK_RUNTIME_BASE}/v1/messages/count_tokens" \
    -H "anthropic-version: 2023-06-01" -H "Content-Type: application/json" \
    -d "$COUNT_BODY" -o "$CURL_BODY_F3" -w '%{http_code}' 2>"$CURL_ERR_F3"
}

if should_run "F1" && can_execute_fg; then
  if ! maybe_dry_run_or "F1" "curl -X POST $BEDROCK_RUNTIME_MSG_URL -H 'x-api-key: ***' -H 'anthropic-version: 2023-06-01' -d '{model,max_tokens:8,messages}'"; then
    run_curl_variant "F1: curl x-api-key" "POST anthropic/v1/messages (x-api-key)" "$CURL_BODY_F1" "$CURL_ERR_F1" variant_F1
  fi
fi

if should_run "F2" && can_execute_fg; then
  if ! maybe_dry_run_or "F2" "curl -X POST $BEDROCK_RUNTIME_MSG_URL -H 'Authorization: Bearer ***' -H 'anthropic-version: 2023-06-01' -d '{model,max_tokens:8,messages}'"; then
    run_curl_variant "F2: curl Bearer" "POST anthropic/v1/messages (Authorization: Bearer)" "$CURL_BODY_F2" "$CURL_ERR_F2" variant_F2
  fi
fi

if should_run "F3" && can_execute_fg; then
  if ! maybe_dry_run_or "F3" "curl -X POST ${BEDROCK_RUNTIME_BASE}/v1/messages/count_tokens -H '<F1/F2で通った方, ***>' -d '{model,messages}'"; then
    run_curl_variant "F3: curl count_tokens" "POST anthropic/v1/messages/count_tokens" "$CURL_BODY_F3" "$CURL_ERR_F3" variant_F3
  fi
fi

# --- F4/F5/F6: G系400("metadataがregexに違反")の原因切り分け(2026-09-04追加) ---
# --- F4/F5/F6: isolate the cause of the G-family 400s ("metadata violates
#     the regex"), added 2026-09-04 ---
# F1と同じx-api-key認証・POST /v1/messagesへ、bodyにmetadata.user_idだけを
# 足して送る。F1(metadata無し)は通る実測があるため、metadataフィールド自体・
# その形式のどちらが拒否原因かをここで切り分ける。
# Same x-api-key auth and POST /v1/messages as F1, only adding
# metadata.user_id to the body. F1 (no metadata) is known to succeed, so
# this isolates whether the metadata field itself, or its particular shape,
# is what gets rejected.
CURL_BODY_F4="$OUTDIR/body_F4.json"
CURL_BODY_F5="$OUTDIR/body_F5.json"
CURL_BODY_F6="$OUTDIR/body_F6.json"
CURL_ERR_F4="$OUTDIR/f4.stderr"
CURL_ERR_F5="$OUTDIR/f5.stderr"
CURL_ERR_F6="$OUTDIR/f6.stderr"

variant_F4() {
  curl -sS --max-time 60 --connect-timeout 15 -K "$CFG_XAPIKEY" -X POST "$BEDROCK_RUNTIME_MSG_URL" \
    -H "anthropic-version: 2023-06-01" -H "Content-Type: application/json" \
    -d "$REQ_BODY_F4" -o "$CURL_BODY_F4" -w '%{http_code}' 2>"$CURL_ERR_F4"
}
variant_F5() {
  curl -sS --max-time 60 --connect-timeout 15 -K "$CFG_XAPIKEY" -X POST "$BEDROCK_RUNTIME_MSG_URL" \
    -H "anthropic-version: 2023-06-01" -H "Content-Type: application/json" \
    -d "$REQ_BODY_F5" -o "$CURL_BODY_F5" -w '%{http_code}' 2>"$CURL_ERR_F5"
}
variant_F6() {
  curl -sS --max-time 60 --connect-timeout 15 -K "$CFG_XAPIKEY" -X POST "$BEDROCK_RUNTIME_MSG_URL" \
    -H "anthropic-version: 2023-06-01" -H "Content-Type: application/json" \
    -d "$REQ_BODY_F6" -o "$CURL_BODY_F6" -w '%{http_code}' 2>"$CURL_ERR_F6"
}

if should_run "F4" && can_execute_fg; then
  if ! maybe_dry_run_or "F4" "curl -X POST $BEDROCK_RUNTIME_MSG_URL -H 'x-api-key: ***' -H 'anthropic-version: 2023-06-01' -d '{model,max_tokens:8,messages,metadata:{user_id:\"probe-user\"}}'"; then
    run_curl_variant "F4: curl metadata short" "POST anthropic/v1/messages (metadata.user_id=short)" "$CURL_BODY_F4" "$CURL_ERR_F4" variant_F4
  fi
fi

if should_run "F5" && can_execute_fg; then
  if ! maybe_dry_run_or "F5" "curl -X POST $BEDROCK_RUNTIME_MSG_URL -H 'x-api-key: ***' -H 'anthropic-version: 2023-06-01' -d '{model,max_tokens:8,messages,metadata:{user_id:\"user_<hex>_account_<uuid>_session_<uuid>\"}}'"; then
    run_curl_variant "F5: curl metadata claude-like" "POST anthropic/v1/messages (metadata.user_id=claude-code-like)" "$CURL_BODY_F5" "$CURL_ERR_F5" variant_F5
  fi
fi

if should_run "F6" && can_execute_fg; then
  if ! maybe_dry_run_or "F6" "curl -X POST $BEDROCK_RUNTIME_MSG_URL -H 'x-api-key: ***' -H 'anthropic-version: 2023-06-01' -d '{model,max_tokens:8,messages,metadata:{user_id:\"{\\\"device_id\\\":...}\"}}'"; then
    run_curl_variant "F6: curl metadata JSON-string" "POST anthropic/v1/messages (metadata.user_id=JSON-string value)" "$CURL_BODY_F6" "$CURL_ERR_F6" variant_F6
  fi
fi

# --safe-mode: CLAUDE.md/skills/plugins/hooks/MCPサーバ等を無効化し、export した
# 秘密がそれら経由で外部へ渡る余地を減らす(Codexレビュー指摘への対応・2026-09-03)。
# --settings によるenvオーバーライドは --safe-mode 下でも効くことを本機の
# subscription経路で実測確認済み(Bedrock関連ではない一般のsettings.env上書きで確認)。
# --tools "" は --allowedTools "" より一段強く組み込みツール自体を無効化する。
# --safe-mode: disables CLAUDE.md/skills/plugins/hooks/MCP servers etc., reducing
# the surface through which the exported secret could reach something else
# (added per Codex review, 2026-09-03). Empirically confirmed on this
# machine's subscription path that a --settings env override still applies
# under --safe-mode (verified with a generic settings.env override, not
# Bedrock-specific). --tools "" is a stronger tool-disable than
# --allowedTools "" alone (disables the built-in tool set itself).
# G1〜G6とH1で共有する基底引数(プロンプトと許可ツール以外は全変種で共通)。
# H1 は変種_G*と別に直書きしていたため --permission-mode plan が抜けていた
# (Opus5レビュー指摘・2026-09-03)。この共通化で再発を防ぐ。
# Base args shared by G1-G6 and H1 (everything except the prompt and the
# allowed tool set is identical across variants). H1 used to duplicate
# these by hand and had silently dropped --permission-mode plan (per
# Opus 5 review, 2026-09-03); sharing this array prevents that recurring.
G_BASE_ARGS=(--output-format stream-json --verbose --permission-mode plan --safe-mode)
G_COMMON_ARGS=(-p "$PROMPT" "${G_BASE_ARGS[@]}" --allowedTools "" --tools "")
# reset_auth_env() が実際にunsetする変数と一致させる(表示用ノートが実挙動と
# ズレないように。2026-09-04にCLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS/
# CLAUDE_CODE_ATTRIBUTION_HEADERを追加した際、reset_auth_env側だけ更新して
# ここを更新し忘れると表示と実際の挙動が食い違うため)。
# Kept in sync with what reset_auth_env() actually unsets (so this display
# note doesn't drift from real behavior; when
# CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS/CLAUDE_CODE_ATTRIBUTION_HEADER were
# added to reset_auth_env on 2026-09-04, forgetting to update this string
# too would have made the note misleading).
G_UNSET_NOTE="unset: CLAUDE_CODE_USE_BEDROCK,CLAUDE_CODE_USE_MANTLE,AWS_PROFILE,AWS_REGION,ANTHROPIC_API_KEY,ANTHROPIC_AUTH_TOKEN,CLAUDE_CODE_OAUTH_TOKEN,CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS,CLAUDE_CODE_ATTRIBUTION_HEADER"

# 各 variant_G*/H1 の冒頭で、Bedrock関連envに加えて資格情報系の変数
# (ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN / CLAUDE_CODE_OAUTH_TOKEN)を
# 一旦すべてunsetしてから、そのバリアントが検証したい1つだけをexportする。
# 親から継承した別の資格情報が混ざって実験結果を汚したり、意図しない
# ヘッダへ別の秘密が乗るのを防ぐ(Codexレビュー指摘・2026-09-03)。
# At the top of each variant_G*/H1, unset all credential-bearing vars
# (ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN / CLAUDE_CODE_OAUTH_TOKEN) in
# addition to the Bedrock-related ones, then export only the single one
# this variant is meant to test. Prevents an inherited credential from
# contaminating the experiment or leaking into an unintended header
# (per Codex review, 2026-09-03).
#   2026-09-04追加: CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS/
#   CLAUDE_CODE_ATTRIBUTION_HEADERも同じ理由でunsetする。呼び出し元シェルに
#   どちらかが既に設定されていた場合、G7/G8以外の変種(G1〜G6・比較対象の
#   G2)にまで意図せず継承され、「G2に1つだけ足した変種」という前提が
#   崩れるのを防ぐため(Codexレビュー指摘・2026-09-04)。
#   Added 2026-09-04: also unset CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS/
#   CLAUDE_CODE_ATTRIBUTION_HEADER for the same reason — if either were
#   already set in the caller's shell, it would unintentionally leak into
#   every variant other than G7/G8 (including G2, the baseline G7/G8 are
#   meant to differ from by exactly one var), per Codex review, 2026-09-04.
reset_auth_env() {
  unset CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_MANTLE AWS_PROFILE AWS_REGION \
        ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN \
        CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS CLAUDE_CODE_ATTRIBUTION_HEADER 2>/dev/null || true
}

variant_G1() {
  reset_auth_env
  export ANTHROPIC_BASE_URL="$BEDROCK_RUNTIME_BASE"
  export ANTHROPIC_AUTH_TOKEN="$BEARER_TOKEN"
  claude "${G_COMMON_ARGS[@]}" --model "$MODEL_ID"
}
variant_G2() {
  reset_auth_env
  export ANTHROPIC_BASE_URL="$BEDROCK_RUNTIME_BASE"
  export ANTHROPIC_AUTH_TOKEN="$BEARER_TOKEN"
  claude "${G_COMMON_ARGS[@]}" --model "$MODEL_ID" \
    --settings '{"env":{"CLAUDE_CODE_USE_BEDROCK":"0","CLAUDE_CODE_USE_MANTLE":"0"}}'
}
variant_G3() {
  reset_auth_env
  export ANTHROPIC_BASE_URL="$BEDROCK_RUNTIME_BASE"
  export ANTHROPIC_API_KEY="$BEARER_TOKEN"
  claude "${G_COMMON_ARGS[@]}" --model "$MODEL_ID" \
    --settings '{"env":{"CLAUDE_CODE_USE_BEDROCK":"0","CLAUDE_CODE_USE_MANTLE":"0"}}'
}
variant_G4() {
  reset_auth_env
  export ANTHROPIC_BASE_URL="$BEDROCK_RUNTIME_BASE"
  export ANTHROPIC_AUTH_TOKEN="$BEARER_TOKEN"
  claude "${G_COMMON_ARGS[@]}" --model "${MODEL_ID}[1m]" \
    --settings '{"env":{"CLAUDE_CODE_USE_BEDROCK":"0","CLAUDE_CODE_USE_MANTLE":"0"}}'
}
variant_G5() {
  reset_auth_env
  export ANTHROPIC_BASE_URL="$BEDROCK_MANTLE_BASE"
  export ANTHROPIC_AUTH_TOKEN="$BEARER_TOKEN"
  claude "${G_COMMON_ARGS[@]}" --model "$MANTLE_MODEL_ID" \
    --settings '{"env":{"CLAUDE_CODE_USE_BEDROCK":"0","CLAUDE_CODE_USE_MANTLE":"0"}}'
}

# G6: 「API経路 + apiKeyHelper」候補の成立確認。ANTHROPIC_AUTH_TOKEN/
# ANTHROPIC_API_KEY は一切渡さず、claude起動のたびにこのヘルパー
# スクリプトがプロファイルからトークンを生成してstdoutへ1行返す方式
# (apiKeyHelperの値はAuthorization/x-api-key両方のヘッダへ使われる、と
# Claude Code公式ドキュメントに記載)。--settingsインラインでapiKeyHelperが
# 受理されるか自体が観測項目。
# G6: verifies the "API route + apiKeyHelper" candidate. No
# ANTHROPIC_AUTH_TOKEN/ANTHROPIC_API_KEY is passed at all; instead this
# helper script generates a token from the profile on each claude
# invocation and returns it on stdout (Claude Code's docs say the
# apiKeyHelper's value is sent in both the Authorization and x-api-key
# headers). Whether apiKeyHelper set via inline --settings is even honored
# is itself one of the things being observed here.
G6_HELPER_PATH="$OUTDIR/apikey_helper.sh"
write_g6_helper() {
  # AWS_METADATA_SERVICE_* でIMDS起因のハングを抑止しつつ(generate_token_from_profile
  # と同じ理由)、それでも(SSOのブラウザ認証待ち等で)ハングする経路に備えて
  # このヘルパー自身にも90秒のタイムアウトを埋め込む(claude側がapiKeyHelperに
  # 独自タイムアウトを課しているかは未確認のため、保険として自前で持たせる)。
  #
  # 【2026-09-03 2巡目レビューで訂正】以前は `set -m` + `( ... ) &` の
  # サブシェル包みでバックグラウンド起動していたが、これだと bash のジョブ制御が
  # そのバックグラウンドジョブを独自のプロセスグループへ切り離してしまい、
  # ①外側(claude起動元のこのスクリプト)の90秒タイムアウトやCtrl-C由来の
  # sweep_group()のグループkillがトークン生成プロセスへ届かない
  # ②ヘルパー自身のタイムアウトも(グループ宛の`kill -TERM -- -"$pid"`のまま
  # `set -m`だけ外すと、pidがグループリーダーでなくなり黙って何もkillしない)
  # という2つの経路で孤児化しうる不具合があった(スタブで実測確認)。
  # サブシェル包み・`set -m`をやめ、`env ... "$PY" ... &`を直接バックグラウンド
  # 起動する(envはコマンドをexecするので `$!` はpythonプロセス自身のPIDになる)。
  # 同じプロセスグループに留まるため、外側のグループkillはpythonにも届く。
  # ヘルパー自身のタイムアウトも、素のPID宛`kill -TERM "$pid"`(グループ宛の
  # `-"$pid"`ではない)に変更する。
  # Set AWS_METADATA_SERVICE_* to suppress IMDS-caused hangs (same rationale
  # as generate_token_from_profile), and additionally embed a 90s timeout in
  # the helper itself in case something else hangs (e.g. an SSO browser
  # prompt) — whether Claude Code imposes its own timeout on apiKeyHelper is
  # unconfirmed, so this is a self-contained safety net.
  #
  # [Corrected in the 2026-09-03 round-2 review] This used to background the
  # job via `set -m` + a `( ... ) &` subshell wrapper. That makes bash's job
  # control detach the background job into its own process group, which
  # broke two things (confirmed with a stub): (1) the outer script's 90s
  # timeout / Ctrl-C-driven sweep_group() group-kill (from the process that
  # launched claude) never reaches the token-generation process, and (2)
  # even the helper's own timeout would silently do nothing if `set -m` were
  # removed while its kill stayed group-directed (`kill -TERM -- -"$pid"`),
  # since `$pid` would no longer be a process-group leader. Fixed by
  # dropping the subshell wrapper and `set -m` — backgrounding
  # `env ... "$PY" ... &` directly (env execs the command, so `$!` is the
  # python process's own PID) keeps it in the same process group as the
  # helper script, so the outer group-kill reaches it — and switching the
  # helper's own timeout to a plain-PID `kill -TERM "$pid"` (not group-
  # directed) to match.
  (
    umask 077
    {
      echo '#!/usr/bin/env bash'
      echo 'set -euo pipefail'
      echo 'TIMEOUT_SECS=90'
      printf 'env AWS_PROFILE=%q AWS_METADATA_SERVICE_TIMEOUT=1 AWS_METADATA_SERVICE_NUM_ATTEMPTS=1 %q -c %q %q &\n' \
        "$PROFILE_NAME" "$TOKEN_VENV_PY" \
        'import sys
from aws_bedrock_token_generator import provide_token
sys.stdout.write(provide_token(region=sys.argv[1]))' \
        "$REGION"
      cat <<'INNER'
pid=$!
waited=0
while kill -0 "$pid" 2>/dev/null; do
  if [ "$waited" -ge "$TIMEOUT_SECS" ]; then
    # $pid はグループリーダーではないため素のPID宛にkillする。python自体は
    # killされるが、python(credential_processやSSO周りでサブプロセスを
    # 起動した場合)の子までは追わない制限が残る。直接の子だけは
    # pkill -P で合わせて狙う(孫以降は対象外・簡易な追加緩和)。
    # なお、このヘルパーを呼び出したclaude自身が外側のプロセスグループの
    # 一員である限り、呼び出し元スクリプトのrun_with_timeout/sweep_group
    # (90秒・グループkill)が最終的にはそちらも回収し得る
    # (Codexレビュー指摘・2026-09-03。今回のプロファイルは静的な
    # アクセスキー+シークレット運用のためサブプロセスは通常発生しない想定)。
    # $pid isn't a process-group leader, so this kills it by plain PID.
    # python itself gets killed, but this doesn't chase any subprocess it
    # may have spawned (e.g. via credential_process or an SSO helper) more
    # than one level deep. Also try pkill -P to catch direct children
    # (grandchildren are not covered; a lightweight, partial mitigation).
    # As long as the claude process that invoked this helper is still part
    # of the outer process group, the caller script's own
    # run_with_timeout/sweep_group (90s, group-kill) may still eventually
    # reap those too (per Codex review, 2026-09-03; the expected profile
    # setup here is static access-key+secret, which doesn't normally spawn
    # subprocesses at all).
    kill -TERM "$pid" 2>/dev/null
    pkill -TERM -P "$pid" 2>/dev/null || true
    sleep 2
    kill -KILL "$pid" 2>/dev/null || true
    pkill -KILL -P "$pid" 2>/dev/null || true
    exit 124
  fi
  sleep 1
  waited=$((waited + 1))
done
wait "$pid"
INNER
    } > "$G6_HELPER_PATH"
  )
  chmod 700 "$G6_HELPER_PATH"
}
variant_G6() {
  reset_auth_env
  export ANTHROPIC_BASE_URL="$BEDROCK_RUNTIME_BASE"
  local settings
  settings=$(jq -n --arg helper "$G6_HELPER_PATH" \
    '{env:{CLAUDE_CODE_USE_BEDROCK:"0",CLAUDE_CODE_USE_MANTLE:"0"},apiKeyHelper:$helper}')
  claude "${G_COMMON_ARGS[@]}" --model "$MODEL_ID" --settings "$settings"
}

# G7/G8: G2にclaude起動時のbeta/attribution関連ヘッダを抑止する既知の
# 環境変数を1つずつ足しただけの変種(2026-09-04追加)。どちらもAnthropic公式
# ドキュメントページには未掲載だが、複数のGitHub Issue/コミュニティ記事で
# 存在・効果(Bedrock 400回避との報告を含む)が確認できる。一次情報は
# ヘッダの「一次情報」節を参照。
# G7/G8: G2 with one extra known env var added, each meant to suppress a
# beta/attribution-related header claude sends (added 2026-09-04). Neither
# is on Anthropic's official docs page, but both are corroborated by
# multiple independent GitHub issues/community write-ups (including reports
# that they avoid Bedrock 400s). See the header's "Sources" section.
variant_G7() {
  reset_auth_env
  export ANTHROPIC_BASE_URL="$BEDROCK_RUNTIME_BASE"
  export ANTHROPIC_AUTH_TOKEN="$BEARER_TOKEN"
  export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1
  claude "${G_COMMON_ARGS[@]}" --model "$MODEL_ID" \
    --settings '{"env":{"CLAUDE_CODE_USE_BEDROCK":"0","CLAUDE_CODE_USE_MANTLE":"0"}}'
}
variant_G8() {
  reset_auth_env
  export ANTHROPIC_BASE_URL="$BEDROCK_RUNTIME_BASE"
  export ANTHROPIC_AUTH_TOKEN="$BEARER_TOKEN"
  export CLAUDE_CODE_ATTRIBUTION_HEADER=0
  claude "${G_COMMON_ARGS[@]}" --model "$MODEL_ID" \
    --settings '{"env":{"CLAUDE_CODE_USE_BEDROCK":"0","CLAUDE_CODE_USE_MANTLE":"0"}}'
}

# --- X1: ローカル捕捉(実AWSを一切呼ばない)(2026-09-04追加) ---
# --- X1: local capture, never calls real AWS (added 2026-09-04) ---
# 127.0.0.1の空きポートに最小HTTPサーバーを立て、claude -p(G2相当の設定)を
# そこへ向けて実行し、実際に送られてきたリクエストのbodyトップレベルキー・
# metadataフィールドのJSON全文・anthropic-betaヘッダ・model値だけを記録する。
# system prompt・messages本文・Authorizationヘッダは一切記録しない。
# 何を受けても400を返す(この400自体には意味を持たせない。目的はBedrockへ
# 届く前の、claudeが組み立てた生リクエストを観測すること)。
# Spins up a minimal HTTP server on a free 127.0.0.1 port, points `claude -p`
# (G2-equivalent settings) at it, and records only the actual request's body
# top-level keys, the full JSON text of the metadata field, the
# anthropic-beta header, and the model value — never the system prompt,
# message content, or Authorization header. Always answers 400 regardless of
# what it receives (that status carries no meaning here; the point is to
# observe the raw request claude builds before it would ever reach Bedrock).
X1_SERVER_SCRIPT="$OUTDIR/x1_capture_server.py"
X1_PORT_FILE="$OUTDIR/x1_port"
X1_CAPTURE_FILE="$OUTDIR/x1_capture.json"

write_x1_server() {
  (
    umask 077
    cat <<'PYEOF' > "$X1_SERVER_SCRIPT"
import http.server
import json
import os
import sys

outdir = sys.argv[1]
port_file = os.path.join(outdir, "x1_port")
capture_file = os.path.join(outdir, "x1_capture.json")

captured = {"done": False}


class Handler(http.server.BaseHTTPRequestHandler):
    # HTTP/1.0にして1接続1リクエストに固定し、HEAD warm-up・count_tokens・
    # 本命のmessagesが別々のhandle_request()呼び出しとして届くようにする
    # (keep-aliveだと1接続内で複数リクエストがハンドラの内部ループへ隠れ、
    # 下のfor文の「最大3リクエスト」カウントと噛み合わなくなるため)。
    # Force HTTP/1.0 (one request per connection) so a HEAD warm-up,
    # count_tokens, and the real messages call each arrive as their own
    # handle_request() call below, instead of being hidden inside one
    # keep-alive connection's internal request loop.
    protocol_version = "HTTP/1.0"

    def _send_error(self):
        payload = json.dumps(
            {"type": "error", "error": {"type": "invalid_request_error", "message": "probe capture"}}
        ).encode("utf-8")
        self.send_response(400)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        try:
            self.wfile.write(payload)
        except Exception:
            pass

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        self.do_HEAD()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length) if length else b""
        # count_tokensは(捕捉が済むまでは)無視して待つ(F1-F3と同様、
        # bedrock-runtimeはcount_tokensも/v1/messagesと同じ経路系統に来る)。
        # Ignore count_tokens until the real capture is done (per F1-F3,
        # bedrock-runtime routes count_tokens through the same path family
        # as /v1/messages).
        if self.path.endswith("/count_tokens") and not captured["done"]:
            self._send_error()
            return
        if not captured["done"]:
            try:
                data = json.loads(body) if body else {}
            except Exception:
                data = {}
            if isinstance(data, dict):
                top_level_keys = sorted(data.keys())
                metadata = data.get("metadata")
                model = data.get("model")
            else:
                top_level_keys, metadata, model = [], None, None
            out = {
                "top_level_keys": top_level_keys,
                "metadata": metadata,
                "anthropic_beta": self.headers.get("anthropic-beta", ""),
                "model": model,
            }
            with open(capture_file, "w") as f:
                json.dump(out, f)
            captured["done"] = True
        self._send_error()

    def log_message(self, format, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w") as f:
    f.write(str(server.server_address[1]))
# 自前の保険的タイムアウト: 外側のプロセスグループkillが何らかの理由で
# 届かなくても、85秒経てば必ず自分で終了する(G6ヘルパーと同じ考え方)。
# server.timeoutはhandle_request()の1回あたりの上限であり、単純に
# 固定値へ設定してループするだけだと最大3回×85秒=255秒までかかりうる
# (Codexレビュー指摘・2026-09-04)。time.monotonic()で絶対デッドラインを
# 持ち、反復のたびに残り時間をserver.timeoutへ設定して85秒を厳守する。
# Self-contained safety timeout: even if the outer process-group kill
# somehow doesn't reach this process, it always exits on its own after 85s
# (same rationale as the G6 helper's self timeout). server.timeout only
# bounds a single handle_request() call, so naively setting a fixed value
# and looping could take up to 3 * 85s = 255s in the worst case (per Codex
# review, 2026-09-04). Track an absolute deadline via time.monotonic() and
# set server.timeout to the remaining budget before each iteration so the
# 85s cap is actually honored.
import time

deadline = time.monotonic() + 85
for _ in range(3):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        break
    server.timeout = remaining
    server.handle_request()
    if captured["done"]:
        break
PYEOF
  )
}

variant_X1() {
  reset_auth_env
  # サブシェル包み無しで直接バックグラウンド起動する(G6ヘルパー修正と同じ
  # 理由: run_with_timeoutが直前にset -mしたジョブ制御が引き継がれた状態で
  # `( ... ) &` を重ねると、bashのジョブ制御がその子を別プロセスグループへ
  # 切り離し、外側のグループkillが届かなくなる不具合が実測済みのため)。
  # 念のためこの関数内でもset +mを明示しておく。
  # Background directly, without a nested subshell wrapper (same reason as
  # the G6 helper fix: stacking another `( ... ) &` while job control is
  # still active from run_with_timeout's own `set -m` would detach this
  # child into its own process group, breaking the outer group-kill — a bug
  # already confirmed empirically for G6). `set +m` here makes that
  # explicit regardless of what was inherited.
  set +m
  rm -f "$X1_PORT_FILE" "$X1_CAPTURE_FILE" 2>/dev/null || true
  python3 "$X1_SERVER_SCRIPT" "$OUTDIR" >"$OUTDIR/x1_server.log" 2>&1 &
  local server_pid=$! waited=0 port claude_rc=0
  while [ ! -s "$X1_PORT_FILE" ]; do
    if ! kill -0 "$server_pid" 2>/dev/null; then
      echo "X1 ERROR: ローカル捕捉サーバーがポート待ち受け前に終了しました / local capture server exited before it could bind a port" >&2
      return 1
    fi
    if [ "$waited" -ge 20 ]; then
      kill "$server_pid" 2>/dev/null || true
      echo "X1 ERROR: ローカル捕捉サーバーが20秒以内にポートを報告しませんでした / local capture server did not report a port within 20s" >&2
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  port=$(cat "$X1_PORT_FILE" 2>/dev/null || true)
  export ANTHROPIC_BASE_URL="http://127.0.0.1:${port}"
  export ANTHROPIC_AUTH_TOKEN="dummy"
  claude "${G_COMMON_ARGS[@]}" --model "$MODEL_ID" \
    --settings '{"env":{"CLAUDE_CODE_USE_BEDROCK":"0","CLAUDE_CODE_USE_MANTLE":"0"}}' || claude_rc=$?
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  return "$claude_rc"
}

# X1専用: report2(claude側の通常列)に加え、ローカルサーバーが捕捉した
# リクエストの中身(トップレベルキー・metadata全文・anthropic-beta・model)を
# 追加の1行(長くなりがちなmetadataだけ別行)として出す。
# X1-specific: on top of report2's usual claude-side columns, also print the
# captured request's contents (top-level keys, full metadata, anthropic-beta,
# model) as an extra line (metadata, which tends to be long, gets its own
# line).
report_x1_capture() {
  local capfile="$X1_CAPTURE_FILE" keys metadata beta model
  if [ -s "$capfile" ]; then
    keys=$( (jq -r '(.top_level_keys // []) | join(",")' "$capfile" 2>/dev/null) || true )
    metadata=$( (jq -c '.metadata' "$capfile" 2>/dev/null) || true )
    beta=$( (jq -r '.anthropic_beta // ""' "$capfile" 2>/dev/null) || true )
    model=$( (jq -r '.model // "?"' "$capfile" 2>/dev/null) || true )
  fi
  [ -z "$keys" ] && keys="(no request captured / リクエスト未捕捉)"
  [ -z "$metadata" ] && metadata="null"
  [ "$metadata" = "null" ] && metadata="(none)"
  [ -z "$model" ] && model="?"
  keys=$(redact "$keys")
  metadata=$(redact "$metadata")
  beta=$(redact "$beta")
  model=$(redact "$model")
  printf '%-26s topLevelKeys=%-42s model=%-24s anthropic-beta=%s\n' \
    "X1-capture" "$keys" "$model" "${beta:--}"
  printf '%-26s metadata=%s\n' "" "$metadata"
  record_summary "X1-capture" "n/a" "topLevelKeys=$keys model=$model anthropic-beta=${beta:--} metadata=$metadata"
}

report_x1() {
  local name="$1" outfile="$2" rc="$3" timed_out="$4"
  report2 "$name" "$outfile" "$rc" "$timed_out"
  report_x1_capture
}

H1_PROMPT="Use the WebSearch tool to find the title of https://code.claude.com/docs/en/amazon-bedrock and reply with the title only."
variant_H1() {
  reset_auth_env
  export ANTHROPIC_BASE_URL="$BEDROCK_RUNTIME_BASE"
  export ANTHROPIC_AUTH_TOKEN="$BEARER_TOKEN"
  # G_BASE_ARGS(output-format/verbose/permission-mode plan/safe-mode)は
  # 他のG変種と共有。H1だけの例外はプロンプトと、ツールをWebSearchだけに
  # 絞る点(--allowedTools/--tools とも "" ではなく WebSearch)。
  # G_BASE_ARGS (output-format/verbose/permission-mode plan/safe-mode) is
  # shared with the other G variants. H1's only differences are its own
  # prompt and restricting tools to WebSearch only (--allowedTools/--tools
  # set to WebSearch instead of "").
  claude -p "$H1_PROMPT" "${G_BASE_ARGS[@]}" \
    --allowedTools WebSearch --tools WebSearch \
    --model "$MODEL_ID" \
    --settings '{"env":{"CLAUDE_CODE_USE_BEDROCK":"0","CLAUDE_CODE_USE_MANTLE":"0"}}'
}

if should_run "G1" && can_execute_fg; then
  if ! maybe_dry_run_or "G1" "$G_UNSET_NOTE / export ANTHROPIC_BASE_URL=$BEDROCK_RUNTIME_BASE ANTHROPIC_AUTH_TOKEN=*** / claude ${G_COMMON_ARGS[*]} --model $MODEL_ID"; then
    run_variant_ext report2 "G1: base_url+auth_token" variant_G1
  fi
fi

if should_run "G2" && can_execute_fg; then
  if ! maybe_dry_run_or "G2" "$G_UNSET_NOTE / export ANTHROPIC_BASE_URL=$BEDROCK_RUNTIME_BASE ANTHROPIC_AUTH_TOKEN=*** / claude ${G_COMMON_ARGS[*]} --model $MODEL_ID --settings '{\"env\":{\"CLAUDE_CODE_USE_BEDROCK\":\"0\",\"CLAUDE_CODE_USE_MANTLE\":\"0\"}}'"; then
    run_variant_ext report2 "G2: G1+settings override" variant_G2
  fi
fi

if should_run "G3" && can_execute_fg; then
  if ! maybe_dry_run_or "G3" "$G_UNSET_NOTE / export ANTHROPIC_BASE_URL=$BEDROCK_RUNTIME_BASE ANTHROPIC_API_KEY=*** / claude ${G_COMMON_ARGS[*]} --model $MODEL_ID --settings '{...}'"; then
    run_variant_ext report2 "G3: G2 with API key" variant_G3
  fi
fi

if should_run "G4" && can_execute_fg; then
  if ! maybe_dry_run_or "G4" "$G_UNSET_NOTE / export ANTHROPIC_BASE_URL=$BEDROCK_RUNTIME_BASE ANTHROPIC_AUTH_TOKEN=*** / claude ${G_COMMON_ARGS[*]} --model '${MODEL_ID}[1m]' --settings '{...}'"; then
    run_variant_ext report2 "G4: G2 model[1m]" variant_G4
  fi
fi

if should_run "G5" && can_execute_fg; then
  if ! maybe_dry_run_or "G5" "$G_UNSET_NOTE / export ANTHROPIC_BASE_URL=$BEDROCK_MANTLE_BASE ANTHROPIC_AUTH_TOKEN=*** / claude ${G_COMMON_ARGS[*]} --model $MANTLE_MODEL_ID --settings '{...}'"; then
    run_variant_ext report2 "G5: mantle" variant_G5
  fi
fi

if should_run "G6"; then
  if ! maybe_dry_run_or "G6" "$G_UNSET_NOTE(ANTHROPIC_AUTH_TOKEN/API_KEYはexportしない) / helper=$G6_HELPER_PATH(内部でAWS_PROFILE=$PROFILE_NAME region=$REGION からトークン生成) / claude ${G_COMMON_ARGS[*]} --model $MODEL_ID --settings '{...,\"apiKeyHelper\":\"<path>\"}'"; then
    if can_execute_g6; then
      write_g6_helper
      run_variant_ext report2 "G6: apiKeyHelper" variant_G6
    else
      echo "SKIP G6: venv/module が見つかりません ($TOKEN_VENV)。 / SKIP G6: venv/module not found ($TOKEN_VENV)."
      echo "セットアップ / setup:"
      print_token_venv_setup_instructions
    fi
  fi
fi

if should_run "G7" && can_execute_fg; then
  if ! maybe_dry_run_or "G7" "$G_UNSET_NOTE / export ANTHROPIC_BASE_URL=$BEDROCK_RUNTIME_BASE ANTHROPIC_AUTH_TOKEN=*** CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1 / claude ${G_COMMON_ARGS[*]} --model $MODEL_ID --settings '{...}'"; then
    run_variant_ext report2 "G7: G2+no-experimental-betas" variant_G7
  fi
fi

if should_run "G8" && can_execute_fg; then
  if ! maybe_dry_run_or "G8" "$G_UNSET_NOTE / export ANTHROPIC_BASE_URL=$BEDROCK_RUNTIME_BASE ANTHROPIC_AUTH_TOKEN=*** CLAUDE_CODE_ATTRIBUTION_HEADER=0 / claude ${G_COMMON_ARGS[*]} --model $MODEL_ID --settings '{...}'"; then
    run_variant_ext report2 "G8: G2+no-attribution-header" variant_G8
  fi
fi

if should_run "X1"; then
  if ! maybe_dry_run_or "X1" "local python3 HTTP server on 127.0.0.1:<port> (no AWS call) captures 1 request's body top-level keys/metadata + anthropic-beta header / export ANTHROPIC_BASE_URL=http://127.0.0.1:<port> ANTHROPIC_AUTH_TOKEN=dummy / claude ${G_COMMON_ARGS[*]} --model $MODEL_ID --settings '{...}'"; then
    if can_execute_x1; then
      write_x1_server
      run_variant_ext report_x1 "X1: local capture" variant_X1
    else
      echo "SKIP X1: python3 が見つかりません(PATHを確認してください) / SKIP X1: python3 not found in PATH"
    fi
  fi
fi

if should_run "H1" && can_execute_fg; then
  if ! maybe_dry_run_or "H1" "$G_UNSET_NOTE / export ANTHROPIC_BASE_URL=$BEDROCK_RUNTIME_BASE ANTHROPIC_AUTH_TOKEN=*** / claude -p '<websearch prompt>' ${G_BASE_ARGS[*]} --allowedTools WebSearch --tools WebSearch --model $MODEL_ID --settings '{...}'"; then
    run_variant_ext report2 "H1: with WebSearch" variant_H1
  fi
fi

write_out_file

# 資格情報/venv不在等で選択したバリアントが全てスキップされた場合、
# 従来は最後まで到達してexit 0になっていた(「全部スキップ=成功」と誤認
# しやすい)。実行できたバリアントが1件も無ければ専用の終了コード(2)で
# 区別する(Opus5レビュー指摘・2026-09-03 2巡目)。--dry-runは何も実行
# しない設計なのでこの判定の対象外。
# If every selected variant was skipped (missing credential/venv, etc.),
# this used to reach the end and exit 0, which is easy to mistake for
# success. Distinguish "zero variants actually ran" with a dedicated exit
# code (2) instead (per Opus 5 review round 2, 2026-09-03). --dry-run is
# exempt since it's designed to run nothing.
if [ "$DRY_RUN" -eq 0 ] && [ "$EXECUTED_COUNT" -eq 0 ]; then
  echo "ERROR: 実行されたバリアントが0件でした(資格情報またはvenvの不在で全てスキップされた可能性があります)。 / ERROR: zero variants actually ran (likely all were skipped due to a missing credential or venv)." >&2
  exit 2
fi

echo
echo "=== done ==="
