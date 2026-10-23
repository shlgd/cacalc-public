"""Offline checks for the experimental meal linker; no model or user diary."""
from decimal import Decimal
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from meal_span_linker import link, number_value, quantities


def foods(text, names):
    result = []
    start = 0
    for name in names:
        position = text.index(name, start)
        result.append({"text": name, "start": position, "end": position + len(name)})
        start = position + len(name)
    return result


class MealSpanLinkerTests(unittest.TestCase):
    def test_decimal_values(self):
        for source, expected in [("12,5", "12.5"), ("12.5", "12.5"), ("0", "0"),
                                 ("ноль запятая ноль пять", "0.05"), ("пять запятая,8", "5.8"),
                                 ("двести пятьдесят", "250"), ("одну", "1"), ("полтора", "1.5"),
                                 ("пять и восемь", "5.8"), ("две целых пять сотых", "2.05"),
                                 ("тысяча двести", "1200")]:
            with self.subTest(source=source):
                self.assertEqual(number_value(source), Decimal(expected))
        for source in ("один сорок два", "150 и 200", "не знаю", "пять шесть"):
            self.assertIsNone(number_value(source))

    def test_four_different_weights_are_not_reused(self):
        text = "Овсянка 120 грамм, молоко 400 мл, протеин 30 грамм и мёд 20 грамм."
        result = link(text, foods(text, ["Овсянка", "молоко", "протеин", "мёд"]))
        self.assertEqual([r["value"] for r in result["items"]], ["120", "400", "30", "20"])
        self.assertFalse(result["unassigned_quantities"])

    def test_amount_before_food(self):
        text = "Добавь 90 г тунца, 110 г кукурузы и 70 г фасоли."
        result = link(text, foods(text, ["тунца", "кукурузы", "фасоли"]))
        self.assertEqual([r["value"] for r in result["items"]], ["90", "110", "70"])

    def test_fractions_and_false_food_inside_number(self):
        text = "Масла пять запятая,8 грамма."
        result = link(text, foods(text, ["Масла", "запятая"]))
        self.assertEqual(len(result["items"]), 1)
        self.assertEqual(result["items"][0]["value"], "5.8")

    def test_no_guessing_when_one_amount_could_belong_to_either_food(self):
        text = "Хлеб 50 г сыр"
        result = link(text, foods(text, ["Хлеб", "сыр"]))
        self.assertEqual([r["value"] for r in result["items"]], [None, None])
        self.assertEqual(len(result["unassigned_quantities"]), 1)

    def test_conjunction_separates_an_unweighed_food(self):
        text = "Хлеб 50 г и сыр"
        result = link(text, foods(text, ["Хлеб", "сыр"]))
        self.assertEqual([r["value"] for r in result["items"]], ["50", None])

    def test_no_link_across_sentences(self):
        text = "Хлеб. 50 грамм сыра."
        result = link(text, foods(text, ["Хлеб", "сыра"]))
        self.assertEqual([r["value"] for r in result["items"]], [None, "50"])

    def test_unknown_portion_and_unconverted_units(self):
        text = "Суп, молоко 250мл и яблоко 120г"
        result = link(text, foods(text, ["Суп", "молоко", "яблоко"]))
        self.assertEqual([(r["value"], r["unit"]) for r in result["items"]],
                         [(None, None), ("250", "мл"), ("120", "г")])

    def test_package_and_nutrition_are_not_consumed_quantities(self):
        text = "Сыр, пачка 200 грамм, съел 40 грамм."
        result = link(text, foods(text, ["Сыр"]))
        self.assertEqual(result["items"][0]["value"], "40")
        text = "Йогурта съел 150 грамм. На 100 грамм в нём 5 грамм белка."
        result = link(text, foods(text, ["Йогурта", "белка"]))
        self.assertEqual(len(result["items"]), 1)
        self.assertEqual(result["items"][0]["value"], "150")
        text = "Белка яйца 50 грамм."
        self.assertEqual(link(text, foods(text, ["Белка яйца"]))["items"][0]["value"], "50")

    def test_negative_or_unclear_number_not_made_positive(self):
        for text in ("Молоко минус 50 мл", "Сыр один сорок два грамма"):
            active, ignored, _ = quantities(text)
            self.assertFalse(active)
            self.assertTrue(ignored)

    def test_false_food_at_package_marker_does_not_steal_consumed_weight(self):
        for marker in ("пакет", "пачка", "упаковка", "бутылка", "масса нетто"):
            with self.subTest(marker=marker):
                text = f"Орехи, {marker} 150 грамм, съел 30 грамм."
                result = link(text, foods(text, ["Орехи", marker]))
                self.assertEqual([(r["food"], r["value"]) for r in result["items"]], [("Орехи", "30")])
                self.assertEqual([f["text"] for f in result["excluded_food_spans"]], [marker])
                self.assertFalse(result["unassigned_quantities"])

    def test_packaging_word_elsewhere_is_not_a_global_stop_word(self):
        text = "Сыр Пакет радости 30 грамм."
        result = link(text, foods(text, ["Сыр Пакет радости"]))
        self.assertEqual(result["items"][0]["value"], "30")
        self.assertFalse(result["excluded_food_spans"])
        text = "Пакет риса, 100 грамм."
        result = link(text, foods(text, ["Пакет риса"]))
        self.assertEqual(result["items"][0]["value"], "100")
        self.assertFalse(result["excluded_food_spans"])

    def test_food_name_enclosing_packaging_marker_is_not_erased(self):
        text = "Сыр Большая пачка 100 грамм."
        result = link(text, foods(text, ["Сыр Большая пачка"]))
        self.assertEqual(result["items"][0]["food"], "Сыр Большая пачка")
        self.assertFalse(result["excluded_food_spans"])

    def test_packaging_offsets_survive_unicode_brand(self):
        text = "Орехи Straße, ПАКЕТ 150 грамм, съел 30 грамм."
        result = link(text, foods(text, ["Орехи Straße", "ПАКЕТ"]))
        self.assertEqual([(r["food"], r["value"]) for r in result["items"]], [("Орехи Straße", "30")])
        self.assertEqual([f["text"] for f in result["excluded_food_spans"]], ["ПАКЕТ"])

    def test_invalid_model_offsets_rejected(self):
        with self.assertRaises(ValueError):
            link("Хлеб 50 г", [{"text": "сыр", "start": 0, "end": 4}])


if __name__ == "__main__":
    unittest.main()
