#!/usr/bin/env python3
"""Build the curated Russian catalog from a pinned, local official Norwegian snapshot.
No network; no invented nutrition. Keeps the previous database until validation succeeds.
"""
import argparse, hashlib, json, sqlite3, tempfile, unicodedata
from decimal import Decimal
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
D = Decimal
NUTRIENTS = ('Protein', 'Fett', 'Karbo')
def read(path):
    return json.loads(path.read_text(), parse_float=D, parse_int=D)
def norm(s):
    return ' '.join(unicodedata.normalize('NFKC', s).lower().replace('ё', 'е').split())
def values(food):
    nutrients = {n['nutrientId']: n for n in food['constituents']}
    fields = [food['calories']] + [nutrients.get(k, {}) for k in NUTRIENTS]
    expected = ['kcal', 'g', 'g', 'g']
    issues = []
    result = []
    for field, unit in zip(fields, expected):
        v = field.get('quantity')
        if v is None or field.get('unit') != unit:
            issues.append('missing_or_wrong_unit'); result.append(None)
        else:
            result.append(D(str(v)))
    if issues: return result, issues
    e, p, f, c = result
    if any(not v.is_finite() or v < 0 for v in result): issues.append('invalid_number')
    elif e > 950 or max(p, f, c) > 100 or p+f+c > 102:
        issues.append('physical_limit')
    return result, issues

def build(source, names_path, output, report_path):
    data = read(source)
    foods = data['foods']
    by_id = {f['foodId']: f for f in foods}
    if len(by_id) != len(foods): raise ValueError('Duplicate source ID')
    names = {}
    for line in names_path.read_text().splitlines():
        if not line.strip() or line.startswith('#'): continue
        id, name = line.split('|', 1)
        if id in names or not name.strip(): raise ValueError('Duplicate/empty curated name')
        names[id] = name
    if len(set(names.values())) != len(names): raise ValueError('Duplicate Russian name')
    rows, rejected, warnings = [], [], []
    for id, name in names.items():
        food = by_id[id]
        (e, p, f, c), issues = values(food)
        if issues:
            rejected.append({'id': id, 'name': name, 'issues': issues}); continue
        constituents = {n['nutrientId']: n for n in food['constituents']}
        fiber = constituents.get('Fiber', {}).get('quantity', 0) or 0
        alcohol = constituents.get('Alko', {}).get('quantity', 0) or 0
        estimate = 4*p + 9*f + 4*c + 2*fiber + 7*alcohol
        if abs(e-estimate) > max(D(25), e*D('.15')):
            warnings.append({'id': id, 'name': name, 'kcal': str(e), 'check_estimate': str(estimate)})
        raw = {'source_name': food['foodName'], 'source_id': id,
               'license': 'NLOD', 'snapshot': '2026-09-14',
               'edible_part': food['ediblePart'], 'calories': food['calories'],
               'energy': food['energy'], 'constituents': food['constituents'],
               'basis': '100 g edible portion', 'carbohydrate': 'available carbohydrate',
               'translation': 'cacalc Russian curation; source nutrition unchanged'}
        rows.append(('basic:no:'+id, None, name, '', norm(name+' '+food['foodName']), '', 'g',
                     str(e), str(food['energy']['quantity']), str(p), str(f), str(c), 'kcal',
                     food['uri'], None, json.dumps(raw, default=str, ensure_ascii=False), '[]'))
    if not rows: raise ValueError('Empty catalog')
    if rejected: raise ValueError('Selected invalid rows: '+json.dumps(rejected,ensure_ascii=False))
    sha = hashlib.sha256(source.read_bytes()).hexdigest()
    manifest = {'source': 'Norwegian Food Safety Authority — Matvaretabellen',
                'license': 'NLOD', 'scope': 'Curated basic foods with Russian names', 'schema_version': 2,
                'snapshot_date': '2026-09-14', 'rows': len(rows), 'source_rows': len(foods),
                'inputs': [{'url': 'https://www.matvaretabellen.no/api/en/foods.json', 'sha256': sha}],
                'translation': 'Russian names curated in cacalc; original names and nutrition retained',
                'carbohydrate_definition': 'available carbohydrate; fibre separate'}
    output.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='cacalc-catalog-') as temp:
        db_path = Path(temp)/'catalog.sqlite'
        db=sqlite3.connect(db_path)
        db.executescript((ROOT/'cacalc/schema.sql').read_text().replace('PRAGMA user_version = 1;', 'PRAGMA user_version = 2;').replace('barcode TEXT PRIMARY KEY NOT NULL,', 'id TEXT PRIMARY KEY NOT NULL,\n    barcode TEXT,'))
        db.executemany('INSERT INTO products VALUES ('+','.join('?'*17)+')', rows)
        db.executemany('INSERT INTO metadata VALUES (?,?)', [(k,json.dumps(v,ensure_ascii=False)) for k,v in manifest.items()])
        db.commit()
        assert db.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
        assert db.execute('SELECT count(*) FROM products').fetchone()[0]==len(rows)
        db.close()
        target=output.with_suffix('.staging')
        target.write_bytes(db_path.read_bytes()); target.replace(output)
    manifest['sha256']=hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_name('catalog.manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
    audit = {'source_rows':len(foods),'imported':len(rows),'not_selected':len(foods)-len(rows),
             'rejected':rejected,'energy_warnings':warnings,
             'kcal_min':str(min(D(r[7]) for r in rows)), 'kcal_max':str(max(D(r[7]) for r in rows)),
             'checks':['finite nonnegative values','kcal <= 950/100g','each macro <= 100g/100g',
                       'macro sum <= 102g (rounding margin)','all four values present with units',
                       'unique IDs and Russian names','SQLite integrity'],
             'source_sha256':sha, 'notes':'Not a laboratory verification. Energy formula is only a warning, never a replacement.'}
    report_path.parent.mkdir(parents=True,exist_ok=True)
    report_path.write_text(json.dumps(audit,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(audit,ensure_ascii=False,indent=2))
if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--source',type=Path,default=ROOT/'data/matvaretabellen/foods.json')
    parser.add_argument('--names',type=Path,default=ROOT/'data/curation/basic-food-names-ru.txt')
    parser.add_argument('--output',type=Path,default=ROOT/'ios/Resources/catalog.sqlite')
    parser.add_argument('--report',type=Path,default=ROOT/'reports/basic-foods-20260914/import-audit.json')
    a=parser.parse_args();build(a.source,a.names,a.output,a.report)
