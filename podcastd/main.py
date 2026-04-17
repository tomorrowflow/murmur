from __future__ import annotations

import asyncio
import json
import logging
import time
from pathlib import Path

import websockets

from aiohttp import web

from audio_generator import cancel_session_prompts, generate_audio, interrupt_comfyui, resolve_preset
from chunk_manager import split_into_chunks
from config import cfg
from ingest import ingest_email, ingest_pdf, ingest_url
from interrupt_handler import handle_interrupt
from script_generator import _resolve_target_minutes, generate_script
from session import PodcastSession, SessionState

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(name)s %(levelname)s %(message)s",
)
log = logging.getLogger("podcastd")

# Active sessions keyed by session_id
sessions: dict[str, PodcastSession] = {}

# Serialise all ComfyUI GPU work — one generation at a time
gpu_lock = asyncio.Lock()

# Track in-flight prefetch tasks per session so we can await them
prefetch_tasks: dict[str, asyncio.Task] = {}

# Track background work tasks (chunk delivery, interrupt, stream) per session
# so we can cancel them on disconnect
work_tasks: dict[str, list[asyncio.Task]] = {}

# Guard against duplicate NEXT_CHUNK — only one delivery in-flight per session
chunk_delivery_active: set[str] = set()

# Guard against duplicate eager streaming work per session
stream_active: set[str] = set()

# How long we keep a disconnected session alive so the client can RESUME_SESSION.
# Generation work is cancelled on disconnect; the grace period only preserves
# already-generated chunk audio + transcript for resume.
RECONNECT_GRACE_SECS = 300
SESSION_SWEEP_INTERVAL = 60


# ---------- Progress Reporting ----------


def _make_progress_cb(websocket, session_id: str, chunk_label: str):
    """Return a callback that sends PROGRESS messages during audio generation."""
    def on_progress(elapsed: float, estimated_total: float):
        pct = min(int(elapsed / estimated_total * 100), 99) if estimated_total > 0 else -1
        remaining = max(0, estimated_total - elapsed)
        msg = f"Generating audio ({chunk_label}) — {elapsed:.0f}s / ~{estimated_total:.0f}s (~{remaining:.0f}s remaining)"
        log.info("Progress: %s (pct=%d)", msg, pct)
        asyncio.create_task(_safe_send(websocket, {
            "type": "PROGRESS",
            "session_id": session_id,
            "stage": "audio_generating",
            "percent": pct,
            "message": msg,
        }))
    return on_progress


def _estimate_script_chars(target_minutes: int) -> int:
    """Heuristic for the expected size of a generated script including JSON wrapper.

    Roughly: spoken dialogue at ~150 wpm * ~6 chars/word = 900 chars/min; JSON
    overhead (keys, quotes, commas) adds ~75%. Capped by the model's
    num_predict budget of 8192 tokens (~32k chars). Used only to drive the
    progress-bar percent — slight misses are fine."""
    rough = max(2000, int(target_minutes * 1600))
    return min(rough, 32000)


def _make_distill_progress_cb(websocket, session_id: str, source_chars: int):
    """Callback that reports source-distillation progress.

    The distillation step's progress callback encodes part info in the `phase`
    string (e.g. "distill:2/3:thinking"), so we decode it here into a PROGRESS
    message the overlay can render alongside its spinner."""
    # Rough estimate: each distilled part outputs ~30% of the input chunk size.
    # This is only used to drive the progress bar percent.
    estimated_out = max(2000, int(source_chars * 0.30))

    def on_progress(char_count: int, phase: str):
        parts_info = ""
        is_thinking = False
        if phase.startswith("distill:"):
            body = phase[len("distill:"):]
            if ":" in body:
                body, suffix = body.split(":", 1)
                is_thinking = suffix == "thinking"
            parts_info = f" ({body})"
        pct = min(int(char_count / max(1, estimated_out) * 100), 95)
        phase_hint = " (thinking)" if is_thinking else ""
        msg = f"Distilling source{parts_info}{phase_hint} — {char_count:,} chars"
        try:
            asyncio.create_task(_safe_send(websocket, {
                "type": "PROGRESS",
                "session_id": session_id,
                "stage": "distilling",
                "percent": pct,
                "message": msg,
            }))
        except RuntimeError:
            pass
    return on_progress


