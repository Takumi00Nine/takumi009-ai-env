#!/bin/bash
# 両 leader / 手動の共通入口。symlink 配置でも repo の本体を呼ぶ。
script="${BASH_SOURCE[0]}"
while [ -L "$script" ]; do
  base="$(cd -P "$(dirname "$script")" && pwd)"
  script="$(readlink "$script")"
  case "$script" in /*) ;; *) script="$base/$script" ;; esac
done
base="$(cd -P "$(dirname "$script")" && pwd)"
python3 "$base/recall_runtime.py" "$@"
exit 0
