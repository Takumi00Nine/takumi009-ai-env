---
date: 2026-09-09
updated: 2026-09-09
tags: [preference, model, catalog, claude, codex, routing, quota, bedrock, vllm]
project: meta
related:
  - "[[Preferences/coding-delegation]]"
  - "[[Preferences/codex-review-protocol]]"
  - "[[Preferences/core-conduct]]"
  - "[[Preferences/core-workflow]]"
  - "[[Preferences/worker-role-prompts]]"
  - "[[Knowledge/claude-codex-strengths-and-orchestration]]"
  - "[[Knowledge/codex-rate-limit-reset-banking]]"
  - "[[Knowledge/claude-codex-usage]]"
  - "[[Knowledge/anthropic-claude-models-2026-06]]"
  - "[[Knowledge/gpt-5-6-and-gpt-live]]"
  - "[[Knowledge/bedrock-claude-code-pitfalls]]"
  - "[[Knowledge/bedrock-bearer-token]]"
  - "[[Decisions/2026-09-08-usage-fetcher-migration]]"
aliases:
  - "モデル特性カタログ"
  - "モデルの選び方"
  - "ClaudeとCodexの枠の違い"
  - "サービス別の向き不向き"
  - "サービス別の枠とリセット"
---

# モデル特性カタログ（背景知識・全マシン共通）

各マシンのローカルカタログ（配役表の隣に置くマシン固有ファイル）は経路ごとの実測メモを持つ。**本ノートはその手前にある共通の背景知識**で、Preferences に置くのは全マシンへ配布するため（本人決定 2026-09-09）。**リーダーが spawn ごとに候補（配役表 `model=` の定義名）から1つ選ぶときの判断材料は本ノート**（機構は読まない。選ぶのは人間相当のリーダーである）。**今後は使えるモデル・経路が増えるたびに本ノートへ追記していく運用**（更新の手順は末尾の「更新の掟」）。**各機での採用の有無は配役表（`role.*`／models.conf）と Projects を見る**（本ノートは性質だけを書き、どの機がどれを使っているかは書かない）。

**2軸で見る**＝①モデルの特性の違い（Claude 各モデル・Codex 側モデル・ローカル LLM）②サービス（経路）の違い（同じモデルでも「サブスクで呼ぶか」「Bedrock で呼ぶか」「ローカルで動かすか」で認証・枠・リセット・機能差・費用の性質が変わる）。**性能は定性の散文で書き、順位・数値スコアにしない**（数値化すると精度の要件になり、本人が求める「適切な配分」から外れるため）。

## ①モデルの特性

