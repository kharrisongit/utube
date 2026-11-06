#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -swift-version 6 -D GUIDED_STORAGE_CHECKS -parse-as-library \
  -target "$(uname -m)-apple-macos15.0" \
  Core/Knowledge.swift Core/Search.swift Core/Answer.swift \
  App/LibraryStore.swift App/EncryptedBackup.swift App/SimulatorChecks.swift \
  scripts/StorageCheckRunner.swift -o build/storage-checks
build/storage-checks
