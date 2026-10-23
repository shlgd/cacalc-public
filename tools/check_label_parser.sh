#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
parser_run_dir=$(mktemp -d "${TMPDIR:-/tmp}/cacalc-label-parser.XXXXXX")
trap 'rm -rf "$parser_run_dir"' EXIT HUP INT TERM
xcrun swiftc -O -parse-as-library -module-cache-path "$parser_run_dir/modules" \
  ios/Cacalc/Domain.swift ios/Cacalc/HealthInsights.swift ios/Cacalc/MealDomain.swift ios/Cacalc/ProductSearch.swift ios/Cacalc/ProductCreation.swift ios/Cacalc/RussianLabelParser.swift \
  tools/LabelParserBench/LabelParserBench.swift -o "$parser_run_dir/check"
"$parser_run_dir/check" tests/fixtures/voice-language.json tests/fixtures/voice-label-rules.json