| モデル | 特徴 | 向く仕事・向かない仕事 | 注意点 |
|---|---|---|---|
| **Claude Fable 5.1**（`claude-fable-5-1`） | Claude 系の最上位。1M コンテキスト・adaptive thinking 常時オン・長時間の自律作業に強い | 向く＝要件定義・設計・採否判定など判断の質が下流全体に効く上流工程。向かない＝日常の軽い実装・定型作業 | 週次の専用枠があり枯渇しやすい。ワーカー・定型生成にはほぼ割り当てない運用が定石 |
| **Claude Opus 5**（`claude-opus-5`） | Fable 5.1 に近い性能をより軽い枠消費で出せる日常の最上位。5段階 effort（low〜max）対応 | 向く＝要件定義・設計・採否判定の既定、複雑な統合判断、Codex 上限到達時の一次レビュー代替。向かない＝大量の並列軽作業 | thinking が既定オンで応答に余裕トークンが要る。推奨 effort の初期値は high |
| **Claude Sonnet 5**（`claude-sonnet-5`） | ワーカー既定。実装・調査・テストなど「作る工程」の主力 | 向く＝開発4工程の実働・探索的調査。向かない＝後戻りコストが高い設計判断の単独決定 | 並行起動しやすく枠の主消費源になりやすい |
| **Claude Haiku 4.5** | Claude 系で最も軽量・高速 | 向く＝分類・抽出・定型変換など判断の重くない大量処理。向かない＝設計判断・複雑なコード理解 | 使う場合は models.conf に個別定義を足す（実測メモ無し） |
| **Codex 既定（GPT-5.6 Sol、`gpt-5.6-sol`）** | Codex の一次レビュー・実装委任・画像生成一気通貫で使う既定モデル。ターミナル系のエージェント作業に強い傾向 | 向く＝コードレビュー、bounded task（目的・範囲・出力形式・停止条件が明確な小さな実装委任）、非同期の反復作業。向かない＝広範囲・複数部品にまたがる不可逆な設計判断の単独決定 | 旧世代 GPT-5.5／5.4 も一部経路（Bedrock 経由）でまだ選べる。Terra・Luna は別行を参照 |
| **GPT-5.6 Terra**（`gpt-5.6-terra`） | OpenAI 公式が旧世代でいう mini ティア相当と位置づける中位モデル。速度・コストと能力のバランスを取った日常ワークロード向け | 向く＝日常のコードレビューで枠を節約したい中間ケース、Sol ほど重くしなくてよい一般的なコーディング作業。向かない＝締めの全体構成レビューなど品質最優先の場面（そこは Sol＋高 effort） | Codex 一次レビューでは既定 Sol に対し明示指定（`-m gpt-5.6-terra`）で使う運用。実効モデルの確認はセッションログの `model` フィールドで行う（自己申告は不正確） |
| **GPT-5.6 Luna**（`gpt-5.6-luna`） | OpenAI 公式が旧世代でいう nano ティア相当と位置づける、GPT-5.6 系で最速・最低コストのモデル。高速・大量処理向け | 向く＝形式・命名・小差分など正解が明確な軽い定型チェック、抽出・分類等の定型大量処理。向かない＝複雑な設計判断・微妙な文脈理解が要るレビュー | Codex 一次レビューでは明示指定（`-m gpt-5.6-luna`）で日常レビューの枠節約に使う運用 |
| **GPT-6 Astra** | Codex 経由で使える上位モデル。消費量が Sol より重い | 向く＝デザイン系案件（3D モデル等）で Codex が上流を主担当する要件定義・設計の工程限定。向かない＝それ以外の全用途（一次レビュー・画像生成・通常実装は Sol のまま） | 既定を切り替えず用途限定で使う運用（ベンチ1本で既定を動かさない方針） |
| **gpt-oss-20b**（OpenAI・オープンウェイト） | MoE（専門家混合）構成で総パラメータ約21B・活性化パラメータ約3.6B。**reasoning effort を low/medium/high から選べる**（プロンプトで指示）。エージェント向けにブラウジング（検索）・Python 実行・関数呼び出しをネイティブに訓練されている | 向く＝reasoning effort を落として軽い定型応答に使う、関数呼び出し中心のエージェント作業。向かない＝ブラウジング・Python 実行はモデルがそのツール呼び出し形式を**訓練で覚えているだけ**で、vLLM 側にそのツール自体を実装・接続しない限り実行されない（提供状況は要確認） | ライセンス＝**Apache 2.0**（改変・商用利用とも制限が緩い）。多言語評価（公式 MMMLU）に日本語を含むが、日本語特化のチューニングではない素の多言語能力（日本語特化の派生モデルは別途コミュニティ製が存在する＝本モデルとは別物） |
| **Gemma 4 12B**（Google DeepMind・オープンウェイト。"12B Unified"） | 約11.95B パラメータ・エンコーダ不要のマルチモーダル（テキスト・画像・音声を1つのデコーダで直接処理）。ローカル／ハイブリッド注意機構（局所+全体）で256Kトークンの長文脈に対応。**ツール利用（function calling）をネイティブサポート**、エージェント的ワークフロー向け | 向く＝長文脈が要る要約・ドキュメント処理、画像を含むマルチモーダル入力が要る軽作業、関数呼び出しを使うエージェント処理。向かない＝皮肉・比喩など機微なニュアンスの読み取り、最新事実の参照（学習データ依存で知識が古くなりうる） | ライセンス＝**Apache 2.0**（Google公式ページ・Hugging Face の両方で確認。旧世代 Gemma の Gemma 利用規約から変わっている点に注意＝再配布時は現行ライセンス文言を都度確認）。35以上の言語に対応し**日本語を含む**（公式サポート言語として明記） |

