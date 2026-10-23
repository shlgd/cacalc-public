#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
meal_run_dir=$(mktemp -d "${TMPDIR:-/tmp}/cacalc-meal-pipeline.XXXXXX")
trap 'rm -rf "$meal_run_dir"' EXIT HUP INT TERM
export CACALC_TEST_CACHE_DIRECTORY="$meal_run_dir/caches"
# The shared file helper is compiled verbatim without the iOS-only audio session.
python3 - "$meal_run_dir/VoiceFiles.swift" <<'PY'
from pathlib import Path
import sys
s=Path('ios/Cacalc/VoiceSession.swift').read_text()
a=s.index('enum VoiceFiles'); b=s.index('@MainActor @Observable final class VoiceSession')
Path(sys.argv[1]).write_text('import Foundation\n'+s[a:b])
PY
optimization=-Onone
if [ "${1:-}" = --performance ]; then optimization=-O; fi
xcrun swiftc "$optimization" -parse-as-library -swift-version 6 -module-cache-path "$meal_run_dir/modules" \
 ios/Cacalc/LiveMealParser.swift ios/Cacalc/LiveAudioBuffer.swift ios/Cacalc/RussianLabelParser.swift ios/Cacalc/Domain.swift ios/Cacalc/MealDomain.swift ios/Cacalc/ProductSearch.swift ios/Cacalc/SemanticProductSearch.swift ios/Cacalc/ProcessMemory.swift ios/Cacalc/ProductCreation.swift ios/Cacalc/UsageJournal.swift \
 tools/MealPipelineBench/MealTimeCorrection.swift ios/Cacalc/BodyMeasurements.swift ios/Cacalc/HealthInsights.swift ios/Cacalc/HealthArchive.swift ios/Cacalc/FoodCombination.swift ios/Cacalc/PreparedFood.swift ios/Cacalc/MealAPI.swift ios/Cacalc/DiaryReader.swift ios/Cacalc/DraftStorage.swift ios/Cacalc/Persistence.swift ios/Cacalc/MealRepository.swift \
 ios/Cacalc/ProductRepository.swift ios/Cacalc/Catalog.swift ios/Cacalc/MealSession.swift \
 "$meal_run_dir/VoiceFiles.swift" tools/MealPipelineBench/LegacySearchIndex.swift tools/MealPipelineBench/MealPipelineBench.swift tools/MealPipelineBench/AuditFixChecks.swift tools/MealPipelineBench/AuditPerformanceChecks.swift tools/MealPipelineBench/CombinationChecks.swift tools/MealPipelineBench/PreparedFoodChecks.swift tools/MealPipelineBench/PlannerChecks.swift tools/MealPipelineBench/SelectionChecks.swift \
 -lsqlite3 -o "$meal_run_dir/check"
"$meal_run_dir/check" "$@"
