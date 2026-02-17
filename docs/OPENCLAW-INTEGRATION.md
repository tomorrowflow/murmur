# OpenClaw Integration Specification

> Development guide for adding an OpenClaw voice interaction mode to super-voice-assistant.
> This is an **additive** integration — no existing features are modified or removed.

---

## 1. Overview & Architecture

### High-Level Flow

```
Voice Input -> STT -> OpenClaw WebSocket -> Filter -> Overlay + TTS
```

The user presses a new keyboard shortcut (`Cmd+Option+O`) to record voice. The existing STT engine (WhisperKit or Parakeet, based on current selection) transcribes the audio. The transcribed text is sent to an OpenClaw gateway via WebSocket RPC. The streamed response is filtered (reasoning tags, TTS directives, tool-call artifacts removed), displayed in a floating overlay window, and spoken aloud using Kokoro TTS (native CoreML via FluidAudio).

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                   super-voice-assistant                      │
│                                                              │
│  ┌──────────────┐    ┌─────────────────────────────────┐    │
│  │  Cmd+Opt+O   │───>│  OpenClawRecordingManager       │    │
│  │  (Shortcut)  │    │  Coordinates full lifecycle      │    │
│  └──────────────┘    └──────┬──────────────────────┬────┘    │
│                             │                      │         │
│                    ┌────────▼────────┐    ┌────────▼───────┐ │
│                    │ AudioTranscrip- │    │ OpenClawOverlay│ │
│                    │ tionManager     │    │ Window         │ │
│                    │ (existing STT)  │    │ (new SwiftUI)  │ │
│                    └────────┬────────┘    └────────▲───────┘ │
│                             │                      │         │
│                    ┌────────▼────────┐    ┌────────┴───────┐ │
│                    │ OpenClawManager │───>│ OpenClawResp-  │ │
│                    │ (WebSocket RPC) │    │ onseFilter     │ │
│                    └────────┬────────┘    └────────┬───────┘ │
│                             │                      │         │
│                             │              ┌───────▼───────┐ │
│                             │              │ KokoroTTS-    │ │
│                             │              │ Player        │ │
│                             │              │ (FluidAudio)  │ │
│                             │              └───────────────┘ │
│                             │                                │
└─────────────────────────────┼────────────────────────────────┘
                              │ WebSocket
                    ┌─────────▼──────────┐
                    │  OpenClaw Gateway   │
                    │  ws://127.0.0.1:   │
                    │       18789         │
                    └────────────────────┘
```

### Relationship to Existing Features

| Existing Feature | Relationship |
|---|---|
| `Cmd+Opt+Z` (WhisperKit recording) | Mutual exclusion — cannot run simultaneously |
| `Cmd+Opt+X` (Gemini recording) | Mutual exclusion — cannot run simultaneously |
| `Cmd+Opt+S` (Read selected text) | Independent — OpenClaw TTS uses Kokoro, not Gemini |
| `Cmd+Opt+C` (Screen recording) | Mutual exclusion — cannot run simultaneously |
| `AudioTranscriptionManager` | **Reused** — provides audio capture + STT |
| `GeminiStreamingPlayer` | Available as **fallback TTS** if Kokoro unavailable |
| `TranscriptionHistory` | **Reused** — OpenClaw interactions saved to history |
| `ModelStateManager` | **Extended** — new properties for Kokoro TTS model state |
| Status bar indicators | **Reused** — same `updateStatusBarWithLevel()` pattern |

---

## 2. New Keyboard Shortcut

### Registration

Add to the `KeyboardShortcuts.Name` extension in `Sources/main.swift` (after line 41):

```swift
static let openclawRecording = Self("openclawRecording")
```

Register the default binding in `applicationDidFinishLaunching` (after line 112):

```swift
KeyboardShortcuts.setShortcut(.init(.o, modifiers: [.command, .option]), for: .openclawRecording)
```

### Behavior

- **Press once**: Start recording (same audio capture as existing STT flow)
- **Press again**: Stop recording, transcribe, send to OpenClaw
- **Escape**: Cancel recording (reuse existing escape key monitor pattern from `AudioTranscriptionManager.swift:132`)
- **Mutual exclusion**: Block if any other recording mode is active (same guard pattern as `main.swift:118-136`)

### Shortcut Conflict Check

Currently taken `Cmd+Option+` shortcuts: **Z**, **X**, **A**, **S**, **C**, **V**. The letter **O** is available.

### Menu Item

Add to the status bar menu (after the existing shortcut menu items):

```
OpenClaw: Press Command+Option+O
```

---

## 3. OpenClaw WebSocket Gateway Protocol

### Connection Scenarios

#### Local (same Mac)

- URL: `ws://127.0.0.1:18789` (default gateway port)
- Auth: Token auth via `.env` (`OPENCLAW_TOKEN`)
- Nonce: Not required for loopback connections (legacy v1 signature support)
- No TLS needed

#### Remote (LAN / Tailscale)

- URL: `wss://<host>:<port>` (TLS required for non-loopback)
- Auth: Token auth, password auth, or full Ed25519 device auth with v2 signature (includes nonce)
- TLS: Standard or self-signed with fingerprint pinning

### Frame Format

All messages are JSON. Three frame types:

