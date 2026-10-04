# FX-4 STUB の追加分（偽 CODE27 取次実行体）— 常設スイートと締めの実走（tests/closing/）で共有

> 所有＝test-writer B（締め）。要件 v1.2 FX-4「偽の CODE27 取次実行体（消去・発話の各入口＝起動を記録して exit 0）を
> FX-3 配下の既定位置へ足したもの」の最小実装。test-writer A の担当範囲だが着手時点で無かったため、
> B が最小を作った（委任文の指示どおり）。A が別の形で作り直すときはこの README とのずれだけ直せばよい。

- `bin/code27-call-clear`＝消去の入口（本物の `~/work/navi-orchestrator/code27-call/bin/code27-call-clear` の代わり）。
  `claude/hooks/code27-call-clear.sh`（束 B 後は `core/connect/claude-code/prompt-answer.sh`）が
  `CODE27_CALL_BIN` で指すか、既定位置 `$HOME/work/navi-orchestrator/code27-call/bin/code27-call-clear` に置く。
- `bin/code27-call-say`＝発話の入口（カナリア）。本リポジトリの送り手は「応答＝消去」だけを呼ぶ契約
  （設計 §2.2＝CODE27 の送り手は消去を呼ぶ段だけ）なので、この入口の記録は常に 0 件のはず
  （AC-2①・AC-4②の判定）。呼ばれたら対応表の誤りを示す。
- 両方とも起動を `<配置先>/calls.log` へ `<基本名> <引数>` の 1 行で記録して exit 0（他の FX-4 の偽物と同じ記録の形）。
  記録先は `CODE27_CALL_LOG`（既定＝`bin/` の親の `calls.log`）で上書きできる。
- 使用例＝`tests/closing/gate-b1.sh`・`tests/closing/ac-b.sh`・`tests/test-code27-call-clear.sh`（test-writer A・
  `CODE27_CALL_BIN=bin/code27-call-clear`・`CODE27_CALL_LOG` で記録先を指定）・`tests/test-notify.sh`（CODE27 送り手の
  単体試験・FX-24 の実行体欠落ケース）。