def _make_llm_progress_cb(
    websocket,
    session_id: str,
    stage: str,
    label: str,
    estimated_chars: int,
):
    """Return a callback the LLM client invokes while streaming tokens.

    We translate (char_count, phase) into a PROGRESS frame so the overlay can
    show a filling bar + live char count instead of a spinner that seems stuck."""
    def on_progress(char_count: int, phase: str):
        denom = max(1, estimated_chars)
        pct = min(int(char_count / denom * 100), 95)
        phase_hint = " (thinking)" if phase == "thinking" else ""
        msg = f"Generating script ({label}){phase_hint} — {char_count:,} chars"
        try:
            asyncio.create_task(_safe_send(websocket, {
                "type": "PROGRESS",
                "session_id": session_id,
                "stage": stage,
                "percent": pct,
                "message": msg,
            }))
        except RuntimeError:
            # No running event loop (shouldn't happen — callback fires from
            # inside a coroutine). Drop the update silently.
            pass
    return on_progress


# ---------- Safe Send ----------


async def _safe_send(websocket, data: dict) -> bool:
    """Send JSON to websocket, return False if connection is dead."""
    try:
        await websocket.send(json.dumps(data))
        return True
    except websockets.ConnectionClosed:
        return False


# ---------- WebSocket Server ----------


