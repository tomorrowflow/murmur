from __future__ import annotations

import json
import logging
import re
from pathlib import Path

from config import cfg
from llm_client import LLMProgressCallback, llm_chat

log = logging.getLogger(__name__)

SYSTEM_PROMPT = (Path(__file__).parent / "prompts" / "script_system.txt").read_text()

# Below this size the raw source goes straight into the script LLM call.
# Above it, we distill the content first so nothing is lost to truncation.
DISTILL_THRESHOLD_CHARS = 18_000

# Target size for each distillation LLM call. Chosen to leave headroom for the
# system prompt + output budget inside qwen3:32b's context window.
DISTILL_CHUNK_CHARS = 22_000

# Max size of the final source content fed to the script LLM call, regardless
# of whether it was distilled or passed through.
MAX_SCRIPT_CONTEXT_CHARS = 32_000

DISTILL_SYSTEM_PROMPT = (
    "You receive source material (an article, paper, transcript, meeting notes, "
    "or any mix of these). Extract a dense, structured brief that preserves "
    "everything a later writer would need to discuss the material faithfully.\n\n"
    "Preserve:\n"
    "- Named entities (people, projects, organisations, places, dates)\n"
    "- Specific numbers, commitments, decisions, quotes\n"
    "- Distinctive phrasings from the author or speakers\n"
    "- Logical structure and distinct sections. If the material clearly contains "
    "  separate parts (e.g. framing narrative and a discussion/transcript), keep "
    "  them visibly separated in your output.\n\n"
    "Rules:\n"
    "- Do NOT summarise in your own words when you can cite original phrasing.\n"
    "- Do NOT collapse multiple speakers or perspectives into one voice.\n"
    "- Do NOT add interpretation, opinion, or facts not in the source.\n"
    "- Output plain prose and bullet points. No JSON, no markdown headers.\n"
    "- Target ~30% of the input length — compress carefully, not aggressively."
)


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


def sanitize_dialogue(text: str) -> str:
    """Clean dialogue text for reliable TTS rendering.

    Handles common LLM artifacts that cause issues with VibeVoice:
    - Curly/smart quotes → straight quotes
    - Ellipsis (… or ...) → em dash
    - Asterisks (emphasis markers) → removed
    - Parenthetical stage directions → removed
    - Excessive punctuation → normalized
    - Unicode dashes → standard em dash
    - Control characters → removed
    """
    import re

    # Smart/curly quotes → straight
    text = text.replace('\u201c', '"').replace('\u201d', '"')
    text = text.replace('\u2018', "'").replace('\u2019', "'")

    # Ellipsis character or triple dots → em dash
    text = text.replace('\u2026', ' \u2014 ')  # … → —
    text = re.sub(r'\.{2,}', ' \u2014 ', text)  # .. or ... → —

    # Various Unicode dashes → standard em dash
    text = text.replace('\u2013', '\u2014')  # en dash → em dash
    text = text.replace('\u2015', '\u2014')  # horizontal bar → em dash

    # Remove asterisks (LLM emphasis: *word* or **word**)
    text = re.sub(r'\*+', '', text)

    # Remove parenthetical stage directions like (laughs) (sighs) (pauses)
    text = re.sub(r'\([^)]{1,30}\)', '', text)

    # Remove hashtags and markdown headers
    text = re.sub(r'#+\s*', '', text)

    # Normalize excessive punctuation (!!!, ???, etc.)
    text = re.sub(r'!{2,}', '!', text)
    text = re.sub(r'\?{2,}', '?', text)

    # Remove control characters (except standard whitespace)
    text = re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', '', text)

    # Collapse multiple spaces
    text = re.sub(r' {2,}', ' ', text)

    return text.strip()


def _split_on_boundaries(text: str, target_chars: int) -> list[str]:
    """Split text into ≤ target_chars chunks, preferring natural boundaries.

    Tries paragraph breaks first, then single newlines, then sentence ends,
    finally a hard cut. Never returns an empty chunk."""
    if len(text) <= target_chars:
        return [text]

    chunks: list[str] = []
    remaining = text
    while len(remaining) > target_chars:
        # Look at the target-chars window and walk backwards for a good split.
        window = remaining[:target_chars]
        # Preference order: paragraph, line, sentence end, whitespace, hard cut.
        split_at = -1
        for pattern in (r"\n\s*\n", r"\n", r"[\.!\?]\s", r"\s"):
            for m in re.finditer(pattern, window):
                split_at = m.end()
        if split_at <= 0 or split_at < target_chars // 2:
            # No sensible boundary in the second half of the window —
            # just hard-cut at target so we don't end up with lopsided chunks.
            split_at = target_chars
        chunks.append(remaining[:split_at].strip())
        remaining = remaining[split_at:]
    if remaining.strip():
        chunks.append(remaining.strip())
    return chunks


def _wrap_distill_progress(
    outer: LLMProgressCallback,
    part_index: int,
    part_count: int,
) -> LLMProgressCallback:
    """Forward LLM streaming progress with a part-number label folded in."""
    if outer is None:
        return None

    def inner(char_count: int, phase: str):
        # Encode part info into the phase string so the main.py callback can
        # render e.g. "Distilling source (part 2/3) — 1,234 chars".
        label = f"distill:{part_index + 1}/{part_count}"
        if phase == "thinking":
            label += ":thinking"
        try:
            outer(char_count, label)
        except Exception:
            log.exception("distill progress wrapper raised")
    return inner


