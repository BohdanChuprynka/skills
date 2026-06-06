"""Deterministic, rule-based mechanical polish.

This is NOT the nuanced rewrite — that is the host agent's job via the skill.
It is a safe baseline that provably moves a draft toward the profile (removes em
dashes, swaps corporate jargon for plain words, drops AI connectors and spoken
filler) without inventing any facts. Used as the skill's offline fallback and to
make the evaluation's before/after rewrite demo reproducible.
"""

from __future__ import annotations

import re

from voice_check import lexicons

_EM_DASH_RE = re.compile(r"\s*—\s*")
_CONNECTOR_RE = re.compile(
    r"(^|[.!?]\s+)(" + "|".join(lexicons.DELETABLE_CONNECTORS) + r"),?\s*",
    re.IGNORECASE,
)
_MULTISPACE_RE = re.compile(r"\s+")
_SPACE_BEFORE_PUNCT_RE = re.compile(r"\s+([,.;:!?])")
_DOUBLE_COMMA_RE = re.compile(r",(\s*,)+")
_LEADING_PUNCT_RE = re.compile(r"^[\s,;:]+")
_CAP_RE = re.compile(r"(^|[.!?]\s+)([a-z])")


def _replace_word_preserving_case(text: str, word: str, replacement: str) -> str:
    pattern = re.compile(r"\b" + re.escape(word) + r"\b", re.IGNORECASE)

    def sub(match: re.Match) -> str:
        original = match.group(0)
        if original[:1].isupper():
            return replacement[:1].upper() + replacement[1:]
        return replacement

    return pattern.sub(sub, text)


def _strip_phrase(text: str, phrase: str) -> str:
    pattern = re.compile(
        r"\b" + r"\s+".join(re.escape(w) for w in phrase.split()) + r"\b,?\s*",
        re.IGNORECASE,
    )
    return pattern.sub("", text)


def _cleanup(text: str) -> str:
    text = _MULTISPACE_RE.sub(" ", text).strip()
    text = _SPACE_BEFORE_PUNCT_RE.sub(r"\1", text)
    text = _DOUBLE_COMMA_RE.sub(",", text)
    text = _LEADING_PUNCT_RE.sub("", text)
    text = re.sub(r"\(\s*\)", "", text)
    text = _CAP_RE.sub(lambda m: m.group(1) + m.group(2).upper(), text)
    text = text.strip()
    if text and text[-1] not in ".!?":
        text += "."
    return text


def mechanical_polish(text: str, rules: dict) -> str:
    """Apply safe, deterministic, idempotent transforms toward the profile."""
    out = text
    # 1. Em dashes -> comma (keeps the clause; profile bans em dashes by default).
    out = _EM_DASH_RE.sub(", ", out)
    # 2. Corporate jargon -> plain word-for-word swaps.
    for word, replacement in lexicons.CORPORATE_TO_PLAIN.items():
        out = _replace_word_preserving_case(out, word, replacement)
    # 3. Delete AI connectors at sentence starts.
    out = _CONNECTOR_RE.sub(lambda m: m.group(1), out)
    # 4. Strip spoken filler (longest phrases first to avoid partial leftovers).
    for phrase in sorted(rules.get("filler_phrases", lexicons.FILLER), key=len, reverse=True):
        out = _strip_phrase(out, phrase)
    # 5. Delete pure-filler AI phrases that can be removed without breaking grammar.
    for phrase in sorted(lexicons.SAFE_DELETE_AI, key=len, reverse=True):
        out = _strip_phrase(out, phrase)
    # 6. Normalize whitespace, punctuation, capitalization, terminal punctuation.
    return _cleanup(out)
