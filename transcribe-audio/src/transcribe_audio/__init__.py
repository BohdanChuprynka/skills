"""transcribe-audio: OpenAI Whisper API → transcript → optional summary → optional Obsidian."""

__version__ = "0.1.0"

from transcribe_audio.audio import AudioInfo, chunk_audio, probe_audio
from transcribe_audio.config import Config, load_config
from transcribe_audio.obsidian import write_obsidian_note
from transcribe_audio.summarize import summarize_text
from transcribe_audio.transcribe import TranscriptionResult, transcribe_file

__all__ = [
    "__version__",
    "AudioInfo",
    "Config",
    "TranscriptionResult",
    "chunk_audio",
    "load_config",
    "probe_audio",
    "summarize_text",
    "transcribe_file",
    "write_obsidian_note",
]
