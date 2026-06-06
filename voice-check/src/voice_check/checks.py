"""Deterministic draft checker. Scores a draft against voice rules and returns a
fully explainable audit. The score is a transparent 100-minus-penalties sum;
every deduction is attributable to a named rule.

Quoting the *draft* back to the user is fine — it is the user's own input, not
the private corpus.
"""

from __future__ import annotations

from voice_check import lexicons
from voice_check import text as txt

_EXPANDABLE = tuple(lexicons.EXPAND_TO_CONTRACTION.keys())


def _matched(text: str, phrases) -> list[str]:
    return [p for p in phrases if txt.count_phrase(text, p)]


def signals(text: str, rules: dict) -> dict:
    sentences = txt.split_sentences(text)
    lengths = [txt.word_count(s) for s in sentences]
    n_words = txt.word_count(text)
    punct = txt.punctuation_counts(text)
    import statistics

    mean = round(statistics.fmean(lengths), 3) if lengths else 0.0
    stdev = round(statistics.pstdev(lengths), 3) if len(lengths) > 1 else 0.0
    expandable = sum(txt.count_phrase(text, p) for p in _EXPANDABLE)
    return {
        "n_words": n_words,
        "n_sentences": len(sentences),
        "sentence_len_mean": mean,
        "sentence_len_stdev": stdev,
        "em_dash": punct.get("em_dash", 0),
        "corporate": _matched(text, rules["corporate_blacklist"]),
        "ai_tells": _matched(text, rules["ai_tells"]),
        "filler": _matched(text, rules["filler_phrases"]),
        "inflated": _matched(text, rules.get("inflated_phrases", [])),
        "hedges": _matched(text, rules.get("hedges", [])),
        "contractions": txt.count_contractions(text),
        "expandable": expandable,
        "filler_rate_per_1k": round(
            sum(txt.count_phrase(text, p) for p in rules["filler_phrases"]) / n_words * 1000, 2
        )
        if n_words
        else 0.0,
    }


def _cap(weight: int, count: int, max_units: int) -> int:
    return weight * min(count, max_units)


def _rule_em_dash(sig, rules):
    if rules.get("em_dash_allowed") or sig["em_dash"] == 0:
        return []
    weight = rules["score_weights"]["em_dash"]
    return [
        {
            "rule": "em_dash_banned",
            "severity": "hard",
            "count": sig["em_dash"],
            "penalty": weight + 3 * (sig["em_dash"] - 1),
            "message": f"{sig['em_dash']} em dash(es); your profile uses none.",
            "fix": "Replace em dashes with a period, comma, or parentheses.",
            "evidence": "—",
        }
    ]


def _phrase_rule(name, severity, items, weight_key, max_units, message, fix):
    def rule(sig, rules):
        words = sig[items]
        if not words:
            return []
        weight = rules["score_weights"][weight_key]
        return [
            {
                "rule": name,
                "severity": severity,
                "count": len(words),
                "penalty": _cap(weight, len(words), max_units),
                "message": message + ": " + ", ".join(words),
                "fix": fix,
                "evidence": ", ".join(words),
            }
        ]

    return rule


_rule_corporate = _phrase_rule(
    "corporate_word", "soft", "corporate", "corporate_word", 3,
    "Corporate words", "Swap for plain words (utilize→use, leverage→use).",
)
_rule_ai_tell = _phrase_rule(
    "ai_tell", "soft", "ai_tells", "ai_tell", 4,
    "Generic-AI tells", "Cut AI filler (delve, moreover, in today's world).",
)
_rule_filler = _phrase_rule(
    "filler_in_writing", "soft", "filler", "filler_in_writing", 3,
    "Spoken filler left in writing", "Delete filler (you know, basically, kind of).",
)
_rule_inflated = _phrase_rule(
    "inflated_claim", "soft", "inflated", "inflated_claim", 3,
    "Inflated claims", "Replace superlatives with a concrete specific or cut them.",
)
_rule_hedge = _phrase_rule(
    "hedge", "info", "hedges", "hedge", 3,
    "Hedging", "State it directly; drop the hedge if you mean it.",
)


