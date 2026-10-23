"""Offline, reproducible quality audit of the complete OFF Russia extracts.

Run with .venv/bin/python tools/audit_off.py. Network access is not used here.
Raw files and generated catalogs stay outside Git. See docs/research/off-audit.md.
"""

import csv
import hashlib
import json
import re
import sqlite3
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from cacalc.catalog import (NUTRIENTS, RAW_FIELDS, build_catalog, catalog_stats,
                           normalize_product, valid_barcode)


def parquet_product(row):
    """Adapt only as-sold /100 values; never substitute prepared/serving values."""
    names = {item['lang']: item['text'] for item in row['product_name'] or []
             if item.get('text') and item['text'].strip()}
    name = (names.get('ru') or names.get(row.get('lang')) or names.get('main')
            or next(iter(names.values()), ''))
    nutriments = {}
    for item in row['nutriments'] or []:
        key = item['name']
        if key in nutriments:
            raise ValueError(f'Duplicate nutrient {key} in {row["code"]}')
        nutriments[key] = item['100g']
    return {
        'code': row['code'] or '', 'product_name': name,
        'brands': row['brands'] or '',
        'countries_tags': ','.join(row['countries_tags'] or []),
        **{field: '' if nutriments.get(field.removesuffix('_100g')) is None
           # Nine significant digits round-trip Float32 without promoting its
           # binary tail to a long, falsely precise decimal from Python float64.
           else format(nutriments[field.removesuffix('_100g')], '.9g') for field in RAW_FIELDS},
        'last_modified_t': str(row['last_modified_t'] or ''),
        'data_quality_errors_tags': ','.join(row['data_quality_errors_tags'] or []),
    }


def checksum_valid(code):
    if not re.fullmatch(r'(?:[0-9]{8}|[0-9]{12,14})', code):
        return False
    total = sum(int(n) * (3 if i % 2 == 0 else 1)
                for i, n in enumerate(reversed(code[:-1])))
    return (10 - total % 10) % 10 == int(code[-1])


def profile(path):
    c = sqlite3.connect(path)
    c.row_factory = sqlite3.Row
    rows = {r['barcode']: dict(r) for r in c.execute('SELECT * FROM products')}
    assert c.execute('PRAGMA quick_check').fetchone()[0] == 'ok'
    c.close()
    complete = lambda p: all(p[k] is not None for k in NUTRIENTS)
    def nutrition_errors(p):
        return any(i.startswith('source:') and any(word in i for word in
                   ['nutrition', 'nutrient', 'energy', 'serving'])
                   for i in json.loads(p['issues_json']))
    fields = {k: sum(p[k] is not None for p in rows.values()) for k in NUTRIENTS}
    cutoff = int(datetime(2025, 9, 6, tzinfo=timezone.utc).timestamp())
    end = int(datetime(2026, 9, 7, tzinfo=timezone.utc).timestamp())
    modified = [int(p['source_modified_at']) for p in rows.values()
                if p['source_modified_at'] and p['source_modified_at'].isdigit()]
    ready = [p for p in rows.values() if complete(p)]
    brands = {
        'ВкусВилл': ['вкусвилл', 'vkusvill'],
        'Простоквашино': ['простоквашино', 'prostokvashino'],
        'Вкуснотеево': ['вкуснотеево', 'vkusnoteevo'],
        'ЭкоНива': ['эконива', 'ekoniva'],
        'Мираторг': ['мираторг', 'miratorg'],
        'Макфа': ['макфа', 'makfa'],
        'Увелка': ['увелка', 'uvelka'],
        'Bombbar': ['bombbar', 'bomb bar', 'бомббар'],
    }
    brand_rows = []
    for name, aliases in brands.items():
        found = [p for p in rows.values() if any(a in p['search_name'] for a in aliases)]
        brand_rows.append({'brand': name, 'found': len(found),
                           'complete': sum(complete(p) for p in found)})
    result = {
        'file': str(path.relative_to(ROOT)), 'bytes': path.stat().st_size,
        'metadata': catalog_stats(path), 'named_products': len(rows),
        'complete_nutrition': len(ready), 'nonmissing_by_field': fields,
        'invalid_gtin_checksum': sum(not checksum_valid(p['barcode']) for p in rows.values()),
        'complete_with_nutrition_errors': sum(nutrition_errors(p) for p in ready),
        'complete_valid_gtin_no_nutrition_errors': sum(
            checksum_valid(p['barcode']) and not nutrition_errors(p) for p in ready),
        'modified_in_last_year': sum(cutoff <= t < end for t in modified),
        'modified_missing': len(rows) - len(modified),
        'brand_presence': brand_rows,
        'sample_rule': 'first 10 complete products with valid GTIN, ordered by barcode',
        'sample': [{k: p[k] for k in ['barcode', 'name', 'brands', *NUTRIENTS]}
                   for p in sorted(ready, key=lambda r: r['barcode'])
                   if checksum_valid(p['barcode'])][:10],
    }
    return result, rows


