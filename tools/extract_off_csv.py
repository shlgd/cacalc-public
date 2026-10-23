"""Extract Russia from the OFF world gzip without unpacking it onto disk.

The official world TSV uses literal quotes, unlike the quoted TSV accepted by
our catalog importer. This tool validates every row width and rewrites quoting.
Reading the gzip to EOF also verifies its CRC. Existing output is not replaced.
"""

import argparse
import csv
import gzip
import hashlib
import json
from pathlib import Path

FIELDS = ['code', 'product_name', 'brands', 'countries_tags', 'energy-kcal_100g',
          'energy-kj_100g', 'energy_100g', 'proteins_100g', 'fat_100g',
          'carbohydrates_100g', 'data_quality_errors_tags', 'last_modified_t']


def extract(source, output):
    source, output = Path(source), Path(output)
    if output.exists() or output.with_suffix('.manifest.json').exists():
        raise FileExistsError('Choose a new output path to preserve the existing snapshot.')
    temporary = output.with_suffix(output.suffix + '.part')
    csv.field_size_limit(16 * 1024 * 1024)
    total = selected = 0
    try:
        with gzip.open(source, 'rt', encoding='utf-8-sig', newline='') as src, \
                temporary.open('x', encoding='utf-8', newline='') as dst:
            reader = csv.reader(src, delimiter='\t', quoting=csv.QUOTE_NONE)
            header = next(reader)
            country = header.index('countries_tags')
            indexes = [header.index(f) if f in header else None for f in FIELDS]
            writer = csv.writer(dst, delimiter='\t')
            writer.writerow(FIELDS)
            for row in reader:
                total += 1
                if len(row) != len(header):
                    raise ValueError(f'Wrong number of columns in row {total}')
                if 'en:russia' in row[country].split(','):
                    selected += 1
                    writer.writerow([row[i] if i is not None else '' for i in indexes])
                if total % 500000 == 0:
                    print(f'{total:,} world rows; {selected:,} Russia', flush=True)
        with source.open('rb') as f:
            digest = hashlib.file_digest(f, 'sha256').hexdigest()
        manifest = {'world_rows': total, 'russia_rows': selected,
                    'source_url': 'https://static.openfoodfacts.org/data/en.openfoodfacts.org.products.csv.gz',
                    'source_sha256': digest, 'source_bytes': source.stat().st_size,
                    'gzip_crc_verified': True, 'input_quoting': 'none; all row widths checked',
                    'filter': 'exact countries_tags contains en:russia'}
        temporary.rename(output)
        output.with_suffix('.manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        return manifest
    finally:
        # Never delete an already-existing .part file that we did not create.
        if 'dst' in locals():
            temporary.unlink(missing_ok=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source')
    parser.add_argument('output')
    args = parser.parse_args()
    print(json.dumps(extract(args.source, args.output), indent=2))
