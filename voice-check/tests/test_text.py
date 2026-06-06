import unittest

from voice_check import text


class TextTests(unittest.TestCase):
    def test_split_sentences_basic(self):
        s = text.split_sentences("Hi there. How are you? I am fine!")
        self.assertEqual(s, ["Hi there.", "How are you?", "I am fine!"])

    def test_split_sentences_keeps_decimal_and_abbrev_together(self):
        s = text.split_sentences("Pay $3.50 to Mr. Smith now.")
        self.assertEqual(len(s), 1)

    def test_split_sentences_empty(self):
        self.assertEqual(text.split_sentences("   "), [])

    def test_tokenize_words_lowercases_and_keeps_apostrophe(self):
        self.assertEqual(text.tokenize_words("Don't STOP, ok"), ["don't", "stop", "ok"])

    def test_word_count_matches_whitespace_split(self):
        self.assertEqual(text.word_count(" a  b\nc\t"), 3)
        self.assertEqual(text.word_count("   "), 0)

    def test_ngrams(self):
        self.assertEqual(text.ngrams(["a", "b", "c"], 2), [("a", "b"), ("b", "c")])
        self.assertEqual(text.ngrams(["a"], 2), [])

    def test_count_contractions(self):
        self.assertEqual(text.count_contractions("I can't and won't, you're right"), 3)
        self.assertEqual(text.count_contractions("no contractions here"), 0)

    def test_punctuation_counts_and_em_dash(self):
        c = text.punctuation_counts("Hi — there, ok. Yes!")
        self.assertEqual(c["em_dash"], 1)
        self.assertEqual(c["comma"], 1)
        self.assertEqual(c["exclamation"], 1)
        self.assertEqual(c["period"], 1)

    def test_paragraphs(self):
        self.assertEqual(text.paragraphs("a\nb\n\nc"), ["a\nb", "c"])

    def test_count_phrase_word_boundary(self):
        self.assertEqual(text.count_phrase("You know, you know it", "you know"), 2)
        self.assertEqual(text.count_phrase("knowledge", "know"), 0)
        self.assertEqual(text.count_phrase("we leverage low-hanging fruit", "low-hanging fruit"), 1)


if __name__ == "__main__":
    unittest.main()
