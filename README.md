# Murmur

A macOS menu bar app for voice-driven work. Dictate into any window, read selected text aloud with natural TTS, run an interactive AI assistant by voice, turn articles into two-host podcasts you can interrupt, edit markdown by speaking, and close the loop with **Claude Code** — hear every assistant reply spoken back to you, then answer by voice straight into the terminal you came from.

---

## Demo

> *Placeholder — replace with a short screen recording of the full flow: Claude Code finishes a turn → Murmur's Read Aloud overlay appears and speaks the reply → auto-recording starts → user speaks → Right Option stops → transcription pastes back into the original terminal.*

<!-- To embed a GitHub-hosted video, drop the mov/mp4 into an Issue or PR comment,
     copy the resulting URL, and paste it here as a plain link. GitHub renders it inline. -->

[Watch the walkthrough (placeholder)](docs/videos/murmur-walkthrough.mp4)

---

## Screenshots

| | |
|---|---|
| ![Menu bar and Read Aloud overlay](docs/screenshots/01-read-aloud.png) *Read Aloud overlay with live sentence highlighting and TTS controls* | ![Recording overlay bound to Ghostty](docs/screenshots/02-recording.png) *Recording overlay showing the bound target window's icon* |
| ![History with filter and search](docs/screenshots/03-history.png) *History window with type filter, search, and separate Copy Text / Copy Spoken buttons* | ![Podcast mode](docs/screenshots/04-podcast.png) *Interactive two-host podcast — interrupt with a double-tap to ask a question* |
| ![Draft editing with TextMate](docs/screenshots/05-draft-editing.png) *Voice-driven markdown editing with paragraph-level TTS and spoken edit commands* | ![Settings — Read Aloud](docs/screenshots/06-settings.png) *Read Aloud settings including the Claude Code recap preprocessor (None / Regex / Ollama)* |

> *Screenshots go into `docs/screenshots/`. Suggested captures listed above — swap the placeholder paths once you have them.*

---

## Features

### Speech-to-Text

- Global hotkey + double-tap push-to-talk (hold or toggle mode).
- Offline engines: **Parakeet** (~110× realtime) or **WhisperKit**, with automatic Gemini fallback when local returns empty.
- Window pinning: the window you were in when recording started is the window that receives the paste, even if you switch apps during transcription.
- Optional Ollama prompt refinement for recordings > 5s — removes filler, fixes punctuation.
- Optional auto-Return after paste — ideal for chat UIs and Claude Code prompts.
- Configurable text replacements for common STT misrecognitions.
- Resilient to AirPods / Bluetooth codec switches: when macOS swaps A2DP→HFP at recording start, Murmur restarts the audio engine automatically instead of hanging in "preparing".

### Read Aloud

- Kokoro (offline) or Gemini Live (streaming) TTS for any selected text.
- Live sentence highlighting, pause/resume, 15% speed boost on Gemini.
- Ask follow-up questions mid-reading with push-to-talk — Ollama answers, then reading resumes.
- **Mute toggle in the overlay header** silences the spoken audio while the transcript continues to scroll and highlight at the natural sentence pace — tap the speaker icon to drop the audio instantly without losing your place. State persists across sessions.
- Export full audio as WAV or transcript as Markdown.

### Claude Code Voice Recap

