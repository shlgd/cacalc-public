#!/bin/sh
set -eu
storage_check_dir=$(mktemp -d)
trap 'rm -rf "$storage_check_dir"' EXIT HUP INT TERM
xcrun swiftc -O -swift-version 6 -parse-as-library -module-cache-path "$storage_check_dir/modules" \
    ios/Cacalc/StorageUsageProbe.swift ios/Cacalc/ProcessMemory.swift tools/StorageUsageBench/main.swift -lsqlite3 -o "$storage_check_dir/check"
"$storage_check_dir/check"