async def prepare_source_content(
    content: str,
    on_progress: LLMProgressCallback = None,
) -> str:
    """Return content ready for the script LLM, distilling if it's long.

    Below DISTILL_THRESHOLD_CHARS the source is passed through untouched.
    Above it, the source is split into chunks and each chunk is distilled via
    the same LLM the script generator uses. The distilled parts are
    concatenated with explicit separators so the script writer can see which
    pieces of source material were distinct."""
    if len(content) <= DISTILL_THRESHOLD_CHARS:
        return content

    parts = _split_on_boundaries(content, DISTILL_CHUNK_CHARS)
    log.info("Distilling source: %d chars → %d parts (target ≤%d chars each)",
             len(content), len(parts), DISTILL_CHUNK_CHARS)

    briefs: list[str] = []
    for i, part in enumerate(parts):
        user_msg = (
            f"Source part {i + 1} of {len(parts)} "
            f"({len(part)} characters).\n\n{part}"
        )
        brief = await llm_chat(
            system=DISTILL_SYSTEM_PROMPT,
            user=user_msg,
            model=cfg.LLM_MODEL,
            on_progress=_wrap_distill_progress(on_progress, i, len(parts)),
        )
        briefs.append(brief.strip())
        log.info("Distilled part %d/%d: %d chars → %d chars",
                 i + 1, len(parts), len(part), len(brief))

    separator = "\n\n--- Next section of source material ---\n\n"
    return separator.join(briefs)


async def generate_script(
    content: str,
    target_length: str = "auto",
    host_a_name: str | None = None,
    host_b_name: str | None = None,
    on_progress: LLMProgressCallback = None,
    on_distill_progress: LLMProgressCallback = None,
) -> tuple[str, list[dict], int]:
    """Generate a podcast script from source content.

    Returns (title, script_lines, target_minutes) where script_lines is a list of
    {"speaker": str, "text": str, "line_id": int} dicts.
    """
    host_a = host_a_name or cfg.HOST_A_NAME
    host_b = host_b_name or cfg.HOST_B_NAME
    target_minutes = _resolve_target_minutes(target_length, content)
    log.info("Target length: %s → %d minutes (content: %d words, hosts: %s/%s)",
             target_length, target_minutes, len(content.split()), host_a, host_b)

    # Distill long content so the full document survives — no hard-coded
    # "is this a transcript?" logic; the LLM decides how to structure the brief.
    prepared = await prepare_source_content(content, on_progress=on_distill_progress)

    system = SYSTEM_PROMPT.format(
        HOST_A_NAME=host_a,
        HOST_B_NAME=host_b,
        target_duration_minutes=target_minutes,
    )

    user_msg = f"Source content to discuss:\n\n{prepared[:MAX_SCRIPT_CONTEXT_CHARS]}"

    raw = await llm_chat(system=system, user=user_msg, model=cfg.LLM_MODEL, on_progress=on_progress)

    script = _parse_script(raw)
    title = _extract_title(script)

    # Ensure line_ids are sequential
    for i, line in enumerate(script):
        line["line_id"] = i

    log.info("Generated script: %d lines, title=%s", len(script), title)
    return title, script, target_minutes


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
        # Sanitize dialogue text for TTS
        item["text"] = sanitize_dialogue(item["text"])

    return data


def _repair_json(text: str) -> str:
    """Fix common JSON issues from LLM output."""
    import re

    # Replace curly/smart quotes with straight quotes
    text = text.replace('\u201c', '"').replace('\u201d', '"')  # " "
    text = text.replace('\u2018', "'").replace('\u2019', "'")  # ' '

    # Replace single-quoted JSON keys/values with double quotes
    # Only if the text looks like it uses single quotes for JSON structure
    # (e.g. {'speaker': 'Alex'} → {"speaker": "Alex"})
    if text.lstrip().startswith("[{") or text.lstrip().startswith("{'"):
        text = _single_to_double_quotes(text)

    # Remove trailing commas before ] or }
    text = re.sub(r",\s*([}\]])", r"\1", text)

    # Fix unescaped literal newlines inside JSON strings
    text = _fix_newlines_in_strings(text)

    # Fix unescaped double quotes inside JSON string values
    text = _fix_inner_quotes(text)

    return text


def _single_to_double_quotes(text: str) -> str:
    """Convert single-quoted JSON to double-quoted JSON."""
    result = []
    i = 0
    in_double = False
    in_single = False
    while i < len(text):
        ch = text[i]
        if ch == '\\' and (in_double or in_single):
            result.append(text[i:i+2])
            i += 2
            continue
        if ch == '"' and not in_single:
            in_double = not in_double
            result.append(ch)
        elif ch == "'" and not in_double:
            if not in_single:
                in_single = True
                result.append('"')
            else:
                in_single = False
                result.append('"')
        else:
            # Inside a single-quoted string that's now double-quoted,
            # escape any literal double quotes
            if in_single and ch == '"':
                result.append('\\"')
            else:
                result.append(ch)
        i += 1
    return ''.join(result)


def _fix_newlines_in_strings(text: str) -> str:
    """Replace literal newlines/tabs inside JSON strings with escaped versions."""
    result = []
    in_string = False
    i = 0
    while i < len(text):
        ch = text[i]
        if ch == '\\' and in_string and i + 1 < len(text):
            result.append(text[i:i+2])
            i += 2
            continue
        if ch == '"':
            in_string = not in_string
            result.append(ch)
            i += 1
        elif in_string and ch == '\n':
            result.append(' ')  # replace literal newline with space
            i += 1
        elif in_string and ch == '\t':
            result.append(' ')
            i += 1
        elif in_string and ch == '\r':
            i += 1  # skip carriage returns
        else:
            result.append(ch)
            i += 1
    return ''.join(result)


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