def _rule_no_contractions(sig, rules):
    if sig["expandable"] > 0 and sig["contractions"] == 0:
        return [
            {
                "rule": "no_contractions",
                "severity": "soft",
                "count": sig["expandable"],
                "penalty": rules["score_weights"]["no_contractions"],
                "message": "No contractions, but your voice uses them.",
                "fix": "Use contractions (do not→don't, it is→it's).",
                "evidence": "",
            }
        ]
    return []


def _rule_uniform_rhythm(sig, rules):
    if sig["n_sentences"] > 3 and sig["sentence_len_stdev"] < 1.0 and sig["sentence_len_mean"] > 8:
        return [
            {
                "rule": "uniform_rhythm",
                "severity": "soft",
                "count": sig["n_sentences"],
                "penalty": rules["score_weights"]["uniform_rhythm"],
                "message": "Sentences are uniformly mid-length (an AI tell).",
                "fix": "Vary sentence length; add a few short, punchy ones.",
                "evidence": "",
            }
        ]
    return []


def _rule_sentence_drift(sig, rules):
    if sig["n_sentences"] == 0:
        return []
    band = rules["sentence_len_band"]
    low, high = band[0], band[1]
    mean = sig["sentence_len_mean"]
    weight = rules["score_weights"]["sentence_len_drift"]
    if high > 0 and mean > high * 1.5:
        over = (mean - high * 1.5) / max(high, 1.0)
        penalty = min(weight, int(6 + over * weight))
        return [
            {
                "rule": "sentence_too_long",
                "severity": "soft",
                "count": round(mean, 1),
                "penalty": penalty,
                "message": f"Avg sentence {round(mean, 1)} words; your band is {low}-{high}.",
                "fix": "Break long sentences into shorter ones.",
                "evidence": "",
            }
        ]
    return []


_RULES = [
    _rule_em_dash,
    _rule_corporate,
    _rule_ai_tell,
    _rule_filler,
    _rule_inflated,
    _rule_hedge,
    _rule_no_contractions,
    _rule_uniform_rhythm,
    _rule_sentence_drift,
]


def _score(violations, has_hard):
    total = sum(v["penalty"] for v in violations)
    score = 100 - total
    if has_hard:
        score = min(score, 60)
    score = max(0, min(100, score))
    breakdown = {}
    for v in violations:
        breakdown[v["rule"]] = breakdown.get(v["rule"], 0) + v["penalty"]
    return score, [{"component": k, "points": -p} for k, p in breakdown.items()]


def _voice_matches(sig, rules):
    matches = []
    band = rules["sentence_len_band"]
    if sig["n_sentences"] and band[0] <= sig["sentence_len_mean"] <= max(band[1] * 1.5, band[1] + 4):
        matches.append({"trait": "sentence rhythm", "detail": "lengths match your band"})
    if sig["contractions"] > 0:
        matches.append({"trait": "contractions", "detail": "uses contractions like your voice"})
    if not rules.get("em_dash_allowed") and sig["em_dash"] == 0:
        matches.append({"trait": "punctuation", "detail": "no em dashes, matching your profile"})
    if not sig["corporate"] and not sig["ai_tells"]:
        matches.append({"trait": "plain language", "detail": "no corporate words or AI tells"})
    return matches


def check_draft(text: str, rules: dict, kind: str = "polished_writing") -> dict:
    sig = signals(text, rules)
    violations = []
    for rule in _RULES:
        violations.extend(rule(sig, rules))
    has_hard = any(v["severity"] == "hard" for v in violations)
    score, breakdown = _score(violations, has_hard)
    rewrite_plan = [v["fix"] for v in sorted(violations, key=lambda v: -v["penalty"]) if v.get("fix")]
    return {
        "score": score,
        "kind_assumed": kind,
        "signals": sig,
        "violations": violations,
        "voice_matches": _voice_matches(sig, rules),
        "rewrite_plan": rewrite_plan,
        "suggested_rewrite": None,
        "score_breakdown": breakdown,
    }
