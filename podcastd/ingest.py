from __future__ import annotations

import base64
import logging
import re

import httpx
import trafilatura

log = logging.getLogger(__name__)


async def ingest_url(url: str) -> str:
    async with httpx.AsyncClient(follow_redirects=True, timeout=30) as client:
        resp = await client.get(url)
        resp.raise_for_status()
        html = resp.text
    text = trafilatura.extract(html, include_comments=False, include_tables=False)
    if not text:
        raise ValueError(f"Could not extract text from {url}")
    return _clean(text)


def ingest_pdf(pdf_b64: str) -> str:
    import fitz  # pymupdf

    pdf_bytes = base64.b64decode(pdf_b64)
    doc = fitz.open(stream=pdf_bytes, filetype="pdf")
    text = "\n".join(page.get_text() for page in doc)
    doc.close()
    if not text.strip():
        raise ValueError("PDF contained no extractable text")
    return _clean(text)


def ingest_email(raw_text: str, subject: str = "") -> str:
    text = _strip_email_noise(raw_text)
    if subject:
        return f"Subject: {subject}\n\n{text}"
    return text


def _strip_email_noise(text: str) -> str:
    lines = text.splitlines()
    cleaned = []
    for line in lines:
        if re.match(r"^(>|On .+ wrote:|---+\s*$|Sent from|--\s*$)", line.strip()):
            continue
        cleaned.append(line)
    return "\n".join(cleaned).strip()


def _clean(text: str) -> str:
    text = re.sub(r"\n{3,}", "\n\n", text)
    text = re.sub(r"[ \t]+", " ", text)
    return text.strip()
