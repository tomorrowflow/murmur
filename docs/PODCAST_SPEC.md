# Murmur — Interactive Podcast Mode
## Implementation Specification v1.0 · 2026-03

> **For Claude Code.** This document is the authoritative design reference for the Interactive Podcast Mode extension to Murmur. Start with Phase 1 and verify each phase end-to-end before proceeding. All design decisions are documented with rationale — prefer not to deviate without revisiting the spec.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Backend Service — podcastd](#3-backend-service--podcastd)
4. [Script Generator](#4-script-generator)
5. [Audio Generator](#5-audio-generator)
6. [Interrupt Handler](#6-interrupt-handler)
7. [Content Ingest](#7-content-ingest)
8. [Murmur Swift Client](#8-murmur-swift-client)
9. [ComfyUI Workflow Setup](#9-comfyui-workflow-setup)
10. [Latency Budget](#10-latency-budget)
11. [Implementation Order](#11-implementation-order)
12. [Docker Setup](#12-docker-setup)

---

## 1. Overview

Interactive Podcast Mode transforms long-form content (URLs, PDFs, emails) into a two-host AI podcast that the user can interrupt and steer in real time via push-to-talk.

**The core design principle:** the podcast is a living conversation, not a static audio file. The user is a third participant, not a passive listener. After any interruption, the LLM re-evaluates the remaining script in light of what was discussed and may trim, expand, or abandon original content entirely.

### What it is not

- A static text-to-speech reader
- A NotebookLM clone (no forced resume, no fixed structure)
- A chatbot with TTS bolted on (two distinct host voices, natural turn-taking, emergent dynamics)

### Input sources

- URLs (web articles, newsletters)
- PDFs (documents, papers)
- Email bodies (from Murmur's existing email pipeline)

### Key capabilities

- Two fixed AI hosts (Alex + Jordan) with consistent voices across all sessions
- 90-second chunk streaming with background prefetch
- PTT interrupt → LLM-driven contextual response → natural conversation evolution
- Fully self-hosted: ComfyUI + VibeVoice on 3090 GPU server, LLM configurable

---

## 2. Architecture

### 2.1 Component Map

```
┌─────────────────────────────────────────────────────────────────┐
│  macOS (Murmur)                                                 │
│  ┌──────────────────┐   WebSocket (wss://)  ┌────────────────┐  │
│  │ PodcastManager   │ ◄───────────────────► │  podcastd      │  │
│  │  .swift          │                       │  (Python)      │  │
│  └──────┬───────────┘                       └───────┬────────┘  │
│         │                                           │            │
│  ┌──────▼───────────┐                     ┌────────▼────────┐   │
│  │ PodcastOverlay   │                     │  ComfyUI API    │   │
│  │  Window.swift    │                     │  (VibeVoice)    │   │
│  └──────────────────┘                     └────────┬────────┘   │
│                                                    │            │
│  ┌───────────────────┐                   ┌────────▼────────┐   │
│  │ main.swift        │                   │  LLM            │   │
│  │ (PTT mode #3)     │                   │  (Claude/Ollama)│   │
│  └───────────────────┘                   └─────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 Network Topology (Docker)

```
[Murmur on macOS]
      │  wss://podcastd.internal.domain  (Traefik TLS)
      ▼
[Traefik + step-ca]
      │
      ├── proxy network ──► podcastd container (:8765 WS, :8766 HTTP)
      │                          │
      │                    internal network
      │                          │
      └── proxy network ──► comfyui container (:8188)
```

- `internal` network: private bridge, comfyui ↔ podcastd only
- `proxy` network: external, shared with Traefik
- Audio flow: ComfyUI writes to `./data/output` → podcastd mounts same path read-only → serves to Murmur via HTTP

### 2.3 Data Flow — Happy Path

1. User triggers **New Podcast** in Murmur (hotkey or menu). Murmur sends `INGEST` message with content over WebSocket to podcastd.
2. podcastd calls LLM to generate a full podcast script as structured JSON (`[{speaker, text, line_id}]`).
3. podcastd splits script into ~90-second segments. Sends segment 0 to ComfyUI VibeVoice API with locked voice seeds. Returns audio URL to Murmur.
4. Murmur downloads and plays chunk 0. Simultaneously, podcastd pre-generates chunk 1 in the background.
5. User holds PTT key during playback → Murmur pauses audio, records question, transcribes via Parakeet, sends `INTERRUPT` message to podcastd.
6. podcastd sends question + full conversation history to LLM → receives mini-script (~3-6 exchange lines) → renders via VibeVoice → streams audio URL back.
7. Murmur plays interrupt response. Session history updated. Podcast evolves from new context — no forced return to original script.

---

## 3. Backend Service — podcastd

Python asyncio service. Two concurrent servers:
- `:8765` WebSocket — Murmur session control
- `:8766` HTTP — audio file serving (`/audio/<filename>`) + health (`/health`)

### 3.1 File Structure

```
podcastd/
├── main.py                  # Entry point, WebSocket + HTTP servers
├── config.py                # All config from environment variables
├── session.py               # PodcastSession dataclass + SessionState enum
├── script_generator.py      # LLM calls → podcast JSON script
├── audio_generator.py       # ComfyUI VibeVoice API wrapper
├── chunk_manager.py         # Script splitting + prefetch queue
├── interrupt_handler.py     # Interrupt → LLM → mini-script → audio
├── ingest.py                # URL fetch, PDF extract, email parse
├── prompts/
│   ├── script_system.txt    # System prompt for full script generation
│   └── interrupt_system.txt # System prompt for interrupt handling
├── tools/
│   └── calibrate.py         # One-time voice seed calibration helper
├── Dockerfile
├── requirements.txt
└── .env.example
```

### 3.2 WebSocket Protocol

All messages are JSON with a `type` field.

#### Client → Server (Murmur → podcastd)

| Type | Payload | Purpose |
|------|---------|---------|
| `INGEST` | `{content_type, content, subject?, web_search?, model?}` | Start new session |
| `NEXT_CHUNK` | `{session_id}` | Request next audio chunk |
| `INTERRUPT` | `{session_id, question}` | User interrupted with voice question |
| `STOP` | `{session_id}` | End session, clean up audio files |
| `PING` | `{}` | Keepalive |

#### Server → Client (podcastd → Murmur)

| Type | Payload | Purpose |
|------|---------|---------|
| `SESSION_CREATED` | `{session_id, title, total_chunks}` | Script ready |
| `CHUNK_READY` | `{session_id, chunk_index, audio_url, transcript}` | Audio chunk available |
| `INTERRUPT_PROCESSING` | `{session_id, state: "processing"}` | Working on interrupt |
| `INTERRUPT_READY` | `{session_id, audio_url, transcript}` | Interrupt response ready |
| `SCRIPT_UPDATED` | `{session_id, remaining_chunks}` | LLM revised remaining script |
| `PROGRESS` | `{session_id, stage, percent, message}` | Generation progress update |
| `ERROR` | `{code, message}` | Error with details |
| `PONG` | `{}` | Keepalive reply |

### 3.2.1 Payload Format Notes (Server Implementation)

> **Important for podcastd implementation.** The Murmur client parses these fields exactly as documented below. Deviations will cause silent failures.

**`INGEST`** — `content_type` values the client sends:
- `"url"` — when the selected text starts with `http`
- `"text"` — all other selected text (articles, email bodies, etc.)
- `"pdf"` — future: base64-encoded PDF bytes (Phase 5)

**`INGEST`** — `web_search` (boolean, optional, default `false`):
- When `true`, interrupt questions are enriched with live web search results via the Ollama Web Search API before being sent to the LLM. This lets the hosts reference current facts, data, and sources when answering the listener's question.
- When `false` or omitted, interrupt responses are generated purely from the original content and conversation context.
- Controlled by the user via a toggle in the Podcast settings UI or per-session in the podcast start dialog.
- Requires `OLLAMA_API_KEY` to be set in the podcastd `.env` file (free key from https://ollama.com/settings/keys).

**`CHUNK_READY` and `INTERRUPT_READY`** — the `transcript` field must be an array of objects:
```json
{
  "transcript": [
    {"speaker": "Alex", "text": "The feedback loop is the key insight."},
    {"speaker": "Jordan", "text": "Wait, are you saying it compounds?"}
  ]
}
```
The client uses `speaker` and `text` fields to render the overlay transcript. Missing or malformed `transcript` is tolerated (audio still plays) but the overlay will show no text.

**`CHUNK_READY`** — the `audio_url` field can be:
- A full URL (`https://podcastd.internal.domain/audio/chunk_0.wav`) — used as-is
- A bare filename (`chunk_0.wav`) — the client prepends `{audioBaseURL}/audio/`

**`SESSION_CREATED`** — `total_chunks` is used for progress tracking. If the script is revised after an interrupt, send `SCRIPT_UPDATED` with the new `remaining_chunks` count so the client updates its total.

**`INGEST`** — `model` (string, optional, default `"large-q4"`):
- Selects the VibeVoice model preset for audio generation. Valid values:

| Preset Key | ComfyUI Model | Quantization | VRAM | Use Case |
|---|---|---|---|---|
| `large-fp` | `VibeVoice-Large` | Full precision | ~17 GB | Best quality, slowest |
| `large-q4` | `VibeVoice-Large` | Q4 (LLM only) | ~8 GB | Good quality, moderate speed |
| `1.5b-fp` | `VibeVoice-1.5B` | Full precision | ~6 GB | Good quality, faster |
| `1.5b-q4` | `VibeVoice-1.5B` | Q4 (LLM only) | ~4 GB | Fast, lowest VRAM |

- Server-side `MODEL_MAP` should map these keys to `(model_name, quantize_llm)` tuples for the ComfyUI workflow.
- If the key is not recognized, fall back to the server's default model config.

**`PROGRESS`** — real-time generation progress updates:
```json
{
  "type": "PROGRESS",
  "session_id": "...",
  "stage": "scripting",
  "percent": -1,
  "message": "Generating script..."
}
```
- `stage`: one of `"scripting"`, `"audio_generating"`, `"downloading"`
- `percent`: `-1` = indeterminate (client shows spinner), `0-100` = determinate (client shows progress bar)
- `message`: human-readable status string displayed in the overlay
- Server should emit PROGRESS before each major operation (LLM call, ComfyUI generation, etc.)

**`ERROR`** — include a `code` field for programmatic handling. Suggested codes:
- `INGEST_FAILED` — content fetch/parse failed
- `LLM_ERROR` — script generation failed
- `AUDIO_ERROR` — ComfyUI/VibeVoice failed
- `SESSION_NOT_FOUND` — invalid session_id

### 3.3 Session State Machine

```
IDLE         --[INGEST]----------→  INGESTING
INGESTING    --[done]------------→  SCRIPTING
SCRIPTING    --[done]------------→  GENERATING
GENERATING   --[chunk_0_ready]---→  READY
READY        --[NEXT_CHUNK]------→  PLAYING
PLAYING      --[NEXT_CHUNK]------→  PLAYING      (prefetch already done)
PLAYING      --[INTERRUPT]-------→  INTERRUPTED
INTERRUPTED  --[llm_done]--------→  INTERRUPT_READY
INTERRUPT_READY --[rendered]-----→  EVOLVING
EVOLVING     --[done]------------→  PLAYING
PLAYING      --[no more chunks]--→  COMPLETE
* → ERROR    (any unrecoverable failure)
```

### 3.4 config.py

```python
class Config:
    # ComfyUI
    COMFYUI_BASE_URL:    str = os.getenv("COMFYUI_BASE_URL", "http://comfyui:8188")
    VIBEVOICE_WORKFLOW:  str = os.getenv("VIBEVOICE_WORKFLOW", "vibevoice_podcast.json")

    # Audio
    AUDIO_CACHE_DIR:     str = os.getenv("AUDIO_CACHE_DIR", "/comfyui_output")

    # Servers
    WS_HOST:   str = os.getenv("WS_HOST", "0.0.0.0")
    WS_PORT:   int = int(os.getenv("WS_PORT", "8765"))
    HTTP_HOST: str = os.getenv("HTTP_HOST", "0.0.0.0")
    HTTP_PORT: int = int(os.getenv("HTTP_PORT", "8766"))

    # Voice — calibrate once, never change
    VOICE_SEED_A:  int = int(os.getenv("VOICE_SEED_A", "42"))
    VOICE_SEED_B:  int = int(os.getenv("VOICE_SEED_B", "137"))
    HOST_A_NAME:   str = os.getenv("HOST_A_NAME", "Alex")
    HOST_B_NAME:   str = os.getenv("HOST_B_NAME", "Jordan")

    # VibeVoice models
    CHUNK_MODEL:     str = os.getenv("CHUNK_MODEL", "Large")    # quality
    INTERRUPT_MODEL: str = os.getenv("INTERRUPT_MODEL", "1.5B") # latency

    # LLM
    LLM_PROVIDER:    str = os.getenv("LLM_PROVIDER", "anthropic")
    LLM_MODEL:       str = os.getenv("LLM_MODEL", "claude-sonnet-4-20250514")
    LLM_API_KEY:     str = os.getenv("LLM_API_KEY", "")
    OLLAMA_BASE_URL: str = os.getenv("OLLAMA_BASE_URL", "http://ollama:11434")

    # Tuning
    CHUNK_TARGET_WORDS:  int = int(os.getenv("CHUNK_TARGET_WORDS", "210"))
    INTERRUPT_MAX_TURNS: int = int(os.getenv("INTERRUPT_MAX_TURNS", "6"))
```

---

## 4. Script Generator

### 4.1 System Prompt (`prompts/script_system.txt`)

> **Tuning lever:** This prompt is the single most important variable for output quality. Iterate on it to control pace, depth, naturalness of host interruptions, and whether hosts disagree.

```
You are a podcast scriptwriter for a two-host show called 'Deep Read'.

Hosts:
- {HOST_A_NAME}: the explainer. Analytical, leads topic introductions, uses vivid
  analogies. Occasionally goes on tangents that {HOST_B_NAME} reins in.
- {HOST_B_NAME}: the curious questioner. Enthusiastic, asks 'but wait—' follow-ups,
  expresses genuine surprise or confusion. Makes the listener feel represented.

Given the provided source content, generate a natural, engaging podcast dialogue.

Rules:
- Output ONLY valid JSON — an array of objects:
  [{"speaker": "Alex", "text": "...", "line_id": 0}, ...]
- Each object is one spoken turn. Keep turns under 60 words for natural pacing.
- Do NOT include stage directions, music cues, or metadata.
- Include natural interruptions: {HOST_B_NAME} can cut in mid-thought with 'Wait—'.
- Hosts occasionally disagree or nuance each other's points.
- Open with an engaging hook, not 'Welcome to our podcast'.
- Target approximately {target_duration_minutes} minutes of speech.
- Do not summarize — synthesize. Bring in analogies and implications not in the source.
```

### 4.2 Output Schema

```json
[
  {
    "speaker": "Alex",
    "text": "The thing that makes this counterintuitive is the feedback loop.",
    "line_id": 0
  },
  {
    "speaker": "Jordan",
    "text": "Wait — are you saying the effect is self-reinforcing?",
    "line_id": 1
  }
]
```

### 4.3 Chunk Splitting (`chunk_manager.py`)

Target ~90 seconds of speech. Estimate: 140 words/minute → 210 words per chunk.

```python
def split_into_chunks(script: list[dict], target_words: int = 210) -> list[list[dict]]:
    chunks, current, count = [], [], 0
    for line in script:
        word_count = len(line['text'].split())
        if count + word_count > target_words and current:
            chunks.append(current)
            current, count = [], 0
        current.append(line)
        count += word_count
    if current:
        chunks.append(current)
    return chunks
```

---

## 5. Audio Generator

### 5.1 Script Formatting for VibeVoice

```python
def format_for_vibevoice(chunk: list[dict]) -> str:
    lines = []
    for turn in chunk:
        tag = '[1]' if turn['speaker'] == cfg.HOST_A_NAME else '[2]'
        lines.append(f"{tag} {turn['text']}")
    return '\n'.join(lines)

# Example output:
# [1] The thing that makes this counterintuitive is the feedback loop.
# [2] Wait — are you saying the effect is self-reinforcing?
# [1] Exactly. And that's where most analyses stop.
```

### 5.2 ComfyUI Workflow Fields

Key fields substituted per generation call:

```python
workflow['VibeVoiceTTS']['inputs']['text']              = formatted_script_text
workflow['VibeVoiceTTS']['inputs']['seed']              = cfg.VOICE_SEED_A  # locks voices
workflow['VibeVoiceTTS']['inputs']['model_name']        = model  # '1.5B' or 'Large'
workflow['VibeVoiceTTS']['inputs']['quantize_llm_4bit'] = True
workflow['VibeVoiceTTS']['inputs']['attention_mode']    = 'sdpa'
workflow['VibeVoiceTTS']['inputs']['cfg_scale']         = 1.3
workflow['VibeVoiceTTS']['inputs']['inference_steps']   = 10

# Leave speaker voice inputs empty → zero-shot mode (voice locked by seed)
workflow['VibeVoiceTTS']['inputs']['speaker_1_voice']   = None
workflow['VibeVoiceTTS']['inputs']['speaker_2_voice']   = None
```

### 5.3 ComfyUI API Polling

```python
async def generate_audio(script_text: str, seed: int, model: str) -> str:
    # 1. POST workflow to /prompt
    prompt_id = await post_workflow(script_text, seed, model)

    # 2. Poll /history/{prompt_id} until complete
    while True:
        history = await get(f'/history/{prompt_id}')
        if prompt_id in history:
            outputs = history[prompt_id]['outputs']
            filename = outputs['SaveAudio']['audio'][0]['filename']
            return filename   # available at GET /view?filename={filename}
        await asyncio.sleep(2)
```

Audio is written by ComfyUI to `./data/output/` (mapped as `/comfyui_output` in podcastd). podcastd serves it directly — no copying.

### 5.4 VRAM Budget (3090 — 24 GB)

| Component | VRAM | Notes |
|-----------|------|-------|
| VibeVoice-1.5B (4-bit, sdpa) | ~4 GB | Fast — use for interrupt responses |
| VibeVoice-Large/7B (4-bit, sdpa) | ~6-8 GB | Better quality — use for main chunks |
| LLM via Ollama (Qwen2.5-14B Q4) | ~9 GB | If running LLM locally |
| Headroom | ~6 GB | OS + ComfyUI + buffers |

---

## 6. Interrupt Handler

### 6.1 Context Passed to LLM

```python
context = {
    'original_topic':    session.title,
    'full_original':     session.original_script,
    'delivered_so_far':  session.delivered_lines,
    'pending_script':    session.remaining_chunks_flat(),
    'prior_interrupts':  session.interrupt_history,
    'user_question':     question,
}
```

### 6.2 Interrupt System Prompt (`prompts/interrupt_system.txt`)

```
You are managing a live two-host podcast. The listener has just interrupted with a question.

Hosts:
- {HOST_A_NAME} (speaker [1]): analytical explainer, leads responses to complex questions
- {HOST_B_NAME} (speaker [2]): curious questioner, voices follow-ups and reactions

You will be given:
- The original topic and script
- Everything said so far (including any prior listener questions)
- The remaining planned content
- The listener's new question

Your tasks:
1. Generate a natural podcast exchange (3-8 turns) where the hosts address the
   listener's question. The response should feel like the hosts noticed the question
   mid-conversation and are naturally pivoting to answer it.

2. After the response exchange, revise the REMAINING SCRIPT to reflect this new
   direction. Do not force a return to topics already covered. Let the conversation
   evolve naturally. You may trim, expand, reorder, or fully replace remaining content.

Output ONLY valid JSON:
{
  "interrupt_response": [{"speaker": "Alex"|"Jordan", "text": "..."}],
  "revised_remaining":  [{"speaker": "Alex"|"Jordan", "text": "..."}]
}

Tone: hosts should feel genuinely engaged by the question.
{HOST_B_NAME} may say: "Oh that's actually what I was wondering too—"
{HOST_A_NAME} may say: "Great question — let me reframe what I was saying..."
```

### 6.3 Host Selection

> **Do NOT add explicit host-selection logic in code.** Let the LLM handle it contextually via the system prompt. Hard-coded rules feel mechanical. Alex defaults to leading analytical responses; Jordan leads if the question is about their recent reaction. The LLM decides based on conversational flow.

### 6.4 Script Splice After Interrupt

```python
# Replace remaining undelivered chunks with LLM-revised content
remaining_start = session.remaining_chunk_index
revised = result["revised_remaining"]
new_chunks = ChunkManager(cfg).split(revised)

session.chunks = session.chunks[:remaining_start] + new_chunks
session.chunk_audio_paths = {
    k: v for k, v in session.chunk_audio_paths.items()
    if k < remaining_start
}
```

---

## 7. Content Ingest

### 7.1 URL

```python
# Dependencies: httpx, trafilatura
async def ingest_url(url: str) -> str:
    html = await fetch_html(url)
    text = trafilatura.extract(html, include_comments=False, include_tables=False)
    return clean_text(text)
```

### 7.2 PDF

```python
# Dependencies: pymupdf (fitz)
# PDF bytes arrive as base64 in the INGEST WebSocket message
def ingest_pdf(pdf_bytes: bytes) -> str:
    doc = fitz.open(stream=pdf_bytes, filetype='pdf')
    return clean_text('\n'.join(page.get_text() for page in doc))
```

### 7.3 Email

```python
# Email body arrives as plain text (already available in Murmur's email pipeline)
def ingest_email(raw_text: str, subject: str = '') -> str:
    text = strip_email_noise(raw_text)  # strip quotes, signatures, forward headers
    return f'Subject: {subject}\n\n{text}' if subject else text
```

---

## 8. Murmur Swift Client

> Follow existing patterns throughout. `PodcastManager` mirrors `OpenClawManager`. `PodcastOverlayWindow` mirrors `OpenClawOverlayWindow`. Reuse `AudioTranscriptionManager` for PTT recording/transcription.

### 8.1 New Files

| File | Location | Description |
|------|----------|-------------|
| `PodcastManager.swift` | `Sources/` | WebSocket client, audio download + playback |
| `PodcastOverlayWindow.swift` | `Sources/` | Floating overlay UI |

### 8.2 Modified Files

| File | Change |
|------|--------|
| `main.swift` | Add PTT mode #3 (podcast interrupt), `Cmd+Opt+P` shortcut |
| `UnifiedManagerWindow.swift` | Add Podcast settings tab |

### 8.3 PodcastManager.swift — Key State

```swift
class PodcastManager: NSObject {
    var sessionId: String?
    var currentChunkIndex: Int = 0
    var state: PodcastState = .idle
    var currentTranscript: [ScriptLine] = []   // for overlay display
    var prefetchedAudioURL: URL?               // next chunk, pre-downloaded
    var player: AVAudioPlayer?

    enum PodcastState {
        case idle, connecting, ingesting, buffering
        case playing, interrupted, processingInterrupt
        case complete, error(String)
    }
}
```

### 8.4 Audio Prefetch Pattern

```swift
// When chunk N starts playing → request chunk N+1 from server
func onChunkStartedPlaying(chunkIndex: Int) {
    sendMessage(.nextChunk(sessionId: sessionId!))
}

// CHUNK_READY arrives for N+1 while N still plays → download in background
func onChunkReady(audioURL: String) {
    Task {
        prefetchedAudioURL = await downloadAudio(from: audioURL)
    }
}

// Chunk N finishes → play N+1 instantly (already downloaded)
func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully: Bool) {
    guard let next = prefetchedAudioURL else { return bufferAndWait() }
    playAudio(from: next)
    prefetchedAudioURL = nil
}
```

### 8.5 PTT Mode #3

```swift
// Recommended hotkey mapping:
// Cmd+Opt+P                    → start/stop podcast session (new shortcut)
// Right Option double-tap-hold → STT (unchanged)
// Left Option double-tap-hold  → podcast interrupt (when session active)
//                              → OpenClaw PTT (when no active podcast session)

func startPodcastInterrupt() {
    podcastManager.pausePlayback()
    // Reuse existing AudioTranscriptionManager for recording
    // On PTT release → Parakeet transcription → send INTERRUPT to podcastd
}
```

### 8.6 PodcastOverlayWindow

Floating non-activating panel (same as `OpenClawOverlayWindow`). Shows:

- Podcast title / current topic
- Active speaker name (Alex / Jordan) with animated speaking indicator
- Scrolling transcript (3-4 lines visible)
- State badge: `PLAYING` / `INTERRUPTED` / `BUFFERING` / `PROCESSING`
- PTT hint at bottom

> Reuse `OpenClawOverlayWindow.swift` as template. Keep floating panel, vibrancy, dismiss-on-Escape.

### 8.7 Podcast Settings Tab

| Setting | Default | Description |
|---------|---------|-------------|
| podcastd URL | `wss://podcastd.internal.domain` | WebSocket address |
| Audio base URL | `https://podcastd.internal.domain` | HTTP audio fetch base |
| Host A name | Alex | Display name in overlay |
| Host B name | Jordan | Display name in overlay |
| Interrupt PTT key | Left Option | Configurable |

### 8.8 Interrupt Audio Tone

Extend `PTTTonePlayer` with an "interrupt received" tone — plays immediately on PTT release to signal the question was captured, before the ~15-25 second processing wait. Makes the latency feel intentional.

---

## 9. ComfyUI Workflow Setup

### 9.1 Install ComfyUI-VibeVoice Node

1. ComfyUI Manager → Install Custom Nodes → search `ComfyUI-VibeVoice` → Install
2. Restart ComfyUI
3. Node appears under `audio/tts` category
4. First run auto-downloads VibeVoice-1.5B to `ComfyUI/models/tts/VibeVoice/`
5. Also download VibeVoice-Large: `huggingface.co/aoi-ot/VibeVoice-Large`

Repo: [wildminder/ComfyUI-VibeVoice](https://github.com/wildminder/ComfyUI-VibeVoice)

### 9.2 Voice Calibration (one-time)

Run once before connecting Murmur. Locks the two host voices permanently.

```bash
docker compose exec podcastd python tools/calibrate.py
```

The calibration script generates 10 test clips with this script at different seeds:

```
[1] Hello, I'm Alex. I'll be your guide through today's topic.
[2] And I'm Jordan — I'll be asking the questions you're probably thinking.
[1] Let's start with why this actually matters in practice.
[2] Wait — before you go there, can you give me the one-sentence version?
```

Listen to all clips, pick the two seeds you like, set `VOICE_SEED_A` and `VOICE_SEED_B` in `.env`, restart podcastd. All future generations use these seeds — consistent voice identity across every session.

---

## 10. Latency Budget

### Session Start (INGEST → first audio playing)

| Step | Time | Notes |
|------|------|-------|
| Content fetch/parse | 1-3s | httpx + trafilatura/fitz |
| LLM script generation | 5-15s | Claude Sonnet, ~2000 token output |
| Chunk 0 VibeVoice (Large, 4-bit) | 15-30s | 3090, sdpa |
| Audio download Murmur ← podcastd | < 1s | Local network |
| **Total** | **~25-50s** | Acceptable for deep read mode |

### Interrupt Response (PTT release → audio playing)

| Step | Time | Notes |
|------|------|-------|
| Parakeet STT | < 1s | ~110x realtime |
| WebSocket round-trip | < 0.1s | Local network |
| LLM interrupt response | 3-6s | Claude Sonnet, ~300 token output |
| VibeVoice-1.5B render (~30s audio) | 10-20s | 3090, sdpa, 4-bit |
| Audio download + buffer | < 1s | |
| **Total** | **~15-28s** | Feels like hosts "thinking" |

> The 15-28 second wait is acceptable because: (1) the interrupt tone plays immediately on PTT release, (2) the pause feels like the hosts are genuinely considering the question, (3) it's analogous to a radio producer putting a caller on hold.

---

## 11. Implementation Order

### Phase 1 — Backend Core (no Murmur changes yet)

1. Scaffold `podcastd/` directory and `requirements.txt`
2. Implement `config.py` and `session.py`
3. Implement `ingest.py` (URL + email first, PDF in Phase 5)
4. Implement `script_generator.py` with LLM API
5. Implement `audio_generator.py` — ComfyUI API polling
6. Implement `chunk_manager.py` — split and prefetch logic
7. Implement WebSocket + HTTP servers in `main.py` — `INGEST → SESSION_CREATED → CHUNK_READY` flow
8. **Test:** feed a URL via wscat, receive audio URL, fetch audio, play with VLC

### Phase 2 — Interrupt Handler

1. Implement `interrupt_handler.py` — context building + LLM call + script splice
2. Wire `INTERRUPT` message type into `main.py`
3. **Test:** simulate interrupt via Python test client, verify `revised_remaining` is coherent

### Phase 3 — Murmur Swift Integration

1. Add `PodcastManager.swift` — WebSocket client, audio download + `AVAudioPlayer`
2. Add `PodcastOverlayWindow.swift` — floating UI
3. Add Podcast tab to `UnifiedManagerWindow.swift`
4. Wire `Cmd+Opt+P` shortcut in `main.swift`
5. **Test:** trigger podcast from Murmur, hear audio, verify overlay

### Phase 4 — PTT Interrupt in Murmur

1. Extend PTT state machine: Left Option double-tap-hold = podcast interrupt when session active
2. Wire: PTT release → Parakeet → `INTERRUPT` message
3. Handle `INTERRUPT_PROCESSING` state in overlay
4. Handle `INTERRUPT_READY`: pause → play response → continue
5. Add interrupt received tone to `PTTTonePlayer`
6. **Test:** full end-to-end interrupt cycle

### Phase 5 — Polish

1. PDF ingest (base64 bytes in `INGEST` message)
2. `tools/calibrate.py` voice calibration helper
3. Error handling: ComfyUI timeout, LLM failure, WebSocket reconnect
4. `STOP` message cleanup — delete temp audio files
5. Session persistence — save/restore session JSON for resume after restart

---

## 12. Docker Setup

See `docker-compose.yml` in repo root for the full ComfyUI + podcastd stack.

### Quick start

```bash
# 1. Copy and fill in env
cp .env.example .env
$EDITOR .env   # set INTERNAL_DOMAIN, LLM_API_KEY

# 2. Start stack
docker compose up -d

# 3. Check health
curl https://podcastd.internal.yourdomain.com/health
# → {"status": "ok", "sessions": 0}

# 4. Calibrate voices (one-time)
docker compose exec podcastd python tools/calibrate.py
# → listen to clips, set VOICE_SEED_A / VOICE_SEED_B in .env
# → docker compose restart podcastd
```

### Testing without Murmur

```bash
npm install -g wscat
wscat -c wss://podcastd.internal.yourdomain.com

# Send:
{"type":"INGEST","content_type":"url","content":"https://example.com/article"}

# Receive SESSION_CREATED, then send:
{"type":"NEXT_CHUNK","session_id":"<id from above>"}

# Receive CHUNK_READY with audio_url, fetch:
curl https://podcastd.internal.yourdomain.com/audio/<filename> -o test.wav
```

### Murmur connection settings

| Setting | Value |
|---------|-------|
| podcastd URL | `wss://podcastd.internal.yourdomain.com` |
| Audio base URL | `https://podcastd.internal.yourdomain.com` |

---

## Appendix: requirements.txt

```
websockets>=12.0
aiohttp>=3.10.0
httpx>=0.27.0
trafilatura>=1.12.0
pymupdf>=1.24.0
anthropic>=0.30.0
openai>=1.40.0
python-dotenv>=1.0.0
pydantic>=2.7.0
aiofiles>=24.0.0
```
