#!/usr/bin/env python3
"""Build MAP units that each fit in ONE Read call (no multi-turn re-bill).

The Read tool rejects any file whose content exceeds ~25,000 tokens. A large
filtered transcript therefore forces an extraction agent into many windowed
Read calls, and the API re-bills the whole accumulated context on every turn
(the "multi-turn multiplier"). Reading one large chat across ~16 windows cost
~1.5M tokens in a real run — for a chat that produced zero candidate facts.

This script removes the multiplier WITHOUT dropping any content:
  * Big filtered transcripts (> --small-threshold bytes) are split, on line
    boundaries, into overlapping chunks of <= --cap-bytes. One MAP agent reads
    one chunk in a single Read call. No agent ever re-reads another's chunk, so
    the content enters context exactly once in total.
  * Small filtered transcripts (<= --small-threshold) are packed first-fit into
    combined bundle files of <= --cap-bytes, separated by provenance headers, so
    ~82 tiny chats become ~7 agents instead of 82.

Every byte of every filtered transcript lands in exactly one unit (chunks add a
small overlap so a fact spanning a boundary is still seen whole). Provenance —
the ORIGINAL raw transcript path and its source_date — travels with each unit so
candidates stay correctly attributed.

Input  (stdin): JSON array of manifest entries, each:
  {"raw": "<raw .jsonl path>", "filtered": "<filtered .txt path>",
   "source_date": "YYYY-MM-DD", "filtered_bytes": <int, optional>}

Output (stdout): JSON array of map-unit descriptors:
  [{"batch_id":"map-0001","kind":"chunk","unit_path":"<file>",
    "source_chat":"<raw>","source_date":"YYYY-MM-DD","part":1,"of":11},
   {"batch_id":"map-0034","kind":"bundle","unit_path":"<file>",
    "members":[{"source_chat":"<raw>","source_date":"YYYY-MM-DD"}, ...]}]

Unit files are written under --workdir. They are what MAP agents read.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


SEPARATOR_PREFIX = "===== DREAM-MAP-UNIT"


def die(message: str) -> int:
    print(f"build-map-batches: {message}", file=sys.stderr)
    return 1


def parse_positive_int(value: Any, name: str) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{name} must be an integer") from exc
    if parsed < 1:
        raise ValueError(f"{name} must be >= 1")
    return parsed


def separator(raw: str, source_date: str) -> str:
    return f"{SEPARATOR_PREFIX} source_chat={raw} source_date={source_date} =====\n"


def split_into_chunks(lines: list[str], cap: int, overlap: int) -> list[str]:
    """Split lines into <=cap-byte chunks (by encoded size) with byte overlap.

    Returns a list of chunk texts. Overlap is realized by replaying trailing
    lines of the previous chunk at the head of the next, so a fact straddling a
    boundary is seen whole by at least one chunk. Line boundaries are never
    split, so no line is ever truncated.
    """
    def blen(s: str) -> int:
        return len(s.encode("utf-8"))

    chunks: list[str] = []
    n = len(lines)
    i = 0
    while i < n:
        cur: list[str] = []
        cur_bytes = 0
        # Pack lines until we would exceed cap. cur_bytes tracks the encoded
        # size of "\n".join(cur), so the joining newline is charged per line.
        while i < n:
            add = blen(lines[i]) + (1 if cur else 0)  # +1 for the joining "\n"
            # Always place at least one line, even if a single line exceeds cap
            # (cannot be split further without breaking the line).
            if cur and cur_bytes + add > cap:
                break
            cur.append(lines[i])
            cur_bytes += add
            i += 1
        chunks.append("\n".join(cur))
        if i >= n:
            break
        # Build overlap: walk backwards over just-emitted lines until we have
        # >= overlap bytes, then rewind i so those lines replay in the next chunk.
        if overlap > 0:
            ob = 0
            k = len(cur)
            while k > 0 and ob < overlap:
                k -= 1
                ob += blen(cur[k])
            # Replay lines cur[k:] — but never rewind past forward progress
            # (k must leave at least one new line consumed, else infinite loop).
            replay = len(cur) - k
            if replay >= len(cur):
                replay = len(cur) - 1  # guarantee progress
            i -= replay
    return chunks


def first_fit_pack(items: list[dict[str, Any]], cap: int) -> list[list[dict[str, Any]]]:
    """First-fit-decreasing pack small files into <=cap-byte bundles.

    Each item carries its own separator+content cost in `unit_bytes`.
    """
    ordered = sorted(items, key=lambda it: it["unit_bytes"], reverse=True)
    bundles: list[list[dict[str, Any]]] = []
    bundle_bytes: list[int] = []
    for it in ordered:
        placed = False
        for idx in range(len(bundles)):
            if bundle_bytes[idx] + it["unit_bytes"] <= cap:
                bundles[idx].append(it)
                bundle_bytes[idx] += it["unit_bytes"]
                placed = True
                break
        if not placed:
            bundles.append([it])
            bundle_bytes.append(it["unit_bytes"])
    return bundles


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Build single-Read MAP units.")
    parser.add_argument("--workdir", required=True, help="dir to write unit files into")
    parser.add_argument("--cap-bytes", default="85000",
                        help="max bytes per unit file; ~21K tokens, safely under the 25K-token Read cap (default 85000)")
    parser.add_argument("--overlap-bytes", default="4000",
                        help="overlap replayed between big-file chunks (default 4000)")
    parser.add_argument("--small-threshold", default="30720",
                        help="filtered files <= this many bytes are bundled, not chunked (default 30720)")
    args = parser.parse_args(argv)

    try:
        cap = parse_positive_int(args.cap_bytes, "--cap-bytes")
        overlap = int(args.overlap_bytes)
        if overlap < 0:
            raise ValueError("--overlap-bytes must be >= 0")
        small_threshold = parse_positive_int(args.small_threshold, "--small-threshold")
        if small_threshold > cap:
            raise ValueError("--small-threshold must be <= --cap-bytes")
        if overlap >= cap:
            raise ValueError("--overlap-bytes must be < --cap-bytes")

        workdir = Path(args.workdir)
        if not workdir.is_dir():
            return die(f"workdir does not exist: {workdir}")

        try:
            manifest = json.load(sys.stdin)
        except json.JSONDecodeError as exc:
            return die(f"invalid JSON input: {exc}")
        if not isinstance(manifest, list):
            return die("input must be a JSON array of manifest entries")

        big_entries: list[dict[str, Any]] = []
        small_items: list[dict[str, Any]] = []

        for i, entry in enumerate(manifest):
            if not isinstance(entry, dict):
                return die(f"manifest entry #{i + 1} is not an object")
            for field in ("raw", "filtered", "source_date"):
                if not entry.get(field):
                    return die(f"manifest entry #{i + 1} missing required field: {field}")
            fpath = Path(entry["filtered"])
            if not fpath.is_file():
                return die(f"filtered transcript not found: {fpath}")
            text = fpath.read_text(encoding="utf-8", errors="ignore")
            if not text.strip():
                # Empty filtered transcript: nothing to extract, skip silently.
                continue
            size = len(text.encode("utf-8"))
            record = {
                "raw": entry["raw"],
                "source_date": entry["source_date"],
                "text": text,
                "size": size,
            }
            if size > small_threshold:
                big_entries.append(record)
            else:
                header = separator(entry["raw"], entry["source_date"])
                # +1 charges the "\n" that joins this part to the next in the
                # bundle file, so first-fit packing never overshoots the cap.
                record["unit_bytes"] = size + len(header.encode("utf-8")) + 1
                small_items.append(record)
    except ValueError as exc:
        return die(str(exc))

    descriptors: list[dict[str, Any]] = []
    seq = 0

    def next_id() -> str:
        nonlocal seq
        seq += 1
        return f"map-{seq:04d}"

    # Big files → overlapping chunks, one descriptor each.
    for rec in big_entries:
        lines = rec["text"].split("\n")
        chunks = split_into_chunks(lines, cap, overlap)
        for part, chunk_text in enumerate(chunks, start=1):
            bid = next_id()
            unit_path = workdir / f"{bid}.txt"
            unit_path.write_text(chunk_text, encoding="utf-8")
            descriptors.append({
                "batch_id": bid,
                "kind": "chunk",
                "unit_path": str(unit_path),
                "source_chat": rec["raw"],
                "source_date": rec["source_date"],
                "part": part,
                "of": len(chunks),
            })

    # Small files → first-fit bundles, one descriptor each.
    bundles = first_fit_pack(small_items, cap)
    for bundle in bundles:
        bid = next_id()
        unit_path = workdir / f"{bid}.txt"
        parts: list[str] = []
        members: list[dict[str, str]] = []
        for it in bundle:
            parts.append(separator(it["raw"], it["source_date"]) + it["text"])
            members.append({"source_chat": it["raw"], "source_date": it["source_date"]})
        unit_path.write_text("\n".join(parts), encoding="utf-8")
        descriptors.append({
            "batch_id": bid,
            "kind": "bundle",
            "unit_path": str(unit_path),
            "members": members,
        })

    json.dump(descriptors, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