async def ws_handler(websocket: websockets.WebSocketServerProtocol) -> None:
    log.info("Client connected: %s", websocket.remote_address)
    session: PodcastSession | None = None

    try:
        async for raw in websocket:
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                await _safe_send(websocket, {"type": "ERROR", "code": "PARSE_ERROR", "message": "Invalid JSON"})
                continue

            msg_type = msg.get("type")
            log.info("Received: %s", msg_type)

            try:
                if msg_type == "PING":
                    await _safe_send(websocket, {"type": "PONG"})

                elif msg_type == "INGEST":
                    session = await _handle_ingest(websocket, msg)

                elif msg_type == "STREAM_CHUNKS":
                    sid = msg.get("session_id")
                    from_index = int(msg.get("from_index", 0))
                    s = sessions.get(sid)
                    if s:
                        # Cancel any in-flight single-chunk delivery — stream takes over
                        _cancel_work_tasks(sid)
                        _spawn_work(sid, _stream_chunks(websocket, s, from_index))
                    else:
                        await _safe_send(websocket, {"type": "ERROR", "code": "NO_SESSION", "message": "Session not found"})

                elif msg_type == "RESUME_SESSION":
                    sid = msg.get("session_id")
                    last_received = int(msg.get("last_received_chunk_index", -1))
                    s = sessions.get(sid)
                    if s:
                        s.disconnected_at = None
                        session = s  # so the finally handler marks it disconnected on exit
                        total = len(s.chunks)
                        log.info("Resuming session %s (last_received=%d, total=%d)", sid, last_received, total)
                        await _safe_send(websocket, {
                            "type": "SESSION_RESUMED",
                            "session_id": sid,
                            "title": s.title,
                            "total_chunks": total,
                            "current_chunk_index": s.current_chunk_index,
                            "last_streamed_chunk_index": s.last_streamed_chunk_index,
                        })
                        # Re-stream from the chunk after the last one the client confirmed.
                        _cancel_work_tasks(sid)
                        _spawn_work(sid, _stream_chunks(websocket, s, last_received + 1))
                    else:
                        await _safe_send(websocket, {"type": "ERROR", "code": "NO_SESSION", "message": "Session not found or expired"})

                elif msg_type == "CHUNK_PLAYED":
                    sid = msg.get("session_id")
                    idx = int(msg.get("chunk_index", -1))
                    s = sessions.get(sid)
                    if s and 0 <= idx < len(s.chunks):
                        s.mark_chunk_delivered(idx)

                elif msg_type == "NEXT_CHUNK":
                    # Legacy one-at-a-time delivery — kept for backward compatibility.
                    sid = msg.get("session_id")
                    s = sessions.get(sid)
                    if s:
                        if sid in chunk_delivery_active:
                            log.info("Ignoring duplicate NEXT_CHUNK for session %s", sid)
                        else:
                            _spawn_work(sid, _deliver_next_chunk(websocket, s))
                    else:
                        await _safe_send(websocket, {"type": "ERROR", "code": "NO_SESSION", "message": "Session not found"})

                elif msg_type == "INTERRUPT":
                    sid = msg.get("session_id")
                    question = msg.get("question", "")
                    at_chunk_index = msg.get("at_chunk_index")
                    s = sessions.get(sid)
                    if s and question:
                        if isinstance(at_chunk_index, int) and 0 <= at_chunk_index < len(s.chunks):
                            # Client tells us the actual playback position. Clamp so we
                            # never move backwards (a late CHUNK_PLAYED could still win).
                            if at_chunk_index > s.current_chunk_index:
                                s.mark_chunk_delivered(at_chunk_index)
                        # Cancel ALL in-flight work (prefetch + delivery + stream)
                        # before starting interrupt, so nothing holds the gpu_lock
                        _cancel_prefetches(sid)
                        _cancel_work_tasks(sid)
                        # Non-blocking: spawn background task for interrupt
                        _spawn_work(sid, _handle_interrupt(websocket, s, question))
                    else:
                        await _safe_send(websocket, {"type": "ERROR", "code": "BAD_REQUEST", "message": "Missing session or question"})

                elif msg_type == "STOP":
                    sid = msg.get("session_id")
                    if sid in sessions:
                        _cleanup_session(sid)
                        session = None
                        log.info("Session stopped: %s", sid)

                else:
                    await _safe_send(websocket, {"type": "ERROR", "code": "UNKNOWN_TYPE", "message": f"Unknown message type: {msg_type}"})

            except Exception as e:
                log.exception("Error handling %s", msg_type)
                await _safe_send(websocket, {"type": "ERROR", "code": "HANDLER_ERROR", "message": str(e)})

    except websockets.ConnectionClosed:
        log.info("Client disconnected")
    finally:
        # Don't immediately cleanup — keep the session alive for RECONNECT_GRACE_SECS
        # so the client can RESUME_SESSION after a transient network failure.
        # In-flight GPU work is cancelled so the lock doesn't stall future requests;
        # already-generated chunk audio is preserved.
        if session and session.session_id in sessions:
            sid = session.session_id
            _cancel_prefetches(sid)
            _cancel_work_tasks(sid)
            chunk_delivery_active.discard(sid)
            stream_active.discard(sid)
            session.mark_disconnected()
            log.info("Session %s disconnected — grace period %ds", sid, RECONNECT_GRACE_SECS)