```
Request:  { "type": "req", "id": "<uuid>", "method": "<name>", "params": { ... } }
Response: { "type": "res", "id": "<uuid>", "ok": true|false, "payload": { ... } }
Event:    { "type": "event", "event": "<name>", "payload": { ... } }
```

### Protocol Flow

```
Client                                  Gateway
  │                                        │
  │◄──── connect.challenge ────────────────│  (1) Immediate on connect
  │      { nonce: "<uuid>", ts: <ms> }     │
  │                                        │
  │──── req: connect ──────────────────────►│  (2) Auth + protocol negotiation
  │     { minProtocol: 3,                  │
  │       maxProtocol: 3,                  │
  │       client: { ... },                 │
  │       auth: { token: "..." } }         │
  │                                        │
  │◄──── res: hello-ok ────────────────────│  (3) Connection established
  │      { protocol: 3,                   │
  │        server: { version, connId },    │
  │        features: { methods, events },  │
  │        policy: { maxPayload, ... } }   │
  │                                        │
  │──── req: chat.send ────────────────────►│  (4) Send user message
  │     { sessionKey, message,             │
  │       idempotencyKey }                 │
  │                                        │
  │◄──── res: { runId, status: "started" } │  (5) ACK
  │                                        │
  │◄──── event: chat (state: "delta") ─────│  (6) Streaming deltas (throttled ≤150ms)
  │◄──── event: chat (state: "delta") ─────│
  │◄──── event: chat (state: "delta") ─────│
  │                                        │
  │◄──── event: chat (state: "final") ─────│  (7) Complete response
  │                                        │
```

### Step 1: connect.challenge

Sent by the server immediately upon WebSocket connection:

```json
{
  "type": "event",
  "event": "connect.challenge",
  "payload": {
    "nonce": "550e8400-e29b-41d4-a716-446655440000",
    "ts": 1708000000000
  }
}
```

**Reference**: `src/gateway/server/ws-connection.ts:161-166`

### Step 2: connect Request

Client sends as the first (and only pre-auth) request:

```json
{
  "type": "req",
  "id": "req-001",
  "method": "connect",
  "params": {
    "minProtocol": 3,
    "maxProtocol": 3,
    "client": {
      "id": "super-voice-assistant",
      "displayName": "Super Voice Assistant",
      "version": "1.0.0",
      "platform": "macos",
      "mode": "operator"
    },
    "auth": {
      "token": "<OPENCLAW_TOKEN from .env>"
    }
  }
}
```

**ConnectParams schema** (from `src/gateway/protocol/schema/frames.ts:20-68`):

| Field | Type | Required | Description |
|---|---|---|---|
| `minProtocol` | integer | Yes | Minimum protocol version (use `3`) |
| `maxProtocol` | integer | Yes | Maximum protocol version (use `3`) |
| `client.id` | string | Yes | Client identifier |
| `client.displayName` | string | No | Human-readable name |
| `client.version` | string | Yes | Client version string |
| `client.platform` | string | Yes | `"macos"` |
| `client.mode` | string | Yes | `"operator"` |
| `client.instanceId` | string | No | Unique instance ID |
| `auth.token` | string | No | Shared secret token |
| `auth.password` | string | No | Shared secret password |
| `device.id` | string | No | Device ID (derived from public key) |
| `device.publicKey` | string | No | Base64-URL Ed25519 public key |
| `device.signature` | string | No | Base64-URL Ed25519 signature |
| `device.signedAt` | integer | No | Signature timestamp (ms) |
| `device.nonce` | string | No | Nonce from connect.challenge (required for non-local) |
| `caps` | string[] | No | Client capabilities |
| `commands` | string[] | No | Supported commands |
| `permissions` | Record | No | Permission flags |
| `role` | string | No | `"operator"` (default) |
| `scopes` | string[] | No | Permission scopes |
| `locale` | string | No | e.g., `"en-US"` |
| `userAgent` | string | No | User agent string |

**Handshake timeout**: 10 seconds (`src/gateway/server-constants.ts:DEFAULT_HANDSHAKE_TIMEOUT_MS`)

### Step 3: hello-ok Response

```json
{
  "type": "res",
  "id": "req-001",
  "ok": true,
  "payload": {
    "type": "hello-ok",
    "protocol": 3,
    "server": {
      "version": "0.x.x",
      "commit": "abc1234",
      "host": "hostname",
      "connId": "conn-uuid"
    },
    "features": {
      "methods": ["chat.send", "chat.abort", "chat.history", ...],
      "events": ["connect.challenge", "chat", "presence", "tick", ...]
    },
    "snapshot": { ... },
    "auth": {
      "deviceToken": "...",
      "role": "operator",
      "scopes": ["operator.admin"]
    },
    "policy": {
      "maxPayload": 26214400,
      "maxBufferedBytes": 52428800,
      "tickIntervalMs": 30000
    }
  }
}
```

**Key fields**:
- `snapshot`: Current system state snapshot (sessions, presence, etc.) — required in response but can be ignored by the voice assistant client
- `auth`: Present when device auth is used; contains `deviceToken` for reconnection
- `server.commit`, `server.host`: Optional server metadata
- `canvasHostUrl`: Optional, not relevant for voice assistant

**Reference**: `src/gateway/protocol/schema/frames.ts:70-113`

### Step 4: chat.send RPC

