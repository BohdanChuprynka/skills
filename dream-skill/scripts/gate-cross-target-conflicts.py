#!/usr/bin/env python3
"""Queue semantically similar new facts routed to different pages.

RECONCILE compares a candidate only with its chosen page.  When MAP emits
paraphrases and ROUTE scatters them across pages, each can look independently
new.  This lossless gate detects that cross-target conflict and makes every
member review-only so a human can keep the canonical destination.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from collections import Counter
from typing import Any


WORD_RE = re.compile(r"[a-z0-9]+", re.I)
STOP = {
    "a", "an", "and", "are", "as", "at", "be", "bohdan", "by", "for",
    "from", "has", "he", "in", "is", "it", "of", "on", "or", "that",
    "the", "this", "to", "user", "was", "were", "will", "with", "wants",
}


def tokens(value: str) -> list[str]:
    return [word.casefold() for word in WORD_RE.findall(value) if len(word) > 2 and word.casefold() not in STOP]


def vectors(texts: list[str]) -> list[dict[str, float]]:
    docs = [tokens(text) for text in texts]
    df: Counter[str] = Counter()
    for doc in docs:
        df.update(set(doc))
    count = max(len(docs), 1)
    output: list[dict[str, float]] = []
    for doc in docs:
        tf = Counter(doc)
        vector = {
            term: frequency * (math.log((count + 1) / (df[term] + 1)) + 1.0)
            for term, frequency in tf.items()
        }
        norm = math.sqrt(sum(value * value for value in vector.values())) or 1.0
        output.append({term: value / norm for term, value in vector.items()})
    return output


def cosine(left: dict[str, float], right: dict[str, float]) -> float:
    if len(left) > len(right):
        left, right = right, left
    return sum(value * right.get(term, 0.0) for term, value in left.items())


def target_key(decision: dict[str, Any]) -> tuple[str, str]:
    target = decision.get("target") if isinstance(decision.get("target"), dict) else {}
    return str(target.get("vault") or ""), str(target.get("page") or "")


def gate(records: list[dict[str, Any]], threshold: float) -> tuple[list[dict[str, Any]], int, int]:
    eligible: list[tuple[int, str, tuple[str, str], str]] = []
    for index, record in enumerate(records):
        decision = record.get("decision") if isinstance(record, dict) else None
        if not isinstance(decision, dict) or decision.get("action") != "new":
            continue
        content = str(decision.get("content") or "")
        target = target_key(decision)
        if content and all(target):
            eligible.append((index, str(record.get("candidate_id") or index), target, content))
    tfidf = vectors([item[3] for item in eligible])
    conflicts: dict[int, set[str]] = {}
    pairs = 0
    for left in range(len(eligible)):
        for right in range(left + 1, len(eligible)):
            li, lid, ltarget, ltext = eligible[left]
            ri, rid, rtarget, rtext = eligible[right]
            if ltarget == rtarget:
                continue
            shared = set(tokens(ltext)) & set(tokens(rtext))
            similarity = cosine(tfidf[left], tfidf[right])
            if len(shared) < 2 or similarity < threshold:
                continue
            conflicts.setdefault(li, set()).add(rid)
            conflicts.setdefault(ri, set()).add(lid)
            pairs += 1

    output: list[dict[str, Any]] = []
    for index, record in enumerate(records):
        enriched_record = dict(record)
        decision = dict(record.get("decision") or {})
        enriched_record["decision"] = decision
        if index in conflicts:
            decision["needs_review"] = True
            decision["cross_target_review"] = True
            decision["cross_target_candidate_ids"] = sorted(conflicts[index])
        output.append(enriched_record)
    return output, len(conflicts), pairs


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--threshold", type=float, default=0.52)
    parser.add_argument("--report", action="store_true")
    args = parser.parse_args(argv)
    if not 0.0 <= args.threshold <= 1.0:
        parser.error("--threshold must be between 0 and 1")
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(f"gate-cross-target-conflicts: invalid JSON: {exc}", file=sys.stderr)
        return 1
    if not isinstance(payload, list) or not all(isinstance(item, dict) for item in payload):
        print("gate-cross-target-conflicts: input must be an array of decision records", file=sys.stderr)
        return 1
    output, gated, pairs = gate(payload, args.threshold)
    if args.report:
        print(
            f"gate-cross-target-conflicts: in={len(payload)} gated={gated} pairs={pairs} threshold={args.threshold}",
            file=sys.stderr,
        )
    json.dump(output, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
