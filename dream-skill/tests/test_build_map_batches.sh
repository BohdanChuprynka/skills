#!/usr/bin/env bash
# Unit tests for build-map-batches.py — the MAP unit builder that removes the
# multi-turn Read multiplier. Core invariants under test:
#   1. Every unit file is <= cap bytes (so each fits in ONE Read call).
#   2. Lossless: every original filtered line appears in at least one unit.
#   3. Provenance (raw source_chat + source_date) travels with each unit.
#   4. Big files chunk (with overlap); small files pack into bundles.
#   5. Fails loud on bad input.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
BUILD="$ROOT/scripts/build-map-batches.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

[ -x "$BUILD" ] || fail "build-map-batches.py missing or not executable at $BUILD"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── Fixtures ──────────────────────────────────────────────────────────────────
# One BIG filtered transcript (~120KB of short lines) and three small ones.
BIG="$WORK/filtered-big.txt"
python3 - "$BIG" <<'PY'
import sys
p = sys.argv[1]
with open(p, "w") as f:
    for i in range(3000):  # 3000 lines * ~45 bytes ≈ 135KB
        f.write(f"USER: line {i:05d} bohdan said something distinctive number {i}\n")
PY
BIG_BYTES=$(wc -c < "$BIG")

SMALL1="$WORK/filtered-s1.txt"; printf 'USER: small one alpha\nASST: reply alpha\n'   > "$SMALL1"
SMALL2="$WORK/filtered-s2.txt"; printf 'USER: small two beta\nASST: reply beta\n'     > "$SMALL2"
SMALL3="$WORK/filtered-s3.txt"; printf 'USER: small three gamma\nASST: reply gamma\n' > "$SMALL3"
EMPTY="$WORK/filtered-empty.txt"; printf '   \n' > "$EMPTY"   # whitespace-only → skipped

UNITS="$WORK/units"; mkdir -p "$UNITS"

MANIFEST="$WORK/manifest.json"
python3 - "$MANIFEST" "$BIG" "$SMALL1" "$SMALL2" "$SMALL3" "$EMPTY" <<'PY'
import json, sys
out, big, s1, s2, s3, empty = sys.argv[1:7]
manifest = [
    {"raw": "/raw/big.jsonl",   "filtered": big,   "source_date": "2026-06-01"},
    {"raw": "/raw/s1.jsonl",    "filtered": s1,    "source_date": "2026-06-02"},
    {"raw": "/raw/s2.jsonl",    "filtered": s2,    "source_date": "2026-06-03"},
    {"raw": "/raw/s3.jsonl",    "filtered": s3,    "source_date": "2026-06-04"},
    {"raw": "/raw/empty.jsonl", "filtered": empty, "source_date": "2026-06-05"},
]
json.dump(manifest, open(out, "w"))
PY

CAP=90000
OUT="$WORK/descriptors.json"
"$BUILD" --workdir "$UNITS" --cap-bytes "$CAP" --overlap-bytes 4000 --small-threshold 30720 \
  < "$MANIFEST" > "$OUT" || fail "build-map-batches.py exited non-zero on valid input"

# ── Test 1: every unit file <= cap bytes (single-Read-safe) ────────────────────
python3 - "$OUT" "$CAP" <<'PY' || fail "a unit file exceeds the cap (would break single-Read)"
import json, os, sys
desc = json.load(open(sys.argv[1])); cap = int(sys.argv[2])
for d in desc:
    b = os.path.getsize(d["unit_path"])
    assert b <= cap, f"{d['batch_id']} is {b} > cap {cap}"
print(f"  {len(desc)} units, all <= {cap} bytes")
PY
pass "every unit fits under the ${CAP}-byte Read cap"

# ── Test 2: lossless — every original BIG line appears in some chunk ───────────
python3 - "$OUT" "$BIG" <<'PY' || fail "big-file chunks dropped at least one original line (NOT lossless)"
import json, sys
desc = json.load(open(sys.argv[1]))
orig = set(l for l in open(sys.argv[2]).read().split("\n") if l)
covered = set()
for d in desc:
    if d["kind"] == "chunk" and d["source_chat"] == "/raw/big.jsonl":
        for l in open(d["unit_path"]).read().split("\n"):
            if l: covered.add(l)
