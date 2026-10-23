"""Build and query an OFF catalog from local tab-separated exports."""

import csv
import gzip
import hashlib
import json
import os
import re
import sqlite3
import tempfile
import unicodedata
from collections import Counter
from contextlib import closing
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from pathlib import Path


APPLICATION_ID = 1128350529
SCHEMA_VERSION = 1
NUTRIENTS = ('energy_kcal_100', 'protein_g_100', 'fat_g_100', 'carbohydrate_g_100')
RAW_FIELDS = (
    'energy-kcal_100g', 'energy-kj_100g', 'energy_100g',
    'proteins_100g', 'fat_100g', 'carbohydrates_100g',
)


def normalize_name(text):
    return ' '.join(unicodedata.normalize('NFKC', text).casefold().replace('ё', 'е').split())


def decimal_text(value):
    return format(value, 'f')


def valid_barcode(code):
    """Check the string shape; check-digit validation is a later scanner concern."""
    return re.fullmatch(r'(?:[0-9]{8}|[0-9]{12,14})', code) is not None


def nutrient(row, field, maximum, issues):
    raw = row.get(field, '').strip()
    if not raw:
        return None
    if len(raw) > 64:
        issues.append(f'invalid:{field}')
        return None
    try:
        value = Decimal(raw.replace(',', '.'))
    except InvalidOperation:
        issues.append(f'invalid:{field}')
        return None
    # Conservative limits support both 100 g and denser products labelled /100 ml.
    if not value.is_finite() or not Decimal(0) <= value <= maximum:
        issues.append(f'invalid:{field}')
        return None
    # Prevent exponent strings from expanding into arbitrarily large text values.
    if not -12 <= value.as_tuple().exponent <= 12:
        issues.append(f'invalid:{field}')
        return None
    return value


def normalize_product(row, demo=False):
    issues = []
    kcal = nutrient(row, 'energy-kcal_100g', Decimal(2000), issues)
    kj_field = 'energy-kj_100g' if row.get('energy-kj_100g', '').strip() else 'energy_100g'
    kj = nutrient(row, kj_field, Decimal(10000), issues)
    energy_origin = 'kcal' if kcal is not None else 'missing'
    if kcal is None and kj is not None:
        kcal = kj / Decimal('4.184')
        energy_origin = 'kj'
        issues.append('energy_converted_from_kj')
    values = (
        kcal,
        nutrient(row, 'proteins_100g', Decimal(200), issues),
        nutrient(row, 'fat_100g', Decimal(200), issues),
        nutrient(row, 'carbohydrates_100g', Decimal(200), issues),
    )
    for key, value in zip(NUTRIENTS, values):
        if value is None:
            issues.append(f'missing:{key}')
    issues.append('basis_unknown')
    issues.extend(
        f'source:{tag.strip()}'
        for tag in row.get('data_quality_errors_tags', '').split(',') if tag.strip()
    )
    if demo:
        issues.append('synthetic_demo')
    code = row['code'].strip()
    name = row['product_name'].strip()
    brands = row.get('brands', '').strip()
    return {
        'barcode': code,
        'name': name,
        'brands': brands,
        'search_name': normalize_name(f'{name} {brands}'),
        'countries_tags': row['countries_tags'].strip(),
        # OFF's _100g suffix also represents 100 ml. Never infer this from a name.
        'basis_unit': 'unknown',
        **{key: decimal_text(value) if value is not None else None
           for key, value in zip(NUTRIENTS, values)},
        'energy_kj_100': decimal_text(kj) if kj is not None else None,
        'energy_origin': energy_origin,
        'source_url': None if demo else f'https://world.openfoodfacts.org/product/{code}',
        'source_modified_at': row.get('last_modified_t', '').strip() or None,
        'raw_nutrition_json': json.dumps(
            {key: row.get(key, '') for key in RAW_FIELDS}, ensure_ascii=False),
        'issues_json': json.dumps(issues, ensure_ascii=False),
    }


def open_catalog(path):
    """Read-only access must not create an empty database for a misspelled path."""
    connection = sqlite3.connect(Path(path).resolve().as_uri() + '?mode=ro', uri=True)
    connection.row_factory = sqlite3.Row
    if (connection.execute('PRAGMA application_id').fetchone()[0] != APPLICATION_ID
            or connection.execute('PRAGMA user_version').fetchone()[0] != SCHEMA_VERSION):
        connection.close()
        raise ValueError('Неподдерживаемый файл или версия каталога.')
    return connection