```json
{
  "type": "req",
  "id": "req-002",
  "method": "chat.send",
  "params": {
    "sessionKey": "voice-assistant",
    "message": "What's the weather like today?",
    "idempotencyKey": "unique-uuid-per-request"
  }
}
```

**ChatSendParams schema** (from `src/gateway/protocol/schema/logs-chat.ts:34-45`):

| Field | Type | Required | Description |
|---|---|---|---|
| `sessionKey` | string | Yes | Session identifier (groups conversation history) |
| `message` | string | Yes | User message text |
| `thinking` | string | No | Thinking content (prepended as `/think`) |
| `deliver` | boolean | No | Delivery flag |
| `attachments` | array | No | File attachments |
| `timeoutMs` | integer | No | Request timeout in milliseconds |
| `idempotencyKey` | string | Yes | Deduplication key (also used as `runId`) |

**Immediate response** (ACK):

```json
{
  "type": "res",
  "id": "req-002",
  "ok": true,
  "payload": {
    "runId": "unique-uuid-per-request",
    "status": "started"
  }
}
```

**Reference**: `src/gateway/server-methods/chat.ts:530-841`

### Step 5: chat Broadcast Events

**Delta** (streaming, throttled to max every 150ms):

```json
{
  "type": "event",
  "event": "chat",
  "payload": {
    "runId": "unique-uuid-per-request",
    "sessionKey": "voice-assistant",
    "seq": 1,
    "state": "delta",
    "message": {
      "role": "assistant",
      "content": [{ "type": "text", "text": "The weather today is..." }],
      "timestamp": 1708000001000
    }
  }
}
```

**Final** (complete response):

```json
{
  "type": "event",
  "event": "chat",
  "payload": {
    "runId": "unique-uuid-per-request",
    "sessionKey": "voice-assistant",
    "seq": 5,
    "state": "final",
    "message": {
      "role": "assistant",
      "content": [{ "type": "text", "text": "The weather today is sunny with a high of 72F." }],
      "timestamp": 1708000005000
    }
  }
}
```

**Error**:

```json
{
  "type": "event",
  "event": "chat",
  "payload": {
    "runId": "unique-uuid-per-request",
    "sessionKey": "voice-assistant",
    "seq": 2,
    "state": "error",
    "errorMessage": "Agent timeout exceeded"
  }
}
```

**Aborted** (via `chat.abort` RPC):

```json
{
  "type": "event",
  "event": "chat",
  "payload": {
    "runId": "unique-uuid-per-request",
    "sessionKey": "voice-assistant",
    "seq": 3,
    "state": "aborted",
    "message": { "text": "partial response so far..." }
  }
}
```

**ChatEvent schema** (from `src/gateway/protocol/schema/logs-chat.ts:64-81`):

| Field | Type | Description |
|---|---|---|
| `runId` | string | Matches the `idempotencyKey` from `chat.send` |
| `sessionKey` | string | Session identifier |
| `seq` | integer | Sequence number (0-indexed, per run) |
| `state` | enum | `"delta"` \| `"final"` \| `"aborted"` \| `"error"` |
| `message` | object? | Present for `delta`, `final`, `aborted`; absent for `error` |
| `message.role` | string | Always `"assistant"` |
| `message.content` | array | `[{ type: "text", text: "..." }]` |
| `message.timestamp` | number | Unix milliseconds |
| `errorMessage` | string? | Present only for `state: "error"` |
| `usage` | object? | Token usage stats (optional) |
| `stopReason` | string? | Why generation stopped (optional) |

**Reference**: `src/gateway/server-chat.ts:237-310`

### Tick Events (Keepalive)

The gateway sends `tick` events every 30 seconds. The client should handle these to detect connection health:

```json
{
  "type": "event",
  "event": "tick",
  "payload": { "ts": 1708000030000 }
}
```

### chat.abort RPC

To cancel an in-flight response:

```json
{
  "type": "req",
  "id": "req-003",
  "method": "chat.abort",
  "params": {
    "sessionKey": "voice-assistant",
    "runId": "unique-uuid-per-request"
  }
}
```

**Reference**: `src/gateway/protocol/schema/logs-chat.ts:47-53`

---

## 4. New Swift Files

| File | Location | Purpose |
|---|---|---|
| `OpenClawManager.swift` | `SharedSources/` | WebSocket client: connect, authenticate, send messages, receive streaming responses |
| `OpenClawResponseFilter.swift` | `SharedSources/` | Strip reasoning tags, `[[tts:...]]` directives, tool-call artifacts from response text |
| `KokoroTTSPlayer.swift` | `SharedSources/` | Native Kokoro TTS via FluidAudio `TtSManager`: synthesize text, play WAV via AVAudioEngine |
| `OpenClawOverlayWindow.swift` | `Sources/` | Floating overlay window to display response text (SwiftUI in NSPanel) |
| `OpenClawRecordingManager.swift` | `Sources/` | Coordinates recording -> STT -> OpenClaw send -> response -> overlay + TTS |

### File Details

#### `OpenClawManager.swift` (SharedSources/)

WebSocket client that manages the full connection lifecycle:

