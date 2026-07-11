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


def content_page(path: Path) -> bool:
    return (
        path.suffix.casefold() == ".md"
        and path.name not in EXCLUDED_NAMES
        and "Attachments" not in path.parts
        and not any(part.startswith(".") for part in path.parts)
    )


def parse_page(path: Path) -> tuple[str, list[str], str]:
    text = path.read_text(encoding="utf-8", errors="ignore")
    title = ""
    headings: list[str] = []
    body_lines: list[str] = []
    in_frontmatter = text.startswith("---\n")
    for index, line in enumerate(text.splitlines()):
        if index == 0 and in_frontmatter:
            continue
        if in_frontmatter:
            if line.strip() == "---":
                in_frontmatter = False
            continue
        if line.startswith("# ") and not title:
            title = line[2:].strip()
        elif line.startswith("## "):
            headings.append(line[3:].strip())
        if not line.startswith("```"):
            body_lines.append(line)
    return title, headings[:20], "\n".join(body_lines)


def build_page_docs(config_path: Path) -> list[PageDoc]:
    docs: list[PageDoc] = []
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
            title, headings, body = parse_page(path)
            weighted: Counter[str] = Counter()
            weighted.update({term: count * 5 for term, count in Counter(tokens(rel)).items()})
            weighted.update({term: count * 5 for term, count in Counter(tokens(title)).items()})
            weighted.update({term: count * 3 for term, count in Counter(tokens(" ".join(headings))).items()})
            weighted.update({term: count * 2 for term, count in Counter(tokens(purpose)).items()})
            weighted.update(Counter(tokens(body)))
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
    if any(term in query for term in person_terms) and "people" in doc.page.casefold():
        boost += 12.0
    stem = Path(doc.page).stem.casefold().replace("-", " ").replace("_", " ")
    if stem and stem in query:
        boost += 14.0
    if doc.title and doc.title.casefold() in query:
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
