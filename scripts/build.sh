#!/usr/bin/env bash
# 一键构建 iOS App（xtool），完整日志写入 .build/xtool-build.log，只输出错误与结尾。
set -uo pipefail
cd "$(dirname "$0")/.."
source ~/.local/share/swiftly/env.sh
mkdir -p .build
LOG=.build/xtool-build.log
xtool dev build "$@" > "$LOG" 2>&1
code=$?
grep -E "error:" "$LOG" | sed 's/\x1b\[[0-9;]*m//g' | sort -u | head -40
tail -3 "$LOG"
exit $code
