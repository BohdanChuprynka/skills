"""Deterministic voice profile: aggregate statistics + emitted artifacts.

Outputs (all local-only, git-ignored): profile_stats.json (exhaustive),
voice_rules.json (the enforceable subset the checker reads), voice_profile.md
(human + agent readable). Emits aggregate numbers, lexicon words, and short
n-gram anchors only — never a raw sentence from the corpus.
"""

from __future__ import annotations

import json
import statistics
from collections import Counter
from pathlib import Path
from typing import Iterable, Optional, Union

from voice_check import lexicons
from voice_check.corpus import EDITED, POLISHED, RAW_SPEECH, Record
from voice_check import text as txt

PROFILE_VERSION = 1
MIN_WRITING_WORDS = 50  # below this we derive the written target from speech

# Default penalty magnitudes for the checker's transparent score. Stored in the
# rules so a profile can override them; the checker reads rules["score_weights"].
DEFAULT_SCORE_WEIGHTS = {
    "em_dash": 30,
    "corporate_word": 8,
    "ai_tell": 8,
    "filler_in_writing": 6,
    "inflated_claim": 6,
    "hedge": 3,
    "sentence_len_drift": 18,
    "no_contractions": 10,
    "uniform_rhythm": 10,
    "over_explained_ending": 6,
    "buried_lede": 5,
}

_HIST_BINS = [(1, 5), (6, 10), (11, 15), (16, 20), (21, 30), (31, 10 ** 9)]
_HIST_LABELS = ["1-5", "6-10", "11-15", "16-20", "21-30", "31+"]


def _rate_per_1k(count: int, n_words: int) -> float:
    return round(count / n_words * 1000, 3) if n_words else 0.0


def _percentile(values: list[int], pct: float) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    if len(s) == 1:
        return float(s[0])
    k = (len(s) - 1) * pct / 100.0
    lo = int(k)
    hi = min(lo + 1, len(s) - 1)
    if lo == hi:
        return float(s[lo])
    return round(s[lo] + (s[hi] - s[lo]) * (k - lo), 3)


def _histogram(lengths: list[int]) -> dict[str, int]:
    counts = {label: 0 for label in _HIST_LABELS}
    for length in lengths:
        for (low, high), label in zip(_HIST_BINS, _HIST_LABELS):
            if low <= length <= high:
                counts[label] += 1
                break
    return counts


def _filter(records: list[Record], kind_filter: Union[str, Iterable[str], None]) -> list[Record]:
    if kind_filter is None:
        return records
    wanted = {kind_filter} if isinstance(kind_filter, str) else set(kind_filter)
    return [r for r in records if r.kind in wanted]


def _phrase_total(text: str, phrases: Iterable[str]) -> tuple[int, dict[str, int]]:
    per = {}
    total = 0
    for phrase in phrases:
        count = txt.count_phrase(text, phrase)
        if count:
            per[phrase] = count
            total += count
    return total, per


def _top_ngrams(tokens: list[str], n: int, limit: int) -> list[list]:
    grams = txt.ngrams(tokens, n)
    if n == 1:
        grams = [(t,) for t in tokens if t not in lexicons.STOPWORDS and len(t) > 1]
    else:
        grams = [g for g in grams if not all(t in lexicons.STOPWORDS for t in g)]
    counter = Counter(" ".join(g) for g in grams)
    return [[gram, count] for gram, count in counter.most_common(limit)]