- **Connection**: `URLSessionWebSocketTask` to `OPENCLAW_URL`
- **Authentication**: Receive `connect.challenge`, send `connect` request with token auth
- **Sending**: `sendChat(text:sessionKey:)` — constructs `chat.send` RPC frame with UUID `idempotencyKey`
- **Receiving**: Listen loop parsing JSON frames, dispatching `chat` events to delegate/callback
- **Reconnection**: Auto-reconnect on disconnect with exponential backoff
- **State**: `isConnected`, `isAuthenticated` published properties
- **Cancellation**: `abortChat(runId:)` sends `chat.abort` RPC

Key types:

```swift
protocol OpenClawManagerDelegate: AnyObject {
    func openClawDidConnect()
    func openClawDidDisconnect(error: Error?)
    func openClawDidReceiveDelta(runId: String, text: String, seq: Int)
    func openClawDidReceiveFinal(runId: String, text: String, seq: Int)
    func openClawDidReceiveError(runId: String, message: String)
    func openClawDidReceiveAborted(runId: String, partialText: String?)
}
```

#### `OpenClawResponseFilter.swift` (SharedSources/)

Stateless text filtering (see [Section 5](#5-response-text-filtering) for rules):

```swift
struct OpenClawResponseFilter {
    static func filter(_ text: String) -> String
    static func filterForTTS(_ text: String) -> String  // Additional markdown stripping
}
```

#### `KokoroTTSPlayer.swift` (SharedSources/)

Native TTS playback using FluidAudio's Kokoro CoreML model:

```swift
class KokoroTTSPlayer {
    let ttsManager: TtSManager  // or PocketTtsManager
    let audioEngine: AVAudioEngine
    let playerNode: AVAudioPlayerNode
    var isCurrentlyPlaying: Bool

    func initialize() async throws
    func speak(_ text: String) async throws
    func stop()
}
```

- Calls `TtSManager.synthesize(text:)` to get WAV audio data (24kHz mono)
- Converts WAV data to `AVAudioPCMBuffer`
- Plays via `AVAudioEngine` + `AVAudioPlayerNode` (same pattern as `GeminiStreamingPlayer`)
- Optional `AVAudioUnitTimePitch` for speed adjustment
- Cancellation support via `Task.isCancelled`

#### `OpenClawOverlayWindow.swift` (Sources/)

Floating overlay for displaying responses (see [Section 6](#6-floating-overlay-window-design)).

#### `OpenClawRecordingManager.swift` (Sources/)

Orchestrator that ties everything together:

```swift
class OpenClawRecordingManager {
    var isRecording: Bool
    var isProcessing: Bool

    func toggleRecording()    // Start/stop audio capture
    func cancelRecording()    // Escape key handler

    // Internal flow:
    // 1. Start AudioTranscriptionManager recording
    // 2. On transcription complete -> send to OpenClawManager
    // 3. On response deltas -> update overlay, accumulate text
    // 4. On response final -> speak via KokoroTTSPlayer
    // 5. Save to TranscriptionHistory
}
```

---

## 5. Response Text Filtering

OpenClaw responses may contain artifacts that should **not** be displayed or spoken.

### Reasoning Tags

Tags stripped (case-insensitive, respecting code blocks):

| Tag | Closing |
|---|---|
| `<think>` | `</think>` |
| `<thinking>` | `</thinking>` |
| `<thought>` | `</thought>` |
| `<antthinking>` | `</antthinking>` |
| `<final>` | `</final>` |

**Note**: The gateway already strips these at the broadcast level (`src/gateway/server-chat.ts:11-12` — `stripChatText()` calls `stripReasoningTagsFromText()` with `mode: "preserve"`, `trim: "start"`). The client should also strip as a safety net for edge cases and partial tags.

**Implementation guidance** (from `src/shared/text/reasoning-tags.ts`):
- Quick-scan regex to skip text with no tags: `/<\s*\/?\s*(?:think(?:ing)?|thought|antthinking|final)\b/i`
- Protect content inside fenced code blocks (triple backticks) and inline code from stripping
- Strip trailing partial/unclosed tags
- In "strict" mode, remove content after unclosed opening tags; in "preserve" mode, keep it

### TTS Directives

Remove all `[[tts:...]]` patterns (from `src/tts/tts-core.ts:99-200`):

| Pattern | Example | Action |
|---|---|---|
| Bare tag | `[[tts]]` | Remove entirely |
| Text block | `[[tts:text]]spoken words[[/tts:text]]` | Remove tags and content |
| Parameter | `[[tts:provider=openai]]` | Remove entirely |
| Parameter | `[[tts:voice=af_heart]]` | Remove entirely |
| Parameter | `[[tts:speed=1.2]]` | Remove entirely |

**Regex for all TTS directives**: `\[\[/?tts(?::[\w=. ]+)?\]\]`

### Tool Call Artifacts

Strip content that represents tool invocations:

| Pattern | Description |
|---|---|
| `<tool_call>...</tool_call>` | XML-style tool call blocks |
| `<tool_result>...</tool_result>` | XML-style tool result blocks |
| Content blocks with `"type": "tool_use"` | JSON tool-use blocks in content array |
| `<function_call>...</function_call>` | Alternative tool call format |

### Markdown Stripping (TTS only)

For text sent to TTS (not for overlay display), additionally strip:

- Code blocks (` ```...``` `)
- Inline code (`` `...` ``)
- Headers (`# `, `## `, etc.) — remove the `#` prefix, keep text
- Bold/italic markers (`**`, `*`, `__`, `_`)
- Link syntax `[text](url)` — keep text, remove URL
- Image syntax `![alt](url)` — remove entirely
- HTML tags (`<br>`, `<p>`, etc.)

### Filter Pipeline

```
Raw response text
    │
    ├── stripReasoningTags()      // <thinking>, <thought>, etc.
    ├── stripTtsDirectives()      // [[tts:...]]
    ├── stripToolCallBlocks()     // <tool_call>, <tool_result>
    │
    ├── For overlay: return as-is (preserve markdown for display)
    │
    └── For TTS: stripMarkdownForSpeech()  // Additional cleanup
```

---

## 6. Floating Overlay Window Design

### Style

- **Type**: `NSPanel` (floating, non-activating — does not steal focus)
- **Level**: `.floating` (always on top of other windows)
- **Appearance**: Rounded corners (12pt), semi-transparent background (`.ultraThinMaterial`)
- **Size**: 400x200pt default, max 500x400pt
- **Position**: Bottom-right of screen (configurable: top-right, bottom-left, top-left)
- **Behavior**: Non-activating (`NSPanel.StyleMask.nonactivatingPanel`) — keyboard focus stays in the user's current app

### Content

SwiftUI view hosted in the `NSPanel`:

```swift
struct OpenClawOverlayView: View {
    @ObservedObject var viewModel: OpenClawOverlayViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: "OpenClaw" label + close button
            // Status indicator (recording/processing/speaking)
            // ScrollView with response text (streaming updates)
        }
        .padding(16)
        .frame(maxWidth: 500, maxHeight: 400)
    }
}
```

### States

| State | Display |
|---|---|
| Hidden | Window not shown (default) |
| Listening | "Listening..." with pulsing microphone icon |
| Processing | "Processing..." with animated dots |
| Streaming | Response text updating in real-time as deltas arrive |
| Speaking | Response text shown + audio playing indicator |
| Complete | Full response text, auto-dismiss timer running |

### Interaction

- **Click close button**: Dismiss immediately, stop TTS if playing
- **Drag title area**: Reposition window
- **Auto-dismiss**: Configurable delay after TTS finishes (default: 5 seconds, 0 = never)
- **Escape**: Dismiss and cancel any in-flight request

### Framework

```swift
class OpenClawOverlayWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled, .closable, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        self.level = .floating
        self.isMovableByWindowBackground = true
        self.hidesOnDeactivate = false
        self.contentView = NSHostingView(rootView: OpenClawOverlayView(viewModel: viewModel))
        // Position in bottom-right corner
    }
}
```

---

## 7. Kokoro TTS (Native CoreML via FluidAudio)

### Why Kokoro via FluidAudio

[FluidAudio](https://github.com/FluidInference/FluidAudio) — the **same Swift library already used for Parakeet STT** — also ships Kokoro TTS as a native CoreML model. This means:

- Same library already in `Package.swift` (`FluidAudio.git >= 0.7.9`, resolved to 0.10.1)
- Same model download mechanism as Parakeet (`TtSManager.initialize()` auto-downloads)
- Native Swift/CoreML — runs on Apple Neural Engine
- 82M params, 23x real-time on M4 Pro, 1.5GB peak RAM
- 48 voices, SSML/phoneme control
- No Python, no subprocess, no external service

### Model

- HuggingFace: [FluidInference/kokoro-82m-coreml](https://huggingface.co/FluidInference/kokoro-82m-coreml)
- Cache location: `~/.cache/fluidaudio/Models/kokoro/` (managed by FluidAudio)
- Compilation: `.mlpackage` -> `.mlmodelc` on first load (one-time)

### Alternative: PocketTTS

[PocketTTS](https://docs.fluidinference.com/tts/pocket-tts.md) is another option via FluidAudio:
- 155M params, ~80ms first audio latency
- No espeak dependency (simpler setup)
- Fewer voices but streaming support
- Works with the default `FluidAudio` product (no `FluidAudioTTS` needed)

### Swift API

```swift
import FluidAudioTTS  // or FluidAudio for PocketTTS

// --- Kokoro ---
let ttsManager = TtSManager()
try await ttsManager.initialize()  // Downloads model on first use

// Simple synthesis (returns WAV Data, 24kHz mono)
let audioData = try await ttsManager.synthesize(text: "Hello from OpenClaw!")

// Detailed synthesis with chunk info
let detailed = try await ttsManager.synthesizeDetailed(
    text: "Longer text here...",
    variantPreference: .fifteenSecond
)

// --- PocketTTS alternative ---
let pocketManager = PocketTtsManager()
try await pocketManager.initialize()
let audioData = try await pocketManager.synthesize(text: "Hello!")
```

### Package.swift Change

For Kokoro TTS, the `FluidAudioTTS` product is needed (adds ESpeakNG framework, GPL-3.0 license):

```swift
// In target dependencies, use FluidAudioTTS instead of FluidAudio:
.target(
    name: "SharedModels",
    dependencies: ["WhisperKit", "FluidAudioTTS"],  // Changed from "FluidAudio"
    path: "SharedSources"),
```

For PocketTTS, no change is needed — it works with the existing `FluidAudio` product.

### Model State Management

Add to `Sources/ModelStateManager.swift` (matching the Parakeet pattern):

```swift
// New published properties (matching Parakeet pattern from ModelStateManager.swift:50-58)
@Published var kokoroTtsLoadingState: ParakeetLoadingState = .notDownloaded
@Published var loadedTtsManager: TtSManager? = nil  // or PocketTtsManager

// Reuse existing ParakeetLoadingState enum:
// .notDownloaded, .downloading, .downloaded, .loading, .loaded
```

New methods (matching `loadParakeetModel()` pattern from `ModelStateManager.swift:324-388`):

```swift
func loadKokoroTtsModel() async {
    kokoroTtsLoadingState = .downloading  // FluidAudio handles download
    let manager = TtSManager()
    try await manager.initialize()
    loadedTtsManager = manager
    kokoroTtsLoadingState = .loaded
}

func unloadKokoroTtsModel() {
    loadedTtsManager = nil
    kokoroTtsLoadingState = .notDownloaded  // or .downloaded if cached
}
```

Persist selection in UserDefaults:

```swift
// New UserDefaults keys:
// "selectedTtsProvider" -> "kokoro" | "gemini"
// "selectedKokoroVoice" -> "af_heart" (default)
```

### Audio Playback

`KokoroTTSPlayer.swift` design (reuses pattern from `GeminiStreamingPlayer.swift:11-24`):

```swift
class KokoroTTSPlayer {
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitchEffect = AVAudioUnitTimePitch()
    private let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!

    @Published var isCurrentlyPlaying = false
    private var playbackTask: Task<Void, Error>?

    init(playbackSpeed: Float = 1.0) {
        timePitchEffect.rate = playbackSpeed
        audioEngine.attach(playerNode)
        audioEngine.attach(timePitchEffect)
        audioEngine.connect(playerNode, to: timePitchEffect, format: audioFormat)
        audioEngine.connect(timePitchEffect, to: audioEngine.mainMixerNode, format: audioFormat)
    }

    func speak(_ text: String) async throws {
        guard let ttsManager = ModelStateManager.shared.loadedTtsManager else {
            // Fallback to Gemini TTS if configured
            throw KokoroTTSError.modelNotLoaded
        }
        isCurrentlyPlaying = true
        defer { isCurrentlyPlaying = false }

        let audioData = try await ttsManager.synthesize(text: text)
        let buffer = try createPCMBuffer(from: audioData)
        try audioEngine.start()
        playerNode.scheduleBuffer(buffer) { [weak self] in
            self?.isCurrentlyPlaying = false
        }
        playerNode.play()
    }

    func stop() {
        playbackTask?.cancel()
        playerNode.stop()
        audioEngine.stop()
        isCurrentlyPlaying = false
    }

    private func createPCMBuffer(from wavData: Data) throws -> AVAudioPCMBuffer {
        // Parse WAV header, extract PCM samples
        // Convert Int16 -> Float32 (same as GeminiStreamingPlayer.swift:200-221)
        // Return AVAudioPCMBuffer at 24kHz mono
    }
}
```

### Settings UI

Add a new model card to `Sources/ModelCardViews.swift` (same style as `ParakeetModelCard`):

- TTS model card with download/load button and loading indicator
- Voice selector dropdown (48 Kokoro voices, default: `af_heart`)
- TTS provider toggle: Kokoro (local CoreML) vs Gemini (cloud)
- "Test" button to play sample audio ("Hello, this is a test of Kokoro text-to-speech.")

---

## 8. Configuration via .env

Add to the existing `.env` pattern (loaded by `loadEnvironmentVariables()` in `main.swift:12-33`):

```env
# OpenClaw connection
OPENCLAW_URL=ws://127.0.0.1:18789
OPENCLAW_TOKEN=your-gateway-token
OPENCLAW_SESSION_KEY=voice-assistant
OPENCLAW_AUTO_TTS=true

# Kokoro TTS (native CoreML via FluidAudio)
KOKORO_VOICE=af_heart
TTS_PROVIDER=kokoro
```

| Variable | Default | Description |
|---|---|---|
| `OPENCLAW_URL` | `ws://127.0.0.1:18789` | Gateway WebSocket URL |
| `OPENCLAW_TOKEN` | (none) | Auth token for gateway connection |
| `OPENCLAW_SESSION_KEY` | `voice-assistant` | Session key for conversation grouping |
| `OPENCLAW_AUTO_TTS` | `true` | Automatically speak responses via TTS |
| `KOKORO_VOICE` | `af_heart` | Kokoro voice ID (48 available) |
| `TTS_PROVIDER` | `kokoro` | `kokoro` (local CoreML) or `gemini` (cloud fallback) |

Update `.env.example` to include these new variables.

---

## 9. Integration Points in Existing Code

### main.swift (AppDelegate)

**Keyboard shortcut registration** (after line 41):

```swift
static let openclawRecording = Self("openclawRecording")
```

**Default binding** (after line 112):

```swift
KeyboardShortcuts.setShortcut(.init(.o, modifiers: [.command, .option]), for: .openclawRecording)
```

**New instance variables** (alongside existing managers around line 44-50):

```swift
private var openClawManager: OpenClawManager?
private var openClawRecordingManager: OpenClawRecordingManager?
private var kokoroTTSPlayer: KokoroTTSPlayer?
private var openClawOverlay: OpenClawOverlayWindow?
```

**Initialization** (in `applicationDidFinishLaunching`, after line 199):

```swift
// Initialize OpenClaw if configured
if let openClawURL = ProcessInfo.processInfo.environment["OPENCLAW_URL"] {
    openClawManager = OpenClawManager(url: openClawURL)
    openClawRecordingManager = OpenClawRecordingManager(
        openClawManager: openClawManager!,
        audioManager: audioManager
    )
    kokoroTTSPlayer = KokoroTTSPlayer()
    openClawOverlay = OpenClawOverlayWindow()
}
```

**Shortcut handler** (after line 191):

```swift
KeyboardShortcuts.onKeyUp(for: .openclawRecording) { [weak self] in
    guard let self = self else { return }

    // Mutual exclusion with screen recording
    if self.screenRecorder.recording {
        // Show notification: "Cannot start — screen recording is active"
        return
    }
    // Mutual exclusion with WhisperKit recording
    if self.audioManager.isRecording {
        // Show notification: "Cannot start — WhisperKit recording is active"
        return
    }
    // Mutual exclusion with Gemini recording
    if self.geminiAudioManager.isRecording {
        // Show notification: "Cannot start — Gemini recording is active"
        return
    }

    self.openClawRecordingManager?.toggleRecording()
}
```

**Menu item** (in menu setup, before the Quit item):

```swift
menu.addItem(NSMenuItem(title: "OpenClaw: Press Command+Option+O", action: nil, keyEquivalent: ""))
```

### Reuse from Existing Code

| Component | Source | Reuse Pattern |
|---|---|---|
| Audio capture + STT | `AudioTranscriptionManager` | Reuse recording + transcription flow; instead of pasting text, send to OpenClaw |
| Primary TTS | `KokoroTTSPlayer` (new) | Native CoreML via FluidAudio `TtSManager` |
| Fallback TTS | `GeminiStreamingPlayer` + `GeminiAudioCollector` | Optional cloud fallback when Kokoro unavailable |
| Status bar levels | `updateStatusBarWithLevel()` (main.swift:581-608) | Same dB -> bar visualization during recording |
| Processing indicator | `startTranscriptionIndicator()` (main.swift:610-642) | Same animated "Processing..." display |
| History | `TranscriptionHistory.shared.addEntry()` | Save OpenClaw Q&A pairs |
| Sentence splitting | `SmartSentenceSplitter` (SharedSources/) | Split long responses for TTS chunks |
| Audio format | 24kHz mono (same as Gemini) | Same `AVAudioFormat` and buffer conversion |

---

## 10. Data Flow Diagram

```
User presses Cmd+Option+O
        │
        ▼
OpenClawRecordingManager.toggleRecording()
        │
        ├── If not recording: start
        │       │
        │       ▼
        │   AudioTranscriptionManager.startRecording()
        │     (reuse existing audio capture)
        │       │
        │       ├── Status bar: live audio level (● ████▁▁▁▁)
        │       │
        │       ▼
        │   OpenClawOverlayWindow.show(state: .listening)
        │
        └── If recording: stop
                │
                ▼
        AudioTranscriptionManager.stopRecording()
                │
                ▼
        STT transcription (WhisperKit or Parakeet)
          based on ModelStateManager.shared.selectedEngine
                │
                ▼
        OpenClawRecordingManager receives transcribed text
                │
                ▼
        OpenClawOverlayWindow.update(state: .processing)
          Status bar: "⚙️ Processing..."
                │
                ▼
        OpenClawManager.sendChat(text, sessionKey)
          WebSocket → chat.send RPC
          { sessionKey, message, idempotencyKey: UUID() }
                │
                ▼
        Listen for "chat" broadcast events:
                │
                ├── state: "delta" (every ≤150ms)
                │     │
                │     ▼
                │   OpenClawResponseFilter.filter(deltaText)
                │     │
                │     ▼
                │   OpenClawOverlayWindow.update(state: .streaming, text: filtered)
                │
                ├── state: "final"
                │     │
                │     ▼
                │   OpenClawResponseFilter.filter(finalText)
                │     │
                │     ├── Overlay: show complete filtered text
                │     │
                │     ├── History: TranscriptionHistory.shared.addEntry(...)
                │     │
                │     ▼
                │   OpenClawResponseFilter.filterForTTS(finalText)
                │     │
                │     ▼
                │   KokoroTTSPlayer.speak(ttsText)
                │     TtSManager.synthesize(text:) → WAV data (24kHz mono)
                │     Native CoreML inference on Apple Neural Engine
                │     WAV → AVAudioPCMBuffer → AVAudioEngine playback
                │     (fallback: GeminiStreamingPlayer if Kokoro unavailable)
                │     │
                │     ▼
                │   Auto-dismiss overlay after TTS completes
                │     (configurable delay, default 5 seconds)
                │
                ├── state: "error"
                │     │
                │     ▼
                │   OpenClawOverlayWindow.update(state: .error, text: errorMessage)
                │   Status bar: reset to idle icon
                │
                └── state: "aborted"
                      │
                      ▼
                    OpenClawOverlayWindow.dismiss()
                    Status bar: reset to idle icon
```

---

## 11. Settings Tab Addition

Add an **"OpenClaw"** section to `Sources/UnifiedManagerWindow.swift` (new tab, after Audio Devices):

### Tab Structure

```
┌──────────────────────────────────────────────────────┐
│  Settings │ History │ Statistics │ Audio │ OpenClaw   │
├──────────────────────────────────────────────────────┤
│                                                      │
│  ┌─ Connection ─────────────────────────────────────┐│
│  │  Server URL:  [ws://127.0.0.1:18789          ]  ││
│  │  Auth Token:  [••••••••••••••                 ]  ││
│  │  Session Key: [voice-assistant                ]  ││
│  │  Status:      ● Connected                        ││
│  │  [Test Connection]                                ││
│  └──────────────────────────────────────────────────┘│
│                                                      │
│  ┌─ Kokoro TTS ─────────────────────────────────────┐│
│  │  ┌─────────────────────────────────────────────┐ ││
│  │  │  Kokoro TTS (82M)                           │ ││
│  │  │  Native CoreML • 48 voices • 24kHz          │ ││
│  │  │  ████████████████████ 100% ✓ Loaded         │ ││
│  │  └─────────────────────────────────────────────┘ ││
│  │                                                   ││
│  │  Provider:  (●) Kokoro (local)  ( ) Gemini       ││
│  │  Voice:     [af_heart                  ▼]        ││
│  │  Auto-TTS:  [✓]                                  ││
│  │  [Test TTS]                                       ││
│  └──────────────────────────────────────────────────┘│
│                                                      │
└──────────────────────────────────────────────────────┘
```

### TTS Model Card

Same UX pattern as the Parakeet model card in `Sources/ModelCardViews.swift`:

- Download/load button with loading indicator
- Model auto-downloads via FluidAudio on first `initialize()`, same as Parakeet
- Progress states: Not Downloaded -> Downloading -> Downloaded -> Loading -> Loaded
- Size and performance info displayed

### Voice Options (Kokoro)

48 voices available. Common choices:

| Voice ID | Description |
|---|---|
| `af_heart` | Default, warm female |
| `af_bella` | Female, clear |
| `af_sarah` | Female, professional |
| `am_adam` | Male, neutral |
| `am_michael` | Male, warm |
| `bf_emma` | British female |
| `bm_george` | British male |

### Settings Persistence

All settings stored via UserDefaults (matching existing pattern):

| Key | Default | Type |
|---|---|---|
| `openClawUrl` | `ws://127.0.0.1:18789` | String |
| `openClawToken` | (none) | String |
| `openClawSessionKey` | `voice-assistant` | String |
| `openClawAutoTts` | `true` | Bool |
| `selectedTtsProvider` | `kokoro` | String |
| `selectedKokoroVoice` | `af_heart` | String |

---

## Appendix A: Device Auth (Ed25519) — Advanced

For remote connections requiring device-level authentication (not needed for local token auth):

### Signature Payload Format

```
v2|<deviceId>|<clientId>|<clientMode>|<role>|<scopes>|<signedAtMs>|<token>|<nonce>
```

- `deviceId`: Derived from Ed25519 public key
- `clientId`: `"super-voice-assistant"`
- `clientMode`: `"operator"`
- `role`: `"operator"`
- `scopes`: comma-separated (e.g., `"operator.admin"`)
- `signedAtMs`: Current timestamp in milliseconds
- `token`: Auth token or empty string
- `nonce`: UUID from `connect.challenge` event

### Signature Clock Skew

Signatures must be within ±10 minutes of server time.

**Reference**: `src/gateway/device-auth.ts:1-32`, `src/gateway/server/ws-connection/message-handler.ts:478-616`

---

## Appendix B: Gateway Server Constants

| Constant | Value | Reference |
|---|---|---|
| Default port | `18789` | `server.impl.ts:162` |
| Protocol version | `3` | `protocol-schemas.ts:262` |
| Handshake timeout | 10,000ms | `server-constants.ts` |
| Max payload | 25 MB | `server-constants.ts` |
| Max buffered bytes | 50 MB per connection | `server-constants.ts` |
| Tick interval | 30,000ms | `server-constants.ts` |
| Dedupe TTL | 5 minutes | `server-constants.ts` |
| Delta throttle | 150ms | `server-chat.ts:245` |
| Signature skew tolerance | 10 minutes | `device-auth.ts` |

---

## Appendix C: Existing Keyboard Shortcuts Reference

| Shortcut | Name | Action | File:Line |
|---|---|---|---|
| `Cmd+Opt+Z` | `startRecording` | WhisperKit/Parakeet audio recording | `main.swift:107` |
| `Cmd+Opt+X` | `geminiAudioRecording` | Gemini API audio recording | `main.swift:108` |
| `Cmd+Opt+A` | `showHistory` | Show transcription history | `main.swift:109` |
| `Cmd+Opt+S` | `readSelectedText` | Read selected text (TTS) | `main.swift:110` |
| `Cmd+Opt+C` | `toggleScreenRecording` | Toggle screen recording | `main.swift:111` |
| `Cmd+Opt+V` | `pasteLastTranscription` | Paste last transcription | `main.swift:112` |
| **`Cmd+Opt+O`** | **`openclawRecording`** | **OpenClaw voice interaction** | **(new)** |
