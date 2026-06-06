import json
import tempfile
import unittest
from pathlib import Path

from voice_check import corpus


class CorpusTests(unittest.TestCase):
    def setUp(self):
        self.d = Path(tempfile.mkdtemp())
        (self.d / "writing").mkdir()
        (self.d / "speech").mkdir()
        (self.d / "writing" / "a.md").write_text(
            "---\nkind: polished_writing\ndate: 2026-01-02\n---\nHello world.\n"
        )
        (self.d / "speech" / "b.txt").write_text("you know like basically yeah")
        (self.d / "c.jsonl").write_text(
            json.dumps(
                {
                    "transcript_id": "row42",
                    "timestamp": "2026-05-20",
                    "asr_text": "raw spoken",
                    "formatted_text": "Formatted.",
                    "edited_text": "Edited.",
                }
            )
            + "\n"
        )
        (self.d / "d.csv").write_text("text,kind\nhi there,polished_writing\n")

    def test_md_frontmatter_kind_wins(self):
        recs = corpus.load_file(self.d / "writing" / "a.md")
        self.assertEqual(recs[0].kind, "polished_writing")
        self.assertEqual(recs[0].text.strip(), "Hello world.")
        self.assertEqual(recs[0].created_at, "2026-01-02")

    def test_txt_kind_from_subfolder(self):
        recs = corpus.load_file(self.d / "speech" / "b.txt")
        self.assertEqual(recs[0].kind, "raw_speech")

    def test_jsonl_row_explodes_into_kinded_records(self):
        recs = corpus.load_file(self.d / "c.jsonl")
        kinds = {r.kind: r.text for r in recs}
        self.assertEqual(kinds["raw_speech"], "raw spoken")
        self.assertEqual(kinds["polished_writing"], "Formatted.")
        self.assertEqual(kinds["edited_revision"], "Edited.")

    def test_jsonl_records_share_row_id(self):
        recs = corpus.load_file(self.d / "c.jsonl")
        row_ids = {r.metadata.get("row_id") for r in recs}
        self.assertEqual(row_ids, {"row42"})

    def test_csv_kind_column(self):
        recs = corpus.load_file(self.d / "d.csv")
        self.assertEqual(recs[0].kind, "polished_writing")
        self.assertEqual(recs[0].text, "hi there")

    def test_load_corpus_walks_recursively(self):
        recs = corpus.load_corpus(self.d)
        self.assertGreaterEqual(len(recs), 6)

    def test_load_corpus_skips_readme(self):
        (self.d / "README.md").write_text("docs, not corpus")
        texts = [r.text for r in corpus.load_corpus(self.d)]
        self.assertNotIn("docs, not corpus", texts)

    def test_stable_id_deterministic(self):
        self.assertEqual(corpus.stable_id("p", "t"), corpus.stable_id("p", "t"))
        self.assertNotEqual(corpus.stable_id("p", "t"), corpus.stable_id("p", "u"))

    def test_unknown_kind_fallback(self):
        (self.d / "loose.txt").write_text("hello there")
        recs = corpus.load_file(self.d / "loose.txt")
        self.assertEqual(recs[0].kind, "unknown")

    def test_empty_text_skipped(self):
        (self.d / "empty.txt").write_text("   \n  ")
        self.assertEqual(corpus.load_file(self.d / "empty.txt"), [])


if __name__ == "__main__":
    unittest.main()
