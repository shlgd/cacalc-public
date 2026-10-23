"""Bounded, lossless meal phrase segmentation experiment; no model or diary writes.

Quantities and discourse markers suggest boundaries. A chunk is source text,
not a resolved product, portion or nutrition record. Ambiguous text is retained.
"""
import re

from meal_span_linker import NUMBER, NUTRIENT, QUANTITY, quantities

TRANSITION = r"(?:потом|затем|ещ[её]|также|плюс)"
ACTION = r"(?:съел[аи]?|ел[аи]?|ем|выпил[аи]?|пил[аи]?|пью|добавил[аи]?|добавляю|добавь|положил[аи]?|взял[аи]?|запиши)"
HELPERS = re.compile(
    rf"^\s*(?:(?:я|ну|вот|сегодня|утром|{TRANSITION}|{ACTION}|и|а)\b|"
    r"на\s+(?:завтрак|обед|ужин)\b|в\s+(?:кафе|ресторане)\b)[\s,:—-]*",
    re.IGNORECASE,
)
NUTRIENT_WORD = r"(?:белк(?:и|а|ов)?|жир(?:ы|а|ов)?|углевод(?:ы|а|ов)?|калори(?:и|й)|ккал|сахар(?:а)?)"
NUTRIENT_BEFORE = re.compile(rf"\b{NUTRIENT_WORD}\s*[:=—-]?\s*$", re.IGNORECASE)
FIELD_START = re.compile(
    rf"^(?:{NUTRIENT_WORD}\s*[:=—-]?\s*(?:{NUMBER})\b|"
    r"(?:марка|бренд|производитель|название)\b)", re.IGNORECASE,
)
SEPARATOR = re.compile(rf"(?P<punct>[,;.!?\n])|\b(?P<transition>{TRANSITION})\b|\b(?P<and>и)\b", re.IGNORECASE)


def _payload(text):
    """Strip leading discourse words for boundary decisions only, never the output."""
    text = text.strip(" \t\r\n,;.!?—-")
    while True:
        trimmed, count = HELPERS.subn("", text, count=1)
        if not count:
            return text
        text = trimmed


def _description(text):
    return bool(re.search(r"[^\W\d_]", _payload(QUANTITY.sub(" ", text))))


def _metadata(text):
    text = _payload(text)
    if FIELD_START.match(text):
        return True
    prefix = re.match(r"^(?:на|в|пачка|пачке|пакет|пакете|упаковка|упаковке|бутылка|масса нетто)\s+", text, re.IGNORECASE)
    return bool(prefix and QUANTITY.match(text, prefix.end()))


def _serving_hints(text):
    active, _, _ = quantities(text)
    # These are only boundary hints. Label numbers remain inside the source chunk.
    return [q for q in active if not NUTRIENT_BEFORE.search(text[:q["start"]])
            and not NUTRIENT.match(text, q["end"])]


def _separators(text):
    protected = [(m.start(), m.end()) for m in QUANTITY.finditer(text)]
    protected += [(m.start(), m.end()) for m in re.finditer(r'«[^»]*»|"[^"]*"|“[^”]*”', text)]
    protected += [(m.start(), m.end()) for m in re.finditer(r"\d+[.,]\s*\d+|\b(?:запятая|точка)[,.]\s*\d+", text, re.IGNORECASE)]
    result = []
    for match in SEPARATOR.finditer(text):
        if any(start <= match.start() < end for start, end in protected):
            continue
        point = match.end() if match["punct"] else match.start()
        kind = ("sentence" if match["punct"] in (".", "!", "?", ";", "\n") else
                "comma" if match["punct"] else "transition" if match["transition"] else "conjunction")
        result.append((point, kind))
    return result


def _explicit_boundaries(text):
    candidates = _separators(text)
    accepted = []
    start = 0
    for index, (point, kind) in enumerate(candidates):
        next_point = candidates[index+1][0] if index+1 < len(candidates) else len(text)
        left, right = text[start:point], text[point:next_point]
        # A comma before a quantity, label or package detail does not start a food.
        if not _description(left) or not _description(right) or _metadata(right):
            continue
        right_action = re.match(rf"^\s*(?:(?:и|{TRANSITION})\b\s*)*{ACTION}\b", right, re.IGNORECASE)
        if kind in ("sentence", "transition") or right_action or _serving_hints(left):
            accepted.append((point, kind))
            start = point
    return accepted


def _quantity_boundaries(text, offset):
    hints = _serving_hints(text)
    if len(hints) < 2:
        return []
    prefix_text = text[:hints[0]["start"]]
    # Use a common order within this clause; do not guess mixed, unmarked orders.
    if not _description(prefix_text):
        pieces = [text[q["end"]:(hints[i+1]["start"] if i+1 < len(hints) else len(text))]
                  for i, q in enumerate(hints)]
        if all(_description(piece) and not _metadata(piece) for piece in pieces):
            return [(offset + q["start"], "quantity_before_description") for q in hints[1:]]
    else:
        pieces = [text[(hints[i-1]["end"] if i else 0):q["start"]] for i, q in enumerate(hints)]
        if all(_description(piece) and not _metadata(piece) for piece in pieces):
            return [(offset + q["end"], "quantity_after_description") for q in hints[:-1]]
    return []


def _review_reasons(text):
    hints = _serving_hints(text)
    reasons = []
    if len(hints) > 1:
        reasons.append("ambiguous_quantity_order")
    if any(kind == "conjunction" and _description(text[:point]) and _description(text[point:])
           for point, kind in _separators(text)):
        reasons.append("unresolved_conjunction")
    if len(hints) == 1:
        before, after = text[:hints[0]["start"]], text[hints[0]["end"]:]
        if _description(before) and _description(after) and not _metadata(after):
            reasons.append("text_on_both_sides_of_quantity")
    return reasons


def chunk(text):
    """Return contiguous, half-open Python string ranges covering the entire input."""
    if not isinstance(text, str) or len(text) > 6000:
        raise ValueError("Expected source text of at most 6000 characters")
    result = {"schema_version": 1, "offset_unit": "unicode_code_point", "source_text": text}
    if not text.strip():
        return {**result, "chunks": []}
    if sum(1 for _ in QUANTITY.finditer(text)) > 128:
        return {**result, "chunks": [{"start": 0, "end": len(text), "text": text,
                 "boundary_reason": "start", "review_reasons": ["too_many_quantities"]}]}
    explicit = _explicit_boundaries(text)
    boundaries = [(0, "start"), *explicit, (len(text), "end")]
    inferred = []
    for (start, _), (end, _) in zip(boundaries, boundaries[1:]):
        inferred += _quantity_boundaries(text[start:end], start)
    boundaries = sorted(dict([*boundaries, *inferred]).items())
    if len(boundaries) > 65:
        return {**result, "chunks": [{"start": 0, "end": len(text), "text": text,
                 "boundary_reason": "start", "review_reasons": ["too_many_chunks"]}]}
    chunks = []
    for (start, reason), (end, _) in zip(boundaries, boundaries[1:]):
        chunks.append({"start": start, "end": end, "text": text[start:end],
                       "boundary_reason": reason, "review_reasons": _review_reasons(text[start:end])})
    return {**result, "chunks": chunks}
