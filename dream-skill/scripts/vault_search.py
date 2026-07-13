#!/usr/bin/env python3
"""Local canonical-page indexing and weighted BM25 retrieval for Dream routing."""

from __future__ import annotations

import math
import re
import tomllib
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any


TOKEN_RE = re.compile(r"[a-z0-9][a-z0-9_+-]*", re.IGNORECASE)
EXCLUDED_NAMES = {"AGENTS.md", "CLAUDE.md", "index.md"}
NONCANONICAL_PATH_TERMS = {"archive", "archives", "raw", "log", "logs"}
NONCANONICAL_STATUSES = {"archived", "completed"}
OVERVIEW_TOKEN_LIMIT = 96


def tokens(text: str) -> list[str]:
    return [token.casefold() for token in TOKEN_RE.findall(text) if len(token) > 1]


@dataclass
class PageDoc:
    vault: str
    page: str
    title: str
    headings: list[str]
    purpose: str
    weighted_tf: Counter[str]
    length: float


def load_vault_config(config_path: Path) -> dict[str, tuple[Path, str]]:
    with config_path.open("rb") as handle:
        parsed = tomllib.load(handle)
    vaults = parsed.get("vaults")
    if not isinstance(vaults, dict):
        raise ValueError("config has no [vaults.*] entries")
    result: dict[str, tuple[Path, str]] = {}
    for name, value in vaults.items():
        if not isinstance(value, dict) or not isinstance(value.get("root"), str):
            continue
        result[str(name)] = (
            Path(value["root"]).expanduser().resolve(),
            str(value.get("description") or ""),
        )
    return result


def load_vault_policies(config_path: Path) -> dict[str, dict[str, Any]]:
    """Load optional per-vault safety and routing policy without changing the
    long-standing load_vault_config() return shape used by callers."""
    with config_path.open("rb") as handle:
        parsed = tomllib.load(handle)
    vaults = parsed.get("vaults")
    if not isinstance(vaults, dict):
        return {}
    policies: dict[str, dict[str, Any]] = {}
    for name, value in vaults.items():
        if not isinstance(value, dict):
            continue
        include = value.get("route_include")
        exclude = value.get("route_exclude")
        policies[str(name)] = {
            "review_only": value.get("review_only") is True,
            "route_include": [str(item).strip("/") for item in include if isinstance(item, str) and item.strip("/")]
            if isinstance(include, list)
            else [],
            "route_exclude": [str(item).strip("/") for item in exclude if isinstance(item, str) and item.strip("/")]
            if isinstance(exclude, list)
            else [],
        }
    return policies


def route_path_allowed(relative: str, policy: dict[str, Any]) -> bool:
    def matches(prefix: str) -> bool:
        return relative == prefix or relative.startswith(prefix + "/")

    includes = policy.get("route_include") or []
    excludes = policy.get("route_exclude") or []
    if includes and not any(matches(prefix) for prefix in includes):
        return False
    return not any(matches(prefix) for prefix in excludes)


def default_route_exclusion_reason(relative: str, frontmatter_status: str) -> str | None:
    """Explain why a page is unsafe as an automatic canonical destination.

    Explicit ``route_include``/``route_exclude`` policy bounds the search tree;
    this default guard then removes archival and work-output surfaces inside
    that tree.  Separating the reason from the boolean makes diagnostics and
    regression tests precise without exposing excluded pages to the model.
    """
    parts = Path(relative).parts
    for part in parts[:-1]:
        normalized = part.casefold().strip(" ._-")
        if normalized in NONCANONICAL_PATH_TERMS:
            return f"noncanonical directory: {part}"

    stem_terms = {
        term.casefold()
        for term in re.findall(r"[a-z0-9]+", Path(relative).stem, re.IGNORECASE)
    }
    matched_terms = sorted(stem_terms & NONCANONICAL_PATH_TERMS)
    if matched_terms:
        return f"noncanonical page type: {matched_terms[0]}"

    normalized_status = frontmatter_status.casefold().strip()
    if normalized_status in NONCANONICAL_STATUSES:
        return f"frontmatter status: {normalized_status}"
    return None


def content_page(path: Path) -> bool:
    return (
        path.suffix.casefold() == ".md"
        and path.name not in EXCLUDED_NAMES
        and "Attachments" not in path.parts
        and not any(part.startswith(".") for part in path.parts)
    )


