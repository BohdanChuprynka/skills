"""Layered config: env (.env) → ~/.config/transcribe-audio/config.yaml → CLI flags."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Literal

import yaml
from dotenv import load_dotenv
from pydantic import BaseModel, Field

CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "transcribe-audio"
CONFIG_FILE = CONFIG_DIR / "config.yaml"


class Config(BaseModel):
    """Runtime config. Loaded from env + yaml. CLI flags override."""

    # === Secrets (env only) ===
    openai_api_key: str = Field(..., description="OpenAI API key. Required.")

    # === Preferences (yaml) ===
    transcribe_model: Literal["whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"] = (
        "whisper-1"
    )
    summary_model: str = "gpt-4o-mini"
    default_language: str = "auto"  # 'auto' = let Whisper detect; or ISO 639-1 code (uk, en, ru)
    default_summary_style: Literal["brief", "detailed", "action_items"] = "brief"

    # Obsidian
    vault_path: Path | None = None  # if None, --obsidian flag errors
    obsidian_inbox_subdir: str = "inbox"
    obsidian_filename_pattern: str = "{date}-{slug}"

    # Output
    default_output_dir: Path = Field(default_factory=lambda: Path.cwd() / "transcripts")

    # Behavior
    chunk_size_mb: int = 24  # OpenAI limit is 25 MB; leave headroom
    max_concurrent_chunks: int = 3
    confirm_above_minutes: int = 30  # ask before running if audio > N min


def load_config(env_file: Path | None = None) -> Config:
    """Load config from layered sources. .env first, then yaml, then env vars win.

    .env search order (first match wins):
      1. Explicit `env_file` argument
      2. ~/.config/transcribe-audio/.env       (canonical for installed CLI)
      3. ./.env in current working directory   (handy when developing in-repo)
      4. <repo>/.env relative to the source    (works only for `uv pip install -e .`)
    """
    if env_file and env_file.exists():
        load_dotenv(env_file)
    else:
        candidates = [
            CONFIG_DIR / ".env",
            Path.cwd() / ".env",
            Path(__file__).parents[2] / ".env",
        ]
        for candidate in candidates:
            if candidate.exists():
                load_dotenv(candidate)
                break

    data: dict = {}
    if CONFIG_FILE.exists():
        data = yaml.safe_load(CONFIG_FILE.read_text()) or {}

    # Env overrides
    if api_key := os.environ.get("OPENAI_API_KEY"):
        data["openai_api_key"] = api_key
    if vault := os.environ.get("OBSIDIAN_VAULT_PATH"):
        data["vault_path"] = vault

    if "openai_api_key" not in data:
        raise RuntimeError(
            "OPENAI_API_KEY not set. Add it to .env or `export OPENAI_API_KEY=sk-...`"
        )

    return Config(**data)


def write_config(config_data: dict) -> Path:
    """Write yaml config. Used by `transcribe-audio init`."""
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    # Strip secrets — never write API key to yaml
    safe = {k: v for k, v in config_data.items() if k != "openai_api_key"}
    # Path objects → strings for yaml
    for k, v in safe.items():
        if isinstance(v, Path):
            safe[k] = str(v)
    CONFIG_FILE.write_text(yaml.safe_dump(safe, sort_keys=False, default_flow_style=False))
    return CONFIG_FILE
