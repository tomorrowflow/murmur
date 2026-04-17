from __future__ import annotations

import json
import logging
import re
import time
from typing import Awaitable, Callable, Optional

import httpx

from config import cfg

log = logging.getLogger(__name__)


# Callback fired periodically while an LLM response is streaming.
# Args: (char_count_so_far, thinking_or_output_phase)
# phase is "thinking" while the model is inside a <think> block,
# "output" otherwise. Callbacks MUST be non-blocking.
LLMProgressCallback = Optional[Callable[[int, str], None]]


async def llm_chat(
    system: str,
    user: str,
    model: str | None = None,
    on_progress: LLMProgressCallback = None,
) -> str:
    """Send a chat completion request to the configured LLM provider.

    If `on_progress` is supplied, streaming mode is used where supported so the
    caller can surface live progress. The callback is throttled internally."""
    model = model or cfg.LLM_MODEL

    if cfg.LLM_PROVIDER == "ollama":
        return await _ollama_chat(system, user, model, on_progress)
    elif cfg.LLM_PROVIDER == "anthropic":
        return await _anthropic_chat(system, user, model, on_progress)
    else:
        raise ValueError(f"Unknown LLM provider: {cfg.LLM_PROVIDER}")


# Minimum interval between progress callbacks to avoid flooding consumers.
_PROGRESS_THROTTLE_SECS = 0.4


async def _ollama_chat(
    system: str,
    user: str,
    model: str,
    on_progress: LLMProgressCallback = None,
) -> str:
    url = f"{cfg.OLLAMA_BASE_URL}/api/chat"
    use_stream = on_progress is not None
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "stream": use_stream,
        "options": {
            "temperature": 0.8,
            "num_predict": 8192,
        },
    }

    log.info("Ollama request: model=%s, url=%s, stream=%s", model, url, use_stream)

    if not use_stream:
        async with httpx.AsyncClient(timeout=180) as client:
            resp = await client.post(url, json=payload)
            resp.raise_for_status()
            data = resp.json()
        content = data["message"]["content"]
        content = re.sub(r"<think>.*?</think>", "", content, flags=re.DOTALL).strip()
        log.info("Ollama response: %d chars", len(content))
        return content

    # Streaming path — accumulate chunks, fire throttled progress callbacks.
    parts: list[str] = []
    total_chars = 0
    in_think = False
    think_depth = 0
    last_emit = 0.0

    # Per-read timeout of 90s — generous for big models, but bails out if the
    # backend stalls. Total time is unbounded so a long generation can complete.
    stream_timeout = httpx.Timeout(connect=15.0, read=90.0, write=30.0, pool=15.0)

    async with httpx.AsyncClient(timeout=stream_timeout) as client:
        async with client.stream("POST", url, json=payload) as resp:
            resp.raise_for_status()
            async for line in resp.aiter_lines():
                if not line.strip():
                    continue
                try:
                    chunk = json.loads(line)
                except json.JSONDecodeError:
                    continue

                piece = (chunk.get("message") or {}).get("content", "")
                if piece:
                    parts.append(piece)
                    total_chars += len(piece)
                    # Rough think-block detection — good enough for a progress label.
                    if "<think>" in piece:
                        think_depth += piece.count("<think>")
                    if "</think>" in piece:
                        think_depth = max(0, think_depth - piece.count("</think>"))
                    in_think = think_depth > 0

                    now = time.monotonic()
                    if now - last_emit >= _PROGRESS_THROTTLE_SECS:
                        try:
                            on_progress(total_chars, "thinking" if in_think else "output")
                        except Exception:
                            log.exception("LLM progress callback raised")
                        last_emit = now

                if chunk.get("done"):
                    break

    content = "".join(parts)
    # Strip thinking blocks from models that emit <think>...</think>
    content = re.sub(r"<think>.*?</think>", "", content, flags=re.DOTALL).strip()
    log.info("Ollama response: %d chars (streamed)", len(content))
    return content


async def _anthropic_chat(
    system: str,
    user: str,
    model: str,
    on_progress: LLMProgressCallback = None,
) -> str:
    import anthropic

    client = anthropic.AsyncAnthropic(api_key=cfg.LLM_API_KEY)

    # Without progress tracking, use the simple non-streaming call.
    if on_progress is None:
        message = await client.messages.create(
            model=model,
            max_tokens=4096,
            system=system,
            messages=[{"role": "user", "content": user}],
        )
        return message.content[0].text

    # Streaming path mirrors the Ollama branch.
    total_chars = 0
    last_emit = 0.0
    collected: list[str] = []
    async with client.messages.stream(
        model=model,
        max_tokens=4096,
        system=system,
        messages=[{"role": "user", "content": user}],
    ) as stream:
        async for text in stream.text_stream:
            collected.append(text)
            total_chars += len(text)
            now = time.monotonic()
            if now - last_emit >= _PROGRESS_THROTTLE_SECS:
                try:
                    on_progress(total_chars, "output")
                except Exception:
                    log.exception("LLM progress callback raised")
                last_emit = now
    return "".join(collected)
