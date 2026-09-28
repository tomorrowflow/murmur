# add-client-test — Reference

## XCTest file template (Tier A)

```swift
import XCTest
@testable import SharedModels

final class <UseCaseName>Tests: XCTestCase {

    // Private helpers build fixtures in-memory. No disk, no network, no live audio.
    private func fixture(_ raw: String) -> Data { Data(raw.utf8) }

    func test<Behavior>() {
        let result = TypeUnderTest.method(fixture("..."))
        XCTAssertEqual(result?.field, expected)
    }

    func test<EdgeCase>() {
        XCTAssertNil(TypeUnderTest.method(fixture("garbage")))
    }
}
```

Rules that keep parallel workers conflict-free and consistent with the repo:

- **One new file per worker.** Name it `<UseCaseName>Tests.swift`. Never edit `HTTPRequestParserTests.swift`, `StreamingResamplerTests.swift`, `STTHallucinationFilterTests.swift`, or another worker's file.
- **Never edit `Package.swift`** — the `SharedModelsTests` target globs the directory.
- **`final class … : XCTestCase`**, methods prefixed `test`, assertions `XCTAssertEqual / Nil / NotNil / True / False / GreaterThan / LessThanOrEqual`.
- **In-memory fixtures only.** `StreamingResamplerTests` generates a synthetic 440 Hz sine `AVAudioPCMBuffer` via a private `makeBuffer(sampleRate:frames:channels:)`; copy that approach for audio. No WAV files, no `.env`, no API keys.
- **Tolerances for float/DSP**: assert ranges, not exact equality (see `StreamingResamplerTests.test44100DownsamplesToCorrectRatio` allowing ±priming-latency frames).
- **Async**: XCTest here is synchronous. For an async API under test, drive it with `XCTestExpectation` + `wait(for:timeout:)`. Do not make the test method `async` unless you've confirmed the toolchain runs it (the existing suite avoids it).

### Real examples to mirror

- `tests/SharedModelsTests/HTTPRequestParserTests.swift` — pure parsing, `Data` fixtures, edge cases (binary body, slices, truncation).
- `tests/SharedModelsTests/StreamingResamplerTests.swift` — DSP with synthetic buffers and tolerance-based assertions, regression cases (mid-stream format change, stereo mixdown).
- `tests/SharedModelsTests/STTHallucinationFilterTests.swift` — heuristic classification, positive/negative/normalization groups.

### Verify your test

```bash
swift test --filter <UseCaseName>Tests
```

Builds serialize on SPM's package lock, so parallel workers won't corrupt `.build` — a worker may just wait for the lock. Iterate until green before reporting.

## EXTRACTION report (Tier B)

The use case's logic is in the un-importable `Murmur` target. Report — do not perform — the extraction:

```
TIER B — EXTRACTION NEEDED
Use case: <restate>
Logic currently in: Sources/<file>.swift  (type/function: <names>, ~lines L–L)
Extract to: SharedSources/<NewType>.swift
What to extract: <the pure logic — the decision/transform, not the AppKit/UI glue>
Seam required: <e.g. wrap NWConnection / AVAudioEngine / FileManager behind a protocol so the
  extracted type takes an injectable dependency and the test can supply a fake>
Blocking deps still in Sources/: <types that must move or be parameterized>
Test I would then write (Tier A): <one-line description + which assertions>
```

Why a worker must not do this: extraction edits `Sources/` (often `main.swift`) and `SharedSources/`, which every parallel worker shares — concurrent edits collide. The orchestrator batches all Tier-B extractions in one serial pass, then re-runs workers as Tier A.

## HARNESS report (Tier C)

The case is only reachable through the running app UI or real I/O. Report the setup:

```
TIER C — HARNESS NEEDED
Use case: <restate>
Reachable only via: <menu-bar UI / overlay window / live mic / live network>
Proposed harness:
  - For UI: an Xcode project (.xcodeproj) with a UI Test bundle target that launches the built
    Murmur.app and drives it through XCUIApplication + accessibility identifiers. SPM cannot host
    a UI test target, so this lives outside the package or in a generated project.
    App changes likely needed: accessibility identifiers on the overlay/menu controls under test.
  - For live I/O: a new tests/test-<name>/main.swift executable target (pattern: @main struct,
    async main(), real frameworks) — matches existing tests/test-live-transcription etc.
    These are run manually via `swift run`, not asserted in CI.
Why not unit-testable: <names the AppKit/CoreAudio/Network dependency that can't be faked at unit level>
What the orchestrator must add: <xcodeproj + UI target, OR Package.swift executable target + dir>
```

## Structured result block (always last in your output)

```json
{
  "tier": "A | B | C",
  "useCase": "<verbatim use case>",
  "status": "implemented | needs-setup",
  "file": "tests/SharedModelsTests/<Name>Tests.swift | null",
  "testsPassing": true | false | null,
  "setupNeeded": "null, or a one-paragraph summary of the EXTRACTION/HARNESS report above"
}
```

`status: implemented` requires a green `swift test --filter`. Otherwise `needs-setup` with `setupNeeded` filled in.
