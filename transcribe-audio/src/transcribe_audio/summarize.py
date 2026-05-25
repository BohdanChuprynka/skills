"""LLM summarization of a transcript. Templated styles + custom prompt support."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from openai import OpenAI

from transcribe_audio.config import Config

TEMPLATE_DIR = Path(__file__).parent / "templates" / "summary_styles"


@dataclass
class SummaryResult:
    text: str
    style: str
    model: str


def _load_style_template(style: str) -> str:
    """Load a built-in style or read a custom template file."""
    path = TEMPLATE_DIR / f"{style}.txt"
    if path.exists():
        return path.read_text()
    # Allow user to pass a custom file path as --summary-style
    custom = Path(style).expanduser()
    if custom.exists():
        return custom.read_text()
    raise FileNotFoundError(
        f"Summary style '{style}' not found. "
        f"Built-in styles: {[p.stem for p in TEMPLATE_DIR.glob('*.txt')]}. "
        f"Or pass a path to a custom template file."
    )


def summarize_text(
    transcript: str,
    config: Config,
    style: str = "brief",
    custom_prompt: str | None = None,
    language: str | None = None,
) -> SummaryResult:
    """Generate an LLM summary of a transcript.

    Args:
        transcript: full transcript text
        config: loaded Config
        style: name of a built-in style ('brief', 'detailed', 'action_items')
               OR path to a custom template file containing the system prompt.
        custom_prompt: explicit system prompt, overrides `style` entirely.
        language: tells the model what language to write the summary in.
                  Defaults to None (model auto-detects).
    """
    client = OpenAI(api_key=config.openai_api_key)

    system_prompt = custom_prompt or _load_style_template(style)
    if language and language != "auto":
        system_prompt += f"\n\nWrite the summary in language: {language}."

    response = client.chat.completions.create(
        model=config.summary_model,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": transcript},
        ],
        temperature=0.3,
    )
    return SummaryResult(
        text=response.choices[0].message.content or "",
        style=style,
        model=config.summary_model,
    )
