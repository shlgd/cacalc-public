#!/usr/bin/env python3
"""Summarize an exported UsageArchive locally; never sends data anywhere."""
import argparse
import collections
import hashlib
import zlib
import json
import sqlite3
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('archive', type=Path, nargs='?', help='Historical UsageArchive directory, if present')
parser.add_argument('--database', type=Path, help='Optional DiagnosticEvents/events-v1.sqlite from the same export')
parser.add_argument('--legacy-archive', type=Path, help='Verified compressed legacy-logs.sqlite')
args = parser.parse_args()
if args.archive is None and args.database is None and args.legacy_archive is None:
    parser.error("Provide a UsageArchive directory, --database or --legacy-archive")
if args.archive is not None and not args.archive.is_dir():
    parser.error("Archive directory does not exist: " + str(args.archive))
counts = collections.Counter()
controls = collections.Counter()
seconds = collections.Counter()
seen = set()
errors = []
sessions = set()
def include(event):
    if event.get('schema') != 'usage-v1':
        return
    identity = event['eventID']
    if identity in seen:
        return
    seen.add(identity)
    sessions.add(event['sessionID'])
    counts[event['event']] += 1
    if event['event'] == 'actionInvoked':
        controls[event['controlID']] += 1
    if event['event'] == 'screenTime':
        seconds[event['measuredScreen']] += float(event['seconds'])

if args.archive:
    for path in args.archive.rglob('*.json'):
        try:
            include(json.loads(path.read_text()))
        except (OSError, ValueError, KeyError) as exc:
            errors.append({'file': str(path), 'error': str(exc)})
if args.legacy_archive:
    try:
        with sqlite3.connect(args.legacy_archive.resolve().as_uri() + '?mode=ro', uri=True) as database:
            if database.execute("SELECT value FROM metadata WHERE key='complete'").fetchone() != ('1',):
                raise ValueError("Legacy export is incomplete")
            for relative, size, checksum, codec, payload in database.execute("SELECT path,raw_bytes,sha256,codec,payload FROM files WHERE path LIKE 'Documents/UsageArchive/%'"):
                try:
                    if codec not in (0, 1):
                        raise ValueError("Unknown archive codec")
                    raw = zlib.decompress(payload, -15) if codec == 1 else payload
                    if len(raw) != size or hashlib.sha256(raw).hexdigest() != checksum:
                        raise ValueError("Archived event checksum mismatch")
                    include(json.loads(raw))
                except (ValueError, KeyError, zlib.error) as exc:
                    errors.append({'file': relative, 'error': str(exc)})
    except (OSError, ValueError, sqlite3.Error) as exc:
        errors.append({'archive': str(args.legacy_archive), 'error': str(exc)})
if args.database:
    try:
        with sqlite3.connect(args.database.resolve().as_uri() + '?mode=ro', uri=True) as database:
            for (payload,) in database.execute("SELECT payload FROM events WHERE stream='usage' ORDER BY sequence"):
                try:
                    include(json.loads(payload))
                except (ValueError, KeyError) as exc:
                    errors.append({'database': str(args.database), 'error': str(exc)})
    except (OSError, sqlite3.Error) as exc:
        errors.append({'database': str(args.database), 'error': str(exc)})
print(json.dumps({'events': len(seen), 'sessions': len(sessions),
    'activeSecondsByScreen': dict(seconds.most_common()),
    'actions': dict(controls.most_common()), 'eventCounts': dict(counts.most_common()),
    'readErrors': errors}, ensure_ascii=False, indent=2))
if errors:
    raise SystemExit(1)
