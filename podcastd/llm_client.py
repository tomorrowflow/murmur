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
# Args: (token_count_so_far, thinking_or_output_phase)
# Ollama's /api/chat streaming emits one JSON message per generated token;
# the count here is literally the number of tokens observed, matching the
# provider's own eval_count field in the final done-message.
# phase is "thinking" while the model is inside a <think> block,
# "output" otherwise. Callbacks MUST be non-blocking.
LLMProgressCallback = Optional[Callable[[int, str], None]]


async def llm_chat(
    system: str,
    user: str,
    model: str | None = None,
    on_progress: LLMProgressCallback = None,
    num_predict: int | None = None,
) -> str:
    """Send a chat completion request to the configured LLM provider.

    If `on_progress` is supplied, streaming mode is used where supported so the
    caller can surface live progress. The callback is throttled internally.
    `num_predict` overrides the per-call output token budget (Ollama only);
    omit to use the provider default."""
    model = model or cfg.LLM_MODEL

    if cfg.LLM_PROVIDER == "ollama":
        return await _ollama_chat(system, user, model, on_progress, num_predict)
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
    num_predict: int | None = None,
) -> str:
    url = f"{cfg.OLLAMA_BASE_URL}/api/chat"
    use_stream = on_progress is not None
    effective_num_predict = num_predict if num_predict is not None else 8192
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "stream": use_stream,
        "options": {
            "temperature": 0.8,
            "num_predict": effective_num_predict,
        },
    }

    log.info("Ollama request: model=%s, url=%s, stream=%s, num_predict=%d",
             model, url, use_stream, effective_num_predict)

    if not use_stream:
        async with httpx.AsyncClient(timeout=180) as client:
            resp = await client.post(url, json=payload)
            resp.raise_for_status()
            data = resp.json()
        content = data["message"]["content"]
        content = re.sub(r"<think>.*?</think>", "", content, flags=re.DOTALL).strip()
        log.info("Ollama response: %d chars", len(content))
        return content

    # Streaming path — one chunk per token, fire throttled progress callbacks.
    parts: list[str] = []
    total_tokens = 0
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
                    # Each non-empty streaming message from Ollama carries exactly
                    # one generated token's text, so this counter matches what the
                    # model reports as eval_count when done=True arrives.
                    total_tokens += 1
                    # Rough think-block detection — good enough for a progress label.
                    if "<think>" in piece:
                        think_depth += piece.count("<think>")
                    if "</think>" in piece:
                        think_depth = max(0, think_depth - piece.count("</think>"))
                    in_think = think_depth > 0

                    now = time.monotonic()
                    if now - last_emit >= _PROGRESS_THROTTLE_SECS:
                        try:
                            on_progress(total_tokens, "thinking" if in_think else "output")
                        except Exception:
                            log.exception("LLM progress callback raised")
                        last_emit = now

                if chunk.get("done"):
                    break

    content = "".join(parts)
    # Strip thinking blocks from models that emit <think>...</think>
    content = re.sub(r"<think>.*?</think>", "", content, flags=re.DOTALL).strip()
    log.info("Ollama response: %d tokens (%d chars after stripping think)",
             total_tokens, len(content))
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

    # Streaming path mirrors the Ollama branch. Anthropic's text_stream yields
    # text deltas of varying size (not necessarily one token per event), so we
    # approximate tokens from character count at ~4 chars/token.
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
                approx_tokens = max(1, total_chars // 4)
                try:
                    on_progress(approx_tokens, "output")
                except Exception:
                    log.exception("LLM progress callback raised")
                last_emit = now
    return "".join(collected)
