#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
maintenance_check_dir=$(mktemp -d)
trap 'rm -rf "$maintenance_check_dir"' EXIT HUP INT TERM
xcrun swiftc -O -swift-version 6 -parse-as-library -module-cache-path "$maintenance_check_dir/modules" ios/Cacalc/StorageUsageProbe.swift ios/Cacalc/ProcessMemory.swift tools/StorageMaintenanceBench/main.swift -lsqlite3 -o "$maintenance_check_dir/check"
"$maintenance_check_dir/check" "$maintenance_check_dir/fixture.sqlite"
python3 tools/verify_legacy_log_archive.py "$maintenance_check_dir/fixture.sqlite" --report "$maintenance_check_dir/verified.json"
python3 -B - "$maintenance_check_dir/fixture.sqlite" <<'PY'
import importlib.util, sqlite3, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location('verify_archive', 'tools/verify_legacy_log_archive.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
path = Path(sys.argv[1])
with sqlite3.connect(path) as db:
    db.execute("UPDATE files SET sha256=? WHERE path=(SELECT path FROM files LIMIT 1)", ('0'*64,))
try:
    module.verify(path)
except ValueError:
    print('PASS: independent verifier rejects a corrupt checksum')
else:
    raise RuntimeError('Corrupt archive accepted')
with sqlite3.connect(path) as db:
    db.execute("DELETE FROM metadata WHERE key='complete'")
try:
    module.verify(path)
except ValueError:
    print('PASS: independent verifier rejects an incomplete archive')
else:
    raise RuntimeError('Incomplete archive accepted')
PY
