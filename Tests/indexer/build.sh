#!/bin/sh
# Builds Tests/indexer/run (explicit file list; never Sources/*.swift).
# Tests/rap/Writer.swift is borrowed read-only to write rapified configs for the synthetic library.
cd "$(dirname "$0")/../.." && swiftc -O -swift-version 5 \
  Sources/PBOArchive.swift Sources/ConfigModel.swift Sources/ConfigPreprocessor.swift Sources/TextConfigParser.swift \
  Sources/RapParser.swift Sources/ConfigIndexer.swift \
  Tests/rap/Writer.swift Tests/indexer/TestPBO.swift Tests/indexer/SelfTest.swift Tests/indexer/Real.swift \
  Tests/indexer/Research.swift Tests/indexer/ParserLock.swift Tests/indexer/main.swift -o Tests/indexer/run
