import json
import unittest

from voice_check import checks, corpus, profile, report


def rec(text, kind):
    return corpus.Record("i", "p", text, kind, None, {})


PROFILE = profile.build_profile([rec("Quick note. It works. Ping me.", "polished_writing")])
RULES = profile.to_voice_rules(PROFILE)


class ReportTests(unittest.TestCase):
    def test_render_text_contains_score(self):
        result = checks.check_draft("We utilize synergy — really.", RULES)
        out = report.render_audit(result, fmt="text")
        self.assertIn("Score", out)
        self.assertIn(str(result["score"]), out)
        self.assertIn("VIOLATIONS", out.upper())

    def test_render_json_is_valid(self):
        result = checks.check_draft("Hello.", RULES)
        out = report.render_audit(result, fmt="json")
        self.assertEqual(json.loads(out)["score"], result["score"])

    def test_render_handles_no_violations(self):
        result = checks.check_draft("Shipped it. Works now.", RULES)
        out = report.render_audit(result, fmt="text")
        self.assertIn("Score", out)  # must not raise

    def test_render_profile_summary(self):
        out = report.render_profile_summary(PROFILE)
        self.assertIn("words", out.lower())
        self.assertIn("sentence", out.lower())


if __name__ == "__main__":
    unittest.main()
