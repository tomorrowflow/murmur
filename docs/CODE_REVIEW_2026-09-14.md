# Code review — 2026-09-14

Full-source review of `Sources/` and `SharedSources/`, and the fixes applied for it. Everything listed under a "Fixed" heading is in the working tree and builds; `swift test` passes 54 tests. The closing section lists what was deliberately left alone.

## Fixed in this pass: Apple Music launching on overlay close

Root cause was structural, not a missing denylist entry. A MediaRemote `Play` sent while no app owns Now Playing makes macOS launch the default player. Three paths let `didPause` stay `true` with nothing actually paused:

1. `MediaRemoteController.anyMediaPlayerActive()` treated every non-denylisted process with `IsRunningOutput=true` as a media player. A notification chime from any app during a TTS session set `didPause` with nothing paused.
2. Natural Read Aloud completion never called `resumeIfWePaused()`, and the overlay's auto-dismiss only hid the panel. `readAloudManager` stayed non-nil, so `isAudioBusy()` reported busy indefinitely (queued recaps stalled) and the pause flag carried into later sessions.
3. A playback task cancelled by `stop()` could still reach `pause()` after its MainActor hop, cancelling the resume `reset()` had just scheduled.

Changes:

- `MediaRemoteController`: allowlist of known native players (extend with `defaults write com.murmur.app audio.mediaPlayerBundleIDs -array <id>`); records pid + bundle of the paused player; `Play` is only sent if that process is still running with the same bundle id; all state behind an `NSLock`.
- `ReadAloudManager`: `Task.checkCancellation()` immediately before `pause()`; `resumeIfWePaused()` on natural completion.
- `ReadAloudOverlayWindow`: auto-dismiss runs the full `onStop` chain.
- `AppDelegate+ReadAloud`: new `tearDownReadAloudSession()` used by X/Escape, Cmd+Opt+S, `stopCurrentPlayback` and auto-dismiss (clears recap state, drains queue).
- `AppDelegate+PushToTalk`: PTT interrupt of a recap clears `pendingAutoRecordAfterReadAloud`/`recapTarget*`.
- `DraftEditingManager`: same cancellation re-check before `pause()`.
- `PodcastManager`: resume media on `.complete`/`.error`/`.disconnected`.

Behavior change: browsers were already never paused (their helpers were denylisted). Players not on the allowlist are now left alone instead of paused; Console (subsystem `com.murmur.app`, category `MediaRemote`) logs which running-output processes were ignored.

## Fixed — crashes and data loss

