import unittest
from pathlib import Path

from voice_check import checks, corpus, eval as ev, profile

ROOT = Path(__file__).resolve().parents[1]


class MetricTests(unittest.TestCase):
    def test_roc_auc_perfect_separation(self):
        self.assertEqual(ev.roc_auc([0.9, 0.8, 0.7], [0.2, 0.1, 0.3]), 1.0)

    def test_roc_auc_random(self):
        self.assertAlmostEqual(ev.roc_auc([0.5, 0.5], [0.5, 0.5]), 0.5)

    def test_roc_auc_reversed(self):
        self.assertEqual(ev.roc_auc([0.1, 0.2], [0.9, 0.8]), 0.0)

    def test_roc_auc_empty_is_half(self):
        self.assertEqual(ev.roc_auc([], [1.0]), 0.5)

    def test_accuracy_at_best_threshold(self):
        acc, _thr = ev.accuracy_at_best_threshold([0.9, 0.8], [0.2, 0.1])
        self.assertEqual(acc, 1.0)

    def test_split_is_deterministic(self):
        a = ev.deterministic_split(list(range(10)), 0.5, seed=1)
        b = ev.deterministic_split(list(range(10)), 0.5, seed=1)
        self.assertEqual(a, b)

    def test_split_covers_all_items_without_overlap(self):
        train, test = ev.deterministic_split(list(range(10)), 0.6, seed=3)
        self.assertEqual(sorted(train + test), list(range(10)))
        self.assertEqual(set(train) & set(test), set())
        self.assertTrue(test)  # never empty


class EvaluateTests(unittest.TestCase):
    def test_evaluate_on_examples_separates(self):
        res = ev.evaluate(
            ROOT / "examples" / "sample_corpus",
            negatives_dir=ROOT / "examples" / "contrast",
            train_frac=0.6,
            seed=7,
        )
        self.assertGreaterEqual(res["discrimination"]["auc"], 0.8)
        self.assertGreater(res["discrimination"]["score_gap"], 10)

    def test_rewrite_demo_raises_mean_score(self):
        res = ev.evaluate(
            ROOT / "examples" / "sample_corpus",
            negatives_dir=ROOT / "examples" / "contrast",
            train_frac=0.6,
            seed=7,
        )
        demo = res["rewrite_demo"]
        before = sum(d["before_score"] for d in demo) / len(demo)
        after = sum(d["after_score"] for d in demo) / len(demo)
        self.assertGreater(after, before)


class AiIfyTests(unittest.TestCase):
    def test_ai_ify_adds_tells_and_lowers_score(self):
        clean = "Don't ship it yet. I'll use the simple fix. It works."
        rules = profile.to_voice_rules(
            profile.build_profile([corpus.Record("i", "p", clean, "polished_writing", None, {})])
        )
        ai = ev.ai_ify(clean)
        self.assertIn("do not", ai.lower())
        self.assertIn("utilize", ai.lower())
        self.assertLess(
            checks.check_draft(ai, rules)["score"], checks.check_draft(clean, rules)["score"]
        )

    def test_content_matched_eval_separates(self):
        res = ev.evaluate(
            ROOT / "examples" / "sample_corpus", content_matched=True, train_frac=0.6, seed=7
        )
        self.assertEqual(res["negative_mode"], "content_matched_ai_paraphrase")
        self.assertGreaterEqual(res["discrimination"]["auc"], 0.8)


if __name__ == "__main__":
    unittest.main()
