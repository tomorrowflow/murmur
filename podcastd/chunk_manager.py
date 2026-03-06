from __future__ import annotations

from config import cfg


def split_into_chunks(script: list[dict], target_words: int | None = None) -> list[list[dict]]:
    target = target_words or cfg.CHUNK_TARGET_WORDS
    chunks: list[list[dict]] = []
    current: list[dict] = []
    count = 0

    for line in script:
        word_count = len(line["text"].split())
        if count + word_count > target and current:
            chunks.append(current)
            current, count = [], 0
        current.append(line)
        count += word_count

    if current:
        chunks.append(current)

    return chunks