| Area | Fix |
|---|---|
| Draft editing paragraph indices | Bounds-checked after re-parse in `processEdit`; undo now resolves its paragraph by matching the text the edit produced (`resolveParagraphIndex`) instead of trusting a stored index that shifts when an earlier edit changes the paragraph count. |
| TextMate highlight range | Both ends clamped, so a file that shrank no longer traps on an inverted `Range`. |
| Paragraph replacement | Rejects `start > end`; new `expectedOriginal` parameter verifies the lines being replaced still hold the expected text, which the modification-date check could not (it was captured right after the caller's own write). |
| Accessibility casts | New `AXSafe` helper checks `CFGetTypeID` before every cast. Replaces eight `as! AXUIElement` / `as! AXValue` sites across paste, push-to-talk, the editor adapter and the cursor overlay. |
| Cursor line from TextMate | Converts the Accessibility UTF-16 offset correctly; it was being applied as a Character offset. |
| LLM server URL | `URL(string:)` on the user-typed server field is no longer force-unwrapped; a malformed URL surfaces as `LLMClientError.invalidURL`. |
| Call-capture microphone | Writes and teardown share a lock, so the audio file can't be released under an in-flight write, and the tail of the recording is flushed before the file closes. |
| Segmentation cap loop | The cut point is clamped to advance past `start`, so a small `maxSegmentSeconds` can no longer loop appending empty regions. Covered by `TranscriptionPipelineSegmentationTests`. |
| Voice sample picker | `UTType(filenameExtension:)` no longer force-unwrapped. |

## Fixed — state that used to get stuck

| Area | Fix |
|---|---|
| Empty transcription result | An empty WhisperKit result now reports silence through the delegate, so the overlay clears and the recap queue keeps draining. |
| Prompt refinement | 15-second deadline; on timeout the raw transcription is pasted instead of the session hanging. |
| OpenClaw push-to-talk | Releasing during Bluetooth warm-up clears `onMicReady` and `bluetoothWarmingUp`, matching the speech-to-text path. |
| OpenClaw runs | One `endProcessing()` path for every terminal case, a 120-second no-response watchdog re-armed on each delta, and a gateway disconnect mid-run now fails the run instead of leaving it "thinking" forever. Escape stays live through the request phase. |
| Call transcription | File-input mode respects the busy flag and returns HTTP 409 instead of silently replacing the capture flow's completion handler. |
| Screen recorder | Reads the pipe before waiting (no deadlock on a long device list), clears `isRecording` from a termination handler, and waits for exit before inspecting the output file. |
| Draft editing sessions | A new session tears down any previous one; `.error` now tears down like `.idle` after a readable delay. |
| Podcast | Buffering watchdog asks for the chunk actually awaited and gives up after four attempts; the deferred INGEST and `cancelInterrupt` can no longer revive a stopped session; a failed replay clears `isReplaying`; pause no longer duplicates a chunk's audio and transcript; a superseded player's finish callback is ignored; resume continues the transcript highlight from the playback position. |
| Audio engine | A failed tap install at start enters the codec-switch recovery loop instead of running a tapless engine; both failure callbacks are session-guarded so a stale one can't clear `isRecording` under a live engine. |
| Settings | The model scan and the incomplete-download sweep run in order rather than racing. |
| Call capture microphone | Registers an `AVAudioEngineConfigurationChange` observer, reinstalls the tap, and rolls to `mic-<n>.wav` with an offset when the format changes — the same strategy the far end already used. |

## Fixed — concurrency, leaks and bundled-build correctness

- **Input device override** is now refcounted by owner, so stopping one recording no longer switches the system default input out from under another. Non-main callers read a locked device snapshot instead of the `@Published` arrays.
- **Device lookups** cache UID → device id and device id → Bluetooth, invalidated by the existing device-change listener. These ran on every push-to-talk tone.
- **LLM streaming** cancels the underlying request when the consumer stops, and `<think>` filtering moved to a new incremental `ThinkBlockFilter` — the old whole-string regex let an unterminated reasoning block stream into the overlay and the speech queue.
- **Draft editing highlights** are serialised through one chain, and edits wait for it to settle before re-parsing.
- **HTTP server** confines listener state to its queue; `/draft/status` and `/draft/start` read manager state on the main actor.
- **Claude host registry** posts its change notification on the main thread, caches the decoded approved list, caps the pending list at 50, and serialises reverse-DNS lookups on one queue.
- **Deinit cleanup** added to the read-aloud and draft-editing overlays and to the read-aloud, draft-editing and podcast managers. A leaked local Escape monitor swallowed Escape app-wide.
- **OpenClaw status** is multicast, so opening the settings tab no longer steals the menu-bar status handler.
- **Test Voice** retains its `NSSound` for the duration of playback.
- **AppNotifier** detects a real `.app` bundle instead of a non-nil bundle identifier.
- **LLM server token** moved to `SecretsStore` (migrates the existing plaintext value on first read).
- **Text replacements** look for `config.json` in the working directory, then the bundle resources, then `~/Library/Application Support/Murmur/`. Note `build.sh` does not copy `config.json` into the bundle, so a bundled install reads the Application Support copy.
- **Unified manager window** hosts `SettingsView` directly instead of stealing another window's content view behind three force unwraps.

## Fixed — performance

| Area | Fix |
|---|---|
| Audio tap | Level metering throttled to 20 Hz (it ran per buffer, ~47 Hz), and the resampler reuses its output buffer instead of allocating one per callback. |
| Call capture | The peak scan is skipped when the 20 Hz gate would discard it; the far-end scan now verifies the format is Float32. |
| Push-to-talk tones | Rendered once and cached per tone + lead-in; concurrent tones each keep their own player. |
| Transcription history | Saves are debounced, encoded and written atomically on a background queue, and flushed on termination. The file path is resolved once. |
| OpenClaw response filter | All eleven regexes compiled once and cached; the dead "protect code blocks" pass removed. |
| Sentence splitting | The splitter runs only when the new token could actually complete a sentence, and its regex is compiled once. |
| Read aloud / draft editing | Audio plays from memory instead of a temp file per sentence; silence blobs are memoised; retained export audio is capped at 150 MB. |
| Podcast | Session-end audio assembly moved off the main thread; transcript rows use a published index map instead of two linear scans each. |
| Model state | Whisper validation loads are serialised behind an async semaphore; Parakeet on-disk state is cached instead of stat-ed inside a SwiftUI body; `ModelData.availableModels` is built once. |
| Overlays | The speech-to-text overlay populates its paste target once per session rather than on every level callback; the OpenClaw overlay is only touched when its state actually changes. |
| History window | Removed a per-row preview render whose result was discarded, and replaced three full scans with one counting pass. |

## Not changed, and why

- **`ScreenRecorder.swift`, `VideoTranscriber.swift`, `VPIORecorder.swift` are unreferenced.** Nothing in `Sources/`, `SharedSources/` or `tests/` mentions them. The two cheap correctness bugs in the screen recorder were fixed anyway; the video transcriber's memory profile and `.env` lookup, and the VPIO recorder's duck/restore device mismatch, are left alone. Deleting the three files is the real fix and is your call.
- **`build.sh` still does not copy `config.json`** into the bundle. Copying it would shadow the user-editable Application Support copy, which is the same trade-off `.env` already makes.
- **Token auth for the HTTP server**, full `@MainActor` isolation of the read-aloud and draft-editing managers, the audio-ownership enum, and the typed `UserDefaults` namespace remain deliberately deferred from the June review.

## Test coverage added

`swift test` runs 54 tests (was 27). New suites:

- `ThinkBlockFilterTests` — 9 tests, including the unterminated block and tags split across chunks.
- `SmartSentenceSplitterTests` — 7 tests, including the all-caps false positive and combining-mark input.
- `TranscriptionPipelineSegmentationTests` — 6 tests, including the cap-loop regression.
- `HTTPRequestParserIncrementalScanTests` — 5 tests for the offset-based header scan.

Still uncovered and worth filling: `TranscriptionPipeline.loadMono16k` and `renderMarkdown`, and `MarkdownParagraphParser` (it lives in the app target, so it needs moving to `SharedSources` before it can be tested).
