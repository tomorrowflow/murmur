from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import Callable
from pathlib import Path

import httpx
import websockets

from config import cfg

# Type alias for progress callbacks: (elapsed_seconds, estimated_total_seconds)
ProgressCallback = Callable[[float, float], None] | None

log = logging.getLogger(__name__)

# Track in-flight ComfyUI prompt IDs per session for cleanup
active_prompts: dict[str, set[str]] = {}  # session_id → {prompt_id, ...}

# Client preset key → (comfyui_model_dir, quantize_llm)
# All models use "full precision" for quantize_llm since they are either
# full-precision checkpoints or pre-quantized (Q8/Q4) checkpoints.
MODEL_PRESETS: dict[str, tuple[str, str]] = {
    "large-fp": ("VibeVoice-Large", "full precision"),
    "large-q8": ("VibeVoice-Large-Q8", "full precision"),
    "large-q4": ("VibeVoice7b-low-vram", "full precision"),
    "1.5b-fp": ("VibeVoice-1.5B", "full precision"),
}
DEFAULT_PRESET = "large-q4"


# Rough generation speed: seconds per character of input text, by model.
# Calibrated from observed generation times on RTX 3090 (diffusion_steps=20).
# 1.5B measured at ~0.035 s/char; others scaled proportionally.
_MODEL_SECS_PER_CHAR: dict[str, float] = {
    "VibeVoice-Large": 0.11,        # ~9 chars/s, slowest
    "VibeVoice-Large-Q8": 0.07,     # ~14 chars/s
    "VibeVoice7b-low-vram": 0.05,   # ~20 chars/s
    "VibeVoice-1.5B": 0.035,        # ~29 chars/s, fastest
}
_OVERHEAD_SECS = 5.0


def estimate_generation_time(text: str, model: str) -> float:
    """Estimate audio generation time in seconds based on text length and model."""
    rate = _MODEL_SECS_PER_CHAR.get(model, 0.015)
    return len(text) * rate + _OVERHEAD_SECS


def format_for_vibevoice(chunk: list[dict], host_a_name: str | None = None) -> str:
    host_a = host_a_name or cfg.HOST_A_NAME
    lines = []
    for turn in chunk:
        tag = "[1]:" if turn["speaker"] == host_a else "[2]:"
        lines.append(f"{tag} {turn['text']}")
    return "\n".join(lines)


def resolve_preset(preset: str | None) -> tuple[str, str]:
    """Resolve a preset key to (comfyui_model, quantize_llm)."""
    return MODEL_PRESETS.get(preset or DEFAULT_PRESET, MODEL_PRESETS[DEFAULT_PRESET])


def get_voice_refs() -> tuple[str | None, str | None]:
    """Return (speaker1_ref, speaker2_ref) filenames, checking uploads first."""
    input_dir = Path(cfg.COMFYUI_INPUT_DIR)
    ref1 = (
        "podcast_voice_speaker1.wav"
        if (input_dir / "podcast_voice_speaker1.wav").exists()
        else cfg.VOICE_REF_SPEAKER1
    )
    ref2 = (
        "podcast_voice_speaker2.wav"
        if (input_dir / "podcast_voice_speaker2.wav").exists()
        else cfg.VOICE_REF_SPEAKER2
    )
    return ref1, ref2


async def generate_audio(
    chunk: list[dict],
    seed: int | None = None,
    model: str | None = None,
    quantize_llm: str | None = None,
    session_id: str | None = None,
    on_progress: ProgressCallback = None,
    host_a_name: str | None = None,
) -> str:
    """Generate audio for a script chunk via ComfyUI VibeVoice.

    Returns the output filename (available at ComfyUI's output dir).
    model/quantize_llm can be passed directly or resolved from a preset.
    on_progress(elapsed, estimated_total) is called periodically during generation.
    """
    seed = seed or cfg.VOICE_SEED_A
    model = model or cfg.CHUNK_MODEL
    quantize_llm = quantize_llm or "full precision"
    text = format_for_vibevoice(chunk, host_a_name=host_a_name)
    estimated_secs = estimate_generation_time(text, model)

    workflow = _build_workflow(text, seed, model, quantize_llm)

    # Connect WS BEFORE posting workflow to avoid missing completion events
    ws_url = cfg.COMFYUI_BASE_URL.replace("http://", "ws://").replace("https://", "wss://") + "/ws?clientId=podcastd"
    try:
        ws = await websockets.connect(ws_url, open_timeout=10)
    except Exception as e:
        log.warning("Could not open ComfyUI WS (%s), will use polling", e)
        ws = None

    prompt_id = await _post_workflow(workflow)

    # Track prompt for cleanup on session cancel
    if session_id:
        active_prompts.setdefault(session_id, set()).add(prompt_id)

    try:
        filename = await _wait_for_completion(prompt_id, ws=ws, on_progress=on_progress, estimated_secs=estimated_secs)
    finally:
        if session_id:
            active_prompts.get(session_id, set()).discard(prompt_id)
        if ws:
            await ws.close()

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


