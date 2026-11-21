#!/usr/bin/env bash
# Linux 上只编译 MolaCore，输出精简的错误列表（test-core.sh 安静模式不显示诊断时用）。
set -uo pipefail
cd "$(dirname "$0")/.."
source ~/.local/share/swiftly/env.sh
mkdir -p .build
MOLA_CORE_ONLY=1 swift build --build-tests > .build/core-build.log 2>&1
code=$?
sed 's/\x1b\[[0-9;]*m//g' .build/core-build.log | grep -E "^/.*: error:" | sort -u | head -30
exit $code
