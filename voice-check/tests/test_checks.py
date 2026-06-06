import unittest

from voice_check import checks, corpus, profile


def rec(text, kind):
    return corpus.Record("i", "p", text, kind, None, {})


RULES = profile.to_voice_rules(
    profile.build_profile(
        [
            rec("Quick note. I shipped the fix. It works. Tell me if it breaks.", "polished_writing"),
            rec("Short and direct. No fluff. Let's go.", "polished_writing"),
        ]
    )
)


class CheckTests(unittest.TestCase):
    def test_em_dash_is_hard_violation_when_banned(self):
        r = checks.check_draft("This is fine — but not really.", RULES)
        hit = [v["rule"] for v in r["violations"]]
        self.assertIn("em_dash_banned", hit)
        self.assertTrue(any(v["severity"] == "hard" for v in r["violations"]))
        self.assertLessEqual(r["score"], 60)

    def test_corporate_and_ai_tells_flagged(self):
        r = checks.check_draft("We will leverage synergy to delve into the realm.", RULES)
        hit = [v["rule"] for v in r["violations"]]
        self.assertIn("corporate_word", hit)
        self.assertIn("ai_tell", hit)

    def test_filler_in_writing_flagged(self):
        r = checks.check_draft("So basically you know the thing is done.", RULES)
        hit = [v["rule"] for v in r["violations"]]
        self.assertIn("filler_in_writing", hit)

    def test_voicey_text_scores_higher_than_ai_text(self):
        voicey = checks.check_draft(
            "Quick note. Shipped the fix. It works. Ping me if it breaks.", RULES
        )
        ai = checks.check_draft(
            "Furthermore, it is worth noting that we must leverage robust, holistic "
            "solutions — thereby unlocking synergies to navigate the complexities of "
            "the evolving paradigm in today's world.",
            RULES,
        )
        self.assertGreater(voicey["score"], ai["score"])
        self.assertGreater(voicey["score"], 70)
        self.assertLess(ai["score"], 50)

    def test_score_is_explained(self):
        r = checks.check_draft("We utilize synergy.", RULES)
        self.assertIn("score_breakdown", r)
        self.assertTrue(all("points" in c for c in r["score_breakdown"]))

    def test_result_shape(self):
        r = checks.check_draft("Hello there friend.", RULES)
        for key in [
            "score",
            "kind_assumed",
            "signals",
            "violations",
            "voice_matches",
            "rewrite_plan",
            "suggested_rewrite",
        ]:
            self.assertIn(key, r)
        self.assertIsNone(r["suggested_rewrite"])

    def test_clean_short_text_has_no_violations(self):
        r = checks.check_draft("Shipped it. Works now.", RULES)
        self.assertEqual(r["violations"], [])
        self.assertEqual(r["score"], 100)


if __name__ == "__main__":
    unittest.main()
