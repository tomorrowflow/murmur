# Murmur

macOS voice assistant that lives in your menu bar. Transcribe speech to text with offline models, interact with an AI assistant by voice, and read selected text aloud — all with global hotkeys and push-to-talk.

## Features

**Speech-to-Text**
- Record and transcribe with a keyboard shortcut or push-to-talk
- Offline engines: Parakeet (recommended, ~110x realtime) or WhisperKit
- Automatic Gemini API fallback when local transcription returns empty
- Auto-paste at cursor with optional Return key for chat inputs
- Configurable text replacements for common STT misrecognitions
- Silence detection and short-audio filtering

**Push-to-Talk**
- Double-tap **Right Option** for STT, **Left Option** for OpenClaw
- Two modes: **hold** (double-tap and keep holding, release to stop) or **toggle** (double-tap and release, tap again to stop)
- Audio feedback tones on recording start and stop
- Optional auto-Return after paste (useful for Claude Code, chat UIs)
- Window targeting: remembers which window was active when recording started and pastes there even if you switch away during processing
- Optional prompt refinement via Ollama — cleans up filler words and fixes punctuation for recordings longer than 5 seconds
- Mutual exclusion prevents simultaneous recordings

**OpenClaw AI Assistant**
- Voice-driven AI interaction over WebSocket
- Floating overlay shows listening, processing, streaming, and complete states
- Response text is scrollable, selectable, and copyable
- TTS playback via Kokoro (local) or Gemini (cloud streaming)
- Secure device identity with Curve25519 keypair
- Automatic reconnection with exponential backoff

**Interactive Read Aloud**
- Read selected text aloud with Kokoro (offline) or Gemini Live API (streaming)
- Smart sentence splitting for natural speech flow with sentence highlighting
- Ask questions mid-reading via push-to-talk — Ollama answers in context, then resumes
- Pause, resume, and export readings
- 15% speed boost via TimePitch effect on Gemini streaming
- Press shortcut again to stop playback

**Podcast Mode**
- Transform URLs, PDFs, or text into a two-host AI podcast you can interrupt and steer
- Two AI hosts with custom names and cloned voices via uploaded samples
- Push-to-talk interrupts — ask questions or redirect the conversation in real time
- LLM-driven script generation with configurable podcast length and model selection
- GPU-accelerated TTS via ComfyUI + VibeVoice on a remote server
- Real-time streaming with chunk prefetch and Now Playing integration
- Full audio download and markdown transcript export
- Self-hosted backend (`podcastd`) with Docker deployment

**Draft Editing Mode**
- Voice-driven writing assistant for markdown documents in TextMate or Obsidian
- Paragraph-by-paragraph TTS with structural cues ("Section:", "List:", "Table:", "Quote:")
- Persistent line highlighting in the editor follows the current paragraph
- Voice-edit paragraphs: double-tap Left Option, speak an instruction, LLM rewrites the paragraph in-place
- Start reading from cursor position, skip forward/back, pause/resume
- Escape key stops the session and clears highlights
- Export full reading as WAV audio
- Markdown-aware: skips front matter, HTML comments, horizontal rules; handles tables, code blocks, lists, blockquotes
- Auto-detects active editor (TextMate or Obsidian) or configurable default in Settings
- Local HTTP API on port 7878 for editor integration
- TextMate integration via `Murmur.tmbundle` (grammar injection for highlighting)
- Obsidian integration via `murmur-obsidian-plugin` (CodeMirror 6 decorations, no file modification)

**Transcription History**
- Browse, copy, and delete past transcriptions
- Persisted to disk (up to 100 entries)
- Q&A parsing for OpenClaw entries

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| **Cmd+Opt+C** | Start/stop STT recording |
| **Cmd+Opt+S** | Read selected text aloud / stop TTS |
| **Cmd+Opt+O** | Start/stop OpenClaw voice recording |
| **Cmd+Opt+A** | Show transcription history |
| **Cmd+Opt+V** | Paste last transcription at cursor |
| **Cmd+Opt+D** | Toggle draft editing mode |
| **Right Option** (double-tap) | STT push-to-talk (hold or toggle) |
| **Left Option** (double-tap) | OpenClaw / Draft Edit / Read Aloud push-to-talk |
| **Escape** | Cancel active recording or stop draft editing |

All shortcuts are customizable in Settings.

## Requirements

- macOS 14.0 or later
- Xcode 15+ or Xcode Command Line Tools (Swift 5.9+)
- Gemini API key (optional — for cloud TTS and transcription fallback)

## Installation

### As an Application (recommended)

```bash
git clone https://github.com/tomorrowflow/murmur.git
cd murmur

# Optional: set up Gemini API for TTS and cloud transcription fallback
cp .env.example .env
# Edit .env and add your GEMINI_API_KEY

# Build and install
./build.sh
cp -R build/Murmur.app /Applications/
```

On first launch, Murmur will prompt for microphone and accessibility permissions, and offer to enable launch at login.

### Development mode

```bash
swift build
swift run Murmur
```

## System Permissions

**Microphone** — required for all recording features. Prompted on first launch.

**Accessibility** — required for auto-paste (CGEvent) and text selection reading. Prompted on first launch. If paste stops working after a rebuild, re-enable the binary in **System Settings > Privacy & Security > Accessibility**.

## Configuration

### Settings

Access via the menu bar icon > Settings:

