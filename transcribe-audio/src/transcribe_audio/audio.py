"""Audio file handling: probe metadata, chunk large files for the 25 MB Whisper API limit."""

from __future__ import annotations

import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path


@dataclass
class AudioInfo:
    path: Path
    duration_seconds: float
    size_bytes: int
    codec: str
    sample_rate: int
    channels: int

    @property
    def size_mb(self) -> float:
        return self.size_bytes / 1024 / 1024

    @property
    def duration_minutes(self) -> float:
        return self.duration_seconds / 60


def _require_ffprobe() -> None:
    if not shutil.which("ffprobe"):
        raise RuntimeError(
            "ffprobe not found. Install ffmpeg:\n"
            "  macOS:   brew install ffmpeg\n"
            "  Ubuntu:  sudo apt install ffmpeg\n"
            "  Windows: choco install ffmpeg"
        )


def _require_ffmpeg() -> None:
    if not shutil.which("ffmpeg"):
        raise RuntimeError("ffmpeg not found. Install with `brew install ffmpeg` or equivalent.")


def probe_audio(path: Path) -> AudioInfo:
    """Read audio metadata via ffprobe."""
    _require_ffprobe()
    if not path.exists():
        raise FileNotFoundError(f"Audio file not found: {path}")

    result = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "a:0",
            "-show_entries",
            "stream=codec_name,sample_rate,channels:format=duration,size",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            str(path),
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    lines = [ln.strip() for ln in result.stdout.strip().splitlines() if ln.strip()]
    if len(lines) < 5:
        raise RuntimeError(f"ffprobe returned unexpected output for {path}:\n{result.stdout}")
    codec, sample_rate, channels, duration, size = lines[0], lines[1], lines[2], lines[3], lines[4]
    return AudioInfo(
        path=path,
        duration_seconds=float(duration),
        size_bytes=int(size),
        codec=codec,
        sample_rate=int(sample_rate),
        channels=int(channels),
    )


def chunk_audio(
    info: AudioInfo,
    chunk_size_mb: int,
    output_dir: Path,
) -> list[Path]:
    """Split a large audio file into chunks under `chunk_size_mb` MB.

    Uses ffmpeg time-based splitting. Each chunk is re-encoded to MP3 mono 16kHz
    (Whisper's preferred input) which also shrinks size predictably.

    Returns a list of chunk file paths in order.
    """
    _require_ffmpeg()
    if info.size_mb <= chunk_size_mb:
        return [info.path]

    output_dir.mkdir(parents=True, exist_ok=True)

    # MP3 mono 16kHz @ 64 kbps = 0.48 MB/min → 24 MB ≈ 50 min per chunk.
    # Compute chunk duration so each chunk is well under the limit.
    target_bitrate_kbps = 64
    bytes_per_sec = target_bitrate_kbps * 1000 / 8  # 8000 B/s
    max_chunk_seconds = int((chunk_size_mb * 1024 * 1024) / bytes_per_sec) - 30  # 30s safety margin
    if max_chunk_seconds < 60:
        max_chunk_seconds = 60  # never less than 1 min

    base = info.path.stem
    pattern = output_dir / f"{base}_chunk_%03d.mp3"

    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-i",
            str(info.path),
            "-f",
            "segment",
            "-segment_time",
            str(max_chunk_seconds),
            "-ac",
            "1",  # mono
            "-ar",
            "16000",  # 16 kHz
            "-b:a",
            f"{target_bitrate_kbps}k",
            "-vn",
            "-loglevel",
            "error",
            str(pattern),
        ],
        check=True,
    )

    chunks = sorted(output_dir.glob(f"{base}_chunk_*.mp3"))
    if not chunks:
        raise RuntimeError(f"ffmpeg produced no chunks from {info.path}")
    return chunks


def normalize_audio(input_path: Path, output_dir: Path) -> Path:
    """Re-encode any input to MP3 mono 16kHz. Useful for non-MP3 inputs even when under size limit."""
    _require_ffmpeg()
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / f"{input_path.stem}.mp3"
    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-i",
            str(input_path),
            "-ac",
            "1",
            "-ar",
            "16000",
            "-b:a",
            "64k",
            "-vn",
            "-loglevel",
            "error",
            str(output_path),
        ],
        check=True,
    )
    return output_path
