#!/usr/bin/env python3
"""Synthetic, offline checks of the compressed archive's actual consumers."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import uuid
import zlib

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('archive_verifier', ROOT / 'verify_legacy_log_archive.py')
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)

class LegacyToolsTests(unittest.TestCase):
    def test_verified_archive_usage_and_deduplication(self):
        with tempfile.TemporaryDirectory(prefix='legacy-tools-') as folder:
            path = Path(folder) / 'legacy.sqlite'
            database = Path(folder) / 'current.sqlite'
            session = str(uuid.uuid4())
            events = [dict(schema='usage-v1', eventID=str(uuid.uuid4()), sessionID=session,
                           time='2026-10-05T00:00:00Z', event='actionInvoked', controlID='synthetic-button'),
                      dict(schema='usage-v1', eventID=str(uuid.uuid4()), sessionID=session,
                           time='2026-10-05T00:00:01Z', event='screenTime', measuredScreen='diary', seconds='12.5')]
            with sqlite3.connect(path) as db:
                db.executescript('CREATE TABLE files(path TEXT PRIMARY KEY,raw_bytes INTEGER NOT NULL,sha256 TEXT NOT NULL,codec INTEGER NOT NULL,payload BLOB NOT NULL); CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL); INSERT INTO metadata VALUES("complete","1");')
                for event in events:
                    raw = json.dumps(event).encode()
                    compressor = zlib.compressobj(wbits=-15)
                    payload = compressor.compress(raw) + compressor.flush()
                    db.execute('INSERT INTO files VALUES(?,?,?,?,?)',
                               (f'Documents/UsageArchive/2026-10-05/{event["eventID"]}.json', len(raw), hashlib.sha256(raw).hexdigest(), 1, payload))
            verified = verifier.verify(path)
            self.assertEqual(verified['files'], 2)
            self.assertEqual(verified['origin_counts'], {'UsageArchive': 2})
            with sqlite3.connect(database) as db:
                db.execute('CREATE TABLE events(sequence INTEGER PRIMARY KEY,stream TEXT NOT NULL,id TEXT NOT NULL,time TEXT NOT NULL,event TEXT NOT NULL,payload BLOB NOT NULL,UNIQUE(stream,id))')
                first = events[0]
                db.execute('INSERT INTO events(stream,id,time,event,payload) VALUES(?,?,?,?,?)',
                           ('usage', first['eventID'], first['time'], first['event'], json.dumps(first).encode()))
            result = subprocess.run([sys.executable, '-B', str(ROOT / 'summarize_usage.py'),
                                     '--legacy-archive', str(path), '--database', str(database)], capture_output=True, text=True, check=True)
            summary = json.loads(result.stdout)
            self.assertEqual(summary['events'], 2)
            self.assertEqual(summary['sessions'], 1)
            self.assertEqual(summary['activeSecondsByScreen'], {'diary': 12.5})
            self.assertEqual(summary['actions'], {'synthetic-button': 1})
            self.assertEqual(summary['readErrors'], [])
            with sqlite3.connect(path) as db:
                db.execute('UPDATE files SET sha256=?', ('0' * 64,))
            with self.assertRaises(ValueError):
                verifier.verify(path)
            rejected = subprocess.run([sys.executable, '-B', str(ROOT / 'summarize_usage.py'), '--legacy-archive', str(path)], capture_output=True, text=True)
            self.assertEqual(rejected.returncode, 1)
            self.assertEqual(len(json.loads(rejected.stdout)['readErrors']), 2)

if __name__ == '__main__':
    unittest.main()
