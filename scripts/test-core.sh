#!/usr/bin/env bash
# 在 Linux 上跑 MolaCore 纯逻辑单测（安静模式）。编译失败时用 scripts/core-build.sh 看诊断。
set -uo pipefail
cd "$(dirname "$0")/.."
source ~/.local/share/swiftly/env.sh
mkdir -p .build
LOG=.build/core-test.log
MOLA_CORE_ONLY=1 swift test -q "$@" > "$LOG" 2>&1
code=$?
sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -E "error:|XCTAssert|failed \(" | grep -v "Command line\|frontend" | sort -u | head -20
sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -E "Executed [0-9]+ tests" | sort -k2 -n | tail -1
exit $code
