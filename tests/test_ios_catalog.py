"""Synthetic catalog fixtures; no production nutrition data is generated here."""
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from tools.prepare_ios_catalog import prepare


class IOSCatalogTests(unittest.TestCase):
    def source(self, path, products):
        with sqlite3.connect(path) as c:
            c.executescript(Path('cacalc/schema.sql').read_text())
            for code, name, modified in products:
                c.execute('INSERT INTO products VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
                          (code, name, '', name, 'en:japan', 'unknown', '45', None,
                           '2.9', '1.5', '4.9', 'kcal', 'https://example.test', modified, '{}', '[]'))

    def test_merges_by_exact_code_preserves_country_and_sources(self):
        with tempfile.TemporaryDirectory() as d:
            base, extra, output = [Path(d)/n for n in ('base.sqlite','extra.sqlite','output.sqlite')]
            self.source(base, [('4600605033951','Old', '1')])
            self.source(extra, [('4600605026533','Milk', '2'), ('4600605033951','Yogurt','2')])
            manifest = prepare(base, extra, output)
            self.assertEqual(manifest['rows'], 2)
            with sqlite3.connect(output) as c:
                self.assertEqual(c.execute('SELECT name,countries_tags FROM products WHERE barcode=?', ('4600605026533',)).fetchone(), ('Milk','en:japan'))
                self.assertEqual(c.execute('SELECT name FROM products WHERE barcode=?', ('4600605033951',)).fetchone()[0], 'Yogurt')
            self.assertEqual(json.loads(output.with_suffix('.manifest.json').read_text())['rows'], 2)
            self.assertNotEqual(base.read_bytes(), output.read_bytes())

    def test_missing_audited_row_keeps_previous_output(self):
        with tempfile.TemporaryDirectory() as d:
            base, extra, output = [Path(d)/n for n in ('base.sqlite','extra.sqlite','output.sqlite')]
            self.source(base, [('4600605033951','Yogurt','1')])
            self.source(extra, [('4600605033951','Yogurt','1')])
            output.write_bytes(b'previous output')
            with self.assertRaises(ValueError):
                prepare(base, extra, output)
            self.assertEqual(output.read_bytes(), b'previous output')

    def test_refuses_source_as_output(self):
        with self.assertRaises(ValueError):
            prepare('base.sqlite', 'extra.sqlite', 'base.sqlite')

    def test_historical_builder_cannot_replace_basic_v2(self):
        with tempfile.TemporaryDirectory() as d:
            base, extra, output = [Path(d)/n for n in ('base.sqlite', 'extra.sqlite', 'output.sqlite')]
            self.source(base, [])
            self.source(extra, [('4600605026533', 'Milk', '2'), ('4600605033951', 'Yogurt', '2')])
            with sqlite3.connect(output) as db:
                db.execute('PRAGMA user_version = 2')
                db.execute('CREATE TABLE preserved(value TEXT)')
                db.execute("INSERT INTO preserved VALUES ('synthetic current basic catalog')")
            before = output.read_bytes()
            with self.assertRaisesRegex(ValueError, 'Refusing to replace'):
                prepare(base, extra, output)
            self.assertEqual(output.read_bytes(), before)
            prepare(base, extra, output, allow_catalog_switch=True)
            with sqlite3.connect(output) as db:
                self.assertEqual(db.execute('PRAGMA user_version').fetchone()[0], 1)