def parse_page(path: Path) -> tuple[str, list[str], str, str]:
    text = path.read_text(encoding="utf-8", errors="ignore")
    title = ""
    headings: list[str] = []
    overview_lines: list[str] = []
    frontmatter_status = ""
    lines = text.splitlines()
    in_frontmatter = bool(lines and lines[0].strip() == "---")
    in_code_fence = False
    reached_h2 = False
    for index, line in enumerate(lines):
        if index == 0 and in_frontmatter:
            continue
        if in_frontmatter:
            if line.strip() == "---":
                in_frontmatter = False
                continue
            status_match = re.match(r"^\s*status\s*:\s*(.*?)\s*$", line, re.IGNORECASE)
            if status_match:
                raw_status = status_match.group(1).split("#", 1)[0].strip()
                frontmatter_status = raw_status.strip("'\"[] ")
            continue
        if line.strip().startswith("```"):
            in_code_fence = not in_code_fence
            continue
        if in_code_fence:
            continue
        if line.startswith("# ") and not title:
            title = line[2:].strip()
        elif line.startswith("## "):
            headings.append(line[3:].strip())
            reached_h2 = True
        elif (
            not reached_h2
            and not line.startswith("#")
            and not re.match(r"^\s*(?:[-*+] |\d+[.)] |\|)", line)
            and line.strip()
        ):
            # Only index a short prose synopsis before the first H2. Facts
            # appended by Dream live under H2 sections and therefore cannot
            # increase their target page's future retrieval score.
            overview_lines.append(line.strip())

    overview_terms = tokens(" ".join(overview_lines))[:OVERVIEW_TOKEN_LIMIT]
    return title, headings[:20], " ".join(overview_terms), frontmatter_status


def build_page_docs(config_path: Path) -> list[PageDoc]:
    docs: list[PageDoc] = []
    policies = load_vault_policies(config_path)
    for vault, (root, purpose) in load_vault_config(config_path).items():
        if not root.is_dir():
            continue
        scan_root = root / "wiki" if (root / "wiki").is_dir() else root
        for path in sorted(scan_root.rglob("*.md")):
            if not content_page(path):
                continue
            try:
                rel = path.resolve().relative_to(root).as_posix()
            except ValueError:
                continue
            if not route_path_allowed(rel, policies.get(vault, {})):
                continue
            title, headings, overview, frontmatter_status = parse_page(path)
            if default_route_exclusion_reason(rel, frontmatter_status) is not None:
                continue
            weighted: Counter[str] = Counter()
            weighted.update({term: count * 5 for term, count in Counter(tokens(rel)).items()})
            weighted.update({term: count * 5 for term, count in Counter(tokens(title)).items()})
            weighted.update({term: count * 3 for term, count in Counter(tokens(" ".join(headings))).items()})
            weighted.update({term: count * 2 for term, count in Counter(tokens(purpose)).items()})
            # A bounded, de-duplicated introductory synopsis can distinguish
            # generic page names without allowing repeated body facts to
            # dominate BM25 or create a self-reinforcing routing loop.
            weighted.update(Counter(set(tokens(overview))))
            docs.append(
                PageDoc(
                    vault=vault,
                    page=rel,
                    title=title,
                    headings=headings,
                    purpose=purpose,
                    weighted_tf=weighted,
                    length=float(sum(weighted.values()) or 1),
                )
            )
    return docs


def domain_boost(query_text: str, doc: PageDoc) -> float:
    query_terms = set(tokens(query_text))
    boost = 0.0
    purpose_overlap = query_terms & set(tokens(doc.purpose))
    if purpose_overlap:
        boost += min(7.0, 2.0 * len(purpose_overlap))
    person_terms = (
        "mentor",
        "friend",
        "classmate",
        "family",
        "teammate",
        "colleague",
        "contact",
        "spoke with",
        "met with",
        "manager",
    )
    query = query_text.casefold()
    normalized_query = " ".join(tokens(query_text))

    def contains_phrase(value: str) -> bool:
        phrase = " ".join(tokens(value))
        return bool(phrase) and f" {phrase} " in f" {normalized_query} "

    if any(term in query for term in person_terms) and "people" in doc.page.casefold():
        boost += 12.0
    stem = Path(doc.page).stem.casefold().replace("-", " ").replace("_", " ")
    if contains_phrase(stem):
        boost += 14.0
    if doc.title and contains_phrase(doc.title):
        boost += 14.0
    return boost


class PageSearch:
    def __init__(self, docs: list[PageDoc]) -> None:
        self.docs = docs
        self.avg_length = sum(doc.length for doc in docs) / max(len(docs), 1)
        self.df: Counter[str] = Counter()
        for doc in docs:
            self.df.update(doc.weighted_tf.keys())

    def search(self, query_text: str, limit: int = 8) -> list[dict[str, Any]]:
        query_terms = Counter(tokens(query_text))
        n_docs = len(self.docs)
        scored: list[tuple[float, PageDoc]] = []
        k1 = 1.2
        b = 0.75
        for doc in self.docs:
            score = domain_boost(query_text, doc)
            for term, query_count in query_terms.items():
                tf = float(doc.weighted_tf.get(term, 0))
                if not tf:
                    continue
                df = self.df.get(term, 0)
                idf = math.log(1.0 + (n_docs - df + 0.5) / (df + 0.5))
                denom = tf + k1 * (1.0 - b + b * doc.length / self.avg_length)
                score += query_count * idf * (tf * (k1 + 1.0) / denom)
            if score > 0:
                scored.append((score, doc))
        scored.sort(key=lambda pair: (-pair[0], pair[1].vault, pair[1].page))
        return [
            {
                "vault": doc.vault,
                "page": doc.page,
                "title": doc.title,
                "headings": doc.headings[:8],
                "score": round(score, 4),
            }
            for score, doc in scored[:limit]
        ]
