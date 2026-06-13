"""Write transcript + summary as an Obsidian-flavored markdown note with frontmatter."""

from __future__ import annotations

import re
import unicodedata
from datetime import datetime
from pathlib import Path

from jinja2 import Environment, FileSystemLoader, select_autoescape

from transcribe_audio.config import Config
from transcribe_audio.summarize import SummaryResult
from transcribe_audio.transcribe import TranscriptionResult

TEMPLATE_DIR = Path(__file__).parent / "templates"


def slugify(text: str, max_len: int = 60) -> str:
    """Convert arbitrary text to a clean filename slug.

    Handles Ukrainian, Russian, English. Strips diacritics, lowercases,
    replaces whitespace with dashes, removes filesystem-unfriendly chars.
    """
    if not text:
        return "untitled"
    # NFKD decomposes accented Latin into base letter + combining marks; the
    # keep-regex below drops the marks (folding é→e) while leaving Cyrillic intact.
    # Applying it to the original text keeps BOTH scripts in a mixed title instead
    # of discarding the Cyrillic half (the old ASCII-fold path lost it).
    base = unicodedata.normalize("NFKD", text).lower()
    base = re.sub(r"[^a-z0-9Ѐ-ӿ\s-]", "", base)  # keep latin, cyrillic, digits, ws, dash
    base = re.sub(r"\s+", "-", base.strip())
    base = re.sub(r"-+", "-", base)
    base = base.strip("-")
    if len(base) > max_len:
        base = base[:max_len].rstrip("-")
    return base or "untitled"


def write_obsidian_note(
    transcription: TranscriptionResult,
    summary: SummaryResult | None,
    config: Config,
    title: str | None = None,
    subdir: str | None = None,
    extra_frontmatter: dict | None = None,
) -> Path:
    """Write the note. Returns the path written.

    Filename pattern: {date}-{slug}.md  (from config.obsidian_filename_pattern)
    Path: {vault_path}/{subdir or config.obsidian_inbox_subdir}/{filename}
    """
    if not config.vault_path:
        raise ValueError(
            "vault_path not set. Add OBSIDIAN_VAULT_PATH to .env or "
            "run `transcribe-audio init` and set the Obsidian vault."
        )

    source_name = transcription.source_path.stem if transcription.source_path else "transcript"
    title = title or source_name
    today = datetime.now().strftime("%Y-%m-%d")
    now_iso = datetime.now().isoformat(timespec="seconds")
    slug = slugify(title)
    filename = config.obsidian_filename_pattern.format(date=today, slug=slug) + ".md"
    # The pattern comes from config and is .format()-ed, so guard against a value
    # that injects a path separator and escapes the target directory.
    if "/" in filename or "\\" in filename:
        raise ValueError(f"obsidian_filename_pattern produced a path separator: {filename!r}")

    vault_root = config.vault_path.resolve()
    target_dir = (config.vault_path / (subdir or config.obsidian_inbox_subdir)).resolve()
    if target_dir != vault_root and vault_root not in target_dir.parents:
        raise ValueError(f"subdir {subdir!r} escapes the vault root {vault_root}")
    target_dir.mkdir(parents=True, exist_ok=True)

    target_path = target_dir / filename
    # Never clobber an existing note (e.g. re-transcribing the same file the same
    # day); suffix -1, -2, … until a free name is found.
    if target_path.exists():
        stem, suffix = target_path.stem, target_path.suffix
        n = 1
        while target_path.exists():
            target_path = target_dir / f"{stem}-{n}{suffix}"
            n += 1

    env = Environment(
        loader=FileSystemLoader(TEMPLATE_DIR),
        autoescape=select_autoescape(disabled_extensions=("md", "j2")),
        keep_trailing_newline=True,
    )
    template = env.get_template("obsidian_note.md.j2")

    frontmatter = {
        "created": now_iso,
        "type": "transcript",
        "source": str(transcription.source_path) if transcription.source_path else None,
        "duration_seconds": round(transcription.duration, 1),
        "language": transcription.language,
        "transcribe_model": "whisper-1",  # could thread through if needed
        "summary_model": summary.model if summary else None,
        "summary_style": summary.style if summary else None,
    }
    if extra_frontmatter:
        frontmatter.update(extra_frontmatter)

    rendered = template.render(
        title=title,
        frontmatter=frontmatter,
        transcript=transcription.text.strip(),
        summary=summary.text.strip() if summary else None,
        segments=transcription.segments,
    )
    target_path.write_text(rendered, encoding="utf-8")
    return target_path
