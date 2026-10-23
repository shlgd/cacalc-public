"""Synthetic source-boundary checks, not measured ASR accuracy."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from meal_text_chunker import chunk


class MealTextChunkerTests(unittest.TestCase):
    def check_chunks(self, text, expected):
        result = chunk(text)
        actual = [part["text"].strip(" \t\n,.;") for part in result["chunks"]]
        self.assertEqual(actual, expected)
        self.assertEqual("".join(part["text"] for part in result["chunks"]), text)
        previous = 0
        for part in result["chunks"]:
            self.assertEqual(part["start"], previous)
            self.assertEqual(text[part["start"]:part["end"]], part["text"])
            previous = part["end"]
        self.assertEqual(previous, len(text))
        return result

    def test_four_positions_in_speech(self):
        self.check_chunks("Добавил овсянку 120 грамм, потом молока 400 мл, ещё протеин 30 грамм и немного мёда.",
                          ["Добавил овсянку 120 грамм", "потом молока 400 мл", "ещё протеин 30 грамм", "и немного мёда"])

    def test_composite_dish_is_not_ingredients(self):
        self.check_chunks("На ужин съел курицу с овощами 250 грамм.", ["На ужин съел курицу с овощами 250 грамм"])
        self.check_chunks("Курица 150 грамм, овощи 100 грамм.", ["Курица 150 грамм", "овощи 100 грамм"])

    def test_separate_actions_without_weights(self):
        self.check_chunks("Ел омлет с сыром и пил какао.", ["Ел омлет с сыром", "и пил какао"])

    def test_both_orders_with_explicit_separators(self):
        self.check_chunks("Добавь 90 г тунца, кукурузы 110 г и 70 г фасоли.",
                          ["Добавь 90 г тунца", "кукурузы 110 г", "и 70 г фасоли"])

    def test_unpunctuated_description_first(self):
        self.check_chunks("овсянка 120 г молоко 400 мл протеин 30 г мёд 20 г",
                          ["овсянка 120 г", "молоко 400 мл", "протеин 30 г", "мёд 20 г"])

    def test_unpunctuated_quantity_first(self):
        self.check_chunks("Добавь 120 г овсянки 400 мл молока 30 г протеина",
                          ["Добавь 120 г овсянки", "400 мл молока", "30 г протеина"])

    def test_decimals_are_not_boundaries(self):
        for quantity in ("7,5", "7.5", "пять запятая,8", "пять и восемь", "ноль запятая ноль пять"):
            with self.subTest(quantity=quantity):
                self.check_chunks(f"Масла {quantity} г, хлеба 40 г.", [f"Масла {quantity} г", "хлеба 40 г"])

    def test_comma_before_weight(self):
        self.check_chunks("Хлеб, 40 грамм, молоко, 200 мл.", ["Хлеб, 40 грамм", "молоко, 200 мл"])

    def test_package_details_stay_with_position(self):
        self.check_chunks("Орехи, пакет 150 грамм, съел 30 грамм. Потом хлеб 40 грамм.",
                          ["Орехи, пакет 150 грамм, съел 30 грамм", "Потом хлеб 40 грамм"])

    def test_label_details_stay_with_position(self):
        self.check_chunks("Йогурт 150 грамм. На 100 грамм: белки 5,8 грамма, жиры 0,5 грамма. Потом хлеб 40 грамм.",
                          ["Йогурт 150 грамм. На 100 грамм: белки 5,8 грамма, жиры 0,5 грамма", "Потом хлеб 40 грамм"])

    def test_brand_details_are_kept(self):
        self.check_chunks("Овсянка 120 грамм, марка Ясно солнышко. Потом молоко 400 мл.",
                          ["Овсянка 120 грамм, марка Ясно солнышко", "Потом молоко 400 мл"])

    def test_quoted_brand_is_not_split(self):
        self.check_chunks('Хлеб «Хлеб и соль» 50 грамм, сок 200 мл.',
                          ['Хлеб «Хлеб и соль» 50 грамм', 'сок 200 мл'])

    def test_no_weight_or_product_guessing(self):
        self.check_chunks("В ресторане ел ризотто с грибами.", ["В ресторане ел ризотто с грибами"])

    def test_ambiguous_mixed_order_is_retained_for_review(self):
        result = self.check_chunks("100 г хлеба сыр 20 г", ["100 г хлеба сыр 20 г"])
        self.assertIn("ambiguous_quantity_order", result["chunks"][0]["review_reasons"])

    def test_ambiguous_enumeration_is_retained_for_review(self):
        result = self.check_chunks("Хлеб и сыр 100 г", ["Хлеб и сыр 100 г"])
        self.assertIn("unresolved_conjunction", result["chunks"][0]["review_reasons"])

    def test_unicode_and_line_breaks_are_lossless(self):
        self.check_chunks("🥣 Каша 150 г.\nКофе 200 мл", ["🥣 Каша 150 г", "Кофе 200 мл"])

    def test_limits_and_empty_text(self):
        self.assertEqual(chunk("  ")["chunks"], [])
        with self.assertRaises(ValueError):
            chunk("я" * 6001)
        with self.assertRaises(ValueError):
            chunk(None)

    def test_large_input_is_retained_without_truncation(self):
        text = "хлеб 1 г " * 129
        result = self.check_chunks(text, [text.strip()])
        self.assertIn("too_many_quantities", result["chunks"][0]["review_reasons"])


if __name__ == "__main__":
    unittest.main()
