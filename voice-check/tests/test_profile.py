import json
import tempfile
import unittest
from pathlib import Path

from voice_check import corpus, profile


def rec(text, kind, row_id=None):
    meta = {"row_id": row_id} if row_id else {}
    return corpus.Record("i", "p", text, kind, None, meta)


class ProfileStatsTests(unittest.TestCase):
    def test_stats_basic_counts(self):
        st = profile.profile_stats([rec("Short one. Two here.", "polished_writing")])
        self.assertEqual(st["n_sentences"], 2)
        self.assertEqual(st["n_words"], 4)

    def test_empty_corpus_is_safe(self):
        st = profile.profile_stats([])
        self.assertEqual(st["n_words"], 0)
        self.assertEqual(st["filler_rate_per_1k"], 0.0)

    def test_filler_rate_detected_in_speech(self):
        st = profile.profile_stats([rec("you know i basically you know mean it", "raw_speech")])
        self.assertGreater(st["filler_rate_per_1k"], 0)

    def test_em_dash_flag(self):
        st = profile.profile_stats([rec("a — b", "polished_writing")])
        self.assertGreater(st["punctuation_per_1k"]["em_dash"], 0)

    def test_top_ngrams_present(self):
        st = profile.profile_stats([rec("ship the fix. ship the build. ship it.", "polished_writing")])
        unigrams = dict(st["top_unigrams"])
        self.assertIn("ship", unigrams)


class BuildProfileTests(unittest.TestCase):
    def test_written_target_strips_filler_expectation(self):
        p = profile.build_profile([rec("you know basically like yeah ok", "raw_speech")])
        wt = p["written_target"]
        self.assertEqual(wt["filler_expectation_per_1k"], 0.0)
        self.assertEqual(wt["derived_from"], "speech")

    def test_written_target_uses_writing_when_available(self):
        recs = [rec("Quick note. " * 40, "polished_writing")]
        p = profile.build_profile(recs)
        self.assertEqual(p["written_target"]["derived_from"], "writing")

    def test_asr_formatted_delta_computed_when_row_shared(self):
        recs = [
            rec("you know basically the build is green you know", "raw_speech", row_id="r1"),
            rec("The build is green.", "polished_writing", row_id="r1"),
        ]
        p = profile.build_profile(recs)
        self.assertIsNotNone(p["asr_formatted_delta"])
        self.assertGreaterEqual(p["asr_formatted_delta"]["pairs"], 1)


class VoiceRulesTests(unittest.TestCase):
    def test_voice_rules_shape(self):
        p = profile.build_profile([rec("Hello there. Quick note.", "polished_writing")])
        r = profile.to_voice_rules(p)
        for key in [
            "filler_phrases",
            "corporate_blacklist",
            "ai_tells",
            "em_dash_allowed",
            "sentence_len_band",
            "contraction_rate_target",
            "score_weights",
        ]:
            self.assertIn(key, r)
        self.assertEqual(len(r["sentence_len_band"]), 2)


class ArtifactTests(unittest.TestCase):
    def test_profile_md_has_no_raw_corpus_sentence(self):
        secret = "the quartermaster hid the ledger under the floorboards tonight"
        md = profile.to_voice_profile_md(profile.build_profile([rec(secret, "polished_writing")]))
        self.assertNotIn("quartermaster hid the ledger", md)

    def test_write_profile_emits_three_files(self):
        d = Path(tempfile.mkdtemp())
        profile.write_profile(
            profile.build_profile([rec("Hi there friend. Short note.", "polished_writing")]), d
        )
        self.assertTrue((d / "profile_stats.json").exists())
        self.assertTrue((d / "voice_rules.json").exists())
        self.assertTrue((d / "voice_profile.md").exists())
        json.loads((d / "voice_rules.json").read_text())  # must be valid json

    def test_load_rules_roundtrip(self):
        d = Path(tempfile.mkdtemp())
        p = profile.build_profile([rec("Hi there friend. Short note.", "polished_writing")])
        profile.write_profile(p, d)
        rules = profile.load_rules(d)
        self.assertIn("score_weights", rules)


if __name__ == "__main__":
    unittest.main()
