"""Tests for the transcribe orchestration layer (Whisper API mocked)."""

from __future__ import annotations

from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from transcribe_audio.config import Config
from transcribe_audio.transcribe import (
    Segment,
    TranscriptionResult,
    estimate_cost_usd,
    transcribe_file,
)


def test_estimate_cost_whisper_baseline() -> None:
    # 10 minutes at $0.006/min = $0.06
    assert estimate_cost_usd(600, "whisper-1") == pytest.approx(0.06, abs=1e-4)


def test_estimate_cost_mini_is_cheaper() -> None:
    assert estimate_cost_usd(600, "gpt-4o-mini-transcribe") < estimate_cost_usd(
        600, "whisper-1"
    )


def test_transcription_result_to_srt_format() -> None:
    result = TranscriptionResult(
        text="hello there",
        segments=[
            Segment(start=0.0, end=1.5, text="hello"),
            Segment(start=1.5, end=3.0, text="there"),
        ],
        language="en",
        duration=3.0,
    )
    srt = result.to_srt()
    assert "1\n00:00:00,000 --> 00:00:01,500\nhello" in srt
    assert "2\n00:00:01,500 --> 00:00:03,000\nthere" in srt


def test_transcription_result_to_vtt_format() -> None:
    result = TranscriptionResult(
        text="hi",
        segments=[Segment(start=0.0, end=1.0, text="hi")],
        language="en",
        duration=1.0,
    )
    vtt = result.to_vtt()
    assert vtt.startswith("WEBVTT\n\n")
    assert "00:00:00.000 --> 00:00:01.000" in vtt


def test_transcribe_file_calls_api_with_correct_args(
    short_test_mp3: Path, fake_openai_key: str
) -> None:
    """Single-chunk path. Assert API call shape + result reconstruction."""
    config = Config(openai_api_key=fake_openai_key)

    fake_response = MagicMock()
    fake_response.text = "test transcript text"
    fake_response.language = "en"
    fake_response.duration = 3.0
    fake_response.segments = [
        MagicMock(start=0.0, end=1.0, text="test"),
        MagicMock(start=1.0, end=3.0, text="transcript text"),
    ]

    with patch("transcribe_audio.transcribe.OpenAI") as mock_openai_cls:
        client = MagicMock()
        mock_openai_cls.return_value = client
        client.audio.transcriptions.create.return_value = fake_response

        result = transcribe_file(
            short_test_mp3,
            config,
            language="en",
            initial_prompt="test vocabulary",
        )

        client.audio.transcriptions.create.assert_called_once()
        call_kwargs = client.audio.transcriptions.create.call_args.kwargs
        assert call_kwargs["model"] == "whisper-1"
        assert call_kwargs["language"] == "en"
        assert call_kwargs["prompt"] == "test vocabulary"
        assert call_kwargs["response_format"] == "verbose_json"

    assert result.text == "test transcript text"
    assert result.language == "en"
    assert len(result.segments) == 2
    assert result.segments[1].text == "transcript text"
    assert result.source_path == short_test_mp3