async def _handle_ingest(websocket, msg: dict) -> PodcastSession:
    session = PodcastSession()
    sessions[session.session_id] = session
    session.state = SessionState.INGESTING

    content_type = msg.get("content_type", "")
    content = msg.get("content", "")
    subject = msg.get("subject", "")
    session.web_search_enabled = msg.get("web_search", False)
    session.model_preset = msg.get("model", "large-q4")
    target_length = msg.get("target_length", "auto")
    host_a_name = msg.get("host_a_name") or cfg.HOST_A_NAME
    host_b_name = msg.get("host_b_name") or cfg.HOST_B_NAME
    session.host_a_name = host_a_name
    session.host_b_name = host_b_name
    log.info("INGEST hosts: raw=%r/%r → resolved=%s/%s",
             msg.get("host_a_name"), msg.get("host_b_name"),
             host_a_name, host_b_name)

    chunk_model, chunk_quantize = resolve_preset(session.model_preset)

    try:
        # Ingest content
        if content_type == "url":
            text = await ingest_url(content)
        elif content_type == "pdf":
            text = ingest_pdf(content)
        elif content_type == "email":
            text = ingest_email(content, subject)
        elif content_type == "text":
            text = content
        else:
            raise ValueError(f"Unknown content_type: {content_type}")

        session.source_content = text
        session.state = SessionState.SCRIPTING

        # Generate script
        target_minutes = _resolve_target_minutes(target_length, text)
        await _safe_send(websocket, {
            "type": "PROGRESS", "session_id": session.session_id,
            "stage": "scripting", "percent": -1,
            "message": f"Generating script for ~{target_minutes} min podcast...",
        })
        script_progress = _make_llm_progress_cb(
            websocket, session.session_id,
            stage="scripting",
            label=f"~{target_minutes} min podcast",
            estimated_chars=_estimate_script_chars(target_minutes),
        )
        distill_progress = _make_distill_progress_cb(
            websocket, session.session_id,
            source_chars=len(text),
        )
        title, script, _ = await generate_script(
            text, target_length=target_length,
            host_a_name=host_a_name, host_b_name=host_b_name,
            on_progress=script_progress,
            on_distill_progress=distill_progress,
        )
        session.title = title
        session.original_script = script
        session.chunks = split_into_chunks(script)
        session.state = SessionState.GENERATING

        # Generate first chunk audio (serialised via GPU lock)
        await _safe_send(websocket, {
            "type": "PROGRESS", "session_id": session.session_id,
            "stage": "audio_generating", "percent": -1,
            "message": f"Generating audio (chunk 1/{len(session.chunks)})...",
        })
        progress_cb = _make_progress_cb(websocket, session.session_id, f"chunk 1/{len(session.chunks)}")
        async with gpu_lock:
            audio_file = await generate_audio(
                session.chunks[0], model=chunk_model,
                quantize_llm=chunk_quantize, session_id=session.session_id,
                on_progress=progress_cb, host_a_name=host_a_name,
            )
        session.chunk_audio_files[0] = audio_file
        session.state = SessionState.READY

        await _safe_send(websocket, {
            "type": "SESSION_CREATED",
            "session_id": session.session_id,
            "title": title,
            "total_chunks": len(session.chunks),
        })

        # Send first chunk immediately
        await _safe_send(websocket, {
            "type": "CHUNK_READY",
            "session_id": session.session_id,
            "chunk_index": 0,
            "audio_url": audio_file,
            "transcript": session.chunks[0],
        })
        session.last_streamed_chunk_index = 0

        # Eagerly generate and push remaining chunks so the client can cache
        # the full podcast without needing to ask chunk-by-chunk.
        if len(session.chunks) > 1:
            _spawn_work(session.session_id, _stream_chunks(websocket, session, 1))

        return session

    except Exception as e:
        log.exception("Ingest failed")
        session.state = SessionState.ERROR
        await _safe_send(websocket, {"type": "ERROR", "code": "INGEST_FAILED", "message": str(e)})
        return session


async def _deliver_next_chunk(websocket, session: PodcastSession) -> None:
    """Deliver next chunk — runs as a background task so message loop stays free."""
    sid = session.session_id
    chunk_delivery_active.add(sid)
    try:
        await _deliver_next_chunk_inner(websocket, session)
    finally:
        chunk_delivery_active.discard(sid)


