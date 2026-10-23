#!/usr/bin/env python3
"""Verify the external SQLite archive before authorizing deletion of original iPhone logs.
Private data stays in the archive. The report contains only sizes, hashes and event counts.
"""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import zlib

def verify(path):
    with path.open('rb') as source:
        digest = hashlib.file_digest(source, 'sha256').hexdigest()
    db = sqlite3.connect(f'file:{path.resolve()}?mode=ro', uri=True)
    if db.execute('PRAGMA integrity_check').fetchall() != [('ok',)]:
        raise ValueError('Archive integrity_check failed')
    if db.execute("SELECT value FROM metadata WHERE key='complete'").fetchone() != ('1',):
        raise ValueError('Archive is incomplete')
    pattern = re.compile(r'Documents/(?:DictationArchive/|UsageArchive/\d{4}-\d{2}-\d{2}/)[0-9A-Fa-f-]{36}\.json\Z')
    events = collections.Counter(); event_bytes = collections.Counter(); origins = collections.Counter()
    files = raw_bytes = packed_bytes = 0
    for relative, size, checksum, codec, blob in db.execute('SELECT path,raw_bytes,sha256,codec,payload FROM files'):
        if not pattern.fullmatch(relative) or codec not in (0, 1):
            raise ValueError(f'Unsafe path/codec: {relative}')
        raw = zlib.decompress(blob, -15) if codec == 1 else blob
        if len(raw) != size or hashlib.sha256(raw).hexdigest() != checksum:
            raise ValueError(f'Corrupt payload: {relative}')
        try:
            event = json.loads(raw).get('event', '(missing)')
        except (ValueError, AttributeError):
            event = '(invalid JSON preserved)'
        if not isinstance(event, str) or len(event) > 160:
            event = '(nonstandard event preserved)'
        events[event] += 1; event_bytes[event] += size
        origins[relative.split('/')[1]] += 1
        files += 1; raw_bytes += size; packed_bytes += len(blob)
    db.close()
    return dict(verified=True, sha256=digest, files=files, raw_bytes=raw_bytes, packed_payload_bytes=packed_bytes, archive_bytes=path.stat().st_size, event_counts=events.most_common(), event_raw_bytes=event_bytes.most_common(), origin_counts=dict(origins))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path); parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    result = verify(args.archive)
    args.report.write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k not in ('event_counts', 'event_raw_bytes')}))
