from __future__ import annotations

import asyncio
import logging

import httpx

from config import cfg

log = logging.getLogger(__name__)

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
) -> str:
    """Generate audio for a script chunk via ComfyUI VibeVoice.

    Returns the output filename (available at ComfyUI's output dir).
    """
    seed = seed or cfg.VOICE_SEED_A
    model = model or cfg.CHUNK_MODEL
    text = format_for_vibevoice(chunk)

    workflow = _build_workflow(text, seed, model)
    prompt_id = await _post_workflow(workflow)
    filename = await _poll_until_complete(prompt_id)

    log.info("Audio generated: %s (seed=%d, model=%s)", filename, seed, model)
    return filename


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
                outputs = history[prompt_id].get("outputs", {})
                for node_id, node_out in outputs.items():
                    if "audio" in node_out:
                        return node_out["audio"][0]["filename"]
                raise RuntimeError(f"No audio output found in ComfyUI result: {outputs}")

            await asyncio.sleep(interval)
            elapsed += interval

    raise TimeoutError(f"ComfyUI prompt {prompt_id} timed out after {timeout}s")
