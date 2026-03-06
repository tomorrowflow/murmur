from __future__ import annotations

import logging

import httpx

from config import cfg

log = logging.getLogger(__name__)

SEARCH_URL = "https://ollama.com/api/web_search"


async def search(query: str) -> list[dict]:
    """Search the web via Ollama's web search API.

    Returns a list of {"title", "url", "content"} dicts.
    Returns empty list on failure or if disabled.
    """
    if not cfg.WEB_SEARCH_ENABLED or not cfg.OLLAMA_API_KEY:
        return []

    try:
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.post(
                SEARCH_URL,
                headers={"Authorization": f"Bearer {cfg.OLLAMA_API_KEY}"},
                json={
                    "query": query,
                    "max_results": cfg.WEB_SEARCH_MAX_RESULTS,
                },
            )
            resp.raise_for_status()
            data = resp.json()

        results = data.get("results", [])
        log.info("Web search for %r: %d results", query, len(results))
        return results

    except Exception:
        log.exception("Web search failed for %r", query)
        return []


def format_search_results(results: list[dict]) -> str:
    """Format search results as context for the LLM."""
    if not results:
        return ""

    lines = ["## Web Search Results\n"]
    for r in results:
        title = r.get("title", "")
        url = r.get("url", "")
        content = r.get("content", "")
        lines.append(f"**{title}** ({url})\n{content}\n")

    return "\n".join(lines)
