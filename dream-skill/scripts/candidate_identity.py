#!/usr/bin/env python3
"""Stable candidate identity shared by deterministic Dream routing stages."""

from __future__ import annotations

import hashlib
import json
from typing import Any


MUTABLE_POLICY_PREFIXES = ("historical_", "quality_review_", "policy_")


def immutable_candidate(candidate: dict[str, Any]) -> dict[str, Any]:
    """Remove review-policy annotations while preserving extraction identity.

    Historical and sampling gates may change confidence or age metadata across
    retries.  They must not change the candidate ID used by queues/sidecars.
    """
    identity = {
        key: value
        for key, value in candidate.items()
        if key not in {
            "original_confidence",
            "fact_class",
            "person_review_only",
            "detected_names",
            "review_kind",
        }
        and not any(key.startswith(prefix) for prefix in MUTABLE_POLICY_PREFIXES)
    }
    original_confidence = candidate.get("original_confidence")
    if isinstance(original_confidence, str) and original_confidence:
        identity["confidence"] = original_confidence
    return identity


def candidate_id(candidate: dict[str, Any]) -> str:
    canonical = json.dumps(
        immutable_candidate(candidate),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    return "c-" + hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:20]
