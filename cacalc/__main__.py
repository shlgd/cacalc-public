"""CLI for the local catalog; run with python3 -m cacalc --help."""

import argparse
import csv
import json
import sqlite3
import sys
from pathlib import Path

from .catalog import build_catalog, catalog_stats, lookup, portion, search


def main(argv=None):
    parser = argparse.ArgumentParser(description='Локальный каталог продуктов cacalc')
    parser.add_argument('--db', type=Path, default=Path('data/catalogs/off-ru.sqlite'))
    commands = parser.add_subparsers(dest='command', required=True)
    importer = commands.add_parser('import-off', help='Собрать SQLite из локального CSV/TSV OFF')
    importer.add_argument('input', type=Path)
    importer.add_argument('--source-url', help='URL происхождения входной выгрузки (сеть не используется)')
    country_filter = importer.add_mutually_exclusive_group()
    country_filter.add_argument('--country', default='en:russia')
    country_filter.add_argument('--all-countries', action='store_true',
                                help='Импортировать все страны, сохранив исходные теги')
    importer.add_argument('--scope', default='unspecified', help='Полная выгрузка или описание выборки')
    importer.add_argument('--demo', action='store_true', help='Пометить все данные как синтетические')
    importer.add_argument('--replace', action='store_true', help='Заменить существующий каталог cacalc')
    importer.add_argument('--delimiter', choices=('tab', 'comma'), default='tab')
    finder = commands.add_parser('lookup', help='Найти точный штрихкод')
    finder.add_argument('barcode')
    searcher = commands.add_parser('search', help='Найти по названию или бренду')
    searcher.add_argument('query')
    searcher.add_argument('--limit', type=int, default=20)
    calculator = commands.add_parser('portion', help='Посчитать порцию без записи в дневник')
    calculator.add_argument('barcode')
    calculator.add_argument('amount')
    calculator.add_argument('--unit', choices=('g', 'ml'), required=True)
    calculator.add_argument('--confirmed-basis', choices=('g', 'ml'),
                            help='Подтверждённая по этикетке единица значений на 100')
    commands.add_parser('stats', help='Источник, версия, контрольная сумма и качество импорта')
    args = parser.parse_args(argv)
    try:
        if args.command == 'import-off':
            result = build_catalog(args.input, args.db, source_url=args.source_url,
                                   country=None if args.all_countries else args.country,
                                   demo=args.demo, replace=args.replace,
                                   delimiter='\t' if args.delimiter == 'tab' else ',', scope=args.scope)
        elif args.command == 'lookup':
            result = lookup(args.db, args.barcode)
            if result is None:
                print(json.dumps({'found': False, 'barcode': args.barcode}, ensure_ascii=False))
                return 1
        elif args.command == 'search':
            result = search(args.db, args.query, args.limit)
        elif args.command == 'portion':
            result = portion(lookup(args.db, args.barcode), args.amount, args.unit, args.confirmed_basis)
        else:
            result = catalog_stats(args.db)
    except (OSError, ValueError, sqlite3.Error, csv.Error, EOFError) as error:
        print(f'Ошибка: {error}', file=sys.stderr)
        return 2
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
