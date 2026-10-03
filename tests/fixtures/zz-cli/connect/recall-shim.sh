#!/bin/bash
# zz-cli 用の変換シム（設計 §10.3 (b)）: stdin {"query":…} を想起入口の {"session_id":…,"prompt":…} に直し、
# 同じ機能の想起実行器を相対パスで起動して stdout をそのまま返す。__RECALL_REL__ は FX-10 を作るときに埋める。
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
jq -c '{session_id:"s1", prompt:.query}' | "$SELF_DIR/__RECALL_REL__"
