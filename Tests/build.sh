#!/bin/zsh
# Builds one developer harness into Tests/<name>/run.
# Uses the harness's own build.sh when it has one; otherwise compiles every app source except the
# SwiftUI app (Kitbag.swift) and Health.swift, which needs the app's Mod type, with Tests/<name>/*.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
name=${1:?usage: Tests/build.sh <harness>   (e.g. conflicts, health, gamelog)}
[[ -f Tests/$name/build.sh ]] && exec zsh Tests/$name/build.sh
srcs=(${(f)"$(ls Sources/*.swift | grep -v -E '/(Kitbag|Health)\.swift$')"})
swiftc ${OPT:--O} -swift-version 5 $srcs Tests/$name/*.swift -o Tests/$name/run
echo "Built Tests/$name/run"