def _build_workflow(text: str, seed: int, model: str, quantize_llm: str = "full precision") -> dict:
    """Build the ComfyUI API workflow payload.

    Nodes:
      3 → LoadAudio (speaker 1 voice reference)
      4 → LoadAudio (speaker 2 voice reference)
      1 → VibeVoiceMultipleSpeakersNode (voice-cloned from reference samples)
      2 → SaveAudio
    """
    ref1, ref2 = get_voice_refs()

    return {
        "prompt": {
            "3": {
                "class_type": "LoadAudio",
                "inputs": {
                    "audio": ref1,
                },
            },
            "4": {
                "class_type": "LoadAudio",
                "inputs": {
                    "audio": ref2,
                },
            },
            "1": {
                "class_type": "VibeVoiceMultipleSpeakersNode",
                "inputs": {
                    "text": text,
                    "model": model,
                    "attention_type": "auto",
                    "quantize_llm": quantize_llm,
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


async def _wait_for_completion(
    prompt_id: str,
    ws=None,
    timeout: float = 300,
    on_progress: ProgressCallback = None,
    estimated_secs: float = 30,
) -> str:
    """Monitor ComfyUI via WebSocket for real-time progress. Returns output filename.

    Falls back to HTTP polling if the WebSocket connection fails or wasn't provided.
    """
    if ws:
        try:
            return await _ws_wait_for_completion(prompt_id, ws, timeout, on_progress, estimated_secs)
        except Exception as ws_err:
            log.warning("ComfyUI WS monitor failed (%s), falling back to polling", ws_err)
    return await _poll_until_complete(prompt_id, timeout)


async def _ws_wait_for_completion(
    prompt_id: str,
    ws,
    timeout: float,
    on_progress: ProgressCallback,
    estimated_secs: float = 30,
) -> str:
    """Listen on pre-connected ComfyUI WebSocket for progress and completion events.

    Sends elapsed-time progress updates every 3 seconds since ComfyUI's
    VibeVoice node does not report intermediate diffusion steps.
    """
    t0 = asyncio.get_event_loop().time()
    done = asyncio.Event()
    result: list[str] = []  # holds filename on success
    error: list[Exception] = []  # holds error on failure

    async def _listen():
        async for raw in ws:
            if isinstance(raw, bytes):
                continue
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                continue

            msg_type = msg.get("type")
            data = msg.get("data", {})

            if data.get("prompt_id") != prompt_id:
                continue

            if msg_type == "progress_state":
                nodes = data.get("nodes", {})
                all_finished = nodes and all(
                    n.get("state") == "finished" for n in nodes.values()
                )
                if all_finished:
                    log.info("All nodes finished for prompt %s", prompt_id)
                    try:
                        result.append(await _fetch_output(prompt_id))
                    except Exception as e:
                        error.append(e)
                    done.set()
                    return

            elif msg_type == "progress":
                # Legacy ComfyUI progress with step/max
                elapsed = asyncio.get_event_loop().time() - t0
                if on_progress:
                    on_progress(elapsed, estimated_secs)

            elif msg_type in ("executed", "executing") and (
                msg_type == "executed" or data.get("node") is None
            ):
                try:
                    result.append(await _fetch_output(prompt_id))
                except Exception as e:
                    error.append(e)
                done.set()
                return

            elif msg_type == "execution_error":
                error.append(RuntimeError(
                    f"ComfyUI prompt {prompt_id} failed: {data.get('exception_message', 'unknown error')}"
                ))
                done.set()
                return

        # WS closed without completion
        error.append(RuntimeError(f"ComfyUI WebSocket closed before prompt {prompt_id} completed"))
        done.set()

    async def _tick_progress():
        """Send elapsed-time progress updates every 3 seconds."""
        while not done.is_set():
            await asyncio.sleep(3)
            if done.is_set():
                break
            elapsed = asyncio.get_event_loop().time() - t0
            if on_progress:
                on_progress(elapsed, estimated_secs)

    listener = asyncio.create_task(_listen())
    ticker = asyncio.create_task(_tick_progress())

    try:
        await asyncio.wait_for(done.wait(), timeout=timeout)
    except asyncio.TimeoutError:
        raise TimeoutError(f"ComfyUI prompt {prompt_id} timed out after {timeout}s")
    finally:
        listener.cancel()
        ticker.cancel()

    if error:
        raise error[0]
    return result[0]


async def _fetch_output(prompt_id: str) -> str:
    """Fetch the output filename from ComfyUI history after completion.

    Retries briefly since history may not be populated immediately after
    the WS signals completion.
    """
    for attempt in range(5):
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(f"{cfg.COMFYUI_BASE_URL}/history/{prompt_id}")
            resp.raise_for_status()
            history = resp.json()

        entry = history.get(prompt_id, {})
        status = entry.get("status", {})
        if status.get("status_str") == "error":
            raise RuntimeError(f"ComfyUI prompt {prompt_id} failed")
        outputs = entry.get("outputs", {})
        for node_id, node_out in outputs.items():
            if "audio" in node_out:
                return node_out["audio"][0]["filename"]

        # Outputs not ready yet — wait briefly and retry
        if attempt < 4:
            await asyncio.sleep(0.5)

    raise RuntimeError(f"No audio output found in ComfyUI history for prompt {prompt_id}")


async def _poll_until_complete(prompt_id: str, timeout: float = 300) -> str:
    """Fallback: poll ComfyUI /history until the prompt completes."""
    elapsed = 0.0
    interval = 2.0

    async with httpx.AsyncClient(timeout=30) as client:
        while elapsed < timeout:
            resp = await client.get(f"{cfg.COMFYUI_BASE_URL}/history/{prompt_id}")
            resp.raise_for_status()
            history = resp.json()

            if prompt_id in history:
                entry = history[prompt_id]
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
