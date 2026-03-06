from __future__ import annotations

import asyncio
import json
import logging
from pathlib import Path

import websockets
from aiohttp import web

from audio_generator import generate_audio
from chunk_manager import split_into_chunks
from config import cfg
from ingest import ingest_email, ingest_pdf, ingest_url
from interrupt_handler import handle_interrupt
from script_generator import generate_script
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


# ---------- WebSocket Server ----------


async def ws_handler(websocket: websockets.WebSocketServerProtocol) -> None:
    log.info("Client connected: %s", websocket.remote_address)
    session: PodcastSession | None = None

    try:
        async for raw in websocket:
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                await _send_error(websocket, "PARSE_ERROR", "Invalid JSON")
                continue

            msg_type = msg.get("type")
            log.info("Received: %s", msg_type)

            try:
                if msg_type == "PING":
                    await websocket.send(json.dumps({"type": "PONG"}))

                elif msg_type == "INGEST":
                    session = await _handle_ingest(websocket, msg)

                elif msg_type == "NEXT_CHUNK":
                    sid = msg.get("session_id")
                    s = sessions.get(sid)
                    if s:
                        await _handle_next_chunk(websocket, s)
                    else:
                        await _send_error(websocket, "NO_SESSION", "Session not found")

                elif msg_type == "INTERRUPT":
                    sid = msg.get("session_id")
                    question = msg.get("question", "")
                    s = sessions.get(sid)
                    if s and question:
                        await _handle_interrupt(websocket, s, question)
                    else:
                        await _send_error(websocket, "BAD_REQUEST", "Missing session or question")

                elif msg_type == "STOP":
                    sid = msg.get("session_id")
                    if sid in sessions:
                        _cleanup_session(sid)
                        session = None
                        log.info("Session stopped: %s", sid)

                else:
                    await _send_error(websocket, "UNKNOWN_TYPE", f"Unknown message type: {msg_type}")

            except Exception as e:
                log.exception("Error handling %s", msg_type)
                await _send_error(websocket, "HANDLER_ERROR", str(e))

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
        title, script = await generate_script(text)
        session.title = title
        session.original_script = script
        session.chunks = split_into_chunks(script)
        session.state = SessionState.GENERATING

        # Generate first chunk audio (serialised via GPU lock)
        async with gpu_lock:
            audio_file = await generate_audio(session.chunks[0])
        session.chunk_audio_files[0] = audio_file
        session.state = SessionState.READY

        await websocket.send(json.dumps({
            "type": "SESSION_CREATED",
            "session_id": session.session_id,
            "title": title,
            "total_chunks": len(session.chunks),
        }))

        # Send first chunk immediately
        await websocket.send(json.dumps({
            "type": "CHUNK_READY",
            "session_id": session.session_id,
            "chunk_index": 0,
            "audio_url": audio_file,
            "transcript": session.chunks[0],
        }))

        # Start prefetching chunk 1 in background
        if len(session.chunks) > 1:
            _start_prefetch(session, 1)

        return session

    except Exception as e:
        log.exception("Ingest failed")
        session.state = SessionState.ERROR
        await _send_error(websocket, "INGEST_FAILED", str(e))
        return session


async def _handle_next_chunk(websocket, session: PodcastSession) -> None:
    next_idx = session.current_chunk_index + 1

    if next_idx >= len(session.chunks):
        session.state = SessionState.COMPLETE
        await websocket.send(json.dumps({
            "type": "CHUNK_READY",
            "session_id": session.session_id,
            "chunk_index": next_idx,
            "audio_url": "",
            "transcript": [],
        }))
        return

    session.mark_chunk_delivered(session.current_chunk_index)
    session.state = SessionState.PLAYING

    # Wait for in-flight prefetch if one exists for this chunk
    prefetch_key = f"{session.session_id}:{next_idx}"
    if prefetch_key in prefetch_tasks:
        task = prefetch_tasks.pop(prefetch_key)
        if not task.done():
            log.info("Waiting for prefetch of chunk %d...", next_idx)
            await task

    # Check if audio is ready (from prefetch or previous generation)
    if next_idx in session.chunk_audio_files:
        audio_file = session.chunk_audio_files[next_idx]
    else:
        # Generate on demand (prefetch missed or failed)
        log.info("On-demand generation for chunk %d", next_idx)
        async with gpu_lock:
            audio_file = await generate_audio(session.chunks[next_idx])
        session.chunk_audio_files[next_idx] = audio_file

    session.current_chunk_index = next_idx

    await websocket.send(json.dumps({
        "type": "CHUNK_READY",
        "session_id": session.session_id,
        "chunk_index": next_idx,
        "audio_url": audio_file,
        "transcript": session.chunks[next_idx],
    }))

    # Prefetch the chunk after next
    prefetch_idx = next_idx + 1
    if prefetch_idx < len(session.chunks) and prefetch_idx not in session.chunk_audio_files:
        _start_prefetch(session, prefetch_idx)


async def _handle_interrupt(websocket, session: PodcastSession, question: str) -> None:
    # Cancel any in-flight prefetch — GPU is needed for interrupt response
    _cancel_prefetches(session.session_id)

    await websocket.send(json.dumps({
        "type": "INTERRUPT_PROCESSING",
        "session_id": session.session_id,
        "state": "processing",
    }))

    try:
        async with gpu_lock:
            audio_file, response_lines = await handle_interrupt(session, question)

        await websocket.send(json.dumps({
            "type": "INTERRUPT_READY",
            "session_id": session.session_id,
            "audio_url": audio_file,
            "transcript": response_lines,
        }))

        # Notify about revised script
        remaining = len(session.chunks) - session.current_chunk_index - 1
        await websocket.send(json.dumps({
            "type": "SCRIPT_UPDATED",
            "session_id": session.session_id,
            "remaining_chunks": remaining,
        }))

        session.state = SessionState.PLAYING

        # Start prefetching next chunk after interrupt
        next_idx = session.current_chunk_index + 1
        if next_idx < len(session.chunks) and next_idx not in session.chunk_audio_files:
            _start_prefetch(session, next_idx)

    except Exception as e:
        log.exception("Interrupt handling failed")
        await _send_error(websocket, "INTERRUPT_FAILED", str(e))
        session.state = SessionState.PLAYING


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
        async with gpu_lock:
            audio_file = await generate_audio(session.chunks[chunk_idx])
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


async def _send_error(websocket, code: str, message: str) -> None:
    try:
        await websocket.send(json.dumps({
            "type": "ERROR",
            "code": code,
            "message": message,
        }))
    except Exception:
        pass  # connection may already be closed


def _cleanup_session(session_id: str) -> None:
    _cancel_prefetches(session_id)
    session = sessions.pop(session_id, None)
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
    filepath = Path(cfg.AUDIO_CACHE_DIR) / filename

    if not filepath.exists():
        # Check subdirectories (ComfyUI may use audio/ prefix)
        alt = Path(cfg.AUDIO_CACHE_DIR) / "audio" / filename
        if alt.exists():
            filepath = alt
        else:
            return web.Response(status=404, text="Not found")

    return web.FileResponse(filepath)


def create_http_app() -> web.Application:
    app = web.Application()
    app.router.add_get("/health", handle_health)
    app.router.add_get("/audio/{filename}", handle_audio)
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
