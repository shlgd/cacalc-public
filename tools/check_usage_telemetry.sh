#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
usage_run_dir=$(mktemp -d "${TMPDIR:-/tmp}/cacalc-usage.XXXXXX")
trap 'rm -rf "$usage_run_dir"' EXIT HUP INT TERM
xcrun swiftc -parse-as-library -swift-version 6 -module-cache-path "$usage_run_dir/modules" ios/Cacalc/UsageJournal.swift tools/UsageTelemetryBench/main.swift -lsqlite3 -o "$usage_run_dir/check"
"$usage_run_dir/check"
