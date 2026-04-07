# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Development build and run
swift build && swift run Murmur

# Production app bundle
./build.sh
cp -R build/Murmur.app /Applications/

# Run a specific test/tool executable
swift run TestSentenceSplitter
swift run TestStreamingTTS
swift run ListModels
```

There are no unit test suites — tests are standalone executables in `tests/` run via `swift run <Name>`.

## Background Process Management

- Run the app in background using `swift build && swift run Murmur` with `run_in_background: true`
- Only kill and restart when code changes require a fresh build
- The user prefers to keep the app running for continuous testing

## Git Commit Guidelines

- Never include Claude attribution or Co-Author information in git commits
- Keep commit messages clean and professional without AI-related references

## Architecture

**Swift Package Manager project** (Swift 5.9+, macOS 14.0+) — a menu bar app, not a standard windowed app.

### Two-target layout

- **`Sources/`** — Main app target (`Murmur`). Entry point is `main.swift` which sets up the NSApplication delegate, registers global hotkeys, manages push-to-talk state machine, and wires overlay windows.
- **`SharedSources/`** — Library target (`SharedModels`). Reusable components shared between the main app and test/tool executables: transcription engines, TTS players, audio utilities.

### Key patterns

- **Manager + OverlayWindow pairs**: Each feature has a manager (business logic, WebSocket, audio) and a companion overlay window (SwiftUI-in-NSWindow floating UI). Examples: `OpenClawManager` + `OpenClawOverlayWindow`, `PodcastManager` + `PodcastOverlayWindow`.
- **Push-to-talk state machine**: Double-tap detection for Option keys, implemented in `main.swift`. Right Option → STT, Left Option → OpenClaw. Two modes: **hold mode** (double-tap and keep holding, release to stop) and **toggle mode** (double-tap and release quickly, tap again to stop). The 0.3s hold threshold distinguishes the two. STT PTT captures the frontmost window (via AXUIElement) at recording start and pastes into that window even if the user switches away during transcription/LLM processing.
- **Prompt refinement**: Optional Ollama-based cleanup of transcribed text (removes filler words, fixes punctuation) before pasting. Only runs for recordings longer than 5 seconds. Uses the LLM configured in Read Aloud settings. Toggle in Shortcuts settings.
- **Engine routing**: `AudioTranscriptionManager` routes between Parakeet (FluidAudio), WhisperKit, and Gemini (cloud fallback) based on user settings and transcription results.
- **Environment**: `.env` file at project root parsed at startup for `GEMINI_API_KEY` and other secrets.

### Keyboard shortcuts

| Shortcut | Action |
|---|---|
| Cmd+Opt+C | Start/stop STT recording |
| Cmd+Opt+S | Read selected text aloud / stop TTS |
| Cmd+Opt+O | Start/stop OpenClaw voice recording |
| Cmd+Opt+A | Show transcription history |
| Cmd+Opt+V | Paste last transcription at cursor |

### Dependencies

| Package | Purpose |
|---|---|
| KeyboardShortcuts (1.8.0) | Global hotkey handling |
| WhisperKit (0.13.0+) | Local speech-to-text |
| FluidAudio (0.13.6+) | Parakeet STT + Kokoro TTS |

## Podcast Mode

Interactive podcast feature. Full spec: `docs/PODCAST_SPEC.md`

- **Backend**: `podcastd/` — Python asyncio WebSocket service (runs on GPU server alongside ComfyUI)
  - Docker deployment via `podcastd/docker-compose.yml` (podcastd + traefik)
  - TTS via ComfyUI + VibeVoice node on 3090 GPU
  - LLM script generation with system prompts in `podcastd/prompts/`
- **Frontend**: `Sources/PodcastManager.swift` + `Sources/PodcastOverlayWindow.swift`
- **Protocol**: All WebSocket messages are JSON with a `type` field — see spec §3.2
- Voice seeds are fixed after calibration — never randomise in production
- Host selection on interrupts is handled by the LLM, not by code — see spec §6.3
- Test podcastd without Murmur: `wscat -c wss://podcastd.internal.domain` — see spec §12
