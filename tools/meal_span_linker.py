"""Experimental, conservative meal binding for source spans (not an iOS parser).

The model locates food names. This module reads explicit quantities and retains
only links shared by every maximum matching of adjacent, compatible spans.
It does not fill missing portions, search a catalog or calculate nutrition.
"""
from decimal import Decimal, InvalidOperation
from functools import lru_cache
import re

GROUPS = [
    (0, "ноль нуль нуля"), (1, "один одна одно одну одного одной"),
    (2, "два две двух"), (3, "три трех"), (4, "четыре четырех"),
    (5, "пять пяти"), (6, "шесть шести"), (7, "семь семи"),
    (8, "восемь восьми"), (9, "девять девяти"), (10, "десять десяти"),
    (11, "одиннадцать"), (12, "двенадцать"), (13, "тринадцать"),
    (14, "четырнадцать"), (15, "пятнадцать"), (16, "шестнадцать"),
    (17, "семнадцать"), (18, "восемнадцать"), (19, "девятнадцать"),
    (20, "двадцать двадцати"), (30, "тридцать тридцати"), (40, "сорок сорока"),
    (50, "пятьдесят пятидесяти"), (60, "шестьдесят шестидесяти"),
    (70, "семьдесят семидесяти"), (80, "восемьдесят восьмидесяти"),
    (90, "девяносто девяноста"), (100, "сто ста"), (200, "двести двухсот"),
    (300, "триста трехсот"), (400, "четыреста четырехсот"),
    (500, "пятьсот пятисот"), (600, "шестьсот шестисот"),
    (700, "семьсот семисот"), (800, "восемьсот восьмисот"), (900, "девятьсот девятисот"),
]
INTEGERS = {word: value for value, words in GROUPS for word in words.split()}
SCALES = {word: 1000 for word in ("тысяча", "тысячи", "тысяч")}
HALVES = {"полтора": "1.5", "полторы": "1.5", "половина": "0.5"}
MARKERS = {"запятая", "запятой", "точка", "точкой", "целая", "целых", "целое", "и"}
DENOMINATORS = {"десятая": 1, "десятых": 1, "сотая": 2, "сотых": 2, "тысячная": 3, "тысячных": 3}
NUMERIC = r"\d+(?:[.,]\s*\d+)?"
WORD = "(?:" + "|".join(sorted(INTEGERS.keys() | SCALES.keys() | HALVES.keys(), key=len, reverse=True)) + ")"
EXTRA = "(?:" + "|".join(sorted(MARKERS | DENOMINATORS.keys(), key=len, reverse=True)) + ")"
NUMBER = rf"(?:{NUMERIC}|{WORD})(?:(?:\s+|(?<=[,.])(?=\d))(?:{NUMERIC}|{WORD}|{EXTRA})(?:[,\.](?=\s*\d))?)*"
UNIT = r"(?:килограмм(?:а|ов)?|миллилитр(?:а|ов)?|грамм(?:а|ов)?|литр(?:а|ов)?|порци(?:я|и|ю|й)|штук(?:а|и)?|гр|кг|мл|г|л)"
QUANTITY = re.compile(rf"(?<![\w.,])(?P<amount>{NUMBER})\s*(?P<unit>{UNIT})(?![\w])", re.IGNORECASE)
NUTRIENT = re.compile(r"\s+(белк(?:а|ов|и)|жир(?:а|ов|ы)|углевод(?:а|ов|ы)|сахар(?:а|ов)?|клетчатк(?:а|и))\b", re.IGNORECASE)
PACKAGE_WEIGHT = re.compile(r"\b(?P<marker>пачка|пачке|пакет|пакете|упаковка|упаковке|бутылка|масса нетто)\s*$", re.IGNORECASE)
BARRIER = re.compile(r"[.!?;\n]|\b(?:и|а|ещ[её]|также|потом|затем|плюс)\b", re.IGNORECASE)


def integer(words):
    if not words:
        return None
    if len(words) == 1 and words[0].isdigit():
        return int(words[0])
    for i, word in enumerate(words):
        if word in SCALES:
            before = integer(words[:i]) if i else 1
            after = integer(words[i+1:]) if i + 1 < len(words) else 0
            if before is None or after is None or not 0 < before < 1000 or not 0 <= after < 1000:
                return None
            return before * 1000 + after
    value, ceiling = 0, 1000
    for word in words:
        number = INTEGERS.get(word)
        if number is None or number >= ceiling:
            return None
        value += number
        ceiling = 100 if number >= 100 else 10 if number >= 20 else 0
    return value


