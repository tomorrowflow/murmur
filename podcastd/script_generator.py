from __future__ import annotations

import json
import logging
from pathlib import Path

from config import cfg
from llm_client import llm_chat

log = logging.getLogger(__name__)

SYSTEM_PROMPT = (Path(__file__).parent / "prompts" / "script_system.txt").read_text()


def _resolve_target_minutes(target_length: str, content: str) -> int:
    """Resolve the target podcast duration in minutes.

    Fixed modes:
      - "short"  → ~8 minutes
      - "medium" → ~15 minutes
      - "long"   → ~30 minutes

    Auto mode scales with content length:
      - < 500 words   → 5 min
      - 500-1500      → 8 min
      - 1500-3000     → 12 min
      - 3000-6000     → 18 min
      - > 6000        → 25 min
    """
    fixed = {"short": 8, "medium": 15, "long": 30}
    if target_length in fixed:
        return fixed[target_length]

    # Auto: scale with content word count
    word_count = len(content.split())
    if word_count < 500:
        return 5
    elif word_count < 1500:
        return 8
    elif word_count < 3000:
        return 12
    elif word_count < 6000:
        return 18
    else:
        return 25


async def generate_script(content: str, target_length: str = "auto") -> tuple[str, list[dict]]:
    """Generate a podcast script from source content.

    Returns (title, script_lines) where script_lines is a list of
    {"speaker": str, "text": str, "line_id": int} dicts.
    """
    target_minutes = _resolve_target_minutes(target_length, content)
    log.info("Target length: %s → %d minutes (content: %d words)",
             target_length, target_minutes, len(content.split()))

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
    # Fix unescaped double quotes inside JSON string values.
    # Walk character by character: when inside a string, any quote that isn't
    # followed by a structural char (, : } ]) or preceded by a structural char
    # (: , { [) is likely an inner quote that needs escaping.
    text = _fix_inner_quotes(text)
    return text


def _fix_inner_quotes(text: str) -> str:
    """Escape unescaped double quotes that appear inside JSON string values."""
    result = []
    i = 0
    in_string = False
    while i < len(text):
        ch = text[i]
        if ch == '\\' and in_string:
            # Escaped character — pass through both chars
            result.append(text[i:i+2])
            i += 2
            continue
        if ch == '"':
            if not in_string:
                in_string = True
                result.append(ch)
            else:
                # Is this the real closing quote or an inner quote?
                # Look ahead: skip whitespace, then expect a structural char
                j = i + 1
                while j < len(text) and text[j] in ' \t\n\r':
                    j += 1
                if j >= len(text) or text[j] in ',}]:':
                    # Structural char follows — this is the real closing quote
                    in_string = False
                    result.append(ch)
                else:
                    # Not followed by structural char — inner quote, escape it
                    result.append('\\"')
            i += 1
        else:
            result.append(ch)
            i += 1
    return ''.join(result)


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