async def _stream_chunks(websocket, session: PodcastSession, from_index: int) -> None:
    """Eagerly generate and push every chunk from from_index until the end.

    One chunk at a time under gpu_lock. Skips chunks already generated
    (chunk_audio_files cache). Stops cleanly on websocket closure so the
    session can be resumed; on cancellation propagates CancelledError."""
    sid = session.session_id
    if sid in stream_active:
        log.info("Stream already active for session %s — skipping duplicate", sid)
        return
    stream_active.add(sid)
    idx = max(from_index, 0)
    try:
        total = len(session.chunks)
        while idx < total:
            if sid not in sessions:
                return

            if idx in session.chunk_audio_files:
                audio_file = session.chunk_audio_files[idx]
            else:
                chunk_model, chunk_quantize = resolve_preset(session.model_preset)
                await _safe_send(websocket, {
                    "type": "PROGRESS", "session_id": sid,
                    "stage": "audio_generating", "percent": -1,
                    "message": f"Generating audio (chunk {idx + 1}/{total})...",
                })
                progress_cb = _make_progress_cb(websocket, sid, f"chunk {idx + 1}/{total}")
                async with gpu_lock:
                    if sid not in sessions:
                        return
                    audio_file = await generate_audio(
                        session.chunks[idx], model=chunk_model,
                        quantize_llm=chunk_quantize, session_id=sid,
                        on_progress=progress_cb,
                        host_a_name=getattr(session, "host_a_name", None),
                    )
                session.chunk_audio_files[idx] = audio_file

            if sid not in sessions:
                return

            sent = await _safe_send(websocket, {
                "type": "CHUNK_READY",
                "session_id": sid,
                "chunk_index": idx,
                "audio_url": audio_file,
                "transcript": session.chunks[idx],
            })
            if not sent:
                # WebSocket closed — stop eager streaming. The connection-close
                # handler marks the session disconnected; remaining chunks can
                # be resumed via RESUME_SESSION.
                log.info("Stream halted — websocket closed at chunk %d", idx)
                return

            if idx > session.last_streamed_chunk_index:
                session.last_streamed_chunk_index = idx
            idx += 1

        # All chunks streamed — send end-of-stream sentinel
        if sid in sessions:
            session.state = SessionState.COMPLETE
            await _safe_send(websocket, {
                "type": "CHUNK_READY",
                "session_id": sid,
                "chunk_index": total,
                "audio_url": "",
                "transcript": [],
            })
            log.info("Stream complete for session %s (%d chunks)", sid, total)
    except asyncio.CancelledError:
        log.info("Stream cancelled for session %s at chunk %d", sid, idx)
        raise
    finally:
        stream_active.discard(sid)


async def _deliver_next_chunk_inner(websocket, session: PodcastSession) -> None:
    sid = session.session_id
    next_idx = session.current_chunk_index + 1

    if next_idx >= len(session.chunks):
        session.state = SessionState.COMPLETE
        await _safe_send(websocket, {
            "type": "CHUNK_READY",
            "session_id": sid,
            "chunk_index": next_idx,
            "audio_url": "",
            "transcript": [],
        })
        return

    session.mark_chunk_delivered(session.current_chunk_index)
    session.state = SessionState.PLAYING

    # Wait for in-flight prefetch if one exists for this chunk
    prefetch_key = f"{sid}:{next_idx}"
    if prefetch_key in prefetch_tasks:
        task = prefetch_tasks.pop(prefetch_key)
        if not task.done():
            log.info("Waiting for prefetch of chunk %d...", next_idx)
            await task

    # Bail out if session was cleaned up while we were waiting
    if sid not in sessions:
        return

    # Check if audio is ready (from prefetch or previous generation)
    if next_idx in session.chunk_audio_files:
        audio_file = session.chunk_audio_files[next_idx]
    else:
        # Generate on demand (prefetch missed or failed)
        log.info("On-demand generation for chunk %d", next_idx)
        chunk_model, chunk_quantize = resolve_preset(session.model_preset)
        await _safe_send(websocket, {
            "type": "PROGRESS", "session_id": sid,
            "stage": "audio_generating", "percent": -1,
            "message": f"Generating audio (chunk {next_idx + 1}/{len(session.chunks)})...",
        })
        progress_cb = _make_progress_cb(websocket, sid, f"chunk {next_idx + 1}/{len(session.chunks)}")
        async with gpu_lock:
            if sid not in sessions:
                return  # session gone while waiting for lock
            audio_file = await generate_audio(
                session.chunks[next_idx], model=chunk_model,
                quantize_llm=chunk_quantize, session_id=sid,
                on_progress=progress_cb,
                host_a_name=getattr(session, "host_a_name", None),
            )
        session.chunk_audio_files[next_idx] = audio_file

    if sid not in sessions:
        return

    session.current_chunk_index = next_idx

    await _safe_send(websocket, {
        "type": "CHUNK_READY",
        "session_id": sid,
        "chunk_index": next_idx,
        "audio_url": audio_file,
        "transcript": session.chunks[next_idx],
    })

    # Prefetch the chunk after next
    prefetch_idx = next_idx + 1
    if prefetch_idx < len(session.chunks) and prefetch_idx not in session.chunk_audio_files:
        _start_prefetch(session, prefetch_idx)