def build_catalog(input_path, output_path, *, source_url=None, country='en:russia',
                  demo=False, replace=False, delimiter='\t', scope='unspecified'):
    """Stream a local file and atomically publish a complete catalog snapshot."""
    input_path, output_path = Path(input_path), Path(output_path)
    if input_path.resolve() == output_path.resolve():
        raise ValueError('Входная выгрузка и выходная база должны быть разными файлами.')
    if not demo and not source_url:
        raise ValueError('Укажите --source-url для происхождения реальной выгрузки.')
    if delimiter not in ('\t', ','):
        raise ValueError('Поддерживаются разделители tab и comma.')
    if output_path.exists():
        if not replace:
            raise FileExistsError('Каталог уже существует. Для обновления укажите --replace.')
        # Refuse to replace a personal database or unrelated SQLite file.
        with closing(open_catalog(output_path)):
            pass
    before = input_path.stat()
    with input_path.open('rb') as source:
        digest = hashlib.file_digest(source, 'sha256').hexdigest()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(prefix=output_path.name + '.', suffix='.tmp',
                                         dir=output_path.parent)
    os.close(handle)
    stats = Counter(rows_read=0, outside_country=0, invalid_identity=0,
                    imported=0, complete_nutrition=0, incomplete_nutrition=0)
    issue_counts = Counter()
    csv.field_size_limit(16 * 1024 * 1024)
    opener = gzip.open if input_path.suffix == '.gz' else open
    try:
        with closing(sqlite3.connect(temporary)) as connection:
            connection.executescript(Path(__file__).with_name('schema.sql').read_text())
            with connection, opener(input_path, 'rt', encoding='utf-8-sig', newline='') as source:
                reader = csv.DictReader(source, delimiter=delimiter, strict=True)
                fields = reader.fieldnames or []
                if not {'code', 'product_name', 'countries_tags'}.issubset(fields):
                    raise ValueError('Нужны столбцы code, product_name, countries_tags; проверьте разделитель.')
                if len(set(fields)) != len(fields) or not set(RAW_FIELDS).intersection(fields):
                    raise ValueError('Повторные заголовки или отсутствуют столбцы пищевой ценности.')
                for row in reader:
                    stats['rows_read'] += 1
                    if None in row or any(value is None for value in row.values()):
                        raise ValueError(f'Повреждена строка {reader.line_num}: неверное число столбцов.')
                    countries = {tag.strip() for tag in row['countries_tags'].split(',')}
                    if country is not None and country not in countries:
                        stats['outside_country'] += 1
                        continue
                    if not valid_barcode(row['code'].strip()) or not row['product_name'].strip():
                        stats['invalid_identity'] += 1
                        continue
                    product = normalize_product(row, demo)
                    columns = ', '.join(product)
                    placeholders = ', '.join('?' for _ in product)
                    try:
                        connection.execute(f'INSERT INTO products ({columns}) VALUES ({placeholders})',
                                           tuple(product.values()))
                    except sqlite3.IntegrityError as error:
                        raise ValueError(f'Повторный штрихкод {product["barcode"]}; каталог не заменён.') from error
                    stats['imported'] += 1
                    complete = all(product[key] is not None for key in NUTRIENTS)
                    stats['complete_nutrition' if complete else 'incomplete_nutrition'] += 1
                    issue_counts.update(json.loads(product['issues_json']))
                if not stats['imported']:
                    raise ValueError('Нет подходящих продуктов; прежний каталог сохранён.')
                after = input_path.stat()
                if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                    raise ValueError('Выгрузка изменилась во время импорта; повторите со стабильным файлом.')
                metadata = {
                    'schema_version': SCHEMA_VERSION,
                    'source': 'synthetic-demo' if demo else 'openfoodfacts',
                    'license': 'synthetic-test-data' if demo else 'ODbL-1.0',
                    'license_url': None if demo else 'https://opendatacommons.org/licenses/odbl/1-0/',
                    'attribution': 'Synthetic examples' if demo else 'Open Food Facts contributors',
                    'source_url': None if demo else source_url,
                    'dataset_scope': 'synthetic-examples' if demo else scope,
                    'input_sha256': digest,
                    'input_file': input_path.name,
                    'input_bytes': before.st_size,
                    'built_at': datetime.now(timezone.utc).isoformat(),
                    'country_filter': country,
                    'stats': dict(stats),
                    'issue_counts': dict(issue_counts),
                }
                connection.executemany('INSERT INTO metadata VALUES (?, ?)',
                                       [(key, json.dumps(value, ensure_ascii=False))
                                        for key, value in metadata.items()])
            if connection.execute('PRAGMA quick_check').fetchone()[0] != 'ok':
                raise ValueError('SQLite quick_check не пройден; прежний каталог сохранён.')
        # Same filesystem, closed/committed SQLite file; readers see a complete snapshot.
        os.replace(temporary, output_path)
        return metadata
    finally:
        Path(temporary).unlink(missing_ok=True)


