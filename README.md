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
- Double-tap-and-hold **Right Option** for STT — release to transcribe and paste
- Double-tap-and-hold **Left Option** for OpenClaw — release to send
- Audio feedback tones on recording start and stop
- Optional auto-Return after paste (useful for Claude Code, chat UIs)
- Mutual exclusion prevents simultaneous recordings

**OpenClaw AI Assistant**
- Voice-driven AI interaction over WebSocket
- Floating overlay shows listening, processing, streaming, and complete states
- Response text is scrollable, selectable, and copyable
- TTS playback via Kokoro (local) or Gemini (cloud streaming)
- Secure device identity with Curve25519 keypair
- Automatic reconnection with exponential backoff

**Text-to-Speech**
- Read selected text aloud with Kokoro (offline) or Gemini Live API (streaming)
- Smart sentence splitting for natural speech flow
- 15% speed boost via TimePitch effect on Gemini streaming
- Press shortcut again to stop playback

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
| **Right Option** (double-tap-hold) | STT push-to-talk |
| **Left Option** (double-tap-hold) | OpenClaw push-to-talk |
| **Escape** | Cancel active recording |

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
| **Models** | Transcription engine (Parakeet / WhisperKit), model download and selection |
| **Audio Devices** | Input/output device, Kokoro TTS voice selection with preview |
| **Shortcuts** | Keyboard shortcuts, PTT toggles, auto-Return after paste |
| **OpenClaw** | Connection URL, token, password, session key, device ID |

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
