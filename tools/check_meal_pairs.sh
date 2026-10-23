#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
pair_run_dir=$(mktemp -d "${TMPDIR:-/tmp}/cacalc-pair-cases.XXXXXX")
trap 'rm -rf "$pair_run_dir"' EXIT HUP INT TERM
python3 tools/generate_meal_pair_cases.py > "$pair_run_dir/generated.json"
python3 - "$pair_run_dir/generated.json" "$pair_run_dir/all.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
x['cases'] += json.load(open('tests/fixtures/meal-pairs-holdout-v1.json'))['cases']
with open(sys.argv[2], 'w') as f: json.dump(x, f, ensure_ascii=False)
PY
# Optional private exported [Product] JSON; no network or private catalog committed.
export CACALC_PAIR_CATALOG="${CACALC_PAIR_CATALOG:-bundled}"
export CACALC_PAIR_CASES="$pair_run_dir/all.json"
export CACALC_PAIR_REPORT="${CACALC_PAIR_REPORT:-$pair_run_dir/report.json}"
sh tools/check_meal_pipeline.sh
python3 - "$CACALC_PAIR_REPORT" <<'PY'
import json,sys,os
from decimal import Decimal
r=json.load(open(sys.argv[1]))
cases={c['text']:c for c in json.load(open(os.environ['CACALC_PAIR_CASES']))['cases']}
incorrect=[]
def key(a): return (a['food'],Decimal(a['quantity']),a['unit'])
for failure in r['failures']:
 expected=list(map(key,cases[failure['text']]['rows']))
 for actual in json.loads(failure['actual']):
  if key(actual) in expected: expected=expected[expected.index(key(actual))+1:]
  else: incorrect.append(failure); break
r['incorrectAcceptedCases']=len(incorrect)
with open(sys.argv[1], 'w') as f: json.dump(r,f,ensure_ascii=False,indent=2)
print('Incorrect accepted cases:',len(incorrect))
if incorrect: raise SystemExit('Unexpected accepted food/quantity binding')
for k,n in r['counts'].items():
 print(f'{k}: {r["passed"].get(k,0)}/{n}')
# Unconstrained streams are measured, not quietly relabeled as supported speech.
failures=[x for x in r['failures'] if x['category']!='mixed-order']
if failures:
 for x in failures[:5]: print(x)
 raise SystemExit('A required controlled/pause-compatible case failed')
PY
