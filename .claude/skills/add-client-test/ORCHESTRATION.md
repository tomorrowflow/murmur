# add-client-test — Orchestration

How the **main orchestrator** drives parallel `add-client-test` workers. The worker handles one use case; you handle the fan-out and the shared setup workers can't safely do in parallel.

## Why setup is the orchestrator's job

Workers run concurrently and share the repo. Two things break under parallel edits, so workers only *report* them and you perform them serially:

1. **Extraction (Tier B)** — moving logic from `Sources/` into `SharedSources/` edits files (`main.swift`, `Package.swift`-adjacent) every worker touches.
2. **XCUITest harness (Tier C)** — there is no `.xcodeproj`; standing up a UI test bundle (or a new `tests/test-*` executable) is a one-time, repo-wide change.

## Loop

1. **Collect use cases.** A list of behaviors to cover (from a spec, a feature, or gaps). Keep each use case to a single behavior.
2. **Fan out — round 1.** Spawn one worker per use case in parallel (the Agent tool with multiple calls in one message, or a `Workflow` `parallel`/`pipeline`). Give each worker exactly one use case and the instruction to follow this skill. Workers writing Tier-A files are safe in parallel: each writes its own `tests/SharedModelsTests/<Name>Tests.swift`, none edits `Package.swift` or shared sources.
3. **Collect results.** Parse each worker's JSON result block. Partition by tier:
   - `tier A, implemented` → done.
   - `tier B` → queue of extractions.
   - `tier C` → queue of harness work.
4. **Do shared setup serially (you, not workers).**
   - **Tier B**: perform each extraction — move the pure logic into a new `SharedSources/<Type>.swift`, introduce the protocol seam the report names (so I/O can be faked), update `Sources/` call sites. Build (`swift build`) after each. The `SharedModelsTests` target needs no change (it globs).
   - **Tier C**: decide per case — stand up the XCUITest harness (generate/commit an `.xcodeproj` with a UI test target that launches `Murmur.app` and drives it via `XCUIApplication` + accessibility ids; add the ids to the relevant overlay/menu controls), or add a `tests/test-<name>` executable target to `Package.swift` for live-I/O smoke tests. UI/live tests are generally not CI-gated — note that.
5. **Fan out — round 2.** Re-spawn workers for the now-extracted Tier-B cases; they are Tier A this time and will write + verify tests.
6. **Final gate.** Run the full suite once: `swift test`. Report total tests, pass/fail, and any Tier-C items intentionally left as manual `swift run` tools.

## Initial test setup (first time only)

If `tests/SharedModelsTests/` and the `SharedModelsTests` testTarget don't yet exist (they do in this repo today), the very first setup is: add the `.testTarget(name: "SharedModelsTests", dependencies: ["SharedModels"], path: "tests/SharedModelsTests")` entry to `Package.swift` and create the directory. After that, workers add files without further `Package.swift` edits.

## Scaling guidance

- Cap concurrency to what the SPM build lock tolerates comfortably (workers serialize on build; ~4–8 in flight is plenty).
- Prefer a `Workflow` `pipeline` when you want each use case to flow classify → write → verify independently without a barrier. Use `parallel` only when you need all reports before starting setup (you usually do, to batch extractions).
