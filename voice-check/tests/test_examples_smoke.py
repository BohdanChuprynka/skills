import unittest
from pathlib import Path

from voice_check import checks, corpus, profile

ROOT = Path(__file__).resolve().parents[1]


class ExamplesSmokeTests(unittest.TestCase):
    def setUp(self):
        self.records = corpus.load_corpus(ROOT / "examples" / "sample_corpus")
        self.rules = profile.to_voice_rules(profile.build_profile(self.records))
        self.negatives = corpus.load_corpus(ROOT / "examples" / "contrast")

    def test_corpus_loaded(self):
        kinds = {r.kind for r in self.records}
        self.assertIn("polished_writing", kinds)
        self.assertIn("raw_speech", kinds)
        self.assertGreaterEqual(len(self.negatives), 6)

    def test_written_target_is_writing_derived(self):
        prof = profile.build_profile(self.records)
        self.assertEqual(prof["written_target"]["derived_from"], "writing")
        self.assertFalse(prof["written_target"]["em_dash_allowed"])

    def test_positives_outscore_negatives(self):
        pos = [
            checks.check_draft(r.text, self.rules)["score"]
            for r in self.records
            if r.kind == "polished_writing"
        ]
        neg = [checks.check_draft(r.text, self.rules)["score"] for r in self.negatives]
        self.assertGreater(sum(pos) / len(pos), sum(neg) / len(neg) + 20)
        self.assertGreater(min(pos), max(neg))


if __name__ == "__main__":
    unittest.main()
