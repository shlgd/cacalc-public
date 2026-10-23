#!/usr/bin/env python3
"""Offline validation of the actual import plus malicious/broken source values."""
import copy, json, sqlite3, tempfile
from decimal import Decimal as D
from pathlib import Path
from build_basic_catalog import ROOT, build, read, values
source=ROOT/'data/matvaretabellen/foods.json'
names=ROOT/'data/curation/basic-food-names-ru.txt'
foods=read(source)['foods'];by_id={f['foodId']:f for f in foods}
banana=by_id['06.525']
for bad in [D(10000),D(-1),D('NaN')]:
    f=copy.deepcopy(banana);f['calories']['quantity']=bad
    assert values(f)[1],bad
f=copy.deepcopy(banana);del f['calories']['quantity'];assert values(f)[1]
f=copy.deepcopy(banana);f['calories']['unit']='kJ';assert values(f)[1]
f=copy.deepcopy(banana)
for n in f['constituents']:
    if n['nutrientId']=='Protein':n['quantity']=D(120)
assert values(f)[1]
with tempfile.TemporaryDirectory(prefix='cacalc-basic-check-') as tmp:
    out=Path(tmp)/'catalog.sqlite';report=Path(tmp)/'audit.json'
    build(source,names,out,report)
    db=sqlite3.connect(out)
    assert db.execute('PRAGMA user_version').fetchone()[0]==2
    rows=db.execute('SELECT id,barcode,name,brands,basis_unit,energy_kcal_100,protein_g_100,fat_g_100,carbohydrate_g_100 FROM products').fetchall()
    assert len(rows)==474
    for id,barcode,name,brand,basis,*nums in rows:
        original,issues=values(by_id[id.removeprefix('basic:no:')])
        assert [D(v) for v in nums]==original and not issues
        assert barcode is None and brand=='' and basis=='g'
    # Invalid update must leave the existing valid database byte-for-byte intact.
    before=out.read_bytes()
    bad=read(source)
    next(f for f in bad['foods'] if f['foodId']=='06.525')['calories']['quantity']=10000
    broken=Path(tmp)/'bad.json';broken.write_text(json.dumps(bad,default=float))
    try:build(broken,names,out,report)
    except ValueError:pass
    else:raise AssertionError('Bad banana was accepted')
    assert out.read_bytes()==before
print('PASS: 474 exact source KBJU, schema/IDs, invalid/missing/wrong-unit/10000kcal rejection, previous database preserved')