## ②サービス（経路）の違い

同じ「Claude」「Codex」でも、**サブスクで呼ぶか・Bedrock で呼ぶか・ローカルで動かすか**で性質が変わる。

| サービス | 認証 | 枠・窓 | リセットの仕組み | 使用率の取れ方 | 機能差 | 費用の性質 | 向く・向かない |
|---|---|---|---|---|---|---|---|
| **Claude サブスク** | claude.ai ログイン（キーチェーン保存の OAuth） | `claude-subscription`。`five_hour`・`seven_day`（＋参考の週次モデル別枠） | `/limit-reset`＝**未公開**の CLI コマンド。**5時間窓だけ**リセット、週次には効かない。残数の機械取得は未確認 | **【使用率】ブロックに出る**（3枠の1つ） | 組み込み WebSearch 等フル機能 | 定額（契約プラン） | 向く＝通常運用・判断の重い上流工程。向かない＝枠が切迫した状況での大量消費 |
| **Claude Bedrock**（現行＝配役表 `provider=bedrock`＋`bedrock.env` のピン留め。設計中の統合経路名は要件書側） | AWS プロファイル→短期ベアラートークン（presigned URL 方式・実効期限は指定値と AWS 認証情報の残り期限の短い方）。使用側に IAM の明示 Allow（`bedrock:CallWithBearerToken`）が要る | `unlimited`（枠の概念なし） | 無し（上限の概念が無いためリセットという操作が意味を持たない） | 出ない（`unlimited` は使用率を読まない） | **WebSearch は利用可**（2026-08 時点の「不可」という公式注記は 2026-09-01 実測で訂正済み＝[[Knowledge/bedrock-claude-code-pitfalls]]） | 従量課金（AWS 側でトークン量課金） | 向く＝サブスク枠を使い切りたくない場面の保険的経路、費用を許容できる場面。向かない＝定額枠で足りている状況（従量課金が無駄になる）。注意＝短期トークンの実効期限・SSO 再ログインが要る場合がある |
| **Codex サブスク**（ChatGPT ログイン） | ChatGPT の OAuth ログイン | `codex-subscription`。`five_hour`・`seven_day` | **公式の「rate-limit reset credit」**（本人の呼び方＝チケット）。**5時間窓と週次窓の両方**を一度にリセット、付与から30日で失効 | **【使用率】ブロックに出る**。チケットの枚数・期限も `account/rateLimits/read` から機械取得できる（確度高＝[[Knowledge/codex-rate-limit-reset-banking]]） | フル機能（WebSearch 含む） | 定額（契約プラン） | 向く＝一次レビュー・bounded task の実装委任・画像生成一気通貫。向かない＝枠切迫時の大量投入（チケットで回復できるが枚数に限りがある） |
| **Codex Bedrock**（`amazon-bedrock` model provider） | Bedrock API キー（`AWS_BEARER_TOKEN_BEDROCK`）または AWS SDK の資格情報チェーン（前者を優先。ChatGPT ログインとは別建て） | ChatGPT サブスクの枠とは別建て（従量課金）。⚠️ **rate-limit reset credit の対象になるかは未確認**（公式ドキュメントに記載なし＝推定で「対象外」とは断定しない） | 記載なし（サブスクの窓の概念自体が無いため無いと推定。確度中） | 出ない想定（Codex サブスクの `usage` とは別系統） | **WebSearch 不可**（公式ドキュメントが機能表で明記＝「OpenAI がホストするクラウド機能に依存する機能は非対応」）。利用可能モデルは `gpt-5.6-sol`／`terra`／`luna` と旧世代 `gpt-5.5`／`gpt-5.4`（リージョン依存、公式確認済み） | 従量課金（トークン単位、シート契約なし＝AWS 公式ブログの表現） | 向く＝Codex サブスク枠が枯渇していて費用を許容できる保険。向かない＝WebSearch が要る裏取り系タスク（researcher 等） |
| **ローカル LLM（vLLM）** | API キー認証（管理方式は設計中） | `unlimited`（枠の概念なし＝「何を任せても持ち時間が減らない」） | 無し | 出ない（そもそも使用率を読まない設計） | Claude Code の組み込みツール（WebSearch 等）が使えるかはモデル・呼び出し元次第で個別確認が要る。vLLM 自体はモデルを提供するだけでツール実行機構を持たない | 電気代・機材維持費（従量課金でも定額でもない自己ホスト） | 向く＝枠を気にせず量をこなしたい定型・反復作業。向かない＝高度な判断・複雑な設計（モデル規模が小さく性能が下位）。注意＝Claude Code 側の経路統合（認証ヘッダの要否等）は要確認事項 |

