#!/bin/zsh
# The health harness stubs the app's Mod and Scanner types, so it builds with Health.swift but without Kitbag.swift.
set -euo pipefail
cd "$(dirname "$0")/../.."
srcs=(${(f)"$(ls Sources/*.swift | grep -v '/Kitbag.swift$')"})
swiftc ${OPT:--O} -swift-version 5 $srcs Tests/health/*.swift -o Tests/health/run
echo "Built Tests/health/run"