def public_product(row):
    if row is None:
        return None
    product = dict(row)
    product.pop('search_name')
    product['issues'] = json.loads(product.pop('issues_json'))
    product['raw_nutrition'] = json.loads(product.pop('raw_nutrition_json'))
    product['nutrition_complete'] = all(product[key] is not None for key in NUTRIENTS)
    return product


def lookup(path, barcode):
    with closing(open_catalog(path)) as connection:
        return public_product(connection.execute('SELECT * FROM products WHERE barcode = ?',
                                                  (barcode.strip(),)).fetchone())


def search(path, query, limit=20):
    query = normalize_name(query)
    if not query or not 1 <= limit <= 100:
        raise ValueError('Нужен непустой запрос и limit от 1 до 100.')
    # instr treats % and _ literally; SQLite lower() is insufficient for Cyrillic.
    with closing(open_catalog(path)) as connection:
        return [public_product(row) for row in connection.execute(
            'SELECT * FROM products WHERE instr(search_name, ?) > 0 ORDER BY name, barcode LIMIT ?',
            (query, limit))]


def catalog_stats(path):
    with closing(open_catalog(path)) as connection:
        return {row['key']: json.loads(row['value'])
                for row in connection.execute('SELECT key, value FROM metadata')}


def portion(product, amount, unit, confirmed_basis=None):
    if product is None:
        raise ValueError('Продукт не найден.')
    amount_text = str(amount).replace(',', '.')
    if len(amount_text) > 64:
        raise ValueError('Слишком длинная запись количества.')
    try:
        amount = Decimal(amount_text)
    except InvalidOperation as error:
        raise ValueError('Количество должно быть числом.') from error
    if not amount.is_finite() or not Decimal(0) < amount <= Decimal(1_000_000):
        raise ValueError('Количество должно быть больше 0 и не больше 1 000 000 г/мл.')
    if not -12 <= amount.as_tuple().exponent <= 12:
        raise ValueError('Неподдерживаемая точность количества.')
    if unit not in ('g', 'ml') or confirmed_basis not in (None, 'g', 'ml'):
        raise ValueError('Поддерживаются единицы g и ml.')
    basis = product['basis_unit']
    if basis == 'unknown':
        if confirmed_basis is None:
            raise ValueError('Уточните по этикетке базу: --confirmed-basis g или ml.')
        basis = confirmed_basis
    elif confirmed_basis is not None and confirmed_basis != basis:
        raise ValueError('Подтверждение противоречит единице карточки.')
    if basis != unit:
        raise ValueError('Единица порции не совпадает с базой; плотность не известна.')
    result = {}
    for key in NUTRIENTS:
        value = product[key]
        total = None if value is None else Decimal(value) * amount / Decimal(100)
        result[key.removesuffix('_100')] = (
            None if total is None else decimal_text(total.quantize(Decimal('0.01'), rounding=ROUND_HALF_UP)))
    return {
        'barcode': product['barcode'], 'name': product['name'],
        'amount': decimal_text(amount), 'unit': unit, 'basis_unit': basis,
        'basis_confirmed_for_calculation': confirmed_basis is not None,
        'nutrition': result, 'nutrition_complete': product['nutrition_complete'],
        'source_url': product['source_url'], 'issues': product['issues'],
    }