⚠️ **Codex の Bedrock 経路は公式に存在する**（確度：高。OpenAI ヘルプセンターと AWS 公式ブログ・`learn.chatgpt.com` の設定ドキュメントで確認）。「gpt-oss 等」ではなく、**GPT-5.6 系がそのまま Bedrock 上で動き**、ローカル LLM とは別物である。

## ③組み合わせの向き不向き（役割 × サービス）

- **検証職（Codex 一次レビュー）**＝Codex サブスクが既定。枠が切迫してもチケット（reset credit）で回復できる余地があり、Bedrock へ落とす前に確認する価値が高い。
- **researcher・裏取りが要る調査**＝Claude サブスクか Codex サブスク（どちらも WebSearch 可）。**Bedrock（Claude・Codex とも）は Codex 側で WebSearch 不可、Claude 側は 2026-09-01 以降は可**——Codex を Bedrock 経由で裏取り系に使わない。
- **上流工程（要件定義・設計・採否判定）**＝Claude の Opus 5／Fable 5.1（判断の質が重要・枠消費は許容）。ローカル LLM は不向き（性能が下位）。
- **量産・定型（分類・抽出・軽い実装の反復）**＝ローカル LLM か Claude Haiku 4.5。サブスク枠を温存できる。
- **サブスク枠が枯渇している状況**＝まずローカル LLM（費用ゼロに近い）→ 次に Bedrock（従量課金だが確実に動く）→ サブスクの `/limit-reset`（Claude）やチケット（Codex）は温存策であって代替経路ではない。

## 出典・確認日
- Codex on Amazon Bedrock（対応モデル・認証方式・WebSearch 非対応）＝ https://learn.chatgpt.com/docs/amazon-bedrock （2026-09-09 取得）／AWS 公式ブログ https://aws.amazon.com/blogs/aws/get-started-with-openai-gpt-5-5-gpt-5-4-models-and-codex-on-amazon-bedrock/ （2026-09-09 取得・従量課金の記述）／PR openai/codex#18744（`amazon-bedrock` provider 実装）。
- Claude Bedrock の WebSearch 訂正＝[[Knowledge/bedrock-claude-code-pitfalls]]（2026-09-01 実測訂正）。短期トークンの実効期限＝[[Knowledge/bedrock-bearer-token]]。
- Codex の rate-limit reset credit＝[[Knowledge/codex-rate-limit-reset-banking]]・[[Knowledge/claude-codex-usage]]（2026-09-09 実測節）。
- Claude `/limit-reset` の性質＝[[Knowledge/claude-codex-usage]]（2026-09-09 節）。
- vLLM の稼働実態（gpt-oss-20b・Gemma 4 12B・ポート8000）＝`ローカルLLM段階経路-要件-2026-09-03.md` §1。枠・窓・`kind` 4値の定義＝同書 §2.1・§2.2・§4.4・§4.14。
- 運用上の役割分担・既定モデル＝`Preferences/coding-delegation`・`Preferences/codex-review-protocol`（2026-09-08〜09 時点の現行値）。
- GPT-5.6 3階層の位置づけ（Sol=flagship／Terra=miniティア相当・日常主力／Luna=nanoティア相当・最速最安）＝OpenAI 公式 https://openai.com/index/gpt-5-6/ （2026-09-09 取得）。
- Codex 一次レビューでの Terra/Luna の使い分け運用（軽い定型チェック=Luna・日常レビューの中間=Terra）＝[[Preferences/codex-review-protocol]]「使用モデルと effort の指標」節（2026-07-20 追加・2026-09-09 参照）。
- モデル一覧・実測可否の背景＝[[Knowledge/gpt-5-6-and-gpt-live]]。
- gpt-oss-20b の構成・reasoning effort・ツール（ブラウジング/Python/関数呼び出し）・ライセンス＝OpenAI 公式モデルカード https://openai.com/index/gpt-oss-model-card/ （PDF: https://cdn.openai.com/pdf/419b6906-9da6-406c-a19d-1bb078ac7637/oai_gpt-oss_model_card.pdf ）・OpenAI Developers https://developers.openai.com/api/docs/models/gpt-oss-20b ・GitHub https://github.com/openai/gpt-oss （2026-09-09 取得）。
- gpt-oss-20b の日本語を含む多言語評価（MMMLU）＝同モデルカード（arXiv版 https://arxiv.org/abs/2508.10925 、2026-09-09 取得。数値スコアは本カタログには転記せず定性のみ記載）。
- Gemma 4 12B の構成・マルチモーダル・注意機構・ツール利用・言語対応＝Google AI for Developers 公式モデルカード https://ai.google.dev/gemma/docs/core/model_card_4 （2026-09-09 取得）。
- Gemma 4 12B のライセンス（Apache 2.0）＝上記公式ページおよび Hugging Face https://huggingface.co/google/gemma-4-12B （2026-09-09 取得・2ソース一致で確認）。

