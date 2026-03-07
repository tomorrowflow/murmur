from __future__ import annotations

import asyncio
import logging

import httpx

from config import cfg

log = logging.getLogger(__name__)

# Track in-flight ComfyUI prompt IDs per session for cleanup
active_prompts: dict[str, set[str]] = {}  # session_id → {prompt_id, ...}

# Model name mapping: config names → actual ComfyUI model names
MODEL_MAP = {
    "Large": "VibeVoice-Large-Q8",
    "1.5B": "VibeVoice7b-low-vram",
}


def format_for_vibevoice(chunk: list[dict]) -> str:
    lines = []
    for turn in chunk:
        tag = "[1]:" if turn["speaker"] == cfg.HOST_A_NAME else "[2]:"
        lines.append(f"{tag} {turn['text']}")
    return "\n".join(lines)


async def generate_audio(
    chunk: list[dict],
    seed: int | None = None,
    model: str | None = None,
    session_id: str | None = None,
) -> str:
    """Generate audio for a script chunk via ComfyUI VibeVoice.

    Returns the output filename (available at ComfyUI's output dir).
    """
    seed = seed or cfg.VOICE_SEED_A
    model = model or cfg.CHUNK_MODEL
    text = format_for_vibevoice(chunk)

    workflow = _build_workflow(text, seed, model)
    prompt_id = await _post_workflow(workflow)

    # Track prompt for cleanup on session cancel
    if session_id:
        active_prompts.setdefault(session_id, set()).add(prompt_id)

    try:
        filename = await _poll_until_complete(prompt_id)
    finally:
        if session_id:
            active_prompts.get(session_id, set()).discard(prompt_id)

    log.info("Audio generated: %s (seed=%d, model=%s)", filename, seed, model)
    return filename


async def interrupt_comfyui() -> None:
    """Interrupt the currently running ComfyUI job immediately.

    POST /interrupt stops whatever is on the GPU right now.
    Use this when a user interrupt arrives to free the GPU fast.
    """
    try:
        async with httpx.AsyncClient(timeout=5) as client:
            await client.post(f"{cfg.COMFYUI_BASE_URL}/interrupt")
        log.info("Sent /interrupt to ComfyUI")
    except Exception:
        log.exception("Failed to interrupt ComfyUI")


async def cancel_session_prompts(session_id: str) -> None:
    """Cancel all queued/running ComfyUI prompts for a session."""
    prompt_ids = active_prompts.pop(session_id, set())
    if not prompt_ids:
        return

    log.info("Cancelling %d ComfyUI prompts for session %s", len(prompt_ids), session_id)
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            # Delete queued prompts
            await client.post(
                f"{cfg.COMFYUI_BASE_URL}/queue",
                json={"delete": list(prompt_ids)},
            )
            # Interrupt currently running prompt (if it belongs to this session)
            await client.post(f"{cfg.COMFYUI_BASE_URL}/interrupt")
    except Exception:
        log.exception("Failed to cancel ComfyUI prompts")


def _build_workflow(text: str, seed: int, model: str) -> dict:
    """Build the ComfyUI API workflow payload.

    Nodes:
      3 → LoadAudio (Carter/man → speaker 1 / Alex)
      4 → LoadAudio (Alice/woman → speaker 2 / Jordan)
      1 → VibeVoiceMultipleSpeakersNode (voice-cloned from reference samples)
      2 → SaveAudio
    """
    comfyui_model = MODEL_MAP.get(model, model)

    return {
        "prompt": {
            "3": {
                "class_type": "LoadAudio",
                "inputs": {
                    "audio": cfg.VOICE_REF_SPEAKER1,
                },
            },
            "4": {
                "class_type": "LoadAudio",
                "inputs": {
                    "audio": cfg.VOICE_REF_SPEAKER2,
                },
            },
            "1": {
                "class_type": "VibeVoiceMultipleSpeakersNode",
                "inputs": {
                    "text": text,
                    "model": comfyui_model,
                    "attention_type": "auto",
                    "quantize_llm": "full precision",
                    "free_memory_after_generate": False,
                    "diffusion_steps": 20,
                    "seed": seed,
                    "cfg_scale": 1.3,
                    "use_sampling": False,
                    "speaker1_voice": ["3", 0],
                    "speaker2_voice": ["4", 0],
                },
            },
            "2": {
                "class_type": "SaveAudio",
                "inputs": {
                    "filename_prefix": "podcast",
                    "audio": ["1", 0],
                },
            },
        }
    }


async def _post_workflow(workflow: dict) -> str:
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.post(
            f"{cfg.COMFYUI_BASE_URL}/prompt",
            json=workflow,
        )
        if resp.status_code != 200:
            log.error("ComfyUI rejected workflow: %s", resp.text)
        resp.raise_for_status()
        data = resp.json()

    prompt_id = data["prompt_id"]
    log.info("Queued ComfyUI prompt: %s", prompt_id)
    return prompt_id


async def _poll_until_complete(prompt_id: str, timeout: float = 300) -> str:
    """Poll ComfyUI /history until the prompt completes. Returns output filename."""
    elapsed = 0.0
    interval = 2.0

    async with httpx.AsyncClient(timeout=30) as client:
        while elapsed < timeout:
            resp = await client.get(f"{cfg.COMFYUI_BASE_URL}/history/{prompt_id}")
            resp.raise_for_status()
            history = resp.json()

            if prompt_id in history:
                entry = history[prompt_id]
                # Check if the prompt was interrupted
                status = entry.get("status", {})
                if status.get("status_str") == "error" or not entry.get("outputs"):
                    raise RuntimeError(f"ComfyUI prompt {prompt_id} was interrupted or failed")
                outputs = entry.get("outputs", {})
                for node_id, node_out in outputs.items():
                    if "audio" in node_out:
                        return node_out["audio"][0]["filename"]
                raise RuntimeError(f"No audio output found in ComfyUI result: {outputs}")

            await asyncio.sleep(interval)
            elapsed += interval

    raise TimeoutError(f"ComfyUI prompt {prompt_id} timed out after {timeout}s")