def profile_stats(records: list[Record], kind_filter: Union[str, Iterable[str], None] = None) -> dict:
    records = _filter(records, kind_filter)
    combined = "\n".join(r.text for r in records)
    n_words = txt.word_count(combined)

    sentences: list[str] = []
    for r in records:
        sentences.extend(txt.split_sentences(r.text))
    sentence_lengths = [txt.word_count(s) for s in sentences]
    n_sentences = len(sentences)

    tokens = txt.tokenize_words(combined)

    filler_total, filler_per = _phrase_total(combined, lexicons.FILLER)
    corporate_total, corporate_per = _phrase_total(combined, lexicons.CORPORATE)
    ai_total, ai_per = _phrase_total(combined, lexicons.AI_TELLS)
    hedge_total, _ = _phrase_total(combined, lexicons.HEDGES)
    inflated_total, _ = _phrase_total(combined, lexicons.INFLATED)
    contractions = txt.count_contractions(combined)
    punct = txt.punctuation_counts(combined)

    questions = sum(1 for s in sentences if s.rstrip().endswith("?"))
    exclamations = sum(1 for s in sentences if s.rstrip().endswith("!"))

    openers = Counter()
    for s in sentences:
        first = txt.tokenize_words(s)[:2]
        if first:
            openers[" ".join(first)] += 1

    return {
        "n_records": len(records),
        "n_words": n_words,
        "n_sentences": n_sentences,
        "sentence_len_mean": round(statistics.fmean(sentence_lengths), 3) if sentence_lengths else 0.0,
        "sentence_len_median": round(statistics.median(sentence_lengths), 3) if sentence_lengths else 0.0,
        "sentence_len_p10": _percentile(sentence_lengths, 10),
        "sentence_len_p90": _percentile(sentence_lengths, 90),
        "sentence_len_stdev": round(statistics.pstdev(sentence_lengths), 3) if len(sentence_lengths) > 1 else 0.0,
        "sentence_len_histogram": _histogram(sentence_lengths),
        "filler_rate_per_1k": _rate_per_1k(filler_total, n_words),
        "filler_top": dict(Counter(filler_per).most_common(12)),
        "corporate_rate_per_1k": _rate_per_1k(corporate_total, n_words),
        "corporate_top": dict(Counter(corporate_per).most_common(12)),
        "ai_tell_rate_per_1k": _rate_per_1k(ai_total, n_words),
        "ai_tell_top": dict(Counter(ai_per).most_common(12)),
        "hedge_rate_per_1k": _rate_per_1k(hedge_total, n_words),
        "inflated_rate_per_1k": _rate_per_1k(inflated_total, n_words),
        "contraction_rate_per_1k": _rate_per_1k(contractions, n_words),
        "punctuation_per_1k": {k: _rate_per_1k(v, n_words) for k, v in punct.items()},
        "em_dash_present": punct.get("em_dash", 0) > 0,
        "question_rate": round(questions / n_sentences, 3) if n_sentences else 0.0,
        "exclamation_rate": round(exclamations / n_sentences, 3) if n_sentences else 0.0,
        "type_token_ratio": round(len(set(tokens)) / len(tokens), 3) if tokens else 0.0,
        "top_unigrams": _top_ngrams(tokens, 1, 25),
        "top_bigrams": _top_ngrams(tokens, 2, 25),
        "top_trigrams": _top_ngrams(tokens, 3, 25),
        "top_openers": [[k, v] for k, v in openers.most_common(15)],
    }


def _asr_formatted_delta(records: list[Record]) -> Optional[dict]:
    by_row: dict[str, dict[str, Record]] = {}
    for r in records:
        row_id = r.metadata.get("row_id")
        if row_id:
            by_row.setdefault(row_id, {})[r.kind] = r
    pairs = [(v[RAW_SPEECH], v[POLISHED]) for v in by_row.values() if RAW_SPEECH in v and POLISHED in v]
    if not pairs:
        return None
    filler_removed = []
    length_ratio = []
    for speech, polished in pairs:
        sw = txt.word_count(speech.text)
        pw = txt.word_count(polished.text)
        s_filler, _ = _phrase_total(speech.text, lexicons.FILLER)
        p_filler, _ = _phrase_total(polished.text, lexicons.FILLER)
        filler_removed.append(s_filler - p_filler)
        if sw:
            length_ratio.append(pw / sw)
    return {
        "pairs": len(pairs),
        "avg_filler_removed": round(statistics.fmean(filler_removed), 3) if filler_removed else 0.0,
        "avg_length_ratio": round(statistics.fmean(length_ratio), 3) if length_ratio else 0.0,
    }


def build_profile(records: list[Record]) -> dict:
    overall = profile_stats(records)
    kinds_present = sorted({r.kind for r in records})
    by_kind = {kind: profile_stats(records, kind) for kind in kinds_present}

    writing_records = _filter(records, {POLISHED, EDITED})
    writing_words = txt.word_count("\n".join(r.text for r in writing_records))
    speech_stats = by_kind.get(RAW_SPEECH, overall)

    if writing_words >= MIN_WRITING_WORDS:
        ws = profile_stats(writing_records)
        derived_from = "writing"
        band = [ws["sentence_len_p10"], ws["sentence_len_p90"]]
        mean = ws["sentence_len_mean"]
        filler_expectation = round(ws["filler_rate_per_1k"], 3)
        em_dash_allowed = ws["em_dash_present"]
        contraction_target = ws["contraction_rate_per_1k"]
        source_stats = ws
    else:
        derived_from = "speech"
        band = [speech_stats["sentence_len_p10"], speech_stats["sentence_len_p90"]]
        mean = speech_stats["sentence_len_mean"]
        filler_expectation = 0.0  # polished writing should carry no spoken filler
        # allow em dash only if any written sample used it
        em_dash_allowed = by_kind.get(POLISHED, {}).get("em_dash_present", False) or by_kind.get(
            EDITED, {}
        ).get("em_dash_present", False)
        contraction_target = speech_stats["contraction_rate_per_1k"]
        source_stats = speech_stats

    written_target = {
        "derived_from": derived_from,
        "sentence_len_band": [round(band[0], 1), round(band[1], 1)],
        "sentence_len_mean": mean,
        "filler_expectation_per_1k": filler_expectation,
        "contraction_rate_per_1k_target": contraction_target,
        "em_dash_allowed": bool(em_dash_allowed),
        "vocab_anchors": [g[0] for g in source_stats["top_unigrams"][:20]],
        "opener_anchors": [o[0] for o in source_stats["top_openers"][:10]],
    }

    spoken_fingerprint = {
        "sentence_len_band": [speech_stats["sentence_len_p10"], speech_stats["sentence_len_p90"]],
        "top_vocab": [g[0] for g in speech_stats["top_unigrams"][:15]],
        "filler_rate_per_1k": speech_stats["filler_rate_per_1k"],
        "contraction_rate_per_1k": speech_stats["contraction_rate_per_1k"],
    }

    return {
        "version": PROFILE_VERSION,
        "overall": overall,
        "by_kind": by_kind,
        "written_target": written_target,
        "spoken_fingerprint": spoken_fingerprint,
        "asr_formatted_delta": _asr_formatted_delta(records),
    }