missing = orig - covered
assert not missing, f"{len(missing)} lines missing, e.g. {list(missing)[:2]}"
print(f"  all {len(orig)} big-file lines covered across chunks")
PY
pass "big-file chunking is lossless (every line covered)"

# ── Test 3: chunks carry correct provenance + sequential part/of ──────────────
python3 - "$OUT" <<'PY' || fail "chunk provenance or part/of numbering is wrong"
import json, sys
desc = json.load(open(sys.argv[1]))
chunks = [d for d in desc if d["kind"] == "chunk"]
assert chunks, "expected at least one chunk from the big file"
of = chunks[0]["of"]
assert of >= 2, f"135KB big file should split into >=2 chunks, got {of}"
for idx, d in enumerate(chunks, start=1):
    assert d["source_chat"] == "/raw/big.jsonl", d
    assert d["source_date"] == "2026-06-01", d
    assert d["part"] == idx and d["of"] == of, d
print(f"  {of} chunks, provenance + part/of correct")
PY
pass "chunks carry raw source_chat/source_date and correct part/of"

# ── Test 4: overlap — consecutive chunks share boundary lines ─────────────────
python3 - "$OUT" <<'PY' || fail "consecutive big-file chunks do not overlap (boundary facts at risk)"
import json, sys
desc = json.load(open(sys.argv[1]))
chunks = [d for d in sorted([d for d in desc if d["kind"]=="chunk"], key=lambda x:x["part"])]
texts = [set(l for l in open(d["unit_path"]).read().split("\n") if l) for d in chunks]
overlaps = sum(1 for a, b in zip(texts, texts[1:]) if a & b)
assert overlaps == len(texts) - 1, f"only {overlaps}/{len(texts)-1} boundaries overlap"
print(f"  all {len(texts)-1} chunk boundaries overlap")
PY
pass "consecutive chunks overlap (boundary-spanning facts preserved)"

# ── Test 5: small files bundled with separators + member provenance ───────────
python3 - "$OUT" <<'PY' || fail "small-file bundling/provenance is wrong"
import json, sys
desc = json.load(open(sys.argv[1]))
bundles = [d for d in desc if d["kind"] == "bundle"]
assert bundles, "expected at least one bundle"
seen = set()
for d in bundles:
    body = open(d["unit_path"]).read()
    for m in d["members"]:
        seen.add(m["source_chat"])
        assert m["source_chat"] in body, f"separator for {m['source_chat']} missing in unit body"
        assert "DREAM-MAP-UNIT" in body
# all three non-empty small files present; the empty one skipped
assert seen == {"/raw/s1.jsonl", "/raw/s2.jsonl", "/raw/s3.jsonl"}, seen
print(f"  {len(bundles)} bundle(s) cover s1/s2/s3; empty.jsonl correctly skipped")
PY
pass "small files packed into bundles with in-band provenance separators"

# ── Test 6: empty/whitespace filtered transcript is skipped, not emitted ──────
python3 - "$OUT" <<'PY' || fail "empty filtered transcript leaked into a unit"
import json, sys
desc = json.load(open(sys.argv[1]))
for d in desc:
    assert d.get("source_chat") != "/raw/empty.jsonl", "empty file should be skipped"
    if d["kind"] == "bundle":
        for m in d["members"]:
            assert m["source_chat"] != "/raw/empty.jsonl"
print("  empty transcript skipped")
PY
pass "empty filtered transcript skipped"

# ── Test 7: fails loud on bad input ───────────────────────────────────────────
echo '{"not":"an array"}' | "$BUILD" --workdir "$UNITS" >/dev/null 2>&1 \
  && fail "should reject non-array input" || pass "rejects non-array input"

echo '[{"raw":"/r.jsonl","filtered":"/nope/missing.txt","source_date":"2026-06-01"}]' \
  | "$BUILD" --workdir "$UNITS" >/dev/null 2>&1 \
  && fail "should reject missing filtered file" || pass "rejects missing filtered file"

echo '[]' | "$BUILD" --workdir "$UNITS" --cap-bytes 100 --small-threshold 200 >/dev/null 2>&1 \
  && fail "should reject small-threshold > cap" || pass "rejects small-threshold > cap-bytes"

echo "PASS: build-map-batches.py invariants hold (single-Read-safe + lossless + provenance)"
