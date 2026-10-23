"""Historical OFF V1 builder. Current basic catalog: tools/build_basic_catalog.py."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CODES = ('4600605026533', '4600605033951')

def prepare(base, additions, output, *, allow_catalog_switch=False):
    base, additions, output = map(Path, (base, additions, output))
    if output.resolve() in {base.resolve(), additions.resolve()}:
        raise ValueError('Output must not replace source catalogs')
    if output.exists():
        try:
            with sqlite3.connect(output.resolve().as_uri() + '?mode=ro', uri=True) as existing:
                family = existing.execute('PRAGMA user_version').fetchone()[0]
        except sqlite3.DatabaseError as error:
            raise ValueError('Existing output is unreadable; it has been preserved') from error
        if family != 1 and not allow_catalog_switch:
            raise ValueError('Refusing to replace the current basic catalog with historical OFF V1; use build_basic_catalog.py. An intentional switch requires --allow-catalog-switch.')
    for path in (base, additions):
        with sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True) as c:
            if c.execute('PRAGMA application_id').fetchone()[0] != 1128350529 or c.execute('PRAGMA user_version').fetchone()[0] != 1:
                raise ValueError('Unsupported source catalog')
            if c.execute('PRAGMA quick_check').fetchone()[0] != 'ok':
                raise ValueError('Corrupt source catalog')
    output.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(dir=output.parent, suffix='.sqlite')
    os.close(fd)
    try:
        shutil.copyfile(base, temp)
        with sqlite3.connect(temp) as dest, sqlite3.connect(additions.resolve().as_uri() + '?mode=ro', uri=True) as extra:
            extra.row_factory = sqlite3.Row
            for code in CODES:
                row = extra.execute('SELECT * FROM products WHERE barcode=?', (code,)).fetchone()
                if row is None:
                    raise ValueError(f'Missing audited product: {code}')
                old = dest.execute('SELECT source_modified_at FROM products WHERE barcode=?', (code,)).fetchone()
                if old and int(old[0] or 0) > int(row['source_modified_at'] or 0):
                    raise ValueError(f'Base contains a newer product: {code}; audit it before replacing')
                columns = ','.join(row.keys())
                dest.execute(f"INSERT OR REPLACE INTO products ({columns}) VALUES ({','.join('?' for _ in row)})", tuple(row))
            count = dest.execute('SELECT count(*) FROM products').fetchone()[0]
            manifest = {
                'source': 'Open Food Facts contributors', 'license': 'ODbL-1.0',
                'scope': 'Russia slice plus two audited world barcodes; not full market coverage',
                'rows': count, 'audited_barcodes': list(CODES),
                'inputs': [{'file': p.name, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()} for p in (base, additions)],
            }
            dest.execute('INSERT OR REPLACE INTO metadata VALUES (?,?)', ('ios_bundle', json.dumps(manifest, ensure_ascii=False)))
            dest.commit()
            if dest.execute('PRAGMA quick_check').fetchone()[0] != 'ok':
                raise ValueError('Output integrity check failed')
        os.replace(temp, output)
        manifest['sha256'] = hashlib.sha256(output.read_bytes()).hexdigest()
        output.with_suffix('.manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n')
        return manifest
    finally:
        Path(temp).unlink(missing_ok=True)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', type=Path, default=ROOT/'data/catalogs/off-ru.sqlite')
    parser.add_argument('--additions', type=Path, default=ROOT/'data/catalogs/off-fridge.sqlite')
    parser.add_argument('--output', type=Path, default=ROOT/'ios/Resources/catalog.sqlite')
    parser.add_argument('--legacy-off', action='store_true', help='Explicitly select historical OFF V1 preparation')
    parser.add_argument('--allow-catalog-switch', action='store_true', help='Allow replacing a different catalog family')
    args = parser.parse_args()
    if not args.legacy_off:
        parser.error('Current catalog command: python3 tools/build_basic_catalog.py. Historical OFF requires --legacy-off.')
    print(json.dumps(prepare(args.base, args.additions, args.output, allow_catalog_switch=args.allow_catalog_switch), ensure_ascii=False, indent=2))
