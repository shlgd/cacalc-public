import argparse
import hashlib
import json
from pathlib import Path
import re

parser = argparse.ArgumentParser()
parser.add_argument('directory', nargs='?', type=Path, default=Path(__file__).resolve().parents[1])
args = parser.parse_args()
root = args.directory.resolve()
patterns = {
    'private-key': r'-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----',
    'api-token': r'\b(?:sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[A-Z0-9]{16})\b',
    'personal-path': r'(?:[/]Users[/]|[/]home[/]|[/]Volumes[/]|[A-Z]:\\Users\\)[^\s"\x27]+',
    'device-id': r'\b00008[0-9]{3}-[A-Fa-f0-9]{16}\b',
    'signing-team': r'DEVELOPMENT_TEAM\s*[:=]\s*[\x27"]?[A-Z0-9]{10}\b',
    'credential-url': r'https?://[^\s/:]+:[^\s/@]+@',
    'private-network': r'\b(?:192\.168\.[0-9]+\.[0-9]+|10\.[0-9]+\.[0-9]+\.[0-9]+)\b',
    'assigned-secret': r'(?i)(?:api[_-]?key|password|secret|token)\s*[:=]\s*[\x27"][A-Za-z0-9_+/=-]{20,}[\x27"]',
}
blocked_parts = {'.env', 'xcuserdata', 'DerivedData', '__pycache__', 'reports', 'notebooks', 'backups'}
blocked_suffixes = {'.sqlite', '.sqlite3', '.db', '.wav', '.m4a', '.caf', '.zip', '.tar', '.gz', '.p12', '.p8', '.mobileprovision', '.safetensors', '.pyc', '.ipynb', '.patch', '.pdf'}
findings = []
files = {}
for path in sorted(root.rglob('*')):
    relative = path.relative_to(root)
    if '.git' in relative.parts:
        continue
    if path.is_symlink():
        findings.append((relative.as_posix(), 'symlink'))
        continue
    if not path.is_file():
        continue
    name = relative.as_posix()
    files[name] = path
    if any(part in blocked_parts or part.startswith('.env.') for part in relative.parts) or path.suffix in blocked_suffixes:
        findings.append((name, 'forbidden-file'))
    if path.stat().st_size > 5 * 1024 * 1024:
        findings.append((name, 'oversized-file'))
    if path.suffix == '.png' and name == 'ios/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png':
        continue
    try:
        text = path.read_text(encoding='utf-8')
    except UnicodeError:
        findings.append((name, 'unexpected-binary'))
        continue
    for rule, pattern in patterns.items():
        if re.search(pattern, text):
            findings.append((name, rule))
manifest_path = root / 'PUBLIC-MANIFEST.json'
if manifest_path.exists():
    entries = json.loads(manifest_path.read_text())['files']
    expected = {entry['path']: entry for entry in entries}
    if len(expected) != len(entries) or set(expected) != set(files) - {'PUBLIC-MANIFEST.json'}:
        findings.append(('PUBLIC-MANIFEST.json', 'file-list-mismatch'))
    for name, entry in expected.items():
        if name in files:
            raw = files[name].read_bytes()
            if len(raw) != entry['bytes'] or hashlib.sha256(raw).hexdigest() != entry['sha256']:
                findings.append((name, 'checksum-mismatch'))
for name, rule in findings:
    print(f'{name}: {rule}')
if findings:
    raise SystemExit(f'FAIL: {len(findings)} findings; values were not printed.')
print(f'PASS: {len(files)} files; privacy patterns, file types and available manifest checked.')
