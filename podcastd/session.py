from __future__ import annotations

import time
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
    # Last chunk the client confirmed it has started playing; drives interrupt slicing.
    current_chunk_index: int = 0
    # Highest chunk the server has pushed via CHUNK_READY (includes eager streaming).
    last_streamed_chunk_index: int = -1

    # Options (set per session from INGEST message)
    web_search_enabled: bool = False
    model_preset: str = "large-q4"
    host_a_name: str = ""
    host_b_name: str = ""

    # History for interrupt context
    delivered_lines: list[dict] = field(default_factory=list)
    delivered_chunk_indices: set[int] = field(default_factory=set)
    interrupt_history: list[dict] = field(default_factory=list)

    # Reconnect grace period: set to disconnect timestamp; cleared on RESUME_SESSION.
    # When non-None the periodic sweep may evict the session after RECONNECT_GRACE_SECS.
    disconnected_at: float | None = None

    def remaining_chunks_flat(self) -> list[dict]:
        remaining = []
        for chunk in self.chunks[self.current_chunk_index + 1:]:
            remaining.extend(chunk)
        return remaining

    def mark_chunk_delivered(self, chunk_index: int) -> None:
        if chunk_index < 0 or chunk_index >= len(self.chunks):
            return
        if chunk_index not in self.delivered_chunk_indices:
            self.delivered_lines.extend(self.chunks[chunk_index])
            self.delivered_chunk_indices.add(chunk_index)
        if chunk_index > self.current_chunk_index:
            self.current_chunk_index = chunk_index

    def invalidate_after(self, index: int) -> None:
        """Drop delivered-line bookkeeping for chunks strictly greater than index.

        Called when a script rewrite (interrupt) replaces chunks past a given point.
        Avoids stale lines reappearing if a replacement chunk happens to land at
        the same index later."""
        self.delivered_chunk_indices = {i for i in self.delivered_chunk_indices if i <= index}

    def mark_disconnected(self) -> None:
        self.disconnected_at = time.monotonic()
