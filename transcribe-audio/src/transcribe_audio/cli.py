"""Command-line interface (Typer)."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Annotated

import typer
from rich.console import Console
from rich.progress import Progress, SpinnerColumn, TextColumn
from rich.prompt import Confirm, Prompt

from transcribe_audio import __version__
from transcribe_audio.audio import probe_audio
from transcribe_audio.config import Config, get_config_file, load_config, write_config
from transcribe_audio.obsidian import write_obsidian_note
from transcribe_audio.summarize import summarize_text
from transcribe_audio.transcribe import estimate_cost_usd, transcribe_file

app = typer.Typer(
    name="transcribe-audio",
    help="Audio file → transcript → optional summary → optional Obsidian note. OpenAI Whisper backend.",
    no_args_is_help=True,
    add_completion=False,
)
console = Console()


def _version_callback(value: bool) -> None:
    if value:
        console.print(f"transcribe-audio v{__version__}")
        raise typer.Exit()


@app.callback()
def main_callback(
    version: Annotated[
        bool, typer.Option("--version", callback=_version_callback, is_eager=True)
    ] = False,
) -> None:
    """transcribe-audio: turn voice recordings into transcripts, summaries, and notes."""
    pass


def _resolve_summary_style(value: str | None, config: Config) -> str:
    """An explicit --summary-style/--style flag wins; otherwise fall back to the
    configured default_summary_style instead of a hardcoded 'brief'."""
    return value or config.default_summary_style


# =================================================================================
# transcribe
# =================================================================================
@app.command()
def transcribe(
    file: Annotated[Path, typer.Argument(help="Path to audio file (.mp3, .m4a, .wav, .mp4, etc.)")],
    language: Annotated[
        str | None,
        typer.Option(
            "--language",
            "-l",
            help="Language code: 'auto', 'uk', 'en', 'ru', etc. Overrides config.",
        ),
    ] = None,
    prompt: Annotated[
        str | None,
        typer.Option(
            "--prompt",
            "-p",
            help="Initial prompt to prime Whisper with proper nouns / tech vocab.",
        ),
    ] = None,
    summary: Annotated[
        bool, typer.Option("--summary/--no-summary", help="Also generate an LLM summary.")
    ] = False,
    summary_style: Annotated[
        str | None,
        typer.Option(
            "--summary-style",
            help="Built-in: brief, detailed, action_items. Or path to a custom template. "
            "Defaults to config's default_summary_style.",
        ),
    ] = None,
    obsidian: Annotated[
        bool,
        typer.Option(
            "--obsidian/--no-obsidian", help="Write a note to the configured Obsidian vault."
        ),
    ] = False,
    output_dir: Annotated[
        Path | None,
        typer.Option(
            "--output-dir",
            "-o",
            help="Where to write .txt/.srt/.vtt/.json. Default: ./transcripts/",
        ),
    ] = None,
    no_confirm: Annotated[
        bool, typer.Option("--no-confirm", help="Skip the cost confirmation prompt.")
    ] = False,
    formats: Annotated[
        str,
        typer.Option(
            "--formats",
            help="Comma-separated output formats: txt, srt, vtt, json, all. Default: txt,srt.",
        ),
    ] = "txt,srt",
) -> None:
    """Transcribe an audio file."""
    config = load_config()
    summary_style = _resolve_summary_style(summary_style, config)
    file = file.expanduser().resolve()

    if not file.exists():
        console.print(f"[red]File not found: {file}[/red]")
        raise typer.Exit(1)

    # Probe + cost estimate
    info = probe_audio(file)
    cost = estimate_cost_usd(info.duration_seconds, config.transcribe_model)
    console.print(
        f"[bold]{file.name}[/bold] — {info.duration_minutes:.1f} min, "
        f"{info.size_mb:.1f} MB, {info.codec} {info.sample_rate}Hz "
        f"({info.channels} ch)"
    )
    console.print(
        f"Estimated cost: [yellow]${cost:.4f}[/yellow]  "
        f"(model: {config.transcribe_model})"
    )

    if (
        not no_confirm
        and info.duration_minutes > config.confirm_above_minutes
        and not Confirm.ask("Proceed?", default=True)
    ):
        raise typer.Exit()

    # Transcribe
    with Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        console=console,
    ) as progress:
        task = progress.add_task("Transcribing...", total=None)

        def cb(stage: str, current: int, total: int) -> None:
            progress.update(task, description=f"{stage}: {current}/{total}")

        result = transcribe_file(file, config, language=language, initial_prompt=prompt, on_progress=cb)
        progress.update(task, description=f"Transcribed {len(result.segments)} segments")

    # Write outputs
    output_dir = (output_dir or config.default_output_dir).expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    base = output_dir / file.stem

    format_set = {f.strip() for f in formats.lower().split(",")}
    if "all" in format_set:
        format_set = {"txt", "srt", "vtt", "json"}

    written: list[Path] = []
    if "txt" in format_set:
        p = base.with_suffix(".txt")
        p.write_text(result.text, encoding="utf-8")
        written.append(p)
    if "srt" in format_set:
        p = base.with_suffix(".srt")
        p.write_text(result.to_srt(), encoding="utf-8")
        written.append(p)
    if "vtt" in format_set:
        p = base.with_suffix(".vtt")
        p.write_text(result.to_vtt(), encoding="utf-8")
        written.append(p)
    if "json" in format_set:
        p = base.with_suffix(".json")
        payload = {
            "language": result.language,
            "duration": result.duration,
            "text": result.text,
            "segments": [
                {"start": s.start, "end": s.end, "text": s.text} for s in result.segments
            ],
        }
        p.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        written.append(p)

    console.print("\n[green]✓ Transcripts written:[/green]")
    for p in written:
        console.print(f"  {p}")

    # Optional summary
    summary_result = None
    if summary:
        with console.status("Summarizing..."):
            summary_result = summarize_text(
                result.text, config, style=summary_style, language=result.language
            )
        summary_path = base.parent / f"{base.stem}.summary.md"
        summary_path.write_text(summary_result.text, encoding="utf-8")
        console.print(f"  {summary_path}  [dim](summary: {summary_style})[/dim]")

    # Optional Obsidian
    if obsidian:
        try:
            note_path = write_obsidian_note(result, summary_result, config, title=file.stem)
            console.print(f"\n[green]✓ Obsidian note:[/green] {note_path}")
        except ValueError as e:
            console.print(f"[red]Obsidian write failed:[/red] {e}")

    console.print(f"\n[dim]Detected language: {result.language or 'unknown'}[/dim]")


# =================================================================================
# summarize
# =================================================================================
@app.command()
def summarize(
    file: Annotated[Path, typer.Argument(help="Path to a .txt transcript file.")],
    style: Annotated[
        str | None,
        typer.Option(
            "--style",
            help="brief | detailed | action_items | path-to-template-file. "
            "Defaults to config's default_summary_style.",
        ),
    ] = None,
    output: Annotated[Path | None, typer.Option("--output", "-o")] = None,
) -> None:
    """Run a summary on an existing transcript .txt file."""
    config = load_config()
    style = _resolve_summary_style(style, config)
    file = file.expanduser().resolve()
    if not file.exists():
        console.print(f"[red]File not found: {file}[/red]")
        raise typer.Exit(1)

    text = file.read_text(encoding="utf-8")
    with console.status("Summarizing..."):
        result = summarize_text(text, config, style=style)

    out = output or file.with_suffix(".summary.md")
    out.write_text(result.text, encoding="utf-8")
    console.print(f"[green]✓ Summary written:[/green] {out}")


# =================================================================================
# init
# =================================================================================
@app.command()
def init() -> None:
    """Interactive setup wizard. Writes ~/.config/transcribe-audio/config.yaml."""
    console.print("\n[bold]transcribe-audio setup[/bold]\n")

    api_key_present = bool(load_config_silent_has_key())
    if api_key_present:
        console.print("[green]✓[/green] OPENAI_API_KEY detected in environment / .env")
    else:
        console.print(
            "[yellow]⚠[/yellow]  OPENAI_API_KEY not detected. "
            "Add it to your .env file (see .env.example)."
        )

    language = Prompt.ask(
        "Default language", default="auto", choices=["auto", "uk", "en", "ru"]
    )
    transcribe_model = Prompt.ask(
        "Transcription model",
        default="whisper-1",
        choices=["whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"],
    )
    summary_model = Prompt.ask("Summary model (OpenAI)", default="gpt-4o-mini")
    summary_style = Prompt.ask(
        "Default summary style",
        default="brief",
        choices=["brief", "detailed", "action_items"],
    )

    obsidian = Confirm.ask("Enable Obsidian export?", default=False)
    vault_path = None
    inbox_subdir = "inbox"
    if obsidian:
        vault_path_str = Prompt.ask("Obsidian vault path", default="")
        if vault_path_str:
            vault_path = str(Path(vault_path_str).expanduser().resolve())
            inbox_subdir = Prompt.ask("Inbox subdirectory within vault", default="inbox")

    output_dir = Prompt.ask(
        "Default output directory (for .txt/.srt files)",
        default=str(Path.home() / "transcripts"),
    )

    config_data = {
        "transcribe_model": transcribe_model,
        "summary_model": summary_model,
        "default_language": language,
        "default_summary_style": summary_style,
        "vault_path": vault_path,
        "obsidian_inbox_subdir": inbox_subdir,
        "default_output_dir": output_dir,
    }
    if not vault_path:
        del config_data["vault_path"]

    path = write_config(config_data)
    console.print(f"\n[green]✓ Config written:[/green] {path}")
    console.print("Run [bold]transcribe-audio transcribe <file>[/bold] to get going.")


# =================================================================================
# config
# =================================================================================
config_app = typer.Typer(help="Show or modify config.")
app.add_typer(config_app, name="config")


@config_app.command("show")
def config_show() -> None:
    """Print current config."""
    config_file = get_config_file()
    if not config_file.exists():
        console.print(
            f"[yellow]No config file yet at {config_file}. "
            f"Run [bold]transcribe-audio init[/bold].[/yellow]"
        )
        raise typer.Exit()
    console.print(f"[dim]{config_file}[/dim]\n")
    console.print(config_file.read_text())


@config_app.command("path")
def config_path() -> None:
    """Print the path to the config file."""
    console.print(str(get_config_file()))


# =================================================================================
# helpers
# =================================================================================
def load_config_silent_has_key() -> bool:
    """Check whether an API key is loadable without raising."""
    try:
        load_config()
        return True
    except Exception:
        return False


if __name__ == "__main__":
    app()
