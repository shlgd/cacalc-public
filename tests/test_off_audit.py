"""Synthetic OFF adapter checks; no download or DuckDB needed."""

import csv
import gzip
import tempfile
import unittest
import struct
from pathlib import Path

from tools.audit_off import parquet_product, checksum_valid
from tools.extract_off_csv import extract
from cacalc.catalog import normalize_product


class OfflineAuditTests(unittest.TestCase):
    def test_prepared_values_do_not_fill_missing_as_sold_nutrition(self):
        row = {'code': '0000000000001', 'product_name': [{'lang': 'ru', 'text': 'Тест'}],
               'lang': 'ru', 'brands': None, 'countries_tags': ['en:russia'],
               'last_modified_t': None, 'data_quality_errors_tags': [],
               'nutriments': [{'name': 'fat', '100g': 0, 'prepared_100g': 8},
                              {'name': 'proteins', '100g': None, 'prepared_100g': 12}]}
        actual = parquet_product(row)
        self.assertEqual(actual['fat_100g'], '0')
        self.assertEqual(actual['proteins_100g'], '')
        self.assertEqual(actual['code'], '0000000000001')

    def test_float32_tail_does_not_turn_valid_nutrition_into_a_missing_value(self):
        value = struct.unpack('f', struct.pack('f', 3.2))[0]
        row = {'code': '0000000000001', 'product_name': [{'lang': 'ru', 'text': 'Тест'}],
               'lang': 'ru', 'brands': None, 'countries_tags': ['en:russia'],
               'last_modified_t': None, 'data_quality_errors_tags': [],
               'nutriments': [{'name': 'fat', '100g': value}]}
        adapted = parquet_product(row)
        self.assertEqual(struct.pack('f', float(adapted['fat_100g'])), struct.pack('f', value))
        self.assertIsNotNone(normalize_product(adapted)['fat_g_100'])

    def test_check_digit_preserves_leading_zeros(self):
        self.assertTrue(checksum_valid('0000000000000'))
        self.assertFalse(checksum_valid('0000000000001'))
        self.assertFalse(checksum_valid('123'))

    def test_literal_quotes_are_reencoded_without_changing_name(self):
        with tempfile.TemporaryDirectory() as d:
            source, output = Path(d) / 'world.gz', Path(d) / 'ru.tsv'
            with gzip.open(source, 'wt', encoding='utf-8') as f:
                f.write('code\tproduct_name\tcountries_tags\tenergy-kcal_100g\n')
                f.write('0000000000001\t"Тест" сыр\ten:russia\t123\n')
                f.write('0000000000002\tOther\ten:france\t100\n')
            manifest = extract(source, output)
            self.assertEqual(manifest['world_rows'], 2)
            self.assertEqual(manifest['russia_rows'], 1)
            with output.open() as f:
                rows = list(csv.DictReader(f, delimiter='\t', strict=True))
            self.assertEqual(rows[0]['product_name'], '"Тест" сыр')


if __name__ == '__main__':
    unittest.main()
