#!/usr/bin/env python3
"""Extract compact, deterministic project context from a source transcript."""

from __future__ import annotations

import argparse
import json
import os
import tomllib
from pathlib import Path
from typing import Any


def _nested_cwd(value: Any) -> str | None:
    if not isinstance(value, dict):
        return None
    for key in ("cwd", "working_directory", "workdir"):
        candidate = value.get(key)
        if isinstance(candidate, str) and candidate.strip():
            return os.path.realpath(os.path.expanduser(candidate.strip()))
    return None


def transcript_cwd(source_chat: str | Path) -> str | None:
    """Read only the metadata prefix; never expose transcript content."""
    path = Path(source_chat)
    if not path.is_file():
        return None
    try:
        with path.open("r", encoding="utf-8", errors="ignore") as handle:
            for index, line in enumerate(handle):
                if index >= 120:
                    break
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(event, dict):
                    continue
                for value in (
                    event,
                    event.get("payload"),
                    event.get("attachment"),
                    event.get("session_meta"),
                ):
                    cwd = _nested_cwd(value)
                    if cwd:
                        return cwd
    except OSError:
        return None
    return None


def _workspace_roots(config_path: Path) -> list[dict[str, Any]]:
    try:
        with config_path.open("rb") as handle:
            parsed = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError):
        return []
    routing = parsed.get("routing")
    roots = routing.get("workspace_roots") if isinstance(routing, dict) else None
    if not isinstance(roots, list):
        return []
    return [item for item in roots if isinstance(item, dict) and isinstance(item.get("path"), str)]


def context_for_cwd(cwd: str | None, config_path: Path) -> dict[str, Any]:
    result: dict[str, Any] = {"cwd": cwd}
    if not cwd:
        return result

    matches = []
    for item in _workspace_roots(config_path):
        root = os.path.realpath(os.path.expanduser(str(item["path"])))
        if cwd == root or cwd.startswith(root + os.sep):
            matches.append((len(root), root, item))
    if not matches:
        return result

    _, root, item = max(matches, key=lambda match: match[0])
    project = str(item.get("project") or Path(root).name)
    aliases = item.get("aliases")
    if not isinstance(aliases, list):
        aliases = []
    normalized_aliases = [str(alias).strip() for alias in aliases if str(alias).strip()]
    if project not in normalized_aliases:
        normalized_aliases.insert(0, project)
    result.update(
        {
            "workspace_root": root,
            "project": project,
            "preferred_vault": str(item.get("vault") or ""),
            "aliases": normalized_aliases,
        }
    )
    return result


def context_for_source(source_chat: str | Path, config_path: Path) -> dict[str, Any]:
    return context_for_cwd(transcript_cwd(source_chat), config_path)


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract source transcript working context")
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("source_chat", type=Path)
    args = parser.parse_args()
    print(json.dumps(context_for_source(args.source_chat, args.config), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
