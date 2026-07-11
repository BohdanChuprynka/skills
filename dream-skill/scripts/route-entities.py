#!/usr/bin/env python3
"""Deterministic (no-LLM) person-name pre-routing pass, run on REDUCE's routable
candidates before build-route-batches.py hands anything to the ROUTE agent.

Scope: only actual roster pages — an indexed page whose filename stem is
exactly "people" case-insensitively (for example, `wiki/People.md` or
`wiki/people/people.md`). Other files that merely live under a
people/ directory (networking-targets.md, dated call-prep notes, etc.) are NOT
rosters and are never indexed. A full person registry with dedup/aliasing
across every vault is explicitly out of scope here.

Input  (stdin):  JSON array of candidate-fact objects (same shape REDUCE/
                  split-memory-tiers.py's "routable" output uses).
Output (stdout): a single JSON object:
  {"pre_routed": [...], "new_person": [...], "remaining": [...]}

  pre_routed = candidates whose content starts with (is about) a known roster
               name. If that name is registered on more than one roster an
               optional configured preferred vault wins; otherwise a deterministic
               (vault,page) tie-break
               picks one. Each record is shaped exactly like a
               validate-route-batch.py output record — candidate_id/candidate/
               route — so it merges straight into the routed list downstream
               (build-reconcile-batches.py needs zero changes to consume it).
  new_person = candidates with no known-name match but at least one detected
               Title-Case name span not already accounted for. Never written
               to a vault; queued to people-review-queue.json/.md for a human.
  remaining  = everything else. Falls through to the existing LLM ROUTE stage
               unchanged, exactly as before this pass existed.

The known-name index is built once per run from the roster pages' raw markdown
text (bulleted `- **Name** — ...` entries and `| **Name** | ... |` table rows).
Only the full cleaned bold span (and any quoted nickname) becomes a name key —
bare word tokens are NOT registered, so a lone first name never matches.
Pre-routing is subject-position only: a candidate is pre-routed just when a
roster key sits at the very start of the fact (the fact is *about* that person),
never on a mid-sentence mention, and a trailing possessive apostrophe is
rejected. When a name is on more than one roster, `entity_routing.preferred_vault`
can choose the canonical roster. Matching is anchored (re.match), never naive
substring containment.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import tomllib
from pathlib import Path
from typing import Any

from vault_search import build_page_docs, load_vault_config


BOLD_RE = re.compile(r"\*\*([^*]{2,80})\*\*")
NICKNAME_RE = re.compile(r'"([^"]+)"')
BACKTICK_QUALIFIER_RE = re.compile(r"`[^`]*`")
PAREN_QUALIFIER_RE = re.compile(r"\([^)]*\)")
SYMBOL_CHARS = "⚠✓⭐✅✔️"
TITLE_CASE_RE = re.compile(r"\b[A-Z][a-z]+(?:\s+[A-Z][a-z]+){1,2}\b")

# First-token verbs/gerunds that mark a sentence-initial Title-Case span as an
# action, not a person ("Implementing Google Calendar", "Next project", "Met
# Sarah"). Any token ending in "ing" is also rejected (see detect_new_person).
VERB_STARTERS = {
    "implementing", "building", "using", "adding", "configuring", "testing",
    "running", "creating", "writing", "met", "next", "added", "configured",
    "created", "built", "used", "made", "started", "implemented",
}

MONTHS = {
    "January", "February", "March", "April", "May", "June", "July",
    "August", "September", "October", "November", "December",
}
WEEKDAYS = {"Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"}
# Generic product and technology terms that are Title-Case but not people.
# Deployment-specific organization, product, and owner names belong in the
# optional `entity_routing.stop_terms` configuration, never in source.
DEFAULT_STOP_TERMS = {
    "AI", "API", "AWS", "Azure", "Calendar", "ChatGPT", "Claude", "Codex",
    "Cursor", "Data", "Docker", "GitHub", "GitLab", "Google", "Haiku", "IT",
    "JavaScript", "Microsoft", "Notion", "Obsidian", "Python", "RAG", "Slack",
    "Sonnet", "SQL", "TypeScript",
}


def die(message: str) -> int:
    print(f"route-entities: {message}", file=sys.stderr)
    return 1


def candidate_id(candidate: dict[str, Any]) -> str:
    """Byte-identical to build-route-batches.py's candidate_id() — do not drift."""
    canonical = json.dumps(candidate, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return "c-" + hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:20]