def to_voice_rules(profile: dict) -> dict:
    wt = profile["written_target"]
    return {
        "version": PROFILE_VERSION,
        "derived_from": wt["derived_from"],
        "filler_phrases": sorted(lexicons.FILLER),
        "corporate_blacklist": sorted(lexicons.CORPORATE),
        "ai_tells": sorted(lexicons.AI_TELLS),
        "inflated_phrases": sorted(lexicons.INFLATED),
        "hedges": sorted(lexicons.HEDGES),
        "em_dash_allowed": wt["em_dash_allowed"],
        "sentence_len_band": wt["sentence_len_band"],
        "sentence_len_mean": wt["sentence_len_mean"],
        "contraction_rate_target": wt["contraction_rate_per_1k_target"],
        "filler_target_per_1k": wt["filler_expectation_per_1k"],
        "opener_anchors": wt["opener_anchors"],
        "vocab_anchors": wt["vocab_anchors"],
        "score_weights": dict(DEFAULT_SCORE_WEIGHTS),
    }


def to_voice_profile_md(profile: dict) -> str:
    wt = profile["written_target"]
    overall = profile["overall"]
    band = wt["sentence_len_band"]
    lines = [
        "# Voice Profile",
        "",
        "_Generated deterministically from your corpus. Aggregate statistics only —",
        "no raw sentences. This file is local-only and git-ignored._",
        "",
        "## Voice at a glance",
        f"- Corpus: {overall['n_words']} words, {overall['n_sentences']} sentences.",
        f"- Written target derived from: **{wt['derived_from']}**.",
        f"- Typical sentence length: ~{wt['sentence_len_mean']} words (band {band[0]}–{band[1]}).",
        f"- Em dashes: **{'allowed' if wt['em_dash_allowed'] else 'avoid'}**.",
        f"- Contraction rate target: {wt['contraction_rate_per_1k_target']} per 1k words.",
        f"- Filler in polished writing: target {wt['filler_expectation_per_1k']} per 1k (strip it).",
        "",
        "## Rhythm",
        "Match the sentence-length band above. Vary length; avoid uniform, mid-length",
        "sentences (an AI tell).",
        "",
        "## Vocabulary anchors",
        "Words that recur in your voice: " + ", ".join(wt["vocab_anchors"][:20] or ["(n/a)"]) + ".",
        "",
        "## Common openers",
        "You often open with: " + ", ".join(wt["opener_anchors"][:8] or ["(n/a)"]) + ".",
        "",
        "## Filler to strip (spoken, not written)",
        ", ".join(sorted(lexicons.FILLER)) + ".",
        "",
        "## Hard no list",
        "- Corporate words: " + ", ".join(sorted(lexicons.CORPORATE)) + ".",
        "- AI tells: " + ", ".join(sorted(lexicons.AI_TELLS)) + ".",
        "- Em dashes" + ("" if wt["em_dash_allowed"] else " — replace with a period or comma.") + ".",
        "- Inflated claims without specifics: " + ", ".join(sorted(lexicons.INFLATED)) + ".",
        "",
    ]
    return "\n".join(lines)


def write_profile(profile: dict, out_dir) -> None:
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "profile_stats.json").write_text(
        json.dumps(profile, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    (out_dir / "voice_rules.json").write_text(
        json.dumps(to_voice_rules(profile), ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (out_dir / "voice_profile.md").write_text(to_voice_profile_md(profile), encoding="utf-8")


def load_stats(profile_dir) -> dict:
    return json.loads((Path(profile_dir) / "profile_stats.json").read_text(encoding="utf-8"))


def load_rules(profile_dir) -> dict:
    return json.loads((Path(profile_dir) / "voice_rules.json").read_text(encoding="utf-8"))