- A [Claude Code **Stop hook**](https://docs.anthropic.com/claude-code/hooks) pipes the assistant's final message into Murmur's local HTTP API.
- Murmur speaks the recap, then **auto-starts an STT recording** so you can reply by voice.
- **Right Option** (single tap) stops the follow-up recording; the transcription pastes into the exact terminal Claude Code ran in.
- **Parallel Claude sessions**: multiple terminal windows can trigger recaps at the same time. Murmur queues them FIFO — TTS, reply, and paste for one session runs to completion before the next starts. No audio overlap.
- **Per-window binding**: the target window is resolved by matching the shell's cwd against each terminal window's `AXDocument` attribute — so Claude running in window B stays bound to window B, even if you're focused on window A when it responds. Works with any terminal emulator that exposes `AXDocument` (Ghostty, Terminal.app; falls back to the focused window for others).
- Optional LLM preprocessing rewrites gnarly assistant output (PIDs, file paths, code blocks, commit hashes, URLs) into a short spoken summary. History keeps both the raw text and the spoken summary with separate copy buttons.

### Claude Code Tool Approvals

- Optional: wire a `PreToolUse` hook so Murmur auto-approves permission prompts instead of stopping to ask "Allow this Bash command? [Yes/No/Yes don't ask again]".
- Every auto-approval is logged to **History → Approvals** with the tool name and input preview (Bash command, file path, URL, etc.) — so you have a full audit trail of what ran unattended.
- Enable in **Settings → Claude → Tool Approvals**. Default off. Toggle it as your trust warrants — unlike `--dangerously-skip-permissions`, you can flip it per-session and still see every tool call afterward.

### Remote Claude Code sessions (LAN)

- Run Claude Code on another machine (remote workstation, a laptop, etc.) and have its hooks call back to Murmur on your Mac.
- Opt in under **Settings → Claude → Network** by toggling **Expose HTTP API to LAN**. Listener binds from `127.0.0.1:7878` → `0.0.0.0:7878` without needing an app restart.
- Every remote IP has to be explicitly **approved** before Murmur processes its requests — unknown hosts get a 403 pending-approval response and show up under **Settings → Claude → Approved Hosts** where you click Approve / Deny.
- Approved hosts persist across app restarts, up to 10. Pending hosts are in-memory only so a hostile LAN host can't fill the list permanently.
- Localhost hooks work regardless of this setting.

### OpenClaw Assistant

- Voice-driven AI over WebSocket with a floating overlay.
- Streaming text display, TTS via Kokoro or Gemini.
- Curve25519 device identity, auto-reconnect with backoff.

### Podcast Mode

- Turn a URL, PDF, or pasted text into a two-host AI podcast with cloned voices.
- Double-tap to interrupt and ask a question — the hosts answer in-context and continue.
- Configurable length and LLM. GPU TTS via ComfyUI + VibeVoice on a remote server.
- Full audio download and Markdown transcript export.

### Draft Editing

- Voice-driven markdown editing in **TextMate** or **Obsidian**.
- Paragraph-by-paragraph TTS with structural cues ("Section:", "List:", "Quote:", "Table:").
- Speak an edit instruction — Ollama rewrites the paragraph and the file updates atomically.
- Persistent in-editor highlighting follows the current paragraph.
- Auto-detects active editor; configurable default.

### History

- Browse all past transcripts, recaps, and podcasts. No cap — everything persists until you clear it.
- Filter by type (**All / Transcripts / Recaps / Podcasts**) and full-text search across raw + spoken text.
- For recap entries: **Copy Text** gives Claude's raw output, **Copy Spoken** gives the LLM-rewritten summary.
- For podcasts: **Save Audio** exports the WAV alongside the transcript.

---

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
| **Right Option** (single tap) | Stop auto-record after a Claude recap |
| **Left Option** (double-tap) | OpenClaw / Draft Edit / Read Aloud interrupt |
| **Escape** | Dismiss the active overlay |

All shortcuts are customizable in **Settings → Shortcuts**.

---

## Requirements

- macOS 14.0 or later
- Xcode 15+ or Xcode Command Line Tools (Swift 5.9+)
- (Optional) Ollama running locally for prompt refinement, Q&A, and recap preprocessing
- (Optional) Gemini API key for cloud TTS / transcription fallback

## Installation

```bash
git clone https://github.com/tomorrowflow/murmur.git
cd murmur

# Optional: Gemini for cloud TTS + transcription fallback
cp .env.example .env
# Edit .env and add your GEMINI_API_KEY

./build.sh
cp -R build/Murmur.app /Applications/
```

On first launch, Murmur prompts for **Microphone** and **Accessibility** permissions, and offers to enable launch at login. If paste stops working after a rebuild, re-enable Murmur in **System Settings → Privacy & Security → Accessibility**.

Dev loop: `swift build && swift run Murmur`.

---

## Wiring Claude Code

Drop a Stop hook into `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/recap.sh" }] }
    ]
  }
}
```

A reference `recap.sh` lives in this repo under `scripts/claude-code/recap.sh`. It walks up the process tree so Murmur can bind the recap to the terminal Claude Code is running in — even when that terminal is on a different space or hidden behind other apps.

To also auto-approve tool permission prompts (optional), add a `PreToolUse` hook that POSTs directly to Murmur — no shell script:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/recap.sh" }] }
    ],
    "PreToolUse": [
      { "hooks": [{ "type": "http", "url": "http://127.0.0.1:7878/api/v1/claude/permission-check", "timeout": 10 }] }
    ]
  }
}
```

Murmur's endpoint consults the **Auto-approve tool requests** toggle in Settings → Claude. When on, it returns `permissionDecision: allow` and logs each call to History → Approvals. When off, it returns `ask` and Claude Code shows its normal interactive prompt — nothing is logged.

For **remote machines** (Claude Code running on a different host), enable LAN exposure in Settings → Claude → Network, then point the hooks at your Mac's LAN IP:

```json
"Stop": [
  { "hooks": [{ "type": "command", "command": "~/.claude/hooks/recap.sh" }] }
],
"PreToolUse": [
  { "hooks": [{ "type": "http", "url": "http://YOUR_MAC_IP:7878/api/v1/claude/permission-check", "timeout": 10 }] }
]
```

First request from a new IP lands in **Settings → Claude → Approved Hosts** as a pending entry — click Approve once and future requests pass through.

Enable the recap preprocessor in **Settings → Claude → Claude Code Recap**:

| Mode | What it does |
|---|---|
| **None** | Speak the raw assistant message verbatim |
| **Regex cleanup** | Strip code blocks, paths, markdown, line refs, hashes, URLs |
| **Ollama (LLM summary)** | Rewrite as a short spoken summary using the configured Ollama model |

---

## Configuration

Settings live in the menu bar icon → **Settings**:

| Tab | What you'll find |
|---|---|
| General | Launch at login, audio ducking mode |
| Settings | Transcription engine (Parakeet / WhisperKit), model download and selection |
| Shortcuts | Keyboard shortcuts, PTT toggles, auto-Return, prompt refinement, auto-stop after silence |
| Audio Devices | Input/output, Kokoro voice selection with preview |
| OpenClaw | Connection URL, token, password, session key, device ID |
| Podcast | Server URL, host names + voice samples, podcast length, LLM model |
| Read Aloud | Ollama model, resume behavior, Claude recap preprocessor, default editor for draft editing |

### Audio Ducking

Set under **Settings → General → Audio Ducking**. Three modes:

| Mode | Behavior |
|---|---|
| **Off** | Murmur leaves system audio alone. |
| **Duck during recording** | Master output volume drops while STT is recording — reduces mic bleed from speakers. Doesn't touch playback. |
| **Pause other media during recording and playback** | Sends `Pause` to whichever app owns macOS Now Playing (Spotify, Apple Music, Apple Podcasts, Safari/YouTube on supported builds), then `Play` when the Murmur session ends. Master volume is left alone — TTS plays at normal level. Real media players that close their output stream when paused (Spotify, Music) are correctly detected via the CoreAudio per-process API; browsers that hold the stream open while paused (Safari, Brave, Chrome) can't be reliably detected and won't be auto-paused. Resume is debounced 1.2s so the recap chain (TTS end → STT start) stays muted throughout. |

Diagnostic test executables for this path live in `tests/test-media-remote/` and `tests/test-audio-activity/` — run via `swift run TestMediaRemote` and `swift run TestAudioActivity` to inspect MediaRemote command behavior and per-process audio activity on a given macOS build (Apple has tightened these private APIs over recent versions; the labs let you verify what still works without rebuilding the whole app).

### Transcription Engines

| Engine | Speed | Accuracy | Languages | Notes |
|---|---|---|---|---|
| Parakeet v2 | ~110× realtime | 1.69% WER | English | Recommended |
| Parakeet v3 | ~210× realtime | 1.8% WER | 25 languages | Multilingual |
| WhisperKit | Varies | Good | Many | Multiple model sizes |
| Gemini (fallback) | Cloud-dependent | Best for messy audio | Many | Auto-fallback when local returns empty |

### Text Replacements

Edit `config.json` at the repo root for common STT misrecognitions:

```json
{
  "textReplacements": {
    "Cloud Code": "Claude Code",
    "cloud code": "claude code",
    "cloud.md": "CLAUDE.md"
  }
}
```

Case-sensitive; applied before paste.

### Environment

`.env` at the repo root:

```
GEMINI_API_KEY=your_key_here
```

Enables Gemini streaming TTS, cloud transcription fallback, and Gemini TTS for OpenClaw.

### Local HTTP API

Murmur runs an HTTP server on `127.0.0.1:7878` for integrations. Endpoints:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/v1/health` | Health check |
| `POST` | `/api/v1/read-aloud` | Speak text via the Read Aloud overlay; optional `autoRecordAfter`, `preprocess`, `sourcePids` |
| `POST` | `/api/v1/claude/permission-check` | Claude Code `PreToolUse` hook target — auto-approve + log, or defer to interactive prompt |
| `GET` | `/api/v1/draft/status` | Draft editing session state |
| `POST` | `/api/v1/draft/{start,stop,navigate,pause,resume,cursor-sync}` | Draft editing control |

