---
name: add-client-test
description: Implement one client-side (macOS/Swift) test case for a single given use case, designed to be fanned out in parallel — one skill instance per use case. Classifies the use case's testability, writes an XCTest in tests/SharedModelsTests/ when the code already lives in the SharedModels library, and otherwise emits a structured SETUP REPORT telling the orchestrator what extraction or XCUITest harness must be built first (it does not perform that shared setup itself). Use when adding client/app test coverage to the Murmur app, building tests for a list of use cases, or running parallel test-implementation agents.
---

# add-client-test

Implement **one** client-side test case for **one** use case. Built to run as a parallel worker (a fork/subagent per use case). The orchestrator owns shared setup; you own a single test file or a single report.

## The one hard constraint

Only the **`SharedModels`** library (`SharedSources/*.swift`) is unit-testable. The `Murmur` executable target (`Sources/*.swift` — AppDelegate, managers, overlays, UI) **cannot be imported by tests**. There is **no Xcode project**, so XCUITest cannot run without harness setup that SPM can't host. Everything below follows from this.

`tests/SharedModelsTests/` is glob-included by the `SharedModelsTests` testTarget — a new `.swift` file there is picked up automatically. **You never edit `Package.swift`.**

## Step 1 — Classify the use case into a tier

| Tier | When | Your action |
|------|------|-------------|
| **A — Unit-ready** | The logic under test already lives in `SharedSources/` (a parser, filter, splitter, resampler, store, pure transform). | Write the test now (Step 2). |
| **B — Needs extraction** | The logic lives in `Sources/` (AppDelegate, a `*Manager`, state machine, overlay). | **Do not** move code. Emit an EXTRACTION report (Step 3). |
| **C — UI / live-I/O** | The case can only be exercised through the running app UI (menu bar, overlay windows) or real audio/network I/O. | **Do not** build a harness. Emit a HARNESS report (Step 3). |

Find where the logic lives before deciding: grep `SharedSources/` and `Sources/` for the types named in the use case. When in doubt between A and B, it's B.

## Step 2 — Write the test (Tier A only)

1. Create **one new file**: `tests/SharedModelsTests/<UseCaseName>Tests.swift`. Never edit an existing test file (parallel-safe: one instance, one file).
2. Use `import XCTest` + `@testable import SharedModels`. Match the repo's style exactly — see [REFERENCE.md](REFERENCE.md) for the template and real examples. XCTest is synchronous; for async APIs use `XCTestExpectation`.
3. Build in-memory fixtures (synthetic buffers, `Data` literals) — no network, no disk, no live audio. If the use case genuinely needs those, it was Tier C.
4. Verify your file alone: `swift test --filter <UseCaseName>Tests`. SPM serializes builds via a lock, so this is safe under parallelism (may queue briefly). Iterate until it passes.
5. Report success (Step 4).

## Step 3 — Emit a SETUP REPORT (Tier B & C)

Do not touch shared files (`Sources/`, `SharedSources/`, `Package.swift`). Produce the structured report from [REFERENCE.md](REFERENCE.md): for **Tier B**, exactly what to extract from which `Sources/` file into a new `SharedSources/` file (types, dependencies, the seam/protocol needed to break I/O), plus the test you *would* write once extracted. For **Tier C**, the harness the orchestrator must stand up (Xcode project + UI test target driving `Murmur.app` via accessibility, or a new `tests/test-*` executable for live I/O) and why SPM can't host it.

## Step 4 — Return a structured result to the orchestrator

End with the JSON result block defined in [REFERENCE.md](REFERENCE.md) (`tier`, `useCase`, `status`, `file`, `setupNeeded`). This is consumed by the orchestrator, not shown to a human — keep it parseable.

## Orchestrator note

If you are the orchestrator (not a single-use-case worker): see [ORCHESTRATION.md](ORCHESTRATION.md) for how to fan out, collect reports, batch the shared setup (extractions, XCUITest harness) that workers cannot do in parallel, then re-run workers on the now-testable cases.