def load_entity_routing_config(config: Path) -> tuple[str | None, set[str]]:
    """Read optional public-safe routing overrides from the local config."""
    with config.open("rb") as handle:
        parsed = tomllib.load(handle)
    section = parsed.get("entity_routing")
    if not isinstance(section, dict):
        return None, set()
    preferred = section.get("preferred_vault")
    preferred_vault = str(preferred) if isinstance(preferred, str) and preferred.strip() else None
    configured_terms = section.get("stop_terms")
    if not isinstance(configured_terms, list):
        return preferred_vault, set()
    return preferred_vault, {str(term) for term in configured_terms if isinstance(term, str) and term.strip()}


def clean_bold_span(raw: str) -> tuple[str, str | None]:
    """Strip a quoted nickname (returned separately), backtick/paren qualifiers,
    and annotation symbols from a bold-span's inner text. Returns (cleaned, nickname)."""
    nickname: str | None = None
    match = NICKNAME_RE.search(raw)
    if match:
        nickname = " ".join(match.group(1).split()) or None
        raw = NICKNAME_RE.sub(" ", raw)
    raw = BACKTICK_QUALIFIER_RE.sub(" ", raw)
    raw = PAREN_QUALIFIER_RE.sub(" ", raw)
    for ch in SYMBOL_CHARS:
        raw = raw.replace(ch, " ")
    cleaned = " ".join(raw.split())
    return cleaned, nickname


def register(name_index: dict[str, list[dict[str, str]]], key: str, target: dict[str, str]) -> None:
    if not key:
        return
    existing = name_index.setdefault(key, [])
    if not any(item["vault"] == target["vault"] and item["page"] == target["page"] for item in existing):
        existing.append(target)


def build_name_index(config: Path) -> tuple[dict[str, list[dict[str, str]]], list[Any]]:
    docs = build_page_docs(config)
    people_docs = [doc for doc in docs if Path(doc.page).stem.casefold() == "people"]
    vault_roots = load_vault_config(config)
    name_index: dict[str, list[dict[str, str]]] = {}

    for doc in people_docs:
        root_entry = vault_roots.get(doc.vault)
        if root_entry is None:
            continue
        root, _purpose = root_entry
        page_path = root / doc.page
        try:
            text = page_path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue

        current_heading: str | None = None
        for line in text.splitlines():
            if line.startswith("## "):
                current_heading = line[3:].strip()
                continue
            for bold_match in BOLD_RE.finditer(line):
                cleaned, nickname = clean_bold_span(bold_match.group(1))
                if not any(ch.isalpha() for ch in cleaned):
                    continue
                target = {"vault": doc.vault, "page": doc.page, "section": current_heading or "People"}
                key = " ".join(cleaned.casefold().split())
                register(name_index, key, target)
                if nickname:
                    register(name_index, " ".join(nickname.casefold().split()), target)

    return name_index, docs


def known_page_terms(docs: list[Any]) -> set[str]:
    terms: set[str] = set()
    for doc in docs:
        if doc.title:
            terms.add(doc.title.casefold())
        for heading in doc.headings:
            terms.add(heading.casefold())
    return terms


_SUBJECT_CACHE: dict[str, re.Pattern[str]] = {}


def subject_pattern(key: str) -> re.Pattern[str]:
    """Anchored subject-position matcher for a roster key. Requires the key at
    the very start of the content (after optional leading non-word chars) and
    rejects a trailing possessive apostrophe so "Avery Patel's team ..."
    does NOT pre-route a tooling fact to a person."""
    pattern = _SUBJECT_CACHE.get(key)
    if pattern is None:
        pattern = re.compile(rf"\W*{re.escape(key)}(?![\'’])\b")
        _SUBJECT_CACHE[key] = pattern
    return pattern


def match_subject_targets(content_cf: str, name_index: dict[str, list[dict[str, str]]]) -> list[dict[str, str]]:
    """Targets for the single longest roster key that sits at subject position
    (fact starts with the name). No subject-position key -> no pre-route."""
    matched = [key for key in name_index if subject_pattern(key).match(content_cf)]
    if not matched:
        return []
    best = sorted(matched, key=lambda k: (-len(k), k))[0]
    return list(name_index[best])


