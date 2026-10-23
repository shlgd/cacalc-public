#!/usr/bin/env python3
"""Read local matching-v1 diagnostics. Does not upload or modify input files."""
import argparse
import collections
import json
from pathlib import Path


def summarize(directory):
    counts = collections.Counter()
    corrections = []
    missing_context = []
    timings = []
    unreadable = 0
    for path in sorted(Path(directory).glob('*.json')):
        try:
            event = json.loads(path.read_text())
            if event.get('version') != 'matching-v1':
                continue
            kind = event.get('event', 'unknown')
            counts[kind] += 1
            if kind == 'ranking':
                if event.get('milliseconds'):
                    timings.append(float(event['milliseconds']))
                if event.get('winnerOutsideContext') == 'true':
                    missing_context.append((event.get('food'), event.get('globalWinner')))
            if kind == 'choice' and event.get('before') != event.get('after'):
                corrections.append({key: event.get(key) for key in
                                    ('food', 'before', 'after', 'inContext', 'candidateRank', 'traceID')})
        except (OSError, ValueError, TypeError, AttributeError):
            unreadable += 1
    timings.sort()
    return {
        'events': dict(counts),
        'unreadable': unreadable,
        'global_winners_outside_context': missing_context,
        'user_changes': corrections,
        'ranking_ms_median': timings[len(timings) // 2] if timings else None,
        'ranking_ms_p95': timings[min(len(timings) - 1, int(len(timings) * .95))] if timings else None,
        'note': 'Смена выбора — наблюдение, не доказанная ошибка. Баллы не являются вероятностями. '
                'Отсутствие исправлений не доказывает точность. Логи ограничены сроком и размером.',
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    if not args.directory.is_dir():
        parser.error('Укажите существующий каталог выгруженных диагностических JSON.')
    print(json.dumps(summarize(args.directory), ensure_ascii=False, indent=2))
