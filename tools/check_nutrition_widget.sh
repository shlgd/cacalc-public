#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
widget_check_dir=$(mktemp -d "${TMPDIR:-/tmp}/cacalc-widget-check.XXXXXX")
trap 'rm -rf "$widget_check_dir"' EXIT HUP INT TERM
xcrun swiftc -parse-as-library -swift-version 6 -module-cache-path "$widget_check_dir/modules" \
    ios/RecordingShared/NutritionWidgetSnapshot.swift tools/NutritionWidgetChecks.swift \
    -o "$widget_check_dir/check"
"$widget_check_dir/check"
