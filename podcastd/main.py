from __future__ import annotations

import asyncio
import json
import logging
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

# Track background work tasks (chunk delivery, interrupt) per session
# so we can cancel them on disconnect
work_tasks: dict[str, list[asyncio.Task]] = {}

# Guard against duplicate NEXT_CHUNK — only one delivery in-flight per session
chunk_delivery_active: set[str] = set()


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

                elif msg_type == "NEXT_CHUNK":
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
                    s = sessions.get(sid)
                    if s and question:
                        # Cancel ALL in-flight work (prefetch + on-demand chunk delivery)
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
        if session and session.session_id in sessions:
            _cleanup_session(session.session_id)


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
        title, script, _ = await generate_script(
            text, target_length=target_length,
            host_a_name=host_a_name, host_b_name=host_b_name,
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

        # Start prefetching chunk 1 in background
        if len(session.chunks) > 1:
            _start_prefetch(session, 1)

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
        async with gpu_lock:
            if session.session_id not in sessions:
                return  # session gone while waiting for lock
            audio_file, response_lines = await handle_interrupt(session, question, on_progress=progress_cb)

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

        # Start prefetching next chunk after interrupt
        next_idx = session.current_chunk_index + 1
        if next_idx < len(session.chunks) and next_idx not in session.chunk_audio_files:
            _start_prefetch(session, next_idx)

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
    _cancel_prefetches(session_id)
    _cancel_work_tasks(session_id)
    # Cancel queued prompts AND interrupt the currently running GPU job
    asyncio.create_task(cancel_session_prompts(session_id))
    asyncio.create_task(interrupt_comfyui())
    if session:
        log.info("Cleaned up session %s", session_id)


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

    # Start WebSocket server
    async with websockets.serve(ws_handler, cfg.WS_HOST, cfg.WS_PORT):
        log.info("podcastd ready")
        await asyncio.Future()  # run forever


if __name__ == "__main__":
    asyncio.run(main())