| Tab | Options |
|---|---|
| **General** | Launch at login |
| **Settings** | Transcription engine (Parakeet / WhisperKit), model download and selection |
| **Shortcuts** | Keyboard shortcuts, PTT toggles, auto-Return after paste, prompt refinement |
| **Audio Devices** | Input/output device, Kokoro TTS voice selection with preview |
| **OpenClaw** | Connection URL, token, password, session key, device ID |
| **Podcast** | Server URL, host names, voice sample upload with preview, podcast length, LLM model |
| **Read Aloud** | Ollama model selection, resume behavior after Q&A, draft editing editor default |

### Transcription Engines

| Engine | Speed | Accuracy | Languages | Notes |
|---|---|---|---|---|
| **Parakeet v2** | ~110x realtime | 1.69% WER | English | Recommended |
| **Parakeet v3** | ~210x realtime | 1.8% WER | 25 languages | Multilingual |
| **WhisperKit** | Varies by model | Good | Many | Multiple model sizes |
| **Gemini** (fallback) | Cloud-dependent | Best for complex audio | Many | Auto-fallback when local returns empty |

### Text Replacements

Edit `config.json` in the project root to correct common STT misrecognitions:

```json
{
  "textReplacements": {
    "Cloud Code": "Claude Code",
    "cloud code": "claude code",
    "cloud.md": "CLAUDE.md"
  }
}
```

Replacements are case-sensitive and applied before pasting.

### Environment Variables

Create a `.env` file in the project root:

```
GEMINI_API_KEY=your_key_here
```

Enables Gemini streaming TTS, cloud transcription fallback, and OpenClaw TTS via Gemini.

## Project Structure

- `Sources/` — Main application
  - `main.swift` — App delegate, shortcuts, push-to-talk state machine, overlay wiring
  - `AudioTranscriptionManager.swift` — Audio recording, engine routing, transcription pipeline
  - `AudioTranscriptionOverlayWindow.swift` — STT recording/transcription overlay
  - `OpenClawRecordingManager.swift` — OpenClaw voice recording and response handling
  - `OpenClawOverlayWindow.swift` — OpenClaw floating overlay with streaming text
  - `PTTTonePlayer.swift` — Synthesized audio tones for PTT feedback
  - `ModelStateManager.swift` — Engine and model lifecycle management
  - `GeneralSettingsViewController.swift` — Launch at login settings
  - `ShortcutsSettingsViewController.swift` — Shortcut and PTT configuration
  - `OpenClawSettingsViewController.swift` — OpenClaw connection settings
  - `AudioDevicesViewController.swift` — Audio device and TTS voice selection
  - `PodcastManager.swift` — Podcast WebSocket client, chunk playback, and interrupt handling
  - `PodcastOverlayWindow.swift` — Podcast floating overlay with transcript and progress
  - `PodcastSettingsViewController.swift` — Podcast server and voice configuration
  - `ReadAloudManager.swift` — Interactive read aloud with Q&A and pause/resume
  - `ReadAloudOverlayWindow.swift` — Read aloud overlay with sentence highlighting
  - `ReadAloudSettingsViewController.swift` — Read aloud, Ollama, and draft editing settings
  - `DraftEditingManager.swift` — Draft editing session state machine, paragraph TTS, LLM edit flow
  - `DraftEditingOverlayWindow.swift` — Draft editing overlay with paragraph view, edit preview, controls
  - `MarkdownParagraphParser.swift` — Markdown-aware paragraph splitting with line ranges
  - `MarkdownTTSRenderer.swift` — Structured TTS rendering with cues, silence, and speed control
  - `MurmurHTTPServer.swift` — Local HTTP server (port 7878) for editor integration
  - `EditorAdapter.swift` — Editor adapter protocol with TextMate and Obsidian implementations
  - `FileEditController.swift` — Atomic file write with paragraph replacement
  - `OllamaClient.swift` — Ollama LLM client for Q&A and prompt refinement
  - `TranscriptionHistory.swift` — JSON-based transcription storage
  - `TextReplacements.swift` — Post-transcription text corrections
  - `UnifiedManagerWindow.swift` — Tabbed settings window
- `SharedSources/` — Shared components
  - `OpenClawManager.swift` — WebSocket connection with Curve25519 device identity
  - `ParakeetTranscriber.swift` — FluidAudio Parakeet wrapper
  - `GeminiStreamingPlayer.swift` — Streaming TTS playback with speed boost
  - `GeminiAudioCollector.swift` — Audio collection and WebSocket handling for TTS
  - `GeminiAudioTranscriber.swift` — Gemini API transcription fallback
  - `SmartSentenceSplitter.swift` — Sentence boundary detection for TTS
  - `AudioDeviceManager.swift` — CoreAudio device enumeration
- `podcastd/` — Podcast backend service (Python asyncio WebSocket)
  - `server.py` — WebSocket server with script generation and TTS pipeline
  - `prompts/` — LLM system prompts for podcast script generation
  - `docker-compose.yml` — Docker deployment with Traefik reverse proxy
- `Murmur.tmbundle/` — TextMate bundle for draft editing (grammar injection, highlight commands)
- `murmur-obsidian-plugin/` — Obsidian companion plugin (CodeMirror 6 decorations, HTTP server on port 27125)
- `docs/` — Documentation
  - `PODCAST_SPEC.md` — Full podcast mode specification

## Dependencies

| Package | Purpose |
|---|---|
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | Global hotkey handling |
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) | Local speech-to-text |
| [FluidAudio](https://github.com/AINativeLab/FluidAudio) | Parakeet STT + Kokoro TTS |

## Acknowledgements

Murmur started as a fork of [ykdojo/super-voice-assistant](https://github.com/ykdojo/super-voice-assistant). Thanks to the original maintainers for the foundation that made this project possible.

## License

See [LICENSE](LICENSE) for details.
