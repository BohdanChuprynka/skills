"""Whisper API transcription with auto-chunking for files >25 MB."""

from __future__ import annotations

import tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from pathlib import Path

from openai import OpenAI

from transcribe_audio.audio import AudioInfo, chunk_audio, probe_audio
from transcribe_audio.config import Config


@dataclass
class Segment:
    start: float
    end: float
    text: str


@dataclass
class TranscriptionResult:
    text: str
    segments: list[Segment] = field(default_factory=list)
    language: str | None = None
    duration: float = 0.0
    source_path: Path | None = None

    def to_srt(self) -> str:
        lines = []
        for i, seg in enumerate(self.segments, 1):
            lines.append(str(i))
            lines.append(f"{_fmt_srt(seg.start)} --> {_fmt_srt(seg.end)}")
            lines.append(seg.text.strip())
            lines.append("")
        return "\n".join(lines)

    def to_vtt(self) -> str:
        lines = ["WEBVTT", ""]
        for seg in self.segments:
            lines.append(f"{_fmt_vtt(seg.start)} --> {_fmt_vtt(seg.end)}")
            lines.append(seg.text.strip())
            lines.append("")
        return "\n".join(lines)


def _fmt_srt(seconds: float) -> str:
    total = int(seconds)
    ms = int((seconds - total) * 1000)
    h, rem = divmod(total, 3600)
    m, s = divmod(rem, 60)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def _fmt_vtt(seconds: float) -> str:
    return _fmt_srt(seconds).replace(",", ".")


def _build_transcribe_kwargs(
    model: str, language: str | None, initial_prompt: str | None
) -> dict:
    """Assemble the transcription request kwargs for the given model.

    Only whisper-1 supports `verbose_json` + `timestamp_granularities` (needed for
    segment-level SRT/VTT). The gpt-4o-transcribe / gpt-4o-mini-transcribe models
    accept only `json` | `text` and reject the verbose form with a 400, so they
    fall back to plain `json` (no per-segment timestamps).
    """
    api_kwargs: dict = {"model": model}
    if model.startswith("gpt-4o"):
        api_kwargs["response_format"] = "json"
    else:
        api_kwargs["response_format"] = "verbose_json"
        api_kwargs["timestamp_granularities"] = ["segment"]
    if language and language != "auto":
        api_kwargs["language"] = language
    if initial_prompt:
        api_kwargs["prompt"] = initial_prompt
    return api_kwargs


def _transcribe_single(
    client: OpenAI,
    file_path: Path,
    model: str,
    language: str | None,
    initial_prompt: str | None,
    time_offset: float = 0.0,
) -> TranscriptionResult:
    """Single Whisper API call. Returns segments with optional time offset."""
    api_kwargs = _build_transcribe_kwargs(model, language, initial_prompt)

    with open(file_path, "rb") as f:
        response = client.audio.transcriptions.create(file=f, **api_kwargs)

    segments = []
    if hasattr(response, "segments") and response.segments:
        for seg in response.segments:
            segments.append(
                Segment(
                    start=seg.start + time_offset,
                    end=seg.end + time_offset,
                    text=seg.text,
                )
            )

    return TranscriptionResult(
        text=response.text,
        segments=segments,
        language=getattr(response, "language", None),
        duration=getattr(response, "duration", 0.0),
        source_path=file_path,
    )


def transcribe_file(
    audio_path: Path,
    config: Config,
    language: str | None = None,
    initial_prompt: str | None = None,
    on_progress: callable = None,
) -> TranscriptionResult:
    """Transcribe an audio file. Auto-chunks if over the API size limit.

    Args:
        audio_path: path to audio file (any format ffmpeg can read)
        config: loaded Config
        language: override config default. 'auto' or ISO 639-1 (e.g. 'uk', 'en', 'ru')
        initial_prompt: tech vocab / proper-noun priming
        on_progress: optional callback(stage: str, current: int, total: int)
    """
    audio_path = Path(audio_path).expanduser().resolve()
    info: AudioInfo = probe_audio(audio_path)
    if on_progress:
        on_progress("probe", 1, 1)

    client = OpenAI(api_key=config.openai_api_key)
    lang = language if language is not None else config.default_language

    with tempfile.TemporaryDirectory(prefix="transcribe_chunks_") as tmpdir:
        chunks = chunk_audio(info, config.chunk_size_mb, Path(tmpdir))
        if on_progress:
            on_progress("chunk", len(chunks), len(chunks))

        if len(chunks) == 1:
            # No chunking — single call, no offset.
            result = _transcribe_single(
                client, chunks[0], config.transcribe_model, lang, initial_prompt
            )
            result.duration = info.duration_seconds
            result.source_path = audio_path
            if on_progress:
                on_progress("transcribe", 1, 1)
            return result

        # Multi-chunk: parallel transcribe, then merge with offsets.
        # Each chunk's offset = sum of preceding chunk durations.
        chunk_infos = [probe_audio(c) for c in chunks]
        offsets = []
        running = 0.0
        for ci in chunk_infos:
            offsets.append(running)
            running += ci.duration_seconds

        results: list[TranscriptionResult | None] = [None] * len(chunks)
        completed = 0
        with ThreadPoolExecutor(max_workers=config.max_concurrent_chunks) as pool:
            futures = {
                pool.submit(
                    _transcribe_single,
                    client,
                    chunk,
                    config.transcribe_model,
                    lang,
                    initial_prompt,
                    offset,
                ): idx
                for idx, (chunk, offset) in enumerate(zip(chunks, offsets, strict=True))
            }
            for fut in as_completed(futures):
                idx = futures[fut]
                results[idx] = fut.result()
                completed += 1
                if on_progress:
                    on_progress("transcribe", completed, len(chunks))

        # Merge in order.
        merged_text = " ".join(r.text.strip() for r in results if r)
        merged_segments: list[Segment] = []
        for r in results:
            if r:
                merged_segments.extend(r.segments)
        # Language: take from first chunk that detected one.
        detected_lang = next((r.language for r in results if r and r.language), None)

        return TranscriptionResult(
            text=merged_text,
            segments=merged_segments,
            language=detected_lang,
            duration=info.duration_seconds,
            source_path=audio_path,
        )


def estimate_cost_usd(duration_seconds: float, model: str = "whisper-1") -> float:
    """Estimate API cost. Whisper-1 = $0.006/minute. gpt-4o-* same baseline."""
    minutes = duration_seconds / 60
    rate_per_minute = {
        "whisper-1": 0.006,
        "gpt-4o-transcribe": 0.006,
        "gpt-4o-mini-transcribe": 0.003,
    }.get(model, 0.006)
    return minutes * rate_per_minute