async def _handle_interrupt(websocket, session: PodcastSession, question: str) -> None:
    """Handle interrupt — runs as a background task so message loop stays free."""
    # Delete all queued ComfyUI prompts and kill the running one.
    # cancel_session_prompts does both /queue delete + /interrupt.
    await cancel_session_prompts(session.session_id)

    if not await _safe_send(websocket, {
        "type": "INTERRUPT_PROCESSING",
        "session_id": session.session_id,
        "state": "processing",
    }):
        return  # connection dead, no point continuing

    try:
        # Reset progress and show initial message while LLM generates response
        await _safe_send(websocket, {
            "type": "PROGRESS", "session_id": session.session_id,
            "stage": "interrupt_scripting", "percent": -1,
            "message": "Generating response to your question...",
        })
        progress_cb = _make_progress_cb(websocket, session.session_id, "response")
        llm_progress = _make_llm_progress_cb(
            websocket, session.session_id,
            stage="interrupt_scripting",
            label="response",
            estimated_chars=2500,
        )
        async with gpu_lock:
            if session.session_id not in sessions:
                return  # session gone while waiting for lock
            audio_file, response_lines = await handle_interrupt(
                session, question,
                on_progress=progress_cb,
                on_llm_progress=llm_progress,
            )

        if session.session_id not in sessions:
            return

        if not await _safe_send(websocket, {
            "type": "INTERRUPT_READY",
            "session_id": session.session_id,
            "audio_url": audio_file,
            "transcript": response_lines,
        }):
            return

        # Notify about revised script
        remaining = len(session.chunks) - session.current_chunk_index - 1
        await _safe_send(websocket, {
            "type": "SCRIPT_UPDATED",
            "session_id": session.session_id,
            "remaining_chunks": remaining,
        })

        session.state = SessionState.PLAYING

        # Interrupt replaced all chunks past current_chunk_index; the client
        # must drop its cache of those indices too. Resume eager streaming
        # so the revised chunks are pushed down to the client without another
        # round-trip.
        next_idx = session.current_chunk_index + 1
        session.last_streamed_chunk_index = session.current_chunk_index
        if next_idx < len(session.chunks):
            _spawn_work(session.session_id, _stream_chunks(websocket, session, next_idx))

    except Exception as e:
        log.exception("Interrupt handling failed")
        await _safe_send(websocket, {"type": "ERROR", "code": "INTERRUPT_FAILED", "message": str(e)})
        session.state = SessionState.PLAYING


# ---------- Background Work Management ----------


def _spawn_work(session_id: str, coro) -> asyncio.Task:
    """Spawn a background task for session work (chunk delivery, interrupt)."""
    task = asyncio.create_task(coro)
    work_tasks.setdefault(session_id, []).append(task)
    task.add_done_callback(lambda t: _remove_work_task(session_id, t))
    return task


def _remove_work_task(session_id: str, task: asyncio.Task) -> None:
    tasks = work_tasks.get(session_id)
    if tasks:
        try:
            tasks.remove(task)
        except ValueError:
            pass
    if task.done() and not task.cancelled():
        exc = task.exception()
        if exc:
            log.error("Background task failed for session %s: %s", session_id, exc)


def _cancel_work_tasks(session_id: str) -> None:
    tasks = work_tasks.pop(session_id, [])
    for task in tasks:
        if not task.done():
            task.cancel()
            log.info("Cancelled work task for session %s", session_id)


# ---------- Prefetch Management ----------


