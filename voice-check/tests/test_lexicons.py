import unittest

from voice_check import lexicons


class LexiconTests(unittest.TestCase):
    def test_core_lists_present_and_lowercase(self):
        for name in ["FILLER", "HEDGES", "CORPORATE", "AI_TELLS"]:
            items = getattr(lexicons, name)
            self.assertTrue(items, f"{name} empty")
            self.assertTrue(all(p == p.lower() for p in items), f"{name} not lowercase")

    def test_corporate_has_plain_replacement(self):
        for word in ["utilize", "leverage"]:
            self.assertIn(word, lexicons.CORPORATE_TO_PLAIN)
            self.assertTrue(lexicons.CORPORATE_TO_PLAIN[word])

    def test_contraction_map_expands_and_contracts(self):
        self.assertEqual(lexicons.EXPAND_TO_CONTRACTION["do not"], "don't")
        self.assertEqual(lexicons.EXPAND_TO_CONTRACTION["it is"], "it's")

    def test_lists_are_disjoint_enough(self):
        # corporate words slated for replacement must not also be in AI_TELLS
        overlap = set(lexicons.CORPORATE_TO_PLAIN) & set(lexicons.AI_TELLS)
        self.assertEqual(overlap, set())


if __name__ == "__main__":
    unittest.main()
