from __future__ import annotations

import json
import logging
from pathlib import Path

from audio_generator import ProgressCallback, generate_audio
from chunk_manager import split_into_chunks
from config import cfg
from llm_client import llm_chat
from session import PodcastSession, SessionState
from web_search import format_search_results, search

log = logging.getLogger(__name__)

SYSTEM_PROMPT = (Path(__file__).parent / "prompts" / "interrupt_system.txt").read_text()


async def handle_interrupt(session: PodcastSession, question: str, on_progress: ProgressCallback = None) -> tuple[str, list[dict]]:
    """Process a user interrupt.

    Returns (audio_filename, interrupt_response_lines).
    Also mutates session: splices revised script into remaining chunks.
    """
    session.state = SessionState.INTERRUPTED
    session.interrupt_history.append({"question": question})

    # Enrich with web search if enabled for this session
    web_context = ""
    if session.web_search_enabled:
        search_results = await search(question)
        web_context = format_search_results(search_results)

    context = {
        "original_topic": session.title,
        "full_original": session.original_script[:50],  # first 50 lines for context
        "delivered_so_far": session.delivered_lines,
        "pending_script": session.remaining_chunks_flat(),
        "prior_interrupts": session.interrupt_history,
        "user_question": question,
    }

    host_a = getattr(session, "host_a_name", cfg.HOST_A_NAME)
    host_b = getattr(session, "host_b_name", cfg.HOST_B_NAME)
    system = SYSTEM_PROMPT.format(
        HOST_A_NAME=host_a,
        HOST_B_NAME=host_b,
    )
    user_msg = f"Conversation context:\n\n{json.dumps(context, indent=2)}"
    if web_context:
        user_msg += f"\n\n{web_context}\n\nUse the web search results above to inform and enrich the hosts' response where relevant. Cite specific facts naturally in conversation."

    raw = await llm_chat(system=system, user=user_msg, model=cfg.LLM_MODEL)
    log.debug("Interrupt LLM raw response: %s", raw[:500])
    result = _parse_interrupt_response(raw)

    interrupt_lines = result["interrupt_response"]
    revised = result.get("revised_remaining", [])

    # Generate audio for the interrupt response using fast model
    audio_file = await generate_audio(
        interrupt_lines,
        seed=cfg.VOICE_SEED_A,
        model=cfg.INTERRUPT_MODEL,
        session_id=session.session_id,
        on_progress=on_progress,
        host_a_name=getattr(session, "host_a_name", None),
    )

    # Splice revised script into remaining chunks.
    # Always replace everything after the current chunk — even if revised is empty,
    # we need to invalidate stale prefetched audio.
    remaining_start = session.current_chunk_index + 1
    new_chunks = split_into_chunks(revised) if revised else []
    session.chunks = session.chunks[:remaining_start] + new_chunks
    # Invalidate all prefetched audio for replaced chunks
    session.chunk_audio_files = {
        k: v for k, v in session.chunk_audio_files.items() if k < remaining_start
    }
    log.info("Script revised: %d new chunks from index %d", len(new_chunks), remaining_start)

    session.interrupt_history[-1]["response"] = interrupt_lines
    session.state = SessionState.INTERRUPT_READY

    return audio_file, interrupt_lines


def _parse_interrupt_response(raw: str) -> dict:
    text = raw.strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[1] if "\n" in text else text[3:]
    if text.endswith("```"):
        text = text[:-3]
    text = text.strip()

    start = text.find("{")
    end = text.rfind("}")
    if start == -1 or end == -1:
        raise ValueError(f"No JSON object in interrupt response: {text[:200]}...")

    json_text = text[start : end + 1]
    # Reuse the same JSON repair from script_generator
    from script_generator import _repair_json
    json_text = _repair_json(json_text)

    data = json.loads(json_text)

    if "interrupt_response" not in data:
        raise ValueError("Missing 'interrupt_response' in LLM output")

    return data