def run():
    import duckdb
    raw = ROOT / 'data/raw'
    revision = json.loads((raw / 'off-hf-revision.json').read_text())
    source = f'https://huggingface.co/datasets/openfoodfacts/product-database/resolve/{revision["sha"]}/food.parquet'
    parquet_file = raw / 'off-ru-2026-09-06.parquet'
    conn = duckdb.connect(config={'memory_limit': '1GB'})
    records = conn.execute('SELECT * FROM read_parquet(?)', [str(parquet_file)]).fetchall()
    columns = [x[0] for x in conn.description]
    records = [dict(zip(columns, r)) for r in records]
    world_file = raw / 'off-benchmark-world.parquet'
    world_source, world_named = {}, {}
    if world_file.exists():
        world_records = conn.execute('SELECT * FROM read_parquet(?)', [str(world_file)]).fetchall()
        world_columns = [x[0] for x in conn.description]
        for values in world_records:
            adapted = parquet_product(dict(zip(world_columns, values)))
            code = adapted['code']
            if code in world_source:
                raise ValueError(f'Duplicate world benchmark code: {code}')
            world_source[code] = adapted
            if adapted['product_name'].strip() and valid_barcode(code):
                world_named[code] = normalize_product(adapted)
    conn.close()
    target = raw / 'off-ru-parquet-adapted.tsv'
    with target.open('w', encoding='utf-8', newline='') as f:
        fields = ['code', 'product_name', 'brands', 'countries_tags', *RAW_FIELDS,
                  'last_modified_t', 'data_quality_errors_tags']
        writer = csv.DictWriter(f, fieldnames=fields, delimiter='\t')
        writer.writeheader()
        writer.writerows(parquet_product(r) for r in records)
    database = ROOT / 'data/catalogs/off-ru.sqlite'
    build_catalog(target, database, source_url=source, replace=database.exists(),
                  scope=f'complete en:russia country slice of HF Parquet {revision["sha"]}; no sampling')
    pq, pq_rows = profile(database)
    csv_result, csv_rows = profile(ROOT / 'data/catalogs/off-ru-full-csv.sqlite')
    shared = pq_rows.keys() & csv_rows.keys()
    same_modified = [k for k in shared if pq_rows[k]['source_modified_at'] == csv_rows[k]['source_modified_at']]
    def recovered(codes):
        return sum(all(pq_rows[k][n] is not None for n in NUTRIENTS)
                   and not all(csv_rows[k][n] is not None for n in NUTRIENTS) for k in codes)
    source_codes = {r['code'] for r in records}
    benchmark = json.loads((ROOT / 'docs/research/barcode-benchmark.json').read_text())
    benchmark_rows = []
    for item in benchmark['products']:
        p = pq_rows.get(item['barcode'])
        complete = bool(p and all(p[n] is not None for n in NUTRIENTS))
        status = ('Есть КБЖУ' if complete else 'Карточка без полного КБЖУ' if p
                  else 'Штрихкод без названия' if item['barcode'] in source_codes else 'Не найден')
        world_p = world_named.get(item['barcode'])
        world_complete = bool(world_p and all(world_p[n] is not None for n in NUTRIENTS))
        world_status = ('Есть КБЖУ' if world_complete else 'Карточка без полного КБЖУ' if world_p
                        else 'Штрихкод без названия' if item['barcode'] in world_source else 'Не найден')
        benchmark_rows.append({**item, 'source_found': item['barcode'] in source_codes,
                               'named_found': p is not None, 'complete': complete,
                               'off_name': p['name'] if p else None, 'status': status,
                               'world_found': item['barcode'] in world_source if world_file.exists() else None,
                               'world_complete': world_complete if world_file.exists() else None,
                               'world_name': world_p['name'] if world_p else None,
                               'world_status': world_status if world_file.exists() else 'Не проверен'})
    result = {
        'checked_at': datetime.now(timezone.utc).isoformat(),
        'question': 'Can an offline catalog avoid routine manual nutrition entry for Russian purchases?',
        'hf_revision': revision,
        'country_filter': 'exact countries_tags contains en:russia; not GTIN prefix or language',
        'parquet_country_rows': len(records),
        'parquet_sha256': hashlib.sha256(parquet_file.read_bytes()).hexdigest(),
        'nutrition_data_per': dict(Counter(r['nutrition_data_per'] for r in records)),
        'product_quantity_unit': dict(Counter(r['product_quantity_unit'] for r in records)),
        'obsolete_rows': sum(bool(r['obsolete']) for r in records),
        'csv': csv_result, 'parquet': pq,
        'benchmark': {
            'selection_rule': benchmark['selection_rule'], 'scope': benchmark['scope'],
            'tested': len(benchmark_rows),
            'source_found': sum(p['source_found'] for p in benchmark_rows),
            'named_found': sum(p['named_found'] for p in benchmark_rows),
            'complete': sum(p['complete'] for p in benchmark_rows), 'rows': benchmark_rows,
            'world_checked': world_file.exists(),
            'world_found': sum(bool(p['world_found']) for p in benchmark_rows) if world_file.exists() else None,
            'world_complete': sum(bool(p['world_complete']) for p in benchmark_rows) if world_file.exists() else None,
            'world_source_sha256': hashlib.sha256(world_file.read_bytes()).hexdigest() if world_file.exists() else None,
        },
        'comparison': {'shared_named_barcodes': len(shared),
                       'same_modified_barcodes': len(same_modified),
                       'recovered_complete_from_parquet': recovered(shared),
                       'recovered_complete_same_modified': recovered(same_modified)},
        'limitations': [
            'Country tags are incomplete. This is not all products sold in Russia.',
            'Brand presence is not market or personal-basket coverage.',
            'Four numbers do not prove label accuracy. Source errors and GTIN checks are additional filters.',
            'Float32 nutrition values in source Parquet may have binary representation noise.',
            'Per-100 basis is not proven to be grams; package quantity unit is not nutritional basis.',
            'Last modification timestamp is not a nutrition label verification date.',
            'CSV and Parquet contain different world populations; matched-timestamp comparison is reported separately.',
        ],
    }
    out = ROOT / 'docs/research/off-audit-results.json'
    out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    for name in ['csv', 'parquet']:
        print(name, {k: result[name][k] for k in ['named_products', 'complete_nutrition',
              'complete_valid_gtin_no_nutrition_errors', 'bytes']})
    print('comparison', result['comparison'])
    print('brands', json.dumps(pq['brand_presence'], ensure_ascii=False))
    print('benchmark', {k: result['benchmark'][k] for k in ['tested', 'source_found', 'named_found', 'complete', 'world_found', 'world_complete']})
    return result


if __name__ == '__main__':
    run()