def _start_prefetch(session: PodcastSession, chunk_idx: int) -> None:
    key = f"{session.session_id}:{chunk_idx}"
    if key in prefetch_tasks:
        return  # already in flight
    task = asyncio.create_task(_prefetch_chunk(session, chunk_idx))
    prefetch_tasks[key] = task
    task.add_done_callback(lambda _: prefetch_tasks.pop(key, None))


async def _prefetch_chunk(session: PodcastSession, chunk_idx: int) -> None:
    try:
        if chunk_idx >= len(session.chunks):
            return
        chunk_model, chunk_quantize = resolve_preset(session.model_preset)
        async with gpu_lock:
            if session.session_id not in sessions:
                return  # session gone while waiting for lock
            audio_file = await generate_audio(
                session.chunks[chunk_idx], model=chunk_model,
                quantize_llm=chunk_quantize, session_id=session.session_id,
                host_a_name=getattr(session, "host_a_name", None),
            )
        session.chunk_audio_files[chunk_idx] = audio_file
        log.info("Prefetched chunk %d: %s", chunk_idx, audio_file)
    except asyncio.CancelledError:
        log.info("Prefetch cancelled for chunk %d", chunk_idx)
    except Exception:
        log.exception("Prefetch failed for chunk %d", chunk_idx)


def _cancel_prefetches(session_id: str) -> None:
    to_cancel = [k for k in prefetch_tasks if k.startswith(f"{session_id}:")]
    for key in to_cancel:
        task = prefetch_tasks.pop(key, None)
        if task and not task.done():
            task.cancel()
            log.info("Cancelled prefetch: %s", key)


# ---------- Helpers ----------


def _cleanup_session(session_id: str) -> None:
    # Remove session first so in-flight tasks see it's gone and bail out
    session = sessions.pop(session_id, None)
    chunk_delivery_active.discard(session_id)
    stream_active.discard(session_id)
    _cancel_prefetches(session_id)
    _cancel_work_tasks(session_id)
    # Cancel queued prompts AND interrupt the currently running GPU job
    asyncio.create_task(cancel_session_prompts(session_id))
    asyncio.create_task(interrupt_comfyui())
    if session:
        log.info("Cleaned up session %s", session_id)


async def _session_sweeper() -> None:
    """Evict sessions that have been disconnected longer than RECONNECT_GRACE_SECS."""
    while True:
        try:
            await asyncio.sleep(SESSION_SWEEP_INTERVAL)
            now = time.monotonic()
            expired = [
                sid for sid, s in sessions.items()
                if s.disconnected_at is not None
                and now - s.disconnected_at > RECONNECT_GRACE_SECS
            ]
            for sid in expired:
                log.info("Evicting disconnected session %s after grace period", sid)
                _cleanup_session(sid)
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("Session sweeper iteration failed")


# ---------- HTTP Server ----------


async def handle_health(request: web.Request) -> web.Response:
    return web.json_response({
        "status": "ok",
        "sessions": len(sessions),
    })


async def handle_audio(request: web.Request) -> web.Response:
    filename = request.match_info["filename"]

    # Check MP3 cache first (writable dir for converted files)
    mp3_path = Path(cfg.MP3_CACHE_DIR) / filename
    if mp3_path.exists():
        return web.FileResponse(mp3_path)

    # Fall back to ComfyUI output dir (WAV originals)
    filepath = Path(cfg.AUDIO_CACHE_DIR) / filename
    if not filepath.exists():
        # Check subdirectories (ComfyUI may use audio/ prefix)
        alt = Path(cfg.AUDIO_CACHE_DIR) / "audio" / filename
        if alt.exists():
            filepath = alt
        else:
            return web.Response(status=404, text="Not found")

    return web.FileResponse(filepath)


