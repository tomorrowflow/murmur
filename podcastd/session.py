from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from enum import Enum


class SessionState(str, Enum):
    IDLE = "idle"
    INGESTING = "ingesting"
    SCRIPTING = "scripting"
    GENERATING = "generating"
    READY = "ready"
    PLAYING = "playing"
    INTERRUPTED = "interrupted"
    INTERRUPT_READY = "interrupt_ready"
    EVOLVING = "evolving"
    COMPLETE = "complete"
    ERROR = "error"


@dataclass
class PodcastSession:
    session_id: str = field(default_factory=lambda: uuid.uuid4().hex[:12])
    state: SessionState = SessionState.IDLE
    title: str = ""
    source_content: str = ""

    # Script
    original_script: list[dict] = field(default_factory=list)
    chunks: list[list[dict]] = field(default_factory=list)
    chunk_audio_files: dict[int, str] = field(default_factory=dict)
    current_chunk_index: int = 0

    # Options (set per session from INGEST message)
    web_search_enabled: bool = False

    # History for interrupt context
    delivered_lines: list[dict] = field(default_factory=list)
    interrupt_history: list[dict] = field(default_factory=list)

    def remaining_chunks_flat(self) -> list[dict]:
        remaining = []
        for chunk in self.chunks[self.current_chunk_index + 1:]:
            remaining.extend(chunk)
        return remaining

    def mark_chunk_delivered(self, chunk_index: int) -> None:
        if chunk_index < len(self.chunks):
            self.delivered_lines.extend(self.chunks[chunk_index])
            self.current_chunk_index = chunk_index
