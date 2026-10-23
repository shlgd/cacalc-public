#!/usr/bin/env python3
"""Guard the existing application-owned button inventory against lost instrumentation."""
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
controls = json.loads((root / 'docs/usage-controls.json').read_text())
ids = [control['id'] for control in controls]
assert len(ids) == len(set(ids)), 'Duplicate control IDs'
source = '\n'.join(path.read_text() for path in (root / 'ios/Cacalc').glob('*.swift'))
for control in controls:
    assert '"' + control['id'] + '"' in (root / control['file']).read_text(), control['id']
buttons = len(re.findall(r'\bButton\s*(?=[({])', source))
assert buttons == len(controls), f'Button inventory changed: {buttons} buttons vs {len(controls)} registered controls'
assert 'MealRecorderTapArea(enabled:' in source and 'usageAction("MealDictationControl.recorderTap"' in source
print(f'PASS: {buttons} registered SwiftUI buttons and recorder tap bridge')