async def handle_upload_voice_sample(request: web.Request) -> web.Response:
    """POST /voice-samples — upload a voice reference WAV for speaker 1 or 2."""
    reader = await request.multipart()
    speaker = None
    audio_data = None

    async for part in reader:
        if part.name == "speaker":
            speaker = (await part.read()).decode().strip()
        elif part.name == "audio":
            audio_data = await part.read(decode=False)

    if speaker not in ("1", "2"):
        return web.json_response({"error": "speaker must be '1' or '2'"}, status=400)
    if not audio_data:
        return web.json_response({"error": "no audio file provided"}, status=400)
    if len(audio_data) > 50 * 1024 * 1024:
        return web.json_response({"error": "file too large (max 50 MB)"}, status=400)

    filename = f"podcast_voice_speaker{speaker}.wav"
    dest = Path(cfg.COMFYUI_INPUT_DIR) / filename
    dest.write_bytes(audio_data)
    log.info("Saved voice sample: %s (%d bytes)", dest, len(audio_data))

    return web.json_response({"status": "ok", "speaker": speaker, "filename": filename})


async def handle_get_voice_samples(request: web.Request) -> web.Response:
    """GET /voice-samples — list uploaded voice sample status."""
    input_dir = Path(cfg.COMFYUI_INPUT_DIR)
    result = {}
    for s in ("1", "2"):
        filename = f"podcast_voice_speaker{s}.wav"
        exists = (input_dir / filename).exists()
        result[f"speaker{s}"] = {"filename": filename, "uploaded": exists}
    return web.json_response(result)


async def handle_delete_voice_sample(request: web.Request) -> web.Response:
    """DELETE /voice-samples/{speaker} — remove uploaded voice sample."""
    speaker = request.match_info["speaker"]
    if speaker not in ("1", "2"):
        return web.json_response({"error": "speaker must be '1' or '2'"}, status=400)

    filepath = Path(cfg.COMFYUI_INPUT_DIR) / f"podcast_voice_speaker{speaker}.wav"
    if filepath.exists():
        filepath.unlink()
        log.info("Deleted voice sample: %s", filepath)

    return web.json_response({"status": "ok"})


async def handle_play_voice_sample(request: web.Request) -> web.Response:
    """GET /voice-samples/{speaker}/audio — stream the uploaded voice sample."""
    speaker = request.match_info["speaker"]
    if speaker not in ("1", "2"):
        return web.Response(status=400, text="speaker must be '1' or '2'")

    filepath = Path(cfg.COMFYUI_INPUT_DIR) / f"podcast_voice_speaker{speaker}.wav"
    if not filepath.exists():
        return web.Response(status=404, text="No voice sample uploaded")

    return web.FileResponse(filepath)


def create_http_app() -> web.Application:
    app = web.Application(client_max_size=50 * 1024 * 1024)
    app.router.add_get("/health", handle_health)
    app.router.add_get("/audio/{filename}", handle_audio)
    app.router.add_post("/voice-samples", handle_upload_voice_sample)
    app.router.add_get("/voice-samples", handle_get_voice_samples)
    app.router.add_delete("/voice-samples/{speaker}", handle_delete_voice_sample)
    app.router.add_get("/voice-samples/{speaker}/audio", handle_play_voice_sample)
    return app


# ---------- Main ----------


async def main() -> None:
    log.info("Starting podcastd")
    log.info("  WS:   %s:%d", cfg.WS_HOST, cfg.WS_PORT)
    log.info("  HTTP: %s:%d", cfg.HTTP_HOST, cfg.HTTP_PORT)
    log.info("  LLM:  %s / %s", cfg.LLM_PROVIDER, cfg.LLM_MODEL)
    log.info("  ComfyUI: %s", cfg.COMFYUI_BASE_URL)

    # Start HTTP server
    http_app = create_http_app()
    runner = web.AppRunner(http_app)
    await runner.setup()
    site = web.TCPSite(runner, cfg.HTTP_HOST, cfg.HTTP_PORT)
    await site.start()

    sweeper_task = asyncio.create_task(_session_sweeper())

    # Start WebSocket server
    try:
        async with websockets.serve(ws_handler, cfg.WS_HOST, cfg.WS_PORT):
            log.info("podcastd ready")
            await asyncio.Future()  # run forever
    finally:
        sweeper_task.cancel()


if __name__ == "__main__":
    asyncio.run(main())