def resolve_target(targets: list[dict[str, str]], preferred_vault: str | None) -> dict[str, str]:
    """Deterministic tie-break with an optional configured preferred vault."""
    if len(targets) == 1:
        return targets[0]
    return sorted(
        targets,
        key=lambda target: (
            preferred_vault is None or target["vault"] != preferred_vault,
            target["vault"],
            target["page"],
        ),
    )[0]


def detect_new_person(
    content: str,
    name_index: dict[str, list[dict[str, str]]],
    known_terms: set[str],
    stoplist_cf: set[str],
) -> list[str]:
    # Precision over recall: only a Title-Case span at subject position (fact
    # start, after leading non-word chars) can be a new person. Object-position
    # mentions ("Met with Sarah Chen") are deliberately not flagged.
    lead = re.match(r"\W*", content)
    start = lead.end() if lead else 0
    match = TITLE_CASE_RE.match(content, start)
    if match is None:
        return []
    span = match.group(0)
    first_token = span.split()[0].casefold()
    # Verb/gerund first token -> it's an action, not a name ("Implementing
    # Google Calendar", "Configured Power BI", "Next project", "Met Sarah").
    if first_token.endswith("ing") or first_token in VERB_STARTERS:
        return []
    span_cf = " ".join(span.casefold().split())
    if span_cf in stoplist_cf or span_cf in known_terms or span_cf in name_index:
        return []
    return [span]


def process_candidates(
    candidates: list[dict[str, Any]],
    name_index: dict[str, list[dict[str, str]]],
    known_terms: set[str],
    stoplist_cf: set[str],
    preferred_vault: str | None,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    pre_routed: list[dict[str, Any]] = []
    new_person: list[dict[str, Any]] = []
    remaining: list[dict[str, Any]] = []

    for candidate in candidates:
        content = str(candidate.get("content") or "")
        content_cf = content.casefold()
        targets = match_subject_targets(content_cf, name_index)
        if targets:
            target = resolve_target(targets, preferred_vault)
            pre_routed.append(
                {
                    "candidate_id": candidate_id(candidate),
                    "candidate": candidate,
                    "route": {
                        "status": "routed",
                        "vault": target["vault"],
                        "page": target["page"],
                        "section": target["section"],
                        "routing_confidence": "high",
                    },
                }
            )
            continue

        detected = detect_new_person(content, name_index, known_terms, stoplist_cf)
        if detected:
            new_person.append(
                {
                    "candidate_id": candidate_id(candidate),
                    "candidate": candidate,
                    "detected_names": detected,
                }
            )
            continue

        remaining.append(candidate)

    return pre_routed, new_person, remaining


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path, help="dream-skill config.toml")
    parser.add_argument("--report", action="store_true", help="write a one-line split report to stderr")
    args = parser.parse_args(argv)

    try:
        candidates = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        return die(f"invalid JSON: {exc}")
    if not isinstance(candidates, list):
        return die("input must be a JSON array")
    for index, candidate in enumerate(candidates):
        if not isinstance(candidate, dict):
            return die(f"candidate #{index + 1} is not an object")

    try:
        name_index, docs = build_name_index(args.config)
        preferred_vault, configured_stop_terms = load_entity_routing_config(args.config)
    except (OSError, ValueError) as exc:
        return die(f"failed to build known-name index: {exc}")

    known_terms = known_page_terms(docs)
    stoplist_cf = {
        term.casefold()
        for term in (DEFAULT_STOP_TERMS | MONTHS | WEEKDAYS | configured_stop_terms)
    }

    pre_routed, new_person, remaining = process_candidates(
        candidates,
        name_index,
        known_terms,
        stoplist_cf,
        preferred_vault,
    )

    if args.report:
        print(
            f"route-entities: in={len(candidates)} pre_routed={len(pre_routed)} "
            f"new_person={len(new_person)} remaining={len(remaining)}",
            file=sys.stderr,
        )

    json.dump(
        {"pre_routed": pre_routed, "new_person": new_person, "remaining": remaining},
        sys.stdout,
        ensure_ascii=False,
    )
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
