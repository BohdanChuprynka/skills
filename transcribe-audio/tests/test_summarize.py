"""Tests for the summarize layer (OpenAI Chat API mocked)."""

from __future__ import annotations

from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from transcribe_audio.config import Config
from transcribe_audio.summarize import summarize_text


def test_summarize_loads_brief_style(fake_openai_key: str) -> None:
    config = Config(openai_api_key=fake_openai_key)
    fake_choice = MagicMock()
    fake_choice.message.content = "**Topic:** quick summary."
    fake_response = MagicMock()
    fake_response.choices = [fake_choice]

    with patch("transcribe_audio.summarize.OpenAI") as mock_cls:
        client = MagicMock()
        mock_cls.return_value = client
        client.chat.completions.create.return_value = fake_response

        result = summarize_text("Some transcript.", config, style="brief")

        call_kwargs = client.chat.completions.create.call_args.kwargs
        # system prompt should contain the brief template's distinctive phrasing.
        system_msg = call_kwargs["messages"][0]["content"]
        assert "Topic:" in system_msg
        assert call_kwargs["model"] == "gpt-4o-mini"

    assert result.text == "**Topic:** quick summary."
    assert result.style == "brief"
    assert result.model == "gpt-4o-mini"


def test_summarize_unknown_style_raises(fake_openai_key: str) -> None:
    config = Config(openai_api_key=fake_openai_key)
    with pytest.raises(FileNotFoundError, match="not found"):
        summarize_text("text", config, style="nonexistent-style")


def test_summarize_custom_template_path(fake_openai_key: str, tmp_path: Path) -> None:
    template_file = tmp_path / "custom.txt"
    template_file.write_text("Custom system prompt here.")
    config = Config(openai_api_key=fake_openai_key)

    fake_response = MagicMock()
    fake_response.choices = [MagicMock(message=MagicMock(content="ok"))]

    with patch("transcribe_audio.summarize.OpenAI") as mock_cls:
        client = MagicMock()
        mock_cls.return_value = client
        client.chat.completions.create.return_value = fake_response

        result = summarize_text("text", config, style=str(template_file))

        call_kwargs = client.chat.completions.create.call_args.kwargs
        assert "Custom system prompt here" in call_kwargs["messages"][0]["content"]

    assert result.text == "ok"
