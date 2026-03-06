from __future__ import annotations

import logging

import httpx

from config import cfg

log = logging.getLogger(__name__)


async def llm_chat(system: str, user: str, model: str | None = None) -> str:
    """Send a chat completion request to the configured LLM provider."""
    model = model or cfg.LLM_MODEL

    if cfg.LLM_PROVIDER == "ollama":
        return await _ollama_chat(system, user, model)
    elif cfg.LLM_PROVIDER == "anthropic":
        return await _anthropic_chat(system, user, model)
    else:
        raise ValueError(f"Unknown LLM provider: {cfg.LLM_PROVIDER}")


async def _ollama_chat(system: str, user: str, model: str) -> str:
    url = f"{cfg.OLLAMA_BASE_URL}/api/chat"
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "stream": False,
        "options": {
            "temperature": 0.8,
            "num_predict": 8192,
        },
    }

    log.info("Ollama request: model=%s, url=%s", model, url)
    async with httpx.AsyncClient(timeout=180) as client:
        resp = await client.post(url, json=payload)
        resp.raise_for_status()
        data = resp.json()

    content = data["message"]["content"]
    # Strip thinking blocks from models that emit <think>...</think>
    import re
    content = re.sub(r"<think>.*?</think>", "", content, flags=re.DOTALL).strip()
    log.info("Ollama response: %d chars", len(content))
    return content


async def _anthropic_chat(system: str, user: str, model: str) -> str:
    import anthropic

    client = anthropic.AsyncAnthropic(api_key=cfg.LLM_API_KEY)
    message = await client.messages.create(
        model=model,
        max_tokens=4096,
        system=system,
        messages=[{"role": "user", "content": user}],
    )
    return message.content[0].text
