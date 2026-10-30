#!/bin/sh
# Builds Tests/conflicts/run (explicit file list; never Sources/*.swift).
cd "$(dirname "$0")/../.." && swiftc -O -swift-version 5 \
  Sources/PBOArchive.swift Sources/ConfigModel.swift Sources/ConfigPreprocessor.swift Sources/TextConfigParser.swift \
  Sources/RapParser.swift Sources/ConfigIndexer.swift Sources/KnownIssues.swift $( [ -f Sources/ConflictAnalysis.swift ] && echo Sources/ConflictAnalysis.swift ) \
  $(ls Tests/conflicts/*.swift | grep -v main.swift) Tests/conflicts/main.swift -o Tests/conflicts/run
