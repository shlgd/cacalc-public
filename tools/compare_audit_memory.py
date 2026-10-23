#!/usr/bin/env python3
"""Compare archived working-tree V7 and current code using the same Mac fixture.

Requires the local preexisting.patch saved before implementation. Both sources,
stores, module cache and binaries live in a TemporaryDirectory and are removed.
Only small JSON measurements are retained. Never checks out or alters the repo.
"""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'reports/project-audit-fixes-2026-09-30'
SOURCES = ['LiveMealParser', 'RussianLabelParser', 'Domain', 'MealDomain', 'ProductSearch',
           'SemanticProductSearch', 'ProductCreation', 'UsageJournal', 'BodyMeasurements',
           'HealthInsights', 'HealthArchive', 'FoodCombination', 'PreparedFood', 'MealAPI',
           'Persistence', 'MealRepository', 'ProductRepository', 'Catalog', 'MealSession']

def run(args, **kwargs):
    subprocess.run(args, check=True, **kwargs)

with tempfile.TemporaryDirectory(prefix='cacalc-audit-memory-') as directory:
    stage = Path(directory)
    before = stage/'before'; before.mkdir()
    archived = subprocess.check_output(['git', 'archive', '479f2e1', 'ios/Cacalc'], cwd=ROOT)
    subprocess.run(['tar', '-x', '-C', str(before)], input=archived, check=True)
    run(['git', 'apply', '--include=ios/Cacalc/*.swift', str(OUTPUT/'preexisting.patch')], cwd=before)
    helper = (ROOT/'ios/Cacalc/ProcessMemory.swift').read_text().replace('enum ProcessMemory', 'enum ProbeMemory')
    (stage/'ProbeMemory.swift').write_text(helper)
    for label, source in [('before', before), ('after', ROOT)]:
        store = stage/(label+'-store'); store.mkdir()
        text = (source/'ios/Cacalc/VoiceSession.swift').read_text()
        text = text[text.index('enum VoiceFiles'):text.index('@MainActor @Observable final class VoiceSession')]
        (stage/'VoiceFiles.swift').write_text('import Foundation\n'+text)
        files = [str(source/f'ios/Cacalc/{name}.swift') for name in SOURCES]
        if label == 'after':
            files += [str(ROOT/f'ios/Cacalc/{name}.swift') for name in ['DraftStorage', 'DiaryReader', 'ProcessMemory']]
        files += [str(stage/'VoiceFiles.swift'), str(stage/'ProbeMemory.swift'), str(ROOT/'tools/MealPipelineBench/MemoryProbe.swift')]
        run(['xcrun', 'swiftc', '-O', '-parse-as-library', '-swift-version', '6', '-module-cache-path', str(stage/'modules'),
             *files, '-lsqlite3', '-o', str(stage/'probe')], cwd=ROOT)
        env = dict(os.environ, CACALC_MEMORY_PROBE_ROOT=str(store), CACALC_TEST_CACHE_DIRECTORY=str(store/'caches'),
                   CACALC_MEMORY_PROBE_OUTPUT=str(OUTPUT/f'memory-{label}.json'))
        run([str(stage/'probe')], cwd=ROOT, env=env)
