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
    # Transliterate Cyrillic + drop combining marks.
    nfkd = unicodedata.normalize("NFKD", text)
    ascii_text = nfkd.encode("ascii", "ignore").decode("ascii")
    # If pure Cyrillic, ascii_text may be empty — fall back to original.
    base = ascii_text if ascii_text.strip() else text
    base = base.lower()
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

    target_dir = config.vault_path / (subdir or config.obsidian_inbox_subdir)
    target_dir.mkdir(parents=True, exist_ok=True)
    target_path = target_dir / filename

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
