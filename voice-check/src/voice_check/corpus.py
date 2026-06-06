"""Load and normalize input files into kinded corpus records.

Supports .txt, .md (with optional YAML-ish frontmatter), .jsonl, and .csv.
A .jsonl row carrying Wispr-style fields (asr_text / formatted_text /
edited_text) explodes into up to three records sharing a `row_id`, so the
profiler can compare the raw-speech and polished versions of one utterance.
"""

from __future__ import annotations

import csv
import hashlib
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

RAW_SPEECH = "raw_speech"
POLISHED = "polished_writing"
EDITED = "edited_revision"
UNKNOWN = "unknown"
VALID_KINDS = {RAW_SPEECH, POLISHED, EDITED, UNKNOWN}

SUBFOLDER_KIND = {
    "speech": RAW_SPEECH,
    "writing": POLISHED,
    "edits": EDITED,
    "edit": EDITED,
}
SUFFIX_KIND = {"speech": RAW_SPEECH, "writing": POLISHED, "edit": EDITED}
JSONL_FIELD_KIND = {
    "asr_text": RAW_SPEECH,
    "formatted_text": POLISHED,
    "edited_text": EDITED,
}
GENERIC_TEXT_FIELDS = ("text", "content", "body", "message")

SUPPORTED_SUFFIXES = {".txt", ".md", ".jsonl", ".csv"}


@dataclass(frozen=True)
class Record:
    id: str
    source_path: str
    text: str
    kind: str
    created_at: Optional[str]
    metadata: dict


def stable_id(source_path: str, text: str) -> str:
    digest = hashlib.sha1(f"{source_path}\x00{text}".encode("utf-8", "replace"))
    return digest.hexdigest()[:16]


def _norm_kind(value: Optional[str]) -> Optional[str]:
    value = (value or "").strip().lower()
    return value if value in VALID_KINDS else None


def detect_kind(path, explicit: Optional[str] = None, frontmatter: Optional[dict] = None) -> str:
    kind = _norm_kind(explicit)
    if kind:
        return kind
    if frontmatter:
        kind = _norm_kind(frontmatter.get("kind"))
        if kind:
            return kind
    parts = [p.lower() for p in Path(path).parts]
    for segment, mapped in SUBFOLDER_KIND.items():
        if segment in parts:
            return mapped
    name = Path(path).name.lower()
    for segment, mapped in SUFFIX_KIND.items():
        if f".{segment}." in name:
            return mapped
    return UNKNOWN


def _parse_frontmatter(md_text: str) -> tuple[dict, str]:
    if md_text.startswith("---"):
        end = md_text.find("\n---", 3)
        if end != -1:
            block = md_text[3:end].strip()
            body = md_text[end + 4 :].lstrip("\n")
            fm: dict = {}
            for line in block.splitlines():
                if ":" in line:
                    key, val = line.split(":", 1)
                    fm[key.strip().lower()] = val.strip()
            return fm, body
    return {}, md_text


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def _created(obj: dict) -> Optional[str]:
    for key in ("created_at", "timestamp", "date"):
        if obj.get(key):
            return str(obj[key])
    return None


def _load_jsonl(path: Path) -> list[Record]:
    out: list[Record] = []
    for i, line in enumerate(_read(path).splitlines()):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(obj, dict):
            continue
        row_id = str(obj.get("transcript_id") or obj.get("id") or f"{path.name}:{i}")
        created = _created(obj)
        emitted = False
        for field_name, kind in JSONL_FIELD_KIND.items():
            val = obj.get(field_name)
            if isinstance(val, str) and val.strip():
                out.append(
                    Record(
                        stable_id(f"{path}#{row_id}#{field_name}", val),
                        str(path),
                        val.strip(),
                        kind,
                        created,
                        {"row_id": row_id, "field": field_name},
                    )
                )
                emitted = True
        if emitted:
            continue
        for tf in GENERIC_TEXT_FIELDS:
            val = obj.get(tf)
            if isinstance(val, str) and val.strip():
                kind = detect_kind(path, explicit=obj.get("kind"))
                out.append(
                    Record(
                        stable_id(f"{path}#{row_id}#{tf}", val),
                        str(path),
                        val.strip(),
                        kind,
                        created,
                        {"row_id": row_id},
                    )
                )
                break
    return out


def _load_csv(path: Path) -> list[Record]:
    out: list[Record] = []
    with path.open(encoding="utf-8", errors="replace", newline="") as handle:
        reader = csv.DictReader(handle)
        for i, row in enumerate(reader):
            text = None
            for tf in GENERIC_TEXT_FIELDS:
                if row.get(tf) and row[tf].strip():
                    text = row[tf].strip()
                    break
            if not text:
                continue
            kind = detect_kind(path, explicit=row.get("kind"))
            created = row.get("created_at") or row.get("timestamp") or row.get("date") or None
            out.append(
                Record(stable_id(f"{path}#{i}", text), str(path), text, kind, created, {})
            )
    return out


def _records_from_body(path: Path, body: str, frontmatter: Optional[dict] = None) -> list[Record]:
    body = body.strip()
    if not body:
        return []
    fm = frontmatter or {}
    kind = detect_kind(path, explicit=fm.get("kind"), frontmatter=fm)
    created = fm.get("created_at") or fm.get("date")
    return [Record(stable_id(str(path), body), str(path), body, kind, created, {})]


def load_file(path) -> list[Record]:
    path = Path(path)
    suffix = path.suffix.lower()
    if suffix == ".md":
        fm, body = _parse_frontmatter(_read(path))
        return _records_from_body(path, body, fm)
    if suffix == ".txt":
        return _records_from_body(path, _read(path))
    if suffix == ".jsonl":
        return _load_jsonl(path)
    if suffix == ".csv":
        return _load_csv(path)
    return []


def load_corpus(input_dir) -> list[Record]:
    input_dir = Path(input_dir)
    out: list[Record] = []
    for path in sorted(input_dir.rglob("*")):
        if not path.is_file() or path.name.startswith("."):
            continue
        if path.name.lower() in ("readme.md", "readme.txt"):
            continue
        if path.suffix.lower() not in SUPPORTED_SUFFIXES:
            continue
        out.extend(load_file(path))
    return out