## 未裏取り・要確認
- **Codex Bedrock 経路がチケット（rate-limit reset credit）の対象になるかは未確認**（公式ドキュメントに記載なし。サブスクとは別建てなので対象外の可能性が高いが、断定はしていない）。
- GPT-6 Astra の詳細な特徴・ベンチマークは [[Knowledge/gpt-6-astra]] を直接読んでいない（用途限定の事実のみ `Decisions/2026-09-05-astra-for-design-upstream-only` から確認）。
- vLLM の Claude Code 側属性（`attribution_header` の要否・`auth_header` の種別）は EXP-4・EXP-5 の実測待ち（要件書 §2.2 注記）。Codex CLI から同じ vLLM サーバーへ独自 `model_providers` 定義で接続できる可能性は技術的に確認したが（Codex は任意の OpenAI 互換エンドポイントを `base_url`＋`wire_api` で受け付ける）。採用の有無は各機の記録による。
- gpt-oss-20b のブラウジング／Python ツールが**実際のデプロイで有効化されているか**は未確認（モデル側の訓練済み能力と、サーバー側のツール実装は別物）。
- Gemma のライセンスが Apache 2.0 である点は2つの独立ソースで一致したが、Google の従来の Gemma シリーズは「Gemma利用規約」という独自ライセンスだったため、この世代（Gemma 4）で条件が変わった可能性がある——再配布・商用利用時は都度一次情報を再確認する運用を注意点欄に明記した。

## 更新の掟

新しいモデル・新しいサービス（経路）が使えるようになったら、その都度この手順で反映する。
- **(a) 表に1行足す**＝該当する表（①モデル or ②サービス）に、既存行と同じ列で書く。①＝特徴・向く仕事/向かない仕事・注意点。②＝認証・枠と窓・リセットの仕組み・使用率の取れ方・機能差・費用の性質・向く/向かない。**出典 URL と確認日**を注意点欄か出典節に必ず添える。
- **(b) `models.conf` に定義を足す**＝`config/models.conf.sample` を更新して配布し（実値は各マシンローカルの `models.conf` が持つ）、本ノートの表とローカルカタログの両方から参照できるようにする。
- **(c) 既存行の陳腐化は読み時に直す**＝新しい行を足すついでに古い行が古くなっていないか確認し、直したら frontmatter の `updated` を引き直す。放置しない。
- **(d) 実測・使用感を材料にしてよいが個人情報は書かない**＝本人の Fragments 等の記録から特徴・注意点を拾ってよいが、呼び名・Personal 配下へのリンク・ホーム配下の絶対パス（`~/` 表記にする）・契約プランの金額は書かない（プラン名そのものは可＝[[Preferences/absolute-rules]] ①③）。
