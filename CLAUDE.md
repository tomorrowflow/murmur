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

- **Manager + OverlayWindow pairs**: Each feature has a manager (business logic, WebSocket, audio) and a companion overlay window (SwiftUI-in-NSWindow floating UI). Examples: `OpenClawManager` + `OpenClawOverlayWindow`, `PodcastManager` + `PodcastOverlayWindow`, `DraftEditingManager` + `DraftEditingOverlayWindow`.
- **Push-to-talk state machine**: Double-tap detection for Option keys, implemented in `main.swift`. Right Option → STT, Left Option → OpenClaw/Draft Edit/Read Aloud interrupt (priority: podcast > draft edit > read-aloud > OpenClaw). Two modes: **hold mode** (double-tap and keep holding, release to stop) and **toggle mode** (double-tap and release quickly, tap again to stop). The 0.3s hold threshold distinguishes the two. STT PTT captures the frontmost window (via AXUIElement) at recording start and pastes into that window even if the user switches away during transcription/LLM processing.
- **Prompt refinement**: Optional Ollama-based cleanup of transcribed text (removes filler words, fixes punctuation) before pasting. Only runs for recordings longer than 5 seconds. Uses the LLM configured in Read Aloud settings. Toggle in Shortcuts settings.
- **Engine routing**: `AudioTranscriptionManager` routes between Parakeet (FluidAudio), WhisperKit, and Gemini (cloud fallback) based on user settings and transcription results.
- **Local HTTP server**: `MurmurHTTPServer` runs on `127.0.0.1:7878` using `Network.framework` (`NWListener`). Provides editor-agnostic REST API for draft editing session control. Started in `applicationDidFinishLaunching`.
- **Environment**: `.env` file at project root parsed at startup for `GEMINI_API_KEY` and other secrets.

### Keyboard shortcuts

| Shortcut | Action |
|---|---|
| Cmd+Opt+C | Start/stop STT recording |
| Cmd+Opt+S | Read selected text aloud / stop TTS |
| Cmd+Opt+O | Start/stop OpenClaw voice recording |
| Cmd+Opt+A | Show transcription history |
| Cmd+Opt+V | Paste last transcription at cursor |
| Cmd+Opt+D | Toggle draft editing mode (TextMate integration) |

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

## Draft Editing Mode

Voice-driven writing assistant for markdown documents, integrated with TextMate.

### Overview

Read markdown documents paragraph-by-paragraph with structured TTS, then edit paragraphs via spoken LLM instructions. Changes are written back to the file in real-time.

### Architecture

- **Manager**: `Sources/DraftEditingManager.swift` — session state machine, paragraph TTS orchestration, LLM edit flow, Escape key handling, audio export
- **Overlay**: `Sources/DraftEditingOverlayWindow.swift` — SwiftUI overlay with paragraph view, edit preview, edit history, audio export button
- **HTTP Server**: `Sources/MurmurHTTPServer.swift` — local REST API on `127.0.0.1:7878` for editor integration
- **Markdown Parser**: `Sources/MarkdownParagraphParser.swift` — splits markdown into paragraphs with line ranges and kind detection (heading, body, code, list, blockquote, table, horizontal rule, HTML comment, front matter)
- **TTS Renderer**: `Sources/MarkdownTTSRenderer.swift` — converts paragraphs to TTS segments with structural cues prepended to content ("Section: Title", "List: item", "Quote: text", "Table: cells"), calibrated silence gaps, and per-kind speed control
- **Editor Adapter**: `Sources/EditorAdapter.swift` — protocol + `TextMateAdapter` implementation. Uses `lsof`/window title parsing for file discovery, AXUIElement for cursor position detection, `mate -l` for paragraph highlighting, `txmt://` URL scheme for navigation
- **File Editor**: `Sources/FileEditController.swift` — atomic paragraph replacement with modification date safety checks
- **TextMate Bundle**: `Murmur.tmbundle/` — installed at `~/Library/Application Support/TextMate/Bundles/`. Includes injection grammar for persistent paragraph highlighting via zero-width space markers + `markup.inserted` scope

### Key behaviors

- **Cmd+Opt+D** toggles draft editing. Reads cursor position from TextMate via Accessibility API and starts from that paragraph.
- **Double-tap Left Option** during a session starts voice edit: STT records instruction → Ollama rewrites paragraph → file updated atomically → TextMate reloads
- **Escape key** stops the session and cleans up highlight markers
- Highlights clear from the file before edits are applied (prevents merge conflicts with TextMate's change detection)
- Paragraph types skipped during reading: front matter, HTML comments (`<!-- -->`), horizontal rules (`---`)
- Tables: separator rows stripped, cell `|` separators converted to periods for natural sentence breaks
- Audio segments collected for WAV export via overlay download button

### Obsidian integration

The same draft editing mode works with Obsidian via a companion plugin:

- **Murmur Bridge plugin** (`murmur-obsidian-plugin/`): Minimal Obsidian plugin (~120 lines TypeScript) that runs an HTTP server on `127.0.0.1:27125`. Exposes cursor position, CodeMirror 6 line decorations for highlighting (no file modification), and line navigation.
- **ObsidianAdapter** in `Sources/EditorAdapter.swift`: Implements `EditorAdapter` protocol by calling the companion plugin's HTTP endpoints.
- **Auto-detection**: `Cmd+Opt+D` checks TextMate first, then Obsidian. Uses whichever is running.
- **Prerequisites**: Install the Murmur Bridge plugin in the vault (`.obsidian/plugins/murmur-bridge/`) and enable it in Obsidian Settings > Community Plugins.

### HTTP API endpoints

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/v1/health` | Health check |
| GET | `/api/v1/draft/status` | Session state |
| POST | `/api/v1/draft/start` | Start session (`filePath`, optional `startLine`) |
| POST | `/api/v1/draft/stop` | Stop session |
| POST | `/api/v1/draft/navigate` | Move between paragraphs (`next`/`prev`/`goto`) |
| POST | `/api/v1/draft/pause` | Pause TTS |
| POST | `/api/v1/draft/resume` | Resume TTS |
| POST | `/api/v1/draft/cursor-sync` | Jump to paragraph at line |
