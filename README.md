# Murmur

> Fork of [ykdojo/super-voice-assistant](https://github.com/ykdojo/super-voice-assistant) with OpenClaw integration, push-to-talk, audio transcription overlay, and consolidated shortcuts.

macOS voice assistant with global hotkeys and push-to-talk support. Transcribe speech to text with offline models (WhisperKit or Parakeet), interact with OpenClaw AI assistant by voice, and read selected text aloud with TTS. Runs in the menu bar with no dock icon.

## Features

**Voice-to-Text Transcription (STT)**
- Press **Cmd+Opt+C** to start/stop recording and transcribe
- Choose your engine in Settings: Parakeet (recommended) or WhisperKit
- Automatic Gemini API fallback when local transcription returns empty
- Automatic text pasting at cursor position
- Transcription history with **Cmd+Opt+A**

**Push-to-Talk**
- Double-tap-and-hold **Right Option** key for STT recording — release to transcribe and paste
- Double-tap-and-hold **Left Option** key for OpenClaw — release to send
- Optional auto-submit: sends Return after paste (for chat inputs like Claude Code)
- Configurable in Settings — enable/disable each PTT and the auto-Return independently

**OpenClaw AI Assistant**
- Press **Cmd+Opt+O** to toggle OpenClaw voice recording
- Floating overlay shows listening, processing, and streaming states
- Responses displayed in overlay with copy support and auto-dismiss
- TTS playback of responses via Kokoro (local) or Gemini (cloud)
- Configure connection in Settings (URL, token, session key)

**Text-to-Speech (TTS)**
- Press **Cmd+Opt+S** to read selected text aloud
- Press again to stop playback
- Supports Kokoro (local, offline) and Gemini Live API (cloud, streaming)

**Audio Transcription Overlay**
- Visual overlay appears during STT recording and transcription
- Shows pulsing mic icon while recording, spinner while transcribing
- Auto-dismisses on completion or shows errors briefly

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| **Cmd+Opt+C** | Start/stop STT recording and transcribe |
| **Cmd+Opt+S** | Read selected text aloud / stop TTS |
| **Cmd+Opt+O** | Start/stop OpenClaw voice recording |
| **Cmd+Opt+A** | Show transcription history |
| **Cmd+Opt+V** | Paste last transcription at cursor |
| **Escape** | Cancel active recording |
| **Right Option** (double-tap-hold) | STT push-to-talk |
| **Left Option** (double-tap-hold) | OpenClaw push-to-talk |

All keyboard shortcuts are customizable in Settings.

## Requirements

- macOS 14.0 or later
- Xcode 15+ or Xcode Command Line Tools (for Swift 5.9+)
- Gemini API key (optional — for TTS, cloud transcription fallback)

## System Permissions

### Microphone Access
The app requests microphone permission on first launch. If denied:
- **System Settings > Privacy & Security > Microphone** — enable for Murmur

### Accessibility Access
Required for global hotkeys and auto-paste:
1. **System Settings > Privacy & Security > Accessibility**
2. Add **Terminal** (if running via `swift run`) or the **Murmur** binary
3. Ensure the checkbox is enabled

## Installation

### As an Application (recommended)

```bash
# Clone the repository
git clone https://github.com/tomorrowflow/murmur.git
cd murmur

# Set up environment (optional — for TTS and cloud transcription fallback)
cp .env.example .env
# Edit .env and add your GEMINI_API_KEY

# Build the .app bundle and install
./build.sh
cp -R build/Murmur.app /Applications/
```

On first launch, Murmur will ask for microphone permission and offer to enable launch at login.

### Development mode

```bash
swift build
swift run Murmur
```

The app appears in your menu bar as a waveform icon (no dock icon).

## Configuration

### Text Replacements

Configure automatic text replacements for transcriptions by editing `config.json` in the project root:

```json
{
  "textReplacements": {
    "Cloud Code": "Claude Code",
    "cloud code": "claude code",
    "cloud.md": "CLAUDE.md"
  }
}
```

Useful for correcting common speech-to-text misrecognitions for proper nouns, brand names, or technical terms. Replacements are case-sensitive.

### Settings

Access via the menu bar icon > Settings:

- **General** — Launch at login toggle
- **Models** — Select and download transcription engine (Parakeet or WhisperKit)
- **Audio Devices** — Configure input/output devices
- **Shortcuts** — Customize keyboard shortcuts and push-to-talk toggles
- **OpenClaw** — Configure OpenClaw connection (URL, token, password, session key)

### Transcription Engines

| Engine | Speed | Accuracy | Languages | Notes |
|---|---|---|---|---|
| **Parakeet v2** | ~110x realtime | 1.69% WER | English | Recommended for speed |
| **Parakeet v3** | ~210x realtime | 1.8% WER | 25 languages | Multilingual |
| **WhisperKit** | Varies by model | Good | Many | Various model sizes |
| **Gemini** (fallback) | Cloud-dependent | Best for complex audio | Many | Auto-fallback when local returns empty |

## Project Structure

- `Sources/` — Main app code
  - `main.swift` — App delegate, shortcuts, push-to-talk, overlay wiring
  - `AudioTranscriptionManager.swift` — Audio recording and transcription routing
  - `AudioTranscriptionOverlayWindow.swift` — STT recording/transcription overlay
  - `OpenClawRecordingManager.swift` — OpenClaw voice recording manager
  - `OpenClawOverlayWindow.swift` — OpenClaw floating overlay UI
  - `ShortcutsSettingsViewController.swift` — Shortcuts and PTT settings
  - `ModelStateManager.swift` — Engine and model selection
- `SharedSources/` — Shared components
  - `OpenClawManager.swift` — OpenClaw WebSocket connection
  - `OpenClawResponseFilter.swift` — Response text processing
  - `ParakeetTranscriber.swift` — FluidAudio Parakeet wrapper
  - `GeminiStreamingPlayer.swift` — Streaming TTS playback
  - `GeminiAudioTranscriber.swift` — Gemini API transcription (fallback)

## Changes from Upstream

This fork adds the following over [ykdojo/super-voice-assistant](https://github.com/ykdojo/super-voice-assistant):

- **OpenClaw integration** — Voice-driven AI assistant with overlay UI and TTS responses
- **Push-to-talk** — Double-tap-and-hold Option keys for hands-free recording
- **Audio transcription overlay** — Visual feedback during recording and transcription
- **Shortcut consolidation** — Removed separate Gemini audio recording shortcut, renamed to "Recording (STT)"
- **Gemini fallback** — Automatic cloud fallback when local transcription returns empty
- **Configurable shortcuts** — All shortcuts customizable in Settings with PTT toggles
- **Transcription history window** — Dedicated window for browsing past transcriptions
- **Unified settings** — Tabbed settings interface (General, Models, Audio, Shortcuts, OpenClaw)
- **Kokoro TTS** — Local offline text-to-speech via FluidAudio
- **No dock icon** — Runs as a menu bar-only app
- **Removed** — Separate Gemini audio recording, screen recording/video transcription

## License

See [LICENSE](LICENSE) for details.