---

## Project Structure

- `Sources/` — main app (menu bar, hotkeys, overlays, managers)
- `SharedSources/` — shared models, transcribers, TTS players, audio utilities
- `podcastd/` — podcast backend (Python asyncio WebSocket, Docker compose, LLM prompts)
- `Murmur.tmbundle/` — TextMate bundle for draft editing
- `murmur-obsidian-plugin/` — Obsidian companion plugin (HTTP server on `127.0.0.1:27125`)
- `scripts/claude-code/` — reference Stop hook for Claude Code recap
- `tests/` — standalone executables; notable diagnostic labs include `test-media-remote/` (MediaRemote command + read-API probes) and `test-audio-activity/` (CoreAudio per-process playback detection)
- `docs/` — specs and screenshots

See `CLAUDE.md` for a deeper architectural tour.

---

## Dependencies

| Package | Purpose |
|---|---|
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | Global hotkey handling |
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) | Local speech-to-text |
| [FluidAudio](https://github.com/AINativeLab/FluidAudio) | Parakeet STT + Kokoro TTS |

---

## Acknowledgements

Murmur started as a fork of [ykdojo/super-voice-assistant](https://github.com/ykdojo/super-voice-assistant) and has evolved substantially since. Thanks to the original maintainers for the foundation.

## License

See [LICENSE](LICENSE).
