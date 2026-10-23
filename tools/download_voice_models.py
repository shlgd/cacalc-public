#!/usr/bin/env python3
"""Development helper: same pinned artifacts as the iPhone's explicit downloader."""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]

def checksum(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=ROOT / 'data/voice-models')
    parser.add_argument('--manifest', type=Path, default=ROOT / 'ios/Resources/voice-models.json')
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    def download(job):
        model, file = job
        path = args.output / (model['id'] + '-' + model['revision']) / file['path']
        if path.exists() and path.stat().st_size == file['bytes'] and checksum(path) == file['sha256']:
            return
        path.parent.mkdir(parents=True, exist_ok=True)
        temp = path.with_suffix(path.suffix + '.partial')
        with urlopen(f'https://huggingface.co/{model["repository"]}/resolve/{model["revision"]}/{file["path"]}') as response, temp.open('wb') as out:
            while chunk := response.read(1024 * 1024): out.write(chunk)
        if temp.stat().st_size != file['bytes'] or checksum(temp) != file['sha256']:
            raise ValueError(f'Checksum/length mismatch: {file["path"]}')
        temp.replace(path)
        print(model['id'], file['path'], flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(download, [(m, f) for m in manifest['models'] for f in m['files']]))
    print(f'All artifacts verified in {args.output}')

if __name__ == '__main__': main()
