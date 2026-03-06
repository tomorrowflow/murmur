from __future__ import annotations

import json
import logging
from pathlib import Path

from config import cfg
from llm_client import llm_chat

log = logging.getLogger(__name__)

SYSTEM_PROMPT = (Path(__file__).parent / "prompts" / "script_system.txt").read_text()


async def generate_script(content: str, target_minutes: int = 8) -> tuple[str, list[dict]]:
    """Generate a podcast script from source content.

    Returns (title, script_lines) where script_lines is a list of
    {"speaker": str, "text": str, "line_id": int} dicts.
    """
    system = SYSTEM_PROMPT.format(
        HOST_A_NAME=cfg.HOST_A_NAME,
        HOST_B_NAME=cfg.HOST_B_NAME,
        target_duration_minutes=target_minutes,
    )

    user_msg = f"Source content to discuss:\n\n{content[:15000]}"

    raw = await llm_chat(system=system, user=user_msg, model=cfg.LLM_MODEL)

    script = _parse_script(raw)
    title = _extract_title(script)

    # Ensure line_ids are sequential
    for i, line in enumerate(script):
        line["line_id"] = i

    log.info("Generated script: %d lines, title=%s", len(script), title)
    return title, script


def _parse_script(raw: str) -> list[dict]:
    # Strip markdown code fences if present
    text = raw.strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[1] if "\n" in text else text[3:]
    if text.endswith("```"):
        text = text[:-3]
    text = text.strip()

    # Try to find JSON array
    start = text.find("[")
    end = text.rfind("]")
    if start == -1:
        raise ValueError(f"No JSON array found in LLM response: {text[:200]}...")

    if end == -1 or end <= start:
        # Array was truncated — try to recover by closing it
        text = text[start:]
        text = _repair_truncated_json(text)
    else:
        text = text[start : end + 1]

    # Fix common LLM JSON issues
    text = _repair_json(text)

    try:
        data = json.loads(text)
    except json.JSONDecodeError as e:
        raise ValueError(f"Invalid JSON in LLM response: {e}") from e

    if not isinstance(data, list) or not data:
        raise ValueError("LLM returned empty or non-list JSON")

    for item in data:
        if "speaker" not in item or "text" not in item:
            raise ValueError(f"Script line missing speaker/text: {item}")

    return data


def _repair_json(text: str) -> str:
    """Fix common JSON issues from LLM output."""
    import re
    # Remove trailing commas before ] or }
    text = re.sub(r",\s*([}\]])", r"\1", text)
    return text


def _repair_truncated_json(text: str) -> str:
    """Attempt to recover a truncated JSON array by closing open structures."""
    import re
    # Remove any trailing incomplete object (no closing brace)
    # Find the last complete object (ends with })
    last_brace = text.rfind("}")
    if last_brace == -1:
        raise ValueError("No complete JSON objects found in truncated response")

    text = text[: last_brace + 1]
    # Remove trailing comma if present
    text = re.sub(r",\s*$", "", text)
    text += "]"
    log.warning("Repaired truncated JSON array (%d chars)", len(text))
    return text


def _extract_title(script: list[dict]) -> str:
    if script:
        first_text = script[0]["text"]
        words = first_text.split()[:8]
        return " ".join(words) + ("..." if len(first_text.split()) > 8 else "")
    return "Untitled Podcast"
