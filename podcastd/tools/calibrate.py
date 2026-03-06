#!/usr/bin/env python3
"""Voice seed calibration tool.

Generates test clips at different seeds so you can pick the best
voice pair for Alex and Jordan. Run inside the podcastd container:

    docker compose exec podcastd python tools/calibrate.py
"""
from __future__ import annotations

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from audio_generator import generate_audio
from config import cfg

TEST_SCRIPT = [
    {"speaker": cfg.HOST_A_NAME, "text": "Hello, I'm Alex. I'll be your guide through today's topic."},
    {"speaker": cfg.HOST_B_NAME, "text": "And I'm Jordan — I'll be asking the questions you're probably thinking."},
    {"speaker": cfg.HOST_A_NAME, "text": "Let's start with why this actually matters in practice."},
    {"speaker": cfg.HOST_B_NAME, "text": "Wait — before you go there, can you give me the one-sentence version?"},
]

SEEDS = [42, 137, 256, 512, 777, 1024, 1337, 2048, 3141, 4096]


async def main():
    print(f"Generating {len(SEEDS)} test clips...")
    print(f"ComfyUI: {cfg.COMFYUI_BASE_URL}")
    print(f"Model: {cfg.CHUNK_MODEL}")
    print()

    for seed in SEEDS:
        print(f"  Seed {seed:5d} ... ", end="", flush=True)
        try:
            filename = await generate_audio(TEST_SCRIPT, seed=seed, model=cfg.CHUNK_MODEL)
            print(f"done → {filename}")
        except Exception as e:
            print(f"FAILED: {e}")

    print()
    print("Listen to the clips, then set VOICE_SEED_A and VOICE_SEED_B in .env")
    print("Restart podcastd after changing seeds.")


if __name__ == "__main__":
    asyncio.run(main())
