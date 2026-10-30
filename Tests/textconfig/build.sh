#!/bin/sh
# Builds Tests/textconfig/run (explicit file list; never Sources/*.swift).
cd "$(dirname "$0")/../.." && swiftc -O -swift-version 5 \
  Sources/PBOArchive.swift Sources/ConfigModel.swift Sources/ConfigPreprocessor.swift Sources/TextConfigParser.swift Sources/RapParser.swift \
  Tests/textconfig/main.swift Tests/textconfig/SelfTest.swift Tests/textconfig/Conformance.swift \
  Tests/textconfig/Corpus.swift Tests/textconfig/V1.swift Tests/textconfig/Probe.swift Tests/textconfig/CrossCheck.swift Tests/textconfig/Fuzz.swift -o Tests/textconfig/run
