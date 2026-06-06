"""Shared, deterministic text utilities. Pure functions, stdlib only."""

from __future__ import annotations

import re

# Single-token abbreviations (no internal period) that should not end a sentence.
_ABBREV = {
    "mr", "mrs", "ms", "dr", "st", "vs", "etc", "sr", "jr", "prof",
    "inc", "co", "no", "fig", "dept", "vol", "approx", "gen", "sen", "rep",
}
_ABBREV_RE = re.compile(
    r"\b(" + "|".join(re.escape(a) for a in _ABBREV) + r")\.", re.IGNORECASE
)
_DECIMAL_RE = re.compile(r"(\d)\.(\d)")
_SENTENCE_SPLIT_RE = re.compile(r"(?<=[.!?])\s+")
_WORD_RE = re.compile(r"[a-z0-9]+(?:'[a-z]+)?")
_CONTRACTION_RE = re.compile(r"\b[a-z]+'(?:t|re|ve|ll|d|s|m)\b")
_PARAGRAPH_RE = re.compile(r"\n\s*\n")

_DOT = "\x00DOT\x00"

_PUNCT = {
    "comma": ",",
    "period": ".",
    "question": "?",
    "exclamation": "!",
    "semicolon": ";",
    "colon": ":",
    "em_dash": "—",
    "open_paren": "(",
    "close_paren": ")",
    "quote": '"',
}


def split_sentences(text: str) -> list[str]:
    """Split prose into sentences, guarding decimals and common abbreviations."""
    if not text or not text.strip():
        return []
    protected = _DECIMAL_RE.sub(lambda m: f"{m.group(1)}{_DOT}{m.group(2)}", text)
    protected = _ABBREV_RE.sub(lambda m: m.group(0)[:-1] + _DOT, protected)
    parts = _SENTENCE_SPLIT_RE.split(protected)
    out = []
    for part in parts:
        restored = part.replace(_DOT, ".").strip()
        if restored:
            out.append(restored)
    return out


def tokenize_words(text: str) -> list[str]:
    """Lowercase word tokens, keeping internal apostrophes (don't -> don't)."""
    return _WORD_RE.findall(text.lower())


def word_count(text: str) -> int:
    """Whitespace token count (matches the exporter's semantics)."""
    return len(text.split())


def ngrams(tokens: list[str], n: int) -> list[tuple[str, ...]]:
    if n <= 0 or len(tokens) < n:
        return []
    return [tuple(tokens[i : i + n]) for i in range(len(tokens) - n + 1)]


def count_contractions(text: str) -> int:
    """Approximate contraction count (possessive 's may slightly inflate)."""
    return len(_CONTRACTION_RE.findall(text.lower()))


def punctuation_counts(text: str) -> dict[str, int]:
    return {name: text.count(ch) for name, ch in _PUNCT.items()}


def paragraphs(text: str) -> list[str]:
    return [p.strip() for p in _PARAGRAPH_RE.split(text.strip()) if p.strip()]


def count_phrase(text: str, phrase: str) -> int:
    """Count word-boundary occurrences of a (possibly multi-word) phrase."""
    words = phrase.split()
    if not words:
        return 0
    pattern = r"\b" + r"\s+".join(re.escape(w) for w in words) + r"\b"
    return len(re.findall(pattern, text.lower()))
