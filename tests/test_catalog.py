import csv
import gzip
import hashlib
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from cacalc.catalog import (
    build_catalog, catalog_stats, lookup, open_catalog, portion, search,
)


FIXTURE = Path(__file__).parent / 'fixtures' / 'off-demo.tsv'


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.db = self.root / 'catalog.sqlite'

    def build(self, **kwargs):
        return build_catalog(FIXTURE, self.db, demo=True, **kwargs)

    def make_input(self, rows):
        fields = list(dict.fromkeys(key for row in rows for key in row))
        path = self.root / 'input.tsv'
        with path.open('w', newline='', encoding='utf-8') as handle:
            writer = csv.DictWriter(handle, fieldnames=fields, delimiter='\t')
            writer.writeheader()
            writer.writerows(rows)
        return path

    def row(self, **changes):
        return {'code': '0000000000009', 'product_name': 'ДЕМО',
                'countries_tags': 'en:russia', 'energy-kcal_100g': '100',
                'proteins_100g': '3', 'fat_100g': '2', 'carbohydrates_100g': '5',
                **changes}

    def test_whole_flow_works_without_network(self):
        with patch('socket.socket', side_effect=AssertionError('Network is forbidden')):
            report = self.build()
            self.assertEqual(report['stats']['imported'], 3)
            product = lookup(self.db, '0000000000001')
            self.assertEqual(product['barcode'], '0000000000001')
            result = portion(product, '120', 'g', 'g')
            self.assertEqual(result['nutrition'], {
                'energy_kcal': '360.00', 'protein_g': '12.00',
                'fat_g': '6.00', 'carbohydrate_g': '60.00'})
            self.assertEqual(len(search(self.db, 'ПШЕННАЯ')), 1)
            self.assertEqual(catalog_stats(self.db)['source'], 'synthetic-demo')

    def test_country_filter_uses_exact_tag_and_not_barcode_prefix(self):
        path = self.make_input([
            self.row(code='0000000000001', countries_tags='en:france, en:russia'),
            self.row(code='4600000000002', countries_tags='en:belarus'),
            self.row(code='4600000000003', countries_tags='en:russia-other'),
        ])
        report = build_catalog(path, self.db, demo=True)
        self.assertEqual(report['stats']['outside_country'], 2)
        self.assertIsNotNone(lookup(self.db, '0000000000001'))
        self.assertIsNone(lookup(self.db, '4600000000002'))

    def test_missing_nutrients_are_not_zero(self):
        self.build()
        product = lookup(self.db, '0000000000003')
        self.assertIsNone(product['protein_g_100'])
        self.assertEqual(product['fat_g_100'], '0')
        result = portion(product, '50', 'g', 'g')
        self.assertFalse(result['nutrition_complete'])
        self.assertIsNone(result['nutrition']['protein_g'])
        self.assertEqual(result['nutrition']['fat_g'], '0.00')

    def test_all_countries_keeps_exact_codes_and_source_country_tags(self):
        path = self.make_input([
            self.row(code='0000000000001', countries_tags='en:russia'),
            self.row(code='0000000000002', countries_tags='en:japan'),
            self.row(code='0000000000003', countries_tags=''),
        ])
        with patch('socket.socket', side_effect=AssertionError('Network is forbidden')):
            report = build_catalog(path, self.db, demo=True, country=None)
            self.assertEqual(report['stats']['imported'], 3)
            self.assertEqual(report['stats']['outside_country'], 0)
            self.assertIsNone(catalog_stats(self.db)['country_filter'])
            self.assertEqual(lookup(self.db, '0000000000002')['countries_tags'], 'en:japan')
            self.assertEqual(lookup(self.db, '0000000000003')['countries_tags'], '')

    def test_kj_conversion_and_label_energy_priority(self):
        path = self.make_input([
            self.row(code='0000000000001', **{'energy-kcal_100g': '', 'energy_100g': '418.4'}),
            self.row(code='0000000000002', **{'energy-kcal_100g': '123.4', 'energy_100g': '418.4'}),
        ])
        build_catalog(path, self.db, demo=True)
        converted = lookup(self.db, '0000000000001')
        self.assertEqual(converted['energy_kcal_100'], '100')
        self.assertEqual(converted['energy_origin'], 'kj')
        self.assertIn('energy_converted_from_kj', converted['issues'])
        labelled = lookup(self.db, '0000000000002')
        self.assertEqual(labelled['energy_kcal_100'], '123.4')
        self.assertEqual(labelled['energy_origin'], 'kcal')

    def test_invalid_nutrition_remains_unknown_and_explained(self):
        for value in ('-1', 'NaN', 'Infinity', 'not a number', '1e10000', '1e-1000000'):
            with self.subTest(value=value):
                path = self.make_input([self.row(proteins_100g=value)])
                build_catalog(path, self.db, demo=True, replace=self.db.exists())
                product = lookup(self.db, '0000000000009')
                self.assertIsNone(product['protein_g_100'])
                self.assertIn('invalid:proteins_100g', product['issues'])
                self.assertEqual(product['raw_nutrition']['proteins_100g'], value)

    def test_fractional_values_keep_precision_until_display(self):
        path = self.make_input([self.row(proteins_100g='3,125')])
        build_catalog(path, self.db, demo=True)
        product = lookup(self.db, '0000000000009')
        self.assertEqual(product['protein_g_100'], '3.125')
        self.assertEqual(portion(product, '12.5', 'g', 'g')['nutrition']['protein_g'], '0.39')

    def test_ambiguous_basis_requires_confirmation_and_no_automatic_density(self):
        self.build()
        product = lookup(self.db, '0000000000002')
        with self.assertRaisesRegex(ValueError, 'Уточните'):
            portion(product, '100', 'g')
        with self.assertRaisesRegex(ValueError, 'плотность'):
            portion(product, '100', 'g', 'ml')
        self.assertEqual(portion(product, '150', 'ml', 'ml')['nutrition']['energy_kcal'], '75.00')
        self.assertEqual(lookup(self.db, '0000000000002')['basis_unit'], 'unknown')

    def test_reject_invalid_portions(self):
        self.build()
        product = lookup(self.db, '0000000000001')
        for amount in ('0', '-1', 'NaN', 'Infinity', '1e10000', '1e-1000000', 'abc'):
            with self.subTest(amount=amount), self.assertRaises(ValueError):
                portion(product, amount, 'g', 'g')
        with self.assertRaises(ValueError):
            portion(product, '2', 'pieces', 'g')

    def test_lookup_is_exact_and_search_special_characters_are_literal(self):
        self.build()
        self.assertIsNone(lookup(self.db, '1'))
        self.assertIsNone(lookup(self.db, "' OR 1=1 --"))
        self.assertEqual(search(self.db, '%'), [])
        self.assertEqual(search(self.db, '_'), [])
        with self.assertRaises(ValueError):
            search(self.db, ' ')

    def test_rebuild_is_explicit_and_reproducible(self):
        report = self.build()
        with self.assertRaises(FileExistsError):
            self.build()
        second = self.build(replace=True)
        self.assertEqual(report['input_sha256'], second['input_sha256'])
        self.assertEqual(report['stats'], second['stats'])

    def test_empty_or_malformed_import_does_not_replace_previous_catalog(self):
        self.build()
        digest = hashlib.sha256(self.db.read_bytes()).hexdigest()
        for text in (
            'not\ta\tdataset\n',
            'code\tproduct_name\tcountries_tags\tenergy-kcal_100g\n',
            'code\tproduct_name\tcountries_tags\tenergy-kcal_100g\n0000000000001\tDemo\ten:russia\n',
        ):
            with self.subTest(text=text):
                path = self.root / 'broken.tsv'
                path.write_text(text)
                with self.assertRaises(ValueError):
                    build_catalog(path, self.db, demo=True, replace=True)
                self.assertEqual(hashlib.sha256(self.db.read_bytes()).hexdigest(), digest)
                self.assertEqual(list(self.root.glob('*.tmp')), [])

    def test_duplicate_barcode_does_not_silently_choose_a_card(self):
        path = self.make_input([self.row(), self.row(product_name='Другой продукт')])
        with self.assertRaisesRegex(ValueError, 'Повторный штрихкод'):
            build_catalog(path, self.db, demo=True)
        self.assertFalse(self.db.exists())

    def test_bad_identity_is_counted(self):
        path = self.make_input([self.row(), self.row(code='not-a-code'), self.row(product_name='')])
        result = build_catalog(path, self.db, demo=True)
        self.assertEqual(result['stats']['invalid_identity'], 2)
        self.assertEqual(result['stats']['imported'], 1)

    def test_gzip_input_and_corrupt_archive(self):
        path = self.root / 'export.csv.gz'
        path.write_bytes(gzip.compress(b'\xef\xbb\xbf' + FIXTURE.read_bytes()))
        build_catalog(path, self.db, demo=True)
        self.assertIsNotNone(lookup(self.db, '0000000000001'))
        before = self.db.read_bytes()
        path.write_bytes(path.read_bytes()[:-5])
        with self.assertRaises(EOFError):
            build_catalog(path, self.db, demo=True, replace=True)
        self.assertEqual(self.db.read_bytes(), before)

    def test_source_metadata_and_quality_tags(self):
        path = self.make_input([self.row(data_quality_errors_tags='en:test-issue')])
        with self.assertRaisesRegex(ValueError, 'source-url'):
            build_catalog(path, self.db)
        report = build_catalog(path, self.db, source_url='https://example.test/export.tsv')
        self.assertEqual(report['license'], 'ODbL-1.0')
        self.assertEqual(report['input_sha256'], hashlib.sha256(path.read_bytes()).hexdigest())
        self.assertEqual(catalog_stats(self.db), report)
        self.assertIn('source:en:test-issue', lookup(self.db, '0000000000009')['issues'])

    def test_read_only_and_missing_path_never_creates_a_database(self):
        with self.assertRaises(sqlite3.Error):
            lookup(self.db, '0000000000001')
        self.assertFalse(self.db.exists())
        self.build()
        connection = open_catalog(self.db)
        self.addCleanup(connection.close)
        with self.assertRaises(sqlite3.Error):
            connection.execute('DELETE FROM products')

    def test_refuse_to_replace_unrelated_database(self):
        with sqlite3.connect(self.db) as connection:
            connection.execute('CREATE TABLE personal_diary (id INTEGER)')
        before = self.db.read_bytes()
        with self.assertRaises(ValueError):
            self.build(replace=True)
        self.assertEqual(self.db.read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
