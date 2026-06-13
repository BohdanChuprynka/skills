#!/usr/bin/env python3
"""REDUCE de-duplication for dream-skill.

Replaces the exact-(content, suggested_section) dedup with a two-layer pass:

  1. Exact layer  — collapse byte-identical (lower(content), lower(section)) pairs.
  2. Near-dup layer — TF-IDF cosine clustering on CONTENT ALONE. Chunk-overlap and
     multi-agent extraction surface the same fact with slightly different wording
     and different agent-guessed sections, so an exact key collapses ~nothing
     (observed: 0/599). Clustering on content fixes that without an embedding API.

Why content-only: two candidates with near-identical content are the same fact
regardless of which section each agent guessed. Distinct facts about the same
subject ("dataset = 10,238 rows" vs "Cliff delta = 0.949") share little vocabulary
and stay below threshold, so they are NOT merged.

Per surviving cluster: keep the highest-(confidence, evidence-length) member, set
source_chat_count to the cluster's distinct source_chat count, and apply the same
confidence promotion REDUCE always did (N>=2 -> >=medium, N>=3 -> high). Promotion
now fires on near-dups across chats, which the exact-only version missed.

Graceful: if scikit-learn is unavailable, fall back to exact-dedup only (a run is
never blocked on the optional near-dup layer).

Input  (stdin):  JSON array of candidate-fact objects.
Output (stdout): JSON array, deduplicated, each with an added source_chat_count int.
Contract preserved: output items keep content/confidence/source_chat/source_date
(+ optional type/evidence/suggested_section), so build-route-batches.py accepts them.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any

CONF_RANK = {"low": 0, "medium": 1, "high": 2}
RANK_CONF = {v: k for k, v in CONF_RANK.items()}


def _norm(s: Any) -> str:
    return (s or "").strip().lower() if isinstance(s, (str, type(None))) else str(s).strip().lower()


def _better(a: dict[str, Any], b: dict[str, Any]) -> dict[str, Any]:
    """Pick the representative: higher confidence, then more evidence text."""
    ra = (CONF_RANK.get(a.get("confidence", "low"), 0), len(a.get("evidence") or ""))
    rb = (CONF_RANK.get(b.get("confidence", "low"), 0), len(b.get("evidence") or ""))
    return a if ra >= rb else b


def exact_dedup(pool: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Collapse byte-identical (content, section); track distinct source chats."""
    groups: dict[tuple[str, str], dict[str, Any]] = {}
    for c in pool:
        key = (_norm(c.get("content")), _norm(c.get("suggested_section")))
        g = groups.get(key)
        if g is None:
            groups[key] = {"rep": c, "sources": {c.get("source_chat")}}
        else:
            g["rep"] = _better(g["rep"], c)
            g["sources"].add(c.get("source_chat"))
    out: list[dict[str, Any]] = []
    for g in groups.values():
        rep = dict(g["rep"])
        rep["_sources"] = set(g["sources"])
        out.append(rep)
    return out


def _promote(rep: dict[str, Any], n_sources: int) -> None:
    rank = CONF_RANK.get(rep.get("confidence", "low"), 0)
    if n_sources >= 3:
        rank = max(rank, 2)
    elif n_sources == 2:
        rank = max(rank, 1)
    rep["confidence"] = RANK_CONF[rank]
    rep["source_chat_count"] = n_sources


def near_dedup(
    items: list[dict[str, Any]], threshold: float
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """TF-IDF cosine union-find clustering on content. Returns (deduped, report)."""
    report: dict[str, Any] = {"in": len(items), "clusters_merged": 0, "merged_pairs": []}
    if len(items) < 2:
        for it in items:
            _promote(it, len(it.get("_sources") or {it.get("source_chat")}))
            it.pop("_sources", None)
        report["out"] = len(items)
        return items, report
    try:
        from sklearn.feature_extraction.text import (  # type: ignore[import-untyped]
            TfidfVectorizer,
        )
        from sklearn.metrics.pairwise import (  # type: ignore[import-untyped]
            cosine_similarity,
        )
    except Exception as exc:  # pragma: no cover - environment fallback
        print(f"reduce-dedup: sklearn unavailable ({exc}); exact-only", file=sys.stderr)
        for it in items:
            _promote(it, len(it.get("_sources") or {it.get("source_chat")}))
            it.pop("_sources", None)
        report["out"] = len(items)
        report["fallback"] = True
        return items, report

    texts = [str(it.get("content", "")) for it in items]
    # Word 1-grams (not bigrams): reworded extractions of the same fact reorder and
    # inflect words, which crushes bigram overlap. Calibration on real candidates:
    # true-dups score ~0.56-0.70, distinct facts about the same subject score <0.06,
    # leaving a wide empty gap. RECONCILE re-checks dups at the page level, so this
    # layer is biased to precision (never merge distinct facts), not recall.
    vec = TfidfVectorizer(lowercase=True, stop_words="english", ngram_range=(1, 1), min_df=1)
    try:
        tfidf = vec.fit_transform(texts)
    except ValueError:
        # empty vocabulary (all stop words) -> no near-dup pass
        for it in items:
            _promote(it, len(it.get("_sources") or {it.get("source_chat")}))
            it.pop("_sources", None)
        report["out"] = len(items)
        return items, report

    sim = cosine_similarity(tfidf)
    n = len(items)
    parent = list(range(n))

    def find(x: int) -> int:
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a: int, b: int) -> None:
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[max(ra, rb)] = min(ra, rb)

    for i in range(n):
        for j in range(i + 1, n):
            if sim[i, j] >= threshold:
                union(i, j)
                report["merged_pairs"].append(
                    {"sim": round(float(sim[i, j]), 3),
                     "a": texts[i][:70], "b": texts[j][:70]}
                )

    clusters: dict[int, list[int]] = {}
    for idx in range(n):
        clusters.setdefault(find(idx), []).append(idx)

    out: list[dict[str, Any]] = []
    for members in clusters.values():
        rep = items[members[0]]
        sources: set[Any] = set()
        for m in members:
            rep = _better(rep, items[m])
            sources |= (items[m].get("_sources") or {items[m].get("source_chat")})
        rep = dict(rep)
        if len(members) > 1:
            report["clusters_merged"] += 1
        _promote(rep, len(sources))
        rep.pop("_sources", None)
        out.append(rep)
    report["out"] = len(out)
    return out, report


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="dream-skill REDUCE dedup (exact + TF-IDF near-dup).")
    ap.add_argument("--threshold", type=float,
                    default=float(os.environ.get("DREAM_DEDUP_THRESHOLD", "0.50")),
                    help="cosine >= threshold merges two candidates (default 0.50, word 1-gram TF-IDF)")
    ap.add_argument("--report", action="store_true", help="write a dedup report to stderr")
    args = ap.parse_args(argv)

    try:
        pool = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(f"reduce-dedup: invalid JSON: {exc}", file=sys.stderr)
        return 1
    if not isinstance(pool, list):
        print("reduce-dedup: input must be a JSON array", file=sys.stderr)
        return 1

    exact = exact_dedup(pool)
    deduped, report = near_dedup(exact, args.threshold)

    if args.report:
        print(
            f"reduce-dedup: pool={len(pool)} after_exact={len(exact)} "
            f"after_near={report['out']} clusters_merged={report['clusters_merged']} "
            f"threshold={args.threshold}",
            file=sys.stderr,
        )
        for mp in report["merged_pairs"][:40]:
            print(f"  merge sim={mp['sim']}: [{mp['a']}] ~ [{mp['b']}]", file=sys.stderr)

    json.dump(deduped, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