def number_value(source):
    text = source.casefold().replace("ё", "е").strip()
    if re.fullmatch(NUMERIC, text):
        try:
            return Decimal(re.sub(r"\s", "", text).replace(",", "."))
        except InvalidOperation:
            return None
    if text in HALVES:
        return Decimal(HALVES[text])
    words = re.sub(r"(запятая|запятой|точка|точкой)[,.]?", r"\1 ", text).split()
    denominator = DENOMINATORS.get(words[-1]) if words else None
    if denominator:
        words = words[:-1]
    marker = next((i for i, word in enumerate(words) if word in MARKERS), None)
    if marker is None:
        value = integer(words)
        if value is None:
            return None
        return Decimal(value).scaleb(-denominator) if denominator else Decimal(value)
    whole, fraction = integer(words[:marker]), words[marker+1:]
    if whole is None or not fraction:
        return None
    # "пять и восемь" is a bounded decimal shorthand; do not reinterpret 150 и 200.
    if words[marker] == "и" and whole > 9:
        return None
    if all(word in INTEGERS and INTEGERS[word] < 10 or word.isdigit() and len(word) == 1 for word in fraction):
        digits = "".join(str(INTEGERS[word]) if word in INTEGERS else word for word in fraction)
    else:
        part = integer(fraction)
        if part is None:
            return None
        digits = str(part)
    if denominator:
        if len(digits) > denominator:
            return None
        digits = digits.zfill(denominator)
    if len(digits) > 6:
        return None
    return Decimal(f"{whole}.{digits}")


def quantities(text):
    found, ignored, nonfood_ranges = [], [], []
    for match in QUANTITY.finditer(text):
        value = number_value(match["amount"])
        before = text[:match.start()].casefold()
        nutrient = NUTRIENT.match(text, match.end())
        # Match original text: casefold can change Unicode length and invalidate offsets.
        package = PACKAGE_WEIGHT.search(text[:match.start()])
        reason = None
        if re.search(r"(?:\bминус|[-−<>])\s*$", before) or value is None:
            reason = "unclear_number"
        elif re.search(r"\bна\s*$", before):
            reason = "label_basis"
        elif package:
            reason = "package_weight"
            # Only exclude the marker attached to an explicit package weight.
            # A packaging word elsewhere, or inside a longer food name, is retained.
            nonfood_ranges.append(package.span("marker"))
        elif nutrient and re.search(r"\bна\s+100\b", before):
            reason = "nutrition_value"
            nonfood_ranges.append((nutrient.start(1), nutrient.end(1)))
        item = {"text": match[0], "start": match.start(), "end": match.end(),
                "amount": match["amount"], "unit": match["unit"],
                "value": format(value, "f") if value is not None else None}
        if reason:
            ignored.append({**item, "reason": reason})
        else:
            found.append(item)
    return found, ignored, nonfood_ranges


def link(text, food_spans):
    if len(text) > 6000 or len(food_spans) > 64:
        raise ValueError("Input exceeds the bounded meal experiment")
    qs, ignored, nonfood = quantities(text)
    all_quantity_ranges = [(q["start"], q["end"]) for q in qs + ignored]
    foods, dropped = [], []
    for food in sorted(food_spans, key=lambda span: span["start"]):
        if not (0 <= food["start"] < food["end"] <= len(text) and text[food["start"]:food["end"]] == food["text"]):
            raise ValueError("Food span does not match source")
        if any(start <= food["start"] and food["end"] <= end for start, end in all_quantity_ranges + nonfood):
            dropped.append(food)
        else:
            foods.append(food)
    nodes = sorted([{"kind": "food", "index": i, **f} for i, f in enumerate(foods)] +
                   [{"kind": "quantity", "index": i, **q} for i, q in enumerate(qs)],
                   key=lambda n: (n["start"], n["end"]))
    allowed = set()
    for i in range(len(nodes)-1):
        left, right = nodes[i:i+2]
        if left["kind"] != right["kind"] and left["end"] <= right["start"] and not BARRIER.search(text[left["end"]:right["start"]]):
            allowed.add(i)

    @lru_cache(None)
    def solve(i):
        if i >= len(nodes):
            return 0, frozenset()
        options = [solve(i+1)]
        if i in allowed:
            score, edges = solve(i+2)
            options.append((score+1, edges | {i}))
        best_score = max(score for score, _ in options)
        choices = [edges for score, edges in options if score == best_score]
        forced = choices[0]
        for choice in choices[1:]:
            forced = forced & choice
        return best_score, forced

    _, edges = solve(0)
    assigned, used = {}, set()
    for i in edges:
        left, right = nodes[i:i+2]
        food, quantity = (left, right) if left["kind"] == "food" else (right, left)
        assigned[food["index"]] = quantity
        used.add(quantity["index"])
    entries = []
    for i, food in enumerate(foods):
        q = assigned.get(i)
        entries.append({"food": food["text"], "amount": q["amount"] if q else None,
                        "unit": q["unit"] if q else None, "value": q["value"] if q else None,
                        "food_span": [food["start"], food["end"]],
                        "quantity_span": [q["start"], q["end"]] if q else None})
    return {"items": entries, "unassigned_quantities": [q for i, q in enumerate(qs) if i not in used],
            "ignored_quantities": ignored, "excluded_food_spans": dropped}
