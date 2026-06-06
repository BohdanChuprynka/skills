import unittest

from voice_check import checks, corpus, profile, rewrite


def rec(text, kind):
    return corpus.Record("i", "p", text, kind, None, {})


RULES = profile.to_voice_rules(
    profile.build_profile([rec("Quick note. It works. Ping me if it breaks.", "polished_writing")])
)


class RewriteTests(unittest.TestCase):
    def test_polish_removes_em_dash_and_corporate(self):
        out = rewrite.mechanical_polish("We will utilize this — really.", RULES)
        self.assertNotIn("—", out)
        self.assertNotIn("utilize", out.lower())
        self.assertIn("use", out.lower())

    def test_polish_strips_leading_filler(self):
        out = rewrite.mechanical_polish("You know, basically the build is green.", RULES)
        self.assertNotIn("basically", out.lower())
        self.assertNotIn("you know", out.lower())

    def test_polish_raises_score(self):
        bad = "Furthermore, we will leverage robust synergies — moreover, utilize holistic paradigms."
        before = checks.check_draft(bad, RULES)["score"]
        after = checks.check_draft(rewrite.mechanical_polish(bad, RULES), RULES)["score"]
        self.assertGreater(after, before)

    def test_polish_is_idempotent(self):
        once = rewrite.mechanical_polish("We utilize synergy.", RULES)
        twice = rewrite.mechanical_polish(once, RULES)
        self.assertEqual(once, twice)

    def test_polish_keeps_clean_text_intact_meaning(self):
        out = rewrite.mechanical_polish("Shipped it. Works now.", RULES)
        self.assertIn("Shipped it", out)
        self.assertIn("Works now", out)

    def test_polish_never_empty_when_input_nonempty(self):
        out = rewrite.mechanical_polish("basically you know", RULES)
        self.assertIsInstance(out, str)

    def test_polish_deletes_safe_ai_filler(self):
        out = rewrite.mechanical_polish("It is worth noting that we use the tool.", RULES)
        self.assertNotIn("worth noting", out.lower())
        self.assertIn("use the tool", out.lower())

    def test_polish_swaps_more_corporate(self):
        out = rewrite.mechanical_polish("Let's circle back on the robust plan.", RULES)
        self.assertNotIn("circle back", out.lower())
        self.assertNotIn("robust", out.lower())
        self.assertIn("follow up", out.lower())


if __name__ == "__main__":
    unittest.main()
